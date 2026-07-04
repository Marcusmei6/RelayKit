#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_BUNDLE="${ROOT}/dist/RelayKitApp.app"
APP="${ROOT}/dist/RelayKitApp.app/Contents/MacOS/RelayKitApp"
APP_REAL="${ROOT}/dist/RelayKitApp.app/Contents/MacOS/RelayKitApp.bin"
BUNDLED_RELAY="${ROOT}/dist/RelayKitApp.app/Contents/MacOS/relay"
BUNDLE_ID="dev.relaykit.app"
APPEARANCE_KEY="appearanceMode"
OUT="${ROOT}/dist/ui-smoke"
PID=""
ORIGINAL_APPEARANCE=""
HAD_ORIGINAL_APPEARANCE=0

cleanup() {
  if [[ -n "${PID}" ]] && kill -0 "${PID}" 2>/dev/null; then
    kill "${PID}" >/dev/null 2>&1 || true
    wait "${PID}" >/dev/null 2>&1 || true
  fi
  pkill -x RelayKitApp.bin >/dev/null 2>&1 || true
  pkill -f "${APP_REAL}" >/dev/null 2>&1 || true
  pkill -f "${BUNDLED_RELAY}" >/dev/null 2>&1 || true
}

restore_defaults() {
  if [[ "${HAD_ORIGINAL_APPEARANCE}" == "1" ]]; then
    /usr/bin/defaults write "${BUNDLE_ID}" "${APPEARANCE_KEY}" "${ORIGINAL_APPEARANCE}" >/dev/null 2>&1 || true
  else
    /usr/bin/defaults delete "${BUNDLE_ID}" "${APPEARANCE_KEY}" >/dev/null 2>&1 || true
  fi
}
trap 'restore_defaults; cleanup' EXIT

capture() {
  local name="$1"
  shift
  local evidence="${OUT}/${name}.json"
  cleanup
  /usr/bin/open -n "${APP_BUNDLE}" --args --ui-smoke --ui-smoke-evidence "${evidence}" "$@" >/tmp/relaykit-ui-smoke.log 2>&1
  sleep 3
  PID="$(pgrep -x RelayKitApp.bin | head -1 || true)"
  if [[ -z "${PID}" ]] || ! kill -0 "${PID}" 2>/dev/null; then
    cat /tmp/relaykit-ui-smoke.log >&2
    exit 1
  fi
  test -s "${evidence}"
  case "${name}" in
    connect) required='["tab-connect","cli-route","local-cli-scan","cli-selected-state","codex-target-state","claude-disabled-placeholder","configured-providers","reference-catalog","add-strip","auth-blocked-state"]' ;;
    detail) required='["tab-connect","cli-route","local-cli-scan","cli-selected-state","codex-target-state","claude-disabled-placeholder","configured-providers","reference-catalog","provider-edit-modal","add-strip","auth-blocked-state"]' ;;
    usage) required='["tab-usage","usage-kpis","usage-rows"]' ;;
    settings|settings-light) required='["tab-settings","appearance-control","launch-login-control","settings-actions","advanced-paths"]' ;;
    provider) required='["add-strip","add-strip-action","tab-provider","provider-modal","provider-add-mode","credential-reference-form","provider-protocol-field","provider-base-url-field","provider-models-url-field","provider-model-mapping-field"]' ;;
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
      $doc.connect.configured_provider_count > 0 and
      ($doc.connect.configured_provider_labels | length) == $doc.connect.configured_provider_count and
      $doc.connect.reference_catalog_model_count > 0 and
      $doc.connect.reference_catalog_source_group_count > 0 and
      $doc.connect.display_mode == "configured-providers-and-reference-sources" and
      ($doc.connect.reference_row_labels | length) == $doc.connect.reference_catalog_source_group_count and
      (all($doc.connect.reference_row_labels[]; test("^source-[0-9]+$"))) and
      ($doc.connect.reference_row_labels | index("qwen3-coder") | not) and
      ($doc.connect.reference_row_labels | index("claude-example") | not) and
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
  if [[ "${name}" == "detail" ]]; then
    jq -e '
      .connect.provider_edit_opened == true and
      .connect.provider_edit_has_save == true and
      .connect.provider_edit_has_add_cta == false and
      .connect.model_ids_redacted == true and
      .connect.source_names_redacted == true
    ' "${evidence}" >/dev/null
  fi
  if [[ "${name}" == "provider" ]]; then
    jq -e '.connect.add_strip_opens_provider_modal == true' "${evidence}" >/dev/null
  fi
  /usr/sbin/screencapture -x "${OUT}/${name}.png"
  test -s "${OUT}/${name}.png"
  kill "${PID}" >/dev/null 2>&1 || true
  wait "${PID}" >/dev/null 2>&1 || true
  PID=""
  cleanup
}

cd "${ROOT}"
./script/build_and_run.sh --verify >/dev/null
rm -rf "${OUT}"
mkdir -p "${OUT}"

if ORIGINAL_APPEARANCE="$(/usr/bin/defaults read "${BUNDLE_ID}" "${APPEARANCE_KEY}" 2>/dev/null)"; then
  HAD_ORIGINAL_APPEARANCE=1
else
  ORIGINAL_APPEARANCE=""
  HAD_ORIGINAL_APPEARANCE=0
fi

capture connect --ui-smoke-tab connect
capture detail --ui-smoke-tab connect --ui-smoke-detail
capture usage --ui-smoke-tab usage
capture settings --ui-smoke-tab settings
/usr/bin/defaults write "${BUNDLE_ID}" "${APPEARANCE_KEY}" light
capture settings-light --ui-smoke-tab settings
jq -e '.settings.appearance_mode == "light"' "${OUT}/settings-light.json" >/dev/null
restore_defaults
capture provider --ui-smoke-tab connect --ui-smoke-provider

if pgrep -x RelayKitApp.bin >/dev/null || pgrep -f "${BUNDLED_RELAY}" >/dev/null; then
  echo "UI smoke left stale RelayKit-owned app or gateway process" >&2
  exit 1
fi

echo "RelayKit menu bar UI smoke passed: ${OUT}"
