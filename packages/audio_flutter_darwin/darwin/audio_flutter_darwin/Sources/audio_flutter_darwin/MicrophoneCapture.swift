import AVFoundation
import AudioFlutterDarwinCore
import Foundation
import os

import AudioToolbox
import CoreAudio
import FlutterMacOS

final class MicrophoneCaptureSession: NativeCaptureSession {
  let sessionId: Int64
  let format: PcmFormatMessage
  let mailbox: FrameMailbox

  private let request: CaptureRequestMessage
  private let events: SessionEventsHandler
  /// Replaced outright when a configuration change leaves the old instance
  /// unable to start; see `recreateEngineLocked`.
  private var engine = AVAudioEngine()
  private let workerQueue = DispatchQueue(
    label: "audio_flutter.microphone.worker",
    qos: .userInitiated
  )
  private let workRing: CaptureWorkRing
  private let lifecycle = NSLock()
  private let running = CompatibleUnfairLock(initialState: false)
  private let failureScheduled = CompatibleUnfairLock(initialState: false)
  #if os(macOS)
    private let holdsActivity = CompatibleUnfairLock(initialState: false)
  #endif
  private let renderCycles = CompatibleUnfairLock(initialState: Int64(0))
  /// Serial queue every tap reinstall runs on, so a burst of configuration
  /// changes cannot reinstall concurrently and the posting thread is never
  /// blocked by the rebuild it triggered.
  private let reconfigureQueue = DispatchQueue(
    label: "audio_flutter.microphone.reconfigure",
    qos: .userInitiated
  )
  /// Bumped by every completed tap reinstall. The delivery watchdog reads it to
  /// tell "this chain was just rebuilt" from "this chain is dead".
  private let tapGeneration = CompatibleUnfairLock(initialState: Int64(0))
  /// How long a configuration-change burst is allowed to settle before the tap
  /// is reinstalled. Long enough to coalesce a Bluetooth connect's several
  /// notifications, short enough to stay well inside one supervision window.
  private static let reconfigureDebounceSeconds = 0.25
  /// Bumped by every configuration-change notification. Only the delayed work
  /// item whose generation still matches goes on to reinstall.
  private let reconfigureGeneration = CompatibleUnfairLock(initialState: Int64(0))
  /// Consecutive failed engine restarts. Reset by the first one that succeeds.
  private let restartAttempts = CompatibleUnfairLock(initialState: 0)
  /// How many times a restart is retried before the session is failed. A
  /// Bluetooth device can refuse to start for several hundred milliseconds
  /// while it settles, and that is a transition, not a death.
  private static let maximumRestartAttempts = 5
  private static let restartRetryDelaySeconds = 0.4
  private var assembler: CaptureFrameAssembler?
  private var converter: PersistentAudioConverter?
  private var recorder: RawAudioRecorder?
  /// Hardware format the open `recorder` file was created for. A WAV file
  /// carries one format, so a mid-capture hardware transition ends it.
  private var recorderFormat: AVAudioFormat?
  private var configurationObserver: NSObjectProtocol?
  private var watchdog: Task<Void, Never>?
  /// Why the platform echo canceller could not be enabled, when it was asked
  /// for and refused. Reported once the session reaches `running`, since a
  /// capture that records the far end is still a working capture.
  private var voiceProcessingFailure: String?

  init(
    sessionId: Int64,
    request: CaptureRequestMessage,
    events: SessionEventsHandler
  ) throws {
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
    mailbox = FrameMailbox(capacity: capacity, overflowPolicy: request.overflowPolicy)

    if let uid = request.inputDeviceId, !uid.isEmpty,
      !AudioInputDeviceSelection.apply(uid: uid, to: engine)
    {
      throw PigeonError(
        code: "InputDeviceUnavailable",
        message: "The selected audio input device is unavailable.",
        details: nil
      )
    }
    // Before the format is read: the voice-processing unit presents its own
    // format, so a read taken ahead of this describes the raw input node that
    // is about to be replaced.
    enableVoiceProcessingLocked()
    let input = engine.inputNode
    let inputFormat = input.outputFormat(forBus: 0)
    guard
      let converter = PersistentAudioConverter(
        inputFormat: inputFormat,
        sampleRate: Double(request.outputFormat.sampleRate),
        channelCount: AVAudioChannelCount(request.outputFormat.channelCount)
      )
    else {
      throw PigeonError(
        code: "ConverterUnavailable",
        message: "Could not convert microphone format \(inputFormat)",
        details: nil
      )
    }
    self.converter = converter
    assembler = CaptureFrameAssembler(
      sessionId: sessionId,
      sampleRate: Int(request.outputFormat.sampleRate),
      channelCount: Int(request.outputFormat.channelCount),
      frameDurationMicros: request.frameDurationMicros,
      mailbox: mailbox
    )
    if let path = request.rawRecordingPath {
      recorder = try RawAudioRecorder(path: path, inputFormat: inputFormat)
      recorderFormat = inputFormat
    }
  }

  func start() throws {
    lifecycle.lock()
    defer { lifecycle.unlock() }
    guard !running.withLock({ $0 }) else { return }

    let input = engine.inputNode
    // Selecting the input device during prepare (and a Bluetooth HFP
    // transition) can change the node's format after the prepare-time
    // converter was built; a stale-rate converter passes 24 kHz buffers
    // through labeled 48 kHz — the 2x "chipmunk" recording. Read the format
    // once here and rebuild the converter from that same read, so the
    // converter and the tap can never disagree.
    // Re-asserted here for the same reason the converter is rebuilt from a
    // fresh read: the node this session prepared against may have been
    // replaced since, and voice processing does not survive that.
    enableVoiceProcessingLocked()
    let liveFormat = input.outputFormat(forBus: 0)
    guard
      liveFormat.sampleRate > 0,
      liveFormat.channelCount > 0,
      let liveConverter = PersistentAudioConverter(
        inputFormat: liveFormat,
        sampleRate: Double(request.outputFormat.sampleRate),
        channelCount: AVAudioChannelCount(request.outputFormat.channelCount)
      )
    else {
      throw PigeonError(
        code: "ConverterUnavailable",
        message: "Could not convert microphone format \(liveFormat)",
        details: nil
      )
    }
    converter = liveConverter
    if closeRecorderIfFormatChangedLocked(to: liveFormat),
      let path = request.rawRecordingPath
    {
      // Unlike a mid-capture change, nothing has been written yet: reopening
      // at the live format keeps the source-native recording instead of
      // ending it before it began.
      recorder = try RawAudioRecorder(path: path, inputFormat: liveFormat)
      recorderFormat = liveFormat
    }
    installTapLocked()
    // Registered before start so the configuration change that engine.start()
    // itself provokes is delivered instead of racing the registration.
    observeConfigurationChangesLocked()
    running.withLock { $0 = true }
    engine.prepare()
    do {
      try engine.start()
    } catch {
      running.withLock { $0 = false }
      removeConfigurationObserverLocked()
      input.removeTap(onBus: 0)
      engine.stop()
      workRing.finish(discardBuffered: true)
      workerQueue.sync {}
      mailbox.finish(discardBuffered: true)
      throw error
    }
    setActivityHold(true)
    events.emit(
      AudioSessionEventMessage(
        sessionId: sessionId,
        phase: .running,
        receivingAudio: false,
        callbackCount: 0
      )
    )
    if let voiceProcessingFailure {
      events.emit(
        healthEvent(
          phase: .running,
          code: "MicrophoneVoiceProcessingUnavailable",
          message: voiceProcessingFailure,
          receivingAudio: false,
          statistics: nil
        )
      )
    }
    watchdog = Task { [weak self] in
      await self?.superviseDelivery()
    }
  }

  /// Routes the input node through the platform voice-processing unit when the
  /// request asked for it.
  private func enableVoiceProcessingLocked() {
    guard request.voiceProcessing == true else { return }
    let input = engine.inputNode
    if !input.isVoiceProcessingEnabled {
      do {
        try input.setVoiceProcessingEnabled(true)
      } catch {
        voiceProcessingFailure =
          "The platform echo canceller could not be enabled, so the "
          + "microphone still records audio played through the speakers: "
          + "\(error.localizedDescription)"
        return
      }
    }
    voiceProcessingFailure = nil
    input.isVoiceProcessingAGCEnabled = false
    if #available(macOS 14.0, iOS 17.0, *) {
      input.voiceProcessingOtherAudioDuckingConfiguration =
        AVAudioVoiceProcessingOtherAudioDuckingConfiguration(
          enableAdvancedDucking: false,
          duckingLevel: .min
        )
    }
  }

  /// Installs the capture tap for `format` on the input bus.
  ///
  /// Called with `lifecycle` held from both the initial start and every
  /// reinstall, so the callback body exists once and both paths count render
  /// cycles the same way.
  /// Installs the input tap without asserting a format.
  ///
  /// `installTap(onBus:bufferSize:format:)` raises an **NSException** when the
  /// format it is handed is not the bus's current format. That is not a Swift
  /// error, so no caller here can catch it and the process terminates. Every
  /// call site reads the node's format and then does work before installing —
  /// converter construction, `removeTap`, a synchronous worker drain — and a
  /// Bluetooth connect moves the hardware format several times across that
  /// window, so the read is routinely stale by the time it is asserted.
  ///
  /// Passing `nil` binds the tap to whatever the bus reports at install time,
  /// which is the only value that cannot be wrong. Buffers then carry their own
  /// format and [ensureConverterMatches] converts from that.
  private func installTapLocked() {
    engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: nil) {
      [weak self] buffer, time in
      guard let self, self.running.withLock({ $0 }) else { return }
      self.renderCycles.withLock { $0 += 1 }
      guard let copy = AudioBufferCopy.copy(buffer) else { return }
      let timestampMicros =
        time.isHostTimeValid
        ? MonotonicClock.microseconds(hostTime: time.hostTime)
        : MonotonicClock.microseconds()
      self.enqueue(copy, timestampMicros: timestampMicros)
    }
  }

  private static let supervisionWindowNanos: UInt64 = 2_000_000_000

  /// Supervises input-tap delivery and repairs a tap that never attached.
  ///
  /// `AVAudioEngine.start()` succeeds even when `installTap` lost a race with a
  /// hardware format transition — the HAL logs a format mismatch and refuses
  /// the tap, the engine reports no error, and the session records zero frames.
  /// A started engine therefore proves nothing; one delivered buffer does.
  ///
  /// Silence is health, never failure: a muted or very quiet microphone is
  /// legitimate, so only the total absence of buffers is fatal, and only
  /// through one of two exhaustion conditions:
  ///
  /// - A rebuild that actually happened, followed by another silent window.
  ///   The chain was repaired against a freshly read format and still delivers
  ///   nothing, so it is dead (`MicrophoneCaptureDead`).
  /// - `MicrophoneSupervisionDecider.maximumUnusableFormatWindows` consecutive
  ///   windows in which the input node never presented a usable format, so no
  ///   rebuild could even be attempted. The device is gone rather than broken
  ///   (`MicrophoneInputFormatUnavailable`).
  ///
  /// A rebuild skipped for want of a usable format therefore costs nothing
  /// from the single-rebuild budget — nothing was repaired, so nothing was
  /// proven — and a configuration-change recovery that rebuilds the tap inside
  /// a window restarts supervision outright, clearing both counters. Neither
  /// can fail a session that is merely mid-transition, which is exactly the
  /// state a Bluetooth headset moving between its call and media profiles
  /// spends several windows in.
  ///
  /// The window timing, the tap reinstall, and the events are this method's;
  /// which outcome a window's counters mean belongs to
  /// [MicrophoneSupervisionDecider], where it is unit-tested.
  private func superviseDelivery() async {
    var decider = MicrophoneSupervisionDecider(
      tapGeneration: tapGeneration.withLock { $0 }
    )
    while !Task.isCancelled, running.withLock({ $0 }) {
      try? await Task.sleep(nanoseconds: Self.supervisionWindowNanos)
      guard !Task.isCancelled, running.withLock({ $0 }) else { return }
      let statistics = assembler?.statistics()
      let window = MicrophoneSupervisionDecider.Window(
        renderCycles: renderCycles.withLock { $0 },
        nonZeroFrameCount: statistics?.nonZeroFrameCount ?? 0,
        tapGeneration: tapGeneration.withLock { $0 }
      )
      switch decider.evaluate(window) {
      case .reportAliveAndStop(let receiving):
        events.emit(
          healthEvent(
            phase: .running,
            message: receiving
              ? nil : "Microphone is active but has not produced non-zero audio",
            receivingAudio: receiving,
            statistics: statistics
          )
        )
        return
      case .keepWaiting:
        continue
      case .escalateDead:
        fail(
          code: "MicrophoneCaptureDead",
          message:
            "The microphone input tap never delivered a buffer, including "
            + "after a rebuild against the current hardware format."
        )
        return
      case .reinstallTap(let reportSilence):
        if reportSilence {
          events.emit(
            healthEvent(
              phase: .interrupted,
              code: "MicrophoneTapSilent",
              message:
                "The microphone tap has delivered no audio; rebuilding it "
                + "against the current hardware format.",
              receivingAudio: false,
              statistics: statistics
            )
          )
        }
        let outcome = reinstallTap()
        switch decider.resolveReinstall(
          outcome,
          tapGeneration: tapGeneration.withLock { $0 }
        ) {
        case .stop:
          // The rebuild already failed the session.
          return
        case .keepWaiting:
          break
        case .reportAwaitingInputFormat:
          events.emit(
            healthEvent(
              phase: .interrupted,
              code: "MicrophoneAwaitingInputFormat",
              message:
                "The microphone input device reports no usable format yet; "
                + "waiting for the hardware transition to settle.",
              receivingAudio: false,
              statistics: statistics
            )
          )
        case .escalateInputFormatUnavailable:
          fail(
            code: "MicrophoneInputFormatUnavailable",
            message:
              "The microphone input device never presented a usable format, "
              + "so the capture tap could not be rebuilt."
          )
          return
        }
      }
    }
  }

  /// One health event carrying the current statistics snapshot. Built only
  /// where health is already emitted, so widening the payload does not raise
  /// the event rate.
  private func healthEvent(
    phase: AudioSessionPhaseMessage,
    code: String? = nil,
    message: String? = nil,
    receivingAudio: Bool,
    statistics: CaptureStatistics?
  ) -> AudioSessionEventMessage {
    AudioSessionEventMessage(
      sessionId: sessionId,
      phase: phase,
      code: code,
      message: message,
      receivingAudio: receivingAudio,
      callbackCount: statistics?.callbackCount,
      peakAmplitude: statistics?.peakAmplitude,
      rms: statistics?.rms,
      nonZeroFramePercent: statistics?.nonZeroFramePercent,
      renderCycles: renderCycles.withLock { $0 },
      firstAudioAtMillis: statistics.flatMap { $0.firstAudioAtMillis }
    )
  }

  /// What a tap reinstall reports. Declared by the supervision decider, which
  /// is the only thing that has to interpret it, so the watchdog cannot drift
  /// from the reinstall it supervises.
  private typealias TapReinstallOutcome =
    MicrophoneSupervisionDecider.ReinstallOutcome

  /// Reacts to `AVAudioEngineConfigurationChange` for this engine.
  ///
  /// Runs on whichever thread AVAudioEngine posted from and returns
  /// immediately: the rebuild takes `lifecycle`, which teardown also holds.
  private func handleConfigurationChange() {
    guard running.withLock({ $0 }) else { return }
    // A Bluetooth connect posts several of these as the device is added, made
    // default, and negotiates its profile. Reinstalling on the first one
    // rebuilds against a format that is still moving, so only the last
    // notification of a burst does the work.
    let generation = reconfigureGeneration.withLock { state -> Int64 in
      state += 1
      return state
    }
    reconfigureQueue.asyncAfter(
      deadline: .now() + Self.reconfigureDebounceSeconds
    ) { [weak self] in
      guard let self, self.running.withLock({ $0 }) else { return }
      guard self.reconfigureGeneration.withLock({ $0 }) == generation else { return }
      guard case .reinstalled = self.reinstallTap() else { return }
      self.events.emit(
        self.healthEvent(
          phase: .interrupted,
          code: "MicrophoneInputFormatChanged",
          message:
            "The microphone hardware configuration changed; the input tap was "
            + "reinstalled against the new format.",
          receivingAudio: false,
          statistics: self.assembler?.statistics()
        )
      )
    }
  }

  /// Rebuilds the tap and its converter against the format the input node
  /// reports right now.
  ///
  /// A hardware transition (a Bluetooth headset moving between its 24 kHz
  /// call profile and the 48 kHz built-in input) leaves the engine stopped and
  /// the old tap detached or mismatched, so the format is re-read, the
  /// converter rebuilt for it, and the engine restarted. The format is read
  /// before anything is torn down: a node reporting no format yet is
  /// mid-transition, and the tap already installed is worth more than none.
  ///
  /// Must be called without `lifecycle` held.
  private func reinstallTap() -> TapReinstallOutcome {
    lifecycle.lock()
    guard running.withLock({ $0 }) else {
      lifecycle.unlock()
      return .skipped
    }
    // A restart that already failed means this engine is holding hardware
    // state that neither stop() nor reset() clears, so the cheap repair is
    // spent and the next attempt replaces the instance outright.
    let recreateEngine = restartAttempts.withLock { $0 > 0 }

    let probeInput = engine.inputNode
    // Probed before anything is torn down: a node reporting no usable format is
    // mid-transition, and the tap already installed is worth more than none.
    // A recreate skips the probe — an engine bound to departed hardware has
    // nothing truthful left to say about what replaced it.
    let probeFormat = probeInput.outputFormat(forBus: 0)
    if !recreateEngine,
      probeFormat.sampleRate <= 0 || probeFormat.channelCount <= 0
    {
      lifecycle.unlock()
      return .skipped
    }

    probeInput.removeTap(onBus: 0)
    // No callback can enqueue past this point, so draining the worker leaves
    // the converter, recorder, and assembler free to be swapped.
    workerQueue.sync {}
    // A configuration change leaves the engine stopped but still holding graph
    // state bound to the departed hardware. Starting it against the new device
    // in that state fails with kAudioUnitErr_FormatNotSupported (-10868), so
    // the stale state is dropped before anything is rebuilt on top of it.
    engine.stop()
    if recreateEngine {
      recreateEngineLocked()
    } else {
      engine.reset()
    }
    #if os(macOS)
      // The AUHAL's current-device property survives neither a reset nor a
      // recreate, so an explicitly selected input has to be re-asserted or the
      // engine quietly reverts to the system default mid-recording.
      if let uid = request.inputDeviceId, !uid.isEmpty {
        _ = AudioInputDeviceSelection.apply(uid: uid, to: engine)
      }
    #endif
    // A reset drops the voice-processing unit and a recreate drops the whole
    // node, so the canceller has to be re-established before the format that
    // describes it is read.
    enableVoiceProcessingLocked()
    // Re-read from the current engine — `probeInput` belongs to the instance
    // that may have just been replaced. The node settles onto the new hardware
    // as part of the reset, so this is the first read that can describe it.
    let settledFormat = engine.inputNode.outputFormat(forBus: 0)
    let inputFormat =
      settledFormat.sampleRate > 0 && settledFormat.channelCount > 0
      ? settledFormat : probeFormat
    let inputFormatIsUsable =
      inputFormat.sampleRate > 0 && inputFormat.channelCount > 0
    // This converter is only a first guess, and building it is no longer
    // fatal if it fails: the tap asserts no format, so `ensureConverterMatches`
    // rebuilds it from the first buffer that actually arrives if the hardware
    // is still moving.
    if inputFormatIsUsable,
      let converter = PersistentAudioConverter(
        inputFormat: inputFormat,
        sampleRate: Double(request.outputFormat.sampleRate),
        channelCount: AVAudioChannelCount(request.outputFormat.channelCount)
      )
    {
      self.converter = converter
    }
    // The host-time clock survives the rebuild, so the next buffer reports the
    // gap as a source restart instead of being spliced onto pre-change audio.
    assembler?.markSourceRestart()
    // The source-native recording is only closed against a format we trust —
    // closing it on a transitional read could end a file that is still fine.
    let recordingEnded =
      inputFormatIsUsable
      ? closeRecorderIfFormatChangedLocked(to: inputFormat) : false
    installTapLocked()
    var startError: Error?
    if !engine.isRunning {
      engine.prepare()
      do {
        try engine.start()
      } catch {
        startError = error
      }
    }
    tapGeneration.withLock { $0 += 1 }
    lifecycle.unlock()

    if let startError {
      // A device that is still negotiating refuses to start, and that is a
      // transition rather than a death — the same distinction the delivery
      // watchdog is built around. Retry a bounded number of times before
      // treating it as fatal, so a Bluetooth connect cannot end the session
      // just for being slow.
      let attempt = restartAttempts.withLock { state -> Int in
        state += 1
        return state
      }
      guard attempt >= Self.maximumRestartAttempts else {
        events.emit(
          healthEvent(
            phase: .interrupted,
            code: "MicrophoneEngineRestartRetrying",
            message:
              "The audio engine did not restart after a microphone "
              + "configuration change (attempt \(attempt) of "
              + "\(Self.maximumRestartAttempts), retrying with a fresh "
              + "engine): \(startError.localizedDescription)",
            receivingAudio: false,
            statistics: assembler?.statistics()
          )
        )
        reconfigureQueue.asyncAfter(
          deadline: .now() + Self.restartRetryDelaySeconds
        ) { [weak self] in
          guard let self, self.running.withLock({ $0 }) else { return }
          _ = self.reinstallTap()
        }
        return .skipped
      }
      fail(
        code: "MicrophoneEngineRestartFailed",
        message:
          "The audio engine could not restart after a microphone "
          + "configuration change, after \(attempt) attempts: "
          + "\(startError.localizedDescription)"
      )
      return .failed
    }
    restartAttempts.withLock { $0 = 0 }
    if recordingEnded {
      events.emit(
        healthEvent(
          phase: .interrupted,
          code: "MicrophoneRecordingFormatChanged",
          message:
            "Source-native recording stopped: the microphone hardware format "
            + "changed mid-capture and a single file cannot carry both.",
          receivingAudio: false,
          statistics: assembler?.statistics()
        )
      )
    }
    return .reinstalled
  }

  /// Ends source-native recording when the hardware format no longer matches
  /// the open file, returning whether it did.
  ///
  /// Writing a mismatched buffer to an `AVAudioFile` is an error, and failing
  /// the whole session over an auxiliary recording would cost the capture far
  /// more than the truncated file does.
  private func closeRecorderIfFormatChangedLocked(
    to inputFormat: AVAudioFormat
  ) -> Bool {
    guard recorder != nil, let recorderFormat else { return false }
    guard
      recorderFormat.sampleRate != inputFormat.sampleRate
        || recorderFormat.channelCount != inputFormat.channelCount
        || recorderFormat.commonFormat != inputFormat.commonFormat
        || recorderFormat.isInterleaved != inputFormat.isInterleaved
    else { return false }
    recorder?.close()
    recorder = nil
    self.recorderFormat = nil
    return true
  }

  /// Replaces the engine with a fresh instance.
  ///
  /// `stop()` and `reset()` clear the graph but not the engine's binding to the
  /// hardware it was created against. A Bluetooth connect moves the default
  /// *output* as well as the input, and an input-only `AVAudioEngine` still
  /// owns an output unit, so a stale binding refuses to start with
  /// `kAudioUnitErr_FormatNotSupported` (-10868) however long it is retried.
  /// Only a new instance rebinds both sides.
  ///
  /// The configuration observer is registered against a specific engine object,
  /// so it has to move with it or this session stops hearing about transitions
  /// entirely. It is re-registered before the caller starts the new engine, for
  /// the same reason `start()` registers before starting: the change that the
  /// start itself provokes must not race the registration.
  private func recreateEngineLocked() {
    removeConfigurationObserverLocked()
    engine.inputNode.removeTap(onBus: 0)
    engine.stop()
    engine = AVAudioEngine()
    observeConfigurationChangesLocked()
  }

  private func observeConfigurationChangesLocked() {
    guard configurationObserver == nil else { return }
    configurationObserver = NotificationCenter.default.addObserver(
      forName: NSNotification.Name.AVAudioEngineConfigurationChange,
      object: engine,
      queue: nil
    ) { [weak self] _ in
      self?.handleConfigurationChange()
    }
  }

  private func removeConfigurationObserverLocked() {
    guard let observer = configurationObserver else { return }
    NotificationCenter.default.removeObserver(observer)
    configurationObserver = nil
  }

  func stop(discardBuffered: Bool = false) {
    lifecycle.lock()
    removeConfigurationObserverLocked()
    let wasRunning = running.withLock { $0 }
    if discardBuffered {
      running.withLock { $0 = false }
    }
    if wasRunning {
      watchdog?.cancel()
      watchdog = nil
      engine.inputNode.removeTap(onBus: 0)
      engine.stop()
    }
    workRing.finish(discardBuffered: discardBuffered)
    workerQueue.sync {}
    recorder?.close()
    recorder = nil
    recorderFormat = nil
    running.withLock { $0 = false }
    setActivityHold(false)
    let failed = failureScheduled.withLock { $0 }
    mailbox.finish(discardBuffered: discardBuffered || failed)
    lifecycle.unlock()
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

  func fail(code: String, message: String) {
    guard running.withLock({ $0 }) else { return }
    let shouldSchedule = failureScheduled.withLock { scheduled in
      guard !scheduled else { return false }
      scheduled = true
      return true
    }
    guard shouldSchedule else { return }
    workRing.finish(discardBuffered: true)
    // The failure event is the one a host will debug from, so it carries the
    // full statistics snapshot — renderCycles separates a tap that never
    // attached from one whose buffers died downstream.
    events.emit(
      healthEvent(
        phase: .failed,
        code: code,
        message: message,
        receivingAudio: false,
        statistics: assembler?.statistics()
      )
    )
    // Failure can originate on `workerQueue`. Teardown waits for that queue to
    // drain, so hand it to an independent lifecycle executor.
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      self?.stop(discardBuffered: true)
    }
  }

  /// Holds the process-wide App Nap assertion while this session captures.
  /// Idempotent, so repeated stops and `deinit` cannot unbalance the refcount.
  /// No-op on iOS, which has no App Nap.
  private func setActivityHold(_ held: Bool) {
    #if os(macOS)
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
    #endif
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
        message: "The bounded microphone conversion queue overflowed."
      )
    }
  }

  private func drainWork() {
    while let work = workRing.takeNext() {
      var resetConverter = false
      if work.droppedDurationMicrosBefore > 0 {
        assembler?.noteDropped(
          durationMicros: work.droppedDurationMicrosBefore,
          startTimestampMicros: work.droppedStartTimestampMicros
        )
        resetConverter = true
      }
      if assembler?.prepareInput(timestampMicros: work.timestampMicros) == true {
        resetConverter = true
      }
      if resetConverter {
        converter?.reset()
      }
      guard ensureConverterMatches(work.buffer.format) else { return }
      // A format change under a running tap would make the source-native WAV
      // inconsistent, and writing a mismatched buffer throws. Stop feeding the
      // auxiliary recording rather than failing the capture over it; the
      // reinstall path closes the file and reports it.
      if recorderFormat == nil || recorderFormat == work.buffer.format {
        do {
          try recorder?.write(work.buffer)
        } catch {
          fail(code: "RecordingWriteFailed", message: error.localizedDescription)
          return
        }
      }
      guard
        let converted = converter?.convert(work.buffer),
        !converted.isEmpty
      else { continue }
      if assembler?.push(
        converted,
        timestampMicros: work.timestampMicros
      ) == false {
        fail(
          code: "CaptureMailboxOverflow",
          message: "The bounded microphone mailbox overflowed."
        )
        return
      }
    }
  }

  /// Keeps the converter bound to the format the buffers actually carry.
  ///
  /// The tap is installed without an asserted format, so the hardware can move
  /// under a running tap and the next buffer simply arrives in the new one. The
  /// converter built at prepare or reinstall time is a first guess; this is
  /// what keeps it true. Returns false once the session has been failed.
  ///
  /// Runs on `workerQueue` and must never take `lifecycle`: `reinstallTap`
  /// holds that lock while it drains this queue, so reaching for it here would
  /// deadlock against the rebuild it is waiting on.
  private func ensureConverterMatches(_ bufferFormat: AVAudioFormat) -> Bool {
    if let converter, converter.inputFormat == bufferFormat { return true }
    guard
      let rebuilt = PersistentAudioConverter(
        inputFormat: bufferFormat,
        sampleRate: Double(request.outputFormat.sampleRate),
        channelCount: AVAudioChannelCount(request.outputFormat.channelCount)
      )
    else {
      fail(
        code: "ConverterUnavailable",
        message: "Could not convert microphone format \(bufferFormat)"
      )
      return false
    }
    converter = rebuilt
    // The samples lost while the hardware moved belong in the stream as a
    // discontinuity, not spliced silently onto the previous format's audio.
    assembler?.markSourceRestart()
    events.emit(
      healthEvent(
        phase: .interrupted,
        code: "MicrophoneBufferFormatChanged",
        message:
          "The microphone delivered a new format (\(bufferFormat)); the "
          + "converter was rebuilt for it.",
        receivingAudio: false,
        statistics: assembler?.statistics()
      )
    )
    return true
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
}

#if os(macOS)
  enum AudioInputDeviceSelection {
    static func apply(uid: String?, to engine: AVAudioEngine) -> Bool {
      guard let uid, !uid.isEmpty, let device = deviceId(for: uid) else { return false }
      guard let unit = engine.inputNode.audioUnit else { return false }
      var value = device
      let status = AudioUnitSetProperty(
        unit,
        kAudioOutputUnitProperty_CurrentDevice,
        kAudioUnitScope_Global,
        0,
        &value,
        UInt32(MemoryLayout<AudioDeviceID>.size)
      )
      return status == noErr
    }

    static func listDevices() -> [AudioInputDeviceMessage] {
      let defaultDevice = defaultInputDevice()
      return deviceIds().compactMap { device in
        guard hasInputStreams(device),
          let uid = stringProperty(
            device,
            selector: kAudioDevicePropertyDeviceUID
          ),
          let label = stringProperty(
            device,
            selector: kAudioObjectPropertyName
          )
        else { return nil }
        return AudioInputDeviceMessage(
          id: uid,
          label: label,
          isDefault: device == defaultDevice
        )
      }
    }

    private static func deviceId(for uid: String) -> AudioDeviceID? {
      deviceIds().first {
        stringProperty($0, selector: kAudioDevicePropertyDeviceUID) == uid
      }
    }

    private static func deviceIds() -> [AudioDeviceID] {
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
        ) == noErr
      else { return [] }
      var devices = [AudioDeviceID](
        repeating: 0,
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
      else { return [] }
      return devices
    }

    private static func defaultInputDevice() -> AudioDeviceID? {
      var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
      )
      var device = AudioDeviceID(kAudioObjectUnknown)
      var size = UInt32(MemoryLayout<AudioDeviceID>.size)
      guard
        AudioObjectGetPropertyData(
          AudioObjectID(kAudioObjectSystemObject),
          &address,
          0,
          nil,
          &size,
          &device
        ) == noErr,
        device != AudioDeviceID(kAudioObjectUnknown)
      else { return nil }
      return device
    }

    private static func hasInputStreams(_ device: AudioDeviceID) -> Bool {
      var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyStreams,
        mScope: kAudioDevicePropertyScopeInput,
        mElement: kAudioObjectPropertyElementMain
      )
      var size: UInt32 = 0
      return AudioObjectGetPropertyDataSize(
        device,
        &address,
        0,
        nil,
        &size
      ) == noErr && size >= UInt32(MemoryLayout<AudioStreamID>.size)
    }

    private static func stringProperty(
      _ device: AudioDeviceID,
      selector: AudioObjectPropertySelector
    ) -> String? {
      var address = AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
      )
      var value: Unmanaged<CFString>?
      var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
      let status = AudioObjectGetPropertyData(
        device,
        &address,
        0,
        nil,
        &size,
        &value
      )
      guard status == noErr, let value else { return nil }
      return value.takeRetainedValue() as String
    }
  }
#endif

enum AudioInputDevices {
  static func list() -> [AudioInputDeviceMessage] {
    AudioInputDeviceSelection.listDevices()
  }
}
