#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${ROOT}/dist/codex-e2e"
TMPDIR_RELAYKIT="$(mktemp -d)"
UPSTREAM_PID=""
GATEWAY_PID=""

free_port() {
  python3 - <<'PY'
import socket

s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
PY
}

cleanup() {
  if [[ -n "${GATEWAY_PID}" ]] && kill -0 "${GATEWAY_PID}" 2>/dev/null; then
    kill "${GATEWAY_PID}" >/dev/null 2>&1 || true
    wait "${GATEWAY_PID}" >/dev/null 2>&1 || true
  fi
  if [[ -n "${UPSTREAM_PID}" ]] && kill -0 "${UPSTREAM_PID}" 2>/dev/null; then
    kill "${UPSTREAM_PID}" >/dev/null 2>&1 || true
    wait "${UPSTREAM_PID}" >/dev/null 2>&1 || true
  fi
  rm -rf "${TMPDIR_RELAYKIT}"
}
trap cleanup EXIT

cat >"${TMPDIR_RELAYKIT}/fake-openai-chat.py" <<'PY'
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import sys

class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        request = json.loads(self.rfile.read(length) or b"{}")
        if request.get("stream"):
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.end_headers()
            chunks = [
                {"id": "chatcmpl-relaykit-e2e", "model": "relaykit-codex-e2e", "choices": [{"delta": {"role": "assistant"}}]},
                {"id": "chatcmpl-relaykit-e2e", "model": "relaykit-codex-e2e", "choices": [{"delta": {"content": "OK"}, "finish_reason": "stop"}], "usage": {"prompt_tokens": 1, "completion_tokens": 1, "total_tokens": 2}},
            ]
            for chunk in chunks:
                self.wfile.write(("data: " + json.dumps(chunk) + "\n\n").encode())
                self.wfile.flush()
            self.wfile.write(b"data: [DONE]\n\n")
            self.wfile.flush()
            return
        body = {
            "id": "chatcmpl-relaykit-e2e",
            "choices": [{"message": {"role": "assistant", "content": "OK"}, "finish_reason": "stop"}],
            "usage": {"prompt_tokens": 1, "completion_tokens": 1, "total_tokens": 2},
        }
        data = json.dumps(body).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *_):
        pass

ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), Handler).serve_forever()
PY

mkdir -p "${OUT}"
rm -f "${OUT}/last-message.txt" "${OUT}/usage-summary.json" "${OUT}/evidence.json"

UPSTREAM_PORT="$(free_port)"
GATEWAY_PORT="$(free_port)"

python3 "${TMPDIR_RELAYKIT}/fake-openai-chat.py" "${UPSTREAM_PORT}" &
UPSTREAM_PID="$!"
sleep 0.5
if ! kill -0 "${UPSTREAM_PID}" 2>/dev/null; then
  echo "fake upstream failed to start" >&2
  exit 1
fi

cat >"${TMPDIR_RELAYKIT}/providers.json" <<JSON
{"providers":[{"id":"codex-e2e","name":"Codex E2E","base_url":"http://127.0.0.1:${UPSTREAM_PORT}/v1","api_format":"openai_chat","models":[{"id":"relaykit-codex-e2e","display_name":"RelayKit Codex E2E","context_window":128000}]}]}
JSON

cd "${ROOT}/gateway"
go build -o bin/relay ./cmd/gateway
./bin/relay -listen "127.0.0.1:${GATEWAY_PORT}" -config "${TMPDIR_RELAYKIT}/providers.json" -usage-log "${TMPDIR_RELAYKIT}/usage.jsonl" >"${TMPDIR_RELAYKIT}/gateway.log" 2>&1 &
GATEWAY_PID="$!"
sleep 1
if ! kill -0 "${GATEWAY_PID}" 2>/dev/null; then
  cat "${TMPDIR_RELAYKIT}/gateway.log" >&2
  exit 1
fi
curl -fsS "http://127.0.0.1:${GATEWAY_PORT}/healthz" >/dev/null
curl -fsS "http://127.0.0.1:${GATEWAY_PORT}/v1/models" >/dev/null

mkdir -p "${TMPDIR_RELAYKIT}/codex-home" "${TMPDIR_RELAYKIT}/home"
cat >"${TMPDIR_RELAYKIT}/codex-home/config.toml" <<TOML
model = "relaykit-codex-e2e"
model_provider = "relaykit"
approval_policy = "never"
sandbox_mode = "read-only"

[model_providers.relaykit]
name = "RelayKit"
base_url = "http://127.0.0.1:${GATEWAY_PORT}/v1"
wire_api = "responses"
experimental_bearer_token = "relaykit-local"
TOML

cd "${ROOT}"
CODEX_HOME="${TMPDIR_RELAYKIT}/codex-home" HOME="${TMPDIR_RELAYKIT}/home" \
  codex exec --skip-git-repo-check --ignore-rules --ephemeral \
  --output-last-message "${OUT}/last-message.txt" \
  "Reply exactly OK. Do not run tools." >"${TMPDIR_RELAYKIT}/codex.out" 2>"${TMPDIR_RELAYKIT}/codex.err"

grep -qx "OK" "${OUT}/last-message.txt"
"${ROOT}/gateway/bin/relay" summarize-usage -path "${TMPDIR_RELAYKIT}/usage.jsonl" >"${OUT}/usage-summary.json"
jq -e 'length == 1 and .[0].provider_id == "codex-e2e" and .[0].model == "relaykit-codex-e2e" and .[0].requests >= 1 and .[0].total_tokens == 2' "${OUT}/usage-summary.json" >/dev/null

jq -n \
  --arg last_message "$(cat "${OUT}/last-message.txt")" \
  --arg gateway_url "http://127.0.0.1:${GATEWAY_PORT}/v1" \
  --slurpfile usage "${OUT}/usage-summary.json" \
  '{
    codex_last_message: $last_message,
    relaykit_gateway_url: $gateway_url,
    wrote_real_home_config: false,
    used_temporary_codex_home: true,
    provider_id: $usage[0][0].provider_id,
    model: $usage[0][0].model,
    requests: $usage[0][0].requests,
    total_tokens: $usage[0][0].total_tokens
  }' >"${OUT}/evidence.json"

jq . "${OUT}/evidence.json"
echo "RelayKit Codex E2E smoke passed: ${OUT}"
