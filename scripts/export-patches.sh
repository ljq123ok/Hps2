#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UPSTREAM="$ROOT/upstream/ARMSX2"
LOCK="$ROOT/patches/upstream.json"
PATCH="$ROOT/patches/upstream/0001-hps2-ohos-bringup-complete.patch"
BASE="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["commit"])' "$LOCK")"

if [[ ! -d "$UPSTREAM/.git" ]]; then
  echo "Missing upstream checkout: $UPSTREAM" >&2
  exit 1
fi
if ! git -C "$UPSTREAM" cat-file -e "$BASE^{commit}" 2>/dev/null || \
   ! git -C "$UPSTREAM" merge-base --is-ancestor "$BASE" HEAD; then
	 echo "Upstream HEAD must contain pinned base $BASE; refusing to export." >&2
	 exit 1
fi

TMP_PATCH="$(mktemp)"
TMP_INDEX="$(mktemp)"
GIT_DIR="$(git -C "$UPSTREAM" rev-parse --absolute-git-dir)"
cp "$GIT_DIR/index" "$TMP_INDEX"
trap 'rm -f "$TMP_PATCH" "$TMP_INDEX"' EXIT

while IFS= read -r -d '' file; do
  GIT_INDEX_FILE="$TMP_INDEX" git -C "$UPSTREAM" add -N -- "$file"
done < <(git -C "$UPSTREAM" ls-files --others --exclude-standard -z -- . \
  ':(exclude)platforms' ':(exclude)*.png' ':(exclude)*.jpg')

GIT_INDEX_FILE="$TMP_INDEX" git -C "$UPSTREAM" diff --binary "$BASE" --diff-filter=d -- . \
  ':(exclude)platforms' ':(exclude)*.png' ':(exclude)*.jpg' > "$TMP_PATCH"
git -C "$UPSTREAM" diff --check -- . \
  ':(exclude)platforms' ':(exclude)*.png' ':(exclude)*.jpg'

mkdir -p "$(dirname "$PATCH")"
install -m 0644 "$TMP_PATCH" "$PATCH"
echo "Exported $(grep -c '^diff --git ' "$PATCH") upstream files to ${PATCH#"$ROOT"/}"
echo "SHA256=$(shasum -a 256 "$PATCH" | awk '{print $1}')"
