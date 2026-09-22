#!/usr/bin/env bash
#
# 为 app-hps2 的 HAP 签名（复用本机调试材料）。
#
# 【为什么需要这个脚本】
#   hvigor 的 SignHap 任务要求 build-profile.json5 里的 storePassword /
#   keyPassword 是 DevEco 加密后的十六进制串（AES-128-GCM，密钥材料在
#   ~/.ohos/config/material），无法离线生成。
#   而工程内的 build-profile.json5 出于隐私考虑已清空签名配置，
#   故改用外部 hap-sign-tool 签名。
#
# 【密文来源】hvigor 的同步缓存保留了原始签名配置：
#   stage1-jitprobe/.hvigor/outputs/sync/output.json
#   本脚本从中读取密文，经 devpwd.js 解密后调用 hap-sign-tool。
#   （该缓存不含密钥本身，安全性等同 build-profile.json5 原有做法。）
#
# 用法：
#   bash stage1-jitprobe/scripts/sign-app-hps2.sh
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DEVECO="/Applications/DevEco-Studio.app/Contents"
JAVA="$DEVECO/jbr/Contents/Home/bin/java"
TOOL="$DEVECO/sdk/default/openharmony/toolchains/lib/hap-sign-tool.jar"
NODE="$DEVECO/tools/node/bin/node"
DEVPROBE="$ROOT/stage1-jitprobe/scripts/devpwd.js"
SYNC="$ROOT/stage1-jitprobe/.hvigor/outputs/sync/output.json"

IN_HAP="$ROOT/app-hps2/entry/build/default/outputs/default/entry-default-unsigned.hap"
OUT_HAP="${OUT_HAP:-/tmp/hps2-debugsigned.hap}"

[[ -f "$IN_HAP" ]] || { echo "缺少未签名产物：$IN_HAP" >&2; exit 1; }
[[ -f "$SYNC" ]]   || { echo "缺少签名配置缓存：$SYNC" >&2; exit 1; }

# 从缓存里取字段（避免明文口令出现在命令行/日志）
read_field() {
  python3 - "$SYNC" "$1" <<'PY'
import json, re, sys
s = open(sys.argv[1]).read()
m = re.search(rf'"{sys.argv[2]}"\s*:\s*"([^"]+)"', s)
print(m.group(1) if m else "")
PY
}

P12="$(read_field storeFile)"
CER="$(read_field certpath)"
P7B="$(read_field profile)"
ALIAS="$(read_field keyAlias)"
SPW_C="$(read_field storePassword)"
KPW_C="$(read_field keyPassword)"

for f in "$P12" "$CER" "$P7B"; do
  [[ -f "$f" ]] || { echo "缺少签名材料：$f" >&2; exit 1; }
done

# 解密口令。
# devpwd.js 把口令写入 HPS2_PWD_OUT（默认 /tmp/hps2_pwd.txt），不回显明文。
PWD_OUT="$(mktemp)"
export HPS2_PWD_OUT="$PWD_OUT"
"$NODE" "$DEVPROBE" "$SPW_C" >/dev/null
SP="$(cat "$PWD_OUT")"
"$NODE" "$DEVPROBE" "$KPW_C" >/dev/null
KP="$(cat "$PWD_OUT")"
rm -f "$PWD_OUT"

"$JAVA" -jar "$TOOL" sign-app \
  -mode localSign \
  -keyAlias "$ALIAS" \
  -keyPwd "$KP" \
  -appCertFile "$CER" \
  -profileFile "$P7B" \
  -profileSigned 1 \
  -inFile "$IN_HAP" \
  -signAlg SHA256withECDSA \
  -keystoreFile "$P12" \
  -keystorePwd "$SP" \
  -outFile "$OUT_HAP"

echo "已签名：$OUT_HAP"
