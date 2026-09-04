import 'dart:typed_data';

import 'package:audio_flutter_platform_interface/audio_flutter_platform_interface.dart';
import 'package:audio_flutter_windows/audio_flutter_windows.dart';
import 'package:audio_flutter_windows/src/channel.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeWindowsChannel channel;
  late WindowsAudioFlutterPlatform platform;

  setUp(() {
    channel = FakeWindowsChannel()..install();
    platform = WindowsAudioFlutterPlatform(
      methodChannel: const MethodChannel(kWindowsMethodChannel),
      eventChannel: const EventChannel(kWindowsEventChannel),
    );
  });

  tearDown(() => channel.remove());

  group('capture lifecycle', () {
    test('prepareCapture forwards the request and decodes the reply', () async {
      channel.replies[kMethodPrepareCapture] = <Object?, Object?>{
        'sessionId': 11,
        'sourceId': 'render:{0.0.0}',
        'trackId': 'them',
        'clockId': 'wasapi',
        'sampleRate': 16000,
        'channelCount': 1,
      };

      final PlatformCaptureSessionInfo info = await platform.prepareCapture(
        const PlatformCaptureRequest(
          kind: PlatformCaptureKind.systemAudio,
          outputFormat: PlatformPcmFormat(sampleRate: 16000, channelCount: 1),
          overflowPolicy: PlatformCaptureOverflowPolicy.dropOldest,
          inputDeviceId: '{0.0.0.render}',
        ),
      );

      expect(info.sessionId, 11);
      expect(channel.calls.single.method, kMethodPrepareCapture);
      expect(channel.calls.single.arguments, <String, Object?>{
        'kind': 'systemAudio',
        'sampleRate': 16000,
        'channelCount': 1,
        'frameDurationMicros': 100000,
        'maxBufferedDurationMicros': 2000000,
        'overflowPolicy': 'dropOldest',
        'processIds': <int>[],
        'inputDeviceId': '{0.0.0.render}',
        'voiceProcessing': false,
      });
    });

    test(
      'rejects per-process capture on an unsupported OS instead of widening',
      () async {
        await expectLater(
          platform.prepareCapture(
            const PlatformCaptureRequest(
              kind: PlatformCaptureKind.systemAudio,
              outputFormat: PlatformPcmFormat(
                sampleRate: 16000,
                channelCount: 1,
              ),
              processIds: <int>[4242],
            ),
          ),
          throwsA(
            isA<UnsupportedError>().having(
              (UnsupportedError error) => error.message,
              'message',
              contains('UnsupportedProcessCapture'),
            ),
          ),
        );
        expect(
          channel.calls.single.method,
          kMethodIsProcessAudioCaptureSupported,
        );
      },
    );

    test('forwards every selected process to native loopback', () async {
      channel.replies[kMethodIsProcessAudioCaptureSupported] = true;
      channel.replies[kMethodPrepareCapture] = <Object?, Object?>{
        'sessionId': 12,
        'sourceId': 'process:4242,4343',
        'trackId': 'them',
        'clockId': 'windows.qpc',
        'timingQuality': 'nativeMapped',
        'sampleRate': 16000,
        'channelCount': 1,
      };

      final PlatformCaptureSessionInfo info = await platform.prepareCapture(
        const PlatformCaptureRequest(
          kind: PlatformCaptureKind.systemAudio,
          outputFormat: PlatformPcmFormat(sampleRate: 16000, channelCount: 1),
          processIds: <int>[4242, 4343],
        ),
      );

      expect(info.sourceId, 'process:4242,4343');
      expect(info.timingQuality, PlatformCaptureTimingQuality.nativeMapped);
      expect(channel.calls.last.method, kMethodPrepareCapture);
      expect(
        channel.calls.last.arguments,
        containsPair('processIds', <int>[4242, 4343]),
      );
      expect(channel.calls.last.arguments, containsPair('inputDeviceId', null));
    });

    test(
      'rejects source-side recording instead of silently dropping it',
      () async {
        await expectLater(
          platform.prepareCapture(
            const PlatformCaptureRequest(
              kind: PlatformCaptureKind.microphone,
              outputFormat: PlatformPcmFormat(
                sampleRate: 16000,
                channelCount: 1,
              ),
              rawRecordingPath: r'C:\tmp\mic.wav',
            ),
          ),
          throwsA(
            isA<UnsupportedError>().having(
              (UnsupportedError error) => error.message,
              'message',
              contains('UnsupportedRawRecording'),
            ),
          ),
        );
        expect(channel.calls, isEmpty);
      },
    );

    test('start, stop, abort, and dispose address the session', () async {
      await platform.startCapture(3);
      await platform.stopCapture(3);
      await platform.abortCapture(3);
      await platform.disposeCapture(3);

      expect(channel.calls.map((FakeCall call) => call.method), <String>[
        kMethodStartCapture,
        kMethodStopCapture,
        kMethodAbortCapture,
        kMethodDisposeCapture,
      ]);
      for (final FakeCall call in channel.calls) {
        expect(call.arguments, <String, Object?>{'sessionId': 3});
      }
    });

    test(
      'readCaptureFrames passes the pull bounds and decodes frames',
      () async {
        channel.replies[kMethodReadCaptureFrames] = <Object?, Object?>{
          'endOfStream': false,
          'frames': <Object?>[
            <Object?, Object?>{
              'sessionId': 4,
              'sequence': 9,
              'sampleOffset': 14400,
              'timestampMicros': 900000,
              'droppedFramesBefore': 1,
              'samples': encodeFloat32Le(
                Float32List.fromList(<double>[0.25, -0.25]),
              ),
            },
          ],
        };

        final PlatformAudioFrameBatch batch = await platform.readCaptureFrames(
          4,
          maxFrames: 3,
          timeout: const Duration(milliseconds: 250),
        );

        expect(channel.calls.single.arguments, <String, Object?>{
          'sessionId': 4,
          'maxFrames': 3,
          'timeoutMillis': 250,
        });
        expect(batch.frames.single.samples, <double>[0.25, -0.25]);
        expect(batch.frames.single.droppedFramesBefore, 1);
      },
    );

    test('surfaces a native failure as a PlatformException', () async {
      channel.errors[kMethodStartCapture] = PlatformException(
        code: 'CaptureFailed',
        message: 'AUDCLNT_E_DEVICE_IN_USE',
      );

      await expectLater(
        platform.startCapture(1),
        throwsA(
          isA<PlatformException>().having(
            (PlatformException error) => error.code,
            'code',
            'CaptureFailed',
          ),
        ),
      );
    });

    test('throws when a payload-bearing reply is empty', () async {
      channel.replies[kMethodPrepareCapture] = null;

      await expectLater(
        platform.prepareCapture(
          const PlatformCaptureRequest(
            kind: PlatformCaptureKind.microphone,
            outputFormat: PlatformPcmFormat(sampleRate: 16000, channelCount: 1),
          ),
        ),
        throwsA(isA<StateError>()),
      );
    });
  });

  group('capability and enumeration', () {
    test(
      'reports loopback support and the always-granted permission',
      () async {
        channel.replies[kMethodIsSystemAudioCaptureSupported] = true;
        channel.replies[kMethodRequestSystemAudioCapturePermission] = true;

        expect(await platform.isSystemAudioCaptureSupported(), isTrue);
        expect(await platform.requestSystemAudioCapturePermission(), isTrue);
      },
    );

    test('treats a null capability reply as unsupported', () async {
      channel.replies[kMethodIsSystemAudioCaptureSupported] = null;
      channel.replies[kMethodIsProcessAudioCaptureSupported] = null;

      expect(await platform.isSystemAudioCaptureSupported(), isFalse);
      expect(await platform.isProcessAudioCaptureSupported(), isFalse);
    });

    test('decodes input devices and render sources', () async {
      channel.replies[kMethodListAudioInputDevices] = <Object?>[
        <Object?, Object?>{
          'id': '{0.0.1.mic}',
          'label': 'Headset Microphone',
          'isDefault': true,
        },
      ];
      channel.replies[kMethodListSystemAudioSources] = <Object?>[
        <Object?, Object?>{
          'id': '{0.0.0.speakers}',
          'label': 'Speakers',
          'isDefault': true,
        },
      ];

      final List<PlatformAudioInputDevice> inputs = await platform
          .listAudioInputDevices();
      final List<PlatformAudioInputDevice> sources = await platform
          .listSystemAudioSources();

      expect(inputs.single.label, 'Headset Microphone');
      expect(sources.single.id, '{0.0.0.speakers}');
    });

    test('listAudioProcesses is empty on Windows', () async {
      channel.replies[kMethodListAudioProcesses] = <Object?>[];

      expect(await platform.listAudioProcesses(), isEmpty);
    });

    test(
      'normalizes WASAPI sources and exposes unsupported process capture',
      () async {
        channel.replies[kMethodIsSystemAudioCaptureSupported] = true;
        channel.replies[kMethodListAudioInputDevices] = <Object?>[
          <Object?, Object?>{
            'id': '{mic}',
            'label': 'Microphone',
            'isDefault': true,
          },
        ];
        channel.replies[kMethodListSystemAudioSources] = <Object?>[
          <Object?, Object?>{
            'id': '{speakers}',
            'label': 'Speakers',
            'isDefault': true,
          },
        ];

        final PlatformCaptureBackendInfo backend = await platform
            .captureBackendInfo();
        final List<PlatformCaptureSourceInfo> sources = await platform
            .listCaptureSources();

        expect(backend.backendId, 'audio_flutter.windows.wasapi');
        expect(
          backend.capabilities,
          contains(PlatformCaptureCapability.systemMix),
        );
        expect(
          sources
              .singleWhere(
                (PlatformCaptureSourceInfo source) =>
                    source.kind == PlatformCaptureSourceKind.microphone,
              )
              .isDefault,
          isTrue,
        );
        expect(
          sources
              .singleWhere(
                (PlatformCaptureSourceInfo source) =>
                    source.kind == PlatformCaptureSourceKind.systemMix,
              )
              .isDefault,
          isTrue,
        );
        expect(
          sources
              .singleWhere(
                (PlatformCaptureSourceInfo source) =>
                    source.kind == PlatformCaptureSourceKind.systemMix,
              )
              .timingQuality,
          PlatformCaptureTimingQuality.nativeMapped,
        );
        final PlatformCaptureSourceInfo application = sources.singleWhere(
          (PlatformCaptureSourceInfo source) =>
              source.kind == PlatformCaptureSourceKind.application,
        );
        expect(
          application.availability,
          PlatformCaptureSourceAvailability.unavailable,
        );
        expect(
          application.availabilityCode,
          'windows_process_loopback_os_unsupported',
        );
      },
    );

    test('normalizes active application and browser render sessions', () async {
      channel.replies[kMethodIsSystemAudioCaptureSupported] = true;
      channel.replies[kMethodIsProcessAudioCaptureSupported] = true;
      channel.replies[kMethodListAudioInputDevices] = <Object?>[];
      channel.replies[kMethodListSystemAudioSources] = <Object?>[];
      channel.replies[kMethodListAudioProcesses] = <Object?>[
        <Object?, Object?>{
          'processId': 4242,
          'bundleId': 'chrome.exe',
          'isProducingAudio': true,
        },
        <Object?, Object?>{
          'processId': 4343,
          'bundleId': 'Zoom.exe',
          'isProducingAudio': true,
        },
      ];

      final PlatformCaptureBackendInfo backend = await platform
          .captureBackendInfo();
      final List<PlatformCaptureSourceInfo> sources = await platform
          .listCaptureSources();

      expect(
        backend.capabilities,
        containsAll(<PlatformCaptureCapability>[
          PlatformCaptureCapability.processFiltering,
          PlatformCaptureCapability.applicationFiltering,
          PlatformCaptureCapability.nativeMonotonicClock,
        ]),
      );
      final PlatformCaptureSourceInfo browser = sources.singleWhere(
        (PlatformCaptureSourceInfo source) =>
            source.kind == PlatformCaptureSourceKind.browser,
      );
      final PlatformCaptureSourceInfo application = sources.singleWhere(
        (PlatformCaptureSourceInfo source) =>
            source.kind == PlatformCaptureSourceKind.application,
      );
      expect(browser.processIds, <int>[4242]);
      expect(browser.applicationId, 'chrome.exe');
      expect(application.processIds, <int>[4343]);
      expect(
        application.availability,
        PlatformCaptureSourceAvailability.available,
      );
    });
  });

  group('playback', () {
    test('prepare and start map onto the render client', () async {
      channel.replies[kMethodPreparePlayback] = <Object?, Object?>{
        'sessionId': 21,
        'clockId': 'wasapi-render',
        'sampleRate': 48000,
        'channelCount': 2,
      };

      final PlatformPlaybackSessionInfo info = await platform.preparePlayback(
        const PlatformPlaybackRequest(
          inputFormat: PlatformPcmFormat(sampleRate: 48000, channelCount: 2),
        ),
      );
      await platform.startPlayback(info.sessionId);

      expect(info.sessionId, 21);
      expect(channel.calls.first.arguments, <String, Object?>{
        'sampleRate': 48000,
        'channelCount': 2,
        'maxBufferedDurationMicros': 2000000,
      });
      expect(channel.calls.last.method, kMethodStartPlayback);
    });

    test('writePlaybackFrames sends little-endian float32 payloads', () async {
      await platform.writePlaybackFrames(21, <PlatformAudioFrame>[
        PlatformAudioFrame(
          sessionId: 21,
          sequence: 0,
          sampleOffset: 0,
          timestamp: Duration.zero,
          samples: Float32List.fromList(<double>[1, -1]),
        ),
      ]);

      final Map<Object?, Object?> arguments =
          channel.calls.single.arguments! as Map<Object?, Object?>;
      final List<Object?> frames = arguments['frames']! as List<Object?>;
      final Map<Object?, Object?> frame =
          frames.single as Map<Object?, Object?>;
      expect(arguments['sessionId'], 21);
      expect(decodeFloat32Le(frame['samples']! as Uint8List), <double>[1, -1]);
    });

    test('finish, abort, and dispose address the session', () async {
      await platform.finishPlayback(8);
      await platform.abortPlayback(8);
      await platform.disposePlayback(8);

      expect(channel.calls.map((FakeCall call) => call.method), <String>[
        kMethodFinishPlayback,
        kMethodAbortPlayback,
        kMethodDisposePlayback,
      ]);
    });
  });

  group('session events', () {
    test('demultiplexes capture events by session', () async {
      final Future<List<PlatformAudioSessionEvent>> collected = platform
          .captureEvents(2)
          .take(2)
          .toList();

      channel
        ..emitEvent(<Object?, Object?>{'sessionId': 1, 'phase': 'running'})
        ..emitEvent(<Object?, Object?>{'sessionId': 2, 'phase': 'starting'})
        ..emitEvent(<Object?, Object?>{
          'sessionId': 2,
          'phase': 'failed',
          'code': 'CaptureStalled',
          'receivingAudio': false,
        });

      final List<PlatformAudioSessionEvent> events = await collected;
      expect(
        events.map((PlatformAudioSessionEvent event) => event.phase),
        <PlatformAudioSessionPhase>[
          PlatformAudioSessionPhase.starting,
          PlatformAudioSessionPhase.failed,
        ],
      );
      expect(events.last.code, 'CaptureStalled');
      expect(events.last.receivingAudio, isFalse);
    });

    test('playback events share the demultiplexed stream', () async {
      final Future<PlatformAudioSessionEvent> first = platform
          .playbackEvents(5)
          .first;

      channel
        ..emitEvent(<Object?, Object?>{'sessionId': 4, 'phase': 'running'})
        ..emitEvent(<Object?, Object?>{'sessionId': 5, 'phase': 'stopped'});

      expect((await first).phase, PlatformAudioSessionPhase.stopped);
    });
  });

  test('registerWith installs the Windows implementation', () {
    AudioFlutterWindows.registerWith();

    expect(AudioFlutterPlatform.instance, isA<WindowsAudioFlutterPlatform>());
  });
}
