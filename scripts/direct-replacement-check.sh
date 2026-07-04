#!/usr/bin/env bash
set -euo pipefail

URL="${RELAYKIT_ACCEPTANCE_URL:-http://127.0.0.1:18787}"
PORT="${URL##*:}"
PORT="${PORT%%/*}"

pids="$(lsof -tiTCP:"${PORT}" -sTCP:LISTEN 2>/dev/null || true)"
if [[ -z "${pids}" ]]; then
  echo "no listener on ${URL}" >&2
  exit 1
fi
commands="$(ps -p "${pids//$'\n'/,}" -o command= 2>/dev/null || true)"
if grep -Eqi 'agent-local-gateway|bridge' <<<"${commands}"; then
  echo "listener on ${URL} is not RelayKit-owned" >&2
  exit 1
fi

if command -v jq >/dev/null 2>&1; then
  curl -fsS "${URL}/healthz" | jq -e '.service == "relaykit" and .status == "ok"' >/dev/null
  curl -fsS "${URL}/v1/models" |
    jq -e '
      (.data | type == "array") and
      (.models | type == "array") and
      ((.models | length) == (.data | length)) and
      (.model_health.healthy | type == "number") and
      (.model_health.unhealthy | type == "number")
    ' >/dev/null
else
  python3 - "${URL}" <<'PY'
import json
import sys
import urllib.request

base = sys.argv[1].rstrip("/")

with urllib.request.urlopen(base + "/healthz", timeout=5) as response:
    health = json.load(response)
assert health.get("service") == "relaykit"
assert health.get("status") == "ok"

with urllib.request.urlopen(base + "/v1/models", timeout=10) as response:
    models = json.load(response)
data = models.get("data")
codex_models = models.get("models")
health = models.get("model_health", {})
assert isinstance(data, list)
assert isinstance(codex_models, list)
assert len(data) == len(codex_models)
assert isinstance(health.get("healthy"), (int, float))
assert isinstance(health.get("unhealthy"), (int, float))
PY
fi

echo "RelayKit direct replacement check passed: ${URL}"
