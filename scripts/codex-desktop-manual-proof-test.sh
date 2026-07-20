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

grep -Fq '.code == "desktop_login_required"' "${PROOF_SCRIPT}" ||
  fail "manual proof readiness does not preserve the typed Desktop login blocker"

expect_failure() {
  local message="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    fail "${message}"
  fi
}

expect_typed_failure() {
  local expected_code="$1"
  local message="$2"
  shift 2
  local output
  if output="$("$@" 2>&1)"; then
    fail "${message}"
  fi
  grep -Fxq "${expected_code}" <<<"${output}" ||
    fail "${message}: expected ${expected_code}, got ${output}"
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
grep -Fq 'dismiss_known_model_nux()' "${PROOF_SCRIPT}" ||
  fail "manual proof must dismiss only the known first-run model NUX"
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
grep -Fq 'sandbox_mode = "danger-full-access"' "${PROOF_SCRIPT}" ||
  fail "externally sandboxed RC1 tool proof must avoid a conflicting nested Codex sandbox"
grep -Fq 'desktop_ui_ready()' "${PROOF_SCRIPT}" ||
  fail "manual proof needs a condition-based Desktop UI readiness probe"
desktop_launch_body="$(sed -n '/^launch_desktop() {/,/^}/p' "${PROOF_SCRIPT}")"
window_wait_line="$(grep -n 'wait_for_desktop_window' <<<"${desktop_launch_body}" | cut -d: -f1 | head -1)"
nux_dismiss_line="$(grep -n 'dismiss_known_model_nux' <<<"${desktop_launch_body}" | cut -d: -f1 | head -1)"
ui_wait_line="$(grep -n 'wait_for_desktop_ui_ready' <<<"${desktop_launch_body}" | cut -d: -f1 | head -1)"
[[ -n "${window_wait_line}" && -n "${nux_dismiss_line}" && -n "${ui_wait_line}" &&
   "${window_wait_line}" -lt "${nux_dismiss_line}" && "${nux_dismiss_line}" -lt "${ui_wait_line}" ]] ||
  fail "manual proof must dismiss the known model NUX after binding and before readiness"
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
grep -Fq 'RELAYKIT_APP_LAUNCH_TIMEOUT_SECONDS:-30' <<<"${relaykit_launch_body}" ||
  fail "signed App launch must allow a bounded cold-start wait"
grep -Fq 'app_launch_timeout_seconds >= 15 && app_launch_timeout_seconds <= 60' <<<"${relaykit_launch_body}" ||
  fail "signed App launch wait must remain bounded"
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
grep -Fq '/usr/bin/ditto -x -k "${ZIP_PATH}" "${APP_INSTALL_DIR}"' <<<"${prepare_app_body}" ||
  fail "manual proof must preserve sealed resources when extracting the current App zip"
if grep -Fq '/usr/bin/unzip' <<<"${prepare_app_body}"; then
  fail "manual proof current App zip extraction must not use unzip"
fi
verify_extracted_app_body="$(sed -n '/^verify_extracted_app_matches_zip() {/,/^}/p' "${PROOF_SCRIPT}")"
grep -Fq '/usr/bin/ditto -x -k "${zip_path}" "${scratch_dir}"' <<<"${verify_extracted_app_body}" ||
  fail "manual proof scratch verification must preserve sealed resources"
if grep -Fq '/usr/bin/unzip' <<<"${verify_extracted_app_body}"; then
  fail "manual proof scratch verification extraction must not use unzip"
fi
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
assisted_fixture_pids=()
cleanup() {
  if [[ -n "${stubborn_pid}" ]] && kill -0 "${stubborn_pid}" 2>/dev/null; then
    kill -KILL "${stubborn_pid}" 2>/dev/null || true
  fi
  for fixture_pid in "${assisted_fixture_pids[@]:-}"; do
    [[ -n "${fixture_pid}" ]] || continue
    kill "${fixture_pid}" 2>/dev/null || true
  done
  rm -rf "${tmp_dir}"
}
trap cleanup EXIT

stale_lock_root="${tmp_dir}/stale-lock-root"
stale_lock_profile="${stale_lock_root}/desktop-user-data"
mkdir -p "${stale_lock_profile}"
ln -s "relaykit-test-999999" "${stale_lock_profile}/SingletonLock"
ln -s "${tmp_dir}/missing-singleton-socket" "${stale_lock_profile}/SingletonSocket"
ln -s "relaykit-cookie-999999" "${stale_lock_profile}/SingletonCookie"
"${PROOF_SCRIPT}" --test-stale-desktop-lock-cleanup "${stale_lock_root}" "${stale_lock_profile}"
for singleton_name in SingletonLock SingletonSocket SingletonCookie; do
  [[ ! -e "${stale_lock_profile}/${singleton_name}" && ! -L "${stale_lock_profile}/${singleton_name}" ]] ||
    fail "dead isolated Desktop ${singleton_name} was not removed"
done

ln -s "relaykit-test-$$" "${stale_lock_profile}/SingletonLock"
ln -s "${tmp_dir}/missing-live-singleton-socket" "${stale_lock_profile}/SingletonSocket"
ln -s "relaykit-cookie-$$" "${stale_lock_profile}/SingletonCookie"
expect_failure "manual proof removed a live isolated Desktop lock" \
  "${PROOF_SCRIPT}" --test-stale-desktop-lock-cleanup "${stale_lock_root}" "${stale_lock_profile}"
for singleton_name in SingletonLock SingletonSocket SingletonCookie; do
  [[ -L "${stale_lock_profile}/${singleton_name}" ]] ||
    fail "live isolated Desktop ${singleton_name} was changed"
  rm -f "${stale_lock_profile}/${singleton_name}"
done

printf 'not a symlink\n' >"${stale_lock_profile}/SingletonLock"
expect_failure "manual proof removed an ambiguous non-symlink Desktop lock" \
  "${PROOF_SCRIPT}" --test-stale-desktop-lock-cleanup "${stale_lock_root}" "${stale_lock_profile}"
[[ -f "${stale_lock_profile}/SingletonLock" ]] ||
  fail "ambiguous non-symlink Desktop lock was changed"
rm -f "${stale_lock_profile}/SingletonLock"

echo "Manual proof isolated stale Desktop lock tests passed"

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

printf '{"route_proof_status":"complete","desktop_gui_route_proof":"automated_first_five_manual_official_tool_complete","usage_event_count":6,"sentinel":"assisted-complete"}\n' >"${current_route_dir}/evidence.json"
"${PROOF_SCRIPT}" --test-preserve-route-evidence "${current_route_dir}" "${last_attempt_dir}" "${last_complete_dir}"
jq -e '.sentinel == "assisted-complete"' "${last_attempt_dir}/evidence.json" >/dev/null
jq -e '.sentinel == "assisted-complete"' "${last_complete_dir}/evidence.json" >/dev/null

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

assisted_guard_config="${global_home}/.codex/assisted-config.toml"
assisted_guard_auth="${global_home}/.codex/assisted-auth.json"
grep -Fq -- '--test-assisted-global-guard-digest)' "${PROOF_SCRIPT}" ||
  fail "assisted opaque global guard digest fixture hook is missing"
grep -Fq -- '--test-assisted-global-state-guard)' "${PROOF_SCRIPT}" ||
  fail "assisted opaque global state guard fixture hook is missing"
printf 'model = "fixture-a"\nnotify = ["opaque-fixture-a"]\n' >"${assisted_guard_config}"
printf '{"fixture":"opaque-a"}\n' >"${assisted_guard_auth}"
assisted_guard_before="$(${PROOF_SCRIPT} --test-assisted-global-guard-digest "${assisted_guard_config}" "${assisted_guard_auth}")"
test "${assisted_guard_before}" = \
  "$("${PROOF_SCRIPT}" --test-assisted-global-guard-digest "${assisted_guard_config}" "${assisted_guard_auth}")" ||
  fail "assisted opaque global guard digest was not stable"
"${PROOF_SCRIPT}" --test-assisted-global-state-guard \
  "${assisted_guard_config}" "${assisted_guard_auth}" \
  "$(file_signature "${assisted_guard_config}")" "$(file_signature "${assisted_guard_auth}")" \
  "$(file_hash "${assisted_guard_config}")" "$(file_hash "${assisted_guard_auth}")"
printf 'model = "fixture-b"\nnotify = ["opaque-fixture-b"]\n' >"${assisted_guard_config}"
test "${assisted_guard_before}" != \
  "$("${PROOF_SCRIPT}" --test-assisted-global-guard-digest "${assisted_guard_config}" "${assisted_guard_auth}")" ||
  fail "assisted opaque global guard ignored a whole-file change"
expect_failure "assisted opaque global guard accepted changed whole-file SHA" \
  "${PROOF_SCRIPT}" --test-assisted-global-state-guard \
  "${assisted_guard_config}" "${assisted_guard_auth}" \
  "$(file_signature "${assisted_guard_config}")" "$(file_signature "${assisted_guard_auth}")" \
  "$(printf 'stale-config-hash')" "$(file_hash "${assisted_guard_auth}")"
assisted_guard_body="$(sed -n '/^current_global_guard_digest() {/,/^}/p' "${PROOF_SCRIPT}")"
if grep -Eq 'notify_line_hash|grep |cat ' <<<"${assisted_guard_body}"; then
  fail "assisted current global guard selectively parses global content"
fi
write_evidence_body="$(sed -n '/^write_evidence() {/,/^}/p' "${PROOF_SCRIPT}")"
grep -Fq 'notify_hash_after="not_collected"' <<<"${write_evidence_body}" ||
  fail "assisted evidence does not suppress selective notify collection"
grep -Fq 'desktopproof_refs="null"' <<<"${write_evidence_body}" ||
  fail "assisted evidence does not suppress DesktopProof content grep"
grep -Fq 'then "not_collected" else ($notify_hash_before == $notify_hash_after) end' <<<"${write_evidence_body}" ||
  fail "assisted evidence does not classify selective content as not collected"
grep -Fq 'global_config_desktopproof_reference_present: $desktopproof_refs' <<<"${write_evidence_body}" ||
  fail "assisted evidence does not encode selective DesktopProof content as null"

echo "Manual proof assisted opaque global guard tests passed"

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
jq '. + [{"role":"provider-tool","captured":true,"target_identity_verified":true,"visual_checks":{"tool_marker_visible":false,"tool_execution_visible":true,"raw_protocol_visible":false}}]' \
  "${usage_dir}/screenshots-complete.json" >"${usage_dir}/screenshots-tool-ocr-fluctuation.json"
test "$("${PROOF_SCRIPT}" --test-stage-checkpoint "${usage_dir}/complete.json" "${usage_dir}/screenshots-tool-ocr-fluctuation.json" provider-tool "${provider_model}" "${usage_dir}/tool-complete.json")" = "verified"
jq '.[-1].visual_checks.raw_protocol_visible = true' \
  "${usage_dir}/screenshots-tool-ocr-fluctuation.json" >"${usage_dir}/screenshots-tool-raw-protocol.json"
expect_failure "tool screenshot aggregation accepted a raw protocol frame" \
  "${PROOF_SCRIPT}" --test-stage-checkpoint "${usage_dir}/complete.json" "${usage_dir}/screenshots-tool-raw-protocol.json" provider-tool "${provider_model}" "${usage_dir}/tool-complete.json"
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

marker_ocr_fixture="${tmp_dir}/marker-ocr-fixture.png"
swift - "${marker_ocr_fixture}" <<'SWIFT'
import AppKit
import Foundation

let output = CommandLine.arguments[1]
let size = NSSize(width: 2000, height: 700)
let image = NSImage(size: size)
image.lockFocus()
NSColor.white.setFill()
NSRect(origin: .zero, size: size).fill()
let attributes: [NSAttributedString.Key: Any] = [
    .font: NSFont.monospacedSystemFont(ofSize: 18, weight: .regular),
    .foregroundColor: NSColor.black,
]
let lines = [
    "RELAYKIT_SB_20260718T152855Z_OFFICIAL_PLAIN_6C68D5BC378B",
    "RELAYKIT_SB_20260718T152855Z_0FFICIAL_PLAIN_6C68D5BC378B",
]
for (index, line) in lines.enumerated() {
    NSString(string: line).draw(at: NSPoint(x: 500, y: 500 - (index * 180)), withAttributes: attributes)
}
image.unlockFocus()
guard let tiff = image.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiff),
      let png = bitmap.representation(using: .png, properties: [:]) else {
    exit(2)
}
try png.write(to: URL(fileURLWithPath: output))
SWIFT
marker="RELAYKIT_SB_20260718T152855Z_OFFICIAL_PLAIN_6C68D5BC378B"
"${PROOF_SCRIPT}" --test-screenshot-analysis plain "${marker_ocr_fixture}" "${marker}" >"${tmp_dir}/marker-ocr-result.json"
jq -e '.response_marker_visible == true' "${tmp_dir}/marker-ocr-result.json" >/dev/null
expect_failure "two-character marker drift was accepted" \
  jq -e '.response_marker_visible == true' <(
    "${PROOF_SCRIPT}" --test-screenshot-analysis plain "${marker_ocr_fixture}" \
      "RELAYKIT_SB_20260718T152855Z_OFFICIAL_PLAIN_6C68D5BC37XX"
  )

echo "Manual proof bounded marker OCR tolerance test passed"

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

assisted_dir="${tmp_dir}/assisted-proof"
mkdir -m 700 "${assisted_dir}"
assisted_marker="RELAYKIT_OFFICIAL_TOOL_FIXTURE_20990718"
assisted_provider_model="public/provider-model"
for assisted_stage in official-plain official-markdown provider-plain provider-markdown provider-tool; do
  printf 'Reply with fixture marker for %s\n' "${assisted_stage}" >"${assisted_dir}/${assisted_stage}.txt"
  chmod 600 "${assisted_dir}/${assisted_stage}.txt"
done
expected_assisted_prompt="$(python3 - "${assisted_marker}" <<'PY'
import json
import sys

marker = sys.argv[1]
print("RELAYKIT_EXEC_COMMAND_V1 " + json.dumps({"cmd": f"echo '{marker}'; pwd"}, separators=(",", ":")))
PY
)"
printf '%s' "${expected_assisted_prompt}" >"${assisted_dir}/official-tool.txt"
chmod 600 "${assisted_dir}/official-tool.txt"
assisted_scenario="${assisted_dir}/scenario.json"
cat >"${assisted_scenario}" <<JSON
{"version":1,"stage_timeout_seconds":60,"stages":[
  {"id":"official-plain","model_id":"@current-official","model_label":"@current-official","query_file":"${assisted_dir}/official-plain.txt","response_marker":"RELAYKIT_OFFICIAL_PLAIN_FIXTURE","evidence_role":"official-plain","expect":"plain"},
  {"id":"official-markdown","model_id":"@current-official","model_label":"@current-official","query_file":"${assisted_dir}/official-markdown.txt","response_marker":"RELAYKIT_OFFICIAL_MARKDOWN_FIXTURE","evidence_role":"official-markdown","expect":"markdown"},
  {"id":"provider-plain","model_id":"${assisted_provider_model}","model_label":"Fixture Provider","query_file":"${assisted_dir}/provider-plain.txt","response_marker":"RELAYKIT_PROVIDER_PLAIN_FIXTURE","evidence_role":"provider-plain","expect":"plain"},
  {"id":"provider-markdown","model_id":"${assisted_provider_model}","model_label":"Fixture Provider","query_file":"${assisted_dir}/provider-markdown.txt","response_marker":"RELAYKIT_PROVIDER_MARKDOWN_FIXTURE","evidence_role":"provider-markdown","expect":"markdown"},
  {"id":"provider-tool","model_id":"${assisted_provider_model}","model_label":"Fixture Provider","query_file":"${assisted_dir}/provider-tool.txt","response_marker":"RELAYKIT_PROVIDER_TOOL_FIXTURE","evidence_role":"provider-tool","expect":"tool"},
  {"id":"official-tool","model_id":"@current-official","model_label":"@current-official","query_file":"${assisted_dir}/official-tool.txt","response_marker":"${assisted_marker}","evidence_role":"official-tool","expect":"tool"}
]}
JSON
chmod 600 "${assisted_scenario}"
"${PROOF_SCRIPT}" --test-assisted-scenario "${assisted_scenario}" >"${assisted_dir}/normalized.json"
jq -e '
  [.stages[].id] == ["official-plain","official-markdown","provider-plain","provider-markdown","provider-tool","official-tool"] and
  [.stages[].evidence_role] == ["official-plain","official-markdown","provider-plain","provider-markdown","provider-tool","official-tool"] and
  .stages[5].model_id == "@current-official" and .stages[5].expect == "tool"
' "${assisted_dir}/normalized.json" >/dev/null || fail "assisted scenario normalization lost the exact six-stage contract"
python3 - "${assisted_dir}/official-tool.txt" "${expected_assisted_prompt}" <<'PY'
from pathlib import Path
import sys

actual = Path(sys.argv[1]).read_bytes()
expected = sys.argv[2].encode("utf-8")
if actual != expected or b"\r" in actual or b"\n" in actual or b"\0" in actual:
    raise SystemExit("assisted official-tool fixture is not an exact single physical line")
PY
printf '%s\n' "${expected_assisted_prompt}" >"${assisted_dir}/official-tool-trailing-newline.txt"
jq --arg path "${assisted_dir}/official-tool-trailing-newline.txt" '.stages[5].query_file = $path' \
  "${assisted_scenario}" >"${assisted_dir}/scenario-trailing-newline.json"
expect_failure "assisted scenario accepted a terminal newline in the V1 tool query" \
  "${PROOF_SCRIPT}" --test-assisted-scenario "${assisted_dir}/scenario-trailing-newline.json"
test "$("${PROOF_SCRIPT}" --test-assisted-launch-deadline "${assisted_scenario}")" = "600" ||
  fail "assisted launcher deadline is not 5*stage_timeout + default 300"
test "$(RELAYKIT_ASSISTED_PREFLIGHT_ALLOWANCE_SECONDS=120 "${PROOF_SCRIPT}" --test-assisted-launch-deadline "${assisted_scenario}")" = "420" ||
  fail "assisted launcher deadline override is not 5*stage_timeout + override"
expect_failure "assisted launcher accepted a preflight allowance below 60" env \
  RELAYKIT_ASSISTED_PREFLIGHT_ALLOWANCE_SECONDS=59 \
  "${PROOF_SCRIPT}" --test-assisted-launch-deadline "${assisted_scenario}"
expect_failure "assisted launcher accepted a non-integer preflight allowance" env \
  RELAYKIT_ASSISTED_PREFLIGHT_ALLOWANCE_SECONDS=invalid \
  "${PROOF_SCRIPT}" --test-assisted-launch-deadline "${assisted_scenario}"
assisted_help="$(${PROOF_SCRIPT} --help 2>&1 || true)"
grep -Fq 'scenario-directory/assisted-state/state.json' <<<"${assisted_help}" ||
  fail "assisted help does not identify the state file inside its dedicated directory"
if grep -Fq '.assisted-state.json' <<<"${assisted_help}"; then
  fail "assisted help still advertises the removed single-file state path"
fi

jq '.stages[4:6] |= reverse' "${assisted_scenario}" >"${assisted_dir}/bad-order.json"
chmod 600 "${assisted_dir}/bad-order.json"
expect_failure "assisted scenario accepted official-tool outside the sixth position" \
  "${PROOF_SCRIPT}" --test-assisted-scenario "${assisted_dir}/bad-order.json"
jq '.stages[5].evidence_role = "provider-tool"' "${assisted_scenario}" >"${assisted_dir}/bad-role.json"
chmod 600 "${assisted_dir}/bad-role.json"
expect_failure "assisted scenario accepted a non-official-tool final evidence role" \
  "${PROOF_SCRIPT}" --test-assisted-scenario "${assisted_dir}/bad-role.json"
jq '.stages[2].model_id = "@current-official" | .stages[2].model_label = "@current-official"' \
  "${assisted_scenario}" >"${assisted_dir}/bad-provider.json"
chmod 600 "${assisted_dir}/bad-provider.json"
expect_failure "assisted scenario accepted a dynamic provider stage" \
  "${PROOF_SCRIPT}" --test-assisted-scenario "${assisted_dir}/bad-provider.json"

assisted_ledger="${assisted_dir}/first-five-ledger.json"
cat >"${assisted_ledger}" <<'JSON'
[
  {"id":"official-plain","evidence_role":"official-plain","state":"evidence_verified","submission_state":"submitted","submission_count":1,"rollout_binding":{"proof_found":true,"thread_id":"thread-1","user_marker_count":1,"assistant_marker_count":1}},
  {"id":"official-markdown","evidence_role":"official-markdown","state":"evidence_verified","submission_state":"submitted","submission_count":1,"rollout_binding":{"proof_found":true,"thread_id":"thread-2","user_marker_count":1,"assistant_marker_count":1}},
  {"id":"provider-plain","evidence_role":"provider-plain","state":"evidence_verified","submission_state":"submitted","submission_count":1,"rollout_binding":{"proof_found":true,"thread_id":"thread-3","user_marker_count":1,"assistant_marker_count":1}},
  {"id":"provider-markdown","evidence_role":"provider-markdown","state":"evidence_verified","submission_state":"submitted","submission_count":1,"rollout_binding":{"proof_found":true,"thread_id":"thread-4","user_marker_count":1,"assistant_marker_count":1}},
  {"id":"provider-tool","evidence_role":"provider-tool","state":"evidence_verified","submission_state":"submitted","submission_count":1,"rollout_binding":{"proof_found":true,"thread_id":"thread-5","user_marker_count":1,"assistant_marker_count":1}}
]
JSON
chmod 600 "${assisted_ledger}"
assisted_state_dir="${assisted_dir}/state"
"${PROOF_SCRIPT}" --test-assisted-create-state-dir "${assisted_state_dir}"
test -d "${assisted_state_dir}" && test ! -L "${assisted_state_dir}"
test "$(stat -f %Lp "${assisted_state_dir}")" = "700"
expect_failure "assisted state directory creation accepted a collision" \
  "${PROOF_SCRIPT}" --test-assisted-create-state-dir "${assisted_state_dir}"
unsafe_state_dir="${assisted_dir}/unsafe-state"
mkdir -m 755 "${unsafe_state_dir}"
expect_failure "assisted token creation accepted a non-0700 state directory" \
  "${PROOF_SCRIPT}" --test-assisted-create-token "${unsafe_state_dir}/state.json"
safe_link_target="${assisted_dir}/safe-link-target"
mkdir -m 700 "${safe_link_target}"
ln -s "${safe_link_target}" "${assisted_dir}/linked-state"
expect_failure "assisted token creation accepted a symlinked state directory" \
  "${PROOF_SCRIPT}" --test-assisted-create-token "${assisted_dir}/linked-state/state.json"
assisted_ledger_snapshot="${assisted_state_dir}/first-five.json"
"${PROOF_SCRIPT}" --test-assisted-snapshot "${assisted_ledger}" "${assisted_ledger_snapshot}"
cmp -s "${assisted_ledger}" "${assisted_ledger_snapshot}" || fail "assisted first-five ledger snapshot is not byte-identical"
test "$(stat -f %Lp "${assisted_ledger_snapshot}")" = "600"
assisted_ledger="${assisted_ledger_snapshot}"
assisted_artifact="${assisted_dir}/artifact.zip"
printf 'fixture artifact\n' >"${assisted_artifact}"
chmod 600 "${assisted_artifact}"
assisted_state="${assisted_state_dir}/state.json"
"${PROOF_SCRIPT}" --test-assisted-create-token "${assisted_state}"
assisted_token="${assisted_state_dir}/token"
test -f "${assisted_token}" && test ! -L "${assisted_token}"
test "$(stat -f %Lp "${assisted_token}")" = "600"
expect_failure "assisted token creation accepted a sidecar collision" \
  "${PROOF_SCRIPT}" --test-assisted-create-token "${assisted_state}"

assisted_scenario_sha="$(file_hash "${assisted_scenario}")"
assisted_artifact_sha="$(file_hash "${assisted_artifact}")"
assisted_ledger_sha="$(file_hash "${assisted_ledger}")"
assisted_token_sha="$(file_hash "${assisted_token}")"
assisted_query_sha="$(file_hash "${assisted_dir}/official-tool.txt")"
sleep 60 & assisted_supervisor_pid=$!
sleep 60 & assisted_desktop_pid=$!
sleep 60 & assisted_gateway_pid=$!
assisted_fixture_pids=("${assisted_supervisor_pid}" "${assisted_desktop_pid}" "${assisted_gateway_pid}")
assisted_supervisor_identity="$(/bin/ps -p "${assisted_supervisor_pid}" -o lstart= -o command= | /usr/bin/shasum -a 256 | awk '{print $1}')"
assisted_desktop_identity="$(/bin/ps -p "${assisted_desktop_pid}" -o lstart= -o command= | /usr/bin/shasum -a 256 | awk '{print $1}')"
assisted_gateway_identity="$(/bin/ps -p "${assisted_gateway_pid}" -o lstart= -o command= | /usr/bin/shasum -a 256 | awk '{print $1}')"
assisted_current="${assisted_state_dir}/current-bindings.json"
cat >"${assisted_current}" <<JSON
{"run_id":"assisted-fixture-run","scenario_sha256":"${assisted_scenario_sha}","artifact_sha256":"${assisted_artifact_sha}","harness_sha256":"harness-fixture","source_snapshot_sha256":"source-fixture","global_guard":"guard-fixture","stage_evidence_sha256":"${assisted_ledger_sha}","next_query_sha256":"${assisted_query_sha}","supervisor":{"pid":${assisted_supervisor_pid},"identity":"${assisted_supervisor_identity}","alive":true},"desktop":{"pid":${assisted_desktop_pid},"identity":"${assisted_desktop_identity}","window_id":303,"alive":true},"gateway":{"pid":${assisted_gateway_pid},"identity":"${assisted_gateway_identity}","host":"127.0.0.1","port":19777,"owns_port":true,"alive":true}}
JSON
chmod 600 "${assisted_current}"
assisted_unsigned="${assisted_state_dir}/unsigned-state.json"
assisted_prompt_json="$(printf '%s' "${expected_assisted_prompt}" | jq -Rs .)"
cat >"${assisted_unsigned}" <<JSON
{"version":1,"status":"awaiting_user_action","run_id":"assisted-fixture-run","scenario_path":"${assisted_scenario}","scenario_sha256":"${assisted_scenario_sha}","artifact_path":"${assisted_artifact}","artifact_sha256":"${assisted_artifact_sha}","harness_sha256":"harness-fixture","source_snapshot_sha256":"source-fixture","global_guard":"guard-fixture","stage_evidence_path":"${assisted_ledger}","stage_evidence_sha256":"${assisted_ledger_sha}","next_query_sha256":"${assisted_query_sha}","token_sha256":"${assisted_token_sha}","supervisor":{"pid":${assisted_supervisor_pid},"identity":"${assisted_supervisor_identity}"},"desktop":{"pid":${assisted_desktop_pid},"identity":"${assisted_desktop_identity}","window_id":303},"gateway":{"pid":${assisted_gateway_pid},"identity":"${assisted_gateway_identity}","host":"127.0.0.1","port":19777,"owns_port":true},"first_five_ledger":$(cat "${assisted_ledger}"),"next_stage":{"id":"official-tool","evidence_role":"official-tool","expect":"tool","model_id":"fixture/official","query_file":"${assisted_dir}/official-tool.txt","response_marker":"${assisted_marker}","usage_baseline":5,"since_epoch":4099680000},"pause_prompt":${assisted_prompt_json},"submission_count":5,"resume_used":false,"cleanup_done":false}
JSON
chmod 600 "${assisted_unsigned}"
"${PROOF_SCRIPT}" --test-assisted-sign-state "${assisted_unsigned}" "${assisted_state}"
test -f "${assisted_state}" && test ! -L "${assisted_state}"
test "$(stat -f %Lp "${assisted_state}")" = "600"
"${PROOF_SCRIPT}" --test-assisted-validate-state "${assisted_state}" "${assisted_current}"
cp "${assisted_state}" "${assisted_state_dir}/signed-state-backup.json"
jq '.run_id = "tampered-run"' "${assisted_state}" >"${assisted_state_dir}/tampered-state.json"
chmod 600 "${assisted_state_dir}/tampered-state.json"
mv "${assisted_state_dir}/tampered-state.json" "${assisted_state}"
expect_failure "assisted resume accepted a state with an invalid MAC" \
  "${PROOF_SCRIPT}" --test-assisted-validate-state "${assisted_state}" "${assisted_current}"
mv "${assisted_state_dir}/signed-state-backup.json" "${assisted_state}"
chmod 600 "${assisted_state}"

descriptor="$(${PROOF_SCRIPT} --test-assisted-descriptor "${assisted_state}")"
jq -e --argjson expected_desktop_pid "${assisted_desktop_pid}" --arg expected_prompt "${expected_assisted_prompt}" '
  keys == ["desktop_pid","desktop_window_id","gateway_endpoint","prompt","status"] and
  .status == "awaiting_user_action" and .desktop_pid == $expected_desktop_pid and .desktop_window_id == 303 and
  .gateway_endpoint == "http://127.0.0.1:19777/v1" and
  .prompt == $expected_prompt
' <<<"${descriptor}" >/dev/null || fail "assisted pause descriptor escaped its strict allowlist"

for assisted_mutation in \
  '.run_id = "stale-run"' \
  '.scenario_sha256 = "stale"' \
  '.artifact_sha256 = "stale"' \
  '.harness_sha256 = "stale"' \
  '.source_snapshot_sha256 = "stale"' \
  '.global_guard = "stale"' \
  '.stage_evidence_sha256 = "stale"' \
  '.next_query_sha256 = "stale"' \
  '.supervisor.alive = false' \
  '.desktop.alive = false' \
  '.gateway.alive = false' \
  '.supervisor.identity = "stale"' \
  '.desktop.identity = "stale"' \
  '.gateway.identity = "stale"' \
  '.desktop.window_id = 999' \
  '.gateway.port = 18787' \
  '.gateway.owns_port = false'; do
  assisted_bad_current="${assisted_state_dir}/bad-current-$(printf '%s' "${assisted_mutation}" | shasum -a 256 | cut -c1-12).json"
  jq "${assisted_mutation}" "${assisted_current}" >"${assisted_bad_current}"
  chmod 600 "${assisted_bad_current}"
  expect_failure "assisted resume accepted mismatched binding: ${assisted_mutation}" \
    "${PROOF_SCRIPT}" --test-assisted-validate-state "${assisted_state}" "${assisted_bad_current}"
done

jq '.desktop.window_id = 999' "${assisted_current}" >"${assisted_state_dir}/wrong-window.json"
chmod 600 "${assisted_state_dir}/wrong-window.json"
expect_failure "assisted resume accepted a different Desktop window" \
  "${PROOF_SCRIPT}" --test-assisted-validate-state "${assisted_state}" "${assisted_state_dir}/wrong-window.json"
chmod 640 "${assisted_state}"
expect_failure "assisted resume accepted a non-0600 state file" \
  "${PROOF_SCRIPT}" --test-assisted-validate-state "${assisted_state}" "${assisted_current}"
chmod 600 "${assisted_state}"
ln -s "${assisted_state}" "${assisted_state_dir}/state-link.json"
expect_failure "assisted resume accepted a symlinked state file" \
  "${PROOF_SCRIPT}" --test-assisted-validate-state "${assisted_state_dir}/state-link.json" "${assisted_current}"

assisted_signal_output="$("${PROOF_SCRIPT}" --test-assisted-signal-state "${assisted_state}" "${assisted_current}")"
test -z "${assisted_signal_output}" || fail "assisted resume printed token or private state"
for fixture_pid in "${assisted_fixture_pids[@]}"; do
  kill -0 "${fixture_pid}" 2>/dev/null || fail "assisted pause/resume cleaned up a parked fixture process"
done
assisted_sentinel="${assisted_state_dir}/resume"
test -f "${assisted_sentinel}" && test ! -L "${assisted_sentinel}"
test "$(stat -f %Lp "${assisted_sentinel}")" = "600"
test "$(file_hash "${assisted_sentinel}")" != "$(file_hash "${assisted_token}")" ||
  fail "assisted sentinel copied the separate resume token"
"${PROOF_SCRIPT}" --test-assisted-sentinel "${assisted_state}"
expect_failure "assisted resume accepted a reused sentinel" \
  "${PROOF_SCRIPT}" --test-assisted-signal-state "${assisted_state}" "${assisted_current}"

"${PROOF_SCRIPT}" --test-assisted-mark-state "${assisted_state}" observing true false
"${PROOF_SCRIPT}" --test-assisted-continuous-binding "${assisted_state}" "${assisted_current}"
jq '.next_query_sha256 = "drifted"' "${assisted_current}" >"${assisted_state_dir}/drifted-query-current.json"
chmod 600 "${assisted_state_dir}/drifted-query-current.json"
expect_typed_failure "assisted_sixth_query_binding_changed" \
  "assisted observing accepted a changed sixth query" \
  "${PROOF_SCRIPT}" --test-assisted-continuous-binding "${assisted_state}" "${assisted_state_dir}/drifted-query-current.json"
jq '.gateway.identity = "drifted"' "${assisted_current}" >"${assisted_state_dir}/drifted-gateway-current.json"
chmod 600 "${assisted_state_dir}/drifted-gateway-current.json"
expect_typed_failure "assisted_gateway_binding_changed" \
  "assisted observing accepted a changed gateway identity" \
  "${PROOF_SCRIPT}" --test-assisted-continuous-binding "${assisted_state}" "${assisted_state_dir}/drifted-gateway-current.json"
drift_cleanup_counter="${assisted_state_dir}/drift-cleanup-count"
expect_typed_failure "assisted_gateway_binding_changed" \
  "assisted gateway drift did not fail typed after exactly one cleanup" \
  "${PROOF_SCRIPT}" --test-assisted-binding-drift-cleanup "${assisted_state}" "${assisted_state_dir}/drifted-gateway-current.json" "${drift_cleanup_counter}"
test "$(cat "${drift_cleanup_counter}")" = "1" || fail "assisted binding drift cleanup ran more than once"
binding_poll_counter="${assisted_state_dir}/binding-poll-cleanup-count"
test "$("${PROOF_SCRIPT}" --test-assisted-binding-poll success "${binding_poll_counter}")" = \
  "attempts=2 verifications=3" || fail "assisted stage-six binding poll did not guard every iteration and pre-accept"
expect_typed_failure "assisted_gateway_binding_changed" \
  "assisted stage-six binding poll drift was not typed and cleaned exactly once" \
  "${PROOF_SCRIPT}" --test-assisted-binding-poll drift "${binding_poll_counter}"
test "$(cat "${binding_poll_counter}")" = "1" || fail "assisted binding-poll drift cleanup did not run exactly once"
assisted_final_stages="${assisted_state_dir}/all-six-stages.json"
assisted_final_session="2099/07/10/rollout-official-tool.jsonl"
assisted_final_session_sha="$(printf '%s' "${assisted_final_session}" | shasum -a 256 | awk '{print $1}')"
jq --arg run_id "assisted-fixture-run" --arg session_file "${assisted_final_session}" --arg session_sha "${assisted_final_session_sha}" '. + [{
  "id":"official-tool","model_id":"fixture/official","evidence_role":"official-tool","expect":"tool",
  "state":"evidence_verified","submission_state":"submitted","submission_count":1,"usage_baseline":5,
  "run_id":$run_id,
  "rollout_binding":{"proof_found":true,"candidate_count":1,"thread_id":"thread-6","model":"fixture/official","user_marker_count":1,"assistant_marker_count":1,"session_file":$session_file,"session_binding_sha256":$session_sha}
}]' "${assisted_ledger}" >"${assisted_final_stages}"
chmod 600 "${assisted_final_stages}"
assisted_usage="${assisted_state_dir}/usage.json"
jq -n '[range(0;5) | {model:"prior",status:"completed",http_status:200}] + [{model:"fixture/official",status:"completed",http_status:200}]' >"${assisted_usage}"
chmod 600 "${assisted_usage}"
assisted_tool="${assisted_state_dir}/tool.json"
cat >"${assisted_tool}" <<JSON
{"proof_found":true,"function_call_found":true,"function_call_output_found":true,"process_exited_zero":true,"matched_provider_tool_count":1,"matched_call_ids":["call-official"],"assisted_same_call_verified":true,"exact_shell_command_found":true,"marker_output_found":true,"pwd_output_found":true,"xml_leak_found":false,"raw_function_calls_found":false,"since_epoch":4099680000,"exact_session_binding_verified":true,"session_binding_sha256":"${assisted_final_session_sha}"}
JSON
chmod 600 "${assisted_tool}"
assisted_screenshots="${assisted_state_dir}/screenshots.json"
cat >"${assisted_screenshots}" <<'JSON'
[
  {"role":"official-tool","captured":true,"target_identity_verified":true,"visual_checks":{"tool_marker_visible":false,"tool_execution_visible":false,"raw_protocol_visible":false}},
  {"role":"official-tool","captured":true,"target_identity_verified":true,"visual_checks":{"tool_marker_visible":true,"tool_execution_visible":true,"raw_protocol_visible":false}}
]
JSON
chmod 600 "${assisted_screenshots}"
"${PROOF_SCRIPT}" --test-assisted-complete "${assisted_state}" "${assisted_current}" "${assisted_final_stages}" "${assisted_usage}" "${assisted_tool}" "${assisted_screenshots}"
jq '.since_epoch = 4099679999' "${assisted_tool}" >"${assisted_state_dir}/stale-tool.json"
chmod 600 "${assisted_state_dir}/stale-tool.json"
expect_failure "assisted completion accepted stale official-tool evidence" \
  "${PROOF_SCRIPT}" --test-assisted-complete "${assisted_state}" "${assisted_current}" "${assisted_final_stages}" "${assisted_usage}" "${assisted_state_dir}/stale-tool.json" "${assisted_screenshots}"
jq '.assisted_same_call_verified = false | .matched_call_ids = ["call-marker","call-pwd"]' "${assisted_tool}" >"${assisted_state_dir}/split-call-tool.json"
chmod 600 "${assisted_state_dir}/split-call-tool.json"
expect_failure "assisted completion accepted split-call official-tool evidence" \
  "${PROOF_SCRIPT}" --test-assisted-complete "${assisted_state}" "${assisted_current}" "${assisted_final_stages}" "${assisted_usage}" "${assisted_state_dir}/split-call-tool.json" "${assisted_screenshots}"
jq '.session_binding_sha256 = "stale-session-binding"' "${assisted_tool}" >"${assisted_state_dir}/stale-session-tool.json"
chmod 600 "${assisted_state_dir}/stale-session-tool.json"
expect_failure "assisted completion accepted a changed official-tool session binding" \
  "${PROOF_SCRIPT}" --test-assisted-complete "${assisted_state}" "${assisted_current}" "${assisted_final_stages}" "${assisted_usage}" "${assisted_state_dir}/stale-session-tool.json" "${assisted_screenshots}"
jq '.[0].visual_checks.raw_protocol_visible = true' "${assisted_screenshots}" >"${assisted_state_dir}/dirty-screenshots.json"
chmod 600 "${assisted_state_dir}/dirty-screenshots.json"
expect_failure "assisted completion accepted a dirty earlier official-tool screenshot" \
  "${PROOF_SCRIPT}" --test-assisted-complete "${assisted_state}" "${assisted_current}" "${assisted_final_stages}" "${assisted_usage}" "${assisted_tool}" "${assisted_state_dir}/dirty-screenshots.json"
jq '.[5].rollout_binding.thread_id = "thread-5"' "${assisted_final_stages}" >"${assisted_state_dir}/replayed-stage.json"
chmod 600 "${assisted_state_dir}/replayed-stage.json"
expect_failure "assisted completion replayed a first-five rollout for stage six" \
  "${PROOF_SCRIPT}" --test-assisted-complete "${assisted_state}" "${assisted_current}" "${assisted_state_dir}/replayed-stage.json" "${assisted_usage}" "${assisted_tool}" "${assisted_screenshots}"

cleanup_counter="${assisted_state_dir}/cleanup-count"
"${PROOF_SCRIPT}" --test-assisted-cleanup-once "${cleanup_counter}"
test "$(cat "${cleanup_counter}")" = "1" || fail "assisted terminal cleanup did not run exactly once"

resume_body="$(sed -n '/^resume_auto_assisted() {/,/^}/p' "${PROOF_SCRIPT}")"
if grep -Eq 'setup_preflight|launch_desktop|run_automated_proof|AX_DRIVER_BINARY.*submit' <<<"${resume_body}"; then
  fail "assisted resume must only validate state and create its single sentinel"
fi
grep -Fq 'run-auto-assisted)' "${PROOF_SCRIPT}" || fail "assisted launcher command is missing"
grep -Fq 'resume-auto-assisted)' "${PROOF_SCRIPT}" || fail "assisted resume command is missing"
grep -Fq -- '--assisted-supervisor)' "${PROOF_SCRIPT}" || fail "assisted background supervisor command is missing"
grep -Fq 'assisted_six_stage)' "${PROOF_SCRIPT}" || fail "assisted final profile branch is missing"
test "$("${PROOF_SCRIPT}" --test-automated-profile "${assisted_dir}/normalized.json" "${assisted_provider_model}")" = "assisted_six_stage"
if grep -Eq '^assisted_canonical_route_status\(\)|--test-assisted-canonical-status\)' "${PROOF_SCRIPT}"; then
  fail "assisted canonical status still has a disconnected helper or test hook"
fi
write_evidence_body="$(sed -n '/^write_evidence() {/,/^}/p' "${PROOF_SCRIPT}")"
test "$(rg -c 'automated_first_five_manual_official_tool_complete' <<<"${write_evidence_body}")" -eq 1 ||
  fail "production write_evidence must contain exactly one assisted canonical classification"
grep -Fq '$human_intervention_count == 1 and $automated_profile == "assisted_six_stage" then "automated_first_five_manual_official_tool_complete"' \
  <<<"${write_evidence_body}" || fail "production write_evidence does not bind the assisted canonical classification"
grep -Fq '"${AUTOMATED_PROFILE}" == "assisted_six_stage" && "${ASSISTED_MODE}" != "true"' "${PROOF_SCRIPT}" ||
  fail "ordinary run-auto no longer preserves six-stage custom-scenario compatibility"
launcher_body="$(sed -n '/^launch_auto_assisted() {/,/^}/p' "${PROOF_SCRIPT}")"
if grep -Fq 'cleanup_processes' <<<"${launcher_body}"; then
  fail "assisted launcher cleaned up the parked supervisor runtime"
fi
grep -Fq 'launch_assisted_supervisor_process' <<<"${launcher_body}" ||
  fail "assisted launcher does not use secure supervisor stdio creation"
supervisor_launch_body="$(sed -n '/^launch_assisted_supervisor_process() {/,/^}/p' "${PROOF_SCRIPT}")"
grep -Fq '/dev/null' <<<"${supervisor_launch_body}" || fail "assisted supervisor still depends on caller stdin"
grep -Fq 'supervisor.out' <<<"${supervisor_launch_body}" || fail "assisted supervisor stdout is not securely redirected"
grep -Fq 'supervisor.err' <<<"${supervisor_launch_body}" || fail "assisted supervisor stderr is not securely redirected"
if grep -Eq 'current\.\$\$|unsigned\.\$\$|supervisor\.(out|err).*>' "${PROOF_SCRIPT}"; then
  fail "assisted lifecycle still uses predictable sidecar shell redirection"
fi

integration_scenario="${assisted_dir}/integration-scenario.json"
cp "${assisted_scenario}" "${integration_scenario}"
chmod 600 "${integration_scenario}"
integration_descriptor="$(${PROOF_SCRIPT} --test-assisted-launch-fixture "${integration_scenario}")"
integration_state_dir="${integration_scenario}.assisted-state"
integration_state="${integration_state_dir}/state.json"
integration_current="${integration_state_dir}/current.json"
jq -e '.status == "awaiting_user_action" and .gateway_endpoint == "http://127.0.0.1:19777/v1"' \
  <<<"${integration_descriptor}" >/dev/null || fail "fake assisted launcher did not return at pause"
test "$(stat -f %Lp "${integration_state_dir}")" = "700"
integration_supervisor_pid="$(jq -er '.supervisor.pid' "${integration_state}")"
integration_desktop_pid="$(jq -er '.desktop.pid' "${integration_state}")"
integration_gateway_pid="$(jq -er '.gateway.pid' "${integration_state}")"
assisted_fixture_pids+=("${integration_supervisor_pid}" "${integration_desktop_pid}" "${integration_gateway_pid}")
for fixture_pid in "${integration_supervisor_pid}" "${integration_desktop_pid}" "${integration_gateway_pid}"; do
  kill -0 "${fixture_pid}" 2>/dev/null || fail "fake assisted process was not live at pause"
done
test ! -e "${integration_state_dir}/cleanup-count" || test "$(cat "${integration_state_dir}/cleanup-count")" = "0"
jq -e '.first_five_submissions == 5 and .official_tool_ax_submissions == 0' \
  "${integration_state_dir}/actions.json" >/dev/null || fail "fake assisted pause did not run first five exactly once"
for sidecar in "${integration_state_dir}"/*; do
  test ! -L "${sidecar}" || fail "fake assisted state contains a symlink sidecar"
  test "$(stat -f %u "${sidecar}")" = "$(id -u)" || fail "fake assisted sidecar owner drifted"
  test "$(stat -f %Lp "${sidecar}")" = "600" || fail "fake assisted sidecar is not 0600"
done
jq '.gateway.identity = "invalid-resume"' "${integration_current}" >"${integration_state_dir}/invalid-current.json"
chmod 600 "${integration_state_dir}/invalid-current.json"
expect_typed_failure "assisted_gateway_binding_changed" \
  "fake assisted launcher accepted an invalid resume" \
  "${PROOF_SCRIPT}" --test-assisted-resume-fixture "${integration_state}" "${integration_state_dir}/invalid-current.json"
jq -e '.status == "awaiting_user_action" and .resume_used == false' "${integration_state}" >/dev/null
kill -0 "${integration_supervisor_pid}" 2>/dev/null || fail "invalid resume killed the parked fake supervisor"
"${PROOF_SCRIPT}" --test-assisted-resume-fixture "${integration_state}" "${integration_current}"
for _ in {1..100}; do
  [[ "$(jq -r '.status' "${integration_state}" 2>/dev/null || true)" == "complete" ]] && break
  sleep 0.05
done
jq -e '.status == "complete" and .resume_used == true and .cleanup_done == true' "${integration_state}" >/dev/null ||
  fail "valid fake resume did not complete in the same state"
jq -e '.first_five_submissions == 5 and .official_tool_ax_submissions == 0 and .official_tool_observations == 1' \
  "${integration_state_dir}/actions.json" >/dev/null || fail "fake supervisor submitted stage six instead of observing it"
test "$(cat "${integration_state_dir}/cleanup-count")" = "1" || fail "fake assisted terminal cleanup did not run exactly once"
for fixture_pid in "${integration_supervisor_pid}" "${integration_desktop_pid}" "${integration_gateway_pid}"; do
  for _ in {1..40}; do
    ! kill -0 "${fixture_pid}" 2>/dev/null && break
    sleep 0.05
  done
  ! kill -0 "${fixture_pid}" 2>/dev/null || fail "fake assisted terminal process remained live"
done
for fixture_pid in "${assisted_fixture_pids[@]}"; do
  kill "${fixture_pid}" 2>/dev/null || true
  wait "${fixture_pid}" 2>/dev/null || true
done
assisted_fixture_pids=()

echo "Manual proof resumable assisted lifecycle fixtures passed"

config_home="${tmp_dir}/isolated-config-home"
mkdir -p "${config_home}"
HOME="${config_home}" "${PROOF_SCRIPT}" --test-write-codex-config 19999
isolated_config="${config_home}/Library/Application Support/RelayKit/DesktopProof/official-proof/codex-home/config.toml"
grep -Fx 'model = "gpt-5.5"' "${isolated_config}" >/dev/null
grep -Fx 'sandbox_mode = "read-only"' "${isolated_config}" >/dev/null
grep -Fx 'openai_base_url = "http://127.0.0.1:19999/v1"' "${isolated_config}" >/dev/null

rc1_config_home="${tmp_dir}/isolated-rc1-config-home"
mkdir -p "${rc1_config_home}"
HOME="${rc1_config_home}" "${PROOF_SCRIPT}" --test-write-codex-config 19998 rc1_native_responses
rc1_config="${rc1_config_home}/Library/Application Support/RelayKit/DesktopProof/official-proof/codex-home/config.toml"
grep -Fx 'sandbox_mode = "danger-full-access"' "${rc1_config}" >/dev/null ||
  fail "RC1 tool proof did not disable only the conflicting inner Codex sandbox"

real_route_config_home="${tmp_dir}/isolated-real-route-config-home"
mkdir -p "${real_route_config_home}"
HOME="${real_route_config_home}" "${PROOF_SCRIPT}" --test-write-codex-config 19997 real_isolated_route
real_route_config="${real_route_config_home}/Library/Application Support/RelayKit/DesktopProof/official-proof/codex-home/config.toml"
grep -Fx 'sandbox_mode = "danger-full-access"' "${real_route_config}" >/dev/null ||
  fail "externally sandboxed real route proof retained a conflicting inner Codex sandbox"

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
scenario_validation_body="$(sed -n '/^validate_auto_scenario() {/,/^}/p' "${PROOF_SCRIPT}")"
if grep -Eq 'query_path\.read_text|open\(query_path|cat .*query_file|jq .*query_file' <<<"${scenario_validation_body}"; then
  fail "automated scenario metadata preflight must not read query content"
fi
postbinding_validation_body="$(sed -n '/^validate_postbinding_query_content() {/,/^}/p' "${PROOF_SCRIPT}")"
grep -Fq 'query_path.read_text()' <<<"${postbinding_validation_body}" ||
  fail "automated query content must be validated only by the postbinding validator"
"${PROOF_SCRIPT}" --test-postbinding-query-content "${query_file}" RELAYKIT_AUTO_TEST plain

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
  "official": [
    {"model":"hidden/model","displayName":"Hidden Model","hidden":true},
    {"model":"gpt-5.6-luna","displayName":"GPT-5.6-Luna"},
    {"model":"gpt-5.5","displayName":"GPT-5.5"}
  ],
  "provider": [{"model":"public/model","displayName":"Current Provider Label"}]
}
JSON
test "$("${PROOF_SCRIPT}" --test-resolve-automated-model-label "${scenario_dir}/app-server-labels.json" gpt-5.6-luna)" = "GPT-5.6-Luna"
test "$("${PROOF_SCRIPT}" --test-resolve-automated-model-label "${scenario_dir}/app-server-labels.json" public/model)" = "Current Provider Label"
expect_failure "automated proof accepted a scenario label for a model absent from current app-server data" \
  "${PROOF_SCRIPT}" --test-resolve-automated-model-label "${scenario_dir}/app-server-labels.json" missing/model

dynamic_scenario="${scenario_dir}/dynamic-scenario.json"
jq '.stages = [
  (.stages[0] | .id = "dynamic-one" | .evidence_role = "dynamic-one" | .model_id = "@current-official" | .model_label = "@current-official"),
  (.stages[0] | .id = "dynamic-two" | .evidence_role = "dynamic-two" | .model_id = "@current-official" | .model_label = "@current-official")
]' "${scenario_file}" >"${dynamic_scenario}"
chmod 600 "${dynamic_scenario}"
"${PROOF_SCRIPT}" --test-auto-scenario "${dynamic_scenario}" >"${scenario_dir}/dynamic-normalized.json"
"${PROOF_SCRIPT}" --test-resolve-automated-scenario-models \
  "${scenario_dir}/dynamic-normalized.json" "${scenario_dir}/app-server-labels.json" >"${scenario_dir}/dynamic-resolved.json"
jq -e '
  [.stages[] | [.model_id, .model_label]] == [
    ["gpt-5.6-luna", "GPT-5.6-Luna"],
    ["gpt-5.6-luna", "GPT-5.6-Luna"]
  ]
' "${scenario_dir}/dynamic-resolved.json" >/dev/null ||
  fail "dynamic Official stages did not resolve once to the first visible catalog pair"

fixed_normalized="${scenario_dir}/fixed-normalized.json"
"${PROOF_SCRIPT}" --test-auto-scenario "${scenario_file}" >"${fixed_normalized}"
"${PROOF_SCRIPT}" --test-resolve-automated-scenario-models \
  "${fixed_normalized}" "${scenario_dir}/app-server-labels.json" >"${scenario_dir}/fixed-resolved.json"
jq -e '.stages[0].model_id == "public/model" and .stages[0].model_label == "Current Provider Label"' \
  "${scenario_dir}/fixed-resolved.json" >/dev/null || fail "fixed model fixtures lost current-label compatibility"

half_dynamic="${scenario_dir}/half-dynamic.json"
jq '.stages[0].model_id = "@current-official"' "${scenario_file}" >"${half_dynamic}"
chmod 600 "${half_dynamic}"
expect_failure "automated scenario accepted only one dynamic model sentinel" \
  "${PROOF_SCRIPT}" --test-auto-scenario "${half_dynamic}"

cat >"${scenario_dir}/official-empty.json" <<'JSON'
{"official":[{"model":"hidden/model","displayName":"Hidden Model","hidden":true}],"provider":[]}
JSON
expect_typed_failure current_official_catalog_empty "dynamic Official accepted an empty visible catalog" \
  "${PROOF_SCRIPT}" --test-resolve-automated-scenario-models "${scenario_dir}/dynamic-normalized.json" "${scenario_dir}/official-empty.json"

cat >"${scenario_dir}/official-duplicate.json" <<'JSON'
{"official":[{"model":"gpt-public","displayName":"GPT Public"},{"model":"gpt-public","displayName":"GPT Public Duplicate"}],"provider":[]}
JSON
expect_typed_failure current_official_model_duplicate "dynamic Official accepted a duplicate model id" \
  "${PROOF_SCRIPT}" --test-resolve-automated-scenario-models "${scenario_dir}/dynamic-normalized.json" "${scenario_dir}/official-duplicate.json"

cat >"${scenario_dir}/official-invalid.json" <<'JSON'
{"official":[{"model":"","displayName":"Invalid Official"}],"provider":[]}
JSON
expect_typed_failure current_official_catalog_invalid "dynamic Official accepted invalid catalog fields" \
  "${PROOF_SCRIPT}" --test-resolve-automated-scenario-models "${scenario_dir}/dynamic-normalized.json" "${scenario_dir}/official-invalid.json"

echo "Manual proof dynamic Official resolution fixtures passed"

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
"${PROOF_SCRIPT}" --test-auto-scenario "${scenario_dir}/missing-marker.json" >/dev/null
expect_failure "postbinding validation accepted a query that omitted response_marker" \
  "${PROOF_SCRIPT}" --test-postbinding-query-content "${missing_marker_query}" RELAYKIT_AUTO_TEST plain

non_utf8_query="${scenario_dir}/non-utf8-query.txt"
printf '\377\376\375\n' >"${non_utf8_query}"
chmod 600 "${non_utf8_query}"
jq --arg query_file "${non_utf8_query}" '.stages[0].query_file = $query_file' "${scenario_file}" >"${scenario_dir}/non-utf8-scenario.json"
chmod 600 "${scenario_dir}/non-utf8-scenario.json"
"${PROOF_SCRIPT}" --test-auto-scenario "${scenario_dir}/non-utf8-scenario.json" >/dev/null
expect_failure "postbinding validation accepted non-UTF-8 query content" \
  "${PROOF_SCRIPT}" --test-postbinding-query-content "${non_utf8_query}" RELAYKIT_AUTO_TEST plain

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
JSONL
"${PROOF_SCRIPT}" --test-auto-rollout-binding "${binding_home}" 0 "public/model" "RELAYKIT_AUTO_BIND" "${scenario_dir}/binding.json"
binding_session_file="2099/07/11/rollout-auto.jsonl"
binding_session_sha="$(printf '%s' "${binding_session_file}" | shasum -a 256 | awk '{print $1}')"
jq -e --arg session_file "${binding_session_file}" --arg session_sha "${binding_session_sha}" '
  .proof_found == true and .thread_id == "thread-auto" and .model == "public/model" and
  .user_marker_found == true and .assistant_marker_found == false and .assistant_marker_count == 0 and
  .session_file == $session_file and .session_binding_sha256 == $session_sha
' "${scenario_dir}/binding.json" >/dev/null || fail "rollout binding did not record its redacted exact-session hash"
"${PROOF_SCRIPT}" --test-submitted-model-selection "${scenario_dir}/binding.json" "public/model"
expect_failure "submitted picker mismatch passed the typed selection comparison" \
  "${PROOF_SCRIPT}" --test-submitted-model-selection "${scenario_dir}/binding.json" "other/model"

zero_binding_home="${scenario_dir}/zero-binding-home"
mkdir -p "${zero_binding_home}/sessions"
expect_failure "zero rollout candidates satisfied submitted binding" \
  "${PROOF_SCRIPT}" --test-auto-rollout-binding "${zero_binding_home}" 0 "public/model" "RELAYKIT_AUTO_BIND" "${scenario_dir}/zero-binding.json"
jq -e '.proof_found == false and .candidate_count == 0 and .binding_status == "rollout_not_found"' "${scenario_dir}/zero-binding.json" >/dev/null

multiple_binding_home="${scenario_dir}/multiple-binding-home"
for thread in one two; do
  thread_dir="${multiple_binding_home}/sessions/2099/07/${thread}"
  mkdir -p "${thread_dir}"
  cat >"${thread_dir}/rollout-${thread}.jsonl" <<JSONL
{"timestamp":"2099-07-11T00:00:00Z","type":"session_meta","payload":{"id":"thread-${thread}"}}
{"timestamp":"2099-07-11T00:00:01Z","type":"turn_context","payload":{"model":"public/model"}}
{"timestamp":"2099-07-11T00:00:02Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Reply with RELAYKIT_AUTO_BIND"}]}}
JSONL
done
expect_failure "multiple rollout candidates satisfied submitted binding" \
  "${PROOF_SCRIPT}" --test-auto-rollout-binding "${multiple_binding_home}" 0 "public/model" "RELAYKIT_AUTO_BIND" "${scenario_dir}/multiple-binding.json"
jq -e '.proof_found == false and .candidate_count == 2 and .binding_status == "rollout_not_unique"' "${scenario_dir}/multiple-binding.json" >/dev/null

cat >>"${binding_sessions}/rollout-auto.jsonl" <<'JSONL'
{"timestamp":"2099-07-11T00:00:03Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"RELAYKIT_AUTO_BIND"}]}}
JSONL
"${PROOF_SCRIPT}" --test-auto-rollout-binding "${binding_home}" 0 "public/model" "RELAYKIT_AUTO_BIND" "${scenario_dir}/binding-with-assistant.json"
jq -e '.proof_found == true and .assistant_marker_found == true and .assistant_marker_count == 1' "${scenario_dir}/binding-with-assistant.json" >/dev/null

cat >"${scenario_dir}/matching-submitted-usage.json" <<'JSON'
[
  {"request_id":"old","model":"public/model","status":"completed","http_status":200},
  {"request_id":"new","model":"public/model","status":"completed","http_status":200}
]
JSON
"${PROOF_SCRIPT}" --test-submitted-model-usage "${scenario_dir}/matching-submitted-usage.json" 1 "${scenario_dir}/binding.json" >"${scenario_dir}/matching-submitted-event.json"
jq -e '.model == "public/model" and .event_count == 1' "${scenario_dir}/matching-submitted-event.json" >/dev/null

cat >"${scenario_dir}/mixed-order-submitted-usage.json" <<'JSON'
[
  {"request_id":"old","model":"public/model","status":"completed","http_status":200},
  {"request_id":"unrelated","provider_id":"openai","model":"other/official-model","status":"completed","http_status":200},
  {"request_id":"expected","model":"public/model","status":"completed","http_status":200}
]
JSON
"${PROOF_SCRIPT}" --test-submitted-model-usage "${scenario_dir}/mixed-order-submitted-usage.json" 1 "${scenario_dir}/binding.json" >"${scenario_dir}/mixed-order-submitted-event.json"
jq -e '.model == "public/model" and .event_count == 1 and .status == "completed" and .http_status == 200' "${scenario_dir}/mixed-order-submitted-event.json" >/dev/null

cat >"${scenario_dir}/mismatching-submitted-usage.json" <<'JSON'
[
  {"request_id":"old","model":"public/model","status":"completed","http_status":200},
  {"request_id":"new","model":"other/model","status":"completed","http_status":200}
]
JSON
expect_failure "usage model mismatch passed the bound rollout comparison" \
  "${PROOF_SCRIPT}" --test-submitted-model-usage "${scenario_dir}/mismatching-submitted-usage.json" 1 "${scenario_dir}/binding.json"
test "$("${PROOF_SCRIPT}" --test-submitted-model-usage-wait "${scenario_dir}/mismatching-submitted-usage.json" 1 "${scenario_dir}/binding.json" before-deadline)" = "pending"
expect_typed_failure "submitted_model_usage_mismatch" "nonmatching completed usage did not map to the exact deadline failure" \
  "${PROOF_SCRIPT}" --test-submitted-model-usage-wait "${scenario_dir}/mismatching-submitted-usage.json" 1 "${scenario_dir}/binding.json" deadline

cat >>"${binding_sessions}/rollout-auto.jsonl" <<'JSONL'
{"timestamp":"2099-07-11T00:00:04Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Reply with RELAYKIT_AUTO_BIND"}]}}
{"timestamp":"2099-07-11T00:00:05Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"RELAYKIT_AUTO_BIND"}]}}
JSONL
expect_failure "duplicate marker messages satisfied a single automated rollout binding" \
  "${PROOF_SCRIPT}" --test-auto-rollout-binding "${binding_home}" 0 "public/model" "RELAYKIT_AUTO_BIND" "${scenario_dir}/duplicate-binding.json"

echo "Manual proof pre-assistant rollout and submitted-model fixtures passed"

cat >"${scenario_dir}/standard-profile.json" <<'JSON'
{"stages":[
  {"model_id":"gpt-5.5","evidence_role":"gpt55-response","expect":"plain"},
  {"model_id":"gpt-5.6-luna","evidence_role":"gpt56-response","expect":"plain"},
  {"model_id":"public/provider-model","evidence_role":"provider-markdown","expect":"markdown"},
  {"model_id":"public/provider-model","evidence_role":"provider-tool","expect":"tool"}
]}
JSON
test "$("${PROOF_SCRIPT}" --test-automated-profile "${scenario_dir}/standard-profile.json" "public/provider-model")" = "standard_four_stage_dogfood"
cat >"${scenario_dir}/custom-tool-profile.json" <<'JSON'
{"stages":[{"model_id":"public/provider-model","evidence_role":"one-tool","expect":"tool"}]}
JSON
test "$("${PROOF_SCRIPT}" --test-automated-profile "${scenario_dir}/custom-tool-profile.json" "public/provider-model")" = "single_tool_scenario"
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

cat >"${scenario_dir}/custom-tool-stage.json" <<'JSON'
[
  {"id":"one","evidence_role":"one-tool","expect":"tool","state":"evidence_verified","submission_state":"submitted","rollout_binding":{"proof_found":true,"thread_id":"thread-one","user_marker_count":1,"assistant_marker_count":1}}
]
JSON
cat >"${scenario_dir}/custom-tool-screenshot.json" <<'JSON'
[
  {"role":"one-tool","captured":true,"target_identity_verified":true,"visual_checks":{"tool_marker_visible":true,"tool_execution_visible":true,"raw_protocol_visible":false}}
]
JSON
"${PROOF_SCRIPT}" --test-custom-tool-scenario-complete \
  "${scenario_dir}/custom-tool-stage.json" 1 "${usage_dir}/tool-complete.json" "${scenario_dir}/custom-tool-screenshot.json"
expect_failure "custom tool completion accepted a non-one-stage profile" \
  "${PROOF_SCRIPT}" --test-custom-tool-scenario-complete \
  "${scenario_dir}/custom-tool-stage.json" 2 "${usage_dir}/tool-complete.json" "${scenario_dir}/custom-tool-screenshot.json"
expect_failure "custom tool completion accepted raw protocol" \
  "${PROOF_SCRIPT}" --test-custom-tool-scenario-complete \
  "${scenario_dir}/custom-tool-stage.json" 1 "${usage_dir}/tool-xml-leak.json" "${scenario_dir}/custom-tool-screenshot.json"

auto_body="$(sed -n '/^run_automated_proof() {/,/^}/p' "${PROOF_SCRIPT}")"
auto_wait_body="$(sed -n '/^wait_for_automated_stage() {/,/^}/p' "${PROOF_SCRIPT}")"
automated_checkpoint_body="$(sed -n '/^automated_stage_checkpoint_verified() {/,/^}/p' "${PROOF_SCRIPT}")"
submitted_binding_body="$(sed -n '/^wait_for_submitted_rollout_binding() {/,/^}/p' "${PROOF_SCRIPT}")"
if grep -Eq 'wait_for_user_continue|read -r _|continue_file' <<<"${auto_body}"; then
  fail "automated proof must never wait for user input"
fi
grep -Fq 'refresh_automated_stage_evidence' <<<"${auto_wait_body}" ||
  fail "automated proof must refresh stage evidence before verification"
grep -Fq 'any($shots[]; .visual_checks.tool_marker_visible == true and .visual_checks.tool_execution_visible == true)' <<<"${automated_checkpoint_body}" ||
  fail "automated tool proof must tolerate later OCR misses after one exact process-bound tool frame"
grep -Fq 'all($shots[]; .visual_checks.raw_protocol_visible != true)' <<<"${automated_checkpoint_body}" ||
  fail "automated tool proof must reject raw protocol in every captured frame"
grep -Fq '"${AX_DRIVER_BINARY}" reveal' <<<"${auto_wait_body}" ||
  fail "Markdown proof must reveal an exact off-screen heading through AX"
grep -Fq 'submission_state="submitted"' <<<"${auto_body}" ||
  fail "automated proof must record the point after which it cannot safely resend"
setup_line="$(grep -n 'setup_preflight real' <<<"${auto_body}" | cut -d: -f1 | head -1)"
bound_desktop_line="$(grep -n 'verify_desktop_window_identity' <<<"${auto_body}" | cut -d: -f1 | head -1)"
postbinding_validation_line="$(grep -n 'validate_postbinding_query_content' <<<"${auto_body}" | cut -d: -f1 | head -1)"
query_copy_line="$(grep -n 'copy_bound_query' <<<"${auto_body}" | cut -d: -f1 | head -1)"
[[ -n "${setup_line}" && -n "${bound_desktop_line}" && -n "${postbinding_validation_line}" && -n "${query_copy_line}" &&
   "${setup_line}" -lt "${bound_desktop_line}" && "${bound_desktop_line}" -lt "${postbinding_validation_line}" &&
   "${postbinding_validation_line}" -lt "${query_copy_line}" ]] ||
  fail "query content validation must occur after exact Desktop binding and before the bound copy"
query_copy_body="$(sed -n '/^copy_bound_query() {/,/^}/p' "${PROOF_SCRIPT}")"
grep -Fq 'source_hash_before' <<<"${query_copy_body}" || fail "bound query copy must hash its source before copying"
grep -Fq 'source_hash_after' <<<"${query_copy_body}" || fail "bound query copy must rehash its source after copying"
grep -Fq 'copy_hash' <<<"${query_copy_body}" || fail "bound query copy must hash the staged copy"
if grep -Eq 'query_text|query_content|cat ' <<<"${query_copy_body}"; then
  fail "bound query copy must never move query content through argv, environment, logs, or evidence"
fi
grep -Fq 'case "${AUTOMATED_PROFILE}" in' <<<"${auto_body}" ||
  fail "automated profile handling must fail closed"
grep -Fq 'single_tool_scenario)' <<<"${auto_body}" ||
  fail "single provider tool scenarios need a distinct completion profile"
grep -Fq 'custom_tool_scenario_complete' <<<"${auto_body}" ||
  fail "single provider tool completion must recheck existing tool and screenshot evidence"
grep -Fq 'codex-desktop-ax-driver.swift' <<<"${auto_body}" ||
  fail "automated proof must invoke the deterministic AX driver"
test "$(rg -c '"\$\{AX_DRIVER_BINARY\}" submit' <<<"${auto_body}")" -eq 1 ||
  fail "the automated state machine must contain exactly one submit call site"
test "$(rg -c '"\$\{AX_DRIVER_BINARY\}" select-model' <<<"${auto_body}")" -eq 1 ||
  fail "the assisted state machine must contain exactly one pre-pause model-selection call site"
if grep -Fq '"${AX_DRIVER_BINARY}" submit' <<<"${auto_wait_body}${submitted_binding_body}"; then
  fail "submitted observation paths must never resend or reopen the picker"
fi
if grep -Fq '"${AX_DRIVER_BINARY}" select-model' <<<"${auto_wait_body}${submitted_binding_body}"; then
  fail "submitted observation paths must never change the selected model"
fi
test "$(rg -c 'verify_assisted_live_bindings' <<<"${submitted_binding_body}")" -eq 2 ||
  fail "stage-six rollout binding must guard every poll and the acceptance edge"
if grep -Fq 'SECONDS + timeout_seconds' <<<"${submitted_binding_body}${auto_wait_body}"; then
  fail "binding and observation must not create independent stage deadlines"
fi
test "$(rg -c 'stage_deadline=\$\(\(SECONDS \+ stage_timeout\)\)' <<<"${auto_body}")" -eq 1 ||
  fail "each stage must create exactly one absolute deadline"
grep -Fq '"${stage_deadline}" "${evidence_role}"' <<<"${auto_body}" ||
  fail "rollout binding must receive the stage absolute deadline and role"
grep -Fq '"${stage_deadline}" || wait_status=$?' <<<"${auto_body}" ||
  fail "stage observation must receive the same absolute deadline"
grep -Fq '7) :' <<<"${auto_body}" ||
  fail "stage-six binding drift must preserve its typed assisted failure"
submit_line="$(grep -n '"${AX_DRIVER_BINARY}" submit' <<<"${auto_body}" | cut -d: -f1)"
submitted_binding_line="$(grep -n 'wait_for_submitted_rollout_binding' <<<"${auto_body}" | cut -d: -f1)"
assistant_render_wait_line="$(grep -n 'wait_for_automated_stage' <<<"${auto_body}" | cut -d: -f1)"
[[ -n "${submit_line}" && -n "${submitted_binding_line}" && -n "${assistant_render_wait_line}" &&
   "${submit_line}" -lt "${submitted_binding_line}" && "${submitted_binding_line}" -lt "${assistant_render_wait_line}" ]] ||
  fail "the unique user-marker rollout must bind after one submit and before assistant/render waiting"
grep -Fq 'AUTO_ERROR_CODE="submitted_model_selection_mismatch"' <<<"${auto_body}" ||
  fail "picker selection mismatch must retain its typed failure"
grep -Fq 'AUTO_ERROR_CODE="submitted_model_usage_mismatch"' <<<"${auto_body}" ||
  fail "completed usage mismatch must retain its typed failure"
grep -Fq 'resolve_automated_scenario_models "${AUTOMATED_SCENARIO_NORMALIZED}" "${OUT}/app-server.json"' <<<"${auto_body}" ||
  fail "scenario models must resolve once from the current-run app-server catalog before submit"
if grep -Fq 'resolve_automated_model_label "${OUT}/app-server.json"' <<<"${auto_body}"; then
  fail "dynamic Official stages must not independently re-resolve inside the submit loop"
fi
catalog_labels_line="$(grep -n 'write_automated_catalog_labels' <<<"${auto_body}" | cut -d: -f1 | head -1)"
desktop_launch_line="$(grep -n 'launch_desktop' <<<"${auto_body}" | cut -d: -f1 | head -1)"
[[ -n "${catalog_labels_line}" && -n "${desktop_launch_line}" && "${catalog_labels_line}" -lt "${desktop_launch_line}" ]] ||
  fail "automated catalog labels must exist before Desktop readiness is evaluated"
ready_body="$(sed -n '/^wait_for_desktop_ui_ready() {/,/^}/p' "${PROOF_SCRIPT}")"
grep -Fq '"${AX_DRIVER_BINARY}" ready' <<<"${ready_body}" ||
  fail "automated Desktop readiness must require the exact catalog picker and composer"
nux_body="$(sed -n '/^dismiss_known_model_nux() {/,/^}/p' "${PROOF_SCRIPT}")"
grep -Fq '"${AX_DRIVER_BINARY}" dismiss-model-nux' <<<"${nux_body}" ||
  fail "manual proof must use the bounded AX model NUX command"
grep -Fq '.candidate_count <= 1 and .action_count <= 1' <<<"${nux_body}" ||
  fail "model NUX handling must allow at most one exact action"
prepare_call_line="$(grep -n '"${AX_DRIVER_BINARY}" prepare' <<<"${auto_body}" | cut -d: -f1)"
select_model_call_line="$(grep -n '"${AX_DRIVER_BINARY}" select-model' <<<"${auto_body}" | cut -d: -f1)"
assisted_pause_line="$(grep -n 'write_assisted_pause_state' <<<"${auto_body}" | cut -d: -f1)"
submit_call_line="$(grep -n '"${AX_DRIVER_BINARY}" submit' <<<"${auto_body}" | cut -d: -f1)"
activation_lines="$(grep -n 'activate_isolated_desktop' <<<"${auto_body}" | cut -d: -f1)"
activation_before_prepare="$(awk -v target="${prepare_call_line}" '$1 < target {last=$1} END {print last}' <<<"${activation_lines}")"
activation_before_select_model="$(awk -v lower="${prepare_call_line}" -v upper="${select_model_call_line}" '$1 > lower && $1 < upper {last=$1} END {print last}' <<<"${activation_lines}")"
activation_before_submit="$(awk -v lower="${prepare_call_line}" -v upper="${submit_call_line}" '$1 > lower && $1 < upper {last=$1} END {print last}' <<<"${activation_lines}")"
[[ -n "${activation_before_prepare}" && -n "${activation_before_select_model}" && -n "${activation_before_submit}" ]] ||
  fail "the harness must reactivate the bound Desktop PID immediately before prepare, select-model, and submit"
[[ -n "${select_model_call_line}" && -n "${assisted_pause_line}" && "${prepare_call_line}" -lt "${select_model_call_line}" && "${select_model_call_line}" -lt "${assisted_pause_line}" ]] ||
  fail "assisted stage six must prepare a fresh task and preselect its official model before pausing"
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

custom_tool_codex_home="${tmp_dir}/custom-tool-codex-home"
custom_tool_rollout_dir="${custom_tool_codex_home}/sessions/2099/07/10"
custom_tool_output="${tmp_dir}/custom-tool-evidence.json"
mkdir -p "${custom_tool_rollout_dir}"
cat >"${custom_tool_rollout_dir}/rollout-current.jsonl" <<JSONL
{"timestamp":"2099-07-10T00:00:00Z","type":"turn_context","payload":{"model":"gpt-fixture-official"}}
{"timestamp":"2099-07-10T00:00:01Z","type":"response_item","payload":{"type":"custom_tool_call","status":"completed","name":"exec","call_id":"call-custom","input":"const result = await tools.exec_command({cmd:\"echo '${tool_marker}'; pwd\"}); text(result.output);"}}
{"timestamp":"2099-07-10T00:00:02Z","type":"response_item","payload":{"type":"custom_tool_call_output","call_id":"call-custom","output":[{"type":"input_text","text":"Script completed\nWall time 0.1 seconds\nOutput:\n"},{"type":"input_text","text":"${tool_marker}\n/tmp/relaykit-fixture\n"}]}}
JSONL
"${PROOF_SCRIPT}" --test-tool-evidence "${custom_tool_codex_home}" "${custom_tool_output}" 0 gpt-fixture-official "${tool_marker}"
jq -e '
  .proof_found == true and .function_call_found == true and .function_call_output_found == true and
  .assisted_same_call_verified == true and .matched_call_ids == ["call-custom"] and
  .exact_shell_command_found == true and .marker_output_found == true and .pwd_output_found == true and
  .process_exited_zero == true and .raw_function_calls_found == false and
  ([.events[] | select(.type == "custom_tool_call_output") | .process_exited_zero] == [true])
' "${custom_tool_output}" >/dev/null || fail "custom exec rollout evidence was not recognized"

failed_custom_tool_codex_home="${tmp_dir}/failed-custom-tool-codex-home"
failed_custom_tool_rollout_dir="${failed_custom_tool_codex_home}/sessions/2099/07/10"
failed_custom_tool_output="${tmp_dir}/failed-custom-tool-evidence.json"
mkdir -p "${failed_custom_tool_rollout_dir}"
cat >"${failed_custom_tool_rollout_dir}/rollout-current.jsonl" <<JSONL
{"timestamp":"2099-07-10T00:00:00Z","type":"turn_context","payload":{"model":"gpt-fixture-official"}}
{"timestamp":"2099-07-10T00:00:01Z","type":"response_item","payload":{"type":"custom_tool_call","status":"completed","name":"exec","call_id":"call-custom-failed","input":"const result = await tools.exec_command({cmd:\"echo '${tool_marker}'; pwd\"}); text(result.output);"}}
{"timestamp":"2099-07-10T00:00:02Z","type":"response_item","payload":{"type":"custom_tool_call_output","call_id":"call-custom-failed","output":[{"type":"input_text","text":"Script failed with exit code 71\nOutput:\n${tool_marker}\n/tmp/relaykit-fixture\n"}]}}
JSONL
"${PROOF_SCRIPT}" --test-tool-evidence "${failed_custom_tool_codex_home}" "${failed_custom_tool_output}" 0 gpt-fixture-official "${tool_marker}"
jq -e '
  .proof_found == false and .assisted_same_call_verified == false and
  .process_exited_zero == false and .matched_provider_tool_count == 0
' "${failed_custom_tool_output}" >/dev/null || fail "failed custom exec rollout was accepted"

ambiguous_custom_tool_codex_home="${tmp_dir}/ambiguous-custom-tool-codex-home"
ambiguous_custom_tool_rollout_dir="${ambiguous_custom_tool_codex_home}/sessions/2099/07/10"
ambiguous_custom_tool_output="${tmp_dir}/ambiguous-custom-tool-evidence.json"
mkdir -p "${ambiguous_custom_tool_rollout_dir}"
cat >"${ambiguous_custom_tool_rollout_dir}/rollout-current.jsonl" <<JSONL
{"timestamp":"2099-07-10T00:00:00Z","type":"turn_context","payload":{"model":"gpt-fixture-official"}}
{"timestamp":"2099-07-10T00:00:01Z","type":"response_item","payload":{"type":"custom_tool_call","name":"exec","call_id":"call-missing-status","input":"const result = await tools.exec_command({cmd:\"echo '${tool_marker}'; pwd\"}); text(result.output);"}}
{"timestamp":"2099-07-10T00:00:02Z","type":"response_item","payload":{"type":"custom_tool_call_output","call_id":"call-missing-status","output":[{"type":"input_text","text":"Script completed\nProcess exited with code 0\n${tool_marker}\n/tmp/relaykit-fixture\n"}]}}
{"timestamp":"2099-07-10T00:00:03Z","type":"response_item","payload":{"type":"custom_tool_call","status":"failed","name":"exec","call_id":"call-failed-status","input":"const result = await tools.exec_command({cmd:\"echo '${tool_marker}'; pwd\"}); text(result.output);"}}
{"timestamp":"2099-07-10T00:00:04Z","type":"response_item","payload":{"type":"custom_tool_call_output","call_id":"call-failed-status","output":[{"type":"input_text","text":"Script completed\nProcess exited with code 0\n${tool_marker}\n/tmp/relaykit-fixture\n"}]}}
{"timestamp":"2099-07-10T00:00:05Z","type":"response_item","payload":{"type":"custom_tool_call","status":"completed","name":"exec","call_id":"call-duplicate","input":"const result = await tools.exec_command({cmd:\"echo '${tool_marker}'; pwd\"}); text(result.output);"}}
{"timestamp":"2099-07-10T00:00:06Z","type":"response_item","payload":{"type":"custom_tool_call","status":"completed","name":"exec","call_id":"call-duplicate","input":"const result = await tools.exec_command({cmd:\"echo '${tool_marker}'; pwd\"}); text(result.output);"}}
{"timestamp":"2099-07-10T00:00:07Z","type":"response_item","payload":{"type":"custom_tool_call_output","call_id":"call-duplicate","output":[{"type":"input_text","text":"Script completed\n${tool_marker}\n/tmp/relaykit-fixture\n"}]}}
{"timestamp":"2099-07-10T00:00:08Z","type":"response_item","payload":{"type":"custom_tool_call_output","call_id":"call-reordered","output":[{"type":"input_text","text":"Script completed\n${tool_marker}\n/tmp/relaykit-fixture\n"}]}}
{"timestamp":"2099-07-10T00:00:09Z","type":"response_item","payload":{"type":"custom_tool_call","status":"completed","name":"exec","call_id":"call-reordered","input":"const result = await tools.exec_command({cmd:\"echo '${tool_marker}'; pwd\"}); text(result.output);"}}
JSONL
"${PROOF_SCRIPT}" --test-tool-evidence "${ambiguous_custom_tool_codex_home}" "${ambiguous_custom_tool_output}" 0 gpt-fixture-official "${tool_marker}"
jq -e '
  .proof_found == false and .assisted_same_call_verified == false and
  .process_exited_zero == false and .matched_provider_tool_count == 0 and .matched_call_ids == []
' "${ambiguous_custom_tool_output}" >/dev/null || fail "ambiguous custom exec rollout was accepted"

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
assisted_tool_codex_home="${tmp_dir}/assisted-tool-codex-home"
assisted_tool_rollout_dir="${assisted_tool_codex_home}/sessions/2099/07/10"
assisted_tool_output="${tmp_dir}/assisted-tool-evidence.json"
mkdir -p "${assisted_tool_rollout_dir}"
cat >"${assisted_tool_rollout_dir}/rollout-current.jsonl" <<JSONL
{"timestamp":"2099-07-10T00:00:00Z","type":"turn_context","payload":{"model":"gpt-fixture-official"}}
{"timestamp":"2099-07-10T00:00:01Z","type":"response_item","payload":{"type":"function_call","name":"exec_command","call_id":"call-exact","arguments":"{\"cmd\":\"echo '${tool_marker}'; pwd\"}"}}
{"timestamp":"2099-07-10T00:00:02Z","type":"response_item","payload":{"type":"function_call_output","call_id":"call-exact","output":"Process exited with code 0\nFinal output:\n${tool_marker}\n/tmp/relaykit-fixture\n"}}
JSONL
assisted_tool_session="2099/07/10/rollout-current.jsonl"
assisted_tool_session_sha="$(printf '%s' "${assisted_tool_session}" | shasum -a 256 | awk '{print $1}')"
"${PROOF_SCRIPT}" --test-tool-evidence "${assisted_tool_codex_home}" "${assisted_tool_output}" 0 gpt-fixture-official "${tool_marker}" \
  "${assisted_tool_session}" "${assisted_tool_session_sha}"
jq -e '
  .assisted_same_call_verified == true and .matched_call_ids == ["call-exact"] and
  .exact_shell_command_found == true and .marker_output_found == true and .pwd_output_found == true and
  .exact_session_binding_verified == true and (.session_binding_sha256 | length) == 64 and
  (.session_file? | not)
' "${assisted_tool_output}" >/dev/null || fail "assisted exact tool evidence did not bind command/output/pwd to one call_id"

aggregate_tool_codex_home="${tmp_dir}/aggregate-tool-codex-home"
aggregate_tool_rollout_dir="${aggregate_tool_codex_home}/sessions/2099/07/10"
aggregate_tool_output="${tmp_dir}/aggregate-tool-evidence.json"
mkdir -p "${aggregate_tool_rollout_dir}"
cat >"${aggregate_tool_rollout_dir}/rollout-command.jsonl" <<JSONL
{"timestamp":"2099-07-10T00:00:00Z","type":"turn_context","payload":{"model":"gpt-fixture-official"}}
{"timestamp":"2099-07-10T00:00:01Z","type":"response_item","payload":{"type":"function_call","name":"exec_command","call_id":"call-aggregate","arguments":"{\"cmd\":\"echo '${tool_marker}'; pwd\"}"}}
JSONL
cat >"${aggregate_tool_rollout_dir}/rollout-output.jsonl" <<JSONL
{"timestamp":"2099-07-10T00:00:00Z","type":"turn_context","payload":{"model":"gpt-fixture-official"}}
{"timestamp":"2099-07-10T00:00:02Z","type":"response_item","payload":{"type":"function_call_output","call_id":"call-aggregate","output":"Process exited with code 0\nFinal output:\n${tool_marker}\n/tmp/relaykit-fixture\n"}}
JSONL
aggregate_tool_session="2099/07/10/rollout-command.jsonl"
aggregate_tool_session_sha="$(printf '%s' "${aggregate_tool_session}" | shasum -a 256 | awk '{print $1}')"
"${PROOF_SCRIPT}" --test-tool-evidence "${aggregate_tool_codex_home}" "${aggregate_tool_output}" 0 gpt-fixture-official "${tool_marker}" \
  "${aggregate_tool_session}" "${aggregate_tool_session_sha}"
jq -e --arg expected "${aggregate_tool_session_sha}" '
  .proof_found == false and .assisted_same_call_verified == false and .matched_call_ids == [] and
  .exact_session_binding_verified == true and .session_binding_sha256 == $expected
' "${aggregate_tool_output}" >/dev/null ||
  fail "assisted tool evidence aggregated command/output across sibling rollouts"

split_tool_codex_home="${tmp_dir}/split-tool-codex-home"
split_tool_rollout_dir="${split_tool_codex_home}/sessions/2099/07/10"
split_tool_output="${tmp_dir}/split-tool-evidence.json"
mkdir -p "${split_tool_rollout_dir}"
cat >"${split_tool_rollout_dir}/rollout-current.jsonl" <<JSONL
{"timestamp":"2099-07-10T00:00:00Z","type":"turn_context","payload":{"model":"gpt-fixture-official"}}
{"timestamp":"2099-07-10T00:00:01Z","type":"response_item","payload":{"type":"function_call","name":"exec_command","call_id":"call-command","arguments":"{\"cmd\":\"echo '${tool_marker}'; pwd\"}"}}
{"timestamp":"2099-07-10T00:00:02Z","type":"response_item","payload":{"type":"function_call_output","call_id":"call-command","output":"Process exited with code 0\nFinal output:\n${tool_marker}\n"}}
{"timestamp":"2099-07-10T00:00:03Z","type":"response_item","payload":{"type":"function_call","name":"exec_command","call_id":"call-pwd","arguments":"{\"cmd\":\"pwd\"}"}}
{"timestamp":"2099-07-10T00:00:04Z","type":"response_item","payload":{"type":"function_call_output","call_id":"call-pwd","output":"Process exited with code 0\nFinal output:\n${tool_marker}\n/tmp/relaykit-fixture\n"}}
JSONL
"${PROOF_SCRIPT}" --test-tool-evidence "${split_tool_codex_home}" "${split_tool_output}" 0 gpt-fixture-official "${tool_marker}"
jq -e '
  .exact_shell_command_found == true and .pwd_output_found == true and
  .assisted_same_call_verified == false and .matched_call_ids == []
' "${split_tool_output}" >/dev/null || fail "assisted split-call fixture was not rejected"
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

app_server_dir="${tmp_dir}/app-server-lineage"
mkdir -p "${app_server_dir}"
app_server_output="${app_server_dir}/app-server.json"
app_server_provider_config="${app_server_dir}/providers.json"
fake_codex_cli="${app_server_dir}/codex"
lineage_artifact_sha="$(printf 'c%.0s' {1..64})"
jq -n '{providers:[{models:[{id:"public/provider-model"}]}]}' >"${app_server_provider_config}"
cat >"${fake_codex_cli}" <<'CODEX'
#!/usr/bin/env bash
set -euo pipefail
[[ "${1:-}" == "app-server" && "${2:-}" == "--listen" && "${3:-}" == "stdio://" ]]
while IFS= read -r request; do
  case "$(jq -r '.id // empty' <<<"${request}")" in
    2) jq -nc '{id:2,result:{config:{model:"gpt-5.5",model_provider:"openai"}}}' ;;
    3)
      jq -nc '{id:3,result:{data:[
        {model:"gpt-5.5",displayName:"GPT-5.5",hidden:false},
        {model:"public/provider-model",displayName:"Public Provider Model",hidden:false}
      ]}}'
      exit 0
      ;;
  esac
done
CODEX
chmod 700 "${fake_codex_cli}"
"${PROOF_SCRIPT}" --test-write-app-server-evidence \
  "${app_server_output}" "${app_server_provider_config}" "${fake_codex_cli}" \
  current-setup current-session "${lineage_artifact_sha}"
jq -e --arg artifact_sha256 "${lineage_artifact_sha}" '
  .relaykit_lineage == {setup_id:"current-setup",session_id:"current-session",artifact_sha256:$artifact_sha256} and
  .config == {model:"gpt-5.5",model_provider:"openai"} and
  ([.official[].model] == ["gpt-5.5"]) and
  ([.provider[].model] == ["public/provider-model"])
' "${app_server_output}" >/dev/null || fail "production app-server evidence path omitted current setup/session/artifact lineage"

echo "Manual proof app-server lineage producer test passed"

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

rc1_auth_real_home="${tmp_dir}/rc1-auth-user"
rc1_auth_home="${rc1_auth_real_home}/Library/Application Support/RelayKit/DesktopProof/official-proof/codex-home"
mkdir -p "${rc1_auth_home}" "${rc1_auth_real_home}/.codex"
printf '{"auth":"isolated-test-fixture"}\n' >"${rc1_auth_home}/auth.json"
chmod 600 "${rc1_auth_home}/auth.json"
HOME="${rc1_auth_real_home}" "${PROOF_SCRIPT}" --test-rc1-isolated-auth-home "${rc1_auth_home}" >/dev/null

rc1_status_cli="${tmp_dir}/rc1-status-cli"
cat >"${rc1_status_cli}" <<'SH'
#!/usr/bin/env bash
test "${1:-}" = "login" && test "${2:-}" = "status" || exit 2
printf '%s\n' 'Logged in using ChatGPT' >&2
SH
chmod 700 "${rc1_status_cli}"
HOME="${rc1_auth_real_home}" "${PROOF_SCRIPT}" --test-rc1-auth-status "${rc1_auth_home}" "${rc1_status_cli}"

rc1_noisy_status_cli="${tmp_dir}/rc1-noisy-status-cli"
cat >"${rc1_noisy_status_cli}" <<'SH'
#!/usr/bin/env bash
printf '%s\n' 'warning' 'Logged in using ChatGPT' >&2
SH
chmod 700 "${rc1_noisy_status_cli}"
if HOME="${rc1_auth_real_home}" "${PROOF_SCRIPT}" --test-rc1-auth-status "${rc1_auth_home}" "${rc1_noisy_status_cli}"; then
  fail "RC1 isolated auth status accepted non-exact output"
fi

rc1_mutating_status_cli="${tmp_dir}/rc1-mutating-status-cli"
cat >"${rc1_mutating_status_cli}" <<'SH'
#!/usr/bin/env bash
printf '\n' >>"${CODEX_HOME}/auth.json"
printf '%s\n' 'Logged in using ChatGPT' >&2
SH
chmod 700 "${rc1_mutating_status_cli}"
if HOME="${rc1_auth_real_home}" "${PROOF_SCRIPT}" --test-rc1-auth-status "${rc1_auth_home}" "${rc1_mutating_status_cli}"; then
  fail "RC1 isolated auth status accepted an auth mutation"
fi
printf '{"auth":"isolated-test-fixture"}\n' >"${rc1_auth_home}/auth.json"
chmod 600 "${rc1_auth_home}/auth.json"

printf '{"auth":"global-test-fixture"}\n' >"${rc1_auth_real_home}/.codex/auth.json"
chmod 600 "${rc1_auth_real_home}/.codex/auth.json"
if HOME="${rc1_auth_real_home}" "${PROOF_SCRIPT}" --test-rc1-isolated-auth-home "${rc1_auth_real_home}/.codex" >/dev/null 2>&1; then
  fail "RC1 isolated auth validation accepted the global Codex home"
fi

rc1_symlink_auth_home="${rc1_auth_real_home}/Library/Application Support/RelayKit/OfficialProof/codex-home"
mkdir -p "${rc1_symlink_auth_home}"
ln -s "${rc1_auth_home}/auth.json" "${rc1_symlink_auth_home}/auth.json"
if HOME="${rc1_auth_real_home}" "${PROOF_SCRIPT}" --test-rc1-isolated-auth-home "${rc1_symlink_auth_home}" >/dev/null 2>&1; then
  fail "RC1 isolated auth validation accepted a symlinked auth source"
fi

chmod 640 "${rc1_auth_home}/auth.json"
if HOME="${rc1_auth_real_home}" "${PROOF_SCRIPT}" --test-rc1-isolated-auth-home "${rc1_auth_home}" >/dev/null 2>&1; then
  fail "RC1 isolated auth validation accepted non-private auth permissions"
fi
chmod 600 "${rc1_auth_home}/auth.json"

rc1_fresh_codex_home="${tmp_dir}/rc1-fresh-codex-home"
source_auth_hash_before="$(/usr/bin/shasum -a 256 "${rc1_auth_home}/auth.json" | awk '{print $1}')"
HOME="${rc1_auth_real_home}" "${PROOF_SCRIPT}" --test-rc1-auth-link-lifecycle "${rc1_auth_home}" "${rc1_fresh_codex_home}"
test ! -e "${rc1_fresh_codex_home}/auth.json"
test ! -L "${rc1_fresh_codex_home}/auth.json"
test "$(/usr/bin/shasum -a 256 "${rc1_auth_home}/auth.json" | awk '{print $1}')" = "${source_auth_hash_before}"

echo "Manual proof isolated RC1 auth link tests passed"

grep -Fq 'rc1_native_responses_three_stage' "${PROOF_SCRIPT}" ||
  fail "manual proof must expose the dedicated RC1 native Responses profile"
grep -Fq 'rc1-native-responses-three-stage)' "${PROOF_SCRIPT}" ||
  fail "manual proof must expose a dedicated RC1 native Responses command"
grep -Fq 'desktop_websocket_to_gateway' "${PROOF_SCRIPT}" ||
  fail "RC1 evidence must require Desktop WebSocket ingress"
grep -Fq 'gateway_sse_to_fixture' "${PROOF_SCRIPT}" ||
  fail "RC1 evidence must require Gateway SSE egress"
grep -Fq 'tool_roundtrip_verified' "${PROOF_SCRIPT}" ||
  fail "RC1 evidence must require function_call_output roundtrip"
grep -Fq 'submission_count' "${PROOF_SCRIPT}" ||
  fail "RC1 stages must prove exactly one submission each"
grep -Fq 'failed_events' "${PROOF_SCRIPT}" ||
  fail "RC1 evidence must preserve failed events instead of relabeling them"
	grep -Fq 'predicate_ledger' "${PROOF_SCRIPT}" ||
	  fail "RC1 evidence must expose a named predicate ledger"
	grep -Fq 'manual_status:"route_complete"' "${PROOF_SCRIPT}" ||
	  fail "RC1 evidence must require a successful manual status"
	grep -Fq 'route_proof_status:"complete"' "${PROOF_SCRIPT}" ||
	  fail "RC1 evidence must require a complete route proof"
	grep -Fq 'harness_exit_code:0' "${PROOF_SCRIPT}" ||
	  fail "RC1 evidence must require a zero harness exit"

rc1_contract="$(${PROOF_SCRIPT} --print-rc1-native-responses-contract)"
jq -e '
  .profile == "rc1_native_responses_three_stage" and
  .stage_ids == ["A", "B", "C"] and
  .submission_count_each == 1 and
  .stage_A == "text_marker" and
  .stage_B == "native_markdown_structure" and
  .stage_C == "exact_shell_marker_plus_pwd" and
  .desktop_websocket_to_gateway == true and
  .gateway_sse_to_fixture == true and
  .tool_roundtrip == true and
  .attaches_existing_app_gateway == true
' <<<"${rc1_contract}" >/dev/null || fail "RC1 three-stage contract is invalid"
