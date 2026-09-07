#ifndef FLUTTER_PLUGIN_AUDIO_FLUTTER_WINDOWS_FRAME_RING_H_
#define FLUTTER_PLUGIN_AUDIO_FLUTTER_WINDOWS_FRAME_RING_H_

#include <cstdint>
#include <deque>
#include <vector>

namespace audio_flutter_windows {

// Overflow behaviour, mirroring PlatformCaptureOverflowPolicy on the Dart side.
enum class OverflowPolicy { kDropOldest, kDropNewest, kFailCapture };

// One converted frame waiting for a pull.
struct CapturedFrame {
  int64_t sequence = 0;
  int64_t sample_offset = 0;
  int64_t timestamp_micros = 0;
  int64_t dropped_frames_before = 0;
  // Set on the first frame after the capture timeline moved: a source that
  // stopped producing, or a chain rebuilt against another endpoint.
  //
  // A host places frames by counting samples from an anchor, and only re-reads
  // the timestamp when a frame says the timeline restarted. Without this, audio
  // the source never produced is audio the host never accounts for: its
  // position lags real time by the length of the gap, permanently, until it
  // falls behind what has already been written and every later frame is
  // discarded. Nothing was dropped, so `dropped_frames_before` cannot say it.
  bool timeline_restarted = false;
  std::vector<float> samples;
};

// Bounded queue between the WASAPI capture thread (producer) and
// readCaptureFrames pulls (consumer). Every access is guarded by the owning
// session's mutex; this type itself does no locking.
//
// Drop accounting matches the Dart FrameRing exactly: `sequence` and
// `sample_offset` are assigned by the producer and keep advancing across drops,
// and the frame delivered after a gap reports how many frames vanished before
// it. dropOldest evicts the head and bills the next read; dropNewest refuses the
// arrival and bills the next admitted frame.
class FrameRing {
 public:
  enum class Admission { kAccepted, kDisplacedOldest, kDiscarded, kOverflowed };

  void Configure(size_t capacity, OverflowPolicy policy);

  Admission Add(CapturedFrame frame);

  // Moves at most `max_frames` frames, oldest first, into `out`.
  void Take(size_t max_frames, std::vector<CapturedFrame>* out);

  bool Empty() const { return frames_.empty(); }
  size_t Size() const { return frames_.size(); }

  void Clear();

 private:
  size_t capacity_ = 1;
  OverflowPolicy policy_ = OverflowPolicy::kFailCapture;
  std::deque<CapturedFrame> frames_;
  // Frames evicted from the head, owed to whichever frame is read next.
  int64_t drops_before_head_ = 0;
  // Frames refused at the tail, owed to the next frame actually queued.
  int64_t drops_before_next_add_ = 0;
};

}  // namespace audio_flutter_windows

#endif  // FLUTTER_PLUGIN_AUDIO_FLUTTER_WINDOWS_FRAME_RING_H_
