#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${ROOT}/dist/dogfood-local-beta"
INSTALL_DIR="${OUT}/install"
SCREENSHOT_DIR="${OUT}/screenshots"
CAPTURE_DIR="${OUT}/captures"
ZIP_PATH="${ROOT}/dist/RelayKitApp-local.zip"
APP_BUNDLE="${INSTALL_DIR}/RelayKitApp.app"
APP_REAL="${APP_BUNDLE}/Contents/MacOS/RelayKitApp.bin"
CODEX_CONFIG_PATH="${HOME}/.codex/config.toml"
CODEX_AUTH_PATH="${HOME}/.codex/auth.json"
CATALOG_PORT="18790"
CATALOG_URL="http://127.0.0.1:${CATALOG_PORT}/v1/models"
SMOKE_KEYCHAIN_SERVICE="relaykit.dogfood.provider.fixture"
PID=""
FAKE_CATALOG_PID=""
SMOKE_CONFIG_DIR=""

cleanup_app() {
  if [[ -n "${PID}" ]] && kill -0 "${PID}" 2>/dev/null; then
    kill "${PID}" >/dev/null 2>&1 || true
    wait "${PID}" >/dev/null 2>&1 || true
  fi
  pkill -f "${APP_REAL}" >/dev/null 2>&1 || true
  pkill -f "${APP_BUNDLE}/Contents/MacOS/relay" >/dev/null 2>&1 || true
}

cleanup() {
  cleanup_app
  if [[ -n "${FAKE_CATALOG_PID}" ]] && kill -0 "${FAKE_CATALOG_PID}" 2>/dev/null; then
    kill "${FAKE_CATALOG_PID}" >/dev/null 2>&1 || true
    wait "${FAKE_CATALOG_PID}" >/dev/null 2>&1 || true
  fi
  while /usr/bin/security delete-generic-password -s "${SMOKE_KEYCHAIN_SERVICE}" -a RelayKit >/dev/null 2>&1; do
    :
  done
  [[ -n "${SMOKE_CONFIG_DIR}" ]] && rm -rf "${SMOKE_CONFIG_DIR}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

file_signature() {
  local path="$1"
  if [[ -e "${path}" ]]; then
    shasum -a 256 "${path}" | awk '{print $1}'
  else
    printf 'missing'
  fi
}

port_free() {
  local port="$1"
  ! lsof -nP -iTCP:"${port}" -sTCP:LISTEN >/dev/null 2>&1
}

capture() {
  local name="$1"
  shift
  local evidence="${CAPTURE_DIR}/${name}.json"
  cleanup_app
  RELAYKIT_DOGFOOD_API_KEY="dogfood-fixture-key" "${APP_REAL}" --ui-smoke --ui-smoke-keep-open --ui-smoke-evidence "${evidence}" --ui-smoke-catalog-url "${CATALOG_URL}" --ui-smoke-seed-keychain "${SMOKE_KEYCHAIN_SERVICE}" "$@" >/tmp/relaykit-dogfood-open.log 2>&1 &
  PID="$!"
  sleep 3
  if [[ -z "${PID}" ]] || ! kill -0 "${PID}" 2>/dev/null; then
    cat /tmp/relaykit-dogfood-open.log >&2
    exit 1
  fi
  for _ in {1..120}; do
    [[ -s "${evidence}" ]] && break
    sleep 0.25
  done
  if [[ ! -s "${evidence}" ]]; then
    echo "dogfood smoke did not receive UI evidence for ${name}: ${evidence}" >&2
    exit 1
  fi
  jq -e '
    .status_item.visible == true and
    .popover.shown == true and
    .popover.ordinary_window == false and
    .surface.kind == "menu-bar-popover"
  ' "${evidence}" >/dev/null
  /usr/sbin/screencapture -x "${SCREENSHOT_DIR}/${name}.png"
  test -s "${SCREENSHOT_DIR}/${name}.png"
  cleanup_app
}

codex_config_before="$(file_signature "${CODEX_CONFIG_PATH}")"
codex_auth_before="$(file_signature "${CODEX_AUTH_PATH}")"

if ! port_free 18787; then
  echo "127.0.0.1:18787 is already listening; dogfood smoke refuses to run around shared gateway state." >&2
  exit 1
fi
if ! port_free 19777; then
  echo "127.0.0.1:19777 is already listening; stop RelayKit before running dogfood smoke." >&2
  exit 1
fi
if ! port_free "${CATALOG_PORT}"; then
  echo "127.0.0.1:${CATALOG_PORT} is already listening; dogfood smoke needs this loopback fixture port." >&2
  exit 1
fi

cd "${ROOT}"
./script/package_release.sh --verify >/dev/null

rm -rf "${OUT}"
mkdir -p "${INSTALL_DIR}" "${SCREENSHOT_DIR}" "${CAPTURE_DIR}"
/usr/bin/unzip -q "${ZIP_PATH}" -d "${INSTALL_DIR}"
test -x "${APP_REAL}"

codesign --verify --deep --strict --verbose=4 "${APP_BUNDLE}" >/dev/null
"${APP_REAL}" --verify-bundled-gateway >/dev/null

set +e
spctl_output="$(spctl -a -vvv -t exec "${APP_BUNDLE}" 2>&1)"
spctl_status=$?
set -e

SMOKE_CONFIG_DIR="$(mktemp -d /tmp/relaykit-dogfood.XXXXXX)"
CATALOG_DIR="${SMOKE_CONFIG_DIR}/catalog"
PROVIDER_CONFIG="${SMOKE_CONFIG_DIR}/providers.json"
USAGE_LOG="${SMOKE_CONFIG_DIR}/usage.jsonl"
mkdir -p "${CATALOG_DIR}/v1"
cat >"${CATALOG_DIR}/v1/models" <<'JSON'
{
  "object": "list",
  "data": [
    {"id": "gpt-5.5", "owned_by": "openai", "source": "openai", "display_name": "GPT-5.5", "protocol": "responses", "transport": "relaykit_official_passthrough", "status": "ready", "visibility": "visible"},
    {"id": "demo/claude-haiku-4-5", "owned_by": "demo", "source": "demo", "display_name": "Demo Claude Haiku 4.5", "protocol": "responses", "transport": "local_relaykit", "bridge_host": "127.0.0.1:18791", "status": "ready", "visibility": "visible"}
  ]
}
JSON
cat >"${PROVIDER_CONFIG}" <<JSON
{
  "providers": [
    {
      "id": "dogfood-demo",
      "name": "Dogfood Demo",
      "base_url": "http://127.0.0.1:${CATALOG_PORT}/v1",
      "api_format": "openai_chat",
      "auth_env": "RELAYKIT_DOGFOOD_API_KEY",
      "models": [{"id": "demo/claude-haiku-4-5", "display_name": "Demo Claude Haiku 4.5"}]
    }
  ]
}
JSON
python3 - "${USAGE_LOG}" <<'PY'
import datetime, json, sys
today = datetime.datetime.utcnow().date().isoformat() + "T12:00:00Z"
with open(sys.argv[1], "w", encoding="utf-8") as f:
    f.write(json.dumps({
        "timestamp": today,
        "request_id": "dogfood-local-beta-1",
        "provider_id": "demo",
        "model": "demo/claude-haiku-4-5",
        "route": "/v1/responses",
        "transport": "responses_http",
        "status": "completed",
        "http_status": 200,
        "input_tokens": 12,
        "output_tokens": 8,
        "total_tokens": 20,
        "duration_ms": 120
    }, separators=(",", ":")) + "\n")
PY
python3 -m http.server "${CATALOG_PORT}" --bind 127.0.0.1 --directory "${CATALOG_DIR}" >/tmp/relaykit-dogfood-catalog.log 2>&1 &
FAKE_CATALOG_PID="$!"
for _ in {1..20}; do
  curl -fsS "${CATALOG_URL}" >/dev/null 2>&1 && break
  sleep 0.1
done
curl -fsS "${CATALOG_URL}" >/dev/null

capture connect --ui-smoke-tab connect --ui-smoke-provider-config "${PROVIDER_CONFIG}"
capture settings --ui-smoke-tab settings --ui-smoke-provider-config "${PROVIDER_CONFIG}"
capture usage --ui-smoke-tab usage --ui-smoke-provider-config "${PROVIDER_CONFIG}" --ui-smoke-usage-log "${USAGE_LOG}"

jq -e '
  .connect.catalog_url_uses_shared_18787 == false and
  .connect.configured_provider_count == 1 and
  .connect.model_access_and_model_list_merged == true and
  .connect.gateway_control_exercise.health_status == "ok" and
  .connect.gateway_control_exercise.restart_health_status == "ok" and
  .connect.gateway_control_exercise.post_stop_health_status == "stopped"
' "${CAPTURE_DIR}/connect.json" >/dev/null
jq -e '.settings.gateway_port == "127.0.0.1:19777" and .settings.general_group_visible == true and .settings.gateway_group_visible == true' "${CAPTURE_DIR}/settings.json" >/dev/null
jq -e '.usage.requests == 1 and .usage.today_tokens == 20 and .usage.cost_unavailable_visible == true' "${CAPTURE_DIR}/usage.json" >/dev/null

codex_config_after="$(file_signature "${CODEX_CONFIG_PATH}")"
codex_auth_after="$(file_signature "${CODEX_AUTH_PATH}")"
if [[ "${codex_config_before}" != "${codex_config_after}" || "${codex_auth_before}" != "${codex_auth_after}" ]]; then
  echo "dogfood smoke changed global Codex config/auth files" >&2
  exit 1
fi
if ! port_free 18787; then
  echo "dogfood smoke left 127.0.0.1:18787 listening" >&2
  exit 1
fi

jq -n \
  --arg zip "${ZIP_PATH}" \
  --arg app "${APP_BUNDLE}" \
  --arg screenshots "${SCREENSHOT_DIR}" \
  --arg spctl_output "${spctl_output}" \
  --argjson spctl_status "${spctl_status}" \
  --slurpfile connect "${CAPTURE_DIR}/connect.json" \
  --slurpfile settings "${CAPTURE_DIR}/settings.json" \
  --slurpfile usage "${CAPTURE_DIR}/usage.json" \
  '{
    artifact: {
      source_zip: $zip,
      extracted_app: $app,
      launched_from_extracted_zip: true,
      launch_method: "extracted app bundle Mach-O with UI smoke arguments",
      codesign_verify: "passed",
      bundled_gateway_verify: "passed",
      gatekeeper: {
        status: $spctl_status,
        output: $spctl_output,
        local_beta_friction_expected: true
      }
    },
    app_regression: {
      menu_bar: true,
      settings_gateway_port_fixed: ($settings[0].settings.gateway_port == "127.0.0.1:19777"),
      usage_has_real_rows: ($usage[0].usage.requests == 1),
      gateway_restart_exercised: true,
      connect_first_screen_locked: $connect[0].connect.connect_first_screen_locked,
      quit_menu_visible: "covered by menu-bar-e2e-smoke"
    },
    provider_setup: {
      demo_loopback: "covered by menu-bar-e2e-smoke",
      configured_provider_count: $connect[0].connect.configured_provider_count,
      deeper_provider_form_flow: "covered by menu-bar-e2e-smoke"
    },
    safety: {
      global_codex_config_unchanged: true,
      global_codex_auth_unchanged: true,
      shared_18787_free_after: true,
      signed_beta_status: "blocked by Apple Developer Program approval"
    },
    codex_desktop_route_proof: {
      status: "skipped_manual_user_required",
      fresh_current_run_usage_event: false,
      mock_ok_used: false,
      old_usage_evidence_used: false,
      reason: "requires user-operated isolated Codex Desktop plus real official/private provider credentials"
    },
    screenshots_dir: $screenshots
  }' >"${OUT}/evidence.json"

echo "RelayKit local beta dogfood smoke passed: ${OUT}/evidence.json"
