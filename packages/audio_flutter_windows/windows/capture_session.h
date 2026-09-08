#ifndef FLUTTER_PLUGIN_AUDIO_FLUTTER_WINDOWS_CAPTURE_SESSION_H_
#define FLUTTER_PLUGIN_AUDIO_FLUTTER_WINDOWS_CAPTURE_SESSION_H_

#include <windows.h>

#include <atomic>
#include <condition_variable>
#include <functional>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include "frame_ring.h"

namespace audio_flutter_windows {

// Which endpoint kind a session captures.
enum class CaptureKind { kMicrophone, kSystemAudio };

// Lifecycle phase, mirroring PlatformAudioSessionPhase on the Dart side.
enum class SessionPhase {
  kPrepared,
  kStarting,
  kRunning,
  kInterrupted,
  kStopping,
  kStopped,
  kFailed,
};

const char* PhaseName(SessionPhase phase);

// A health event bound for the Dart event channel.
struct SessionEvent {
  int64_t session_id = 0;
  SessionPhase phase = SessionPhase::kPrepared;
  std::string code;
  std::string message;
  bool has_receiving_audio = false;
  bool receiving_audio = false;
};

// Called from any thread; the plugin marshals the event onto the platform
// thread before touching the Flutter event sink.
using EventCallback = std::function<void(SessionEvent)>;

struct CaptureConfig {
  CaptureKind kind = CaptureKind::kSystemAudio;
  int sample_rate = 16000;
  int channel_count = 1;
  int64_t frame_duration_micros = 100000;
  int64_t max_buffered_duration_micros = 2000000;
  OverflowPolicy overflow_policy = OverflowPolicy::kFailCapture;
  // Empty selects the default endpoint for `kind`.
  std::string endpoint_id;
  // Whether a microphone capture is echo-cancelled against the system output.
  // Ignored for system-audio capture, which is the reference signal itself.
  bool voice_processing = false;
  // Exact requested process trees. Empty selects endpoint capture.
  std::vector<DWORD> process_ids;
};

// One WASAPI capture, pulled rather than pushed.
//
// A dedicated thread runs the WASAPI poll loop, converts each packet to the
// requested format and appends whole frames to a bounded ring. `Read` drains
// that ring from the platform thread. Because the consumer pulls, there is no
// audio path through the event channel and no platform-thread marshalling in
// the hot loop — the ring mutex is the only synchronisation between the two.
//
// The WASAPI initialisation sequence, mix-format handling and poll cadence are
// derived from Control Center's `system_audio_capture` plugin
// (MIT (c) 2026 Samuel Alev); see the package NOTICE.
class CaptureSession {
 public:
  CaptureSession(int64_t session_id, CaptureConfig config,
                 EventCallback on_event);
  ~CaptureSession();

  CaptureSession(const CaptureSession&) = delete;
  CaptureSession& operator=(const CaptureSession&) = delete;

  int64_t session_id() const { return session_id_; }
  const std::string& source_id() const { return source_id_; }
  const CaptureConfig& config() const { return config_; }

  // Resolves the endpoint and reports the prepared phase. Returns false and
  // fills `error` when no endpoint can be opened.
  bool Prepare(std::string* error);

  bool Start(std::string* error);

  // Drains at most `max_frames`, waiting up to `timeout_millis` for the first
  // one. `end_of_stream` reports that the session has finished and the ring is
  // drained.
  void Read(size_t max_frames, int64_t timeout_millis,
            std::vector<CapturedFrame>* out, bool* end_of_stream);

  // Graceful: stops the thread and leaves buffered frames readable.
  void Stop();

  // Immediate: stops the thread and discards buffered frames.
  void Abort();

 private:
  void CaptureThreadMain();
  void ProcessCaptureThreadMain();
  void EchoCancelledCaptureThreadMain();
  void JoinThread();
  void Emit(SessionPhase phase, const std::string& code = std::string(),
            const std::string& message = std::string());
  void Fail(const std::string& code, const std::string& message);
  // Reports that the microphone is being recorded without echo cancellation,
  // and latches the refusal so the handover cannot come back.
  void DeclineEchoCancellation(const std::string& reason);

  const int64_t session_id_;
  const CaptureConfig config_;
  const EventCallback on_event_;

  std::string source_id_;

  std::thread thread_;
  std::atomic<bool> stop_requested_{false};
  std::atomic<bool> running_{false};
  std::atomic<bool> finished_{false};
  std::atomic<bool> received_any_audio_{false};
  // Set by the endpoint notification client when the default endpoint for this
  // session's data flow moves. Polled by the capture loop, which reopens
  // against the new device rather than recording the old one.
  std::atomic<bool> default_endpoint_changed_{false};
  // Set once the Voice Capture DSP has refused a session, so the plain endpoint
  // stream it falls back to cannot hand the capture to the DSP again.
  std::atomic<bool> echo_cancellation_declined_{false};

  mutable std::mutex mutex_;
  std::condition_variable frames_available_;
  FrameRing ring_;

  int64_t next_sequence_ = 0;
  int64_t next_sample_offset_ = 0;
};

}  // namespace audio_flutter_windows

#endif  // FLUTTER_PLUGIN_AUDIO_FLUTTER_WINDOWS_CAPTURE_SESSION_H_
