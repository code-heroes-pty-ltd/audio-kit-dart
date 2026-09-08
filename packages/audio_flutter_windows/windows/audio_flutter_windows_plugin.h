#ifndef FLUTTER_PLUGIN_AUDIO_FLUTTER_WINDOWS_PLUGIN_H_
#define FLUTTER_PLUGIN_AUDIO_FLUTTER_WINDOWS_PLUGIN_H_

#include <flutter/encodable_value.h>
#include <flutter/event_channel.h>
#include <flutter/event_sink.h>
#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>

#include <windows.h>

#include <mmdeviceapi.h>

#include <condition_variable>
#include <cstdint>
#include <functional>
#include <map>
#include <memory>
#include <mutex>
#include <queue>
#include <string>
#include <thread>
#include <vector>

#include "capture_session.h"
#include "playback_session.h"

namespace audio_flutter_windows {

// WASAPI implementation of the audio_flutter platform contract.
//
// Capture sessions push converted frames into their own bounded ring; Dart
// drains them with `readCaptureFrames`. Only lifecycle events travel over the
// event channel, so the platform-thread task queue below carries a handful of
// messages per session rather than every audio frame.
class AudioFlutterWindowsPlugin : public flutter::Plugin {
 public:
  static void RegisterWithRegistrar(flutter::PluginRegistrarWindows* registrar);

  explicit AudioFlutterWindowsPlugin(
      flutter::PluginRegistrarWindows* registrar);
  ~AudioFlutterWindowsPlugin() override;

  AudioFlutterWindowsPlugin(const AudioFlutterWindowsPlugin&) = delete;
  AudioFlutterWindowsPlugin& operator=(const AudioFlutterWindowsPlugin&) =
      delete;

 private:
  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& method_call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  // Capture.
  void PrepareCapture(
      const flutter::EncodableMap& arguments,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  void ReadCaptureFrames(
      const flutter::EncodableMap& arguments,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  void ReplyWithCaptureInfo(
      const std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>>&
          result,
      const CaptureSession& session, int64_t session_id,
      const CaptureConfig& config);

  // Playback.
  void PreparePlayback(
      const flutter::EncodableMap& arguments,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  void WritePlaybackFrames(
      const flutter::EncodableMap& arguments,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  // Enumeration. `flow` selects capture (inputs) or render (system sources).
  flutter::EncodableValue ListEndpoints(EDataFlow flow);

  // Shared for the duration of one method call, because the call outlives the
  // platform thread's turn: the work runs on a worker and a dispose can arrive
  // meanwhile. Holding a reference keeps the session alive until the worker is
  // done with it, and the last reference — whichever thread drops it — destroys
  // it. Ownership was a bare pointer while every call ran inline on the
  // platform thread; that no longer orders anything.
  std::shared_ptr<CaptureSession> FindCapture(
      const flutter::EncodableMap& arguments);
  std::shared_ptr<PlaybackSession> FindPlayback(
      const flutter::EncodableMap& arguments);

  // Delivers a session event to Dart. Safe to call from any thread: the event
  // is queued and drained on the platform thread, because the Flutter event
  // sink is not thread-safe.
  void PostEvent(SessionEvent event);
  void DrainPlatformTasks();
  void RunOnPlatformThread(std::function<void()> task);

  // Runs `task` on a worker thread, off the platform thread.
  //
  // Every WASAPI call this plugin makes blocks: resolving an endpoint takes
  // COM enumeration, stopping or disposing a session joins its capture thread,
  // and `readCaptureFrames` waits on the frame ring for up to its full timeout
  // — half a second, on every pull, for the whole recording. Run inline on the
  // platform thread, as they all were, that time comes out of the message loop
  // and the window stops painting.
  //
  // A `MethodResult` may only be used on the platform thread, so a task that
  // answers a call does its work here and posts the reply back through
  // `RunOnPlatformThread`.
  void RunOffPlatformThread(std::function<void()> task);

  flutter::PluginRegistrarWindows* registrar_ = nullptr;

  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      method_channel_;
  std::unique_ptr<flutter::EventChannel<flutter::EncodableValue>>
      event_channel_;

  // Touched exclusively on the platform thread.
  std::unique_ptr<flutter::EventSink<flutter::EncodableValue>> event_sink_;

  int window_proc_id_ = -1;

  std::mutex tasks_mutex_;
  std::queue<std::function<void()>> tasks_;

  // Worker pool. Sized so the two capture sessions a call records can sit in
  // their reads simultaneously without either waiting on the other, with room
  // for a lifecycle call or a playback write alongside them.
  static constexpr size_t kWorkerCount = 4;
  std::vector<std::thread> workers_;
  std::mutex work_mutex_;
  std::condition_variable work_available_;
  std::queue<std::function<void()>> work_;
  bool workers_stopping_ = false;

  std::mutex sessions_mutex_;
  std::map<int64_t, std::shared_ptr<CaptureSession>> captures_;
  std::map<int64_t, std::shared_ptr<PlaybackSession>> playbacks_;
  int64_t next_session_id_ = 1;
};

}  // namespace audio_flutter_windows

#endif  // FLUTTER_PLUGIN_AUDIO_FLUTTER_WINDOWS_PLUGIN_H_
