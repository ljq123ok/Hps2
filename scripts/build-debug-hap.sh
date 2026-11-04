#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEVECO="${DEVECO_HOME:-/Applications/DevEco-Studio.app/Contents}"
CMAKE="$DEVECO/sdk/default/openharmony/native/build-tools/cmake/bin/cmake"
HVIGOR="$DEVECO/tools/hvigor/bin/hvigorw"
USE_VULKAN="${HPS2_USE_VULKAN:-OFF}"
case "$USE_VULKAN" in ON|OFF) ;; *) echo "HPS2_USE_VULKAN must be ON or OFF" >&2; exit 1 ;; esac
DEFAULT_BUILD_DIR="$HOME/.cache/hps2-build"
if [[ "$USE_VULKAN" == ON ]]; then DEFAULT_BUILD_DIR="$HOME/.cache/hps2-build-vulkan"; fi
ARMSX2_BUILD_DIR="${HPS2_ARMSX2_BUILD_DIR:-$DEFAULT_BUILD_DIR}"

[[ -x "$CMAKE" ]] || { echo "DevEco CMake not found: $CMAKE (set DEVECO_HOME)" >&2; exit 1; }
[[ -x "$HVIGOR" ]] || { echo "DevEco Hvigor not found: $HVIGOR (set DEVECO_HOME)" >&2; exit 1; }
bash "$ROOT/scripts/setup-upstream.sh"
bash "$ROOT/scripts/verify-upstream.sh"
bash "$ROOT/scripts/build-thirdparty-ohos.sh"
RENDERER_CMAKE_ARGS=("-DUSE_VULKAN=$USE_VULKAN")
if [[ "$USE_VULKAN" == ON ]]; then
  bash "$ROOT/scripts/build-shaderc-ohos.sh"
  RENDERER_CMAKE_ARGS+=("-DSHADERC_LIBRARY:FILEPATH=$ROOT/thirdparty-ohos/prefix/lib/libshaderc_combined.a")
fi

export HPS2_ARMSX2_BUILD_DIR="$ARMSX2_BUILD_DIR"
export DEVECO_SDK_HOME="$DEVECO/sdk"
"$CMAKE" -S "$ROOT/upstream/ARMSX2" -B "$ARMSX2_BUILD_DIR" \
  -DCMAKE_TOOLCHAIN_FILE="$ROOT/upstream/ARMSX2/cmake/ohos.toolchain.cmake" \
  -DCMAKE_BUILD_TYPE=Release -DDISABLE_ADVANCE_SIMD=OFF \
  "-DCMAKE_CXX_FLAGS=-ffile-prefix-map=$ROOT=hps2-src" \
  "-DCMAKE_C_FLAGS=-ffile-prefix-map=$ROOT=hps2-src" \
  -DENABLE_TESTS=OFF -DENABLE_RECOMPILER_TEST_HOOKS=OFF \
  "-DLTO_PCSX2_CORE=$USE_VULKAN" \
  -DUSE_OPENGL=ON -DENABLE_QT_UI=OFF \
  -DENABLE_QT_DEBUGGER=OFF -DWAYLAND_API=OFF -DX11_API=OFF "${RENDERER_CMAKE_ARGS[@]}"
"$CMAKE" --build "$ARMSX2_BUILD_DIR" --target PCSX2_CORE_STATIC --parallel "${HPS2_BUILD_JOBS:-6}"

# Hvigor does not track shell environment changes as native configure inputs.
# Refresh an existing native cache explicitly when switching GL/Vulkan cores.
NATIVE_BUILD_DIR="$ROOT/app-hps2/entry/.cxx/default/default/debug/arm64-v8a"
if [[ -f "$NATIVE_BUILD_DIR/CMakeCache.txt" ]]; then
  "$CMAKE" -S "$ROOT/app-hps2/entry/src/main/cpp" -B "$NATIVE_BUILD_DIR" \
    -DARMSX2_BUILD_DIR="$ARMSX2_BUILD_DIR" -DHPS2_STORE_BUILD=OFF
fi

cd "$ROOT/app-hps2"
"$HVIGOR" --mode module -p module=entry@default assembleHap --no-daemon
