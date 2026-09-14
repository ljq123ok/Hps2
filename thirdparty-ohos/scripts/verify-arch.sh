#!/usr/bin/env bash
#
# 验证第三方库是否为真正的 OHOS aarch64 产物。
#
# 为什么需要这个脚本：`file libfoo.a` 只会说 "current ar archive"，
# 不能证明里面的目标文件是 aarch64。必须解出一个成员再判断。
#
# 用法： bash verify-arch.sh [前缀目录]
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PREFIX="${1:-$ROOT/prefix}"
AR="/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/native/llvm/bin/llvm-ar"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "验证 $PREFIX 下的静态库架构"
echo

fail=0
total=0
for lib in "$PREFIX"/lib/*.a; do
  [ -f "$lib" ] || continue
  total=$((total+1))
  name="$(basename "$lib")"

  # 取第一个成员
  obj="$("$AR" t "$lib" 2>/dev/null | head -1)"
  if [ -z "$obj" ]; then
    printf "  %-24s ⚠️  读取失败\n" "$name"
    fail=$((fail+1)); continue
  fi

  rm -rf "$TMP/x"; mkdir -p "$TMP/x"
  ( cd "$TMP/x" && "$AR" x "$lib" "$obj" ) 2>/dev/null
  if [ ! -f "$TMP/x/$obj" ]; then
    printf "  %-24s ⚠️  解包失败\n" "$name"
    fail=$((fail+1)); continue
  fi

  if file "$TMP/x/$obj" 2>/dev/null | grep -q "aarch64"; then
    printf "  %-24s ✅ aarch64\n" "$name"
  else
    printf "  %-24s ❌ 非 aarch64: %s\n" "$name" "$(file -b "$TMP/x/$obj" 2>/dev/null | head -c 60)"
    fail=$((fail+1))
  fi
done

echo
echo "结果：$((total-fail))/$total 通过"
[ "$fail" -eq 0 ] || exit 1
