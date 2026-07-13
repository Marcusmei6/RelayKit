#!/usr/bin/env bash
set -euo pipefail

HOST="${RELAYKIT_ACCEPTANCE_HOST:-}"
REMOTE_ROOT="${RELAYKIT_ACCEPTANCE_ROOT:-RelayKit-acceptance}"
URL="${RELAYKIT_ACCEPTANCE_URL:-http://127.0.0.1:19777}"
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=8 -o ConnectionAttempts=1 -o ControlMaster=no -o ControlPath=none)

fail() {
  printf 'remote Mac acceptance failed: %s\n' "$*" >&2
  exit 1
}

[[ -n "${HOST}" ]] || fail "RELAYKIT_ACCEPTANCE_HOST is required"
[[ -n "${REMOTE_ROOT}" && "${REMOTE_ROOT}" != *$'\n'* && "${REMOTE_ROOT}" != *$'\r'* ]] ||
  fail "RELAYKIT_ACCEPTANCE_ROOT is invalid"
[[ "${URL}" =~ ^http://127\.0\.0\.1:[0-9]+$ ]] || fail "RELAYKIT_ACCEPTANCE_URL must be an isolated loopback HTTP URL"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/relaykit-remote-acceptance.XXXXXX")"
trap 'rm -rf "${tmp}"' EXIT

if ! ssh "${SSH_OPTS[@]}" "${HOST}" 'hostname >/dev/null' >"${tmp}/ssh.out" 2>"${tmp}/ssh.err"; then
  printf 'Remote SSH readiness check failed.\n' >&2
  cat "${tmp}/ssh.err" >&2
  exit 1
fi

ssh "${SSH_OPTS[@]}" "${HOST}" ROOT="${REMOTE_ROOT}" URL="${URL}" 'bash -s' <<'REMOTE'
set -euo pipefail
cd "${ROOT}"
RELAYKIT_ACCEPTANCE_URL="${URL}" ./scripts/direct-replacement-check.sh >/dev/null
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
if not data or not models or len(data) != len(models) or healthy <= 0:
    raise SystemExit("catalog has no visible healthy models")

print(json.dumps({
    "status": "passed",
    "catalog": {
        "public_model_count": len(data),
        "codex_model_count": len(models),
        "healthy_count": healthy,
        "unhealthy_count": unhealthy,
    },
}, sort_keys=True))
PY
REMOTE
