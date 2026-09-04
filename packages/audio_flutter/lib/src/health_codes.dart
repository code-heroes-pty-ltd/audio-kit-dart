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
  ];
}
