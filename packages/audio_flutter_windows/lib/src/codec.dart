/// Pure translation between the platform contract types and the channel maps
/// described in `channel.dart`.
///
/// Kept free of channel plumbing so every mapping is directly unit-testable
/// without a binary messenger.
library;

import 'dart:typed_data';

import 'package:audio_flutter_platform_interface/audio_flutter_platform_interface.dart';

/// Decodes interleaved little-endian float32 [bytes].
///
/// Views the incoming buffer when it is 4-byte aligned, which is the common
/// case, and otherwise copies through an explicitly little-endian read. Both
/// paths agree on every host Flutter supports.
Float32List decodeFloat32Le(Uint8List bytes) {
  if (bytes.lengthInBytes % Float32List.bytesPerElement != 0) {
    throw FormatException(
      'sample payload of ${bytes.lengthInBytes} bytes is not a whole number '
      'of float32 samples',
    );
  }
  final int count = bytes.lengthInBytes ~/ Float32List.bytesPerElement;
  if (bytes.offsetInBytes % Float32List.bytesPerElement == 0) {
    return Float32List.view(bytes.buffer, bytes.offsetInBytes, count);
  }
  final ByteData data = ByteData.sublistView(bytes);
  final Float32List samples = Float32List(count);
  for (var index = 0; index < count; index++) {
    samples[index] = data.getFloat32(
      index * Float32List.bytesPerElement,
      Endian.little,
    );
  }
  return samples;
}

/// Encodes [samples] as interleaved little-endian float32 bytes without a copy.
Uint8List encodeFloat32Le(Float32List samples) => Uint8List.view(
  samples.buffer,
  samples.offsetInBytes,
  samples.lengthInBytes,
);

String encodeCaptureKind(PlatformCaptureKind kind) => switch (kind) {
  PlatformCaptureKind.microphone => 'microphone',
  PlatformCaptureKind.systemAudio => 'systemAudio',
};

String encodeOverflowPolicy(PlatformCaptureOverflowPolicy policy) =>
    switch (policy) {
      PlatformCaptureOverflowPolicy.dropOldest => 'dropOldest',
      PlatformCaptureOverflowPolicy.dropNewest => 'dropNewest',
      PlatformCaptureOverflowPolicy.failCapture => 'failCapture',
    };

/// Maps a wire discontinuity name onto the contract enum.
///
/// Null means the frame continues the one before it, which is the ordinary
/// case; an unknown name is still a break in the timeline, so it degrades to
/// [PlatformAudioDiscontinuityReason.unknown] rather than being discarded. A
/// dropped break is worse than an imprecise one: a host that never learns the
/// timeline moved keeps placing audio where the old timeline said it belonged.
PlatformAudioDiscontinuityReason? decodeDiscontinuityReason(String? name) =>
    switch (name) {
      null => null,
      'droppedFrames' => PlatformAudioDiscontinuityReason.droppedFrames,
      'sourceRestart' => PlatformAudioDiscontinuityReason.sourceRestart,
      'clockReset' => PlatformAudioDiscontinuityReason.clockReset,
      'formatChange' => PlatformAudioDiscontinuityReason.formatChange,
      _ => PlatformAudioDiscontinuityReason.unknown,
    };

/// Maps a wire phase name onto the contract enum.
///
/// Unknown names degrade to [PlatformAudioSessionPhase.failed] rather than
/// throwing: a health event is a diagnostic, and dropping one because a newer
/// plugin added a phase would hide the very failure it reports.
PlatformAudioSessionPhase decodeSessionPhase(String? name) => switch (name) {
  'prepared' => PlatformAudioSessionPhase.prepared,
  'starting' => PlatformAudioSessionPhase.starting,
  'running' => PlatformAudioSessionPhase.running,
  'interrupted' => PlatformAudioSessionPhase.interrupted,
  'stopping' => PlatformAudioSessionPhase.stopping,
  'stopped' => PlatformAudioSessionPhase.stopped,
  'failed' => PlatformAudioSessionPhase.failed,
  _ => PlatformAudioSessionPhase.failed,
};

Map<String, Object?> encodeCaptureRequest(PlatformCaptureRequest request) =>
    <String, Object?>{
      'kind': encodeCaptureKind(request.kind),
      'sampleRate': request.outputFormat.sampleRate,
      'channelCount': request.outputFormat.channelCount,
      'frameDurationMicros': request.frameDuration.inMicroseconds,
      'maxBufferedDurationMicros': request.maxBufferedDuration.inMicroseconds,
      'overflowPolicy': encodeOverflowPolicy(request.overflowPolicy),
      'processIds': request.processIds,
      'inputDeviceId': request.inputDeviceId,
      'voiceProcessing': request.voiceProcessing,
    };

Map<String, Object?> encodePlaybackRequest(PlatformPlaybackRequest request) =>
    <String, Object?>{
      'sampleRate': request.inputFormat.sampleRate,
      'channelCount': request.inputFormat.channelCount,
      'maxBufferedDurationMicros': request.maxBufferedDuration.inMicroseconds,
    };

PlatformPcmFormat decodeFormat(Map<Object?, Object?> reply) =>
    PlatformPcmFormat(
      sampleRate: _requireInt(reply, 'sampleRate'),
      channelCount: _requireInt(reply, 'channelCount'),
    );

PlatformCaptureSessionInfo decodeCaptureSessionInfo(
  Map<Object?, Object?> reply,
) => PlatformCaptureSessionInfo(
  sessionId: _requireInt(reply, 'sessionId'),
  sourceId: _requireString(reply, 'sourceId'),
  trackId: _requireString(reply, 'trackId'),
  clockId: _requireString(reply, 'clockId'),
  format: decodeFormat(reply),
  timingQuality: switch (reply['timingQuality']) {
    'nativeMapped' => PlatformCaptureTimingQuality.nativeMapped,
    'synchronized' => PlatformCaptureTimingQuality.synchronized,
    _ => PlatformCaptureTimingQuality.synthesized,
  },
);

PlatformPlaybackSessionInfo decodePlaybackSessionInfo(
  Map<Object?, Object?> reply,
) => PlatformPlaybackSessionInfo(
  sessionId: _requireInt(reply, 'sessionId'),
  clockId: _requireString(reply, 'clockId'),
  format: decodeFormat(reply),
);

PlatformAudioFrame decodeFrame(Map<Object?, Object?> entry) {
  final Object? samples = entry['samples'];
  if (samples is! Uint8List) {
    throw const FormatException('frame is missing its float32 sample payload');
  }
  return PlatformAudioFrame(
    sessionId: _requireInt(entry, 'sessionId'),
    sequence: _requireInt(entry, 'sequence'),
    sampleOffset: _requireInt(entry, 'sampleOffset'),
    timestamp: Duration(microseconds: _requireInt(entry, 'timestampMicros')),
    samples: decodeFloat32Le(samples),
    droppedFramesBefore: _optionalInt(entry, 'droppedFramesBefore') ?? 0,
    discontinuityReason: decodeDiscontinuityReason(
      entry['discontinuityReason'] as String?,
    ),
  );
}

PlatformAudioFrameBatch decodeFrameBatch(Map<Object?, Object?> reply) {
  final Object? frames = reply['frames'];
  return PlatformAudioFrameBatch(
    frames: frames is List
        ? frames
              .cast<Map<Object?, Object?>>()
              .map(decodeFrame)
              .toList(growable: false)
        : const <PlatformAudioFrame>[],
    endOfStream: reply['endOfStream'] == true,
  );
}

PlatformAudioInputDevice decodeInputDevice(Map<Object?, Object?> entry) =>
    PlatformAudioInputDevice(
      id: _requireString(entry, 'id'),
      label: _requireString(entry, 'label'),
      isDefault: entry['isDefault'] == true,
    );

PlatformAudioProcess decodeAudioProcess(Map<Object?, Object?> entry) =>
    PlatformAudioProcess(
      processId: _requireInt(entry, 'processId'),
      bundleId: _requireString(entry, 'bundleId'),
      isProducingAudio: entry['isProducingAudio'] == true,
    );

PlatformAudioSessionEvent decodeSessionEvent(Map<Object?, Object?> entry) =>
    PlatformAudioSessionEvent(
      sessionId: _requireInt(entry, 'sessionId'),
      phase: decodeSessionPhase(entry['phase'] as String?),
      code: entry['code'] as String?,
      message: entry['message'] as String?,
      receivingAudio: entry['receivingAudio'] as bool?,
      callbackCount: _optionalInt(entry, 'callbackCount'),
    );

int _requireInt(Map<Object?, Object?> map, String key) {
  final Object? value = map[key];
  if (value is int) {
    return value;
  }
  throw FormatException('expected int for "$key", got ${value.runtimeType}');
}

int? _optionalInt(Map<Object?, Object?> map, String key) {
  final Object? value = map[key];
  return value is int ? value : null;
}

String _requireString(Map<Object?, Object?> map, String key) {
  final Object? value = map[key];
  if (value is String) {
    return value;
  }
  throw FormatException('expected String for "$key", got ${value.runtimeType}');
}
