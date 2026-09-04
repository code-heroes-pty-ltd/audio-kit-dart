import AVFoundation
import AudioFlutterDarwinCore
import Foundation
import os

#if os(macOS)
  import CoreAudio
  import FlutterMacOS

  /// Core Audio process-tap capture for macOS 14.4 and newer.
  @available(macOS 14.4, *)
  final class SystemAudioCaptureSession: NativeCaptureSession {
    let sessionId: Int64
    let format: PcmFormatMessage
    let mailbox: FrameMailbox

    private let request: CaptureRequestMessage
    private let events: SessionEventsHandler
    private let ioQueue = DispatchQueue(
      label: "audio_flutter.system_capture",
      qos: .userInitiated
    )
    private let workerQueue = DispatchQueue(
      label: "audio_flutter.system_capture.worker",
      qos: .userInitiated
    )
    private let workRing: CaptureWorkRing
    private let lifecycle = NSLock()
    private let running = CompatibleUnfairLock(initialState: false)
    private let failureScheduled = CompatibleUnfairLock(initialState: false)
    private let holdsActivity = CompatibleUnfairLock(initialState: false)
    private let renderCycles = CompatibleUnfairLock(initialState: Int64(0))
    /// Serial queue the HAL delivers default-output-device notifications on.
    /// Separate from `ioQueue`/`workerQueue`, which a rebuild drains.
    private let deviceListenerQueue = DispatchQueue(
      label: "audio_flutter.system_capture.device_listener",
      qos: .userInitiated
    )
    private var tapId = AudioObjectID(kAudioObjectUnknown)
    private var aggregateId = AudioObjectID(kAudioObjectUnknown)
    private var aggregateUid: String?
    private var clockDeviceUid: String?
    /// Rate the current chain's converter expects from the IO proc.
    private var deliveredSampleRate: Double = 0
    private var outputDeviceListener: AudioObjectPropertyListenerBlock?
    private var aggregateRateListener: AudioObjectPropertyListenerBlock?
    private var aggregateRateListenerDevice = AudioObjectID(kAudioObjectUnknown)
    private var aggregateStreamListener: AudioObjectPropertyListenerBlock?
    private var aggregateStreamListenerDevice = AudioObjectID(kAudioObjectUnknown)
    /// Input channels the current chain's IO proc expects the aggregate to
    /// present: the tap's own, and nothing in front of them.
    private var deliveredInputChannels: UInt32 = 0
    private var ioProcId: AudioDeviceIOProcID?
    private var assembler: CaptureFrameAssembler
    private var converter: PersistentAudioConverter?
    private var recorder: RawAudioRecorder?
    /// Input format the raw recording was opened with; a rebuild that changes
    /// the delivered format must end the recording rather than feed it.
    private var recorderFormat: AVAudioFormat?
    /// A format-change close is final: recreating the recorder would reopen
    /// the same path and overwrite the audio already written.
    private var rawRecordingEnded = false
    private var watchdog: Task<Void, Never>?

    init(
      sessionId: Int64,
      request: CaptureRequestMessage,
      events: SessionEventsHandler
    ) {
      self.sessionId = sessionId
      self.request = request
      self.events = events
      format = request.outputFormat
      workRing = CaptureWorkRing(
        maximumDurationMicros: request.maxBufferedDurationMicros,
        // Source-native recording must never silently omit callback audio.
        overflowPolicy: request.rawRecordingPath == nil
          ? request.overflowPolicy
          : .failCapture
      )
      let frameDuration = max(request.frameDurationMicros, 1)
      let capacity = max(
        Int(request.maxBufferedDurationMicros / frameDuration),
        1
      )
      let mailbox = FrameMailbox(
        capacity: capacity,
        overflowPolicy: request.overflowPolicy
      )
      self.mailbox = mailbox
      assembler = CaptureFrameAssembler(
        sessionId: sessionId,
        sampleRate: Int(request.outputFormat.sampleRate),
        channelCount: Int(request.outputFormat.channelCount),
        frameDurationMicros: request.frameDurationMicros,
        mailbox: mailbox
      )
    }

    func start() throws {
      lifecycle.lock()
      defer { lifecycle.unlock() }
      guard !running.withLock({ $0 }) else { return }
      running.withLock { $0 = true }
      do {
        try startChainLocked()
      } catch {
        running.withLock { $0 = false }
        workRing.finish(discardBuffered: true)
        workerQueue.sync {}
        unwindLocked()
        throw error
      }
      installOutputDeviceListenerLocked()
      setActivityHold(true)
      events.emit(
        AudioSessionEventMessage(
          sessionId: sessionId,
          phase: .running,
          receivingAudio: false,
          callbackCount: 0
        )
      )
      let initialStatistics = assembler.statistics()
      let initialNonZero = initialStatistics.nonZeroFrameCount
      watchdog = Task { [weak self] in
        await self?.superviseCapture(initialNonZeroFrameCount: initialNonZero)
      }
    }

    private static let supervisionWindowNanos: UInt64 = 2_000_000_000

    /// Supervises a freshly started chain: confirms audio within one window,
    /// rebuilds a silent tap once against a freshly resolved target set
    /// (Electron/Chromium helpers may become tappable after start; see
    /// [tapDescription]), and then separates the silent outcomes that used to
    /// collapse into one failure:
    ///
    /// - Zero render cycles: `kAudioAggregateDeviceTapAutoStartKey` arms the
    ///   aggregate, and the HAL defers its start until a tapped process
    ///   receives its first audio. A tap on an app that is not playing yet
    ///   sits here indefinitely and begins delivering the moment sound
    ///   arrives — a waiting state, not a failure. The session stays alive
    ///   and reports `SystemCaptureAwaitingAppAudio` health so hosts can
    ///   re-resolve their process selection.
    /// - Render cycles advancing while nothing survives conversion into the
    ///   assembler for two consecutive windows: the pipeline is genuinely
    ///   broken and fails as `SystemCaptureDead`.
    /// - Converted buffers arriving all-zero: alive-but-silent health, the
    ///   documented shape of a TCC-denied tap.
    ///
    /// The window timing, the device probe, the rebuild, and the events are
    /// this method's; which outcome a window's counters mean belongs to
    /// [SystemCaptureSupervisionDecider], where it is unit-tested.
    private func superviseCapture(initialNonZeroFrameCount: Int64) async {
      try? await Task.sleep(nanoseconds: Self.supervisionWindowNanos)
      guard !Task.isCancelled, running.withLock({ $0 }) else { return }
      let checkStatistics = assembler.statistics()
      switch SystemCaptureSupervisionDecider.initialOutcome(
        nonZeroFrameCount: checkStatistics.nonZeroFrameCount,
        baselineNonZeroFrameCount: initialNonZeroFrameCount
      ) {
      case .reportReceiving:
        events.emit(
          healthEvent(
            phase: .running,
            receivingAudio: true,
            statistics: checkStatistics
          )
        )
        return
      case .rebuildChain:
        break
      }
      events.emit(
        healthEvent(
          phase: .interrupted,
          message: "System capture is silent; rebuilding its process tap once.",
          receivingAudio: false,
          statistics: checkStatistics
        )
      )
      guard rebuild() else { return }
      // Assembler counters are monotonic across a rebuild
      // (`markSourceRestart` only flags a discontinuity), so the pre-rebuild
      // snapshot is the baseline — callbacks landing while the new chain
      // starts count as progress instead of inflating a post-start baseline.
      // `renderCycles` is a session-lifetime counter too, so its baseline is
      // read here rather than assumed to be zero.
      var decider = SystemCaptureSupervisionDecider(
        baselineCallbackCount: checkStatistics.callbackCount,
        baselineNonZeroFrameCount: checkStatistics.nonZeroFrameCount,
        renderCyclesBaseline: renderCycles.withLock { $0 }
      )
      while !Task.isCancelled, running.withLock({ $0 }) {
        try? await Task.sleep(nanoseconds: Self.supervisionWindowNanos)
        guard !Task.isCancelled, running.withLock({ $0 }) else { return }
        let statistics = assembler.statistics()
        let window = SystemCaptureSupervisionDecider.Window(
          callbackCount: statistics.callbackCount,
          nonZeroFrameCount: statistics.nonZeroFrameCount,
          renderCycles: renderCycles.withLock { $0 }
        )
        switch decider.evaluate(window) {
        case .reportAliveAndStop(let receiving):
          events.emit(
            healthEvent(
              phase: .running,
              message: receiving
                ? nil : "System tap is alive but currently silent.",
              receivingAudio: receiving,
              statistics: statistics
            )
          )
          return
        case .probeDeviceRunning:
          lifecycle.lock()
          let aggregate = aggregateId
          lifecycle.unlock()
          // Probing can race the chain coming alive, so the cycle counter is
          // re-read after the probe.
          let idle = decider.resolveIdleWindow(
            deviceIsRunning: Self.deviceIsRunning(aggregate),
            renderCyclesAfterProbe: renderCycles.withLock { $0 }
          )
          switch idle {
          case .escalateDead(let death):
            fail(code: "SystemCaptureDead", message: Self.message(for: death))
            return
          case .reportAwaitingAppAudio:
            events.emit(
              healthEvent(
                phase: .interrupted,
                code: "SystemCaptureAwaitingAppAudio",
                message:
                  "The tapped application is not playing audio; capture is "
                  + "armed and starts with its first sound.",
                receivingAudio: false,
                statistics: statistics
              )
            )
          case .keepWaiting:
            break
          }
        case .escalateDead(let death):
          fail(code: "SystemCaptureDead", message: Self.message(for: death))
          return
        case .keepWaiting:
          break
        }
      }
    }

    /// The host-facing explanation of a supervision death.
    private static func message(for death: SystemCaptureDeath) -> String {
      switch death {
      case .renderCallbackNeverFired:
        // A device that reports running while the IO proc still has not fired
        // has a broken render-callback registration, which waiting cannot
        // repair.
        return
          "The capture aggregate is running but its render callback "
          + "never fired."
      case .noAudioSurvivedConversion(let renderCycles):
        return
          "The system tap ran \(renderCycles) render cycles but no audio "
          + "survived conversion into the capture pipeline."
      }
    }

    /// One health event carrying the full statistics snapshot. Built only where
    /// health is already emitted, so widening the payload does not raise the
    /// event rate.
    private func healthEvent(
      phase: AudioSessionPhaseMessage,
      code: String? = nil,
      message: String? = nil,
      receivingAudio: Bool,
      statistics: CaptureStatistics
    ) -> AudioSessionEventMessage {
      AudioSessionEventMessage(
        sessionId: sessionId,
        phase: phase,
        code: code,
        message: message,
        receivingAudio: receivingAudio,
        callbackCount: statistics.callbackCount,
        peakAmplitude: statistics.peakAmplitude,
        rms: statistics.rms,
        nonZeroFramePercent: statistics.nonZeroFramePercent,
        renderCycles: renderCycles.withLock { $0 },
        firstAudioAtMillis: statistics.firstAudioAtMillis
      )
    }

    /// Puts a freshly rebuilt chain back under supervision.
    private func restartSupervisionLocked() {
      watchdog?.cancel()
      let baseline = assembler.statistics().nonZeroFrameCount
      watchdog = Task { [weak self] in
        await self?.superviseCapture(initialNonZeroFrameCount: baseline)
      }
    }

    /// Rebuilds the capture chain in place.
    private func rebuild(restartSupervision: Bool = false) -> Bool {
      lifecycle.lock()
      defer { lifecycle.unlock() }
      guard running.withLock({ $0 }) else { return false }
      teardownChainLocked()
      assembler.markSourceRestart()
      do {
        try startChainLocked()
        if restartSupervision {
          restartSupervisionLocked()
        }
        return true
      } catch {
        running.withLock { $0 = false }
        workRing.finish(discardBuffered: true)
        workerQueue.sync {}
        removeOutputDeviceListenerLocked()
        recorder?.close()
        recorder = nil
        setActivityHold(false)
        mailbox.finish(discardBuffered: true)
        events.emit(
          AudioSessionEventMessage(
            sessionId: sessionId,
            phase: .failed,
            code: "SystemCaptureRebuildFailed",
            message: error.localizedDescription,
            receivingAudio: false
          )
        )
        return false
      }
    }

    private func startChainLocked() throws {
      let description = try Self.tapDescription(
        bundleIds: request.bundleIds ?? [],
        processIds: request.processIds
      )
      description.name = "audio_flutter system capture"
      description.isPrivate = true
      description.muteBehavior = .unmuted

      var tap = AudioObjectID(kAudioObjectUnknown)
      var status = AudioHardwareCreateProcessTap(description, &tap)
      guard status == noErr else {
        throw PigeonError(
          code: "TapCreateFailed",
          message: "AudioHardwareCreateProcessTap failed (\(status)).",
          details: nil
        )
      }
      tapId = tap

      // Adapted from Control Center (MIT © 2026 Samuel Alev): a tap-only
      // aggregate supplies no clock of its own, and was observed never to be
      // clocked on macOS 26 with a USB output device — the aggregate's
      // `kAudioDevicePropertyDeviceIsRunning` stayed 0 and the IO proc never
      // fired, with the capture grant in place. Anchoring the aggregate to the
      // current default output device as both main sub-device and explicit
      // clock device gives the HAL real hardware to clock from. The output
      // device is a clock source only; the tap still carries the whole-system
      // mix regardless of output routing.
      var clockDeviceUid = Self.defaultOutputDeviceUid()
      let uid = Self.aggregateUidPrefix + UUID().uuidString
      var aggregate = AudioObjectID(kAudioObjectUnknown)
      status = AudioHardwareCreateAggregateDevice(
        Self.aggregateDescription(
          aggregateUid: uid,
          tapUid: description.uuid.uuidString,
          clockDeviceUid: clockDeviceUid,
          clockDeviceContributesInput: clockDeviceUid.map {
            Self.inputChannelCount(uid: $0) > 0
          } ?? false
        ) as CFDictionary,
        &aggregate
      )
      if status != noErr, clockDeviceUid != nil {
        // A composition the HAL rejects must not cost the session its capture:
        // retry as the unclocked tap-only aggregate. The session must then
        // remember it is unclocked — output-device changes are irrelevant to
        // it, and diagnostics must not claim a clock it does not have.
        clockDeviceUid = nil
        status = AudioHardwareCreateAggregateDevice(
          Self.aggregateDescription(
            aggregateUid: uid,
            tapUid: description.uuid.uuidString,
            clockDeviceUid: nil
          ) as CFDictionary,
          &aggregate
        )
      }
      guard status == noErr else {
        unwindLocked()
        throw PigeonError(
          code: "AggregateCreateFailed",
          message: "AudioHardwareCreateAggregateDevice failed (\(status)).",
          details: nil
        )
      }
      aggregateId = aggregate
      aggregateUid = uid
      self.clockDeviceUid = clockDeviceUid
      // Registered before any failure path can run, so the orphan sweeper never
      // destroys a device this process is still building on.
      Self.liveAggregateUids.withLock { _ = $0.insert(uid) }

      guard let tapDescribedFormat = Self.tapFormat(tapId) else {
        unwindLocked()
        throw PigeonError(
          code: "TapFormatUnavailable",
          message: "Could not read the process tap format.",
          details: nil
        )
      }
      // The aggregate delivers at its CLOCK device's rate — the HAL resamples
      // the tap's stream into that clock domain (AirPods in HFP/SCO clock it
      // at 24 kHz) — while kAudioTapPropertyFormat keeps reporting the tap
      // object's own 48 kHz. Labeling IO buffers with the tap format would
      // write half-speed content into a full-rate container: the 2x
      // "chipmunk" recording. The aggregate's nominal rate is the truth.
      let inputFormat = Self.formatAtDeviceRate(
        tapDescribedFormat,
        device: aggregate
      )
      deliveredSampleRate = inputFormat.sampleRate
      deliveredInputChannels = inputFormat.channelCount
      guard
        let converter = PersistentAudioConverter(
          inputFormat: inputFormat,
          sampleRate: Double(request.outputFormat.sampleRate),
          channelCount: AVAudioChannelCount(request.outputFormat.channelCount)
        )
      else {
        unwindLocked()
        throw PigeonError(
          code: "ConverterUnavailable",
          message: "Could not convert the process tap format.",
          details: nil
        )
      }
      self.converter = converter
      if let openFormat = recorderFormat, recorder != nil,
        openFormat != inputFormat
      {
        // A source-native WAV carries one format; buffers from a rebuilt
        // chain at a new rate would corrupt it. End the recording and let
        // the capture continue — the durable converted track is unaffected.
        recorder?.close()
        recorder = nil
        recorderFormat = nil
        rawRecordingEnded = true
        events.emit(
          healthEvent(
            phase: .interrupted,
            code: "SystemRecordingFormatChanged",
            message:
              "The source-native recording ended because the capture chain "
              + "was rebuilt at a different format.",
            receivingAudio: false,
            statistics: assembler.statistics()
          )
        )
      }
      if recorder == nil, !rawRecordingEnded, let path = request.rawRecordingPath {
        recorder = try RawAudioRecorder(path: path, inputFormat: inputFormat)
        recorderFormat = inputFormat
      }

      var proc: AudioDeviceIOProcID?
      status = AudioDeviceCreateIOProcIDWithBlock(
        &proc,
        aggregateId,
        ioQueue
      ) { [weak self] now, inputData, inputTime, _, _ in
        guard let self, self.running.withLock({ $0 }) else { return }
        self.renderCycles.withLock { $0 += 1 }
        guard
          let buffer = AVAudioPCMBuffer(
            pcmFormat: inputFormat,
            bufferListNoCopy: inputData,
            deallocator: nil
          ),
          buffer.frameLength > 0,
          let copy = AudioBufferCopy.copy(buffer)
        else { return }
        let inputFlags = inputTime.pointee.mFlags
        let nowFlags = now.pointee.mFlags
        let hostTime: UInt64?
        if inputFlags.contains(.hostTimeValid) {
          hostTime = inputTime.pointee.mHostTime
        } else if nowFlags.contains(.hostTimeValid) {
          hostTime = now.pointee.mHostTime
        } else {
          hostTime = nil
        }
        self.enqueue(
          copy,
          timestampMicros: MonotonicClock.microseconds(hostTime: hostTime)
        )
      }
      guard status == noErr, let proc else {
        unwindLocked()
        throw PigeonError(
          code: "IOProcCreateFailed",
          message: "AudioDeviceCreateIOProcIDWithBlock failed (\(status)).",
          details: nil
        )
      }
      ioProcId = proc
      installAggregateRateListenerLocked(on: aggregateId)
      installAggregateStreamListenerLocked(on: aggregateId)
      status = AudioDeviceStart(aggregateId, proc)
      guard status == noErr else {
        unwindLocked()
        throw PigeonError(
          code: "DeviceStartFailed",
          message: "AudioDeviceStart failed (\(status)).",
          details: nil
        )
      }
    }

    func stop(discardBuffered: Bool = false) {
      lifecycle.lock()
      let wasRunning = running.withLock { $0 }
      if discardBuffered {
        running.withLock { $0 = false }
      }
      if wasRunning {
        watchdog?.cancel()
        watchdog = nil
        removeOutputDeviceListenerLocked()
        teardownChainLocked(
          discardPendingWork: discardBuffered,
          finishWork: true
        )
      } else {
        workRing.finish(discardBuffered: discardBuffered)
        workerQueue.sync {}
      }
      recorder?.close()
      recorder = nil
      running.withLock { $0 = false }
      setActivityHold(false)
      let failed = failureScheduled.withLock { $0 }
      lifecycle.unlock()
      mailbox.finish(discardBuffered: discardBuffered || failed)
      if wasRunning, !discardBuffered, !failed {
        emitTrailingDropHealth()
      }
      if wasRunning, !failed {
        events.emit(
          AudioSessionEventMessage(
            sessionId: sessionId,
            phase: .stopped,
            receivingAudio: false
          )
        )
      }
    }

    private func fail(code: String, message: String) {
      guard running.withLock({ $0 }) else { return }
      let shouldSchedule = failureScheduled.withLock { scheduled in
        guard !scheduled else { return false }
        scheduled = true
        return true
      }
      guard shouldSchedule else { return }
      workRing.finish(discardBuffered: true)
      // The failure event is the one a host will debug from, so it carries
      // the full statistics snapshot — renderCycles distinguishes a device
      // that never ran from one whose buffers died downstream.
      events.emit(
        healthEvent(
          phase: .failed,
          code: code,
          message: message,
          receivingAudio: false,
          statistics: assembler.statistics()
        )
      )
      // The IO callback runs on `ioQueue`, while teardown drains that same
      // queue. Dispatch lifecycle work elsewhere to avoid self-deadlock.
      DispatchQueue.global(qos: .userInitiated).async { [weak self] in
        self?.stop(discardBuffered: true)
      }
    }

    private func teardownChainLocked(
      discardPendingWork: Bool = false,
      finishWork: Bool = false
    ) {
      if let proc = ioProcId {
        AudioDeviceStop(aggregateId, proc)
        ioQueue.sync {}
      }
      if finishWork {
        workRing.finish(discardBuffered: discardPendingWork)
      }
      workerQueue.sync {}
      unwindLocked()
      converter = nil
    }

    private func unwindLocked() {
      removeAggregateRateListenerLocked()
      removeAggregateStreamListenerLocked()
      if let proc = ioProcId {
        AudioDeviceDestroyIOProcID(aggregateId, proc)
        ioProcId = nil
      }
      if aggregateId != AudioObjectID(kAudioObjectUnknown) {
        AudioHardwareDestroyAggregateDevice(aggregateId)
        aggregateId = AudioObjectID(kAudioObjectUnknown)
      }
      if let uid = aggregateUid {
        Self.liveAggregateUids.withLock { _ = $0.remove(uid) }
        aggregateUid = nil
      }
      clockDeviceUid = nil
      if tapId != AudioObjectID(kAudioObjectUnknown) {
        AudioHardwareDestroyProcessTap(tapId)
        tapId = AudioObjectID(kAudioObjectUnknown)
      }
    }

    /// Watches the default output device the aggregate is clocked from.
    ///
    /// The aggregate anchors to whichever device was default when the chain was
    /// built, so switching output (speakers to AirPods, HDMI unplugged) leaves
    /// it clocked by a device the user no longer routes to — and by a device
    /// that may vanish outright, which stops the IO proc silently. The listener
    /// rebuilds the chain against the new default; the rebuild reports itself
    /// through the frame stream as an `AudioDiscontinuityReason.sourceRestart`.
    private func installOutputDeviceListenerLocked() {
      guard outputDeviceListener == nil else { return }
      var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
      )
      let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        self?.handleDefaultOutputDeviceChange()
      }
      let status = AudioObjectAddPropertyListenerBlock(
        AudioObjectID(kAudioObjectSystemObject),
        &address,
        deviceListenerQueue,
        block
      )
      guard status == noErr else { return }
      outputDeviceListener = block
    }

    private func removeOutputDeviceListenerLocked() {
      guard let block = outputDeviceListener else { return }
      var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
      )
      AudioObjectRemovePropertyListenerBlock(
        AudioObjectID(kAudioObjectSystemObject),
        &address,
        deviceListenerQueue,
        block
      )
      outputDeviceListener = nil
    }

    /// Watches the live aggregate's nominal sample rate.
    ///
    /// A Bluetooth output flipping between A2DP (48 kHz) and HFP/SCO
    /// (16–24 kHz) keeps its UID — the default-output listener never fires —
    /// yet it re-clocks the aggregate, silently changing the rate the IO proc
    /// delivers at. The chain's converter is built for one input rate, so the
    /// only correct response is a rebuild against the new rate.
    private func installAggregateRateListenerLocked(on device: AudioObjectID) {
      removeAggregateRateListenerLocked()
      var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyNominalSampleRate,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
      )
      let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        self?.handleAggregateRateChange()
      }
      let status = AudioObjectAddPropertyListenerBlock(
        device,
        &address,
        deviceListenerQueue,
        block
      )
      guard status == noErr else { return }
      aggregateRateListener = block
      aggregateRateListenerDevice = device
    }

    private func removeAggregateRateListenerLocked() {
      guard let block = aggregateRateListener else { return }
      var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyNominalSampleRate,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
      )
      AudioObjectRemovePropertyListenerBlock(
        aggregateRateListenerDevice,
        &address,
        deviceListenerQueue,
        block
      )
      aggregateRateListener = nil
      aggregateRateListenerDevice = AudioObjectID(kAudioObjectUnknown)
    }

    /// Runs on `deviceListenerQueue` and returns immediately, mirroring
    /// [handleDefaultOutputDeviceChange]'s deadlock discipline.
    private func handleAggregateRateChange() {
      guard running.withLock({ $0 }) else { return }
      DispatchQueue.global(qos: .userInitiated).async { [weak self] in
        self?.rebuildForAggregateRateChange()
      }
    }

    private func rebuildForAggregateRateChange() {
      guard running.withLock({ $0 }) else { return }
      lifecycle.lock()
      let aggregate = aggregateId
      let expected = deliveredSampleRate
      lifecycle.unlock()
      guard
        let rate = Self.deviceNominalSampleRate(aggregate),
        rate > 0,
        rate != expected
      else { return }
      events.emit(
        healthEvent(
          phase: .interrupted,
          code: "CaptureSampleRateChanged",
          message:
            "The capture device renegotiated its sample rate; rebuilding the "
            + "capture chain at the new rate.",
          receivingAudio: false,
          statistics: assembler.statistics()
        )
      )
      _ = rebuild(restartSupervision: true)
    }

    /// Watches the aggregate's own input stream composition.
    private func installAggregateStreamListenerLocked(on device: AudioObjectID) {
      removeAggregateStreamListenerLocked()
      var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyStreamConfiguration,
        mScope: kAudioObjectPropertyScopeInput,
        mElement: kAudioObjectPropertyElementMain
      )
      let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        self?.handleAggregateStreamChange()
      }
      let status = AudioObjectAddPropertyListenerBlock(
        device,
        &address,
        deviceListenerQueue,
        block
      )
      guard status == noErr else { return }
      aggregateStreamListener = block
      aggregateStreamListenerDevice = device
    }

    private func removeAggregateStreamListenerLocked() {
      guard let block = aggregateStreamListener else { return }
      var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyStreamConfiguration,
        mScope: kAudioObjectPropertyScopeInput,
        mElement: kAudioObjectPropertyElementMain
      )
      AudioObjectRemovePropertyListenerBlock(
        aggregateStreamListenerDevice,
        &address,
        deviceListenerQueue,
        block
      )
      aggregateStreamListener = nil
      aggregateStreamListenerDevice = AudioObjectID(kAudioObjectUnknown)
    }

    /// Runs on `deviceListenerQueue` and returns immediately, mirroring
    /// [handleAggregateRateChange]'s deadlock discipline.
    private func handleAggregateStreamChange() {
      guard running.withLock({ $0 }) else { return }
      DispatchQueue.global(qos: .userInitiated).async { [weak self] in
        self?.rebuildForAggregateStreamChange()
      }
    }

    private func rebuildForAggregateStreamChange() {
      guard running.withLock({ $0 }) else { return }
      lifecycle.lock()
      let aggregate = aggregateId
      let expected = deliveredInputChannels
      lifecycle.unlock()
      guard expected > 0, aggregate != AudioObjectID(kAudioObjectUnknown) else {
        return
      }
      let present = Self.inputChannelCount(aggregate)
      guard present != expected else { return }
      events.emit(
        healthEvent(
          phase: .interrupted,
          code: "CaptureStreamLayoutChanged",
          message:
            "The capture aggregate now presents \(present) input channels "
            + "where the tap supplies \(expected); rebuilding the capture "
            + "chain so the tap is read from the right stream.",
          receivingAudio: false,
          statistics: assembler.statistics()
        )
      )
      _ = rebuild(restartSupervision: true)
    }

    /// Runs on `deviceListenerQueue` and returns immediately: teardown removes
    /// this listener while it holds `lifecycle`, so a listener block that
    /// waited for `lifecycle` could deadlock against its own removal.
    private func handleDefaultOutputDeviceChange() {
      guard running.withLock({ $0 }) else { return }
      DispatchQueue.global(qos: .userInitiated).async { [weak self] in
        self?.rebuildForOutputDeviceChange()
      }
    }

    /// A tap-only aggregate (no clock device) is unaffected by the switch, and
    /// a notification that resolves to the same device is a no-op, so neither
    /// rebuilds.
    private func rebuildForOutputDeviceChange() {
      guard running.withLock({ $0 }) else { return }
      lifecycle.lock()
      let previousUid = clockDeviceUid
      lifecycle.unlock()
      guard let previousUid else { return }
      let currentUid = Self.defaultOutputDeviceUid()
      guard currentUid != previousUid else { return }
      events.emit(
        healthEvent(
          phase: .interrupted,
          code: "DefaultOutputDeviceChanged",
          message:
            "The default output device changed; rebuilding the capture chain "
            + "against the new clock device.",
          receivingAudio: false,
          statistics: assembler.statistics()
        )
      )
      _ = rebuild(restartSupervision: true)
    }

    /// Holds the process-wide App Nap assertion while this session captures.
    /// Idempotent, so repeated stops and `deinit` cannot unbalance the refcount.
    private func setActivityHold(_ held: Bool) {
      let changed = holdsActivity.withLock { current -> Bool in
        guard current != held else { return false }
        current = held
        return true
      }
      guard changed else { return }
      if held {
        CaptureActivity.shared.acquire()
      } else {
        CaptureActivity.shared.release()
      }
    }

    deinit {
      stop(discardBuffered: true)
    }

    private func enqueue(
      _ buffer: AVAudioPCMBuffer,
      timestampMicros: Int64
    ) {
      let result = workRing.enqueue(
        CaptureWorkItem(buffer: buffer, timestampMicros: timestampMicros),
        schedulePump: {
          self.workerQueue.async { [weak self] in
            self?.drainWork()
          }
        }
      )
      switch result {
      case .accepted:
        break
      case .droppedNewest, .closed:
        break
      case .failed:
        fail(
          code: "CaptureWorkerOverflow",
          message: "The bounded system-audio conversion queue overflowed."
        )
      }
    }

    private func drainWork() {
      while let work = workRing.takeNext() {
        var resetConverter = false
        if work.droppedDurationMicrosBefore > 0 {
          assembler.noteDropped(
            durationMicros: work.droppedDurationMicrosBefore,
            startTimestampMicros: work.droppedStartTimestampMicros
          )
          resetConverter = true
        }
        if assembler.prepareInput(timestampMicros: work.timestampMicros) {
          resetConverter = true
        }
        if resetConverter {
          converter?.reset()
        }
        do {
          try recorder?.write(work.buffer)
        } catch {
          fail(
            code: "RecordingWriteFailed",
            message: error.localizedDescription
          )
          return
        }
        guard
          let samples = converter?.convert(work.buffer),
          !samples.isEmpty
        else { continue }
        if !assembler.push(
          samples,
          timestampMicros: work.timestampMicros
        ) {
          fail(
            code: "CaptureMailboxOverflow",
            message: "The bounded system-audio mailbox overflowed."
          )
          return
        }
      }
    }

    private func emitTrailingDropHealth() {
      let nativeDuration = workRing.trailingDroppedDurationMicros()
      let dartFrames = mailbox.trailingDroppedFrameCount()
      guard nativeDuration > 0 || dartFrames > 0 else { return }
      events.emit(
        AudioSessionEventMessage(
          sessionId: sessionId,
          phase: .interrupted,
          code: "CaptureTrailingAudioDropped",
          message:
            "Capture ended after dropping \(nativeDuration) microseconds "
            + "before conversion and \(dartFrames) converted frames.",
          receivingAudio: false
        )
      )
    }

    /// The tap description for this capture's current target set.
    ///
    /// Built from scratch on every chain start, including a rebuild, so a
    /// selection expressed as bundle IDs is resolved against the process list
    /// as it is now and never against the objects that existed when the
    /// session was prepared — the stale-PID rebuild this used to perform.
    ///
    /// The authorized target set is resolved the same way on every macOS: the
    /// process objects that own the requested bundle IDs right now, unioned
    /// with the process IDs the host authorized. macOS 26 additionally names
    /// the bundle IDs on the description, where `processRestoreEnabled` keeps
    /// the tap pointed at those applications as they exit and relaunch — the
    /// identity list is additive to the process list, never a replacement for
    /// it, so a host's authorized processes are tapped on both OS generations.
    ///
    /// Only on macOS 26 with bundle IDs present may that union be empty: the
    /// tap is armed for the app's next launch rather than broken, which is a
    /// waiting state — `kAudioAggregateDeviceTapAutoStartKey` arms the
    /// aggregate and [superviseCapture] reports `SystemCaptureAwaitingAppAudio`
    /// until the app's first sound. Everywhere else an empty union means there
    /// is nothing to tap.
    static func tapDescription(
      bundleIds: [String],
      processIds: [Int64]
    ) throws -> CATapDescription {
      let targetBundleIds = TapTargetSelection.sanitizedBundleIds(bundleIds)
      if targetBundleIds.isEmpty, processIds.isEmpty {
        let ownProcess = translatePid(getpid())
        let excluded =
          ownProcess == AudioObjectID(kAudioObjectUnknown) ? [] : [ownProcess]
        return CATapDescription(stereoGlobalTapButExcludeProcesses: excluded)
      }
      let objects = TapTargetSelection.tapTargetObjects(
        bundleMatches: processObjects(matchingBundleIds: targetBundleIds),
        processIds: processIds,
        translate: translatePid
      )
      if !targetBundleIds.isEmpty, #available(macOS 26.0, *) {
        // A plain `CATapDescription()` leaves `mixdown` false, which taps the
        // device's channels rather than mixing the tapped processes down. The
        // three flags below are what `initStereoMixdownOfProcesses` sets, so
        // the stream shape matches the process path exactly; the bundle IDs
        // only add the identities the tap follows across app restarts.
        let description = CATapDescription()
        description.processes = objects
        description.bundleIDs = targetBundleIds
        description.isProcessRestoreEnabled = true
        description.isMixdown = true
        description.isMono = false
        description.isExclusive = false
        return description
      }
      guard !objects.isEmpty else {
        throw PigeonError(
          code: "NoTappableProcess",
          message: targetBundleIds.isEmpty
            ? "None of the selected processes currently owns a Core Audio "
              + "process object."
            : "Neither the selected bundle IDs nor the selected processes "
              + "currently own a Core Audio process object.",
          details: nil
        )
      }
      return CATapDescription(stereoMixdownOfProcesses: objects)
    }

    static func translatePid(_ pid: pid_t) -> AudioObjectID {
      var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
      )
      var mutablePid = pid
      var object = AudioObjectID(kAudioObjectUnknown)
      var size = UInt32(MemoryLayout<AudioObjectID>.size)
      let status = AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject),
        &address,
        UInt32(MemoryLayout<pid_t>.size),
        &mutablePid,
        &size,
        &object
      )
      return status == noErr ? object : AudioObjectID(kAudioObjectUnknown)
    }

    /// The described stream layout re-rated to the device's nominal sample
    /// rate, which is what the device's IO proc actually delivers. Falls back
    /// to the described format when the rate cannot be read.
    ///
    /// The device read is this method's; the re-rate itself is
    /// [CaptureFormatMath.formatAtRate], where it is unit-tested.
    static func formatAtDeviceRate(
      _ described: AVAudioFormat,
      device: AudioObjectID
    ) -> AVAudioFormat {
      guard let rate = deviceNominalSampleRate(device) else { return described }
      return CaptureFormatMath.formatAtRate(described, rate: rate)
    }

    static func deviceNominalSampleRate(_ device: AudioObjectID) -> Double? {
      guard device != AudioObjectID(kAudioObjectUnknown) else { return nil }
      var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyNominalSampleRate,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
      )
      var rate = Float64(0)
      var size = UInt32(MemoryLayout<Float64>.size)
      guard
        AudioObjectGetPropertyData(
          device,
          &address,
          0,
          nil,
          &size,
          &rate
        ) == noErr
      else { return nil }
      return rate
    }

    static func tapFormat(_ tap: AudioObjectID) -> AVAudioFormat? {
      var address = AudioObjectPropertyAddress(
        mSelector: kAudioTapPropertyFormat,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
      )
      var description = AudioStreamBasicDescription()
      var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
      guard
        AudioObjectGetPropertyData(
          tap,
          &address,
          0,
          nil,
          &size,
          &description
        ) == noErr
      else { return nil }
      return AVAudioFormat(streamDescription: &description)
    }

    /// UID prefix of every aggregate device this plugin creates.
    ///
    /// The name stays human-readable for anything that shows device names; the
    /// UID is what `cleanupOrphanedAggregateDevices()` matches on, so it must
    /// be unmistakably ours and must never change casually — a released build
    /// that used the old prefix leaks devices this one would no longer
    /// recognise.
    static let aggregateUidPrefix = "audio-flutter.tap."

    /// UIDs of aggregates a live session in this process still owns. The
    /// orphan sweeper skips them; everything else carrying the prefix was
    /// leaked by a process that died before it could unwind.
    private static let liveAggregateUids = CompatibleUnfairLock(
      initialState: Set<String>()
    )

    /// The private aggregate device that exposes the tap as an input stream.
    ///
    /// `clockDeviceUid` anchors the aggregate to real output hardware; `nil`
    /// builds the tap-only aggregate, which has no clock source of its own.
    /// `clockDeviceContributesInput` drops the clock device from the aggregate's
    /// *composition* while keeping it as the clock, for a device whose own
    /// input channels would otherwise be prepended to the tap's.
    static func aggregateDescription(
      aggregateUid: String,
      tapUid: String,
      clockDeviceUid: String?,
      clockDeviceContributesInput: Bool = false
    ) -> [String: Any] {
      var tap: [String: Any] = [kAudioSubTapUIDKey as String: tapUid]
      var description: [String: Any] = [
        kAudioAggregateDeviceNameKey as String: "audio_flutter aggregate",
        kAudioAggregateDeviceUIDKey as String: aggregateUid,
        kAudioAggregateDeviceIsPrivateKey as String: true,
        kAudioAggregateDeviceTapAutoStartKey as String: true,
      ]
      guard let clockDeviceUid else {
        description[kAudioAggregateDeviceTapListKey as String] = [tap]
        return description
      }
      // The tap and the clock device are separate timing domains, so the tap
      // sub-entry compensates for drift between them.
      tap[kAudioSubTapDriftCompensationKey as String] = true
      description[kAudioAggregateDeviceIsStackedKey as String] = false
      description[kAudioAggregateDeviceClockDeviceKey as String] =
        clockDeviceUid
      description[kAudioAggregateDeviceTapListKey as String] = [tap]
      // An aggregate presents its sub-devices' input channels *before* its
      // taps'. An output device normally has none, so the tap starts at channel
      // zero and the IO proc can read the buffer list as the tap's format
      // describes it. A device that does carry input channels breaks that: the
      // buffer list arrives as its channels followed by the tap's, the read
      // lands on the wrong stream, and every converted sample is silence while
      // the render cycles keep advancing — a capture that looks alive and
      // records nothing.
      //
      // This is not hypothetical: enabling voice processing on the microphone
      // attaches an input side to the current *output* device (four channels on
      // the built-in speakers), so turning the echo canceller on would silently
      // kill the system-audio track. Such a device stays the aggregate's clock,
      // which is all it was ever wanted for, but is kept out of the
      // composition so the tap remains the only thing in the stream.
      guard !clockDeviceContributesInput else { return description }
      description[kAudioAggregateDeviceMainSubDeviceKey as String] =
        clockDeviceUid
      description[kAudioAggregateDeviceSubDeviceListKey as String] = [
        [kAudioSubDeviceUIDKey as String: clockDeviceUid]
      ]
      return description
    }

    /// UID of the current default output device, resolved when the aggregate is
    /// created so it follows the user's live output selection.
    ///
    /// `nil` when the machine reports no default output (every output device
    /// unplugged, headless CI), in which case the caller falls back to the
    /// tap-only aggregate rather than failing the capture.
    static func defaultOutputDeviceUid() -> String? {
      var deviceAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
      )
      var device = AudioDeviceID(kAudioObjectUnknown)
      var size = UInt32(MemoryLayout<AudioDeviceID>.size)
      guard
        AudioObjectGetPropertyData(
          AudioObjectID(kAudioObjectSystemObject),
          &deviceAddress,
          0,
          nil,
          &size,
          &device
        ) == noErr,
        device != AudioDeviceID(kAudioObjectUnknown)
      else { return nil }
      return deviceUid(device)
    }

    /// Total input channels the device with `uid` presents, or 0 when it has
    /// no input side or cannot be resolved.
    ///
    /// Read fresh every time an aggregate is composed: whether the current
    /// output device has an input side is not a fixed property of the hardware.
    /// A voice-processing unit adds one to whichever device it runs on, and
    /// removes it again when it stops.
    static func inputChannelCount(uid: String) -> UInt32 {
      var translateAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
      )
      var device = AudioDeviceID(kAudioObjectUnknown)
      var deviceSize = UInt32(MemoryLayout<AudioDeviceID>.size)
      var cfUid = uid as CFString
      let translated = withUnsafeMutablePointer(to: &cfUid) { uidPointer -> OSStatus in
        AudioObjectGetPropertyData(
          AudioObjectID(kAudioObjectSystemObject),
          &translateAddress,
          UInt32(MemoryLayout<CFString>.size),
          uidPointer,
          &deviceSize,
          &device
        )
      }
      guard translated == noErr, device != AudioDeviceID(kAudioObjectUnknown) else {
        return 0
      }
      return inputChannelCount(device)
    }

    /// Total input channels `device` presents, across every input stream.
    static func inputChannelCount(_ device: AudioObjectID) -> UInt32 {
      guard device != AudioObjectID(kAudioObjectUnknown) else { return 0 }
      var streamAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyStreamConfiguration,
        mScope: kAudioObjectPropertyScopeInput,
        mElement: kAudioObjectPropertyElementMain
      )
      var size: UInt32 = 0
      guard
        AudioObjectGetPropertyDataSize(device, &streamAddress, 0, nil, &size) == noErr,
        size > 0
      else { return 0 }
      let raw = UnsafeMutableRawPointer.allocate(
        byteCount: Int(size),
        alignment: MemoryLayout<AudioBufferList>.alignment
      )
      defer { raw.deallocate() }
      guard
        AudioObjectGetPropertyData(device, &streamAddress, 0, nil, &size, raw) == noErr
      else { return 0 }
      let buffers = UnsafeMutableAudioBufferListPointer(
        raw.assumingMemoryBound(to: AudioBufferList.self)
      )
      return buffers.reduce(0) { $0 + $1.mNumberChannels }
    }

    /// Whether the HAL reports the device's IO engine as running, or nil when
    /// the property cannot be read (unknown or destroyed device).
    static func deviceIsRunning(_ device: AudioObjectID) -> Bool? {
      guard device != AudioObjectID(kAudioObjectUnknown) else { return nil }
      var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDeviceIsRunning,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
      )
      var isRunning: UInt32 = 0
      var size = UInt32(MemoryLayout<UInt32>.size)
      guard
        AudioObjectGetPropertyData(
          device,
          &address,
          0,
          nil,
          &size,
          &isRunning
        ) == noErr
      else { return nil }
      return isRunning != 0
    }

    static func deviceUid(_ device: AudioDeviceID) -> String? {
      var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDeviceUID,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
      )
      var value: Unmanaged<CFString>?
      var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
      guard
        AudioObjectGetPropertyData(
          device,
          &address,
          0,
          nil,
          &size,
          &value
        ) == noErr,
        let value
      else { return nil }
      return value.takeRetainedValue() as String
    }

    /// Destroys aggregate devices this plugin created and never unwound,
    /// returning how many were reclaimed.
    ///
    /// macOS reclaims a private aggregate when its creating process exits
    /// cleanly, but a `kill -9`, a crash, or a debugger stop can leave it in
    /// the device tree. Only devices whose UID carries
    /// `aggregateUidPrefix` are touched, and never one a live session in this
    /// process still owns, so this is safe to call at app start — which is the
    /// point of calling it: an app that never calls it accumulates leaked
    /// devices across crashes.
    static func cleanupOrphanedAggregateDevices() -> Int64 {
      let live = liveAggregateUids.withLock { $0 }
      var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
      )
      var size: UInt32 = 0
      guard
        AudioObjectGetPropertyDataSize(
          AudioObjectID(kAudioObjectSystemObject),
          &address,
          0,
          nil,
          &size
        ) == noErr,
        size > 0
      else { return 0 }
      var devices = [AudioDeviceID](
        repeating: AudioDeviceID(kAudioObjectUnknown),
        count: Int(size) / MemoryLayout<AudioDeviceID>.size
      )
      guard
        AudioObjectGetPropertyData(
          AudioObjectID(kAudioObjectSystemObject),
          &address,
          0,
          nil,
          &size,
          &devices
        ) == noErr
      else { return 0 }

      var destroyed: Int64 = 0
      for device in devices {
        guard
          let uid = deviceUid(device),
          uid.hasPrefix(aggregateUidPrefix),
          !live.contains(uid)
        else { continue }
        if AudioHardwareDestroyAggregateDevice(device) == noErr {
          destroyed += 1
        }
      }
      return destroyed
    }

    /// One process the audio server knows about.
    struct AudioProcessObject {
      let object: AudioObjectID
      let pid: pid_t
      let bundleId: String
      let isRunningOutput: Bool
    }

    /// Every Core Audio process object, with the facts a selection is made on.
    ///
    /// Both the host-visible process list and bundle-ID tap targeting read
    /// this one enumeration, so what a host was shown and what the tap
    /// resolves cannot disagree about which processes own a bundle ID.
    static func processObjects() -> [AudioProcessObject] {
      var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyProcessObjectList,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
      )
      var size: UInt32 = 0
      guard
        AudioObjectGetPropertyDataSize(
          AudioObjectID(kAudioObjectSystemObject),
          &address,
          0,
          nil,
          &size
        ) == noErr,
        size > 0
      else { return [] }
      var objects = [AudioObjectID](
        repeating: AudioObjectID(kAudioObjectUnknown),
        count: Int(size) / MemoryLayout<AudioObjectID>.size
      )
      guard
        AudioObjectGetPropertyData(
          AudioObjectID(kAudioObjectSystemObject),
          &address,
          0,
          nil,
          &size,
          &objects
        ) == noErr
      else { return [] }

      return objects.compactMap { object in
        var pidAddress = AudioObjectPropertyAddress(
          mSelector: kAudioProcessPropertyPID,
          mScope: kAudioObjectPropertyScopeGlobal,
          mElement: kAudioObjectPropertyElementMain
        )
        var pid: pid_t = 0
        var pidSize = UInt32(MemoryLayout<pid_t>.size)
        guard
          AudioObjectGetPropertyData(
            object,
            &pidAddress,
            0,
            nil,
            &pidSize,
            &pid
          ) == noErr
        else { return nil }

        var bundleAddress = AudioObjectPropertyAddress(
          mSelector: kAudioProcessPropertyBundleID,
          mScope: kAudioObjectPropertyScopeGlobal,
          mElement: kAudioObjectPropertyElementMain
        )
        var bundleReference: Unmanaged<CFString>?
        var bundleSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let bundleStatus = AudioObjectGetPropertyData(
          object,
          &bundleAddress,
          0,
          nil,
          &bundleSize,
          &bundleReference
        )
        let bundle =
          bundleStatus == noErr
          ? (bundleReference?.takeRetainedValue() as String? ?? "")
          : ""

        var runningAddress = AudioObjectPropertyAddress(
          mSelector: kAudioProcessPropertyIsRunningOutput,
          mScope: kAudioObjectPropertyScopeGlobal,
          mElement: kAudioObjectPropertyElementMain
        )
        var isRunning: UInt32 = 0
        var runningSize = UInt32(MemoryLayout<UInt32>.size)
        _ = AudioObjectGetPropertyData(
          object,
          &runningAddress,
          0,
          nil,
          &runningSize,
          &isRunning
        )
        return AudioProcessObject(
          object: object,
          pid: pid,
          bundleId: bundle,
          isRunningOutput: isRunning != 0
        )
      }
    }

    /// The process objects that belong to [bundleIds] right now.
    ///
    /// The enumeration is this method's; the namespace rule it filters with is
    /// [TapTargetSelection.processObjects], where it is unit-tested. The empty
    /// selection is answered before the enumeration, so a process-ID-only tap
    /// never pays for a process list it cannot match against.
    static func processObjects(matchingBundleIds bundleIds: [String])
      -> [AudioObjectID]
    {
      guard !bundleIds.isEmpty else { return [] }
      return TapTargetSelection.processObjects(
        matchingBundleIds: bundleIds,
        in: processObjects().map {
          TapCandidateProcess(object: $0.object, bundleId: $0.bundleId)
        }
      )
    }

    static func listProcesses() -> [AudioProcessMessage] {
      processObjects().map { process in
        AudioProcessMessage(
          processId: Int64(process.pid),
          bundleId: process.bundleId,
          isProducingAudio: process.isRunningOutput
        )
      }
    }

    /// Advisory only — this can report an optimistic `true`.
    ///
    /// The `kTCCServiceAudioCapture` grant is documented by Control Center
    /// (MIT © 2026 Samuel Alev) as enforced at delivery rather than at
    /// creation: an unauthorized tap still creates, still reports a valid
    /// format, and is simply fed silence. Tap creation therefore proves the API
    /// is reachable, not that audio will arrive. The authoritative signal is
    /// capture health — a running session whose non-zero frame count never
    /// advances, reported by the supervision task as `receivingAudio: false`
    /// ("alive but currently silent" when callbacks flow, or
    /// `SystemCaptureAwaitingAppAudio` while the armed aggregate waits for
    /// the tapped app's first sound).
    ///
    /// Gating this on observed non-silent frames needs validation against an
    /// actually-denied grant on current macOS before the behaviour changes;
    /// until then the contract is documented as advisory rather than rewritten.
    static func preflightPermission() -> Bool {
      let ownProcess = translatePid(getpid())
      let excluded =
        ownProcess == AudioObjectID(kAudioObjectUnknown) ? [] : [ownProcess]
      let description = CATapDescription(
        stereoGlobalTapButExcludeProcesses: excluded
      )
      description.name = "audio_flutter permission preflight"
      description.isPrivate = true
      var tap = AudioObjectID(kAudioObjectUnknown)
      let status = AudioHardwareCreateProcessTap(description, &tap)
      if status == noErr {
        AudioHardwareDestroyProcessTap(tap)
        return true
      }
      return false
    }
  }
#endif
