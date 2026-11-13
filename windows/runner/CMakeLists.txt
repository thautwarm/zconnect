cmake_minimum_required(VERSION 3.14)
project(runner LANGUAGES CXX)

# Define the application target. To change its name, change BINARY_NAME in the
# top-level CMakeLists.txt, not the value here, or `flutter run` will no longer
# work.
#
# Any new source files that you add to the application should be added here.
set(VENDOR_DIR "${CMAKE_SOURCE_DIR}/Vendor")

add_executable(${BINARY_NAME} WIN32
  "flutter_window.cpp"
  "main.cpp"
  "utils.cpp"
  "win32_window.cpp"
  "voice/audio_support.cpp"
  "voice/ogg_opus_codec.cpp"
  "voice/win_voice_engine.cpp"
  "voice/voice_engine_plugin.cpp"
  "${FLUTTER_MANAGED_DIR}/generated_plugin_registrant.cc"
  "Runner.rc"
  "runner.exe.manifest"
)

# Apply the standard set of build settings. This can be removed for applications
# that need different build settings.
apply_standard_settings(${BINARY_NAME})

# Add preprocessor definitions for the build version.
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION=\"${FLUTTER_VERSION}\"")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_MAJOR=${FLUTTER_VERSION_MAJOR}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_MINOR=${FLUTTER_VERSION_MINOR}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_PATCH=${FLUTTER_VERSION_PATCH}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_BUILD=${FLUTTER_VERSION_BUILD}")

# Disable Windows macros that collide with C++ standard library functions.
target_compile_definitions(${BINARY_NAME} PRIVATE "NOMINMAX")

# Add dependency libraries and include directories. Add any application-specific
# dependencies here.
target_link_libraries(${BINARY_NAME} PRIVATE flutter flutter_wrapper_app)
target_link_libraries(${BINARY_NAME} PRIVATE "dwmapi.lib")
target_include_directories(${BINARY_NAME} PRIVATE "${CMAKE_SOURCE_DIR}")
target_include_directories(${BINARY_NAME} PRIVATE
  "${CMAKE_CURRENT_SOURCE_DIR}/voice"
  "${VENDOR_DIR}"
  "${VENDOR_DIR}/include")

# 原生语音引擎依赖：miniaudio（header-only）、libopus/libogg、Voice Capture DSP。
foreach(required
    "${VENDOR_DIR}/miniaudio.h"
    "${VENDOR_DIR}/include/opus.h"
    "${VENDOR_DIR}/include/ogg/ogg.h"
    "${VENDOR_DIR}/lib/opus.lib"
    "${VENDOR_DIR}/lib/ogg.lib")
  if(NOT EXISTS "${required}")
    message(FATAL_ERROR
      "缺少 Windows 原生依赖：${required}\n"
      "先在仓库根目录运行：pwsh -File tools/build_windows.ps1")
  endif()
endforeach()

target_link_libraries(${BINARY_NAME} PRIVATE
  "${VENDOR_DIR}/lib/opus.lib"
  "${VENDOR_DIR}/lib/ogg.lib"
  "ole32.lib"
  "uuid.lib"
  "avrt.lib"
  "ksuser.lib"
  "wmcodecdspuuid.lib"
  "dmoguids.lib"
  "msdmo.lib"
  "propsys.lib"
  "strmiids.lib"
  "shell32.lib"
  "winmm.lib")

# Run the Flutter tool portions of the build. This must not be removed.
add_dependencies(${BINARY_NAME} flutter_assemble)
