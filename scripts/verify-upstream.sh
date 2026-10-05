#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UPSTREAM="$ROOT/upstream/ARMSX2"
BASE="d7e8d01678107f066d6ec988ca178d80089bd9f5"
PATCH="$ROOT/patches/upstream/0001-hps2-ohos-bringup-complete.patch"

if [[ ! -d "$UPSTREAM/.git" ]]; then
  echo "Upstream checkout is missing. Run: bash scripts/setup-upstream.sh" >&2
  exit 1
fi
if ! git -C "$UPSTREAM" cat-file -e "$BASE^{commit}" 2>/dev/null || \
   ! git -C "$UPSTREAM" merge-base --is-ancestor "$BASE" HEAD; then
  echo "Upstream history does not contain pinned base commit $BASE" >&2
  exit 1
fi

TMP_DIFF="$(mktemp)"
TMP_INDEX="$(mktemp)"
trap 'rm -f "$TMP_DIFF" "$TMP_INDEX"' EXIT
GIT_DIR="$(git -C "$UPSTREAM" rev-parse --absolute-git-dir)"
cp "$GIT_DIR/index" "$TMP_INDEX"
while IFS= read -r -d '' file; do
  GIT_INDEX_FILE="$TMP_INDEX" git -C "$UPSTREAM" add -N -- "$file"
done < <(git -C "$UPSTREAM" ls-files --others --exclude-standard -z)
GIT_INDEX_FILE="$TMP_INDEX" git -C "$UPSTREAM" diff --binary "$BASE" --diff-filter=d -- . \
  ':(exclude)platforms' ':(exclude)*.png' ':(exclude)*.jpg' > "$TMP_DIFF"

if ! cmp -s "$TMP_DIFF" "$PATCH"; then
  echo "Upstream content differs from the archived patch." >&2
  echo "Expected patch SHA256: $(shasum -a 256 "$TMP_DIFF" | awk '{print $1}')" >&2
  echo "Archived patch SHA256: $(shasum -a 256 "$PATCH" | awk '{print $1}')" >&2
  exit 1
fi

GIT_INDEX_FILE="$TMP_INDEX" git -C "$UPSTREAM" diff --check "$BASE"
echo "PASS: base=$BASE patch-files=$(grep -c '^diff --git ' "$PATCH") patch-SHA256=$(shasum -a 256 "$PATCH" | awk '{print $1}')"
