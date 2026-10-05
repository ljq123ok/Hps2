#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="$ROOT/upstream/ARMSX2"
LOCK="$ROOT/patches/upstream.json"
BASE="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["commit"])' "$LOCK")"
REPO="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["repo"])' "$LOCK")"
PATCH="$ROOT/$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["patch"])' "$LOCK")"

if [[ ! -f "$PATCH" ]]; then
  echo "Missing upstream patch: $PATCH" >&2
  exit 1
fi

if [[ -e "$DEST" ]]; then
  if [[ ! -d "$DEST/.git" ]]; then
    echo "Refusing to replace non-git path: $DEST" >&2
    exit 1
  fi
  if ! git -C "$DEST" cat-file -e "$BASE^{commit}" 2>/dev/null || \
     ! git -C "$DEST" merge-base --is-ancestor "$BASE" HEAD; then
    echo "Existing upstream does not contain pinned base $BASE. Leaving it untouched." >&2
    exit 1
  fi
  CURRENT_DIFF="$(mktemp)"
  CURRENT_INDEX="$(mktemp)"
  GIT_DIR="$(git -C "$DEST" rev-parse --absolute-git-dir)"
  cp "$GIT_DIR/index" "$CURRENT_INDEX"
  trap 'rm -f "$CURRENT_DIFF" "$CURRENT_INDEX"' EXIT
  while IFS= read -r -d '' file; do
    GIT_INDEX_FILE="$CURRENT_INDEX" git -C "$DEST" add -N -- "$file"
  done < <(git -C "$DEST" ls-files --others --exclude-standard -z -- . \
    ':(exclude)platforms' ':(exclude)*.png' ':(exclude)*.jpg')
  GIT_INDEX_FILE="$CURRENT_INDEX" git -C "$DEST" diff --binary "$BASE" --diff-filter=d -- . \
    ':(exclude)platforms' ':(exclude)*.png' ':(exclude)*.jpg' > "$CURRENT_DIFF"
  if cmp -s "$CURRENT_DIFF" "$PATCH"; then
    echo "Upstream patch is already applied."
  elif [[ "$(git -C "$DEST" rev-parse HEAD)" == "$BASE" ]] && \
       git -C "$DEST" apply --check "$PATCH" >/dev/null 2>&1; then
    git -C "$DEST" apply "$PATCH"
    echo "Applied Hps2 OHOS patch."
  else
    echo "Existing source does not match the pinned base or patch; leaving it untouched." >&2
    exit 1
  fi
  rm -f "$CURRENT_DIFF"
  trap - EXIT
else
  mkdir -p "$(dirname "$DEST")"
  TEMP="$ROOT/upstream/.ARMSX2-setup-$$"
  trap 'rm -rf "$TEMP"' EXIT
  git clone --no-checkout "$REPO" "$TEMP"
  git -C "$TEMP" checkout --detach "$BASE"
  if [[ -f "$TEMP/.gitmodules" ]] && [[ -s "$TEMP/.gitmodules" ]]; then
    git -C "$TEMP" submodule update --init --recursive
  fi
  git -C "$TEMP" apply "$PATCH"
  mv "$TEMP" "$DEST"
  trap - EXIT
  echo "Cloned pinned upstream and applied Hps2 OHOS patch."
fi

git -C "$DEST" diff --check
echo "upstream HEAD=$(git -C "$DEST" rev-parse HEAD)"
echo "upstream patch=$(shasum -a 256 "$PATCH" | awk '{print $1}')"
echo "upstream dirty entries=$(git -C "$DEST" status --porcelain | wc -l | tr -d ' ') (expected: applied patch)"
