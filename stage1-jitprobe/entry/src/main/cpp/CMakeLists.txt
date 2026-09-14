cmake_minimum_required(VERSION 3.5.0)
project(hps2_jitprobe)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

if(NOT DEFINED OHOS_SDK_NATIVE)
    set(OHOS_SDK_NATIVE ${CMAKE_CURRENT_SOURCE_DIR}/../../../../../sdk/default/openharmony/native)
endif()

include_directories(
    ${OHOS_SDK_NATIVE}/sysroot/usr/include
    ${OHOS_SDK_NATIVE}/sysroot/usr/include/aarch64-linux-ohos
)

add_library(jitprobe SHARED jitprobe.cpp)

target_link_libraries(jitprobe PUBLIC
    libace_napi.z.so
    libhilog_ndk.z.so
)
