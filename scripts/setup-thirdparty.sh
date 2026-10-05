#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOCK="$ROOT/thirdparty-ohos/sources.lock.json"
DEST_ROOT="$ROOT/thirdparty-ohos/src"

python3 - "$LOCK" "$DEST_ROOT" <<'PY'
import json
import pathlib
import subprocess
import sys

lock_path = pathlib.Path(sys.argv[1])
dest_root = pathlib.Path(sys.argv[2])
data = json.loads(lock_path.read_text())
dest_root.mkdir(parents=True, exist_ok=True)

for source in data["sources"]:
    name, repo, commit = source["name"], source["repo"], source["commit"]
    dest = dest_root / name
    if dest.exists():
        if not (dest / ".git").exists():
            raise SystemExit(f"Refusing to replace non-git path: {dest}")
        current = subprocess.check_output(["git", "-C", str(dest), "rev-parse", "HEAD"], text=True).strip()
        if current != commit:
            raise SystemExit(f"{name}: existing HEAD {current} differs from pinned {commit}; left untouched")
        print(f"{name}: already at {commit}")
        continue

    temp = dest_root / f".{name}-setup-{commit[:8]}"
    if temp.exists():
        raise SystemExit(f"Temporary path already exists; inspect and remove manually: {temp}")
    subprocess.run(["git", "clone", "--no-checkout", repo, str(temp)], check=True)
    subprocess.run(["git", "-C", str(temp), "checkout", "--detach", commit], check=True)
    modules = temp / ".gitmodules"
    if modules.exists() and modules.stat().st_size:
        subprocess.run(["git", "-C", str(temp), "submodule", "update", "--init", "--recursive"], check=True)
    temp.rename(dest)
    print(f"{name}: checked out {commit}")
PY
