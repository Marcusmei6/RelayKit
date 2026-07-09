#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_BUNDLE="${RELAYKIT_APP_BUNDLE:-${ROOT}/dist/RelayKitApp.app}"
APP_REAL="${APP_BUNDLE}/Contents/MacOS/RelayKitApp.bin"
BUNDLED_RELAY="${APP_BUNDLE}/Contents/MacOS/relay"
BUNDLE_ID="dev.relaykit.app"
APPEARANCE_KEY="appearanceMode"
PROVIDER_CONFIG_KEY="providerConfigPath"
OUT="${RELAYKIT_UI_SMOKE_OUT:-${ROOT}/dist/ui-smoke}"
CATALOG_PORT="18790"
CATALOG_URL="http://127.0.0.1:${CATALOG_PORT}/v1/models"
APP_SUPPORT_PROVIDER_CONFIG="${HOME}/Library/Application Support/RelayKit/providers.json"
CODEX_CONFIG_PATH="${HOME}/.codex/config.toml"
CODEX_AUTH_PATH="${HOME}/.codex/auth.json"
PID=""
FAKE_CATALOG_PID=""
ORIGINAL_CODEX_CONFIG_SIGNATURE=""
ORIGINAL_CODEX_AUTH_SIGNATURE=""
ORIGINAL_APPEARANCE=""
HAD_ORIGINAL_APPEARANCE=0
ORIGINAL_PROVIDER_CONFIG=""
HAD_ORIGINAL_PROVIDER_CONFIG=0
SMOKE_CONFIG_DIR=""
REAL_QUIT_MENU_EVIDENCE=""
ORIGINAL_OFFICIAL_LOGIN_PIDS=""
MANUAL_PROOF_SCRIPT="${ROOT}/scripts/codex-desktop-manual-proof.sh"
MANUAL_PROOF_EVIDENCE="${ROOT}/dist/codex-desktop-manual-proof/evidence.json"
MANUAL_PROOF_USAGE_PROOF="${ROOT}/dist/codex-desktop-manual-proof/usage-proof.json"
MANUAL_PROOF_EVIDENCE_BACKUP=""
MANUAL_PROOF_USAGE_PROOF_BACKUP=""
SMOKE_KEYCHAIN_SERVICE="relaykit.ui-smoke.provider.fixture"

is_relaykit_tmp_provider_config() {
  [[ "$1" == /tmp/relaykit-* || "$1" == /private/tmp/relaykit-* ]]
}

cleanup() {
  if [[ -n "${PID}" ]] && kill -0 "${PID}" 2>/dev/null; then
    kill "${PID}" >/dev/null 2>&1 || true
    wait "${PID}" >/dev/null 2>&1 || true
  fi
  pkill -x RelayKitApp.bin >/dev/null 2>&1 || true
  pkill -f "${APP_REAL}" >/dev/null 2>&1 || true
  pkill -f "${BUNDLED_RELAY}" >/dev/null 2>&1 || true
  for _ in {1..40}; do
    if ! pgrep -x RelayKitApp.bin >/dev/null 2>&1 &&
       ! pgrep -f "${APP_REAL}" >/dev/null 2>&1 &&
       ! pgrep -f "${BUNDLED_RELAY}" >/dev/null 2>&1; then
      break
    fi
    sleep 0.1
  done
}

restore_defaults() {
  if [[ "${HAD_ORIGINAL_APPEARANCE}" == "1" ]]; then
    /usr/bin/defaults write "${BUNDLE_ID}" "${APPEARANCE_KEY}" "${ORIGINAL_APPEARANCE}" >/dev/null 2>&1 || true
  else
    /usr/bin/defaults delete "${BUNDLE_ID}" "${APPEARANCE_KEY}" >/dev/null 2>&1 || true
  fi
  if [[ "${HAD_ORIGINAL_PROVIDER_CONFIG}" == "1" ]]; then
    /usr/bin/defaults write "${BUNDLE_ID}" "${PROVIDER_CONFIG_KEY}" "${ORIGINAL_PROVIDER_CONFIG}" >/dev/null 2>&1 || true
  else
    /usr/bin/defaults delete "${BUNDLE_ID}" "${PROVIDER_CONFIG_KEY}" >/dev/null 2>&1 || true
  fi
}

cleanup_smoke_config() {
  [[ -n "${SMOKE_CONFIG_DIR}" ]] && rm -rf "${SMOKE_CONFIG_DIR}" >/dev/null 2>&1 || true
}

cleanup_fake_catalog() {
  if [[ -n "${FAKE_CATALOG_PID}" ]] && kill -0 "${FAKE_CATALOG_PID}" 2>/dev/null; then
    kill "${FAKE_CATALOG_PID}" >/dev/null 2>&1 || true
    wait "${FAKE_CATALOG_PID}" >/dev/null 2>&1 || true
  fi
}

install_smoke_keychain_credential() {
  cleanup_smoke_keychain_credential
}

cleanup_smoke_keychain_credential() {
  while /usr/bin/security delete-generic-password -s "${SMOKE_KEYCHAIN_SERVICE}" -a RelayKit >/dev/null 2>&1; do
    :
  done
}

official_login_pids() {
  pgrep -f "/Applications/Codex.app/Contents/Resources/codex login --device-auth" || true
}

cleanup_official_login_processes() {
  local pid
  while IFS= read -r pid; do
    [[ -z "${pid}" ]] && continue
    if ! printf '%s\n' "${ORIGINAL_OFFICIAL_LOGIN_PIDS}" | grep -qx "${pid}"; then
      kill "${pid}" >/dev/null 2>&1 || true
    fi
  done < <(official_login_pids)
}

cleanup_manual_proof() {
  "${MANUAL_PROOF_SCRIPT}" cleanup >/dev/null 2>&1 || true
  pkill -f "open-proof-terminal.command" >/dev/null 2>&1 || true
}

backup_manual_proof_files() {
  [[ -n "${SMOKE_CONFIG_DIR}" ]] || return 0
  if [[ -f "${MANUAL_PROOF_EVIDENCE}" ]]; then
    MANUAL_PROOF_EVIDENCE_BACKUP="${SMOKE_CONFIG_DIR}/manual-proof-evidence.json"
    cp "${MANUAL_PROOF_EVIDENCE}" "${MANUAL_PROOF_EVIDENCE_BACKUP}"
  fi
  if [[ -f "${MANUAL_PROOF_USAGE_PROOF}" ]]; then
    MANUAL_PROOF_USAGE_PROOF_BACKUP="${SMOKE_CONFIG_DIR}/manual-proof-usage-proof.json"
    cp "${MANUAL_PROOF_USAGE_PROOF}" "${MANUAL_PROOF_USAGE_PROOF_BACKUP}"
  fi
}

restore_manual_proof_files() {
  if [[ -n "${MANUAL_PROOF_EVIDENCE_BACKUP}" && -f "${MANUAL_PROOF_EVIDENCE_BACKUP}" ]]; then
    mkdir -p "$(dirname "${MANUAL_PROOF_EVIDENCE}")"
    cp "${MANUAL_PROOF_EVIDENCE_BACKUP}" "${MANUAL_PROOF_EVIDENCE}"
  fi
  if [[ -n "${MANUAL_PROOF_USAGE_PROOF_BACKUP}" && -f "${MANUAL_PROOF_USAGE_PROOF_BACKUP}" ]]; then
    mkdir -p "$(dirname "${MANUAL_PROOF_USAGE_PROOF}")"
    cp "${MANUAL_PROOF_USAGE_PROOF_BACKUP}" "${MANUAL_PROOF_USAGE_PROOF}"
  fi
}

trap 'restore_defaults; cleanup; cleanup_official_login_processes; cleanup_fake_catalog; cleanup_smoke_keychain_credential; restore_manual_proof_files; cleanup_smoke_config; cleanup_manual_proof' EXIT

file_signature() {
  local path="$1"
  if [[ -e "${path}" ]]; then
    shasum -a 256 "${path}" | awk '{print $1}'
  else
    printf 'missing'
  fi
}

assert_shared_codex_files_unchanged() {
  if [[ "$(file_signature "${CODEX_CONFIG_PATH}")" != "${ORIGINAL_CODEX_CONFIG_SIGNATURE}" ]]; then
    echo "UI smoke changed real ${CODEX_CONFIG_PATH}" >&2
    exit 1
  fi
  if [[ "$(file_signature "${CODEX_AUTH_PATH}")" != "${ORIGINAL_CODEX_AUTH_SIGNATURE}" ]]; then
    echo "UI smoke changed real ${CODEX_AUTH_PATH}" >&2
    exit 1
  fi
}

click_point() {
  swift - "$1" "$2" >/tmp/relaykit-ui-smoke-click.log 2>&1 <<'SWIFT'
import CoreGraphics
import Foundation

let args = CommandLine.arguments
guard args.count == 3,
      let x = Double(args[1]),
      let y = Double(args[2]) else {
    exit(2)
}
let point = CGPoint(x: x, y: y)
let source = CGEventSource(stateID: .hidSystemState)
CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
usleep(80_000)
CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
usleep(80_000)
CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
SWIFT
}

press_ax_label() {
  local label="$1"
  local pid="${2:-${PID}}"
  swift - "${pid}" "${label}" >/tmp/relaykit-ui-smoke-ax.log 2>&1 <<'SWIFT'
import ApplicationServices
import Foundation

let args = CommandLine.arguments
guard args.count == 3, let pid = pid_t(args[1]) else { exit(2) }
let needle = args[2].lowercased()
let app = AXUIElementCreateApplication(pid)

func text(_ element: AXUIElement, _ attribute: String) -> String {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
          let value else { return "" }
    return String(describing: value)
}

func press(_ element: AXUIElement) -> Bool {
    var actionsRef: CFArray?
    if AXUIElementCopyActionNames(element, &actionsRef) == .success,
       let actions = actionsRef as? [String],
       actions.contains(kAXPressAction) {
        return AXUIElementPerformAction(element, kAXPressAction as CFString) == .success
    }
    var parent: CFTypeRef?
    if AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &parent) == .success,
       let parent {
        return press(parent as! AXUIElement)
    }
    return false
}

func walk(_ element: AXUIElement, _ depth: Int = 0) -> Bool {
    if depth > 12 { return false }
    let haystack = [
        text(element, kAXTitleAttribute),
        text(element, kAXDescriptionAttribute),
        text(element, kAXValueAttribute),
        text(element, "AXIdentifier")
    ].joined(separator: " ").lowercased()
    if haystack.contains(needle), press(element) {
        return true
    }
    var children: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success,
          let elements = children as? [AXUIElement] else {
        return false
    }
    for child in elements {
        if walk(child, depth + 1) { return true }
    }
    return false
}

exit(walk(app) ? 0 : 1)
SWIFT
}

assert_ax_label_disabled() {
  local label="$1"
  local pid="${2:-${PID}}"
  swift - "${pid}" "${label}" >/tmp/relaykit-ui-smoke-ax-disabled.log 2>&1 <<'SWIFT'
import ApplicationServices
import Foundation

let args = CommandLine.arguments
guard args.count == 3, let pid = pid_t(args[1]) else { exit(2) }
let needle = args[2].lowercased()
let app = AXUIElementCreateApplication(pid)

func attr(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
    return value
}

func text(_ element: AXUIElement, _ attribute: String) -> String {
    guard let value = attr(element, attribute) else { return "" }
    return String(describing: value)
}

func enabled(_ element: AXUIElement) -> Bool? {
    attr(element, kAXEnabledAttribute as String) as? Bool
}

func canPress(_ element: AXUIElement) -> Bool {
    var actionsRef: CFArray?
    guard AXUIElementCopyActionNames(element, &actionsRef) == .success,
          let actions = actionsRef as? [String] else { return false }
    return actions.contains(kAXPressAction)
}

func buttonAncestor(_ element: AXUIElement) -> AXUIElement {
    var current = element
    for _ in 0..<6 {
        if text(current, kAXRoleAttribute).lowercased().contains("button") {
            return current
        }
        guard let parent = attr(current, kAXParentAttribute as String) else { return current }
        current = parent as! AXUIElement
    }
    return current
}

func walk(_ element: AXUIElement, _ depth: Int = 0) -> Int32? {
    if depth > 12 { return nil }
    let haystack = [
        text(element, kAXTitleAttribute),
        text(element, kAXDescriptionAttribute),
        text(element, kAXValueAttribute),
        text(element, "AXIdentifier")
    ].joined(separator: " ").lowercased()
    if haystack.contains(needle) {
        let button = buttonAncestor(element)
        if enabled(button) == false { return 0 }
        if !canPress(button) { return 0 }
        return 1
    }
    guard let children = attr(element, kAXChildrenAttribute) as? [AXUIElement] else { return nil }
    for child in children {
        if let result = walk(child, depth + 1) { return result }
    }
    return nil
}

exit(walk(app) ?? 2)
SWIFT
}

focus_ax_label() {
  local label="$1"
  local pid="${2:-${PID}}"
  swift - "${pid}" "${label}" >/tmp/relaykit-ui-smoke-ax-focus.log 2>&1 <<'SWIFT'
import ApplicationServices
import Foundation

let args = CommandLine.arguments
guard args.count == 3, let pid = pid_t(args[1]) else { exit(2) }
let needle = args[2].lowercased()
let app = AXUIElementCreateApplication(pid)

func text(_ element: AXUIElement, _ attribute: String) -> String {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
          let value else { return "" }
    return String(describing: value)
}

func walk(_ element: AXUIElement, _ depth: Int = 0) -> Bool {
    if depth > 12 { return false }
    let haystack = [
        text(element, kAXTitleAttribute),
        text(element, kAXDescriptionAttribute),
        text(element, kAXValueAttribute),
        text(element, "AXIdentifier")
    ].joined(separator: " ").lowercased()
    if haystack.contains(needle) {
        return AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success
    }
    var children: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success,
          let elements = children as? [AXUIElement] else {
        return false
    }
    for child in elements {
        if walk(child, depth + 1) { return true }
    }
    return false
}

exit(walk(app) ? 0 : 1)
SWIFT
}

type_text() {
  local text="$1"
  local pid="${2:-${PID}}"
  /usr/bin/osascript - "${pid}" "${text}" >/tmp/relaykit-ui-smoke-type.log 2>&1 <<'APPLESCRIPT'
on run argv
  tell application "System Events"
    set frontmost of (first process whose unix id is (item 1 of argv as integer)) to true
    keystroke (item 2 of argv)
  end tell
end run
APPLESCRIPT
}

replace_focused_text() {
  local text="$1"
  local pid="${2:-${PID}}"
  /usr/bin/osascript - "${pid}" "${text}" >/tmp/relaykit-ui-smoke-replace-text.log 2>&1 <<'APPLESCRIPT'
on run argv
  tell application "System Events"
    set frontmost of (first process whose unix id is (item 1 of argv as integer)) to true
    keystroke "a" using command down
    keystroke (item 2 of argv)
  end tell
end run
APPLESCRIPT
}

wait_for_jq() {
  local evidence="$1"
  local expression="$2"
  for _ in {1..60}; do
    if jq -e "${expression}" "${evidence}" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.2
  done
  jq -e "${expression}" "${evidence}" >/dev/null
}

wait_for_manual_proof_jq() {
  local expression="$1"
  for _ in {1..90}; do
    if jq -e "${expression}" "${MANUAL_PROOF_EVIDENCE}" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.5
  done
  jq -e "${expression}" "${MANUAL_PROOF_EVIDENCE}" >/dev/null
}

capture() {
  local name="$1"
  shift
  local evidence="${OUT}/${name}.json"
  cleanup
  /usr/bin/open -n "${APP_BUNDLE}" --args --ui-smoke --ui-smoke-keep-open --ui-smoke-evidence "${evidence}" --ui-smoke-catalog-url "${CATALOG_URL}" --ui-smoke-seed-keychain "${SMOKE_KEYCHAIN_SERVICE}" "$@" >/tmp/relaykit-ui-smoke.log 2>&1
  sleep 3
  PID="$(pgrep -x RelayKitApp.bin | sort -n | tail -1 || true)"
  if [[ -z "${PID}" ]] || ! kill -0 "${PID}" 2>/dev/null; then
    cat /tmp/relaykit-ui-smoke.log >&2
    exit 1
  fi
  for _ in {1..120}; do
    [[ -s "${evidence}" ]] && break
    sleep 0.25
  done
  test -s "${evidence}"
  case "${name}" in
    connect|official-sheet|official-light|official-dark|provider-click-flow|provider-light|provider-dark|real-demo) required='["tab-connect","cli-route","local-cli-scan","cli-selected-state","codex-target-state","claude-disabled-placeholder","configured-providers","import-candidates","status-summary-inline","model-access-merged","official-provider-row","add-strip","auth-blocked-state"]' ;;
    detail|detail-advanced-expanded|detail-advanced-collapsed|provider-test-failure) required='["tab-connect","cli-route","local-cli-scan","cli-selected-state","codex-target-state","claude-disabled-placeholder","configured-providers","import-candidates","provider-edit-modal","configured-provider-row-action","add-strip","auth-blocked-state","provider-codex-route-chip","provider-upstream-protocol-chip","provider-connection-test-entry"]' ;;
    import) required='["tab-connect","cli-route","local-cli-scan","cli-selected-state","codex-target-state","claude-disabled-placeholder","configured-providers","import-candidates","provider-import-modal","provider-import-mode","provider-import-prefilled-fields","provider-model-table","discovered-row-action","add-strip","auth-blocked-state"]' ;;
    usage|usage-light|usage-dark|usage-auto-refresh|usage-large|usage-1m|usage-1y) required='["tab-usage","usage-kpis","usage-provider-groups","usage-model-rollups","usage-activity-heatmap","usage-activity-range-control","usage-cost-unavailable","usage-auto-refresh-enabled","usage-activity-unit-label","usage-top-model-readable"]' ;;
    usage-empty) required='["tab-usage","usage-kpis","usage-provider-groups","usage-model-rollups","usage-activity-heatmap","usage-activity-range-control","usage-cost-unavailable","usage-empty-state"]' ;;
    settings|settings-light|settings-dark|settings-developer-expanded) required='["tab-settings","appearance-control","launch-login-control","settings-general-group","settings-gateway-group","settings-codex-group","settings-data-privacy-group","settings-developer-group","settings-developer-collapsed","settings-actions","advanced-paths"]' ;;
    provider) required='["add-strip","add-strip-action","tab-provider","provider-modal","provider-add-mode","provider-name-field","provider-base-url-field","provider-api-key-field","provider-connection-test-entry","provider-model-detection-entry","provider-model-table","provider-model-row","provider-model-id-main-field","provider-advanced-options"]' ;;
    *) required='[]' ;;
  esac
  jq -e --argjson required "${required}" '
    . as $doc |
    $doc.status_item.visible == true and
    $doc.status_item.width > 0 and
    $doc.popover.shown == true and
    $doc.popover.ordinary_window == false and
    $doc.surface.kind == "menu-bar-popover" and
    ($doc.settings.appearance_mode | test("^(system|light|dark)$")) and
    ($doc.settings.launch_at_login_requested | type == "boolean") and
    ($doc.settings.launch_at_login_status | type == "string") and
    ($doc.connect.model_ids_redacted == true) and
    ($doc.connect.source_names_redacted == true) and
    ($doc.connect.demo_model_rows_present == false) and
    ($doc.surface.sections | index("global-status")) and
    (all($required[]; . as $section | ($doc.surface.sections | index($section))))
  ' "${evidence}" >/dev/null
  if [[ "${name}" == "connect" ]]; then
    jq -e '
      . as $doc |
      $doc.connect.provider_config_path_is_app_support == false and
      $doc.connect.stale_tmp_provider_config_recovered == false and
      (all($doc.connect.configured_provider_labels[]; test("Fixture Provider|Saved Key Provider") | not)) and
      $doc.connect.status_summary_inline == true and
      $doc.connect.model_access_and_model_list_merged == true and
      $doc.connect.duplicate_empty_state == false and
      $doc.connect.official_provider_row_visible == true and
      $doc.connect.official_provider_row_managed_by_relaykit == true and
      $doc.connect.header_models_match_unified_models == true and
      ($doc.connect.configured_provider_labels | length) == $doc.connect.configured_provider_count and
      $doc.connect.discovered_catalog_model_count == 3 and
      $doc.connect.discovered_catalog_source_group_count > 0 and
      $doc.connect.display_mode == "model-access" and
      $doc.connect.unified_model_count >= $doc.connect.unified_model_catalog_count and
      $doc.connect.unified_model_configured_count == ($doc.connect.configured_provider_model_labels | length) and
      $doc.connect.unified_model_catalog_count == 3 and
      $doc.connect.unified_model_has_official_and_provider_catalog_fixture == true and
      $doc.connect.unified_model_has_demo_fixture == true and
      $doc.connect.status_under_codex_card == false and
      $doc.connect.top_level_relaykit_status_visible == false and
      $doc.connect.catalog_url_uses_shared_18787 == false and
      ($doc.connect.desktop_acceptance_global_files | type == "string") and
      ($doc.connect.desktop_acceptance_catalog | test("^catalog ok: [0-9]+ models$")) and
      ($doc.connect.desktop_acceptance_picker_data | test("^picker data has [0-9]+ routed models$")) and
      ($doc.connect.desktop_acceptance_route_proof | test("blocked|routed model|routed_model|ready|usage|not run|succeeded|missing")) and
      ($doc.connect.desktop_acceptance_manual_available | type == "boolean") and
      $doc.connect.desktop_acceptance_manual_entry_visible == false and
      ($doc.connect.desktop_acceptance_manual_status | type == "string") and
      ($doc.connect.desktop_acceptance_manual_route_status | type == "string") and
      ($doc.connect.desktop_acceptance_proof_root | endswith("Library/Application Support/RelayKit/DesktopProof")) and
      ($doc.connect.desktop_acceptance_start_command | contains("./scripts/codex-desktop-manual-proof.sh")) and
      ($doc.connect.discovered_row_labels | length) == $doc.connect.discovered_catalog_source_group_count and
      (all($doc.connect.discovered_row_labels[]; test("^source-[0-9]+$"))) and
      ($doc.connect.auth_state | test("auth required|credential reference needed")) and
      $doc.connect.add_strip_available == true and
      $doc.connect.cli_selected == "codex" and
      $doc.connect.gateway_control_exercise.start_invoked == true and
      $doc.connect.gateway_control_exercise.start_process_id > 0 and
      $doc.connect.gateway_control_exercise.start_process_running == true and
      $doc.connect.gateway_control_exercise.health_status == "ok" and
      $doc.connect.gateway_control_exercise.gateway_model_count > 0 and
      $doc.connect.gateway_control_exercise.restart_process_id > 0 and
      $doc.connect.gateway_control_exercise.restart_process_running == true and
      $doc.connect.gateway_control_exercise.restart_health_status == "ok" and
      $doc.connect.gateway_control_exercise.stop_status == "stopped" and
      $doc.connect.gateway_control_exercise.post_stop_health_status == "stopped"
    ' "${evidence}" >/dev/null
  fi
  if [[ "${name}" == "official-sheet" || "${name}" == "official-light" || "${name}" == "official-dark" ]]; then
    manual_proof_signature_before="$(file_signature "${MANUAL_PROOF_EVIDENCE}")"
    press_ax_label "OpenAI Official"
    wait_for_jq "${evidence}" '.connect.official_sheet_opened == true'
    press_ax_label "Check status"
    wait_for_jq "${evidence}" '
      .connect.official_current_status == "not connected" or
      .connect.official_current_status == "login available" or
      .connect.official_current_status == "route verified"
    '
    jq -e '
      .connect.official_current_status as $status |
      .connect.official_provider_row_actionable == true and
      .connect.official_sheet_opened == true and
      .connect.official_auth_cta_visible == true and
      .connect.official_auth_cta_has_real_action == true and
      .connect.official_auth_cta_disabled_as_unimplemented == false and
      .connect.official_auth_unimplemented_visible == false and
      .connect.official_auth_cta_clicked == false and
      ($status == "not connected" or $status == "login available" or $status == "route verified") and
      .connect.official_connected_by_login_status == ($status != "not connected") and
      .connect.official_route_verified_status == ($status == "route verified") and
      .connect.official_not_connected_status_visible == ($status == "not connected") and
      (.connect.official_device_login_pending_status_visible | type == "boolean") and
      (.connect.official_login_available_status_visible | type == "boolean") and
      (.connect.official_route_verified_status_visible | type == "boolean") and
      .connect.official_state_details_collapsed == true and
      .connect.official_state_details_expanded == false and
      .connect.official_device_url_captured == false and
      .connect.official_device_code_captured == false and
      .connect.official_product_actions_visible == true and
      .connect.official_authenticate_action_visible == true and
      .connect.official_status_refresh_action_visible == true and
      .connect.official_reauth_action_visible == false and
      .connect.official_disconnect_action_visible == true and
      .connect.official_isolated_desktop_entry_visible == false and
      .connect.official_token_boundary_visible == true and
      .connect.official_debug_status_visible == false and
      .connect.official_debug_actions_visible == false and
      .connect.official_mock_passthrough_status_visible == false and
      .connect.official_login_required_status_visible == false and
      .connect.official_real_auth_not_verified_visible == false and
      .connect.official_open_codex_desktop_action_visible == false and
      .connect.official_run_isolated_check_action_visible == false and
      .connect.official_copy_command_action_visible == false and
      .connect.official_run_isolated_check_clicked == false and
      .connect.official_open_signin_link_clicked == false
    ' "${evidence}" >/dev/null
    /usr/sbin/screencapture -x "${OUT}/official-cta-before.png"
    test -s "${OUT}/official-cta-before.png"
    /usr/sbin/screencapture -x "${OUT}/official-cta-after.png"
    test -s "${OUT}/official-cta-after.png"
    official_status="$(jq -r '.connect.official_current_status // ""' "${evidence}")"
    if [[ "${official_status}" == "not connected" ]]; then
      press_ax_label "Connect Official"
      wait_for_jq "${evidence}" '
        .connect.official_auth_cta_clicked == true and
        .connect.official_auth_in_progress == true and
        .connect.official_auth_process_id_present == true and
        .connect.official_current_status == "device login pending" and
        .connect.official_connected_by_login_status == false and
        .connect.official_route_verified_status == false and
        .connect.official_device_url_captured == true and
        .connect.official_device_code_captured == true and
        .connect.official_credential_ref_exists == true and
        .connect.official_device_login_visible == true and
        .connect.official_copy_device_code_action_visible == true and
        .connect.official_open_signin_link_action_visible == true and
        .connect.official_open_signin_link_clicked == false
      '
      press_ax_label "Copy code"
      wait_for_jq "${evidence}" '.connect.official_device_code_copied == true and .connect.official_copy_device_code_clicked == true'
      pbpaste | grep -Eq '^[A-Z0-9]{4}-[A-Z0-9]{4,6}$'
    else
      jq -e '
        (.connect.official_current_status == "login available" or .connect.official_current_status == "route verified") and
        .connect.official_connected_by_login_status == true and
        .connect.official_connected_cta_disabled == true and
        .connect.official_connected_device_code_hidden == true and
        .connect.official_connected_click_does_not_start_login == true and
        .connect.official_device_url_captured == false and
        .connect.official_device_code_captured == false and
        .connect.official_auth_cta_clicked == false and
        .connect.official_auth_in_progress == false
      ' "${evidence}" >/dev/null
    fi
    if [[ "$(file_signature "${MANUAL_PROOF_EVIDENCE}")" != "${manual_proof_signature_before}" ]]; then
      echo "Official product sheet unexpectedly touched manual proof evidence" >&2
      exit 1
    fi
  fi
  if [[ "${name}" == "real-demo" ]]; then
    wait_for_jq "${evidence}" '.connect.real_demo_provider_clicked == true and .connect.real_demo_models_visible == true'
    jq -e '
      .connect.provider_config_path_is_app_support == false and
      .connect.real_demo_provider_clicked == true and
      .connect.real_demo_provider_config_path == true and
      .connect.real_demo_base_url_visible == true and
      .connect.real_demo_key_saved_visible == true and
      .connect.real_demo_models_visible == true and
      .connect.saved_key_fake_eye_visible == false
    ' "${evidence}" >/dev/null
    /usr/sbin/screencapture -x "${OUT}/real-user-demo-provider.png"
    test -s "${OUT}/real-user-demo-provider.png"
  fi
  if [[ "${name}" == "provider-click-flow" || "${name}" == "provider-light" || "${name}" == "provider-dark" ]]; then
    if ! jq -e '.connect.provider_edit_opened == true' "${evidence}" >/dev/null; then
      press_ax_label "provider-fixture-provider"
    fi
    wait_for_jq "${evidence}" '.connect.provider_edit_opened == true and .connect.api_key_masked_field_visible == true'
    wait_for_jq "${evidence}" '
      .connect.provider_health_summary_visible == true and
      .connect.provider_health_saved_count == 2 and
      .connect.provider_health_available_count == 1 and
      .connect.provider_health_hidden_count == 1 and
      .connect.provider_hidden_models_toggle_visible == true
    '
    press_ax_label "Hidden models"
    wait_for_jq "${evidence}" '.connect.provider_hidden_model_reasons_visible == true'
    jq -e '
      .connect.provider_edit_opened == true and
      .connect.provider_edit_row_action_invoked == true and
      .connect.provider_edit_base_url_prefilled == true and
      .connect.provider_edit_models_loaded == true and
      .connect.provider_health_summary_visible == true and
      .connect.provider_health_saved_count == 2 and
      .connect.provider_health_available_count == 1 and
      .connect.provider_health_hidden_count == 1 and
      .connect.provider_model_reachable_row_visible == true and
      .connect.provider_model_unavailable_row_visible == true and
      .connect.provider_hidden_models_toggle_visible == true and
      .connect.provider_hidden_model_reasons_visible == true and
      .connect.api_key_saved_state_visible == true and
      .connect.api_key_masked_field_visible == true and
      .connect.api_key_saved_mask_control_visible == true and
      .connect.api_key_saved_eye_visible == true and
      .connect.saved_key_fake_eye_visible == false and
      .connect.saved_key_disabled_eye_reason_visible == false and
      .connect.api_key_replace_visible == false and
      .connect.api_key_replace_available == false and
      .connect.provider_form_test_connection_visible == true and
      .connect.saved_key_plaintext_hidden == true
    ' "${evidence}" >/dev/null
    /usr/sbin/screencapture -x "${OUT}/provider-key-saved.png"
    test -s "${OUT}/provider-key-saved.png"
    press_ax_label "Show API key"
    wait_for_jq "${evidence}" '.connect.saved_key_eye_toggle_works == true'
    press_ax_label "Hide API key"
    wait_for_jq "${evidence}" '.connect.api_key_saved_mask_control_visible == true'
    focus_ax_label "API key field"
    replace_focused_text "relaykit-ui-smoke-key"
    wait_for_jq "${evidence}" '.connect.api_key_saved_mask_control_visible == true'
    press_ax_label "provider-connection-test-entry"
    wait_for_jq "${evidence}" '.connect.provider_connection_connected_visible == true'
    jq -e '
      .connect.provider_connection_connected_visible == true and
      .connect.provider_connection_network_failed_visible == false and
      .connect.provider_connection_counts_separated == true and
      .connect.provider_connection_use_reachable_visible == true
    ' "${evidence}" >/dev/null
    /usr/sbin/screencapture -x "${OUT}/provider-test-success.png"
    test -s "${OUT}/provider-test-success.png"
    if [[ "${name}" == "provider-click-flow" ]]; then
      press_ax_label "provider-connection-use-reachable-visible"
      wait_for_jq "${evidence}" '.connect.provider_connection_used_reachable_models_only == true'
      /usr/sbin/screencapture -x "${OUT}/provider-use-reachable.png"
      test -s "${OUT}/provider-use-reachable.png"
    fi
    press_ax_label Advanced
    wait_for_jq "${evidence}" '.connect.advanced_has_protocol_selector == true and .connect.advanced_has_custom_models_url == true'
    jq -e '
      .connect.advanced_scrollable_when_expanded == true and
      .connect.advanced_toggle_row_visible == true and
      .connect.advanced_has_protocol_selector == true and
      .connect.advanced_has_custom_models_url == true and
      .connect.advanced_has_custom_auth_header == true and
      .connect.advanced_has_upstream_model_override == true and
      .connect.advanced_raw_fields_hidden == true and
      .connect.ordinary_advanced_labels == ["Upstream protocol","Custom models URL","Custom auth header","Upstream model override"] and
      .connect.enabled_gateway_provider_protocols == ["anthropic_messages","openai_chat"] and
      .connect.planned_provider_protocols == ["OpenAI Responses (planned)"]
    ' "${evidence}" >/dev/null
    /usr/sbin/screencapture -x "${OUT}/provider-advanced-simplified.png"
    test -s "${OUT}/provider-advanced-simplified.png"
    if [[ "${name}" != "provider-click-flow" ]]; then
      press_ax_label "保存"
      sleep 0.8
    fi
  fi
  if [[ "${name}" == "provider-test-failure" ]]; then
    if ! jq -e '.connect.provider_edit_opened == true' "${evidence}" >/dev/null; then
      press_ax_label "provider-failure-provider"
    fi
    wait_for_jq "${evidence}" '.connect.provider_edit_opened == true and .connect.provider_form_test_connection_visible == true'
    press_ax_label "provider-connection-test-entry"
    wait_for_jq "${evidence}" '.connect.provider_connection_network_failed_visible == true'
    jq -e '
      .connect.provider_connection_network_failed_visible == true and
      .connect.provider_connection_reachable_visible == false and
      .connect.provider_connection_connected_visible == false
    ' "${evidence}" >/dev/null
    /usr/sbin/screencapture -x "${OUT}/provider-test-failure.png"
    test -s "${OUT}/provider-test-failure.png"
  fi
  if [[ "${name}" == detail* ]]; then
    jq -e '
      .connect.configured_provider_count == 1 and
      .connect.provider_edit_opened == true and
      .connect.provider_edit_row_action_invoked == true and
      .connect.provider_edit_has_save == true and
      .connect.provider_edit_has_add_cta == false and
      .connect.provider_edit_base_url_prefilled == true and
      .connect.provider_edit_models_loaded == true and
      .connect.provider_health_summary_visible == true and
      .connect.api_key_saved_state_visible == true and
      .connect.protocol_tag_distinguishes_codex_route_and_upstream == true and
      .connect.saved_key_plaintext_hidden == true and
      .connect.saved_key_state_visible == true and
      .connect.model_ids_redacted == true and
      .connect.source_names_redacted == true
    ' "${evidence}" >/dev/null
  fi
  if [[ "${name}" == "detail-advanced-expanded" ]]; then
    press_ax_label Advanced
    wait_for_jq "${evidence}" '.connect.advanced_scrollable_when_expanded == true'
    jq -e '.connect.advanced_scrollable_when_expanded == true' "${evidence}" >/dev/null
  fi
  if [[ "${name}" == "detail-advanced-collapsed" ]]; then
    press_ax_label Advanced
    wait_for_jq "${evidence}" '.connect.advanced_scrollable_when_expanded == true'
    press_ax_label Advanced
    wait_for_jq "${evidence}" '.connect.advanced_can_collapse_after_expand == true'
    jq -e '.connect.advanced_can_collapse_after_expand == true' "${evidence}" >/dev/null
  fi
  if [[ "${name}" == "import" ]]; then
    jq -e '
      .connect.configured_provider_count == 0 and
      .connect.import_mode_opened == true and
      .connect.import_row_action_invoked == true and
      .connect.import_has_prefilled_fields == true and
      .connect.import_has_multiple_model_rows == true and
      .connect.import_model_list_bounded == true and
      .connect.import_selected_model_count > 1 and
      .connect.import_uses_first_model_only == false and
      .connect.import_bridge_host_detected == true and
      .connect.import_execution_base_url_prefilled == true and
      .connect.import_protocol_checked == true and
      (.connect.import_has_missing_required_fields | type == "boolean") and
      .connect.redacted_only_detail_opened == false and
      .connect.model_ids_redacted == true and
      .connect.source_names_redacted == true
    ' "${evidence}" >/dev/null
    if grep -Eq 'Source redacted|Model IDs redacted|not configured|reference only' "${evidence}"; then
      echo "import smoke regressed to redacted-only reference detail" >&2
      exit 1
    fi
  fi
  if [[ "${name}" == "usage-auto-refresh" ]]; then
    wait_for_jq "${evidence}" '.usage.today_tokens == 100 and .usage.refresh_count >= 1'
    python3 - "${USAGE_LOG_AUTO}" <<'PY'
import datetime
import json
import sys

today = datetime.datetime.utcnow().date().isoformat() + "T12:01:00Z"
with open(sys.argv[1], "a", encoding="utf-8") as f:
    f.write(json.dumps({
        "timestamp": today,
        "request_id": "ui-smoke-auto-appended",
        "provider_id": "demo",
        "model": "demo/claude-sonnet-4-6",
        "route": "/v1/responses",
        "transport": "responses_http",
        "status": "completed",
        "http_status": 200,
        "input_tokens": 100,
        "output_tokens": 150,
        "total_tokens": 250,
        "duration_ms": 120,
    }, separators=(",", ":")) + "\n")
PY
    wait_for_jq "${evidence}" '.usage.today_tokens == 350 and .usage.seven_day_tokens == 350 and .usage.all_time_tokens == 350 and .usage.requests == 2 and .usage.top_model_7d == "demo/claude-sonnet-4-6" and .usage.refresh_count >= 2'
  fi
  if [[ "${name}" == "usage-1m" ]]; then
    press_ax_label "1M"
    sleep 0.5
  fi
  if [[ "${name}" == "usage-1y" ]]; then
    press_ax_label "1Y"
    sleep 0.5
  fi
  if [[ "${name}" == "usage" || "${name}" == "usage-light" || "${name}" == "usage-dark" || "${name}" == "usage-1m" || "${name}" == "usage-1y" ]]; then
    jq -e '
      .usage.has_rows == true and
      .usage.empty_state_visible == false and
      .usage.auto_refresh_enabled == true and
      .usage.summary_background == true and
      .usage.token_unit_formatting == true and
      .usage.today_tokens == 150 and
      .usage.today_tokens_label == "150" and
      .usage.seven_day_tokens == 750 and
      .usage.all_time_tokens == 775 and
      .usage.requests == 7 and
      .usage.top_model_7d == "demo/claude-sonnet-4-6" and
      .usage.top_model_7d_readable == "claude-sonnet-4-6" and
      .usage.top_model_readable_visible == true and
      .usage.active_days == 4 and
      .usage.provider_group_names == ["Official Codex / OpenAI","Third-party providers"] and
      .usage.provider_source_shifted == true and
      .usage.model_count == 4 and
      .usage.activity_bucket_count_7d == 14 and
      .usage.activity_active_days_7d == 3 and
      .usage.activity_unit_labels == ["7D · half-day","1M · daily","1Y · weekly"] and
      .usage.activity_heatmap_visible == true and
      .usage.activity_range_control_visible == true and
      .usage.activity_unit_label_visible == true and
      .usage.cost_unavailable_visible == true
    ' "${evidence}" >/dev/null
  fi
  if [[ "${name}" == "usage-large" ]]; then
    jq -e '
      .usage.has_rows == true and
      .usage.requests == 1800 and
      .usage.auto_refresh_enabled == true and
      .usage.summary_background == true and
      .usage.last_refresh_duration_ms < 5000 and
      .usage.activity_heatmap_visible == true
    ' "${evidence}" >/dev/null
  fi
  if [[ "${name}" == "usage-empty" ]]; then
    jq -e '
      .usage.has_rows == false and
      .usage.empty_state_visible == true and
      .usage.today_tokens == 0 and
      .usage.seven_day_tokens == 0 and
      .usage.all_time_tokens == 0 and
      .usage.requests == 0 and
      .usage.top_model_7d == "" and
      .usage.active_days == 0 and
      .usage.provider_group_names == [] and
      .usage.model_count == 0 and
      .usage.activity_bucket_count_7d == 14 and
      .usage.activity_active_days_7d == 0 and
      .usage.activity_unit_labels == ["7D · half-day","1M · daily","1Y · weekly"] and
      .usage.activity_heatmap_visible == true and
      .usage.activity_range_control_visible == true and
      .usage.activity_unit_label_visible == true and
      .usage.cost_unavailable_visible == true
    ' "${evidence}" >/dev/null
  fi
  if [[ "${name}" == settings* ]]; then
    jq -e '
      .settings.general_group_visible == true and
      .settings.gateway_group_visible == true and
      .settings.codex_group_visible == true and
      .settings.data_privacy_group_visible == true and
      .settings.developer_collapsed == true and
      .settings.gateway_port == "127.0.0.1:19777" and
      .settings.global_codex_activate_visible == false and
      .settings.manual_proof_hidden_when_collapsed == true
    ' "${evidence}" >/dev/null
  fi
  if [[ "${name}" == "settings-developer-expanded" ]]; then
    press_ax_label "Developer / Diagnostics"
    wait_for_jq "${evidence}" '.settings.developer_expanded == true and .settings.manual_proof_visible_when_expanded == true'
  fi
  if [[ "${name}" == "provider" ]]; then
    jq -e '
      .connect.add_strip_opens_provider_modal == true and
      .connect.add_form_has_save == true and
      .connect.add_form_has_gateway_port_control == false and
      .connect.provider_form_user_main_flow == true and
      .connect.provider_model_main_field_count == 1 and
      .connect.provider_display_name_visible_on_main == false and
      .connect.provider_upstream_model_visible_on_main == false and
      .connect.api_key_input_visible == true and
      .connect.provider_form_raw_protocol_visible == false and
      .connect.provider_form_credential_mode_visible == false and
      .connect.provider_form_keychain_ref_visible_on_main == false and
      .connect.provider_form_catalog_url_visible_on_main == false and
      .connect.provider_form_model_mapping_visible_on_main == false and
      .connect.provider_form_use_models_visible == false and
      .connect.provider_form_test_connection_visible == true and
      .connect.api_key_new_eye_visible == true and
      .connect.provider_form_detect_models_visible == true and
      .connect.provider_form_model_table_visible == true and
      .connect.protocol_tag_distinguishes_codex_route_and_upstream == true and
      .connect.advanced_default_collapsed == true
    ' "${evidence}" >/dev/null
  fi
  /usr/sbin/screencapture -x "${OUT}/${name}.png"
  test -s "${OUT}/${name}.png"
  kill "${PID}" >/dev/null 2>&1 || true
  wait "${PID}" >/dev/null 2>&1 || true
  PID=""
  cleanup
}

capture_real_quit_menu() {
  local evidence="${OUT}/real-quit-menu.json"
  cleanup
  restore_defaults
  /usr/bin/open -n "${APP_BUNDLE}" >/tmp/relaykit-real-quit.log 2>&1
  sleep 1
  PID="$(pgrep -x RelayKitApp.bin | head -1 || true)"
  if [[ -z "${PID}" ]] || ! kill -0 "${PID}" 2>/dev/null; then
    cat /tmp/relaykit-real-quit.log >&2 || true
    exit 1
  fi
  local coords x y width height
  coords="$(/usr/bin/osascript <<'APPLESCRIPT'
tell application "System Events"
  tell process "RelayKitApp.bin"
    repeat 50 times
      try
        set itemPosition to position of menu bar item 1 of menu bar 1
        set itemSize to size of menu bar item 1 of menu bar 1
        if itemPosition is not missing value and itemSize is not missing value then
          set itemX to item 1 of itemPosition as integer
          set itemY to item 2 of itemPosition as integer
          set itemWidth to item 1 of itemSize as integer
          set itemHeight to item 2 of itemSize as integer
          if itemWidth > 0 and itemHeight > 0 then
            return (itemX as text) & "|" & (itemY as text) & "|" & (itemWidth as text) & "|" & (itemHeight as text)
          end if
        end if
      end try
      delay 0.1
    end repeat
    error "RelayKit menu bar item coordinates were not available"
  end tell
end tell
APPLESCRIPT
)"
  IFS='|' read -r x y width height <<<"${coords}"
  swift - "${x}" "${y}" "${width}" "${height}" >/tmp/relaykit-real-quit-menu.log 2>&1 <<'SWIFT'
import CoreGraphics
import Foundation

let args = CommandLine.arguments
guard args.count == 5,
      let x = Double(args[1]),
      let y = Double(args[2]),
      let width = Double(args[3]),
      let height = Double(args[4]) else {
    exit(2)
}
let point = CGPoint(x: x + width / 2.0, y: y + height / 2.0)
let source = CGEventSource(stateID: .hidSystemState)
CGEvent(mouseEventSource: source, mouseType: .rightMouseDown, mouseCursorPosition: point, mouseButton: .right)?.post(tap: .cghidEventTap)
usleep(100_000)
CGEvent(mouseEventSource: source, mouseType: .rightMouseUp, mouseCursorPosition: point, mouseButton: .right)?.post(tap: .cghidEventTap)
SWIFT
  /usr/bin/osascript >>/tmp/relaykit-real-quit-menu.log 2>&1 <<'APPLESCRIPT' || true
tell application "System Events"
  tell process "RelayKitApp.bin"
    try
      perform action "AXShowMenu" of menu bar item 1 of menu bar 1
    end try
  end tell
end tell
APPLESCRIPT
  /usr/bin/osascript >>/tmp/relaykit-real-quit-menu.log 2>&1 <<'APPLESCRIPT'
tell application "System Events"
  tell process "RelayKitApp.bin"
    repeat 20 times
      if exists menu item "Quit RelayKit" of menu 1 of menu bar item 1 of menu bar 1 then
        return
      end if
      delay 0.1
    end repeat
    error "Quit RelayKit menu item was not visible"
  end tell
end tell
APPLESCRIPT
  sleep 0.4
  /usr/sbin/screencapture -x "${OUT}/real-quit-menu.png"
  test -s "${OUT}/real-quit-menu.png"
  /usr/bin/osascript >/tmp/relaykit-real-quit-click.log 2>&1 <<'APPLESCRIPT'
tell application "System Events"
  tell process "RelayKitApp.bin"
    repeat with menuBarRef in menu bars
      try
        if exists menu item "Quit RelayKit" of menu 1 of menu bar item 1 of menuBarRef then
          click menu item "Quit RelayKit" of menu 1 of menu bar item 1 of menuBarRef
          return
        end if
      end try
    end repeat
  end tell
end tell
error "Quit RelayKit menu item could not be clicked"
APPLESCRIPT
  for _ in {1..30}; do
    if ! kill -0 "${PID}" 2>/dev/null && ! pgrep -x RelayKitApp.bin >/dev/null; then
      break
    fi
    sleep 0.2
  done
  if pgrep -x RelayKitApp.bin >/dev/null; then
    echo "Real Quit RelayKit menu item did not exit the app" >&2
    cat /tmp/relaykit-real-quit-click.log >&2 || true
    exit 1
  fi
  jq -n --arg screenshot "${OUT}/real-quit-menu.png" \
    '{real_quit_menu_visible: true, screenshot: $screenshot}' >"${evidence}"
  REAL_QUIT_MENU_EVIDENCE="${evidence}"
  PID=""
  cleanup
}

capture_outside_click() {
  local evidence="${OUT}/outside-click.json"
  cleanup
  /usr/bin/open -n "${APP_BUNDLE}" --args --ui-smoke --ui-smoke-evidence "${evidence}" --ui-smoke-catalog-url "${CATALOG_URL}" --ui-smoke-provider-config "${EMPTY_PROVIDER_CONFIG}" >/tmp/relaykit-outside-click.log 2>&1
  sleep 3
  PID="$(pgrep -x RelayKitApp.bin | head -1 || true)"
  if [[ -z "${PID}" ]] || ! kill -0 "${PID}" 2>/dev/null; then
    cat /tmp/relaykit-outside-click.log >&2 || true
    exit 1
  fi
  wait_for_jq "${evidence}" '.popover.shown == true'
  click_point 200 200
  wait_for_jq "${evidence}" '.popover.shown == false'
  /usr/sbin/screencapture -x "${OUT}/outside-click.png"
  test -s "${OUT}/outside-click.png"
  kill "${PID}" >/dev/null 2>&1 || true
  wait "${PID}" >/dev/null 2>&1 || true
  PID=""
  cleanup
}

cd "${ROOT}"
ORIGINAL_CODEX_CONFIG_SIGNATURE="$(file_signature "${CODEX_CONFIG_PATH}")"
ORIGINAL_CODEX_AUTH_SIGNATURE="$(file_signature "${CODEX_AUTH_PATH}")"
ORIGINAL_OFFICIAL_LOGIN_PIDS="$(official_login_pids)"
if [[ "${RELAYKIT_SKIP_BUILD_VERIFY:-0}" != "1" ]]; then
  ./script/build_and_run.sh --verify >/dev/null
fi
rm -rf "${OUT}"
mkdir -p "${OUT}"
SMOKE_CONFIG_DIR="$(mktemp -d /tmp/relaykit-ui-smoke-config.XXXXXX)"
EMPTY_PROVIDER_CONFIG="${SMOKE_CONFIG_DIR}/user-providers.json"
FIXTURE_PROVIDER_CONFIG="${SMOKE_CONFIG_DIR}/fixture-providers.json"
FAIL_PROVIDER_CONFIG="${SMOKE_CONFIG_DIR}/failure-providers.json"
CONNECT_PROVIDER_CONFIG="${SMOKE_CONFIG_DIR}/connect-providers.json"
USAGE_LOG_FULL="${SMOKE_CONFIG_DIR}/usage-full.jsonl"
USAGE_LOG_EMPTY="${SMOKE_CONFIG_DIR}/usage-empty.jsonl"
USAGE_LOG_AUTO="${SMOKE_CONFIG_DIR}/usage-auto.jsonl"
USAGE_LOG_LARGE="${SMOKE_CONFIG_DIR}/usage-large.jsonl"
CATALOG_DIR="${SMOKE_CONFIG_DIR}/catalog"
mkdir -p "${CATALOG_DIR}/v1"
cat >"${CATALOG_DIR}/v1/models" <<'JSON'
{
  "object": "list",
  "data": [
    {
      "id": "gpt-5.5",
      "owned_by": "openai",
      "source": "openai",
      "display_name": "GPT-5.5",
      "protocol": "responses",
      "transport": "relaykit_official_passthrough",
      "status": "ready",
      "visibility": "visible",
      "context_window": 128000
    },
    {
      "id": "demo/claude-haiku-4-5",
      "owned_by": "demo",
      "source": "demo",
      "display_name": "Demo Claude Haiku 4.5",
      "protocol": "responses",
      "transport": "local_relaykit",
      "bridge_host": "127.0.0.1:18791",
      "status": "ready",
      "visibility": "visible",
      "context_window": 200000
    },
    {
      "id": "demo/claude-sonnet-4-6",
      "owned_by": "demo",
      "source": "demo",
      "display_name": "Demo Claude Sonnet 4.6",
      "protocol": "responses",
      "transport": "local_relaykit",
      "bridge_host": "127.0.0.1:18791",
      "status": "ready",
      "visibility": "visible",
      "context_window": 200000
    }
  ]
}
JSON
cat >"${CATALOG_DIR}/provider-models" <<'JSON'
{
  "object": "list",
  "data": [
    {
      "id": "saved-coder-upstream",
      "object": "model",
      "owned_by": "fixture-provider"
    }
  ]
}
JSON
python3 -m http.server "${CATALOG_PORT}" --bind 127.0.0.1 --directory "${CATALOG_DIR}" >/tmp/relaykit-ui-smoke-catalog.log 2>&1 &
FAKE_CATALOG_PID="$!"
for _ in {1..20}; do
  if curl -fsS "${CATALOG_URL}" >/dev/null 2>&1; then
    break
  fi
  sleep 0.1
done
curl -fsS "${CATALOG_URL}" >/dev/null
install_smoke_keychain_credential
cat >"${FIXTURE_PROVIDER_CONFIG}" <<JSON
{
  "providers": [
    {
      "id": "fixture-provider",
      "name": "Saved Key Provider",
      "base_url": "http://127.0.0.1:${CATALOG_PORT}/v1",
      "api_format": "anthropic_messages",
      "credential_ref": {
        "kind": "keychain",
        "value": "${SMOKE_KEYCHAIN_SERVICE}"
      },
      "catalog": {
        "models_url": "http://127.0.0.1:${CATALOG_PORT}/provider-models"
      },
      "models": [
        {
          "id": "saved/coder",
          "display_name": "Saved Key Coder",
          "upstream_model": "saved-coder-upstream"
        },
        {
          "id": "saved/missing",
          "display_name": "Saved Missing",
          "upstream_model": "saved-missing-upstream"
        }
      ]
    }
  ]
}
JSON
cat >"${FAIL_PROVIDER_CONFIG}" <<JSON
{
  "providers": [
    {
      "id": "failure-provider",
      "name": "Saved Key Provider",
      "base_url": "http://127.0.0.1:9/v1",
      "api_format": "anthropic_messages",
      "credential_ref": {
        "kind": "keychain",
        "value": "${SMOKE_KEYCHAIN_SERVICE}"
      },
      "models": [
        {
          "id": "saved/coder",
          "display_name": "Saved Key Coder"
        }
      ]
    }
  ]
}
JSON
cat >"${CONNECT_PROVIDER_CONFIG}" <<JSON
{
  "providers": [
    {
      "id": "demo",
      "name": "Demo Anthropic",
      "base_url": "http://127.0.0.1:${CATALOG_PORT}",
      "api_format": "anthropic_messages",
      "credential_ref": {
        "kind": "keychain",
        "value": "${SMOKE_KEYCHAIN_SERVICE}"
      },
      "routing": {
        "source": "demo",
        "model_prefix": "demo/",
        "status": "enabled",
        "visible": true
      },
      "models": [
        {
          "id": "demo/claude-haiku-4-5",
          "display_name": "Claude Haiku 4.5"
        },
        {
          "id": "demo/claude-sonnet-4-6",
          "display_name": "Claude Sonnet 4.6"
        }
      ]
    }
  ]
}
JSON
python3 - "${USAGE_LOG_FULL}" "${USAGE_LOG_AUTO}" "${USAGE_LOG_LARGE}" <<'PY'
import datetime
import json
import sys

out, auto_out, large_out = sys.argv[1:4]
today = datetime.datetime.utcnow().date()

def ts(days):
    return (today - datetime.timedelta(days=days)).isoformat() + "T12:00:00Z"

events = [
    (0, "openai", "gpt-5.5", 60, 20, 80),
    (0, "openai", "gpt-5.5", 30, 40, 70),
    (1, "demo", "demo/claude-sonnet-4-6", 100, 80, 180),
    (1, "demo", "demo/claude-sonnet-4-6", 120, 90, 210),
    (1, "demo", "demo/claude-sonnet-4-6", 60, 50, 110),
    (6, "demo", "demo/claude-haiku-4-5", 40, 60, 100),
    (20, "openai", "gpt-5.1", 10, 15, 25),
]
with open(out, "w", encoding="utf-8") as f:
    for index, (days, provider, model, input_tokens, output_tokens, total_tokens) in enumerate(events, 1):
        f.write(json.dumps({
            "timestamp": ts(days),
            "request_id": f"ui-smoke-{index}",
            "provider_id": provider,
            "model": model,
            "route": "/v1/responses",
            "transport": "responses_http",
            "status": "completed",
            "http_status": 200,
            "input_tokens": input_tokens,
            "output_tokens": output_tokens,
            "total_tokens": total_tokens,
            "duration_ms": 100 + index,
        }, separators=(",", ":")) + "\n")
with open(auto_out, "w", encoding="utf-8") as f:
    f.write(json.dumps({
        "timestamp": ts(0),
        "request_id": "ui-smoke-auto-initial",
        "provider_id": "openai",
        "model": "gpt-5.5",
        "route": "/v1/responses",
        "transport": "responses_http",
        "status": "completed",
        "http_status": 200,
        "input_tokens": 40,
        "output_tokens": 60,
        "total_tokens": 100,
        "duration_ms": 100,
    }, separators=(",", ":")) + "\n")
with open(large_out, "w", encoding="utf-8") as f:
    models = ["gpt-5.5", "demo/claude-haiku-4-5", "demo/claude-sonnet-4-6"]
    providers = ["openai", "demo", "demo"]
    for index in range(1800):
        model_index = index % len(models)
        total = 50 + (index % 200)
        f.write(json.dumps({
            "timestamp": ts(index % 40),
            "request_id": f"ui-smoke-large-{index}",
            "provider_id": providers[model_index],
            "model": models[model_index],
            "route": "/v1/responses",
            "transport": "responses_http",
            "status": "completed",
            "http_status": 200,
            "input_tokens": total // 2,
            "output_tokens": total - (total // 2),
            "total_tokens": total,
            "duration_ms": 20,
        }, separators=(",", ":")) + "\n")
PY

if ORIGINAL_APPEARANCE="$(/usr/bin/defaults read "${BUNDLE_ID}" "${APPEARANCE_KEY}" 2>/dev/null)"; then
  HAD_ORIGINAL_APPEARANCE=1
else
  ORIGINAL_APPEARANCE=""
  HAD_ORIGINAL_APPEARANCE=0
fi
if ORIGINAL_PROVIDER_CONFIG="$(/usr/bin/defaults read "${BUNDLE_ID}" "${PROVIDER_CONFIG_KEY}" 2>/dev/null)"; then
  HAD_ORIGINAL_PROVIDER_CONFIG=1
  if is_relaykit_tmp_provider_config "${ORIGINAL_PROVIDER_CONFIG}"; then
    ORIGINAL_PROVIDER_CONFIG="${APP_SUPPORT_PROVIDER_CONFIG}"
  elif [[ "${ORIGINAL_PROVIDER_CONFIG}" == /tmp/* && ! -e "${ORIGINAL_PROVIDER_CONFIG}" ]]; then
    ORIGINAL_PROVIDER_CONFIG="${APP_SUPPORT_PROVIDER_CONFIG}"
  fi
else
  ORIGINAL_PROVIDER_CONFIG=""
  HAD_ORIGINAL_PROVIDER_CONFIG=0
fi

backup_manual_proof_files
rm -f "${ROOT}/dist/codex-desktop-manual-proof/evidence.json" "${ROOT}/dist/codex-desktop-manual-proof/usage-proof.json"
capture connect --ui-smoke-tab connect --ui-smoke-provider-config "${EMPTY_PROVIDER_CONFIG}"
capture official-sheet --ui-smoke-tab connect --ui-smoke-provider-config "${CONNECT_PROVIDER_CONFIG}" --ui-smoke-skip-gateway-exercise
restore_manual_proof_files
jq -e '
  .providers[] |
  select(
    .id == "demo" and
    .name == "Demo Anthropic" and
    .credential_ref.kind == "keychain" and
    ((.routing.model_prefix // "") == "demo/") and
    ([.models[].id] | length >= 1)
  )
' "${CONNECT_PROVIDER_CONFIG}" >/dev/null
capture real-demo --ui-smoke-tab connect --ui-smoke-provider-config "${CONNECT_PROVIDER_CONFIG}" --ui-smoke-skip-gateway-exercise
capture provider-click-flow --ui-smoke-tab connect --ui-smoke-detail --ui-smoke-provider-config "${FIXTURE_PROVIDER_CONFIG}" --ui-smoke-model-health-fixture
capture provider-test-failure --ui-smoke-tab connect --ui-smoke-detail --ui-smoke-provider-config "${FAIL_PROVIDER_CONFIG}"
jq -e '
  .providers[0].credential_ref.kind == "keychain" and
  .providers[0].credential_ref.value == "relaykit.ui-smoke.provider.fixture" and
  (.providers[0] | has("api_key") | not)
' "${FIXTURE_PROVIDER_CONFIG}" >/dev/null
if grep -Eiq 'sk-|bearer |access_token|refresh_token|password|secret' "${FIXTURE_PROVIDER_CONFIG}"; then
  echo "provider click flow leaked a credential-looking value into provider config" >&2
  exit 1
fi
capture detail --ui-smoke-tab connect --ui-smoke-detail --ui-smoke-provider-config "${FIXTURE_PROVIDER_CONFIG}"
capture detail-advanced-expanded --ui-smoke-tab connect --ui-smoke-detail --ui-smoke-provider-config "${FIXTURE_PROVIDER_CONFIG}"
capture detail-advanced-collapsed --ui-smoke-tab connect --ui-smoke-detail --ui-smoke-provider-config "${FIXTURE_PROVIDER_CONFIG}"
capture import --ui-smoke-tab connect --ui-smoke-import --ui-smoke-provider-config "${EMPTY_PROVIDER_CONFIG}"
capture usage --ui-smoke-tab usage --ui-smoke-provider-config "${EMPTY_PROVIDER_CONFIG}" --ui-smoke-usage-log "${USAGE_LOG_FULL}"
capture usage-auto-refresh --ui-smoke-tab usage --ui-smoke-provider-config "${EMPTY_PROVIDER_CONFIG}" --ui-smoke-usage-log "${USAGE_LOG_AUTO}" --ui-smoke-usage-refresh-interval 1
capture usage-large --ui-smoke-tab usage --ui-smoke-provider-config "${EMPTY_PROVIDER_CONFIG}" --ui-smoke-usage-log "${USAGE_LOG_LARGE}" --ui-smoke-usage-refresh-interval 1
capture usage-1m --ui-smoke-tab usage --ui-smoke-provider-config "${EMPTY_PROVIDER_CONFIG}" --ui-smoke-usage-log "${USAGE_LOG_FULL}"
capture usage-1y --ui-smoke-tab usage --ui-smoke-provider-config "${EMPTY_PROVIDER_CONFIG}" --ui-smoke-usage-log "${USAGE_LOG_FULL}"
capture usage-empty --ui-smoke-tab usage --ui-smoke-provider-config "${EMPTY_PROVIDER_CONFIG}" --ui-smoke-usage-log "${USAGE_LOG_EMPTY}"
capture settings --ui-smoke-tab settings --ui-smoke-provider-config "${EMPTY_PROVIDER_CONFIG}"
capture settings-developer-expanded --ui-smoke-tab settings --ui-smoke-provider-config "${EMPTY_PROVIDER_CONFIG}"
/usr/bin/defaults write "${BUNDLE_ID}" "${APPEARANCE_KEY}" light
capture settings-light --ui-smoke-tab settings --ui-smoke-provider-config "${EMPTY_PROVIDER_CONFIG}"
jq -e '.settings.appearance_mode == "light"' "${OUT}/settings-light.json" >/dev/null
capture usage-light --ui-smoke-tab usage --ui-smoke-provider-config "${EMPTY_PROVIDER_CONFIG}" --ui-smoke-usage-log "${USAGE_LOG_FULL}"
jq -e '.settings.appearance_mode == "light"' "${OUT}/usage-light.json" >/dev/null
capture official-light --ui-smoke-tab connect --ui-smoke-provider-config "${CONNECT_PROVIDER_CONFIG}" --ui-smoke-skip-gateway-exercise
cp "${OUT}/official-cta-before.png" "${OUT}/official-light.png"
capture provider-light --ui-smoke-tab connect --ui-smoke-detail --ui-smoke-provider-config "${FIXTURE_PROVIDER_CONFIG}" --ui-smoke-model-health-fixture
cp "${OUT}/provider-test-success.png" "${OUT}/provider-light.png"
/usr/bin/defaults write "${BUNDLE_ID}" "${APPEARANCE_KEY}" dark
capture settings-dark --ui-smoke-tab settings --ui-smoke-provider-config "${EMPTY_PROVIDER_CONFIG}"
jq -e '.settings.appearance_mode == "dark"' "${OUT}/settings-dark.json" >/dev/null
capture usage-dark --ui-smoke-tab usage --ui-smoke-provider-config "${EMPTY_PROVIDER_CONFIG}" --ui-smoke-usage-log "${USAGE_LOG_FULL}"
jq -e '.settings.appearance_mode == "dark"' "${OUT}/usage-dark.json" >/dev/null
capture official-dark --ui-smoke-tab connect --ui-smoke-provider-config "${CONNECT_PROVIDER_CONFIG}" --ui-smoke-skip-gateway-exercise
cp "${OUT}/official-cta-before.png" "${OUT}/official-dark.png"
capture provider-dark --ui-smoke-tab connect --ui-smoke-detail --ui-smoke-provider-config "${FIXTURE_PROVIDER_CONFIG}" --ui-smoke-model-health-fixture
cp "${OUT}/provider-test-success.png" "${OUT}/provider-dark.png"
restore_defaults
capture provider --ui-smoke-tab connect --ui-smoke-provider --ui-smoke-provider-config "${EMPTY_PROVIDER_CONFIG}"
capture_real_quit_menu
capture_outside_click
jq -n \
  --slurpfile connect "${OUT}/connect.json" \
  --slurpfile official "${OUT}/official-sheet.json" \
  --slurpfile officialLight "${OUT}/official-light.json" \
  --slurpfile officialDark "${OUT}/official-dark.json" \
  --slurpfile realDemo "${OUT}/real-demo.json" \
  --slurpfile providerFlow "${OUT}/provider-click-flow.json" \
  --slurpfile providerLight "${OUT}/provider-light.json" \
  --slurpfile providerDark "${OUT}/provider-dark.json" \
  --slurpfile providerAdd "${OUT}/provider.json" \
  --slurpfile providerFailure "${OUT}/provider-test-failure.json" \
  --slurpfile detail "${OUT}/detail.json" \
  --slurpfile advancedExpanded "${OUT}/detail-advanced-expanded.json" \
  --slurpfile advancedCollapsed "${OUT}/detail-advanced-collapsed.json" \
  --slurpfile usage "${OUT}/usage.json" \
  --slurpfile usageAuto "${OUT}/usage-auto-refresh.json" \
  --slurpfile usageLarge "${OUT}/usage-large.json" \
  --slurpfile usageEmpty "${OUT}/usage-empty.json" \
  --slurpfile settingsMain "${OUT}/settings.json" \
  --slurpfile settingsDeveloper "${OUT}/settings-developer-expanded.json" \
  --slurpfile quitMenu "${OUT}/real-quit-menu.json" \
  --slurpfile outsideClick "${OUT}/outside-click.json" \
  '{
    provider_config_path_is_app_support: $connect[0].connect.provider_config_path_is_app_support,
    stale_tmp_provider_config_recovered: $connect[0].connect.stale_tmp_provider_config_recovered,
    status_summary_inline: $connect[0].connect.status_summary_inline,
    model_access_and_model_list_merged: $connect[0].connect.model_access_and_model_list_merged,
    duplicate_empty_state: $connect[0].connect.duplicate_empty_state,
    official_provider_row_visible: $connect[0].connect.official_provider_row_visible,
    official_provider_row_managed_by_relaykit: $connect[0].connect.official_provider_row_managed_by_relaykit,
    official_sheet_opened: $official[0].connect.official_sheet_opened,
    official_light_sheet_opened: ($officialLight[0].settings.appearance_mode == "light" and $officialLight[0].connect.official_sheet_opened == true),
    official_dark_sheet_opened: ($officialDark[0].settings.appearance_mode == "dark" and $officialDark[0].connect.official_sheet_opened == true),
    official_auth_required_visible: $official[0].connect.official_auth_required_visible,
    official_auth_cta_visible: $official[0].connect.official_auth_cta_visible,
    official_auth_cta_clicked: $official[0].connect.official_auth_cta_clicked,
    official_auth_cta_has_real_action: $official[0].connect.official_auth_cta_has_real_action,
    official_auth_cta_disabled_as_unimplemented: $official[0].connect.official_auth_cta_disabled_as_unimplemented,
    official_auth_unimplemented_visible: $official[0].connect.official_auth_unimplemented_visible,
    official_auth_in_progress: $official[0].connect.official_auth_in_progress,
    official_auth_process_id_present: $official[0].connect.official_auth_process_id_present,
    official_device_url_captured: $official[0].connect.official_device_url_captured,
    official_device_code_captured: $official[0].connect.official_device_code_captured,
    official_device_code_copied: $official[0].connect.official_device_code_copied,
    official_credential_ref_exists: $official[0].connect.official_credential_ref_exists,
    official_current_status: $official[0].connect.official_current_status,
    official_connected_by_login_status: $official[0].connect.official_connected_by_login_status,
    official_connected_cta_disabled: $official[0].connect.official_connected_cta_disabled,
    official_connected_device_code_hidden: $official[0].connect.official_connected_device_code_hidden,
    official_connected_click_does_not_start_login: $official[0].connect.official_connected_click_does_not_start_login,
    official_route_verified_status: $official[0].connect.official_route_verified_status,
    official_device_login_visible: $official[0].connect.official_device_login_visible,
    official_product_actions_visible: $official[0].connect.official_product_actions_visible,
    official_authenticate_action_visible: $official[0].connect.official_authenticate_action_visible,
    official_status_refresh_action_visible: $official[0].connect.official_status_refresh_action_visible,
    official_reauth_action_visible: $official[0].connect.official_reauth_action_visible,
    official_disconnect_action_visible: $official[0].connect.official_disconnect_action_visible,
    official_isolated_desktop_entry_visible: $official[0].connect.official_isolated_desktop_entry_visible,
    official_token_boundary_visible: $official[0].connect.official_token_boundary_visible,
    official_debug_status_visible: $official[0].connect.official_debug_status_visible,
    official_debug_actions_visible: $official[0].connect.official_debug_actions_visible,
    official_mock_passthrough_status_visible: $official[0].connect.official_mock_passthrough_status_visible,
    official_not_connected_status_visible: $official[0].connect.official_not_connected_status_visible,
    official_device_login_pending_status_visible: $official[0].connect.official_device_login_pending_status_visible,
    official_login_available_status_visible: $official[0].connect.official_login_available_status_visible,
    official_route_verified_status_visible: $official[0].connect.official_route_verified_status_visible,
    official_state_details_collapsed: $official[0].connect.official_state_details_collapsed,
    official_state_details_expanded: $official[0].connect.official_state_details_expanded,
    official_login_required_status_visible: $official[0].connect.official_login_required_status_visible,
    official_real_auth_not_verified_visible: $official[0].connect.official_real_auth_not_verified_visible,
    official_open_codex_desktop_action_visible: $official[0].connect.official_open_codex_desktop_action_visible,
    official_run_isolated_check_action_visible: $official[0].connect.official_run_isolated_check_action_visible,
    official_copy_command_action_visible: $official[0].connect.official_copy_command_action_visible,
    official_run_isolated_check_clicked: $official[0].connect.official_run_isolated_check_clicked,
    official_open_signin_link_action_visible: $official[0].connect.official_open_signin_link_action_visible,
    official_open_signin_link_clicked: $official[0].connect.official_open_signin_link_clicked,
    official_copy_device_code_action_visible: $official[0].connect.official_copy_device_code_action_visible,
    official_copy_device_code_clicked: $official[0].connect.official_copy_device_code_clicked,
    header_models_match_unified_models: $connect[0].connect.header_models_match_unified_models,
    real_quit_menu_visible: $quitMenu[0].real_quit_menu_visible,
    outside_click_closes_popover: ($outsideClick[0].popover.shown == false),
    connect_first_screen_locked: $connect[0].connect.connect_first_screen_locked,
    protocol_tag_distinguishes_codex_route_and_upstream: $detail[0].connect.protocol_tag_distinguishes_codex_route_and_upstream,
    real_demo_provider_clicked: $realDemo[0].connect.real_demo_provider_clicked,
    real_demo_provider_config_path: $realDemo[0].connect.real_demo_provider_config_path,
    real_demo_base_url_visible: $realDemo[0].connect.real_demo_base_url_visible,
    real_demo_key_saved_visible: $realDemo[0].connect.real_demo_key_saved_visible,
    real_demo_models_visible: $realDemo[0].connect.real_demo_models_visible,
    provider_edit_base_url_prefilled: $providerFlow[0].connect.provider_edit_base_url_prefilled,
    provider_edit_models_loaded: $providerFlow[0].connect.provider_edit_models_loaded,
    provider_health_summary_visible: $providerFlow[0].connect.provider_health_summary_visible,
    provider_health_saved_count: $providerFlow[0].connect.provider_health_saved_count,
    provider_health_available_count: $providerFlow[0].connect.provider_health_available_count,
    provider_health_hidden_count: $providerFlow[0].connect.provider_health_hidden_count,
    provider_hidden_models_toggle_visible: $providerFlow[0].connect.provider_hidden_models_toggle_visible,
    provider_hidden_model_reasons_visible: $providerFlow[0].connect.provider_hidden_model_reasons_visible,
    provider_model_reachable_row_visible: $providerFlow[0].connect.provider_model_reachable_row_visible,
    provider_model_unavailable_row_visible: $providerFlow[0].connect.provider_model_unavailable_row_visible,
    provider_light_modal_opened: ($providerLight[0].settings.appearance_mode == "light" and $providerLight[0].connect.provider_edit_opened == true),
    provider_dark_modal_opened: ($providerDark[0].settings.appearance_mode == "dark" and $providerDark[0].connect.provider_edit_opened == true),
    saved_key_plaintext_hidden: $providerFlow[0].connect.saved_key_plaintext_hidden,
    saved_key_state_visible: $providerFlow[0].connect.saved_key_state_visible,
    api_key_masked_field_visible: $providerFlow[0].connect.api_key_masked_field_visible,
    api_key_saved_mask_control_visible: $providerFlow[0].connect.api_key_saved_mask_control_visible,
    api_key_saved_eye_visible: $providerFlow[0].connect.api_key_saved_eye_visible,
    saved_key_fake_eye_visible: $providerFlow[0].connect.saved_key_fake_eye_visible,
    saved_key_disabled_eye_reason_visible: $providerFlow[0].connect.saved_key_disabled_eye_reason_visible,
    saved_key_eye_toggle_works: $providerFlow[0].connect.saved_key_eye_toggle_works,
    api_key_replace_visible: $providerFlow[0].connect.api_key_replace_visible,
    api_key_new_eye_visible: $providerAdd[0].connect.api_key_new_eye_visible,
    new_key_eye_toggle_works: $providerAdd[0].connect.new_key_eye_toggle_works,
    api_key_replace_available: $providerFlow[0].connect.api_key_replace_available,
    provider_test_connection_visible: $providerFlow[0].connect.provider_form_test_connection_visible,
    provider_test_success_connected: $providerFlow[0].connect.provider_connection_connected_visible,
    provider_connection_counts_separated: $providerFlow[0].connect.provider_connection_counts_separated,
    provider_connection_use_reachable_visible: $providerFlow[0].connect.provider_connection_use_reachable_visible,
    provider_connection_used_reachable_models_only: $providerFlow[0].connect.provider_connection_used_reachable_models_only,
    provider_test_failure_network: $providerFailure[0].connect.provider_connection_network_failed_visible,
    provider_click_flow_real_ax: $providerFlow[0].connect.api_key_eye_toggle_clicked,
    advanced_default_collapsed: $detail[0].connect.advanced_default_collapsed,
    advanced_toggle_row_visible: $providerFlow[0].connect.advanced_toggle_row_visible,
    advanced_scrollable_when_expanded: $providerFlow[0].connect.advanced_scrollable_when_expanded,
    advanced_has_protocol_selector: $providerFlow[0].connect.advanced_has_protocol_selector,
    advanced_has_custom_models_url: $providerFlow[0].connect.advanced_has_custom_models_url,
    advanced_has_custom_auth_header: $providerFlow[0].connect.advanced_has_custom_auth_header,
    advanced_has_upstream_model_override: $providerFlow[0].connect.advanced_has_upstream_model_override,
    advanced_raw_fields_hidden: $providerFlow[0].connect.advanced_raw_fields_hidden,
    advanced_can_collapse_after_expand: $advancedCollapsed[0].connect.advanced_can_collapse_after_expand,
    usage_has_real_rows: $usage[0].usage.has_rows,
    usage_auto_refresh_enabled: $usage[0].usage.auto_refresh_enabled,
    usage_auto_refresh_updates_without_restart: ($usageAuto[0].usage.today_tokens == 350 and $usageAuto[0].usage.refresh_count >= 2),
    usage_summary_background: $usage[0].usage.summary_background,
    usage_last_refresh_duration_ms: $usage[0].usage.last_refresh_duration_ms,
    usage_large_fixture_requests: $usageLarge[0].usage.requests,
    usage_large_fixture_duration_ms: $usageLarge[0].usage.last_refresh_duration_ms,
    usage_empty_state_visible: $usageEmpty[0].usage.empty_state_visible,
    usage_today_tokens: $usage[0].usage.today_tokens,
    usage_today_tokens_label: $usage[0].usage.today_tokens_label,
    usage_seven_day_tokens: $usage[0].usage.seven_day_tokens,
    usage_seven_day_tokens_label: $usage[0].usage.seven_day_tokens_label,
    usage_all_time_tokens: $usage[0].usage.all_time_tokens,
    usage_all_time_tokens_label: $usage[0].usage.all_time_tokens_label,
    usage_requests: $usage[0].usage.requests,
    usage_top_model_7d: $usage[0].usage.top_model_7d,
    usage_top_model_7d_readable: $usage[0].usage.top_model_7d_readable,
    usage_top_model_readable_visible: $usage[0].usage.top_model_readable_visible,
    usage_provider_groups: $usage[0].usage.provider_group_names,
    usage_provider_source_shifted: $usage[0].usage.provider_source_shifted,
    usage_provider_tokens_labels: $usage[0].usage.provider_tokens_labels,
    usage_activity_heatmap_visible: $usage[0].usage.activity_heatmap_visible,
    usage_activity_range_control_visible: $usage[0].usage.activity_range_control_visible,
    usage_activity_unit_labels: $usage[0].usage.activity_unit_labels,
    usage_activity_unit_label_visible: $usage[0].usage.activity_unit_label_visible,
    usage_cost_unavailable_visible: $usage[0].usage.cost_unavailable_visible,
    usage_token_unit_formatting: $usage[0].usage.token_unit_formatting,
    settings_general_group_visible: $settingsMain[0].settings.general_group_visible,
    settings_gateway_group_visible: $settingsMain[0].settings.gateway_group_visible,
    settings_codex_group_visible: $settingsMain[0].settings.codex_group_visible,
    settings_data_privacy_group_visible: $settingsMain[0].settings.data_privacy_group_visible,
    settings_developer_collapsed_by_default: $settingsMain[0].settings.developer_collapsed,
    settings_developer_expands: $settingsDeveloper[0].settings.developer_expanded,
    settings_manual_proof_hidden_when_collapsed: $settingsMain[0].settings.manual_proof_hidden_when_collapsed,
    settings_manual_proof_visible_when_expanded: $settingsDeveloper[0].settings.manual_proof_visible_when_expanded,
    settings_gateway_port_fixed: ($settingsMain[0].settings.gateway_port == "127.0.0.1:19777"),
    settings_global_codex_activate_visible: $settingsMain[0].settings.global_codex_activate_visible,
    global_config_auth_unchanged: true
  }' >"${OUT}/product-evidence.json"
jq -e '
  .official_current_status as $officialStatus |
  .provider_config_path_is_app_support == false and
  .stale_tmp_provider_config_recovered == false and
  .status_summary_inline == true and
  .model_access_and_model_list_merged == true and
  .duplicate_empty_state == false and
  .official_provider_row_visible == true and
  .official_provider_row_managed_by_relaykit == true and
  .official_sheet_opened == true and
  .official_light_sheet_opened == true and
  .official_dark_sheet_opened == true and
  .official_auth_required_visible == false and
  .official_auth_cta_visible == true and
  (($officialStatus == "not connected" and .official_auth_cta_clicked == false) or
   ($officialStatus == "device login pending" and .official_auth_cta_clicked == true) or
   (($officialStatus == "login available" or $officialStatus == "route verified") and .official_auth_cta_clicked == false)) and
  .official_auth_cta_has_real_action == true and
  .official_auth_cta_disabled_as_unimplemented == false and
  .official_auth_unimplemented_visible == false and
  (($officialStatus == "not connected" and .official_auth_in_progress == false) or
   ($officialStatus == "device login pending" and .official_auth_in_progress == true and .official_auth_process_id_present == true) or
   (($officialStatus == "login available" or $officialStatus == "route verified") and .official_auth_in_progress == false)) and
  (($officialStatus == "not connected" and .official_connected_by_login_status == false) or
   ($officialStatus == "device login pending" and .official_device_url_captured == true and .official_device_code_captured == true and .official_device_code_copied == true and .official_copy_device_code_action_visible == true and .official_copy_device_code_clicked == true) or
   (($officialStatus == "login available" or $officialStatus == "route verified") and .official_connected_by_login_status == true and .official_connected_cta_disabled == true and .official_connected_device_code_hidden == true and .official_connected_click_does_not_start_login == true)) and
  ($officialStatus == "not connected" or .official_credential_ref_exists == true) and
  ($officialStatus == "not connected" or $officialStatus == "device login pending" or $officialStatus == "login available" or $officialStatus == "route verified") and
  .official_connected_by_login_status == ($officialStatus == "login available" or $officialStatus == "route verified") and
  .official_route_verified_status == ($officialStatus == "route verified") and
  (($officialStatus == "not connected" and .official_device_login_visible == false) or
   ($officialStatus == "device login pending" and .official_device_login_visible == true) or
   ($officialStatus == "login available" or $officialStatus == "route verified")) and
  .official_product_actions_visible == true and
  .official_authenticate_action_visible == true and
  .official_status_refresh_action_visible == true and
  .official_reauth_action_visible == false and
  .official_disconnect_action_visible == true and
  .official_isolated_desktop_entry_visible == false and
  .official_token_boundary_visible == true and
  .official_debug_status_visible == false and
  .official_debug_actions_visible == false and
  .official_mock_passthrough_status_visible == false and
  .official_not_connected_status_visible == ($officialStatus == "not connected") and
  (.official_device_login_pending_status_visible | type == "boolean") and
  (.official_login_available_status_visible | type == "boolean") and
  (.official_route_verified_status_visible | type == "boolean") and
  .official_state_details_collapsed == true and
  .official_state_details_expanded == false and
  .official_login_required_status_visible == false and
  .official_real_auth_not_verified_visible == false and
  .official_open_codex_desktop_action_visible == false and
  .official_run_isolated_check_action_visible == false and
  .official_copy_command_action_visible == false and
  .official_run_isolated_check_clicked == false and
  (($officialStatus == "device login pending" and .official_open_signin_link_action_visible == true) or
   ($officialStatus == "login available" or $officialStatus == "route verified")) and
  .official_open_signin_link_clicked == false and
  .header_models_match_unified_models == true and
  .real_quit_menu_visible == true and
  .outside_click_closes_popover == true and
  .connect_first_screen_locked == true and
  .protocol_tag_distinguishes_codex_route_and_upstream == true and
  .real_demo_provider_clicked == true and
  .real_demo_provider_config_path == true and
  .real_demo_base_url_visible == true and
  .real_demo_key_saved_visible == true and
  .real_demo_models_visible == true and
  .provider_edit_base_url_prefilled == true and
  .provider_edit_models_loaded == true and
  .provider_health_summary_visible == true and
  .provider_health_saved_count == 2 and
  .provider_health_available_count == 1 and
  .provider_health_hidden_count == 1 and
  .provider_model_reachable_row_visible == true and
  .provider_model_unavailable_row_visible == true and
  .provider_light_modal_opened == true and
  .provider_dark_modal_opened == true and
  .provider_hidden_models_toggle_visible == true and
  .provider_hidden_model_reasons_visible == true and
  .saved_key_plaintext_hidden == true and
  .saved_key_state_visible == true and
  .api_key_masked_field_visible == true and
  .api_key_saved_mask_control_visible == true and
  .api_key_saved_eye_visible == true and
  .saved_key_fake_eye_visible == false and
  .saved_key_disabled_eye_reason_visible == false and
  .saved_key_eye_toggle_works == true and
  .api_key_replace_visible == false and
  .api_key_new_eye_visible == true and
  .new_key_eye_toggle_works == true and
  .api_key_replace_available == false and
  .provider_test_connection_visible == true and
  .provider_test_success_connected == true and
  .provider_connection_counts_separated == true and
  .provider_connection_use_reachable_visible == true and
  .provider_connection_used_reachable_models_only == true and
  .provider_test_failure_network == true and
  .provider_click_flow_real_ax == true and
  .advanced_default_collapsed == true and
  .advanced_toggle_row_visible == true and
  .advanced_scrollable_when_expanded == true and
  .advanced_has_protocol_selector == true and
  .advanced_has_custom_models_url == true and
  .advanced_has_custom_auth_header == true and
  .advanced_has_upstream_model_override == true and
  .advanced_raw_fields_hidden == true and
  .advanced_can_collapse_after_expand == true and
  .usage_has_real_rows == true and
  .usage_auto_refresh_enabled == true and
  .usage_auto_refresh_updates_without_restart == true and
  .usage_summary_background == true and
  .usage_large_fixture_requests == 1800 and
  .usage_large_fixture_duration_ms < 5000 and
  .usage_empty_state_visible == true and
  .usage_today_tokens == 150 and
  .usage_today_tokens_label == "150" and
  .usage_seven_day_tokens == 750 and
  .usage_seven_day_tokens_label == "750" and
  .usage_all_time_tokens == 775 and
  .usage_all_time_tokens_label == "775" and
  .usage_requests == 7 and
  .usage_top_model_7d == "demo/claude-sonnet-4-6" and
  .usage_top_model_7d_readable == "claude-sonnet-4-6" and
  .usage_top_model_readable_visible == true and
  .usage_provider_groups == ["Official Codex / OpenAI","Third-party providers"] and
  .usage_provider_source_shifted == true and
  .usage_activity_heatmap_visible == true and
  .usage_activity_range_control_visible == true and
  .usage_activity_unit_labels == ["7D · half-day","1M · daily","1Y · weekly"] and
  .usage_activity_unit_label_visible == true and
  .usage_cost_unavailable_visible == true and
  .usage_token_unit_formatting == true and
  .settings_general_group_visible == true and
  .settings_gateway_group_visible == true and
  .settings_codex_group_visible == true and
  .settings_data_privacy_group_visible == true and
  .settings_developer_collapsed_by_default == true and
  .settings_developer_expands == true and
  .settings_manual_proof_hidden_when_collapsed == true and
  .settings_manual_proof_visible_when_expanded == true and
  .settings_gateway_port_fixed == true and
  .settings_global_codex_activate_visible == false and
  .global_config_auth_unchanged == true
' "${OUT}/product-evidence.json" >/dev/null
MANUAL_CHECK_OUT="${ROOT}/dist/manual-check"
mkdir -p "${MANUAL_CHECK_OUT}"
cp "${OUT}/connect.png" "${MANUAL_CHECK_OUT}/final-connect-provider-real.png"
cp "${OUT}/official-sheet.png" "${MANUAL_CHECK_OUT}/final-official-auth-flow.png"
cp "${OUT}/provider-key-saved.png" "${MANUAL_CHECK_OUT}/final-provider-key-models.png"
cp "${OUT}/provider-advanced-simplified.png" "${MANUAL_CHECK_OUT}/final-advanced-expanded.png"
cp "${OUT}/provider-test-success.png" "${MANUAL_CHECK_OUT}/final-provider-test-success.png"
cp "${OUT}/provider-use-reachable.png" "${MANUAL_CHECK_OUT}/final-provider-use-reachable.png"
cp "${OUT}/provider-test-failure.png" "${MANUAL_CHECK_OUT}/final-provider-test-failure.png"
cp "${OUT}/usage.png" "${MANUAL_CHECK_OUT}/final-usage-real-data.png"
cp "${OUT}/usage.png" "${MANUAL_CHECK_OUT}/final-usage-7d-activity.png"
cp "${OUT}/usage.png" "${MANUAL_CHECK_OUT}/final-usage-activity-heatmap.png"
cp "${OUT}/usage-1m.png" "${MANUAL_CHECK_OUT}/final-usage-1m-activity.png"
cp "${OUT}/usage-1y.png" "${MANUAL_CHECK_OUT}/final-usage-1y-activity.png"
cp "${OUT}/usage-empty.png" "${MANUAL_CHECK_OUT}/final-usage-empty.png"
cp "${OUT}/settings.png" "${MANUAL_CHECK_OUT}/final-settings-groups.png"
cp "${OUT}/settings-developer-expanded.png" "${MANUAL_CHECK_OUT}/final-settings-developer-expanded.png"
cp "${OUT}/usage-light.png" "${MANUAL_CHECK_OUT}/final-usage-light.png"
cp "${OUT}/usage-dark.png" "${MANUAL_CHECK_OUT}/final-usage-dark.png"
cp "${OUT}/settings-light.png" "${MANUAL_CHECK_OUT}/final-settings-light.png"
cp "${OUT}/settings-dark.png" "${MANUAL_CHECK_OUT}/final-settings-dark.png"
cp "${OUT}/official-light.png" "${MANUAL_CHECK_OUT}/final-official-light.png"
cp "${OUT}/provider-light.png" "${MANUAL_CHECK_OUT}/final-provider-light.png"
cp "${OUT}/official-dark.png" "${MANUAL_CHECK_OUT}/final-official-dark.png"
cp "${OUT}/provider-dark.png" "${MANUAL_CHECK_OUT}/final-provider-dark.png"
cp "${OUT}/official-cta-before.png" "${MANUAL_CHECK_OUT}/real-user-official-before.png"
cp "${OUT}/official-cta-after.png" "${MANUAL_CHECK_OUT}/real-user-official-after.png"
cp "${OUT}/real-user-demo-provider.png" "${MANUAL_CHECK_OUT}/real-user-demo-provider.png"
cleanup
cleanup_official_login_processes
assert_shared_codex_files_unchanged

if pgrep -x RelayKitApp.bin >/dev/null || pgrep -f "${BUNDLED_RELAY}" >/dev/null; then
  echo "UI smoke left stale RelayKit-owned app or gateway process" >&2
  exit 1
fi
while IFS= read -r pid; do
  [[ -z "${pid}" ]] && continue
  if ! printf '%s\n' "${ORIGINAL_OFFICIAL_LOGIN_PIDS}" | grep -qx "${pid}"; then
    echo "UI smoke left stale RelayKit-owned official login process ${pid}" >&2
    exit 1
  fi
done < <(official_login_pids)

echo "RelayKit menu bar UI smoke passed: ${OUT}"
