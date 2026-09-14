#!/usr/bin/env bash
# 构建未签名 HAP。签名交给 scripts/sign.sh（或 DevEco 自动签名）。
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEVECO="/Applications/DevEco-Studio.app/Contents"
export DEVECO_SDK_HOME="$DEVECO/sdk"
export JAVA_HOME="$DEVECO/jbr/Contents/Home"
export PATH="$DEVECO/tools/node/bin:$PATH"

cd "$ROOT"
"$DEVECO/tools/ohpm/bin/ohpm" install
"$DEVECO/tools/hvigor/bin/hvigorw" --mode module -p module=entry@default assembleHap --no-daemon
find "$ROOT/entry/build" -name '*.hap' -exec ls -la {} \;
