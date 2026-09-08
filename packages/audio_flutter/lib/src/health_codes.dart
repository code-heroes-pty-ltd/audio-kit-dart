/// Capture health codes emitted by the platform supervision loops.
///
/// These strings are the cross-package contract between the native capture
/// implementations and hosts that match on
/// `FlutterAudioCaptureHealth.code`. They must stay byte-identical to the
/// literals in the darwin Swift sources; `health_codes_swift_contract_test`
/// greps those sources for every constant here so a rename on either side
/// fails the suite instead of silently orphaning a host's handler.
abstract final class AudioCaptureHealthCodes {
  /// An armed system tap whose target application has not rendered audio
  /// yet. Reported once per session; the tap starts on its own when the app
  /// produces audio. Non-fatal.
  static const systemCaptureAwaitingAppAudio = 'SystemCaptureAwaitingAppAudio';

  /// A running aggregate device whose IO proc never fired, or two
  /// consecutive advancing supervision windows without converted audio.
  /// Fatal to the session.
  static const systemCaptureDead = 'SystemCaptureDead';

  /// The aggregate's nominal sample rate changed (Bluetooth A2DP↔HFP and
  /// similar clock renegotiations); the capture chain was rebuilt and the
  /// first frames after it carry a restart discontinuity. Non-fatal.
  static const captureSampleRateChanged = 'CaptureSampleRateChanged';

  /// The microphone tap produced no audio inside a supervision window;
  /// recovery is being attempted. Non-fatal, transient.
  static const microphoneTapSilent = 'MicrophoneTapSilent';

  /// The microphone engine reported no usable input format this window; the
  /// window did not consume the rebuild budget. Non-fatal, transient.
  static const microphoneAwaitingInputFormat = 'MicrophoneAwaitingInputFormat';

  /// The microphone input format changed and the tap was reinstalled
  /// successfully; the mic-side analogue of [captureSampleRateChanged].
  /// Non-fatal.
  static const microphoneInputFormatChanged = 'MicrophoneInputFormatChanged';

  /// No usable microphone input format for five consecutive supervision
  /// windows. Fatal to the session.
  static const microphoneInputFormatUnavailable =
      'MicrophoneInputFormatUnavailable';

  /// Restarting the microphone engine after a configuration change failed.
  /// Fatal to the session.
  static const microphoneEngineRestartFailed = 'MicrophoneEngineRestartFailed';

  /// The microphone tap stayed silent past the supervision budget after a
  /// real rebuild attempt. Fatal to the session.
  static const microphoneCaptureDead = 'MicrophoneCaptureDead';

  /// The source-native raw microphone recording was closed because one WAV
  /// file cannot hold two formats. Emitted from inside the same rebuild as
  /// [microphoneInputFormatChanged]. Non-fatal.
  static const microphoneRecordingFormatChanged =
      'MicrophoneRecordingFormatChanged';

  /// The source-native raw system recording was closed because one WAV file
  /// cannot hold two formats. Emitted from inside the same rebuild as
  /// [captureSampleRateChanged]. Non-fatal.
  static const systemRecordingFormatChanged = 'SystemRecordingFormatChanged';

  /// The capture asked for the platform echo canceller and the platform
  /// refused it, so audio played through the speakers is on this track as
  /// well as on the system-audio one. Reported once, as the session starts.
  /// Non-fatal.
  static const microphoneVoiceProcessingUnavailable =
      'MicrophoneVoiceProcessingUnavailable';

  /// The capture aggregate began presenting input channels the tap does not
  /// supply, so the tap was no longer the stream being read; the chain was
  /// rebuilt against the new layout. Emitted when a device the aggregate holds
  /// grows an input side mid-capture — enabling the platform echo canceller
  /// does exactly that to whichever output device it runs on. Non-fatal.
  static const captureStreamLayoutChanged = 'CaptureStreamLayoutChanged';

  /// A capture chain could not be rebuilt after its device changed. Fatal to
  /// the session.
  static const systemCaptureRebuildFailed = 'SystemCaptureRebuildFailed';

  /// A restart after a configuration change failed and is being retried with a
  /// fresh engine. Non-fatal, transient; [microphoneEngineRestartFailed] is
  /// what the same sequence reports once the retries are exhausted.
  static const microphoneEngineRestartRetrying =
      'MicrophoneEngineRestartRetrying';

  /// The microphone's hardware buffer format changed and the converter was
  /// rebuilt from the buffer that carried it. Non-fatal.
  static const microphoneBufferFormatChanged = 'MicrophoneBufferFormatChanged';

  /// The default output device changed and the capture chain was rebuilt
  /// against the new one. Non-fatal; frames after it carry a restart
  /// discontinuity.
  static const defaultOutputDeviceChanged = 'DefaultOutputDeviceChanged';

  /// The native mailbox overflowed under the `failCapture` policy. Fatal to
  /// the session; a capture using a drop policy never reports it.
  static const captureMailboxOverflow = 'CaptureMailboxOverflow';

  /// Audio buffered at stop was discarded rather than delivered. Non-fatal,
  /// reported once as the session ends.
  static const captureTrailingAudioDropped = 'CaptureTrailingAudioDropped';

  /// The native conversion stage fell behind and shed work. Non-fatal.
  static const captureWorkerOverflow = 'CaptureWorkerOverflow';

  /// Source-native recording could not be written. Non-fatal: the converted
  /// track is unaffected.
  static const recordingWriteFailed = 'RecordingWriteFailed';

  /// A Windows capture failed outright — endpoint activation, format, or the
  /// WASAPI loop. Fatal to the session.
  static const captureFailed = 'CaptureFailed';

  /// A Windows capture delivered no audio inside the stall timeout. Fatal to
  /// the session.
  static const captureStalled = 'CaptureStalled';

  /// Activating, starting or reading a Windows process-loopback capture
  /// failed. Each is fatal to the session.
  static const processCaptureActivationFailed =
      'ProcessCaptureActivationFailed';
  static const processCaptureStartFailed = 'ProcessCaptureStartFailed';
  static const processCaptureReadFailed = 'ProcessCaptureReadFailed';

  /// Codes that end a capture. A session reporting one of these has stopped
  /// producing audio and will not resume; the phase is `failed` alongside it.
  ///
  /// Hosts were hand-maintaining this set, which meant every code a new
  /// platform added was silently non-fatal until someone noticed.
  static const fatal = <String>{
    systemCaptureDead,
    systemCaptureRebuildFailed,
    microphoneInputFormatUnavailable,
    microphoneEngineRestartFailed,
    microphoneCaptureDead,
    captureFailed,
    captureStalled,
    captureMailboxOverflow,
    processCaptureActivationFailed,
    processCaptureStartFailed,
    processCaptureReadFailed,
  };

  /// Codes reporting that the audio hardware moved under a running capture.
  ///
  /// None is fatal: the chain was rebuilt, and the frames after it carry a
  /// restart discontinuity. They cost a short gap, which a host aligning by
  /// timestamp materialises as silence.
  static const deviceChange = <String>{
    captureSampleRateChanged,
    microphoneInputFormatChanged,
    microphoneBufferFormatChanged,
    captureStreamLayoutChanged,
    defaultOutputDeviceChanged,
  };

  /// Every constant in this contract, for exhaustive tooling and tests.
  static const all = <String>[
    systemCaptureAwaitingAppAudio,
    systemCaptureDead,
    captureSampleRateChanged,
    microphoneTapSilent,
    microphoneAwaitingInputFormat,
    microphoneInputFormatChanged,
    microphoneInputFormatUnavailable,
    microphoneEngineRestartFailed,
    microphoneCaptureDead,
    microphoneRecordingFormatChanged,
    systemRecordingFormatChanged,
    microphoneVoiceProcessingUnavailable,
    captureStreamLayoutChanged,
    systemCaptureRebuildFailed,
    microphoneEngineRestartRetrying,
    microphoneBufferFormatChanged,
    defaultOutputDeviceChanged,
    captureMailboxOverflow,
    captureTrailingAudioDropped,
    captureWorkerOverflow,
    recordingWriteFailed,
    captureFailed,
    captureStalled,
    processCaptureActivationFailed,
    processCaptureStartFailed,
    processCaptureReadFailed,
  ];
}
