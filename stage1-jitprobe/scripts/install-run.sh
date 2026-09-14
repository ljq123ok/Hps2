#!/usr/bin/env bash
# 在设备/模拟器上安装并启动探针，随后抓取日志。
# 用法： bash scripts/install-run.sh [hdc-target]
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HDC="/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc"
BUNDLE="com.hps2.jitprobe"
ABILITY="EntryAbility"

TARGET="${1:-}"
if [[ -z "$TARGET" ]]; then
  TARGET="$("$HDC" list targets -v 2>/dev/null | awk '$3=="Connected"{print $1; exit}')"
fi
[[ -n "$TARGET" ]] || { echo "没有可用设备。请连接真机或启动模拟器。" >&2; "$HDC" list targets -v >&2 || true; exit 1; }
echo "target: $TARGET"

# 优先安装已签名产物
HAP="$(ls "$ROOT"/entry/build/default/outputs/default/*signed*.hap 2>/dev/null | head -1 || true)"
[[ -n "$HAP" ]] || HAP="$(find "$ROOT/entry/build" -name '*.hap' | head -1)"
echo "HAP: $HAP"

"$HDC" -t "$TARGET" install -r "$HAP" 2>&1 | tee /tmp/hps2-install.log || true

if grep -q "no signature file" /tmp/hps2-install.log; then
  echo >&2
  echo "真机拒绝未签名 HAP。需要华为签发的 Profile（Debug 证书 + 设备白名单）。" >&2
  echo "可先尝试模拟器：模拟器允许安装未签名 HAP。" >&2
  exit 2
fi

"$HDC" -t "$TARGET" shell aa force-stop "$BUNDLE" >/dev/null 2>&1 || true
"$HDC" -t "$TARGET" shell aa start -b "$BUNDLE" -a "$ABILITY"
sleep 6
echo "==> 抓取 HPS2_JIT 日志 =="
"$HDC" -t "$TARGET" shell hilog -x 2>/dev/null | grep -i "HPS2_JIT" | tail -60 || true
