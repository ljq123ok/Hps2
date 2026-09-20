#!/usr/bin/env bash
#
# 真机验证一键脚本：构建 → 签名 → 安装 → 运行 → 抓证据
#
# 前提：签名材料只从本机环境读取，不写入仓库。
#       可先配置 HPS2_SIGN_DIR、HPS2_KEY_ALIAS、HPS2_KEY_PWD；
#       HPS2_SIGN_DIR 内应包含 app.p12、app.cer、app.p7b。
#
# 用法： bash scripts/verify-on-device.sh [hdc-target]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEVECO="/Applications/DevEco-Studio.app/Contents"
JAVA="$DEVECO/jbr/Contents/Home/bin/java"
TOOL="$DEVECO/sdk/default/openharmony/toolchains/lib/hap-sign-tool.jar"
HDC="$DEVECO/sdk/default/openharmony/toolchains/hdc"
NODE="$DEVECO/tools/node/bin/node"
BUNDLE="com.hps2.jitprobe"
ABILITY="EntryAbility"
EVID="$ROOT/../docs/evidence"
mkdir -p "$EVID"

TARGET="${1:-}"
[[ -n "$TARGET" ]] || TARGET="$("$HDC" list targets -v | awk '$3=="Connected" && $2=="USB"{print $1; exit}')"
[[ -n "$TARGET" ]] || { echo "未找到 USB 真机（忽略模拟器）" >&2; "$HDC" list targets -v >&2; exit 1; }
echo "==> 真机 target: $TARGET"

# --- 1) 构建 ---
echo "==> 构建"
# JAVA_HOME 必须指向 JDK 根目录（不是 java 可执行文件），否则 hvigor 启动失败
export DEVECO_SDK_HOME="$DEVECO/sdk"
export JAVA_HOME="$DEVECO/jbr/Contents/Home"
export PATH="$DEVECO/tools/node/bin:$PATH"
cd "$ROOT"
"$DEVECO/tools/ohpm/bin/ohpm" install >/dev/null
"$DEVECO/tools/hvigor/bin/hvigorw" --mode module -p module=entry@default assembleHap --no-daemon 2>&1 | tail -3

UNSIGNED="$ROOT/entry/build/default/outputs/default/entry-default-unsigned.hap"
SIGNED="$ROOT/entry/build/default/outputs/default/entry-default-signed.hap"
OUT_HAP="${SIGNED}"
if [[ ! -f "$OUT_HAP" ]]; then
  echo "==> hvigor 未产出已签名 HAP，使用本机外部签名材料"
  SIGN_DIR="\${HPS2_SIGN_DIR:-}"
  KEY_PWD="\${HPS2_KEY_PWD:-}"
  ALIAS="\${HPS2_KEY_ALIAS:-app}"
  [[ -n "$SIGN_DIR" ]] || {
    echo "请设置 HPS2_SIGN_DIR（目录内包含 app.p12/app.cer/app.p7b）" >&2
    exit 1
  }
  [[ -n "$KEY_PWD" ]] || {
    echo "请设置 HPS2_KEY_PWD（签名材料口令）" >&2
    exit 1
  }
  CER="$SIGN_DIR/app.cer"
  P7B="$SIGN_DIR/app.p7b"
  P12="$SIGN_DIR/app.p12"
  OUT_HAP="$ROOT/entry/build/default/outputs/default/entry-default-manualsigned.hap"
  "$JAVA" -jar "$TOOL" sign-app -mode localSign \
    -keyAlias "$ALIAS" -keyPwd "$KEY_PWD" -appCertFile "$CER" \
    -profileFile "$P7B" -profileSigned 1 -inFile "$UNSIGNED" \
    -signAlg SHA256withECDSA -keystoreFile "$P12" -keystorePwd "$KEY_PWD" \
    -outFile "$OUT_HAP" 2>&1 | tail -2
fi
echo "==> 待安装: $OUT_HAP"

# --- 2) 安装 ---
echo "==> 安装到真机"
"$HDC" -t "$TARGET" shell hilog -r >/dev/null 2>&1 || true
INSTALL_LOG="$EVID/stage1-device-install.txt"
"$HDC" -t "$TARGET" install -r "$OUT_HAP" 2>&1 | tee "$INSTALL_LOG"

# --- 3) 运行并抓取 ---
echo "==> 启动并抓取探针输出"
"$HDC" -t "$TARGET" shell aa force-stop "$BUNDLE" >/dev/null 2>&1 || true
sleep 2
"$HDC" -t "$TARGET" shell aa start -b "$BUNDLE" -a "$ABILITY" 2>&1 | tail -1
sleep 15

OUT="$EVID/stage1-device-log.txt"
{
  echo "# HPS2 阶段 1 探针 —— 真机实测日志"
  echo "# target : $TARGET"
  printf "# device : "; "$HDC" -t "$TARGET" shell param get const.product.name 2>/dev/null | tr -d '\r'
  printf "# os     : "; "$HDC" -t "$TARGET" shell param get const.ohos.fullname 2>/dev/null | tr -d '\r'
  printf "# api    : "; "$HDC" -t "$TARGET" shell param get const.ohos.apiversion 2>/dev/null | tr -d '\r'
  echo "# 时间   : $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  echo
  "$HDC" -t "$TARGET" shell hilog -x 2>/dev/null | grep -i "HPS2_JIT"
  echo
  echo "## SELinux / XPM 拒绝记录（若有）"
  "$HDC" -t "$TARGET" shell hilog -x 2>/dev/null | grep -iE "avc:|denied|xpm|execmem" | tail -20 || true
} > "$OUT" 2>&1

echo
echo "=========== 探针结果 ==========="
grep -E "探针结束|basicReturn|\[OK\]|\[FAIL\]" "$OUT" | tail -15 || tail -5 "$OUT"
echo "完整日志: $OUT"
