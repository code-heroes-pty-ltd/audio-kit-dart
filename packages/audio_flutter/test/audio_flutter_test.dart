import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'package:audio_core/audio_core.dart';
import 'package:audio_flutter/audio_flutter.dart';
import 'package:audio_flutter_platform_interface/audio_flutter_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const PlatformCaptureSessionInfo captureInfo = PlatformCaptureSessionInfo(
    sessionId: 7,
    sourceId: 'microphone-7',
    trackId: 'microphone',
    clockId: 'clock-7',
    format: PlatformPcmFormat(sampleRate: 16000, channelCount: 1),
  );
  final AudioFormat format = AudioFormat(sampleRate: 16000, channels: 1);

  test(
    'capture is prepared before start and graceful stop drains native data',
    () async {
      final _FakeAudioPlatform platform = _FakeAudioPlatform(captureInfo);
      addTearDown(platform.close);
      final FlutterAudioCaptureSource source = FlutterAudioCaptureSource(
        FlutterAudioCaptureConfig(
          type: AudioCaptureType.microphone,
          format: format,
        ),
        platform: platform,
      );

      final FlutterAudioCaptureSession session = await source.prepare();
      expect(platform.startCaptureCalls, 0);

      final List<AudioFrame> frames = <AudioFrame>[];
      final List<FlutterAudioCaptureHealth> health =
          <FlutterAudioCaptureHealth>[];
      final StreamSubscription<FlutterAudioCaptureHealth> healthSubscription =
          session.health.listen(health.add);
      final StreamSubscription<AudioFrame> subscription = session.frames.listen(
        frames.add,
      );
      platform.captureBatches.add(
        PlatformAudioFrameBatch(
          frames: <PlatformAudioFrame>[
            PlatformAudioFrame(
              sessionId: 7,
              sequence: 0,
              sampleOffset: 0,
              timestamp: Duration.zero,
              samples: Float32List.fromList(<double>[0.25, -0.25]),
            ),
          ],
          endOfStream: false,
        ),
      );

      await session.start();
      await _eventually(() => frames.length == 1);
      await _eventually(
        () => health.any(
          (FlutterAudioCaptureHealth event) =>
              event.phase == FlutterAudioCaptureHealthPhase.running,
        ),
      );

      platform.framesOnGracefulStop = <PlatformAudioFrame>[
        PlatformAudioFrame(
          sessionId: 7,
          sequence: 1,
          sampleOffset: 2,
          timestamp: const Duration(microseconds: 125),
          samples: Float32List.fromList(<double>[0.5, -0.5]),
        ),
      ];
      await session.stop();

      expect(platform.startCaptureCalls, 1);
      expect(platform.stopCaptureCalls, 1);
      expect(frames.map((AudioFrame frame) => frame.sequence), <int>[0, 1]);
      expect(frames.last.samples, <double>[0.5, -0.5]);
      expect(session.status.state, AudioSessionState.finished);

      await session.abort();
      expect(session.status.state, AudioSessionState.finished);
      expect(platform.abortCaptureCalls, 0);

      await subscription.cancel();
      await healthSubscription.cancel();
      await session.close();
      expect(platform.disposeCaptureCalls, 1);
    },
  );

  test(
    'capture mailbox overflow is surfaced as discontinuity metadata',
    () async {
      final _FakeAudioPlatform platform = _FakeAudioPlatform(captureInfo);
      addTearDown(platform.close);
      final AudioSourceSession session = await FlutterAudioCaptureSource(
        FlutterAudioCaptureConfig(
          type: AudioCaptureType.microphone,
          format: format,
          overflowPolicy: AudioCaptureOverflowPolicy.dropOldest,
        ),
        platform: platform,
      ).prepare();
      final Future<AudioFrame> next = session.frames.first;
      platform.captureBatches.add(
        PlatformAudioFrameBatch(
          frames: <PlatformAudioFrame>[
            PlatformAudioFrame(
              sessionId: 7,
              sequence: 4,
              sampleOffset: 6400,
              timestamp: const Duration(milliseconds: 400),
              samples: Float32List.fromList(<double>[0.1]),
              droppedFramesBefore: 2,
            ),
          ],
          endOfStream: true,
        ),
      );

      await session.start();
      final AudioFrame frame = await next;

      expect(
        frame.discontinuity?.reason,
        AudioDiscontinuityReason.droppedFrames,
      );
      expect(frame.discontinuity?.droppedFrameCount, 2);
      expect(frame.discontinuity?.previousSequence, 1);
      await session.close();
    },
  );

  test('capture read failure aborts without awaiting its own pump', () async {
    final _FakeAudioPlatform platform = _FakeAudioPlatform(captureInfo)
      ..readFailure = StateError('read failed');
    addTearDown(platform.close);
    final AudioSourceSession session = await FlutterAudioCaptureSource(
      FlutterAudioCaptureConfig(
        type: AudioCaptureType.microphone,
        format: format,
      ),
      platform: platform,
    ).prepare();
    final Future<Object> frameError = session.frames.first
        .then<Object>((AudioFrame value) => value)
        .catchError((Object error) => error);

    await session.start();
    expect(
      await frameError.timeout(const Duration(seconds: 1)),
      isA<AudioFailure>(),
    );
    await _eventually(() => session.status.state == AudioSessionState.failed);
    expect(platform.abortCaptureCalls, 1);
    await session.close().timeout(const Duration(seconds: 1));
  });

  test('paused capture observers cannot hang resource close', () async {
    final _FakeAudioPlatform platform = _FakeAudioPlatform(captureInfo);
    addTearDown(platform.close);
    final FlutterAudioCaptureSession session = await FlutterAudioCaptureSource(
      FlutterAudioCaptureConfig(
        type: AudioCaptureType.microphone,
        format: format,
      ),
      platform: platform,
    ).prepare();
    final StreamSubscription<AudioSessionStatus> statusObserver = session
        .statuses
        .listen((_) {});
    final StreamSubscription<FlutterAudioCaptureHealth> healthObserver = session
        .health
        .listen((_) {});
    statusObserver.pause();
    healthObserver.pause();

    await session.close().timeout(const Duration(seconds: 1));

    expect(session.status.state, AudioSessionState.closed);
    await healthObserver.cancel();
    await statusObserver.cancel();
  });

  test(
    'cancellation after native prepare disposes the unreachable session',
    () async {
      final AudioCancellationController cancellation =
          AudioCancellationController();
      final _FakeAudioPlatform platform = _FakeAudioPlatform(captureInfo)
        ..onPrepareCapture = cancellation.cancel;
      addTearDown(platform.close);

      await expectLater(
        FlutterAudioCaptureSource(
          FlutterAudioCaptureConfig(
            type: AudioCaptureType.microphone,
            format: format,
          ),
          platform: platform,
        ).prepare(cancellationToken: cancellation.token),
        throwsA(isA<AudioCancelledException>()),
      );
      expect(platform.disposeCaptureCalls, 1);
    },
  );

  test('start failure is stable and aborts its native session', () async {
    final _FakeAudioPlatform platform = _FakeAudioPlatform(captureInfo)
      ..startFailure = StateError('engine unavailable');
    addTearDown(platform.close);
    final AudioSourceSession session = await FlutterAudioCaptureSource(
      FlutterAudioCaptureConfig(
        type: AudioCaptureType.microphone,
        format: format,
      ),
      platform: platform,
    ).prepare();

    await expectLater(
      session.start(),
      throwsA(
        isA<AudioFailure>()
            .having(
              (AudioFailure failure) => failure.code,
              'code',
              'platform_capture_failed',
            )
            .having(
              (AudioFailure failure) => failure.stage,
              'stage',
              AudioFailureStage.capture,
            ),
      ),
    );

    expect(session.status.state, AudioSessionState.failed);
    expect(platform.abortCaptureCalls, 1);
    await session.close();
  });

  test('cancellation after native start aborts capture', () async {
    final AudioCancellationController cancellation =
        AudioCancellationController();
    final _FakeAudioPlatform platform = _FakeAudioPlatform(captureInfo)
      ..onStartCapture = cancellation.cancel;
    addTearDown(platform.close);
    final AudioSourceSession session = await FlutterAudioCaptureSource(
      FlutterAudioCaptureConfig(
        type: AudioCaptureType.microphone,
        format: format,
      ),
      platform: platform,
    ).prepare();

    await expectLater(
      session.start(cancellationToken: cancellation.token),
      throwsA(isA<AudioCancelledException>()),
    );

    expect(session.status.state, AudioSessionState.aborted);
    expect(platform.abortCaptureCalls, 1);
    await session.close();
  });

  test(
    'graceful stop requested during native start never resurrects',
    () async {
      final Completer<void> startGate = Completer<void>();
      final _FakeAudioPlatform platform = _FakeAudioPlatform(captureInfo)
        ..startCaptureGate = startGate;
      addTearDown(platform.close);
      final AudioSourceSession session = await FlutterAudioCaptureSource(
        FlutterAudioCaptureConfig(
          type: AudioCaptureType.microphone,
          format: format,
        ),
        platform: platform,
      ).prepare();
      final List<AudioSessionState> states = <AudioSessionState>[];
      final StreamSubscription<AudioSessionStatus> statuses = session.statuses
          .listen((AudioSessionStatus status) => states.add(status.state));

      final Future<void> start = session.start();
      await _eventually(() => platform.startCaptureCalls == 1);
      final Future<void> stop = session.stop();
      startGate.complete();
      await Future.wait<void>(<Future<void>>[start, stop]);

      expect(session.status.state, AudioSessionState.finished);
      final int finishingIndex = states.indexOf(AudioSessionState.finishing);
      expect(finishingIndex, isNonNegative);
      expect(
        states.skip(finishingIndex + 1),
        isNot(contains(AudioSessionState.active)),
      );
      expect(platform.stopCaptureCalls, 1);
      await statuses.cancel();
      await session.close();
    },
  );

  test(
    'close interrupts delayed capture start and is concurrently idempotent',
    () async {
      final Completer<void> startGate = Completer<void>();
      final _FakeAudioPlatform platform = _FakeAudioPlatform(captureInfo)
        ..startCaptureGate = startGate;
      addTearDown(platform.close);
      final AudioSourceSession session = await FlutterAudioCaptureSource(
        FlutterAudioCaptureConfig(
          type: AudioCaptureType.microphone,
          format: format,
        ),
        platform: platform,
      ).prepare();

      final Future<void> start = session.start();
      await _eventually(() => platform.startCaptureCalls == 1);
      final Future<void> firstClose = session.close();
      final Future<void> secondClose = session.close();
      expect(identical(firstClose, secondClose), isTrue);
      startGate.complete();
      await Future.wait<void>(<Future<void>>[start, firstClose]);

      expect(session.status.state, AudioSessionState.closed);
      expect(platform.abortCaptureCalls, greaterThanOrEqualTo(1));
      expect(platform.disposeCaptureCalls, 1);
    },
  );

  test('capture rejects a mismatched prepared platform format', () async {
    const PlatformCaptureSessionInfo mismatched = PlatformCaptureSessionInfo(
      sessionId: 8,
      sourceId: 'microphone-8',
      trackId: 'microphone',
      clockId: 'clock-8',
      format: PlatformPcmFormat(sampleRate: 48000, channelCount: 2),
    );
    final _FakeAudioPlatform platform = _FakeAudioPlatform(mismatched);
    addTearDown(platform.close);

    await expectLater(
      FlutterAudioCaptureSource(
        FlutterAudioCaptureConfig(
          type: AudioCaptureType.microphone,
          format: format,
        ),
        platform: platform,
      ).prepare(),
      throwsA(
        isA<AudioFailure>().having(
          (AudioFailure failure) => failure.code,
          'code',
          'platform_capture_format_mismatch',
        ),
      ),
    );
    expect(platform.disposeCaptureCalls, 1);
  });

  test('live frame subscriptions reject pause instead of buffering', () async {
    final _FakeAudioPlatform platform = _FakeAudioPlatform(captureInfo);
    addTearDown(platform.close);
    final AudioSourceSession session = await FlutterAudioCaptureSource(
      FlutterAudioCaptureConfig(
        type: AudioCaptureType.microphone,
        format: format,
      ),
      platform: platform,
    ).prepare();
    final StreamSubscription<AudioFrame> subscription = session.frames.listen(
      (_) {},
    );

    expect(subscription.pause, throwsUnsupportedError);

    await subscription.cancel();
    await session.close();
  });

  test('the platform echo canceller is opt-in per capture', () async {
    final _FakeAudioPlatform platform = _FakeAudioPlatform(captureInfo);
    addTearDown(platform.close);

    final AudioSourceSession raw = await FlutterAudioCaptureSource(
      FlutterAudioCaptureConfig(
        type: AudioCaptureType.microphone,
        format: format,
      ),
      platform: platform,
    ).prepare();
    // A capture that did not ask for it must reach the platform unprocessed:
    // enabling cancellation changes the recorded signal.
    expect(platform.lastCaptureRequest?.voiceProcessing, isFalse);
    await raw.close();

    final AudioSourceSession cancelled = await FlutterAudioCaptureSource(
      FlutterAudioCaptureConfig(
        type: AudioCaptureType.microphone,
        format: format,
        voiceProcessing: true,
      ),
      platform: platform,
    ).prepare();
    expect(platform.lastCaptureRequest?.voiceProcessing, isTrue);
    await cancelled.close();
  });

  test('system capture forwards both process and bundle selections', () async {
    final _FakeAudioPlatform platform = _FakeAudioPlatform(captureInfo);
    addTearDown(platform.close);
    final AudioSourceSession session = await FlutterAudioCaptureSource(
      FlutterAudioCaptureConfig(
        type: AudioCaptureType.systemAudio,
        format: format,
        processIds: <int>[42, 43],
        bundleIds: <String>['com.example.meeting'],
      ),
      platform: platform,
    ).prepare();

    expect(platform.lastCaptureRequest?.processIds, <int>[42, 43]);
    expect(platform.lastCaptureRequest?.bundleIds, <String>[
      'com.example.meeting',
    ]);
    // Naming an application is enough on its own: a platform that taps by
    // identity needs no process to have been resolved first.
    expect(
      FlutterAudioCaptureConfig(
        type: AudioCaptureType.systemAudio,
        format: format,
        bundleIds: <String>['com.example.meeting'],
      ).processIds,
      isEmpty,
    );
    await session.close();
  });

  test('capture rejects blank or repeated bundle IDs', () {
    expect(
      () => FlutterAudioCaptureConfig(
        type: AudioCaptureType.systemAudio,
        format: format,
        bundleIds: <String>['  '],
      ),
      throwsArgumentError,
    );
    // Case is not identity here: the platform matches bundle IDs
    // case-insensitively, so two spellings would tap the same app twice.
    expect(
      () => FlutterAudioCaptureConfig(
        type: AudioCaptureType.systemAudio,
        format: format,
        bundleIds: <String>['com.example.meeting', 'com.example.Meeting'],
      ),
      throwsArgumentError,
    );
  });

  test('input devices stay provider-neutral and preserve stable IDs', () async {
    final _FakeAudioPlatform platform = _FakeAudioPlatform(captureInfo)
      ..inputDevices = const <PlatformAudioInputDevice>[
        PlatformAudioInputDevice(
          id: 'coreaudio:studio',
          label: 'Studio Microphone',
          isDefault: true,
        ),
      ];
    addTearDown(platform.close);

    final List<AudioInputDevice> devices = await FlutterAudioDevices(
      platform: platform,
    ).listInputs();

    expect(devices, hasLength(1));
    expect(devices.single.id, 'coreaudio:studio');
    expect(devices.single.label, 'Studio Microphone');
    expect(devices.single.isDefault, isTrue);
  });

  test(
    'cancellation after native playback prepare disposes the session',
    () async {
      final AudioCancellationController cancellation =
          AudioCancellationController();
      final _FakeAudioPlatform platform = _FakeAudioPlatform(captureInfo)
        ..onPreparePlayback = cancellation.cancel;
      addTearDown(platform.close);

      await expectLater(
        FlutterAudioPlaybackSink(
          platform: platform,
        ).prepare(format, cancellationToken: cancellation.token),
        throwsA(isA<AudioCancelledException>()),
      );

      expect(platform.startPlaybackCalls, 0);
      expect(platform.disposePlaybackCalls, 1);
    },
  );

  test(
    'native failure during playback start cannot resurrect the session',
    () async {
      final Completer<void> startGate = Completer<void>();
      final _FakeAudioPlatform platform = _FakeAudioPlatform(captureInfo)
        ..startPlaybackGate = startGate;
      addTearDown(platform.close);

      final Future<AudioSinkSession> preparing = FlutterAudioPlaybackSink(
        platform: platform,
      ).prepare(format);
      await _eventually(() => platform.startPlaybackCalls == 1);
      platform.events.add(
        const PlatformAudioSessionEvent(
          sessionId: 11,
          phase: PlatformAudioSessionPhase.failed,
          code: 'device_lost',
          message: 'sensitive native detail',
        ),
      );
      await _eventually(() => platform.abortPlaybackCalls == 1);
      startGate.complete();

      await expectLater(
        preparing,
        throwsA(
          isA<AudioFailure>()
              .having(
                (AudioFailure failure) => failure.code,
                'code',
                'device_lost',
              )
              .having(
                (AudioFailure failure) => failure.message,
                'message',
                'Platform playback failed.',
              ),
        ),
      );
      expect(platform.disposePlaybackCalls, 1);
    },
  );

  test('playback forwards sequential PCM and drains before disposal', () async {
    final _FakeAudioPlatform platform = _FakeAudioPlatform(captureInfo);
    addTearDown(platform.close);
    final AudioSinkSession session = await FlutterAudioPlaybackSink(
      platform: platform,
    ).prepare(format);
    final AudioFrame frame = AudioFrame.owned(
      format: format,
      samples: Float32List.fromList(<double>[0.1, 0.2, 0.3]),
      sourceId: 'tts',
      trackId: 'speech',
      clockId: 'tts-clock',
      sequence: 0,
      sampleOffset: 0,
      timestamp: Duration.zero,
    );

    await session.write(frame);
    await session.finish();
    await session.close();

    expect(platform.startPlaybackCalls, 1);
    expect(platform.playbackWrites, hasLength(1));
    expect(platform.playbackWrites.single.single.samples, frame.samples);
    expect(platform.finishPlaybackCalls, 1);
    expect(platform.disposePlaybackCalls, 1);
  });

  test('paused playback status observer cannot hang resource close', () async {
    final _FakeAudioPlatform platform = _FakeAudioPlatform(captureInfo);
    addTearDown(platform.close);
    final AudioSinkSession session = await FlutterAudioPlaybackSink(
      platform: platform,
    ).prepare(format);
    final StreamSubscription<AudioSessionStatus> statusObserver = session
        .statuses
        .listen((_) {});
    statusObserver.pause();

    await session.close().timeout(const Duration(seconds: 1));

    expect(session.status.state, AudioSessionState.closed);
    await statusObserver.cancel();
  });

  test('playback abort wins over an in-flight graceful finish', () async {
    final Completer<void> finishGate = Completer<void>();
    final _FakeAudioPlatform platform = _FakeAudioPlatform(captureInfo)
      ..finishPlaybackGate = finishGate;
    addTearDown(platform.close);
    final AudioSinkSession session = await FlutterAudioPlaybackSink(
      platform: platform,
    ).prepare(format);

    final Future<void> finish = session.finish();
    await _eventually(() => platform.finishPlaybackCalls == 1);
    await session.abort();
    finishGate.complete();
    await finish;

    expect(session.status.state, AudioSessionState.aborted);
    expect(platform.abortPlaybackCalls, 1);
    await session.close();
  });

  test('playback rejects a mismatched prepared platform format', () async {
    final _FakeAudioPlatform platform = _FakeAudioPlatform(captureInfo)
      ..playbackFormat = const PlatformPcmFormat(
        sampleRate: 48000,
        channelCount: 2,
      );
    addTearDown(platform.close);

    await expectLater(
      FlutterAudioPlaybackSink(platform: platform).prepare(format),
      throwsA(
        isA<AudioFailure>().having(
          (AudioFailure failure) => failure.code,
          'code',
          'platform_playback_format_mismatch',
        ),
      ),
    );
    expect(platform.startPlaybackCalls, 0);
    expect(platform.disposePlaybackCalls, 1);
  });
}

Future<void> _eventually(
  bool Function() predicate, {
  Duration timeout = const Duration(seconds: 1),
}) async {
  final Stopwatch stopwatch = Stopwatch()..start();
  while (!predicate()) {
    if (stopwatch.elapsed > timeout) {
      fail('Condition was not met within $timeout.');
    }
    await Future<void>.delayed(Duration.zero);
  }
}

final class _FakeAudioPlatform extends AudioFlutterPlatform {
  _FakeAudioPlatform(this.captureInfo);

  final PlatformCaptureSessionInfo captureInfo;
  final Queue<PlatformAudioFrameBatch> captureBatches =
      Queue<PlatformAudioFrameBatch>();
  final StreamController<PlatformAudioSessionEvent> events =
      StreamController<PlatformAudioSessionEvent>.broadcast();
  Completer<PlatformAudioFrameBatch>? _pendingRead;

  Object? readFailure;
  Object? startFailure;
  Completer<void>? startCaptureGate;
  Completer<void>? startPlaybackGate;
  Completer<void>? finishPlaybackGate;
  void Function()? onPrepareCapture;
  void Function()? onPreparePlayback;
  void Function()? onStartCapture;
  List<PlatformAudioFrame> framesOnGracefulStop = const <PlatformAudioFrame>[];
  List<PlatformAudioInputDevice> inputDevices =
      const <PlatformAudioInputDevice>[];
  PlatformCaptureRequest? lastCaptureRequest;
  PlatformPcmFormat? playbackFormat;
  final List<List<PlatformAudioFrame>> playbackWrites =
      <List<PlatformAudioFrame>>[];

  int startCaptureCalls = 0;
  int stopCaptureCalls = 0;
  int abortCaptureCalls = 0;
  int disposeCaptureCalls = 0;
  int startPlaybackCalls = 0;
  int finishPlaybackCalls = 0;
  int abortPlaybackCalls = 0;
  int disposePlaybackCalls = 0;

  Future<void> close() => events.close();

  @override
  Future<PlatformCaptureSessionInfo> prepareCapture(
    PlatformCaptureRequest request,
  ) async {
    onPrepareCapture?.call();
    lastCaptureRequest = request;
    return captureInfo;
  }

  @override
  Stream<PlatformAudioSessionEvent> captureEvents(int sessionId) => events
      .stream
      .where((PlatformAudioSessionEvent event) => event.sessionId == sessionId);

  @override
  Future<void> startCapture(int sessionId) async {
    startCaptureCalls += 1;
    onStartCapture?.call();
    await startCaptureGate?.future;
    final Object? failure = startFailure;
    if (failure != null) {
      throw failure;
    }
    events.add(
      PlatformAudioSessionEvent(
        sessionId: sessionId,
        phase: PlatformAudioSessionPhase.running,
        receivingAudio: true,
        callbackCount: 1,
      ),
    );
  }

  @override
  Future<PlatformAudioFrameBatch> readCaptureFrames(
    int sessionId, {
    int maxFrames = 8,
    Duration timeout = const Duration(milliseconds: 500),
  }) async {
    final Object? failure = readFailure;
    if (failure != null) {
      readFailure = null;
      throw failure;
    }
    if (captureBatches.isNotEmpty) {
      return captureBatches.removeFirst();
    }
    final Completer<PlatformAudioFrameBatch> completer =
        Completer<PlatformAudioFrameBatch>();
    _pendingRead = completer;
    return completer.future;
  }

  @override
  Future<void> stopCapture(int sessionId) async {
    stopCaptureCalls += 1;
    _completeRead(
      PlatformAudioFrameBatch(frames: framesOnGracefulStop, endOfStream: true),
    );
  }

  @override
  Future<void> abortCapture(int sessionId) async {
    abortCaptureCalls += 1;
    _completeRead(
      const PlatformAudioFrameBatch(
        frames: <PlatformAudioFrame>[],
        endOfStream: true,
      ),
    );
  }

  void _completeRead(PlatformAudioFrameBatch batch) {
    final Completer<PlatformAudioFrameBatch>? pending = _pendingRead;
    _pendingRead = null;
    if (pending == null) {
      captureBatches.add(batch);
    } else if (!pending.isCompleted) {
      pending.complete(batch);
    }
  }

  @override
  Future<void> disposeCapture(int sessionId) async {
    disposeCaptureCalls += 1;
  }

  @override
  Future<bool> isSystemAudioCaptureSupported() async => true;

  @override
  Future<List<PlatformAudioInputDevice>> listAudioInputDevices() async =>
      inputDevices;

  @override
  Future<bool> requestSystemAudioCapturePermission() async => true;

  @override
  Future<List<PlatformAudioProcess>> listAudioProcesses() async =>
      const <PlatformAudioProcess>[];

  @override
  Future<PlatformPlaybackSessionInfo> preparePlayback(
    PlatformPlaybackRequest request,
  ) async {
    onPreparePlayback?.call();
    return PlatformPlaybackSessionInfo(
      sessionId: 11,
      clockId: 'playback-11',
      format: playbackFormat ?? request.inputFormat,
    );
  }

  @override
  Stream<PlatformAudioSessionEvent> playbackEvents(int sessionId) => events
      .stream
      .where((PlatformAudioSessionEvent event) => event.sessionId == sessionId);

  @override
  Future<void> startPlayback(int sessionId) async {
    startPlaybackCalls += 1;
    await startPlaybackGate?.future;
  }

  @override
  Future<void> writePlaybackFrames(
    int sessionId,
    List<PlatformAudioFrame> frames,
  ) async {
    playbackWrites.add(List<PlatformAudioFrame>.of(frames));
  }

  @override
  Future<void> finishPlayback(int sessionId) async {
    finishPlaybackCalls += 1;
    await finishPlaybackGate?.future;
  }

  @override
  Future<void> abortPlayback(int sessionId) async {
    abortPlaybackCalls += 1;
  }

  @override
  Future<void> disposePlayback(int sessionId) async {
    disposePlaybackCalls += 1;
  }
}
