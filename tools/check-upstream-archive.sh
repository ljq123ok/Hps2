#!/usr/bin/env bash
#
# 校验 upstream/ARMSX2 的所有改动是否都被 patches/ 完整归档。
#
# 【为什么需要它】
#   2026-10-01 发现：上游改动实际有 29 个文件，但 patches/ 只归档了 6 个，
#   漏掉 23 个 —— 而 README 的构建步骤依赖这些改动才能跑通。
#   根因是"归档靠人工记得"，且 patches/README.md 里教的重生成命令
#   （git diff -- '*.cpp' '*.h' '*.txt'）只抓工作区未提交改动，
#   抓不到已提交到本地分支的部分。
#
#   本脚本把"是否漏了"变成可自动判定的事实，而不是靠人记。
#
# 用法：
#   bash tools/check-upstream-archive.sh          # 校验，有问题则退出码 1
#
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UPSTREAM="$REPO_ROOT/upstream/ARMSX2"
PATCH="$REPO_ROOT/patches/upstream/0001-hps2-ohos-bringup-complete.patch"
BASE="d7e8d01678107f066d6ec988ca178d80089bd9f5"   # 上游基线（= origin/master）

if [ ! -d "$UPSTREAM/.git" ]; then
  echo "跳过：$UPSTREAM 不是 git 仓库（未克隆上游）。"
  exit 0
fi

if [ ! -f "$PATCH" ]; then
  echo "❌ 找不到归档补丁：$PATCH"
  exit 1
fi

cd "$UPSTREAM" || exit 1

# ---------------------------------------------------------------------------
# 口径必须与生成补丁时完全一致，否则会误报。
#   排除：platforms/（挪走的移动端资源）
#   排除：*.png *.jpg（清体积时删除的图片，与功能无关）
#   排除：被删除的文件（--diff-filter=d）
# ---------------------------------------------------------------------------
EXCLUDES=(':(exclude)platforms' ':(exclude)*.png' ':(exclude)*.jpg')

# 收集当前真实存在的改动（已提交 + 已跟踪的工作区改动 + 未跟踪的新文件）
actual="$(
  {
    git diff --name-only --diff-filter=d "$BASE" -- . "${EXCLUDES[@]}"
    git status --porcelain --untracked-files=all -- . "${EXCLUDES[@]}" \
      | grep -vE '^ ?D ' | awk '{print $NF}'
  } | sort -u
)"

# 收集补丁里声明的文件（从 diff --git 行解析，最可靠）
archived="$(
  grep -E '^diff --git' "$PATCH" \
    | sed -E 's|^diff --git a/(.*) b/.*|\1|' \
    | sort -u
)"

missing="$(comm -23 <(printf '%s\n' "$actual") <(printf '%s\n' "$archived"))"

n_actual=$(printf '%s\n' "$actual" | grep -c . || true)
n_archived=$(printf '%s\n' "$archived" | grep -c . || true)

echo "上游基线      : $BASE"
echo "实际改动文件  : $n_actual"
echo "归档覆盖文件  : $n_archived"
echo

if [ -n "$missing" ]; then
  n_missing=$(printf '%s\n' "$missing" | grep -c . || true)
  echo "❌ 有 $n_missing 个改动未被归档 —— 换机器重新克隆会丢失："
  echo
  printf '%s\n' "$missing" | sed 's/^/    /'
  echo
  echo "修复：重新生成完整归档（注意必须含未跟踪的新文件）"
  echo "    cd upstream/ARMSX2"
  echo "    git add -N <新增文件>          # 否则未跟踪文件不进 diff"
  echo "    git diff $BASE --diff-filter=d -- . ':(exclude)platforms' \\"
  echo "        ':(exclude)*.png' ':(exclude)*.jpg' \\"
  echo "        > ../../patches/upstream/0001-hps2-ohos-bringup-complete.patch"
  exit 1
fi

# File-name coverage alone cannot detect a stale patch. Compare its full bytes
# with the current diff, including untracked files, using a temporary index so
# this check does not alter the developer's upstream index.
TMP_DIFF="$(mktemp)"
TMP_INDEX="$(mktemp)"
GIT_DIR="$(git rev-parse --absolute-git-dir)"
cp "$GIT_DIR/index" "$TMP_INDEX"
while IFS= read -r -d '' file; do
  GIT_INDEX_FILE="$TMP_INDEX" git add -N -- "$file"
done < <(git ls-files --others --exclude-standard -z -- . "${EXCLUDES[@]}")
GIT_INDEX_FILE="$TMP_INDEX" git diff --binary "$BASE" --diff-filter=d -- . "${EXCLUDES[@]}" > "$TMP_DIFF"
if ! cmp -s "$TMP_DIFF" "$PATCH"; then
  echo "❌ 归档补丁内容与当前上游改动不一致。"
  echo "    当前改动 SHA256: $(shasum -a 256 "$TMP_DIFF" | awk '{print $1}')"
  echo "    归档补丁 SHA256: $(shasum -a 256 "$PATCH" | awk '{print $1}')"
  rm -f "$TMP_DIFF" "$TMP_INDEX"
  exit 1
fi
rm -f "$TMP_DIFF" "$TMP_INDEX"

# 反向检查：归档里有、但本地已不存在的文件（补丁已过时）
stale="$(comm -13 <(printf '%s\n' "$actual") <(printf '%s\n' "$archived"))"
if [ -n "$stale" ]; then
  echo "⚠️  归档里有 $(printf '%s\n' "$stale" | grep -c .) 个文件已不在本地改动中（补丁可能过时）："
  printf '%s\n' "$stale" | sed 's/^/    /'
  echo "    （若确认是回退了改动，重新生成补丁即可）"
  echo
fi

echo "✅ 归档完整：全部 $n_actual 个改动文件都在补丁中。"
exit 0
