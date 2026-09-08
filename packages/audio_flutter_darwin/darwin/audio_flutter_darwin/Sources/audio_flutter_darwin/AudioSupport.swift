import AVFoundation
import Foundation
import os

import FlutterMacOS

enum MonotonicClock {
  static func microseconds(hostTime: UInt64? = nil) -> Int64 {
    let ticks = hostTime ?? mach_continuous_time()
    return Int64((AVAudioTime.seconds(forHostTime: ticks) * 1_000_000).rounded())
  }
}

/// Heap-backed unfair lock with the stateful `withLock` API used by the audio
/// callbacks. `OSAllocatedUnfairLock` only exists on macOS 13; the underlying
/// unfair-lock primitive is available on macOS 12 and keeps the callback path
/// allocation-free after initialization.
final class CompatibleUnfairLock<State>: @unchecked Sendable {
  private var primitive = os_unfair_lock_s()
  private var state: State

  init(initialState: State) {
    state = initialState
  }

  @inline(__always)
  func withLock<Result>(_ body: (inout State) throws -> Result) rethrows -> Result {
    os_unfair_lock_lock(&primitive)
    defer { os_unfair_lock_unlock(&primitive) }
    return try body(&state)
  }
}

enum AudioTypedData {
  static func encode(_ samples: [Float]) -> FlutterStandardTypedData {
    FlutterStandardTypedData(bytes: samples.withUnsafeBytes { Data($0) })
  }

  static func decode(_ data: FlutterStandardTypedData) -> [Float] {
    let count = data.data.count / MemoryLayout<Float>.size
    var output = [Float](repeating: 0, count: count)
    _ = output.withUnsafeMutableBytes {
      data.data.copyBytes(to: $0, count: count * MemoryLayout<Float>.size)
    }
    return output
  }
}

/// One stateful converter per source/track. AVAudioConverter carries filter
/// history, so creating a converter for every callback introduces boundary
/// artifacts.
final class PersistentAudioConverter {
  let outputFormat: AVAudioFormat
  /// The format this converter was built to read. Callers that receive buffers
  /// whose format they did not choose — a tap installed without an asserted
  /// format — compare against this to know when to rebuild.
  let inputFormat: AVAudioFormat
  private let converter: AVAudioConverter

  init?(inputFormat: AVAudioFormat, sampleRate: Double, channelCount: AVAudioChannelCount) {
    guard
      let output = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: sampleRate,
        channels: channelCount,
        interleaved: false
      ),
      let converter = AVAudioConverter(from: inputFormat, to: output)
    else { return nil }
    outputFormat = output
    self.inputFormat = inputFormat
    self.converter = converter
    Self.mapUnmappedOutputChannels(of: converter, inputFormat: inputFormat)
  }

  /// Points output channels the converter left unmapped at real input channels.
  private static func mapUnmappedOutputChannels(
    of converter: AVAudioConverter,
    inputFormat: AVAudioFormat
  ) {
    let inputChannels = Int(inputFormat.channelCount)
    guard inputChannels > 0 else { return }
    let map = converter.channelMap
    guard map.contains(where: { $0.intValue < 0 }) else { return }
    converter.channelMap = (0..<map.count).map { channel in
      NSNumber(value: min(channel, inputChannels - 1))
    }
  }

  /// Converts to owned interleaved float32 samples.
  func convert(_ input: AVAudioPCMBuffer) -> [Float]? {
    guard input.frameLength > 0 else { return [] }
    let ratio = outputFormat.sampleRate / input.format.sampleRate
    let capacity =
      AVAudioFrameCount((Double(input.frameLength) * ratio).rounded(.up)) + 64
    guard
      let output = AVAudioPCMBuffer(
        pcmFormat: outputFormat,
        frameCapacity: max(capacity, 1)
      )
    else { return nil }

    var consumed = false
    var conversionError: NSError?
    let status = converter.convert(to: output, error: &conversionError) { _, outStatus in
      if consumed {
        outStatus.pointee = .noDataNow
        return nil
      }
      consumed = true
      outStatus.pointee = .haveData
      return input
    }
    guard status != .error, let channels = output.floatChannelData else { return nil }

    let frameCount = Int(output.frameLength)
    let channelCount = Int(outputFormat.channelCount)
    var interleaved = [Float](repeating: 0, count: frameCount * channelCount)
    for frame in 0..<frameCount {
      for channel in 0..<channelCount {
        interleaved[frame * channelCount + channel] = channels[channel][frame]
      }
    }
    return interleaved
  }

  /// Clears filter history after an explicitly reported input discontinuity.
  func reset() {
    converter.reset()
  }
}

enum AudioBufferCopy {
  static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
    guard
      let copy = AVAudioPCMBuffer(
        pcmFormat: buffer.format,
        frameCapacity: buffer.frameLength
      )
    else { return nil }
    copy.frameLength = buffer.frameLength

    let source = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
    let destination = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
    guard source.count == destination.count else { return nil }
    for index in 0..<source.count {
      guard let sourceData = source[index].mData, let destinationData = destination[index].mData
      else { return nil }
      memcpy(
        destinationData,
        sourceData,
        min(Int(source[index].mDataByteSize), Int(destination[index].mDataByteSize))
      )
    }
    return copy
  }
}

/// Source-side file recording. It receives callback-owned buffers only from
/// the capture's serial queue and finalizes the file when released.
final class RawAudioRecorder {
  private var file: AVAudioFile?

  init(path: String, inputFormat: AVAudioFormat) throws {
    let settings: [String: Any] = [
      AVFormatIDKey: kAudioFormatLinearPCM,
      AVSampleRateKey: inputFormat.sampleRate,
      AVNumberOfChannelsKey: Int(inputFormat.channelCount),
      AVLinearPCMBitDepthKey: 32,
      AVLinearPCMIsFloatKey: true,
      AVLinearPCMIsBigEndianKey: false,
      AVLinearPCMIsNonInterleaved: !inputFormat.isInterleaved,
    ]
    file = try AVAudioFile(forWriting: URL(fileURLWithPath: path), settings: settings)
  }

  func write(_ buffer: AVAudioPCMBuffer) throws {
    guard let file else { return }
    try file.write(from: buffer)
  }

  func close() {
    file = nil
  }
}
