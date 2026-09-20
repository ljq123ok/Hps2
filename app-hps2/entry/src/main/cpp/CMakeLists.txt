# Hps2 — HAP native 层构建
#
# 链接对象：
#   libPCSX2core.a  —— PCSX2 核心（由 upstream/ARMSX2 的 PCSX2_CORE_STATIC 目标产出）
#   thirdparty-ohos/prefix 下的第三方库 —— 交叉编译产物
#
# 注意：本 CMakeLists 由 hvigor 调用，工具链由 hvigor 提供（OHOS NDK）。
# 因此这里**不设** CMAKE_TOOLCHAIN_FILE，只声明源文件与依赖。

cmake_minimum_required(VERSION 3.5.0)
project(hps2core)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# ---------------------------------------------------------------------------
# 路径定位
# ---------------------------------------------------------------------------
# 本文件位于 <repo>/app-hps2/entry/src/main/cpp/CMakeLists.txt
get_filename_component(HPS2_CPP_DIR   "${CMAKE_CURRENT_LIST_DIR}" ABSOLUTE)
get_filename_component(HPS2_REPO      "${HPS2_CPP_DIR}/../../../../.." ABSOLUTE)

set(ARMSX2_ROOT   "${HPS2_REPO}/upstream/ARMSX2")
set(TP_PREFIX     "${HPS2_REPO}/thirdparty-ohos/prefix")

# ARMSX2 的 OHOS 构建目录（含 libPCSX2core.a）。
# 必须在计算 CORE_LIB 之前定义，否则变量为空。
# 可由构建脚本用 -DARMSX2_BUILD_DIR=<path> 覆盖。
if(NOT DEFINED ARMSX2_BUILD_DIR)
    set(ARMSX2_BUILD_DIR "$ENV{HPS2_ARMSX2_BUILD_DIR}" CACHE PATH "ARMSX2 OHOS build dir")
endif()
if(NOT ARMSX2_BUILD_DIR)
    set(ARMSX2_BUILD_DIR "/tmp/armsx2-ohos" CACHE PATH "ARMSX2 OHOS build dir" FORCE)
endif()

set(CORE_LIB      "${ARMSX2_BUILD_DIR}/lib/libPCSX2core.a")

message(STATUS "Hps2: ARMSX2_ROOT   = ${ARMSX2_ROOT}")
message(STATUS "Hps2: TP_PREFIX     = ${TP_PREFIX}")
message(STATUS "Hps2: CORE_LIB      = ${CORE_LIB}")

if(NOT EXISTS "${CORE_LIB}")
    message(FATAL_ERROR
        "找不到核心静态库: ${CORE_LIB}\n"
        "请先构建：cmake --build <ARMSX2_BUILD_DIR> --target PCSX2_CORE_STATIC")
endif()

# ---------------------------------------------------------------------------
# 头文件路径（与 ARMSX2 构建时一致）
# ---------------------------------------------------------------------------
include_directories(
    ${ARMSX2_ROOT}
    ${ARMSX2_ROOT}/common
    ${ARMSX2_ROOT}/pcsx2
    ${ARMSX2_ROOT}/3rdparty/fmt/include
    ${ARMSX2_ROOT}/3rdparty/include
    ${ARMSX2_ROOT}/3rdparty/vixl/include
    ${ARMSX2_ROOT}/3rdparty/fast_float/include
    ${ARMSX2_ROOT}/3rdparty/rapidyaml/include
    ${ARMSX2_ROOT}/3rdparty/imgui/include
    ${ARMSX2_ROOT}/3rdparty/cpuinfo/include
    ${ARMSX2_ROOT}/3rdparty/simpleini/include
    ${ARMSX2_ROOT}/3rdparty/libchdr/include
    ${ARMSX2_ROOT}/3rdparty/rcheevos/include
    ${ARMSX2_ROOT}/3rdparty/discord-rpc/include
    ${ARMSX2_ROOT}/3rdparty/rapidjson/include
    ${ARMSX2_ROOT}/3rdparty/freesurround/include
    ${ARMSX2_ROOT}/3rdparty/soundtouch/soundtouch
    ${ARMSX2_ROOT}/3rdparty/lzma/include
    ${ARMSX2_ROOT}/3rdparty/demangler/include
    ${ARMSX2_ROOT}/3rdparty/ccc/src
    ${ARMSX2_ROOT}/3rdparty/libzip/lib
    ${TP_PREFIX}/include
    # SDL3 头文件（虚拟手柄需要 SDL_joystick.h）
    ${TP_PREFIX}/include/SDL3
    ${CMAKE_CURRENT_SOURCE_DIR}/types/libhps2core
)

add_compile_definitions(
    __OHOS__=1
    __MUSL__=1
    __POSIX__
    VIXL_INCLUDE_TARGET_A64
    CPUINFO_SUPPORTED_PLATFORM=0
    HAVE_LIMITS_H=1
    HAVE_STDLIB_H=1
    HAVE_STRING_H=1
    HAVE_DECL_BASENAME=1
    C4_NO_DEBUG_BREAK
    PLUTOSVG_BUILD_STATIC
    PLUTOVG_BUILD_STATIC
    SOUNDTOUCH_FLOAT_SAMPLES
    ST_NO_EXCEPTION_HANDLING
)

# ---------------------------------------------------------------------------
# 目标
# ---------------------------------------------------------------------------
add_library(hps2core SHARED
    napi_init.cpp
    hps2_host.cpp
    hps2_jitcheck.cpp
    hps2_vpad.cpp
    hps2_video.cpp
)

# 不把开发机绝对路径编进发布 HAP 的 native 字符串（包括 __FILE__）。
# 上游 ARMSX2 静态库由独立构建目录使用同等映射编译；这里覆盖本应用
# 自己的 native 源文件，保证两层产物都不暴露本机用户名和工作区路径。
target_compile_options(hps2core PRIVATE
    "-ffile-prefix-map=${HPS2_REPO}=hps2-src"
)

# 核心静态库（整体链接，避免部分符号缺失）
target_link_libraries(hps2core PUBLIC
    -Wl,--whole-archive
    ${CORE_LIB}
    -Wl,--no-whole-archive
)

# ARMSX2 的配套静态库（common 层 + 内建的 3rdparty）
# 注意：这些是 ARMSX2 构建时自建的，与 thirdparty-ohos/prefix 下的交叉编译产物不同。
target_link_libraries(hps2core PUBLIC
    ${ARMSX2_BUILD_DIR}/common/libcommon.a
    ${ARMSX2_BUILD_DIR}/3rdparty/ccc/libccc.a
    ${ARMSX2_BUILD_DIR}/3rdparty/cpuinfo/libcpuinfo.a
    ${ARMSX2_BUILD_DIR}/3rdparty/demangler/libdemanglegnu.a
    ${ARMSX2_BUILD_DIR}/3rdparty/fmt/libfmt.a
    ${ARMSX2_BUILD_DIR}/3rdparty/imgui/libimgui.a
    ${ARMSX2_BUILD_DIR}/3rdparty/libchdr/liblibchdr.a
    ${ARMSX2_BUILD_DIR}/3rdparty/libzip/libzip.a
    ${ARMSX2_BUILD_DIR}/3rdparty/lzma/libpcsx2-lzma.a
    ${ARMSX2_BUILD_DIR}/3rdparty/rapidyaml/libpcsx2-rapidyaml.a
    ${ARMSX2_BUILD_DIR}/3rdparty/rcheevos/librcheevos.a
    ${ARMSX2_BUILD_DIR}/3rdparty/simpleini/libsimpleini.a
    ${ARMSX2_BUILD_DIR}/3rdparty/soundtouch/libpcsx2-soundtouch.a
    ${ARMSX2_BUILD_DIR}/3rdparty/vixl/libvixl.a
    ${ARMSX2_BUILD_DIR}/3rdparty/freesurround/libfreesurround.a
    # glad：GL/EGL 函数加载器。PCSX2 的 OpenGL 后端靠它
    # 在运行时 dlopen("libEGL") 并装载 GLES 函数指针。
    ${ARMSX2_BUILD_DIR}/3rdparty/glad/libglad.a
    ${ARMSX2_BUILD_DIR}/3rdparty/discord-rpc/libdiscord-rpc.a
    ${ARMSX2_BUILD_DIR}/3rdparty/cubeb/libcubeb.a
)

# 交叉编译的第三方库 + OHOS 系统库
target_link_libraries(hps2core PUBLIC
    ${TP_PREFIX}/lib/libzstd.a
    ${TP_PREFIX}/lib/liblz4.a
    ${TP_PREFIX}/lib/libpng.a
    ${TP_PREFIX}/lib/libjpeg.a
    ${TP_PREFIX}/lib/libwebp.a
    ${TP_PREFIX}/lib/libwebpdemux.a
    ${TP_PREFIX}/lib/libwebpmux.a
    ${TP_PREFIX}/lib/libsharpyuv.a
    ${TP_PREFIX}/lib/libfreetype.a
    ${TP_PREFIX}/lib/libplutovg.a
    ${TP_PREFIX}/lib/libplutosvg.a
    # SDL3：ARMSX2 核心的音频/输入后端依赖它。
    # 这是实际交叉编译成功的 SDL3（非 stub）——先前准备的
    # thirdparty-ohos/sdl3-stub/ 保留为应急备份，此处不启用。
    ${TP_PREFIX}/lib/libSDL3.a
    # OHOS 的 pthread.h 定义了 PTHREAD_CANCEL_ASYNCHRONOUS 宏，
    # 但 libc 并不导出 pthread_setcanceltype，SDL3 的 #ifdef 因此命中并引用它。
    # 该 compat 库提供空实现（OHOS musl 无 POSIX 线程取消）。
    ${HPS2_REPO}/thirdparty-ohos/compat/libohos_musl_compat.a
    z
    net_http
    libace_napi.z.so
    libhilog_ndk.z.so
    ohaudio
    # OHOS 图形：EGL/GLES 由 glad 运行时 dlopen，但 native_window 的
    # OH_NativeWindow_* 是直接调用的，需要链接期解析。
    native_window
    EGL
    GLESv3
)
