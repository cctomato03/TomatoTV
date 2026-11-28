cmake_minimum_required(VERSION 3.5.0)
project(ffprobe)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

set(FFMPEG_ROOT
  "${CMAKE_CURRENT_SOURCE_DIR}/../../../../oh_modules/.ohpm/@ohos+ijkplayer@2.0.13/oh_modules/@ohos/ijkplayer/libs/${OHOS_ARCH}")

add_library(ffprobe SHARED ffprobe_napi.cpp)
target_include_directories(ffprobe PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/ffmpeg/include")

add_library(ffmpeg_avformat SHARED IMPORTED)
set_target_properties(ffmpeg_avformat PROPERTIES IMPORTED_LOCATION "${FFMPEG_ROOT}/libavformat.so")
add_library(ffmpeg_avcodec SHARED IMPORTED)
set_target_properties(ffmpeg_avcodec PROPERTIES IMPORTED_LOCATION "${FFMPEG_ROOT}/libavcodec.so")
add_library(ffmpeg_avutil SHARED IMPORTED)
set_target_properties(ffmpeg_avutil PROPERTIES IMPORTED_LOCATION "${FFMPEG_ROOT}/libavutil.so")

target_link_libraries(ffprobe PUBLIC
  ffmpeg_avformat
  ffmpeg_avcodec
  ffmpeg_avutil
  libace_napi.z.so
  libnative_window.so
  libnative_buffer.so
  m)
