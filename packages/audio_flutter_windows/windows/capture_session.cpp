#include "capture_session.h"

// WASAPI / Core Audio.
//
// Order matters and must NOT be alphabetized: <mmdeviceapi.h> pulls in the
// PROPERTYKEY infrastructure (propsys.h -> propkeydef.h) that defines the
// DEFINE_PROPERTYKEY macro. As of Windows SDK 10.0.26100 the
// <functiondiscoverykeys_devpkey.h> header no longer self-includes it, so it
// must come AFTER <mmdeviceapi.h> or every PKEY_* line fails to compile.
// clang-format off
#include <audioclient.h>
#include <avrt.h>
#include <mmdeviceapi.h>
#include <functiondiscoverykeys_devpkey.h>  // PKEY_Device_FriendlyName
// clang-format on

#include <algorithm>
#include <chrono>
#include <cstddef>
#include <system_error>
#include <utility>

#include "audio_format.h"
#include "com_utils.h"
#include "process_loopback_capture.h"
#include "voice_capture_dsp.h"

namespace audio_flutter_windows {

namespace {

// REFERENCE_TIME units are 100-ns intervals; 10,000,000 == one second.
constexpr REFERENCE_TIME kRefTimesPerSecond = 10000000;

// Requested endpoint buffer. The endpoint allocates at least this much and the
// poll loop reads whatever has accumulated.
constexpr REFERENCE_TIME kRequestedBufferDuration = kRefTimesPerSecond / 5;

// A capture that delivers no audio for this long is reported as dead. A tap can
// initialise cleanly and never produce a packet; only observing frames proves
// the path works.
constexpr int64_t kStallTimeoutMillis = 2000;

int64_t NowMillis() {
  return std::chrono::duration_cast<std::chrono::milliseconds>(
             std::chrono::steady_clock::now().time_since_epoch())
      .count();
}

// Puts a capture stream in the category Windows reserves for calls.
bool ApplyCommunicationsCategory(IAudioClient* client) {
  ComPtr<IAudioClient2> client2;
  if (FAILED(client->QueryInterface(IID_PPV_ARGS(client2.put()))) || !client2) {
    return false;
  }
  AudioClientProperties properties = {};
  properties.cbSize = sizeof(AudioClientProperties);
  properties.bIsOffload = FALSE;
  properties.eCategory = AudioCategory_Communications;
  properties.Options = AUDCLNT_STREAMOPTIONS_NONE;
  return SUCCEEDED(client2->SetClientProperties(&properties));
}

// Whether the endpoint itself cancels echo, so far as Windows will say.
bool EndpointCancelsEcho(IMMDevice* device) {
#ifdef __IAudioEffectsManager_INTERFACE_DEFINED__
  ComPtr<IAudioEffectsManager> effects_manager;
  if (FAILED(device->Activate(__uuidof(IAudioEffectsManager), CLSCTX_ALL,
                              nullptr,
                              reinterpret_cast<void**>(
                                  effects_manager.put()))) ||
      !effects_manager) {
    return false;
  }
  AUDIO_EFFECT* effects = nullptr;
  UINT32 effect_count = 0;
  if (FAILED(effects_manager->GetAudioEffects(&effects, &effect_count)) ||
      effects == nullptr) {
    return false;
  }
  bool cancels = false;
  for (UINT32 index = 0; index < effect_count; ++index) {
    if (effects[index].id ==
            AUDIO_EFFECT_TYPE_ACOUSTIC_ECHO_CANCELLATION &&
        effects[index].state == AUDIO_EFFECT_STATE_ON) {
      cancels = true;
      break;
    }
  }
  ::CoTaskMemFree(effects);
  return cancels;
#else
  (void)device;
  return false;
#endif
}

int64_t QpcNowMicros() {
  LARGE_INTEGER counter = {};
  LARGE_INTEGER frequency = {};
  if (!::QueryPerformanceCounter(&counter) ||
      !::QueryPerformanceFrequency(&frequency) || frequency.QuadPart <= 0) {
    return NowMillis() * 1000;
  }
  const long double micros =
      static_cast<long double>(counter.QuadPart) * 1000000.0L /
      static_cast<long double>(frequency.QuadPart);
  return static_cast<int64_t>(micros);
}

}  // namespace

const char* PhaseName(SessionPhase phase) {
  switch (phase) {
    case SessionPhase::kPrepared:
      return "prepared";
    case SessionPhase::kStarting:
      return "starting";
    case SessionPhase::kRunning:
      return "running";
    case SessionPhase::kInterrupted:
      return "interrupted";
    case SessionPhase::kStopping:
      return "stopping";
    case SessionPhase::kStopped:
      return "stopped";
    case SessionPhase::kFailed:
      return "failed";
  }
  return "failed";
}

CaptureSession::CaptureSession(int64_t session_id, CaptureConfig config,
                               EventCallback on_event)
    : session_id_(session_id),
      config_(std::move(config)),
      on_event_(std::move(on_event)) {
  const int64_t frame_micros =
      config_.frame_duration_micros > 0 ? config_.frame_duration_micros : 100000;
  const int64_t capacity =
      config_.max_buffered_duration_micros > 0
          ? config_.max_buffered_duration_micros / frame_micros
          : 1;
  ring_.Configure(static_cast<size_t>(std::max<int64_t>(1, capacity)),
                  config_.overflow_policy);
}

CaptureSession::~CaptureSession() {
  stop_requested_.store(true);
  JoinThread();
}

bool CaptureSession::Prepare(std::string* error) {
  if (!config_.process_ids.empty()) {
    if (config_.kind != CaptureKind::kSystemAudio) {
      if (error != nullptr) {
        *error = "process loopback is valid only for system-audio capture";
      }
      return false;
    }
    if (!config_.endpoint_id.empty()) {
      if (error != nullptr) {
        *error = "process loopback cannot also select a render endpoint";
      }
      return false;
    }
    if (!IsProcessLoopbackSupported()) {
      if (error != nullptr) {
        *error = "process loopback requires Windows OS build 20348 or newer";
      }
      return false;
    }
    source_id_ = "process:";
    for (size_t index = 0; index < config_.process_ids.size(); ++index) {
      if (index != 0) {
        source_id_ += ',';
      }
      source_id_ += std::to_string(config_.process_ids[index]);
    }
    Emit(SessionPhase::kPrepared);
    return true;
  }

  ComApartment apartment;
  if (!apartment.ok()) {
    if (error != nullptr) {
      *error = "COM could not be initialised on this thread";
    }
    return false;
  }

  ComPtr<IMMDeviceEnumerator> enumerator;
  HRESULT hr = ::CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr,
                                  CLSCTX_ALL, IID_PPV_ARGS(enumerator.put()));
  if (FAILED(hr)) {
    if (error != nullptr) {
      *error = "MMDeviceEnumerator unavailable";
    }
    return false;
  }

  // Loopback taps a render endpoint; microphone capture opens a capture
  // endpoint. Both resolve to an IMMDevice the same way.
  const EDataFlow flow =
      config_.kind == CaptureKind::kSystemAudio ? eRender : eCapture;

  ComPtr<IMMDevice> device;
  if (config_.endpoint_id.empty()) {
    hr = enumerator->GetDefaultAudioEndpoint(flow, eConsole, device.put());
  } else {
    const std::wstring wide = WideFromUtf8(config_.endpoint_id);
    hr = enumerator->GetDevice(wide.c_str(), device.put());
    if (FAILED(hr)) {
      // A requested endpoint that has since disappeared should not strand the
      // session; fall back to the current default.
      hr = enumerator->GetDefaultAudioEndpoint(flow, eConsole, device.put());
    }
  }
  if (FAILED(hr) || !device) {
    if (error != nullptr) {
      *error = "no audio endpoint available";
    }
    return false;
  }

  ComTaskMem<WCHAR> endpoint_id;
  if (SUCCEEDED(device->GetId(endpoint_id.put())) && endpoint_id) {
    source_id_ = Utf8FromWide(endpoint_id.get());
  } else {
    source_id_ = config_.kind == CaptureKind::kSystemAudio ? "render:default"
                                                           : "capture:default";
  }

  Emit(SessionPhase::kPrepared);
  return true;
}

bool CaptureSession::Start(std::string* error) {
  if (running_.load()) {
    return true;
  }
  stop_requested_.store(false);
  finished_.store(false);
  running_.store(true);
  Emit(SessionPhase::kStarting);
  try {
    thread_ = std::thread(&CaptureSession::CaptureThreadMain, this);
  } catch (const std::system_error&) {
    running_.store(false);
    if (error != nullptr) {
      *error = "capture thread could not be started";
    }
    return false;
  }
  return true;
}

void CaptureSession::Read(size_t max_frames, int64_t timeout_millis,
                          std::vector<CapturedFrame>* out,
                          bool* end_of_stream) {
  std::unique_lock<std::mutex> lock(mutex_);
  if (ring_.Empty() && !finished_.load() && timeout_millis > 0) {
    frames_available_.wait_for(lock,
                               std::chrono::milliseconds(timeout_millis),
                               [this] {
                                 return !ring_.Empty() || finished_.load();
                               });
  }
  ring_.Take(max_frames, out);
  if (end_of_stream != nullptr) {
    *end_of_stream = finished_.load() && ring_.Empty();
  }
}

void CaptureSession::Stop() {
  if (!running_.load() && !thread_.joinable()) {
    return;
  }
  Emit(SessionPhase::kStopping);
  stop_requested_.store(true);
  JoinThread();
  running_.store(false);
  Emit(SessionPhase::kStopped);
}

void CaptureSession::Abort() {
  stop_requested_.store(true);
  JoinThread();
  running_.store(false);
  {
    std::lock_guard<std::mutex> lock(mutex_);
    ring_.Clear();
  }
  Emit(SessionPhase::kStopped);
}

void CaptureSession::JoinThread() {
  if (thread_.joinable()) {
    thread_.join();
  }
  finished_.store(true);
  frames_available_.notify_all();
}

void CaptureSession::Emit(SessionPhase phase, const std::string& code,
                          const std::string& message) {
  if (!on_event_) {
    return;
  }
  SessionEvent event;
  event.session_id = session_id_;
  event.phase = phase;
  event.code = code;
  event.message = message;
  event.has_receiving_audio = true;
  event.receiving_audio = received_any_audio_.load();
  on_event_(std::move(event));
}

void CaptureSession::Fail(const std::string& code, const std::string& message) {
  finished_.store(true);
  frames_available_.notify_all();
  Emit(SessionPhase::kFailed, code, message);
}

void CaptureSession::CaptureThreadMain() {
  if (!config_.process_ids.empty()) {
    ProcessCaptureThreadMain();
    return;
  }

  ComApartment apartment;
  if (!apartment.ok()) {
    Fail("CaptureFailed", "COM could not be initialised on the capture thread");
    running_.store(false);
    return;
  }

  ComPtr<IMMDeviceEnumerator> enumerator;
  HRESULT hr = ::CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr,
                                  CLSCTX_ALL, IID_PPV_ARGS(enumerator.put()));
  if (FAILED(hr)) {
    Fail("CaptureFailed", "MMDeviceEnumerator unavailable");
    running_.store(false);
    return;
  }

  const EDataFlow flow =
      config_.kind == CaptureKind::kSystemAudio ? eRender : eCapture;
  ComPtr<IMMDevice> device;
  if (config_.endpoint_id.empty()) {
    hr = enumerator->GetDefaultAudioEndpoint(flow, eConsole, device.put());
  } else {
    const std::wstring wide = WideFromUtf8(config_.endpoint_id);
    hr = enumerator->GetDevice(wide.c_str(), device.put());
    if (FAILED(hr)) {
      hr = enumerator->GetDefaultAudioEndpoint(flow, eConsole, device.put());
    }
  }
  if (FAILED(hr) || !device) {
    Fail("CaptureFailed", "no audio endpoint available");
    running_.store(false);
    return;
  }

  // A DSP that could not be created has already reported itself and handed the
  // capture back here; the endpoint stream is what is left, so the handover is
  // not offered a second time.
  const bool echo_cancelled = config_.kind == CaptureKind::kMicrophone &&
                              config_.voice_processing &&
                              !echo_cancellation_declined_.load();
  if (echo_cancelled && !EndpointCancelsEcho(device.get())) {
    // Nothing on the endpoint will remove the speakers from this microphone,
    // so the capture is handed to the DSP that will.
    EchoCancelledCaptureThreadMain();
    return;
  }

  ComPtr<IAudioClient> audio_client;
  hr = device->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr,
                        reinterpret_cast<void**>(audio_client.put()));
  if (FAILED(hr)) {
    Fail("CaptureFailed", "IAudioClient activation failed");
    running_.store(false);
    return;
  }

  if (echo_cancelled && !ApplyCommunicationsCategory(audio_client.get())) {
    // The endpoint reported a canceller a moment ago but will not take the
    // category that runs it, so the stream would be raw after all.
    EchoCancelledCaptureThreadMain();
    return;
  }

  // The capture buffer arrives in the endpoint's mix format; that is the actual
  // source format to convert from, and it must be read rather than assumed.
  ComTaskMem<WAVEFORMATEX> mix_format;
  hr = audio_client->GetMixFormat(mix_format.put());
  if (FAILED(hr) || !mix_format) {
    Fail("CaptureFailed", "endpoint mix format unavailable");
    running_.store(false);
    return;
  }

  // Loopback requires shared mode. The poll (non-event) buffering model works
  // on every supported Windows version and keeps stop latency bounded.
  const DWORD stream_flags = config_.kind == CaptureKind::kSystemAudio
                                 ? AUDCLNT_STREAMFLAGS_LOOPBACK
                                 : 0;
  hr = audio_client->Initialize(AUDCLNT_SHAREMODE_SHARED, stream_flags,
                                kRequestedBufferDuration, 0, mix_format.get(),
                                nullptr);
  if (FAILED(hr)) {
    Fail("CaptureFailed", "IAudioClient::Initialize failed");
    running_.store(false);
    return;
  }

  UINT32 buffer_frame_count = 0;
  hr = audio_client->GetBufferSize(&buffer_frame_count);
  if (FAILED(hr)) {
    Fail("CaptureFailed", "buffer size unavailable");
    running_.store(false);
    return;
  }

  ComPtr<IAudioCaptureClient> capture_client;
  hr = audio_client->GetService(__uuidof(IAudioCaptureClient),
                                reinterpret_cast<void**>(capture_client.put()));
  if (FAILED(hr) || !capture_client) {
    Fail("CaptureFailed", "IAudioCaptureClient unavailable");
    running_.store(false);
    return;
  }

  const WORD source_channels = mix_format->nChannels;
  const WORD source_bits = mix_format->wBitsPerSample;
  const DWORD source_rate = mix_format->nSamplesPerSec;
  const bool source_is_float = IsFloatFormat(mix_format.get());
  const bool source_is_pcm = IsPcmFormat(mix_format.get());

  if ((!source_is_float && !source_is_pcm) || source_channels == 0 ||
      source_bits == 0 || source_rate == 0) {
    Fail("CaptureFailed", "endpoint mix format cannot be interpreted");
    running_.store(false);
    return;
  }

  LinearResampler resampler;
  resampler.Reset(static_cast<double>(source_rate),
                  static_cast<double>(config_.sample_rate));

  // "Pro Audio" schedules the thread for low-latency capture. Failure is not
  // fatal, it just means ordinary scheduling.
  DWORD mmcss_task_index = 0;
  MmcssHandle mmcss(::AvSetMmThreadCharacteristicsW(L"Pro Audio",
                                                    &mmcss_task_index));

  // By the time half the endpoint buffer has elapsed there is work waiting.
  const double buffer_seconds = static_cast<double>(buffer_frame_count) /
                                static_cast<double>(source_rate);
  DWORD sleep_ms = static_cast<DWORD>(buffer_seconds * 1000.0 / 2.0);
  sleep_ms = std::max<DWORD>(5, std::min<DWORD>(100, sleep_ms));

  hr = audio_client->Start();
  if (FAILED(hr)) {
    Fail("CaptureFailed", "IAudioClient::Start failed");
    running_.store(false);
    return;
  }

  Emit(SessionPhase::kRunning);

  const auto channel_count = static_cast<size_t>(std::max(1, config_.channel_count));
  const int64_t frame_micros =
      config_.frame_duration_micros > 0 ? config_.frame_duration_micros : 100000;
  const auto samples_per_frame = static_cast<size_t>(std::max<int64_t>(
      1, static_cast<int64_t>(config_.sample_rate) * frame_micros / 1000000));

  std::vector<float> mono_block;
  std::vector<float> resampled;
  std::vector<float> pending;
  const int64_t started_at = NowMillis();
  int64_t last_audio_at = started_at;
  int64_t timestamp_anchor_micros = -1;
  bool overflowed = false;

  while (!stop_requested_.load()) {
    UINT32 packet_length = 0;
    hr = capture_client->GetNextPacketSize(&packet_length);
    if (FAILED(hr)) {
      break;
    }

    while (packet_length != 0 && !stop_requested_.load()) {
      BYTE* data = nullptr;
      UINT32 frames_available = 0;
      DWORD flags = 0;
      UINT64 qpc_position = 0;
      hr = capture_client->GetBuffer(&data, &frames_available, &flags,
                                     nullptr, &qpc_position);
      if (FAILED(hr)) {
        break;
      }

      mono_block.clear();
      mono_block.reserve(frames_available);
      if ((flags & AUDCLNT_BUFFERFLAGS_SILENT) != 0) {
        // The endpoint signalled silence; emit zeros so timing stays correct.
        mono_block.assign(frames_available, 0.0f);
      } else if (data != nullptr) {
        for (UINT32 frame = 0; frame < frames_available; ++frame) {
          mono_block.push_back(ReadMonoSample(data, frame, source_channels,
                                              source_bits, source_is_float));
        }
      }

      // Release before doing conversion work so the endpoint keeps filling.
      hr = capture_client->ReleaseBuffer(frames_available);
      if (FAILED(hr)) {
        break;
      }

      if (timestamp_anchor_micros < 0 && frames_available > 0) {
        timestamp_anchor_micros =
            (flags & AUDCLNT_BUFFERFLAGS_TIMESTAMP_ERROR) == 0 &&
                    qpc_position != 0
                ? static_cast<int64_t>(qpc_position / 10)
                : QpcNowMicros();
      }

      if (!mono_block.empty()) {
        resampled.clear();
        resampler.Process(mono_block, &resampled);
        pending.insert(pending.end(), resampled.begin(), resampled.end());
        if (!resampled.empty()) {
          last_audio_at = NowMillis();
          received_any_audio_.store(true);
        }
      }

      while (pending.size() >= samples_per_frame) {
        CapturedFrame frame;
        frame.samples.resize(samples_per_frame * channel_count);
        for (size_t index = 0; index < samples_per_frame; ++index) {
          // Capture is mono; a wider request is satisfied by replication.
          for (size_t channel = 0; channel < channel_count; ++channel) {
            frame.samples[index * channel_count + channel] = pending[index];
          }
        }
        // ptrdiff_t, not long: long is 32-bit on Windows and would truncate a
        // large frame size.
        pending.erase(
            pending.begin(),
            pending.begin() + static_cast<std::ptrdiff_t>(samples_per_frame));

        FrameRing::Admission admission;
        {
          std::lock_guard<std::mutex> lock(mutex_);
          frame.sequence = next_sequence_++;
          frame.sample_offset = next_sample_offset_;
          frame.timestamp_micros =
              std::max<int64_t>(0, timestamp_anchor_micros) +
              next_sample_offset_ * 1000000 /
                  std::max(1, config_.sample_rate);
          next_sample_offset_ += static_cast<int64_t>(samples_per_frame);
          admission = ring_.Add(std::move(frame));
        }
        if (admission == FrameRing::Admission::kOverflowed) {
          overflowed = true;
          break;
        }
        frames_available_.notify_all();
      }

      if (overflowed) {
        break;
      }

      hr = capture_client->GetNextPacketSize(&packet_length);
      if (FAILED(hr)) {
        break;
      }
    }

    if (FAILED(hr) || overflowed) {
      break;
    }

    // A capture that never delivers is indistinguishable from a healthy silent
    // one until the watchdog fires; report it rather than hanging the consumer.
    if (!received_any_audio_.load() &&
        NowMillis() - last_audio_at > kStallTimeoutMillis) {
      audio_client->Stop();
      running_.store(false);
      Fail("CaptureStalled",
           "no audio delivered within the capture stall timeout");
      return;
    }

    // Split the sleep so a stop request is honoured within ~5 ms.
    DWORD slept = 0;
    while (slept < sleep_ms && !stop_requested_.load()) {
      const DWORD chunk = std::min<DWORD>(5, sleep_ms - slept);
      ::Sleep(chunk);
      slept += chunk;
    }
  }

  audio_client->Stop();
  running_.store(false);

  if (overflowed) {
    Fail("CaptureMailboxOverflow",
         "the capture mailbox overflowed under the failCapture policy");
    return;
  }
  if (FAILED(hr) && !stop_requested_.load()) {
    Fail("CaptureFailed", "the WASAPI capture loop failed");
    return;
  }

  finished_.store(true);
  frames_available_.notify_all();
}

void CaptureSession::ProcessCaptureThreadMain() {
  ComApartment apartment;
  if (!apartment.ok()) {
    Fail("CaptureFailed", "COM could not be initialised on the capture thread");
    running_.store(false);
    return;
  }

  ProcessLoopbackCapture capture(config_.process_ids, config_.sample_rate,
                                 config_.channel_count);
  std::string error;
  if (!capture.Initialize(&error)) {
    Fail("ProcessCaptureActivationFailed", error);
    running_.store(false);
    return;
  }
  if (!capture.Start(&error)) {
    Fail("ProcessCaptureStartFailed", error);
    running_.store(false);
    return;
  }

  DWORD mmcss_task_index = 0;
  MmcssHandle mmcss(::AvSetMmThreadCharacteristicsW(L"Pro Audio",
                                                    &mmcss_task_index));
  Emit(SessionPhase::kRunning);

  const size_t channel_count =
      static_cast<size_t>(std::max(1, config_.channel_count));
  const int64_t frame_micros =
      config_.frame_duration_micros > 0 ? config_.frame_duration_micros : 100000;
  const size_t sample_frames_per_frame =
      static_cast<size_t>(std::max<int64_t>(
          1, static_cast<int64_t>(config_.sample_rate) * frame_micros /
                 1000000));
  const size_t samples_per_frame = sample_frames_per_frame * channel_count;

  std::vector<float> mixed;
  std::vector<float> pending;
  int64_t pending_timestamp_micros = 0;
  const int64_t started_at = NowMillis();
  bool overflowed = false;

  while (!stop_requested_.load()) {
    int64_t mixed_timestamp_micros = 0;
    if (!capture.Drain(&mixed, &mixed_timestamp_micros, &error)) {
      capture.Stop();
      running_.store(false);
      Fail("ProcessCaptureReadFailed", error);
      return;
    }
    if (!mixed.empty()) {
      if (pending.empty()) {
        pending_timestamp_micros = mixed_timestamp_micros;
      }
      pending.insert(pending.end(), mixed.begin(), mixed.end());
      received_any_audio_.store(true);
    }

    while (pending.size() >= samples_per_frame) {
      CapturedFrame frame;
      frame.samples.assign(pending.begin(),
                           pending.begin() +
                               static_cast<std::ptrdiff_t>(samples_per_frame));
      pending.erase(
          pending.begin(),
          pending.begin() + static_cast<std::ptrdiff_t>(samples_per_frame));

      FrameRing::Admission admission;
      {
        std::lock_guard<std::mutex> lock(mutex_);
        frame.sequence = next_sequence_++;
        frame.sample_offset = next_sample_offset_;
        frame.timestamp_micros = pending_timestamp_micros;
        next_sample_offset_ += static_cast<int64_t>(sample_frames_per_frame);
        pending_timestamp_micros +=
            static_cast<int64_t>(sample_frames_per_frame) * 1000000 /
            std::max(1, config_.sample_rate);
        admission = ring_.Add(std::move(frame));
      }
      if (admission == FrameRing::Admission::kOverflowed) {
        overflowed = true;
        break;
      }
      frames_available_.notify_all();
    }

    if (overflowed) {
      break;
    }
    if (!received_any_audio_.load() &&
        NowMillis() - started_at > kStallTimeoutMillis) {
      capture.Stop();
      running_.store(false);
      Fail("CaptureStalled",
           "no process-loopback audio clock within the capture stall timeout");
      return;
    }

    for (DWORD slept = 0; slept < 10 && !stop_requested_.load(); slept += 5) {
      ::Sleep(5);
    }
  }

  capture.Stop();
  running_.store(false);
  if (overflowed) {
    Fail("CaptureMailboxOverflow",
         "the capture mailbox overflowed under the failCapture policy");
    return;
  }
  finished_.store(true);
  frames_available_.notify_all();
}

void CaptureSession::EchoCancelledCaptureThreadMain() {
  ComApartment apartment;
  if (!apartment.ok()) {
    Fail("CaptureFailed", "COM could not be initialised on the capture thread");
    running_.store(false);
    return;
  }

  VoiceCaptureDsp dsp(config_.endpoint_id);
  std::string error;
  if (!dsp.Initialize(&error)) {
    // The canceller is a quality of the capture, not the capture itself, and
    // the caller asked for a microphone. Report why the far end will still be
    // on this track and carry on with the plain endpoint stream.
    Emit(SessionPhase::kInterrupted, "MicrophoneVoiceProcessingUnavailable",
         "Echo cancellation is unavailable for this microphone, so audio "
         "played through the speakers is recorded on this track too: " +
             error);
    echo_cancellation_declined_.store(true);
    CaptureThreadMain();
    return;
  }

  DWORD mmcss_task_index = 0;
  MmcssHandle mmcss(::AvSetMmThreadCharacteristicsW(L"Pro Audio",
                                                    &mmcss_task_index));
  Emit(SessionPhase::kRunning);

  LinearResampler resampler;
  resampler.Reset(static_cast<double>(kVoiceCaptureDspSampleRate),
                  static_cast<double>(config_.sample_rate));

  const auto channel_count =
      static_cast<size_t>(std::max(1, config_.channel_count));
  const int64_t frame_micros =
      config_.frame_duration_micros > 0 ? config_.frame_duration_micros : 100000;
  const auto samples_per_frame = static_cast<size_t>(std::max<int64_t>(
      1, static_cast<int64_t>(config_.sample_rate) * frame_micros / 1000000));

  std::vector<float> cancelled;
  std::vector<float> resampled;
  std::vector<float> pending;
  const int64_t started_at = NowMillis();
  int64_t timestamp_anchor_micros = -1;
  bool overflowed = false;

  while (!stop_requested_.load()) {
    cancelled.clear();
    if (!dsp.Drain(&cancelled, &error)) {
      dsp.Stop();
      running_.store(false);
      Fail("CaptureFailed", error);
      return;
    }
    if (!cancelled.empty()) {
      if (timestamp_anchor_micros < 0) {
        // The DSP reports its own stream time, which starts at zero and says
        // nothing about the session clock; anchoring on the first delivery is
        // the same mapping the other poll-driven paths use.
        timestamp_anchor_micros = QpcNowMicros();
      }
      resampled.clear();
      resampler.Process(cancelled, &resampled);
      pending.insert(pending.end(), resampled.begin(), resampled.end());
      received_any_audio_.store(true);
    }

    while (pending.size() >= samples_per_frame) {
      CapturedFrame frame;
      frame.samples.resize(samples_per_frame * channel_count);
      for (size_t index = 0; index < samples_per_frame; ++index) {
        // The DSP is mono; a wider request is satisfied by replication, as on
        // every other capture path here.
        for (size_t channel = 0; channel < channel_count; ++channel) {
          frame.samples[index * channel_count + channel] = pending[index];
        }
      }
      pending.erase(
          pending.begin(),
          pending.begin() + static_cast<std::ptrdiff_t>(samples_per_frame));

      FrameRing::Admission admission;
      {
        std::lock_guard<std::mutex> lock(mutex_);
        frame.sequence = next_sequence_++;
        frame.sample_offset = next_sample_offset_;
        frame.timestamp_micros =
            std::max<int64_t>(0, timestamp_anchor_micros) +
            next_sample_offset_ * 1000000 / std::max(1, config_.sample_rate);
        next_sample_offset_ += static_cast<int64_t>(samples_per_frame);
        admission = ring_.Add(std::move(frame));
      }
      if (admission == FrameRing::Admission::kOverflowed) {
        overflowed = true;
        break;
      }
      frames_available_.notify_all();
    }

    if (overflowed) {
      break;
    }
    if (!received_any_audio_.load() &&
        NowMillis() - started_at > kStallTimeoutMillis) {
      dsp.Stop();
      running_.store(false);
      Fail("CaptureStalled",
           "no echo-cancelled audio delivered within the capture stall "
           "timeout");
      return;
    }

    // The DSP produces 10 ms at a time; polling on that cadence keeps latency
    // at one block without spinning.
    for (DWORD slept = 0; slept < 10 && !stop_requested_.load(); slept += 5) {
      ::Sleep(5);
    }
  }

  dsp.Stop();
  running_.store(false);
  if (overflowed) {
    Fail("CaptureMailboxOverflow",
         "the capture mailbox overflowed under the failCapture policy");
    return;
  }
  finished_.store(true);
  frames_available_.notify_all();
}

}  // namespace audio_flutter_windows
