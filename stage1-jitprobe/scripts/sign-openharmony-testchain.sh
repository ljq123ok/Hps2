#!/usr/bin/env bash
#
# 用 SDK 自带的 OpenHarmony 测试签名链为 HAP 签名。
#
# 用途与限制（重要）：
#   - 该链的根是 **OpenHarmony Application Root CA**；
#   - **模拟器接受**该链（本仓库已实测：安装成功且探针 PASS=8 FAIL=1）；
#   - **华为真机拒绝**该链：HapVerify 报
#       "it do not come from trusted root, issuer: ... OpenHarmony Application Root CA"
#     因为真机只信任 **Huawei CBG** 签发链。
#   => 因此本脚本只用于模拟器验证；真机需用 AGC 签发的 profile（见 sign.sh）。
#
# 用法：
#   bash scripts/sign-openharmony-testchain.sh <未签名HAP> <输出HAP>
set -euo pipefail

IN_HAP="${1:?用法: $0 <未签名HAP> <输出HAP>}"
OUT_HAP="${2:?用法: $0 <未签名HAP> <输出HAP>}"

DEVECO="/Applications/DevEco-Studio.app/Contents"
JAVA="$DEVECO/jbr/Contents/Home/bin/java"
TOOL="$DEVECO/sdk/default/openharmony/toolchains/lib/hap-sign-tool.jar"
TC="$DEVECO/sdk/default/openharmony/toolchains/lib"
KEYTOOL="$DEVECO/jbr/Contents/Home/bin/keytool"
STORE_PW="123456"          # SDK 公开测试密钥库口令（OpenHarmony 官方测试材料）
BUNDLE="com.hps2.jitprobe"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# 1) 生成绑定 bundle 与设备 UDID 的 debug profile
python3 - "$TC/UnsgnedDebugProfileTemplate.json" "$WORK/profile.json" "$BUNDLE" <<'PY'
import json,sys
src,dst,bundle=sys.argv[1],sys.argv[2],sys.argv[3]
d=json.load(open(src))
d['bundle-info']['bundle-name']=bundle
d['bundle-info']['developer-id']='hps2'
# 设备白名单交给调用方按需追加；此处先清空，模拟器不校验 UDID
d['debug-info']['device-ids']=[]
json.dump(d,open(dst,'w'),ensure_ascii=False,indent=2)
PY

# 2) 签名 profile
"$JAVA" -jar "$TOOL" sign-profile -mode localSign \
  -keyAlias "openharmony application profile release" -keyPwd "$STORE_PW" \
  -profileCertFile "$TC/OpenHarmonyProfileRelease.pem" \
  -inFile "$WORK/profile.json" -signAlg SHA256withECDSA \
  -keystoreFile "$TC/OpenHarmony.p12" -keystorePwd "$STORE_PW" \
  -outFile "$WORK/profile.p7b" >/dev/null

# 3) 组装三级证书链（leaf -> CA -> root）。
#    leaf 取自 profile 模板（其 issuer=Application CA，才是正确的非自签证书）。
python3 - "$TC/UnsgnedDebugProfileTemplate.json" "$WORK/leaf.pem" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
open(sys.argv[2],'w').write(d['bundle-info']['development-certificate'])
PY
"$KEYTOOL" -exportcert -rfc -alias "openharmony application ca" \
  -keystore "$TC/OpenHarmony.p12" -storetype PKCS12 -storepass "$STORE_PW" \
  -file "$WORK/ca.pem" 2>/dev/null
"$KEYTOOL" -exportcert -rfc -alias "openharmony application root ca" \
  -keystore "$TC/OpenHarmony.p12" -storetype PKCS12 -storepass "$STORE_PW" \
  -file "$WORK/root.pem" 2>/dev/null
cat "$WORK/leaf.pem" "$WORK/ca.pem" "$WORK/root.pem" > "$WORK/chain.pem"

# 4) 签名 HAP
"$JAVA" -jar "$TOOL" sign-app -mode localSign \
  -keyAlias "openharmony application release" -keyPwd "$STORE_PW" \
  -appCertFile "$WORK/chain.pem" -profileFile "$WORK/profile.p7b" -profileSigned 1 \
  -inFile "$IN_HAP" -signAlg SHA256withECDSA \
  -keystoreFile "$TC/OpenHarmony.p12" -keystorePwd "$STORE_PW" \
  -outFile "$OUT_HAP"

echo "已签名（OpenHarmony 测试链，仅模拟器可用）: $OUT_HAP"
