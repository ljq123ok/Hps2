# 通用 OHOS (HarmonyOS) 交叉编译 toolchain
#
# 供 thirdparty-ohos/ 下所有第三方库共用。
# 与 upstream/ARMSX2/cmake/ohos.toolchain.cmake 的区别：
#   本文件面向**独立库构建**，把产物安装到统一前缀 thirdparty-ohos/prefix，
#   再由 CMake config 供 ARMSX2 上游 find_package 使用。

set(CMAKE_SYSTEM_NAME OHOS)
set(CMAKE_SYSTEM_PROCESSOR aarch64)

if(NOT DEFINED OHOS_SDK_NATIVE)
    set(OHOS_SDK_NATIVE "/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/native")
endif()

set(OHOS_TOOLCHAIN "${OHOS_SDK_NATIVE}/llvm")
set(OHOS_SYSROOT   "${OHOS_SDK_NATIVE}/sysroot")

set(CMAKE_C_COMPILER   "${OHOS_TOOLCHAIN}/bin/clang")
set(CMAKE_CXX_COMPILER "${OHOS_TOOLCHAIN}/bin/clang++")
set(CMAKE_AR           "${OHOS_TOOLCHAIN}/bin/llvm-ar"     CACHE FILEPATH "" FORCE)
set(CMAKE_RANLIB       "${OHOS_TOOLCHAIN}/bin/llvm-ranlib" CACHE FILEPATH "" FORCE)
set(CMAKE_STRIP        "${OHOS_TOOLCHAIN}/bin/llvm-strip"  CACHE FILEPATH "" FORCE)

set(CMAKE_SYSROOT "${OHOS_SYSROOT}")

# 关键：把 --target 写进 CMAKE_C_FLAGS / CXX_FLAGS，而不仅是 add_compile_options。
#
# 原因（实测教训）：某些库（如 libpng）在构建期会用 try_run / 自定义命令
# 运行**宿主机上的**代码生成器。这些步骤使用 CMAKE_C_FLAGS 提供的标志，
# 而不经过 add_compile_options 的目标级机制。若缺少 --target，
# clang 不会加入架构专属的 include 目录
# (sysroot/usr/include/aarch64-linux-ohos)，随即报：
#     fatal error: 'bits/alltypes.h' file not found
# OHOS 的 bits/ 是按架构分目录存放的（aarch64/arm/i686/x86_64-linux-ohos），
# 因此 --target 对 OHOS 是必需的，不能只靠 sysroot。
set(CMAKE_C_FLAGS_INIT   "--target=aarch64-linux-ohos -D__OHOS__=1 -D__MUSL__=1")
set(CMAKE_CXX_FLAGS_INIT "--target=aarch64-linux-ohos -D__OHOS__=1 -D__MUSL__=1")
set(CMAKE_ASM_FLAGS_INIT "--target=aarch64-linux-ohos")

set(CMAKE_EXE_LINKER_FLAGS_INIT    "--target=aarch64-linux-ohos")
set(CMAKE_SHARED_LINKER_FLAGS_INIT "--target=aarch64-linux-ohos")
set(CMAKE_MODULE_LINKER_FLAGS_INIT "--target=aarch64-linux-ohos")

# 同时保留目标级标志，覆盖未走 *_INIT 的路径
add_compile_options(--target=aarch64-linux-ohos)
add_link_options(--target=aarch64-linux-ohos)

add_compile_definitions(__OHOS__=1 __MUSL__=1)

# 从 sysroot 与我们自己的安装前缀找库/头，避免误链宿主库。
#
# 必须同时包含 PREFIX：否则已安装到 prefix 的第三方库
# （lz4 / libjpeg / webp / freetype / zstd ...）全部找不到，
# 表现为 "Could NOT find JPEG (missing: JPEG_LIBRARY JPEG_INCLUDE_DIR)"。
# 注意：必须以 list(APPEND ...) 追加，而不是直接 set() 覆盖 ——
# 否则命令行传入的 -DCMAKE_FIND_ROOT_PATH 会被本文件覆盖掉。
if(NOT DEFINED OHOS_EXTRA_PREFIX)
    set(OHOS_EXTRA_PREFIX "${CMAKE_CURRENT_LIST_DIR}/../prefix")
endif()

set(CMAKE_FIND_ROOT_PATH "${OHOS_SYSROOT}")
if(EXISTS "${OHOS_EXTRA_PREFIX}")
    list(APPEND CMAKE_FIND_ROOT_PATH "${OHOS_EXTRA_PREFIX}")
endif()

# PROGRAM 用 BOTH：构建期需要在宿主执行代码生成器（如 libpng 的 genout）。
# LIBRARY/INCLUDE/PACKAGE 用 BOTH 而非 ONLY：
#   ONLY 会连同 prefix 中的库一起排除，导致已装好的依赖不可见。
# 误链宿主库的风险由 --target + sysroot 控制，不需要靠 ONLY 兜底。
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM BOTH)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY BOTH)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE BOTH)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE BOTH)

# 让 find_package 优先在 prefix 中查找
list(APPEND CMAKE_PREFIX_PATH "${OHOS_EXTRA_PREFIX}")

# --- OHOS 的架构专属库/头目录（关键，实测教训）---
#
# OHOS sysroot 把库放在带架构后缀的子目录里：
#     usr/lib/aarch64-linux-ohos/libz.so      <- 实际位置
#     usr/include/aarch64-linux-ohos/bits/    <- 架构专属头
# 而 CMake 默认只找 <root>/usr/lib，于是即便 libz.so 就在那里也会报：
#     Could NOT find ZLIB (missing: ZLIB_LIBRARY)
# 这会连带让 find_package(PNG) 失败 —— FindPNG 把整个查找都包在
# `if(ZLIB_FOUND)` 里，ZLIB 找不到就直接报
#     Could NOT find PNG (missing: PNG_LIBRARY PNG_PNG_INCLUDE_DIR)
# 看起来像 libpng 的问题，实际是 ZLIB。设置 CMAKE_LIBRARY_ARCHITECTURE
# 让 CMake 自动带上该后缀子目录，一次性修好所有 find_library/find_package。
# （与 upstream/ARMSX2/cmake/ohos.toolchain.cmake 的做法保持一致。）
set(CMAKE_LIBRARY_ARCHITECTURE "aarch64-linux-ohos")
list(APPEND CMAKE_LIBRARY_PATH "${OHOS_SYSROOT}/usr/lib/aarch64-linux-ohos")
list(APPEND CMAKE_INCLUDE_PATH "${OHOS_SYSROOT}/usr/include/aarch64-linux-ohos")
