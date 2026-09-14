#!/usr/bin/env bash
#
# 统一的 OHOS 第三方库构建脚本。
#
# 设计目的：让多个库能用完全一致的方式构建，产物安装到统一前缀，
# 避免各库各自为政导致的 ABI/路径不一致。
#
# 用法：
#   bash build-lib.sh <lib-name> <source-dir> [cmake-args...]
#
# 环境变量：
#   PREFIX     安装前缀（默认 thirdparty-ohos/prefix）
#   BUILD_ROOT 构建目录（默认 thirdparty-ohos/build）
#   JOBS       并行度（默认 CPU 核数）
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEVECO="/Applications/DevEco-Studio.app/Contents"
CMAKE_BIN="$DEVECO/sdk/default/openharmony/native/build-tools/cmake/bin/cmake"
export PATH="$(dirname "$CMAKE_BIN"):$PATH"

PREFIX="${PREFIX:-$ROOT/prefix}"
BUILD_ROOT="${BUILD_ROOT:-$ROOT/build}"
JOBS="${JOBS:-$(sysctl -n hw.ncpu 2>/dev/null || echo 8)}"

LIB="${1:?用法: build-lib.sh <lib-name> <source-dir> [cmake-args...]}"
SRC="${2:?缺少源码目录}"
shift 2 || true

BUILD_DIR="$BUILD_ROOT/$LIB"
LOG_DIR="$ROOT/logs"
mkdir -p "$BUILD_DIR" "$PREFIX" "$LOG_DIR"
LOG="$LOG_DIR/$LIB.log"

echo "==> 构建 $LIB"
echo "    源码: $SRC"
echo "    构建: $BUILD_DIR"
echo "    安装: $PREFIX"
echo "    日志: $LOG"

if [[ ! -d "$SRC" ]]; then
  echo "错误：源码目录不存在: $SRC" >&2
  exit 1
fi

"$CMAKE_BIN" -S "$SRC" -B "$BUILD_DIR" \
  -DCMAKE_TOOLCHAIN_FILE="$ROOT/cmake/ohos-common-toolchain.cmake" \
  -DCMAKE_INSTALL_PREFIX="$PREFIX" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
  -DBUILD_SHARED_LIBS=OFF \
  -DOHOS_SDK_NATIVE="$DEVECO/sdk/default/openharmony/native" \
  "$@" > "$LOG" 2>&1 || { echo "配置失败，见 $LOG"; tail -30 "$LOG"; exit 1; }

"$CMAKE_BIN" --build "$BUILD_DIR" --parallel "$JOBS" >> "$LOG" 2>&1 \
  || { echo "编译失败，见 $LOG"; tail -30 "$LOG"; exit 1; }

"$CMAKE_BIN" --install "$BUILD_DIR" >> "$LOG" 2>&1 \
  || { echo "安装失败，见 $LOG"; tail -30 "$LOG"; exit 1; }

echo "==> $LIB 完成"
find "$PREFIX" -name "*${LIB}*" -o -name "lib${LIB}*" 2>/dev/null | head -5
