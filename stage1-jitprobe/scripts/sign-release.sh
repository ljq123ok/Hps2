#!/usr/bin/env bash
#
# 用 AGC 签发的「发布证书 + 发布 Profile」签名 HAP，
# 用于验证正式发布签名下的 JIT 可用性。
#
# 背景：
#   debug 签名 → 应用运行在 debug_hap 域
#   release 签名 → 应用运行在 normal_hap 域
#   而 SELinux 策略中 xpm:exec_anon_mem 的豁免名单**只含 debug_hap**，
#   不含 normal_hap。因此 release 下 JIT 是否可用必须单独实测。
#
# 前置材料（放在 .release-signing/ 下）：
#   hps2-release.p12    本次生成的私钥（已就绪）
#   hps2-release.cer    AGC 用 CSR 签发的发布证书（待获取）
#   hps2-release.p7b    AGC 签发的发布 Profile（待获取）
#
# 用法：
#   HPS2_REL_PWD=<密钥库口令> bash scripts/sign-release.sh
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO="$(cd "$ROOT/.." && pwd)"
DEVECO="/Applications/DevEco-Studio.app/Contents"
JAVA="$DEVECO/jbr/Contents/Home/bin/java"
TOOL="$DEVECO/sdk/default/openharmony/toolchains/lib/hap-sign-tool.jar"

SIGN_DIR="$REPO/.release-signing"
P12="$SIGN_DIR/hps2-release.p12"
CER="$SIGN_DIR/hps2-release.cer"
P7B="$SIGN_DIR/hps2-release.p7b"

OUT_DIR="$ROOT/entry/build/default/outputs/default"
IN_HAP="$OUT_DIR/entry-default-unsigned.hap"
OUT_HAP="$OUT_DIR/entry-default-releasesigned.hap"

: "${HPS2_REL_PWD:?请设置 HPS2_REL_PWD（release 密钥库口令）}"

for f in "$P12" "$CER" "$P7B"; do
  [[ -f "$f" ]] || { echo "缺少签名材料: $f" >&2; exit 1; }
done
[[ -f "$IN_HAP" ]] || { echo "缺少未签名产物，请先运行 scripts/build.sh" >&2; exit 1; }

"$JAVA" -jar "$TOOL" sign-app \
  -mode localSign \
  -keyAlias "hps2-release" \
  -keyPwd "$HPS2_REL_PWD" \
  -appCertFile "$CER" \
  -profileFile "$P7B" \
  -profileSigned 1 \
  -inFile "$IN_HAP" \
  -signAlg SHA384withECDSA \
  -keystoreFile "$P12" \
  -keystorePwd "$HPS2_REL_PWD" \
  -outFile "$OUT_HAP"

echo "已签名（release）: $OUT_HAP"
