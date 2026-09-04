import 'package:pigeon/pigeon.dart';

@ConfigurePigeon(
  PigeonOptions(
    dartOut: 'lib/src/messages.g.dart',
    swiftOut:
        'darwin/audio_flutter_darwin/Sources/audio_flutter_darwin/Messages.g.swift',
    dartPackageName: 'audio_flutter_darwin',
  ),
)
enum CaptureKindMessage { microphone, systemAudio }

enum CaptureOverflowPolicyMessage { dropOldest, dropNewest, failCapture }

enum AudioSessionPhaseMessage {
  prepared,
  starting,
  running,
  interrupted,
  stopping,
  stopped,
  failed,
}

/// Why the source timeline broke immediately before a frame.
enum DiscontinuityReasonMessage {
  droppedFrames,
  sourceRestart,
  clockReset,
  formatChange,
  unknown,
}

/// Mirrors `AVAuthorizationStatus` for the audio capture device.
enum MicrophonePermissionStatusMessage {
  notDetermined,
  granted,
  denied,
  restricted,
}

class PcmFormatMessage {
  PcmFormatMessage({required this.sampleRate, required this.channelCount});

  int sampleRate;
  int channelCount;
}

class CaptureRequestMessage {
  CaptureRequestMessage({
    required this.kind,
    required this.outputFormat,
    required this.frameDurationMicros,
    required this.maxBufferedDurationMicros,
    required this.overflowPolicy,
    required this.processIds,
    this.bundleIds,
    this.inputDeviceId,
    this.rawRecordingPath,
    this.voiceProcessing,
  });

  CaptureKindMessage kind;
  PcmFormatMessage outputFormat;
  int frameDurationMicros;
  int maxBufferedDurationMicros;
  CaptureOverflowPolicyMessage overflowPolicy;
  List<int> processIds;

  /// Application bundle IDs to tap, independent of which processes currently
  /// carry them.
  ///
  /// macOS 26 taps these identities directly and restores them across app
  /// exit and relaunch; older versions resolve them to process objects when
  /// the chain is built, which is re-done on every rebuild.
  List<String>? bundleIds;
  String? inputDeviceId;
  String? rawRecordingPath;

  /// Whether to run the microphone through the platform voice-processing unit,
  /// whose echo canceller removes the system output from the captured signal.
  ///
  /// Null and false are the same request: the raw input tap. Ignored by
  /// system-audio capture.
  bool? voiceProcessing;
}

class CaptureSessionInfoMessage {
  CaptureSessionInfoMessage({
    required this.sessionId,
    required this.sourceId,
    required this.trackId,
    required this.clockId,
    required this.format,
  });

  int sessionId;
  String sourceId;
  String trackId;
  String clockId;
  PcmFormatMessage format;
}

class AudioFrameMessage {
  AudioFrameMessage({
    required this.sessionId,
    required this.sequence,
    required this.sampleOffset,
    required this.timestampMicros,
    required this.float32Samples,
    required this.droppedFramesBefore,
    this.discontinuityReason,
  });

  int sessionId;
  int sequence;
  int sampleOffset;
  int timestampMicros;
  Uint8List float32Samples;
  int droppedFramesBefore;

  /// Null when the frame continues the previous one. Set for every reported
  /// gap, including the ones a rebuilt capture chain opens with no frame loss.
  DiscontinuityReasonMessage? discontinuityReason;
}

class AudioFrameBatchMessage {
  AudioFrameBatchMessage({required this.frames, required this.endOfStream});

  List<AudioFrameMessage> frames;
  bool endOfStream;
}

class AudioSessionEventMessage {
  AudioSessionEventMessage({
    required this.sessionId,
    required this.phase,
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

  int sessionId;
  AudioSessionPhaseMessage phase;
  String? code;
  String? message;
  bool? receivingAudio;
  int? callbackCount;

  /// Largest absolute sample seen since the session started, 0...1 nominal.
  double? peakAmplitude;

  /// Root mean square over every converted sample since the session started.
  double? rms;

  /// Percentage of converted callback buffers that carried non-zero audio.
  double? nonZeroFramePercent;

  /// Hardware render callbacks delivered, including buffers a bounded queue
  /// dropped before conversion.
  int? renderCycles;

  /// Milliseconds from session creation to the first non-zero buffer.
  int? firstAudioAtMillis;
}

class AudioProcessMessage {
  AudioProcessMessage({
    required this.processId,
    required this.bundleId,
    required this.isProducingAudio,
  });

  int processId;
  String bundleId;
  bool isProducingAudio;
}

class AudioInputDeviceMessage {
  AudioInputDeviceMessage({
    required this.id,
    required this.label,
    required this.isDefault,
  });

  String id;
  String label;
  bool isDefault;
}

class PlaybackRequestMessage {
  PlaybackRequestMessage({
    required this.inputFormat,
    required this.maxBufferedDurationMicros,
  });

  PcmFormatMessage inputFormat;
  int maxBufferedDurationMicros;
}

class PlaybackSessionInfoMessage {
  PlaybackSessionInfoMessage({
    required this.sessionId,
    required this.clockId,
    required this.format,
  });

  int sessionId;
  String clockId;
  PcmFormatMessage format;
}

@HostApi()
abstract class DarwinAudioHostApi {
  @async
  CaptureSessionInfoMessage prepareCapture(CaptureRequestMessage request);

  @async
  void startCapture(int sessionId);

  @async
  AudioFrameBatchMessage readCaptureFrames(
    int sessionId,
    int maxFrames,
    int timeoutMillis,
  );

  @async
  void stopCapture(int sessionId);

  @async
  void abortCapture(int sessionId);

  @async
  void disposeCapture(int sessionId);

  @async
  bool isSystemAudioCaptureSupported();

  @async
  bool requestSystemAudioCapturePermission();

  @async
  MicrophonePermissionStatusMessage microphonePermissionStatus();

  @async
  MicrophonePermissionStatusMessage requestMicrophonePermission();

  @async
  int cleanupOrphanedAggregateDevices();

  @async
  List<AudioInputDeviceMessage> listAudioInputDevices();

  @async
  List<AudioProcessMessage> listAudioProcesses();

  @async
  PlaybackSessionInfoMessage preparePlayback(PlaybackRequestMessage request);

  @async
  void startPlayback(int sessionId);

  @async
  void writePlaybackFrames(int sessionId, List<AudioFrameMessage> frames);

  @async
  void finishPlayback(int sessionId);

  @async
  void abortPlayback(int sessionId);

  @async
  void disposePlayback(int sessionId);
}

@EventChannelApi()
abstract class DarwinAudioEventChannelApi {
  AudioSessionEventMessage sessionEvents();
}
