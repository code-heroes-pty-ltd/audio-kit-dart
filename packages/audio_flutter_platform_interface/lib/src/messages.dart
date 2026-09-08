import 'dart:typed_data';

/// Physical source selected for a capture session.
enum PlatformCaptureKind { microphone, systemAudio }

/// Normalized source category reported by a federated capture backend.
enum PlatformCaptureSourceKind {
  microphone,
  application,
  browser,
  systemMix,
  pulseMonitor,
  pipeWireMonitor,
}

/// Whether a normalized source can currently be opened.
enum PlatformCaptureSourceAvailability {
  available,
  permissionRequired,
  unavailable,
}

/// Independently probeable behavior exposed by a platform capture adapter.
enum PlatformCaptureCapability {
  processFiltering,
  applicationFiltering,
  browserGrouping,
  systemMix,
  pauseResume,
  sourceChangeEvents,
  nativeMonotonicClock,
  independentTracks,
}

/// How native frame timestamps map onto a monotonic session timeline.
enum PlatformCaptureTimingQuality { nativeMapped, synchronized, synthesized }

/// Stable facts about the active federated capture implementation.
final class PlatformCaptureBackendInfo {
  const PlatformCaptureBackendInfo({
    required this.backendId,
    required this.displayName,
    required this.platform,
    required this.sourceKinds,
    this.capabilities = const <PlatformCaptureCapability>{},
  });

  final String backendId;
  final String displayName;
  final String platform;
  final Set<PlatformCaptureSourceKind> sourceKinds;
  final Set<PlatformCaptureCapability> capabilities;
}

/// One normalized source plus the exact native request needed to open it.
///
/// Unavailable entries are intentional: they let callers distinguish a native
/// feature the platform does not implement from an empty, transient device
/// list. [availabilityCode] is stable for programmatic handling while
/// [availabilityReason] is suitable for diagnostics and UI.
final class PlatformCaptureSourceInfo {
  const PlatformCaptureSourceInfo({
    required this.sourceId,
    required this.kind,
    required this.displayName,
    required this.availability,
    required this.captureKind,
    required this.timingQuality,
    this.capabilities = const <PlatformCaptureCapability>{},
    this.supportedSampleRates = const <int>[],
    this.supportedChannelCounts = const <int>[],
    this.minimumSampleRate,
    this.maximumSampleRate,
    this.minimumChannelCount,
    this.maximumChannelCount,
    this.processIds = const <int>[],
    this.isDefault = false,
    this.nativeSourceId,
    this.applicationId,
    this.inputDeviceId,
    this.availabilityCode,
    this.availabilityReason,
  });

  final String sourceId;
  final PlatformCaptureSourceKind kind;
  final String displayName;
  final PlatformCaptureSourceAvailability availability;
  final PlatformCaptureKind captureKind;
  final PlatformCaptureTimingQuality timingQuality;
  final Set<PlatformCaptureCapability> capabilities;
  final List<int> supportedSampleRates;
  final List<int> supportedChannelCounts;
  final int? minimumSampleRate;
  final int? maximumSampleRate;
  final int? minimumChannelCount;
  final int? maximumChannelCount;
  final List<int> processIds;
  final bool isDefault;
  final String? nativeSourceId;
  final String? applicationId;
  final String? inputDeviceId;
  final String? availabilityCode;
  final String? availabilityReason;
}

/// Overflow action for the bounded native capture mailbox.
enum PlatformCaptureOverflowPolicy { dropOldest, dropNewest, failCapture }

/// Why the source timeline broke immediately before a platform frame.
enum PlatformAudioDiscontinuityReason {
  droppedFrames,
  sourceRestart,
  clockReset,

  /// No platform implementation emits this today: the darwin captures
  /// respond to a mid-capture format change by rebuilding the chain (frames
  /// resume with [sourceRestart]) and disclosing it through capture health
  /// events (`CaptureSampleRateChanged` / `MicrophoneInputFormatChanged`).
  /// The value is kept for wire stability and for hosts' processing
  /// pipelines, which do synthesize format-change discontinuities.
  formatChange,
  unknown,
}

/// Platform-reported microphone authorization, mirroring the Apple states.
enum PlatformMicrophonePermissionStatus {
  /// The user has not been asked yet; a request can still show the prompt.
  notDetermined,
  granted,

  /// Explicitly refused. Only the user can change this, in system settings.
  denied,

  /// Blocked by policy (managed device, parental controls). Not requestable.
  restricted,
}

/// Low-frequency lifecycle state reported independently from audio frames.
enum PlatformAudioSessionPhase {
  prepared,
  starting,
  running,
  interrupted,
  stopping,
  stopped,
  failed,
}

/// Fixed PCM format for one platform capture or playback session.
final class PlatformPcmFormat {
  const PlatformPcmFormat({
    required this.sampleRate,
    required this.channelCount,
  }) : assert(sampleRate > 0),
       assert(channelCount > 0);

  final int sampleRate;
  final int channelCount;

  @override
  bool operator ==(Object other) =>
      other is PlatformPcmFormat &&
      other.sampleRate == sampleRate &&
      other.channelCount == channelCount;

  @override
  int get hashCode => Object.hash(sampleRate, channelCount);
}

/// Fully typed request for a prepared native capture.
final class PlatformCaptureRequest {
  const PlatformCaptureRequest({
    required this.kind,
    required this.outputFormat,
    this.frameDuration = const Duration(milliseconds: 100),
    this.maxBufferedDuration = const Duration(seconds: 2),
    this.overflowPolicy = PlatformCaptureOverflowPolicy.failCapture,
    this.processIds = const <int>[],
    this.bundleIds = const <String>[],
    this.inputDeviceId,
    this.rawRecordingPath,
    this.voiceProcessing = false,
  });

  final PlatformCaptureKind kind;
  final PlatformPcmFormat outputFormat;
  final Duration frameDuration;
  final Duration maxBufferedDuration;
  final PlatformCaptureOverflowPolicy overflowPolicy;

  /// Empty means all system audio except the current process, unless
  /// [bundleIds] names the applications to capture.
  final List<int> processIds;

  /// Application bundle IDs to capture, independent of which processes carry
  /// them right now.
  ///
  /// Identity outlives a process: a helper that spawns after the capture
  /// started, or an app that quits and relaunches, is still the same target.
  /// Platforms that can tap by identity (macOS 26 and newer) do exactly that;
  /// the rest resolve these to processes every time they build a capture
  /// chain, which is still stronger than a process list frozen at start.
  /// Ignored by platforms with no application identity of their own.
  final List<String> bundleIds;
  final String? inputDeviceId;

  /// Optional source-side recording, finalized by graceful stop.
  final String? rawRecordingPath;

  /// Whether the platform echo canceller runs on a microphone capture.
  ///
  /// The far end of a call played through the speakers is picked up by the
  /// microphone, so a raw input tap carries it too and a per-track transcript
  /// reports it twice. With this set the platform's own canceller removes the
  /// system output from the microphone signal, using that output as its
  /// reference. It costs a processed (rather than raw) microphone signal, so it
  /// is off by default and opt-in per capture.
  ///
  /// Ignored by system-audio captures, which have no echo to cancel, and by
  /// platforms with no canceller of their own.
  final bool voiceProcessing;
}

/// Opaque prepared capture information.
final class PlatformCaptureSessionInfo {
  const PlatformCaptureSessionInfo({
    required this.sessionId,
    required this.sourceId,
    required this.trackId,
    required this.clockId,
    required this.format,
    this.timingQuality = PlatformCaptureTimingQuality.synthesized,
  });

  final int sessionId;
  final String sourceId;
  final String trackId;
  final String clockId;
  final PlatformPcmFormat format;

  /// Quality of the native timestamp-to-session-clock mapping.
  final PlatformCaptureTimingQuality timingQuality;
}

/// One owned interleaved float32 frame returned by a platform pull.
final class PlatformAudioFrame {
  const PlatformAudioFrame({
    required this.sessionId,
    required this.sequence,
    required this.sampleOffset,
    required this.timestamp,
    required this.samples,
    this.droppedFramesBefore = 0,
    this.discontinuityReason,
  }) : assert(droppedFramesBefore >= 0);

  final int sessionId;
  final int sequence;
  final int sampleOffset;
  final Duration timestamp;
  final Float32List samples;

  /// Frames removed by the native mailbox immediately before this frame.
  final int droppedFramesBefore;

  /// Why continuity broke before this frame, when the platform reports it.
  ///
  /// Null means the platform said nothing: a frame with
  /// [droppedFramesBefore] > 0 and no reason is still a dropped-frame gap.
  final PlatformAudioDiscontinuityReason? discontinuityReason;
}

/// A bounded native mailbox read.
final class PlatformAudioFrameBatch {
  const PlatformAudioFrameBatch({
    required this.frames,
    required this.endOfStream,
  });

  final List<PlatformAudioFrame> frames;
  final bool endOfStream;
}

/// Lifecycle/health event for a capture or playback session.
final class PlatformAudioSessionEvent {
  const PlatformAudioSessionEvent({
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

  final int sessionId;
  final PlatformAudioSessionPhase phase;
  final String? code;
  final String? message;
  final bool? receivingAudio;
  final int? callbackCount;

  /// Largest absolute sample seen since the session started, 0...1 nominal.
  final double? peakAmplitude;

  /// Root mean square over every sample delivered since the session started.
  final double? rms;

  /// Percentage of delivered callback buffers that carried non-zero audio.
  final double? nonZeroFramePercent;

  /// Hardware render callbacks delivered, including buffers a bounded queue
  /// dropped before conversion. Always at least [callbackCount].
  final int? renderCycles;

  /// Milliseconds from session creation to the first non-zero buffer.
  final int? firstAudioAtMillis;
}

/// Core Audio process that may be selected for system capture.
final class PlatformAudioProcess {
  const PlatformAudioProcess({
    required this.processId,
    required this.bundleId,
    required this.isProducingAudio,
  });

  final int processId;
  final String bundleId;
  final bool isProducingAudio;
}

/// Provider-neutral physical input device exposed by the platform.
final class PlatformAudioInputDevice {
  const PlatformAudioInputDevice({
    required this.id,
    required this.label,
    required this.isDefault,
  });

  /// Stable platform device identifier, such as a Core Audio UID.
  final String id;

  /// Human-readable device name.
  final String label;

  /// Whether the platform currently selects this input by default.
  final bool isDefault;
}

/// Typed request for a PCM playback sink.
final class PlatformPlaybackRequest {
  const PlatformPlaybackRequest({
    required this.inputFormat,
    this.maxBufferedDuration = const Duration(seconds: 2),
  });

  final PlatformPcmFormat inputFormat;
  final Duration maxBufferedDuration;
}

/// Opaque prepared playback information.
final class PlatformPlaybackSessionInfo {
  const PlatformPlaybackSessionInfo({
    required this.sessionId,
    required this.clockId,
    required this.format,
  });

  final int sessionId;
  final String clockId;
  final PlatformPcmFormat format;
}
