#include "voice_capture_dsp.h"

// clang-format off
#include <mmdeviceapi.h>
#include <audioclient.h>
#include <mediaobj.h>
#include <dmort.h>
#include <uuids.h>
#include <wmcodecdsp.h>
#include <propvarutil.h>
// clang-format on

#include <algorithm>
#include <cstring>

#include "com_utils.h"

namespace audio_flutter_windows {

namespace {

/// `MFPKEY_WMAAECMA_SYSTEM_MODE` value for microphone capture with acoustic
/// echo cancellation and no microphone-array processing.
constexpr LONG kSingleChannelAec = 0;

/// Bytes pulled from the DSP per `ProcessOutput`. One second of 16-bit mono at
/// 16 kHz, so a poll that arrives late still empties the DSP in one pass.
constexpr DWORD kOutputBufferBytes = kVoiceCaptureDspSampleRate * 2;

/// Buffer handed to `IMediaObject::ProcessOutput`.
///
/// The DSP writes into a buffer the caller owns, so an `IMediaBuffer` has to
/// exist even though nothing else in this plugin is a COM object. It lives for
/// as long as the DSP session and is never handed to anything that could
/// outlive it, so its reference counting is deliberately inert: the DMO calls
/// AddRef/Release around each ProcessOutput and must not be able to destroy a
/// member of this class.
class OutputMediaBuffer : public IMediaBuffer {
 public:
  OutputMediaBuffer() : data_(kOutputBufferBytes, 0) {}

  HRESULT STDMETHODCALLTYPE QueryInterface(REFIID riid, void** object)
      override {
    if (object == nullptr) {
      return E_POINTER;
    }
    if (riid == IID_IUnknown || riid == __uuidof(IMediaBuffer)) {
      *object = static_cast<IMediaBuffer*>(this);
      return S_OK;
    }
    *object = nullptr;
    return E_NOINTERFACE;
  }

  ULONG STDMETHODCALLTYPE AddRef() override { return 2; }
  ULONG STDMETHODCALLTYPE Release() override { return 1; }

  HRESULT STDMETHODCALLTYPE SetLength(DWORD length) override {
    if (length > static_cast<DWORD>(data_.size())) {
      return E_INVALIDARG;
    }
    length_ = length;
    return S_OK;
  }

  HRESULT STDMETHODCALLTYPE GetMaxLength(DWORD* max_length) override {
    if (max_length == nullptr) {
      return E_POINTER;
    }
    *max_length = static_cast<DWORD>(data_.size());
    return S_OK;
  }

  HRESULT STDMETHODCALLTYPE GetBufferAndLength(BYTE** buffer,
                                               DWORD* length) override {
    if (buffer == nullptr && length == nullptr) {
      return E_POINTER;
    }
    if (buffer != nullptr) {
      *buffer = data_.data();
    }
    if (length != nullptr) {
      *length = length_;
    }
    return S_OK;
  }

  void Reset() { length_ = 0; }
  DWORD length() const { return length_; }
  const BYTE* data() const { return data_.data(); }

 private:
  std::vector<BYTE> data_;
  DWORD length_ = 0;
};

/// Sets one `VT_I4` DSP property.
HRESULT SetInt32Property(IPropertyStore* store, REFPROPERTYKEY key,
                         LONG value) {
  PROPVARIANT variant;
  ::PropVariantInit(&variant);
  variant.vt = VT_I4;
  variant.lVal = value;
  const HRESULT hr = store->SetValue(key, variant);
  ::PropVariantClear(&variant);
  return hr;
}

/// Sets one `VT_BOOL` DSP property.
HRESULT SetBoolProperty(IPropertyStore* store, REFPROPERTYKEY key, bool value) {
  PROPVARIANT variant;
  ::PropVariantInit(&variant);
  variant.vt = VT_BOOL;
  variant.boolVal = value ? VARIANT_TRUE : VARIANT_FALSE;
  const HRESULT hr = store->SetValue(key, variant);
  ::PropVariantClear(&variant);
  return hr;
}

/// Position of an endpoint inside the DSP's view of the device list.
///
/// The DSP addresses devices by their index in the active-endpoint collection
/// for their data flow, which is the same enumeration this plugin already uses
/// to list input devices. -1 selects a default the DSP picks by an undocumented
/// rule, which is what an unspecified microphone wants; the speaker reference
/// is resolved by id instead, because which default it means is exactly what
/// decides whether the echo is cancelled.
int EndpointIndex(IMMDeviceEnumerator* enumerator, EDataFlow flow,
                  const std::string& endpoint_id) {
  if (endpoint_id.empty()) {
    return -1;
  }
  ComPtr<IMMDeviceCollection> collection;
  if (FAILED(enumerator->EnumAudioEndpoints(flow, DEVICE_STATE_ACTIVE,
                                            collection.put())) ||
      !collection) {
    return -1;
  }
  UINT count = 0;
  if (FAILED(collection->GetCount(&count))) {
    return -1;
  }
  for (UINT index = 0; index < count; ++index) {
    ComPtr<IMMDevice> device;
    if (FAILED(collection->Item(index, device.put())) || !device) {
      continue;
    }
    ComTaskMem<WCHAR> id;
    if (FAILED(device->GetId(id.put())) || !id) {
      continue;
    }
    if (Utf8FromWide(id.get()) == endpoint_id) {
      return static_cast<int>(index);
    }
  }
  return -1;
}

/// Id of the endpoint Windows currently gives `role` for `flow`, or empty.
std::string DefaultEndpointId(IMMDeviceEnumerator* enumerator, EDataFlow flow,
                              ERole role) {
  ComPtr<IMMDevice> device;
  if (FAILED(enumerator->GetDefaultAudioEndpoint(flow, role, device.put())) ||
      !device) {
    return std::string();
  }
  ComTaskMem<WCHAR> id;
  if (FAILED(device->GetId(id.put())) || !id) {
    return std::string();
  }
  return Utf8FromWide(id.get());
}

}  // namespace

struct VoiceCaptureDsp::Impl {
  ComPtr<IMediaObject> dmo;
  ComPtr<IPropertyStore> properties;
  OutputMediaBuffer buffer;
  bool streaming = false;
};

VoiceCaptureDsp::VoiceCaptureDsp(std::string endpoint_id)
    : impl_(std::make_unique<Impl>()), endpoint_id_(std::move(endpoint_id)) {}

VoiceCaptureDsp::~VoiceCaptureDsp() { Stop(); }

bool VoiceCaptureDsp::Initialize(std::string* error) {
  const auto fail = [error](const char* reason) {
    if (error != nullptr) {
      *error = reason;
    }
    return false;
  };

  HRESULT hr = ::CoCreateInstance(CLSID_CWMAudioAEC, nullptr,
                                  CLSCTX_INPROC_SERVER,
                                  IID_PPV_ARGS(impl_->dmo.put()));
  if (FAILED(hr) || !impl_->dmo) {
    return fail("the Windows Voice Capture DSP is unavailable");
  }
  hr = impl_->dmo->QueryInterface(IID_PPV_ARGS(impl_->properties.put()));
  if (FAILED(hr) || !impl_->properties) {
    return fail("the Voice Capture DSP exposes no property store");
  }

  // Source mode: the DSP opens both endpoints itself. Filter mode would make
  // this code responsible for feeding it a reference stream, which is exactly
  // the thing a capture-only tap cannot produce.
  if (FAILED(SetBoolProperty(impl_->properties.get(),
                             MFPKEY_WMAAECMA_DMO_SOURCE_MODE, true))) {
    return fail("the Voice Capture DSP refused source mode");
  }
  if (FAILED(SetInt32Property(impl_->properties.get(),
                              MFPKEY_WMAAECMA_SYSTEM_MODE,
                              kSingleChannelAec))) {
    return fail("the Voice Capture DSP refused echo-cancellation mode");
  }

  ComPtr<IMMDeviceEnumerator> enumerator;
  hr = ::CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL,
                          IID_PPV_ARGS(enumerator.put()));
  if (FAILED(hr) || !enumerator) {
    return fail("MMDeviceEnumerator unavailable");
  }
  const int microphone_index =
      EndpointIndex(enumerator.get(), eCapture, endpoint_id_);
  if (!endpoint_id_.empty() && microphone_index < 0) {
    // Silently cancelling the echo off a different microphone than the one the
    // caller selected would be a worse bug than the echo.
    return fail(
        "the selected microphone has no endpoint index the Voice Capture DSP "
        "can address");
  }
  // The reference the canceller subtracts has to be the endpoint the meeting
  // plays through, which is the one the system-audio track records. -1 asks the
  // DSP to pick "the default" by a rule it does not document, and Windows keeps
  // several defaults that are routinely different devices, so the endpoint is
  // resolved here with the role the rest of this plugin uses and named
  // explicitly. A failure still falls back to -1: a canceller referencing the
  // wrong speakers beats no capture at all.
  const int speaker_index = EndpointIndex(
      enumerator.get(), eRender,
      DefaultEndpointId(enumerator.get(), eRender, eConsole));
  const LONG device_indexes = static_cast<LONG>(
      ((static_cast<uint32_t>(speaker_index) & 0xFFFFu) << 16) |
      (static_cast<uint32_t>(microphone_index) & 0xFFFFu));
  if (FAILED(SetInt32Property(impl_->properties.get(),
                              MFPKEY_WMAAECMA_DEVICE_INDEXES,
                              device_indexes))) {
    return fail("the Voice Capture DSP refused the endpoint selection");
  }

  // Automatic gain control rides the level of a signal the caller asked for at
  // a fixed format, and it reacts to the far end as readily as to the near end.
  // Turning the feature block on is what makes the individual switches take
  // effect at all; echo cancellation itself stays on.
  if (SUCCEEDED(SetBoolProperty(impl_->properties.get(),
                                MFPKEY_WMAAECMA_FEATURE_MODE, true))) {
    SetBoolProperty(impl_->properties.get(), MFPKEY_WMAAECMA_FEATR_AGC, false);
  }

  WAVEFORMATEX format = {};
  format.wFormatTag = WAVE_FORMAT_PCM;
  format.nChannels = 1;
  format.nSamplesPerSec = kVoiceCaptureDspSampleRate;
  format.wBitsPerSample = 16;
  format.nBlockAlign =
      static_cast<WORD>(format.nChannels * format.wBitsPerSample / 8);
  format.nAvgBytesPerSec = format.nSamplesPerSec * format.nBlockAlign;
  format.cbSize = 0;

  DMO_MEDIA_TYPE media_type = {};
  if (FAILED(::MoInitMediaType(&media_type, sizeof(WAVEFORMATEX)))) {
    return fail("the Voice Capture DSP output type could not be allocated");
  }
  media_type.majortype = MEDIATYPE_Audio;
  media_type.subtype = MEDIASUBTYPE_PCM;
  media_type.lSampleSize = 0;
  media_type.bFixedSizeSamples = TRUE;
  media_type.bTemporalCompression = FALSE;
  media_type.formattype = FORMAT_WaveFormatEx;
  std::memcpy(media_type.pbFormat, &format, sizeof(WAVEFORMATEX));
  hr = impl_->dmo->SetOutputType(0, &media_type, 0);
  ::MoFreeMediaType(&media_type);
  if (FAILED(hr)) {
    return fail("the Voice Capture DSP refused 16 kHz mono output");
  }

  hr = impl_->dmo->AllocateStreamingResources();
  if (FAILED(hr)) {
    return fail("the Voice Capture DSP could not open the audio endpoints");
  }
  impl_->streaming = true;
  return true;
}

bool VoiceCaptureDsp::Drain(std::vector<float>* samples, std::string* error) {
  if (samples == nullptr) {
    return true;
  }
  if (!impl_->streaming || !impl_->dmo) {
    if (error != nullptr) {
      *error = "the Voice Capture DSP is not streaming";
    }
    return false;
  }

  // The DSP reports an incomplete flag while it still holds audio, so one poll
  // drains everything that has accumulated rather than leaving a backlog that
  // grows into latency.
  bool more = true;
  while (more) {
    impl_->buffer.Reset();
    DMO_OUTPUT_DATA_BUFFER output = {};
    output.pBuffer = &impl_->buffer;
    output.dwStatus = 0;
    output.rtTimestamp = 0;
    output.rtTimelength = 0;

    DWORD status = 0;
    const HRESULT hr = impl_->dmo->ProcessOutput(0, 1, &output, &status);
    if (FAILED(hr)) {
      if (error != nullptr) {
        *error = "the Voice Capture DSP failed while producing audio";
      }
      return false;
    }
    // S_FALSE means the DSP has nothing ready yet, which for a live microphone
    // simply means the next 10 ms has not elapsed.
    if (hr == S_FALSE || impl_->buffer.length() == 0) {
      return true;
    }

    const DWORD byte_count = impl_->buffer.length();
    const BYTE* bytes = impl_->buffer.data();
    const size_t sample_count = byte_count / sizeof(int16_t);
    samples->reserve(samples->size() + sample_count);
    for (size_t index = 0; index < sample_count; ++index) {
      int16_t value = 0;
      std::memcpy(&value, bytes + index * sizeof(int16_t), sizeof(int16_t));
      samples->push_back(static_cast<float>(value) / 32768.0f);
    }

    more = (output.dwStatus & DMO_OUTPUT_DATA_BUFFERF_INCOMPLETE) != 0;
  }
  return true;
}

void VoiceCaptureDsp::Stop() {
  if (impl_ == nullptr) {
    return;
  }
  if (impl_->dmo && impl_->streaming) {
    impl_->dmo->FreeStreamingResources();
  }
  impl_->streaming = false;
  impl_->properties.reset();
  impl_->dmo.reset();
}

}  // namespace audio_flutter_windows
