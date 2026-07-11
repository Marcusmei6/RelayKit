#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
base=""
head=""

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --base) base="${2:-}"; shift 2 ;;
    --head) head="${2:-}"; shift 2 ;;
    *) printf 'unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done

base="$(git -C "${ROOT}" rev-parse --verify "${base}^{commit}")"
head="$(git -C "${ROOT}" rev-parse --verify "${head}^{commit}")"

python3 - "${ROOT}" "${base}" "${head}" <<'PY'
import posixpath
import re
import subprocess
import sys

root, base, head = sys.argv[1:]
changed = subprocess.check_output(
    ["git", "-C", root, "diff", "--name-only", "--diff-filter=ACMRT", base, head, "--"],
    text=True,
).splitlines()
link_pattern = re.compile(r"!?\[[^\]]*\]\(([^)]+)\)")
missing = []

for path in changed:
    if not path.lower().endswith((".md", ".markdown")):
        continue
    try:
        content = subprocess.check_output(
            ["git", "-C", root, "show", f"{head}:{path}"],
            text=True,
            stderr=subprocess.DEVNULL,
        )
    except subprocess.CalledProcessError:
        continue
    for raw_target in link_pattern.findall(content):
        target = raw_target.strip().strip("<>").split("#", 1)[0]
        if not target or target.startswith(("/", "#", "mailto:")) or "://" in target:
            continue
        resolved = posixpath.normpath(posixpath.join(posixpath.dirname(path), target))
        if resolved.startswith("../"):
            missing.append((path, raw_target))
            continue
        exists = subprocess.run(
            ["git", "-C", root, "cat-file", "-e", f"{head}:{resolved}"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        ).returncode == 0
        if not exists:
            missing.append((path, raw_target))

if missing:
    for source, target in missing:
        print(f"missing local documentation link: {source} -> {target}", file=sys.stderr)
    raise SystemExit(1)
print("RelayKit documentation consistency check passed")
PY
