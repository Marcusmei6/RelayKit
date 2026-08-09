#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${ROOT}/scripts/menu-bar-e2e-smoke.sh"
BUILD_SCRIPT="${ROOT}/script/build_app_bundle.sh"
PACKAGE_SCRIPT="${ROOT}/script/package_release.sh"
APP_VIEW_SOURCE="${ROOT}/app/Sources/RelayKitApp/Views/ContentView.swift"

fail() {
  echo "menu bar smoke contract test failed: $*" >&2
  exit 1
}

bash -n "${SCRIPT}"
bash -n "${BUILD_SCRIPT}"
bash -n "${PACKAGE_SCRIPT}"

grep -Fq 'final_aggregate_predicate() {' "${SCRIPT}" ||
  fail "final aggregate predicate needs first-failed-conjunct observability"
grep -Fq 'global_config_auth_access_mode: "isolated-not-accessed"' "${SCRIPT}" ||
  fail "final evidence must honestly state isolated global config/auth non-access"
if grep -Fq 'global_config_auth_unchanged' "${SCRIPT}"; then
  fail "final evidence retained the unsupported global config/auth equality claim"
fi
if grep -Eq '\$HOME/\.codex|~/\.codex|\.codex/(config\.toml|auth\.json)|shasum.*(config|auth)' "${SCRIPT}"; then
  fail "isolated smoke reads or hashes global Codex config/auth"
fi
run_final_aggregate_predicate_contract() (
  RELAYKIT_MENU_BAR_E2E_SOURCE_ONLY=1 source "${SCRIPT}"
  local case_root helper_body keys_json baseline output rc label key expected_type
  case_root="$(mktemp -d /tmp/relaykit-final-aggregate-test.XXXXXX)"
  trap 'rm -rf -- "${case_root}"' EXIT
  helper_body="$(sed -n '/^final_aggregate_predicate() {/,/^}/p' "${SCRIPT}")"
  keys_json="$(grep -o 'key:"[^"]*"' <<<"${helper_body}" | sed 's/^key:"//; s/"$//' | awk '!seen[$0]++' | jq -Rsc 'split("\n") | map(select(length > 0))')"
  baseline="${case_root}/baseline.json"
  jq -n --argjson keys "${keys_json}" '
    reduce $keys[] as $key ({}; .[$key] = true) |
    .official_current_status = "login available" |
    .provider_config_path_is_app_support = false |
    .stale_tmp_provider_config_recovered = false |
    .duplicate_empty_state = false |
    .official_auth_required_visible = false |
    .official_auth_cta_clicked = false |
    .official_auth_cta_disabled_as_unimplemented = false |
    .official_auth_unimplemented_visible = false |
    .official_auth_in_progress = false |
    .official_connected_cta_disabled = true |
    .official_connected_device_code_hidden = true |
    .official_connected_click_does_not_start_login = true |
    .official_route_verified_status = false |
    .official_reauth_action_visible = false |
    .official_isolated_desktop_entry_visible = false |
    .official_debug_status_visible = false |
    .official_debug_actions_visible = false |
    .official_mock_passthrough_status_visible = false |
    .official_not_connected_status_visible = false |
    .official_state_details_expanded = false |
    .official_login_required_status_visible = false |
    .official_real_auth_not_verified_visible = false |
    .official_open_codex_desktop_action_visible = false |
    .official_run_isolated_check_action_visible = false |
    .official_copy_command_action_visible = false |
    .official_run_isolated_check_clicked = false |
    .official_open_signin_link_clicked = false |
    .saved_key_fake_eye_visible = false |
    .saved_key_disabled_eye_reason_visible = false |
    .api_key_replace_visible = false |
    .api_key_replace_available = false |
    .settings_global_codex_activate_visible = false |
    .global_config_auth_access_mode = "isolated-not-accessed" |
    .provider_health_saved_count = 2 |
    .provider_health_available_count = 1 |
    .provider_health_hidden_count = 1 |
    .usage_large_fixture_requests = 1800 |
    .usage_large_fixture_duration_ms = 4999 |
    .usage_today_tokens = 150 |
    .usage_today_tokens_label = "150" |
    .usage_seven_day_tokens = 750 |
    .usage_seven_day_tokens_label = "750" |
    .usage_all_time_tokens = 775 |
    .usage_all_time_tokens_label = "775" |
    .usage_requests = 7 |
    .usage_top_model_7d = "demo/claude-sonnet-4-6" |
    .usage_top_model_7d_readable = "claude-sonnet-4-6" |
    .usage_provider_groups = ["Official Codex / OpenAI", "Third-party providers"] |
    .usage_activity_unit_labels = ["7D · half-day", "1M · daily", "1Y · weekly"]
  ' >"${baseline}"

  output="$(final_aggregate_predicate "${baseline}" 2>&1)" ||
    fail "valid final aggregate fixture failed: ${output}"
  [[ -z "${output}" ]] || fail "successful final aggregate predicate was not silent"

  jq '
    .official_current_status = "not connected" |
    .official_auth_cta_clicked = false |
    .official_auth_in_progress = false |
    .official_connected_by_login_status = false |
    .official_route_verified_status = false |
    .official_device_login_visible = false |
    .official_not_connected_status_visible = true |
    .official_open_signin_link_action_visible = false
  ' "${baseline}" >"${case_root}/not-connected.json"
  output="$(final_aggregate_predicate "${case_root}/not-connected.json" 2>&1)" ||
    fail "not-connected aggregate rejected a hidden sign-in link: ${output}"
  [[ -z "${output}" ]] || fail "not-connected aggregate success was not silent"
  jq '.official_open_signin_link_action_visible = true' "${case_root}/not-connected.json" >"${case_root}/not-connected-link-visible.json"
  set +e
  output="$(final_aggregate_predicate "${case_root}/not-connected-link-visible.json" 2>&1)"
  rc="$?"
  set -e
  [[ "${rc}" == "1" && "${output}" == 'AGGREGATE_FIRST_FAILED_CONJUNCT=official_open_signin_link_by_status type=boolean' ]] ||
    fail "not-connected visible sign-in link did not map to the fixed aggregate conjunct"

  jq '
    .official_current_status = "device login pending" |
    .official_auth_cta_clicked = true |
    .official_auth_in_progress = true |
    .official_auth_process_id_present = true |
    .official_connected_by_login_status = false |
    .official_device_url_captured = true |
    .official_device_code_captured = true |
    .official_device_code_copied = true |
    .official_copy_device_code_action_visible = true |
    .official_copy_device_code_clicked = true |
    .official_route_verified_status = false |
    .official_device_login_visible = true |
    .official_not_connected_status_visible = false |
    .official_open_signin_link_action_visible = true
  ' "${baseline}" >"${case_root}/device-login-pending.json"
  output="$(final_aggregate_predicate "${case_root}/device-login-pending.json" 2>&1)" ||
    fail "device-login-pending aggregate rejected a visible sign-in link: ${output}"
  [[ -z "${output}" ]] || fail "device-login-pending aggregate success was not silent"
  jq '.official_open_signin_link_action_visible = false' "${case_root}/device-login-pending.json" >"${case_root}/device-login-link-hidden.json"
  set +e
  output="$(final_aggregate_predicate "${case_root}/device-login-link-hidden.json" 2>&1)"
  rc="$?"
  set -e
  [[ "${rc}" == "1" && "${output}" == 'AGGREGATE_FIRST_FAILED_CONJUNCT=official_open_signin_link_by_status type=boolean' ]] ||
    fail "device-login-pending hidden sign-in link did not map to the fixed aggregate conjunct"

  for key in false true; do
    jq --argjson visible "${key}" '.official_open_signin_link_action_visible = $visible' "${baseline}" >"${case_root}/login-available-${key}.json"
    output="$(final_aggregate_predicate "${case_root}/login-available-${key}.json" 2>&1)" ||
      fail "login-available aggregate unexpectedly constrained sign-in visibility: ${output}"
    jq --argjson visible "${key}" '
      .official_current_status = "route verified" |
      .official_route_verified_status = true |
      .official_open_signin_link_action_visible = $visible
    ' "${baseline}" >"${case_root}/route-verified-${key}.json"
    output="$(final_aggregate_predicate "${case_root}/route-verified-${key}.json" 2>&1)" ||
      fail "route-verified aggregate unexpectedly constrained sign-in visibility: ${output}"
  done
  jq '.official_current_status = "unknown"' "${baseline}" >"${case_root}/unknown-status.json"
  if final_aggregate_predicate "${case_root}/unknown-status.json" >/dev/null 2>&1; then
    fail "unknown official status was accepted by final aggregate"
  fi

  local seen_keys=$'\n'
  while IFS=$'\t' read -r label key; do
    [[ -n "${label}" && -n "${key}" ]] || continue
    grep -Fxq "${key}" <<<"${seen_keys}" && continue
    seen_keys+="${key}"$'\n'
    case "${key}" in
      official_device_login_visible|official_open_signin_link_action_visible|usage_large_fixture_duration_ms) continue ;;
    esac
    jq --arg key "${key}" 'del(.[$key])' "${baseline}" >"${case_root}/failed.json"
    set +e
    output="$(final_aggregate_predicate "${case_root}/failed.json" 2>&1)"
    rc="$?"
    set -e
    expected_type=missing
    [[ "${key}" == "official_current_status" ]] && label=official_auth_cta_clicked_by_status && expected_type=boolean
    [[ "${rc}" == "1" ]] || fail "final aggregate missing-field RC changed for ${label}"
    [[ "${output}" == "AGGREGATE_FIRST_FAILED_CONJUNCT=${label} type=${expected_type}" ]] ||
      fail "final aggregate first-failed mapping changed for ${label}: ${output}"
  done < <(grep -o 'label:"[^"]*", key:"[^"]*"' <<<"${helper_body}" |
    sed 's/^label:"//; s/", key:"/\t/; s/"$//')

  jq 'del(.provider_config_path_is_app_support)' "${baseline}" >"${case_root}/missing.json"
  output="$(final_aggregate_predicate "${case_root}/missing.json" 2>&1)" || rc="$?"
  [[ "${rc:-1}" == "1" && "${output}" == 'AGGREGATE_FIRST_FAILED_CONJUNCT=provider_config_path_is_app_support type=missing' ]] ||
    fail "final aggregate missing type is not fixed and public-safe"
  jq '.provider_config_path_is_app_support = null' "${baseline}" >"${case_root}/null.json"
  output="$(final_aggregate_predicate "${case_root}/null.json" 2>&1)" || rc="$?"
  [[ "${rc:-1}" == "1" && "${output}" == 'AGGREGATE_FIRST_FAILED_CONJUNCT=provider_config_path_is_app_support type=null' ]] ||
    fail "final aggregate null type is not fixed and public-safe"
  jq '.provider_config_path_is_app_support = {}' "${baseline}" >"${case_root}/object.json"
  output="$(final_aggregate_predicate "${case_root}/object.json" 2>&1)" || rc="$?"
  [[ "${rc:-1}" == "1" && "${output}" == 'AGGREGATE_FIRST_FAILED_CONJUNCT=provider_config_path_is_app_support type=object' ]] ||
    fail "final aggregate wrong JSON type is not fixed and public-safe"
  printf '%s\n' '{malformed' >"${case_root}/malformed.json"
  set +e
  output="$(final_aggregate_predicate "${case_root}/malformed.json" 2>&1)"
  rc="$?"
  set -e
  [[ "${rc}" != "0" && "${output}" == 'AGGREGATE_FIRST_FAILED_CONJUNCT=parse-or-schema type=invalid' ]] ||
    fail "final aggregate malformed JSON fallback changed or leaked diagnostics"
  [[ "$(grep -Fc 'final_aggregate_predicate "${OUT}/product-evidence.json"' "${SCRIPT}")" == "1" ]] ||
    fail "final aggregate helper must have exactly one production callsite"
)
run_final_aggregate_predicate_contract

if grep -Eq 'press_ax_label|focus_ax_label|click_point|/usr/sbin/screencapture|AXShowMenu|click menu item' "${SCRIPT}"; then
  fail "popover actions and captures must not use AX children, static clicks, or screen-wide screenshots"
fi
for required_visual_contract in \
  'import CoreGraphics' \
  'import Vision' \
  'CGWindowListCopyWindowInfo' \
  'SCScreenshotManager.captureImage' \
  'proc_pidpath' \
  'VNRecognizeTextRequest' \
  'visual_action_synthetic_contract'; do
  grep -Fq "${required_visual_contract}" "${SCRIPT}" ||
    fail "visual action helper lacks ${required_visual_contract}"
done
grep -Fq 'func connectRootAnchorObservationDiagnostic(' "${SCRIPT}" ||
  fail "connect-root anchor observation diagnostic calculator is missing"
grep -Fq 'func connectRootAnchorObservationSchema(' "${SCRIPT}" ||
  fail "connect-root anchor observation diagnostic schema is missing"
grep -Fq 'func connectRootPublicAnchorCandidatesDiagnostic(' "${SCRIPT}" ||
  fail "connect-root public anchor candidates diagnostic calculator is missing"
set +e
visual_contract_output="$(RELAYKIT_MENU_BAR_VISUAL_SYNTHETIC_TEST=1 bash "${SCRIPT}" 2>&1)"
visual_contract_rc="$?"
set -e
[[ "${visual_contract_rc}" == "0" && "${visual_contract_output}" == "Visual action synthetic contract passed" ]] ||
  fail "pure synthetic visual action contract failed"
grep -Fq 'return_visual_action_failure() {' "${SCRIPT}" ||
  fail "visual action failures need a fixed shell substage mapper"
grep -Fq 'visual-${mode}.pre-swift-identity' "${SCRIPT}" ||
  fail "pre-Swift executable identity must remain a distinct fixed stage"
if grep -Eq 'exit\(70\)|exit 70' "${SCRIPT}"; then
  fail "visual helper must not retain the generic RC70 catch"
fi
grep -Fq 'visual_mode_is_valid() {' "${SCRIPT}" || fail "visual action modes need a fixed shell allowlist"
run_visual_mode_contract() (
  RELAYKIT_MENU_BAR_E2E_SOURCE_ONLY=1 source "${SCRIPT}"
  local mode rc
  for mode in self-test probe-window capture click-text outside type-text; do
    visual_mode_is_valid "${mode}" || fail "reviewed visual mode ${mode} was rejected"
  done
  for mode in window-equivalence-diagnostic unknown-mode; do
    if visual_mode_is_valid "${mode}" >/dev/null 2>&1; then
      fail "obsolete or unknown visual mode ${mode} was accepted"
    else
      rc="$?"
    fi
    [[ "${rc}" == "2" ]] || fail "obsolete or unknown visual mode ${mode} did not fail closed with rc2"
  done
)
run_visual_mode_contract
grep -Fq 'func allowedInput(_ input: String) -> Bool' "${SCRIPT}" || fail "type-text input needs a fixed Swift allowlist"
for keyboard_contract in \
  'CGEvent(keyboardEventSource:' \
  'keyDown: true' \
  'keyDown: false' \
  '.maskCommand' \
  'keyboardSetUnicodeString'; do
  grep -Fq "${keyboard_contract}" "${SCRIPT}" || fail "type-text CGEvent contract lacks ${keyboard_contract}"
done
if grep -Eq '/usr/bin/osascript|tell application "System Events"|keystroke |set the clipboard|pbcopy' "${SCRIPT}"; then
  fail "type-text must not retain osascript, System Events, keystroke, or clipboard input"
fi
type_text_branch="$(sed -n '/if mode == "type-text"/,/exit(0)/p' "${SCRIPT}")"
[[ "$(grep -Fc 'try revalidate(frozen, pid: pid, expectedExecutable: expectedExecutable)' <<<"${type_text_branch}")" -ge 2 ]] ||
  fail "type-text must revalidate the exact PID/window before click and keyboard"
grep -Fq 'try selectAllText()' <<<"${type_text_branch}" || fail "type-text lacks fixed Cmd-A selection"
grep -Fq 'try inputText(output)' <<<"${type_text_branch}" || fail "type-text lacks fixed Unicode input"
visual_type_body="$(sed -n '/^visual_type_exact_pid() {/,/^}/p' "${SCRIPT}")"
grep -Fq 'visual_action type-text "$1" "$2" "$3" "$4"' <<<"${visual_type_body}" ||
  fail "visual_type_exact_pid must solely delegate to type-text with its type-key phase"
[[ "$(grep -c 'visual_action type-text' <<<"${visual_type_body}")" == "1" ]] || fail "visual_type_exact_pid delegated more than once"
if grep -Eq 'process_executable_matches|osascript|System Events|CGEvent' <<<"${visual_type_body}"; then
  fail "visual_type_exact_pid retained a second input path"
fi

run_pre_swift_identity_contract() (
  RELAYKIT_MENU_BAR_E2E_SOURCE_ONLY=1 source "${SCRIPT}"
  local case_root expected actual_path output_file output rc category expected_rc
  case_root="$(mktemp -d /tmp/relaykit-pre-swift-identity-test.XXXXXX)"
  trap 'rm -rf -- "${case_root}"' EXIT
  mkdir -p "${case_root}/bin"
  expected="/tmp/$(basename "${case_root}")/bin/RelayKitApp.bin"
  actual_path="$(cd "${case_root}/bin" && pwd -P)/RelayKitApp.bin"
  : >"${case_root}/bin/RelayKitApp.bin"
  output_file="${case_root}/output.txt"

  while IFS='|' read -r category expected_rc; do
    CURRENT_STAGE=bootstrap
    PID=321
    APP_REAL="${expected}"
    visual_pid_is_alive() { return 0; }
    process_executable_path() { printf '%s\n' "${actual_path}"; }
    case "${category}" in
      pid-missing-or-invalid) PID=invalid ;;
      pid-not-alive) visual_pid_is_alive() { return 1; } ;;
      proc-pidpath-unavailable) process_executable_path() { return 1; } ;;
      expected-canonical-unavailable) APP_REAL="${case_root}/missing/RelayKitApp.bin" ;;
      executable-mismatch) process_executable_path() { printf '%s\n' "${case_root}/wrong"; } ;;
    esac
    set +e
    pre_swift_process_identity official-sheet click-text >"${output_file}" 2>&1
    rc="$?"
    set -e
    output="$(<"${output_file}")"
    if [[ -n "${output}" && "${output}" != "RelayKit menu smoke failed: stage=flow.official-sheet.visual-click-text.pre-swift-identity.${category} rc=${expected_rc}" ]]; then
      fail "pre-Swift identity classification exposed dynamic content"
    fi
    [[ "${rc}" == "${expected_rc}" ]] || fail "pre-Swift identity rc collapsed for ${category}"
    [[ "${CURRENT_STAGE}" == "flow.official-sheet.visual-click-text.pre-swift-identity.${category}" ]] ||
      fail "pre-Swift identity stage mismatch for ${category}"
  done <<'CASES'
pid-missing-or-invalid|61
pid-not-alive|62
proc-pidpath-unavailable|63
expected-canonical-unavailable|64
executable-mismatch|65
CASES

  CURRENT_STAGE=bootstrap
  PID=321
  APP_REAL="${expected}"
  visual_pid_is_alive() { return 0; }
  process_executable_path() { printf '%s\n' "${actual_path}"; }
  set +e
  pre_swift_process_identity official-sheet click-text >"${output_file}" 2>&1
  rc="$?"
  set -e
  [[ "${rc}" == "0" ]] || fail "/tmp canonical path produced a false executable mismatch"
  [[ "${CURRENT_STAGE}" == "flow.official-sheet.visual-click-text.pre-swift-identity.success" ]] ||
    fail "successful pre-Swift identity did not reach its fixed success stage"
)

run_pre_swift_identity_contract

grep -Fq 'set_visual_swift_stage() {' "${SCRIPT}" || fail "visual Swift execution needs fixed invoke/success stages"
visual_action_body="$(sed -n '/^visual_action() {/,/^visual_click_text() {/p' "${SCRIPT}")"
grep -Fq 'if swift - "${mode}" "${PID:-0}" "${APP_REAL:-/nonexistent}" "${flow}" "${label}" "${output}" <<'\''SWIFT'\''' <<<"${visual_action_body}" ||
  fail "visual Swift invocation argv or quoted heredoc changed"
visual_invoke_stage_line="$(grep -nF 'set_visual_swift_stage "${flow}" "${mode}" invoke' <<<"${visual_action_body}" | cut -d: -f1 || true)"
visual_swift_line="$(grep -nF 'if swift - "${mode}" "${PID:-0}" "${APP_REAL:-/nonexistent}" "${flow}" "${label}" "${output}"' <<<"${visual_action_body}" | cut -d: -f1)"
[[ -n "${visual_invoke_stage_line}" && "${visual_invoke_stage_line}" -lt "${visual_swift_line}" ]] ||
  fail "visual Swift invoke stage must be set after identity and before Swift"
visual_swift_tail="$(sed -n '/^SWIFT$/,/^  return_visual_action_failure/p' <<<"${visual_action_body}")"
visual_swift_expected_tail='SWIFT
  then
    set_visual_swift_stage "${flow}" "${mode}" success
    return 0
  else
    visual_rc="$?"
  fi
  if [[ "${RELAYKIT_MENU_BAR_WINDOW_EQUIVALENCE_DIAGNOSTIC:-0}" == "1" && "${mode}" == "probe-window" ]]; then
    return "${visual_rc}"
  fi
  if [[ "${RELAYKIT_WINDOW_EQUIVALENCE_DIAGNOSTIC_TARGET:-}" == "first-ambiguity" && "${visual_rc}" == "98" ]]; then
    cleanup_current_app
    FAILURE_REPORTED=1
    exit 0
  fi
  if [[ "${RELAYKIT_WINDOW_EQUIVALENCE_DIAGNOSTIC_TARGET:-}" == "first-ambiguity-private-visual" && "${visual_rc}" == "99" ]]; then
    cleanup_current_app
    FAILURE_REPORTED=1
    exit 0
  fi
  if [[ "${RELAYKIT_WINDOW_EQUIVALENCE_DIAGNOSTIC_TARGET:-}" == "connect-root-anchor-observations" && "${flow}" == "connect" && "${mode}" == "probe-window" && "${visual_rc}" == "100" ]]; then
    cleanup_current_app
    FAILURE_REPORTED=1
    exit 0
  fi
  if [[ "${RELAYKIT_WINDOW_EQUIVALENCE_DIAGNOSTIC_TARGET:-}" == "connect-root-public-anchor-candidates" && "${flow}" == "connect" && "${mode}" == "probe-window" && "${visual_rc}" == "101" ]]; then
    cleanup_current_app
    FAILURE_REPORTED=1
    exit 0
  fi
  if [[ "${RELAYKIT_WINDOW_EQUIVALENCE_DIAGNOSTIC_TARGET:-}" == "outside-click" && "${mode}" == "probe-window" && "${visual_rc}" == "98" ]]; then
    return 1
  fi
  return_visual_action_failure "${flow}" "${mode}" "${visual_rc}" "${phase}" "${scope}"'
[[ "${visual_swift_tail}" == "${visual_swift_expected_tail}" ]] ||
  fail "visual Swift RC must be captured immediately, then use the existing mapper; success must set its fixed stage"
if grep -Fq 'set +e' <<<"${visual_action_body}"; then fail "visual action must not disable global failure handling"; fi

run_visual_swift_stage_contract() (
  RELAYKIT_MENU_BAR_E2E_SOURCE_ONLY=1 source "${SCRIPT}"
  local flow mode phase rc swift_rc expected_rc category output_file
  output_file="$(mktemp /tmp/relaykit-visual-swift-stage-test.XXXXXX)"
  trap 'rm -f -- "${output_file}"' EXIT

  for phase in invoke success; do
    CURRENT_STAGE=bootstrap
    set_visual_swift_stage connect capture "${phase}"
    [[ "${CURRENT_STAGE}" == "flow.connect.visual-capture.swift-${phase}" ]] ||
      fail "visual Swift stage mapping lost ${phase}"
  done
  for flow in invalid-flow; do
    CURRENT_STAGE=bootstrap
    if set_visual_swift_stage "${flow}" capture invoke >"${output_file}" 2>&1; then fail "invalid visual Swift flow was accepted"; else rc="$?"; fi
    [[ "${rc}" == "2" && "${CURRENT_STAGE}" == "bootstrap" && ! -s "${output_file}" ]] ||
      fail "invalid visual Swift flow did not fail silently with rc2"
  done
  CURRENT_STAGE=bootstrap
  if set_visual_swift_stage connect invalid-mode invoke >"${output_file}" 2>&1; then fail "invalid visual Swift mode was accepted"; else rc="$?"; fi
  [[ "${rc}" == "2" && "${CURRENT_STAGE}" == "bootstrap" && ! -s "${output_file}" ]] ||
    fail "invalid visual Swift mode did not fail silently with rc2"
  CURRENT_STAGE=bootstrap
  if set_visual_swift_stage connect capture invalid-phase >"${output_file}" 2>&1; then fail "invalid visual Swift phase was accepted"; else rc="$?"; fi
  [[ "${rc}" == "2" && "${CURRENT_STAGE}" == "bootstrap" && ! -s "${output_file}" ]] ||
    fail "invalid visual Swift phase did not fail silently with rc2"

  pre_swift_process_identity() {
    set_pre_swift_identity_stage "$1" "$2" "${3:-}" success "${4:-}"
  }
  swift() { return "${swift_rc}"; }

  swift_rc=0
  CURRENT_STAGE=bootstrap
  visual_action capture connect "" /synthetic/output >"${output_file}" 2>&1
  [[ "${CURRENT_STAGE}" == "flow.connect.visual-capture.swift-success" && ! -s "${output_file}" ]] ||
    fail "visual Swift RC0 did not return silently from swift-success"

  while IFS='|' read -r swift_rc expected_rc category; do
    CURRENT_STAGE=bootstrap
    if visual_action capture connect "" /synthetic/output >"${output_file}" 2>&1; then
      fail "visual Swift RC${swift_rc} was accepted"
    else
      rc="$?"
    fi
    [[ "${rc}" == "${expected_rc}" && "${CURRENT_STAGE}" == "flow.connect.visual-capture.${category}" && ! -s "${output_file}" ]] ||
      fail "visual Swift RC${swift_rc} lost mapped RC${expected_rc}/${category} or remained at identity/invoke"
  done <<'VISUAL_SWIFT_RCS'
1|80|internal
71|71|window-identity
72|72|capture
73|73|geometry
74|74|label-contract
75|75|ocr
76|76|ocr-empty
77|77|stale-window
78|78|temp
79|79|perform
80|80|internal
81|81|duplicate-match
82|82|low-confidence
83|83|out-of-window-invalid-bounds
84|84|target-absent-current-flow
85|85|wrong-flow-anchors
86|86|nonempty-unclassified
87|87|select-text
88|88|input-text
89|89|window-missing
90|90|window-ambiguous
91|91|captureable-content-unavailable
92|92|semantic-capture-unavailable
93|93|semantic-ocr-empty
94|94|semantic-anchor-missing
95|95|semantic-anchor-duplicate
96|96|semantic-anchor-ambiguous
97|97|identity-or-geometry
VISUAL_SWIFT_RCS
)
run_visual_swift_stage_contract

grep -Fq 'visual_probe_window() {' "${SCRIPT}" || fail "captures need a no-side-effect exact-window probe"
visual_probe_body="$(sed -n '/^visual_probe_window() {/,/^}/p' "${SCRIPT}")"
grep -Fq 'visual_action probe-window "$1"' <<<"${visual_probe_body}" ||
  fail "capture readiness must reuse the exact visual window selector with its fixed context"
grep -Fq 'window_readiness_context_is_valid() {' "${SCRIPT}" || fail "window readiness needs a fixed capture-context allowlist"
grep -Fq 'set_capture_window_readiness_stage() {' "${SCRIPT}" || fail "normal captures need fixed context-bound readiness stages"
grep -Fq 'wait_for_capture_window_ready() {' "${SCRIPT}" || fail "normal captures need a bounded window-readiness wait"
capture_wait_body="$(sed -n '/^wait_for_capture_window_ready() {/,/^}/p' "${SCRIPT}")"
grep -Fq 'window_readiness_context_is_valid "${context}" || return $?' <<<"${capture_wait_body}" ||
  fail "capture window readiness must reject invalid context before probing"
grep -Fq 'for attempt in {1..120}; do' <<<"${capture_wait_body}" || fail "capture window readiness lost its 120-attempt bound"
grep -Fq 'sleep 0.05' <<<"${capture_wait_body}" || fail "capture window readiness lost its 50ms interval"
grep -Fq 'visual_probe_window "${context}"' <<<"${capture_wait_body}" || fail "capture readiness wait does not use context-bound probe-window"
if grep -Fq 'visual_click_outside' <<<"${capture_wait_body}"; then fail "capture readiness wait must not perform the visual action"; fi
grep -Fq 'wait_for_outside_window_ready() {' "${SCRIPT}" || fail "outside-click needs a bounded window-readiness wait"
outside_wait_body="$(sed -n '/^wait_for_outside_window_ready() {/,/^}/p' "${SCRIPT}")"
grep -Fq 'wait_for_capture_window_ready outside-click' <<<"${outside_wait_body}" ||
  fail "outside readiness must delegate once to the shared bounded wait"
if grep -Eq 'for attempt|sleep |visual_probe_window|visual_click_outside' <<<"${outside_wait_body}"; then
  fail "outside readiness duplicated the shared probe loop or action"
fi

probe_mode_line="$(grep -nF 'if mode == "probe-window" { exit(0) }' "${SCRIPT}" | head -1 | cut -d: -f1 || true)"
main_capture_line="$(grep -nF 'let image = try capture(frozen)' "${SCRIPT}" | head -1 | cut -d: -f1 || true)"
[[ -n "${probe_mode_line}" && -n "${main_capture_line}" && "${probe_mode_line}" -lt "${main_capture_line}" ]] ||
  fail "probe-window must exit after exact window validation and before capture"
for probe_synthetic_contract in \
  syntheticProbeSuccess \
  syntheticProbeMissing \
  syntheticProbeDuplicate \
  syntheticProbeStale \
  syntheticProbeIdentity \
  syntheticProbeGeometry \
  syntheticProbeCounts \
  syntheticOutsideCount \
  syntheticEligibilityOneValidOneInvalid \
  syntheticEligibilityTwoValid \
  syntheticEligibilityOnlyInvalid \
  syntheticInvalidWindowNumber \
  syntheticUnparseableBounds \
  syntheticZeroBounds \
  syntheticNegativeBounds \
  syntheticProbeActionParity \
  syntheticCaptureableOneOfTwo \
  syntheticCaptureableBoth \
  syntheticCaptureableNone \
  syntheticCaptureableUnavailable \
  syntheticCaptureableExternalPID \
  syntheticCaptureableProbeActionParity \
  syntheticSemanticAnchorMissing \
  syntheticSemanticAnchorDuplicate \
  syntheticSemanticAnchorAmbiguous \
  syntheticSemanticOCREmpty \
  syntheticSemanticCaptureUnavailable \
  syntheticSemanticIdentityOrGeometry \
  syntheticSemanticRealQuit \
  syntheticSemanticFlowAnchorMatrix \
  syntheticSemanticProbeActionParity \
  syntheticSemanticProbeCounts \
  syntheticEquivalenceAllEqual \
  syntheticEquivalenceEachFalse \
  syntheticEquivalenceInvalidCardinality \
  syntheticEquivalenceStale \
  syntheticEquivalenceSchemaPrivacy \
  syntheticEquivalenceInvalidReasons \
  syntheticEquivalenceUnknownFallback \
  syntheticEquivalenceValidNoReason \
  syntheticEquivalenceZeroInvalid \
  syntheticEquivalenceOneInvalid \
  syntheticEquivalenceTwoAllEqual \
  syntheticEquivalenceThreeAllEqual \
  syntheticEquivalenceThreeEachFalse \
  syntheticEquivalenceMemberStale \
  syntheticEquivalencePermutationInvariant; do
  grep -Fq "${probe_synthetic_contract}" "${SCRIPT}" || fail "visual synthetic contract lacks ${probe_synthetic_contract}"
done
grep -Fq 'func eligibleWindowIdentities(' "${SCRIPT}" || fail "probe/action need one shared exact window eligibility filter"
grep -Fq 'func captureableEligibleWindowIdentities(' "${SCRIPT}" ||
  fail "probe/action need one shared eligible-intersect-captureable filter"
grep -Fq 'func captureableWindowIDs() throws -> Set<CGWindowID>' "${SCRIPT}" ||
  fail "window selection needs one read-only ScreenCaptureKit captureable-id source"
grep -Fq 'SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)' "${SCRIPT}" ||
  fail "captureable-id source must use on-screen non-desktop ScreenCaptureKit content"
grep -Fq 'func selectedCaptureableWindowInfo(pid:' "${SCRIPT}" ||
  fail "probe/action need one shared captureable window selector"
grep -Fq 'func semanticAnchor(flow: String) throws -> String' "${SCRIPT}" ||
  fail "semantic selector needs a fixed caller-independent flow anchor mapping"
grep -Fq 'func selectedSemanticWindowInfo(pid:' "${SCRIPT}" ||
  fail "probe/action need one shared semantic window selector"
for eligibility_contract in \
  'kCGWindowOwnerPID' \
  'kCGWindowIsOnscreen' \
  'kCGWindowNumber' \
  'number.uint32Value != 0' \
  'kCGWindowBounds' \
  'CGRect(dictionaryRepresentation:' \
  'bounds.width > 0, bounds.height > 0'; do
  grep -Fq "${eligibility_contract}" "${SCRIPT}" || fail "shared window eligibility lacks ${eligibility_contract}"
done
window_info_body="$(sed -n '/^func windowInfo(pid:/,/^}/p' "${SCRIPT}")"
probe_window_info_body="$(sed -n '/^func probeWindowInfo(pid:/,/^}/p' "${SCRIPT}")"
shared_captureable_selector_body="$(sed -n '/^func selectedCaptureableWindowInfo(pid:/,/^}/p' "${SCRIPT}")"
shared_semantic_selector_body="$(sed -n '/^func selectedSemanticWindowInfo(pid:/,/^}/p' "${SCRIPT}")"
semantic_candidates_body="$(sed -n '/^func semanticCandidates(pid:/,/^}/p' "${SCRIPT}")"
production_semantic_selector_body="$(sed -n '/^func selectSemanticWindow(/,/^}/p' "${SCRIPT}")"
grep -Fq 'return try selectedSemanticWindowInfo(pid: pid, expectedExecutable: expectedExecutable, flow: semanticFlowContext)' <<<"${window_info_body}" ||
  fail "action windowInfo does not delegate to the shared semantic selector"
grep -Fq 'return try selectedSemanticWindowInfo(pid: pid, expectedExecutable: expectedExecutable, flow: semanticFlowContext)' <<<"${probe_window_info_body}" ||
  fail "probe windowInfo does not delegate to the shared semantic selector"
grep -Fq 'eligibleWindowIdentities(' <<<"${shared_captureable_selector_body}" ||
  fail "shared captureable selector does not preserve exact CG eligibility"
grep -Fq 'captureableEligibleWindowIdentities(' <<<"${shared_captureable_selector_body}" ||
  fail "shared selector does not intersect CG eligibility with captureable IDs"
grep -Fq 'captureableWindowIDs()' <<<"${shared_captureable_selector_body}" ||
  fail "shared selector does not obtain read-only ScreenCaptureKit IDs"
grep -Fq 'selectEligibleWindow(' <<<"${shared_captureable_selector_body}" ||
  fail "shared captureable selector does not preserve 0/1/>1 selection"
grep -Fq 'selectedCaptureableWindowInfo(' <<<"${shared_semantic_selector_body}" &&
  fail "semantic selector must not fall back to the pre-semantic selector"
grep -Fq 'semanticAnchor(flow: flow)' <<<"${shared_semantic_selector_body}" ||
  fail "semantic selector does not derive its fixed anchor from the validated flow"
grep -Fq 'semanticCandidates(' <<<"${shared_semantic_selector_body}" ||
  fail "semantic selector does not use the shared exact-candidate collector"
grep -Fq 'captureSemanticCandidate(' <<<"${semantic_candidates_body}" ||
  fail "semantic selector does not inspect every exact captureable candidate in memory"
grep -Fq 'selectSemanticWindow(' <<<"${shared_semantic_selector_body}" ||
  fail "semantic selector does not apply shared exact-anchor cardinality"
for strict_profile_selector_contract in \
  'surfaceProfile(flow: semanticFlowContext, mode: semanticVisualModeContext)' \
  'case .connectRoot, .outsidePopover:' \
  'requiredAnchors(for: profile)' \
  'candidateMatchesAllRequiredExactAnchors' \
  'throw VisualFailure.semanticAnchorMissing' \
  'throw VisualFailure.semanticAnchorAmbiguous' \
  'semanticMatches(candidates, anchor: anchor)'; do
  grep -Fq "${strict_profile_selector_contract}" <<<"${production_semantic_selector_body}" ||
    fail "production strict public profile selector lacks ${strict_profile_selector_contract}"
done
if grep -Eq 'semanticCandidates\(|captureSemanticCandidate\(|recognizedText\(|capture\(|sleep|usleep|CGEvent|contains|localizedCaseInsensitiveContains|sorted|sort\(|largest|title|layer|alpha' <<<"${production_semantic_selector_body}"; then
  fail "production strict public profile selector adds work, retry, fuzzy matching, or heuristics"
fi
if grep -Eq 'items\.count|raw\.count|kCGWindowAlpha|kCGWindowLayer|kCGWindowName|kCGWindowOwnerName|largest|shadow|title' <<<"${window_info_body}${probe_window_info_body}"; then
  fail "probe/action window selection retained raw-count uniqueness or heuristic filtering"
fi
if grep -Eq '\.title|owningApplication|kCGWindowAlpha|kCGWindowLayer|kCGWindowName|kCGWindowOwnerName|largest|shadow' <<<"${shared_captureable_selector_body}"; then
  fail "captureable selector reads content metadata or uses an unreviewed heuristic"
fi
captureable_ids_body="$(sed -n '/^func captureableWindowIDs() throws -> Set<CGWindowID>/,/^}/p' "${SCRIPT}")"
if grep -Eq '\.title|owningApplication|SCScreenshotManager|CGEvent|writePNG|createFile' <<<"${captureable_ids_body}"; then
  fail "captureable-id probe reads content metadata or creates capture/write/event side effects"
fi
semantic_selector_region="$(sed -n '/^func semanticAnchor(flow:/,/^func windowInfo(pid:/p' "${SCRIPT}")"
if grep -Eq 'writePNG|createFile|withTemporaryCapture|CGEvent|\.title|owningApplication|kCGWindowAlpha|kCGWindowLayer|kCGWindowName|kCGWindowOwnerName|largest|shadow|text[^\n]*contains|localizedCaseInsensitiveContains' <<<"${semantic_selector_region}"; then
  fail "semantic selector uses temp/output/events, metadata, fuzzy matching, or a heuristic"
fi

grep -Fq 'import CryptoKit' "${SCRIPT}" || fail "window equivalence diagnostic needs in-memory SHA-256"
grep -Fq 'func windowEquivalenceDiagnostic(' "${SCRIPT}" || fail "window equivalence diagnostic implementation is missing"
grep -Fq 'func windowEquivalenceDiagnosticSchema(' "${SCRIPT}" || fail "window equivalence diagnostic fixed schema formatter is missing"
grep -Fq 'func allCandidateWindowEquivalence(' "${SCRIPT}" ||
  fail "window equivalence diagnostic needs one all-candidate aggregate"
grep -Fq 'enum WindowEquivalenceInvalidReason: String, CaseIterable' "${SCRIPT}" ||
  fail "window equivalence invalid diagnostic needs a fixed reason enum"
grep -Fq 'func windowEquivalenceInvalidSchema(reason:' "${SCRIPT}" ||
  fail "window equivalence invalid diagnostic needs a fixed temporal formatter"
grep -Fq 'enum SemanticMatchBucket' "${SCRIPT}" ||
  fail "temporal diagnostic needs internal zero/one/multiple buckets"
grep -Fq 'struct TemporalSemanticState' "${SCRIPT}" ||
  fail "temporal diagnostic needs fixed observation state"
grep -Fq 'func temporalWindowEquivalenceDiagnostic(' "${SCRIPT}" ||
  fail "temporal diagnostic sampler is missing"
equivalence_region="$(sed -n '/^func rgbaData/,/^func windowInfo(pid:/p' "${SCRIPT}")"
equivalence_reason_enum="$(sed -n '/^enum WindowEquivalenceInvalidReason:/,/^}/p' "${SCRIPT}")"
all_candidate_equivalence_body="$(sed -n '/^func allCandidateWindowEquivalence(/,/^}/p' "${SCRIPT}")"
grep -Fq 'dropFirst()' <<<"${all_candidate_equivalence_body}" ||
  fail "all-candidate equivalence must use the first candidate as reference"
[[ "$(grep -Fc 'allSatisfy' <<<"${all_candidate_equivalence_body}")" -ge 7 ]] ||
  fail "all-candidate equivalence does not aggregate all seven predicates across every remaining candidate"
if grep -Eq 'sorted|sort\(|windowID|largest|title|layer|alpha' <<<"${all_candidate_equivalence_body}"; then
  fail "all-candidate equivalence introduced canonical selection, sorting, or metadata heuristics"
fi
if grep -Fq 'exactEquivalencePair' "${SCRIPT}"; then
  fail "two-candidate-only equivalence helper must not remain"
fi
for equivalence_field in \
  same_point_bounds \
  same_pixel_dimensions \
  same_pixel_sha256 \
  same_exact_anchor_normalized_bbox \
  same_absolute_anchor_center \
  same_backing_scale \
  all_revalidate_stable; do
  grep -Fq "${equivalence_field}" <<<"${equivalence_region}" || fail "window equivalence schema lacks ${equivalence_field}"
done
for temporal_field in saw_zero saw_one saw_multiple saw_transition; do
  grep -Fq "${temporal_field}" <<<"${equivalence_region}" || fail "window equivalence schema lacks ${temporal_field}"
done
for invalid_reason in \
  semantic-candidate-cardinality \
  semantic-multiple-not-observed \
  captureable-content-unavailable \
  semantic-capture-unavailable \
  semantic-ocr-empty \
  semantic-anchor-missing \
  semantic-anchor-duplicate \
  identity-or-geometry \
  revalidation-failed \
  internal; do
  grep -Fq "${invalid_reason}" <<<"${equivalence_reason_enum}" || fail "window equivalence invalid reason enum lacks ${invalid_reason}"
done
if grep -Eq 'writePNG|createFile|withTemporaryCapture|CGEvent|\.title|owningApplication|print\([^\n]*(windowID|bounds|digest|count|text|pixel)' <<<"${equivalence_region}"; then
  fail "window equivalence diagnostic writes files/events or emits private diagnostic values"
fi
grep -Fq 'RELAYKIT_MENU_BAR_WINDOW_EQUIVALENCE_DIAGNOSTIC' "${SCRIPT}" ||
  fail "window equivalence diagnostic needs a fixed environment entry"
if grep -Eq '^run_window_equivalence_diagnostic\(\)|^visual_window_equivalence_diagnostic\(\)|visual_action window-equivalence-diagnostic|"window-equivalence-diagnostic"' "${SCRIPT}"; then
  fail "independent window equivalence runner or visual mode survived"
fi
capture_body="$(sed -n '/^capture() {/,/^}/p' "${SCRIPT}")"
diagnostic_inline_body="$(sed -n '/RELAYKIT_MENU_BAR_WINDOW_EQUIVALENCE_DIAGNOSTIC:-0/,/wait_for_capture_window_ready "${name}"/p' <<<"${capture_body}")"
[[ "$(grep -Fc 'if [[ "${RELAYKIT_MENU_BAR_WINDOW_EQUIVALENCE_DIAGNOSTIC:-0}" == "1" ]]' <<<"${capture_body}")" == "1" ]] ||
  fail "window equivalence diagnostic must enter the first normal connect capture inline"
grep -Fq '[[ "${name}" == "connect" ]] || return 2' <<<"${diagnostic_inline_body}" ||
  fail "inline window equivalence diagnostic must fail closed outside connect"
[[ "$(grep -Fc 'if visual_probe_window "${name}"; then' <<<"${diagnostic_inline_body}")" == "1" ]] ||
  fail "inline window equivalence diagnostic must invoke the normal semantic probe exactly once"
for inline_contract in \
  'diagnostic_rc=0' \
  'diagnostic_rc="$?"' \
  'set_stage capture.connect.window-equivalence-diagnostic-complete' \
  'cleanup_current_app' \
  'FAILURE_REPORTED=1' \
  'exit "${diagnostic_rc}"'; do
  grep -Fq "${inline_contract}" <<<"${diagnostic_inline_body}" ||
    fail "inline window equivalence diagnostic lacks ${inline_contract}"
done
diagnostic_stage_line="$(grep -nF 'set_capture_window_readiness_stage "${name}"' <<<"${capture_body}" | cut -d: -f1)"
diagnostic_entry_line="$(grep -nF 'if [[ "${RELAYKIT_MENU_BAR_WINDOW_EQUIVALENCE_DIAGNOSTIC:-0}" == "1" ]]' <<<"${capture_body}" | cut -d: -f1)"
diagnostic_probe_line="$(grep -nF 'if visual_probe_window "${name}"; then' <<<"${capture_body}" | cut -d: -f1)"
diagnostic_exit_line="$(grep -nF 'exit "${diagnostic_rc}"' <<<"${capture_body}" | cut -d: -f1)"
diagnostic_wait_line="$(grep -nF 'wait_for_capture_window_ready "${name}"' <<<"${capture_body}" | cut -d: -f1)"
((diagnostic_stage_line < diagnostic_entry_line && diagnostic_entry_line < diagnostic_probe_line &&
  diagnostic_probe_line < diagnostic_exit_line && diagnostic_exit_line < diagnostic_wait_line)) ||
  fail "inline diagnostic must use the first normal selector then exit before readiness retry/full capture"
inline_swift_diagnostic="$(sed -n '/^if mode == "probe-window",/,/exit(diagnostic.exitCode)/p' "${SCRIPT}")"
grep -Fq 'mode == "probe-window"' <<<"${inline_swift_diagnostic}" ||
  fail "Swift diagnostic must reuse the normal probe-window selector invocation"
grep -Fq 'diagnostic = temporalWindowEquivalenceDiagnostic(' <<<"${inline_swift_diagnostic}" ||
  fail "inline diagnostic must invoke the bounded temporal sampler"
equivalence_evaluator_body="$(sed -n '/^func windowEquivalenceDiagnostic(/,/^}/p' "${SCRIPT}")"
if grep -Eq 'semanticCandidates\(|captureSemanticCandidate\(' <<<"${equivalence_evaluator_body}"; then
  fail "pure equivalence evaluation requeries or recaptures candidates"
fi
temporal_sampler_body="$(sed -n '/^func temporalWindowEquivalenceDiagnostic(/,/^}/p' "${SCRIPT}")"
for sampler_contract in \
  'for sample in 0..<120' \
  'kill(pid, 0) == 0' \
  'let candidates = try semanticCandidates(pid: pid, expectedExecutable: expectedExecutable)' \
  'state.record(matches.count)' \
  'candidates: candidates' \
  'usleep(50_000)' \
  'invalidWindowEquivalenceDiagnostic(.semanticMultipleNotObserved, temporal: state)'; do
  grep -Fq "${sampler_contract}" <<<"${temporal_sampler_body}" ||
    fail "temporal sampler lacks ${sampler_contract}"
done
[[ "$(grep -Fc 'semanticCandidates(pid: pid, expectedExecutable: expectedExecutable)' <<<"${temporal_sampler_body}")" == "1" ]] ||
  fail "each temporal sample must perform one semantic candidate query"
temporal_multiple_line="$(grep -nF 'if matches.count >= 2 {' <<<"${temporal_sampler_body}" | cut -d: -f1 || true)"
temporal_evaluate_line="$(grep -nF 'candidates: candidates' <<<"${temporal_sampler_body}" | cut -d: -f1 || true)"
temporal_sleep_line="$(grep -nF 'usleep(50_000)' <<<"${temporal_sampler_body}" | cut -d: -f1 || true)"
[[ -n "${temporal_multiple_line}" && -n "${temporal_evaluate_line}" && -n "${temporal_sleep_line}" &&
   "${temporal_multiple_line}" -lt "${temporal_evaluate_line}" && "${temporal_evaluate_line}" -lt "${temporal_sleep_line}" ]] ||
  fail "first multiple must evaluate the same captured set before any next-sample sleep"
if grep -Eq 'CGEvent|writePNG|createFile|withTemporaryCapture|print\(' <<<"${temporal_sampler_body}"; then
  fail "temporal sampler emits output or creates events/temp files"
fi
if grep -Eq 'specific-jq|visual_click|visual_capture_window|screenshot.capture' <<<"${diagnostic_inline_body}"; then
  fail "inline diagnostic continues into specific predicates, actions, or screenshots"
fi
grep -Fq 'FAILURE_REPORTED=1' "${SCRIPT}" ||
  fail "invalid diagnostic must suppress the unrelated generic failure line while preserving nonzero RC"
run_window_equivalence_invalid_rc_contract() (
  RELAYKIT_MENU_BAR_E2E_SOURCE_ONLY=1 source "${SCRIPT}"
  local output output_file rc
  output_file="$(mktemp /tmp/relaykit-window-equivalence-invalid-test.XXXXXX)"
  trap 'rm -f -- "${output_file}"' EXIT
  visual_action() {
    printf '%s\n' \
      'DIAG_VALID=false' \
      'DIAG_REASON=semantic-multiple-not-observed' \
      'saw_zero=true' \
      'saw_one=true' \
      'saw_multiple=false' \
      'saw_transition=true'
    return 1
  }
  if visual_probe_window connect >"${output_file}" 2>&1; then rc=0; else rc="$?"; fi
  output="$(<"${output_file}")"
  [[ "${rc}" == "1" && "${output}" == $'DIAG_VALID=false\nDIAG_REASON=semantic-multiple-not-observed\nsaw_zero=true\nsaw_one=true\nsaw_multiple=false\nsaw_transition=true' ]] ||
    fail "invalid diagnostic did not preserve exact fixed temporal schema and nonzero RC"
)
run_window_equivalence_invalid_rc_contract
grep -Fq 'window_equivalence_diagnostic_target_is_valid() {' "${SCRIPT}" ||
  fail "outside equivalence diagnostic needs a fixed target allowlist"
run_outside_equivalence_target_contract() (
  RELAYKIT_MENU_BAR_E2E_SOURCE_ONLY=1 source "${SCRIPT}"
  local target rc output
  for target in "" outside-click first-ambiguity first-ambiguity-private-visual connect-root-anchor-observations connect-root-public-anchor-candidates; do
    window_equivalence_diagnostic_target_is_valid "${target}" ||
      fail "reviewed outside equivalence target ${target:-empty} was rejected"
  done
  for target in connect arbitrary-target; do
    if output="$(window_equivalence_diagnostic_target_is_valid "${target}" 2>&1)"; then rc=0; else rc="$?"; fi
    [[ "${rc}" == "2" && -z "${output}" ]] ||
      fail "unreviewed outside equivalence target ${target} did not fail silently with rc2"
  done
)
run_outside_equivalence_target_contract
grep -Fq 'case "${RELAYKIT_WINDOW_EQUIVALENCE_DIAGNOSTIC_TARGET:-}" in' "${SCRIPT}" ||
  fail "outside equivalence target is not validated before runtime launch"
grep -Fq 'func outsideWindowEquivalenceDiagnostic(' "${SCRIPT}" ||
  fail "outside equivalence same-set evaluator is missing"
grep -Fq 'func outsideWindowEquivalenceDiagnosticSchema(' "${SCRIPT}" ||
  fail "outside equivalence exact-seven schema is missing"
outside_equivalence_schema_body="$(sed -n '/^func outsideWindowEquivalenceDiagnosticSchema(/,/^}/p' "${SCRIPT}")"
for outside_schema_field in \
  same_point_bounds same_pixel_dimensions same_pixel_sha256 same_exact_anchor_normalized_bbox \
  same_absolute_anchor_center same_backing_scale all_revalidate_stable; do
  [[ "$(grep -Fc "${outside_schema_field}" <<<"${outside_equivalence_schema_body}")" == "1" ]] ||
    fail "outside equivalence schema lost exact field ${outside_schema_field}"
done
grep -Fq '"DIAG_VALID=true"' <<<"${outside_equivalence_schema_body}" ||
  fail "outside equivalence valid schema lacks its fixed validity marker"
if grep -Eq 'saw_zero|saw_one|saw_multiple|saw_transition|DIAG_REASON' <<<"${outside_equivalence_schema_body}"; then
  fail "outside equivalence exact-seven schema leaked temporal or invalid fields"
fi
outside_equivalence_body="$(sed -n '/^func outsideWindowEquivalenceDiagnostic(/,/^}/p' "${SCRIPT}")"
for outside_equivalence_contract in \
  'let matches = try semanticMatches(candidates, anchor: anchor)' \
  'guard matches.count > 1 else' \
  'outsideSemanticAmbiguityNotObserved' \
  'allCandidateWindowEquivalence(observations)' \
  'outsideWindowEquivalenceDiagnosticSchema(result)'; do
  grep -Fq "${outside_equivalence_contract}" <<<"${outside_equivalence_body}" ||
    fail "outside equivalence evaluator lacks ${outside_equivalence_contract}"
done
if grep -Eq 'semanticCandidates\(|captureSemanticCandidate\(|allSemanticWindowsStable\(|sleep|usleep|CGEvent|writePNG|createFile|print\(' <<<"${outside_equivalence_body}"; then
  fail "outside equivalence evaluator requeries, recaptures, waits, acts, writes, or emits dynamic output"
fi
outside_inline_swift="$(sed -n '/if mode == "probe-window", flow == "outside-click",/,/exit(diagnostic.exitCode == 0 ? 0 : 98)/p' "${SCRIPT}")"
[[ "$(grep -Fc 'let candidates = try semanticCandidates(pid: pid, expectedExecutable: expectedExecutable)' <<<"${outside_inline_swift}")" == "1" ]] ||
  fail "first outside selector must compute one semantic candidate set"
grep -Fq 'outsideWindowEquivalenceDiagnostic(candidates: candidates' <<<"${outside_inline_swift}" ||
  fail "outside diagnostic must evaluate the same already-computed candidate set"
for forbidden_outside_output in windowID bounds digest count text pixel; do
  if grep -Eq "print\([^\n]*${forbidden_outside_output}" <<<"${outside_inline_swift}${outside_equivalence_body}"; then
    fail "outside equivalence diagnostic emits private ${forbidden_outside_output} data"
  fi
done
grep -Fq 'case outsideSemanticAmbiguityNotObserved = "outside-semantic-ambiguity-not-observed"' "${SCRIPT}" ||
  fail "outside missing/unique diagnostic reason is not fixed"
grep -Fq 'case semanticAmbiguityNotObserved = "semantic-ambiguity-not-observed"' "${SCRIPT}" ||
  fail "full successful run without ambiguity lacks a fixed reason"
grep -Fq 'func firstAmbiguityWindowEquivalenceDiagnostic(' "${SCRIPT}" ||
  fail "first-ambiguity same-set evaluator is missing"
grep -Fq 'private_visual_diagnostic_dir_is_valid() {' "${SCRIPT}" ||
  fail "private ambiguity visual diagnostic needs a strict prelaunch directory guard"
grep -Fq 'func writePrivateAmbiguityPNGs(' "${SCRIPT}" ||
  fail "private ambiguity visual diagnostic needs same-candidate PNG serialization"
private_visual_dir_guard_body="$(sed -n '/^private_visual_diagnostic_dir_is_valid()/,/^}/p' "${SCRIPT}")"
for private_dir_guard_contract in \
  '"${directory}" == /*' \
  'relaykit-window-diag.*' \
  '[[ -d "${directory}" && ! -L "${directory}" ]]' \
  '[[ -d "${parent}" && ! -L "${parent}" ]]' \
  'pwd -P' \
  '/usr/bin/stat -f '\''%u'\''' \
  '/usr/bin/stat -f '\''%Lp'\''' \
  '$(/usr/bin/id -u)' \
  '"${mode}" == "700"' \
  'find "${directory}" -mindepth 1 -maxdepth 1 -print -quit'; do
  grep -Fq "${private_dir_guard_contract}" <<<"${private_visual_dir_guard_body}" ||
    fail "private visual prelaunch directory guard lacks ${private_dir_guard_contract}"
done
if grep -Eq 'echo|printf' <<<"${private_visual_dir_guard_body}"; then
  fail "private visual prelaunch directory guard emits output"
fi
grep -Fq 'enum AmbiguityMode: String, CaseIterable' "${SCRIPT}" ||
  fail "first-ambiguity diagnostic needs a fixed public mode enum"
grep -Fq 'func ambiguityTargetDiscriminability(' "${SCRIPT}" ||
  fail "first-ambiguity target discriminability calculator is missing"
grep -Fq 'func firstAmbiguityWindowEquivalenceDiagnosticSchema(' "${SCRIPT}" ||
  fail "first-ambiguity diagnostic schema formatter is missing"
grep -Fq 'enum SurfaceProfile: String, CaseIterable' "${SCRIPT}" ||
  fail "first-ambiguity diagnostic needs a fixed surface profile enum"
grep -Fq 'func surfaceProfile(flow:' "${SCRIPT}" ||
  fail "surface profile needs a fixed flow/mode context mapper"
grep -Fq 'func requiredAnchors(for profile:' "${SCRIPT}" ||
  fail "surface profile fixed anchor table is missing"
grep -Fq 'func requiredAlternativeGroups(for profile:' "${SCRIPT}" ||
  fail "surface profile fixed alternative-group table is missing"
grep -Fq 'func surfaceProfileDiscriminability(' "${SCRIPT}" ||
  fail "surface profile discriminability calculator is missing"
surface_profile_enum="$(sed -n '/^enum SurfaceProfile:/,/^}/p' "${SCRIPT}")"
for profile in connect-root official-sheet provider-form usage-root settings-root outside-popover real-quit unsupported; do
  grep -Fq "= \"${profile}\"" <<<"${surface_profile_enum}" || fail "surface profile enum lacks ${profile}"
done
surface_profile_mapping_body="$(sed -n '/^func surfaceProfile(flow:/,/^}/p' "${SCRIPT}")"
for mapping_contract in \
  'case "connect": return .connectRoot' \
  'case "official-sheet", "official-light", "official-dark":' \
  'case "probe-window", "click-text": return .connectRoot' \
  'case "capture": return .officialSheet' \
  'case "provider-click-flow", "provider-light", "provider-dark", "provider-test-failure",' \
  '"detail", "detail-advanced-expanded", "detail-advanced-collapsed", "provider":' \
  'return .providerForm' \
  'case "usage", "usage-auto-refresh", "usage-large", "usage-1m", "usage-1y", "usage-empty", "usage-light", "usage-dark":' \
  'case "settings", "settings-developer-expanded", "settings-light", "settings-dark":' \
  'case "outside-click": return .outsidePopover' \
  'case "real-quit": return .realQuit' \
  'default: return .unsupported'; do
  grep -Fq "${mapping_contract}" <<<"${surface_profile_mapping_body}" ||
    fail "surface profile context map lacks ${mapping_contract}"
done
surface_profile_table_body="$(sed -n '/^func requiredAnchors(for profile:/,/^}/p' "${SCRIPT}")"
for profile_anchor_row in \
  'connectRoot|["RelayKit", "Usage"]' \
  'officialSheet|["AUTH", "OpenAI Official", "Codex Official"]' \
  'providerForm|["Test connection", "Advanced"]' \
  'usageRoot|["RelayKit", "Usage", "Today tokens"]' \
  'settingsRoot|["RelayKit", "Developer / Diagnostics"]' \
  'outsidePopover|["RelayKit", "Usage"]' \
  'realQuit|["Quit RelayKit"]' \
  'unsupported|[]'; do
  profile="${profile_anchor_row%%|*}"
  anchors="${profile_anchor_row#*|}"
  grep -Fq "case .${profile}: return ${anchors}" <<<"${surface_profile_table_body}" ||
    fail "surface profile anchor table drifted for ${profile}"
done
if grep -Eq 'connectRoot.*OpenAI Official / Codex Official|outsidePopover.*OpenAI Official / Codex Official' <<<"${surface_profile_table_body}"; then
  fail "connect/outside strict profile retained the old combined Official anchor"
fi
surface_profile_group_body="$(sed -n '/^func requiredAlternativeGroups(for profile:/,/^}/p' "${SCRIPT}")"
grep -Fq 'return []' <<<"${surface_profile_group_body}" ||
  fail "surface profiles do not retain an empty alternative-group table"
if grep -Eq 'connectRoot|outsidePopover|OpenAI Official|Codex Official' <<<"${surface_profile_group_body}"; then
  fail "connect/outside diagnostic table retained an alternative group"
fi
diagnostic_surface_allowlist_body="$(sed -n '/^func diagnosticSurfaceAnchorIsAllowlisted(/,/^}/p' "${SCRIPT}")"
for alternative in 'OpenAI Official / Codex Official' 'OpenAI Official' 'Codex Official'; do
  grep -Fq "\"${alternative}\"" <<<"${diagnostic_surface_allowlist_body}" ||
    fail "diagnostic-only surface allowlist lacks exact public anchor ${alternative}"
done
allowed_action_body="$(sed -n '/^func allowed(label:/,/^}/p' "${SCRIPT}")"
grep -Fq '"OpenAI Official / Codex Official"' <<<"${allowed_action_body}" ||
  fail "surface diagnostic change modified the existing combined action label allowlist"
surface_alternative_match_body="$(sed -n '/^func candidateSatisfiesAllRequiredAlternativeGroups(/,/^}/p' "${SCRIPT}")"
for alternative_contract in \
  '$0.text == alternative' \
  '$0.confidence >= 0.80' \
  'matching.count == 1' \
  'group.contains(where:'; do
  grep -Fq "${alternative_contract}" <<<"${surface_alternative_match_body}" ||
    fail "surface alternative-group matcher lacks ${alternative_contract}"
done
if grep -Eq 'text\.contains|localizedCaseInsensitiveContains|joined|fuzzy|recognizedText\(|capture\(' <<<"${surface_alternative_match_body}"; then
  fail "surface alternative-group matcher changed OCR or uses fuzzy/substring/joined matching"
fi
surface_profile_discriminability_body="$(sed -n '/^func surfaceProfileDiscriminability(/,/^}/p' "${SCRIPT}")"
for surface_contract in \
  'diagnosticSurfaceAnchorIsAllowlisted' \
  'candidateMatchesAllRequiredExactAnchors' \
  'candidateSatisfiesAllRequiredAlternativeGroups' \
  'matchingCandidates.count == 1' \
  'matchingCandidates.count > 1' \
  'allRequiredAnchorsAllowlisted' \
  'exactlyOneCandidateMatchesAllRequiredExactAnchors' \
  'otherCandidatesMatchAll' \
  'profileHasRequiredAlternativeGroup' \
  'atLeastOneCandidateSatisfiesAllRequiredAlternativeGroups'; do
  grep -Fq "${surface_contract}" <<<"${surface_profile_discriminability_body}" ||
    fail "surface profile discriminability lacks ${surface_contract}"
done
if grep -Eq 'semanticCandidates\(|captureSemanticCandidate\(|recognizedText\(|capture\(|sleep|usleep|CGEvent|writePNG|createFile|print\(' <<<"${surface_profile_discriminability_body}"; then
  fail "surface profile discriminability requeries, recaptures, OCRs, waits, acts, writes, or emits dynamic output"
fi
ambiguity_discriminability_body="$(sed -n '/^func ambiguityTargetDiscriminability(/,/^}/p' "${SCRIPT}")"
for discriminability_contract in \
  'mode == .clickText || mode == .typeText' \
  'allowed(label: label, flow: flow)' \
  'candidateTargetCounts.filter { $0 == 1 }' \
  'candidateTargetCounts.enumerated().contains' \
  'exactlyOneCandidateHasUniqueExactTarget' \
  'otherCandidatesHaveTarget'; do
  grep -Fq "${discriminability_contract}" <<<"${ambiguity_discriminability_body}" ||
    fail "first-ambiguity discriminability lacks ${discriminability_contract}"
done
if grep -Eq 'semanticCandidates\(|captureSemanticCandidate\(|recognizedText\(|capture\(|sleep|usleep|CGEvent|writePNG|createFile|print\(' <<<"${ambiguity_discriminability_body}"; then
  fail "target discriminability requeries, recaptures, waits, acts, writes, or emits dynamic output"
fi
first_ambiguity_schema_body="$(sed -n '/^func firstAmbiguityWindowEquivalenceDiagnosticSchema(/,/^}/p' "${SCRIPT}")"
for discriminator_field in \
  AMBIGUITY_MODE target_label_applicable current_target_allowlisted \
  exactly_one_candidate_has_unique_exact_target other_candidates_have_target \
  SURFACE_PROFILE all_required_anchors_allowlisted \
  exactly_one_candidate_matches_all_required_exact_anchors other_candidates_match_all \
  profile_has_required_alternative_group \
  at_least_one_candidate_satisfies_all_required_alternative_groups; do
  [[ "$(grep -Fc "${discriminator_field}" <<<"${first_ambiguity_schema_body}")" == "1" ]] ||
    fail "first-ambiguity schema lost fixed field ${discriminator_field}"
done
for equivalence_field in \
  same_point_bounds same_pixel_dimensions same_pixel_sha256 same_exact_anchor_normalized_bbox \
  same_absolute_anchor_center same_backing_scale all_revalidate_stable; do
  [[ "$(grep -Fc "${equivalence_field}" <<<"${first_ambiguity_schema_body}")" == "1" ]] ||
    fail "first-ambiguity schema lost exact equivalence field ${equivalence_field}"
done
if grep -Eq '\\\(flow|\\\(label|windowID|window_count|ocr_text' <<<"${first_ambiguity_schema_body}"; then
  fail "first-ambiguity schema emits flow, label, count, or window metadata"
fi
for private_schema_value in 'RelayKit' 'OpenAI Official' 'AUTH' 'Test connection' 'Usage' 'Today tokens' 'Developer / Diagnostics' 'Quit RelayKit'; do
  if grep -Fq "${private_schema_value}" <<<"${first_ambiguity_schema_body}"; then
    fail "first-ambiguity schema emits a required anchor"
  fi
done
first_ambiguity_evaluator="$(sed -n '/^func firstAmbiguityWindowEquivalenceDiagnostic(/,/^}/p' "${SCRIPT}")"
for first_ambiguity_contract in \
  'let matches = try semanticMatches(candidates, anchor: anchor)' \
  'guard matches.count > 1 else' \
  'allCandidateWindowEquivalence(observations)' \
  'ambiguityTargetDiscriminability(candidates: candidates, mode: mode, flow: flow, label: label)' \
  'surfaceProfileDiscriminability(candidates: candidates, mode: mode, flow: flow)' \
  'firstAmbiguityWindowEquivalenceDiagnosticSchema(result, discriminability: discriminability, surface: surface)' ; do
  grep -Fq "${first_ambiguity_contract}" <<<"${first_ambiguity_evaluator}" ||
    fail "first-ambiguity evaluator lacks ${first_ambiguity_contract}"
done
if grep -Eq 'semanticCandidates\(|captureSemanticCandidate\(|allSemanticWindowsStable\(|sleep|usleep|CGEvent|writePNG|createFile|print\(' <<<"${first_ambiguity_evaluator}"; then
  fail "first-ambiguity evaluator requeries, recaptures, waits, acts, writes, or emits dynamic output"
fi
anchor_observation_calculator="$(sed -n '/^func connectRootAnchorObservationDiagnostic(/,/^}/p' "${SCRIPT}")"
anchor_observation_schema="$(sed -n '/^func connectRootAnchorObservationSchema(/,/^}/p' "${SCRIPT}")"
for observation_contract in \
  'exactObservationSeen' \
  'confidenceThresholdSeen' \
  'geometryValidSeen' \
  'validHitCardinality' \
  'sameCandidateRelayKitAndCombinedValid' \
  'sameCandidateRelayKitAndOpenAIOfficialValid' \
  'sameCandidateRelayKitAndCodexOfficialValid' \
  'sameCandidateRelayKitAndBothSplitOfficialValid'; do
  grep -Fq "${observation_contract}" <<<"${anchor_observation_calculator}${anchor_observation_schema}" ||
    fail "connect-root anchor observation diagnostic lacks ${observation_contract}"
done
for fixed_cardinality in zero one multiple-candidates duplicate-within-candidate mixed; do
  grep -Fq "= \"${fixed_cardinality}\"" "${SCRIPT}" ||
    fail "anchor observation diagnostic lacks fixed cardinality ${fixed_cardinality}"
done
for schema_key in \
  connect_root_profile_cardinality \
  relaykit_exact_observation_seen relaykit_confidence_threshold_seen relaykit_geometry_valid_seen relaykit_valid_hit_cardinality \
  combined_official_exact_observation_seen combined_official_confidence_threshold_seen combined_official_geometry_valid_seen combined_official_valid_hit_cardinality \
  openai_official_exact_observation_seen openai_official_confidence_threshold_seen openai_official_geometry_valid_seen openai_official_valid_hit_cardinality \
  codex_official_exact_observation_seen codex_official_confidence_threshold_seen codex_official_geometry_valid_seen codex_official_valid_hit_cardinality \
  same_candidate_relaykit_and_combined_valid same_candidate_relaykit_and_openai_official_valid \
  same_candidate_relaykit_and_codex_official_valid same_candidate_relaykit_and_both_split_official_valid; do
  [[ "$(grep -Fc "${schema_key}=" <<<"${anchor_observation_schema}")" == "1" ]] ||
    fail "connect-root anchor observation schema lacks exact key ${schema_key}"
done
if grep -Eq 'semanticCandidates\(|captureSemanticCandidate\(|recognizedText\(|capture\(|sleep|usleep|CGEvent|writePNG|createFile|windowID|window_count|bounds|ocr_text|confidence_value' <<<"${anchor_observation_schema}"; then
  fail "connect-root anchor observation schema performs work or emits dynamic metadata"
fi
for forbidden_anchor_value in 'RelayKit' 'OpenAI Official / Codex Official' 'OpenAI Official' 'Codex Official'; do
  if grep -Fq "\"${forbidden_anchor_value}\"" <<<"${anchor_observation_schema}"; then
    fail "connect-root anchor observation schema emits a literal anchor"
  fi
done
if grep -Eq 'semanticCandidates\(|captureSemanticCandidate\(|recognizedText\(|capture\(|sleep|usleep|CGEvent|writePNG|createFile|print\(' <<<"${anchor_observation_calculator}"; then
  fail "connect-root anchor observation calculator adds query, capture, OCR, wait, action, write, or output"
fi
anchor_observation_hook="$(sed -n '/^func selectSemanticWindow(/,/^}/p' "${SCRIPT}")"
for hook_contract in \
  'RELAYKIT_WINDOW_EQUIVALENCE_DIAGNOSTIC_TARGET' \
  'connect-root-anchor-observations' \
  'semanticFlowContext == "connect"' \
  'semanticVisualModeContext == "probe-window"' \
  'connectRootAnchorObservationDiagnostic(candidates: candidates)' \
  'print(connectRootAnchorObservationSchema(diagnostic))' \
  'exit(100)'; do
  grep -Fq "${hook_contract}" <<<"${anchor_observation_hook}" ||
    fail "connect-root anchor observation same-selector hook lacks ${hook_contract}"
done
[[ "$(grep -Fc 'connectRootAnchorObservationDiagnostic(candidates: candidates)' <<<"${anchor_observation_hook}")" == "1" ]] ||
  fail "connect-root anchor observation hook evaluates the candidate set more than once"
public_anchor_mapping="$(sed -n '/^func connectRootPublicAnchorText(/,/^}/p' "${SCRIPT}")"
for public_anchor_mapping_contract in \
  'case .gatewayStopped: return "Stopped"' \
  'case .usageTab: return "Usage"' \
  'case .codexCard: return "Codex"' \
  'case .enableRelayKit: return "Enable RelayKit"' \
  'case .officialAuthBadge: return "AUTH"' \
  'case .localCLIEyebrow: return "LOCAL CLI"'; do
  grep -Fq "${public_anchor_mapping_contract}" <<<"${public_anchor_mapping}" ||
    fail "connect-root public anchor mapping lacks ${public_anchor_mapping_contract}"
done
public_anchor_calculator="$(sed -n '/^func publicAnchorCandidateDiagnostic(/,/^}/p' "${SCRIPT}")$(sed -n '/^func connectRootPublicAnchorCandidatesDiagnostic(/,/^}/p' "${SCRIPT}")"
public_anchor_schema="$(sed -n '/^func connectRootPublicAnchorCandidatesSchema(/,/^}/p' "${SCRIPT}")"
for public_anchor_key in gateway_stopped usage_tab codex_card enable_relaykit official_auth_badge local_cli_eyebrow; do
  for public_anchor_field in exact_observation_seen confidence_threshold_seen geometry_valid_seen valid_hit_cardinality relaykit_pair_profile_cardinality; do
    [[ "$(grep -Fc "${public_anchor_key}_${public_anchor_field}=" <<<"${public_anchor_schema}")" == "1" ]] ||
      fail "connect-root public anchor schema lacks ${public_anchor_key}_${public_anchor_field}"
  done
done
grep -Fq 'DIAG_VALID=true' <<<"${public_anchor_schema}" ||
  fail "connect-root public anchor schema lacks its fixed validity line"
for public_anchor_contract in \
  'anchorObservationDiagnostic(candidates: candidates' \
  'relayKit.validCounts' \
  '== 1' \
  'relayKitPairProfileCardinality'; do
  grep -Fq "${public_anchor_contract}" <<<"${public_anchor_calculator}" ||
    fail "connect-root public anchor calculator lacks ${public_anchor_contract}"
done
if grep -Eq 'semanticCandidates\(|captureSemanticCandidate\(|recognizedText\(|capture\(|sleep|usleep|CGEvent|writePNG|createFile|print\(' <<<"${public_anchor_calculator}"; then
  fail "connect-root public anchor calculator adds query, capture, OCR, wait, action, write, or output"
fi
if grep -Eq 'semanticCandidates\(|captureSemanticCandidate\(|recognizedText\(|capture\(|sleep|usleep|CGEvent|writePNG|createFile|windowID|window_count|bounds|ocr_text|confidence_value' <<<"${public_anchor_schema}"; then
  fail "connect-root public anchor schema performs work or emits runtime metadata"
fi
for forbidden_public_anchor in 'Stopped' 'Usage' 'Codex' 'Enable RelayKit' 'AUTH' 'LOCAL CLI'; do
  if grep -Fq "\"${forbidden_public_anchor}\"" <<<"${public_anchor_schema}"; then
    fail "connect-root public anchor schema emits a literal label"
  fi
done
allowed_action_body="$(sed -n '/^func allowed(label:/,/^}/p' "${SCRIPT}")"
for diagnostic_only_action_label in 'Stopped' 'Codex' 'Enable RelayKit' 'LOCAL CLI'; do
  if grep -Fq "\"${diagnostic_only_action_label}\"" <<<"${allowed_action_body}"; then
    fail "diagnostic-only public anchor entered the action allowlist"
  fi
done
for public_hook_contract in \
  'connect-root-public-anchor-candidates' \
  'connectRootPublicAnchorCandidatesDiagnostic(candidates: candidates)' \
  'print(connectRootPublicAnchorCandidatesSchema(diagnostic))' \
  'exit(101)'; do
  grep -Fq "${public_hook_contract}" <<<"${anchor_observation_hook}" ||
    fail "connect-root public anchor same-selector hook lacks ${public_hook_contract}"
done
[[ "$(grep -Fc 'connectRootPublicAnchorCandidatesDiagnostic(candidates: candidates)' <<<"${anchor_observation_hook}")" == "1" ]] ||
  fail "connect-root public anchor hook evaluates the candidate set more than once"
first_ambiguity_swift="$(sed -n '/let equivalenceDiagnosticTarget = ProcessInfo/,/^    } else {/p' "${SCRIPT}")"
[[ "$(grep -Fc 'let candidates = try semanticCandidates(pid: pid, expectedExecutable: expectedExecutable)' <<<"${first_ambiguity_swift}")" == "1" ]] ||
  fail "first-ambiguity path must compute each semantic set once"
grep -Fq 'let matches = try semanticMatches(candidates, anchor: anchor)' <<<"${first_ambiguity_swift}" ||
  fail "first-ambiguity path must classify the same set as zero/one/multiple"
grep -Fq 'firstAmbiguityWindowEquivalenceDiagnostic(candidates: candidates' <<<"${first_ambiguity_swift}" ||
  fail "first-ambiguity path must pass the same object to its evaluator"
grep -Fq 'mode: mode, flow: flow, label: label' <<<"${first_ambiguity_swift}" ||
  fail "first-ambiguity evaluator does not receive the current fixed mode/allowlist inputs"
grep -Fq 'frozen = matches[0].candidate.window' <<<"${first_ambiguity_swift}" ||
  fail "unique first-ambiguity samples must continue with the same selected object"
if grep -Eq 'windowInfo\(|probeWindowInfo\(|semanticCandidates\(' <<<"$(sed -n '/frozen = matches\[0\]\.candidate\.window/,/^    } else {/p' <<<"${first_ambiguity_swift}")"; then
  fail "unique first-ambiguity path performs a second semantic query"
fi
grep -Fq 'throw VisualFailure.semanticAnchorMissing' <<<"${first_ambiguity_swift}" ||
  fail "zero-match first-ambiguity path no longer preserves its ordinary missing failure"
first_ambiguity_completion="$(sed -n '/^cleanup$/,/^echo "RelayKit menu bar UI smoke passed:/p' "${SCRIPT}")"
for completion_contract in \
  'if [[ "${RELAYKIT_WINDOW_EQUIVALENCE_DIAGNOSTIC_TARGET:-}" == "first-ambiguity" ||' \
  '"${RELAYKIT_WINDOW_EQUIVALENCE_DIAGNOSTIC_TARGET:-}" == "first-ambiguity-private-visual" ]]; then' \
  'printf '\''%s\n'\'' '\''DIAG_VALID=false'\'' '\''DIAG_REASON=semantic-ambiguity-not-observed'\''' \
  'FAILURE_REPORTED=1' \
  'exit 1'; do
  grep -Fq "${completion_contract}" <<<"${first_ambiguity_completion}" ||
    fail "first-ambiguity no-match completion lacks ${completion_contract}"
done
completion_cleanup_line="$(grep -nFx 'cleanup' <<<"${first_ambiguity_completion}" | cut -d: -f1)"
completion_target_line="$(grep -nF 'RELAYKIT_WINDOW_EQUIVALENCE_DIAGNOSTIC_TARGET:-}' <<<"${first_ambiguity_completion}" | head -n 1 | cut -d: -f1)"
completion_success_line="$(grep -nF 'echo "RelayKit menu bar UI smoke passed:' <<<"${first_ambiguity_completion}" | cut -d: -f1)"
((completion_cleanup_line < completion_target_line && completion_target_line < completion_success_line)) ||
  fail "first-ambiguity absence must be reported only after a fully successful normal run and cleanup"

run_private_visual_diagnostic_dir_contract() (
  RELAYKIT_MENU_BAR_E2E_SOURCE_ONLY=1 source "${SCRIPT}"
  local valid_dir nonempty_dir mode_dir wrong_name_dir symlink_target symlink_dir output rc
  valid_dir="$(mktemp -d /private/tmp/relaykit-window-diag.XXXXXX)"
  nonempty_dir="$(mktemp -d /private/tmp/relaykit-window-diag.XXXXXX)"
  mode_dir="$(mktemp -d /private/tmp/relaykit-window-diag.XXXXXX)"
  wrong_name_dir="$(mktemp -d /private/tmp/relaykit-private-visual.XXXXXX)"
  symlink_target="$(mktemp -d /private/tmp/relaykit-window-diag.XXXXXX)"
  symlink_dir="/private/tmp/relaykit-window-diag.symlink.$$"
  : >"${nonempty_dir}/fixture"
  chmod 0755 "${mode_dir}"
  ln -s "${symlink_target}" "${symlink_dir}"
  trap '
    unlink "${nonempty_dir}/fixture" 2>/dev/null || true
    unlink "${symlink_dir}" 2>/dev/null || true
    chmod 0700 "${mode_dir}" 2>/dev/null || true
    rmdir "${valid_dir}" "${nonempty_dir}" "${mode_dir}" "${wrong_name_dir}" "${symlink_target}" 2>/dev/null || true
  ' EXIT

  output="$(private_visual_diagnostic_dir_is_valid "${valid_dir}" 2>&1)" ||
    fail "strict private visual directory guard rejected a valid empty 0700 directory"
  [[ -z "${output}" ]] || fail "valid private visual directory guard emitted output"
  for rejected_dir in \
    "relative/relaykit-window-diag.fixture" \
    "${nonempty_dir}" \
    "${mode_dir}" \
    "${wrong_name_dir}" \
    "${symlink_dir}"; do
    if output="$(private_visual_diagnostic_dir_is_valid "${rejected_dir}" 2>&1)"; then rc=0; else rc="$?"; fi
    [[ "${rc}" == "2" && -z "${output}" ]] ||
      fail "invalid private visual directory did not fail silently with rc2"
  done
)
run_private_visual_diagnostic_dir_contract

private_visual_writer_body="$(sed -n '/^func writePrivateAmbiguityPNGs(/,/^}/p' "${SCRIPT}")"
for private_writer_contract in \
  'candidate.image' \
  'String(format: "window-%04d.png", index)' \
  'CGImageDestinationCreateWithData' \
  'O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW' \
  'S_IRUSR | S_IWUSR' \
  'status.st_uid == getuid()' \
  '(status.st_mode & S_IFMT) == S_IFREG' \
  '(status.st_mode & 0o777) == 0o600'; do
  grep -Fq "${private_writer_contract}" <<<"${private_visual_writer_body}" ||
    fail "private ambiguity PNG writer lacks ${private_writer_contract}"
done
if grep -Eq 'semanticCandidates\(|captureSemanticCandidate\(|recognizedText\(|capture\(|CGEvent|print\(' <<<"${private_visual_writer_body}"; then
  fail "private ambiguity PNG writer requeries, recaptures, OCRs, acts, or emits dynamic output"
fi
private_visual_swift="$(sed -n '/let equivalenceDiagnosticTarget = ProcessInfo/,/exit(99)/p' "${SCRIPT}")"
for private_swift_contract in \
  'let candidates = try semanticCandidates(pid: pid, expectedExecutable: expectedExecutable)' \
  'let matches = try semanticMatches(candidates, anchor: anchor)' \
  'writePrivateAmbiguityPNGs(candidates: matches.map { $0.candidate }' \
  'print("PRIVATE_VISUAL_DIAGNOSTIC_READY=true")' \
  'exit(99)'; do
  grep -Fq "${private_swift_contract}" <<<"${private_visual_swift}" ||
    fail "private ambiguity visual path lacks ${private_swift_contract}"
done
[[ "$(grep -Fc 'semanticCandidates(pid: pid, expectedExecutable: expectedExecutable)' <<<"${private_visual_swift}")" == "1" ]] ||
  fail "private ambiguity visual path performs more than one semantic query"
if grep -Eq 'captureSemanticCandidate\(|recognizedText\(|capture\(|sleep|usleep|CGEvent' <<<"${private_visual_swift}"; then
  fail "private ambiguity visual path recaptures, OCRs, waits, or acts after ambiguity"
fi
grep -Fq 'first-ambiguity-private-visual' <<<"$(sed -n '/^window_equivalence_diagnostic_target_is_valid()/,/^}/p' "${SCRIPT}")" ||
  fail "private ambiguity visual target is not in the fixed target allowlist"
grep -Fq 'RELAYKIT_PRIVATE_VISUAL_DIAGNOSTIC_DIR' "${SCRIPT}" ||
  fail "private ambiguity visual target does not require its explicit output directory"
grep -Fq 'PRIVATE_VISUAL_DIAGNOSTIC_READY=true' "${SCRIPT}" ||
  fail "private ambiguity visual completion marker is missing"
normal_connect_line="$(grep -nFx 'capture connect --ui-smoke-tab connect --ui-smoke-provider-config "${EMPTY_PROVIDER_CONFIG}"' "${SCRIPT}" | cut -d: -f1 || true)"
[[ -n "${normal_connect_line}" ]] || fail "normal connect capture entry is missing"
grep -Fq '$0.text == anchor' <<<"${semantic_selector_region}" ||
  fail "semantic selector must retain exact OCR equality"
grep -Fq 'hit.confidence >= 0.80' <<<"${semantic_selector_region}" ||
  fail "semantic selector must retain the existing confidence floor"
grep -Fq 'recognitionLevel = .accurate' "${SCRIPT}" || fail "semantic selector changed Vision recognition level"
grep -Fq 'capture.${context}.semantic-window-readiness' "${SCRIPT}" ||
  fail "capture readiness stage is not explicitly semantic"
if grep -Fq 'capture.${context}.window-readiness' "${SCRIPT}"; then
  fail "generic capture window-readiness stage survived semantic selection"
fi

run_outside_window_readiness_contract() (
  RELAYKIT_MENU_BAR_E2E_SOURCE_ONLY=1 source "${SCRIPT}"
  local context calls sleeps rc output_file expected
  local -a normal_contexts=(
    connect official-sheet real-demo provider-click-flow provider-test-failure
    detail detail-advanced-expanded detail-advanced-collapsed import usage
    usage-auto-refresh usage-large usage-1m usage-1y usage-empty settings
    settings-developer-expanded settings-light usage-light official-light
    provider-light settings-dark usage-dark official-dark provider-dark provider
  )
  output_file="$(mktemp /tmp/relaykit-outside-window-readiness-test.XXXXXX)"
  trap 'rm -f -- "${output_file}"' EXIT

  for context in "${normal_contexts[@]}"; do
    window_readiness_context_is_valid "${context}" || fail "normal capture readiness rejected ${context}"
    CURRENT_STAGE=bootstrap
    set_capture_window_readiness_stage "${context}"
    expected="capture.${context}.semantic-window-readiness"
    [[ "${CURRENT_STAGE}" == "${expected}" ]] || fail "capture readiness stage mapping lost ${expected}"
  done
  window_readiness_context_is_valid outside-click || fail "outside-click readiness context was rejected"
  for context in real-quit invalid-context; do
    calls=0
    visual_probe_window() { calls=$((calls + 1)); return 0; }
    CURRENT_STAGE=bootstrap
    if wait_for_capture_window_ready "${context}" >"${output_file}" 2>&1; then
      fail "invalid window-readiness context ${context} was accepted"
    else
      rc="$?"
    fi
    [[ "${rc}" == "2" && "${calls}" == "0" && "${CURRENT_STAGE}" == "bootstrap" && ! -s "${output_file}" ]] ||
      fail "invalid window-readiness context ${context} did not fail silently with rc2 before probe"
  done

  calls=0
  sleeps=0
  visual_probe_window() { calls=$((calls + 1)); return 0; }
  kill() { fail "ready outside window unexpectedly checked process death"; }
  sleep() { fail "ready outside window unexpectedly slept"; }
  wait_for_capture_window_ready connect >"${output_file}" 2>&1
  [[ "${calls}" == "1" && ! -s "${output_file}" ]] || fail "ready outside window was not accepted silently on first probe"

  calls=0
  sleeps=0
  visual_probe_window() { calls=$((calls + 1)); return 71; }
  kill() { return 1; }
  sleep() { sleeps=$((sleeps + 1)); }
  if wait_for_outside_window_ready >"${output_file}" 2>&1; then
    fail "dead outside-click process was accepted"
  else
    rc="$?"
  fi
  [[ "${rc}" == "1" && "${calls}" == "1" && "${sleeps}" == "0" && ! -s "${output_file}" ]] ||
    fail "outside readiness process death lost fail-closed rc1/silence"

  calls=0
  sleeps=0
  visual_probe_window() { calls=$((calls + 1)); return 77; }
  kill() { return 0; }
  sleep() { [[ "$1" == "0.05" ]] || fail "outside readiness used a non-50ms sleep"; sleeps=$((sleeps + 1)); }
  if wait_for_capture_window_ready provider-dark >"${output_file}" 2>&1; then
    fail "missing/stale outside window exceeded its budget but was accepted"
  else
    rc="$?"
  fi
  [[ "${rc}" == "1" && "${calls}" == "120" && "${sleeps}" == "120" && ! -s "${output_file}" ]] ||
    fail "outside readiness lost its exact 120x50ms budget or silent rc1"
)
run_outside_window_readiness_contract

grep -Fq 'ensure_outside_popover_open() {' "${SCRIPT}" || fail "outside-click needs conditional popover opening"
outside_ensure_body="$(sed -n '/^ensure_outside_popover_open() {/,/^}/p' "${SCRIPT}")"
[[ "$(grep -Fc 'visual_probe_window outside-click' <<<"${outside_ensure_body}")" == "1" ]] ||
  fail "outside initial window probe must run exactly once"
[[ "$(grep -Fc 'press_unique_status_item' <<<"${outside_ensure_body}")" == "1" ]] ||
  fail "outside conditional status-item press must occur at most once"
grep -Fq 'set_stage capture.outside-click.status-item-press' <<<"${outside_ensure_body}" ||
  fail "outside missing-window path lacks its fixed status-item-press stage"

run_outside_conditional_open_contract() (
  RELAYKIT_MENU_BAR_E2E_SOURCE_ONLY=1 source "${SCRIPT}"
  local probe_rc expected_rc expected_presses rc probes presses press_rc output_file
  output_file="$(mktemp /tmp/relaykit-outside-conditional-open-test.XXXXXX)"
  trap 'rm -f -- "${output_file}"' EXIT

  while IFS='|' read -r probe_rc expected_rc expected_presses; do
    probes=0
    presses=0
    press_rc=0
    CURRENT_STAGE=capture.outside-click.initial-window-probe
    visual_probe_window() { probes=$((probes + 1)); return "${probe_rc}"; }
    press_unique_status_item() { presses=$((presses + 1)); return "${press_rc}"; }
    if ensure_outside_popover_open >"${output_file}" 2>&1; then rc=0; else rc="$?"; fi
    [[ "${rc}" == "${expected_rc}" && "${probes}" == "1" && "${presses}" == "${expected_presses}" && ! -s "${output_file}" ]] ||
      fail "outside state matrix lost probe/press/RC for probe RC${probe_rc}"
    if [[ "${expected_presses}" == "1" ]]; then
      [[ "${CURRENT_STAGE}" == "capture.outside-click.status-item-press" ]] || fail "missing window did not reach status-item-press stage"
    fi
  done <<'OUTSIDE_STATES'
0|0|0
89|0|1
90|90|0
71|71|0
73|73|0
77|77|0
OUTSIDE_STATES

  for press_rc in 33 38 39 40; do
    probes=0
    presses=0
    visual_probe_window() { probes=$((probes + 1)); return 89; }
    press_unique_status_item() { presses=$((presses + 1)); return "${press_rc}"; }
    CURRENT_STAGE=capture.outside-click.initial-window-probe
    if ensure_outside_popover_open >"${output_file}" 2>&1; then fail "failed status-item press RC${press_rc} was accepted"; else rc="$?"; fi
    [[ "${rc}" == "${press_rc}" && "${probes}" == "1" && "${presses}" == "1" &&
       "${CURRENT_STAGE}" == "capture.outside-click.status-item-press" && ! -s "${output_file}" ]] ||
      fail "status-item press failure RC${press_rc} lost single-action/fixed-stage semantics"
  done
)
run_outside_conditional_open_contract

run_provider_click_flow_predicate_contract() (
  RELAYKIT_MENU_BAR_E2E_SOURCE_ONLY=1 source "${SCRIPT}"
  local case_root evidence output rc
  case_root="$(mktemp -d /tmp/relaykit-provider-predicate-test.XXXXXX)"
  trap 'rm -rf -- "${case_root}"' EXIT
  evidence="${case_root}/fixture.json"
  jq -n '{connect: {
    provider_edit_opened: true,
    provider_edit_row_action_invoked: true,
    provider_edit_base_url_prefilled: true,
    provider_edit_models_loaded: true,
    provider_health_summary_visible: true,
    provider_health_saved_count: 2,
    provider_health_available_count: 1,
    provider_health_hidden_count: 1,
    provider_model_reachable_row_visible: true,
    provider_model_unavailable_row_visible: false,
    provider_hidden_models_toggle_visible: true,
    provider_hidden_model_reasons_visible: true,
    api_key_saved_state_visible: true,
    api_key_masked_field_visible: true,
    api_key_saved_mask_control_visible: true,
    api_key_saved_eye_visible: true,
    saved_key_fake_eye_visible: false,
    saved_key_disabled_eye_reason_visible: false,
    api_key_replace_visible: false,
    api_key_replace_available: false,
    provider_form_test_connection_visible: true,
    saved_key_plaintext_hidden: true
  }}' >"${evidence}"
  set +e
  output="$(provider_click_flow_specific_predicate "${evidence}" 2>&1)"
  rc="$?"
  set -e
  [[ "${rc}" != "0" && "${output}" == "provider_model_unavailable_row_visible type=boolean" ]] ||
    fail "provider-click-flow false conjunct diagnostic is not fixed and typed"
  jq 'del(.connect.provider_model_unavailable_row_visible)' "${evidence}" >"${case_root}/missing.json"
  set +e
  output="$(provider_click_flow_specific_predicate "${case_root}/missing.json" 2>&1)"
  rc="$?"
  set -e
  [[ "${rc}" != "0" && "${output}" == "provider_model_unavailable_row_visible type=null" ]] ||
    fail "provider-click-flow missing conjunct diagnostic is not fixed and typed"
  if grep -Fq "${case_root}" <<<"${output}"; then
    fail "provider-click-flow diagnostic exposed its evidence path"
  fi
)

run_provider_click_flow_predicate_contract

grep -Fq 'wait_for_provider_edit_ready() {' "${SCRIPT}" ||
  fail "provider edit-ready wait needs a fixed two-field diagnostic wrapper"
run_provider_edit_ready_wait_contract() (
  RELAYKIT_MENU_BAR_E2E_SOURCE_ONLY=1 source "${SCRIPT}"
  local case_root evidence output_file output rc calls observed_expression wait_rc
  case_root="$(mktemp -d /tmp/relaykit-provider-edit-ready-test.XXXXXX)"
  trap 'rm -rf -- "${case_root}"' EXIT
  evidence="${case_root}/fixture.json"
  output_file="${case_root}/output.txt"
  calls=0
  observed_expression=""
  wait_rc=0
  wait_for_jq() {
    calls=$((calls + 1))
    [[ "$1" == "${evidence}" ]] || fail "provider edit-ready wrapper changed the evidence argument"
    observed_expression="$2"
    return "${wait_rc}"
  }

  printf '%s\n' '{"connect":{"provider_edit_opened":true,"api_key_masked_field_visible":true}}' >"${evidence}"
  wait_for_provider_edit_ready "${evidence}" >"${output_file}" 2>&1
  output="$(<"${output_file}")"
  [[ -z "${output}" && "${calls}" == "1" ]] || fail "provider edit-ready success was not silent or called wait more than once"
  [[ "${observed_expression}" == '.connect.provider_edit_opened == true and .connect.api_key_masked_field_visible == true' ]] ||
    fail "provider edit-ready wrapper changed the exact wait expression"

  while IFS='|' read -r fixture expected; do
    printf '%s\n' "${fixture}" >"${evidence}"
    calls=0
    observed_expression=""
    wait_rc=37
    set +e
    wait_for_provider_edit_ready "${evidence}" >"${output_file}" 2>&1
    rc="$?"
    set -e
    output="$(<"${output_file}")"
    [[ "${rc}" == "37" ]] || fail "provider edit-ready wrapper did not preserve the original non-1 rc"
    [[ "${calls}" == "1" ]] || fail "provider edit-ready wrapper invoked wait_for_jq more than once"
    [[ "${observed_expression}" == '.connect.provider_edit_opened == true and .connect.api_key_masked_field_visible == true' ]] ||
      fail "provider edit-ready failure changed the exact wait expression"
    [[ "${output}" == "${expected}" ]] || fail "provider edit-ready fixed diagnostic mismatch"
    if grep -Fq "${case_root}" <<<"${output}"; then
      fail "provider edit-ready diagnostic exposed its evidence path"
    fi
  done <<'CASES'
{"connect":{"provider_edit_opened":false,"api_key_masked_field_visible":true}}|provider_edit_opened type=boolean
{"connect":{"provider_edit_opened":true,"api_key_masked_field_visible":false}}|api_key_masked_field_visible type=boolean
{"connect":{"provider_edit_opened":true}}|api_key_masked_field_visible type=null
not-json|provider_edit_opened type=null
CASES
)
run_provider_edit_ready_wait_contract

grep -Fq 'usage_specific_predicate() {' "${SCRIPT}" ||
  fail "usage specific validation needs a first-failed-conjunct helper"
run_usage_specific_predicate_contract() (
  RELAYKIT_MENU_BAR_E2E_SOURCE_ONLY=1 source "${SCRIPT}"
  local case_root evidence output_file output rc label
  local -a labels=(
    has_rows empty_state_visible auto_refresh_enabled summary_background token_unit_formatting
    today_tokens today_tokens_label seven_day_tokens all_time_tokens requests top_model_7d
    top_model_7d_readable top_model_readable_visible active_days provider_group_names
    provider_source_shifted model_count activity_bucket_count_7d activity_active_days_7d
    activity_unit_labels activity_heatmap_visible activity_range_control_visible
    activity_unit_label_visible cost_unavailable_visible
  )
  case_root="$(mktemp -d /tmp/relaykit-usage-predicate-test.XXXXXX)"
  trap 'rm -rf -- "${case_root}"' EXIT
  evidence="${case_root}/fixture.json"
  output_file="${case_root}/output.txt"
  jq -n '{usage: {
    has_rows: true,
    empty_state_visible: false,
    auto_refresh_enabled: true,
    summary_background: true,
    token_unit_formatting: true,
    today_tokens: 150,
    today_tokens_label: "150",
    seven_day_tokens: 750,
    all_time_tokens: 775,
    requests: 7,
    top_model_7d: "demo/claude-sonnet-4-6",
    top_model_7d_readable: "claude-sonnet-4-6",
    top_model_readable_visible: true,
    active_days: 4,
    provider_group_names: ["Official Codex / OpenAI","Third-party providers"],
    provider_source_shifted: true,
    model_count: 4,
    activity_bucket_count_7d: 14,
    activity_active_days_7d: 3,
    activity_unit_labels: ["7D · half-day","1M · daily","1Y · weekly"],
    activity_heatmap_visible: true,
    activity_range_control_visible: true,
    activity_unit_label_visible: true,
    cost_unavailable_visible: true
  }}' >"${evidence}"
  CURRENT_STAGE=capture.usage.specific-jq
  usage_specific_predicate "${evidence}" >"${output_file}" 2>&1
  [[ ! -s "${output_file}" && "${CURRENT_STAGE}" == "capture.usage.specific-jq" ]] ||
    fail "successful usage specific predicate was not silent or changed stage"

  for label in "${labels[@]}"; do
    jq --arg label "${label}" 'del(.usage[$label])' "${evidence}" >"${case_root}/${label}.json"
    CURRENT_STAGE=capture.usage.specific-jq
    if usage_specific_predicate "${case_root}/${label}.json" >"${output_file}" 2>&1; then
      fail "usage specific predicate accepted missing ${label}"
    else
      rc="$?"
    fi
    output="$(<"${output_file}")"
    [[ "${rc}" == "1" && "${output}" == "FIRST_FAILED_CONJUNCT=${label} type=null" ]] ||
      fail "usage specific first-failed diagnostic mismatch for ${label}"
    [[ "${CURRENT_STAGE}" == "capture.usage.specific-jq" ]] || fail "usage diagnostic changed the capture-specific stage"
  done
  jq '.usage.has_rows = false' "${evidence}" >"${case_root}/false.json"
  if usage_specific_predicate "${case_root}/false.json" >"${output_file}" 2>&1; then rc=0; else rc="$?"; fi
  output="$(<"${output_file}")"
  [[ "${rc}" == "1" && "${output}" == "FIRST_FAILED_CONJUNCT=has_rows type=boolean" ]] ||
    fail "usage specific boolean diagnostic is not fixed and typed"
  printf '%s\n' 'not-json' >"${case_root}/malformed.json"
  if usage_specific_predicate "${case_root}/malformed.json" >"${output_file}" 2>&1; then rc=0; else rc="$?"; fi
  output="$(<"${output_file}")"
  [[ "${rc}" == "1" && "${output}" == "FIRST_FAILED_CONJUNCT=has_rows type=null" ]] ||
    fail "malformed usage evidence did not use the fixed fallback"
  if grep -Fq "${case_root}" <<<"${output}"; then fail "usage diagnostic exposed its evidence path"; fi
)
run_usage_specific_predicate_contract

usage_helper_body="$(sed -n '/^usage_specific_predicate() {/,/^}/p' "${SCRIPT}")"
[[ "$(grep -Fc "jq -e '" <<<"${usage_helper_body}")" == "1" ]] || fail "original usage aggregate jq must execute exactly once"
[[ "$(grep -Fc 'usage_specific_predicate "${evidence}"' "${SCRIPT}")" == "1" ]] || fail "usage specific helper must have exactly one capture callsite"
usage_diagnostic_labels="$(grep -o 'label:"[a-z0-9_]*"' <<<"${usage_helper_body}" | sed -E 's/label:"([a-z0-9_]*)"/\1/' | tr '\n' ' ')"
[[ "${usage_diagnostic_labels}" == "has_rows empty_state_visible auto_refresh_enabled summary_background token_unit_formatting today_tokens today_tokens_label seven_day_tokens all_time_tokens requests top_model_7d top_model_7d_readable top_model_readable_visible active_days provider_group_names provider_source_shifted model_count activity_bucket_count_7d activity_active_days_7d activity_unit_labels activity_heatmap_visible activity_range_control_visible activity_unit_label_visible cost_unavailable_visible " ]] ||
  fail "usage diagnostic labels do not preserve all 24 conjuncts in order"

grep -Fq 'set_provider_capture_stage() {' "${SCRIPT}" ||
  fail "provider capture flow needs a fixed name/phase stage mapper"
run_provider_capture_stage_contract() (
  RELAYKIT_MENU_BAR_E2E_SOURCE_ONLY=1 source "${SCRIPT}"
  local name phase expected
  for name in provider-click-flow provider-light provider-dark; do
    for phase in edit-open-check provider-row-click edit-ready-wait health-ready-wait hidden-models-click hidden-reasons-wait specific-predicate; do
      set_provider_capture_stage "${name}" "${phase}"
      expected="capture.${name}.${phase}"
      [[ "${CURRENT_STAGE}" == "${expected}" ]] || fail "provider capture stage mapping lost ${expected}"
    done
  done
  if set_provider_capture_stage invalid-capture edit-open-check >/dev/null 2>&1; then
    fail "invalid provider capture name must fail closed"
  fi
  if set_provider_capture_stage provider-click-flow invalid-phase >/dev/null 2>&1; then
    fail "invalid provider capture phase must fail closed"
  fi
)
run_provider_capture_stage_contract

provider_capture_phases="$(sed -n '/if \[\[ "${name}" == "provider-click-flow"/,/provider_click_flow_specific_predicate "${evidence}"/p' "${SCRIPT}" |
  grep 'set_provider_capture_stage "${name}"' |
  sed -E 's/.* "([^ "]+)"$/\1/' |
  tr '\n' ' ')"
[[ "${provider_capture_phases}" == "edit-open-check provider-row-click edit-ready-wait health-ready-wait hidden-models-click hidden-reasons-wait specific-predicate " ]] ||
  fail "provider capture stages do not match the exact seven-step control order"

grep -Fq 'set_official_sheet_stage() {' "${SCRIPT}" ||
  fail "official sheet post-click flow needs a fixed flow/phase stage mapper"
grep -Fq 'wait_for_official_sheet_opened() {' "${SCRIPT}" ||
  fail "official sheet opened wait needs a fixed timeout classifier"
run_official_sheet_opened_timeout_contract() (
  RELAYKIT_MENU_BAR_E2E_SOURCE_ONLY=1 source "${SCRIPT}"
  local fixture output_file output rc expected wait_calls wait_rc
  fixture="$(mktemp /tmp/relaykit-official-opened-timeout.XXXXXX)"
  output_file="$(mktemp /tmp/relaykit-official-opened-output.XXXXXX)"
  trap 'rm -f -- "${fixture}" "${output_file}"' EXIT
  wait_for_jq() {
    wait_calls=$((wait_calls + 1))
    [[ "$1" == "${fixture}" && "$2" == '.connect.official_sheet_opened == true' ]] || return 97
    return "${wait_rc}"
  }

  while IFS='|' read -r json expected; do
    printf '%s\n' "${json}" >"${fixture}"
    wait_calls=0
    wait_rc=37
    set +e
    wait_for_official_sheet_opened "${fixture}" >"${output_file}" 2>&1
    rc="$?"
    set -e
    output="$(<"${output_file}")"
    [[ "${rc}" == "37" && "${wait_calls}" == "1" && "${output}" == "${expected}" ]] ||
      fail "official opened timeout classification lost ${expected} or original rc"
  done <<'OFFICIAL_OPENED_CASES'
{"connect":{"official_provider_row_actionable":false,"official_sheet_opened":false}}|row-action-not-recorded
{"connect":{"official_provider_row_actionable":true,"official_sheet_opened":false}}|sheet-appear-not-recorded
{"connect":{"official_provider_row_actionable":true,"official_sheet_opened":true}}|sheet-recorded-after-timeout
{"connect":{"official_provider_row_actionable":false,"official_sheet_opened":true}}|evidence-inconsistent
{"connect":{"official_sheet_opened":false}}|evidence-type-invalid
{"connect":{"official_provider_row_actionable":"true","official_sheet_opened":false}}|evidence-type-invalid
OFFICIAL_OPENED_CASES

  printf '%s\n' 'not-json' >"${fixture}"
  wait_calls=0
  wait_rc=37
  set +e
  wait_for_official_sheet_opened "${fixture}" >"${output_file}" 2>&1
  rc="$?"
  set -e
  [[ "${rc}" == "37" && "${wait_calls}" == "1" && "$(<"${output_file}")" == 'evidence-type-invalid' ]] ||
    fail "malformed official opened evidence did not fail closed without changing the wait rc"

  wait_calls=0
  wait_rc=0
  : >"${output_file}"
  wait_for_official_sheet_opened "${fixture}" >"${output_file}" 2>&1
  [[ "${wait_calls}" == "1" && ! -s "${output_file}" ]] ||
    fail "successful official opened wait was not silent and exact-once"
)
run_official_sheet_opened_timeout_contract
run_official_sheet_stage_contract() (
  RELAYKIT_MENU_BAR_E2E_SOURCE_ONLY=1 source "${SCRIPT}"
  local flow phase expected previous rc output
  local -a flows=(official-sheet official-light official-dark)
  local -a phases=(opened-wait specific-predicate before-capture before-verify after-capture after-verify)
  for flow in "${flows[@]}"; do
    for phase in "${phases[@]}"; do
      set_official_sheet_stage "${flow}" "${phase}"
      expected="capture.${flow}.${phase}"
      [[ "${CURRENT_STAGE}" == "${expected}" ]] ||
        fail "official sheet stage mapping lost ${expected}"
    done
  done
  previous="${CURRENT_STAGE}"
  if output="$(set_official_sheet_stage provider-light opened-wait 2>&1)"; then rc=0; else rc="$?"; fi
  [[ "${rc}" == "2" && -z "${output}" && "${CURRENT_STAGE}" == "${previous}" ]] ||
    fail "unlisted official sheet flow did not fail closed before changing stage"
  if output="$(set_official_sheet_stage official-sheet invalid-phase 2>&1)"; then rc=0; else rc="$?"; fi
  [[ "${rc}" == "2" && -z "${output}" && "${CURRENT_STAGE}" == "${previous}" ]] ||
    fail "unlisted official sheet phase did not fail closed before changing stage"
)
run_official_sheet_stage_contract

official_sheet_block="$(sed -n '/if \[\[ "${name}" == "official-sheet"/,/^  fi$/p' "${SCRIPT}")"
official_sheet_stages="$(grep 'set_official_sheet_stage "${name}"' <<<"${official_sheet_block}" |
  sed -E 's/.* "([^ "]+)"$/\1/' |
  tr '\n' ' ')"
[[ "${official_sheet_stages}" == "opened-wait specific-predicate before-capture before-verify after-capture after-verify " ]] ||
  fail "official sheet stages do not match the exact six-step post-click order"
official_sheet_numbered="$(nl -ba <<<"${official_sheet_block}")"
official_stage_line() {
  grep -F 'set_official_sheet_stage "${name}"' <<<"${official_sheet_numbered}" |
    grep -F "\"$1\"" | awk '{print $1}'
}
official_command_line() {
  grep -F "$1" <<<"${official_sheet_numbered}" | head -1 | awk '{print $1}'
}
for stage_command in \
  'opened-wait|wait_for_official_sheet_opened "${evidence}"' \
  "specific-predicate|jq -e '" \
  'before-capture|visual_capture_window "${name}" "${OUT}/official-cta-before.png"' \
  'before-verify|test -s "${OUT}/official-cta-before.png"' \
  'after-capture|visual_capture_window "${name}" "${OUT}/official-cta-after.png"' \
  'after-verify|test -s "${OUT}/official-cta-after.png"'; do
  stage="${stage_command%%|*}"
  command="${stage_command#*|}"
  stage_line="$(official_stage_line "${stage}")"
  command_line="$(official_command_line "${command}")"
  [[ -n "${stage_line}" && -n "${command_line}" && "$((stage_line + 1))" == "${command_line}" ]] ||
    fail "official sheet ${stage} stage is not immediately before its existing command"
done
official_opened_wait_body="$(sed -n '/^wait_for_official_sheet_opened() {/,/^}/p' "${SCRIPT}")"
[[ "$(grep -Fc 'wait_for_jq "${evidence}" '\''.connect.official_sheet_opened == true'\''' <<<"${official_opened_wait_body}")" == "1" ]] ||
  fail "official sheet opened wait expression changed or was duplicated"
[[ "$(grep -Fc 'wait_for_official_sheet_opened "${evidence}"' <<<"${official_sheet_block}")" == "1" ]] ||
  fail "official sheet opened classifier call changed or was duplicated"
[[ "$(grep -Fc "jq -e '" <<<"${official_sheet_block}")" == "1" ]] || fail "official sheet predicate invocation changed or was duplicated"
[[ "$(grep -Fc 'visual_capture_window "${name}" "${OUT}/official-cta-' <<<"${official_sheet_block}")" == "2" ]] ||
  fail "official sheet before/after capture count changed"
[[ "$(grep -Fc 'test -s "${OUT}/official-cta-' <<<"${official_sheet_block}")" == "2" ]] ||
  fail "official sheet before/after verification count changed"
[[ "$(grep -Fc 'visual_click_text "${name}" "OpenAI Official / Codex Official"' <<<"${official_sheet_block}")" == "1" ]] ||
  fail "official sheet click action changed or was duplicated"
if grep -Eq '(^|[[:space:]])sleep([[:space:]]|$)|\|\| true' <<<"${official_sheet_block}"; then
  fail "official sheet post-click stages added a wait or swallowed a failure"
fi

grep -Fq 'set_provider_action_stage() {' "${SCRIPT}" ||
  fail "provider post-specific actions need a fixed flow/phase mapper"
run_provider_action_stage_contract() (
  RELAYKIT_MENU_BAR_E2E_SOURCE_ONLY=1 source "${SCRIPT}"
  local flow phase expected output output_file rc
  output_file="$(mktemp /tmp/relaykit-provider-action-stage-test.XXXXXX)"
  trap 'rm -f -- "${output_file}"' EXIT
  for flow in provider-click-flow provider-light provider-dark; do
    for phase in show-key hide-key type-key test-connection use-reachable advanced; do
      set_provider_action_stage "${flow}" "${phase}"
      expected="capture.${flow}.action.${phase}"
      [[ "${CURRENT_STAGE}" == "${expected}" ]] || fail "provider action stage mapping lost ${expected}"
    done
  done
  if set_provider_action_stage invalid-flow show-key >/dev/null 2>&1; then
    fail "invalid provider action flow must fail closed"
  fi
  if set_provider_action_stage provider-click-flow invalid-phase >/dev/null 2>&1; then
    fail "invalid provider action phase must fail closed"
  fi

  CURRENT_STAGE=bootstrap
  set +e
  return_visual_action_failure provider-click-flow click-text 84 show-key >"${output_file}" 2>&1
  rc="$?"
  set -e
  output="$(<"${output_file}")"
  [[ "${rc}" == "84" && -z "${output}" ]] || fail "provider action visual failure did not preserve rc84 silently"
  [[ "${CURRENT_STAGE}" == "flow.provider-click-flow.action.show-key.visual-click-text.target-absent-current-flow" ]] ||
    fail "provider action visual failure lost its fixed phase context"
  while IFS='|' read -r failure_rc failure_category; do
    CURRENT_STAGE=bootstrap
    set +e
    return_visual_action_failure provider-click-flow type-text "${failure_rc}" type-key >"${output_file}" 2>&1
    rc="$?"
    set -e
    [[ "${rc}" == "${failure_rc}" && ! -s "${output_file}" ]] || fail "type-text ${failure_category} failure lost rc or silence"
    [[ "${CURRENT_STAGE}" == "flow.provider-click-flow.action.type-key.visual-type-text.${failure_category}" ]] ||
      fail "type-text ${failure_category} failure lost its fixed stage"
  done <<'TYPE_FAILURES'
87|select-text
88|input-text
TYPE_FAILURES
  CURRENT_STAGE=bootstrap
  set +e
  return_visual_action_failure provider-click-flow click-text 84 invalid-phase >/dev/null 2>&1
  rc="$?"
  set -e
  [[ "${rc}" == "2" && "${CURRENT_STAGE}" == "bootstrap" ]] || fail "invalid visual action phase did not fail before action staging"
  CURRENT_STAGE=bootstrap
  set +e
  return_visual_action_failure official-sheet click-text 84 >/dev/null 2>&1
  rc="$?"
  set -e
  [[ "${rc}" == "84" && "${CURRENT_STAGE}" == "flow.official-sheet.visual-click-text.target-absent-current-flow" ]] ||
    fail "no-phase visual flows changed their existing stage contract"
)
run_provider_action_stage_contract

grep -Fq 'set_provider_capture_visual_stage() {' "${SCRIPT}" ||
  fail "provider row and hidden-model clicks need a strict capture visual phase mapper"
run_provider_capture_visual_stage_contract() (
  RELAYKIT_MENU_BAR_E2E_SOURCE_ONLY=1 source "${SCRIPT}"
  local phase expected output output_file rc
  output_file="$(mktemp /tmp/relaykit-provider-capture-visual-stage-test.XXXXXX)"
  trap 'rm -f -- "${output_file}"' EXIT
  for phase in provider-row-click hidden-models-click; do
    CURRENT_STAGE=bootstrap
    set +e
    return_visual_action_failure provider-click-flow click-text 84 "${phase}" capture >"${output_file}" 2>&1
    rc="$?"
    set -e
    output="$(<"${output_file}")"
    expected="flow.provider-click-flow.capture.${phase}.visual-click-text.target-absent-current-flow"
    [[ "${rc}" == "84" && -z "${output}" && "${CURRENT_STAGE}" == "${expected}" ]] ||
      fail "provider capture visual phase lost rc84, silence, or exact stage for ${phase}"
  done
  CURRENT_STAGE=bootstrap
  set +e
  return_visual_action_failure provider-click-flow click-text 84 edit-ready-wait capture >"${output_file}" 2>&1
  rc="$?"
  set -e
  [[ "${rc}" == "2" && "${CURRENT_STAGE}" == "bootstrap" && ! -s "${output_file}" ]] ||
    fail "unapproved provider capture visual phase did not fail closed before staging"
  CURRENT_STAGE=bootstrap
  set +e
  return_visual_action_failure provider-test-failure click-text 84 provider-row-click capture >"${output_file}" 2>&1
  rc="$?"
  set -e
  [[ "${rc}" == "2" && "${CURRENT_STAGE}" == "bootstrap" && ! -s "${output_file}" ]] ||
    fail "unapproved provider capture visual flow did not fail closed before staging"
)
run_provider_capture_visual_stage_contract

grep -Fq 'visual_click_text "${name}" "Saved Key Provider" "provider-row-click" capture' "${SCRIPT}" ||
  fail "Saved Key Provider click lacks its independent provider-row-click capture phase"
grep -Fq 'visual_click_text "${name}" "Hidden models" "hidden-models-click" capture' "${SCRIPT}" ||
  fail "Hidden models click lacks its independent hidden-models-click capture phase"

provider_action_phases="$(sed -n '/if \[\[ "${name}" == "provider-click-flow"/,/advanced_has_protocol_selector == true/p' "${SCRIPT}" |
  grep 'set_provider_action_stage "${name}"' |
  sed -E 's/.* "([^ "]+)"$/\1/' |
  tr '\n' ' ')"
[[ "${provider_action_phases}" == "type-key show-key hide-key test-connection use-reachable advanced " ]] ||
  fail "provider post-specific stages do not match the exact six-action control order"
for provider_action_call in \
  'visual_click_text "${name}" "Show API key" "show-key"' \
  'visual_click_text "${name}" "Hide API key" "hide-key"' \
  'visual_type_exact_pid "${name}" "Paste API key" "relaykit-ui-smoke-key" "type-key"' \
  'visual_click_text "${name}" "Test connection" "test-connection"' \
  'visual_click_text "${name}" "Use 1 reachable models" "use-reachable"' \
  'visual_click_text "${name}" Advanced "advanced"'; do
  grep -Fq "${provider_action_call}" "${SCRIPT}" || fail "provider action phase is not independent from its existing public label"
done

grep -Fq 'visual_click_text "${name}" "Save"' "${SCRIPT}" ||
  fail "provider light/dark final target must be exact English Save"
run_provider_type_before_expansion_contract() (
  local block_file edit_line health_line type_stage_line type_action_line hidden_line hidden_wait_line predicate_line
  local show_line hide_line test_line use_line advanced_line save_line masked_line
  block_file="$(mktemp /tmp/relaykit-provider-type-order-test.XXXXXX)"
  trap 'rm -f -- "${block_file}"' EXIT
  sed -n '/if \[\[ "${name}" == "provider-click-flow" || "${name}" == "provider-light" || "${name}" == "provider-dark" \]\]/,/if \[\[ "${name}" == "provider-test-failure" \]\]/p' "${SCRIPT}" >"${block_file}"
  [[ "$(grep -Fc 'set_provider_action_stage "${name}" "type-key"' "${block_file}")" == "1" ]] || fail "type-key stage must occur exactly once"
  [[ "$(grep -Fc 'visual_type_exact_pid "${name}" "Paste API key" "relaykit-ui-smoke-key" "type-key"' "${block_file}")" == "1" ]] ||
    fail "type-key action must occur exactly once"
  [[ "$(grep -Fc 'wait_for_jq "${evidence}" '\''.connect.api_key_saved_mask_control_visible == true'\''' "${block_file}")" == "2" ]] ||
    fail "existing masked waits were removed or duplicated"
  grep -Fq 'if [[ "${name}" != "provider-click-flow" ]]; then' "${block_file}" || fail "light/dark save condition changed"

  edit_line="$(grep -nF 'wait_for_provider_edit_ready "${evidence}"' "${block_file}" | head -1 | cut -d: -f1)"
  health_line="$(grep -nF 'set_provider_capture_stage "${name}" "health-ready-wait"' "${block_file}" | head -1 | cut -d: -f1)"
  type_stage_line="$(grep -nF 'set_provider_action_stage "${name}" "type-key"' "${block_file}" | cut -d: -f1)"
  type_action_line="$(grep -nF 'visual_type_exact_pid "${name}" "Paste API key" "relaykit-ui-smoke-key" "type-key"' "${block_file}" | cut -d: -f1)"
  masked_line=$((type_action_line + 1))
  sed -n "${masked_line}p" "${block_file}" | grep -Fq 'wait_for_jq "${evidence}" '\''.connect.api_key_saved_mask_control_visible == true'\''' ||
    fail "type-key masked wait is not immediately after the existing action"
  hidden_line="$(grep -nF 'set_provider_capture_stage "${name}" "hidden-models-click"' "${block_file}" | cut -d: -f1)"
  hidden_wait_line="$(grep -nF 'set_provider_capture_stage "${name}" "hidden-reasons-wait"' "${block_file}" | cut -d: -f1)"
  predicate_line="$(grep -nF 'provider_click_flow_specific_predicate "${evidence}"' "${block_file}" | cut -d: -f1)"
  show_line="$(grep -nF 'set_provider_action_stage "${name}" "show-key"' "${block_file}" | cut -d: -f1)"
  hide_line="$(grep -nF 'set_provider_action_stage "${name}" "hide-key"' "${block_file}" | cut -d: -f1)"
  test_line="$(grep -nF 'set_provider_action_stage "${name}" "test-connection"' "${block_file}" | cut -d: -f1)"
  use_line="$(grep -nF 'set_provider_action_stage "${name}" "use-reachable"' "${block_file}" | cut -d: -f1)"
  advanced_line="$(grep -nF 'set_provider_action_stage "${name}" "advanced"' "${block_file}" | cut -d: -f1)"
  save_line="$(grep -nF 'visual_click_text "${name}" "Save"' "${block_file}" | cut -d: -f1)"
  ((edit_line < health_line && health_line < type_stage_line && type_stage_line < type_action_line &&
    type_action_line < hidden_line && hidden_line < hidden_wait_line && hidden_wait_line < predicate_line &&
    predicate_line < show_line && show_line < hide_line && hide_line < test_line && test_line < use_line &&
    use_line < advanced_line && advanced_line < save_line)) || fail "provider flows do not preserve the fixed type-before-expansion order"
)
run_provider_type_before_expansion_contract

run_provider_english_save_contract() (
  local block_file save_line condition_line
  block_file="$(mktemp /tmp/relaykit-provider-save-target-test.XXXXXX)"
  trap 'rm -f -- "${block_file}"' EXIT
  sed -n '/if \[\[ "${name}" == "provider-click-flow" || "${name}" == "provider-light" || "${name}" == "provider-dark" \]\]/,/if \[\[ "${name}" == "provider-test-failure" \]\]/p' "${SCRIPT}" >"${block_file}"
  [[ "$(grep -Fc 'visual_click_text "${name}" "Save"' "${block_file}")" == "1" ]] ||
    fail "provider light/dark need exactly one shared exact Save action"
  condition_line="$(grep -nF 'if [[ "${name}" != "provider-click-flow" ]]; then' "${block_file}" | cut -d: -f1)"
  save_line="$(grep -nF 'visual_click_text "${name}" "Save"' "${block_file}" | cut -d: -f1)"
  ((condition_line < save_line)) || fail "provider click-flow was not excluded before the Save action"
  grep -Fq 'case "Save":' "${SCRIPT}" || fail "visual allowlist lacks exact English Save"
  grep -A1 -F 'case "Save":' "${SCRIPT}" | grep -Fq 'return ["provider-light", "provider-dark"].contains(flow)' ||
    fail "Save must be allowlisted only for provider-light and provider-dark"
  if grep -Fq '"保存"' "${SCRIPT}"; then
    fail "obsolete localized save target remains in the smoke harness"
  fi
)
run_provider_english_save_contract

run_visual_failure_mapping_contract() (
  RELAYKIT_MENU_BAR_E2E_SOURCE_ONLY=1 source "${SCRIPT}"
  local category expected_rc rc output output_file
  output_file="$(mktemp /tmp/relaykit-visual-observability-test.XXXXXX)"
  trap 'rm -f -- "${output_file}"' EXIT
  while IFS='|' read -r category expected_rc; do
    CURRENT_STAGE=bootstrap
    set +e
    return_visual_action_failure official-sheet click-text "${expected_rc}" >"${output_file}" 2>&1
    rc="$?"
    set -e
    output="$(<"${output_file}")"
    [[ -z "${output}" ]] || fail "visual failure mapping emitted dynamic content"
    [[ "${rc}" == "${expected_rc}" ]] || fail "visual failure mapping did not preserve rc=${expected_rc}"
    [[ "${CURRENT_STAGE}" == "flow.official-sheet.visual-click-text.${category}" ]] ||
      fail "visual failure mapping lost fixed category ${category}"
  done <<'CASES'
window-identity|71
capture|72
geometry|73
label-contract|74
ocr|75
ocr-empty|76
stale-window|77
temp|78
perform|79
duplicate-match|81
low-confidence|82
out-of-window-invalid-bounds|83
target-absent-current-flow|84
wrong-flow-anchors|85
nonempty-unclassified|86
select-text|87
input-text|88
CASES
  CURRENT_STAGE=bootstrap
  set +e
  return_visual_action_failure official-sheet click-text 99 >"${output_file}" 2>&1
  rc="$?"
  set -e
  [[ "${rc}" == "80" && "${CURRENT_STAGE}" == "flow.official-sheet.visual-click-text.internal" ]] ||
    fail "unknown visual failure did not map to the fixed internal category"
)

run_visual_failure_mapping_contract

grep -Fq 'run_isolated_extracted_app_verifier() (' "${PACKAGE_SCRIPT}" ||
  fail "extracted App verifier must run in its own isolated subshell"
package_verify_body="$(sed -n '/^run_isolated_extracted_app_verifier() (/,/^)/p' "${PACKAGE_SCRIPT}")"
grep -Fq 'mktemp -d /tmp/relaykit-package-verify.XXXXXX' <<<"${package_verify_body}" ||
  fail "extracted App verifier must own a guarded temporary root"
grep -Fq '/tmp/relaykit-package-verify.*|/private/tmp/relaykit-package-verify.*' <<<"${package_verify_body}" ||
  fail "extracted App verifier must validate its exact temporary-root prefix"
for isolated_name in HOME CFFIXED_USER_HOME CODEX_HOME TMPDIR RELAYKIT_RUNTIME_SAFETY_ROOT RELAYKIT_RUNTIME_SAFETY_TEST RELAYKIT_RUNTIME_SAFETY_PORT; do
  grep -Fq "${isolated_name}=" <<<"${package_verify_body}" ||
    fail "extracted App verifier does not isolate ${isolated_name}"
done
grep -Fq 'run_isolated_extracted_app_verifier "${verify_port}" "${EXTRACTED_APP}/Contents/MacOS/RelayKitApp.bin" --verify-bundled-gateway' "${PACKAGE_SCRIPT}" ||
  fail "package verification must route the extracted App through its isolated root"
grep -Fq 'RELAYKIT_PACKAGE_RELEASE_SOURCE_ONLY' "${PACKAGE_SCRIPT}" ||
  fail "package verifier contract needs a harmless source-only entrypoint"

run_package_verifier_isolation_contract() (
  RELAYKIT_PACKAGE_RELEASE_SOURCE_ONLY=1 source "${PACKAGE_SCRIPT}"
  local case_root fixture marker inherited_root recorded_root rc
  case_root="$(mktemp -d /tmp/relaykit-package-verify-test.XXXXXX)"
  trap 'rm -rf -- "${case_root}"' EXIT
  fixture="${case_root}/fixture.sh"
  marker="${case_root}/root.txt"
  cat >"${fixture}" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
marker="$1"
expected_port="$2"
exit_rc="$3"
[[ "${PWD}" == "${RELAYKIT_RUNTIME_SAFETY_ROOT}" ]]
[[ "${HOME}" == "${RELAYKIT_RUNTIME_SAFETY_ROOT}/home" ]]
[[ "${CFFIXED_USER_HOME}" == "${RELAYKIT_RUNTIME_SAFETY_ROOT}/preferences" ]]
[[ "${CODEX_HOME}" == "${RELAYKIT_RUNTIME_SAFETY_ROOT}/codex" ]]
[[ "${TMPDIR}" == "${RELAYKIT_RUNTIME_SAFETY_ROOT}/tmp/" ]]
[[ "${RELAYKIT_RUNTIME_SAFETY_TEST}" == "1" ]]
[[ "${RELAYKIT_RUNTIME_SAFETY_PORT}" == "${expected_port}" ]]
printf '%s\n' "${RELAYKIT_RUNTIME_SAFETY_ROOT}" >"${marker}"
exit "${exit_rc}"
SH
  chmod +x "${fixture}"
  inherited_root="${case_root}/inherited-must-not-be-used"
  RELAYKIT_RUNTIME_SAFETY_ROOT="${inherited_root}"
  HOME="${case_root}/caller-home"
  CFFIXED_USER_HOME="${case_root}/caller-prefs"
  CODEX_HOME="${case_root}/caller-codex"
  TMPDIR="${case_root}/caller-tmp/"

  run_isolated_extracted_app_verifier 43125 "${fixture}" "${marker}" 43125 0
  recorded_root="$(<"${marker}")"
  [[ "${recorded_root}" != "${inherited_root}" && ! -e "${recorded_root}" ]] ||
    fail "successful package verifier did not clean only its fresh isolated root"
  [[ "${HOME}" == "${case_root}/caller-home" && "${RELAYKIT_RUNTIME_SAFETY_ROOT}" == "${inherited_root}" ]] ||
    fail "package verifier modified caller environment"

  set +e
  run_isolated_extracted_app_verifier 43126 "${fixture}" "${marker}" 43126 29
  rc="$?"
  set -e
  [[ "${rc}" == "29" ]] || fail "package verifier did not preserve extracted App rc=29"
  recorded_root="$(<"${marker}")"
  [[ "${recorded_root}" != "${inherited_root}" && ! -e "${recorded_root}" ]] ||
    fail "failed package verifier did not clean only its fresh isolated root"
)

run_package_verifier_isolation_contract

grep -Fq 'run_isolated_app_verifier() (' "${BUILD_SCRIPT}" ||
  fail "bundle verifier must run in its own isolated subshell"
verify_body="$(sed -n '/^run_isolated_app_verifier() (/,/^)/p' "${BUILD_SCRIPT}")"
grep -Fq 'mktemp -d /tmp/relaykit-bundle-verify.XXXXXX' <<<"${verify_body}" ||
  fail "bundle verifier must own a guarded temporary root"
grep -Fq '/tmp/relaykit-bundle-verify.*|/private/tmp/relaykit-bundle-verify.*' <<<"${verify_body}" ||
  fail "bundle verifier must validate its exact temporary-root prefix"
for isolated_name in HOME CFFIXED_USER_HOME CODEX_HOME TMPDIR RELAYKIT_RUNTIME_SAFETY_ROOT RELAYKIT_RUNTIME_SAFETY_TEST RELAYKIT_RUNTIME_SAFETY_PORT; do
  grep -Fq "${isolated_name}=" <<<"${verify_body}" ||
    fail "bundle verifier does not isolate ${isolated_name}"
done
grep -Fq 'run_isolated_app_verifier "${verify_port}" "${APP_REAL_BINARY}" --verify-bundled-gateway' "${BUILD_SCRIPT}" ||
  fail "bundle verification must call the App verifier through the isolated root"
grep -Fq 'RELAYKIT_BUILD_APP_BUNDLE_SOURCE_ONLY' "${BUILD_SCRIPT}" ||
  fail "bundle verifier contract needs a harmless source-only entrypoint"

run_bundle_verifier_isolation_contract() (
  RELAYKIT_BUILD_APP_BUNDLE_SOURCE_ONLY=1 source "${BUILD_SCRIPT}"
  local case_root fixture marker inherited_root recorded_root rc
  case_root="$(mktemp -d /tmp/relaykit-bundle-verify-test.XXXXXX)"
  trap 'rm -rf -- "${case_root}"' EXIT
  fixture="${case_root}/fixture.sh"
  marker="${case_root}/root.txt"
  cat >"${fixture}" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
marker="$1"
expected_port="$2"
exit_rc="$3"
[[ "${PWD}" == "${RELAYKIT_RUNTIME_SAFETY_ROOT}" ]]
[[ "${HOME}" == "${RELAYKIT_RUNTIME_SAFETY_ROOT}/home" ]]
[[ "${CFFIXED_USER_HOME}" == "${RELAYKIT_RUNTIME_SAFETY_ROOT}/preferences" ]]
[[ "${CODEX_HOME}" == "${RELAYKIT_RUNTIME_SAFETY_ROOT}/codex" ]]
[[ "${TMPDIR}" == "${RELAYKIT_RUNTIME_SAFETY_ROOT}/tmp/" ]]
[[ "${RELAYKIT_RUNTIME_SAFETY_TEST}" == "1" ]]
[[ "${RELAYKIT_RUNTIME_SAFETY_PORT}" == "${expected_port}" ]]
printf '%s\n' "${RELAYKIT_RUNTIME_SAFETY_ROOT}" >"${marker}"
exit "${exit_rc}"
SH
  chmod +x "${fixture}"
  inherited_root="${case_root}/inherited-must-not-be-used"
  RELAYKIT_RUNTIME_SAFETY_ROOT="${inherited_root}"
  HOME="${case_root}/caller-home"
  CFFIXED_USER_HOME="${case_root}/caller-prefs"
  CODEX_HOME="${case_root}/caller-codex"
  TMPDIR="${case_root}/caller-tmp/"

  run_isolated_app_verifier 43123 "${fixture}" "${marker}" 43123 0
  recorded_root="$(<"${marker}")"
  [[ "${recorded_root}" != "${inherited_root}" && ! -e "${recorded_root}" ]] ||
    fail "successful verifier did not clean only its fresh isolated root"
  [[ "${HOME}" == "${case_root}/caller-home" && "${RELAYKIT_RUNTIME_SAFETY_ROOT}" == "${inherited_root}" ]] ||
    fail "isolated verifier modified caller environment"

  set +e
  run_isolated_app_verifier 43124 "${fixture}" "${marker}" 43124 23
  rc="$?"
  set -e
  [[ "${rc}" == "23" ]] || fail "isolated verifier did not preserve App verifier rc=23"
  recorded_root="$(<"${marker}")"
  [[ "${recorded_root}" != "${inherited_root}" && ! -e "${recorded_root}" ]] ||
    fail "failed verifier did not clean only its fresh isolated root"
)

run_bundle_verifier_isolation_contract

grep -Fq 'RELAYKIT_RUNTIME_SAFETY_ROOT="${RUNTIME_ROOT}"' "${SCRIPT}" ||
  fail "every smoke App launch must export the guarded runtime-safety root"
grep -Fq '/usr/bin/ditto "${SOURCE_APP_BUNDLE}" "${APP_BUNDLE}"' "${SCRIPT}" ||
  fail "menu smoke must copy the complete verified source App bundle with ditto"
grep -Fq 'APP_BUNDLE="${RUNTIME_ROOT}/RelayKitApp.app"' "${SCRIPT}" ||
  fail "copied App bundle must live directly under the guarded runtime root"
grep -Fq 'APP_REAL="${APP_BUNDLE}/Contents/MacOS/RelayKitApp.bin"' "${SCRIPT}" ||
  fail "App identity must bind to the copied bundle internal Mach-O"
grep -Fq 'BUNDLED_RELAY="${APP_BUNDLE}/Contents/MacOS/relay"' "${SCRIPT}" ||
  fail "gateway identity must bind to the copied bundle internal helper"
grep -Fq '/usr/bin/codesign --verify --deep --strict "${APP_BUNDLE}"' "${SCRIPT}" ||
  fail "copied App bundle must pass deep strict verification before launch"
if grep -Eq 'cp "\$\{SOURCE_APP_BUNDLE\}/Contents/MacOS/(RelayKitApp\.bin|relay)"|chmod .*APP_REAL|rm -[fr]+ .*APP_BUNDLE' "${SCRIPT}"; then
  fail "menu smoke must not materialize, modify, or delete bare copied executables"
fi
if grep -Fq '/usr/bin/open' "${SCRIPT}"; then
  fail "menu smoke must preserve exact direct-child launch identity"
fi
grep -Fq 'export HOME CFFIXED_USER_HOME CODEX_HOME TMPDIR RELAYKIT_RUNTIME_SAFETY_ROOT' "${SCRIPT}" ||
  fail "runtime-safety root must be exported with the existing isolation defense"
launch_body="$(sed -n '/^launch_isolated_app() {/,/^}/p' "${SCRIPT}")"
grep -Fq 'set_capture_app_launch_stage() {' "${SCRIPT}" ||
  fail "isolated App launch needs a fixed capture-context stage mapper"
run_capture_app_launch_stage_contract() (
  RELAYKIT_MENU_BAR_E2E_SOURCE_ONLY=1 source "${SCRIPT}"
  local context phase expected rc
  local -a contexts=(
    connect official-sheet real-demo provider-click-flow provider-test-failure
    detail detail-advanced-expanded detail-advanced-collapsed import usage
    usage-auto-refresh usage-large usage-1m usage-1y usage-empty settings
    settings-developer-expanded settings-light usage-light official-light
    provider-light settings-dark usage-dark official-dark provider-dark provider
    real-quit outside-click
  )
  for context in "${contexts[@]}"; do
    for phase in spawn identity-wait register; do
      CURRENT_STAGE=bootstrap
      set_capture_app_launch_stage "${context}" "${phase}"
      expected="capture.${context}.app-launch.${phase}"
      [[ "${CURRENT_STAGE}" == "${expected}" ]] || fail "App launch stage mapping lost ${expected}"
    done
    for phase in pid-invalid pid-not-alive proc-pidpath-unavailable expected-canonical-unavailable executable-mismatch success; do
      CURRENT_STAGE=bootstrap
      set_capture_app_identity_stage "${context}" "${phase}"
      expected="capture.${context}.app-identity.${phase}"
      [[ "${CURRENT_STAGE}" == "${expected}" ]] || fail "App identity stage mapping lost ${expected}"
    done
  done
  CURRENT_STAGE=bootstrap
  if set_capture_app_launch_stage invalid-context spawn >/dev/null 2>&1; then
    fail "invalid App launch context was accepted"
  else
    rc="$?"
  fi
  [[ "${rc}" == "2" && "${CURRENT_STAGE}" == "bootstrap" ]] ||
    fail "invalid App launch context did not fail with rc2 before launch staging"
  CURRENT_STAGE=bootstrap
  if set_capture_app_launch_stage connect invalid-phase >/dev/null 2>&1; then
    fail "invalid App launch phase was accepted"
  else
    rc="$?"
  fi
  [[ "${rc}" == "2" && "${CURRENT_STAGE}" == "bootstrap" ]] ||
    fail "invalid App launch phase did not fail with rc2 before spawn"
)
run_capture_app_launch_stage_contract
run_capture_app_identity_failure_contract() (
  RELAYKIT_MENU_BAR_E2E_SOURCE_ONLY=1 source "${SCRIPT}"
  eval "$(sed -n '/^require_app_identity() {/,/^}/p' "${SCRIPT}")"
  local category expected_rc rc output output_file
  output_file="$(mktemp /tmp/relaykit-app-identity-category-test.XXXXXX)"
  trap 'rm -f -- "${output_file}"' EXIT
  while IFS='|' read -r category expected_rc; do
    CURRENT_STAGE=bootstrap
    PID=321
    APP_REAL=/public/RelayKitApp.bin
    visual_pid_is_alive() { return 0; }
    process_executable_path() { printf '%s\n' /public/RelayKitApp.bin; }
    canonical_executable_path() { printf '%s\n' /public/RelayKitApp.bin; }
    case "${category}" in
      pid-invalid) PID=invalid ;;
      pid-not-alive) visual_pid_is_alive() { return 1; } ;;
      proc-pidpath-unavailable) process_executable_path() { return 1; } ;;
      expected-canonical-unavailable) canonical_executable_path() { return 1; } ;;
      executable-mismatch) process_executable_path() { printf '%s\n' /public/wrong; } ;;
    esac
    if require_app_identity connect >"${output_file}" 2>&1; then
      rc=0
    else
      rc="$?"
    fi
    output="$(<"${output_file}")"
    [[ "${rc}" == "${expected_rc}" ]] || fail "App identity ${category} did not preserve fixed rc${expected_rc}"
    [[ "${CURRENT_STAGE}" == "capture.connect.app-identity.${category}" ]] || fail "App identity stage lost ${category}"
    [[ "${output}" == "isolated RelayKit PID identity changed" ]] || fail "App identity ${category} output changed or exposed values"
  done <<'IDENTITY_FAILURES'
pid-invalid|1
pid-not-alive|1
proc-pidpath-unavailable|1
expected-canonical-unavailable|1
executable-mismatch|1
IDENTITY_FAILURES

  CURRENT_STAGE=bootstrap
  PID=321
  APP_REAL=/public/RelayKitApp.bin
  visual_pid_is_alive() { return 0; }
  process_executable_path() { printf '%s\n' /public/RelayKitApp.bin; }
  canonical_executable_path() { printf '%s\n' /public/RelayKitApp.bin; }
  require_app_identity connect >"${output_file}" 2>&1
  [[ ! -s "${output_file}" && "${CURRENT_STAGE}" == "capture.connect.app-identity.success" ]] ||
    fail "successful App identity check was not silent or lost its fixed stage"

  CURRENT_STAGE=bootstrap
  PID=invalid
  if require_app_identity invalid-context >"${output_file}" 2>&1; then
    fail "invalid App identity context was accepted"
  else
    rc="$?"
  fi
  [[ "${rc}" == "2" && "${CURRENT_STAGE}" == "bootstrap" && ! -s "${output_file}" ]] ||
    fail "invalid App identity context did not fail with rc2 before PID inspection"
)
run_capture_app_identity_failure_contract
if grep -Fq 'set_stage app.launch' "${SCRIPT}"; then
  fail "generic app.launch stage must not remain"
fi
[[ "$(grep -c '^  launch_isolated_app ' "${SCRIPT}")" == "3" ]] || fail "not all isolated App launch callsites have fixed contexts"
grep -Fq 'launch_isolated_app "${name}" "${TMPDIR}ui-smoke.log"' "${SCRIPT}" || fail "capture(name) did not pass its exact context"
grep -Fq 'launch_isolated_app real-quit "${TMPDIR}real-quit.log"' "${SCRIPT}" || fail "real Quit launch lacks its fixed context"
grep -Fq 'launch_isolated_app outside-click "${TMPDIR}outside-click.log"' "${SCRIPT}" || fail "outside-click launch lacks its fixed context"
grep -Fq 'cd "${RUNTIME_ROOT}"' <<<"${launch_body}" ||
  fail "isolated App launcher must change to the guarded runtime root"
grep -Fq 'exec "${APP_REAL}" "$@"' <<<"${launch_body}" ||
  fail "isolated App launcher must exec the exact unpackaged App"
grep -Fq 'PID="$!"' <<<"${launch_body}" ||
  fail "parent must retain the literal direct-child PID"
launch_pid_line="$(grep -nF 'PID="$!"' <<<"${launch_body}" | cut -d: -f1)"
launch_wait_line="$(grep -nF 'wait_for_process_executable_match "${PID}" "${APP_REAL}"' <<<"${launch_body}" | cut -d: -f1 || true)"
launch_register_line="$(grep -nF 'register_owned_pid "${PID}" "${APP_REAL}"' <<<"${launch_body}" | cut -d: -f1)"
launch_spawn_stage_line="$(grep -nF 'set_capture_app_launch_stage "${context}" spawn' <<<"${launch_body}" | cut -d: -f1 || true)"
launch_wait_stage_line="$(grep -nF 'set_capture_app_launch_stage "${context}" identity-wait' <<<"${launch_body}" | cut -d: -f1 || true)"
launch_register_stage_line="$(grep -nF 'set_capture_app_launch_stage "${context}" register' <<<"${launch_body}" | cut -d: -f1 || true)"
[[ -n "${launch_wait_line}" ]] || fail "App launch must wait for the direct child executable identity before registration"
[[ -n "${launch_spawn_stage_line}" && -n "${launch_wait_stage_line}" && -n "${launch_register_stage_line}" ]] ||
  fail "App launch lacks fixed spawn, identity-wait, or register substages"
((launch_spawn_stage_line < launch_pid_line && launch_pid_line < launch_wait_stage_line &&
  launch_wait_stage_line < launch_wait_line && launch_wait_line < launch_register_stage_line &&
  launch_register_stage_line < launch_register_line)) ||
  fail "App launch substage order does not bind spawn, PID, wait, and registration"
[[ "$(grep -Fc 'wait_for_process_executable_match "${PID}" "${APP_REAL}"' <<<"${launch_body}")" == "1" ]] ||
  fail "App launcher must perform exactly one bounded executable match"
wait_match_body="$(sed -n '/^wait_for_process_executable_match() {/,/^}/p' "${SCRIPT}")"
grep -Fq 'for attempt in {1..40}; do' <<<"${wait_match_body}" || fail "App identity wait lost its 40-attempt bound"
grep -Fq 'kill -0 "${pid}" 2>/dev/null || return 1' <<<"${wait_match_body}" || fail "App identity wait lost strict early-death handling"
grep -Fq 'sleep 0.05' <<<"${wait_match_body}" || fail "App identity wait lost its 50ms interval"
if grep -Fq 'wait_for_process_executable_match "${PID}" "${APP_REAL}" || true' <<<"${launch_body}"; then
  fail "App identity wait RC must not be ignored"
fi
if grep -Fq 'cd "${ROOT}"' <<<"${launch_body}"; then
  fail "isolated App launcher must never use the repository working directory"
fi
if grep -Fq 'set_stage app.identity' "${SCRIPT}"; then
  fail "generic app.identity stage must not remain"
fi
require_identity_body="$(sed -n '/^require_app_identity() {/,/^}/p' "${SCRIPT}")"
grep -Fq 'capture_context_is_valid "${context}" || return $?' <<<"${require_identity_body}" ||
  fail "require_app_identity must validate the capture context before PID inspection"
if grep -Eq 'sleep |for .* in ' <<<"${require_identity_body}"; then
  fail "require_app_identity must not add waits or retries"
fi
grep -Fq 'require_app_identity "${context}"' "${SCRIPT}" || fail "shared capture prefix identity check lacks its fixed context"
grep -Fq 'require_app_identity real-quit' "${SCRIPT}" || fail "real Quit identity check lacks fixed context"
grep -Fq 'require_app_identity outside-click' "${SCRIPT}" || fail "outside-click identity check lacks fixed context"
while IFS= read -r launch_line; do
  for required_arg in --ui-smoke --ui-smoke-skip-gateway-exercise --ui-smoke-evidence --ui-smoke-usage-log --ui-smoke-appearance; do
    grep -Fq -- "${required_arg}" <<<"${launch_line}" ||
      fail "full-bundle App launch lacks ${required_arg}"
  done
done < <(grep 'launch_isolated_app .*--ui-smoke' "${SCRIPT}")
if grep -Fq '/usr/bin/defaults' "${SCRIPT}"; then
  fail "UI smoke must not read, write, restore, or delete defaults"
fi
if grep -Eq 'dist/codex-desktop-acceptance|prepare_final_bundle_desktop_acceptance_evidence|DESKTOP_ACCEPTANCE_SOURCE' "${SCRIPT}"; then
  fail "UI smoke must not read or copy historical Desktop acceptance evidence"
fi
grep -Fq -- '--ui-smoke-appearance "${appearance}"' "${SCRIPT}" ||
  fail "every UI smoke must pass one reviewed explicit appearance argument"

while IFS= read -r capture_line; do
  grep -Fq -- '--ui-smoke-provider-config' <<<"${capture_line}" ||
    fail "hardcoded UI smoke capture lacks an explicit provider path: ${capture_line}"
done < <(grep '^capture [a-z0-9-].*--ui-smoke' "${SCRIPT}")

real_quit_body="$(sed -n '/^capture_real_quit_menu() {/,/^}/p' "${SCRIPT}")"
for required_arg in --ui-smoke --ui-smoke-skip-gateway-exercise --ui-smoke-provider-config --ui-smoke-evidence --ui-smoke-usage-log; do
  grep -Fq -- "${required_arg}" <<<"${real_quit_body}" ||
    fail "real Quit launch lacks ${required_arg}"
done
grep -Fq 'status_item_is_ready() {' "${SCRIPT}" || fail "real Quit needs a read-only status-item readiness probe"
grep -Fq 'wait_for_status_item_ready() {' "${SCRIPT}" || fail "real Quit needs a bounded status-item readiness wait"
grep -Fq 'status_item_selector() {' "${SCRIPT}" || fail "probe and open need one shared status-item selector"
grep -Fq 'press_unique_status_item() {' "${SCRIPT}" || fail "outside missing-window recovery needs exact status-item AXPress"
status_ready_body="$(sed -n '/^status_item_is_ready() {/,/^}/p' "${SCRIPT}")"
status_wait_body="$(sed -n '/^wait_for_status_item_ready() {/,/^}/p' "${SCRIPT}")"
status_selector_body="$(sed -n '/^status_item_selector() {/,/^}/p' "${SCRIPT}")"
grep -Fq 'status_item_selector probe' <<<"${status_ready_body}" || fail "readiness must use shared selector probe mode"
grep -Fq 'process_executable_matches "${PID}" "${APP_REAL}" || return 31' <<<"${status_selector_body}" ||
  fail "status-item readiness must bind the exact PID to APP_REAL"
grep -Fq 'expected_executable="$(canonical_executable_path "${APP_REAL}")"' <<<"${status_selector_body}" ||
  fail "status-item selector did not canonicalize APP_REAL before Swift"
grep -Fq 'swift - "${mode}" "${PID}" "${expected_executable}"' <<<"${status_selector_body}" ||
  fail "status-item Swift selector must receive canonical APP_REAL"
[[ "$(grep -Fc 'proc_pidpath' <<<"${status_selector_body}")" -ge 1 &&
   "$(grep -Fc 'identityMatches(pid: pid, expectedExecutable: expectedExecutable)' <<<"${status_selector_body}")" -ge 2 ]] ||
  fail "status-item Swift selector lacks pre-traversal and pre-action PID identity checks"
if grep -Fq 'kAXMenuBarAttribute' <<<"${status_selector_body}"; then fail "shared selector must not depend on kAXMenuBarAttribute"; fi
for selector_contract in \
  'AXUIElementCreateApplication(pid)' \
  'kAXChildrenAttribute' \
  'let maxDepth = 6' \
  'let maxVisited = 128' \
  'CFEqual' \
  'role == "AXMenuBarItem"' \
  'description == "RelayKit"'; do
  grep -Fq "${selector_contract}" <<<"${status_selector_body}" || fail "shared recursive selector lacks ${selector_contract}"
done
grep -Fq 'candidates.count == 1' <<<"${status_selector_body}" || fail "shared status-item selector must reject zero or ambiguous recursive AX items"
for synthetic_contract in \
  'syntheticNested' \
  'syntheticZero' \
  'syntheticDuplicate' \
  'syntheticCycle' \
  'syntheticDepthBudget' \
  'syntheticNodeBudget' \
  'syntheticInvalidGeometry' \
  'syntheticRoleDescription' \
  'syntheticEventCounts'; do
  grep -Fq "${synthetic_contract}" <<<"${status_selector_body}" || fail "shared recursive selector lacks ${synthetic_contract} coverage"
done
grep -Fq 'kAXPositionAttribute' <<<"${status_selector_body}" || fail "shared status-item selector lacks position selection"
grep -Fq 'size.width > 0, size.height > 0' <<<"${status_selector_body}" || fail "shared status-item selector must require positive size"
grep -Fq 'let point = CGPoint(x: position.x + size.width / 2, y: position.y + size.height / 2)' <<<"${status_selector_body}" ||
  fail "shared status-item selector must derive one center from the selected item"
selector_role_line="$(grep -nF 'kAXRoleAttribute' <<<"${status_selector_body}" | head -1 | cut -d: -f1 || true)"
selector_description_line="$(grep -nF 'kAXDescriptionAttribute' <<<"${status_selector_body}" | head -1 | cut -d: -f1 || true)"
selector_children_line="$(grep -nF 'let children = try childElements(element, isRoot: isRoot)' <<<"${status_selector_body}" | head -1 | cut -d: -f1 || true)"
selector_candidate_line="$(grep -nF 'role == "AXMenuBarItem" && description == "RelayKit"' <<<"${status_selector_body}" | tail -1 | cut -d: -f1 || true)"
selector_position_line="$(grep -nF 'kAXPositionAttribute' <<<"${status_selector_body}" | head -1 | cut -d: -f1 || true)"
[[ -n "${selector_role_line}" && -n "${selector_description_line}" && -n "${selector_children_line}" && -n "${selector_candidate_line}" && -n "${selector_position_line}" ]] ||
  fail "shared selector attribute-read order is incomplete"
((selector_role_line < selector_description_line && selector_description_line < selector_children_line &&
  selector_children_line < selector_candidate_line && selector_candidate_line < selector_position_line)) ||
  fail "shared selector must read role, description, and children before candidate geometry"
if grep -Eq 'kAXMenuBarAttribute|kAXTitleAttribute|kAXValueAttribute|kAXContentsAttribute|CGWindow|NSScreen|System Events|position\.x >=|position\.y >=' <<<"${status_selector_body}"; then
  fail "shared selector used forbidden menu-bar, title/value/content, window/screen, other-process, or nonnegative-position paths"
fi
grep -Fq 'for attempt in {1..40}; do' <<<"${status_wait_body}" || fail "status-item readiness wait lost its 40-attempt bound"
grep -Fq 'sleep 0.05' <<<"${status_wait_body}" || fail "status-item readiness wait lost its 50ms interval"
grep -Fq 'set_status_item_readiness_stage death' <<<"${status_wait_body}" || fail "status-item readiness wait lacks death classification"
[[ "$(grep -Fc 'open_unique_status_menu' <<<"${status_wait_body}")" == "0" ]] || fail "status-item readiness wait must not retry the click"
[[ "$(grep -Fc 'open_unique_status_menu' <<<"${real_quit_body}")" == "1" ]] || fail "real Quit must open the status menu exactly once"
status_wait_line="$(grep -nF 'wait_for_status_item_ready' <<<"${real_quit_body}" | cut -d: -f1 || true)"
status_open_line="$(grep -nF 'open_unique_status_menu' <<<"${real_quit_body}" | cut -d: -f1)"
[[ -n "${status_wait_line}" ]] || fail "real Quit does not wait for status-item readiness"
((status_open_line == status_wait_line + 2)) || fail "real Quit must wait, set open-action, then perform its single existing menu open"
open_status_body="$(sed -n '/^open_unique_status_menu() {/,/^}/p' "${SCRIPT}")"
grep -Fq 'status_item_selector open' <<<"${open_status_body}" || fail "menu open must use shared selector open mode"
probe_return_line="$(grep -nF 'if mode == "probe" { exit(0) }' <<<"${status_selector_body}" | cut -d: -f1 || true)"
first_event_line="$(grep -nF 'CGEventSource' <<<"${status_selector_body}" | head -1 | cut -d: -f1 || true)"
[[ -n "${probe_return_line}" && -n "${first_event_line}" && "${probe_return_line}" -lt "${first_event_line}" ]] ||
  fail "probe mode must return before any CGEvent creation"
[[ "$(grep -Fc '.rightMouseDown' <<<"${status_selector_body}")" == "1" && "$(grep -Fc '.rightMouseUp' <<<"${status_selector_body}")" == "1" ]] ||
  fail "existing rightMouseDown/rightMouseUp action count changed"
grep -Fq 'usleep(100_000)' <<<"${status_selector_body}" || fail "status-item open lost its 100ms down/up interval"
status_press_body="$(sed -n '/^press_unique_status_item() {/,/^}/p' "${SCRIPT}")"
grep -Fq 'status_item_selector press' <<<"${status_press_body}" || fail "status-item recovery must reuse the exact PID-root selector in press mode"
for status_press_contract in \
  'if mode == "press"' \
  'kAXEnabledAttribute' \
  'enabled == true' \
  'actions.contains(kAXPressAction as String)' \
  'AXUIElementPerformAction(candidates[0], kAXPressAction as CFString)'; do
  grep -Fq "${status_press_contract}" <<<"${status_selector_body}" || fail "status-item AXPress lacks ${status_press_contract}"
done
[[ "$(grep -Fc 'AXUIElementPerformAction(candidates[0], kAXPressAction as CFString)' <<<"${status_selector_body}")" == "1" ]] ||
  fail "status-item AXPress must perform exactly once"
for status_press_synthetic in \
  syntheticStatusPressZero \
  syntheticStatusPressDuplicate \
  syntheticStatusPressDisabled \
  syntheticStatusPressMissingAction \
  syntheticStatusPressPerformFailure \
  syntheticStatusPressCount; do
  grep -Fq "${status_press_synthetic}" <<<"${status_selector_body}" || fail "status-item AXPress synthetic contract lacks ${status_press_synthetic}"
done
run_status_item_readiness_category_contract() (
  RELAYKIT_MENU_BAR_E2E_SOURCE_ONLY=1 source "${SCRIPT}"
  local internal_rc category rc output output_file calls sleeps selector_root
  output_file="$(mktemp /tmp/relaykit-status-readiness-category-test.XXXXXX)"
  selector_root="$(mktemp -d /tmp/relaykit-status-selector-synthetic-test.XXXXXX)"
  trap 'rm -f -- "${output_file}"; rm -rf -- "${selector_root}"' EXIT

  TMPDIR="${selector_root}/"
  PID=0
  APP_REAL="${selector_root}/RelayKitApp"
  : >"${APP_REAL}"
  set +e
  RELAYKIT_STATUS_ITEM_SELECTOR_SYNTHETIC_TEST=1 status_item_selector probe
  rc="$?"
  set -e
  [[ "${rc}" == "0" ]] || fail "recursive status-item synthetic contract failed with rc${rc}"
  [[ "$(<"${TMPDIR}status-item-selector.log")" == "Status item selector synthetic contract passed" ]] ||
    fail "recursive status-item synthetic contract did not return its fixed public-safe result"
  set +e
  RELAYKIT_STATUS_ITEM_SELECTOR_SYNTHETIC_TEST=1 status_item_selector press
  rc="$?"
  set -e
  [[ "${rc}" == "0" && "$(<"${TMPDIR}status-item-selector.log")" == "Status item selector synthetic contract passed" ]] ||
    fail "status-item AXPress synthetic contract failed"
  while IFS='|' read -r internal_rc category; do
    CURRENT_STAGE=bootstrap
    set_status_item_readiness_stage "${internal_rc}"
    [[ "${CURRENT_STAGE}" == "capture.real-quit.status-menu.readiness-wait.${category}" ]] ||
      fail "status-item readiness mapping lost ${category}"
  done <<'READINESS_MAPPINGS'
0|ready
31|process-id
32|root-traversal
33|unique-item
35|positive-size
36|internal
37|budget
READINESS_MAPPINGS
  CURRENT_STAGE=bootstrap
  if set_status_item_readiness_stage 99 >"${output_file}" 2>&1; then
    fail "invalid status-item readiness input was accepted"
  else
    rc="$?"
  fi
  [[ "${rc}" == "2" && "${CURRENT_STAGE}" == "bootstrap" && ! -s "${output_file}" ]] ||
    fail "invalid status-item readiness input did not fail silently with rc2"
  process_executable_matches() { fail "invalid selector mode inspected process identity"; }
  if status_item_selector invalid-mode >"${output_file}" 2>&1; then
    fail "invalid shared status-item selector mode was accepted"
  else
    rc="$?"
  fi
  [[ "${rc}" == "2" && ! -s "${output_file}" ]] || fail "invalid selector mode did not fail silently with rc2"

  CURRENT_STAGE=bootstrap
  status_item_is_ready() { return 0; }
  kill() { fail "ready status item unexpectedly checked process death"; }
  sleep() { fail "ready status item unexpectedly slept"; }
  wait_for_status_item_ready >"${output_file}" 2>&1
  [[ "${CURRENT_STAGE}" == "capture.real-quit.status-menu.readiness-wait.ready" && ! -s "${output_file}" ]] ||
    fail "ready status item did not return silently with its fixed stage"

  CURRENT_STAGE=bootstrap
  status_item_is_ready() { return 31; }
  kill() { return 1; }
  sleep() { fail "dead status-item process unexpectedly slept"; }
  if wait_for_status_item_ready >"${output_file}" 2>&1; then
    fail "dead status-item process was accepted"
  else
    rc="$?"
  fi
  [[ "${rc}" == "1" && "${CURRENT_STAGE}" == "capture.real-quit.status-menu.readiness-wait.death" && ! -s "${output_file}" ]] ||
    fail "status-item process death did not map silently to external rc1"

  while IFS='|' read -r internal_rc category; do
    CURRENT_STAGE=bootstrap
    calls=0
    sleeps=0
    status_item_is_ready() { calls=$((calls + 1)); return "${internal_rc}"; }
    kill() { return 0; }
    sleep() { [[ "$1" == "0.05" ]] || fail "status readiness used a non-50ms sleep"; sleeps=$((sleeps + 1)); }
    if wait_for_status_item_ready >"${output_file}" 2>&1; then
      fail "timed-out status-item category ${category} was accepted"
    else
      rc="$?"
    fi
    [[ "${rc}" == "1" && "${calls}" == "40" && "${sleeps}" == "40" && ! -s "${output_file}" ]] ||
      fail "status-item ${category} timeout lost external rc1, silence, or 40x50ms budget"
    [[ "${CURRENT_STAGE}" == "capture.real-quit.status-menu.readiness-wait.${category}" ]] ||
      fail "status-item timeout lost final category ${category}"
  done <<'READINESS_TIMEOUTS'
31|process-id
32|root-traversal
33|unique-item
35|positive-size
36|internal
37|budget
READINESS_TIMEOUTS
)
run_status_item_readiness_category_contract
grep -Fq 'press_unique_quit_menu_item() {' "${SCRIPT}" || fail "real Quit needs an exact PID-owned AXPress helper"
quit_press_body="$(sed -n '/^press_unique_quit_menu_item() {/,/^}/p' "${SCRIPT}")"
grep -Fq 'process_executable_matches "${PID}" "${APP_REAL}"' <<<"${quit_press_body}" ||
  fail "Quit AXPress must bind the exact PID to APP_REAL"
grep -Fq 'expected_executable="$(canonical_executable_path "${APP_REAL}")"' <<<"${quit_press_body}" ||
  fail "Quit AXPress did not canonicalize APP_REAL before Swift"
grep -Fq 'swift - "${PID}" "${expected_executable}"' <<<"${quit_press_body}" ||
  fail "Quit Swift AXPress must receive canonical APP_REAL"
[[ "$(grep -Fc 'proc_pidpath' <<<"${quit_press_body}")" -ge 1 &&
   "$(grep -Fc 'identityMatches(pid: pid, expectedExecutable: expectedExecutable)' <<<"${quit_press_body}")" -ge 2 ]] ||
  fail "Quit Swift AXPress lacks pre-traversal and immediate pre-action PID identity checks"
for quit_press_contract in \
  'AXUIElementCreateApplication(pid)' \
  'kAXChildrenAttribute' \
  'let maxDepth = 6' \
  'let maxVisited = 128' \
  'CFEqual' \
  'role == "AXMenuItem"' \
  'title == "Quit RelayKit" || name == "Quit RelayKit"' \
  'candidates.count == 1' \
  'enabled == true' \
  'actions.contains(kAXPressAction as String)' \
  'AXUIElementPerformAction(candidates[0], kAXPressAction as CFString)'; do
  grep -Fq "${quit_press_contract}" <<<"${quit_press_body}" || fail "exact Quit AXPress helper lacks ${quit_press_contract}"
done
for quit_synthetic_contract in \
  syntheticNestedQuit \
  syntheticZeroQuit \
  syntheticDuplicateQuit \
  syntheticDisabledQuit \
  syntheticMissingActionQuit \
  syntheticCycleQuit \
  syntheticDepthBudgetQuit \
  syntheticNodeBudgetQuit \
  syntheticPerformFailureQuit \
  syntheticEventCountsQuit; do
  grep -Fq "${quit_synthetic_contract}" <<<"${quit_press_body}" || fail "Quit AXPress synthetic contract lacks ${quit_synthetic_contract}"
done
[[ "$(grep -Fc 'AXUIElementPerformAction(candidates[0], kAXPressAction as CFString)' <<<"${quit_press_body}")" == "1" ]] ||
  fail "Quit AXPress helper must perform exactly one action"
if grep -Eq 'CGEvent|System Events|osascript|visual_click_text|keyboard|keyDown|mouse|position|kAXPosition|kAXSize|kill |sleep |signal' <<<"${quit_press_body}"; then
  fail "Quit AXPress helper used a forbidden fallback, event, coordinate, signal, or retry path"
fi
grep -Fq 'set_real_quit_press_stage() {' "${SCRIPT}" || fail "Quit AXPress failures need fixed public-safe categories"
run_quit_press_contract() (
  RELAYKIT_MENU_BAR_E2E_SOURCE_ONLY=1 source "${SCRIPT}"
  local internal_rc category rc output_file selector_root
  output_file="$(mktemp /tmp/relaykit-quit-press-category-test.XXXXXX)"
  selector_root="$(mktemp -d /tmp/relaykit-quit-press-synthetic-test.XXXXXX)"
  trap 'rm -f -- "${output_file}"; rm -rf -- "${selector_root}"' EXIT

  TMPDIR="${selector_root}/"
  PID=0
  APP_REAL="${selector_root}/RelayKitApp"
  : >"${APP_REAL}"
  CURRENT_STAGE=bootstrap
  set +e
  RELAYKIT_QUIT_PRESS_SYNTHETIC_TEST=1 press_unique_quit_menu_item
  rc="$?"
  set -e
  [[ "${rc}" == "0" && "${CURRENT_STAGE}" == "capture.real-quit.quit-click.pressed" ]] ||
    fail "synthetic Quit AXPress contract did not complete with its fixed success category"
  [[ "$(<"${TMPDIR}quit-menu-item-press.log")" == "Quit menu item synthetic contract passed" ]] ||
    fail "synthetic Quit AXPress contract did not return its fixed public-safe result"

  while IFS='|' read -r internal_rc category; do
    CURRENT_STAGE=bootstrap
    set_real_quit_press_stage "${internal_rc}"
    [[ "${CURRENT_STAGE}" == "capture.real-quit.quit-click.${category}" ]] ||
      fail "Quit AXPress category mapping lost ${category}"
  done <<'QUIT_PRESS_MAPPINGS'
0|pressed
41|process-id
42|root-traversal
43|budget
44|unique-item
45|disabled
46|missing-action
47|perform
48|internal
QUIT_PRESS_MAPPINGS

  CURRENT_STAGE=bootstrap
  if set_real_quit_press_stage 99 >"${output_file}" 2>&1; then
    fail "invalid Quit AXPress category was accepted"
  else
    rc="$?"
  fi
  [[ "${rc}" == "2" && "${CURRENT_STAGE}" == "bootstrap" && ! -s "${output_file}" ]] ||
    fail "invalid Quit AXPress category did not fail silently before changing stage"

  unset RELAYKIT_QUIT_PRESS_SYNTHETIC_TEST
  CURRENT_STAGE=bootstrap
  PID=123
  APP_REAL=/synthetic/RelayKitApp
  process_executable_matches() { return 1; }
  if press_unique_quit_menu_item >"${output_file}" 2>&1; then
    fail "wrong executable identity was accepted for Quit AXPress"
  else
    rc="$?"
  fi
  [[ "${rc}" == "41" && "${CURRENT_STAGE}" == "capture.real-quit.quit-click.process-id" && ! -s "${output_file}" ]] ||
    fail "Quit AXPress process identity failure lost fixed rc41/category/silence"
)
run_quit_press_contract
while IFS='|' read -r phase command; do
  stage="  set_stage capture.real-quit.${phase}"
  [[ "$(grep -Fxc "${stage}" <<<"${real_quit_body}")" == "1" ]] || fail "real Quit ${phase} stage must occur exactly once"
  stage_line="$(grep -nFx "${stage}" <<<"${real_quit_body}" | cut -d: -f1)"
  command_line="$(grep -nF "${command}" <<<"${real_quit_body}" | head -1 | cut -d: -f1)"
  ((command_line == stage_line + 1)) || fail "real Quit ${phase} stage is not immediately before its original command"
done <<'REAL_QUIT_STAGES'
status-menu.readiness-wait|wait_for_status_item_ready
status-menu.open-action|open_unique_status_menu
settle|sleep 0.4
capture|visual_capture_window real-quit "${OUT}/real-quit-menu.png"
capture-verify|test -s "${OUT}/real-quit-menu.png"
quit-click|press_unique_quit_menu_item
exit-wait|for _ in {1..30}; do
exit-verify|if kill -0 "${PID}" 2>/dev/null; then
evidence-write|jq -n --arg screenshot "${OUT}/real-quit-menu.png"
REAL_QUIT_STAGES
[[ "$(grep -Fxc '  press_unique_quit_menu_item' <<<"${real_quit_body}")" == "1" ]] ||
  fail "real Quit must use the exact AXPress helper exactly once"
if grep -Fq 'visual_click_text real-quit "Quit RelayKit"' <<<"${real_quit_body}"; then
  fail "real Quit retained the OCR/CGEvent click fallback"
fi
if grep -Fxq '  set_stage capture.real-quit.status-menu.open' <<<"${real_quit_body}"; then
  fail "combined real Quit status-menu.open stage must not remain"
fi
[[ "$(grep -Fc 'sleep 0.4' <<<"${real_quit_body}")" == "1" && "$(grep -Fc 'sleep 0.2' <<<"${real_quit_body}")" == "1" ]] ||
  fail "real Quit settle or exit-wait timeout command changed"
if grep -Eq 'wait_for_capture_window_ready|set_capture_window_readiness_stage' <<<"${real_quit_body}"; then
  fail "real Quit must retain only its status-item readiness path"
fi

outside_click_body="$(sed -n '/^capture_outside_click() {/,/^}/p' "${SCRIPT}")"
outside_launch='  launch_isolated_app outside-click "${TMPDIR}outside-click.log" --ui-smoke --ui-smoke-keep-open --ui-smoke-skip-gateway-exercise --ui-smoke-evidence "${evidence}" --ui-smoke-catalog-url "${CATALOG_URL}" --ui-smoke-provider-config "${EMPTY_PROVIDER_CONFIG}" --ui-smoke-usage-log "${USAGE_LOG_EMPTY}" --ui-smoke-appearance "${appearance}"'
[[ "$(grep -Fxc "${outside_launch}" <<<"${outside_click_body}")" == "1" ]] ||
  fail "outside-click unique launch argv must add keep-open without changing other flags"
[[ "$(grep -Fc -- '--ui-smoke-keep-open' <<<"${outside_click_body}")" == "1" ]] ||
  fail "outside-click launch must include keep-open exactly once"
for outside_contract in \
  "wait_for_jq \"\${evidence}\" '.popover.shown == true'" \
  'set_stage capture.outside-click.initial-window-probe' \
  'ensure_outside_popover_open' \
  'set_stage capture.outside-click.semantic-window-readiness' \
  'wait_for_outside_window_ready' \
  'visual_click_outside "${OUT}/outside-click.png"' \
  "wait_for_jq \"\${evidence}\" '.popover.shown == false'" \
  'test -s "${OUT}/outside-click.png"'; do
  grep -Fq "${outside_contract}" <<<"${outside_click_body}" || fail "outside-click sequence lacks ${outside_contract}"
done
outside_shown_line="$(grep -nF 'wait_for_jq "${evidence}" '\''.popover.shown == true'\''' <<<"${outside_click_body}" | cut -d: -f1)"
outside_initial_stage_line="$(grep -nFx '  set_stage capture.outside-click.initial-window-probe' <<<"${outside_click_body}" | cut -d: -f1 || true)"
outside_ensure_line="$(grep -nFx '  if ensure_outside_popover_open; then' <<<"${outside_click_body}" | cut -d: -f1 || true)"
outside_diagnostic_line="$(grep -nF 'if [[ "${RELAYKIT_WINDOW_EQUIVALENCE_DIAGNOSTIC_TARGET:-}" == "outside-click" ]]' <<<"${outside_click_body}" | cut -d: -f1 || true)"
outside_ready_stage_line="$(grep -nFx '  set_stage capture.outside-click.semantic-window-readiness' <<<"${outside_click_body}" | cut -d: -f1 || true)"
outside_ready_wait_line="$(grep -nFx '  wait_for_outside_window_ready' <<<"${outside_click_body}" | cut -d: -f1 || true)"
outside_action_line="$(grep -nFx '  visual_click_outside "${OUT}/outside-click.png"' <<<"${outside_click_body}" | cut -d: -f1 || true)"
[[ -n "${outside_initial_stage_line}" && -n "${outside_ensure_line}" && -n "${outside_diagnostic_line}" && -n "${outside_ready_stage_line}" && -n "${outside_ready_wait_line}" && -n "${outside_action_line}" ]] ||
  fail "outside-click readiness/action ordering is incomplete"
((outside_initial_stage_line == outside_shown_line + 1 && outside_ensure_line == outside_initial_stage_line + 1 &&
  outside_ensure_line < outside_diagnostic_line && outside_diagnostic_line < outside_ready_stage_line &&
  outside_ready_wait_line == outside_ready_stage_line + 1 &&
  outside_action_line == outside_ready_wait_line + 1)) ||
  fail "outside-click must probe once, terminate diagnostic before readiness, or continue unchanged to its one outside action"
outside_diagnostic_shell="$(sed -n '/RELAYKIT_WINDOW_EQUIVALENCE_DIAGNOSTIC_TARGET:-}/,/^  fi$/p' <<<"${outside_click_body}")"
for outside_diagnostic_shell_contract in \
  'cleanup_current_app' \
  'FAILURE_REPORTED=1' \
  'exit "${outside_probe_rc}"'; do
  grep -Fq "${outside_diagnostic_shell_contract}" <<<"${outside_diagnostic_shell}" ||
    fail "outside diagnostic termination lacks ${outside_diagnostic_shell_contract}"
done
[[ "$(grep -Fc 'cleanup_current_app' <<<"${outside_diagnostic_shell}")" == "1" ]] ||
  fail "outside diagnostic must perform exactly one post-selector cleanup"
if grep -Eq 'wait_for_outside_window_ready|visual_click_outside|test -s|wait_for_jq' <<<"${outside_diagnostic_shell}"; then
  fail "outside diagnostic continues into readiness, action, evidence wait, or screenshot verification"
fi
[[ "$(grep -Fc 'visual_click_outside "${OUT}/outside-click.png"' <<<"${outside_click_body}")" == "1" ]] ||
  fail "outside-click action count changed"
[[ "$(grep -Fxc '  wait_for_outside_window_ready' <<<"${outside_click_body}")" == "1" ]] ||
  fail "outside-click readiness path was duplicated"
if grep -Eq 'wait_for_capture_window_ready|set_capture_window_readiness_stage' <<<"${outside_click_body}"; then
  fail "outside-click must not duplicate generic capture readiness"
fi
if grep -Eq 'open_unique_status_menu|status_item_selector open|press_unique_quit_menu_item' <<<"${outside_click_body}"; then
  fail "outside-click must not add a status-item click or Quit action"
fi
[[ "$(grep -Fc 'sleep 3' <<<"${outside_click_body}")" == "1" ]] || fail "outside-click launch settle changed or gained a retry sleep"

grep -Fq '.settings.appearance_mode == "light"' "${SCRIPT}" ||
  fail "strong Light appearance predicate was removed"
grep -Fq '.settings.appearance_mode == "dark"' "${SCRIPT}" ||
  fail "strong Dark appearance predicate was removed"
grep -Fq 'desktop_acceptance_catalog == "not run"' "${SCRIPT}" ||
  fail "unavailable Desktop acceptance predicate was weakened"

grep -Fq 'RELAYKIT_MENU_BAR_E2E_OBSERVABILITY_TEST' "${SCRIPT}" ||
  fail "menu smoke must expose the harmless pre-runtime observability contract"
observability_line="$(grep -n 'RELAYKIT_MENU_BAR_E2E_OBSERVABILITY_TEST' "${SCRIPT}" | head -1 | cut -d: -f1)"
runtime_init_line="$(grep -n '^cd "${ROOT}"' "${SCRIPT}" | head -1 | cut -d: -f1)"
[[ "${observability_line}" -lt "${runtime_init_line}" ]] ||
  fail "observability contract must run before build and runtime initialization"
grep -Fq 'set -Eeu' "${SCRIPT}" ||
  fail "menu smoke must retain errtrace plus errexit, nounset, and pipefail"
grep -Fq 'set_stage test.forced-failure' "${SCRIPT}" ||
  fail "observability contract must use the fixed forced-failure stage"
grep -Fxq '  false' "${SCRIPT}" ||
  fail "observability contract must use one unsuppressed false command"

set +e
observability_output="$(RELAYKIT_MENU_BAR_E2E_OBSERVABILITY_TEST=1 bash "${SCRIPT}" 2>&1)"
observability_rc="$?"
set -e
[[ "${observability_rc}" == "1" ]] ||
  fail "observability forced failure must preserve rc=1, got ${observability_rc}"
[[ "${observability_output}" == 'RelayKit menu smoke failed: stage=test.forced-failure rc=1' ]] ||
  fail "observability forced failure must emit exactly one sanitized line"
[[ "$(wc -l <<<"${observability_output}" | tr -d '[:space:]')" == "1" ]] ||
  fail "observability forced failure emitted duplicate lines"
if grep -Eq '/Users|/tmp|provider|config|evidence|PID' <<<"${observability_output}"; then
  fail "observability failure line exposed dynamic or sensitive content"
fi
if grep -Fq 'set_stage evidence.specific-jq' "${SCRIPT}" ||
   grep -Fq 'set_stage evidence.generic-jq' "${SCRIPT}"; then
  fail "evidence failures must retain the hardcoded capture identifier"
fi
grep -Fq 'set_capture_evidence_stage "${context}" generic-jq' "${SCRIPT}" ||
  fail "generic evidence validation must set a capture-specific stage"
grep -Fq 'set_capture_evidence_stage "${name}" specific-jq' "${SCRIPT}" ||
  fail "specific evidence validation must set a capture-specific stage"

required_stages=(
  preflight.build runtime.root runtime.ports
  catalog.start catalog.identity catalog.readiness fixtures.write
  evidence.wait
  screenshot.capture quit.menu outside.click
  final.aggregate final.copy
  cleanup.defaults cleanup.processes cleanup.acceptance cleanup.config cleanup.root
  capture.connect capture.official-sheet capture.real-demo capture.provider-click-flow
  capture.provider-test-failure capture.detail capture.detail-advanced-expanded
  capture.detail-advanced-collapsed capture.import capture.usage
  capture.usage-auto-refresh capture.usage-large capture.usage-1m capture.usage-1y
  capture.usage-empty capture.settings capture.settings-developer-expanded
  capture.settings-light capture.usage-light capture.official-light
  capture.provider-light capture.settings-dark capture.usage-dark
  capture.official-dark capture.provider-dark capture.provider
  capture.real-quit capture.outside-click
)
for required_stage in "${required_stages[@]}"; do
  grep -Fq "set_stage ${required_stage}" "${SCRIPT}" ||
    fail "menu smoke is missing fixed stage ${required_stage}"
done

safety_contract_failures=()
if grep -Eq '(^|[^[:alnum:]_])(pkill|pgrep)([^[:alnum:]_]|$)' "${SCRIPT}"; then
  safety_contract_failures+=("broad process-name scanning or termination")
fi
if grep -Fq 'tell process "RelayKitApp.bin"' "${SCRIPT}"; then
  safety_contract_failures+=("name-only System Events process selection")
fi
if grep -Eq '\$\{HOME\}/\.codex|dist/codex-desktop-manual-proof|open-proof-terminal' "${SCRIPT}"; then
  safety_contract_failures+=("shared Codex or manual-proof paths")
fi
if grep -Eq 'CATALOG_PORT="18790"|gateway_port == "127\.0\.0\.1:19777"' "${SCRIPT}"; then
  safety_contract_failures+=("fixed protected or shared runtime port assumptions")
fi
if grep -Fq './script/build_and_run.sh --verify' "${SCRIPT}"; then
  safety_contract_failures+=("unsafe build-and-launch verification")
fi
if ((${#safety_contract_failures[@]} > 0)); then
  printf 'menu bar smoke safety contract violations:\n' >&2
  printf ' - %s\n' "${safety_contract_failures[@]}" >&2
  exit 1
fi

grep -Fq './script/build_app_bundle.sh --verify' "${SCRIPT}" ||
  fail "menu smoke must use the headless bundle verifier"
grep -Fq 'RELAYKIT_RUNTIME_SAFETY_TEST=1' "${SCRIPT}" ||
  fail "menu smoke must force runtime-safety mode"
grep -Fq 'RELAYKIT_RUNTIME_SAFETY_PORT="${RUNTIME_PORT}"' "${SCRIPT}" ||
  fail "menu smoke must bind the App to its isolated dynamic port"
grep -Fq 'PID="$!"' "${SCRIPT}" ||
  fail "menu smoke must capture the direct App child PID"
grep -Fq 'register_owned_pid "${PID}" "${APP_REAL}"' "${SCRIPT}" ||
  fail "menu smoke must bind the direct child PID to its expected executable"
grep -Fq 'python_runtime_executable() {' "${SCRIPT}" ||
  fail "menu smoke must derive the Python interpreter runtime executable"
grep -Fq 'PYTHON_RUNTIME_EXECUTABLE="$(python_runtime_executable)"' "${SCRIPT}" ||
  fail "menu smoke must freeze the Python runtime executable before launch"
grep -Fq 'wait_for_process_executable_match "${FAKE_CATALOG_PID}" "${PYTHON_RUNTIME_EXECUTABLE}"' "${SCRIPT}" ||
  fail "fake catalog registration must wait for the launcher to exec its runtime interpreter"
grep -Fq 'register_owned_pid "${FAKE_CATALOG_PID}" "${PYTHON_RUNTIME_EXECUTABLE}"' "${SCRIPT}" ||
  fail "fake catalog ownership must use the Python runtime executable"
if grep -Fq 'register_owned_pid "${FAKE_CATALOG_PID}" "$(command -v python3)"' "${SCRIPT}"; then
  fail "fake catalog ownership must not bind to the Python launcher path"
fi
grep -Fq 'process_executable_matches "${PID}" "${APP_REAL}"' "${SCRIPT}" ||
  fail "menu smoke must revalidate App PID identity before GUI actions"
grep -Fq 'case "${RUNTIME_ROOT}" in' "${SCRIPT}" ||
  fail "menu smoke temp cleanup must be guarded by its exact runtime root"
grep -Fq 'export HOME CFFIXED_USER_HOME CODEX_HOME TMPDIR' "${SCRIPT}" ||
  fail "menu smoke must isolate HOME, defaults, Codex, and temporary state"

if grep -Eq 'press_ax_label|focus_ax_label|replace_focused_text|click_point|AXShowMenu|click menu item|/usr/sbin/screencapture' "${SCRIPT}"; then
  fail "popover child actions must use only the PID-window visual helper"
fi
grep -Fq 'hits.filter { $0.text == label }' "${SCRIPT}" ||
  fail "Vision labels must use exact text"
grep -Fq 'exact.filter { $0.confidence >= 0.80 }' "${SCRIPT}" ||
  fail "Vision labels must preserve the fixed confidence floor"
grep -Fq 'if exact.isEmpty { continue }' "${SCRIPT}" ||
  fail "Vision Official alternatives must advance only on exact absence"
grep -Fq 'guard !confident.isEmpty else { throw VisualFailure.lowConfidence }' "${SCRIPT}" ||
  fail "Vision low-confidence must remain distinct"
grep -Fq 'guard confident.count == 1 else { throw VisualFailure.duplicateMatch }' "${SCRIPT}" ||
  fail "Vision duplicate-match must remain distinct"
grep -Fq 'guard bounds.contains(match) else { throw VisualFailure.invalidBounds }' "${SCRIPT}" ||
  fail "Vision out-of-window match must remain distinct"
grep -Fq 'func classifyMissingTarget(flow: String, hits: [TextHit])' "${SCRIPT}" ||
  fail "missing visual targets need pure anchor-only classification"
grep -Fq '["OpenAI Official / Codex Official", "AUTH", "OpenAI Official", "Codex Official"]' "${SCRIPT}" ||
  fail "Official target alternatives must preserve the reviewed exact order"
grep -Fq 'try revalidate(frozen, pid: pid, expectedExecutable: expectedExecutable)' "${SCRIPT}" ||
  fail "window identity must be revalidated immediately before visual action"
grep -Fq 'visual_type_exact_pid "${name}" "Paste API key"' "${SCRIPT}" ||
  fail "API key typing must begin with an exact visible field click"
for public_label in "OpenAI Official / Codex Official" "AUTH" "OpenAI Official" "Codex Official" "Saved Key Provider" "Hidden models" "Paste API key" "Show API key" "Hide API key" "Test connection" "Use 1 reachable models" "Advanced" "Save" "1M" "1Y" "Developer / Diagnostics" "Quit RelayKit"; do
  grep -Fq "\"${public_label}\"" "${SCRIPT}" ||
    fail "visual action allowlist lacks public label ${public_label}"
done
grep -Fq 'RELAYKIT_REUSE_FINAL_BUNDLE' "${SCRIPT}" ||
  fail "menu smoke must support explicit final-bundle reuse"
grep -Fq '/usr/bin/codesign --verify --deep --strict "${SOURCE_APP_BUNDLE}"' "${SCRIPT}" ||
  fail "reused final bundle must be verified before launch"
grep -Fq '.connect.enabled_gateway_provider_protocols == ["anthropic_messages","openai_chat","openai_responses"]' "${SCRIPT}" ||
  fail "menu smoke must accept the RC1 native Responses provider protocol"
grep -Fq '.connect.planned_provider_protocols == []' "${SCRIPT}" ||
  fail "menu smoke must not describe native Responses as planned"
capture_body="$(sed -n '/^capture() {/,/^}/p' "${SCRIPT}")"
grep -Fq 'prepare_capture_prefix() {' "${SCRIPT}" ||
  fail "normal capture and equivalence diagnostic need one shared no-action prefix helper"
prepare_capture_prefix_body="$(sed -n '/^prepare_capture_prefix() {/,/^}/p' "${SCRIPT}")"
for prefix_parameter in \
  'local context="$1"' \
  'local evidence="$2"' \
  'local log="$3"'; do
  grep -Fq "${prefix_parameter}" <<<"${prepare_capture_prefix_body}" ||
    fail "shared capture prefix lacks fixed parameter ${prefix_parameter}"
done
for prefix_contract in \
  'sleep 3' \
  'require_app_identity "${context}"' \
  'cat "${log}" >&2' \
  'set_stage evidence.wait' \
  'for _ in {1..120}; do' \
  'sleep 0.25' \
  'test -s "${evidence}"' \
  'set_capture_evidence_stage "${context}" generic-jq' \
  'jq -e --argjson required "${required}"'; do
  grep -Fq "${prefix_contract}" <<<"${prepare_capture_prefix_body}" ||
    fail "shared capture prefix lost existing command ${prefix_contract}"
done
[[ "$(grep -Fc 'sleep 3' <<<"${prepare_capture_prefix_body}")" == "1" &&
   "$(grep -Fc 'for _ in {1..120}; do' <<<"${prepare_capture_prefix_body}")" == "1" &&
   "$(grep -Fc 'sleep 0.25' <<<"${prepare_capture_prefix_body}")" == "1" ]] ||
  fail "shared capture prefix changed the exact existing wait budget"
if grep -Eq 'visual_|press_|AXPress|CGEvent|set_capture_window_readiness_stage|wait_for_capture_window_ready|specific-jq|screenshot' <<<"${prepare_capture_prefix_body}"; then
  fail "shared capture prefix contains an action, semantic readiness, specific predicate, or screenshot"
fi
[[ "$(grep -Fc 'set_stage evidence.wait' "${SCRIPT}")" == "1" &&
   "$(grep -Fc 'jq -e --argjson required "${required}"' "${SCRIPT}")" == "1" ]] ||
  fail "post-launch evidence/generic predicate prefix must have one source copy"
if grep -Eq '/usr/bin/open|/usr/bin/security|--ui-smoke-seed-keychain' <<<"${capture_body}"; then
  fail "isolated captures must directly launch the child and avoid shared Keychain state"
fi
grep -Fq 'prepare_capture_prefix "${name}" "${evidence}" "${TMPDIR}ui-smoke.log"' <<<"${capture_body}" ||
  fail "normal capture does not call the shared prefix with fixed context/evidence/log"
if grep -Eq 'sleep 3|require_app_identity|set_stage evidence.wait|for _ in \{1\.\.120\}|sleep 0\.25|jq -e --argjson required' <<<"${capture_body}"; then
  fail "normal capture retained a duplicate post-launch prefix"
fi
[[ "$(grep -Fc 'set_capture_window_readiness_stage "${name}"' <<<"${capture_body}")" == "1" ]] ||
  fail "normal capture readiness stage must be set exactly once"
[[ "$(grep -Fc 'wait_for_capture_window_ready "${name}"' <<<"${capture_body}")" == "1" ]] ||
  fail "normal capture readiness wait must run exactly once"
capture_prefix_line="$(grep -nF 'prepare_capture_prefix "${name}" "${evidence}" "${TMPDIR}ui-smoke.log"' <<<"${capture_body}" | cut -d: -f1)"
capture_readiness_stage_line="$(grep -nF 'set_capture_window_readiness_stage "${name}"' <<<"${capture_body}" | cut -d: -f1 || true)"
capture_readiness_wait_line="$(grep -nF 'wait_for_capture_window_ready "${name}"' <<<"${capture_body}" | cut -d: -f1 || true)"
capture_specific_stage_line="$(grep -nF 'set_capture_evidence_stage "${name}" specific-jq' <<<"${capture_body}" | cut -d: -f1)"
[[ -n "${capture_readiness_stage_line}" && -n "${capture_readiness_wait_line}" ]] ||
  fail "normal capture readiness ordering is incomplete"
((capture_prefix_line < capture_readiness_stage_line && capture_readiness_stage_line < capture_readiness_wait_line &&
  capture_readiness_wait_line < capture_specific_stage_line)) ||
  fail "normal capture must validate nonempty evidence/generic popover, then stage/wait once before specific actions"

grep -Fq 'terminate_exact_owned_pid() {' "${SCRIPT}" ||
  fail "owned cleanup needs bounded exact-PID termination"
terminate_owned_body="$(sed -n '/^terminate_exact_owned_pid() {/,/^}/p' "${SCRIPT}")"
wait_owned_body="$(sed -n '/^wait_for_exact_owned_pid_exit() {/,/^}/p' "${SCRIPT}")"
[[ "$(grep -Fc 'kill -TERM "${pid}"' <<<"${terminate_owned_body}")" == "1" ]] ||
  fail "exact owned cleanup must send TERM at most once"
[[ "$(grep -Fc 'kill -KILL "${pid}"' <<<"${terminate_owned_body}")" == "1" ]] ||
  fail "exact owned cleanup must send KILL at most once"
[[ "$(grep -Fc 'process_executable_matches "${pid}" "${expected}"' <<<"${terminate_owned_body}")" -ge 2 ]] ||
  fail "exact owned cleanup must revalidate identity before TERM and KILL"
grep -Fq 'for attempt in {1..40}; do' <<<"${wait_owned_body}" ||
  fail "exact owned cleanup lacks a fixed bounded poll"
grep -Fq 'if ! kill -0 "${pid}"' <<<"${wait_owned_body}" ||
  fail "exact owned cleanup does not prove exit before reaping"
[[ "$(grep -Fc 'wait "${pid}"' <<<"${wait_owned_body}")" == "1" ]] ||
  fail "exact owned cleanup must reap only once after observed exit"
if grep -Eq 'pkill|killall|ps -axo|pgrep|pid_descends_from_owned_root|owned_descendant_pids' <<<"${terminate_owned_body}"; then
  fail "exact owned cleanup retained broad process discovery"
fi

run_exact_owned_cleanup_matrix() (
  RELAYKIT_MENU_BAR_E2E_SOURCE_ONLY=1 source "${SCRIPT}"
  local state identity term_count kill_count wait_count sleep_count rc

  run_case() {
    local behavior="$1"
    state=alive
    identity=match
    term_count=0
    kill_count=0
    wait_count=0
    sleep_count=0
    process_executable_matches() { [[ "${identity}" == "match" ]]; }
    sleep() { [[ "$1" == "0.05" ]] || fail "owned cleanup used a non-fixed poll interval"; sleep_count=$((sleep_count + 1)); }
    wait() { wait_count=$((wait_count + 1)); [[ "${state}" == "dead" ]] || fail "owned cleanup waited on a live or replaced PID"; }
    kill() {
      case "$1" in
        -0) [[ "${state}" == "alive" ]] ;;
        -TERM)
          term_count=$((term_count + 1))
          case "${behavior}" in
            term-exit) state=dead ;;
            replacement) identity=mismatch ;;
          esac
          return 0
          ;;
        -KILL)
          kill_count=$((kill_count + 1))
          [[ "${behavior}" == "kill-exit" ]] && state=dead
          return 0
          ;;
        *) fail "owned cleanup used an unexpected signal" ;;
      esac
    }
  }

  run_case term-exit
  terminate_exact_owned_pid 321 /synthetic/RelayKitApp
  [[ "${term_count}:${kill_count}:${wait_count}:${sleep_count}" == "1:0:1:0" ]] ||
    fail "TERM-success cleanup action matrix changed"

  run_case kill-exit
  terminate_exact_owned_pid 321 /synthetic/RelayKitApp
  [[ "${term_count}:${kill_count}:${wait_count}:${sleep_count}" == "1:1:1:40" ]] ||
    fail "bounded TERM-to-KILL cleanup matrix changed"

  run_case survivor
  set +e
  terminate_exact_owned_pid 321 /synthetic/RelayKitApp
  rc="$?"
  set -e
  [[ "${rc}" == "1" && "${term_count}:${kill_count}:${wait_count}:${sleep_count}" == "1:1:0:80" ]] ||
    fail "surviving owned PID did not fail explicitly after bounded TERM/KILL"

  run_case replacement
  set +e
  terminate_exact_owned_pid 321 /synthetic/RelayKitApp
  rc="$?"
  set -e
  [[ "${rc}" == "1" && "${term_count}:${kill_count}:${wait_count}:${sleep_count}" == "1:0:0:40" ]] ||
    fail "replacement PID was signaled, waited, or not surfaced as cleanup failure"

  run_case survivor
  identity=mismatch
  set +e
  terminate_exact_owned_pid 321 /synthetic/RelayKitApp
  rc="$?"
  set -e
  [[ "${rc}" == "1" && "${term_count}:${kill_count}:${wait_count}:${sleep_count}" == "0:0:0:0" ]] ||
    fail "initial executable mismatch was signaled or waited"
)
run_exact_owned_cleanup_matrix

run_owned_process_cleanup_contract() (
  RELAYKIT_MENU_BAR_E2E_SOURCE_ONLY=1 source "${SCRIPT}"
  local sentinel_pid owned_pid
  /bin/sleep 30 &
  sentinel_pid="$!"
  trap 'kill "${sentinel_pid}" >/dev/null 2>&1 || true; wait "${sentinel_pid}" >/dev/null 2>&1 || true' EXIT
  /bin/sleep 30 &
  owned_pid="$!"
  register_owned_pid "${owned_pid}" /bin/sleep
  cleanup_owned_processes 2>/dev/null
  if kill -0 "${owned_pid}" 2>/dev/null; then
    fail "owned same-executable fixture survived exact cleanup"
  fi
  if ! kill -0 "${sentinel_pid}" 2>/dev/null; then
    fail "unowned same-executable sentinel was terminated"
  fi
)

run_owned_process_cleanup_contract

run_python_launcher_identity_contract() (
  RELAYKIT_MENU_BAR_E2E_SOURCE_ONLY=1 source "${SCRIPT}"
  local owned_pid sentinel_pid runtime_executable
  python3 -c 'import time; time.sleep(30)' &
  sentinel_pid="$!"
  trap 'kill "${owned_pid:-}" "${sentinel_pid}" >/dev/null 2>&1 || true; wait "${owned_pid:-}" "${sentinel_pid}" >/dev/null 2>&1 || true' EXIT
  runtime_executable="$(python_runtime_executable)"
  python3 -c 'import time; time.sleep(30)' &
  owned_pid="$!"
  wait_for_process_executable_match "${owned_pid}" "${runtime_executable}" ||
    fail "literal Python child never reached its runtime executable identity"
  process_executable_matches "${owned_pid}" "${runtime_executable}" ||
    fail "literal Python child did not match its derived runtime executable"
  register_owned_pid "${owned_pid}" "${runtime_executable}"
  if process_executable_matches "${owned_pid}" /bin/sleep; then
    fail "literal Python child matched a deliberately wrong executable"
  fi
  if register_owned_pid "${owned_pid}" /bin/sleep >/dev/null 2>&1; then
    fail "ownership registry accepted a deliberately wrong executable"
  fi
  cleanup_owned_processes 2>/dev/null
  if kill -0 "${owned_pid}" 2>/dev/null; then
    fail "owned Python launcher fixture survived exact cleanup"
  fi
  if ! kill -0 "${sentinel_pid}" 2>/dev/null; then
    fail "unowned Python launcher sentinel was terminated"
  fi
)

run_python_launcher_identity_contract

run_desktop_acceptance_state_contract() (
  RELAYKIT_MENU_BAR_E2E_SOURCE_ONLY=1 source "${SCRIPT}"
  local case_root unavailable available weak_available
  case_root="$(mktemp -d /tmp/relaykit-desktop-acceptance-state-test.XXXXXX)"
  trap 'rm -rf "${case_root}"' EXIT
  unavailable="${case_root}/unavailable.json"
  available="${case_root}/available.json"
  weak_available="${case_root}/weak-available.json"
  cat >"${unavailable}" <<'JSON'
{
  "connect": {
    "desktop_acceptance_available": false,
    "desktop_acceptance_catalog": "not run",
    "desktop_acceptance_picker_data": "not run",
    "desktop_acceptance_route_proof": "not run",
    "desktop_acceptance_global_files": "not run",
    "desktop_acceptance_manual_available": false,
    "desktop_acceptance_manual_entry_visible": false,
    "desktop_acceptance_manual_status": "not run",
    "desktop_acceptance_manual_route_status": "not run",
    "desktop_acceptance_proof_root": "/tmp/relaykit-public-fixture/Library/Application Support/RelayKit/DesktopProof",
    "desktop_acceptance_start_command": "./scripts/codex-desktop-manual-proof.sh run-auto"
  }
}
JSON
  cat >"${available}" <<'JSON'
{
  "connect": {
    "desktop_acceptance_available": true,
    "desktop_acceptance_catalog": "catalog ok: 3 models",
    "desktop_acceptance_picker_data": "picker data has 2 routed models",
    "desktop_acceptance_route_proof": "ready",
    "desktop_acceptance_global_files": "unchanged",
    "desktop_acceptance_manual_available": true,
    "desktop_acceptance_manual_entry_visible": false,
    "desktop_acceptance_manual_status": "ready",
    "desktop_acceptance_manual_route_status": "ready",
    "desktop_acceptance_proof_root": "/tmp/relaykit-public-fixture/Library/Application Support/RelayKit/DesktopProof",
    "desktop_acceptance_start_command": "./scripts/codex-desktop-manual-proof.sh run-auto"
  }
}
JSON
  declare -F desktop_acceptance_state_is_valid >/dev/null ||
    fail "current desktop acceptance predicate rejects the exact unavailable neutral state"
  desktop_acceptance_state_is_valid "${unavailable}" ||
    fail "exact unavailable neutral desktop acceptance state was rejected"
  desktop_acceptance_state_is_valid "${available}" ||
    fail "available desktop acceptance state with strong proof was rejected"
  jq '.connect.desktop_acceptance_catalog = "not run" | .connect.desktop_acceptance_picker_data = "not run"' "${available}" >"${weak_available}"
  if desktop_acceptance_state_is_valid "${weak_available}"; then
    fail "available desktop acceptance state passed without strong catalog and picker proof"
  fi
)

run_desktop_acceptance_state_contract

run_capture_evidence_stage_contract() (
  RELAYKIT_MENU_BAR_E2E_SOURCE_ONLY=1 source "${SCRIPT}"
  local capture_name phase expected seen=""
  local -a capture_names=(
    connect official-sheet real-demo provider-click-flow provider-test-failure
    detail detail-advanced-expanded detail-advanced-collapsed import usage
    usage-auto-refresh usage-large usage-1m usage-1y usage-empty settings
    settings-developer-expanded settings-light usage-light official-light
    provider-light settings-dark usage-dark official-dark provider-dark provider
  )
  for capture_name in "${capture_names[@]}"; do
    for phase in generic-jq specific-jq; do
      expected="capture.${capture_name}.${phase}"
      set_capture_evidence_stage "${capture_name}" "${phase}" ||
        fail "hardcoded capture stage mapping rejected ${expected}"
      [[ "${CURRENT_STAGE}" == "${expected}" ]] ||
        fail "capture stage mapping lost context for ${expected}"
      if grep -Fqx "${CURRENT_STAGE}" <<<"${seen}"; then
        fail "capture stage mapping produced duplicate id ${CURRENT_STAGE}"
      fi
      seen="${seen}${CURRENT_STAGE}"$'\n'
    done
  done
  if set_capture_evidence_stage 'provider/private-value' specific-jq >/dev/null 2>&1; then
    fail "capture stage mapping accepted an unlisted dynamic name"
  fi
  if set_capture_evidence_stage connect 'predicate/private-value' >/dev/null 2>&1; then
    fail "capture stage mapping accepted an unlisted dynamic phase"
  fi
)

run_capture_evidence_stage_contract

echo "Menu bar smoke contract tests passed"
