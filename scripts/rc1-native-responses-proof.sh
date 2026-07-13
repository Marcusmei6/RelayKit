#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_BUNDLE="${RELAYKIT_RC1_APP_BUNDLE:-${ROOT}/dist/verify-release/RelayKitApp.app}"
APP_REAL="${APP_BUNDLE}/Contents/MacOS/RelayKitApp.bin"
BUNDLED_RELAY="${APP_BUNDLE}/Contents/MacOS/relay"
OUT="${RELAYKIT_RC1_NATIVE_RESPONSES_OUT:-${ROOT}/dist/rc1-native-responses-proof}"
CODEX_CONFIG="${HOME}/.codex/config.toml"
CODEX_AUTH="${HOME}/.codex/auth.json"
APP_PID=""
HELPER_PID=""
UPSTREAM_PID=""

print_contract() {
  jq -n '{
    proof: "rc1_native_responses",
    app_first: true,
    final_bundle: "dist/verify-release/RelayKitApp.app",
    provider_fixture: "loopback_openai_responses",
    app_listener: "127.0.0.1:19777",
    shared_18787_mutation: false,
    global_codex_mutation: false,
    launch_agent_mutation: false,
    real_provider_request: false,
    evidence_contains_request_or_response_body: false
  }'
}

if [[ "${1:-}" == "--print-contract" ]]; then
  [[ "$#" -eq 1 ]] || exit 2
  print_contract
  exit 0
fi
[[ "$#" -eq 0 ]] || exit 2

fail() {
  printf 'RC1 native Responses proof failed: %s\n' "$*" >&2
  exit 1
}

file_signature() {
  if [[ -e "$1" ]]; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    printf 'missing'
  fi
}

listener_snapshot() {
  lsof -nP -iTCP:"$1" -sTCP:LISTEN -Fpc 2>/dev/null | sort || true
}

port_is_free() {
  [[ -z "$(listener_snapshot "$1")" ]]
}

cleanup() {
  if [[ -n "${APP_PID}" ]] && kill -0 "${APP_PID}" 2>/dev/null; then
    kill "${APP_PID}" >/dev/null 2>&1 || true
  fi
  if [[ -n "${HELPER_PID}" ]] && kill -0 "${HELPER_PID}" 2>/dev/null; then
    kill "${HELPER_PID}" >/dev/null 2>&1 || true
  fi
  if [[ -n "${UPSTREAM_PID}" ]] && kill -0 "${UPSTREAM_PID}" 2>/dev/null; then
    kill "${UPSTREAM_PID}" >/dev/null 2>&1 || true
    wait "${UPSTREAM_PID}" >/dev/null 2>&1 || true
  fi
  [[ -n "${tmp:-}" ]] && rm -rf "${tmp}" >/dev/null 2>&1 || true
}

wait_for_file() {
  for _ in {1..80}; do
    [[ -s "$1" ]] && return 0
    sleep 0.1
  done
  return 1
}

wait_for_health() {
  for _ in {1..80}; do
    curl -fsS --max-time 1 http://127.0.0.1:19777/healthz >/dev/null 2>&1 && return 0
    sleep 0.1
  done
  return 1
}

press_ax_identifier() {
  swift - "${APP_PID}" "$1" >/dev/null <<'SWIFT'
import ApplicationServices
import Foundation

guard CommandLine.arguments.count == 3, let pid = pid_t(CommandLine.arguments[1]) else { exit(2) }
let target = CommandLine.arguments[2]
let app = AXUIElementCreateApplication(pid)

func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
    var result: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &result) == .success else { return nil }
    return result
}
func text(_ element: AXUIElement, _ attribute: String) -> String { (value(element, attribute) as? String) ?? "" }
func children(_ element: AXUIElement) -> [AXUIElement] { (value(element, kAXChildrenAttribute as String) as? [AXUIElement]) ?? [] }
func press(_ element: AXUIElement, depth: Int = 0) -> Bool {
    if depth > 8 { return false }
    let role = text(element, kAXRoleAttribute)
    if role == kAXButtonRole as String,
       AXUIElementPerformAction(element, kAXPressAction as CFString) == .success { return true }
    return children(element).contains { press($0, depth: depth + 1) }
}
func walk(_ element: AXUIElement, depth: Int = 0) -> Bool {
    if depth > 12 { return false }
    let identities = [text(element, kAXTitleAttribute), text(element, kAXDescriptionAttribute), text(element, "AXIdentifier")]
    if identities.contains(target), press(element) { return true }
    return children(element).contains { walk($0, depth: depth + 1) }
}
exit(walk(app) ? 0 : 1)
SWIFT
}

[[ -x "${APP_REAL}" && -x "${BUNDLED_RELAY}" ]] || fail "final extracted App bundle is incomplete"
/usr/bin/codesign --verify --deep --strict "${APP_BUNDLE}" || fail "final extracted App bundle failed code-sign verification"
port_is_free 19777 || fail "127.0.0.1:19777 is already in use"
[[ -z "$(pgrep -x RelayKitApp.bin || true)" ]] || fail "RelayKitApp.bin is already running"

config_before="$(file_signature "${CODEX_CONFIG}")"
auth_before="$(file_signature "${CODEX_AUTH}")"
shared_before="$(listener_snapshot 18787)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/relaykit-rc1-native.XXXXXX")"
trap cleanup EXIT
chmod 700 "${tmp}"

port_file="${tmp}/upstream-port"
request_log="${tmp}/upstream-requests.json"
python3 - "${port_file}" "${request_log}" <<'PY' &
import json
import os
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

port_file, request_log = sys.argv[1:]
requests = []

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_args):
        return

    def do_GET(self):
        if self.path != "/v1/models":
            self.send_error(404)
            return
        body = json.dumps({"object":"list","data":[{"id":"native-upstream","object":"model","owned_by":"fixture"}]}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        body = json.loads(self.rfile.read(length))
        requests.append({
            "method": "POST",
            "path": self.path,
            "model_is_upstream": body.get("model") == "native-upstream",
            "fixture_metadata_preserved": body.get("metadata", {}).get("fixture") == "RELAYKIT_FAKE_SENTINEL_DO_NOT_USE",
            "fake_credential_received": self.headers.get("X-RelayKit-Fixture") == "RELAYKIT_FAKE_SENTINEL_DO_NOT_USE",
        })
        temporary = request_log + ".tmp"
        with open(temporary, "w", encoding="utf-8") as handle:
            json.dump(requests, handle, sort_keys=True)
        os.replace(temporary, request_log)
        response = {
            "id": "resp_fixture",
            "object": "response",
            "status": "completed",
            "model": "native-upstream",
            "output": [{"id":"msg_fixture","type":"message","role":"assistant","content":[{"type":"output_text","text":"fixture response"}]}],
            "usage": {"input_tokens": 2, "output_tokens": 2, "total_tokens": 4},
        }
        encoded = json.dumps(response, separators=(",", ":")).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(encoded)))
        self.end_headers()
        self.wfile.write(encoded)

server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
with open(port_file, "w", encoding="utf-8") as handle:
    handle.write(str(server.server_address[1]))
os.chmod(port_file, 0o600)
server.serve_forever()
PY
UPSTREAM_PID="$!"
wait_for_file "${port_file}" || fail "loopback Responses fixture did not start"
upstream_port="$(cat "${port_file}")"

credential_file="${tmp}/fixture-key"
printf '%s\n' 'RELAYKIT_FAKE_SENTINEL_DO_NOT_USE' >"${credential_file}"
chmod 600 "${credential_file}"
provider_config="${tmp}/providers.json"
jq -n --arg base "http://127.0.0.1:${upstream_port}/v1" --arg key "${credential_file}" '{providers:[{
  id:"fixture-native", name:"Fixture Native Responses", base_url:$base, api_format:"openai_responses",
  credential_ref:{kind:"key_file",value:$key,header:"X-RelayKit-Fixture"},
  models:[{id:"fixture/native",display_name:"Fixture Native",upstream_model:"native-upstream"}]
}]}' >"${provider_config}"
chmod 600 "${provider_config}"

ui_evidence="${tmp}/app-evidence.json"
/usr/bin/open -n "${APP_BUNDLE}" --args --ui-smoke --ui-smoke-keep-open --ui-smoke-tab settings \
  --ui-smoke-provider-config "${provider_config}" --ui-smoke-skip-gateway-exercise --ui-smoke-evidence "${ui_evidence}" >/dev/null
for _ in {1..80}; do
  APP_PID="$(pgrep -x RelayKitApp.bin | tail -1 || true)"
  [[ -n "${APP_PID}" && -s "${ui_evidence}" ]] && break
  sleep 0.1
done
[[ -n "${APP_PID}" && -s "${ui_evidence}" ]] || fail "final App did not launch"
press_ax_identifier gateway-start || fail "App gateway Start control was unavailable"
wait_for_health || fail "App-owned gateway did not become healthy"
HELPER_PID="$(pgrep -P "${APP_PID}" -f "${BUNDLED_RELAY}" | head -1 || true)"
[[ -n "${HELPER_PID}" ]] || fail "App did not own the bundled helper process"

request_file="${tmp}/request.json"
jq -n '{model:"fixture/native",input:"public fixture request",metadata:{fixture:"RELAYKIT_FAKE_SENTINEL_DO_NOT_USE"}}' >"${request_file}"
chmod 600 "${request_file}"
response_file="${tmp}/response.json"
curl -fsS --max-time 10 -H 'Content-Type: application/json' --data-binary "@${request_file}" \
  http://127.0.0.1:19777/v1/responses >"${response_file}"
jq -e '.object == "response" and .status == "completed" and .model == "fixture/native" and .output[0].content[0].text == "fixture response" and .usage.total_tokens == 4' "${response_file}" >/dev/null ||
  fail "gateway did not preserve the native Responses contract"
wait_for_file "${request_log}" || fail "upstream request evidence was not written"
jq -e 'length == 1 and .[0].method == "POST" and .[0].path == "/v1/responses" and .[0].model_is_upstream == true and .[0].fixture_metadata_preserved == true and .[0].fake_credential_received == true' "${request_log}" >/dev/null ||
  fail "native upstream request contract was not preserved"

kill "${APP_PID}" >/dev/null 2>&1 || true
for _ in {1..80}; do
  ! kill -0 "${APP_PID}" 2>/dev/null && ! kill -0 "${HELPER_PID}" 2>/dev/null && port_is_free 19777 && break
  sleep 0.1
done
! kill -0 "${APP_PID}" 2>/dev/null || fail "App did not exit"
! kill -0 "${HELPER_PID}" 2>/dev/null || fail "App-owned helper did not exit"
port_is_free 19777 || fail "App-owned gateway port was not released"
APP_PID=""
HELPER_PID=""

[[ "$(file_signature "${CODEX_CONFIG}")" == "${config_before}" ]] || fail "global Codex config changed"
[[ "$(file_signature "${CODEX_AUTH}")" == "${auth_before}" ]] || fail "global Codex auth changed"
[[ "$(listener_snapshot 18787)" == "${shared_before}" ]] || fail "shared 18787 listener changed"

rm -rf "${OUT}"
mkdir -p "${OUT}"
jq -n \
  --arg app_sha256 "$(file_signature "${APP_REAL}")" \
  --arg helper_sha256 "$(file_signature "${BUNDLED_RELAY}")" \
  '{status:"passed",proof:"rc1_native_responses",app_first:true,final_bundle_verified:true,
    app_sha256:$app_sha256,helper_sha256:$helper_sha256,provider_fixture:"loopback_openai_responses",
    upstream_path:"/v1/responses",upstream_model_rewrite_verified:true,public_model_rewrite_verified:true,
    fake_credential_verified:true,global_codex_unchanged:true,shared_18787_unchanged:true,
    helper_released:true,app_port_released:true,request_or_response_body_exported:false}' >"${OUT}/evidence.json"
printf 'RelayKit RC1 native Responses proof passed: %s\n' "${OUT}/evidence.json"
