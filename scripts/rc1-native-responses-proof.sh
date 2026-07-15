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
AX_INSPECT_TEMP=""
AX_INSPECT_OUT=""
AX_INSPECT_FINALIZED=false
AX_INSPECT_FINAL_STATUS=1
AX_INSPECT_APP_LAUNCHED=false
AX_INSPECT_LAUNCHED_PID=""
AX_INSPECT_FAILURE="repro_failed"
AX_INSPECT_GLOBAL_CONFIG_BEFORE=""
AX_INSPECT_GLOBAL_AUTH_BEFORE=""
AX_INSPECT_18787_BEFORE=""
AX_INSPECT_19777_BEFORE=""
AX_INSPECT_OPEN_INVOCATION_COUNT=0
AX_INSPECT_OPEN_SUCCESS_COUNT=0
AX_INSPECT_OPEN_EXIT_STATUS=0
AX_INSPECT_OPEN_STDERR_CATEGORY=not_invoked
AX_INSPECT_EXACT_PID_COUNT=0
AX_INSPECT_APP_LAUNCH_COUNT=0
AX_INSPECT_PROBE_BINARY=""
AX_INSPECT_OWNED_TEMP_ROOT="${RELAYKIT_RC1_AX_INSPECT_OWNED_TEMP_ROOT:-}"
AX_INSPECT_OWNED_TEMP_CLEANUP_REQUIRED=false
AX_INSPECT_OWNED_TEMP_APP_REMOVED=false
AX_INSPECT_OWNED_ROOT_REAL=""
AX_INSPECT_OWNED_APP_REAL=""
AX_INSPECT_OWNED_MARKER_REAL=""
AX_INSPECT_OWNED_ROOT_STAT=""
AX_INSPECT_OWNED_APP_STAT=""
AX_INSPECT_OWNED_MARKER_STAT=""
CONFIG_REBASELINE_EVIDENCE="${RELAYKIT_RC1_CONFIG_REBASELINE_EVIDENCE:-}"
CONFIG_REBASELINE_EVIDENCE_SHA256="${RELAYKIT_RC1_CONFIG_REBASELINE_EVIDENCE_SHA256:-}"
GLOBAL_CONFIG_BASELINE_SHA256=""
GLOBAL_AUTH_BASELINE_SHA256=""
STATUS_ITEM_READINESS_ATTEMPTS=100
STATUS_ITEM_READINESS_INTERVAL=0.1

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

validate_config_rebaseline() {
  [[ "${CONFIG_REBASELINE_EVIDENCE}" == /* && -f "${CONFIG_REBASELINE_EVIDENCE}" &&
     ! -L "${CONFIG_REBASELINE_EVIDENCE}" ]] ||
    fail "config rebaseline evidence must be an explicit regular absolute path"
  [[ "${CONFIG_REBASELINE_EVIDENCE_SHA256}" =~ ^[0-9a-f]{64}$ ]] ||
    fail "config rebaseline evidence SHA-256 is invalid"
  [[ "$(stat -f '%Lp' "${CONFIG_REBASELINE_EVIDENCE}")" == "600" ]] ||
    fail "config rebaseline evidence permissions are not 0600"
  [[ "$(sha256 "${CONFIG_REBASELINE_EVIDENCE}")" == "${CONFIG_REBASELINE_EVIDENCE_SHA256}" ]] ||
    fail "config rebaseline evidence SHA-256 changed"
  jq -e '
    .schema_version == 1 and
    .observation == "external_pre_run_config_replacement" and
    (.previous_config_sha256 | test("^[0-9a-f]{64}$")) and
    (.new_config_sha256 | test("^[0-9a-f]{64}$")) and
    (.auth_sha256 | test("^[0-9a-f]{64}$")) and
    (.config_stat | type == "object") and
    .replacement_predated_relaykit_run == true and
    .latest_relaykit_run_changed_config == false and
    .latest_relaykit_run_changed_auth == false and
    .new_baseline_effective_for_future_fresh_runs == true and
    .global_files_written == false
  ' "${CONFIG_REBASELINE_EVIDENCE}" >/dev/null ||
    fail "config rebaseline evidence contract is invalid"
  GLOBAL_CONFIG_BASELINE_SHA256="$(jq -er '.new_config_sha256' "${CONFIG_REBASELINE_EVIDENCE}")"
  GLOBAL_AUTH_BASELINE_SHA256="$(jq -er '.auth_sha256' "${CONFIG_REBASELINE_EVIDENCE}")"
  [[ "$(sha256 "${HOME}/.codex/config.toml")" == "${GLOBAL_CONFIG_BASELINE_SHA256}" ]] ||
    fail "global Codex config no longer matches the rebaseline evidence"
  [[ "$(sha256 "${HOME}/.codex/auth.json")" == "${GLOBAL_AUTH_BASELINE_SHA256}" ]] ||
    fail "global Codex auth no longer matches the rebaseline evidence"
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
  if [[ "${KEYCHAIN_CREATED}" == "true" &&
        "${RELAYKIT_RC1_PROVIDER_PROTOCOL_PROBE_ONLY:-0}" != "1" &&
        -x "${APP_REAL}" ]]; then
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

read_exact_status_item_state() {
  local action="$1" output status=0 process_count menu_bar_count item_count extra
  output="$(osascript - "${APP_PID}" "${action}" 2>&1 <<'APPLESCRIPT'
on run argv
  set targetPID to (item 1 of argv) as integer
  set requestedAction to item 2 of argv
  tell application "System Events"
    set targetProcesses to every process whose unix id is targetPID
    set processCount to count of targetProcesses
    if processCount is not 1 then return (processCount as text) & tab & "0" & tab & "0"
    set targetProcess to item 1 of targetProcesses
    tell targetProcess
      set menuBarCount to count of menu bars
      set statusItems to {}
      if menuBarCount is 1 then set statusItems to menu bar items of menu bar 1
      set statusItemCount to count of statusItems
    end tell
    if requestedAction is "click" and menuBarCount is 1 and statusItemCount is 1 then
      set frontmost of targetProcess to true
      tell targetProcess to click item 1 of statusItems
    end if
    return (processCount as text) & tab & (menuBarCount as text) & tab & (statusItemCount as text)
  end tell
end run
APPLESCRIPT
  )" || status=$?
  [[ "${status}" -eq 0 ]] || { [[ "${output}" =~ (^|[^0-9])-1719([^0-9]|$) ]] && return 75; return 76; }
  IFS=$'\t' read -r process_count menu_bar_count item_count extra <<<"${output}"
  [[ -z "${extra}" && "${process_count}" =~ ^[0-9]+$ &&
     "${menu_bar_count}" =~ ^[0-9]+$ && "${item_count}" =~ ^[0-9]+$ ]] || return 76
  [[ "${process_count}" -eq 1 ]] || return 76
  printf '%s\t%s\n' "${menu_bar_count}" "${item_count}"
}

open_exact_nonactivating_menu_bar_panel() {
  # The exact status item opens RelayKit's canonical nonactivating NSPanel menu-bar panel.
  local attempt state read_status=0 menu_bar_count item_count ready=false
  for ((attempt = 1; attempt <= STATUS_ITEM_READINESS_ATTEMPTS; attempt++)); do
    read_status=0
    state="$(read_exact_status_item_state read)" || read_status=$?
    if [[ "${read_status}" -eq 0 ]]; then
      IFS=$'\t' read -r menu_bar_count item_count <<<"${state}"
      (( menu_bar_count > 1 || item_count > 1 )) && fail "status_item_not_unique"
      if [[ "${menu_bar_count}/${item_count}" == "1/1" ]]; then ready=true; break; fi
    elif [[ "${read_status}" -ne 75 ]]; then
      fail "status_item_read_error"
    fi
    (( attempt < STATUS_ITEM_READINESS_ATTEMPTS )) && sleep "${STATUS_ITEM_READINESS_INTERVAL}"
  done
  [[ "${ready}" == "true" ]] || fail "status_item_readiness_timeout"
  read_status=0; state="$(read_exact_status_item_state click)" || read_status=$?
  [[ "${read_status}" -eq 0 ]] || {
    [[ "${read_status}" -eq 75 ]] && fail "status_item_click_unavailable"
    fail "status_item_read_error"
  }
  IFS=$'\t' read -r menu_bar_count item_count <<<"${state}"
  [[ "${menu_bar_count}/${item_count}" == "1/1" ]] || fail "status_item_not_unique"
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
  open_exact_nonactivating_menu_bar_panel
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
  local temporary="${report}.tmp.$$.$RANDOM"
  local driver_status=0
  shift
  activate_exact_app
  (umask 077; "${OUT}/run/codex-desktop-ax-driver" "$@" >"${temporary}") || driver_status=$?
  if ! atomic_copy_private "${temporary}" "${report}"; then
    rm -f "${temporary}"
    return 1
  fi
  rm -f "${temporary}"
  [[ "${driver_status}" -eq 0 ]] || return "${driver_status}"
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
  open_exact_nonactivating_menu_bar_panel || fail "window repro did not open the exact nonactivating menu-bar panel"
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

atomic_write_private() {
  local target="$1"
  local temporary="${target}.tmp.$$.$RANDOM"
  umask 077
  /bin/cat >"${temporary}"
  chmod 600 "${temporary}"
  mv -f "${temporary}" "${target}"
}

atomic_copy_private() {
  local source="$1"
  local target="$2"
  local temporary="${target}.tmp.$$.$RANDOM"
  /bin/cp "${source}" "${temporary}" || { /bin/rm -f "${temporary}"; return 1; }
  chmod 600 "${temporary}" || { /bin/rm -f "${temporary}"; return 1; }
  mv -f "${temporary}" "${target}" || { /bin/rm -f "${temporary}"; return 1; }
  return 0
}

ax_driver_report_is_redacted() {
  jq -e '
    type == "object" and .command == "relaykit-ax-inspect" and
    (.status == "ok" or .status == "error") and (.code | type == "string") and
    ((keys - ["action_count","candidate_count","code","command","composer_count",
      "model_picker_count","send_count","status","window_verified"]) | length == 0) and
    ((has("candidate_count") | not) or .candidate_count == null or (.candidate_count | type == "number"))
  ' "$1" >/dev/null 2>&1
}

ax_tree_is_allowlisted() {
  jq -e '
    (keys | sort) == [
      "ax_windows_available","ax_windows_count","depth_counts",
      "matching_window_count","nodes","numbered_window_count",
      "role_counts","semantic_identifier_count","status","truncated"
    ] and .status == "ok" and .ax_windows_available == true and
    .ax_windows_count >= 1 and .numbered_window_count == 1 and
    .matching_window_count == 1 and .semantic_identifier_count >= 1 and
    .truncated == false and (.nodes | length >= 1) and
    .nodes[0].parent == null and .nodes[0].depth == 0 and
    .nodes[0].role == "AXWindow" and .nodes[0].window_number_present == true and
    .nodes[0].matches_expected_window == true and
    ([.role_counts[] | select(.role == "AXWindow") | .count] == [1]) and
    (.nodes | length <= 512) and ([.nodes[].depth] | max // 0) <= 12 and
    (.nodes | all(.[];
      (keys | sort) == [
        "child_count","depth","matches_expected_window","ordinal","parent",
        "role","subrole","window_number_present"
      ])) and
    (.role_counts | all(.[]; (keys | sort) == ["count","role"])) and
    (.depth_counts | all(.[]; (keys | sort) == ["count","depth"]))
  ' "$1" >/dev/null 2>&1
}

ax_driver_report_is_success() {
  jq -e '
    .command == "relaykit-ax-inspect" and .status == "ok" and .code == "ok" and
    .window_verified == true
  ' "$1" >/dev/null 2>&1
}

ax_window_identity_is_exact() {
  local identity="$1" diagnostic="$2" expected_pid="$3"
  jq -e --argjson expected_pid "${expected_pid}" --slurpfile identity "${identity}" '
    .status == "selected" and .pid == $expected_pid and
    .largest_candidate_count == 1 and
    ($identity | length == 1) and $identity[0].pid == $expected_pid and
    (.selected_window_id as $selected |
      $identity[0].window_id == $selected and
      ([.candidates[] | select(.window_id == $selected)] | length) == 1)
  ' "${diagnostic}" >/dev/null 2>&1
}

ax_inspect_artifact_hash() {
  /usr/bin/shasum -a 256 "$1" | awk '{print $1}'
}

launch_ax_inspect_app() {
  local action="${1:-launch}" raw_stderr="${AX_INSPECT_TEMP}/open.stderr" open_status=0
  [[ "${APP_BUNDLE}" == /* && "$(basename "${APP_BUNDLE}")" == "RelayKitApp.app" ]] || {
    AX_INSPECT_FAILURE=app_bundle_path_invalid
    return 2
  }
  [[ "${action}" == validate ]] && return 0
  AX_INSPECT_OPEN_INVOCATION_COUNT=1
  /usr/bin/open -n "${APP_BUNDLE}" >/dev/null 2>"${raw_stderr}" || open_status=$?
  AX_INSPECT_OPEN_EXIT_STATUS="${open_status}"
  if [[ -s "${raw_stderr}" ]]; then
    [[ "${open_status}" -eq 0 ]] && AX_INSPECT_OPEN_STDERR_CATEGORY=open_succeeded_with_stderr ||
      AX_INSPECT_OPEN_STDERR_CATEGORY=open_failed_with_stderr
  elif [[ "${open_status}" -eq 0 ]]; then
    AX_INSPECT_OPEN_STDERR_CATEGORY=none
  else
    AX_INSPECT_OPEN_STDERR_CATEGORY=open_failed_without_stderr
  fi
  rm -f "${raw_stderr}"
  if [[ "${open_status}" -ne 0 ]]; then AX_INSPECT_FAILURE=open_failed; return "${open_status}"; fi
  AX_INSPECT_OPEN_SUCCESS_COUNT=1
  for _ in {1..100}; do
    APP_PID="$(find_exact_app_pid || true)"
    [[ -n "${APP_PID}" ]] && break
    sleep 0.1
  done
  [[ -n "${APP_PID}" ]] || { AX_INSPECT_FAILURE=exact_pid_absent; return 1; }
  AX_INSPECT_EXACT_PID_COUNT=1
  AX_INSPECT_APP_LAUNCH_COUNT=1
  AX_INSPECT_APP_LAUNCHED=true
  AX_INSPECT_LAUNCHED_PID="${APP_PID}"
}

paths_overlap() {
  [[ "$1" == "$2" || "$1" == "$2/"* || "$2" == "$1/"* ]]
}

owned_temp_ax_inspect() {
  local action="$1" root="${AX_INSPECT_OWNED_TEMP_ROOT}" marker root_real app_real marker_real
  local out_real worktree_real home_real uid root_stat app_stat marker_stat top_count
  [[ -n "${root}" ]] || return 0
  marker="${root}/.relaykit-rc1-ax-inspect-owned"
  root_real="$(cd "${root}" 2>/dev/null && pwd -P || true)"
  app_real="$(cd "${APP_BUNDLE}" 2>/dev/null && pwd -P || true)"
  marker_real="$(cd "$(dirname "${marker}")" 2>/dev/null && pwd -P || true)/$(basename "${marker}")"
  out_real="$(cd "$(dirname "${AX_INSPECT_OUT}")" 2>/dev/null && pwd -P || true)/$(basename "${AX_INSPECT_OUT}")"
  worktree_real="$(cd "${ROOT}" 2>/dev/null && pwd -P || true)"; home_real="$(cd "${HOME}" 2>/dev/null && pwd -P || true)"
  uid="$(id -u)"; root_stat="$(stat -f '%d:%i:%u' "${root}" 2>/dev/null || true)"
  app_stat="$(stat -f '%d:%i:%u' "${APP_BUNDLE}" 2>/dev/null || true)"; marker_stat="$(stat -f '%d:%i:%u' "${marker}" 2>/dev/null || true)"
  top_count="$(/usr/bin/find "${root}" -mindepth 1 -maxdepth 1 -print 2>/dev/null | wc -l | tr -d ' ')"
  [[ "${root}" == /* && "${root}" != *$'\n'* && "${root}" == "${root_real}" && "${root_real}" != / &&
     -d "${root}" && ! -L "${root}" && "$(stat -f '%Lp:%u' "${root}")" == "700:${uid}" &&
     "${APP_BUNDLE}" == "${root_real}/RelayKitApp.app" && "${app_real}" == "${APP_BUNDLE}" &&
     -d "${APP_BUNDLE}" && ! -L "${APP_BUNDLE}" && "$(stat -f '%u' "${APP_BUNDLE}")" == "${uid}" &&
     "${marker_real}" == "${root_real}/.relaykit-rc1-ax-inspect-owned" && -f "${marker}" && ! -L "${marker}" &&
     "$(stat -f '%Lp:%u' "${marker}")" == "600:${uid}" && "$(cat "${marker}")" == "${app_real}" &&
     "${top_count}" == 2 ]] || return 1
  paths_overlap "${root_real}" "${out_real}" && return 1
  paths_overlap "${root_real}" "${worktree_real}" && return 1
  paths_overlap "${root_real}" "${home_real}" && return 1
  if [[ "${action}" == validate ]]; then
    AX_INSPECT_OWNED_ROOT_REAL="${root_real}"; AX_INSPECT_OWNED_APP_REAL="${app_real}"
    AX_INSPECT_OWNED_MARKER_REAL="${marker_real}"; AX_INSPECT_OWNED_ROOT_STAT="${root_stat}"
    AX_INSPECT_OWNED_APP_STAT="${app_stat}"; AX_INSPECT_OWNED_MARKER_STAT="${marker_stat}"
    AX_INSPECT_OWNED_TEMP_CLEANUP_REQUIRED=true
    return 0
  fi
  [[ "${root_real}" == "${AX_INSPECT_OWNED_ROOT_REAL}" && "${app_real}" == "${AX_INSPECT_OWNED_APP_REAL}" &&
     "${marker_real}" == "${AX_INSPECT_OWNED_MARKER_REAL}" && "${root_stat}" == "${AX_INSPECT_OWNED_ROOT_STAT}" &&
     "${app_stat}" == "${AX_INSPECT_OWNED_APP_STAT}" && "${marker_stat}" == "${AX_INSPECT_OWNED_MARKER_STAT}" ]] || return 1
  rm -rf -- "${AX_INSPECT_OWNED_APP_REAL}" >/dev/null 2>&1 || return 1
  [[ ! -e "${AX_INSPECT_OWNED_APP_REAL}" && ! -L "${AX_INSPECT_OWNED_APP_REAL}" &&
     "$(stat -f '%d:%i:%u' "${root}" 2>/dev/null || true)" == "${AX_INSPECT_OWNED_ROOT_STAT}" &&
     "$(stat -f '%Lp:%u' "${root}")" == "700:${uid}" &&
     "$(stat -f '%d:%i:%u' "${marker}" 2>/dev/null || true)" == "${AX_INSPECT_OWNED_MARKER_STAT}" &&
     -f "${marker}" && ! -L "${marker}" && "$(stat -f '%Lp:%u' "${marker}")" == "600:${uid}" &&
     "$(cat "${marker}")" == "${AX_INSPECT_OWNED_APP_REAL}" &&
     "$(/usr/bin/find "${root}" -mindepth 1 -maxdepth 1 -print | wc -l | tr -d ' ')" == 1 ]] || return 1
  rm -f -- "${AX_INSPECT_OWNED_MARKER_REAL}" >/dev/null 2>&1 || return 1
  [[ ! -e "${AX_INSPECT_OWNED_MARKER_REAL}" && ! -L "${AX_INSPECT_OWNED_MARKER_REAL}" &&
     "$(stat -f '%d:%i:%u' "${root}" 2>/dev/null || true)" == "${AX_INSPECT_OWNED_ROOT_STAT}" &&
     "$(stat -f '%Lp:%u' "${root}")" == "700:${uid}" &&
     -z "$(/usr/bin/find "${root}" -mindepth 1 -maxdepth 1 -print -quit)" ]] || return 1
  rmdir -- "${AX_INSPECT_OWNED_ROOT_REAL}" >/dev/null 2>&1 || return 1
  [[ ! -e "${AX_INSPECT_OWNED_ROOT_REAL}" && ! -L "${AX_INSPECT_OWNED_ROOT_REAL}" ]] || return 1
  AX_INSPECT_OWNED_TEMP_APP_REMOVED=true
}

ax_inspect_finalize() {
  local original_exit="$1"
  local final_exit="${original_exit}"
  local stable_identity="${AX_INSPECT_OUT}/window-identity.json"
  local stable_window_diagnostic="${AX_INSPECT_OUT}/window-diagnostic.json"
  local stable_driver_report="${AX_INSPECT_OUT}/ax-driver-report.json"
  local stable_tree="${AX_INSPECT_OUT}/ax-tree.json"
  local app_stop_attempted=false
  local app_stopped=true
  local global_config_unchanged=false
  local global_auth_unchanged=false
  local shared_18787_unchanged=false
  local port_19777_unchanged=false
  local transient_removed=false
  local probe_binary_removed=false
  local tree_status=not_created
  local result_status=failed
  local driver_status=error
  local driver_code=not_created
  local driver_command=relaykit-ax-inspect
  local driver_candidate_count=null
  local artifact_tree_hash=""

  [[ "${AX_INSPECT_FINALIZED}" == "false" ]] || return 0
  AX_INSPECT_FINALIZED=true
  trap - EXIT INT TERM HUP

  if [[ -s "${AX_INSPECT_TEMP}/window-identity.json" ]]; then
    atomic_copy_private "${AX_INSPECT_TEMP}/window-identity.json" "${stable_identity}"
  else
    jq -n '{status:"not_created"}' | atomic_write_private "${stable_identity}"
  fi
  if [[ -s "${AX_INSPECT_TEMP}/window-diagnostic.json" ]]; then
    atomic_copy_private "${AX_INSPECT_TEMP}/window-diagnostic.json" "${stable_window_diagnostic}"
  else
    jq -n '{status:"not_created"}' | atomic_write_private "${stable_window_diagnostic}"
  fi
  if [[ -s "${AX_INSPECT_TEMP}/ax-driver-report.json" ]] &&
     ax_driver_report_is_redacted "${AX_INSPECT_TEMP}/ax-driver-report.json"; then
    atomic_copy_private "${AX_INSPECT_TEMP}/ax-driver-report.json" "${stable_driver_report}"
  else
    jq -n '{command:"relaykit-ax-inspect",status:"error",code:"not_created"}' |
      atomic_write_private "${stable_driver_report}"
  fi
  if [[ -s "${AX_INSPECT_TEMP}/ax-tree.json" ]] &&
     ax_tree_is_allowlisted "${AX_INSPECT_TEMP}/ax-tree.json"; then
    atomic_copy_private "${AX_INSPECT_TEMP}/ax-tree.json" "${stable_tree}"
    tree_status=created
  fi

  if [[ "${AX_INSPECT_APP_LAUNCHED}" == "true" && -n "${AX_INSPECT_LAUNCHED_PID}" ]]; then
    if kill -0 "${AX_INSPECT_LAUNCHED_PID}" 2>/dev/null; then
      app_stop_attempted=true
      kill -TERM "${AX_INSPECT_LAUNCHED_PID}" >/dev/null 2>&1 || true
      for _ in {1..100}; do
        kill -0 "${AX_INSPECT_LAUNCHED_PID}" 2>/dev/null || break
        sleep 0.1
      done
    fi
    if kill -0 "${AX_INSPECT_LAUNCHED_PID}" 2>/dev/null; then
      app_stopped=false
    fi
  fi
  APP_PID=""

  [[ "$(sha256 "${HOME}/.codex/config.toml")" == "${AX_INSPECT_GLOBAL_CONFIG_BEFORE}" ]] &&
    global_config_unchanged=true
  [[ "$(sha256 "${HOME}/.codex/auth.json")" == "${AX_INSPECT_GLOBAL_AUTH_BEFORE}" ]] &&
    global_auth_unchanged=true
  [[ "$(listener_snapshot 18787)" == "${AX_INSPECT_18787_BEFORE}" ]] &&
    shared_18787_unchanged=true
  [[ "$(listener_snapshot 19777)" == "${AX_INSPECT_19777_BEFORE}" ]] &&
    port_19777_unchanged=true

  rm -rf "${AX_INSPECT_TEMP}"
  [[ ! -e "${AX_INSPECT_TEMP}" ]] && transient_removed=true
  [[ -z "${AX_INSPECT_PROBE_BINARY}" || ! -e "${AX_INSPECT_PROBE_BINARY}" ]] && probe_binary_removed=true
  AX_INSPECT_TEMP=""
  if [[ "${AX_INSPECT_OWNED_TEMP_CLEANUP_REQUIRED}" == true ]]; then
    owned_temp_ax_inspect remove || true
  fi

  if [[ "${RELAYKIT_RC1_AX_INSPECT_TEST:-0}" == "1" ]]; then
    [[ "${RELAYKIT_RC1_AX_INSPECT_TEST_FORCE_APP_STOPPED_FALSE:-false}" != "true" ]] ||
      app_stopped=false
    [[ "${RELAYKIT_RC1_AX_INSPECT_TEST_FORCE_SHARED_18787_FALSE:-false}" != "true" ]] ||
      shared_18787_unchanged=false
    [[ "${RELAYKIT_RC1_AX_INSPECT_TEST_FORCE_PORT_19777_FALSE:-false}" != "true" ]] ||
      port_19777_unchanged=false
    [[ "${RELAYKIT_RC1_AX_INSPECT_TEST_FORCE_TRANSIENT_REMOVED_FALSE:-false}" != "true" ]] ||
      transient_removed=false
  fi

  if [[ "${original_exit}" -eq 0 &&
        ("${global_config_unchanged}" != "true" ||
         "${global_auth_unchanged}" != "true" ||
         "${app_stopped}" != "true" ||
         "${shared_18787_unchanged}" != "true" ||
         "${port_19777_unchanged}" != "true" ||
         "${transient_removed}" != "true" || "${probe_binary_removed}" != "true" ||
         ("${AX_INSPECT_OWNED_TEMP_CLEANUP_REQUIRED}" == "true" && "${AX_INSPECT_OWNED_TEMP_APP_REMOVED}" != "true")) ]]; then
    final_exit=4
    AX_INSPECT_FAILURE=cleanup_invariant_failed
  fi

  jq -n \
    --argjson app_launched "${AX_INSPECT_APP_LAUNCHED}" \
    --argjson app_stop_attempted "${app_stop_attempted}" \
    --argjson app_stopped "${app_stopped}" \
    --argjson global_auth_unchanged "${global_auth_unchanged}" \
    --argjson global_config_unchanged "${global_config_unchanged}" \
    --argjson port_19777_unchanged "${port_19777_unchanged}" \
    --argjson owned_temp_cleanup_required "${AX_INSPECT_OWNED_TEMP_CLEANUP_REQUIRED}" \
    --argjson owned_temp_app_removed "${AX_INSPECT_OWNED_TEMP_APP_REMOVED}" \
    --argjson probe_binary_removed "${probe_binary_removed}" \
    --argjson shared_18787_unchanged "${shared_18787_unchanged}" \
    --argjson transient_removed "${transient_removed}" '{
      schema_version:1,
      app_launched:$app_launched,
      app_stop_attempted:$app_stop_attempted,
      app_stopped:$app_stopped,
      global_auth_unchanged:$global_auth_unchanged,
      global_config_unchanged:$global_config_unchanged,
      owned_temp_cleanup_required:$owned_temp_cleanup_required,
      owned_temp_app_removed:$owned_temp_app_removed,
      port_19777_unchanged:$port_19777_unchanged,
      probe_binary_removed:$probe_binary_removed,
      shared_18787_unchanged:$shared_18787_unchanged,
      transient_removed:$transient_removed
    }' | atomic_write_private "${AX_INSPECT_OUT}/cleanup.json"

  driver_status="$(jq -r '.status' "${stable_driver_report}")"
  driver_code="$(jq -r '.code' "${stable_driver_report}")"
  driver_command="$(jq -r '.command' "${stable_driver_report}")"
  driver_candidate_count="$(jq -c 'if has("candidate_count") then .candidate_count else null end' "${stable_driver_report}")"
  if [[ "${final_exit}" -eq 0 &&
        "${driver_status}" == "ok" && "${driver_code}" == "ok" &&
        "${tree_status}" == "created" && "${AX_INSPECT_EXACT_PID_COUNT}" -eq 1 ]]; then
    result_status=passed
    AX_INSPECT_FAILURE=none
  elif [[ "${final_exit}" -eq 0 ]]; then
    final_exit=4
    AX_INSPECT_FAILURE=ax_binding_not_exact
  fi
  jq -n \
    --arg status "${result_status}" \
    --argjson exit_code "${final_exit}" \
    --arg failure "${AX_INSPECT_FAILURE}" \
    --arg driver_status "${driver_status}" \
    --arg driver_code "${driver_code}" \
    --arg driver_command "${driver_command}" \
    --argjson driver_candidate_count "${driver_candidate_count}" \
    --argjson open_invocation_count "${AX_INSPECT_OPEN_INVOCATION_COUNT}" \
    --argjson open_success_count "${AX_INSPECT_OPEN_SUCCESS_COUNT}" \
    --argjson open_exit_status "${AX_INSPECT_OPEN_EXIT_STATUS}" \
    --arg open_stderr_category "${AX_INSPECT_OPEN_STDERR_CATEGORY}" \
    --argjson exact_pid_count "${AX_INSPECT_EXACT_PID_COUNT}" \
    --argjson app_launch_count "${AX_INSPECT_APP_LAUNCH_COUNT}" \
    --arg ax_tree "${tree_status}" '{
      schema_version:1,
      status:$status,
      exit_code:$exit_code,
      failure:$failure,
      driver_status:$driver_status,
      driver_code:$driver_code,
      driver_command:$driver_command,
      driver_candidate_count:$driver_candidate_count,
      open_invocation_count:$open_invocation_count,
      open_success_count:$open_success_count,
      open_exit_status:$open_exit_status,
      open_stderr_category:$open_stderr_category,
      exact_pid_count:$exact_pid_count,
      app_launch_count:$app_launch_count,
      package_invocation_count:0,
      full_e2e_invocation_count:0,
      ax_tree:$ax_tree
    }' | atomic_write_private "${AX_INSPECT_OUT}/result.json"

  if [[ "${tree_status}" == "created" ]]; then
    artifact_tree_hash="$(ax_inspect_artifact_hash "${stable_tree}")"
  fi
  jq -n \
    --arg inspect_out "${AX_INSPECT_OUT}" \
    --arg status "${result_status}" \
    --arg failure "${AX_INSPECT_FAILURE}" \
    --arg run_metadata_hash "$(ax_inspect_artifact_hash "${AX_INSPECT_OUT}/run-metadata.json")" \
    --arg identity_hash "$(ax_inspect_artifact_hash "${stable_identity}")" \
    --arg window_diagnostic_hash "$(ax_inspect_artifact_hash "${stable_window_diagnostic}")" \
    --arg driver_report_hash "$(ax_inspect_artifact_hash "${stable_driver_report}")" \
    --arg tree_status "${tree_status}" \
    --arg tree_hash "${artifact_tree_hash}" \
    --arg cleanup_hash "$(ax_inspect_artifact_hash "${AX_INSPECT_OUT}/cleanup.json")" \
    --arg result_hash "$(ax_inspect_artifact_hash "${AX_INSPECT_OUT}/result.json")" '{
      schema_version:1,
      inspect_out:$inspect_out,
      status:$status,
      failure:$failure,
      artifacts:[
        {name:"run_metadata",path:"run-metadata.json",status:"created",sha256:$run_metadata_hash},
        {name:"window_identity",path:"window-identity.json",status:"created",sha256:$identity_hash},
        {name:"window_diagnostic",path:"window-diagnostic.json",status:"created",sha256:$window_diagnostic_hash},
        {name:"driver_report",path:"ax-driver-report.json",status:"created",sha256:$driver_report_hash},
        {name:"ax_tree",path:"ax-tree.json",status:$tree_status,sha256:(if $tree_status == "created" then $tree_hash else null end)},
        {name:"cleanup",path:"cleanup.json",status:"created",sha256:$cleanup_hash},
        {name:"result",path:"result.json",status:"created",sha256:$result_hash}
      ]
    }' | atomic_write_private "${AX_INSPECT_OUT}/evidence-manifest.json"
  AX_INSPECT_FINAL_STATUS="${final_exit}"
  printf 'INSPECT_OUT=%s\n' "${AX_INSPECT_OUT}"
}

ax_inspect_exit_handler() {
  local status="$?"
  ax_inspect_finalize "${status}"
  exit "${AX_INSPECT_FINAL_STATUS}"
}

ax_inspect_signal_handler() {
  local status="$1"
  AX_INSPECT_FAILURE=signal
  ax_inspect_finalize "${status}"
  exit "${AX_INSPECT_FINAL_STATUS}"
}

run_window_ax_inspect_repro() {
  local repro_out="${RELAYKIT_RC1_AX_INSPECT_OUT:-}"
  local identity_path window_diagnostic_path diagnostic_output report_temporary
  local driver_binary selector_status driver_exit launch_exit tracked_files_sha256
  local test_mode=false

  [[ -n "${RELAYKIT_RC1_APP_BUNDLE:-}" ]] || fail "AX inspect repro requires RELAYKIT_RC1_APP_BUNDLE"
  [[ -n "${RELAYKIT_RC1_AX_INSPECT_OUT:-}" ]] || fail "AX inspect repro requires RELAYKIT_RC1_AX_INSPECT_OUT"
  AX_INSPECT_OUT="${repro_out}"
  [[ "${repro_out}" == /* && ! -e "${repro_out}" ]] ||
    fail "AX inspect repro output must be a fresh absolute path"
  owned_temp_ax_inspect validate || fail "AX inspect repro owned temp root is invalid"
  launch_ax_inspect_app validate || fail "AX inspect repro App bundle path is invalid"
  [[ -d "${APP_BUNDLE}" && -x "${APP_REAL}" ]] || fail "AX inspect repro App bundle is incomplete"
  [[ -f "${AX_SOURCE}" ]] || fail "AX inspect repro driver source is missing"
  [[ -z "$(pgrep -x RelayKitApp.bin 2>/dev/null || true)" ]] || fail "RelayKit App is already running"
  validate_config_rebaseline

  if [[ "${RELAYKIT_RC1_AX_INSPECT_TEST:-0}" == "1" ]]; then
    test_mode=true
    [[ "${RELAYKIT_RC1_AX_INSPECT_FAKE_DRIVER:-}" == /* &&
       -x "${RELAYKIT_RC1_AX_INSPECT_FAKE_DRIVER}" ]] ||
      fail "AX inspect test gate requires an absolute fake driver"
  fi

  AX_INSPECT_FINALIZED=false
  AX_INSPECT_FINAL_STATUS=1
  AX_INSPECT_APP_LAUNCHED=false
  AX_INSPECT_LAUNCHED_PID=""
  AX_INSPECT_FAILURE=repro_failed
  AX_INSPECT_OPEN_INVOCATION_COUNT=0; AX_INSPECT_OPEN_SUCCESS_COUNT=0; AX_INSPECT_OPEN_EXIT_STATUS=0
  AX_INSPECT_OPEN_STDERR_CATEGORY=not_invoked; AX_INSPECT_EXACT_PID_COUNT=0; AX_INSPECT_APP_LAUNCH_COUNT=0
  AX_INSPECT_GLOBAL_CONFIG_BEFORE="${GLOBAL_CONFIG_BASELINE_SHA256}"
  AX_INSPECT_GLOBAL_AUTH_BEFORE="${GLOBAL_AUTH_BASELINE_SHA256}"
  AX_INSPECT_18787_BEFORE="$(listener_snapshot 18787)"
  AX_INSPECT_19777_BEFORE="$(listener_snapshot 19777)"
  umask 077
  mkdir "${AX_INSPECT_OUT}"
  chmod 700 "${AX_INSPECT_OUT}"
  AX_INSPECT_TEMP="${AX_INSPECT_OUT}/.run"
  mkdir "${AX_INSPECT_TEMP}"
  chmod 700 "${AX_INSPECT_TEMP}"
  identity_path="${AX_INSPECT_TEMP}/window-identity.json"
  window_diagnostic_path="${AX_INSPECT_TEMP}/window-diagnostic.json"
  diagnostic_output="${AX_INSPECT_TEMP}/ax-tree.json"
  report_temporary="${AX_INSPECT_TEMP}/ax-driver-report.json"
  driver_binary="${AX_INSPECT_TEMP}/codex-desktop-ax-driver"
  AX_INSPECT_PROBE_BINARY="${driver_binary}"
  printf 'INSPECT_OUT=%s\n' "${AX_INSPECT_OUT}"
  trap ax_inspect_exit_handler EXIT
  trap 'ax_inspect_signal_handler 130' INT
  trap 'ax_inspect_signal_handler 143' TERM
  trap 'ax_inspect_signal_handler 129' HUP

  if [[ "${test_mode}" == "true" ]]; then
    driver_binary="${RELAYKIT_RC1_AX_INSPECT_FAKE_DRIVER}"
  else
    /usr/bin/xcrun swiftc "${AX_SOURCE}" -o "${driver_binary}"
  fi
  tracked_files_sha256="$(for path in \
    app/Sources/RelayKitApp/App/RelayKitApp.swift app/Sources/RelayKitAppValidationTests/main.swift \
    scripts/codex-desktop-ax-driver.swift scripts/codex-desktop-ax-driver-test.sh \
    scripts/rc1-native-responses-proof.sh scripts/rc1-native-responses-proof-test.sh; do
      jq -n --arg key "${path}" --arg value "$(sha256 "${ROOT}/${path}")" '{key:$key,value:$value}'
    done | jq -s 'from_entries')"

  jq -n \
    --arg inspect_out "${AX_INSPECT_OUT}" \
    --arg app_bundle_path "${APP_BUNDLE}" \
    --arg app_binary_sha256 "$(sha256 "${APP_REAL}")" \
    --arg ax_driver_binary_sha256 "$(sha256 "${driver_binary}")" \
    --arg ax_driver_source_sha256 "$(sha256 "${AX_SOURCE}")" \
    --argjson tracked_files_sha256 "${tracked_files_sha256}" \
    --arg config_rebaseline_evidence_path "${CONFIG_REBASELINE_EVIDENCE}" \
    --arg config_rebaseline_evidence_sha256 "${CONFIG_REBASELINE_EVIDENCE_SHA256}" '{
      schema_version:1,
      mode:"window_ax_inspect_repro",
      inspect_out:$inspect_out,
      app_bundle_path:$app_bundle_path,
      app_binary_sha256:$app_binary_sha256,
      ax_driver_binary_sha256:$ax_driver_binary_sha256,
      ax_driver_source_sha256:$ax_driver_source_sha256,
      tracked_files_sha256:$tracked_files_sha256,
      package_invocation_count:0,
      full_e2e_invocation_count:0,
      config_rebaseline_evidence_path:$config_rebaseline_evidence_path,
      config_rebaseline_evidence_sha256:$config_rebaseline_evidence_sha256
    }' | atomic_write_private "${AX_INSPECT_OUT}/run-metadata.json"

  if [[ "${test_mode}" == "true" ]]; then
    if [[ "${RELAYKIT_RC1_AX_INSPECT_TEST_FORCE_DEAD_PID:-false}" == "true" ]]; then
      APP_PID=2147483647
    else
      APP_PID="$$"
    fi
    AX_INSPECT_EXACT_PID_COUNT=1
    jq -n --argjson pid "${APP_PID}" '{pid:$pid,window_id:101,width:640,height:480,captured_at:"test"}' |
      atomic_write_private "${identity_path}"
    jq -n --argjson pid "${APP_PID}" '{
      status:"selected",pid:$pid,owner_window_count:1,eligible_count:1,largest_candidate_count:1,
      captured_at:"test",selected_window_id:101,
      candidates:[{window_id:101,layer:25,width:640,height:480,area:307200,eligible:true}]
    }' | atomic_write_private "${window_diagnostic_path}"
  else
    launch_exit=0
    launch_ax_inspect_app || launch_exit=$?
    if [[ "${launch_exit}" -ne 0 ]]; then
      ax_inspect_finalize "${launch_exit}"
      exit "${AX_INSPECT_FINAL_STATUS}"
    fi
    open_exact_nonactivating_menu_bar_panel || fail "AX inspect repro did not open the exact nonactivating menu-bar panel"
    for _ in {1..100}; do
      if write_exact_app_window_identity "${identity_path}" "${window_diagnostic_path}" 2>/dev/null; then
        break
      fi
      sleep 0.1
    done
    [[ -s "${window_diagnostic_path}" ]] || fail "AX inspect repro selector wrote no diagnostic"
    selector_status="$(jq -r '.status' "${window_diagnostic_path}")"
    [[ "${selector_status}" == "selected" && -s "${identity_path}" ]] ||
      fail "AX inspect repro selector did not produce one exact identity"
    activate_exact_app
  fi

  if RELAYKIT_AX_DRIVER_DIAGNOSTIC=1 "${driver_binary}" \
    relaykit-ax-inspect --pid "${APP_PID}" --window-identity "${identity_path}" \
    --diagnostic-output "${diagnostic_output}" >"${report_temporary}"; then
    driver_exit=0
  else
    driver_exit="$?"
  fi
  if [[ "${driver_exit}" -ne 0 ]]; then
    AX_INSPECT_FAILURE=driver_failed
    ax_inspect_finalize "${driver_exit}"
    exit "${AX_INSPECT_FINAL_STATUS}"
  fi
  if ! ax_driver_report_is_redacted "${report_temporary}"; then
    AX_INSPECT_FAILURE=driver_report_invalid
    ax_inspect_finalize 4
    exit "${AX_INSPECT_FINAL_STATUS}"
  fi
  if ! ax_driver_report_is_success "${report_temporary}"; then
    AX_INSPECT_FAILURE=driver_report_failed
    ax_inspect_finalize 4
    exit "${AX_INSPECT_FINAL_STATUS}"
  fi
  if ! kill -0 "${APP_PID}" 2>/dev/null ||
     [[ "${AX_INSPECT_EXACT_PID_COUNT}" -ne 1 ]] ||
     ! ax_window_identity_is_exact "${identity_path}" "${window_diagnostic_path}" "${APP_PID}" ||
     ! ax_tree_is_allowlisted "${diagnostic_output}"; then
    AX_INSPECT_FAILURE=ax_binding_not_exact
    ax_inspect_finalize 4
    exit "${AX_INSPECT_FINAL_STATUS}"
  fi
  ax_inspect_finalize 0
  [[ "${AX_INSPECT_FINAL_STATUS}" -eq 0 ]] || exit "${AX_INSPECT_FINAL_STATUS}"
  printf '%s\n' 'RelayKit RC1 AX inspect repro passed'
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
if [[ "${1:-}" == "--window-ax-inspect-repro" ]]; then
  [[ "$#" -eq 1 ]] || exit 2
  run_window_ax_inspect_repro
  exit 0
fi
[[ "$#" -eq 0 ]] || exit 2

[[ "${RUN_ID}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{5,63}$ ]] || fail "run id is invalid"
[[ "${OUT}" == /* && ! -e "${OUT}" ]] || fail "output must be a fresh absolute run-specific path"
[[ "${RELAYKIT_RC1_PROVIDER_PROTOCOL_PROBE_ONLY:-0}" == "0" ||
   "${RELAYKIT_RC1_PROVIDER_PROTOCOL_PROBE_ONLY:-0}" == "1" ]] || fail "provider protocol probe mode is invalid"
global_config_before="$(sha256 "${HOME}/.codex/config.toml")"
global_auth_before="$(sha256 "${HOME}/.codex/auth.json")"
[[ "${global_config_before}" != "missing" ]] || fail "global Codex config baseline is missing"
[[ "${global_auth_before}" != "missing" ]] || fail "global Codex auth baseline is missing"

if [[ "${RELAYKIT_RC1_FULL_PROOF_TEST_STOP_AFTER_SETUP:-0}" == "1" ]]; then
  mkdir -p "${OUT}/run" "${OUT}/desktop-root"
  chmod 700 "${OUT}" "${OUT}/run" "${OUT}/desktop-root"
  : >"${OUT}/run/full-proof-test-ready"
  chmod 600 "${OUT}/run/full-proof-test-ready"
  for _ in {1..500}; do
    [[ -e "${OUT}/run/full-proof-test-continue" ]] && break
    sleep 0.01
  done
  [[ -e "${OUT}/run/full-proof-test-continue" ]] || fail "public full proof test continuation was not provided"
  [[ "$(sha256 "${HOME}/.codex/config.toml")" == "${global_config_before}" ]] || fail "global Codex config changed"
  [[ "$(sha256 "${HOME}/.codex/auth.json")" == "${global_auth_before}" ]] || fail "global Codex auth changed"
  printf '%s\n' 'RelayKit RC1 public full proof test setup passed'
  exit 0
fi

[[ -d "${APP_BUNDLE}" && -x "${APP_REAL}" && -x "${BUNDLED_RELAY}" ]] || fail "extracted App is incomplete"
[[ -f "${APP_ZIP}" && ! -L "${APP_ZIP}" ]] || fail "App zip is missing"
[[ -x "${FIXTURE}" && -f "${AX_SOURCE}" ]] || fail "proof harness inputs are incomplete"
[[ "${RELAYKIT_RC1_PROVIDER_PROTOCOL_PROBE_ONLY:-0}" == "1" || ( -x "${MANUAL_PROOF}" && -x "${MANIFEST}" ) ]] || fail "proof harness inputs are incomplete"
/usr/bin/codesign --verify --deep --strict "${APP_BUNDLE}" || fail "extracted App failed code-sign verification"
zip_app_sha="$(/usr/bin/unzip -p "${APP_ZIP}" 'RelayKitApp.app/Contents/MacOS/RelayKitApp.bin' | /usr/bin/shasum -a 256 | awk '{print $1}')"
[[ "${zip_app_sha}" == "$(sha256 "${APP_REAL}")" ]] || fail "extracted App does not match the bound App zip"
port_is_free 19777 || fail "127.0.0.1:19777 is already in use"
[[ -z "$(pgrep -x RelayKitApp.bin 2>/dev/null || true)" ]] || fail "RelayKit App is already running"

shared_18787_before="$(listener_snapshot 18787)"
mkdir -p "${OUT}/run"
[[ "${RELAYKIT_RC1_PROVIDER_PROTOCOL_PROBE_ONLY:-0}" == "1" ]] || mkdir -p "${OUT}/desktop-root"
chmod 700 "${OUT}" "${OUT}/run"
[[ "${RELAYKIT_RC1_PROVIDER_PROTOCOL_PROBE_ONLY:-0}" == "1" ]] || chmod 700 "${OUT}/desktop-root"
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
if [[ "${RELAYKIT_RC1_PROVIDER_PROTOCOL_PROBE_ONLY:-0}" == "1" ]]; then
  KEYCHAIN_CREATED=false
  run_ax "${OUT}/run/ax-provider-protocol-probe.json" \
    relaykit-provider-protocol-probe --pid "${APP_PID}" --window-identity "${first_identity}" \
    --provider-name "${PROVIDER_NAME}" --base-url "${base_url}" \
    --synthetic-key "${SYNTHETIC_KEY}" --model-id "${PROVIDER_MODEL}" || fail "exact AX provider protocol probe failed"
  jq -e '.providers == []' "${OUT}/providers.json" >/dev/null || fail "protocol probe changed provider config before Save"
  [[ "$(sha256 "${HOME}/.codex/config.toml")" == "${global_config_before}" ]] || fail "global Codex config changed"
  [[ "$(sha256 "${HOME}/.codex/auth.json")" == "${global_auth_before}" ]] || fail "global Codex auth changed"
  exit 0
fi
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
