import 'dart:typed_data';

import 'package:audio_flutter_platform_interface/audio_flutter_platform_interface.dart';
import 'package:audio_flutter_windows/src/codec.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('float32 payloads', () {
    test('decodes aligned little-endian bytes without copying', () {
      final Float32List source = Float32List.fromList(<double>[
        0,
        0.5,
        -0.5,
        1,
      ]);
      final Uint8List bytes = encodeFloat32Le(source);

      final Float32List decoded = decodeFloat32Le(bytes);

      expect(decoded, <double>[0, 0.5, -0.5, 1]);
      // The aligned path views the incoming buffer, so a write is observable.
      decoded[0] = 0.25;
      expect(source[0], 0.25);
    });

    test('decodes an unaligned view by copying', () {
      final Float32List source = Float32List.fromList(<double>[1, -1]);
      final Uint8List aligned = encodeFloat32Le(source);
      // Place the payload at a byte offset that is not a multiple of 4.
      final Uint8List padded = Uint8List(aligned.lengthInBytes + 2)
        ..setRange(2, 2 + aligned.lengthInBytes, aligned);
      final Uint8List unaligned = Uint8List.view(
        padded.buffer,
        2,
        aligned.lengthInBytes,
      );

      final Float32List decoded = decodeFloat32Le(unaligned);

      expect(decoded, <double>[1, -1]);
      decoded[0] = 0.125;
      expect(source[0], 1, reason: 'copy path must not alias the source');
    });

    test('rejects a payload that is not a whole number of samples', () {
      expect(
        () => decodeFloat32Le(Uint8List(6)),
        throwsA(isA<FormatException>()),
      );
    });

    test('encodes a view without dragging in the rest of the buffer', () {
      final Float32List backing = Float32List.fromList(<double>[9, 1, 2, 9]);
      final Float32List window = Float32List.view(
        backing.buffer,
        Float32List.bytesPerElement,
        2,
      );

      final Uint8List encoded = encodeFloat32Le(window);

      expect(encoded.lengthInBytes, 2 * Float32List.bytesPerElement);
      expect(decodeFloat32Le(encoded), <double>[1, 2]);
    });
  });

  group('request encoding', () {
    test('encodes every capture request field', () {
      final Map<String, Object?> encoded = encodeCaptureRequest(
        const PlatformCaptureRequest(
          kind: PlatformCaptureKind.systemAudio,
          outputFormat: PlatformPcmFormat(sampleRate: 16000, channelCount: 1),
          frameDuration: Duration(milliseconds: 120),
          maxBufferedDuration: Duration(seconds: 3),
          overflowPolicy: PlatformCaptureOverflowPolicy.dropOldest,
          inputDeviceId: '{0.0.0.render}',
        ),
      );

      expect(encoded, <String, Object?>{
        'kind': 'systemAudio',
        'sampleRate': 16000,
        'channelCount': 1,
        'frameDurationMicros': 120000,
        'maxBufferedDurationMicros': 3000000,
        'overflowPolicy': 'dropOldest',
        'processIds': <int>[],
        'inputDeviceId': '{0.0.0.render}',
        'voiceProcessing': false,
      });
    });

    test('encodes each capture kind and overflow policy', () {
      expect(encodeCaptureKind(PlatformCaptureKind.microphone), 'microphone');
      expect(encodeCaptureKind(PlatformCaptureKind.systemAudio), 'systemAudio');
      expect(
        encodeOverflowPolicy(PlatformCaptureOverflowPolicy.dropNewest),
        'dropNewest',
      );
      expect(
        encodeOverflowPolicy(PlatformCaptureOverflowPolicy.failCapture),
        'failCapture',
      );
    });

    test('encodes a playback request', () {
      expect(
        encodePlaybackRequest(
          const PlatformPlaybackRequest(
            inputFormat: PlatformPcmFormat(sampleRate: 48000, channelCount: 2),
            maxBufferedDuration: Duration(milliseconds: 500),
          ),
        ),
        <String, Object?>{
          'sampleRate': 48000,
          'channelCount': 2,
          'maxBufferedDurationMicros': 500000,
        },
      );
    });
  });

  group('reply decoding', () {
    test('decodes capture session info', () {
      final PlatformCaptureSessionInfo info =
          decodeCaptureSessionInfo(<Object?, Object?>{
            'sessionId': 7,
            'sourceId': 'render:{0.0.0}',
            'trackId': 'them',
            'clockId': 'wasapi',
            'timingQuality': 'nativeMapped',
            'sampleRate': 16000,
            'channelCount': 1,
          });

      expect(info.sessionId, 7);
      expect(info.sourceId, 'render:{0.0.0}');
      expect(info.trackId, 'them');
      expect(info.clockId, 'wasapi');
      expect(info.timingQuality, PlatformCaptureTimingQuality.nativeMapped);
      expect(
        info.format,
        const PlatformPcmFormat(sampleRate: 16000, channelCount: 1),
      );
    });

    test('decodes playback session info', () {
      final PlatformPlaybackSessionInfo info =
          decodePlaybackSessionInfo(<Object?, Object?>{
            'sessionId': 3,
            'clockId': 'wasapi-render',
            'sampleRate': 48000,
            'channelCount': 2,
          });

      expect(info.sessionId, 3);
      expect(info.clockId, 'wasapi-render');
      expect(info.format.channelCount, 2);
    });

    test('decodes a frame batch preserving drop accounting', () {
      final PlatformAudioFrameBatch batch = decodeFrameBatch(<Object?, Object?>{
        'endOfStream': false,
        'frames': <Object?>[
          <Object?, Object?>{
            'sessionId': 1,
            'sequence': 41,
            'sampleOffset': 6560,
            'timestampMicros': 410000,
            'droppedFramesBefore': 2,
            'samples': encodeFloat32Le(Float32List.fromList(<double>[0.5, -1])),
          },
        ],
      });

      expect(batch.endOfStream, isFalse);
      expect(batch.frames, hasLength(1));
      final PlatformAudioFrame frame = batch.frames.single;
      expect(frame.sequence, 41);
      expect(frame.sampleOffset, 6560);
      expect(frame.timestamp, const Duration(microseconds: 410000));
      expect(frame.droppedFramesBefore, 2);
      expect(frame.samples, <double>[0.5, -1]);
    });

    test('defaults droppedFramesBefore and tolerates a missing frame list', () {
      final PlatformAudioFrame frame = decodeFrame(<Object?, Object?>{
        'sessionId': 1,
        'sequence': 0,
        'sampleOffset': 0,
        'timestampMicros': 0,
        'samples': Uint8List(0),
      });
      expect(frame.droppedFramesBefore, 0);

      final PlatformAudioFrameBatch batch = decodeFrameBatch(<Object?, Object?>{
        'endOfStream': true,
      });
      expect(batch.frames, isEmpty);
      expect(batch.endOfStream, isTrue);
    });

    test('rejects a frame with no sample payload', () {
      expect(
        () => decodeFrame(<Object?, Object?>{
          'sessionId': 1,
          'sequence': 0,
          'sampleOffset': 0,
          'timestampMicros': 0,
        }),
        throwsA(isA<FormatException>()),
      );
    });

    test('rejects a malformed required field', () {
      expect(
        () => decodeCaptureSessionInfo(<Object?, Object?>{
          'sessionId': 'seven',
          'sourceId': 'a',
          'trackId': 'b',
          'clockId': 'c',
          'sampleRate': 16000,
          'channelCount': 1,
        }),
        throwsA(isA<FormatException>()),
      );
    });

    test('decodes devices and processes', () {
      expect(
        decodeInputDevice(<Object?, Object?>{
          'id': '{0.0.1.mic}',
          'label': 'Headset',
          'isDefault': true,
        }).isDefault,
        isTrue,
      );
      expect(
        decodeAudioProcess(<Object?, Object?>{
          'processId': 42,
          'bundleId': 'chrome.exe',
          'isProducingAudio': false,
        }).bundleId,
        'chrome.exe',
      );
    });
  });

  group('session events', () {
    test('maps every known phase', () {
      expect(
        decodeSessionPhase('prepared'),
        PlatformAudioSessionPhase.prepared,
      );
      expect(
        decodeSessionPhase('starting'),
        PlatformAudioSessionPhase.starting,
      );
      expect(decodeSessionPhase('running'), PlatformAudioSessionPhase.running);
      expect(
        decodeSessionPhase('interrupted'),
        PlatformAudioSessionPhase.interrupted,
      );
      expect(
        decodeSessionPhase('stopping'),
        PlatformAudioSessionPhase.stopping,
      );
      expect(decodeSessionPhase('stopped'), PlatformAudioSessionPhase.stopped);
      expect(decodeSessionPhase('failed'), PlatformAudioSessionPhase.failed);
    });

    test('degrades an unknown phase to failed rather than dropping it', () {
      expect(
        decodeSessionPhase('teleported'),
        PlatformAudioSessionPhase.failed,
      );
      expect(decodeSessionPhase(null), PlatformAudioSessionPhase.failed);
    });

    test('decodes a full health event', () {
      final PlatformAudioSessionEvent event =
          decodeSessionEvent(<Object?, Object?>{
            'sessionId': 5,
            'phase': 'running',
            'code': 'CaptureStalled',
            'message': 'no frames for 2s',
            'receivingAudio': false,
            'callbackCount': 12,
          });

      expect(event.sessionId, 5);
      expect(event.phase, PlatformAudioSessionPhase.running);
      expect(event.code, 'CaptureStalled');
      expect(event.message, 'no frames for 2s');
      expect(event.receivingAudio, isFalse);
      expect(event.callbackCount, 12);
    });
  });
}
