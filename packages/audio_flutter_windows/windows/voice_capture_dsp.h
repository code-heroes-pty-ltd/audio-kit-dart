#ifndef FLUTTER_PLUGIN_AUDIO_FLUTTER_WINDOWS_VOICE_CAPTURE_DSP_H_
#define FLUTTER_PLUGIN_AUDIO_FLUTTER_WINDOWS_VOICE_CAPTURE_DSP_H_

#include <windows.h>

#include <cstdint>
#include <memory>
#include <string>
#include <vector>

namespace audio_flutter_windows {

/// Sample rate the Voice Capture DSP is asked to produce.
///
/// The DSP accepts 8000, 11025, 16000 and 22050 Hz; 16 kHz is the widest band
/// its canceller supports and matches what speech models consume, so the
/// capture path resamples from here rather than asking the DSP for a rate its
/// canceller does not run at.
constexpr int kVoiceCaptureDspSampleRate = 16000;

/// Microphone capture through the Windows Voice Capture DSP (`CWMAudioAEC`).
///
/// The DSP runs in *source* mode: it opens the microphone and the speaker
/// endpoints itself and, because it holds both, it has the render stream as
/// the reference signal its acoustic echo canceller needs. That is the whole
/// point of routing through it — a plain WASAPI capture stream has no
/// reference, so whatever the speakers play is picked up by the microphone and
/// recorded as if the person in the room had said it.
///
/// The DSP delivers 16-bit mono PCM at [kVoiceCaptureDspSampleRate]; this class
/// converts it to float and leaves rate conversion to the caller, which already
/// resamples every other capture path the same way.
class VoiceCaptureDsp {
 public:
  /// [endpoint_id] is the requested capture endpoint, or empty for the default
  /// communications microphone.
  explicit VoiceCaptureDsp(std::string endpoint_id);
  ~VoiceCaptureDsp();

  VoiceCaptureDsp(const VoiceCaptureDsp&) = delete;
  VoiceCaptureDsp& operator=(const VoiceCaptureDsp&) = delete;

  /// Creates the DSP, binds it to the microphone and speaker endpoints, and
  /// allocates its streaming resources.
  ///
  /// Returns false with a reason in [error] when the DSP is unavailable or the
  /// requested microphone cannot be mapped onto an endpoint index. The caller
  /// is expected to fall back to a plain capture stream rather than fail the
  /// session: an uncancelled microphone is worse than a cancelled one, but far
  /// better than none.
  ///
  /// Must be called on a thread with COM initialised.
  bool Initialize(std::string* error);

  /// Appends every echo-cancelled sample the DSP has ready.
  ///
  /// Mono float in [-1, 1] at [kVoiceCaptureDspSampleRate]. Returns false only
  /// on a fatal DSP error; having no samples ready yet is normal and reported
  /// as success with nothing appended.
  bool Drain(std::vector<float>* samples, std::string* error);

  void Stop();

 private:
  struct Impl;
  std::unique_ptr<Impl> impl_;
  std::string endpoint_id_;
};

}  // namespace audio_flutter_windows

#endif  // FLUTTER_PLUGIN_AUDIO_FLUTTER_WINDOWS_VOICE_CAPTURE_DSP_H_
