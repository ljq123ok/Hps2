#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT/thirdparty-ohos/src"
HPS2_THIRDPARTY_LOCK="$ROOT/thirdparty-ohos/vulkan-sources.lock.json" \
  bash "$ROOT/scripts/setup-thirdparty.sh"
bash "$ROOT/thirdparty-ohos/scripts/build-lib.sh" shaderc "$SRC/shaderc" \
  -DSHADERC_SKIP_TESTS=ON -DSHADERC_SKIP_EXAMPLES=ON \
  -DSHADERC_SKIP_EXECUTABLES=ON -DSHADERC_SKIP_COPYRIGHT_CHECK=ON \
  -DSHADERC_ENABLE_WERROR_COMPILE=OFF -DSPIRV_SKIP_TESTS=ON \
  -DSPIRV_SKIP_EXECUTABLES=ON -DENABLE_GLSLANG_BINARIES=OFF \
  -DSHADERC_SPIRV_TOOLS_DIR="$SRC/spirv-tools" \
  -DSHADERC_SPIRV_HEADERS_DIR="$SRC/spirv-headers" \
  -DSHADERC_GLSLANG_DIR="$SRC/glslang" \
  -DSPIRV-Headers_SOURCE_DIR="$SRC/spirv-headers"
test -f "$ROOT/thirdparty-ohos/prefix/lib/libshaderc_combined.a"
