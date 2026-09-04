# The Flutter tooling requires that developers have a version of Visual Studio
# installed that includes CMake 3.14 or later. You should not increase this
# version, as doing so will cause the plugin to fail to compile for some
# customers of the plugin.
cmake_minimum_required(VERSION 3.14)

# Project-level configuration.
set(PROJECT_NAME "audio_flutter_windows")
project(${PROJECT_NAME} LANGUAGES CXX)

# This value is used when generating builds using this plugin, so it must
# not be changed.
set(PLUGIN_NAME "audio_flutter_windows_plugin")

# Any new source files that you add to the plugin should be added here.
list(APPEND PLUGIN_SOURCES
  "audio_flutter_windows_plugin.cpp"
  "audio_flutter_windows_plugin.h"
  "audio_format.cpp"
  "audio_format.h"
  "capture_session.cpp"
  "capture_session.h"
  "com_utils.h"
  "frame_ring.cpp"
  "frame_ring.h"
  "playback_session.cpp"
  "playback_session.h"
  "process_loopback_capture.cpp"
  "process_loopback_capture.h"
  "voice_capture_dsp.cpp"
  "voice_capture_dsp.h"
)

# Define the plugin library target. Its name must not be changed (see comment
# on PLUGIN_NAME above).
add_library(${PLUGIN_NAME} SHARED
  "include/audio_flutter_windows/audio_flutter_windows_plugin_c_api.h"
  "audio_flutter_windows_plugin_c_api.cpp"
  ${PLUGIN_SOURCES}
)

# Apply a standard set of build settings that are configured in the
# application-level CMakeLists.txt. This can be removed for plugins that want
# full control over build settings.
apply_standard_settings(${PLUGIN_NAME})

# C++17 for std::optional, structured bindings, and inline statics.
target_compile_features(${PLUGIN_NAME} PRIVATE cxx_std_17)

# Symbols are hidden by default to reduce the chance of accidental conflicts
# between plugins. This should not be removed; any symbols that should be
# exported should be explicitly exported with the FLUTTER_PLUGIN_EXPORT macro.
set_target_properties(${PLUGIN_NAME} PROPERTIES
  CXX_VISIBILITY_PRESET hidden)
target_compile_definitions(${PLUGIN_NAME} PRIVATE FLUTTER_PLUGIN_IMPL)

# <windows.h> defines min/max as macros, which break std::min/std::max used
# throughout the conversion and poll-cadence code. NOMINMAX must be defined
# before any windows.h include, so set it on the target rather than per source.
target_compile_definitions(${PLUGIN_NAME} PRIVATE NOMINMAX)

# Source include directories and library dependencies.
target_include_directories(${PLUGIN_NAME} INTERFACE
  "${CMAKE_CURRENT_SOURCE_DIR}/include")

# flutter / flutter_wrapper_plugin: the Flutter C++ client wrapper.
# Ole32       : CoInitializeEx / CoCreateInstance / CoTaskMemFree (COM).
# Mmdevapi    : IMMDeviceEnumerator / MMDeviceEnumerator; the WASAPI interfaces
#               (IAudioClient / IAudioCaptureClient / IAudioRenderClient)
#               resolve through this and the Windows SDK headers.
# Avrt        : AvSetMmThreadCharacteristics, to place the capture and render
#               threads on the "Pro Audio" MMCSS task.
# Propsys     : PropVariantInit / PropVariantClear for device friendly names.
# Msdmo       : MoInitMediaType / MoFreeMediaType for the Voice Capture DSP's
#               output media type.
# dmoguids    : IMediaObject / IMediaBuffer interface IDs.
# wmcodecdspuuid: CLSID_CWMAudioAEC and the MFPKEY_WMAAECMA_* property keys.
# strmiids    : MEDIATYPE_Audio / MEDIASUBTYPE_PCM / FORMAT_WaveFormatEx.
target_link_libraries(${PLUGIN_NAME} PRIVATE
  flutter
  flutter_wrapper_plugin
  Mmdevapi
  Ole32
  Avrt
  Propsys
  Msdmo
  dmoguids
  wmcodecdspuuid
  strmiids)

# List of absolute paths to libraries that should be bundled with the plugin.
set(audio_flutter_windows_bundled_libraries
  ""
  PARENT_SCOPE)
