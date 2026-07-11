#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HARNESS="${ROOT}/scripts/codex-desktop-manual-proof.sh"

fail_json() {
  jq -nc --arg code "$1" '{status:"failed",error_code:$code}' >&2
  exit 1
}

[[ "${1:-}" == "--model" && -n "${2:-}" && "${3:-}" == "--query-file" && -n "${4:-}" &&
   "${5:-}" == "--expect" && -n "${6:-}" && "${7:-}" == "--catalog-evidence" && -n "${8:-}" &&
   "${9:-}" == "--catalog-sha256" && -n "${10:-}" && "${11:-}" == "--artifact-sha256" && -n "${12:-}" && -z "${13:-}" ]] ||
  fail_json "invalid_arguments"

REQUESTED_MODEL="$2"
QUERY_FILE="$4"
EXPECTATION="$6"
CATALOG_EVIDENCE="$8"
EXPECTED_CATALOG_SHA256="${10}"
EXPECTED_ARTIFACT_SHA256="${12}"

[[ -x "${HARNESS}" ]] || fail_json "harness_unavailable"
[[ "${QUERY_FILE}" = /* && -f "${QUERY_FILE}" && ! -L "${QUERY_FILE}" && "$(stat -f '%Lp' "${QUERY_FILE}")" == "600" ]] ||
  fail_json "query_file_invalid"
[[ "${EXPECTATION}" == "plain" || "${EXPECTATION}" == "markdown" || "${EXPECTATION}" == "tool" ]] ||
  fail_json "expect_invalid"
[[ "${CATALOG_EVIDENCE}" = /* && -f "${CATALOG_EVIDENCE}" && ! -L "${CATALOG_EVIDENCE}" ]] ||
  fail_json "catalog_evidence_unavailable"
[[ "${EXPECTED_CATALOG_SHA256}" =~ ^[0-9a-f]{64}$ && "${EXPECTED_ARTIFACT_SHA256}" =~ ^[0-9a-f]{64}$ ]] ||
  fail_json "evidence_hash_invalid"
[[ "$(shasum -a 256 "${CATALOG_EVIDENCE}" | awk '{print $1}')" == "${EXPECTED_CATALOG_SHA256}" ]] ||
  fail_json "catalog_evidence_stale"

MARKER="$(rg -o 'RELAYKIT_DESKTOP_QUERY_[0-9TZ]+_[0-9]+' "${QUERY_FILE}" | tail -n 1 || true)"
[[ -n "${MARKER}" && "$(rg -o 'RELAYKIT_DESKTOP_QUERY_[0-9TZ]+_[0-9]+' "${QUERY_FILE}" | wc -l | tr -d ' ')" == "1" ]] ||
  fail_json "query_marker_invalid"

# Load the established fail-closed sandbox, App lifecycle, AX, screenshot, and
# rollout helpers without entering a proof mode. The targeted lifecycle below
# deliberately skips the full multi-stage and provider setup paths.
# shellcheck source=/dev/null
source "${HARNESS}" --help 2>/dev/null

REAL_HOME="$(cd "${HOME}" && pwd -P)"
PROOF_ROOT="${HOME}/Library/Application Support/RelayKit/DesktopProof"
ISO_HOME="${PROOF_ROOT}/home"
OFFICIAL_PROOF_ROOT="${PROOF_ROOT}/official-proof"
APP_OFFICIAL_CODEX_HOME="${OFFICIAL_PROOF_ROOT}/codex-home"
CODEX_HOME_DIR="${APP_OFFICIAL_CODEX_HOME}"
DESKTOP_USER_DATA_DIR="${PROOF_ROOT}/desktop-user-data"
APP_INSTALL_DIR="${PROOF_ROOT}/app-install"
APP_BUNDLE="${APP_INSTALL_DIR}/RelayKitApp.app"
APP_REAL_BINARY="${APP_BUNDLE}/Contents/MacOS/RelayKitApp.bin"
BUNDLED_RELAY="${APP_BUNDLE}/Contents/MacOS/relay"
ZIP_PATH="${ROOT}/dist/RelayKitApp-local.zip"

REQUEST_ROOT="${PROOF_ROOT}/query-once/${MARKER}"
RUN_DIR="${REQUEST_ROOT}/run"
LOG_DIR="${REQUEST_ROOT}/logs"
OUT="${ROOT}/dist/codex-desktop-query/${MARKER}"
USAGE_PATH="${REQUEST_ROOT}/usage.jsonl"
PROVIDER_CONFIG="${REQUEST_ROOT}/official-provider.json"
CATALOG_PATH="${REQUEST_ROOT}/model-catalog.json"
CODEX_CONFIG="${CODEX_HOME_DIR}/config.toml"
CONFIG_BACKUP="${REQUEST_ROOT}/codex-config.before"
CONFIG_WAS_PRESENT=false

PROVIDER_PID_FILE="${RUN_DIR}/provider.pid"
GATEWAY_PID_FILE="${RUN_DIR}/gateway.pid"
APP_PID_FILE="${RUN_DIR}/relaykit-app.pid"
DESKTOP_PID_FILE="${RUN_DIR}/codex-desktop.pid"
PORT_FILE="${RUN_DIR}/gateway-port"
PROVIDER_PORT_FILE="${RUN_DIR}/provider-port"
GATEWAY_LOG="${LOG_DIR}/gateway.log"
APP_LOG="${LOG_DIR}/relaykit-app.log"
DESKTOP_LOG="${LOG_DIR}/codex-desktop.log"
PROVIDER_LOG="${LOG_DIR}/provider.log"
DESKTOP_SANDBOX_PROFILE="${RUN_DIR}/codex-desktop-proof.sb"
DESKTOP_SANDBOX_STATUS_FILE="${RUN_DIR}/desktop-sandbox-status"
DESKTOP_WINDOW_IDENTITY="${RUN_DIR}/desktop-window-identity.json"
APP_WINDOW_IDENTITY="${RUN_DIR}/relaykit-app-window-identity.json"
APP_SCREENSHOT="${OUT}/relaykit-app-before-desktop.png"
DESKTOP_TOOL_EVIDENCE="${OUT}/desktop-tool-evidence.json"
DESKTOP_RENDER_EVIDENCE="${OUT}/desktop-render-evidence.json"
SCREENSHOT_DIR="${OUT}/screenshots"
SCREENSHOT_EVIDENCE="${OUT}/screenshots.json"
TOOL_MARKER_FILE="${RUN_DIR}/tool-marker"
TOOL_SINCE_FILE="${RUN_DIR}/tool-since-epoch"
AX_DRIVER_SOURCE="${ROOT}/scripts/codex-desktop-ax-driver.swift"
AX_DRIVER_BINARY="${RUN_DIR}/codex-desktop-ax-driver"
AUTOMATED_CATALOG_LABELS_FILE="${RUN_DIR}/automated-model-labels.json"
AUTOMATED_STAGE_EVIDENCE="${OUT}/automated-stages.json"
PROOF_INPUT_MODE="automated_ax"
PROOF_SCOPE="real_isolated_route"
PROOF_PROVIDER_MODEL_ID=""
RELAYKIT_APP_LAUNCHED=false
GLOBAL_GUARD_ARMED=false
SOURCE_GUARD_ARMED=false
SUBMISSION_STATE="not_submitted"
ERROR_CODE="official_lifecycle_failed"
OWNED_RUNTIME_STARTED=false

[[ ! -e "${REQUEST_ROOT}" && ! -e "${OUT}" ]] || fail_json "request_state_exists"

restore_isolated_config() {
  if [[ "${CONFIG_WAS_PRESENT}" == "true" && -f "${CONFIG_BACKUP}" ]]; then
    cp -p "${CONFIG_BACKUP}" "${CODEX_CONFIG}"
  else
    rm -f "${CODEX_CONFIG}"
  fi
}

finish_cleanup() {
  local exit_status=$? evidence_path=""
  trap - EXIT INT TERM HUP
  cleanup_processes >/dev/null 2>&1 || exit_status=1
  restore_isolated_config >/dev/null 2>&1 || exit_status=1
  if [[ "${GLOBAL_GUARD_ARMED}" == "true" ]] && ! assert_global_state_unchanged >/dev/null 2>&1; then
    ERROR_CODE="global_state_changed"
    exit_status=1
  fi
  if [[ "${OWNED_RUNTIME_STARTED}" == "true" ]]; then
    for _ in {1..50}; do
      port_is_free 19777 && break
      sleep 0.1
    done
    if ! port_is_free 19777; then
      ERROR_CODE="gateway_port_not_released"
      exit_status=1
    fi
  fi
  if [[ "${exit_status}" -ne 0 ]]; then
    [[ -f "${OUT}/evidence.json" ]] && evidence_path="${OUT}/evidence.json"
    jq -nc \
      --arg code "${ERROR_CODE}" \
      --arg submission_state "${SUBMISSION_STATE}" \
      --arg evidence "${evidence_path}" \
      '{status:"failed",error_code:$code,submission_state:$submission_state,evidence:(if $evidence == "" then null else $evidence end)}' >&2
  fi
  exit "${exit_status}"
}

trap finish_cleanup EXIT
trap 'ERROR_CODE="official_lifecycle_interrupted"; exit 130' INT TERM HUP

mkdir -p "${REQUEST_ROOT}" "${RUN_DIR}" "${LOG_DIR}" "${OUT}" "${SCREENSHOT_DIR}"
chmod 700 "${REQUEST_ROOT}" "${RUN_DIR}" "${LOG_DIR}" "${OUT}" "${SCREENSHOT_DIR}"
printf '[]\n' >"${SCREENSHOT_EVIDENCE}"
printf '[]\n' >"${AUTOMATED_STAGE_EVIDENCE}"
printf '{"proof_found":false,"function_call_found":false,"function_call_output_found":false,"process_exited_zero":false,"matched_provider_tool_count":0,"xml_leak_found":false,"raw_function_calls_found":false,"xml_leak_records":[],"event_count":0,"events":[]}\n' >"${DESKTOP_TOOL_EVIDENCE}"
printf '{"gpt55_gui_visible":false,"gpt56_gui_visible":false,"markdown_source_contract_verified":false,"markdown_visual_tokens_verified":false,"markdown_render_verified":false,"raw_protocol_absent":true,"raw_protocol_records":[],"tool_gui_verified":false,"current_run_assistant_message_count":0}\n' >"${DESKTOP_RENDER_EVIDENCE}"
: >"${USAGE_PATH}"
chmod 600 "${USAGE_PATH}" "${SCREENSHOT_EVIDENCE}" "${AUTOMATED_STAGE_EVIDENCE}" "${DESKTOP_TOOL_EVIDENCE}" "${DESKTOP_RENDER_EVIDENCE}"

if [[ -f "${CODEX_CONFIG}" ]]; then
  cp -p "${CODEX_CONFIG}" "${CONFIG_BACKUP}"
  chmod 600 "${CONFIG_BACKUP}"
  CONFIG_WAS_PRESENT=true
fi

ERROR_CODE="global_state_capture_failed"
capture_global_state
ERROR_CODE="runtime_conflict"
port_is_free 18787 || {
  ERROR_CODE="shared_18787_in_use"
  exit 1
}
port_is_free 19777 || {
  ERROR_CODE="shared_19777_in_use"
  exit 1
}

ERROR_CODE="artifact_reuse_failed"
RELAYKIT_DESKTOP_PROOF_REUSE_CURRENT_ZIP=1
RELAYKIT_DESKTOP_PROOF_REUSE_EXTRACTED_APP=1
prepare_extracted_app >>"${LOG_DIR}/lifecycle.log" 2>&1
[[ "${APP_ZIP_SHA256}" == "${EXPECTED_ARTIFACT_SHA256}" ]] || {
  ERROR_CODE="artifact_evidence_stale"
  exit 1
}

ERROR_CODE="desktop_binary_unavailable"
CODEX_APP_BINARY="$(resolve_codex_app_binary || true)"
CODEX_CLI_BINARY="$(resolve_codex_cli_binary || true)"
[[ -n "${CODEX_APP_BINARY}" && -x "${CODEX_APP_BINARY}" && -n "${CODEX_CLI_BINARY}" && -x "${CODEX_CLI_BINARY}" ]] || exit 1

ERROR_CODE="official_catalog_failed"
"${CODEX_CLI_BINARY}" debug models --bundled >"${RUN_DIR}/bundled-models.json"
project_official_model_catalog \
  "${RUN_DIR}/bundled-models.json" \
  "${CODEX_HOME_DIR}/models_cache.json" \
  "${PROOF_SCOPE}" \
  "${CATALOG_PATH}"
chmod 600 "${CATALOG_PATH}"
jq -e --arg model "${REQUESTED_MODEL}" 'any(.models[]?; .slug == $model)' "${CATALOG_PATH}" >/dev/null || {
  ERROR_CODE="model_not_in_live_official_catalog"
  exit 1
}

jq -n \
  --arg codex_home "${CODEX_HOME_DIR}" \
  --arg codex_binary "${CODEX_CLI_BINARY}" \
  --slurpfile catalog "${CATALOG_PATH}" \
  '{
    official_passthrough: {
      base_url: "https://api.openai.example/v1",
      credential_ref: {kind:"codex_home", value:$codex_home},
      codex_binary: $codex_binary,
      models: [$catalog[0].models[] | select(.visibility == "list") | {id:.slug, display_name:(.display_name // .slug)}]
    },
    providers: []
  }' >"${PROVIDER_CONFIG}"
chmod 600 "${PROVIDER_CONFIG}"

ERROR_CODE="isolated_config_failed"
write_codex_config 19777
chmod 600 "${CODEX_CONFIG}"
printf '19777\n' >"${PORT_FILE}"
chmod 600 "${PORT_FILE}"
OWNED_RUNTIME_STARTED=true

ERROR_CODE="relaykit_app_launch_failed"
launch_isolated_relaykit_app >>"${LOG_DIR}/lifecycle.log" 2>&1
curl -fsS --max-time 5 http://127.0.0.1:19777/v1/models >"${OUT}/gateway-models.json"
jq -e --arg model "${REQUESTED_MODEL}" 'any(.data[]?; .id == $model)' "${OUT}/gateway-models.json" >/dev/null || {
  ERROR_CODE="model_not_in_gateway_catalog"
  exit 1
}

ERROR_CODE="app_server_catalog_failed"
write_app_server_evidence
jq -e --arg model "${REQUESTED_MODEL}" 'any(.official[]?; .model == $model)' "${OUT}/app-server.json" >/dev/null || {
  ERROR_CODE="model_not_in_app_server_catalog"
  exit 1
}
LIVE_MODEL_LABEL="$(resolve_automated_model_label "${OUT}/app-server.json" "${REQUESTED_MODEL}")" || {
  ERROR_CODE="model_label_resolution_failed"
  exit 1
}

ERROR_CODE="ax_driver_build_failed"
build_automated_ax_driver
write_automated_catalog_labels "${AUTOMATED_CATALOG_LABELS_FILE}"
ERROR_CODE="desktop_launch_failed"
launch_desktop >>"${LOG_DIR}/lifecycle.log" 2>&1
DESKTOP_PID="$(jq -er '.pid | select(type == "number" and . > 0)' "${DESKTOP_WINDOW_IDENTITY}")"

ERROR_CODE="desktop_prepare_failed"
activate_isolated_desktop
verify_desktop_window_identity
if ! "${AX_DRIVER_BINARY}" prepare \
    --pid "${DESKTOP_PID}" \
    --window-identity "${DESKTOP_WINDOW_IDENTITY}" \
    --workspace "$(basename "${ROOT}")" >"${RUN_DIR}/ax-prepare.json"; then
  ERROR_CODE="prepare_$(driver_failure_code "${RUN_DIR}/ax-prepare.json" unknown)"
  exit 1
fi
jq -e '.status == "ok" and .code == "ok" and .window_verified == true and .composer_count == 1 and .action_count == 1' "${RUN_DIR}/ax-prepare.json" >/dev/null || {
  ERROR_CODE="prepare_report_invalid"
  exit 1
}

SINCE_EPOCH="$(date +%s)"
ERROR_CODE="desktop_submit_failed"
activate_isolated_desktop
verify_desktop_window_identity
if ! "${AX_DRIVER_BINARY}" submit \
    --pid "${DESKTOP_PID}" \
    --window-identity "${DESKTOP_WINDOW_IDENTITY}" \
    --model-label "${LIVE_MODEL_LABEL}" \
    --catalog-labels-file "${AUTOMATED_CATALOG_LABELS_FILE}" \
    --query-file "${QUERY_FILE}" >"${RUN_DIR}/ax-submit.json"; then
  DRIVER_CODE="$(driver_failure_code "${RUN_DIR}/ax-submit.json" unknown)"
  [[ "${DRIVER_CODE}" == "send_result_ambiguous" ]] && SUBMISSION_STATE="unknown_after_submit_attempt"
  ERROR_CODE="submit_${DRIVER_CODE}"
  exit 1
fi
jq -e '.status == "ok" and .code == "ok" and .window_verified == true and .composer_count == 1 and .send_count == 1' "${RUN_DIR}/ax-submit.json" >/dev/null || {
  SUBMISSION_STATE="unknown_after_submit_attempt"
  ERROR_CODE="submit_report_invalid"
  exit 1
}
SUBMISSION_STATE="submitted"

ERROR_CODE="observation_failed"
WAIT_STATUS=0
wait_for_automated_stage 0 "${REQUESTED_MODEL}" "desktop-query-response" "${EXPECTATION}" "${MARKER}" "${SINCE_EPOCH}" 420 || WAIT_STATUS=$?
if [[ "${WAIT_STATUS}" -ne 0 ]]; then
  ERROR_CODE="observation_failed_${WAIT_STATUS}"
  exit 1
fi

ERROR_CODE="global_state_changed"
assert_global_state_unchanged
CONFIG_AFTER="$(file_signature "${GLOBAL_CODEX_CONFIG}")"
AUTH_AFTER="$(file_signature "${GLOBAL_CODEX_AUTH}")"
CONFIG_HASH_AFTER="$(file_hash "${GLOBAL_CODEX_CONFIG}")"
AUTH_HASH_AFTER="$(file_hash "${GLOBAL_CODEX_AUTH}")"

ERROR_CODE="runtime_cleanup_failed"
cleanup_processes
for _ in {1..50}; do
  port_is_free 19777 && break
  sleep 0.1
done
port_is_free 19777 || exit 1
restore_isolated_config
assert_global_state_unchanged
port_is_free 18787 || {
  ERROR_CODE="shared_18787_in_use_after"
  exit 1
}

jq -n \
  --arg model "${REQUESTED_MODEL}" \
  --arg expect "${EXPECTATION}" \
  --arg artifact_sha256 "${EXPECTED_ARTIFACT_SHA256}" \
  --arg catalog_sha256 "${EXPECTED_CATALOG_SHA256}" \
  --arg config_before "${CONFIG_HASH_BEFORE}" \
  --arg config_after "${CONFIG_HASH_AFTER}" \
  --arg auth_before "${AUTH_HASH_BEFORE}" \
  --arg auth_after "${AUTH_HASH_AFTER}" \
  --arg codex_binary "${CODEX_CLI_BINARY}" \
  --slurpfile usage "${OUT}/usage-events.json" \
  --slurpfile binding "${RUN_DIR}/automated-rollout-desktop-query-response.json" \
  --slurpfile screenshots "${SCREENSHOT_EVIDENCE}" \
  '{
    status:"complete",
    scope:"targeted_official_desktop_query",
    model:$model,
    expect:$expect,
    submission_state:"submitted",
    artifact_sha256:$artifact_sha256,
    catalog_sha256:$catalog_sha256,
    official_passthrough_uses_desktop_bundled_cli:($codex_binary | startswith("/") and contains("/Contents/Resources/codex")),
    current_run_usage: [$usage[0][] | select(.model == $model) | {model,status,http_status,provider_id,error_type}],
    rollout_binding: ($binding[0] | {proof_found,thread_id,user_marker_count,assistant_marker_count}),
    process_bound_screenshots: [$screenshots[0][] | {role,path,sha256,pid,window_id,target_identity_verified,visual_checks}],
    global_config_sha256_before:$config_before,
    global_config_sha256_after:$config_after,
    global_auth_sha256_before:$auth_before,
    global_auth_sha256_after:$auth_after,
    global_config_unchanged:($config_before == $config_after),
    global_auth_unchanged:($auth_before == $auth_after),
    shared_18787_free_after:true,
    shared_19777_free_after:true
  }' >"${OUT}/evidence.json"
chmod 600 "${OUT}/evidence.json"
jq -e '
  .status == "complete" and
  .submission_state == "submitted" and
  (.current_run_usage | length) == 1 and
  .current_run_usage[0].status == "completed" and
  .current_run_usage[0].http_status == 200 and
  .rollout_binding.proof_found == true and
  .rollout_binding.user_marker_count == 1 and
  .rollout_binding.assistant_marker_count == 1 and
  (.process_bound_screenshots | length) >= 1 and
  all(.process_bound_screenshots[]; .target_identity_verified == true) and
  .global_config_unchanged == true and
  .global_auth_unchanged == true
' "${OUT}/evidence.json" >/dev/null || {
  ERROR_CODE="evidence_validation_failed"
  exit 1
}

trap - EXIT INT TERM HUP
jq -nc --arg evidence "${OUT}/evidence.json" '{status:"complete",submission_state:"submitted",evidence:$evidence}'
