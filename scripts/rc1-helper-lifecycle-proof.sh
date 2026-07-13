#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_BUNDLE="${RELAYKIT_RC1_APP_BUNDLE:-${ROOT}/dist/verify-release/RelayKitApp.app}"
APP_REAL="${APP_BUNDLE}/Contents/MacOS/RelayKitApp.bin"
BUNDLED_RELAY="${APP_BUNDLE}/Contents/MacOS/relay"
OUT="${RELAYKIT_RC1_HELPER_LIFECYCLE_OUT:-${ROOT}/dist/rc1-helper-lifecycle-proof}"
CODEX_CONFIG="${HOME}/.codex/config.toml"
CODEX_AUTH="${HOME}/.codex/auth.json"
APP_PID=""
HELPER_PID=""

print_contract() {
  jq -n '{
    proof: "rc1_helper_lifecycle",
    app_first: true,
    final_bundle: "dist/verify-release/RelayKitApp.app",
    parent_loss: "sigkill_app",
    helper_exit_required: true,
    app_listener: "127.0.0.1:19777",
    shared_18787_mutation: false,
    global_codex_mutation: false,
    launch_agent_mutation: false,
    provider_request: false
  }'
}

if [[ "${1:-}" == "--print-contract" ]]; then
  [[ "$#" -eq 1 ]] || exit 2
  print_contract
  exit 0
fi
[[ "$#" -eq 0 ]] || exit 2

fail() {
  printf 'RC1 helper lifecycle proof failed: %s\n' "$*" >&2
  exit 1
}

file_signature() {
  if [[ -e "$1" ]]; then shasum -a 256 "$1" | awk '{print $1}'; else printf 'missing'; fi
}

listener_snapshot() {
  lsof -nP -iTCP:"$1" -sTCP:LISTEN -Fpc 2>/dev/null | sort || true
}

port_is_free() {
  [[ -z "$(listener_snapshot "$1")" ]]
}

cleanup() {
  [[ -n "${APP_PID}" ]] && kill -KILL "${APP_PID}" >/dev/null 2>&1 || true
  [[ -n "${HELPER_PID}" ]] && kill "${HELPER_PID}" >/dev/null 2>&1 || true
  [[ -n "${tmp:-}" ]] && rm -rf "${tmp}" >/dev/null 2>&1 || true
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
    if text(element, kAXRoleAttribute) == kAXButtonRole as String,
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
tmp="$(mktemp -d "${TMPDIR:-/tmp}/relaykit-rc1-lifecycle.XXXXXX")"
trap cleanup EXIT
chmod 700 "${tmp}"
provider_config="${tmp}/providers.json"
jq -n '{providers:[{id:"fixture-lifecycle",name:"Fixture Lifecycle",base_url:"http://127.0.0.1:9/v1",api_format:"openai_chat",models:[{id:"fixture/lifecycle"}]}]}' >"${provider_config}"
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
for _ in {1..80}; do
  curl -fsS --max-time 1 http://127.0.0.1:19777/healthz >/dev/null 2>&1 && break
  sleep 0.1
done
curl -fsS --max-time 2 http://127.0.0.1:19777/healthz >/dev/null || fail "App-owned helper did not become healthy"
HELPER_PID="$(pgrep -P "${APP_PID}" -f "${BUNDLED_RELAY}" | head -1 || true)"
[[ -n "${HELPER_PID}" ]] || fail "App did not own the bundled helper process"
[[ "$(ps -o ppid= -p "${HELPER_PID}" | tr -d ' ')" == "${APP_PID}" ]] || fail "helper parent process did not match the App"

kill -KILL "${APP_PID}"
for _ in {1..80}; do
  ! kill -0 "${HELPER_PID}" 2>/dev/null && port_is_free 19777 && break
  sleep 0.1
done
! kill -0 "${HELPER_PID}" 2>/dev/null || fail "helper survived abrupt App parent loss"
port_is_free 19777 || fail "helper did not release the App port"
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
  '{status:"passed",proof:"rc1_helper_lifecycle",app_first:true,final_bundle_verified:true,
    app_sha256:$app_sha256,helper_sha256:$helper_sha256,parent_loss:"sigkill_app",
    helper_parent_verified:true,helper_exit_verified:true,app_port_released:true,
    provider_request_sent:false,global_codex_unchanged:true,shared_18787_unchanged:true}' >"${OUT}/evidence.json"
printf 'RelayKit RC1 helper lifecycle proof passed: %s\n' "${OUT}/evidence.json"
