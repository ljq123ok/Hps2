# Hps2 — SDL3 minimal stub for HarmonyOS
#
# 定位：让 ARMSX2 核心能编译/链接通过，不提供真实功能。
# 音频与输入由 OHOS 原生实现替换（见 docs/stage2-progress.md 方案 B）。
#
# 与"完整移植 SDL3"的取舍说明：
#   SDL3 无 HarmonyOS 平台支持，其 UNIX_SYS 分支要求 X11/Wayland/ALSA。
#   本 stub 使用 SDL3 **真实头文件**（保证类型/ABI 一致），只提供空实现。
cmake_minimum_required(VERSION 3.16)
project(SDL3-stub CXX)

# SDL3 头文件来源（源码树）
set(SDL3_REAL_INCLUDE "" CACHE PATH "Path to real SDL3 include dir (containing SDL3/)")

add_library(SDL3-static STATIC sdl3_stub.cpp)
add_library(SDL3::SDL3 ALIAS SDL3-static)

target_compile_features(SDL3-static PUBLIC cxx_std_17)
target_include_directories(SDL3-static PUBLIC
    $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}>
    $<INSTALL_INTERFACE:include>
    ${SDL3_REAL_INCLUDE}
)
target_compile_definitions(SDL3-static PUBLIC __OHOS__=1)

install(TARGETS SDL3-static EXPORT SDL3Targets ARCHIVE DESTINATION lib)
install(FILES ${SDL3_REAL_INCLUDE}/SDL3/SDL.h DESTINATION include/SDL3)
install(DIRECTORY ${SDL3_REAL_INCLUDE}/SDL3/ DESTINATION include/SDL3
        FILES_MATCHING PATTERN "*.h")
install(EXPORT SDL3Targets NAMESPACE SDL3:: DESTINATION lib/cmake/SDL3)
