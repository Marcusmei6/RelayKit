#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_BUNDLE="${RELAYKIT_RC1_APP_BUNDLE:-${ROOT}/dist/verify-release/RelayKitApp.app}"
APP_ZIP="${RELAYKIT_RC1_APP_ZIP:-${ROOT}/dist/RelayKitApp-local.zip}"
APP_REAL="${APP_BUNDLE}/Contents/MacOS/RelayKitApp.bin"
BUNDLED_RELAY="${APP_BUNDLE}/Contents/MacOS/relay"
FIXTURE="${ROOT}/scripts/rc1-native-responses-proof-fixture.py"
AX_SOURCE="${ROOT}/scripts/codex-desktop-ax-driver.swift"
MANUAL_PROOF="${ROOT}/scripts/codex-desktop-manual-proof.sh"
MANIFEST="${ROOT}/scripts/rc1-native-responses-manifest.sh"
OUT="${RELAYKIT_RC1_NATIVE_RESPONSES_OUT:-${ROOT}/dist/rc1-native-responses-proof}"
RUN_ID="${RELAYKIT_RC1_RUN_ID:-rc1-native-$(date -u +%Y%m%dT%H%M%SZ)-$$}"
PROVIDER_NAME="Dogfood RC1 Native Responses"
PROVIDER_ID="dogfood-rc1-native-responses"
PROVIDER_MODEL="dogfood/native-responses"
KEYCHAIN_SERVICE="relaykit.provider.${PROVIDER_ID}"
SYNTHETIC_KEY="RELAYKIT_FAKE_RC1_NATIVE_RESPONSES_DO_NOT_USE"
APP_PID=""
FIXTURE_PID=""
HELPER_PID=""
KEYCHAIN_CREATED=false

print_contract() {
  jq -n '{
    proof:"rc1_native_responses_chain",
    app_first:true,
    ordinary_extracted_app:true,
    provider_destination_initially_empty:true,
    provider_created_through_exact_ax:true,
    provider_protocol:"openai_responses",
    credential_storage:"keychain_reference_only",
    relaunch_restoration_required:true,
    gateway_started_through_ui:true,
    desktop_profile:"rc1_native_responses_three_stage",
    desktop_stage_count:3,
    desktop_websocket_to_gateway_required:true,
    gateway_sse_to_fixture_required:true,
    shared_18787_mutation:false,
    global_codex_mutation:false,
    launch_agent_mutation:false,
    real_provider_request:false,
    evidence_contains_request_or_response_body:false
  }'
}

fail() {
  printf 'RC1 native Responses proof failed: %s\n' "$*" >&2
  exit 1
}

sha256() {
  if [[ -f "$1" ]]; then
    /usr/bin/shasum -a 256 "$1" | awk '{print $1}'
  else
    printf 'missing\n'
  fi
}

listener_snapshot() {
  lsof -nP -iTCP:"$1" -sTCP:LISTEN -Fpc 2>/dev/null | LC_ALL=C sort || true
}

port_is_free() {
  [[ -z "$(listener_snapshot "$1")" ]]
}

stop_app() {
  if [[ -n "${APP_PID}" ]] && kill -0 "${APP_PID}" 2>/dev/null; then
    kill -TERM "${APP_PID}" >/dev/null 2>&1 || true
    for _ in {1..100}; do
      kill -0 "${APP_PID}" 2>/dev/null || break
      sleep 0.1
    done
  fi
  APP_PID=""
}

cleanup() {
  stop_app
  if [[ -n "${HELPER_PID}" ]] && kill -0 "${HELPER_PID}" 2>/dev/null; then
    kill -TERM "${HELPER_PID}" >/dev/null 2>&1 || true
  fi
  if [[ -n "${FIXTURE_PID}" ]] && kill -0 "${FIXTURE_PID}" 2>/dev/null; then
    kill -TERM "${FIXTURE_PID}" >/dev/null 2>&1 || true
    wait "${FIXTURE_PID}" >/dev/null 2>&1 || true
  fi
  if [[ "${KEYCHAIN_CREATED}" == "true" && -x "${APP_REAL}" ]]; then
    "${APP_REAL}" --delete-dogfood-keychain "${KEYCHAIN_SERVICE}" >/dev/null 2>&1 || true
  fi
}

wait_for_file() {
  local path="$1"
  for _ in {1..100}; do
    [[ -s "${path}" ]] && return 0
    sleep 0.1
  done
  return 1
}

find_exact_app_pid() {
  local pid command
  local matches=()
  while IFS= read -r pid; do
    [[ -n "${pid}" ]] || continue
    command="$(ps -p "${pid}" -o command= 2>/dev/null || true)"
    [[ "${command}" == "${APP_REAL}"* ]] && matches+=("${pid}")
  done < <(pgrep -x RelayKitApp.bin 2>/dev/null || true)
  [[ "${#matches[@]}" -eq 1 ]] || return 1
  printf '%s\n' "${matches[0]}"
}

open_exact_app_popover() {
  /usr/bin/osascript - "${APP_PID}" <<'APPLESCRIPT' >/dev/null
on run argv
  set targetPID to (item 1 of argv) as integer
  tell application "System Events"
    set targetProcess to first process whose unix id is targetPID
    set frontmost of targetProcess to true
    tell targetProcess
      set statusItems to menu bar items of menu bar 1
      if (count of statusItems) is not 1 then error "relaykit_status_item_not_unique"
      click item 1 of statusItems
    end tell
  end tell
end run
APPLESCRIPT
}

write_exact_app_window_identity() {
  local identity_output="$1"
  local diagnostic_output="$2"
  local metadata_input="${3:-}"
  swift - "${APP_PID}" "${identity_output}" "${diagnostic_output}" "${metadata_input}" <<'SWIFT'
import AppKit
import CoreGraphics
import Darwin
import Foundation

let pid = pid_t(Int(CommandLine.arguments[1])!)
let identityOutput = CommandLine.arguments[2]
let diagnosticOutput = CommandLine.arguments[3]
let metadataInput = CommandLine.arguments[4]
let fileManager = FileManager.default
_ = umask(0o077)
try? fileManager.removeItem(atPath: identityOutput)

struct WindowMetadata {
    let ownerPID: pid_t
    let windowID: UInt32?
    let layer: Int?
    let width: Double?
    let height: Double?
    let boundsValid: Bool
}

struct Candidate {
    let windowID: UInt32
    let layer: Int
    let width: Double
    let height: Double
    let area: Double
    let eligible: Bool

    var dictionary: [String: Any] {
        [
            "window_id": windowID,
            "layer": layer,
            "width": width,
            "height": height,
            "area": area,
            "eligible": eligible,
        ]
    }
}

func writeAtomicJSON(_ value: [String: Any], to path: String) throws {
    let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    try data.write(to: URL(fileURLWithPath: path), options: [.atomic])
    try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
}

let capturedAtFormatter = ISO8601DateFormatter()
capturedAtFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
let capturedAt = capturedAtFormatter.string(from: Date())
var appValid = false
var windows: [WindowMetadata] = []

if metadataInput.isEmpty {
    if let app = NSRunningApplication(processIdentifier: pid),
       app.bundleIdentifier == "dev.relaykit.app",
       !app.isTerminated {
        appValid = true
        let liveWindows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] ?? []
        windows = liveWindows.compactMap { window in
            guard let ownerPID = (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value else {
                return nil
            }
            let windowID = (window[kCGWindowNumber as String] as? NSNumber)?.uint32Value
            let layer = (window[kCGWindowLayer as String] as? NSNumber)?.intValue
            let bounds = window[kCGWindowBounds as String] as? [String: Any]
            let rect = bounds.flatMap { CGRect(dictionaryRepresentation: $0 as CFDictionary) }
            let width = rect.map { Double($0.width) }
            let height = rect.map { Double($0.height) }
            let boundsValid = width?.isFinite == true && height?.isFinite == true &&
                (width ?? 0) > 0 && (height ?? 0) > 0
            return WindowMetadata(
                ownerPID: ownerPID,
                windowID: windowID,
                layer: layer,
                width: width,
                height: height,
                boundsValid: boundsValid
            )
        }
    }
} else {
    let data = try Data(contentsOf: URL(fileURLWithPath: metadataInput))
    let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    appValid = value["app_valid"] as? Bool == true
    let injectedWindows = value["windows"] as? [[String: Any]] ?? []
    windows = injectedWindows.compactMap { window in
        guard let ownerPID = (window["owner_pid"] as? NSNumber)?.int32Value else { return nil }
        return WindowMetadata(
            ownerPID: ownerPID,
            windowID: (window["window_id"] as? NSNumber)?.uint32Value,
            layer: (window["layer"] as? NSNumber)?.intValue,
            width: (window["width"] as? NSNumber)?.doubleValue,
            height: (window["height"] as? NSNumber)?.doubleValue,
            boundsValid: window["bounds_valid"] as? Bool == true
        )
    }
}

func baseDiagnostic(
    status: String,
    ownerWindowCount: Int,
    candidates: [Candidate],
    largestCandidateCount: Int
) -> [String: Any] {
    [
        "status": status,
        "pid": pid,
        "owner_window_count": ownerWindowCount,
        "eligible_count": candidates.filter(\.eligible).count,
        "largest_candidate_count": largestCandidateCount,
        "captured_at": capturedAt,
        "candidates": candidates.map(\.dictionary),
    ]
}

guard appValid else {
    try writeAtomicJSON(
        baseDiagnostic(
            status: "app_invalid",
            ownerWindowCount: 0,
            candidates: [],
            largestCandidateCount: 0
        ),
        to: diagnosticOutput
    )
    exit(2)
}

let ownerWindows = windows.filter { $0.ownerPID == pid }
let candidates = ownerWindows.compactMap { window -> Candidate? in
    guard window.boundsValid,
          let windowID = window.windowID,
          let layer = window.layer,
          let width = window.width,
          let height = window.height,
          width.isFinite,
          height.isFinite,
          width > 0,
          height > 0 else { return nil }
    return Candidate(
        windowID: windowID,
        layer: layer,
        width: width,
        height: height,
        area: width * height,
        eligible: width >= 400 && height >= 400
    )
}.sorted { $0.windowID < $1.windowID }
let eligible = candidates.filter(\.eligible)

guard let maximumArea = eligible.map(\.area).max() else {
    try writeAtomicJSON(
        baseDiagnostic(
            status: "no_eligible_window",
            ownerWindowCount: ownerWindows.count,
            candidates: candidates,
            largestCandidateCount: 0
        ),
        to: diagnosticOutput
    )
    exit(3)
}

let largest = eligible.filter { $0.area == maximumArea }
guard largest.count == 1, let selected = largest.first else {
    try writeAtomicJSON(
        baseDiagnostic(
            status: "ambiguous_largest_window",
            ownerWindowCount: ownerWindows.count,
            candidates: candidates,
            largestCandidateCount: largest.count
        ),
        to: diagnosticOutput
    )
    exit(4)
}

let identity: [String: Any] = [
    "pid": pid,
    "window_id": selected.windowID,
    "width": selected.width,
    "height": selected.height,
    "captured_at": capturedAt,
]
var diagnostic = baseDiagnostic(
    status: "selected",
    ownerWindowCount: ownerWindows.count,
    candidates: candidates,
    largestCandidateCount: 1
)
diagnostic["selected_window_id"] = selected.windowID
do {
    try writeAtomicJSON(identity, to: identityOutput)
    try writeAtomicJSON(diagnostic, to: diagnosticOutput)
} catch {
    try? fileManager.removeItem(atPath: identityOutput)
    throw error
}
SWIFT
}

activate_exact_app() {
  /usr/bin/osascript -e "tell application \"System Events\" to tell first process whose unix id is ${APP_PID} to set frontmost to true" >/dev/null
}

launch_ordinary_app() {
  local identity_path="$1"
  local diagnostic_path="$2"
  /usr/bin/open -n \
    --env "RELAYKIT_OFFICIAL_PROOF_ROOT=${OUT}/app-official-proof" \
    "${APP_BUNDLE}" --args \
    --ui-smoke-provider-config "${OUT}/providers.json" \
    --ui-smoke-usage-log "${OUT}/app-usage.jsonl" >/dev/null
  for _ in {1..100}; do
    APP_PID="$(find_exact_app_pid || true)"
    [[ -n "${APP_PID}" ]] && break
    sleep 0.1
  done
  [[ -n "${APP_PID}" ]] || return 1
  open_exact_app_popover
  for _ in {1..100}; do
    if write_exact_app_window_identity "${identity_path}" "${diagnostic_path}" 2>/dev/null; then
      activate_exact_app
      return 0
    fi
    sleep 0.1
  done
  if [[ -s "${diagnostic_path}" ]]; then
    printf 'RelayKit App window selector status: %s\n' "$(jq -r '.status' "${diagnostic_path}")" >&2
  fi
  return 1
}

run_ax() {
  local report="$1"
  shift
  activate_exact_app
  "${OUT}/run/codex-desktop-ax-driver" "$@" >"${report}" || return 1
  jq -e '
    .status == "ok" and .code == "ok" and .window_verified == true and
    ((keys - ["action_count","candidate_count","code","command","composer_count","model_picker_count","send_count","status","window_verified"]) | length == 0)
  ' "${report}" >/dev/null
}

wait_for_gateway() {
  for _ in {1..100}; do
    curl -fsS --max-time 1 http://127.0.0.1:19777/healthz >/dev/null 2>&1 && return 0
    sleep 0.1
  done
  return 1
}

run_window_identity_repro() {
  local repro_out="${RELAYKIT_RC1_WINDOW_REPRO_OUT:-}"
  local identity_path diagnostic_path launched_pid selector_status
  local shared_18787_before shared_19777_before

  [[ -n "${RELAYKIT_RC1_APP_BUNDLE:-}" ]] || fail "window repro requires RELAYKIT_RC1_APP_BUNDLE"
  [[ -n "${RELAYKIT_RC1_WINDOW_REPRO_OUT:-}" ]] || fail "window repro requires RELAYKIT_RC1_WINDOW_REPRO_OUT"
  [[ "${repro_out}" == /* && ! -e "${repro_out}" ]] ||
    fail "window repro output must be a fresh absolute path"
  [[ -d "${APP_BUNDLE}" && -x "${APP_REAL}" ]] || fail "window repro App bundle is incomplete"
  [[ -z "$(pgrep -x RelayKitApp.bin 2>/dev/null || true)" ]] || fail "RelayKit App is already running"

  shared_18787_before="$(listener_snapshot 18787)"
  shared_19777_before="$(listener_snapshot 19777)"
  mkdir -p "${repro_out}"
  chmod 700 "${repro_out}"
  identity_path="${repro_out}/window-identity.json"
  diagnostic_path="${repro_out}/window-diagnostic.json"
  trap cleanup EXIT INT TERM HUP

  /usr/bin/open -n "${APP_BUNDLE}" >/dev/null
  for _ in {1..100}; do
    APP_PID="$(find_exact_app_pid || true)"
    [[ -n "${APP_PID}" ]] && break
    sleep 0.1
  done
  [[ -n "${APP_PID}" ]] || fail "window repro App did not expose an exact PID"
  launched_pid="${APP_PID}"
  open_exact_app_popover || fail "window repro did not expose one status item"
  for _ in {1..100}; do
    if write_exact_app_window_identity "${identity_path}" "${diagnostic_path}" 2>/dev/null; then
      break
    fi
    sleep 0.1
  done
  [[ -s "${diagnostic_path}" ]] || fail "window repro selector wrote no diagnostic"
  selector_status="$(jq -r '.status' "${diagnostic_path}")"
  [[ "${selector_status}" == "selected" && -s "${identity_path}" ]] ||
    fail "window repro selector status=${selector_status}"
  [[ "$(listener_snapshot 18787)" == "${shared_18787_before}" ]] ||
    fail "window repro changed shared 18787"
  [[ "$(listener_snapshot 19777)" == "${shared_19777_before}" ]] ||
    fail "window repro changed 19777"

  stop_app
  kill -0 "${launched_pid}" 2>/dev/null && fail "window repro App cleanup failed"
  [[ -z "$(pgrep -x RelayKitApp.bin 2>/dev/null || true)" ]] || fail "window repro left RelayKit App running"
  [[ "$(listener_snapshot 18787)" == "${shared_18787_before}" ]] || fail "window repro cleanup changed shared 18787"
  [[ "$(listener_snapshot 19777)" == "${shared_19777_before}" ]] || fail "window repro cleanup changed 19777"
  trap - EXIT INT TERM HUP
  printf 'RelayKit RC1 window identity repro selected: identity=%s diagnostic=%s pid=%s status=%s\n' \
    "${identity_path}" "${diagnostic_path}" "${launched_pid}" "${selector_status}"
}

if [[ "${1:-}" == "--print-contract" ]]; then
  [[ "$#" -eq 1 ]] || exit 2
  print_contract
  exit 0
fi
if [[ "${1:-}" == "--select-window-identity" ]]; then
  [[ "$#" -eq 5 ]] || exit 2
  APP_PID="$2"
  if write_exact_app_window_identity "$3" "$4" "$5"; then
    exit 0
  else
    selector_exit="$?"
    exit "${selector_exit}"
  fi
fi
if [[ "${1:-}" == "--window-identity-repro" ]]; then
  [[ "$#" -eq 1 ]] || exit 2
  run_window_identity_repro
  exit 0
fi
[[ "$#" -eq 0 ]] || exit 2

[[ "${RUN_ID}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{5,63}$ ]] || fail "run id is invalid"
[[ "${OUT}" == /* && ! -e "${OUT}" ]] || fail "output must be a fresh absolute run-specific path"
[[ -d "${APP_BUNDLE}" && -x "${APP_REAL}" && -x "${BUNDLED_RELAY}" ]] || fail "extracted App is incomplete"
[[ -f "${APP_ZIP}" && ! -L "${APP_ZIP}" ]] || fail "App zip is missing"
[[ -x "${FIXTURE}" && -f "${AX_SOURCE}" && -x "${MANUAL_PROOF}" && -x "${MANIFEST}" ]] || fail "proof harness inputs are incomplete"
/usr/bin/codesign --verify --deep --strict "${APP_BUNDLE}" || fail "extracted App failed code-sign verification"
zip_app_sha="$(/usr/bin/unzip -p "${APP_ZIP}" 'RelayKitApp.app/Contents/MacOS/RelayKitApp.bin' | /usr/bin/shasum -a 256 | awk '{print $1}')"
[[ "${zip_app_sha}" == "$(sha256 "${APP_REAL}")" ]] || fail "extracted App does not match the bound App zip"
port_is_free 19777 || fail "127.0.0.1:19777 is already in use"
[[ -z "$(pgrep -x RelayKitApp.bin 2>/dev/null || true)" ]] || fail "RelayKit App is already running"

global_config_before="$(sha256 "${HOME}/.codex/config.toml")"
global_auth_before="$(sha256 "${HOME}/.codex/auth.json")"
shared_18787_before="$(listener_snapshot 18787)"
mkdir -p "${OUT}/run" "${OUT}/desktop-root"
chmod 700 "${OUT}" "${OUT}/run" "${OUT}/desktop-root"
trap cleanup EXIT INT TERM HUP

printf '{\n  "providers": []\n}\n' >"${OUT}/providers.json"
printf '' >"${OUT}/app-usage.jsonl"
chmod 600 "${OUT}/providers.json" "${OUT}/app-usage.jsonl"
python3 "${FIXTURE}" serve \
  --port-file "${OUT}/run/fixture-port" \
  --events "${OUT}/provider-events.jsonl" \
  --run-id "${RUN_ID}" \
  --synthetic-key "${SYNTHETIC_KEY}" >"${OUT}/run/fixture.stdout" 2>"${OUT}/run/fixture.stderr" &
FIXTURE_PID="$!"
wait_for_file "${OUT}/run/fixture-port" || fail "loopback fixture did not start"
fixture_port="$(cat "${OUT}/run/fixture-port")"
base_url="http://127.0.0.1:${fixture_port}/v1"

/usr/bin/xcrun swiftc "${AX_SOURCE}" -o "${OUT}/run/codex-desktop-ax-driver"
first_identity="${OUT}/run/app-window-first.json"
first_window_diagnostic="${OUT}/run/app-window-first-diagnostic.json"
launch_ordinary_app "${first_identity}" "${first_window_diagnostic}" ||
  fail "ordinary extracted App window selector status=$(jq -r '.status // "app_invalid"' "${first_window_diagnostic}" 2>/dev/null || printf 'app_invalid')"
jq -e '.providers == []' "${OUT}/providers.json" >/dev/null || fail "provider destination was not empty before AX setup"
run_ax "${OUT}/run/ax-provider-configure.json" \
  relaykit-provider-configure --pid "${APP_PID}" --window-identity "${first_identity}" \
  --provider-name "${PROVIDER_NAME}" --base-url "${base_url}" \
  --synthetic-key "${SYNTHETIC_KEY}" --model-id "${PROVIDER_MODEL}" || fail "exact AX provider setup failed"
KEYCHAIN_CREATED=true
jq -e --arg name "${PROVIDER_NAME}" --arg base "${base_url}" --arg model "${PROVIDER_MODEL}" --arg service "${KEYCHAIN_SERVICE}" '
  (.providers | length == 1) and
  .providers[0].name == $name and .providers[0].base_url == $base and
  .providers[0].api_format == "openai_responses" and
  .providers[0].credential_ref.kind == "keychain" and
  .providers[0].credential_ref.value == $service and
  .providers[0].credential_ref.header == "Authorization" and
  ((.providers[0].credential_ref | keys | sort) == ["header","kind","value"]) and
  ([.providers[0].models[].id] == [$model]) and
  ([.. | objects | select(has("key_file") or has("api_key") or has("token") or has("secret"))] | length == 0)
' "${OUT}/providers.json" >/dev/null || fail "saved provider JSON is not Responses plus Keychain-reference-only"
provider_config_sha="$(sha256 "${OUT}/providers.json")"

first_app_pid="${APP_PID}"
stop_app
for _ in {1..100}; do
  port_is_free 19777 && break
  sleep 0.1
done
port_is_free 19777 || fail "first App launch left gateway state behind"
second_identity="${OUT}/run/app-window-second.json"
second_window_diagnostic="${OUT}/run/app-window-second-diagnostic.json"
launch_ordinary_app "${second_identity}" "${second_window_diagnostic}" ||
  fail "same extracted App window selector status=$(jq -r '.status // "app_invalid"' "${second_window_diagnostic}" 2>/dev/null || printf 'app_invalid')"
[[ "${APP_PID}" != "${first_app_pid}" ]] || fail "App relaunch did not produce a fresh PID"
[[ "$(sha256 "${OUT}/providers.json")" == "${provider_config_sha}" ]] || fail "provider config changed during relaunch"
run_ax "${OUT}/run/ax-provider-verify.json" \
  relaykit-provider-verify --pid "${APP_PID}" --window-identity "${second_identity}" \
  --provider-name "${PROVIDER_NAME}" --base-url "${base_url}" --model-id "${PROVIDER_MODEL}" || fail "restored provider UI state was not verified"
run_ax "${OUT}/run/ax-gateway-start.json" \
  relaykit-gateway-start --pid "${APP_PID}" --window-identity "${second_identity}" || fail "App gateway Start AX action failed"
wait_for_gateway || fail "App-owned gateway did not become healthy"
HELPER_PID="$(pgrep -P "${APP_PID}" -f "${BUNDLED_RELAY}" | head -1 || true)"
[[ -n "${HELPER_PID}" ]] || fail "bundled Gateway is not owned by the exact App PID"

marker_a="RELAYKIT_NATIVE_TEXT_${RUN_ID//[^A-Za-z0-9]/_}"
marker_b="RELAYKIT_NATIVE_MARKDOWN_${RUN_ID//[^A-Za-z0-9]/_}"
marker_c="RELAYKIT_NATIVE_TOOL_${RUN_ID//[^A-Za-z0-9]/_}"
printf 'Reply with exactly this marker and no extra text: %s\n' "${marker_a}" >"${OUT}/query-A.txt"
cat >"${OUT}/query-B.txt" <<EOF
Render exactly this Markdown structure and include response marker ${marker_b}:
## RelayKit Rich Text Check
1. First route check
2. Second route check
| status | route |
| --- | --- |
| ready | official |
| ready | provider |
\`\`\`bash
echo relaykit
\`\`\`
**RELAYKIT_FORMAT_OK**
Do not call tools.
EOF
printf "Use the shell tool to run exactly: printf '%s\\n'; pwd\nThen report only the exact tool output.\n" "${marker_c}" >"${OUT}/query-C.txt"
chmod 600 "${OUT}/query-A.txt" "${OUT}/query-B.txt" "${OUT}/query-C.txt"
jq -n \
  --arg model "${PROVIDER_MODEL}" \
  --arg a "${OUT}/query-A.txt" --arg b "${OUT}/query-B.txt" --arg c "${OUT}/query-C.txt" \
  --arg ma "${marker_a}" --arg mb "${marker_b}" --arg mc "${marker_c}" '{
    version:1,
    stage_timeout_seconds:300,
    stages:[
      {id:"A",model_id:$model,model_label:$model,query_file:$a,response_marker:$ma,evidence_role:"rc1-text",expect:"plain"},
      {id:"B",model_id:$model,model_label:$model,query_file:$b,response_marker:$mb,evidence_role:"rc1-markdown",expect:"markdown"},
      {id:"C",model_id:$model,model_label:$model,query_file:$c,response_marker:$mc,evidence_role:"rc1-tool",expect:"tool"}
    ]
  }' >"${OUT}/scenario.json"
chmod 600 "${OUT}/scenario.json"

RELAYKIT_DESKTOP_PROOF_INPUT_MODE=automated_ax \
RELAYKIT_RC1_RUN_ID="${RUN_ID}" \
RELAYKIT_RC1_DESKTOP_ROOT="${OUT}/desktop-root" \
RELAYKIT_RC1_OUTPUT="${OUT}/desktop-evidence" \
RELAYKIT_RC1_APP_PID_FILE="${OUT}/run/app.pid" \
RELAYKIT_RC1_APP_WINDOW_IDENTITY="${second_identity}" \
RELAYKIT_RC1_APP_BUNDLE="${APP_BUNDLE}" \
RELAYKIT_RC1_APP_ZIP="${APP_ZIP}" \
RELAYKIT_RC1_PROVIDER_CONFIG="${OUT}/providers.json" \
RELAYKIT_RC1_USAGE_PATH="${OUT}/app-usage.jsonl" \
RELAYKIT_RC1_PROVIDER_EVENTS="${OUT}/provider-events.jsonl" \
  bash -c 'printf "%s\n" "$1" >"$2"; exec "$3" rc1-native-responses-three-stage --scenario "$4"' \
  _ "${APP_PID}" "${OUT}/run/app.pid" "${MANUAL_PROOF}" "${OUT}/scenario.json" \
  >"${OUT}/run/manual-proof-result.json" || fail "three-stage native Responses Desktop proof failed"

desktop_evidence="${OUT}/desktop-evidence/rc1-native-responses-evidence.json"
jq -e --arg run_id "${RUN_ID}" '
  .status == "complete" and .run_id == $run_id and
  .profile == "rc1_native_responses_three_stage" and
  .desktop_websocket_to_gateway == true and .gateway_sse_to_fixture == true and
  .tool_roundtrip_verified == true and .failed_events == [] and
  (.predicate_ledger | all(.[]; . == true)) and
  ([.stages[].submission_count] == [1,1,1])
' "${desktop_evidence}" >/dev/null || fail "three-stage evidence is incomplete"

native_evidence="${OUT}/native-app-evidence.json"
jq -n --arg run_id "${RUN_ID}" --arg app_zip_sha256 "$(sha256 "${APP_ZIP}")" '{
  status:"passed",
  run_id:$run_id,
  predicate_ledger:{
    ordinary_app_started:true,
    empty_provider_destination:true,
    provider_created_via_exact_ax:true,
    provider_json_openai_responses:true,
    credential_keychain_ref_only:true,
    app_relaunched:true,
    restored_protocol:true,
    restored_url:true,
    restored_model:true,
    restored_saved_key_state:true,
    gateway_started_via_ui:true
  },
  failed_events:[],
  app_zip_sha256:$app_zip_sha256
}' >"${native_evidence}"
chmod 600 "${native_evidence}"

screenshot="$(jq -er '.screenshot_path' "${desktop_evidence}")"
usage_evidence="$(jq -er '.usage_path' "${desktop_evidence}")"
"${MANIFEST}" \
  --native-evidence "${native_evidence}" \
  --desktop-evidence "${desktop_evidence}" \
  --provider-config "${OUT}/providers.json" \
  --app-zip "${APP_ZIP}" \
  --screenshot "${screenshot}" \
  --usage "${usage_evidence}" \
  --provider-events "${OUT}/provider-events.jsonl" \
  --harness "${MANUAL_PROOF}" \
  --scenario "${OUT}/scenario.json" \
  --output "${OUT}/manifest.json" >/dev/null
jq -e '.phase_b == "PASS" and .failed_events == [] and (.predicate_ledger | all(.[]; . == true))' \
  "${OUT}/manifest.json" >/dev/null || fail "phase-b manifest did not derive PASS"

[[ "$(sha256 "${HOME}/.codex/config.toml")" == "${global_config_before}" ]] || fail "global Codex config changed"
[[ "$(sha256 "${HOME}/.codex/auth.json")" == "${global_auth_before}" ]] || fail "global Codex auth changed"
[[ "$(listener_snapshot 18787)" == "${shared_18787_before}" ]] || fail "shared 18787 listener changed"
printf 'RelayKit RC1 native Responses chain passed: %s\n' "${OUT}/manifest.json"
