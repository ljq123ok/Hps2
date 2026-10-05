#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TP="$ROOT/thirdparty-ohos"
SRC="$TP/src"

bash "$ROOT/scripts/setup-thirdparty.sh"

# All outputs go to the ignored, rebuildable prefix. The application links z
# from the OHOS sysroot; zlib's pinned source is retained for dependency/API
# reproducibility but is not separately linked into Hps2.
bash "$TP/scripts/build-lib.sh" zstd "$SRC/zstd/build/cmake" \
  -DZSTD_BUILD_PROGRAMS=OFF -DZSTD_BUILD_TESTS=OFF \
  -DZSTD_BUILD_SHARED=OFF -DZSTD_BUILD_STATIC=ON

bash "$TP/scripts/build-lib.sh" lz4 "$SRC/lz4/build/cmake" \
  -DBUILD_SHARED_LIBS=OFF -DLZ4_BUILD_CLI=OFF \
  -DLZ4_BUILD_LEGACY_LZ4C=OFF -DLZ4_POSITION_INDEPENDENT_LIB=ON

bash "$TP/scripts/build-lib.sh" libjpeg-turbo "$SRC/libjpeg-turbo" \
  -DENABLE_SHARED=OFF -DENABLE_STATIC=ON -DWITH_SIMD=OFF \
  -DWITH_TESTS=OFF -DWITH_TOOLS=OFF

bash "$TP/scripts/build-lib.sh" libpng "$SRC/libpng" \
  -DPNG_SHARED=OFF -DPNG_STATIC=ON -DPNG_TESTS=OFF -DPNG_TOOLS=OFF \
  -DPNG_BUILD_ZLIB=OFF

bash "$TP/scripts/build-lib.sh" libwebp "$SRC/libwebp" \
  -DWEBP_LINK_STATIC=ON -DWEBP_BUILD_ANIM_UTILS=OFF \
  -DWEBP_BUILD_CWEBP=OFF -DWEBP_BUILD_DWEBP=OFF \
  -DWEBP_BUILD_EXTRAS=OFF -DWEBP_BUILD_FUZZTEST=OFF \
  -DWEBP_BUILD_GIF2WEBP=OFF -DWEBP_BUILD_IMG2WEBP=OFF \
  -DWEBP_BUILD_VWEBP=OFF -DWEBP_BUILD_WEBPINFO=OFF

bash "$TP/scripts/build-lib.sh" freetype "$SRC/freetype" \
  -DBUILD_SHARED_LIBS=OFF -DFT_DISABLE_BZIP2=TRUE \
  -DFT_DISABLE_BROTLI=TRUE -DFT_DISABLE_HARFBUZZ=TRUE

# These are part of the pinned ARMSX2 source tree rather than thirdparty-ohos/src.
bash "$TP/scripts/build-lib.sh" plutovg "$ROOT/upstream/ARMSX2/3rdparty/plutovg"
bash "$TP/scripts/build-lib.sh" plutosvg "$ROOT/upstream/ARMSX2/3rdparty/plutosvg"

# SDL's OHOS configuration needs the repository's dedicated compatibility shim.
bash "$TP/scripts/build-sdl3-ohos.sh"

required=(libzstd.a liblz4.a libpng.a libjpeg.a libwebp.a libwebpdemux.a \
  libwebpmux.a libsharpyuv.a libfreetype.a libplutovg.a libplutosvg.a libSDL3.a)
for file in "${required[@]}"; do
  [[ -f "$TP/prefix/lib/$file" ]] || { echo "Missing library: $TP/prefix/lib/$file" >&2; exit 1; }
done
[[ -f "$TP/compat/libohos_musl_compat.a" ]] || {
  echo "Missing OHOS musl compatibility archive" >&2; exit 1;
}
echo "Third-party OHOS static libraries are ready in $TP/prefix/lib"
