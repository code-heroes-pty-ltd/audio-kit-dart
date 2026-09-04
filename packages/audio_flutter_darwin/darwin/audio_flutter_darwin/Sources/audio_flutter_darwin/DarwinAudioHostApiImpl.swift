import AVFoundation
import Foundation

#if os(iOS)
  import Flutter
#elseif os(macOS)
  import FlutterMacOS
#endif

protocol NativeCaptureSession: AnyObject {
  var sessionId: Int64 { get }
  var format: PcmFormatMessage { get }
  var mailbox: FrameMailbox { get }

  func start() throws
  func stop(discardBuffered: Bool)
}

final class DarwinAudioHostApiImpl: DarwinAudioHostApi {
  private let events: SessionEventsHandler
  private let lock = NSLock()
  private let blockingQueue = DispatchQueue(
    label: "audio_flutter.host_blocking",
    qos: .userInitiated,
    attributes: .concurrent
  )
  private var nextId: Int64 = 1
  private var captures: [Int64: NativeCaptureSession] = [:]
  private var playbacks: [Int64: PcmPlaybackSession] = [:]

  init(events: SessionEventsHandler) {
    self.events = events
  }

  /// Runs `work` off the platform thread and replies on the main thread.
  private func offloadToBlockingQueue<Value>(
    _ completion: @escaping (Result<Value, Error>) -> Void,
    _ work: @escaping () -> Result<Value, Error>
  ) {
    blockingQueue.async {
      let result = work()
      DispatchQueue.main.async {
        completion(result)
      }
    }
  }

  private func allocateId() -> Int64 {
    lock.lock()
    defer { lock.unlock() }
    let id = nextId
    nextId += 1
    return id
  }

  private func capture(_ id: Int64) -> NativeCaptureSession? {
    lock.lock()
    defer { lock.unlock() }
    return captures[id]
  }

  private func playback(_ id: Int64) -> PcmPlaybackSession? {
    lock.lock()
    defer { lock.unlock() }
    return playbacks[id]
  }

  private func missing(_ id: Int64, kind: String) -> PigeonError {
    PigeonError(
      code: "SessionNotFound",
      message: "\(kind) session \(id) does not exist.",
      details: nil
    )
  }

  func prepareCapture(
    request: CaptureRequestMessage,
    completion: @escaping (Result<CaptureSessionInfoMessage, Error>) -> Void
  ) {
    let id = allocateId()
    offloadToBlockingQueue(completion) { [self] in
      Result { try makeCaptureSession(id: id, request: request) }
    }
  }

  /// Builds, registers, and announces one prepared capture session.
  ///
  /// Split out of `prepareCapture` so the Core Audio work it performs can run
  /// on `blockingQueue` while the Pigeon reply stays on the main thread.
  private func makeCaptureSession(
    id: Int64,
    request: CaptureRequestMessage
  ) throws -> CaptureSessionInfoMessage {
    let session: NativeCaptureSession
    switch request.kind {
    case .microphone:
      session = try MicrophoneCaptureSession(
        sessionId: id,
        request: request,
        events: events
      )
    case .systemAudio:
      #if os(macOS)
        if #available(macOS 14.4, *) {
          session = SystemAudioCaptureSession(
            sessionId: id,
            request: request,
            events: events
          )
        } else {
          throw PigeonError(
            code: "Unsupported",
            message: "System audio capture requires macOS 14.4 or newer.",
            details: nil
          )
        }
      #else
        throw PigeonError(
          code: "Unsupported",
          message: "System audio capture is unavailable on iOS.",
          details: nil
        )
      #endif
    }
    lock.lock()
    captures[id] = session
    lock.unlock()
    let source = request.kind == .microphone ? "microphone-\(id)" : "system-\(id)"
    let track = request.kind == .microphone ? "microphone" : "system"
    events.emit(
      AudioSessionEventMessage(sessionId: id, phase: .prepared)
    )
    return CaptureSessionInfoMessage(
      sessionId: id,
      sourceId: source,
      trackId: track,
      clockId: "darwin.host-time",
      format: request.outputFormat
    )
  }

  func startCapture(
    sessionId: Int64,
    completion: @escaping (Result<Void, Error>) -> Void
  ) {
    guard let session = capture(sessionId) else {
      completion(.failure(missing(sessionId, kind: "Capture")))
      return
    }
    events.emit(
      AudioSessionEventMessage(sessionId: sessionId, phase: .starting)
    )
    offloadToBlockingQueue(completion) {
      Result { try session.start() }
    }
  }

  func readCaptureFrames(
    sessionId: Int64,
    maxFrames: Int64,
    timeoutMillis: Int64,
    completion: @escaping (Result<AudioFrameBatchMessage, Error>) -> Void
  ) {
    guard let session = capture(sessionId) else {
      completion(.failure(missing(sessionId, kind: "Capture")))
      return
    }
    blockingQueue.async {
      let batch = session.mailbox.read(
        maxFrames: Int(clamping: maxFrames),
        timeout: Double(max(timeoutMillis, 0)) / 1_000
      )
      completion(.success(batch))
    }
  }

  func stopCapture(
    sessionId: Int64,
    completion: @escaping (Result<Void, Error>) -> Void
  ) {
    guard let session = capture(sessionId) else {
      completion(.success(()))
      return
    }
    events.emit(
      AudioSessionEventMessage(sessionId: sessionId, phase: .stopping)
    )
    offloadToBlockingQueue(completion) {
      session.stop(discardBuffered: false)
      return .success(())
    }
  }

  func abortCapture(
    sessionId: Int64,
    completion: @escaping (Result<Void, Error>) -> Void
  ) {
    let session = capture(sessionId)
    offloadToBlockingQueue(completion) {
      session?.stop(discardBuffered: true)
      return .success(())
    }
  }

  /// Tearing a session down destroys its engine, tap and aggregate device, so
  /// it runs off the platform thread like `stopCapture`; the registry entry is
  /// removed synchronously so a later call cannot find a session being torn down.
  func disposeCapture(
    sessionId: Int64,
    completion: @escaping (Result<Void, Error>) -> Void
  ) {
    lock.lock()
    let session = captures.removeValue(forKey: sessionId)
    lock.unlock()
    offloadToBlockingQueue(completion) {
      session?.stop(discardBuffered: true)
      return .success(())
    }
  }

  func isSystemAudioCaptureSupported(
    completion: @escaping (Result<Bool, Error>) -> Void
  ) {
    #if os(macOS)
      if #available(macOS 14.4, *) {
        completion(.success(true))
        return
      }
    #endif
    completion(.success(false))
  }

  func requestSystemAudioCapturePermission(
    completion: @escaping (Result<Bool, Error>) -> Void
  ) {
    offloadToBlockingQueue(completion) {
      #if os(macOS)
        if #available(macOS 14.4, *) {
          return .success(SystemAudioCaptureSession.preflightPermission())
        }
      #endif
      return .success(false)
    }
  }

  func microphonePermissionStatus(
    completion: @escaping (Result<MicrophonePermissionStatusMessage, Error>) -> Void
  ) {
    completion(
      .success(Self.permission(AVCaptureDevice.authorizationStatus(for: .audio)))
    )
  }

  /// `requestAccess` prompts only while the status is `.notDetermined`; for
  /// every other status it returns the standing answer without UI, so this
  /// reads the status first and reports it unchanged.
  func requestMicrophonePermission(
    completion: @escaping (Result<MicrophonePermissionStatusMessage, Error>) -> Void
  ) {
    let status = AVCaptureDevice.authorizationStatus(for: .audio)
    guard status == .notDetermined else {
      completion(.success(Self.permission(status)))
      return
    }
    AVCaptureDevice.requestAccess(for: .audio) { granted in
      completion(.success(granted ? .granted : .denied))
    }
  }

  private static func permission(
    _ status: AVAuthorizationStatus
  ) -> MicrophonePermissionStatusMessage {
    switch status {
    case .authorized: return .granted
    case .denied: return .denied
    case .restricted: return .restricted
    case .notDetermined: return .notDetermined
    @unknown default: return .denied
    }
  }

  func cleanupOrphanedAggregateDevices(
    completion: @escaping (Result<Int64, Error>) -> Void
  ) {
    offloadToBlockingQueue(completion) {
      #if os(macOS)
        if #available(macOS 14.4, *) {
          return .success(
            SystemAudioCaptureSession.cleanupOrphanedAggregateDevices()
          )
        }
      #endif
      return .success(0)
    }
  }

  func listAudioProcesses(
    completion: @escaping (Result<[AudioProcessMessage], Error>) -> Void
  ) {
    #if os(macOS)
      if #available(macOS 14.4, *) {
        completion(.success(SystemAudioCaptureSession.listProcesses()))
        return
      }
    #endif
    completion(.success([]))
  }

  func listAudioInputDevices(
    completion: @escaping (Result<[AudioInputDeviceMessage], Error>) -> Void
  ) {
    completion(.success(AudioInputDevices.list()))
  }

  func preparePlayback(
    request: PlaybackRequestMessage,
    completion: @escaping (Result<PlaybackSessionInfoMessage, Error>) -> Void
  ) {
    let id = allocateId()
    do {
      let session = try PcmPlaybackSession(
        sessionId: id,
        request: request,
        events: events
      )
      lock.lock()
      playbacks[id] = session
      lock.unlock()
      events.emit(
        AudioSessionEventMessage(sessionId: id, phase: .prepared)
      )
      completion(
        .success(
          PlaybackSessionInfoMessage(
            sessionId: id,
            clockId: "darwin-playback-\(id)",
            format: request.inputFormat
          )
        )
      )
    } catch {
      completion(.failure(error))
    }
  }

  func startPlayback(
    sessionId: Int64,
    completion: @escaping (Result<Void, Error>) -> Void
  ) {
    guard let session = playback(sessionId) else {
      completion(.failure(missing(sessionId, kind: "Playback")))
      return
    }
    do {
      try session.start()
      completion(.success(()))
    } catch {
      completion(.failure(error))
    }
  }

  func writePlaybackFrames(
    sessionId: Int64,
    frames: [AudioFrameMessage],
    completion: @escaping (Result<Void, Error>) -> Void
  ) {
    guard let session = playback(sessionId) else {
      completion(.failure(missing(sessionId, kind: "Playback")))
      return
    }
    blockingQueue.async {
      do {
        try session.enqueue(frames)
        completion(.success(()))
      } catch {
        completion(.failure(error))
      }
    }
  }

  func finishPlayback(
    sessionId: Int64,
    completion: @escaping (Result<Void, Error>) -> Void
  ) {
    guard let session = playback(sessionId) else {
      completion(.success(()))
      return
    }
    blockingQueue.async {
      session.finish()
      completion(.success(()))
    }
  }

  func abortPlayback(
    sessionId: Int64,
    completion: @escaping (Result<Void, Error>) -> Void
  ) {
    playback(sessionId)?.abort()
    completion(.success(()))
  }

  func disposePlayback(
    sessionId: Int64,
    completion: @escaping (Result<Void, Error>) -> Void
  ) {
    lock.lock()
    let session = playbacks.removeValue(forKey: sessionId)
    lock.unlock()
    session?.abort()
    completion(.success(()))
  }

  func teardown() {
    lock.lock()
    let captureValues = Array(captures.values)
    let playbackValues = Array(playbacks.values)
    captures.removeAll()
    playbacks.removeAll()
    lock.unlock()
    captureValues.forEach { $0.stop(discardBuffered: true) }
    playbackValues.forEach { $0.abort() }
  }
}
