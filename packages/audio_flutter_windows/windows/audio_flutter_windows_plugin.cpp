#include "audio_flutter_windows_plugin.h"

#include <flutter/event_stream_handler_functions.h>
#include <flutter/method_result_functions.h>
#include <flutter/standard_method_codec.h>

// See capture_session.cpp for why this include order is deliberate.
// clang-format off
#include <audioclient.h>
#include <mmdeviceapi.h>
#include <functiondiscoverykeys_devpkey.h>  // PKEY_Device_FriendlyName
// clang-format on

#include <algorithm>
#include <cstring>
#include <limits>
#include <optional>
#include <utility>
#include <vector>

#include "com_utils.h"
#include "process_loopback_capture.h"

namespace audio_flutter_windows {

namespace {

// Channel names; these must match lib/src/channel.dart exactly.
constexpr char kMethodChannelName[] =
    "dev.kshdotdev.audio_kit/audio_flutter_windows";
constexpr char kEventChannelName[] =
    "dev.kshdotdev.audio_kit/audio_flutter_windows/events";

// Private window message used to drain platform-thread tasks. WM_USER is safe
// for window-class-private messages; 0x311 keeps clear of the conventions other
// plugins use on the Flutter view window.
constexpr UINT WM_AFW_RUN_TASK = WM_USER + 0x311;

const flutter::EncodableValue* Find(const flutter::EncodableMap& map,
                                    const char* key) {
  const auto it = map.find(flutter::EncodableValue(key));
  return it == map.end() ? nullptr : &it->second;
}

int64_t IntArg(const flutter::EncodableMap& map, const char* key,
               int64_t fallback) {
  const flutter::EncodableValue* value = Find(map, key);
  if (value == nullptr) {
    return fallback;
  }
  if (const auto* narrow = std::get_if<int32_t>(value)) {
    return *narrow;
  }
  if (const auto* wide = std::get_if<int64_t>(value)) {
    return *wide;
  }
  return fallback;
}

bool BoolArg(const flutter::EncodableMap& map, const char* key,
             bool fallback) {
  const flutter::EncodableValue* value = Find(map, key);
  if (value == nullptr) {
    return fallback;
  }
  const auto* flag = std::get_if<bool>(value);
  return flag == nullptr ? fallback : *flag;
}

std::string StringArg(const flutter::EncodableMap& map, const char* key) {
  const flutter::EncodableValue* value = Find(map, key);
  if (value == nullptr) {
    return std::string();
  }
  const auto* text = std::get_if<std::string>(value);
  return text == nullptr ? std::string() : *text;
}

std::vector<DWORD> ProcessIdsArg(const flutter::EncodableMap& map,
                                 const char* key) {
  const flutter::EncodableValue* value = Find(map, key);
  const auto* list =
      value == nullptr ? nullptr : std::get_if<flutter::EncodableList>(value);
  if (list == nullptr) {
    return {};
  }
  std::vector<DWORD> process_ids;
  for (const flutter::EncodableValue& item : *list) {
    int64_t process_id = 0;
    if (const auto* narrow = std::get_if<int32_t>(&item)) {
      process_id = *narrow;
    } else if (const auto* wide = std::get_if<int64_t>(&item)) {
      process_id = *wide;
    }
    if (process_id <= 0 ||
        process_id > static_cast<int64_t>(std::numeric_limits<DWORD>::max())) {
      return {};
    }
    const DWORD native_id = static_cast<DWORD>(process_id);
    if (std::find(process_ids.begin(), process_ids.end(), native_id) !=
        process_ids.end()) {
      return {};
    }
    process_ids.push_back(native_id);
  }
  return process_ids;
}

const flutter::EncodableMap* MapArguments(
    const flutter::MethodCall<flutter::EncodableValue>& call) {
  return std::get_if<flutter::EncodableMap>(call.arguments());
}

OverflowPolicy ParseOverflowPolicy(const std::string& name) {
  if (name == "dropOldest") {
    return OverflowPolicy::kDropOldest;
  }
  if (name == "dropNewest") {
    return OverflowPolicy::kDropNewest;
  }
  return OverflowPolicy::kFailCapture;
}

flutter::EncodableValue FrameToValue(int64_t session_id,
                                     const CapturedFrame& frame) {
  // Interleaved float32, little-endian. Windows is little-endian on every
  // architecture Flutter targets, so a raw copy is already in wire order.
  const auto* bytes = reinterpret_cast<const uint8_t*>(frame.samples.data());
  std::vector<uint8_t> payload(
      bytes, bytes + frame.samples.size() * sizeof(float));

  flutter::EncodableMap map;
  map[flutter::EncodableValue("sessionId")] =
      flutter::EncodableValue(session_id);
  map[flutter::EncodableValue("sequence")] =
      flutter::EncodableValue(frame.sequence);
  map[flutter::EncodableValue("sampleOffset")] =
      flutter::EncodableValue(frame.sample_offset);
  map[flutter::EncodableValue("timestampMicros")] =
      flutter::EncodableValue(frame.timestamp_micros);
  map[flutter::EncodableValue("droppedFramesBefore")] =
      flutter::EncodableValue(frame.dropped_frames_before);
  map[flutter::EncodableValue("samples")] =
      flutter::EncodableValue(std::move(payload));
  return flutter::EncodableValue(std::move(map));
}

}  // namespace

void AudioFlutterWindowsPlugin::RegisterWithRegistrar(
    flutter::PluginRegistrarWindows* registrar) {
  registrar->AddPlugin(std::make_unique<AudioFlutterWindowsPlugin>(registrar));
}

AudioFlutterWindowsPlugin::AudioFlutterWindowsPlugin(
    flutter::PluginRegistrarWindows* registrar)
    : registrar_(registrar) {
  auto* messenger = registrar->messenger();

  method_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          messenger, kMethodChannelName,
          &flutter::StandardMethodCodec::GetInstance());
  method_channel_->SetMethodCallHandler(
      [this](const auto& call, auto result) {
        HandleMethodCall(call, std::move(result));
      });

  event_channel_ =
      std::make_unique<flutter::EventChannel<flutter::EncodableValue>>(
          messenger, kEventChannelName,
          &flutter::StandardMethodCodec::GetInstance());
  event_channel_->SetStreamHandler(
      std::make_unique<flutter::StreamHandlerFunctions<flutter::EncodableValue>>(
          [this](const flutter::EncodableValue*,
                 std::unique_ptr<flutter::EventSink<flutter::EncodableValue>>&&
                     events)
              -> std::unique_ptr<
                  flutter::StreamHandlerError<flutter::EncodableValue>> {
            event_sink_ = std::move(events);
            return nullptr;
          },
          [this](const flutter::EncodableValue*)
              -> std::unique_ptr<
                  flutter::StreamHandlerError<flutter::EncodableValue>> {
            event_sink_.reset();
            return nullptr;
          }));

  workers_.reserve(kWorkerCount);
  for (size_t index = 0; index < kWorkerCount; ++index) {
    workers_.emplace_back([this]() {
      for (;;) {
        std::function<void()> task;
        {
          std::unique_lock<std::mutex> lock(work_mutex_);
          work_available_.wait(
              lock, [this] { return workers_stopping_ || !work_.empty(); });
          if (work_.empty()) {
            return;
          }
          task = std::move(work_.front());
          work_.pop();
        }
        task();
      }
    });
  }

  window_proc_id_ = registrar_->RegisterTopLevelWindowProcDelegate(
      [this](HWND, UINT message, WPARAM, LPARAM) -> std::optional<LRESULT> {
        if (message == WM_AFW_RUN_TASK) {
          DrainPlatformTasks();
          return 0;
        }
        return std::nullopt;
      });
}

AudioFlutterWindowsPlugin::~AudioFlutterWindowsPlugin() {
  if (window_proc_id_ != -1) {
    registrar_->UnregisterTopLevelWindowProcDelegate(window_proc_id_);
  }
  // Wake whatever the workers are blocked in before joining them. A playback
  // write waits for buffer space with no timeout at all, and both waits are
  // released by stopping the session — so the sessions are aborted first,
  // while they still exist, and destroyed once no worker can touch them.
  // Joining first would wait on a writer that nothing has told to stop.
  {
    std::lock_guard<std::mutex> lock(sessions_mutex_);
    for (auto& entry : captures_) {
      entry.second->Abort();
    }
    for (auto& entry : playbacks_) {
      entry.second->Abort();
    }
  }
  // Workers run tasks that touch the sessions and the channels, so they are
  // drained and joined before either goes away. Queued work is allowed to
  // finish: a task abandoned mid-flight is one that never answers its call,
  // and its `MethodResult` would be destroyed with the reply still owed.
  {
    std::lock_guard<std::mutex> lock(work_mutex_);
    workers_stopping_ = true;
  }
  work_available_.notify_all();
  for (std::thread& worker : workers_) {
    if (worker.joinable()) {
      worker.join();
    }
  }
  workers_.clear();
  // Sessions own threads that call back into this plugin; drop them before the
  // channels and task queue disappear.
  std::lock_guard<std::mutex> lock(sessions_mutex_);
  captures_.clear();
  playbacks_.clear();
}

void AudioFlutterWindowsPlugin::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& method_call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const std::string& method = method_call.method_name();
  const flutter::EncodableMap* arguments = MapArguments(method_call);
  const flutter::EncodableMap empty;
  const flutter::EncodableMap& args = arguments ? *arguments : empty;

  if (method == "prepareCapture") {
    PrepareCapture(args, std::move(result));
    return;
  }
  if (method == "startCapture") {
    std::shared_ptr<CaptureSession> session = FindCapture(args);
    if (session == nullptr) {
      result->Error("SessionNotFound", "no such capture session");
      return;
    }
    std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>> reply(
        std::move(result));
    RunOffPlatformThread([this, session, reply]() {
      std::string error;
      const bool started = session->Start(&error);
      RunOnPlatformThread([reply, started, error]() {
        if (started) {
          reply->Success();
        } else {
          reply->Error("CaptureFailed", error);
        }
      });
    });
    return;
  }
  if (method == "readCaptureFrames") {
    ReadCaptureFrames(args, std::move(result));
    return;
  }
  if (method == "stopCapture" || method == "abortCapture") {
    std::shared_ptr<CaptureSession> session = FindCapture(args);
    if (session == nullptr) {
      result->Error("SessionNotFound", "no such capture session");
      return;
    }
    // Both join the capture thread, which is mid-poll and only notices the
    // stop request between its 5 ms sleeps.
    const bool graceful = method == "stopCapture";
    std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>> reply(
        std::move(result));
    RunOffPlatformThread([this, session, graceful, reply]() {
      if (graceful) {
        session->Stop();
      } else {
        session->Abort();
      }
      RunOnPlatformThread([reply]() { reply->Success(); });
    });
    return;
  }
  if (method == "disposeCapture") {
    const int64_t session_id = IntArg(args, "sessionId", 0);
    std::shared_ptr<CaptureSession> session;
    {
      std::lock_guard<std::mutex> lock(sessions_mutex_);
      const auto it = captures_.find(session_id);
      if (it != captures_.end()) {
        session = std::move(it->second);
        captures_.erase(it);
      }
    }
    // Removed from the registry on the platform thread, so a later call cannot
    // find a session being torn down, but released on a worker: the destructor
    // joins the capture thread, and a read still in flight holds its own
    // reference, so whichever finishes last does the destroying.
    std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>> reply(
        std::move(result));
    RunOffPlatformThread([this, session = std::move(session), reply]() mutable {
      session.reset();
      RunOnPlatformThread([reply]() { reply->Success(); });
    });
    return;
  }

  if (method == "isSystemAudioCaptureSupported" ||
      method == "requestSystemAudioCapturePermission") {
    // Shared-mode loopback on a render endpoint needs no grant and no minimum
    // OS version beyond the one Flutter already requires.
    result->Success(flutter::EncodableValue(true));
    return;
  }
  if (method == "isProcessAudioCaptureSupported") {
    result->Success(flutter::EncodableValue(IsProcessLoopbackSupported()));
    return;
  }
  if (method == "listAudioInputDevices" || method == "listSystemAudioSources") {
    // Endpoint enumeration opens every device's property store for its name.
    const EDataFlow flow =
        method == "listAudioInputDevices" ? eCapture : eRender;
    std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>> reply(
        std::move(result));
    RunOffPlatformThread([this, flow, reply]() {
      flutter::EncodableValue endpoints = ListEndpoints(flow);
      RunOnPlatformThread(
          [reply, endpoints = std::move(endpoints)]() mutable {
            reply->Success(std::move(endpoints));
          });
    });
    return;
  }
  if (method == "listAudioProcesses") {
    // Walks every render session on the default endpoint and resolves each
    // owning process, which is a registry and process-handle round trip apiece.
    std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>> reply(
        std::move(result));
    RunOffPlatformThread([this, reply]() {
      flutter::EncodableList encoded;
      for (const AudioProcessInfo& process : ListAudioRenderProcesses()) {
        flutter::EncodableMap entry;
        entry[flutter::EncodableValue("processId")] =
            flutter::EncodableValue(static_cast<int64_t>(process.process_id));
        entry[flutter::EncodableValue("bundleId")] =
            flutter::EncodableValue(process.application_id);
        entry[flutter::EncodableValue("isProducingAudio")] =
            flutter::EncodableValue(process.is_producing_audio);
        encoded.push_back(flutter::EncodableValue(std::move(entry)));
      }
      RunOnPlatformThread([reply, encoded = std::move(encoded)]() mutable {
        reply->Success(flutter::EncodableValue(std::move(encoded)));
      });
    });
    return;
  }
  if (method == "preparePlayback") {
    PreparePlayback(args, std::move(result));
    return;
  }
  if (method == "startPlayback") {
    std::shared_ptr<PlaybackSession> session = FindPlayback(args);
    if (session == nullptr) {
      result->Error("SessionNotFound", "no such playback session");
      return;
    }
    std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>> reply(
        std::move(result));
    RunOffPlatformThread([this, session, reply]() {
      std::string error;
      const bool started = session->Start(&error);
      RunOnPlatformThread([reply, started, error]() {
        if (started) {
          reply->Success();
        } else {
          reply->Error("PlaybackFailed", error);
        }
      });
    });
    return;
  }
  if (method == "writePlaybackFrames") {
    WritePlaybackFrames(args, std::move(result));
    return;
  }
  if (method == "finishPlayback" || method == "abortPlayback") {
    std::shared_ptr<PlaybackSession> session = FindPlayback(args);
    if (session == nullptr) {
      result->Error("SessionNotFound", "no such playback session");
      return;
    }
    // `Finish` drains the render buffer before returning, so it blocks for as
    // long as there is audio left to play.
    const bool graceful = method == "finishPlayback";
    std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>> reply(
        std::move(result));
    RunOffPlatformThread([this, session, graceful, reply]() {
      if (graceful) {
        session->Finish();
      } else {
        session->Abort();
      }
      RunOnPlatformThread([reply]() { reply->Success(); });
    });
    return;
  }
  if (method == "disposePlayback") {
    const int64_t session_id = IntArg(args, "sessionId", 0);
    std::shared_ptr<PlaybackSession> session;
    {
      std::lock_guard<std::mutex> lock(sessions_mutex_);
      const auto it = playbacks_.find(session_id);
      if (it != playbacks_.end()) {
        session = std::move(it->second);
        playbacks_.erase(it);
      }
    }
    std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>> reply(
        std::move(result));
    RunOffPlatformThread([this, session = std::move(session), reply]() mutable {
      session.reset();
      RunOnPlatformThread([reply]() { reply->Success(); });
    });
    return;
  }

  result->NotImplemented();
}

void AudioFlutterWindowsPlugin::PrepareCapture(
    const flutter::EncodableMap& arguments,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  CaptureConfig config;
  config.kind = StringArg(arguments, "kind") == "microphone"
                    ? CaptureKind::kMicrophone
                    : CaptureKind::kSystemAudio;
  config.sample_rate = static_cast<int>(IntArg(arguments, "sampleRate", 16000));
  config.channel_count =
      static_cast<int>(IntArg(arguments, "channelCount", 1));
  config.frame_duration_micros =
      IntArg(arguments, "frameDurationMicros", 100000);
  config.max_buffered_duration_micros =
      IntArg(arguments, "maxBufferedDurationMicros", 2000000);
  config.overflow_policy =
      ParseOverflowPolicy(StringArg(arguments, "overflowPolicy"));
  config.endpoint_id = StringArg(arguments, "inputDeviceId");
  config.voice_processing = BoolArg(arguments, "voiceProcessing", false);
  config.process_ids = ProcessIdsArg(arguments, "processIds");

  const flutter::EncodableValue* encoded_process_ids =
      Find(arguments, "processIds");
  const auto* requested_process_ids = encoded_process_ids == nullptr
                                          ? nullptr
                                          : std::get_if<flutter::EncodableList>(
                                                encoded_process_ids);
  if (encoded_process_ids != nullptr && requested_process_ids == nullptr) {
    result->Error("InvalidProcessIds", "processIds must be a list");
    return;
  }
  if (requested_process_ids != nullptr && !requested_process_ids->empty() &&
      config.process_ids.empty()) {
    result->Error("InvalidProcessIds",
                  "processIds must contain unique positive 32-bit values");
    return;
  }

  if (config.sample_rate <= 0 || config.channel_count <= 0) {
    result->Error("InvalidFormat", "sample rate and channels must be positive");
    return;
  }

  int64_t session_id = 0;
  std::shared_ptr<CaptureSession> session;
  {
    std::lock_guard<std::mutex> lock(sessions_mutex_);
    session_id = next_session_id_++;
    session = std::make_shared<CaptureSession>(
        session_id, config,
        [this](SessionEvent event) { PostEvent(std::move(event)); });
    captures_[session_id] = session;
  }

  // `Prepare` initialises COM, enumerates endpoints and opens the chosen one's
  // property store; it is the reason a capture start visibly stutters the UI.
  std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>> reply(
      std::move(result));
  RunOffPlatformThread([this, session, session_id, config, reply]() {
    std::string error;
    if (!session->Prepare(&error)) {
      {
        std::lock_guard<std::mutex> lock(sessions_mutex_);
        captures_.erase(session_id);
      }
      RunOnPlatformThread([reply, error]() {
        reply->Error("CaptureFailed", error);
      });
      return;
    }
    RunOnPlatformThread([this, reply, session, session_id, config]() {
      ReplyWithCaptureInfo(reply, *session, session_id, config);
    });
  });
}

// Builds the prepared-session reply. Split out so `PrepareCapture` can send it
// from the platform thread after the work has run on a worker.
void AudioFlutterWindowsPlugin::ReplyWithCaptureInfo(
    const std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>>&
        result,
    const CaptureSession& session, int64_t session_id,
    const CaptureConfig& config) {
  flutter::EncodableMap info;
  info[flutter::EncodableValue("sessionId")] =
      flutter::EncodableValue(session_id);
  info[flutter::EncodableValue("sourceId")] =
      flutter::EncodableValue(session.source_id());
  info[flutter::EncodableValue("trackId")] = flutter::EncodableValue(
      config.kind == CaptureKind::kMicrophone ? "microphone" : "systemAudio");
  info[flutter::EncodableValue("clockId")] =
      flutter::EncodableValue("windows.qpc");
  info[flutter::EncodableValue("timingQuality")] =
      flutter::EncodableValue("nativeMapped");
  info[flutter::EncodableValue("sampleRate")] =
      flutter::EncodableValue(config.sample_rate);
  info[flutter::EncodableValue("channelCount")] =
      flutter::EncodableValue(config.channel_count);
  result->Success(flutter::EncodableValue(std::move(info)));
}

void AudioFlutterWindowsPlugin::ReadCaptureFrames(
    const flutter::EncodableMap& arguments,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  std::shared_ptr<CaptureSession> session = FindCapture(arguments);
  if (session == nullptr) {
    result->Error("SessionNotFound", "no such capture session");
    return;
  }
  const auto max_frames =
      static_cast<size_t>(std::max<int64_t>(0, IntArg(arguments, "maxFrames", 8)));
  const int64_t timeout_millis = IntArg(arguments, "timeoutMillis", 500);

  // The read waits on the frame ring for up to its full timeout, and Dart pulls
  // continuously for as long as the capture runs. This is the call that has to
  // leave the platform thread: the others stall the window at a device change,
  // this one stalls it permanently.
  std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>> reply(
      std::move(result));
  RunOffPlatformThread([this, session, max_frames, timeout_millis, reply]() {
    std::vector<CapturedFrame> frames;
    bool end_of_stream = false;
    session->Read(max_frames, timeout_millis, &frames, &end_of_stream);

    flutter::EncodableList encoded;
    encoded.reserve(frames.size());
    for (const CapturedFrame& frame : frames) {
      encoded.push_back(FrameToValue(session->session_id(), frame));
    }

    flutter::EncodableMap batch;
    batch[flutter::EncodableValue("frames")] =
        flutter::EncodableValue(std::move(encoded));
    batch[flutter::EncodableValue("endOfStream")] =
        flutter::EncodableValue(end_of_stream);
    RunOnPlatformThread([reply, batch = std::move(batch)]() mutable {
      reply->Success(flutter::EncodableValue(std::move(batch)));
    });
  });
}

void AudioFlutterWindowsPlugin::PreparePlayback(
    const flutter::EncodableMap& arguments,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  PlaybackConfig config;
  config.sample_rate = static_cast<int>(IntArg(arguments, "sampleRate", 16000));
  config.channel_count =
      static_cast<int>(IntArg(arguments, "channelCount", 1));
  config.max_buffered_duration_micros =
      IntArg(arguments, "maxBufferedDurationMicros", 2000000);

  if (config.sample_rate <= 0 || config.channel_count <= 0) {
    result->Error("InvalidFormat", "sample rate and channels must be positive");
    return;
  }

  int64_t session_id = 0;
  std::shared_ptr<PlaybackSession> session;
  {
    std::lock_guard<std::mutex> lock(sessions_mutex_);
    session_id = next_session_id_++;
    session = std::make_shared<PlaybackSession>(
        session_id, config,
        [this](SessionEvent event) { PostEvent(std::move(event)); });
    playbacks_[session_id] = session;
  }

  // Opens the render endpoint, which is the same COM and device work a capture
  // prepare does.
  std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>> reply(
      std::move(result));
  RunOffPlatformThread([this, session, session_id, config, reply]() {
    std::string error;
    if (!session->Prepare(&error)) {
      {
        std::lock_guard<std::mutex> lock(sessions_mutex_);
        playbacks_.erase(session_id);
      }
      RunOnPlatformThread([reply, error]() {
        reply->Error("PlaybackFailed", error);
      });
      return;
    }
    flutter::EncodableMap info;
    info[flutter::EncodableValue("sessionId")] =
        flutter::EncodableValue(session_id);
    info[flutter::EncodableValue("clockId")] =
        flutter::EncodableValue("wasapi-render");
    info[flutter::EncodableValue("sampleRate")] =
        flutter::EncodableValue(config.sample_rate);
    info[flutter::EncodableValue("channelCount")] =
        flutter::EncodableValue(config.channel_count);
    RunOnPlatformThread([reply, info = std::move(info)]() mutable {
      reply->Success(flutter::EncodableValue(std::move(info)));
    });
  });
}

void AudioFlutterWindowsPlugin::WritePlaybackFrames(
    const flutter::EncodableMap& arguments,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  std::shared_ptr<PlaybackSession> session = FindPlayback(arguments);
  if (session == nullptr) {
    result->Error("SessionNotFound", "no such playback session");
    return;
  }

  const flutter::EncodableValue* frames_value = Find(arguments, "frames");
  const auto* frames =
      frames_value == nullptr
          ? nullptr
          : std::get_if<flutter::EncodableList>(frames_value);
  if (frames == nullptr) {
    result->Success();
    return;
  }

  std::vector<float> samples;
  for (const flutter::EncodableValue& entry : *frames) {
    const auto* frame = std::get_if<flutter::EncodableMap>(&entry);
    if (frame == nullptr) {
      continue;
    }
    const flutter::EncodableValue* payload_value = Find(*frame, "samples");
    if (payload_value == nullptr) {
      continue;
    }
    const auto* payload = std::get_if<std::vector<uint8_t>>(payload_value);
    if (payload == nullptr || payload->size() % sizeof(float) != 0) {
      continue;
    }
    const size_t count = payload->size() / sizeof(float);
    const size_t offset = samples.size();
    samples.resize(offset + count);
    std::memcpy(samples.data() + offset, payload->data(), payload->size());
  }

  // `Write` blocks while the render buffer is full, which is the steady state
  // of a playback that is keeping up.
  std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>> reply(
      std::move(result));
  RunOffPlatformThread(
      [this, session, samples = std::move(samples), reply]() mutable {
        session->Write(samples);
        RunOnPlatformThread([reply]() { reply->Success(); });
      });
}

flutter::EncodableValue AudioFlutterWindowsPlugin::ListEndpoints(
    EDataFlow flow) {
  flutter::EncodableList devices;

  ComApartment apartment;
  if (!apartment.ok()) {
    return flutter::EncodableValue(std::move(devices));
  }

  ComPtr<IMMDeviceEnumerator> enumerator;
  if (FAILED(::CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr,
                                CLSCTX_ALL, IID_PPV_ARGS(enumerator.put())))) {
    return flutter::EncodableValue(std::move(devices));
  }

  std::string default_id;
  {
    ComPtr<IMMDevice> default_device;
    if (SUCCEEDED(enumerator->GetDefaultAudioEndpoint(
            flow, eConsole, default_device.put())) &&
        default_device) {
      ComTaskMem<WCHAR> id;
      if (SUCCEEDED(default_device->GetId(id.put())) && id) {
        default_id = Utf8FromWide(id.get());
      }
    }
  }

  ComPtr<IMMDeviceCollection> collection;
  if (FAILED(enumerator->EnumAudioEndpoints(flow, DEVICE_STATE_ACTIVE,
                                            collection.put()))) {
    return flutter::EncodableValue(std::move(devices));
  }

  UINT count = 0;
  collection->GetCount(&count);
  for (UINT index = 0; index < count; ++index) {
    ComPtr<IMMDevice> device;
    if (FAILED(collection->Item(index, device.put())) || !device) {
      continue;
    }

    std::string endpoint_id;
    ComTaskMem<WCHAR> id;
    if (SUCCEEDED(device->GetId(id.put())) && id) {
      endpoint_id = Utf8FromWide(id.get());
    }
    if (endpoint_id.empty()) {
      continue;
    }

    std::string label = "Unknown audio device";
    ComPtr<IPropertyStore> properties;
    if (SUCCEEDED(device->OpenPropertyStore(STGM_READ, properties.put())) &&
        properties) {
      PROPVARIANT name;
      ::PropVariantInit(&name);
      if (SUCCEEDED(properties->GetValue(PKEY_Device_FriendlyName, &name)) &&
          name.vt == VT_LPWSTR) {
        label = Utf8FromWide(name.pwszVal);
      }
      ::PropVariantClear(&name);
    }

    flutter::EncodableMap entry;
    entry[flutter::EncodableValue("id")] = flutter::EncodableValue(endpoint_id);
    entry[flutter::EncodableValue("label")] = flutter::EncodableValue(label);
    entry[flutter::EncodableValue("isDefault")] =
        flutter::EncodableValue(endpoint_id == default_id);
    devices.push_back(flutter::EncodableValue(std::move(entry)));
  }

  return flutter::EncodableValue(std::move(devices));
}

std::shared_ptr<CaptureSession> AudioFlutterWindowsPlugin::FindCapture(
    const flutter::EncodableMap& arguments) {
  const int64_t session_id = IntArg(arguments, "sessionId", 0);
  std::lock_guard<std::mutex> lock(sessions_mutex_);
  const auto it = captures_.find(session_id);
  return it == captures_.end() ? nullptr : it->second;
}

std::shared_ptr<PlaybackSession> AudioFlutterWindowsPlugin::FindPlayback(
    const flutter::EncodableMap& arguments) {
  const int64_t session_id = IntArg(arguments, "sessionId", 0);
  std::lock_guard<std::mutex> lock(sessions_mutex_);
  const auto it = playbacks_.find(session_id);
  return it == playbacks_.end() ? nullptr : it->second;
}

void AudioFlutterWindowsPlugin::PostEvent(SessionEvent event) {
  RunOnPlatformThread([this, event = std::move(event)]() {
    if (!event_sink_) {
      return;
    }
    flutter::EncodableMap map;
    map[flutter::EncodableValue("sessionId")] =
        flutter::EncodableValue(event.session_id);
    map[flutter::EncodableValue("phase")] =
        flutter::EncodableValue(PhaseName(event.phase));
    if (!event.code.empty()) {
      map[flutter::EncodableValue("code")] =
          flutter::EncodableValue(event.code);
    }
    if (!event.message.empty()) {
      map[flutter::EncodableValue("message")] =
          flutter::EncodableValue(event.message);
    }
    if (event.has_receiving_audio) {
      map[flutter::EncodableValue("receivingAudio")] =
          flutter::EncodableValue(event.receiving_audio);
    }
    event_sink_->Success(flutter::EncodableValue(std::move(map)));
  });
}

void AudioFlutterWindowsPlugin::RunOffPlatformThread(
    std::function<void()> task) {
  {
    std::lock_guard<std::mutex> lock(work_mutex_);
    if (workers_stopping_) {
      return;
    }
    work_.push(std::move(task));
  }
  work_available_.notify_one();
}

void AudioFlutterWindowsPlugin::RunOnPlatformThread(
    std::function<void()> task) {
  {
    std::lock_guard<std::mutex> lock(tasks_mutex_);
    tasks_.push(std::move(task));
  }
  if (HWND window = registrar_->GetView() == nullptr
                        ? nullptr
                        : registrar_->GetView()->GetNativeWindow()) {
    // GetNativeWindow() is the child Flutter view, whose window procedure
    // discards private messages. The top-level WindowProc delegate registered
    // in the constructor only sees messages sent to the root window, so post
    // there or the drain never runs and every offloaded reply is lost.
    ::PostMessage(::GetAncestor(window, GA_ROOT), WM_AFW_RUN_TASK, 0, 0);
  }
}

void AudioFlutterWindowsPlugin::DrainPlatformTasks() {
  std::queue<std::function<void()>> pending;
  {
    std::lock_guard<std::mutex> lock(tasks_mutex_);
    pending.swap(tasks_);
  }
  while (!pending.empty()) {
    pending.front()();
    pending.pop();
  }
}

}  // namespace audio_flutter_windows
