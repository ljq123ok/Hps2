#!/usr/bin/env bash
#
# Build SDL3 (library only) for HarmonyOS / OHOS aarch64, install to the shared
# thirdparty-ohos prefix. Reproduces the working recipe verified on 2025-09.
#
# Usage: bash scripts/build-sdl3-ohos.sh
#
# Why this wrapper exists instead of a bare build-lib.sh call:
#
#  1. SDL_UNIX_CONSOLE_BUILD=ON
#     SDL's cmake/macros.cmake raises FATAL_ERROR if neither X11 nor Wayland is
#     found on a UNIX build. OHOS has neither. This flag is SDL's documented
#     opt-out (docs/README-cmake.md) for "no desktop windows" targets.
#
#  2. libohos_musl_compat.a
#     OHOS pthread.h line ~80 DEFINES PTHREAD_CANCEL_ASYNCHRONOUS but the NDK
#     sysroot neither declares nor exports pthread_setcanceltype(). SDL3's
#     src/thread/pthread/SDL_systhread.c guards the call with
#     "#ifdef PTHREAD_CANCEL_ASYNCHRONOUS", so the guard passes and the SHARED
#     library fails to link:
#         ld.lld: error: undefined symbol: pthread_setcanceltype
#     Note: -UPTHREAD_CANCEL_ASYNCHRONOUS does NOT work -- <pthread.h>
#     re-defines the macro after the command line, so the #ifdef still fires.
#     We therefore supply the symbol from our own compat shim rather than
#     patching SDL source (SDL's AGENTS.md asks that AI not author code there).
#
# The static library (libSDL3.a) builds fine even WITHOUT the shim; only the
# shared library needs it.
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NDK="/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/native"
CLANG="$NDK/llvm/bin/clang"
AR="$NDK/llvm/bin/llvm-ar"
COMPAT_DIR="$ROOT/compat"
COMPAT_SRC="$COMPAT_DIR/ohos_musl_compat.c"
COMPAT_LIB="$COMPAT_DIR/libohos_musl_compat.a"

# --- 1. Build the musl compat shim (if needed) -------------------------------
if [[ ! -f "$COMPAT_LIB" || "$COMPAT_SRC" -nt "$COMPAT_LIB" ]]; then
  echo "==> 构建 musl compat shim"
  mkdir -p "$COMPAT_DIR"
  "$CLANG" --target=aarch64-linux-ohos --sysroot="$NDK/sysroot" \
    -O2 -fPIC -c "$COMPAT_SRC" -o "$COMPAT_DIR/ohos_musl_compat.o"
  "$AR" rcs "$COMPAT_LIB" "$COMPAT_DIR/ohos_musl_compat.o"
fi

# --- 2. Configure + build + install SDL3 (library only) ----------------------
rm -rf "$ROOT/build/sdl3"

bash "$ROOT/scripts/build-lib.sh" sdl3 "$ROOT/src/sdl3" \
  -DSDL_UNIX_CONSOLE_BUILD=ON \
  -DSDL_TESTS=OFF \
  -DSDL_EXAMPLES=OFF \
  -DSDL_INSTALL_TESTS=OFF \
  -DSDL_TEST_LIBRARY=OFF \
  -DSDL_SHARED=ON \
  -DSDL_STATIC=ON \
  -DSDL_DISABLE_INSTALL_DOCS=ON \
  -DCMAKE_C_STANDARD_LIBRARIES="$COMPAT_LIB"

# --- 3. Verify the artifacts are genuine aarch64 -----------------------------
echo "==> 验证产物"
"$NDK/llvm/bin/llvm-readelf" -h "$ROOT/prefix/lib/libSDL3.so.0.5.0" \
  | grep -E "Class|Machine|Type"
echo "==> SDL3 完成: $ROOT/prefix/lib/libSDL3.{a,so}"
