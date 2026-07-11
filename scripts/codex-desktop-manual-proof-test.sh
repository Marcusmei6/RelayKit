#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROOF_SCRIPT="${ROOT}/scripts/codex-desktop-manual-proof.sh"
AX_DRIVER="${ROOT}/scripts/codex-desktop-ax-driver.swift"
APP_VIEW_SOURCE="${ROOT}/app/Sources/RelayKitApp/Views/ContentView.swift"
APP_MODEL_SOURCE="${ROOT}/app/Sources/RelayKitApp/Stores/AppModel.swift"
GATEWAY_PROCESS_SOURCE="${ROOT}/app/Sources/RelayKitApp/Services/GatewayProcess.swift"

fail() {
  echo "$1" >&2
  exit 1
}

expect_failure() {
  local message="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    fail "${message}"
  fi
}

file_signature() {
  if [[ -e "$1" ]]; then
    /usr/bin/stat -f '%m:%z' "$1"
  else
    printf 'missing'
  fi
}

file_hash() {
  if [[ -e "$1" ]]; then
    /usr/bin/shasum -a 256 "$1" | awk '{print $1}'
  else
    printf 'missing'
  fi
}

notify_hash() {
  if [[ -f "$1" ]]; then
    grep -m 1 '^notify = ' "$1" | /usr/bin/shasum -a 256 | awk '{print $1}' || printf 'missing'
  else
    printf 'missing'
  fi
}

resolved_binary="$(${PROOF_SCRIPT} --print-desktop-binary)"
test -x "${resolved_binary}"

app_bundle="${resolved_binary%%/Contents/MacOS/*}"
bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "${app_bundle}/Contents/Info.plist")"
test "${bundle_id}" = "com.openai.codex"

resolved_codex_cli="$(${PROOF_SCRIPT} --print-desktop-codex-binary)"
test -x "${resolved_codex_cli}"
test "${resolved_codex_cli}" = "${app_bundle}/Contents/Resources/codex"

echo "Codex Desktop binary resolution test passed"

if grep -Fq '"--disable-gpu"' "${PROOF_SCRIPT}"; then
  fail "manual proof must not disable the current Codex Desktop renderer"
fi
grep -Fq '"--force-renderer-accessibility"' "${PROOF_SCRIPT}" ||
  fail "manual proof must expose the isolated Codex renderer through the AX tree"
for evidence_field in \
  source_snapshot_sha256_before source_snapshot_sha256_after source_snapshot_unchanged \
  manual_proof_harness_sha256_before manual_proof_harness_sha256_after manual_proof_harness_unchanged \
  product_artifact_sha256 product_artifact_sha256_before product_artifact_sha256_after product_artifact_unchanged \
  harness_sha256 harness_sha256_before harness_sha256_after harness_unchanged \
  scenario_sha256 scenario_sha256_before scenario_sha256_after scenario_unchanged; do
  grep -Fq "${evidence_field}:" "${PROOF_SCRIPT}" ||
    fail "manual proof evidence is missing ${evidence_field}"
done
grep -Fq -- '--test-source-snapshot-hash' "${PROOF_SCRIPT}" ||
  fail "manual proof needs a focused source snapshot hash test mode"
grep -Fq -- '--test-source-state-guard' "${PROOF_SCRIPT}" ||
  fail "manual proof needs a focused source mutation guard test mode"
grep -Fq 'wait_for_desktop_window()' "${PROOF_SCRIPT}" ||
  fail "manual proof must wait for a real isolated Desktop window"
grep -Fq 'wait_for_desktop_ui_ready()' "${PROOF_SCRIPT}" ||
  fail "manual proof must wait for the isolated Desktop AX tree to become interactive"
grep -Fq 'run_automated_proof()' "${PROOF_SCRIPT}" ||
  fail "Desktop proof needs a zero-human automated state machine"
grep -Fq 'automated_ax' "${PROOF_SCRIPT}" ||
  fail "Desktop proof must expose an automated AX input mode"
grep -Fq 'human_intervention_count' "${PROOF_SCRIPT}" ||
  fail "automated evidence must record that no human intervention occurred"
grep -Fq 'write_automated_rollout_binding' "${PROOF_SCRIPT}" ||
  fail "automated stages must bind fresh usage to one exact rollout/thread"
grep -Fq 'rollout_binding:' "${PROOF_SCRIPT}" ||
  fail "automated stage evidence must include the redacted rollout binding"
grep -Fq 'send({method: "initialized", params: {}})' "${PROOF_SCRIPT}" ||
  fail "App Server preflight must complete the initialize/initialized handshake"
grep -Fq 'scripts/codex-desktop-ax-driver.swift' "${PROOF_SCRIPT}" ||
  fail "automated proof must bind the tracked AX driver into the harness"
grep -Fq 'sandbox_mode = "read-only"' "${PROOF_SCRIPT}" ||
  fail "unattended Desktop proof must use the read-only Codex sandbox"
if grep -Fq 'sandbox_mode = "danger-full-access"' "${PROOF_SCRIPT}"; then
  fail "unattended Desktop proof must not grant danger-full-access"
fi
grep -Fq 'desktop_ui_ready()' "${PROOF_SCRIPT}" ||
  fail "manual proof needs a condition-based Desktop UI readiness probe"
desktop_launch_body="$(sed -n '/^launch_desktop() {/,/^}/p' "${PROOF_SCRIPT}")"
window_wait_line="$(grep -n 'wait_for_desktop_window' <<<"${desktop_launch_body}" | cut -d: -f1 | head -1)"
ui_wait_line="$(grep -n 'wait_for_desktop_ui_ready' <<<"${desktop_launch_body}" | cut -d: -f1 | head -1)"
[[ -n "${window_wait_line}" && -n "${ui_wait_line}" && "${window_wait_line}" -lt "${ui_wait_line}" ]] ||
  fail "manual proof must wait for an interactive AX tree after binding the Desktop window"
grep -Fq 'Codex Desktop process started without an isolated GUI window' "${PROOF_SCRIPT}" ||
  fail "manual proof must fail closed when the isolated GUI window is missing"
if grep -Fq 'as? CFDictionary' "${PROOF_SCRIPT}"; then
  fail "manual proof WindowServer probes must compile with the current Swift toolchain"
fi
grep -Fq 'write_evidence "awaiting_user_action" "awaiting_gpt55_gui_request"' "${PROOF_SCRIPT}" ||
  fail "manual proof must publish awaiting_user_action only after the isolated GUI is ready"
grep -Fq 'Start with RelayKit Official 55 Live:' "${PROOF_SCRIPT}" ||
  fail "manual proof must request a fresh GPT-5.5 GUI response"
grep -Fq 'Start with RelayKit Official 56 Live:' "${PROOF_SCRIPT}" ||
  fail "manual proof must request a fresh GPT-5.6 Luna GUI response"
if grep -Eq 'Stage [0-9]+/[0-9]+ - select official gpt-5\.2|gpt52_availability_missing' "${PROOF_SCRIPT}"; then
  fail "manual proof must not expose or require unsupported GPT-5.2"
fi
grep -Fq 'Render exactly this Markdown structure and no extra sections:' "${PROOF_SCRIPT}" ||
  fail "manual proof must request the exact provider rich-text contract"
if grep -Fq "printf '\${TOOL_MARKER}\\n'; pwd" "${PROOF_SCRIPT}"; then
  fail "manual proof tool request must not disclose the local working directory"
fi
grep -Fq 'Select this workspace: ${ROOT}' "${PROOF_SCRIPT}" ||
  fail "manual proof must tell the user which workspace to select"
grep -Fq 'launch_isolated_relaykit_app()' "${PROOF_SCRIPT}" ||
  fail "real manual proof must launch RelayKit App before Codex Desktop"
popover_open_body="$(sed -n '/^open_relaykit_popover() {/,/^}/p' "${PROOF_SCRIPT}")"
popover_probe_line="$(grep -n 'write_current_app_window_identity' <<<"${popover_open_body}" | head -1 | cut -d: -f1 || true)"
popover_press_line="$(grep -n 'perform action "AXPress" of statusItem' <<<"${popover_open_body}" | head -1 | cut -d: -f1 || true)"
[[ -n "${popover_probe_line}" && -n "${popover_press_line}" && "${popover_probe_line}" -lt "${popover_press_line}" ]] ||
  fail "RelayKit launch must observe an auto-opened popover before toggling the status item"
relaykit_launch_body="$(sed -n '/^launch_isolated_relaykit_app() {/,/^}/p' "${PROOF_SCRIPT}")"
if grep -Eq 'CFFIXED_USER_HOME|--env "HOME=|(^|[[:space:]])HOME=' <<<"${relaykit_launch_body}"; then
  fail "manual proof must preserve the real macOS home so Security.framework can use the login Keychain"
fi
grep -Fq -- '--env "RELAYKIT_OFFICIAL_PROOF_ROOT=${OFFICIAL_PROOF_ROOT}"' <<<"${relaykit_launch_body}" ||
  fail "manual proof must isolate official auth with an explicit RelayKit proof root"
grep -Fq 'CODEX_HOME_DIR="${APP_OFFICIAL_CODEX_HOME}"' "${PROOF_SCRIPT}" ||
  fail "isolated Desktop must reuse the RelayKit App official login home"
if grep -Fq 'CODEX_HOME_DIR="${PROOF_ROOT}/codex-home"' "${PROOF_SCRIPT}"; then
  fail "manual proof must not create a second unauthenticated Desktop CODEX_HOME"
fi
grep -Fq -- '--ui-smoke-provider-config' "${PROOF_SCRIPT}" ||
  fail "normal App proof must override stale global providerConfigPath with the isolated copy"
grep -Fq -- '"-usage-log", usageLogPath' "${GATEWAY_PROCESS_SOURCE}" ||
  fail "App-owned gateway must write usage to the App-selected isolated usage log"
grep -Fq 'usageLogPath: usageLogPath' "${APP_MODEL_SOURCE}" ||
  fail "AppModel must pass its selected usage log path when starting the gateway"
grep -Fq 'RelayKitApp-local.zip' "${PROOF_SCRIPT}" ||
  fail "manual proof must launch an app extracted from the current local zip"
grep -Fq 'RELAYKIT_DESKTOP_PROOF_REUSE_CURRENT_ZIP' "${PROOF_SCRIPT}" ||
  fail "manual proof needs an explicit current-zip reuse path for a previously authorized ad-hoc build"
prepare_app_body="$(sed -n '/^prepare_extracted_app() {/,/^}/p' "${PROOF_SCRIPT}")"
grep -Fq '"${ROOT}/script/package_release.sh" --verify' <<<"${prepare_app_body}" ||
  fail "manual proof must still rebuild the current zip by default"
grep -Fq 'relaykit_app_launched_from_extracted_zip' "${PROOF_SCRIPT}" ||
  fail "manual proof evidence must disclose the extracted App launch"
grep -Fq 'official_preflight_route_evidence_allowed: false' "${PROOF_SCRIPT}" ||
  fail "official auth preflight must never count as Desktop route evidence"
grep -Fq '.accessibilityIdentifier("gateway-start")' "${APP_VIEW_SOURCE}" ||
  fail "RelayKit gateway Start control needs a stable AX identifier"
grep -Fq '.smokeRecordOnly("settings-gateway-group", recorder: smokeSectionRecorder)' "${APP_VIEW_SOURCE}" ||
  fail "Gateway container smoke markers must not override child AX identifiers"
grep -Fq '.smokeRecordOnly("model-access-merged", recorder: smokeSectionRecorder)' "${APP_VIEW_SOURCE}" ||
  fail "Model access container smoke markers must not override provider row AX identifiers"
grep -Fq 'press_relaykit_app_ax "gateway-start"' "${PROOF_SCRIPT}" ||
  fail "manual proof must start the App-owned gateway through exact AX"
grep -Fq 'keychain_authorization_prompt_visible()' "${PROOF_SCRIPT}" ||
  fail "manual proof must distinguish a Keychain authorization prompt from an AX failure"
grep -Fq 'wait_for_keychain_authorization()' "${PROOF_SCRIPT}" ||
  fail "manual proof must pause for user-owned Keychain authorization"
grep -Fq 'Authorize only the dedicated DesktopProof Keychain item' "${PROOF_SCRIPT}" ||
  fail "manual proof must explain the narrow Keychain authorization boundary"
grep -Fq 'wait_for_app_gateway_health()' "${PROOF_SCRIPT}" ||
  fail "manual proof must verify gateway health after Keychain authorization"
grep -Fq 'if [[ "${start_action_status}" -ne 0 ]] && ! wait_for_app_gateway_health; then' <<<"${relaykit_launch_body}" ||
  fail "manual proof must check gateway health before classifying an AX timeout as Keychain authorization"
popover_reopen_line="$(grep -n 'ensure_relaykit_popover_open' <<<"${relaykit_launch_body}" | tail -1 | cut -d: -f1 || true)"
connect_press_line="$(grep -n 'press_relaykit_app_ax "tab-connect"' <<<"${relaykit_launch_body}" | tail -1 | cut -d: -f1 || true)"
[[ -n "${popover_reopen_line}" && -n "${connect_press_line}" && "${popover_reopen_line}" -lt "${connect_press_line}" ]] ||
  fail "manual proof must reopen the RelayKit popover after Keychain authorization before pressing Connect"
grep -Fq 'RELAYKIT_AX_PRESS_TIMEOUT_SECONDS' "${PROOF_SCRIPT}" ||
  fail "manual proof AX press must have a bounded timeout around SecurityAgent"
grep -Fq 'RELAYKIT_AX_PRESS_TIMEOUT_SECONDS:-20' "${PROOF_SCRIPT}" ||
  fail "manual proof AX timeout must cover cold Swift startup while remaining bounded"
ax_press_body="$(sed -n '/^press_relaykit_app_ax() {/,/^}/p' "${PROOF_SCRIPT}")"
grep -Fq 'RELAYKIT_AX_PRESS_TOTAL_TIMEOUT_SECONDS:-30' <<<"${ax_press_body}" ||
  fail "manual proof AX press needs one total deadline across helper retries"
grep -Fq 'ensure_relaykit_popover_open' <<<"${ax_press_body}" ||
  fail "manual proof AX press must reopen a disappeared RelayKit popover"
grep -Fq 'SECONDS < deadline' <<<"${ax_press_body}" ||
  fail "manual proof AX retries must stop at the total deadline"
grep -Fq 'expected_window_id="$(jq -er' <<<"${ax_press_body}" ||
  fail "RelayKit AX control must bind its focus activation to the captured window id"
grep -Fq 'ownerPID == targetPID && windowID == expectedWindowID' <<<"${ax_press_body}" ||
  fail "RelayKit AX control must reject a mismatched WindowServer PID/window"
grep -Fq 'CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown' "${PROOF_SCRIPT}" ||
  fail "RelayKit AX control must focus the exact popover before traversing SwiftUI AX"
grep -Fq "alarm shift; exec @ARGV" "${PROOF_SCRIPT}" ||
  fail "manual proof must terminate a blocked AX helper without killing the App"
keychain_prompt_body="$(sed -n '/^keychain_authorization_prompt_visible() {/,/^}/p' "${PROOF_SCRIPT}")"
if grep -Fq 'pgrep -x SecurityAgent' <<<"${keychain_prompt_body}"; then
  fail "manual proof must not treat a background SecurityAgent process as a visible prompt"
fi
grep -Fq 'process "SecurityAgent"' <<<"${keychain_prompt_body}" ||
  fail "manual proof must inspect the exact SecurityAgent window"
grep -Fq '.name = "Local Provider Proof"' "${PROOF_SCRIPT}" ||
  fail "real provider copy must redact the provider name in isolated App evidence"
grep -Fq 'relaykit.desktop-proof.provider-' "${PROOF_SCRIPT}" ||
  fail "real provider copy must use a dedicated proof Keychain service"
grep -Fq 'delete_proof_keychain_items' "${PROOF_SCRIPT}" ||
  fail "proof purge must remove dedicated provider Keychain items"
if grep -Fq '/usr/bin/security' "${PROOF_SCRIPT}"; then
  fail "manual proof must not access Keychain through /usr/bin/security"
fi
grep -Fq -- '--delete-desktop-proof-keychain "${service}"' "${PROOF_SCRIPT}" ||
  fail "proof Keychain cleanup must use the extracted RelayKit App identity"
app_launch_line="$(grep -n '^    launch_isolated_relaykit_app$' "${PROOF_SCRIPT}" | cut -d: -f1 | head -1)"
desktop_launch_line="$(grep -n '^    launch_desktop$' "${PROOF_SCRIPT}" | cut -d: -f1 | head -1)"
[[ -n "${app_launch_line}" && -n "${desktop_launch_line}" && "${app_launch_line}" -lt "${desktop_launch_line}" ]] ||
  fail "real manual proof must make RelayKit App ready before launching Codex Desktop"

tmp_dir="$(mktemp -d)"
pid_file="${tmp_dir}/stubborn.pid"
ready_file="${tmp_dir}/ready"
stubborn_pid=""
cleanup() {
  if [[ -n "${stubborn_pid}" ]] && kill -0 "${stubborn_pid}" 2>/dev/null; then
    kill -KILL "${stubborn_pid}" 2>/dev/null || true
  fi
  rm -rf "${tmp_dir}"
}
trap cleanup EXIT

source_fixture="${tmp_dir}/source-fixture"
mkdir -p \
  "${source_fixture}/app/Sources" \
  "${source_fixture}/gateway/cmd" \
  "${source_fixture}/gateway/internal" \
  "${source_fixture}/script"
printf 'swift fixture\n' >"${source_fixture}/app/Package.swift"
printf 'app source\n' >"${source_fixture}/app/Sources/App.swift"
printf 'module fixture\n' >"${source_fixture}/gateway/go.mod"
printf 'gateway source\n' >"${source_fixture}/gateway/cmd/main.go"
printf 'server source\n' >"${source_fixture}/gateway/internal/server.go"
printf 'build fixture\n' >"${source_fixture}/script/build_app_bundle.sh"
printf 'package fixture\n' >"${source_fixture}/script/package_release.sh"
source_hash_before="$(${PROOF_SCRIPT} --test-source-snapshot-hash "${source_fixture}")"
test -n "${source_hash_before}"
test "$(${PROOF_SCRIPT} --test-source-snapshot-hash "${source_fixture}")" = "${source_hash_before}"
"${PROOF_SCRIPT}" --test-source-state-guard "${source_fixture}" "${source_hash_before}"
printf 'changed gateway source\n' >"${source_fixture}/gateway/internal/server.go"
expect_failure "manual proof accepted a changed source snapshot" \
  "${PROOF_SCRIPT}" --test-source-state-guard "${source_fixture}" "${source_hash_before}"

echo "Manual proof source snapshot guard test passed"

harness_fixture="${tmp_dir}/harness-fixture"
mkdir -p "${harness_fixture}/scripts"
printf 'proof harness fixture\n' >"${harness_fixture}/scripts/codex-desktop-manual-proof.sh"
printf 'AX driver fixture\n' >"${harness_fixture}/scripts/codex-desktop-ax-driver.swift"
harness_hash_before="$(${PROOF_SCRIPT} --test-harness-snapshot-hash "${harness_fixture}")"
test -n "${harness_hash_before}"
test "$(${PROOF_SCRIPT} --test-harness-snapshot-hash "${harness_fixture}")" = "${harness_hash_before}"
printf 'changed AX driver fixture\n' >"${harness_fixture}/scripts/codex-desktop-ax-driver.swift"
test "$(${PROOF_SCRIPT} --test-harness-snapshot-hash "${harness_fixture}")" != "${harness_hash_before}"

echo "Manual proof harness snapshot hash test passed"

product_artifact_fixture="${tmp_dir}/RelayKitApp-local.zip"
printf 'fixed product artifact\n' >"${product_artifact_fixture}"
product_artifact_hash="$(/usr/bin/shasum -a 256 "${product_artifact_fixture}" | awk '{print $1}')"
"${PROOF_SCRIPT}" --test-product-artifact-state-guard "${product_artifact_fixture}" "${product_artifact_hash}"
printf 'changed product artifact\n' >"${product_artifact_fixture}"
expect_failure "manual proof accepted a changed product artifact" \
  "${PROOF_SCRIPT}" --test-product-artifact-state-guard "${product_artifact_fixture}" "${product_artifact_hash}"

echo "Manual proof product artifact guard test passed"

provider_status_dir="${tmp_dir}/provider-status"
mkdir -p "${provider_status_dir}"
cat >"${provider_status_dir}/available.json" <<'JSON'
{"data":[{"id":"public/model"}],"model_health":{"hidden":[]}}
JSON
cat >"${provider_status_dir}/auth-required.json" <<'JSON'
{"data":[],"model_health":{"hidden":[{"id":"public/model","reason":"auth failed"}]}}
JSON
cat >"${provider_status_dir}/unavailable.json" <<'JSON'
{"data":[],"model_health":{"hidden":[{"id":"public/model","reason":"network failed"}]}}
JSON
cat >"${provider_status_dir}/missing.json" <<'JSON'
{"data":[],"model_health":{"hidden":[]}}
JSON
test "$(${PROOF_SCRIPT} --test-provider-gateway-status "${provider_status_dir}/available.json" public/model)" = "available"
test "$(${PROOF_SCRIPT} --test-provider-gateway-status "${provider_status_dir}/auth-required.json" public/model)" = "auth_required"
test "$(${PROOF_SCRIPT} --test-provider-gateway-status "${provider_status_dir}/unavailable.json" public/model)" = "unavailable"
test "$(${PROOF_SCRIPT} --test-provider-gateway-status "${provider_status_dir}/missing.json" public/model)" = "missing"
provider_wait_body="$(sed -n '/^wait_for_provider_gateway_status() {/,/^}/p' "${PROOF_SCRIPT}")"
grep -Fq 'RELAYKIT_PROVIDER_PREFLIGHT_ATTEMPTS' <<<"${provider_wait_body}" ||
  fail "provider preflight readiness needs a bounded retry count"
grep -Fq 'fetch_gateway_models' <<<"${provider_wait_body}" ||
  fail "provider preflight retry must refetch the gateway catalog"
grep -Fq 'sleep 1' <<<"${provider_wait_body}" ||
  fail "provider preflight retry must wait between transient catalog probes"
ensure_provider_body="$(sed -n '/^ensure_provider_models_available_via_app() {/,/^}/p' "${PROOF_SCRIPT}")"
grep -Fq 'provider_status="$(wait_for_provider_gateway_status)"' <<<"${ensure_provider_body}" ||
  fail "provider readiness must use the bounded catalog wait"

echo "Manual proof provider readiness retry tests passed"

zip_fixture_root="${tmp_dir}/zip-fixture"
zip_fixture_source="${zip_fixture_root}/source"
zip_fixture_app="${zip_fixture_source}/RelayKitApp.app"
zip_fixture_extracted="${zip_fixture_root}/extracted/RelayKitApp.app"
zip_fixture_archive="${zip_fixture_root}/RelayKitApp-local.zip"
zip_fixture_scratch="${zip_fixture_root}/scratch"
mkdir -p "${zip_fixture_app}/Contents/MacOS" "$(dirname "${zip_fixture_extracted}")"
printf 'fixture app\n' >"${zip_fixture_app}/Contents/MacOS/RelayKitApp.bin"
printf 'fixture gateway\n' >"${zip_fixture_app}/Contents/MacOS/relay"
(
  cd "${zip_fixture_source}"
  /usr/bin/zip -qry "${zip_fixture_archive}" RelayKitApp.app
)
cp -R "${zip_fixture_app}" "${zip_fixture_extracted}"
"${PROOF_SCRIPT}" --test-extracted-app-matches-zip "${zip_fixture_archive}" "${zip_fixture_extracted}" "${zip_fixture_scratch}"
printf 'changed\n' >>"${zip_fixture_extracted}/Contents/MacOS/relay"
expect_failure "manual proof reused an extracted App that did not match the current zip" \
  "${PROOF_SCRIPT}" --test-extracted-app-matches-zip "${zip_fixture_archive}" "${zip_fixture_extracted}" "${zip_fixture_scratch}"
grep -Fq 'RELAYKIT_DESKTOP_PROOF_REUSE_EXTRACTED_APP' "${PROOF_SCRIPT}" ||
  fail "manual proof needs an explicit verified extracted-App reuse mode for Keychain authorization"

echo "Manual proof extracted App reuse guard test passed"

current_route_dir="${tmp_dir}/current-route"
last_attempt_dir="${tmp_dir}/last-attempt"
last_complete_dir="${tmp_dir}/last-complete"
mkdir -p "${current_route_dir}" "${last_attempt_dir}" "${last_complete_dir}"
printf '{"route_proof_status":"complete","desktop_gui_route_proof":"manual_user_assisted_complete","usage_event_count":4,"sentinel":"completed-route"}\n' >"${last_complete_dir}/evidence.json"
printf '{"manual_status":"awaiting_user_action","route_proof_status":"awaiting_gpt55_gui_request","usage_event_count":0}\n' >"${current_route_dir}/evidence.json"
"${PROOF_SCRIPT}" --test-preserve-route-evidence "${current_route_dir}" "${last_attempt_dir}" "${last_complete_dir}"
jq -e '.sentinel == "completed-route"' "${last_complete_dir}/evidence.json" >/dev/null
test ! -e "${last_attempt_dir}/evidence.json"

printf '{"manual_status":"route_incomplete","route_proof_status":"official_auth_required","usage_event_count":1,"sentinel":"current-failed-route"}\n' >"${current_route_dir}/evidence.json"
mkdir -p "${current_route_dir}/screenshots"
printf 'process-bound screenshot fixture\n' >"${current_route_dir}/screenshots/gpt55-response.png"
"${PROOF_SCRIPT}" --test-preserve-route-evidence "${current_route_dir}" "${last_attempt_dir}" "${last_complete_dir}"
jq -e '.sentinel == "current-failed-route"' "${last_attempt_dir}/evidence.json" >/dev/null
test -f "${last_attempt_dir}/screenshots/gpt55-response.png"
jq -e '.sentinel == "completed-route"' "${last_complete_dir}/evidence.json" >/dev/null

printf '{"manual_status":"route_complete","route_proof_status":"complete","desktop_gui_route_proof":"manual_user_assisted_complete","usage_event_count":4,"sentinel":"new-complete"}\n' >"${current_route_dir}/evidence.json"
"${PROOF_SCRIPT}" --test-preserve-route-evidence "${current_route_dir}" "${last_attempt_dir}" "${last_complete_dir}"
jq -e '.sentinel == "new-complete"' "${last_attempt_dir}/evidence.json" >/dev/null
jq -e '.sentinel == "new-complete"' "${last_complete_dir}/evidence.json" >/dev/null

printf '{"route_proof_status":"complete","desktop_gui_route_proof":"automated_custom_scenario_complete","usage_event_count":2,"sentinel":"custom-complete"}\n' >"${current_route_dir}/evidence.json"
"${PROOF_SCRIPT}" --test-preserve-route-evidence "${current_route_dir}" "${last_attempt_dir}" "${last_complete_dir}"
jq -e '.sentinel == "custom-complete"' "${last_attempt_dir}/evidence.json" >/dev/null
jq -e '.sentinel == "new-complete"' "${last_complete_dir}/evidence.json" >/dev/null

echo "Manual proof last-route preservation test passed"

stubborn_pid="$(sh -c 'sh -c '\''trap "" TERM; : >"$1"; while :; do sleep 60; done'\'' sh "$1" >/dev/null 2>&1 & echo $!' sh "${ready_file}")"
echo "${stubborn_pid}" >"${pid_file}"
for _ in {1..40}; do
  [[ -f "${ready_file}" ]] && break
  sleep 0.05
done
test -f "${ready_file}"

if ! RELAYKIT_PROCESS_STOP_TIMEOUT=1 perl -e 'alarm shift; exec @ARGV' 5 "${PROOF_SCRIPT}" --test-stop-pid-file "${pid_file}"; then
  echo "manual proof process cleanup did not finish within its timeout" >&2
  exit 1
fi
test ! -e "${pid_file}"
for _ in {1..40}; do
  ! kill -0 "${stubborn_pid}" 2>/dev/null && break
  sleep 0.05
done
! kill -0 "${stubborn_pid}" 2>/dev/null
stubborn_pid=""

echo "Manual proof process cleanup test passed"

if grep -En 'repair_global_notify_if_needed|GLOBAL_NOTIFY_REPAIRED_FILE|cat .*GLOBAL_CODEX_CONFIG|perl .*GLOBAL_CODEX_CONFIG' "${PROOF_SCRIPT}" >/dev/null; then
  fail "manual proof script still contains global Codex config repair/write capability"
fi

expect_failure "manual proof accepted an unsandboxed Desktop policy" env RELAYKIT_DESKTOP_PROOF_USE_SANDBOX=0 "${PROOF_SCRIPT}" --test-sandbox-policy
RELAYKIT_DESKTOP_PROOF_USE_SANDBOX=1 "${PROOF_SCRIPT}" --test-sandbox-policy

global_home="${tmp_dir}/global-home"
mkdir -p "${global_home}/.codex"
config_path="${global_home}/.codex/config.toml"
auth_path="${global_home}/.codex/auth.json"
printf 'model = "gpt-5.5"\nnotify = ["/usr/bin/true"]\n' >"${config_path}"
printf '{"auth":"fixture"}\n' >"${auth_path}"
config_before="$(file_signature "${config_path}")"
auth_before="$(file_signature "${auth_path}")"
config_hash_before="$(file_hash "${config_path}")"
auth_hash_before="$(file_hash "${auth_path}")"
notify_hash_before="$(notify_hash "${config_path}")"

HOME="${global_home}" "${PROOF_SCRIPT}" --test-global-state-guard \
  "${config_before}" "${auth_before}" "${config_hash_before}" "${auth_hash_before}" "${notify_hash_before}"

printf '# changed\n' >>"${config_path}"
expect_failure "global guard accepted changed config" env HOME="${global_home}" "${PROOF_SCRIPT}" --test-global-state-guard \
  "${config_before}" "${auth_before}" "${config_hash_before}" "${auth_hash_before}" "${notify_hash_before}"
printf 'model = "gpt-5.5"\nnotify = ["/usr/bin/true"]\n' >"${config_path}"

printf '{"auth":"changed"}\n' >"${auth_path}"
expect_failure "global guard accepted changed auth" env HOME="${global_home}" "${PROOF_SCRIPT}" --test-global-state-guard \
  "$(file_signature "${config_path}")" "${auth_before}" "$(file_hash "${config_path}")" "${auth_hash_before}" "$(notify_hash "${config_path}")"
printf '{"auth":"fixture"}\n' >"${auth_path}"

config_before="$(file_signature "${config_path}")"
config_hash_before="$(file_hash "${config_path}")"
notify_hash_before="$(notify_hash "${config_path}")"
printf 'model = "gpt-5.5"\nnotify = ["/usr/bin/false"]\n' >"${config_path}"
expect_failure "global guard accepted changed notify line" env HOME="${global_home}" "${PROOF_SCRIPT}" --test-global-state-guard \
  "${config_before}" "$(file_signature "${auth_path}")" "${config_hash_before}" "$(file_hash "${auth_path}")" "${notify_hash_before}"

echo "Manual proof global file guard test passed"

sandbox_home="${tmp_dir}/sandbox-home"
sandbox_profile="${tmp_dir}/desktop-proof.sb"
isolated_write_path="${sandbox_home}/Library/Application Support/RelayKit/DesktopProof/isolated-home/probe"
mkdir -p \
  "${sandbox_home}/.codex" \
  "${sandbox_home}/Library/Application Support/Codex" \
  "${sandbox_home}/Library/Application Support/OpenAI" \
  "${sandbox_home}/Library/Application Support/com.openai.codex" \
  "${sandbox_home}/Library/Preferences" \
  "$(dirname "${isolated_write_path}")"

HOME="${sandbox_home}" "${PROOF_SCRIPT}" --test-write-desktop-sandbox-profile "${sandbox_profile}"
test -s "${sandbox_profile}"

for protected_path in \
  "${sandbox_home}/.codex/probe" \
  "${sandbox_home}/Library/Application Support/Codex/probe" \
  "${sandbox_home}/Library/Application Support/OpenAI/probe" \
  "${sandbox_home}/Library/Application Support/com.openai.codex/probe" \
  "${sandbox_home}/Library/Preferences/com.openai.codex.plist" \
  "${sandbox_home}/Library/Preferences/com.openai.sky.CUAService.cli.plist" \
  "${sandbox_home}/Library/Preferences/com.openai.sky.CUAService.plist"; do
  expect_failure "Desktop sandbox allowed a global Codex state write: ${protected_path}" \
    /usr/bin/sandbox-exec -f "${sandbox_profile}" /bin/sh -c ': >"$1"' sh "${protected_path}"
  test ! -e "${protected_path}"
done

/usr/bin/sandbox-exec -f "${sandbox_profile}" /bin/sh -c ': >"$1"' sh "${isolated_write_path}"
test -f "${isolated_write_path}"

echo "Manual proof shared Codex state sandbox test passed"

usage_dir="${tmp_dir}/usage-cases"
mkdir -p "${usage_dir}"
provider_model="public-provider/model"
cat >"${usage_dir}/tool-complete.json" <<'JSON'
{
  "proof_found": true,
  "function_call_found": true,
  "function_call_output_found": true,
  "process_exited_zero": true,
  "xml_leak_found": false,
  "raw_function_calls_found": false
}
JSON
cat >"${usage_dir}/render-complete.json" <<'JSON'
{
  "gpt55_gui_visible": true,
  "gpt56_gui_visible": true,
  "markdown_render_verified": true,
  "raw_protocol_absent": true,
  "tool_gui_verified": true
}
JSON
cat >"${usage_dir}/screenshots-complete.json" <<'JSON'
[
  {"role":"before-manual-input","captured":true,"target_identity_verified":true},
  {"role":"gpt55-response","captured":true,"target_identity_verified":true,"visual_checks":{"official55_response_visible":true,"raw_protocol_visible":false}},
  {"role":"gpt56-response","captured":true,"target_identity_verified":true,"visual_checks":{"official56_response_visible":true,"raw_protocol_visible":false}},
  {"role":"provider-markdown","captured":true,"target_identity_verified":true,"visual_checks":{"heading_visible":true,"numbered_items_visible":true,"table_headers_visible":true,"bash_code_visible":true,"bold_conclusion_visible":true,"raw_protocol_visible":false}},
  {"role":"provider-tool","captured":true,"target_identity_verified":true,"visual_checks":{"tool_marker_visible":true,"tool_execution_visible":true,"raw_protocol_visible":false}}
]
JSON
cat >"${usage_dir}/screenshots-wrong-task.json" <<'JSON'
[
  {"role":"gpt55-response","captured":true,"target_identity_verified":true,"visual_checks":{"official55_response_visible":false,"raw_protocol_visible":false}}
]
JSON
jq '
  [.[] | select(.role != "provider-markdown")] + [
    {"role":"provider-markdown","captured":true,"target_identity_verified":true,"visual_checks":{"heading_visible":true,"numbered_items_visible":true,"table_headers_visible":true,"bash_code_visible":true,"bold_conclusion_visible":false,"raw_protocol_visible":false}},
    {"role":"provider-markdown","captured":true,"target_identity_verified":true,"visual_checks":{"heading_visible":false,"numbered_items_visible":false,"table_headers_visible":false,"bash_code_visible":true,"bold_conclusion_visible":true,"raw_protocol_visible":false}}
  ]
' "${usage_dir}/screenshots-complete.json" >"${usage_dir}/screenshots-markdown-split.json"

cat >"${usage_dir}/complete.json" <<JSON
[
  {"provider_id":"openai","model":"gpt-5.5","status":"completed","http_status":200},
  {"provider_id":"openai","model":"gpt-5.6-luna","status":"completed","http_status":200},
  {"provider_id":"provider","model":"${provider_model}","status":"completed","http_status":200},
  {"provider_id":"provider","model":"${provider_model}","status":"completed","http_status":200}
]
JSON
test "$("${PROOF_SCRIPT}" --test-route-outcome "${usage_dir}/complete.json" "${provider_model}" "${usage_dir}/tool-complete.json" "${usage_dir}/screenshots-complete.json" "${usage_dir}/render-complete.json")" = "complete"
jq 'map(if .role == "before-manual-input" then .role = "before-automated-input" else . end)' "${usage_dir}/screenshots-complete.json" >"${usage_dir}/screenshots-automated-complete.json"
test "$("${PROOF_SCRIPT}" --test-route-outcome "${usage_dir}/complete.json" "${provider_model}" "${usage_dir}/tool-complete.json" "${usage_dir}/screenshots-automated-complete.json" "${usage_dir}/render-complete.json")" = "complete"
test "$("${PROOF_SCRIPT}" --test-stage-checkpoint "${usage_dir}/complete.json" "${usage_dir}/screenshots-complete.json" gpt55-response "${provider_model}" "${usage_dir}/tool-complete.json")" = "verified"
test "$("${PROOF_SCRIPT}" --test-stage-checkpoint "${usage_dir}/complete.json" "${usage_dir}/screenshots-markdown-split.json" provider-markdown "${provider_model}" "${usage_dir}/tool-complete.json")" = "verified"
expect_failure "wrong active task advanced the GPT-5.5 stage" "${PROOF_SCRIPT}" --test-stage-checkpoint "${usage_dir}/complete.json" "${usage_dir}/screenshots-wrong-task.json" gpt55-response "${provider_model}" "${usage_dir}/tool-complete.json"
test "$("${PROOF_SCRIPT}" --test-stage-checkpoint "${usage_dir}/complete.json" "${usage_dir}/screenshots-complete.json" provider-tool "${provider_model}" "${usage_dir}/tool-complete.json")" = "verified"
cat >"${usage_dir}/tool-stale-empty.json" <<'JSON'
{"proof_found":false,"function_call_found":false,"function_call_output_found":false,"process_exited_zero":false,"xml_leak_found":false,"raw_function_calls_found":false}
JSON
expect_failure "stale empty tool evidence advanced the provider tool stage" "${PROOF_SCRIPT}" --test-stage-checkpoint "${usage_dir}/complete.json" "${usage_dir}/screenshots-complete.json" provider-tool "${provider_model}" "${usage_dir}/tool-stale-empty.json"

cat >"${usage_dir}/provider-only.json" <<JSON
[{"provider_id":"provider","model":"${provider_model}","status":"completed","http_status":200}]
JSON
expect_failure "provider-only usage produced route success" "${PROOF_SCRIPT}" --test-route-outcome "${usage_dir}/provider-only.json" "${provider_model}" "${usage_dir}/tool-complete.json" "${usage_dir}/screenshots-complete.json" "${usage_dir}/render-complete.json"

cat >"${usage_dir}/auth-required.json" <<JSON
[
  {"provider_id":"openai","model":"gpt-5.5","status":"error","http_status":401,"error_type":"auth_required"},
  {"provider_id":"provider","model":"${provider_model}","status":"completed","http_status":200}
]
JSON
expect_failure "auth_required produced route success" "${PROOF_SCRIPT}" --test-route-outcome "${usage_dir}/auth-required.json" "${provider_model}" "${usage_dir}/tool-complete.json" "${usage_dir}/screenshots-complete.json" "${usage_dir}/render-complete.json"

cat >"${usage_dir}/refresh-revoked.json" <<JSON
[
  {"provider_id":"openai","model":"gpt-5.5","status":"error","http_status":401,"error_type":"refresh_token_revoked"},
  {"provider_id":"provider","model":"${provider_model}","status":"completed","http_status":200}
]
JSON
expect_failure "refresh revoked produced route success" "${PROOF_SCRIPT}" --test-route-outcome "${usage_dir}/refresh-revoked.json" "${provider_model}" "${usage_dir}/tool-complete.json" "${usage_dir}/screenshots-complete.json" "${usage_dir}/render-complete.json"

cat >"${usage_dir}/unknown-model.json" <<JSON
[
  {"provider_id":"openai","model":"gpt-5.5","status":"completed","http_status":200},
  {"provider_id":"provider","model":"${provider_model}","status":"completed","http_status":200},
  {"provider_id":"provider","model":"${provider_model}","status":"completed","http_status":200},
  {"provider_id":"unknown","model":"missing-model","status":"error","http_status":400,"error_type":"unknown_model"}
]
JSON
expect_failure "unknown model produced route success" "${PROOF_SCRIPT}" --test-route-outcome "${usage_dir}/unknown-model.json" "${provider_model}" "${usage_dir}/tool-complete.json" "${usage_dir}/screenshots-complete.json" "${usage_dir}/render-complete.json"

cat >"${usage_dir}/missing-gpt56.json" <<JSON
[
  {"provider_id":"openai","model":"gpt-5.5","status":"completed","http_status":200},
  {"provider_id":"provider","model":"${provider_model}","status":"completed","http_status":200},
  {"provider_id":"provider","model":"${provider_model}","status":"completed","http_status":200}
]
JSON
expect_failure "missing GPT-5.6 success produced route success" "${PROOF_SCRIPT}" --test-route-outcome "${usage_dir}/missing-gpt56.json" "${provider_model}" "${usage_dir}/tool-complete.json" "${usage_dir}/screenshots-complete.json" "${usage_dir}/render-complete.json"

expect_failure "missing tool evidence produced route success" "${PROOF_SCRIPT}" --test-route-outcome "${usage_dir}/complete.json" "${provider_model}" "${usage_dir}/missing-tool.json" "${usage_dir}/screenshots-complete.json" "${usage_dir}/render-complete.json"
cat >"${usage_dir}/tool-xml-leak.json" <<'JSON'
{"proof_found":false,"function_call_found":true,"function_call_output_found":true,"process_exited_zero":true,"xml_leak_found":true,"raw_function_calls_found":true}
JSON
expect_failure "raw tool protocol text produced route success" "${PROOF_SCRIPT}" --test-route-outcome "${usage_dir}/complete.json" "${provider_model}" "${usage_dir}/tool-xml-leak.json" "${usage_dir}/screenshots-complete.json" "${usage_dir}/render-complete.json"
cat >"${usage_dir}/render-markdown-missing.json" <<'JSON'
{"gpt55_gui_visible":true,"gpt56_gui_visible":true,"markdown_render_verified":false,"raw_protocol_absent":true,"tool_gui_verified":true}
JSON
expect_failure "missing Markdown render proof produced route success" "${PROOF_SCRIPT}" --test-route-outcome "${usage_dir}/complete.json" "${provider_model}" "${usage_dir}/tool-complete.json" "${usage_dir}/screenshots-complete.json" "${usage_dir}/render-markdown-missing.json"
cat >"${usage_dir}/render-tool-missing.json" <<'JSON'
{"gpt55_gui_visible":true,"gpt56_gui_visible":true,"markdown_render_verified":true,"raw_protocol_absent":true,"tool_gui_verified":false}
JSON
expect_failure "missing visible tool block produced route success" "${PROOF_SCRIPT}" --test-route-outcome "${usage_dir}/complete.json" "${provider_model}" "${usage_dir}/tool-complete.json" "${usage_dir}/screenshots-complete.json" "${usage_dir}/render-tool-missing.json"
printf '[]\n' >"${usage_dir}/screenshots-missing.json"
expect_failure "missing process-bound screenshots produced route success" "${PROOF_SCRIPT}" --test-route-outcome "${usage_dir}/complete.json" "${provider_model}" "${usage_dir}/tool-complete.json" "${usage_dir}/screenshots-missing.json" "${usage_dir}/render-complete.json"

if grep -En 'RelayKit demo provider response|choices:.*content:.*response' "${PROOF_SCRIPT}" >/dev/null; then
  fail "public fixture still returns fixed model success text"
fi
grep -Fq 'write_desktop_tool_evidence()' "${PROOF_SCRIPT}" ||
  fail "manual proof must derive redacted tool-call evidence from the isolated current run"
grep -Fq 'verify_desktop_window_identity()' "${PROOF_SCRIPT}" ||
  fail "manual proof must re-verify the isolated PID/window identity"
grep -Fq 'capture_desktop_window "before-manual-input"' "${PROOF_SCRIPT}" ||
  fail "manual proof must capture the process-bound window before manual input"
for screenshot_role in gpt55-response gpt56-response provider-markdown provider-tool; do
  grep -Fq "wait_for_verified_stage_checkpoint \"${screenshot_role}\"" "${PROOF_SCRIPT}" ||
    fail "manual proof is missing verified stage checkpoint ${screenshot_role}"
done
grep -Fq 'capture_desktop_window "${role}"' "${PROOF_SCRIPT}" ||
  fail "verified stage checkpoints must capture the process-bound window"
grep -Fq 'write_desktop_render_evidence()' "${PROOF_SCRIPT}" ||
  fail "manual proof must derive GUI render evidence from current-run rollout and screenshots"
grep -Fq 'VNRecognizeTextRequest' "${PROOF_SCRIPT}" ||
  fail "manual proof must inspect process-bound screenshots instead of trusting typed confirmation"

table_ocr_fixture="${tmp_dir}/table-ocr-fixture.png"
swift - "${table_ocr_fixture}" <<'SWIFT'
import AppKit
import Foundation

let output = CommandLine.arguments[1]
let size = NSSize(width: 1400, height: 1000)
let image = NSImage(size: size)
image.lockFocus()
NSColor.white.setFill()
NSRect(origin: .zero, size: size).fill()
let attributes: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 30),
    .foregroundColor: NSColor.black,
]
let lines = [
    "exactly two table columns named status and route",
    "table row ready and official",
    "table row ready and provider",
    "status                         route",
    "ready                          official",
    "ready                          provider",
]
for (index, line) in lines.enumerated() {
    NSString(string: line).draw(at: NSPoint(x: 360, y: 850 - (index * 100)), withAttributes: attributes)
}
image.unlockFocus()
guard let tiff = image.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiff),
      let png = bitmap.representation(using: .png, properties: [:]) else {
    exit(2)
}
try png.write(to: URL(fileURLWithPath: output))
SWIFT
"${PROOF_SCRIPT}" --test-screenshot-analysis provider-markdown "${table_ocr_fixture}" >"${tmp_dir}/table-ocr-result.json"
jq -e '.table_headers_visible == true' "${tmp_dir}/table-ocr-result.json" >/dev/null

echo "Manual proof split table-header OCR test passed"

benign_unauthorized_fixture="${tmp_dir}/benign-unauthorized-fixture.png"
swift - "${benign_unauthorized_fixture}" <<'SWIFT'
import AppKit
import Foundation

let output = CommandLine.arguments[1]
let size = NSSize(width: 1400, height: 700)
let image = NSImage(size: size)
image.lockFocus()
NSColor.white.setFill()
NSRect(origin: .zero, size: size).fill()
let attributes: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 30),
    .foregroundColor: NSColor.black,
]
NSString(string: "RelayKit Official 55 Live: explain credential redaction").draw(at: NSPoint(x: 360, y: 500), withAttributes: attributes)
NSString(string: "RelayKit Official 55 Live: exposed secrets can enable unauthorized access").draw(at: NSPoint(x: 360, y: 350), withAttributes: attributes)
image.unlockFocus()
guard let tiff = image.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiff),
      let png = bitmap.representation(using: .png, properties: [:]) else {
    exit(2)
}
try png.write(to: URL(fileURLWithPath: output))
SWIFT
"${PROOF_SCRIPT}" --test-screenshot-analysis gpt55-response "${benign_unauthorized_fixture}" >"${tmp_dir}/benign-unauthorized-result.json"
jq -e '.official55_response_visible == true and .auth_error_visible == false' "${tmp_dir}/benign-unauthorized-result.json" >/dev/null

echo "Manual proof benign unauthorized wording OCR test passed"

localized_tool_fixture="${tmp_dir}/localized-tool-fixture.png"
tool_ocr_marker="RELAYKITTOOLLOCALIZEDTEST"
swift - "${localized_tool_fixture}" "${tool_ocr_marker}" <<'SWIFT'
import AppKit
import Foundation

let output = CommandLine.arguments[1]
let marker = CommandLine.arguments[2]
let size = NSSize(width: 1400, height: 800)
let image = NSImage(size: size)
image.lockFocus()
NSColor.white.setFill()
NSRect(origin: .zero, size: size).fill()
let attributes: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 30),
    .foregroundColor: NSColor.black,
]
let lines = [
    "Use the shell tool to run exactly: printf '\(marker)\\n'",
    "运行了多个命令",
    "已运行 printf '\(marker)\\n'",
    "已处理 5s",
    marker,
]
for (index, line) in lines.enumerated() {
    NSString(string: line).draw(at: NSPoint(x: 360, y: 650 - (index * 110)), withAttributes: attributes)
}
image.unlockFocus()
guard let tiff = image.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiff),
      let png = bitmap.representation(using: .png, properties: [:]) else {
    exit(2)
}
try png.write(to: URL(fileURLWithPath: output))
SWIFT
"${PROOF_SCRIPT}" --test-screenshot-analysis provider-tool "${localized_tool_fixture}" "${tool_ocr_marker}" >"${tmp_dir}/localized-tool-result.json"
jq -e '.tool_marker_visible == true and .tool_execution_visible == true and .raw_protocol_visible == false' "${tmp_dir}/localized-tool-result.json" >/dev/null

echo "Manual proof localized completed-tool OCR test passed"

for evidence_field in gpt56_gui_completed official_picker_has_spark official_picker_excludes_gpt52 markdown_render_verified raw_protocol_absent tool_gui_verified; do
  grep -Fq "${evidence_field}:" "${PROOF_SCRIPT}" ||
    fail "manual proof evidence is missing ${evidence_field}"
done

test "$("${PROOF_SCRIPT}" --test-tool-ui-review-status automated_ax true true)" = "derived_from_current_run_rollout_and_process_bound_screenshot"
test "$("${PROOF_SCRIPT}" --test-tool-ui-review-status manual_user_only true true)" = "derived_from_current_run_rollout_and_process_bound_screenshot"
test "$("${PROOF_SCRIPT}" --test-tool-ui-review-status isolated_codex_cli_fallback true true)" = "rollout_verified_gui_display_not_verified"
test "$("${PROOF_SCRIPT}" --test-tool-ui-review-status automated_ax true false)" = "rollout_verified_gui_display_not_verified"
test "$("${PROOF_SCRIPT}" --test-tool-ui-review-status automated_ax false true)" = "not_verified"
grep -Fq -- '--arg input_mode "${PROOF_INPUT_MODE}"' "${PROOF_SCRIPT}" ||
  fail "manual proof evidence must record the actual input mode"
grep -Fq 'and $input_mode == "manual_user_only"' "${PROOF_SCRIPT}" ||
  fail "CLI fallback evidence must not be labeled as manual Desktop GUI proof"
if grep -Fq 'collect_user_review()' "${PROOF_SCRIPT}"; then
  fail "manual proof must not convert typed confirmation into tool-call evidence"
fi

RELAYKIT_DESKTOP_PROOF_INPUT_MODE=manual_user_only "${PROOF_SCRIPT}" --test-input-mode
RELAYKIT_DESKTOP_PROOF_INPUT_MODE=isolated_codex_cli_fallback "${PROOF_SCRIPT}" --test-input-mode
RELAYKIT_DESKTOP_PROOF_INPUT_MODE=automated_ax "${PROOF_SCRIPT}" --test-input-mode
expect_failure "manual proof accepted an unknown input mode" env \
  RELAYKIT_DESKTOP_PROOF_INPUT_MODE=unsupported \
  "${PROOF_SCRIPT}" --test-input-mode
RELAYKIT_DESKTOP_PROOF_INPUT_MODE=automated_ax "${PROOF_SCRIPT}" --test-automated-input-mode
expect_failure "run-auto accepted the manual input mode" env \
  RELAYKIT_DESKTOP_PROOF_INPUT_MODE=manual_user_only \
  "${PROOF_SCRIPT}" --test-automated-input-mode

config_home="${tmp_dir}/isolated-config-home"
mkdir -p "${config_home}"
HOME="${config_home}" "${PROOF_SCRIPT}" --test-write-codex-config 19999
isolated_config="${config_home}/Library/Application Support/RelayKit/DesktopProof/official-proof/codex-home/config.toml"
grep -Fx 'model = "gpt-5.5"' "${isolated_config}" >/dev/null
grep -Fx 'sandbox_mode = "read-only"' "${isolated_config}" >/dev/null
grep -Fx 'openai_base_url = "http://127.0.0.1:19999/v1"' "${isolated_config}" >/dev/null

scenario_dir="${tmp_dir}/auto-scenario"
mkdir -m 700 "${scenario_dir}"
query_file="${scenario_dir}/query.txt"
printf 'Reply exactly RELAYKIT_AUTO_TEST\n' >"${query_file}"
chmod 600 "${query_file}"
scenario_file="${scenario_dir}/scenario.json"
cat >"${scenario_file}" <<JSON
{"version":1,"stages":[{"id":"route-check","model_id":"public/model","model_label":"Public Model","query_file":"${query_file}","response_marker":"RELAYKIT_AUTO_TEST","evidence_role":"gpt55-response","expect":"plain"}]}
JSON
chmod 600 "${scenario_file}"
"${PROOF_SCRIPT}" --test-auto-scenario "${scenario_file}" >"${scenario_dir}/normalized.json"
jq -e '.version == 1 and (.stages | length) == 1 and .stages[0].id == "route-check"' "${scenario_dir}/normalized.json" >/dev/null

scenario_guard_file="${scenario_dir}/scenario-guard.json"
cp "${scenario_file}" "${scenario_guard_file}"
scenario_guard_hash="$(/usr/bin/shasum -a 256 "${scenario_guard_file}" | awk '{print $1}')"
"${PROOF_SCRIPT}" --test-scenario-state-guard "${scenario_guard_file}" "${scenario_guard_hash}"
printf '\n' >>"${scenario_guard_file}"
expect_failure "automated proof accepted a changed scenario" \
  "${PROOF_SCRIPT}" --test-scenario-state-guard "${scenario_guard_file}" "${scenario_guard_hash}"

echo "Manual proof scenario mutation guard test passed"

markdown_fixture="${scenario_dir}/markdown-scrolled-assistant.png"
top_markdown_fixture="${scenario_dir}/markdown-top-assistant.png"
prompt_only_fixture="${scenario_dir}/markdown-prompt-only.png"
flat_assistant_fixture="${scenario_dir}/markdown-flat-assistant.png"
swift - "${markdown_fixture}" "${prompt_only_fixture}" "${flat_assistant_fixture}" "${top_markdown_fixture}" <<'SWIFT'
import AppKit
import Foundation

func draw(_ text: String, x: CGFloat, y: CGFloat, size: CGFloat = 24, bold: Bool = false, color: NSColor = .black) {
    let font = bold ? NSFont.boldSystemFont(ofSize: size) : NSFont.systemFont(ofSize: size)
    text.draw(at: NSPoint(x: x, y: y), withAttributes: [.font: font, .foregroundColor: color])
}

func writeImage(path: String, mode: String) throws {
    let canvas = NSSize(width: 1280, height: 820)
    let image = NSImage(size: canvas)
    image.lockFocus()
    NSColor.white.setFill()
    NSRect(origin: .zero, size: canvas).fill()
    if mode == "promptOnly" {
        draw("RelayKit Rich Text Check", x: 340, y: 785, size: 18, bold: true)
        draw("1. First route check 2. Second route check", x: 340, y: 760, size: 16)
        draw("status route ready official ready provider", x: 340, y: 735, size: 16)
        draw("bash echo relaykit RELAYKIT_FORMAT_OK", x: 340, y: 710, size: 16)
    } else if mode == "flatAssistant" {
        draw("RelayKit Rich Text Check 1. First route check 2. Second route check", x: 320, y: 560, size: 17)
        draw("status route ready official ready provider", x: 320, y: 520, size: 17)
        draw("bash echo relaykit RELAYKIT_FORMAT_OK", x: 320, y: 480, size: 17)
    } else if mode == "topAssistant" {
        draw("RelayKit Rich Text Check", x: 340, y: 710, size: 30, bold: true)
        draw("1. First route check", x: 340, y: 665)
        draw("2. Second route check", x: 340, y: 625)
        draw("status", x: 340, y: 570, bold: true)
        draw("route", x: 720, y: 570, bold: true)
        draw("ready", x: 340, y: 525)
        draw("official", x: 720, y: 525)
        draw("ready", x: 340, y: 480)
        draw("provider", x: 720, y: 480)
        draw("bash", x: 340, y: 405, size: 18)
        draw("echo", x: 360, y: 360, color: .systemOrange)
        draw("relaykit", x: 450, y: 354)
        draw("RELAYKIT_FORMAT_OK", x: 340, y: 295, size: 26, bold: true)
    } else {
        draw("Previous prompt is scrolled above the visible response", x: 320, y: 770, size: 18)
        draw("RelayKit Rich Text Check", x: 340, y: 650, size: 30, bold: true)
        draw("1. First route check", x: 340, y: 605)
        draw("2. Second route check", x: 340, y: 565)
        draw("status", x: 340, y: 510, bold: true)
        draw("route", x: 720, y: 510, bold: true)
        draw("ready", x: 340, y: 465)
        draw("official", x: 720, y: 465)
        draw("ready", x: 340, y: 420)
        draw("provider", x: 720, y: 420)
        draw("bash", x: 340, y: 345, size: 18)
        draw("echo", x: 360, y: 300, color: .systemOrange)
        draw("relaykit", x: 450, y: 294)
        draw("RELAYKIT_FORMAT_OK", x: 340, y: 235, size: 26, bold: true)
    }
    image.unlockFocus()
    guard let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let png = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "RelayKitFixture", code: 1)
    }
    try png.write(to: URL(fileURLWithPath: path))
}

try writeImage(path: CommandLine.arguments[1], mode: "valid")
try writeImage(path: CommandLine.arguments[2], mode: "promptOnly")
try writeImage(path: CommandLine.arguments[3], mode: "flatAssistant")
try writeImage(path: CommandLine.arguments[4], mode: "topAssistant")
SWIFT

"${PROOF_SCRIPT}" --test-screenshot-analysis provider-markdown "${markdown_fixture}" RELAYKIT_FORMAT_OK >"${scenario_dir}/markdown-scrolled-analysis.json"
jq -e '
  .assistant_response_line_count > 0 and
  .heading_visible == true and
  .numbered_items_visible == true and
  .table_headers_visible == true and
  .bash_code_visible == true and
  .bold_conclusion_visible == true and
  .raw_protocol_visible == false
' "${scenario_dir}/markdown-scrolled-analysis.json" >/dev/null

"${PROOF_SCRIPT}" --test-screenshot-analysis provider-markdown "${top_markdown_fixture}" RELAYKIT_FORMAT_OK >"${scenario_dir}/markdown-top-analysis.json"
jq -e '
  .heading_visible == true and
  .numbered_items_visible == true and
  .table_headers_visible == true and
  .bash_code_visible == true and
  .bold_conclusion_visible == true
' "${scenario_dir}/markdown-top-analysis.json" >/dev/null

"${PROOF_SCRIPT}" --test-screenshot-analysis provider-markdown "${prompt_only_fixture}" RELAYKIT_FORMAT_OK >"${scenario_dir}/markdown-prompt-only-analysis.json"
if jq -e '.heading_visible or .numbered_items_visible or .table_headers_visible or .bash_code_visible or .bold_conclusion_visible' "${scenario_dir}/markdown-prompt-only-analysis.json" >/dev/null; then
  fail "Markdown visual proof accepted tokens that appeared only in the user prompt region"
fi

"${PROOF_SCRIPT}" --test-screenshot-analysis provider-markdown "${flat_assistant_fixture}" RELAYKIT_FORMAT_OK >"${scenario_dir}/markdown-flat-assistant-analysis.json"
if jq -e '.heading_visible or .numbered_items_visible or .table_headers_visible or .bash_code_visible or .bold_conclusion_visible' "${scenario_dir}/markdown-flat-assistant-analysis.json" >/dev/null; then
  fail "Markdown visual proof accepted flattened assistant text as structured rendering"
fi

echo "Manual proof scrolled Markdown screenshot analysis test passed"

cat >"${scenario_dir}/app-server-labels.json" <<'JSON'
{
  "official": [{"model":"gpt-5.6-luna","displayName":"GPT-5.6-Luna"}],
  "provider": [{"model":"public/model","displayName":"Current Provider Label"}]
}
JSON
test "$("${PROOF_SCRIPT}" --test-resolve-automated-model-label "${scenario_dir}/app-server-labels.json" gpt-5.6-luna)" = "GPT-5.6-Luna"
test "$("${PROOF_SCRIPT}" --test-resolve-automated-model-label "${scenario_dir}/app-server-labels.json" public/model)" = "Current Provider Label"
expect_failure "automated proof accepted a scenario label for a model absent from current app-server data" \
  "${PROOF_SCRIPT}" --test-resolve-automated-model-label "${scenario_dir}/app-server-labels.json" missing/model
grep -Fq 'resolve_automated_model_label "${OUT}/app-server.json" "${model_id}"' "${PROOF_SCRIPT}" ||
  fail "automated proof must resolve the current picker label from stable model id"

scenario_link="${scenario_dir}/scenario-link.json"
ln -s "${scenario_file}" "${scenario_link}"
expect_failure "automated scenario accepted a symlinked scenario file" "${PROOF_SCRIPT}" --test-auto-scenario "${scenario_link}"

query_link="${scenario_dir}/query-link.txt"
ln -s "${query_file}" "${query_link}"
jq --arg query_file "${query_link}" '.stages[0].query_file = $query_file' "${scenario_file}" >"${scenario_dir}/symlink-query.json"
chmod 600 "${scenario_dir}/symlink-query.json"
expect_failure "automated scenario accepted a symlinked query file" "${PROOF_SCRIPT}" --test-auto-scenario "${scenario_dir}/symlink-query.json"

missing_marker_query="${scenario_dir}/missing-marker.txt"
printf 'Reply with an unrelated value\n' >"${missing_marker_query}"
chmod 600 "${missing_marker_query}"
jq --arg query_file "${missing_marker_query}" '.stages[0].query_file = $query_file' "${scenario_file}" >"${scenario_dir}/missing-marker.json"
chmod 600 "${scenario_dir}/missing-marker.json"
expect_failure "automated scenario accepted a query that omitted response_marker" "${PROOF_SCRIPT}" --test-auto-scenario "${scenario_dir}/missing-marker.json"

chmod 644 "${query_file}"
expect_failure "automated scenario accepted a non-0600 query file" "${PROOF_SCRIPT}" --test-auto-scenario "${scenario_file}"
chmod 600 "${query_file}"
jq '.stages[0].expect = "arbitrary-script"' "${scenario_file}" >"${scenario_dir}/bad-expect.json"
chmod 600 "${scenario_dir}/bad-expect.json"
expect_failure "automated scenario accepted an unknown expectation profile" "${PROOF_SCRIPT}" --test-auto-scenario "${scenario_dir}/bad-expect.json"

cat >"${scenario_dir}/fresh-usage.json" <<'JSON'
[
  {"request_id":"old","model":"public/model","status":"completed","http_status":200},
  {"request_id":"new","model":"public/model","status":"completed","http_status":200}
]
JSON
expect_failure "stale usage before the stage boundary satisfied an automated stage" \
  "${PROOF_SCRIPT}" --test-fresh-stage-usage "${scenario_dir}/fresh-usage.json" 1 "other/model"
"${PROOF_SCRIPT}" --test-fresh-stage-usage "${scenario_dir}/fresh-usage.json" 1 "public/model" >"${scenario_dir}/fresh-event.json"
jq -e '.event_count == 1 and .model == "public/model" and .status == "completed" and .http_status == 200' "${scenario_dir}/fresh-event.json" >/dev/null
cat >"${scenario_dir}/duplicate-fresh-usage.json" <<'JSON'
[
  {"request_id":"old","model":"public/model","status":"completed","http_status":200},
  {"request_id":"new-one","model":"public/model","status":"completed","http_status":200},
  {"request_id":"new-two","model":"public/model","status":"completed","http_status":200}
]
JSON
"${PROOF_SCRIPT}" --test-fresh-stage-usage "${scenario_dir}/duplicate-fresh-usage.json" 1 "public/model" >"${scenario_dir}/duplicate-fresh-event.json"
jq -e '.event_count == 2 and .model == "public/model" and .status == "completed" and .http_status == 200' "${scenario_dir}/duplicate-fresh-event.json" >/dev/null
cat >"${scenario_dir}/mixed-fresh-usage.json" <<'JSON'
[
  {"request_id":"old","model":"public/model","status":"completed","http_status":200},
  {"request_id":"new-one","model":"public/model","status":"completed","http_status":200},
  {"request_id":"new-two","model":"public/model","status":"failed","http_status":500}
]
JSON
expect_failure "a failed matching upstream usage satisfied an automated GUI stage" \
  "${PROOF_SCRIPT}" --test-fresh-stage-usage "${scenario_dir}/mixed-fresh-usage.json" 1 "public/model"

binding_home="${scenario_dir}/binding-home"
binding_sessions="${binding_home}/sessions/2099/07/11"
mkdir -p "${binding_sessions}"
cat >"${binding_sessions}/rollout-auto.jsonl" <<'JSONL'
{"timestamp":"2099-07-11T00:00:00Z","type":"session_meta","payload":{"id":"thread-auto"}}
{"timestamp":"2099-07-11T00:00:01Z","type":"turn_context","payload":{"model":"public/model"}}
{"timestamp":"2099-07-11T00:00:02Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Reply with RELAYKIT_AUTO_BIND"}]}}
{"timestamp":"2099-07-11T00:00:03Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"RELAYKIT_AUTO_BIND"}]}}
JSONL
"${PROOF_SCRIPT}" --test-auto-rollout-binding "${binding_home}" 0 "public/model" "RELAYKIT_AUTO_BIND" "${scenario_dir}/binding.json"
jq -e '.proof_found == true and .thread_id == "thread-auto" and .model == "public/model" and .user_marker_found == true and .assistant_marker_found == true' "${scenario_dir}/binding.json" >/dev/null
expect_failure "wrong rollout model satisfied an automated stage binding" \
  "${PROOF_SCRIPT}" --test-auto-rollout-binding "${binding_home}" 0 "other/model" "RELAYKIT_AUTO_BIND" "${scenario_dir}/wrong-binding.json"
cat >>"${binding_sessions}/rollout-auto.jsonl" <<'JSONL'
{"timestamp":"2099-07-11T00:00:04Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Reply with RELAYKIT_AUTO_BIND"}]}}
{"timestamp":"2099-07-11T00:00:05Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"RELAYKIT_AUTO_BIND"}]}}
JSONL
expect_failure "duplicate marker messages satisfied a single automated rollout binding" \
  "${PROOF_SCRIPT}" --test-auto-rollout-binding "${binding_home}" 0 "public/model" "RELAYKIT_AUTO_BIND" "${scenario_dir}/duplicate-binding.json"

cat >"${scenario_dir}/standard-profile.json" <<'JSON'
{"stages":[
  {"model_id":"gpt-5.5","evidence_role":"gpt55-response","expect":"plain"},
  {"model_id":"gpt-5.6-luna","evidence_role":"gpt56-response","expect":"plain"},
  {"model_id":"public/provider-model","evidence_role":"provider-markdown","expect":"markdown"},
  {"model_id":"public/provider-model","evidence_role":"provider-tool","expect":"tool"}
]}
JSON
test "$("${PROOF_SCRIPT}" --test-automated-profile "${scenario_dir}/standard-profile.json" "public/provider-model")" = "standard_four_stage_dogfood"
test "$("${PROOF_SCRIPT}" --test-automated-profile "${scenario_file}" "public/provider-model")" = "custom_scenario"

cat >"${scenario_dir}/complete-stages.json" <<'JSON'
[
  {"id":"one","evidence_role":"role-one","state":"evidence_verified","submission_state":"submitted","rollout_binding":{"proof_found":true,"thread_id":"thread-one","user_marker_count":1,"assistant_marker_count":1}},
  {"id":"two","evidence_role":"role-two","state":"evidence_verified","submission_state":"submitted","rollout_binding":{"proof_found":true,"thread_id":"thread-two","user_marker_count":1,"assistant_marker_count":1}}
]
JSON
"${PROOF_SCRIPT}" --test-automated-stages-complete "${scenario_dir}/complete-stages.json" 2
jq '.[1].rollout_binding.thread_id = "thread-one"' "${scenario_dir}/complete-stages.json" >"${scenario_dir}/duplicate-thread-stages.json"
expect_failure "automated stages accepted a reused rollout thread" \
  "${PROOF_SCRIPT}" --test-automated-stages-complete "${scenario_dir}/duplicate-thread-stages.json" 2
jq '.[1].state = "submitted"' "${scenario_dir}/complete-stages.json" >"${scenario_dir}/incomplete-stages.json"
expect_failure "automated stages accepted an incomplete stage" \
  "${PROOF_SCRIPT}" --test-automated-stages-complete "${scenario_dir}/incomplete-stages.json" 2

auto_body="$(sed -n '/^run_automated_proof() {/,/^}/p' "${PROOF_SCRIPT}")"
auto_wait_body="$(sed -n '/^wait_for_automated_stage() {/,/^}/p' "${PROOF_SCRIPT}")"
if grep -Eq 'wait_for_user_continue|read -r _|continue_file' <<<"${auto_body}"; then
  fail "automated proof must never wait for user input"
fi
grep -Fq 'refresh_automated_stage_evidence' <<<"${auto_wait_body}" ||
  fail "automated proof must refresh stage evidence before verification"
grep -Fq '"${AX_DRIVER_BINARY}" reveal' <<<"${auto_wait_body}" ||
  fail "Markdown proof must reveal an exact off-screen heading through AX"
grep -Fq 'submission_state="submitted"' <<<"${auto_body}" ||
  fail "automated proof must record the point after which it cannot safely resend"
grep -Fq 'codex-desktop-ax-driver.swift' <<<"${auto_body}" ||
  fail "automated proof must invoke the deterministic AX driver"
test "$(rg -c '"\$\{AX_DRIVER_BINARY\}" submit' <<<"${auto_body}")" -eq 1 ||
  fail "the automated state machine must contain exactly one submit call site"
catalog_labels_line="$(grep -n 'write_automated_catalog_labels' <<<"${auto_body}" | cut -d: -f1 | head -1)"
desktop_launch_line="$(grep -n 'launch_desktop' <<<"${auto_body}" | cut -d: -f1 | head -1)"
[[ -n "${catalog_labels_line}" && -n "${desktop_launch_line}" && "${catalog_labels_line}" -lt "${desktop_launch_line}" ]] ||
  fail "automated catalog labels must exist before Desktop readiness is evaluated"
ready_body="$(sed -n '/^wait_for_desktop_ui_ready() {/,/^}/p' "${PROOF_SCRIPT}")"
grep -Fq '"${AX_DRIVER_BINARY}" ready' <<<"${ready_body}" ||
  fail "automated Desktop readiness must require the exact catalog picker and composer"
prepare_call_line="$(grep -n '"${AX_DRIVER_BINARY}" prepare' <<<"${auto_body}" | cut -d: -f1)"
submit_call_line="$(grep -n '"${AX_DRIVER_BINARY}" submit' <<<"${auto_body}" | cut -d: -f1)"
activation_lines="$(grep -n 'activate_isolated_desktop' <<<"${auto_body}" | cut -d: -f1)"
activation_before_prepare="$(awk -v target="${prepare_call_line}" '$1 < target {last=$1} END {print last}' <<<"${activation_lines}")"
activation_before_submit="$(awk -v lower="${prepare_call_line}" -v upper="${submit_call_line}" '$1 > lower && $1 < upper {last=$1} END {print last}' <<<"${activation_lines}")"
[[ -n "${activation_before_prepare}" && -n "${activation_before_submit}" ]] ||
  fail "the harness must reactivate the bound Desktop PID immediately before prepare and submit"
activation_body="$(sed -n '/^activate_isolated_desktop() {/,/^}/p' "${PROOF_SCRIPT}")"
if grep -Fq 'guard app.activate' <<<"${activation_body}"; then
  fail "Desktop activation must not treat the immediate NSRunningApplication boolean as terminal"
fi
grep -Fq '_ = app.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])' <<<"${activation_body}" ||
  fail "Desktop activation must request the exact PID and wait for observed frontmost identity"
grep -Fq 'AXUIElementSetAttributeValue(accessibilityApp, kAXFrontmostAttribute as CFString, kCFBooleanTrue)' <<<"${activation_body}" ||
  fail "Desktop activation needs an exact-PID Accessibility fallback"
grep -Fq 'NSWorkspace.shared.frontmostApplication?.processIdentifier == targetPID' <<<"${activation_body}" ||
  fail "Desktop activation must verify the observed frontmost PID"
if grep -Fq 'if run_automated_proof' "${PROOF_SCRIPT}"; then
  fail "run-auto must not disable function-level errexit by invoking the state machine as an if-condition"
fi
grep -Fq 'handle_automated_signal()' "${PROOF_SCRIPT}" ||
  fail "automated proof needs an explicit signal path into fail-closed cleanup"
grep -Fq 'trap handle_automated_signal INT TERM HUP' "${PROOF_SCRIPT}" ||
  fail "automated proof must preserve interrupted current-run evidence"
grep -Fq 'automated_stages_complete' <<<"${auto_body}" ||
  fail "automated proof must verify the expected stage count and unique rollout threads before completion"
grep -Fq 'write_desktop_render_evidence "${overall_since}" "${PROOF_PROVIDER_MODEL_ID}" "${SCREENSHOT_EVIDENCE}" "${gpt55_marker}" "${gpt56_marker}"' <<<"${auto_body}" ||
  fail "final render evidence must use the current scenario official markers"
grep -Fq 'driver_failure_code' <<<"${auto_body}" ||
  fail "automated proof must preserve the AX driver's redacted failure code"
cleanup_body="$(sed -n '/^cleanup_processes() {/,/^}/p' "${PROOF_SCRIPT}")"
grep -Fq 'automated-query-' <<<"${cleanup_body}" ||
  fail "automated proof cleanup must remove staged private query copies after interruption"
reset_markers_body="$(sed -n '/^reset_run_markers() {/,/^}/p' "${PROOF_SCRIPT}")"
grep -Fq 'automated-rollout-' <<<"${reset_markers_body}" ||
  fail "a fresh automated run must remove stale rollout bindings"
grep -Fq 'ax-prepare-' <<<"${reset_markers_body}" ||
  fail "a fresh automated run must remove stale AX prepare reports"
grep -Fq 'ax-submit-' <<<"${reset_markers_body}" ||
  fail "a fresh automated run must remove stale AX submit reports"

test -f "${AX_DRIVER}" || fail "automated proof AX driver is missing"

echo "Manual proof route outcome tests passed"

render_codex_home="${tmp_dir}/render-codex-home"
render_rollout_dir="${render_codex_home}/sessions/2099/07/10"
render_output="${tmp_dir}/render-evidence.json"
render_gpt55_marker="RELAYKIT55LIVE20990710"
render_gpt56_marker="RELAYKIT56LIVE20990710"
mkdir -p "${render_rollout_dir}"
cat >"${render_rollout_dir}/rollout-current.jsonl" <<JSONL
{"timestamp":"2099-07-10T00:00:00Z","type":"turn_context","payload":{"model":"gpt-5.5"}}
{"timestamp":"2099-07-10T00:00:01Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"${render_gpt55_marker}: redaction protects credentials."}]}}
{"timestamp":"2099-07-10T00:00:02Z","type":"turn_context","payload":{"model":"gpt-5.6-luna"}}
{"timestamp":"2099-07-10T00:00:03Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"${render_gpt56_marker}: this run uses the bundled CLI."}]}}
{"timestamp":"2099-07-10T00:00:04Z","type":"turn_context","payload":{"model":"${provider_model}"}}
{"timestamp":"2099-07-10T00:00:05Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"## RelayKit Rich Text Check\n1. First route check\n2. Second route check\n\n| status | route |\n| --- | --- |\n| ready | official |\n| ready | provider |\n\n\u0060\u0060\u0060bash\necho relaykit\n\u0060\u0060\u0060\n\n**RELAYKIT_FORMAT_OK**"}]}}
JSONL
"${PROOF_SCRIPT}" --test-render-evidence "${render_codex_home}" "${render_output}" 0 "${provider_model}" "${usage_dir}/screenshots-markdown-split.json" "${render_gpt55_marker}" "${render_gpt56_marker}"
jq -e '
  .gpt55_gui_visible == true and
  .gpt56_gui_visible == true and
  .markdown_source_contract_verified == true and
  .markdown_render_verified == true and
  .raw_protocol_absent == true and
  .tool_gui_verified == true
' "${render_output}" >/dev/null

cat >>"${render_rollout_dir}/rollout-current.jsonl" <<'JSONL'
{"timestamp":"2099-07-10T00:00:06Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"<invoke>raw</invoke>"}]}}
JSONL
"${PROOF_SCRIPT}" --test-render-evidence "${render_codex_home}" "${render_output}" 0 "${provider_model}" "${usage_dir}/screenshots-markdown-split.json" "${render_gpt55_marker}" "${render_gpt56_marker}"
jq -e '.raw_protocol_absent == false and .markdown_render_verified == false' "${render_output}" >/dev/null

echo "Manual proof GUI render evidence tests passed"

tool_codex_home="${tmp_dir}/tool-codex-home"
tool_rollout_dir="${tool_codex_home}/sessions/2026/07/10"
tool_output="${tmp_dir}/tool-evidence.json"
tool_marker="RELAYKIT_TOOL_TEST_MARKER"
mkdir -p "${tool_rollout_dir}"
cat >"${tool_rollout_dir}/rollout-current.jsonl" <<JSONL
{"timestamp":"2099-07-10T00:00:00Z","type":"turn_context","payload":{"model":"${provider_model}"}}
{"timestamp":"2099-07-10T00:00:01Z","type":"response_item","payload":{"type":"function_call","name":"exec_command","call_id":"call-current","arguments":"{\\"cmd\\":\\"printf '${tool_marker}\\\\n'\\"}"}}
{"timestamp":"2099-07-10T00:00:02Z","type":"response_item","payload":{"type":"function_call_output","call_id":"call-current","output":"Process exited with code 0\\nFinal output:\\n${tool_marker}\\n"}}
JSONL
"${PROOF_SCRIPT}" --test-tool-evidence "${tool_codex_home}" "${tool_output}" 0 "${provider_model}" "${tool_marker}"
jq -e '
  .proof_found == true and
  .function_call_found == true and
  .function_call_output_found == true and
  .process_exited_zero == true and
  .matched_provider_tool_count == 1 and
  .xml_leak_found == false
' "${tool_output}" >/dev/null

bad_tool_codex_home="${tmp_dir}/bad-tool-codex-home"
bad_tool_rollout_dir="${bad_tool_codex_home}/sessions/2099/07/10"
bad_tool_output="${tmp_dir}/bad-tool-evidence.json"
mkdir -p "${bad_tool_rollout_dir}"
cat >"${bad_tool_rollout_dir}/rollout-current.jsonl" <<JSONL
{"timestamp":"2099-07-10T00:00:00Z","type":"turn_context","payload":{"model":"${provider_model}"}}
{"timestamp":"2099-07-10T00:00:01Z","type":"response_item","payload":{"type":"function_call","name":"exec_command","call_id":"call-failed","arguments":"{\"cmd\":\"printf '${tool_marker}\\\\n'\"}"}}
{"timestamp":"2099-07-10T00:00:02Z","type":"response_item","payload":{"type":"function_call_output","call_id":"call-failed","output":"Process exited with code 71\\nFinal output:\\n${tool_marker}\\n"}}
JSONL
"${PROOF_SCRIPT}" --test-tool-evidence "${bad_tool_codex_home}" "${bad_tool_output}" 0 "${provider_model}" "${tool_marker}"
jq -e '.proof_found == false and .process_exited_zero == false and .matched_provider_tool_count == 0' "${bad_tool_output}" >/dev/null
cat >>"${tool_rollout_dir}/rollout-current.jsonl" <<'JSONL'
{"timestamp":"2099-07-10T00:00:03Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"<function_calls>raw</function_calls>"}]}}
JSONL
"${PROOF_SCRIPT}" --test-tool-evidence "${tool_codex_home}" "${tool_output}" 0 "${provider_model}" "${tool_marker}"
jq -e '.proof_found == false and .xml_leak_found == true and .raw_function_calls_found == true' "${tool_output}" >/dev/null

echo "Manual proof rollout tool evidence tests passed"

expect_failure "real route policy accepted missing provider config" env \
  RELAYKIT_DESKTOP_PROOF_REAL_PROVIDER_CONFIG= \
  RELAYKIT_DESKTOP_PROOF_PUBLIC_MODEL_ID= \
  "${PROOF_SCRIPT}" --test-real-provider-policy

real_provider_config="${tmp_dir}/real-provider.json"
cat >"${real_provider_config}" <<'JSON'
{
  "providers": [
    {
      "id": "test-provider",
      "name": "Test Provider",
      "base_url": "https://provider.example.test/v1",
      "api_format": "openai_chat",
      "credential_ref": {"kind": "keychain", "value": "relaykit.test-only"},
      "models": [{"id": "public-provider/model", "upstream_model": "upstream-model"}]
    }
  ]
}
JSON
policy_output="$(RELAYKIT_DESKTOP_PROOF_REAL_PROVIDER_CONFIG="${real_provider_config}" RELAYKIT_DESKTOP_PROOF_PUBLIC_MODEL_ID="public-provider/model" "${PROOF_SCRIPT}" --test-real-provider-policy)"
test "${policy_output}" = "public-provider/model"
expect_failure "real route policy accepted a model not present in provider config" env \
  RELAYKIT_DESKTOP_PROOF_REAL_PROVIDER_CONFIG="${real_provider_config}" \
  RELAYKIT_DESKTOP_PROOF_PUBLIC_MODEL_ID="public-provider/missing" \
  "${PROOF_SCRIPT}" --test-real-provider-policy

echo "Manual proof real provider policy tests passed"

official_catalog="${tmp_dir}/official-models.json"
account_catalog="${tmp_dir}/account-models.json"
projected_catalog="${tmp_dir}/projected-models.json"
fixture_projected_catalog="${tmp_dir}/fixture-projected-models.json"
merged_catalog="${tmp_dir}/merged-models.json"
cat >"${official_catalog}" <<'JSON'
{
  "models": [
    {
      "slug": "gpt-5.6-sol",
      "display_name": "GPT-5.6-Sol",
      "default_reasoning_level": "low",
      "supported_reasoning_levels": [
        {"effort": "low", "description": "Fast"},
        {"effort": "max", "description": "Maximum"},
        {"effort": "ultra", "description": "Delegation"}
      ],
      "additional_speed_tiers": ["fast"],
      "service_tiers": [{"id": "priority", "name": "Fast"}],
      "visibility": "list",
      "priority": 1,
      "sentinel": {"preserve": true}
    },
    {
      "slug": "gpt-5.6-terra",
      "display_name": "GPT-5.6-Terra",
      "supported_reasoning_levels": [{"effort": "max"}, {"effort": "ultra"}],
      "visibility": "list",
      "priority": 2
    },
    {
      "slug": "gpt-5.6-luna",
      "display_name": "GPT-5.6-Luna",
      "supported_reasoning_levels": [{"effort": "max"}],
      "visibility": "list",
      "priority": 3
    },
    {
      "slug": "gpt-5.5",
      "display_name": "GPT-5.5",
      "supported_reasoning_levels": [{"effort": "medium"}],
      "visibility": "list",
      "priority": 7
    },
    {
      "slug": "gpt-5.2",
      "display_name": "GPT-5.2",
      "visibility": "list",
      "supported_in_api": true,
      "priority": 29
    },
    {
      "slug": "codex-auto-review",
      "display_name": "Codex Auto Review",
      "visibility": "hide",
      "priority": 43
    }
  ]
}
JSON
cat >"${account_catalog}" <<'JSON'
{
  "fetched_at": "2099-07-10T00:00:00Z",
  "models": [
    {
      "slug": "gpt-5.6-sol",
      "display_name": "GPT-5.6-Sol",
      "supported_reasoning_levels": [
        {"effort": "low", "description": "Fast"},
        {"effort": "max", "description": "Maximum"},
        {"effort": "ultra", "description": "Delegation"}
      ],
      "visibility": "list",
      "supported_in_api": true,
      "priority": 1
    },
    {
      "slug": "gpt-5.6-terra",
      "display_name": "GPT-5.6-Terra",
      "visibility": "list",
      "supported_in_api": true,
      "priority": 2
    },
    {
      "slug": "gpt-5.6-luna",
      "display_name": "GPT-5.6-Luna",
      "visibility": "list",
      "supported_in_api": true,
      "priority": 3
    },
    {
      "slug": "gpt-5.5",
      "display_name": "GPT-5.5",
      "visibility": "list",
      "supported_in_api": true,
      "priority": 7
    },
    {
      "slug": "gpt-5.3-codex-spark",
      "display_name": "GPT-5.3-Codex-Spark",
      "visibility": "list",
      "supported_in_api": false,
      "priority": 26,
      "sentinel": {"account_cache": true}
    },
    {
      "slug": "codex-auto-review",
      "display_name": "Codex Auto Review",
      "visibility": "hide",
      "supported_in_api": true,
      "priority": 43
    }
  ]
}
JSON
"${PROOF_SCRIPT}" --test-project-official-catalog \
  "${official_catalog}" "${account_catalog}" "real_isolated_route" "${projected_catalog}"
jq -e '
  ([.models[].slug] | index("gpt-5.6-luna")) and
  ([.models[].slug] | index("gpt-5.5")) and
  ([.models[].slug] | index("gpt-5.3-codex-spark")) and
  (([.models[].slug] | index("gpt-5.2")) | not) and
  ((.models[] | select(.slug == "gpt-5.3-codex-spark")) | .visibility == "list" and .supported_in_api == false and .sentinel.account_cache == true)
' "${projected_catalog}" >/dev/null
"${PROOF_SCRIPT}" --test-project-official-catalog \
  "${official_catalog}" "${tmp_dir}/missing-account-cache.json" "fixture_plumbing_preflight" "${fixture_projected_catalog}"
jq -e --slurpfile bundled "${official_catalog}" '.models == $bundled[0].models' "${fixture_projected_catalog}" >/dev/null

echo "Manual proof account-aware official catalog projection test passed"

cat >"${real_provider_config}" <<'JSON'
{
  "providers": [
    {
      "id": "test-provider",
      "name": "Test Provider",
      "base_url": "https://provider.example.test/v1",
      "api_format": "anthropic_messages",
      "routing": {"source": "relaykit-user-provider"},
      "credential_ref": {"kind": "keychain", "value": "relaykit.test-only"},
      "models": [
        {
          "id": "public-provider/claude-haiku",
          "display_name": "Claude Haiku Test",
          "upstream_model": "claude-haiku-upstream"
        },
        {
          "id": "public-provider/claude-sonnet",
          "display_name": "Claude Sonnet Test",
          "upstream_model": "claude-sonnet-upstream"
        }
      ]
    }
  ]
}
JSON
"${PROOF_SCRIPT}" --test-merge-model-catalog \
  "${projected_catalog}" "${real_provider_config}" "real_isolated_route" "${merged_catalog}"
jq -e --slurpfile official "${projected_catalog}" '
  .models[0:($official[0].models | length)] == $official[0].models and
  ([.models[].slug] | index("gpt-5.6-sol")) and
  ([.models[].slug] | index("gpt-5.6-terra")) and
  ([.models[].slug] | index("gpt-5.6-luna")) and
  ([.models[].slug] | index("gpt-5.3-codex-spark")) and
  (([.models[].slug] | index("gpt-5.2")) | not) and
  ((.models[] | select(.slug == "gpt-5.6-sol") | .supported_reasoning_levels | map(.effort)) == ["low", "max", "ultra"]) and
  ((.models[] | select(.slug == "public-provider/claude-haiku")) | .display_name == "Claude Haiku Test" and .upstream_model == "claude-haiku-upstream" and .source == "relaykit-user-provider" and .owned_by == "user-provider" and .visibility == "list" and .priority == 100) and
  ((.models[] | select(.slug == "public-provider/claude-sonnet")) | .display_name == "Claude Sonnet Test" and .upstream_model == "claude-sonnet-upstream" and .source == "relaykit-user-provider" and .owned_by == "user-provider" and .visibility == "list" and .priority == 100)
' "${merged_catalog}" >/dev/null
if grep -Fq 'Local Provider Proof Model' "${merged_catalog}"; then
  fail "merged model catalog still replaces provider display names with a generic placeholder"
fi

echo "Manual proof current Desktop catalog merge test passed"

gateway_config="${tmp_dir}/gateway-provider-config.json"
cat >"${gateway_config}" <<'JSON'
{
  "official_passthrough": {
    "base_url": "https://api.openai.example/v1",
    "credential_ref": {"kind": "codex_home", "value": "/tmp/isolated-codex-home"},
    "models": [{"id": "gpt-5.5", "display_name": "GPT-5.5"}]
  },
  "providers": []
}
JSON
bundled_codex_binary="/Applications/ChatGPT.app/Contents/Resources/codex"
"${PROOF_SCRIPT}" --test-sync-official-models "${projected_catalog}" "${gateway_config}" "${bundled_codex_binary}"
jq -e '
  (.official_passthrough.base_url == "https://api.openai.example/v1") and
  (.official_passthrough.codex_binary == "/Applications/ChatGPT.app/Contents/Resources/codex") and
  ([.official_passthrough.models[].id] == ["gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna", "gpt-5.5", "gpt-5.3-codex-spark"]) and
  ([.official_passthrough.models[].display_name] == ["GPT-5.6-Sol", "GPT-5.6-Terra", "GPT-5.6-Luna", "GPT-5.5", "GPT-5.3-Codex-Spark"])
' "${gateway_config}" >/dev/null

echo "Manual proof official gateway catalog sync test passed"

marker_home="${tmp_dir}/marker-home"
marker_run_dir="${marker_home}/Library/Application Support/RelayKit/DesktopProof/run"
mkdir -p "${marker_run_dir}"
printf 'enabled\n' >"${marker_run_dir}/desktop-sandbox-status"
printf '{}\n' >"${marker_run_dir}/desktop-window-identity.json"
printf 'stale\n' >"${marker_run_dir}/tool-marker"
printf '0\n' >"${marker_run_dir}/tool-since-epoch"
marker_output="$(HOME="${marker_home}" "${PROOF_SCRIPT}" --test-reset-run-markers)"
test "${marker_output}" = "not_launched"
test ! -e "${marker_run_dir}/desktop-window-identity.json"
test ! -e "${marker_run_dir}/tool-marker"
test ! -e "${marker_run_dir}/tool-since-epoch"

echo "Manual proof run marker reset test passed"
