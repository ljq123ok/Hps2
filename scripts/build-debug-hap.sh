#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEVECO="${DEVECO_HOME:-/Applications/DevEco-Studio.app/Contents}"
CMAKE="$DEVECO/sdk/default/openharmony/native/build-tools/cmake/bin/cmake"
HVIGOR="$DEVECO/tools/hvigor/bin/hvigorw"
ARMSX2_BUILD_DIR="${HPS2_ARMSX2_BUILD_DIR:-$HOME/.cache/hps2-build}"

[[ -x "$CMAKE" ]] || { echo "DevEco CMake not found: $CMAKE (set DEVECO_HOME)" >&2; exit 1; }
[[ -x "$HVIGOR" ]] || { echo "DevEco Hvigor not found: $HVIGOR (set DEVECO_HOME)" >&2; exit 1; }
bash "$ROOT/scripts/setup-upstream.sh"
bash "$ROOT/scripts/verify-upstream.sh"
bash "$ROOT/scripts/build-thirdparty-ohos.sh"

export HPS2_ARMSX2_BUILD_DIR="$ARMSX2_BUILD_DIR"
export DEVECO_SDK_HOME="$DEVECO/sdk"
"$CMAKE" -S "$ROOT/upstream/ARMSX2" -B "$ARMSX2_BUILD_DIR" \
  -DCMAKE_TOOLCHAIN_FILE="$ROOT/upstream/ARMSX2/cmake/ohos.toolchain.cmake" \
  -DCMAKE_BUILD_TYPE=Release -DDISABLE_ADVANCE_SIMD=ON \
  -DUSE_VULKAN=OFF -DUSE_OPENGL=ON -DENABLE_QT_UI=OFF \
  -DENABLE_QT_DEBUGGER=OFF -DWAYLAND_API=OFF -DX11_API=OFF
"$CMAKE" --build "$ARMSX2_BUILD_DIR" --target PCSX2_CORE_STATIC --parallel

cd "$ROOT/app-hps2"
"$HVIGOR" --mode module -p module=entry@default assembleHap --no-daemon
