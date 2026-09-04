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
    CaptureSession* session = FindCapture(args);
    if (session == nullptr) {
      result->Error("SessionNotFound", "no such capture session");
      return;
    }
    std::string error;
    if (!session->Start(&error)) {
      result->Error("CaptureFailed", error);
      return;
    }
    result->Success();
    return;
  }
  if (method == "readCaptureFrames") {
    ReadCaptureFrames(args, std::move(result));
    return;
  }
  if (method == "stopCapture" || method == "abortCapture") {
    CaptureSession* session = FindCapture(args);
    if (session == nullptr) {
      result->Error("SessionNotFound", "no such capture session");
      return;
    }
    if (method == "stopCapture") {
      session->Stop();
    } else {
      session->Abort();
    }
    result->Success();
    return;
  }
  if (method == "disposeCapture") {
    const int64_t session_id = IntArg(args, "sessionId", 0);
    std::unique_ptr<CaptureSession> session;
    {
      std::lock_guard<std::mutex> lock(sessions_mutex_);
      const auto it = captures_.find(session_id);
      if (it != captures_.end()) {
        session = std::move(it->second);
        captures_.erase(it);
      }
    }
    // Destroyed outside the lock: the destructor joins the capture thread,
    // which may still be posting events.
    session.reset();
    result->Success();
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
  if (method == "listAudioInputDevices") {
    result->Success(ListEndpoints(eCapture));
    return;
  }
  if (method == "listSystemAudioSources") {
    result->Success(ListEndpoints(eRender));
    return;
  }
  if (method == "listAudioProcesses") {
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
    result->Success(flutter::EncodableValue(std::move(encoded)));
    return;
  }

  if (method == "preparePlayback") {
    PreparePlayback(args, std::move(result));
    return;
  }
  if (method == "startPlayback") {
    PlaybackSession* session = FindPlayback(args);
    if (session == nullptr) {
      result->Error("SessionNotFound", "no such playback session");
      return;
    }
    std::string error;
    if (!session->Start(&error)) {
      result->Error("PlaybackFailed", error);
      return;
    }
    result->Success();
    return;
  }
  if (method == "writePlaybackFrames") {
    WritePlaybackFrames(args, std::move(result));
    return;
  }
  if (method == "finishPlayback" || method == "abortPlayback") {
    PlaybackSession* session = FindPlayback(args);
    if (session == nullptr) {
      result->Error("SessionNotFound", "no such playback session");
      return;
    }
    if (method == "finishPlayback") {
      session->Finish();
    } else {
      session->Abort();
    }
    result->Success();
    return;
  }
  if (method == "disposePlayback") {
    const int64_t session_id = IntArg(args, "sessionId", 0);
    std::unique_ptr<PlaybackSession> session;
    {
      std::lock_guard<std::mutex> lock(sessions_mutex_);
      const auto it = playbacks_.find(session_id);
      if (it != playbacks_.end()) {
        session = std::move(it->second);
        playbacks_.erase(it);
      }
    }
    session.reset();
    result->Success();
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
  CaptureSession* session = nullptr;
  {
    std::lock_guard<std::mutex> lock(sessions_mutex_);
    session_id = next_session_id_++;
    auto owned = std::make_unique<CaptureSession>(
        session_id, config,
        [this](SessionEvent event) { PostEvent(std::move(event)); });
    session = owned.get();
    captures_[session_id] = std::move(owned);
  }

  std::string error;
  if (!session->Prepare(&error)) {
    {
      std::lock_guard<std::mutex> lock(sessions_mutex_);
      captures_.erase(session_id);
    }
    result->Error("CaptureFailed", error);
    return;
  }

  flutter::EncodableMap info;
  info[flutter::EncodableValue("sessionId")] =
      flutter::EncodableValue(session_id);
  info[flutter::EncodableValue("sourceId")] =
      flutter::EncodableValue(session->source_id());
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
  CaptureSession* session = FindCapture(arguments);
  if (session == nullptr) {
    result->Error("SessionNotFound", "no such capture session");
    return;
  }
  const auto max_frames =
      static_cast<size_t>(std::max<int64_t>(0, IntArg(arguments, "maxFrames", 8)));
  const int64_t timeout_millis = IntArg(arguments, "timeoutMillis", 500);

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
  result->Success(flutter::EncodableValue(std::move(batch)));
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
  PlaybackSession* session = nullptr;
  {
    std::lock_guard<std::mutex> lock(sessions_mutex_);
    session_id = next_session_id_++;
    auto owned = std::make_unique<PlaybackSession>(
        session_id, config,
        [this](SessionEvent event) { PostEvent(std::move(event)); });
    session = owned.get();
    playbacks_[session_id] = std::move(owned);
  }

  std::string error;
  if (!session->Prepare(&error)) {
    {
      std::lock_guard<std::mutex> lock(sessions_mutex_);
      playbacks_.erase(session_id);
    }
    result->Error("PlaybackFailed", error);
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
  result->Success(flutter::EncodableValue(std::move(info)));
}

void AudioFlutterWindowsPlugin::WritePlaybackFrames(
    const flutter::EncodableMap& arguments,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  PlaybackSession* session = FindPlayback(arguments);
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

  session->Write(samples);
  result->Success();
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

CaptureSession* AudioFlutterWindowsPlugin::FindCapture(
    const flutter::EncodableMap& arguments) {
  const int64_t session_id = IntArg(arguments, "sessionId", 0);
  std::lock_guard<std::mutex> lock(sessions_mutex_);
  const auto it = captures_.find(session_id);
  return it == captures_.end() ? nullptr : it->second.get();
}

PlaybackSession* AudioFlutterWindowsPlugin::FindPlayback(
    const flutter::EncodableMap& arguments) {
  const int64_t session_id = IntArg(arguments, "sessionId", 0);
  std::lock_guard<std::mutex> lock(sessions_mutex_);
  const auto it = playbacks_.find(session_id);
  return it == playbacks_.end() ? nullptr : it->second.get();
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

void AudioFlutterWindowsPlugin::RunOnPlatformThread(
    std::function<void()> task) {
  {
    std::lock_guard<std::mutex> lock(tasks_mutex_);
    tasks_.push(std::move(task));
  }
  if (HWND window = registrar_->GetView() == nullptr
                        ? nullptr
                        : registrar_->GetView()->GetNativeWindow()) {
    ::PostMessage(window, WM_AFW_RUN_TASK, 0, 0);
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
