#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${ROOT}/scripts/local-beta-dogfood-smoke.sh"
APP_SOURCE="${ROOT}/app/Sources/RelayKitApp/App/RelayKitApp.swift"
APP_VIEW_SOURCE="${ROOT}/app/Sources/RelayKitApp/Views/ContentView.swift"
APP_MODEL_SOURCE="${ROOT}/app/Sources/RelayKitApp/Stores/AppModel.swift"
GATEWAY_PROCESS_SOURCE="${ROOT}/app/Sources/RelayKitApp/Services/GatewayProcess.swift"

fail() {
  echo "local beta dogfood smoke test failed: $*" >&2
  exit 1
}

file_signature() {
  stat -f '%Sp|%u|%g|%z|%m' "$1"
  shasum -a 256 "$1" | awk '{print $1}'
}

bash -n "${SCRIPT}"
grep -Fq 'umask 077' "${SCRIPT}" ||
  fail "dogfood screenshots and temporary state must be owner-only"
grep -Fq 'rm -f "${SCREENSHOT_DIR}"/*.raw.png "${SCREENSHOT_DIR}"/*.composited.png' "${SCRIPT}" ||
  fail "dogfood cleanup must remove uncropped screen frames on every exit path"

termination_body="$(sed -n '/func applicationWillTerminate/,/^    }/p' "${APP_SOURCE}")"
grep -Fq 'model.stopGateway()' <<<"${termination_body}" ||
  fail "App termination must stop the bundled gateway"
grep -Fq 'model.stopOfficialAuthProcessForShutdown()' <<<"${termination_body}" ||
  fail "App termination must preserve official-auth shutdown"

grep -Fq '/usr/bin/open -n "${APP_BUNDLE}"' "${SCRIPT}" ||
  fail "normal extracted app launch must use LaunchServices"
grep -Fq 'RelayKit status item did not become available after normal app launch' "${SCRIPT}" ||
  fail "normal launch must wait for the exact status item before clicking"
grep -Fq 'RELAYKIT_DOGFOOD_REUSE_CURRENT_ZIP' "${SCRIPT}" ||
  fail "dogfood must support reusing the exact zip already bound to route evidence"
grep -Fq 'RELAYKIT_DOGFOOD_REUSE_CURRENT_ZIP must be 0 or 1' "${SCRIPT}" ||
  fail "dogfood zip reuse must reject unsupported values"
grep -Fq '/usr/bin/ditto -x -k "${ZIP_PATH}" "${INSTALL_DIR}"' "${SCRIPT}" ||
  fail "signed app extraction must preserve macOS metadata without AppleDouble files"
if grep -Fq '/usr/bin/unzip' "${SCRIPT}"; then
  fail "signed app extraction must not materialize AppleDouble files inside the bundle"
fi
grep -Fq 'test -x "${BUNDLED_RELAY}" || fail "extracted bundled gateway is missing"' "${SCRIPT}" ||
  fail "dogfood must require the bundled gateway executable"
if grep -Fq '"${APP_REAL}" --verify-bundled-gateway' "${SCRIPT}"; then
  fail "signed dogfood must verify the gateway through the normal App lifecycle"
fi
grep -Fq 'bundled_gateway_verify: "passed_via_normal_app_lifecycle"' "${SCRIPT}" ||
  fail "dogfood evidence must describe the normal App gateway proof"
grep -Fq 'launch_method: "launchservices_open_extracted_app"' "${SCRIPT}" ||
  fail "evidence must identify the LaunchServices launch path"
grep -Fq 'normal_launch: true' "${SCRIPT}" ||
  fail "evidence must distinguish normal launch from UI smoke"

grep -Fq 'ax_press_exact()' "${SCRIPT}" ||
  fail "product controls must be pressed by exact AX identity"
grep -Fq 'ax_set_value_exact()' "${SCRIPT}" ||
  fail "provider fields must be written by exact AX identity"
grep -Fq '.smokeRecordOnly("model-access-merged", recorder: smokeSectionRecorder)' "${APP_VIEW_SOURCE}" ||
  fail "model access smoke markers must preserve unique provider row AX identifiers"
grep -Fq '.smokeRecordOnly("provider-connection-use-reachable-visible", recorder: smokeSectionRecorder)' "${APP_VIEW_SOURCE}" ||
  fail "Use reachable smoke recording must preserve the real AXButton identifier"
grep -Fq 'set candidateElement to contents of candidate' "${SCRIPT}" ||
  fail "provider input must dereference the AX tree item"
grep -Fq 'set popoverRoot to group 1 of pop over 1 of menu bar 1' "${SCRIPT}" ||
  fail "provider input must bind the exact popover root"
grep -Fq 'repeat with candidate in (every group of popoverRoot)' "${SCRIPT}" ||
  fail "provider input must stay within first-level groups of the exact popover"
grep -Fq 'value of attribute "AXIdentifier" of candidateElement is "provider-form-container"' "${SCRIPT}" ||
  fail "provider input must bind the exact provider sheet container"
grep -Fq 'multiple provider form containers' "${SCRIPT}" ||
  fail "provider input must reject ambiguous provider sheet containers"
grep -Fq 'set providerScroll to scroll area 1 of providerForm' "${SCRIPT}" ||
  fail "provider input must descend through the bound provider sheet wrapper"
if grep -Fq 'repeat with candidate in entire contents' "${SCRIPT}"; then
  fail "provider input must not scan an untyped global AX list"
fi
grep -Fq 'description of candidateElement is targetLabel' "${SCRIPT}" ||
  fail "provider input must match the exact AX description"
grep -Fq 'role of candidateElement is "AXTextField"' "${SCRIPT}" ||
  fail "provider input must target a real AXTextField"
grep -Fq 'set fieldPosition to position of candidateElement' "${SCRIPT}" ||
  fail "provider input must derive its click point from the exact AXTextField"
grep -Fq 'set fieldSize to size of candidateElement' "${SCRIPT}" ||
  fail "provider input must derive its click size from the exact AXTextField"
grep -Fq 'set supportedCharacters to "abcdefghijklmnopqrstuvwxyz0123456789:/.-"' "${SCRIPT}" ||
  fail "provider input must use the bounded ASCII key-code writer"
grep -Fq 'key code 51' "${SCRIPT}" ||
  fail "exact AX field input must support clearing an existing value"
if grep -Fq 'keystroke replacementValue' "${SCRIPT}"; then
  fail "provider input must not depend on the active keyboard input method"
fi
grep -Fq 'if [[ "${identifier}" == "API key field" ]]' "${SCRIPT}" ||
  fail "SecureField readback must use masked nonempty semantics"
grep -Fq 'current_input_source()' "${SCRIPT}" ||
  fail "dogfood must snapshot the current macOS input source"
grep -Fq 'select_input_source()' "${SCRIPT}" ||
  fail "dogfood must select and restore the bounded input source"
grep -Fq 'com.apple.keylayout.ABC' "${SCRIPT}" ||
  fail "dogfood must use the stable ABC layout for physical key codes"
grep -Fq 'select_input_source "${ORIGINAL_INPUT_SOURCE}"' "${SCRIPT}" ||
  fail "cleanup must restore the original input source"
grep -Fq 'snapshot_clipboard()' "${SCRIPT}" ||
  fail "dogfood must snapshot the complete pasteboard before SecureField paste"
grep -Fq 'restore_clipboard()' "${SCRIPT}" ||
  fail "dogfood must restore the complete pasteboard"
grep -Fq 'set value of candidateElement to replacementValue' "${SCRIPT}" ||
  fail "SecureField must receive the fixture key as one exact AX value"
grep -Fq 'key code 48' "${SCRIPT}" ||
  fail "SecureField AX value must be committed by ending editing"
grep -Fq 'CLIPBOARD_CHANGED=1' "${SCRIPT}" ||
  fail "clipboard mutation must be tracked for trap cleanup"
grep -Fq 'DOGFOOD_STATE_DIR="${HOME}/Library/Application Support/RelayKit/DogfoodHarness/${RUN_TAG}"' "${SCRIPT}" ||
  fail "provider config must live in a non-stale isolated App Support directory"
grep -Fq 'PROVIDER_CONFIG="${DOGFOOD_STATE_DIR}/providers.json"' "${SCRIPT}" ||
  fail "dogfood provider config must not use the rejected /tmp relaykit prefix"
grep -Fq 'real_provider_config_unchanged' "${SCRIPT}" ||
  fail "evidence must prove the real RelayKit provider config was unchanged"
if grep -Fq '/usr/bin/security' "${SCRIPT}"; then
  fail "dogfood must not access the App-created Keychain item with /usr/bin/security"
fi
grep -Fq -- '--delete-dogfood-keychain "${KEYCHAIN_SERVICE}"' "${SCRIPT}" ||
  fail "fixture cleanup must run through the same RelayKit App code identity"
grep -Fq 'process.standardInput = credentialPipe' "${GATEWAY_PROCESS_SOURCE}" ||
  fail "RelayKit App must hand credentials to the gateway over an anonymous stdin pipe"
grep -Fq -- '"-credential-stdin"' "${GATEWAY_PROCESS_SOURCE}" ||
  fail "RelayKit App gateway launch must disable Keychain CLI fallback"
grep -Fq 'credential_handoff: "anonymous_stdin_pipe"' "${SCRIPT}" ||
  fail "evidence must identify the App-to-gateway in-memory credential handoff"

reload_body="$(sed -n '/private func saveProviderTransaction/,/^    }/p' "${APP_MODEL_SOURCE}")"
[[ -n "${reload_body}" ]] ||
  fail "provider save transaction must define a running-gateway credential reload"
grep -Fq 'guard reloadRunningGateway else' <<<"${reload_body}" ||
  fail "provider save must not start a previously stopped gateway"
grep -Fq 'restartGateway()' <<<"${reload_body}" ||
  fail "provider save must restart a running gateway with the new Keychain snapshot"
reload_call_count="$(grep -Fc 'reloadRunningGateway: gatewayWasRunning' "${APP_MODEL_SOURCE}" || true)"
[[ "${reload_call_count}" -eq 2 ]] ||
  fail "provider add and update must both use the transactional running-gateway reload"

grep -Fq 'write_reopen_failure_evidence()' "${SCRIPT}" ||
  fail "reopened provider failures must preserve a redacted runtime diagnosis"
for field in fixture_process_alive keychain_item_present provider_config_exists provider_config_model_count provider_enabled_count provider_visible_count provider_keychain_ref_count provider_catalog_url_present_count defaults_provider_config_matches_expected gateway_config_matches_expected gateway_is_app_child gateway_health_ok gateway_loaded_provider_count gateway_loaded_configured_model_count gateway_loaded_official_model_count gateway_model_health_probed gateway_visible_models gateway_hidden_models ui_testing_in_progress ui_failure_kind; do
  grep -Fq "${field}" "${SCRIPT}" || fail "reopen failure diagnosis missing ${field}"
done
if grep -Fq 'keyboardSetUnicodeString' "${SCRIPT}"; then
  fail "dogfood must not rely on blocked CGEvent Unicode injection"
fi
if grep -Fq 'kAXParentAttribute' "${SCRIPT}"; then
  fail "AX actions must not climb to unrelated ancestor buttons"
fi
if grep -Fq 'mouse_status_item left' "${SCRIPT}"; then
  fail "normal product actions must not use a guessed coordinate click"
fi
grep -Fq 'description is "RelayKit"' "${SCRIPT}" ||
  fail "status item lookup must use the exact RelayKit identity"
grep -Fq 'tell process "RelayKitApp.bin"' "${SCRIPT}" ||
  fail "AX text input must target the exact RelayKit process"
grep -Fq 'set frontmost to true' "${SCRIPT}" ||
  fail "AX text input must activate RelayKit before typing"

for field in \
  current_zip_sha256 \
  zip_build_time_utc \
  extracted_app_path \
  connect_clicked \
  gateway_warmup_retry_used \
  settings_clicked \
  usage_clicked \
  gateway_restart_clicked \
  right_click_quit_clicked \
  provider_saved_before_quit \
  provider_save_reloaded_running_gateway \
  provider_present_after_reopen \
  keychain_saved_state_after_reopen \
  reachable_models_after_reopen \
  reachable_models_reprobed_after_reopen \
  bad_base_url_actionable \
  bad_key_actionable \
  bad_model_actionable; do
  grep -Fq "${field}" "${SCRIPT}" || fail "missing evidence field ${field}"
done

grep -Fq 'gateway_pid_before_provider_save=' "${SCRIPT}" ||
  fail "dogfood must snapshot the already-running gateway before provider save"
grep -Fq 'PROVIDER_SAVE_RELOADED_RUNNING_GATEWAY=true' "${SCRIPT}" ||
  fail "dogfood must prove provider save replaced the stale gateway credential snapshot"

if grep -Fq 'usage_has_real_rows' "${SCRIPT}"; then
  fail "fixture usage must not be described as real rows"
fi
grep -Fq 'usage_evidence_kind: "fixture"' "${SCRIPT}" ||
  fail "fixture usage must be labeled explicitly"

grep -Fq 'ax_press_exact "provider-connection-test-entry" || fail "reopened provider Test connection AX click failed"' "${SCRIPT}" ||
  fail "reachable models must be re-probed after reopening the extracted app"
grep -Fq 'app_exited_after_right_click_quit' "${SCRIPT}" ||
  fail "evidence must record that the normal app lifecycle exited"
grep -Fq 'gateway_19777_released_after_quit' "${SCRIPT}" ||
  fail "evidence must record bounded gateway release after Quit"
if grep -Fq 'fixture_gateway_keychain_acl' "${SCRIPT}"; then
  fail "dogfood evidence must not claim fixture Keychain ACL preparation"
fi
grep -Fq 'real_user_keychain_authorization_claimed: false' "${SCRIPT}" ||
  fail "dogfood must not claim a real user Keychain authorization"
grep -Fq 'cleanup_and_verify_global_state()' "${SCRIPT}" ||
  fail "dogfood failure and interruption cleanup must verify global Codex state"
grep -Fq 'trap cleanup_and_verify_global_state EXIT' "${SCRIPT}" ||
  fail "dogfood must install the fail-closed global-state cleanup trap"
if grep -Fq 'trap cleanup EXIT' "${SCRIPT}"; then
  fail "dogfood must not use cleanup without the global Codex state guard"
fi
guard_home="$(mktemp -d "${TMPDIR:-/tmp}/relaykit-dogfood-global-guard.XXXXXX")"
mkdir -p "${guard_home}/.codex"
printf 'model = "gpt-5.5"\n' >"${guard_home}/.codex/config.toml"
printf '{}\n' >"${guard_home}/.codex/auth.json"
guard_config_before="$(file_signature "${guard_home}/.codex/config.toml")"
guard_auth_before="$(file_signature "${guard_home}/.codex/auth.json")"
HOME="${guard_home}" "${SCRIPT}" --test-global-state-guard "${guard_config_before}" "${guard_auth_before}"
printf '# changed\n' >>"${guard_home}/.codex/config.toml"
if HOME="${guard_home}" "${SCRIPT}" --test-global-state-guard "${guard_config_before}" "${guard_auth_before}"; then
  rm -rf "${guard_home}"
  fail "dogfood global-state guard accepted a changed config"
fi
rm -rf "${guard_home}"
if grep -Fq 'capture_popover "provider-bad-key-guidance"' "${SCRIPT}"; then
  fail "dogfood must not capture the provider sheet while macOS secure-input redaction is active"
fi
grep -Fq 'screenshot_audit:' "${SCRIPT}" ||
  fail "tracked dogfood must generate its own screenshot audit"
grep -Fq '/usr/sbin/screencapture -x -l "${window_id}"' "${SCRIPT}" ||
  fail "screenshots must bind to a RelayKit-owned WindowServer id"
grep -Fq '/usr/sbin/screencapture -x -l "${window_id}" -o "${raw}"' "${SCRIPT}" ||
  fail "window screenshots must exclude the macOS shadow artifact"
grep -Fq '/usr/sbin/screencapture -x -m "${composited}"' "${SCRIPT}" ||
  fail "window screenshots must capture the main display final composition before owned-bounds cropping"
grep -Fq 'flatten_screenshot "${raw}" "${composited}" "${bounds}" "${destination}"' "${SCRIPT}" ||
  fail "window screenshots must mask final composition with the owned window alpha"
grep -Fq 'sleep 2 # let SwiftUI and WindowServer finish the popover transition' "${SCRIPT}" ||
  fail "window screenshots must wait for SwiftUI and the popover transition to settle"
grep -Fq 'func windowBodyRect(_ image: CGImage) -> CGRect' "${SCRIPT}" ||
  fail "window screenshots must derive the main body from the WindowServer alpha mask"
grep -Fq 'let maskBodyRect = windowBodyRect(maskCG)' "${SCRIPT}" ||
  fail "window screenshots must remove popover pointers without editing content"
grep -Fq 'func silhouetteAlpha(_ pixels: [UInt8], width: Int, height: Int) -> [UInt8]' "${SCRIPT}" ||
  fail "window screenshots must bridge internal SwiftUI surface holes without losing the owned window outline"
grep -Fq 'bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue' "${SCRIPT}" ||
  fail "window screenshots must composite transparent WindowServer pixels with alpha"
if grep -Fq 'bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue' "${SCRIPT}"; then
  fail "window screenshot flattening must not turn transparent pixels black"
fi
if grep -Fq 'as? CFDictionary' "${SCRIPT}"; then
  fail "dogfood WindowServer probes must compile with the current Swift toolchain"
fi
if grep -Fq '/usr/sbin/screencapture -x -R' "${SCRIPT}"; then
  fail "screenshots must crop the final display frame by owned bounds instead of using region capture"
fi

if grep -Eq 'launch_method: .*ui.smoke|normal_launch: false' "${SCRIPT}"; then
  fail "UI smoke cannot be the normal dogfood launch evidence"
fi

echo "Local beta dogfood smoke contract tests passed"
