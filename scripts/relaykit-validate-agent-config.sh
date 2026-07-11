#!/usr/bin/env bash
set -euo pipefail

[[ "$#" -gt 0 ]] || {
  printf 'usage: %s agent.toml [...]\n' "$0" >&2
  exit 2
}

python3 - "$@" <<'PY'
import ast
import re
import sys
from pathlib import Path

allowed = {
    "name", "description", "model", "model_reasoning_effort",
    "sandbox_mode", "nickname_candidates", "developer_instructions",
}
required = allowed
assignment = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$")

def parse(path):
    lines = Path(path).read_text(encoding="utf-8").splitlines()
    values = {}
    index = 0
    while index < len(lines):
        line = lines[index]
        index += 1
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        match = assignment.match(line)
        if not match:
            raise ValueError(f"{path}:{index}: expected top-level assignment")
        key, raw = match.groups()
        if key not in allowed or key in values:
            raise ValueError(f"{path}:{index}: unknown or duplicate key {key}")
        if raw == '"""':
            body = []
            while index < len(lines) and lines[index] != '"""':
                body.append(lines[index])
                index += 1
            if index >= len(lines):
                raise ValueError(f"{path}:{index}: unterminated multiline string")
            index += 1
            values[key] = "\n".join(body)
            continue
        try:
            values[key] = ast.literal_eval(raw)
        except (SyntaxError, ValueError) as error:
            raise ValueError(f"{path}:{index}: invalid literal for {key}") from error
    if set(values) != required:
        missing = sorted(required - set(values))
        raise ValueError(f"{path}: missing keys {missing}")
    for key in required - {"nickname_candidates"}:
        if not isinstance(values[key], str) or not values[key].strip():
            raise ValueError(f"{path}: {key} must be a non-empty string")
    nicknames = values["nickname_candidates"]
    if not isinstance(nicknames, list) or not nicknames or not all(isinstance(value, str) and value for value in nicknames):
        raise ValueError(f"{path}: nickname_candidates must be a non-empty string array")

for candidate in sys.argv[1:]:
    try:
        parse(candidate)
    except (OSError, UnicodeError, ValueError) as error:
        print(error, file=sys.stderr)
        raise SystemExit(1)
print("RelayKit agent config validation passed")
PY
