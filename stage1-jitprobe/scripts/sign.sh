#!/usr/bin/env bash
# 用官方 hap-sign-tool 为 HAP 签名。
#
# 为什么不交给 hvigor：其 SignHap 任务要求 build-profile.json5 里的
# storePassword / keyPassword 是 DevEco 加密后的十六进制串
# （AES-128-GCM，密钥材料在 ~/.ohos/config/material），无法离线生成。
#
# 默认使用本机已有的调试证书材料（~/.ohos/config/default_arktunnel_*）。
# 若要用「含 JIT ACL 的 Profile」签名，把 HPS2_SIGN_DIR 指向你的材料目录，
# 并保证其中三件套文件名如下：
#   app.p12 / app.cer / app.p7b
#
# 用法：
#   HPS2_KEY_PWD=xxx bash scripts/sign.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEVECO="/Applications/DevEco-Studio.app/Contents"
JAVA="$DEVECO/jbr/Contents/Home/bin/java"
TOOL="$DEVECO/sdk/default/openharmony/toolchains/lib/hap-sign-tool.jar"

OUT_DIR="$ROOT/entry/build/default/outputs/default"
IN_HAP="$OUT_DIR/entry-default-unsigned.hap"
OUT_HAP="$OUT_DIR/entry-default-signed.hap"

# 选择签名材料
if [[ -n "${HPS2_SIGN_DIR:-}" ]]; then
  SIGN_DIR="$HPS2_SIGN_DIR"
  KEY_ALIAS="${HPS2_KEY_ALIAS:-app}"
  P12="$SIGN_DIR/app.p12"; CER="$SIGN_DIR/app.cer"; P7B="$SIGN_DIR/app.p7b"
else
  SIGN_DIR="$HOME/.ohos/config"
  KEY_ALIAS="${HPS2_KEY_ALIAS:-default_arktunnel}"
  P12="$(ls "$SIGN_DIR"/default_arktunnel_*.p12 2>/dev/null | head -1 || true)"
  CER="$(ls "$SIGN_DIR"/default_arktunnel_*.cer 2>/dev/null | head -1 || true)"
  P7B="$(ls "$SIGN_DIR"/default_arktunnel_*.p7b 2>/dev/null | head -1 || true)"
fi

: "${HPS2_KEY_PWD:?请设置 HPS2_KEY_PWD（密钥库口令）}"
[[ -f "$IN_HAP" ]] || { echo "缺少未签名产物，请先运行 scripts/build.sh" >&2; exit 1; }
for f in "$P12" "$CER" "$P7B"; do
  [[ -f "$f" ]] || { echo "缺少签名材料: $f" >&2; exit 1; }
done

"$JAVA" -jar "$TOOL" sign-app \
  -mode localSign \
  -keyAlias "$KEY_ALIAS" \
  -keyPwd "$HPS2_KEY_PWD" \
  -appCertFile "$CER" \
  -profileFile "$P7B" \
  -profileSigned 1 \
  -inFile "$IN_HAP" \
  -signAlg SHA256withECDSA \
  -keystoreFile "$P12" \
  -keystorePwd "$HPS2_KEY_PWD" \
  -outFile "$OUT_HAP"

echo "已签名: $OUT_HAP"
