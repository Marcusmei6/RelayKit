#!/usr/bin/env bash
set -euo pipefail

HOST="${RELAYKIT_MAC_PRO_HOST:-bytedance@192.168.50.97}"
ROOT="${RELAYKIT_MAC_PRO_ROOT:-/Users/bytedance/workplace/RelayKit-acceptance}"
URL="${RELAYKIT_ACCEPTANCE_URL:-http://127.0.0.1:18787}"
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=8 -o ConnectionAttempts=1 -o ControlMaster=no -o ControlPath=none)

if ! ssh "${SSH_OPTS[@]}" "${HOST}" 'hostname; date' >/tmp/relaykit-mac-pro-ssh-check.out 2>/tmp/relaykit-mac-pro-ssh-check.err; then
  echo "Mac Pro SSH banner still blocked: TCP 22 accepts connections but ssh does not return a server banner." >&2
  cat /tmp/relaykit-mac-pro-ssh-check.err >&2
  exit 1
fi

cat /tmp/relaykit-mac-pro-ssh-check.out

ssh "${SSH_OPTS[@]}" "${HOST}" ROOT="${ROOT}" URL="${URL}" 'bash -s' <<'REMOTE'
set -euo pipefail
cd "${ROOT}"
lsof -nP -iTCP:18787 -sTCP:LISTEN
awk '/^[[:space:]]*model_provider[[:space:]]*=/{print}' "${HOME}/.codex/config.toml"
RELAYKIT_ACCEPTANCE_URL="${URL}" ./scripts/direct-replacement-check.sh
python3 - "${URL}" <<'PY'
import json
import sys
import urllib.request

base = sys.argv[1].rstrip("/")
with urllib.request.urlopen(base + "/v1/models", timeout=10) as response:
    catalog = json.load(response)

data = catalog.get("data") or []
models = catalog.get("models") or []
health = catalog.get("model_health") or {}
healthy = health.get("healthy") or 0
unhealthy = health.get("unhealthy") or 0

print(json.dumps({
    "catalog": {
        "data_len": len(data),
        "models_len": len(models),
        "healthy": healthy,
        "unhealthy": unhealthy,
    }
}, sort_keys=True))

if not data or not models or healthy <= 0:
    raise SystemExit("catalog has no visible healthy models")
PY
REMOTE
