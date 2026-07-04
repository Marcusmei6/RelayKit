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

curl -fsS "${URL}/healthz" | jq -e '.service == "relaykit" and .status == "ok"' >/dev/null
curl -fsS "${URL}/v1/models" |
  jq -e '
    (.data | type == "array") and
    (.models | type == "array") and
    ((.models | length) == (.data | length)) and
    (.model_health.healthy | type == "number") and
    (.model_health.unhealthy | type == "number")
  ' >/dev/null

echo "RelayKit direct replacement check passed: ${URL}"
