import 'dart:async';

import 'package:audio_core/audio_core.dart';
import 'package:audio_flutter_platform_interface/audio_flutter_platform_interface.dart';

import 'permissions.dart';

/// Physical Flutter capture source.
enum AudioCaptureType { microphone, systemAudio }

/// Bounded native mailbox behavior before frames enter the Dart graph.
enum AudioCaptureOverflowPolicy { dropOldest, dropNewest, failCapture }

/// Capture lifecycle and watchdog phase reported by the native transport.
enum FlutterAudioCaptureHealthPhase {
  prepared,
  starting,
  running,
  interrupted,
  stopping,
  stopped,
  failed,
}

/// Provider-neutral capture health separate from high-rate PCM delivery.
final class FlutterAudioCaptureHealth {
  const FlutterAudioCaptureHealth({
    required this.phase,
    required this.timestamp,
    this.code,
    this.message,
    this.receivingAudio,
    this.callbackCount,
    this.peakAmplitude,
    this.rms,
    this.nonZeroFramePercent,
    this.renderCycles,
    this.firstAudioAtMillis,
  });

  final FlutterAudioCaptureHealthPhase phase;
  final Duration timestamp;
  final String? code;
  final String? message;

  /// Whether the source has produced non-zero audio, when the platform knows.
  final bool? receivingAudio;

  /// Buffers the platform has delivered into its own rechunking stage.
  final int? callbackCount;

  /// Largest absolute sample seen since the session started, 0...1 nominal.
  ///
  /// Together with [rms] this separates "silent because nobody is speaking"
  /// from "silent because the wrong source is tapped": a live tap on a quiet
  /// room still reports a small non-zero peak.
  final double? peakAmplitude;

  /// Root mean square over every sample delivered since the session started.
  final double? rms;

  /// Percentage of delivered buffers that carried non-zero audio.
  final double? nonZeroFramePercent;

  /// Hardware render callbacks, including buffers dropped before conversion.
  ///
  /// Zero while [callbackCount] is also zero means the device never ran at
  /// all, which is a different fault from a running device delivering silence.
  final int? renderCycles;

  /// Milliseconds from session creation to the first non-zero buffer.
  ///
  /// Null while no audio has arrived. Two captures started together expose
  /// their start skew here; see the README's mic-delay recipe.
  final int? firstAudioAtMillis;
}

/// Prepared Flutter capture with a low-frequency health stream.
abstract interface class FlutterAudioCaptureSession
    implements AudioSourceSession {
  /// Broadcast health events, including an initial prepared event.
  Stream<FlutterAudioCaptureHealth> get health;

  /// How this track's timestamps were mapped to a monotonic session clock.
  MonotonicTrackTimingQuality get timingQuality;

  /// Mapping established by the first delivered frame, or null beforehand.
  MonotonicTrackTiming? get timing;
}

/// Immutable configuration for [FlutterAudioCaptureSource].
final class FlutterAudioCaptureConfig {
  FlutterAudioCaptureConfig({
    required this.type,
    required this.format,
    this.frameDuration = const Duration(milliseconds: 100),
    this.maxBufferedDuration = const Duration(seconds: 2),
    this.overflowPolicy = AudioCaptureOverflowPolicy.failCapture,
    List<int> processIds = const <int>[],
    List<String> bundleIds = const <String>[],
    this.inputDeviceId,
    this.rawRecordingPath,
    this.logicalSourceId,
    this.timingQuality,
    this.voiceProcessing = false,
  }) : processIds = List<int>.unmodifiable(processIds),
       bundleIds = List<String>.unmodifiable(bundleIds) {
    if (frameDuration <= Duration.zero) {
      throw ArgumentError.value(
        frameDuration,
        'frameDuration',
        'Must be positive.',
      );
    }
    if (maxBufferedDuration < frameDuration) {
      throw ArgumentError.value(
        maxBufferedDuration,
        'maxBufferedDuration',
        'Must be at least one frame.',
      );
    }
    if (format.framesForDuration(frameDuration) < 1) {
      throw ArgumentError.value(
        frameDuration,
        'frameDuration',
        'Must contain at least one sample frame.',
      );
    }
    if (processIds.any((int processId) => processId <= 0) ||
        processIds.toSet().length != processIds.length) {
      throw ArgumentError.value(
        processIds,
        'processIds',
        'Must contain unique positive process IDs.',
      );
    }
    // Bundle IDs are matched case-insensitively by the platforms that tap by
    // identity, so two spellings of one app are a duplicate, not two targets.
    final Set<String> distinctBundleIds = bundleIds
        .map((String bundleId) => bundleId.toLowerCase())
        .toSet();
    if (bundleIds.any((String bundleId) => bundleId.trim().isEmpty) ||
        distinctBundleIds.length != bundleIds.length) {
      throw ArgumentError.value(
        bundleIds,
        'bundleIds',
        'Must contain unique non-empty bundle IDs.',
      );
    }
    if (inputDeviceId != null && inputDeviceId!.trim().isEmpty) {
      throw ArgumentError.value(
        inputDeviceId,
        'inputDeviceId',
        'Must not be empty.',
      );
    }
    if (rawRecordingPath != null && rawRecordingPath!.trim().isEmpty) {
      throw ArgumentError.value(
        rawRecordingPath,
        'rawRecordingPath',
        'Must not be empty.',
      );
    }
    if (logicalSourceId != null && logicalSourceId!.trim().isEmpty) {
      throw ArgumentError.value(
        logicalSourceId,
        'logicalSourceId',
        'Must not be empty.',
      );
    }
  }

  final AudioCaptureType type;
  final AudioFormat format;
  final Duration frameDuration;
  final Duration maxBufferedDuration;
  final AudioCaptureOverflowPolicy overflowPolicy;
  final List<int> processIds;

  /// Applications to capture, named by bundle ID rather than by process.
  ///
  /// Use it alongside or instead of [processIds]: a bundle ID keeps naming the
  /// same app after its helpers respawn or the app itself restarts, which a
  /// process list captured before the session started cannot. On macOS 26 the
  /// tap targets these identities directly and survives the app's exit;
  /// earlier versions re-resolve them to processes whenever the capture chain
  /// is rebuilt. See [SystemAudioProcessSelector.expandBundleIds] for turning
  /// a user's app choice into this list.
  final List<String> bundleIds;
  final String? inputDeviceId;
  final String? rawRecordingPath;

  /// Optional normalized source ID exposed by the prepared session.
  final String? logicalSourceId;

  /// Optional override for the platform-reported timestamp quality.
  final MonotonicTrackTimingQuality? timingQuality;

  /// Whether the platform echo canceller runs on this microphone capture.
  final bool voiceProcessing;
}

/// Two-phase microphone or system-audio source backed by the federated plugin.
final class FlutterAudioCaptureSource implements AudioSource {
  FlutterAudioCaptureSource(this.config, {AudioFlutterPlatform? platform})
    : _platform = platform ?? AudioFlutterPlatform.instance;

  final FlutterAudioCaptureConfig config;
  final AudioFlutterPlatform _platform;

  @override
  Future<FlutterAudioCaptureSession> prepare({
    AudioCancellationToken? cancellationToken,
  }) async {
    cancellationToken?.throwIfCancelled();
    await _requireMicrophonePermission(cancellationToken);
    final PlatformCaptureSessionInfo info;
    try {
      info = await _platform.prepareCapture(
        PlatformCaptureRequest(
          kind: switch (config.type) {
            AudioCaptureType.microphone => PlatformCaptureKind.microphone,
            AudioCaptureType.systemAudio => PlatformCaptureKind.systemAudio,
          },
          outputFormat: PlatformPcmFormat(
            sampleRate: config.format.sampleRate,
            channelCount: config.format.channels,
          ),
          frameDuration: config.frameDuration,
          maxBufferedDuration: config.maxBufferedDuration,
          overflowPolicy: switch (config.overflowPolicy) {
            AudioCaptureOverflowPolicy.dropOldest =>
              PlatformCaptureOverflowPolicy.dropOldest,
            AudioCaptureOverflowPolicy.dropNewest =>
              PlatformCaptureOverflowPolicy.dropNewest,
            AudioCaptureOverflowPolicy.failCapture =>
              PlatformCaptureOverflowPolicy.failCapture,
          },
          processIds: config.processIds,
          bundleIds: config.bundleIds,
          inputDeviceId: config.inputDeviceId,
          rawRecordingPath: config.rawRecordingPath,
          voiceProcessing: config.voiceProcessing,
        ),
      );
    } on AudioCancelledException {
      rethrow;
    } catch (error, stackTrace) {
      Error.throwWithStackTrace(_captureFailure(error), stackTrace);
    }
    try {
      cancellationToken?.throwIfCancelled();
      final AudioFormat preparedFormat = AudioFormat(
        sampleRate: info.format.sampleRate,
        channels: info.format.channelCount,
      );
      if (preparedFormat != config.format) {
        throw AudioFailure(
          code: 'platform_capture_format_mismatch',
          stage: AudioFailureStage.capture,
          message: 'The platform prepared an unexpected capture format.',
          retryable: false,
        );
      }
      return _FlutterAudioCaptureSession(
        platform: _platform,
        info: info,
        format: preparedFormat,
        logicalSourceId: config.logicalSourceId,
        timingQuality:
            config.timingQuality ?? _captureTimingQuality(info.timingQuality),
      );
    } catch (error, stackTrace) {
      // Preparation already allocated a native session. Cancellation must not
      // strand that resource merely because the Dart wrapper was never built.
      try {
        await _platform.disposeCapture(info.sessionId);
      } catch (_) {
        // Preserve the original preparation or cancellation failure.
      }
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  /// Fails a microphone capture the platform has already refused.
  ///
  /// Without this the engine starts, the session reaches a running phase, and
  /// the app receives an endless stream of zeroes — the failure mode the
  /// health stream can only report several seconds later. A platform with no
  /// permission API (or a still-undetermined status, which the system prompt
  /// resolves at start) is not blocked here.
  Future<void> _requireMicrophonePermission(
    AudioCancellationToken? cancellationToken,
  ) async {
    if (config.type != AudioCaptureType.microphone) {
      return;
    }
    final AudioMicrophonePermissionStatus status =
        await FlutterMicrophonePermission(
          platform: _platform,
        ).status(cancellationToken: cancellationToken);
    if (!status.blocksCapture) {
      return;
    }
    throw AudioFailure(
      code: 'microphone_permission_denied',
      stage: AudioFailureStage.capture,
      message: status == AudioMicrophonePermissionStatus.restricted
          ? 'Microphone access is restricted by policy on this device.'
          : 'Microphone access was denied for this app.',
      // Only the user, in system settings, can change this answer.
      retryable: false,
    );
  }
}

final class _FlutterAudioCaptureSession implements FlutterAudioCaptureSession {
  _FlutterAudioCaptureSession({
    required this._platform,
    required this._info,
    required this.format,
    required String? logicalSourceId,
    required this.timingQuality,
  }) : _sourceId = logicalSourceId ?? _info.sourceId,
       _status = AudioSessionStatus(
         state: AudioSessionState.prepared,
         timestamp: Duration.zero,
       ) {
    _platformEvents = _platform
        .captureEvents(_info.sessionId)
        .listen(
          _onPlatformEvent,
          onError: (Object error, StackTrace stackTrace) {
            unawaited(_fail(error, stackTrace, waitForPump: true));
          },
        );
  }

  final AudioFlutterPlatform _platform;
  final PlatformCaptureSessionInfo _info;
  final String _sourceId;

  @override
  final AudioFormat format;

  @override
  final MonotonicTrackTimingQuality timingQuality;
  MonotonicTrackTiming? _timing;
  final StreamController<AudioFrame> _frames = StreamController<AudioFrame>();
  late final Stream<AudioFrame> _frameStream = AudioFrameStream(
    _frames.stream,
    pauseSupported: false,
  );
  final StreamController<AudioSessionStatus> _statuses =
      StreamController<AudioSessionStatus>.broadcast();
  final StreamController<FlutterAudioCaptureHealth> _health =
      StreamController<FlutterAudioCaptureHealth>.broadcast();
  late final StreamSubscription<PlatformAudioSessionEvent> _platformEvents;
  late AudioSessionStatus _status;
  Future<void>? _startFuture;
  Future<void>? _pump;
  Future<void>? _stopFuture;
  Future<void>? _abortFuture;
  Future<void>? _closeFuture;
  Future<void>? _failureFuture;
  AudioFailure? _pendingPlatformFailure;
  bool _gracefulStopRequested = false;
  bool _abortRequested = false;
  bool _closeRequested = false;
  bool _nativeStarted = false;
  bool _closed = false;
  final Stopwatch _clock = Stopwatch();

  @override
  AudioSourceCapabilities get capabilities => AudioSourceCapabilities.realtime;

  @override
  String get clockId => _info.clockId;

  @override
  Stream<AudioFrame> get frames => _frameStream;

  @override
  Stream<FlutterAudioCaptureHealth> get health =>
      Stream<FlutterAudioCaptureHealth>.multi((
        MultiStreamController<FlutterAudioCaptureHealth> controller,
      ) {
        controller.add(
          FlutterAudioCaptureHealth(
            phase: FlutterAudioCaptureHealthPhase.prepared,
            timestamp: _clock.elapsed,
          ),
        );
        final StreamSubscription<FlutterAudioCaptureHealth> subscription =
            _health.stream.listen(
              controller.add,
              onError: controller.addError,
              onDone: controller.close,
            );
        controller.onCancel = subscription.cancel;
      }, isBroadcast: true);

  @override
  String get sourceId => _sourceId;

  @override
  MonotonicTrackTiming? get timing => _timing;

  @override
  AudioSessionStatus get status => _status;

  @override
  Stream<AudioSessionStatus> get statuses => Stream<AudioSessionStatus>.multi((
    MultiStreamController<AudioSessionStatus> controller,
  ) {
    controller.add(_status);
    final StreamSubscription<AudioSessionStatus> subscription = _statuses.stream
        .listen(
          controller.add,
          onError: controller.addError,
          onDone: controller.close,
        );
    controller.onCancel = subscription.cancel;
  }, isBroadcast: true);

  @override
  String get trackId => _info.trackId;

  @override
  Future<void> start({AudioCancellationToken? cancellationToken}) {
    _ensureOpen();
    cancellationToken?.throwIfCancelled();
    if (_status.state == AudioSessionState.active) {
      return Future<void>.value();
    }
    if (_startFuture == null && _status.state != AudioSessionState.prepared) {
      throw StateError('Capture can only start from prepared state.');
    }
    return _startFuture ??= _start(cancellationToken);
  }

  Future<void> _start(AudioCancellationToken? cancellationToken) async {
    _clock.start();
    _setState(AudioSessionState.starting);
    try {
      await _platform.startCapture(_info.sessionId);
      _nativeStarted = true;
      final AudioFailure? platformFailure = _pendingPlatformFailure;
      if (platformFailure != null) {
        throw platformFailure;
      }
      cancellationToken?.throwIfCancelled();
      _pump = _pumpFrames();
      if (_abortRequested ||
          _closeRequested ||
          _status.state == AudioSessionState.aborted ||
          _status.state == AudioSessionState.failed ||
          _status.state == AudioSessionState.closed) {
        try {
          await _platform.abortCapture(_info.sessionId);
        } catch (_) {
          // The terminal operation owns any cleanup error.
        }
        return;
      }
      if (_gracefulStopRequested ||
          _status.state == AudioSessionState.finishing) {
        return;
      }
      _setState(AudioSessionState.active);
    } on AudioCancelledException {
      _abortRequested = true;
      try {
        await _abortNative(waitForPump: false);
      } catch (_) {
        // Cancellation remains the operation result.
      } finally {
        if (_status.state != AudioSessionState.failed &&
            _status.state != AudioSessionState.closed) {
          _setState(AudioSessionState.aborted);
        }
        if (!_frames.isClosed) {
          _requestFrameClose();
        }
      }
      rethrow;
    } catch (error, stackTrace) {
      final AudioFailure failure = _captureFailure(error);
      await _fail(failure, stackTrace, waitForPump: false);
      Error.throwWithStackTrace(failure, stackTrace);
    }
  }

  Future<void> _pumpFrames() async {
    try {
      while (!_abortRequested) {
        final PlatformAudioFrameBatch batch = await _platform.readCaptureFrames(
          _info.sessionId,
        );
        for (final PlatformAudioFrame frame in batch.frames) {
          if (_frames.isClosed) {
            return;
          }
          _establishTiming(frame);
          _frames.add(
            AudioFrame.owned(
              format: format,
              samples: frame.samples,
              sourceId: sourceId,
              trackId: trackId,
              clockId: clockId,
              sequence: frame.sequence,
              sampleOffset: frame.sampleOffset,
              timestamp: frame.timestamp,
              discontinuity: _discontinuity(frame),
            ),
          );
        }
        if (batch.endOfStream) {
          break;
        }
      }
    } catch (error, stackTrace) {
      if (!_abortRequested) {
        await _fail(error, stackTrace, waitForPump: false);
      }
    } finally {
      if (!_frames.isClosed) {
        _requestFrameClose();
      }
    }
  }

  void _establishTiming(PlatformAudioFrame frame) {
    if (_timing != null) {
      return;
    }
    if (frame.timestamp.isNegative) {
      throw AudioFailure(
        code: 'platform_capture_timing_invalid',
        stage: AudioFailureStage.capture,
        message: 'The platform returned a negative monotonic timestamp.',
        retryable: false,
      );
    }
    _timing = MonotonicTrackTiming(
      trackId: trackId,
      clockId: clockId,
      sessionClockId: timingQuality == MonotonicTrackTimingQuality.synthesized
          ? '$clockId.session.${_info.sessionId}'
          : clockId,
      sampleRate: format.sampleRate,
      startOffset: frame.timestamp,
      firstSampleOffset: frame.sampleOffset,
      quality: timingQuality,
    );
  }

  @override
  Future<void> pause({AudioCancellationToken? cancellationToken}) async {
    cancellationToken?.throwIfCancelled();
    throw UnsupportedError('Realtime platform capture cannot be paused.');
  }

  @override
  Future<void> resume({AudioCancellationToken? cancellationToken}) async {
    cancellationToken?.throwIfCancelled();
    throw UnsupportedError('Realtime platform capture cannot be resumed.');
  }

  @override
  Future<void> stop({AudioCancellationToken? cancellationToken}) {
    _ensureOpen();
    cancellationToken?.throwIfCancelled();
    if (_status.state == AudioSessionState.finished) {
      return Future<void>.value();
    }
    return _stopFuture ??= _stop(cancellationToken);
  }

  Future<void> _stop(AudioCancellationToken? cancellationToken) async {
    if (_status.state == AudioSessionState.prepared) {
      _gracefulStopRequested = true;
      _setState(AudioSessionState.finishing);
      if (!_frames.isClosed) {
        _requestFrameClose();
      }
      _setState(AudioSessionState.finished);
      return;
    }
    if (_status.state != AudioSessionState.active &&
        _status.state != AudioSessionState.starting &&
        _status.state != AudioSessionState.finishing) {
      return;
    }
    _gracefulStopRequested = true;
    _setState(AudioSessionState.finishing);
    try {
      await _startFuture;
      if (_abortRequested ||
          _status.state == AudioSessionState.aborted ||
          _status.state == AudioSessionState.failed ||
          _status.state == AudioSessionState.closed) {
        return;
      }
      if (_nativeStarted) {
        await _platform.stopCapture(_info.sessionId);
      }
      await _pump;
      cancellationToken?.throwIfCancelled();
      if (!_isTerminal(_status.state)) {
        _setState(AudioSessionState.finished);
      }
    } on AudioCancelledException {
      await abort();
      rethrow;
    } catch (error, stackTrace) {
      final AudioFailure failure = _captureFailure(
        error,
        code: 'platform_capture_stop_failed',
        message: 'Platform audio capture could not stop cleanly.',
      );
      await _fail(failure, stackTrace, waitForPump: false);
      Error.throwWithStackTrace(failure, stackTrace);
    }
  }

  @override
  Future<void> abort({AudioFailure? failure}) {
    if (_closed ||
        _status.state == AudioSessionState.finished ||
        _status.state == AudioSessionState.aborted ||
        _status.state == AudioSessionState.failed ||
        _status.state == AudioSessionState.closed) {
      return Future<void>.value();
    }
    return _abortFuture ??= _abort(failure);
  }

  Future<void> _abort(AudioFailure? failure) async {
    _abortRequested = true;
    _setState(
      failure == null ? AudioSessionState.aborted : AudioSessionState.failed,
      failure: failure,
    );
    try {
      await _abortNative(waitForPump: true);
    } catch (error, stackTrace) {
      Error.throwWithStackTrace(
        _captureFailure(
          error,
          code: 'platform_capture_abort_failed',
          message: 'Platform audio capture could not be aborted.',
        ),
        stackTrace,
      );
    } finally {
      if (!_frames.isClosed) {
        _requestFrameClose();
      }
    }
  }

  Future<void> _fail(
    Object error,
    StackTrace stackTrace, {
    required bool waitForPump,
  }) => _failureFuture ??= _failOnce(
    _captureFailure(error),
    stackTrace,
    waitForPump: waitForPump,
  );

  Future<void> _failOnce(
    AudioFailure failure,
    StackTrace stackTrace, {
    required bool waitForPump,
  }) async {
    if (!_frames.isClosed && _frames.hasListener) {
      _frames.addError(failure, stackTrace);
    }
    if (_closed || _isTerminal(_status.state)) {
      return;
    }
    _pendingPlatformFailure = failure;
    _abortRequested = true;
    _setState(AudioSessionState.failed, failure: failure);
    try {
      await _abortNative(waitForPump: waitForPump);
    } catch (_) {
      // Preserve the first stable capture failure.
    } finally {
      if (!_frames.isClosed && !waitForPump) {
        _requestFrameClose();
      }
    }
  }

  Future<void> _abortNative({required bool waitForPump}) async {
    _abortRequested = true;
    await _platform.abortCapture(_info.sessionId);
    if (waitForPump) {
      await _pump;
    }
  }

  void _onPlatformEvent(PlatformAudioSessionEvent event) {
    if (!_health.isClosed) {
      _health.add(
        FlutterAudioCaptureHealth(
          phase: switch (event.phase) {
            PlatformAudioSessionPhase.prepared =>
              FlutterAudioCaptureHealthPhase.prepared,
            PlatformAudioSessionPhase.starting =>
              FlutterAudioCaptureHealthPhase.starting,
            PlatformAudioSessionPhase.running =>
              FlutterAudioCaptureHealthPhase.running,
            PlatformAudioSessionPhase.interrupted =>
              FlutterAudioCaptureHealthPhase.interrupted,
            PlatformAudioSessionPhase.stopping =>
              FlutterAudioCaptureHealthPhase.stopping,
            PlatformAudioSessionPhase.stopped =>
              FlutterAudioCaptureHealthPhase.stopped,
            PlatformAudioSessionPhase.failed =>
              FlutterAudioCaptureHealthPhase.failed,
          },
          timestamp: _clock.elapsed,
          code: event.code,
          message: event.message,
          receivingAudio: event.receivingAudio,
          callbackCount: event.callbackCount,
          peakAmplitude: event.peakAmplitude,
          rms: event.rms,
          nonZeroFramePercent: event.nonZeroFramePercent,
          renderCycles: event.renderCycles,
          firstAudioAtMillis: event.firstAudioAtMillis,
        ),
      );
    }
    if (event.phase != PlatformAudioSessionPhase.failed) {
      return;
    }
    final AudioFailure failure = AudioFailure(
      code: event.code ?? 'platform_capture_failed',
      stage: AudioFailureStage.capture,
      message: event.message ?? 'Platform audio capture failed.',
      retryable: true,
    );
    _pendingPlatformFailure = failure;
    unawaited(_fail(failure, StackTrace.current, waitForPump: true));
  }

  @override
  Future<void> close() => _closeFuture ??= _close();

  Future<void> _close() async {
    _closeRequested = true;
    Object? firstError;
    StackTrace? firstStackTrace;
    if (!_isTerminal(_status.state)) {
      try {
        await abort();
      } catch (error, stackTrace) {
        firstError = error;
        firstStackTrace = stackTrace;
      }
    }
    // Operational failures are reported by their initiating calls/status
    // stream and must not be replayed from close().
    for (final Future<void>? operation in <Future<void>?>[
      _startFuture,
      _stopFuture,
      _failureFuture,
      _pump,
    ]) {
      try {
        await operation;
      } catch (_) {
        // Cleanup continues independently.
      }
    }
    try {
      await _abortFuture;
    } catch (error, stackTrace) {
      firstError ??= error;
      firstStackTrace ??= stackTrace;
    }
    try {
      await _platform.disposeCapture(_info.sessionId);
    } catch (error, stackTrace) {
      firstError ??= _captureFailure(
        error,
        code: 'platform_capture_dispose_failed',
        message: 'Platform audio capture could not be released.',
      );
      firstStackTrace ??= stackTrace;
    }
    try {
      await _platformEvents.cancel();
    } catch (error, stackTrace) {
      firstError ??= error;
      firstStackTrace ??= stackTrace;
    }
    try {
      if (!_frames.isClosed) {
        _requestFrameClose();
      }
    } catch (error, stackTrace) {
      firstError ??= error;
      firstStackTrace ??= stackTrace;
    }
    _closed = true;
    _setState(AudioSessionState.closed);
    if (!_statuses.isClosed) {
      unawaited(_statuses.close());
    }
    if (!_health.isClosed) {
      unawaited(_health.close());
    }
    _clock.stop();
    if (firstError != null) {
      final AudioFailure failure = _captureFailure(
        firstError,
        code: 'platform_capture_cleanup_failed',
        message: 'Platform audio capture could not be cleaned up.',
      );
      Error.throwWithStackTrace(failure, firstStackTrace ?? StackTrace.current);
    }
  }

  void _setState(AudioSessionState state, {AudioFailure? failure}) {
    _status = AudioSessionStatus(
      state: state,
      timestamp: _clock.elapsed,
      failure: failure,
    );
    if (!_statuses.isClosed) {
      _statuses.add(_status);
    }
  }

  void _ensureOpen() {
    if (_closed || _closeRequested) {
      throw StateError('Capture session is closed.');
    }
  }

  void _requestFrameClose() {
    if (!_frames.isClosed) {
      unawaited(_frames.close());
    }
  }

  static bool _isTerminal(AudioSessionState state) =>
      state == AudioSessionState.finished ||
      state == AudioSessionState.aborted ||
      state == AudioSessionState.failed ||
      state == AudioSessionState.closed;
}

/// Continuity metadata for one platform frame, or null when it continues the
/// previous one.
///
/// A frame can carry a reason without a frame count: a capture chain rebuilt
/// against a new output device loses no queued frame, but the audio after the
/// gap is not a continuation of the audio before it.
AudioDiscontinuity? _discontinuity(PlatformAudioFrame frame) {
  final PlatformAudioDiscontinuityReason? reason = frame.discontinuityReason;
  if (frame.droppedFramesBefore == 0 && reason == null) {
    return null;
  }
  final int previousSequence = frame.sequence - frame.droppedFramesBefore - 1;
  return AudioDiscontinuity(
    reason: switch (reason) {
      null || PlatformAudioDiscontinuityReason.droppedFrames =>
        AudioDiscontinuityReason.droppedFrames,
      PlatformAudioDiscontinuityReason.sourceRestart =>
        AudioDiscontinuityReason.sourceRestart,
      PlatformAudioDiscontinuityReason.clockReset =>
        AudioDiscontinuityReason.clockReset,
      PlatformAudioDiscontinuityReason.formatChange =>
        AudioDiscontinuityReason.formatChange,
      PlatformAudioDiscontinuityReason.unknown =>
        AudioDiscontinuityReason.unknown,
    },
    droppedFrameCount: frame.droppedFramesBefore,
    previousSequence: previousSequence < 0 ? null : previousSequence,
    description: switch (reason) {
      PlatformAudioDiscontinuityReason.sourceRestart =>
        'Native capture chain restarted',
      _ => 'Native capture mailbox overflow',
    },
  );
}

MonotonicTrackTimingQuality _captureTimingQuality(
  PlatformCaptureTimingQuality quality,
) => switch (quality) {
  PlatformCaptureTimingQuality.nativeMapped =>
    MonotonicTrackTimingQuality.nativeMapped,
  PlatformCaptureTimingQuality.synchronized =>
    MonotonicTrackTimingQuality.synchronized,
  PlatformCaptureTimingQuality.synthesized =>
    MonotonicTrackTimingQuality.synthesized,
};

AudioFailure _captureFailure(
  Object error, {
  String code = 'platform_capture_failed',
  String message = 'Platform audio capture failed.',
  bool retryable = true,
}) => error is AudioFailure
    ? error
    : AudioFailure(
        code: code,
        stage: AudioFailureStage.capture,
        message: message,
        retryable: retryable,
        safeCause: error.runtimeType.toString(),
      );
