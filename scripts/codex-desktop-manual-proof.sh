#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REAL_HOME="$(cd "${HOME}" && pwd -P)"
PROOF_ROOT="${HOME}/Library/Application Support/RelayKit/DesktopProof"
ISO_HOME="${PROOF_ROOT}/home"
APP_SUPPORT_DIR="${ISO_HOME}/Library/Application Support/RelayKit"
OFFICIAL_PROOF_ROOT="${PROOF_ROOT}/official-proof"
APP_OFFICIAL_CODEX_HOME="${OFFICIAL_PROOF_ROOT}/codex-home"
CODEX_HOME_DIR="${APP_OFFICIAL_CODEX_HOME}"
DESKTOP_USER_DATA_DIR="${PROOF_ROOT}/desktop-user-data"
LOG_DIR="${PROOF_ROOT}/logs"
RUN_DIR="${PROOF_ROOT}/run"
USAGE_PATH="${APP_SUPPORT_DIR}/usage.jsonl"
PROVIDER_CONFIG="${APP_SUPPORT_DIR}/providers.json"
CATALOG_PATH="${PROOF_ROOT}/model-catalog.json"
CODEX_CONFIG="${CODEX_HOME_DIR}/config.toml"
OUT="${ROOT}/dist/codex-desktop-manual-proof"
LAST_ROUTE_OUT="${ROOT}/dist/codex-desktop-manual-proof-last-route"
LAST_COMPLETE_OUT="${ROOT}/dist/codex-desktop-manual-proof-last-complete"
ZIP_PATH="${ROOT}/dist/RelayKitApp-local.zip"
APP_INSTALL_DIR="${PROOF_ROOT}/app-install"
APP_BUNDLE="${APP_INSTALL_DIR}/RelayKitApp.app"
APP_REAL_BINARY="${APP_BUNDLE}/Contents/MacOS/RelayKitApp.bin"
BUNDLED_RELAY="${APP_BUNDLE}/Contents/MacOS/relay"
CODEX_APP_BINARY=""
CODEX_CLI_BINARY=""
GLOBAL_CODEX_CONFIG="${REAL_HOME}/.codex/config.toml"
GLOBAL_CODEX_AUTH="${REAL_HOME}/.codex/auth.json"
GLOBAL_CODEX_STATE_DIR="${REAL_HOME}/.codex"
GLOBAL_CODEX_APP_SUPPORT_DIR="${REAL_HOME}/Library/Application Support/Codex"
GLOBAL_OPENAI_APP_SUPPORT_DIR="${REAL_HOME}/Library/Application Support/OpenAI"
GLOBAL_CODEX_BUNDLE_SUPPORT_DIR="${REAL_HOME}/Library/Application Support/com.openai.codex"
GLOBAL_CODEX_PREFERENCES="${REAL_HOME}/Library/Preferences/com.openai.codex.plist"
GLOBAL_CUA_CLI_PREFERENCES="${REAL_HOME}/Library/Preferences/com.openai.sky.CUAService.cli.plist"
GLOBAL_CUA_PREFERENCES="${REAL_HOME}/Library/Preferences/com.openai.sky.CUAService.plist"
PROVIDER_PID_FILE="${RUN_DIR}/provider.pid"
GATEWAY_PID_FILE="${RUN_DIR}/gateway.pid"
APP_PID_FILE="${RUN_DIR}/relaykit-app.pid"
DESKTOP_PID_FILE="${RUN_DIR}/codex-desktop.pid"
PORT_FILE="${RUN_DIR}/gateway-port"
PROVIDER_PORT_FILE="${RUN_DIR}/provider-port"
PROVIDER_EVENTS="${LOG_DIR}/provider-events.jsonl"
GATEWAY_LOG="${LOG_DIR}/gateway.log"
APP_LOG="${LOG_DIR}/relaykit-app.log"
DESKTOP_LOG="${LOG_DIR}/codex-desktop.log"
AX_DRIVER_SOURCE="${ROOT}/scripts/codex-desktop-ax-driver.swift"
AX_DRIVER_BINARY="${RUN_DIR}/codex-desktop-ax-driver"
AX_DRIVER_HASH_BEFORE=""
HARNESS_SNAPSHOT_HASH_BEFORE=""
SCENARIO_PATH=""
SCENARIO_HASH_BEFORE=""
AUTOMATED_CATALOG_LABELS_FILE="${RUN_DIR}/automated-model-labels.json"
AUTOMATED_STAGE_EVIDENCE="${OUT}/automated-stages.json"
AUTOMATED_SCENARIO_NORMALIZED="${RUN_DIR}/automated-scenario.json"
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
PROVIDER_TOKEN_ENV="RELAYKIT_DESKTOP_PROOF_PROVIDER_TOKEN"
PROVIDER_TOKEN_VALUE="relaykit-desktop-proof-token"
PROOF_PROVIDER_MODEL_ID="${RELAYKIT_DESKTOP_PROOF_PUBLIC_MODEL_ID:-desktop-proof-demo/claude-haiku-4-5}"
PROOF_SCOPE="fixture_plumbing_preflight"
if [[ "${MODE}" == "run-auto" || "${MODE}" == "rc1-native-responses-three-stage" ]]; then
  PROOF_INPUT_MODE="${RELAYKIT_DESKTOP_PROOF_INPUT_MODE:-automated_ax}"
else
  PROOF_INPUT_MODE="${RELAYKIT_DESKTOP_PROOF_INPUT_MODE:-manual_user_only}"
fi
APP_ZIP_SHA256=""
APP_ZIP_BUILD_TIME_UTC=""
APP_SERVER_SETUP_ID=""
APP_SERVER_SESSION_ID=""
RELAYKIT_APP_LAUNCHED=false
STARTED_AT=""
CONFIG_BEFORE=""
AUTH_BEFORE=""
CONFIG_HASH_BEFORE=""
AUTH_HASH_BEFORE=""
NOTIFY_HASH_BEFORE=""
GLOBAL_GUARD_ARMED=false
SOURCE_SNAPSHOT_HASH_BEFORE=""
HARNESS_HASH_BEFORE=""
SOURCE_GUARD_ARMED=false
HUMAN_INTERVENTION_COUNT=0
AUTO_ERROR_CODE="automated_proof_failed"
AUTOMATED_PROFILE="not_automated"
RC1_ISOLATED_AUTH_HOME=""
RC1_ISOLATED_AUTH_SOURCE=""
RC1_ISOLATED_AUTH_HASH_BEFORE=""
RC1_AUTH_LINK_CREATED=false

usage() {
  cat >&2 <<'EOF'
usage: ./scripts/codex-desktop-manual-proof.sh [run|run-auto --scenario /absolute/path/scenario.json|rc1-native-responses-three-stage --scenario /absolute/path/scenario.json|--setup-only|status|cleanup|--purge]

run          Start an extracted RelayKit App with isolated state, verify its
             gateway/login gate, then start Codex Desktop for manual requests.
run-auto     Run the same isolated proof with the PID/window-bound AX driver.
             It never waits for user input and fails closed on missing setup.
--setup-only Build/setup/verify isolated config and stop helper processes.
status       Print the latest redacted proof evidence if present.
cleanup      Stop isolated gateway/provider/Desktop processes.
--purge      Stop processes and remove the isolated DesktopProof directory.

The full run requires:
  RELAYKIT_DESKTOP_PROOF_REAL_PROVIDER_CONFIG=/absolute/path/to/local-providers.json
  RELAYKIT_DESKTOP_PROOF_PUBLIC_MODEL_ID=public/provider-model-id

The provider config must be outside tracked public files, contain only a
credential reference, and never contain an inline key or token.
EOF
}

codex_binary_from_bundle() {
  local app_bundle="$1"
  local info_plist="${app_bundle}/Contents/Info.plist"
  [[ -f "${info_plist}" ]] || return 1
  local bundle_id executable
  bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "${info_plist}" 2>/dev/null || true)"
  [[ "${bundle_id}" == "com.openai.codex" ]] || return 1
  executable="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "${info_plist}" 2>/dev/null || true)"
  [[ -n "${executable}" && -x "${app_bundle}/Contents/MacOS/${executable}" ]] || return 1
  printf '%s\n' "${app_bundle}/Contents/MacOS/${executable}"
}

resolve_codex_app_binary() {
  if [[ -n "${RELAYKIT_CODEX_APP_BINARY:-}" ]]; then
    [[ -x "${RELAYKIT_CODEX_APP_BINARY}" ]] || return 1
    printf '%s\n' "${RELAYKIT_CODEX_APP_BINARY}"
    return 0
  fi

  local app_bundle resolved
  for app_bundle in \
    "/Applications/Codex.app" \
    "/Applications/ChatGPT.app" \
    "${HOME}/Applications/Codex.app" \
    "${HOME}/Applications/ChatGPT.app"; do
    resolved="$(codex_binary_from_bundle "${app_bundle}" || true)"
    if [[ -n "${resolved}" ]]; then
      printf '%s\n' "${resolved}"
      return 0
    fi
  done

  while IFS= read -r app_bundle; do
    resolved="$(codex_binary_from_bundle "${app_bundle}" || true)"
    if [[ -n "${resolved}" ]]; then
      printf '%s\n' "${resolved}"
      return 0
    fi
  done < <(mdfind 'kMDItemCFBundleIdentifier == "com.openai.codex"' 2>/dev/null || true)
  return 1
}

codex_cli_from_desktop_binary() {
  local desktop_binary="$1"
  local app_bundle="${desktop_binary%%/Contents/MacOS/*}"
  [[ "${app_bundle}" != "${desktop_binary}" ]] || return 1
  local codex_cli="${app_bundle}/Contents/Resources/codex"
  [[ -x "${codex_cli}" ]] || return 1
  printf '%s\n' "${codex_cli}"
}

resolve_codex_cli_binary() {
  local desktop_binary
  desktop_binary="$(resolve_codex_app_binary || true)"
  [[ -n "${desktop_binary}" ]] || return 1
  codex_cli_from_desktop_binary "${desktop_binary}"
}

file_signature() {
  local path="$1"
  if [[ -e "${path}" ]]; then
    /usr/bin/stat -f "%m:%z" "${path}"
  else
    printf 'missing'
  fi
}

file_hash() {
  local path="$1"
  if [[ -e "${path}" ]]; then
    /usr/bin/shasum -a 256 "${path}" | awk '{print $1}'
  else
    printf 'missing'
  fi
}

harness_snapshot_hash() {
  local source_root="${1:-${ROOT}}"
  local manifest=""
  for path in \
    "${source_root}/scripts/codex-desktop-manual-proof.sh" \
    "${source_root}/scripts/codex-desktop-ax-driver.swift"; do
    [[ -f "${path}" ]] || {
      echo "manual proof harness input is unavailable: ${path}" >&2
      return 1
    }
    manifest+="$(file_hash "${path}")  ${path#${source_root}/}"$'\n'
  done
  printf '%s' "${manifest}" | /usr/bin/shasum -a 256 | awk '{print $1}'
}

notify_line_hash() {
  local path="$1"
  if [[ -f "${path}" ]]; then
    grep -m 1 '^notify = ' "${path}" | /usr/bin/shasum -a 256 | awk '{print $1}' || printf 'missing'
  else
    printf 'missing'
  fi
}

source_snapshot_hash() {
  local source_root="${1:-${ROOT}}"
  [[ -d "${source_root}" ]] || {
    echo "source snapshot root is unavailable" >&2
    return 1
  }
  local manifest
  manifest="$({
    cd "${source_root}"
    for entry in \
      app/Package.swift \
      app/Package.resolved \
      app/Sources \
      gateway/go.mod \
      gateway/go.sum \
      gateway/cmd \
      gateway/internal \
      script/build_app_bundle.sh \
      script/package_release.sh; do
      if [[ -d "${entry}" ]]; then
        find "${entry}" -type f -print
      elif [[ -f "${entry}" ]]; then
        printf '%s\n' "${entry}"
      fi
    done | LC_ALL=C sort -u | while IFS= read -r path; do
      printf '%s  %s\n' "$(/usr/bin/shasum -a 256 "${path}" | awk '{print $1}')" "${path}"
    done
  })"
  [[ -n "${manifest}" ]] || {
    echo "source snapshot contains no build inputs" >&2
    return 1
  }
  printf '%s\n' "${manifest}" | /usr/bin/shasum -a 256 | awk '{print $1}'
}

capture_source_state() {
  SOURCE_SNAPSHOT_HASH_BEFORE="$(source_snapshot_hash "${ROOT}")"
  HARNESS_HASH_BEFORE="$(file_hash "${ROOT}/scripts/codex-desktop-manual-proof.sh")"
  AX_DRIVER_HASH_BEFORE="$(file_hash "${AX_DRIVER_SOURCE}")"
  HARNESS_SNAPSHOT_HASH_BEFORE="$(harness_snapshot_hash "${ROOT}")"
  SOURCE_GUARD_ARMED=true
}

assert_scenario_unchanged() {
  [[ -z "${SCENARIO_PATH}" ]] && return 0
  if [[ -z "${SCENARIO_HASH_BEFORE}" || "${SCENARIO_HASH_BEFORE}" != "$(file_hash "${SCENARIO_PATH}")" ]]; then
    echo "automated proof detected a scenario change" >&2
    return 1
  fi
}

assert_product_artifact_unchanged() {
  local artifact_path="${1:-${ZIP_PATH}}"
  local expected_hash="${2:-${APP_ZIP_SHA256}}"
  if [[ -z "${expected_hash}" || "${expected_hash}" != "$(file_hash "${artifact_path}")" ]]; then
    echo "manual proof detected a product artifact change" >&2
    return 1
  fi
}

assert_source_snapshot_unchanged() {
  local source_root="${1:-${ROOT}}"
  local expected_hash="${2:-${SOURCE_SNAPSHOT_HASH_BEFORE}}"
  local current_hash
  current_hash="$(source_snapshot_hash "${source_root}")"
  if [[ -z "${expected_hash}" || "${expected_hash}" != "${current_hash}" ]]; then
    echo "manual proof detected a RelayKit source snapshot change" >&2
    return 1
  fi
}

assert_current_source_state_unchanged() {
  local changed=false
  if ! assert_source_snapshot_unchanged "${ROOT}" "${SOURCE_SNAPSHOT_HASH_BEFORE}"; then
    changed=true
  fi
  if [[ -z "${HARNESS_HASH_BEFORE}" || "${HARNESS_HASH_BEFORE}" != "$(file_hash "${ROOT}/scripts/codex-desktop-manual-proof.sh")" ]]; then
    echo "manual proof detected a harness source change" >&2
    changed=true
  fi
  if [[ "${PROOF_INPUT_MODE}" == "automated_ax" && ( -z "${AX_DRIVER_HASH_BEFORE}" || "${AX_DRIVER_HASH_BEFORE}" != "$(file_hash "${AX_DRIVER_SOURCE}")" ) ]]; then
    echo "automated proof detected an AX driver source change" >&2
    changed=true
  fi
  if [[ -z "${HARNESS_SNAPSHOT_HASH_BEFORE}" || "${HARNESS_SNAPSHOT_HASH_BEFORE}" != "$(harness_snapshot_hash "${ROOT}")" ]]; then
    echo "manual proof detected a harness snapshot change" >&2
    changed=true
  fi
  if ! assert_scenario_unchanged; then
    changed=true
  fi
  if [[ -n "${APP_ZIP_SHA256}" ]] && ! assert_product_artifact_unchanged "${ZIP_PATH}" "${APP_ZIP_SHA256}"; then
    changed=true
  fi
  [[ "${changed}" == "false" ]]
}

assert_proof_state_unchanged() {
  assert_global_state_unchanged
  assert_current_source_state_unchanged
}

port_is_free() {
  ! lsof -nP -iTCP:"$1" -sTCP:LISTEN >/dev/null 2>&1
}

free_port() {
  python3 - <<'PY'
import socket
for _ in range(100):
    sock = socket.socket()
    sock.bind(("127.0.0.1", 0))
    port = sock.getsockname()[1]
    sock.close()
    if port not in (18787, 19777):
        print(port)
        break
else:
    raise SystemExit("could not allocate a safe loopback port")
PY
}

kill_pid_file() {
  local path="$1"
  [[ -f "${path}" ]] || return 0
  local pid timeout
  pid="$(cat "${path}" 2>/dev/null || true)"
  timeout="${RELAYKIT_PROCESS_STOP_TIMEOUT:-5}"
  case "${timeout}" in
    ''|*[!0-9]*) timeout=5 ;;
  esac
  if [[ -n "${pid}" ]] && kill -0 "${pid}" 2>/dev/null; then
    kill "${pid}" >/dev/null 2>&1 || true
    local deadline=$((SECONDS + timeout))
    while kill -0 "${pid}" 2>/dev/null && (( SECONDS < deadline )); do
      sleep 0.1
    done
    if kill -0 "${pid}" 2>/dev/null; then
      kill -KILL "${pid}" >/dev/null 2>&1 || true
    fi
    wait "${pid}" >/dev/null 2>&1 || true
  fi
  rm -f "${path}" >/dev/null 2>&1 || true
}

cleanup_stale_isolated_desktop_locks() {
  local proof_root="$1" profile_dir="$2"
  local lock_entry="${profile_dir}/SingletonLock"
  local socket_entry="${profile_dir}/SingletonSocket"
  local cookie_entry="${profile_dir}/SingletonCookie"
  local lock_target lock_pid socket_target singleton_entry process_line

  [[ "${proof_root}" == /* && "${profile_dir}" == "${proof_root}/"* ]] || return 1
  [[ -d "${proof_root}" && ! -L "${proof_root}" && -d "${profile_dir}" && ! -L "${profile_dir}" ]] || return 1
  if [[ ! -e "${lock_entry}" && ! -L "${lock_entry}" &&
        ! -e "${socket_entry}" && ! -L "${socket_entry}" &&
        ! -e "${cookie_entry}" && ! -L "${cookie_entry}" ]]; then
    return 0
  fi

  for singleton_entry in "${lock_entry}" "${socket_entry}" "${cookie_entry}"; do
    [[ -L "${singleton_entry}" ]] || return 1
  done
  while IFS= read -r process_line; do
    [[ "${process_line}" == *"--user-data-dir=${profile_dir}"* ]] && return 1
  done < <(/bin/ps -axo command=)

  lock_target="$(/usr/bin/stat -f '%Y' "${lock_entry}" 2>/dev/null || true)"
  lock_pid="${lock_target##*-}"
  [[ "${lock_pid}" =~ ^[1-9][0-9]*$ ]] || return 1
  if kill -0 "${lock_pid}" 2>/dev/null; then
    return 1
  fi

  socket_target="$(/usr/bin/stat -f '%Y' "${socket_entry}" 2>/dev/null || true)"
  [[ "${socket_target}" == /* ]] || return 1
  if [[ -e "${socket_target}" ]] && /usr/sbin/lsof "${socket_target}" >/dev/null 2>&1; then
    return 1
  fi

  rm -f "${lock_entry}" "${socket_entry}" "${cookie_entry}"
}

cleanup_processes() {
  kill_pid_file "${DESKTOP_PID_FILE}"
  kill_pid_file "${APP_PID_FILE}"
  kill_pid_file "${GATEWAY_PID_FILE}"
  kill_pid_file "${PROVIDER_PID_FILE}"
  pkill -f "${BUNDLED_RELAY} -listen 127.0.0.1:$(cat "${PORT_FILE}" 2>/dev/null || printf impossible)" >/dev/null 2>&1 || true
  pkill -f -- "--user-data-dir=${DESKTOP_USER_DATA_DIR}" >/dev/null 2>&1 || true
  rm -f "${RUN_DIR}"/automated-query-*.txt >/dev/null 2>&1 || true
  rm -rf "${RUN_DIR}/extracted-app-verify" >/dev/null 2>&1 || true
}

delete_proof_keychain_items() {
  [[ -f "${PROVIDER_CONFIG}" ]] || return 0
  [[ -x "${APP_REAL_BINARY}" ]] || {
    echo "extracted RelayKit App is unavailable; refusing unsafe Keychain cleanup fallback" >&2
    return 1
  }
  while IFS= read -r service; do
    [[ -n "${service}" ]] || continue
    "${APP_REAL_BINARY}" --delete-desktop-proof-keychain "${service}" >/dev/null 2>&1 || {
      echo "RelayKit DesktopProof Keychain cleanup failed" >&2
      return 1
    }
  done < <(jq -r '.providers[]?.credential_ref.value // empty | select(startswith("relaykit.desktop-proof.provider-"))' "${PROVIDER_CONFIG}" 2>/dev/null || true)
}

ensure_dirs() {
  mkdir -p "${ISO_HOME}" "${APP_SUPPORT_DIR}" "${OFFICIAL_PROOF_ROOT}" "${APP_OFFICIAL_CODEX_HOME}" "${CODEX_HOME_DIR}" "${DESKTOP_USER_DATA_DIR}" "${LOG_DIR}" "${RUN_DIR}" "${OUT}"
  chmod 700 "${PROOF_ROOT}" "${ISO_HOME}" "${APP_SUPPORT_DIR}" "${OFFICIAL_PROOF_ROOT}" "${APP_OFFICIAL_CODEX_HOME}" "${CODEX_HOME_DIR}" "${DESKTOP_USER_DATA_DIR}" "${LOG_DIR}" "${RUN_DIR}"
}

reset_run_markers() {
  mkdir -p "${RUN_DIR}"
  printf 'not_launched\n' >"${DESKTOP_SANDBOX_STATUS_FILE}"
  rm -f "${DESKTOP_WINDOW_IDENTITY}" "${APP_WINDOW_IDENTITY}" "${TOOL_MARKER_FILE}" "${TOOL_SINCE_FILE}"
  rm -f "${RUN_DIR}"/automated-rollout-*.json "${RUN_DIR}"/ax-prepare-*.json "${RUN_DIR}"/ax-submit-*.json
  RELAYKIT_APP_LAUNCHED=false
}

copy_route_evidence() {
  local current_out="$1"
  local destination="$2"
  rm -rf "${destination}"
  mkdir -p "${destination}"
  find "${current_out}" -maxdepth 1 -type f \( -name '*.json' -o -name '*.toml' -o -name '*.png' \) -exec cp {} "${destination}/" \;
  if [[ -d "${current_out}/screenshots" ]]; then
    cp -R "${current_out}/screenshots" "${destination}/screenshots"
  fi
  date -u +"%Y-%m-%dT%H:%M:%SZ" >"${destination}/preserved-at.txt"
}

preserve_existing_route_evidence() {
  local current_out="${1:-${OUT}}"
  local last_attempt_out="${2:-${LAST_ROUTE_OUT}}"
  local last_complete_out="${3:-${LAST_COMPLETE_OUT}}"
  [[ -f "${current_out}/evidence.json" ]] || return 0
  local usage_event_count route_status desktop_gui_route_proof
  usage_event_count="$(jq -r '.usage_event_count // 0' "${current_out}/evidence.json" 2>/dev/null || printf 0)"
  case "${usage_event_count}" in
    ''|*[!0-9]*) usage_event_count=0 ;;
  esac
  [[ "${usage_event_count}" -gt 0 ]] || return 0
  copy_route_evidence "${current_out}" "${last_attempt_out}"
  route_status="$(jq -r '.route_proof_status // ""' "${current_out}/evidence.json" 2>/dev/null || true)"
  desktop_gui_route_proof="$(jq -r '.desktop_gui_route_proof // ""' "${current_out}/evidence.json" 2>/dev/null || true)"
  if [[ "${route_status}" == "complete" &&
        ( "${desktop_gui_route_proof}" == "manual_user_assisted_complete" ||
          "${desktop_gui_route_proof}" == "automated_gui_complete" ) ]]; then
    copy_route_evidence "${current_out}" "${last_complete_out}"
  fi
}

write_desktop_sandbox_profile() {
  local output_path="${1:-${DESKTOP_SANDBOX_PROFILE}}"
  cat >"${output_path}" <<EOF
(version 1)
(allow default)
(deny file-write* (literal "${GLOBAL_CODEX_CONFIG}"))
(deny file-write* (literal "${GLOBAL_CODEX_AUTH}"))
(deny file-write* (subpath "${GLOBAL_CODEX_STATE_DIR}"))
(deny file-write* (subpath "${GLOBAL_CODEX_APP_SUPPORT_DIR}"))
(deny file-write* (subpath "${GLOBAL_OPENAI_APP_SUPPORT_DIR}"))
(deny file-write* (subpath "${GLOBAL_CODEX_BUNDLE_SUPPORT_DIR}"))
(deny file-write* (literal "${GLOBAL_CODEX_PREFERENCES}"))
(deny file-write* (literal "${GLOBAL_CUA_CLI_PREFERENCES}"))
(deny file-write* (literal "${GLOBAL_CUA_PREFERENCES}"))
(deny file-write* (subpath "${REAL_HOME}/Library/LaunchAgents"))
(deny file-write* (subpath "${REAL_HOME}/.config/agent-local-gateway"))
EOF
  if [[ "${RC1_AUTH_LINK_CREATED}" == "true" ]]; then
    cat >>"${output_path}" <<EOF
(deny file-write* (literal "${CODEX_HOME_DIR}/auth.json"))
(deny file-write* (literal "${RC1_ISOLATED_AUTH_SOURCE}"))
EOF
  fi
}

resolve_rc1_isolated_auth_home() {
  local candidate="${1:-}" resolved auth_path auth_mode
  [[ "${candidate}" == /* && -d "${candidate}" && ! -L "${candidate}" ]] || return 1
  resolved="$(cd "${candidate}" && pwd -P)" || return 1
  case "${resolved}" in
    "${REAL_HOME}/Library/Application Support/RelayKit/DesktopProof/official-proof/codex-home"|"${REAL_HOME}/Library/Application Support/RelayKit/OfficialProof/codex-home") ;;
    *) return 1 ;;
  esac
  auth_path="${resolved}/auth.json"
  [[ -f "${auth_path}" && ! -L "${auth_path}" ]] || return 1
  auth_mode="$(stat -f %Lp "${auth_path}" 2>/dev/null || true)"
  [[ "${auth_mode}" == "600" ]] || return 1
  printf '%s\n' "${resolved}"
}

rc1_isolated_auth_status() {
  local auth_home="$1" cli_binary="$2" resolved auth_path auth_hash_before auth_status
  resolved="$(resolve_rc1_isolated_auth_home "${auth_home}")" || return 1
  [[ "${cli_binary}" == /* && -f "${cli_binary}" && ! -L "${cli_binary}" && -x "${cli_binary}" ]] || return 1
  auth_path="${resolved}/auth.json"
  auth_hash_before="$(file_hash "${auth_path}")"
  [[ "${auth_hash_before}" != "missing" ]] || return 1
  auth_status="$(CODEX_HOME="${resolved}" "${cli_binary}" login status 2>&1)" || return 1
  [[ "${auth_status}" == "Logged in using ChatGPT" ]] || return 1
  [[ "$(file_hash "${auth_path}")" == "${auth_hash_before}" ]]
}

create_rc1_isolated_auth_link() {
  local source_home="$1" destination_home="$2" resolved source_path destination_path source_hash
  resolved="$(resolve_rc1_isolated_auth_home "${source_home}")" || return 1
  source_path="${resolved}/auth.json"
  destination_path="${destination_home}/auth.json"
  mkdir -p "${destination_home}"
  [[ ! -e "${destination_path}" && ! -L "${destination_path}" ]] || return 1
  source_hash="$(file_hash "${source_path}")"
  [[ "${source_hash}" != "missing" ]] || return 1
  ln -s "${source_path}" "${destination_path}" || return 1
  if [[ ! -L "${destination_path}" || "$(readlink "${destination_path}")" != "${source_path}" ||
        "$(file_hash "${source_path}")" != "${source_hash}" ]]; then
    rm -f "${destination_path}"
    return 1
  fi
  RC1_ISOLATED_AUTH_HOME="${resolved}"
  RC1_ISOLATED_AUTH_SOURCE="${source_path}"
  RC1_ISOLATED_AUTH_HASH_BEFORE="${source_hash}"
  RC1_AUTH_LINK_CREATED=true
}

remove_rc1_isolated_auth_link() {
  [[ "${RC1_AUTH_LINK_CREATED}" == "true" ]] || return 0
  local destination_path="${CODEX_HOME_DIR}/auth.json"
  if [[ ! -L "${destination_path}" || "$(readlink "${destination_path}")" != "${RC1_ISOLATED_AUTH_SOURCE}" ]]; then
    echo "RC1 isolated auth link changed unexpectedly" >&2
    return 1
  fi
  if [[ "$(file_hash "${RC1_ISOLATED_AUTH_SOURCE}")" != "${RC1_ISOLATED_AUTH_HASH_BEFORE}" ]]; then
    echo "RC1 isolated auth source changed during proof" >&2
    return 1
  fi
  rm -f "${destination_path}" || return 1
  RC1_AUTH_LINK_CREATED=false
  RC1_ISOLATED_AUTH_SOURCE=""
  RC1_ISOLATED_AUTH_HASH_BEFORE=""
}

capture_global_state() {
  CONFIG_BEFORE="$(file_signature "${GLOBAL_CODEX_CONFIG}")"
  AUTH_BEFORE="$(file_signature "${GLOBAL_CODEX_AUTH}")"
  CONFIG_HASH_BEFORE="$(file_hash "${GLOBAL_CODEX_CONFIG}")"
  AUTH_HASH_BEFORE="$(file_hash "${GLOBAL_CODEX_AUTH}")"
  NOTIFY_HASH_BEFORE="$(notify_line_hash "${GLOBAL_CODEX_CONFIG}")"
  GLOBAL_GUARD_ARMED=true
}

assert_global_state_unchanged() {
  local config_after auth_after config_hash_after auth_hash_after notify_hash_after
  config_after="$(file_signature "${GLOBAL_CODEX_CONFIG}")"
  auth_after="$(file_signature "${GLOBAL_CODEX_AUTH}")"
  config_hash_after="$(file_hash "${GLOBAL_CODEX_CONFIG}")"
  auth_hash_after="$(file_hash "${GLOBAL_CODEX_AUTH}")"
  notify_hash_after="$(notify_line_hash "${GLOBAL_CODEX_CONFIG}")"

  local changed=false
  if [[ "${CONFIG_BEFORE}" != "${config_after}" ]]; then
    echo "manual proof detected a global Codex config signature change" >&2
    changed=true
  fi
  if [[ "${AUTH_BEFORE}" != "${auth_after}" ]]; then
    echo "manual proof detected a global Codex auth signature change" >&2
    changed=true
  fi
  if [[ "${CONFIG_HASH_BEFORE}" != "${config_hash_after}" ]]; then
    echo "manual proof detected a global Codex config content change" >&2
    changed=true
  fi
  if [[ "${AUTH_HASH_BEFORE}" != "${auth_hash_after}" ]]; then
    echo "manual proof detected a global Codex auth content change" >&2
    changed=true
  fi
  if [[ "${NOTIFY_HASH_BEFORE}" != "${notify_hash_after}" ]]; then
    echo "manual proof detected a global Codex notify change" >&2
    changed=true
  fi
  [[ "${changed}" == "false" ]]
}

cleanup_and_verify_global_state() {
  local exit_status=$?
  trap - EXIT
  cleanup_processes
  if [[ "${GLOBAL_GUARD_ARMED}" == "true" ]] && ! assert_global_state_unchanged; then
    exit_status=1
  fi
  if [[ "${SOURCE_GUARD_ARMED}" == "true" ]] && ! assert_current_source_state_unchanged; then
    exit_status=1
  fi
  exit "${exit_status}"
}

cleanup_automated_run() {
  local exit_status=$?
  trap - EXIT
  cleanup_processes
  if [[ "${GLOBAL_GUARD_ARMED}" == "true" ]] && ! assert_global_state_unchanged; then
    AUTO_ERROR_CODE="global_state_changed"
    exit_status=1
  fi
  if [[ "${SOURCE_GUARD_ARMED}" == "true" ]] && ! assert_current_source_state_unchanged; then
    AUTO_ERROR_CODE="source_state_changed"
    exit_status=1
  fi
  if [[ "${exit_status}" -ne 0 ]]; then
    if [[ -n "${CONFIG_BEFORE}" && -f "${OUT}/app-server.json" ]]; then
      write_evidence "route_incomplete" "${AUTO_ERROR_CODE}" "${CONFIG_BEFORE}" "${AUTH_BEFORE}" "${CONFIG_HASH_BEFORE}" "${AUTH_HASH_BEFORE}" "${NOTIFY_HASH_BEFORE}" || true
      preserve_existing_route_evidence "${OUT}" "${LAST_ROUTE_OUT}" "${LAST_COMPLETE_OUT}" || true
    fi
    jq -n --arg error_code "${AUTO_ERROR_CODE}" --arg evidence "${OUT}/evidence.json" '{status:"failed",error_code:$error_code,evidence:$evidence,human_intervention_count:0}' >&2 || true
  fi
  exit "${exit_status}"
}

handle_automated_signal() {
  AUTO_ERROR_CODE="automated_proof_interrupted"
  exit 130
}

require_sandbox_policy() {
  if [[ "${RELAYKIT_DESKTOP_PROOF_USE_SANDBOX:-1}" != "1" ]]; then
    echo "unsandboxed Codex Desktop proof is disabled; refusing to continue" >&2
    return 1
  fi
  if [[ ! -x /usr/bin/sandbox-exec ]]; then
    echo "sandbox-exec is unavailable; refusing to launch Codex Desktop" >&2
    return 1
  fi
}

validate_input_mode() {
  case "${PROOF_INPUT_MODE}" in
    manual_user_only|isolated_codex_cli_fallback|automated_ax) return 0 ;;
    *)
      echo "unsupported Desktop proof input mode: ${PROOF_INPUT_MODE}" >&2
      return 1
      ;;
  esac
}

validate_automated_input_mode() {
  if [[ "${PROOF_INPUT_MODE}" != "automated_ax" ]]; then
    echo "run-auto requires RELAYKIT_DESKTOP_PROOF_INPUT_MODE=automated_ax" >&2
    return 1
  fi
}

validate_auto_scenario() {
  local scenario_path="$1"
  python3 - "${scenario_path}" <<'PY'
import json
import os
import re
import stat
import sys
from pathlib import Path

path = Path(sys.argv[1])
try:
    metadata = path.lstat()
except OSError:
    raise SystemExit("scenario must be an absolute regular file")
if not path.is_absolute() or not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != os.getuid():
    raise SystemExit("scenario must be an absolute regular file")
if stat.S_IMODE(metadata.st_mode) != 0o600:
    raise SystemExit("scenario file must have mode 0600")
try:
    value = json.loads(path.read_text())
except (OSError, json.JSONDecodeError) as error:
    raise SystemExit(f"invalid scenario JSON: {error}")
if not isinstance(value, dict) or set(value) - {"version", "stages", "stage_timeout_seconds"}:
    raise SystemExit("scenario contains unknown top-level fields")
if value.get("version") != 1:
    raise SystemExit("scenario version must be 1")
stages = value.get("stages")
if not isinstance(stages, list) or not 1 <= len(stages) <= 8:
    raise SystemExit("scenario must contain between 1 and 8 stages")
timeout = value.get("stage_timeout_seconds", 300)
if not isinstance(timeout, int) or not 10 <= timeout <= 900:
    raise SystemExit("stage_timeout_seconds must be between 10 and 900")
allowed = {"id", "model_id", "model_label", "query_file", "response_marker", "evidence_role", "expect"}
ids = set()
roles = set()
normalized = []
for index, stage in enumerate(stages):
    if not isinstance(stage, dict) or set(stage) != allowed:
        raise SystemExit(f"stage {index} fields do not match the v1 contract")
    stage_id = stage["id"]
    if not isinstance(stage_id, str) or re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9-]{0,63}", stage_id) is None:
        raise SystemExit(f"stage {index} id is invalid")
    if stage_id in ids:
        raise SystemExit("stage ids must be unique")
    ids.add(stage_id)
    role = stage["evidence_role"]
    if not isinstance(role, str) or re.fullmatch(r"[a-z0-9][a-z0-9-]{0,63}", role) is None:
        raise SystemExit(f"stage {index} evidence_role is invalid")
    if role in roles:
        raise SystemExit("evidence roles must be unique")
    roles.add(role)
    for field in ("model_id", "model_label", "response_marker"):
        field_value = stage[field]
        if not isinstance(field_value, str) or not field_value.strip() or len(field_value) > 256:
            raise SystemExit(f"stage {index} {field} is invalid")
    dynamic_model_id = stage["model_id"] == "@current-official"
    dynamic_model_label = stage["model_label"] == "@current-official"
    if dynamic_model_id != dynamic_model_label:
        raise SystemExit(f"stage {index} dynamic model fields must both be @current-official")
    if stage["expect"] not in {"plain", "markdown", "tool"}:
        raise SystemExit(f"stage {index} expectation is invalid")
    query_path = Path(stage["query_file"])
    try:
        query_metadata = query_path.lstat()
    except OSError:
        raise SystemExit(f"stage {index} query_file must be an absolute regular file")
    if not query_path.is_absolute() or not stat.S_ISREG(query_metadata.st_mode) or query_metadata.st_uid != os.getuid():
        raise SystemExit(f"stage {index} query_file must be an absolute regular file")
    if stat.S_IMODE(query_metadata.st_mode) != 0o600:
        raise SystemExit(f"stage {index} query_file must have mode 0600")
    if query_metadata.st_size == 0 or query_metadata.st_size > 65536:
        raise SystemExit(f"stage {index} query_file size is invalid")
    normalized.append({key: stage[key] for key in sorted(allowed)})
print(json.dumps({"version": 1, "stage_timeout_seconds": timeout, "stages": normalized}, sort_keys=True))
PY
}

validate_postbinding_query_content() {
  local query_path="$1"
  local marker="$2"
  local expectation="$3"
  python3 - "${query_path}" "${marker}" "${expectation}" <<'PY'
import sys
from pathlib import Path

query_path = Path(sys.argv[1])
marker = sys.argv[2]
expectation = sys.argv[3]
try:
    query_text = query_path.read_text()
except (OSError, UnicodeDecodeError):
    raise SystemExit("query file must contain UTF-8 text")
if marker not in query_text:
    raise SystemExit("query file must contain its response marker")
if expectation == "markdown":
    required_markdown = (
        "## RelayKit Rich Text Check",
        "1. First route check",
        "2. Second route check",
        "| status | route |",
        "| ready | official |",
        "| ready | provider |",
        "```bash",
        "echo relaykit",
        "**RELAYKIT_FORMAT_OK**",
    )
    if any(fragment not in query_text for fragment in required_markdown):
        raise SystemExit("markdown query does not declare the required render contract")
elif expectation == "tool":
    if "printf" not in query_text:
        raise SystemExit("tool query must declare the marker through printf")
elif expectation != "plain":
    raise SystemExit("query expectation is invalid")
PY
}

copy_bound_query() {
  local source_path="$1"
  local copy_path="$2"
  local source_hash_before source_hash_after copy_hash
  source_hash_before="$(file_hash "${source_path}")"
  cp "${source_path}" "${copy_path}" || return 1
  chmod 600 "${copy_path}" || return 1
  source_hash_after="$(file_hash "${source_path}")"
  copy_hash="$(file_hash "${copy_path}")"
  if [[ "${source_hash_before}" == "missing" ||
        "${source_hash_before}" != "${source_hash_after}" ||
        "${source_hash_before}" != "${copy_hash}" ]]; then
    rm -f "${copy_path}"
    return 1
  fi
  printf '%s\n' "${copy_hash}"
}

prepare_automated_provider_inputs() {
  local scenario_path="$1"
  local scenario_provider_model default_config
  scenario_provider_model="$(jq -r '[.stages[] | select(.expect == "markdown" or .expect == "tool") | .model_id] | unique | if length == 1 then .[0] else "" end' "${scenario_path}")" || return 1
  if [[ -z "${RELAYKIT_DESKTOP_PROOF_PUBLIC_MODEL_ID:-}" && -n "${scenario_provider_model}" ]]; then
    RELAYKIT_DESKTOP_PROOF_PUBLIC_MODEL_ID="${scenario_provider_model}"
  fi
  if [[ -n "${scenario_provider_model}" && "${RELAYKIT_DESKTOP_PROOF_PUBLIC_MODEL_ID:-}" != "${scenario_provider_model}" ]]; then
    echo "automated provider stages must use the configured public provider model" >&2
    return 1
  fi
  default_config="${PROOF_ROOT}/real-provider-input.json"
  if [[ -z "${RELAYKIT_DESKTOP_PROOF_REAL_PROVIDER_CONFIG:-}" && -f "${default_config}" ]]; then
    RELAYKIT_DESKTOP_PROOF_REAL_PROVIDER_CONFIG="${default_config}"
  fi
  [[ -n "${RELAYKIT_DESKTOP_PROOF_REAL_PROVIDER_CONFIG:-}" && -n "${RELAYKIT_DESKTOP_PROOF_PUBLIC_MODEL_ID:-}" ]] || {
    echo "automated proof requires a local real-provider config and a public provider model" >&2
    return 1
  }
}

automated_profile_for_scenario() {
  local scenario_path="$1"
  local provider_model="$2"
  jq -r --arg provider_model "${provider_model}" '
    .stages as $stages
    | def has_stage($role; $expect; $model):
        any($stages[]; .evidence_role == $role and .expect == $expect and .model_id == $model);
      if ($stages | length) == 4
         and ($provider_model | length) > 0
         and has_stage("gpt55-response"; "plain"; "gpt-5.5")
         and has_stage("gpt56-response"; "plain"; "gpt-5.6-luna")
         and has_stage("provider-markdown"; "markdown"; $provider_model)
         and has_stage("provider-tool"; "tool"; $provider_model)
      then "standard_four_stage_dogfood"
      elif ($stages | length) == 3
         and ($provider_model | length) > 0
         and ([ $stages[].id ] == ["A", "B", "C"])
         and all($stages[]; .model_id == $provider_model)
         and ($stages[0].evidence_role == "rc1-text" and $stages[0].expect == "plain")
         and ($stages[1].evidence_role == "rc1-markdown" and $stages[1].expect == "markdown")
         and ($stages[2].evidence_role == "rc1-tool" and $stages[2].expect == "tool")
      then "rc1_native_responses_three_stage"
      elif ($stages | length) == 1
         and ($provider_model | length) > 0
         and $stages[0].expect == "tool"
         and $stages[0].model_id == $provider_model
      then "single_tool_scenario"
      else "custom_scenario"
      end
  ' "${scenario_path}"
}

resolve_automated_model_label() {
  local app_server_path="$1"
  local model_id="$2"
  jq -er --arg model "${model_id}" '
    [.official[]?, .provider[]?]
    | map(select(.model == $model and (.displayName | type) == "string" and (.displayName | length) > 0))
    | if length == 1 then .[0].displayName else empty end
  ' "${app_server_path}"
}

resolve_automated_scenario_models() {
  local scenario_path="$1"
  local app_server_path="$2"
  python3 - "${scenario_path}" "${app_server_path}" <<'PY'
import json
import sys
from collections import Counter
from pathlib import Path

scenario_path = Path(sys.argv[1])
app_server_path = Path(sys.argv[2])

try:
    scenario = json.loads(scenario_path.read_text())
    app_server = json.loads(app_server_path.read_text())
except (OSError, json.JSONDecodeError):
    raise SystemExit("current_official_catalog_invalid")

stages = scenario.get("stages")
if not isinstance(stages, list):
    raise SystemExit("scenario_invalid")

dynamic_stages = [
    stage for stage in stages
    if stage.get("model_id") == "@current-official"
    and stage.get("model_label") == "@current-official"
]

current_official = None
if dynamic_stages:
    official = app_server.get("official")
    if not isinstance(official, list):
        raise SystemExit("current_official_catalog_invalid")
    visible = []
    for item in official:
        if not isinstance(item, dict):
            raise SystemExit("current_official_catalog_invalid")
        hidden = item.get("hidden", False)
        if not isinstance(hidden, bool):
            raise SystemExit("current_official_catalog_invalid")
        if hidden:
            continue
        model = item.get("model")
        label = item.get("displayName")
        if not isinstance(model, str) or not model.strip() or not isinstance(label, str) or not label.strip():
            raise SystemExit("current_official_catalog_invalid")
        visible.append((model.strip(), label.strip()))
    if not visible:
        raise SystemExit("current_official_catalog_empty")
    duplicates = [model for model, count in Counter(model for model, _ in visible).items() if count > 1]
    if duplicates:
        raise SystemExit("current_official_model_duplicate")
    current_official = visible[0]

catalog = []
for section in ("official", "provider"):
    items = app_server.get(section, [])
    if not isinstance(items, list):
        raise SystemExit("model_label_resolution_failed")
    catalog.extend(item for item in items if isinstance(item, dict))

resolved = []
for stage in stages:
    stage = dict(stage)
    if stage.get("model_id") == "@current-official":
        if stage.get("model_label") != "@current-official" or current_official is None:
            raise SystemExit("scenario_invalid")
        stage["model_id"], stage["model_label"] = current_official
    else:
        model_id = stage.get("model_id")
        labels = [
            item.get("displayName").strip()
            for item in catalog
            if item.get("model") == model_id
            and isinstance(item.get("displayName"), str)
            and item.get("displayName").strip()
        ]
        if len(labels) != 1:
            raise SystemExit("model_label_resolution_failed")
        stage["model_label"] = labels[0]
    resolved.append(stage)

scenario["stages"] = resolved
print(json.dumps(scenario, sort_keys=True))
PY
}

automated_stages_complete() {
  local stages_path="$1"
  local expected_count="$2"
  jq -e --argjson expected "${expected_count}" '
    length == $expected
    and all(.[];
      .state == "evidence_verified"
      and .submission_state == "submitted"
      and (.rollout_binding.proof_found // false) == true
      and (.rollout_binding.thread_id | type) == "string"
      and (.rollout_binding.thread_id | length) > 0
      and (.rollout_binding.user_marker_count // 0) == 1
      and (.rollout_binding.assistant_marker_count // 0) == 1
    )
    and ([.[].id] | unique | length) == $expected
    and ([.[].evidence_role] | unique | length) == $expected
    and ([.[].rollout_binding.thread_id] | unique | length) == $expected
  ' "${stages_path}" >/dev/null
}

custom_tool_scenario_complete() {
  local stages_path="$1"
  local expected_count="$2"
  local tool_evidence="$3"
  local screenshot_evidence="$4"
  [[ "${expected_count}" == "1" ]] || return 1
  automated_stages_complete "${stages_path}" "${expected_count}" || return 1
  local evidence_role
  evidence_role="$(jq -er 'if length == 1 and .[0].expect == "tool" then .[0].evidence_role else empty end' "${stages_path}")" || return 1
  jq -e '
    .proof_found == true
    and .function_call_found == true
    and .function_call_output_found == true
    and .process_exited_zero == true
    and .xml_leak_found == false
    and .raw_function_calls_found == false
  ' "${tool_evidence}" >/dev/null || return 1
  jq -e --arg role "${evidence_role}" '
    ([.[] | select(.role == $role)] | last) as $shot
    | $shot.captured == true
    and $shot.target_identity_verified == true
    and $shot.visual_checks.tool_marker_visible == true
    and $shot.visual_checks.tool_execution_visible == true
    and $shot.visual_checks.raw_protocol_visible == false
  ' "${screenshot_evidence}" >/dev/null
}

driver_failure_code() {
  local report_path="$1"
  local fallback="$2"
  local code
  code="$(jq -r '.code // empty' "${report_path}" 2>/dev/null || true)"
  if [[ "${code}" =~ ^[a-z0-9_]+$ ]]; then
    printf '%s\n' "${code}"
  else
    printf '%s\n' "${fallback}"
  fi
}

desktop_gui_tool_ui_review_status() {
  local input_mode="$1"
  local tool_proof_found="$2"
  local tool_gui_verified="$3"
  if [[ "${tool_proof_found}" != "true" ]]; then
    printf 'not_verified\n'
  elif [[ "${tool_gui_verified}" == "true" && ( "${input_mode}" == "manual_user_only" || "${input_mode}" == "automated_ax" ) ]]; then
    printf 'derived_from_current_run_rollout_and_process_bound_screenshot\n'
  else
    printf 'rollout_verified_gui_display_not_verified\n'
  fi
}

fresh_stage_usage() {
  local usage_file="$1"
  local baseline_count="$2"
  local model_id="$3"
  case "${baseline_count}" in
    ''|*[!0-9]*) return 2 ;;
  esac
  jq -e --argjson baseline "${baseline_count}" --arg model "${model_id}" '
    [.[$baseline:][] | select((.model // "") == $model)] as $events
    | if ($events | length) >= 1
         and all($events[]; (.status // "") == "completed" and (.http_status // 0) == 200)
      then {
        model: $model,
        status: "completed",
        http_status: 200,
        event_count: ($events | length)
      }
      else empty
      end
  ' "${usage_file}"
}

write_automated_rollout_binding() {
  local codex_home="$1"
  local since_epoch="$2"
  local model_id="$3"
  local marker="$4"
  local output="$5"
  python3 - "${codex_home}" "${since_epoch}" "${model_id}" "${marker}" "${output}" <<'PY'
import json
import sys
from datetime import datetime
from pathlib import Path

sessions_root = Path(sys.argv[1]) / "sessions"
since_epoch = float(sys.argv[2] or 0)
expected_model = sys.argv[3]
marker = sys.argv[4]
output = Path(sys.argv[5])

def parse_ts(value):
    if not value:
        return 0.0
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp()
    except ValueError:
        return 0.0

def message_text(value):
    if isinstance(value, str):
        return value
    if isinstance(value, list):
        return "\n".join(message_text(item) for item in value)
    if isinstance(value, dict):
        if isinstance(value.get("text"), str):
            return value["text"]
        return "\n".join(message_text(value.get(key)) for key in ("content", "input_text", "output_text") if key in value)
    return ""

candidates = []
for path in sorted(sessions_root.glob("**/rollout-*.jsonl")):
    thread_id = ""
    current_model = ""
    user_marker_count = 0
    assistant_marker_count = 0
    user_marker_models = []
    try:
        lines = path.read_text(errors="replace").splitlines()
    except OSError:
        continue
    records = []
    for line in lines:
        if not line.strip():
            continue
        try:
            records.append(json.loads(line))
        except json.JSONDecodeError:
            continue
    for record in records:
        payload = record.get("payload") or {}
        record_type = record.get("type")
        if record_type == "session_meta":
            thread_id = payload.get("id") or payload.get("thread_id") or thread_id
            continue
        if record_type == "turn_context":
            current_model = payload.get("model") or current_model
            continue
        if record_type != "response_item":
            continue
        event_epoch = parse_ts(record.get("timestamp"))
        if since_epoch and (not event_epoch or event_epoch < since_epoch):
            continue
        if payload.get("type") != "message":
            continue
        text = message_text(payload.get("content") or payload.get("text") or "")
        if marker not in text:
            continue
        if payload.get("role") == "user":
            user_marker_count += 1
            if isinstance(current_model, str) and current_model.strip():
                user_marker_models.append(current_model.strip())
        elif payload.get("role") == "assistant":
            assistant_marker_count += 1
    marker_models = sorted(set(user_marker_models))
    if user_marker_count == 1 and len(marker_models) == 1:
        candidates.append({
            "session_file": str(path.relative_to(sessions_root)),
            "thread_id": thread_id or None,
            "model": marker_models[0],
            "user_marker_found": True,
            "assistant_marker_found": assistant_marker_count == 1,
            "user_marker_count": user_marker_count,
            "assistant_marker_count": assistant_marker_count,
        })

proof_found = len(candidates) == 1
result = {
    "proof_found": proof_found,
    "candidate_count": len(candidates),
    "binding_status": "bound" if proof_found else ("rollout_not_found" if len(candidates) == 0 else "rollout_not_unique"),
    "session_file": candidates[0]["session_file"] if proof_found else None,
    "thread_id": candidates[0]["thread_id"] if proof_found else None,
    "model": candidates[0]["model"] if proof_found else None,
    "expected_model": expected_model,
    "user_marker_found": proof_found,
    "assistant_marker_found": candidates[0]["assistant_marker_found"] if proof_found else False,
    "user_marker_count": candidates[0]["user_marker_count"] if proof_found else 0,
    "assistant_marker_count": candidates[0]["assistant_marker_count"] if proof_found else 0,
}

output.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
raise SystemExit(0 if proof_found else 1)
PY
}

submitted_model_selection_matches() {
  local binding_file="$1"
  local expected_model="$2"
  jq -e --arg expected "${expected_model}" '
    .proof_found == true
    and .candidate_count == 1
    and (.model | type) == "string"
    and .model == $expected
  ' "${binding_file}" >/dev/null
}

fresh_completed_stage_usage() {
  local usage_file="$1"
  local baseline_count="$2"
  case "${baseline_count}" in
    ''|*[!0-9]*) return 2 ;;
  esac
  jq -e --argjson baseline "${baseline_count}" '
    [.[$baseline:][] | select((.status // "") == "completed" and (.http_status // 0) == 200)] as $events
    | ($events | map(.model // "") | unique) as $models
    | if ($events | length) == 0 then empty
      else {
        model: (if ($models | length) == 1 and ($models[0] | type) == "string" and ($models[0] | length) > 0 then $models[0] else null end),
        event_count: ($events | length),
        model_count: ($models | length),
        status: "completed",
        http_status: 200
      }
      end
  ' "${usage_file}"
}

submitted_model_usage_matches() {
  local usage_file="$1"
  local baseline_count="$2"
  local binding_file="$3"
  local usage_json usage_model bound_model
  usage_json="$(fresh_completed_stage_usage "${usage_file}" "${baseline_count}")" || return $?
  usage_model="$(jq -r '.model // empty' <<<"${usage_json}")"
  bound_model="$(jq -er '.model | select(type == "string" and length > 0)' "${binding_file}")" || return 6
  [[ -n "${usage_model}" && "${usage_model}" == "${bound_model}" ]] || return 5
  printf '%s\n' "${usage_json}"
}

wait_for_submitted_rollout_binding() {
  local codex_home="$1"
  local since_epoch="$2"
  local expected_model="$3"
  local marker="$4"
  local output="$5"
  local timeout_seconds="$6"
  local deadline=$((SECONDS + timeout_seconds))
  local binding_status
  while (( SECONDS < deadline )); do
    if write_automated_rollout_binding "${codex_home}" "${since_epoch}" "${expected_model}" "${marker}" "${output}"; then
      return 0
    fi
    binding_status="$(jq -r '.binding_status // "rollout_not_found"' "${output}" 2>/dev/null || printf 'rollout_not_found')"
    [[ "${binding_status}" == "rollout_not_found" ]] || return 2
    sleep 1
  done
  return 3
}

scenario_argument() {
  [[ "${2:-}" == "--scenario" && -n "${3:-}" && -z "${4:-}" ]] || {
    echo "run-auto requires exactly --scenario /absolute/path/scenario.json" >&2
    return 2
  }
  printf '%s\n' "$3"
}

start_provider() {
  local provider_port="$1"
  rm -f "${PROVIDER_EVENTS}"
  RELAYKIT_PROVIDER_EVENTS="${PROVIDER_EVENTS}" \
  RELAYKIT_PROVIDER_TOKEN="${PROVIDER_TOKEN_VALUE}" \
  node - "${provider_port}" >"${PROVIDER_LOG}" 2>&1 <<'NODE' &
const fs = require("fs");
const http = require("http");

const port = Number(process.argv[2]);
const events = process.env.RELAYKIT_PROVIDER_EVENTS;
const token = process.env.RELAYKIT_PROVIDER_TOKEN;

function append(event) {
  fs.appendFileSync(events, JSON.stringify({...event, timestamp: new Date().toISOString()}) + "\n");
}

function readJSON(req) {
  return new Promise((resolve, reject) => {
    let body = "";
    req.on("data", chunk => { body += chunk; });
    req.on("end", () => {
      try { resolve(JSON.parse(body || "{}")); } catch (error) { reject(error); }
    });
    req.on("error", reject);
  });
}

const server = http.createServer(async (req, res) => {
  if (req.method === "GET" && req.url === "/healthz") {
    res.writeHead(200, {"Content-Type": "application/json"}).end(JSON.stringify({status: "ok"}));
    return;
  }
  if (req.method === "GET" && req.url === "/v1/models") {
    res.writeHead(200, {"Content-Type": "application/json"}).end(JSON.stringify({
      object: "list",
      data: [{id: "provider-upstream", object: "model", owned_by: "demo"}]
    }));
    return;
  }
  if (req.method !== "POST" || req.url !== "/chat/completions") {
    res.writeHead(404).end();
    return;
  }
  const body = await readJSON(req);
  const authorized = req.headers["x-api-key"] === token;
  append({route: "fixture_plumbing_only", model: body.model, provider_auth_present: authorized});
  res.writeHead(409, {"Content-Type": "application/json"}).end(JSON.stringify({
    error: {code: "fixture_plumbing_only", message: "Public fixture does not provide route proof."}
  }));
});

server.listen(port, "127.0.0.1");
process.on("SIGTERM", () => server.close(() => process.exit(0)));
setInterval(() => {}, 1000);
NODE
  echo "$!" >"${PROVIDER_PID_FILE}"
  for _ in {1..40}; do
    curl -fsS "http://127.0.0.1:${provider_port}/healthz" >/dev/null 2>&1 && return 0
    sleep 0.1
  done
  echo "provider fixture did not start" >&2
  exit 1
}

write_provider_config() {
  local provider_port="$1"
  cat >"${PROVIDER_CONFIG}" <<JSON
{
  "official_passthrough": {
    "base_url": "https://api.openai.example/v1",
    "credential_ref": { "kind": "codex_home", "value": "${CODEX_HOME_DIR}" },
    "codex_binary": "codex",
    "models": [
      { "id": "gpt-5.5", "display_name": "GPT-5.5" }
    ]
  },
  "providers": [
    {
      "id": "desktop-proof-demo",
      "name": "Desktop Proof Demo",
      "base_url": "http://127.0.0.1:${provider_port}",
      "api_format": "openai_chat",
      "credential_ref": { "kind": "env", "value": "${PROVIDER_TOKEN_ENV}", "header": "x-api-key" },
      "routing": { "source": "desktop-proof-demo", "model_prefix": "desktop-proof-demo/", "priority": 100, "status": "enabled", "visible": true },
      "models": [
        { "id": "desktop-proof-demo/claude-haiku-4-5", "display_name": "Desktop Proof Demo Haiku 4.5", "upstream_model": "provider-upstream" }
      ]
    }
  ]
}
JSON
}

validate_real_provider_policy() {
  local source_config="${RELAYKIT_DESKTOP_PROOF_REAL_PROVIDER_CONFIG:-}"
  local public_model="${RELAYKIT_DESKTOP_PROOF_PUBLIC_MODEL_ID:-}"
  if [[ -z "${source_config}" || ! -f "${source_config}" ]]; then
    echo "real route requires RELAYKIT_DESKTOP_PROOF_REAL_PROVIDER_CONFIG" >&2
    return 1
  fi
  if [[ -z "${public_model}" ]]; then
    echo "real route requires RELAYKIT_DESKTOP_PROOF_PUBLIC_MODEL_ID" >&2
    return 1
  fi
  if [[ "${source_config}" == "${ROOT}"/* ]]; then
    local relative_path="${source_config#${ROOT}/}"
    if git -C "${ROOT}" ls-files --error-unmatch "${relative_path}" >/dev/null 2>&1; then
      echo "real provider config must be ignored or stored outside the repository" >&2
      return 1
    fi
  fi
  if ! jq -e --arg model "${public_model}" '
    (.providers | type == "array" and length > 0) and
    any(.providers[]; any(.models[]?; (.id // "") == $model)) and
    ([.. | objects | to_entries[] | select((.key | ascii_downcase) == "api_key" or (.key | ascii_downcase) == "token" or (.key | ascii_downcase) == "authorization")] | length) == 0
  ' "${source_config}" >/dev/null 2>&1; then
    echo "real provider config is invalid, contains an inline credential, or does not expose the public model id" >&2
    return 1
  fi
  printf '%s\n' "${public_model}"
}

prepare_real_provider_config() {
  local source_config="${RELAYKIT_DESKTOP_PROOF_REAL_PROVIDER_CONFIG}"
  PROOF_PROVIDER_MODEL_ID="$(validate_real_provider_policy)"
  PROOF_SCOPE="real_isolated_route"
  jq --arg codex_home "${APP_OFFICIAL_CODEX_HOME}" '
    {
      official_passthrough: {
        base_url: "https://api.openai.example/v1",
        credential_ref: {kind: "codex_home", value: $codex_home},
        codex_binary: "codex",
        models: [{id: "gpt-5.5", display_name: "GPT-5.5"}]
      },
      providers: (
        .providers
        | to_entries
        | map(
            .key as $index
            | .value
            | .id = ("relaykit-proof-provider-" + (($index + 1) | tostring))
            | .name = "Local Provider Proof"
            | .credential_ref = {
                kind: "keychain",
                value: ("relaykit.desktop-proof.provider-" + (($index + 1) | tostring)),
                header: (.credential_ref.header // .catalog.key_header // "Authorization")
              }
            | .routing.source = "relaykit-user-provider"
          )
      )
    }
  ' "${source_config}" >"${PROVIDER_CONFIG}"
  chmod 600 "${PROVIDER_CONFIG}"
}

project_official_model_catalog() {
  local bundled_catalog="$1"
  local account_cache="$2"
  local proof_scope="$3"
  local output_catalog="$4"
  if [[ "${proof_scope}" == "fixture_plumbing_preflight" ]]; then
    cp "${bundled_catalog}" "${output_catalog}"
    return 0
  fi
  [[ -s "${account_cache}" ]] || {
    echo "real Desktop proof requires the isolated Codex account model cache" >&2
    return 1
  }
  node - "${account_cache}" "${output_catalog}" <<'NODE'
const fs = require("fs");
const accountCachePath = process.argv[2];
const outputPath = process.argv[3];
const accountCache = JSON.parse(fs.readFileSync(accountCachePath, "utf8"));
const models = accountCache.models || [];
if (!Array.isArray(models) || models.length === 0) {
  throw new Error("isolated Codex account model cache is empty");
}
const ids = models.map(model => model.slug);
if (new Set(ids).size !== ids.length) {
  throw new Error("isolated Codex account model cache contains duplicate model ids");
}
for (const required of ["gpt-5.5", "gpt-5.6-luna", "gpt-5.3-codex-spark"]) {
  if (!ids.includes(required)) {
    throw new Error(`isolated Codex account model cache is missing ${required}`);
  }
}
if (ids.includes("gpt-5.2")) {
  throw new Error("isolated Codex account model cache still exposes unsupported gpt-5.2");
}
fs.writeFileSync(outputPath, JSON.stringify({models}, null, 2) + "\n");
NODE
}

merge_model_catalog() {
  local official_catalog="$1"
  local provider_config="$2"
  local proof_scope="$3"
  local output_catalog="$4"
  node - "${official_catalog}" "${provider_config}" "${proof_scope}" "${output_catalog}" <<'NODE'
const fs = require("fs");
const officialCatalog = process.argv[2];
const providerConfig = process.argv[3];
const proofScope = process.argv[4];
const out = process.argv[5];
const parsed = JSON.parse(fs.readFileSync(officialCatalog, "utf8"));
const configured = JSON.parse(fs.readFileSync(providerConfig, "utf8"));
const official = parsed.models || [];
const template = official.find(model => model.slug === "gpt-5.5") || official[0];
if (!template) throw new Error("no bundled model template found");
const officialIds = new Set(official.map(model => model.slug));
const providerModels = (configured.providers || []).flatMap(provider =>
  (provider.models || []).map(model => {
    if (!model.id) throw new Error("provider model is missing id");
    if (officialIds.has(model.id)) throw new Error(`provider model collides with official model: ${model.id}`);
    return {
      ...template,
      slug: model.id,
      display_name: model.display_name || model.id,
      description: proofScope === "fixture_plumbing_preflight"
        ? "RelayKit catalog/picker plumbing fixture."
        : "RelayKit user-supplied provider proof route.",
      source: provider.routing?.source || (proofScope === "fixture_plumbing_preflight" ? "desktop-proof-demo" : "relaykit-user-provider"),
      owned_by: proofScope === "fixture_plumbing_preflight" ? "demo" : "user-provider",
      visibility: "list",
      priority: 100,
      upstream_model: model.upstream_model || model.id,
      protocol: "responses",
      transport: "local_relaykit",
      status: "ready",
      object: "model",
      supported_in_api: true,
      upgrade: null,
      availability_nux: null,
      additional_speed_tiers: [],
      service_tiers: []
    };
  })
);
if (providerModels.length === 0) throw new Error("provider config contains no models");
const providerIds = new Set();
for (const model of providerModels) {
  if (providerIds.has(model.slug)) throw new Error(`duplicate provider model: ${model.slug}`);
  providerIds.add(model.slug);
}
fs.writeFileSync(out, JSON.stringify({models: [...official, ...providerModels]}, null, 2) + "\n");
NODE
}

sync_official_models_to_provider_config() {
  local official_catalog="$1"
  local provider_config="$2"
  local codex_binary="$3"
  [[ "${codex_binary}" = /* && -x "${codex_binary}" ]] || {
    echo "Desktop bundled codex CLI path is invalid" >&2
    return 1
  }
  node - "${official_catalog}" "${provider_config}" "${codex_binary}" <<'NODE'
const fs = require("fs");
const officialCatalogPath = process.argv[2];
const providerConfigPath = process.argv[3];
const codexBinary = process.argv[4];
const officialCatalog = JSON.parse(fs.readFileSync(officialCatalogPath, "utf8"));
const providerConfig = JSON.parse(fs.readFileSync(providerConfigPath, "utf8"));
if (!providerConfig.official_passthrough) {
  throw new Error("provider config is missing official_passthrough");
}
const models = (officialCatalog.models || [])
  .filter(model => model.visibility === "list")
  .map(model => ({id: model.slug, display_name: model.display_name || model.slug}));
if (!models.some(model => model.id === "gpt-5.5")) {
  throw new Error("Desktop bundled catalog is missing required default gpt-5.5");
}
providerConfig.official_passthrough.models = models;
providerConfig.official_passthrough.codex_binary = codexBinary;
const tempPath = `${providerConfigPath}.tmp`;
fs.writeFileSync(tempPath, JSON.stringify(providerConfig, null, 2) + "\n", {mode: 0o600});
fs.renameSync(tempPath, providerConfigPath);
NODE
  chmod 600 "${provider_config}"
}

write_catalog() {
  local bundled_models="${RUN_DIR}/codex-bundled-models.json"
  local current_official_models="${RUN_DIR}/codex-current-models.json"
  local account_model_cache="${CODEX_HOME_DIR}/models_cache.json"
  if [[ -z "${CODEX_CLI_BINARY}" ]]; then
    CODEX_CLI_BINARY="$(resolve_codex_cli_binary || true)"
  fi
  if [[ -z "${CODEX_CLI_BINARY}" || ! -x "${CODEX_CLI_BINARY}" ]]; then
    echo "Codex Desktop bundled codex CLI was not found" >&2
    return 1
  fi
  "${CODEX_CLI_BINARY}" debug models --bundled >"${bundled_models}"
  project_official_model_catalog "${bundled_models}" "${account_model_cache}" "${PROOF_SCOPE}" "${current_official_models}"
  sync_official_models_to_provider_config "${current_official_models}" "${PROVIDER_CONFIG}" "${CODEX_CLI_BINARY}"
  merge_model_catalog "${current_official_models}" "${PROVIDER_CONFIG}" "${PROOF_SCOPE}" "${CATALOG_PATH}"
  cp "${current_official_models}" "${OUT}/official-model-catalog.json"
  cp "${CATALOG_PATH}" "${OUT}/model-catalog.json"
}

write_codex_config() {
  local gateway_port="$1"
  local sandbox_line='sandbox_mode = "read-only"'
  if [[ "${PROOF_SCOPE}" == "rc1_native_responses" ]]; then
    sandbox_line='sandbox_mode = "danger-full-access"'
  fi
cat >"${CODEX_CONFIG}" <<TOML
model = "gpt-5.5"
model_provider = "openai"
${sandbox_line}
openai_base_url = "http://127.0.0.1:${gateway_port}/v1"
model_catalog_json = "${CATALOG_PATH}"

[features]
plugins = false
computer_use = false
browser_use = false
browser_use_external = false
browser_use_full_cdp_access = false
TOML
  cp "${CODEX_CONFIG}" "${OUT}/codex-config.toml"
}

start_gateway() {
  local gateway_port="$1"
  rm -f "${USAGE_PATH}" "${GATEWAY_LOG}"
  env "${PROVIDER_TOKEN_ENV}=${PROVIDER_TOKEN_VALUE}" \
  "${BUNDLED_RELAY}" -listen "127.0.0.1:${gateway_port}" -config "${PROVIDER_CONFIG}" -usage-log "${USAGE_PATH}" >"${GATEWAY_LOG}" 2>&1 &
  echo "$!" >"${GATEWAY_PID_FILE}"
  for _ in {1..60}; do
    curl -fsS "http://127.0.0.1:${gateway_port}/healthz" >/dev/null 2>&1 && return 0
    sleep 0.2
  done
  echo "RelayKit gateway did not start" >&2
  cat "${GATEWAY_LOG}" >&2 || true
  exit 1
}

prepare_extracted_app() {
  if ! port_is_free 19777; then
    echo "127.0.0.1:19777 is already in use; close RelayKit before starting isolated proof" >&2
    return 1
  fi
  if pgrep -x RelayKitApp.bin >/dev/null 2>&1; then
    echo "RelayKit App is already running; close it before starting isolated proof" >&2
    return 1
  fi

  local reuse_current_zip="${RELAYKIT_DESKTOP_PROOF_REUSE_CURRENT_ZIP:-0}"
  case "${reuse_current_zip}" in
    0) "${ROOT}/script/package_release.sh" --verify >/dev/null ;;
    1) ;;
    *)
      echo "RELAYKIT_DESKTOP_PROOF_REUSE_CURRENT_ZIP must be 0 or 1" >&2
      return 1
      ;;
  esac
  [[ -s "${ZIP_PATH}" ]] || {
    echo "current RelayKit local zip was not produced" >&2
    return 1
  }
  APP_ZIP_SHA256="$(/usr/bin/shasum -a 256 "${ZIP_PATH}" | awk '{print $1}')"
  APP_ZIP_BUILD_TIME_UTC="$(date -u -r "${ZIP_PATH}" +"%Y-%m-%dT%H:%M:%SZ")"
  local reuse_extracted_app="${RELAYKIT_DESKTOP_PROOF_REUSE_EXTRACTED_APP:-0}"
  case "${reuse_extracted_app}" in
    0)
      rm -rf "${APP_INSTALL_DIR}"
      mkdir -p "${APP_INSTALL_DIR}"
      /usr/bin/ditto -x -k "${ZIP_PATH}" "${APP_INSTALL_DIR}"
      ;;
    1)
      verify_extracted_app_matches_zip "${ZIP_PATH}" "${APP_BUNDLE}" "${RUN_DIR}/extracted-app-verify" || {
        echo "existing DesktopProof App does not match the current zip; refusing reuse" >&2
        return 1
      }
      ;;
    *)
      echo "RELAYKIT_DESKTOP_PROOF_REUSE_EXTRACTED_APP must be 0 or 1" >&2
      return 1
      ;;
  esac
  [[ -x "${APP_REAL_BINARY}" && -x "${BUNDLED_RELAY}" ]] || {
    echo "extracted RelayKit App is incomplete" >&2
    return 1
  }
  /usr/bin/codesign --verify --deep --strict "${APP_BUNDLE}"
}

verify_extracted_app_matches_zip() {
  local zip_path="$1"
  local extracted_app="$2"
  local scratch_dir="$3"
  [[ -s "${zip_path}" && -d "${extracted_app}" && -n "${scratch_dir}" && "${scratch_dir}" != "/" ]] || return 1
  rm -rf "${scratch_dir}"
  mkdir -p "${scratch_dir}"
  if ! /usr/bin/ditto -x -k "${zip_path}" "${scratch_dir}"; then
    rm -rf "${scratch_dir}"
    return 1
  fi
  local zipped_app="${scratch_dir}/RelayKitApp.app"
  if [[ ! -d "${zipped_app}" ]] || ! /usr/bin/diff -qr "${zipped_app}" "${extracted_app}" >/dev/null; then
    rm -rf "${scratch_dir}"
    return 1
  fi
  rm -rf "${scratch_dir}"
}

find_relaykit_app_pid() {
  local pid command
  while IFS= read -r pid; do
    command="$(ps -p "${pid}" -o command= 2>/dev/null || true)"
    case "${command}" in
      "${APP_REAL_BINARY}"*)
        printf '%s\n' "${pid}"
        return 0
        ;;
    esac
  done < <(pgrep -f -- "^${APP_REAL_BINARY}" 2>/dev/null || true)
  return 1
}

open_relaykit_popover() {
  local app_pid="$1"
  local identity=""
  for _ in {1..8}; do
    identity="$(write_current_app_window_identity "${app_pid}" 2>/dev/null || true)"
    [[ -n "${identity}" ]] && return 0
    sleep 0.25
  done
  /usr/bin/osascript - "${app_pid}" <<'APPLESCRIPT'
on run argv
  tell application "System Events"
    tell (first process whose unix id is (item 1 of argv as integer))
      set frontmost to true
      repeat 80 times
        try
          set statusItem to first menu bar item of menu bar 1 whose description is "RelayKit"
          perform action "AXPress" of statusItem
          return
        end try
        delay 0.1
      end repeat
    end tell
  end tell
  error "RelayKit status item unavailable"
end run
APPLESCRIPT
}

write_current_app_window_identity() {
  local app_pid="$1"
  swift - "${app_pid}" <<'SWIFT'
import CoreGraphics
import Foundation

let targetPID = Int(CommandLine.arguments[1])!
let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
func windowBounds(_ window: [String: Any]) -> CGRect? {
    guard let values = window[kCGWindowBounds as String] as? [String: Any],
          let x = values["X"] as? NSNumber,
          let y = values["Y"] as? NSNumber,
          let width = values["Width"] as? NSNumber,
          let height = values["Height"] as? NSNumber else {
        return nil
    }
    return CGRect(x: x.doubleValue, y: y.doubleValue, width: width.doubleValue, height: height.doubleValue)
}
let candidates = windows.compactMap { window -> (Int, CGRect)? in
    guard let ownerPID = window[kCGWindowOwnerPID as String] as? Int,
          ownerPID == targetPID,
          let windowID = window[kCGWindowNumber as String] as? Int,
          let bounds = windowBounds(window),
          bounds.width >= 400,
          bounds.height >= 400 else {
        return nil
    }
    return (windowID, bounds)
}
guard let selected = candidates.max(by: { $0.1.width * $0.1.height < $1.1.width * $1.1.height }) else {
    exit(1)
}
let value: [String: Any] = [
    "pid": targetPID,
    "window_id": selected.0,
    "width": Int(selected.1.width),
    "height": Int(selected.1.height),
    "captured_at": ISO8601DateFormatter().string(from: Date()),
]
let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
FileHandle.standardOutput.write(data)
FileHandle.standardOutput.write(Data("\n".utf8))
SWIFT
}

press_relaykit_app_ax() {
  local identifier="$1"
  local app_pid expected_window_id timeout total_timeout deadline attempt_timeout remaining
  app_pid="$(cat "${APP_PID_FILE}")"
  timeout="${RELAYKIT_AX_PRESS_TIMEOUT_SECONDS:-20}"
  case "${timeout}" in
    ''|*[!0-9]*) timeout=5 ;;
  esac
  total_timeout="${RELAYKIT_AX_PRESS_TOTAL_TIMEOUT_SECONDS:-30}"
  case "${total_timeout}" in
    ''|*[!0-9]*) total_timeout=30 ;;
  esac
  (( total_timeout >= 5 && total_timeout <= 120 )) || total_timeout=30
  deadline=$((SECONDS + total_timeout))
  while (( SECONDS < deadline )); do
    if ! ensure_relaykit_popover_open "${deadline}"; then
      sleep 0.1
      continue
    fi
    expected_window_id="$(jq -er '.window_id | select(type == "number" and . > 0)' "${APP_WINDOW_IDENTITY}")" || return 1
    remaining=$((deadline - SECONDS))
    (( remaining > 0 )) || break
    attempt_timeout="${timeout}"
    (( attempt_timeout > remaining )) && attempt_timeout="${remaining}"
    if /usr/bin/perl -e 'alarm shift; exec @ARGV' "${attempt_timeout}" swift - "${app_pid}" "${identifier}" "${expected_window_id}" <<'SWIFT'
import ApplicationServices
import CoreGraphics
import Foundation

let targetPID = Int(CommandLine.arguments[1])!
let identifier = CommandLine.arguments[2]
let expectedWindowID = Int(CommandLine.arguments[3])!
let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
let matches = windows.compactMap { window -> CGRect? in
    guard let ownerPID = window[kCGWindowOwnerPID as String] as? Int,
          let windowID = window[kCGWindowNumber as String] as? Int,
          ownerPID == targetPID && windowID == expectedWindowID,
          let values = window[kCGWindowBounds as String] as? [String: Any],
          let x = values["X"] as? NSNumber,
          let y = values["Y"] as? NSNumber,
          let width = values["Width"] as? NSNumber,
          let height = values["Height"] as? NSNumber,
          width.doubleValue >= 400,
          height.doubleValue >= 400 else {
        return nil
    }
    return CGRect(x: x.doubleValue, y: y.doubleValue, width: width.doubleValue, height: height.doubleValue)
}
guard matches.count == 1, let bounds = matches.first else { exit(2) }
let focusPoint = CGPoint(x: bounds.midX, y: bounds.minY + min(80, bounds.height / 4))
CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: focusPoint, mouseButton: .left)?.post(tap: .cghidEventTap)
Thread.sleep(forTimeInterval: 0.03)
CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: focusPoint, mouseButton: .left)?.post(tap: .cghidEventTap)
Thread.sleep(forTimeInterval: 0.15)
let app = AXUIElementCreateApplication(pid_t(targetPID))

func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
    return value
}

func text(_ element: AXUIElement, _ name: String) -> String {
    (attribute(element, name) as? String) ?? ""
}

func children(_ element: AXUIElement) -> [AXUIElement] {
    (attribute(element, kAXChildrenAttribute as String) as? [AXUIElement]) ?? []
}

func press(_ element: AXUIElement, depth: Int = 0) -> Bool {
    if depth > 10 { return false }
    if text(element, kAXRoleAttribute) == kAXButtonRole as String,
       AXUIElementPerformAction(element, kAXPressAction as CFString) == .success {
        return true
    }
    for child in children(element) where press(child, depth: depth + 1) {
        return true
    }
    return false
}

func walk(_ element: AXUIElement, depth: Int = 0) -> Bool {
    if depth > 16 { return false }
    if text(element, "AXIdentifier") == identifier {
        return press(element)
    }
    for child in children(element) where walk(child, depth: depth + 1) {
        return true
    }
    return false
}

exit(walk(app) ? 0 : 1)
SWIFT
    then
      return 0
    fi
    if keychain_authorization_prompt_visible; then
      return 2
    fi
    sleep 0.1
  done
  echo "RelayKit AX control unavailable: ${identifier}" >&2
  return 1
}

keychain_authorization_prompt_visible() {
  [[ "$(/usr/bin/osascript -e 'tell application "System Events" to exists window 1 of process "SecurityAgent"' 2>/dev/null || printf false)" == "true" ]]
}

wait_for_app_gateway_health() {
  for _ in {1..100}; do
    curl -fsS --max-time 1 http://127.0.0.1:19777/healthz >/dev/null 2>&1 && return 0
    sleep 0.1
  done
  return 1
}

wait_for_keychain_authorization() {
  keychain_authorization_prompt_visible || return 1
  if [[ "${PROOF_INPUT_MODE}" == "automated_ax" ]]; then
    echo '{"status":"precondition_failed","error_code":"keychain_authorization_required"}' >&2
    return 1
  fi
  cat <<'EOF'
RelayKit is waiting for macOS Keychain authorization.

Authorize only the dedicated DesktopProof Keychain item shown by macOS:
1. Enter your macOS login password in the SecurityAgent dialog.
2. Choose Always Allow.
3. Return here and press Enter.

RelayKit does not read, copy, or modify global Codex auth files during this step.
EOF
  wait_for_user_continue
}

launch_isolated_relaykit_app() {
  port_is_free 19777 || {
    echo "127.0.0.1:19777 became busy before RelayKit App launch" >&2
    return 1
  }
  rm -f "${USAGE_PATH}" "${APP_LOG}"
  /usr/bin/open -n \
    --env "RELAYKIT_OFFICIAL_PROOF_ROOT=${OFFICIAL_PROOF_ROOT}" \
    --env "PATH=${PATH}" \
    --stdout "${APP_LOG}" \
    --stderr "${APP_LOG}" \
    "${APP_BUNDLE}" \
    --args \
    --ui-smoke-provider-config "${PROVIDER_CONFIG}" \
    --ui-smoke-usage-log "${USAGE_PATH}"

  local app_pid="" app_launch_timeout_seconds app_launch_attempts attempt
  app_launch_timeout_seconds="${RELAYKIT_APP_LAUNCH_TIMEOUT_SECONDS:-30}"
  case "${app_launch_timeout_seconds}" in
    ''|*[!0-9]*) app_launch_timeout_seconds=30 ;;
  esac
  (( app_launch_timeout_seconds >= 15 && app_launch_timeout_seconds <= 60 )) || app_launch_timeout_seconds=30
  app_launch_attempts=$((app_launch_timeout_seconds * 10))
  for ((attempt = 1; attempt <= app_launch_attempts; attempt++)); do
    app_pid="$(find_relaykit_app_pid || true)"
    [[ -n "${app_pid}" ]] && break
    sleep 0.1
  done
  [[ -n "${app_pid}" ]] || {
    echo "extracted RelayKit App did not start" >&2
    return 1
  }
  printf '%s\n' "${app_pid}" >"${APP_PID_FILE}"
  open_relaykit_popover "${app_pid}"
  local identity=""
  for _ in {1..80}; do
    identity="$(write_current_app_window_identity "${app_pid}" 2>/dev/null || true)"
    [[ -n "${identity}" ]] && break
    sleep 0.25
  done
  [[ -n "${identity}" ]] || {
    echo "RelayKit App started without a visible popover" >&2
    return 1
  }
  printf '%s\n' "${identity}" >"${APP_WINDOW_IDENTITY}"

  press_relaykit_app_ax "tab-settings"
  local start_action_status=0
  press_relaykit_app_ax "gateway-start" || start_action_status=$?
  if [[ "${start_action_status}" -ne 0 ]] && ! wait_for_app_gateway_health; then
    wait_for_keychain_authorization || {
      echo "RelayKit gateway Start AX action failed without a Keychain authorization prompt" >&2
      return 1
    }
  fi
  if ! wait_for_app_gateway_health; then
    if keychain_authorization_prompt_visible; then
      wait_for_keychain_authorization
    fi
    if ! wait_for_app_gateway_health; then
      press_relaykit_app_ax "gateway-start" || return 1
    fi
  fi
  wait_for_app_gateway_health || {
    echo "RelayKit App Start action did not start its gateway on 19777" >&2
    return 1
  }
  ensure_relaykit_popover_open || return 1
  press_relaykit_app_ax "tab-connect"
  /usr/sbin/screencapture -x -l "$(jq -r '.window_id' "${APP_WINDOW_IDENTITY}")" "${APP_SCREENSHOT}"
  [[ -s "${APP_SCREENSHOT}" ]] || return 1
  RELAYKIT_APP_LAUNCHED=true
}

official_gateway_preflight_status() {
  local http_status curl_status=0
  http_status="$(
    jq -nc --arg input "RelayKit official login preflight $(date -u +%Y%m%d%H%M%S)" '{model:"gpt-5.5",input:$input,stream:false}' |
      curl -sS --max-time 90 -o /dev/null -w '%{http_code}' \
        -H 'Content-Type: application/json' \
        --data-binary @- \
        http://127.0.0.1:19777/v1/responses
  )" || curl_status=$?
  if [[ "${curl_status}" -ne 0 ]]; then
    printf 'network_failed\n'
    return 0
  fi
  case "${http_status}" in
    200) printf 'connected\n' ;;
    401|403) printf 'auth_required\n' ;;
    *) printf 'request_failed\n' ;;
  esac
}

reset_route_usage_after_preflight() {
  : >"${USAGE_PATH}"
  chmod 600 "${USAGE_PATH}"
}

fetch_gateway_models() {
  local tmp="${OUT}/gateway-models.tmp"
  if curl -fsS --max-time 25 http://127.0.0.1:19777/v1/models >"${tmp}"; then
    mv "${tmp}" "${OUT}/gateway-models.json"
    return 0
  fi
  rm -f "${tmp}"
  return 1
}

provider_gateway_status_from_file() {
  local models_path="$1"
  local provider_model="$2"
  jq -r --arg model "${provider_model}" '
    if ([.data[]?.id] | index($model)) then "available"
    elif any(.model_health.hidden[]?; .id == $model and .reason == "auth failed") then "auth_required"
    elif any(.model_health.hidden[]?; .id == $model) then "unavailable"
    else "missing"
    end
  ' "${models_path}"
}

provider_gateway_status() {
  provider_gateway_status_from_file "${OUT}/gateway-models.json" "${PROOF_PROVIDER_MODEL_ID}"
}

wait_for_provider_gateway_status() {
  local attempts="${RELAYKIT_PROVIDER_PREFLIGHT_ATTEMPTS:-5}"
  case "${attempts}" in
    ''|*[!0-9]*) attempts=5 ;;
  esac
  (( attempts >= 1 && attempts <= 20 )) || attempts=5
  local attempt provider_status="network_failed"
  for ((attempt = 1; attempt <= attempts; attempt++)); do
    if fetch_gateway_models; then
      provider_status="$(provider_gateway_status)"
      if [[ "${provider_status}" == "available" ]]; then
        printf '%s\n' "${provider_status}"
        return 0
      fi
    else
      provider_status="network_failed"
    fi
    (( attempt < attempts )) && sleep 1
  done
  printf '%s\n' "${provider_status}"
}

ensure_relaykit_popover_open() {
  local deadline="${1:-$((SECONDS + 20))}"
  local app_pid identity=""
  app_pid="$(cat "${APP_PID_FILE}")"
  identity="$(write_current_app_window_identity "${app_pid}" 2>/dev/null || true)"
  if [[ -z "${identity}" ]]; then
    open_relaykit_popover "${app_pid}"
    while (( SECONDS < deadline )); do
      identity="$(write_current_app_window_identity "${app_pid}" 2>/dev/null || true)"
      [[ -n "${identity}" ]] && break
      sleep 0.25
    done
  fi
  [[ -n "${identity}" ]] || return 1
  printf '%s\n' "${identity}" >"${APP_WINDOW_IDENTITY}"
}

ensure_provider_models_available_via_app() {
  local provider_status
  provider_status="$(wait_for_provider_gateway_status)"
  [[ "${provider_status}" == "available" ]] && return 0

  local route_status="provider_model_${provider_status}"
  [[ "${provider_status}" == "auth_required" ]] && route_status="provider_auth_required"
  write_evidence "awaiting_provider_app_setup" "${route_status}" "${CONFIG_BEFORE}" "${AUTH_BEFORE}" "${CONFIG_HASH_BEFORE}" "${AUTH_HASH_BEFORE}" "${NOTIFY_HASH_BEFORE}"
  assert_proof_state_unchanged
  if [[ "${PROOF_INPUT_MODE}" == "automated_ax" ]]; then
    echo "{\"status\":\"precondition_failed\",\"error_code\":\"${route_status}\"}" >&2
    return 1
  fi
  ensure_relaykit_popover_open

  cat <<EOF
RelayKit App is running, but the isolated provider route is not usable yet (${route_status}).

In the RelayKit Connect page:
1. Open "Local Provider Proof".
2. Paste the real provider API key into the empty isolated Keychain field.
3. Run Test connection, choose Use reachable models, and Save.
4. Return here and press Enter.

This writes only the dedicated DesktopProof Keychain item. It does not overwrite the original provider Keychain item.
EOF
  wait_for_user_continue

  [[ -f "${APP_PID_FILE}" ]] && kill -0 "$(cat "${APP_PID_FILE}")" 2>/dev/null || {
    echo "RelayKit App exited before provider verification" >&2
    return 1
  }
  curl -fsS --max-time 1 http://127.0.0.1:19777/healthz >/dev/null || {
    echo "RelayKit App gateway stopped before provider verification" >&2
    return 1
  }
  provider_status="$(wait_for_provider_gateway_status)"
  if [[ "${provider_status}" != "available" ]]; then
    route_status="provider_model_${provider_status}"
    [[ "${provider_status}" == "auth_required" ]] && route_status="provider_auth_required"
    write_evidence "route_incomplete" "${route_status}" "${CONFIG_BEFORE}" "${AUTH_BEFORE}" "${CONFIG_HASH_BEFORE}" "${AUTH_HASH_BEFORE}" "${NOTIFY_HASH_BEFORE}"
    echo "RelayKit provider preflight remains incomplete: ${route_status}" >&2
    return 1
  fi
}

write_app_server_evidence() {
  if [[ -z "${CODEX_CLI_BINARY}" ]]; then
    CODEX_CLI_BINARY="$(resolve_codex_cli_binary || true)"
  fi
  [[ -n "${CODEX_CLI_BINARY}" && -x "${CODEX_CLI_BINARY}" ]] || return 1
  [[ "${APP_SERVER_SETUP_ID}" =~ ^[A-Za-z0-9._:-]{1,128}$ ]] || return 1
  [[ "${APP_SERVER_SESSION_ID}" =~ ^[A-Za-z0-9._:-]{1,128}$ ]] || return 1
  [[ "${APP_ZIP_SHA256}" =~ ^[0-9a-f]{64}$ ]] || return 1
  CFFIXED_USER_HOME="${ISO_HOME}" HOME="${ISO_HOME}" CODEX_HOME="${CODEX_HOME_DIR}" node - \
    "${OUT}/app-server.json" "${PROVIDER_CONFIG}" "${CODEX_CLI_BINARY}" \
    "${APP_SERVER_SETUP_ID}" "${APP_SERVER_SESSION_ID}" "${APP_ZIP_SHA256}" <<'NODE'
const {spawn} = require("child_process");
const fs = require("fs");
const out = process.argv[2];
const providerConfig = JSON.parse(fs.readFileSync(process.argv[3], "utf8"));
const codexCli = process.argv[4];
const setupId = process.argv[5];
const sessionId = process.argv[6];
const artifactSha256 = process.argv[7];
const providerModels = new Set((providerConfig.providers || []).flatMap(provider => (provider.models || []).map(model => model.id)));
const child = spawn(codexCli, ["app-server", "--listen", "stdio://"], {stdio: ["pipe", "pipe", "pipe"], env: process.env});
let buffer = "";
const messages = [];
let wrote = false;
child.stdout.on("data", data => {
  buffer += data.toString();
  let idx;
  while ((idx = buffer.indexOf("\n")) >= 0) {
    const line = buffer.slice(0, idx).trim();
    buffer = buffer.slice(idx + 1);
    if (!line) continue;
    try { messages.push(JSON.parse(line)); } catch {}
  }
});
child.stderr.resume();
function send(msg) { child.stdin.write(JSON.stringify(msg) + "\n"); }
function finish() {
  if (wrote) return;
  wrote = true;
  const config = messages.find(m => m.id === 2)?.result?.config;
  const models = messages.find(m => m.id === 3)?.result?.data || [];
  const temp = `${out}.tmp.${process.pid}`;
  fs.writeFileSync(temp, JSON.stringify({
    relaykit_lineage: {setup_id: setupId, session_id: sessionId, artifact_sha256: artifactSha256},
    config: {model: config?.model, model_provider: config?.model_provider},
    official: models.filter(model => !providerModels.has(model.model)).map(model => ({model: model.model, displayName: model.displayName, hidden: model.hidden})),
    provider: models.filter(model => providerModels.has(model.model)).map(model => ({model: model.model, displayName: model.displayName, hidden: model.hidden}))
  }, null, 2) + "\n");
  fs.chmodSync(temp, 0o600);
  fs.renameSync(temp, out);
  child.kill("SIGTERM");
  setTimeout(() => process.exit(0), 100);
}
send({id: 1, method: "initialize", params: {clientInfo: {name: "relaykit-desktop-proof", title: null, version: "1.0.0"}, capabilities: {experimentalApi: true, requestAttestation: false}}});
send({method: "initialized", params: {}});
send({id: 2, method: "config/read", params: {}});
send({id: 3, method: "model/list", params: {includeHidden: false}});
const timer = setInterval(() => {
  if (messages.some(m => m.id === 2) && messages.some(m => m.id === 3)) {
    clearInterval(timer);
    finish();
  }
}, 100);
setTimeout(finish, 20000);
NODE
}

summarize_usage() {
  if [[ -f "${USAGE_PATH}" ]]; then
    "${BUNDLED_RELAY}" summarize-usage -path "${USAGE_PATH}" >"${OUT}/usage-summary.json"
    jq -s '.' "${USAGE_PATH}" >"${OUT}/usage-events.json"
  else
    printf '[]\n' >"${OUT}/usage-summary.json"
    printf '[]\n' >"${OUT}/usage-events.json"
  fi
}

write_desktop_tool_evidence() {
  local since_epoch="$1"
  local provider_model="$2"
  local marker="$3"
  python3 - "${CODEX_HOME_DIR}" "${DESKTOP_TOOL_EVIDENCE}" "${since_epoch}" "${provider_model}" "${marker}" <<'PY'
import json
import sys
from datetime import datetime
from pathlib import Path

sessions_root = Path(sys.argv[1]) / "sessions"
out_path = Path(sys.argv[2])
since_epoch = float(sys.argv[3] or 0)
provider_model = sys.argv[4]
marker = sys.argv[5]
events = []
xml_leak_records = []
calls = {}
outputs = {}

def parse_ts(value):
    if not value:
        return 0.0
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp()
    except ValueError:
        return 0.0

for path in sorted(sessions_root.glob("**/rollout-*.jsonl")):
    current_model = ""
    try:
        lines = path.read_text(errors="replace").splitlines()
    except OSError:
        continue
    for line in lines:
        try:
            record = json.loads(line)
        except json.JSONDecodeError:
            continue
        record_type = record.get("type")
        payload = record.get("payload") or {}
        if record_type == "turn_context":
            current_model = payload.get("model") or current_model
            continue
        if record_type != "response_item":
            continue
        event_epoch = parse_ts(record.get("timestamp"))
        if since_epoch and (not event_epoch or event_epoch < since_epoch):
            continue
        if payload.get("type") == "message" and payload.get("role") == "assistant":
            assistant_text = json.dumps(payload.get("content") or payload.get("text") or "", ensure_ascii=False)
            leak_terms = ["<function_calls", "<invoke", "<parameter", "<tool_call", "</tool_call"]
            if any(term in assistant_text for term in leak_terms):
                xml_leak_records.append({
                    "session_file": str(path.relative_to(sessions_root)),
                    "timestamp": record.get("timestamp"),
                    "model": current_model,
                })
        item = payload.get("item") if isinstance(payload.get("item"), dict) else payload
        if not isinstance(item, dict):
            continue
        item_type = item.get("type")
        if item_type not in {"function_call", "function_call_output"}:
            continue
        call_id = item.get("call_id") or payload.get("call_id") or ""
        if not call_id:
            continue
        if item_type == "function_call":
            arguments = item.get("arguments")
            try:
                parsed_args = json.loads(arguments) if isinstance(arguments, str) else arguments or {}
            except json.JSONDecodeError:
                parsed_args = {}
            command = str(parsed_args.get("cmd") or parsed_args.get("command") or "")
            marker_found = marker in command
            calls[call_id] = {
                "model": current_model,
                "tool_name": item.get("name") or "",
                "marker_found": marker_found,
                "exact_shell_command_found": command == f"printf '{marker}\\n'; pwd",
            }
            events.append({
                "timestamp": record.get("timestamp"),
                "type": "function_call",
                "model": current_model,
                "tool_name": item.get("name") or "",
                "marker_found": marker_found,
            })
        else:
            output = item.get("output")
            output_text = output if isinstance(output, str) else json.dumps(output, separators=(",", ":"), sort_keys=True) if output is not None else ""
            marker_found = marker in output_text
            process_exited_zero = "Process exited with code 0" in output_text
            outputs[call_id] = {
                "model": current_model,
                "marker_found": marker_found,
                "process_exited_zero": process_exited_zero,
                "pwd_output_found": any(line.startswith("/") for line in output_text.splitlines()),
            }
            events.append({
                "timestamp": record.get("timestamp"),
                "type": "function_call_output",
                "model": current_model,
                "marker_found": marker_found,
                "process_exited_zero": process_exited_zero,
            })

matched_ids = [
    call_id for call_id, call in calls.items()
    if call.get("model") == provider_model
    and call.get("tool_name") in {"exec_command", "shell", "bash"}
    and call.get("marker_found")
    and outputs.get(call_id, {}).get("marker_found")
    and outputs.get(call_id, {}).get("process_exited_zero")
]
xml_leak_found = bool(xml_leak_records)
exact_shell_command_found = any(
    call.get("model") == provider_model
    and call.get("exact_shell_command_found")
    for call in calls.values()
)
pwd_output_found = any(
    output.get("model") == provider_model
    and output.get("marker_found")
    and output.get("pwd_output_found")
    for output in outputs.values()
)
out_path.write_text(json.dumps({
    "proof_found": bool(matched_ids) and not xml_leak_found,
    "function_call_found": any(event["type"] == "function_call" for event in events),
    "function_call_output_found": any(event["type"] == "function_call_output" for event in events),
    "process_exited_zero": bool(matched_ids),
    "matched_provider_tool_count": len(matched_ids),
    "xml_leak_found": xml_leak_found,
    "raw_function_calls_found": xml_leak_found,
    "exact_shell_command_found": exact_shell_command_found,
    "pwd_output_found": pwd_output_found,
    "xml_leak_records": xml_leak_records,
    "since_epoch": since_epoch,
    "event_count": len(events),
    "events": events,
}, indent=2, sort_keys=True) + "\n")
PY
}

write_desktop_render_evidence() {
  local since_epoch="$1"
  local provider_model="$2"
  local screenshot_evidence="$3"
  local gpt55_marker="${4:-RelayKit Official 55 Live:}"
  local gpt56_marker="${5:-RelayKit Official 56 Live:}"
  python3 - "${CODEX_HOME_DIR}" "${DESKTOP_RENDER_EVIDENCE}" "${since_epoch}" "${provider_model}" "${screenshot_evidence}" "${gpt55_marker}" "${gpt56_marker}" <<'PY'
import json
import re
import sys
from datetime import datetime
from pathlib import Path

sessions_root = Path(sys.argv[1]) / "sessions"
out_path = Path(sys.argv[2])
since_epoch = float(sys.argv[3] or 0)
provider_model = sys.argv[4]
screenshot_path = Path(sys.argv[5])
gpt55_marker = sys.argv[6]
gpt56_marker = sys.argv[7]

def parse_ts(value):
    if not value:
        return 0.0
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp()
    except ValueError:
        return 0.0

def message_text(value):
    if isinstance(value, str):
        return value
    if isinstance(value, list):
        return "\n".join(message_text(item) for item in value)
    if isinstance(value, dict):
        if isinstance(value.get("text"), str):
            return value["text"]
        return "\n".join(message_text(value.get(key)) for key in ("content", "output_text") if key in value)
    return ""

def table_cells(line):
    stripped = line.strip()
    if not (stripped.startswith("|") and stripped.endswith("|")):
        return None
    return [cell.strip() for cell in stripped[1:-1].split("|")]

def has_exact_two_column_table(text):
    lines = text.splitlines()
    for index in range(len(lines) - 3):
        header = table_cells(lines[index])
        separator = table_cells(lines[index + 1])
        first = table_cells(lines[index + 2])
        second = table_cells(lines[index + 3])
        if not all(row is not None and len(row) == 2 for row in (header, separator, first, second)):
            continue
        if [cell.lower() for cell in header] != ["status", "route"]:
            continue
        if not all(re.fullmatch(r":?-{3,}:?", cell) for cell in separator):
            continue
        if [cell.lower() for cell in first] != ["ready", "official"]:
            continue
        if [cell.lower() for cell in second] != ["ready", "provider"]:
            continue
        return True
    return False

assistant_messages = []
raw_protocol_records = []
raw_terms = (
    "<function_calls", "</function_calls", "<invoke", "</invoke",
    "<parameter", "</parameter", "<tool_call", "</tool_call",
    '"function_calls"', '"tool_call"',
)
for path in sorted(sessions_root.glob("**/rollout-*.jsonl")):
    current_model = ""
    try:
        lines = path.read_text(errors="replace").splitlines()
    except OSError:
        continue
    for line in lines:
        try:
            record = json.loads(line)
        except json.JSONDecodeError:
            continue
        payload = record.get("payload") or {}
        if record.get("type") == "turn_context":
            current_model = payload.get("model") or current_model
            continue
        if record.get("type") != "response_item":
            continue
        event_epoch = parse_ts(record.get("timestamp"))
        if since_epoch and (not event_epoch or event_epoch < since_epoch):
            continue
        if payload.get("type") != "message" or payload.get("role") != "assistant":
            continue
        text = message_text(payload.get("content") or payload.get("text") or "")
        if not text:
            continue
        assistant_messages.append((current_model, text))
        lowered = text.lower()
        if any(term in lowered for term in raw_terms):
            raw_protocol_records.append({
                "session_file": str(path.relative_to(sessions_root)),
                "timestamp": record.get("timestamp"),
                "model": current_model,
            })

gpt55_source = any(model == "gpt-5.5" and gpt55_marker in text for model, text in assistant_messages)
gpt56_source = any(model == "gpt-5.6-luna" and gpt56_marker in text for model, text in assistant_messages)
markdown_source = False
for model, text in assistant_messages:
    if model != provider_model:
        continue
    markdown_source = (
        "## RelayKit Rich Text Check" in text
        and "1. First route check" in text
        and "2. Second route check" in text
        and has_exact_two_column_table(text)
        and "```bash" in text
        and "echo relaykit" in text
        and text.count("```") >= 2
        and "**RELAYKIT_FORMAT_OK**" in text
    )
    if markdown_source:
        break

try:
    screenshots = json.loads(screenshot_path.read_text())
except (OSError, json.JSONDecodeError):
    screenshots = []

def role_screenshots(role):
    return [
        item for item in screenshots
        if item.get("role") == role
        and item.get("captured") is True
        and item.get("target_identity_verified") is True
    ]

def visual(role, key):
    return any((item.get("visual_checks") or {}).get(key) is True for item in role_screenshots(role))

proof_roles = ("gpt55-response", "gpt56-response", "provider-markdown", "provider-tool")
screenshot_raw_protocol_absent = all(not visual(role, "raw_protocol_visible") for role in proof_roles)
raw_protocol_absent = not raw_protocol_records and screenshot_raw_protocol_absent
markdown_visual = all(visual("provider-markdown", key) for key in (
    "heading_visible", "numbered_items_visible", "table_headers_visible",
    "bash_code_visible", "bold_conclusion_visible",
))
tool_gui_verified = visual("provider-tool", "tool_marker_visible") and visual("provider-tool", "tool_execution_visible")

out_path.write_text(json.dumps({
    "gpt55_gui_visible": gpt55_source and (visual("gpt55-response", "response_marker_visible") or visual("gpt55-response", "official55_response_visible")),
    "gpt56_gui_visible": gpt56_source and (visual("gpt56-response", "response_marker_visible") or visual("gpt56-response", "official56_response_visible")),
    "markdown_source_contract_verified": markdown_source,
    "markdown_visual_tokens_verified": markdown_visual,
    "markdown_render_verified": markdown_source and markdown_visual and raw_protocol_absent,
    "raw_protocol_absent": raw_protocol_absent,
    "raw_protocol_records": raw_protocol_records,
    "tool_gui_verified": tool_gui_verified and raw_protocol_absent,
    "current_run_assistant_message_count": len(assistant_messages),
}, indent=2, sort_keys=True) + "\n")
PY
}

route_outcome_from_usage_file() {
  local usage_file="$1"
  local provider_model="$2"
  local tool_evidence="$3"
  local screenshot_evidence="$4"
  local render_evidence="$5"
  if [[ ! -s "${usage_file}" ]] || ! jq -e 'type == "array"' "${usage_file}" >/dev/null 2>&1; then
    printf 'usage_missing_or_invalid\n'
    return 0
  fi
  if [[ ! -s "${tool_evidence}" ]] || ! jq -e 'type == "object"' "${tool_evidence}" >/dev/null 2>&1; then
    printf 'tool_evidence_missing\n'
    return 0
  fi
  if [[ ! -s "${screenshot_evidence}" ]] || ! jq -e 'type == "array"' "${screenshot_evidence}" >/dev/null 2>&1; then
    printf 'target_screenshot_evidence_missing\n'
    return 0
  fi
  if [[ ! -s "${render_evidence}" ]] || ! jq -e 'type == "object"' "${render_evidence}" >/dev/null 2>&1; then
    printf 'render_evidence_missing\n'
    return 0
  fi
  jq -r \
    --arg provider_model "${provider_model}" \
    --slurpfile tool "${tool_evidence}" \
    --slurpfile screenshots "${screenshot_evidence}" \
    --slurpfile render "${render_evidence}" \
    '
      if any(.[]; (.error_type // "") == "unknown_model") then "unknown_model_failure"
      elif any(.[]; (.provider_id // "") == "openai" and ((.error_type // "") | test("refresh(_token)?_revoked|token_revoked"))) then "official_refresh_revoked"
      elif any(.[]; (.provider_id // "") == "openai" and (.error_type // "") == "auth_required") then "official_auth_required"
      elif any(.[]; (.provider_id // "") == "openai" and (.error_type // "") == "model_not_supported") then "official_model_not_supported"
      elif ([.[] | select((.provider_id // "") == "openai" and (.model // "") == "gpt-5.5" and (.status // "") == "completed" and (.http_status // 0) == 200)] | length) == 0 then "gpt55_incomplete"
      elif ([.[] | select((.provider_id // "") == "openai" and (.model // "") == "gpt-5.6-luna" and (.status // "") == "completed" and (.http_status // 0) == 200)] | length) == 0 then "gpt56_incomplete"
      elif ([.[] | select((.model // "") == $provider_model and (.status // "") == "completed" and (.http_status // 0) == 200)] | length) < 2 then "provider_simple_or_tool_incomplete"
      elif ($tool[0].xml_leak_found == true) or ($tool[0].raw_function_calls_found == true) or (($render[0].raw_protocol_absent // false) != true) then "raw_tool_protocol_visible"
      elif ($tool[0].proof_found // false) != true then "tool_evidence_missing"
      elif ($tool[0].process_exited_zero // false) != true then "tool_process_failed"
      elif ($render[0].gpt55_gui_visible // false) != true then "gpt55_gui_response_missing"
      elif ($render[0].gpt56_gui_visible // false) != true then "gpt56_gui_response_missing"
      elif ($render[0].markdown_render_verified // false) != true then "markdown_render_unverified"
      elif ($render[0].tool_gui_verified // false) != true then "tool_gui_unverified"
      elif ((["gpt55-response", "gpt56-response", "provider-markdown", "provider-tool"] - [$screenshots[0][] | select(.captured == true and .target_identity_verified == true) | .role]) | length) > 0
        or ([$screenshots[0][] | select(.captured == true and .target_identity_verified == true and (.role == "before-manual-input" or .role == "before-automated-input"))] | length) == 0 then "target_screenshot_evidence_missing"
      else "complete"
      end
    ' "${usage_file}"
}

stage_checkpoint_verified() {
  local usage_file="$1"
  local screenshot_evidence="$2"
  local role="$3"
  local provider_model="$4"
  local tool_evidence="${5:-}"
  [[ -s "${usage_file}" && -s "${screenshot_evidence}" ]] || return 1
  jq -e 'type == "array"' "${usage_file}" >/dev/null 2>&1 || return 1
  jq -e 'type == "array"' "${screenshot_evidence}" >/dev/null 2>&1 || return 1

  case "${role}" in
    gpt55-response)
      jq -e 'any(.[]; (.provider_id // "") == "openai" and (.model // "") == "gpt-5.5" and (.status // "") == "completed" and (.http_status // 0) == 200)' "${usage_file}" >/dev/null &&
        jq -e --arg role "${role}" '([.[] | select(.role == $role)] | last) as $shot | $shot.captured == true and $shot.target_identity_verified == true and $shot.visual_checks.official55_response_visible == true and $shot.visual_checks.raw_protocol_visible == false' "${screenshot_evidence}" >/dev/null
      ;;
    gpt56-response)
      jq -e 'any(.[]; (.provider_id // "") == "openai" and (.model // "") == "gpt-5.6-luna" and (.status // "") == "completed" and (.http_status // 0) == 200)' "${usage_file}" >/dev/null &&
        jq -e --arg role "${role}" '([.[] | select(.role == $role)] | last) as $shot | $shot.captured == true and $shot.target_identity_verified == true and $shot.visual_checks.official56_response_visible == true and $shot.visual_checks.raw_protocol_visible == false' "${screenshot_evidence}" >/dev/null
      ;;
    provider-markdown)
      jq -e --arg model "${provider_model}" 'any(.[]; (.model // "") == $model and (.status // "") == "completed" and (.http_status // 0) == 200)' "${usage_file}" >/dev/null &&
        jq -e --arg role "${role}" '
          [.[] | select(.role == $role and .captured == true and .target_identity_verified == true)] as $shots
          | ($shots | length) > 0
          and all($shots[]; .visual_checks.raw_protocol_visible != true)
          and any($shots[]; .visual_checks.heading_visible == true)
          and any($shots[]; .visual_checks.numbered_items_visible == true)
          and any($shots[]; .visual_checks.table_headers_visible == true)
          and any($shots[]; .visual_checks.bash_code_visible == true)
          and any($shots[]; .visual_checks.bold_conclusion_visible == true)
        ' "${screenshot_evidence}" >/dev/null
      ;;
    provider-tool)
      [[ -s "${tool_evidence}" ]] &&
        jq -e '.proof_found == true and .function_call_found == true and .function_call_output_found == true and .process_exited_zero == true and .xml_leak_found == false and .raw_function_calls_found == false' "${tool_evidence}" >/dev/null &&
        jq -e --arg model "${provider_model}" '([.[] | select((.model // "") == $model and (.status // "") == "completed" and (.http_status // 0) == 200)] | length) >= 2' "${usage_file}" >/dev/null &&
        jq -e --arg role "${role}" '([.[] | select(.role == $role)] | last) as $shot | $shot.captured == true and $shot.target_identity_verified == true and $shot.visual_checks.tool_marker_visible == true and $shot.visual_checks.tool_execution_visible == true and $shot.visual_checks.raw_protocol_visible == false' "${screenshot_evidence}" >/dev/null
      ;;
    *)
      return 2
      ;;
  esac
}

write_evidence() {
  local manual_status="$1"
  local route_status="$2"
  local config_before="$3"
  local auth_before="$4"
  local config_hash_before="${5:-}"
  local auth_hash_before="${6:-}"
  local notify_hash_before="${7:-}"
  local gateway_port
  local provider_port
  gateway_port="$(cat "${PORT_FILE}" 2>/dev/null || true)"
  provider_port="$(cat "${PROVIDER_PORT_FILE}" 2>/dev/null || true)"
  summarize_usage
  [[ -f "${DESKTOP_TOOL_EVIDENCE}" ]] || printf '{"proof_found":false,"function_call_found":false,"function_call_output_found":false,"process_exited_zero":false,"matched_provider_tool_count":0,"xml_leak_found":false,"raw_function_calls_found":false,"xml_leak_records":[],"event_count":0,"events":[]}\n' >"${DESKTOP_TOOL_EVIDENCE}"
  [[ -f "${DESKTOP_RENDER_EVIDENCE}" ]] || printf '{"gpt55_gui_visible":false,"gpt56_gui_visible":false,"markdown_source_contract_verified":false,"markdown_visual_tokens_verified":false,"markdown_render_verified":false,"raw_protocol_absent":true,"raw_protocol_records":[],"tool_gui_verified":false,"current_run_assistant_message_count":0}\n' >"${DESKTOP_RENDER_EVIDENCE}"
  [[ -f "${SCREENSHOT_EVIDENCE}" ]] || printf '[]\n' >"${SCREENSHOT_EVIDENCE}"
  [[ -f "${AUTOMATED_STAGE_EVIDENCE}" ]] || printf '[]\n' >"${AUTOMATED_STAGE_EVIDENCE}"
  [[ -f "${DESKTOP_WINDOW_IDENTITY}" ]] || printf '{"pid":null,"window_id":null,"width":null,"height":null}\n' >"${DESKTOP_WINDOW_IDENTITY}"
  [[ -f "${APP_WINDOW_IDENTITY}" ]] || printf '{"pid":null,"window_id":null,"width":null,"height":null}\n' >"${APP_WINDOW_IDENTITY}"
  if [[ -n "${gateway_port}" ]] && curl -fsS --max-time 25 "http://127.0.0.1:${gateway_port}/v1/models" >"${OUT}/gateway-models.tmp" 2>/dev/null; then
    mv "${OUT}/gateway-models.tmp" "${OUT}/gateway-models.json"
  else
    rm -f "${OUT}/gateway-models.tmp"
    [[ -f "${OUT}/gateway-models.json" ]] || printf '{"data":[]}\n' >"${OUT}/gateway-models.json"
  fi
  local config_after auth_after config_hash_after auth_hash_after notify_hash_after port18787 port19777 gateway_released
  local source_snapshot_hash_after harness_hash_after ax_driver_hash_after harness_snapshot_hash_after scenario_hash_after product_artifact_hash_after
  local source_snapshot_unchanged harness_unchanged ax_driver_unchanged harness_snapshot_unchanged scenario_unchanged product_artifact_unchanged
  local sandbox_status desktopproof_refs global_guard_passed app_screenshot_sha
  local last_route_evidence official_codex_binary tool_ui_review_status
  config_after="$(file_signature "${GLOBAL_CODEX_CONFIG}")"
  auth_after="$(file_signature "${GLOBAL_CODEX_AUTH}")"
  config_hash_after="$(file_hash "${GLOBAL_CODEX_CONFIG}")"
  auth_hash_after="$(file_hash "${GLOBAL_CODEX_AUTH}")"
  notify_hash_after="$(notify_line_hash "${GLOBAL_CODEX_CONFIG}")"
  source_snapshot_hash_after="$(source_snapshot_hash "${ROOT}")"
  harness_hash_after="$(file_hash "${ROOT}/scripts/codex-desktop-manual-proof.sh")"
  ax_driver_hash_after="$(file_hash "${AX_DRIVER_SOURCE}")"
  harness_snapshot_hash_after="$(harness_snapshot_hash "${ROOT}")"
  scenario_hash_after=""
  [[ -n "${SCENARIO_PATH}" ]] && scenario_hash_after="$(file_hash "${SCENARIO_PATH}")"
  product_artifact_hash_after="$(file_hash "${ZIP_PATH}")"
  source_snapshot_unchanged=false
  harness_unchanged=false
  ax_driver_unchanged=false
  harness_snapshot_unchanged=false
  scenario_unchanged=false
  product_artifact_unchanged=false
  [[ -n "${SOURCE_SNAPSHOT_HASH_BEFORE}" && "${SOURCE_SNAPSHOT_HASH_BEFORE}" == "${source_snapshot_hash_after}" ]] && source_snapshot_unchanged=true
  [[ -n "${HARNESS_HASH_BEFORE}" && "${HARNESS_HASH_BEFORE}" == "${harness_hash_after}" ]] && harness_unchanged=true
  [[ -n "${AX_DRIVER_HASH_BEFORE}" && "${AX_DRIVER_HASH_BEFORE}" == "${ax_driver_hash_after}" ]] && ax_driver_unchanged=true
  [[ -n "${HARNESS_SNAPSHOT_HASH_BEFORE}" && "${HARNESS_SNAPSHOT_HASH_BEFORE}" == "${harness_snapshot_hash_after}" ]] && harness_snapshot_unchanged=true
  [[ -z "${SCENARIO_PATH}" || ( -n "${SCENARIO_HASH_BEFORE}" && "${SCENARIO_HASH_BEFORE}" == "${scenario_hash_after}" ) ]] && scenario_unchanged=true
  [[ -n "${APP_ZIP_SHA256}" && "${APP_ZIP_SHA256}" == "${product_artifact_hash_after}" ]] && product_artifact_unchanged=true
  last_route_evidence=""
  [[ -f "${LAST_ROUTE_OUT}/evidence.json" ]] && last_route_evidence="${LAST_ROUTE_OUT}/evidence.json"
  official_codex_binary="$(jq -r '.official_passthrough.codex_binary // ""' "${PROVIDER_CONFIG}" 2>/dev/null || true)"
  tool_ui_review_status="$(desktop_gui_tool_ui_review_status \
    "${PROOF_INPUT_MODE}" \
    "$(jq -r '.proof_found // false' "${DESKTOP_TOOL_EVIDENCE}")" \
    "$(jq -r '.tool_gui_verified // false' "${DESKTOP_RENDER_EVIDENCE}")")"
  sandbox_status="$(cat "${DESKTOP_SANDBOX_STATUS_FILE}" 2>/dev/null || printf disabled)"
  app_screenshot_sha=""
  [[ -s "${APP_SCREENSHOT}" ]] && app_screenshot_sha="$(/usr/bin/shasum -a 256 "${APP_SCREENSHOT}" | awk '{print $1}')"
  desktopproof_refs=false
  if [[ -f "${GLOBAL_CODEX_CONFIG}" ]] && grep -Fq "${CODEX_HOME_DIR}/computer-use/" "${GLOBAL_CODEX_CONFIG}"; then
    desktopproof_refs=true
  fi
  global_guard_passed=false
  if [[ "${config_before}" == "${config_after}" && "${auth_before}" == "${auth_after}" && "${config_hash_before}" == "${config_hash_after}" && "${auth_hash_before}" == "${auth_hash_after}" && "${notify_hash_before}" == "${notify_hash_after}" ]]; then
    global_guard_passed=true
  fi
  port18787=false
  port19777=false
  gateway_released=false
  port_is_free 18787 && port18787=true
  port_is_free 19777 && port19777=true
  [[ -n "${gateway_port}" ]] && port_is_free "${gateway_port}" && gateway_released=true
	  jq -n \
    --arg proof_root "${PROOF_ROOT}" \
    --arg manual_status "${manual_status}" \
    --arg route_status "${route_status}" \
    --arg config_before "${config_before}" \
    --arg config_after "${config_after}" \
    --arg auth_before "${auth_before}" \
    --arg auth_after "${auth_after}" \
    --arg config_hash_before "${config_hash_before}" \
    --arg config_hash_after "${config_hash_after}" \
    --arg auth_hash_before "${auth_hash_before}" \
    --arg auth_hash_after "${auth_hash_after}" \
    --arg notify_hash_before "${notify_hash_before}" \
    --arg notify_hash_after "${notify_hash_after}" \
    --arg source_snapshot_hash_before "${SOURCE_SNAPSHOT_HASH_BEFORE}" \
    --arg source_snapshot_hash_after "${source_snapshot_hash_after}" \
    --arg harness_hash_before "${HARNESS_HASH_BEFORE}" \
    --arg harness_hash_after "${harness_hash_after}" \
    --arg ax_driver_hash_before "${AX_DRIVER_HASH_BEFORE}" \
    --arg ax_driver_hash_after "${ax_driver_hash_after}" \
    --arg harness_snapshot_hash_before "${HARNESS_SNAPSHOT_HASH_BEFORE}" \
    --arg harness_snapshot_hash_after "${harness_snapshot_hash_after}" \
    --arg scenario_hash_before "${SCENARIO_HASH_BEFORE}" \
    --arg scenario_hash_after "${scenario_hash_after}" \
    --arg product_artifact_hash_after "${product_artifact_hash_after}" \
    --arg gateway_port "${gateway_port}" \
    --arg provider_port "${provider_port}" \
    --arg started_at "${STARTED_AT}" \
    --arg sandbox_status "${sandbox_status}" \
    --arg proof_scope "${PROOF_SCOPE}" \
    --arg input_mode "${PROOF_INPUT_MODE}" \
    --arg automated_profile "${AUTOMATED_PROFILE}" \
    --arg provider_model "${PROOF_PROVIDER_MODEL_ID}" \
    --arg official_codex_binary "${official_codex_binary}" \
    --arg tool_ui_review_status "${tool_ui_review_status}" \
    --arg desktop_codex_binary "${CODEX_CLI_BINARY}" \
    --arg last_route_evidence "${last_route_evidence}" \
    --arg current_zip_sha256 "${APP_ZIP_SHA256}" \
    --arg zip_build_time_utc "${APP_ZIP_BUILD_TIME_UTC}" \
    --arg extracted_app_path "${APP_BUNDLE}" \
    --arg app_screenshot_path "${APP_SCREENSHOT}" \
    --arg app_screenshot_sha256 "${app_screenshot_sha}" \
    --argjson app_launched "${RELAYKIT_APP_LAUNCHED}" \
    --argjson port18787 "${port18787}" \
    --argjson port19777 "${port19777}" \
    --argjson gateway_released "${gateway_released}" \
    --argjson desktopproof_refs "${desktopproof_refs}" \
    --argjson global_guard_passed "${global_guard_passed}" \
    --argjson source_snapshot_unchanged "${source_snapshot_unchanged}" \
    --argjson harness_unchanged "${harness_unchanged}" \
    --argjson ax_driver_unchanged "${ax_driver_unchanged}" \
    --argjson harness_snapshot_unchanged "${harness_snapshot_unchanged}" \
    --argjson scenario_unchanged "${scenario_unchanged}" \
    --argjson product_artifact_unchanged "${product_artifact_unchanged}" \
    --argjson human_intervention_count "${HUMAN_INTERVENTION_COUNT}" \
    --slurpfile gateway "${OUT}/gateway-models.json" \
    --slurpfile app_server "${OUT}/app-server.json" \
    --slurpfile usage "${OUT}/usage-events.json" \
    --slurpfile tool "${DESKTOP_TOOL_EVIDENCE}" \
    --slurpfile render "${DESKTOP_RENDER_EVIDENCE}" \
    --slurpfile screenshots "${SCREENSHOT_EVIDENCE}" \
    --slurpfile window_identity "${DESKTOP_WINDOW_IDENTITY}" \
    --slurpfile app_window_identity "${APP_WINDOW_IDENTITY}" \
    --slurpfile automated_stages "${AUTOMATED_STAGE_EVIDENCE}" \
    '{
      proof_root: $proof_root,
      manual_status: $manual_status,
      route_proof_status: $route_status,
      proof_scope: $proof_scope,
      proof_origin: "tracked_harness_current_run",
      input_mode: $input_mode,
      automated_profile: $automated_profile,
      started_at: $started_at,
      source_snapshot_sha256_before: $source_snapshot_hash_before,
      source_snapshot_sha256_after: $source_snapshot_hash_after,
      source_snapshot_unchanged: $source_snapshot_unchanged,
      manual_proof_harness_sha256_before: $harness_hash_before,
      manual_proof_harness_sha256_after: $harness_hash_after,
      manual_proof_harness_unchanged: $harness_unchanged,
      ax_driver_sha256_before: $ax_driver_hash_before,
      ax_driver_sha256_after: $ax_driver_hash_after,
      ax_driver_unchanged: $ax_driver_unchanged,
      product_artifact_sha256: (if $product_artifact_unchanged then $current_zip_sha256 else null end),
      product_artifact_sha256_before: (if $current_zip_sha256 == "" then null else $current_zip_sha256 end),
      product_artifact_sha256_after: (if $product_artifact_hash_after == "missing" then null else $product_artifact_hash_after end),
      product_artifact_unchanged: $product_artifact_unchanged,
      harness_sha256: (if $harness_snapshot_unchanged then $harness_snapshot_hash_after else null end),
      harness_sha256_before: $harness_snapshot_hash_before,
      harness_sha256_after: $harness_snapshot_hash_after,
      harness_unchanged: $harness_snapshot_unchanged,
      scenario_sha256: (if $scenario_hash_after == "" or ($scenario_unchanged | not) then null else $scenario_hash_after end),
      scenario_sha256_before: (if $scenario_hash_before == "" then null else $scenario_hash_before end),
      scenario_sha256_after: (if $scenario_hash_after == "" then null else $scenario_hash_after end),
      scenario_unchanged: $scenario_unchanged,
      human_intervention_count: $human_intervention_count,
      automated_stages: ($automated_stages[0] // []),
      gateway_port: $gateway_port,
      provider_port: $provider_port,
      relaykit_app: {
        relaykit_app_launched_from_extracted_zip: $app_launched,
        launch_method: (if $app_launched then "launchservices_open_extracted_app_with_isolated_config_override" else "not_launched_for_fixture_setup" end),
        extracted_app_path: $extracted_app_path,
        current_zip_sha256: $current_zip_sha256,
        zip_build_time_utc: $zip_build_time_utc,
        process_and_gateway_ready_observed_before_desktop: $app_launched,
        window_identity: ($app_window_identity[0] // {}),
        screenshot_path: (if $app_screenshot_sha256 == "" then null else $app_screenshot_path end),
        screenshot_sha256: (if $app_screenshot_sha256 == "" then null else $app_screenshot_sha256 end)
      },
      last_route_evidence_path: (if $last_route_evidence == "" then null else $last_route_evidence end),
      gateway_health_ok: (($gateway[0].data // []) | length > 0),
      gateway_models_include_provider: (([$gateway[0].data[]?.id] | index("gpt-5.5")) and ([$gateway[0].data[]?.id] | index($provider_model))),
      gateway_model_health: {healthy: (($gateway[0].data // []) | length)},
      generated_config_model: "gpt-5.5",
      official_passthrough_codex_binary: (if $official_codex_binary == "" then null else $official_codex_binary end),
      official_passthrough_uses_desktop_bundled_cli: ($official_codex_binary != "" and $official_codex_binary == $desktop_codex_binary and ($official_codex_binary | startswith("/"))),
      app_server_demo_models: ($app_server[0].provider // []),
      app_server_official_models: ($app_server[0].official // []),
      isolated_app_server_lists_official_and_provider: (([$app_server[0].official[]?.model] | index("gpt-5.5")) and ([$app_server[0].provider[]?.model] | index($provider_model))),
      official_picker_has_spark: (([$app_server[0].official[]?.model] | index("gpt-5.3-codex-spark")) != null),
      official_picker_excludes_gpt52: (([$app_server[0].official[]?.model] | index("gpt-5.2")) == null and ([$gateway[0].data[]?.id] | index("gpt-5.2")) == null),
      usage_event_count: ($usage[0] | length),
      usage_models: ($usage[0] | map(.model) | unique | sort),
      provider_model_public_id: $provider_model,
      usage_official_completed_count: ([$usage[0][] | select(.provider_id == "openai" and .model == "gpt-5.5" and (.status // "") == "completed" and (.http_status // 0) == 200)] | length),
      usage_gpt56_completed_count: ([$usage[0][] | select(.provider_id == "openai" and .model == "gpt-5.6-luna" and (.status // "") == "completed" and (.http_status // 0) == 200)] | length),
      usage_official_auth_required_count: ([$usage[0][] | select(.provider_id == "openai" and (.error_type // "") == "auth_required")] | length),
      usage_official_refresh_revoked_count: ([$usage[0][] | select(.provider_id == "openai" and ((.error_type // "") | test("refresh(_token)?_revoked|token_revoked")))] | length),
      usage_provider_completed_count: ([$usage[0][] | select(.model == $provider_model and (.status // "") == "completed" and (.http_status // 0) == 200)] | length),
      usage_unknown_model_count: ([$usage[0][] | select((.error_type // "") == "unknown_model")] | length),
      gpt56_gui_completed: (
        ([$usage[0][] | select(.provider_id == "openai" and .model == "gpt-5.6-luna" and (.status // "") == "completed" and (.http_status // 0) == 200)] | length) > 0
        and ($render[0].gpt56_gui_visible // false)
      ),
      markdown_render_verified: ($render[0].markdown_render_verified // false),
      raw_protocol_absent: (($render[0].raw_protocol_absent // false) and ($tool[0].xml_leak_found != true) and ($tool[0].raw_function_calls_found != true)),
      tool_gui_verified: (($render[0].tool_gui_verified // false) and ($tool[0].proof_found // false) and ($tool[0].process_exited_zero // false)),
      official_auth_status: (
        if ([$usage[0][] | select(.provider_id == "openai" and ((.error_type // "") | test("refresh(_token)?_revoked|token_revoked")))] | length) > 0 then "refresh_revoked"
        elif ([$usage[0][] | select(.provider_id == "openai" and (.error_type // "") == "auth_required")] | length) > 0 then "auth_required"
        elif ([$usage[0][] | select(.provider_id == "openai" and .model == "gpt-5.5" and (.status // "") == "completed" and (.http_status // 0) == 200)] | length) > 0
          and ([$usage[0][] | select(.provider_id == "openai" and .model == "gpt-5.6-luna" and (.status // "") == "completed" and (.http_status // 0) == 200)] | length) > 0 then "verified"
        else "not_attempted"
        end
      ),
      provider_route_status: (
        if ([$usage[0][] | select(.model == $provider_model and (.status // "") == "completed" and (.http_status // 0) == 200)] | length) > 0 then "verified"
        else "not_verified"
        end
      ),
      fresh_current_run_usage_event: (($usage[0] | length) > 0),
      desktop_gui_route_proof: (
        if $route_status == "complete" and $input_mode == "automated_ax" and $human_intervention_count == 0 and $automated_profile == "standard_four_stage_dogfood" then "automated_gui_complete"
        elif $route_status == "complete" and $input_mode == "automated_ax" and $human_intervention_count == 0 and ($automated_profile == "single_tool_scenario" or $automated_profile == "custom_scenario") then "automated_custom_scenario_complete"
        elif $route_status == "complete" and $input_mode == "manual_user_only" then "manual_user_assisted_complete"
        elif $route_status == "same_profile_cli_route_complete" then "not_complete_cli_fallback"
        else "not_complete"
        end
      ),
      desktop_window_identity: ($window_identity[0] // {}),
      process_bound_screenshots: ($screenshots[0] // []),
      desktop_tool_evidence: ($tool[0] // {}),
      desktop_render_evidence: ($render[0] // {}),
      tool_call_completed: ($tool[0].function_call_found // false),
      tool_output_visible: (($tool[0].function_call_output_found // false) and ($tool[0].process_exited_zero // false)),
      raw_xml_absent: (($tool[0].xml_leak_found != true) and ($render[0].raw_protocol_absent // false)),
      raw_function_calls_absent: (($tool[0].raw_function_calls_found != true) and ($render[0].raw_protocol_absent // false)),
      desktop_gui_tool_ui_review: $tool_ui_review_status,
      mock_ok_used: false,
      old_usage_evidence_used: false,
      public_fixture_route_proof_allowed: false,
      official_preflight_route_evidence_allowed: false,
      global_config_signature_before: $config_before,
      global_config_signature_after: $config_after,
      global_auth_signature_before: $auth_before,
      global_auth_signature_after: $auth_after,
      global_config_unchanged: ($config_before == $config_after),
      global_auth_unchanged: ($auth_before == $auth_after),
      global_config_sha256_before: $config_hash_before,
      global_config_sha256_after: $config_hash_after,
      global_auth_sha256_before: $auth_hash_before,
      global_auth_sha256_after: $auth_hash_after,
      global_config_content_unchanged: ($config_hash_before == $config_hash_after),
      global_auth_content_unchanged: ($auth_hash_before == $auth_hash_after),
      global_config_notify_sha256_before: $notify_hash_before,
      global_config_notify_sha256_after: $notify_hash_after,
      global_config_notify_unchanged: ($notify_hash_before == $notify_hash_after),
      global_state_guard_passed: $global_guard_passed,
      desktop_sandbox_profile: $sandbox_status,
      global_config_write_repair_attempted: false,
      global_config_desktopproof_reference_present: $desktopproof_refs,
      shared_18787_free_after: $port18787,
      shared_19777_free_after: $port19777,
      gateway_port_released: $gateway_released
    }' >"${OUT}/evidence.json"
  cp "${OUT}/usage-events.json" "${OUT}/usage-proof.json"
}

setup_preflight() {
  local setup_scope="${1:-fixture}"
  ensure_dirs
  cleanup_processes
  reset_run_markers
  STARTED_AT="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  capture_source_state
  preserve_existing_route_evidence
  rm -rf "${OUT}"
  mkdir -p "${OUT}" "${SCREENSHOT_DIR}"
  printf '[]\n' >"${SCREENSHOT_EVIDENCE}"
  printf '{"proof_found":false,"function_call_found":false,"function_call_output_found":false,"process_exited_zero":false,"matched_provider_tool_count":0,"xml_leak_found":false,"raw_function_calls_found":false,"xml_leak_records":[],"event_count":0,"events":[]}\n' >"${DESKTOP_TOOL_EVIDENCE}"
  printf '{"gpt55_gui_visible":false,"gpt56_gui_visible":false,"markdown_source_contract_verified":false,"markdown_visual_tokens_verified":false,"markdown_render_verified":false,"raw_protocol_absent":true,"raw_protocol_records":[],"tool_gui_verified":false,"current_run_assistant_message_count":0}\n' >"${DESKTOP_RENDER_EVIDENCE}"
  : >"${USAGE_PATH}"
  chmod 600 "${USAGE_PATH}"
  prepare_extracted_app
  APP_SERVER_SETUP_ID="desktop-proof-${APP_ZIP_SHA256:0:16}"
  APP_SERVER_SESSION_ID="desktop-proof:${STARTED_AT}:$$"

  local provider_port="" gateway_port
  if [[ "${setup_scope}" == "real" ]]; then
    gateway_port=19777
  else
    gateway_port="$(free_port)"
  fi
  echo "${gateway_port}" >"${PORT_FILE}"

  if [[ "${setup_scope}" == "real" ]]; then
    rm -f "${PROVIDER_PORT_FILE}"
    prepare_real_provider_config
  else
    PROOF_SCOPE="fixture_plumbing_preflight"
    PROOF_PROVIDER_MODEL_ID="desktop-proof-demo/claude-haiku-4-5"
    provider_port="$(free_port)"
    while [[ "${provider_port}" == "${gateway_port}" ]]; do
      provider_port="$(free_port)"
    done
    echo "${provider_port}" >"${PROVIDER_PORT_FILE}"
    start_provider "${provider_port}"
    write_provider_config "${provider_port}"
  fi
  write_catalog
  write_codex_config "${gateway_port}"
  if [[ "${setup_scope}" == "real" ]]; then
    launch_isolated_relaykit_app
  else
    start_gateway "${gateway_port}"
  fi

  CFFIXED_USER_HOME="${ISO_HOME}" HOME="${ISO_HOME}" CODEX_HOME="${CODEX_HOME_DIR}" "${CODEX_CLI_BINARY}" debug models >"${OUT}/codex-debug-models.json"
  if [[ "${setup_scope}" == "real" ]]; then
    jq -e --arg provider_model "${PROOF_PROVIDER_MODEL_ID}" '
      ([.models[].slug] | index("gpt-5.5")) != null and
      ([.models[].slug] | index("gpt-5.6-luna")) != null and
      ([.models[].slug] | index("gpt-5.3-codex-spark")) != null and
      ([.models[].slug] | index($provider_model)) != null and
      ([.models[].slug] | index("gpt-5.2")) == null
    ' "${OUT}/codex-debug-models.json" >/dev/null
  else
    jq -e --arg provider_model "${PROOF_PROVIDER_MODEL_ID}" '([.models[].slug] | index("gpt-5.5") and index($provider_model))' "${OUT}/codex-debug-models.json" >/dev/null
  fi
  write_app_server_evidence
  if [[ "${setup_scope}" == "real" ]]; then
    jq -e --arg provider_model "${PROOF_PROVIDER_MODEL_ID}" '
      .config.model == "gpt-5.5" and
      ([.official[].model] | index("gpt-5.5")) != null and
      ([.official[].model] | index("gpt-5.6-luna")) != null and
      ([.official[].model] | index("gpt-5.3-codex-spark")) != null and
      ([.official[].model] | index("gpt-5.2")) == null and
      ([.provider[].model] | index($provider_model)) != null
    ' "${OUT}/app-server.json" >/dev/null
  else
    jq -e --arg provider_model "${PROOF_PROVIDER_MODEL_ID}" '.config.model == "gpt-5.5" and ([.official[].model] | index("gpt-5.5")) and ([.provider[].model] | index($provider_model))' "${OUT}/app-server.json" >/dev/null
  fi
  if [[ "${setup_scope}" == "real" ]]; then
    ensure_provider_models_available_via_app
  else
    curl -fsS --max-time 25 "http://127.0.0.1:${gateway_port}/v1/models" >"${OUT}/gateway-models.json"
  fi
  if [[ "${setup_scope}" == "real" ]]; then
    jq -e --arg provider_model "${PROOF_PROVIDER_MODEL_ID}" '
      ([.data[].id] | index("gpt-5.5")) != null and
      ([.data[].id] | index("gpt-5.6-luna")) != null and
      ([.data[].id] | index("gpt-5.3-codex-spark")) != null and
      ([.data[].id] | index($provider_model)) != null and
      ([.data[].id] | index("gpt-5.2")) == null
    ' "${OUT}/gateway-models.json" >/dev/null
  else
    jq -e --arg provider_model "${PROOF_PROVIDER_MODEL_ID}" '([.data[].id] | index("gpt-5.5") and index($provider_model))' "${OUT}/gateway-models.json" >/dev/null
  fi
}

find_desktop_pid() {
  local pid command
  while IFS= read -r pid; do
    command="$(ps -p "${pid}" -o command= 2>/dev/null || true)"
    case "${command}" in
      "${CODEX_APP_BINARY} --user-data-dir=${DESKTOP_USER_DATA_DIR}"*)
        printf '%s\n' "${pid}"
        return 0
        ;;
    esac
  done < <(pgrep -f -- "--user-data-dir=${DESKTOP_USER_DATA_DIR}" 2>/dev/null || true)
  return 1
}

write_current_desktop_window_identity() {
  local desktop_pid="$1"
  swift - "${desktop_pid}" <<'SWIFT'
import CoreGraphics
import Foundation

let targetPID = Int(CommandLine.arguments[1])!
let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
func windowBounds(_ window: [String: Any]) -> CGRect? {
    guard let values = window[kCGWindowBounds as String] as? [String: Any],
          let x = values["X"] as? NSNumber,
          let y = values["Y"] as? NSNumber,
          let width = values["Width"] as? NSNumber,
          let height = values["Height"] as? NSNumber else {
        return nil
    }
    return CGRect(x: x.doubleValue, y: y.doubleValue, width: width.doubleValue, height: height.doubleValue)
}
let candidates = windows.compactMap { window -> (Int, CGRect)? in
    guard let ownerPID = window[kCGWindowOwnerPID as String] as? Int,
          ownerPID == targetPID,
          let windowID = window[kCGWindowNumber as String] as? Int,
          let bounds = windowBounds(window),
          bounds.width >= 400,
          bounds.height >= 400 else {
        return nil
    }
    return (windowID, bounds)
}
guard let selected = candidates.max(by: { $0.1.width * $0.1.height < $1.1.width * $1.1.height }) else {
    exit(1)
}
let value: [String: Any] = [
    "pid": targetPID,
    "window_id": selected.0,
    "width": Int(selected.1.width),
    "height": Int(selected.1.height),
    "captured_at": ISO8601DateFormatter().string(from: Date()),
]
let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
FileHandle.standardOutput.write(data)
FileHandle.standardOutput.write(Data("\n".utf8))
SWIFT
}

verify_desktop_window_identity() {
  [[ -s "${DESKTOP_WINDOW_IDENTITY}" ]] || return 1
  local expected_pid expected_window_id resolved_pid
  expected_pid="$(jq -r '.pid // empty' "${DESKTOP_WINDOW_IDENTITY}")"
  expected_window_id="$(jq -r '.window_id // empty' "${DESKTOP_WINDOW_IDENTITY}")"
  resolved_pid="$(find_desktop_pid || true)"
  [[ -n "${expected_pid}" && -n "${expected_window_id}" && "${resolved_pid}" == "${expected_pid}" ]] || return 1
  swift - "${expected_pid}" "${expected_window_id}" <<'SWIFT'
import CoreGraphics
import Foundation

let expectedPID = Int(CommandLine.arguments[1])!
let expectedWindowID = Int(CommandLine.arguments[2])!
let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
func windowBounds(_ window: [String: Any]) -> CGRect? {
    guard let values = window[kCGWindowBounds as String] as? [String: Any],
          let x = values["X"] as? NSNumber,
          let y = values["Y"] as? NSNumber,
          let width = values["Width"] as? NSNumber,
          let height = values["Height"] as? NSNumber else {
        return nil
    }
    return CGRect(x: x.doubleValue, y: y.doubleValue, width: width.doubleValue, height: height.doubleValue)
}
let matched = windows.contains { window in
    guard let ownerPID = window[kCGWindowOwnerPID as String] as? Int,
          let windowID = window[kCGWindowNumber as String] as? Int,
          ownerPID == expectedPID,
          windowID == expectedWindowID,
          let bounds = windowBounds(window) else {
        return false
    }
    return bounds.width >= 400 && bounds.height >= 400
}
exit(matched ? 0 : 1)
SWIFT
}

activate_isolated_desktop() {
  local desktop_pid
  desktop_pid="$(jq -r '.pid // empty' "${DESKTOP_WINDOW_IDENTITY}")"
  [[ -n "${desktop_pid}" ]] || return 1
  swift - "${desktop_pid}" <<'SWIFT'
import AppKit
import ApplicationServices
import Foundation

let targetPID = pid_t(Int(CommandLine.arguments[1])!)
guard let app = NSRunningApplication(processIdentifier: targetPID) else { exit(1) }
let accessibilityApp = AXUIElementCreateApplication(targetPID)
app.unhide()
for _ in 0..<40 {
    _ = app.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
    AXUIElementSetAttributeValue(accessibilityApp, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
    if NSWorkspace.shared.frontmostApplication?.processIdentifier == targetPID {
        exit(0)
    }
    Thread.sleep(forTimeInterval: 0.1)
}
exit(3)
SWIFT
}

analyze_desktop_screenshot() {
  local role="$1"
  local path="$2"
  local marker="${3:-}"
  local expectation="${4:-}"
  swift - "${path}" "${role}" "${marker}" "${expectation}" <<'SWIFT'
import AppKit
import Foundation
import Vision

guard CommandLine.arguments.count >= 3 else { exit(2) }
let imagePath = CommandLine.arguments[1]
let role = CommandLine.arguments[2]
let marker = CommandLine.arguments.count > 3 ? CommandLine.arguments[3] : ""
let expectation = CommandLine.arguments.count > 4 ? CommandLine.arguments[4] : ""
guard let image = NSImage(contentsOfFile: imagePath) else { exit(3) }
var rect = NSRect(origin: .zero, size: image.size)
guard let cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { exit(4) }

let request = VNRecognizeTextRequest()
request.recognitionLevel = .accurate
request.usesLanguageCorrection = false
request.recognitionLanguages = ["en-US", "zh-Hans"]
let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
do {
    try handler.perform([request])
} catch {
    exit(5)
}

let observations = (request.results ?? [])
    .filter { $0.boundingBox.minX >= 0.23 }
let lines = observations.compactMap { $0.topCandidates(1).first?.string }
let assistantObservations = observations
    .filter { $0.boundingBox.minY < 0.92 && $0.boundingBox.minY > 0.15 }
let assistantLines = assistantObservations.compactMap { $0.topCandidates(1).first?.string }
let combined = lines.joined(separator: "\n")
func compact(_ value: String) -> String {
    String(value.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
}
func occurrences(_ haystack: String, _ needle: String) -> Int {
    guard !needle.isEmpty else { return 0 }
    return haystack.components(separatedBy: needle).count - 1
}

let normalized = compact(combined)
let assistantNormalizedLines = assistantLines.map(compact)
let markerNormalized = compact(marker)
let rawProtocolVisible = ["functioncalls", "toolcall", "functioncallxml", "invoketool", "parametername"].contains { normalized.contains($0) }
let authErrorVisible = [
    "relaykitofficialcodexloginisnotconnected",
    "authrequired",
    "loginrequired",
    "401unauthorized",
    "unexpectedstatus401unauthorized",
    "refreshtokenrevoked",
].contains { normalized.contains($0) }

var checks: [String: Any] = [
    "ocr_completed": true,
    "recognized_line_count": lines.count,
    "assistant_response_line_count": assistantLines.count,
    "raw_protocol_visible": rawProtocolVisible,
    "auth_error_visible": authErrorVisible,
    "official55_response_visible": false,
    "official56_response_visible": false,
    "heading_visible": false,
    "numbered_items_visible": false,
    "table_headers_visible": false,
    "bash_code_visible": false,
    "bold_conclusion_visible": false,
    "tool_marker_visible": false,
    "tool_execution_visible": false,
    "response_marker_visible": false,
]

func assistantLineEquals(_ value: String) -> Bool {
    let expected = compact(value)
    return assistantNormalizedLines.contains { $0 == expected }
}

func assistantExactLineCount(_ value: String) -> Int {
    let expected = compact(value)
    return assistantNormalizedLines.filter { $0 == expected }.count
}

func assistantTokensShareVisualRow(_ leftValue: String, _ rightValue: String) -> Bool {
    let leftExpected = compact(leftValue)
    let rightExpected = compact(rightValue)
    let tokens = assistantObservations.compactMap { observation -> (text: String, box: CGRect)? in
        guard let text = observation.topCandidates(1).first?.string else { return nil }
        return (compact(text), observation.boundingBox)
    }
    for left in tokens where left.text == leftExpected {
        for right in tokens where right.text == rightExpected {
            let horizontalGap = right.box.minX - left.box.maxX
            if abs(left.box.minY - right.box.minY) <= 0.02 && horizontalGap >= -0.02 && horizontalGap <= 0.12 {
                return true
            }
        }
    }
    return false
}

func applyMarkdownChecks() {
    checks["heading_visible"] = assistantLineEquals("RelayKit Rich Text Check")
    checks["numbered_items_visible"] =
        assistantLineEquals("1. First route check") && assistantLineEquals("2. Second route check")
    checks["table_headers_visible"] =
        assistantLineEquals("status") && assistantLineEquals("route") &&
        assistantExactLineCount("ready") >= 2 &&
        assistantLineEquals("official") && assistantLineEquals("provider")
    checks["bash_code_visible"] = assistantLineEquals("bash") &&
        (assistantLineEquals("echo relaykit") || assistantTokensShareVisualRow("echo", "relaykit"))
    checks["bold_conclusion_visible"] = assistantLineEquals("RELAYKIT_FORMAT_OK")
}

if !markerNormalized.isEmpty {
    checks["response_marker_visible"] = occurrences(normalized, markerNormalized) >= 2
}

switch expectation.isEmpty ? role : expectation {
case "gpt55-response":
    checks["official55_response_visible"] = occurrences(normalized, "relaykitofficial55live") >= 2
case "gpt56-response":
    checks["official56_response_visible"] = occurrences(normalized, "relaykitofficial56live") >= 2
case "provider-markdown":
    applyMarkdownChecks()
case "provider-tool":
    checks["tool_marker_visible"] = !markerNormalized.isEmpty && occurrences(normalized, markerNormalized) >= 2
    checks["tool_execution_visible"] =
        normalized.contains("processexitedwithcode0") || occurrences(normalized, "printf") >= 2
case "plain":
    break
case "markdown":
    applyMarkdownChecks()
case "tool":
    checks["tool_marker_visible"] = !markerNormalized.isEmpty && occurrences(normalized, markerNormalized) >= 2
    checks["tool_execution_visible"] = normalized.contains("processexitedwithcode0") || occurrences(normalized, "printf") >= 2
default:
    break
}

let data = try JSONSerialization.data(withJSONObject: checks, options: [.sortedKeys])
FileHandle.standardOutput.write(data)
FileHandle.standardOutput.write(Data([0x0a]))
SWIFT
}

capture_desktop_window() {
  local role="$1"
  local marker_override="${2:-}"
  local expectation="${3:-}"
  verify_desktop_window_identity || {
    echo "isolated Codex Desktop PID/window identity changed before ${role}" >&2
    return 1
  }
  local window_id path relative_path sha timestamp tmp visual_tmp marker attempt
  window_id="$(jq -er '.window_id' "${DESKTOP_WINDOW_IDENTITY}")" || return 1
  attempt="$(jq -er --arg role "${role}" '[.[] | select(.role == $role)] | length + 1' "${SCREENSHOT_EVIDENCE}")" || return 1
  path="${SCREENSHOT_DIR}/${role}-${attempt}.png"
  relative_path="${path#${ROOT}/}"
  /usr/sbin/screencapture -x -l "${window_id}" "${path}" || return 1
  [[ -s "${path}" ]] || return 1
  sha="$(/usr/bin/shasum -a 256 "${path}" | awk '{print $1}')" || return 1
  timestamp="$(date -u +"%Y-%m-%dT%H:%M:%SZ")" || return 1
  marker="${marker_override}"
  [[ -z "${marker}" && -f "${TOOL_MARKER_FILE}" ]] && marker="$(cat "${TOOL_MARKER_FILE}")"
  visual_tmp="${RUN_DIR}/desktop-visual-${role}-${attempt}.json"
  analyze_desktop_screenshot "${role}" "${path}" "${marker}" "${expectation}" >"${visual_tmp}" || return 1
  jq -e 'type == "object" and .ocr_completed == true' "${visual_tmp}" >/dev/null || return 1
  tmp="${SCREENSHOT_EVIDENCE}.tmp"
  jq \
    --arg role "${role}" \
    --arg path "${relative_path}" \
    --arg sha "${sha}" \
    --arg timestamp "${timestamp}" \
    --slurpfile visual "${visual_tmp}" \
    --slurpfile identity "${DESKTOP_WINDOW_IDENTITY}" \
    '. + [{
      role: $role,
      path: $path,
      sha256: $sha,
      captured_at: $timestamp,
      pid: $identity[0].pid,
      window_id: $identity[0].window_id,
      width: $identity[0].width,
      height: $identity[0].height,
      captured: true,
      target_identity_verified: true,
      visual_checks: $visual[0]
    }]' "${SCREENSHOT_EVIDENCE}" >"${tmp}" || return 1
  mv "${tmp}" "${SCREENSHOT_EVIDENCE}" || return 1
  rm -f "${visual_tmp}"
}

wait_for_desktop_window() {
  local desktop_pid=""
  for _ in {1..80}; do
    desktop_pid="$(find_desktop_pid || true)"
    [[ -n "${desktop_pid}" ]] && break
    sleep 0.25
  done
  if [[ -z "${desktop_pid}" ]]; then
    echo "Codex Desktop did not start with isolated user data dir: ${DESKTOP_USER_DATA_DIR}" >&2
    return 1
  fi
  echo "${desktop_pid}" >"${DESKTOP_PID_FILE}"

  local identity=""
  for _ in {1..80}; do
    identity="$(write_current_desktop_window_identity "${desktop_pid}" 2>/dev/null || true)"
    [[ -n "${identity}" ]] && break
    sleep 0.25
  done
  if [[ -z "${identity}" ]]; then
    echo "Codex Desktop process started without an isolated GUI window" >&2
    return 1
  fi
  printf '%s\n' "${identity}" >"${DESKTOP_WINDOW_IDENTITY}"
  verify_desktop_window_identity
}

desktop_ui_ready() {
  local desktop_pid="$1"
  swift - "${desktop_pid}" <<'SWIFT'
import ApplicationServices
import Foundation

let targetPID = pid_t(Int(CommandLine.arguments[1])!)
let app = AXUIElementCreateApplication(targetPID)

func attribute(_ element: AXUIElement, _ name: CFString) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name, &value) == .success else { return nil }
    return value
}

func text(_ element: AXUIElement, _ name: CFString) -> String {
    attribute(element, name) as? String ?? ""
}

func children(_ element: AXUIElement) -> [AXUIElement] {
    attribute(element, kAXChildrenAttribute as CFString) as? [AXUIElement] ?? []
}

let windows = attribute(app, kAXWindowsAttribute as CFString) as? [AXUIElement] ?? []
var visited = 0
var buttonCount = 0
var groupCount = 0

func walk(_ element: AXUIElement, depth: Int = 0) {
    guard depth <= 18, visited < 2000 else { return }
    visited += 1
    switch text(element, kAXRoleAttribute as CFString) {
    case kAXButtonRole as String:
        buttonCount += 1
    case kAXGroupRole as String:
        groupCount += 1
    default:
        break
    }
    for child in children(element) {
        walk(child, depth: depth + 1)
    }
}

for window in windows {
    walk(window)
}
exit(!windows.isEmpty && visited >= 10 && buttonCount >= 3 && groupCount >= 5 ? 0 : 1)
SWIFT
}

wait_for_desktop_ui_ready() {
  local desktop_pid ready_report
  desktop_pid="$(cat "${DESKTOP_PID_FILE}" 2>/dev/null || true)"
  [[ -n "${desktop_pid}" ]] || return 1
  if [[ "${PROOF_INPUT_MODE}" == "automated_ax" ]]; then
    [[ -x "${AX_DRIVER_BINARY}" && -s "${AUTOMATED_CATALOG_LABELS_FILE}" ]] || {
      echo "automated Desktop readiness inputs are unavailable" >&2
      return 1
    }
    ready_report="${RUN_DIR}/ax-ready.json"
    for _ in {1..120}; do
      /usr/bin/osascript -e "tell application \"System Events\" to tell first process whose unix id is ${desktop_pid} to set frontmost to true" >/dev/null 2>&1 || true
      if "${AX_DRIVER_BINARY}" ready \
          --pid "${desktop_pid}" \
          --window-identity "${DESKTOP_WINDOW_IDENTITY}" \
          --catalog-labels-file "${AUTOMATED_CATALOG_LABELS_FILE}" >"${ready_report}" 2>/dev/null &&
         jq -e '.status == "ok" and .window_verified == true and .model_picker_count == 1 and .composer_count == 1 and .action_count == 0' "${ready_report}" >/dev/null; then
        return 0
      fi
      if jq -e '.status == "error" and .code == "desktop_login_required"' "${ready_report}" >/dev/null 2>&1; then
        echo "Codex Desktop login is required in the isolated Desktop window" >&2
        return 1
      fi
      sleep 0.25
    done
    echo "Codex Desktop catalog picker and composer did not become ready before the proof timeout" >&2
    return 1
  fi
  for _ in {1..120}; do
    desktop_ui_ready "${desktop_pid}" >/dev/null 2>&1 && return 0
    sleep 0.25
  done
  echo "Codex Desktop window did not become interactive before the proof timeout" >&2
  return 1
}

dismiss_known_model_nux() {
  local desktop_pid report action_total action_count
  [[ "${PROOF_INPUT_MODE}" == "automated_ax" ]] || return 0
  desktop_pid="$(cat "${DESKTOP_PID_FILE}" 2>/dev/null || true)"
  [[ -n "${desktop_pid}" && -x "${AX_DRIVER_BINARY}" ]] || return 1
  report="${RUN_DIR}/ax-dismiss-model-nux.json"
  action_total=0
  for _ in {1..20}; do
    if ! "${AX_DRIVER_BINARY}" dismiss-model-nux \
        --pid "${desktop_pid}" \
        --window-identity "${DESKTOP_WINDOW_IDENTITY}" >"${report}" 2>/dev/null; then
      return 1
    fi
    jq -e '.status == "ok" and .window_verified == true and .candidate_count <= 1 and .action_count <= 1' \
      "${report}" >/dev/null || return 1
    action_count="$(jq -r '.action_count' "${report}")"
    action_total=$((action_total + action_count))
    (( action_total <= 1 )) || return 1
    (( action_count == 1 )) && return 0
    sleep 0.25
  done
  return 0
}

launch_desktop() {
  require_sandbox_policy
  CODEX_APP_BINARY="$(resolve_codex_app_binary || true)"
  if [[ -z "${CODEX_APP_BINARY}" || ! -x "${CODEX_APP_BINARY}" ]]; then
    echo "Codex Desktop app with bundle id com.openai.codex was not found" >&2
    exit 1
  fi
  local desktop_args=(
    "--user-data-dir=${DESKTOP_USER_DATA_DIR}"
    "--no-sandbox"
    "--force-renderer-accessibility"
  )
  cleanup_stale_isolated_desktop_locks "${PROOF_ROOT}" "${DESKTOP_USER_DATA_DIR}" || {
    echo "isolated Codex Desktop profile has a live or ambiguous Singleton lock" >&2
    return 1
  }
  write_desktop_sandbox_profile
  printf 'enabled\n' >"${DESKTOP_SANDBOX_STATUS_FILE}"
  CFFIXED_USER_HOME="${ISO_HOME}" HOME="${ISO_HOME}" CODEX_HOME="${CODEX_HOME_DIR}" /usr/bin/sandbox-exec -f "${DESKTOP_SANDBOX_PROFILE}" "${CODEX_APP_BINARY}" "${desktop_args[@]}" >"${DESKTOP_LOG}" 2>&1 &
  echo "$!" >"${DESKTOP_PID_FILE}"
  wait_for_desktop_window
  dismiss_known_model_nux
  wait_for_desktop_ui_ready
}

manual_route_status() {
  summarize_usage
  route_outcome_from_usage_file "${OUT}/usage-events.json" "${PROOF_PROVIDER_MODEL_ID}" "${DESKTOP_TOOL_EVIDENCE}" "${SCREENSHOT_EVIDENCE}" "${DESKTOP_RENDER_EVIDENCE}"
}

wait_for_user_continue() {
  if read -r _; then
    return 0
  fi
  local continue_file="${RUN_DIR}/continue"
  echo "stdin is unavailable; waiting for ${continue_file}" >&2
  for _ in {1..720}; do
    if [[ -f "${continue_file}" ]]; then
      rm -f "${continue_file}"
      return 0
    fi
    sleep 5
  done
  echo "timed out waiting for manual proof continuation" >&2
  return 1
}

wait_for_verified_stage_checkpoint() {
  local role="$1"
  while true; do
    wait_for_user_continue
    verify_desktop_window_identity
    capture_desktop_window "${role}"
    summarize_usage
    if [[ "${role}" == "provider-tool" ]]; then
      write_desktop_tool_evidence "$(cat "${TOOL_SINCE_FILE}")" "${PROOF_PROVIDER_MODEL_ID}" "$(cat "${TOOL_MARKER_FILE}")"
    fi
    if stage_checkpoint_verified "${OUT}/usage-events.json" "${SCREENSHOT_EVIDENCE}" "${role}" "${PROOF_PROVIDER_MODEL_ID}" "${DESKTOP_TOOL_EVIDENCE}"; then
      return 0
    fi
    echo "${role} checkpoint is not visible in the bound isolated window or lacks fresh completed/200 usage." >&2
    echo "Keep the matching conversation and completed response visible, then press Enter to retry this same stage." >&2
  done
}

build_automated_ax_driver() {
  [[ -f "${AX_DRIVER_SOURCE}" ]] || {
    echo "automated AX driver source is missing" >&2
    return 1
  }
  /usr/bin/xcrun swiftc -O "${AX_DRIVER_SOURCE}" -o "${AX_DRIVER_BINARY}"
}

write_automated_catalog_labels() {
  local output="$1"
  jq -e '[.official[]?.displayName, .provider[]?.displayName] | map(select(type == "string" and length > 0)) | unique' "${OUT}/app-server.json" >"${output}"
  chmod 600 "${output}"
  jq -e 'type == "array" and length > 0' "${output}" >/dev/null
}

write_automated_stage_state() {
  local stage_id="$1"
  local model_id="$2"
  local evidence_role="$3"
  local expectation="$4"
  local state="$5"
  local submission_state="$6"
  local usage_baseline="$7"
  local error_code="${8:-}"
  local binding_path="${RUN_DIR}/automated-rollout-${evidence_role}.json"
  local binding_json='null'
  [[ -s "${binding_path}" ]] && binding_json="$(cat "${binding_path}")"
  local tmp="${AUTOMATED_STAGE_EVIDENCE}.tmp"
  jq \
    --arg id "${stage_id}" \
    --arg model_id "${model_id}" \
    --arg evidence_role "${evidence_role}" \
    --arg expect "${expectation}" \
    --arg state "${state}" \
    --arg submission_state "${submission_state}" \
    --argjson usage_baseline "${usage_baseline}" \
    --arg error_code "${error_code}" \
    --argjson rollout_binding "${binding_json}" \
    --arg updated_at "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
    'map(select(.id != $id)) + [{
      id: $id,
      model_id: $model_id,
      evidence_role: $evidence_role,
      expect: $expect,
      state: $state,
      submission_state: $submission_state,
      usage_baseline: $usage_baseline,
      rollout_binding: $rollout_binding,
      error_code: (if $error_code == "" then null else $error_code end),
      submission_count: (if $submission_state == "submitted" then 1 else 0 end),
      updated_at: $updated_at
    }]' "${AUTOMATED_STAGE_EVIDENCE}" >"${tmp}"
  mv "${tmp}" "${AUTOMATED_STAGE_EVIDENCE}"
}

fresh_stage_error() {
  local usage_file="$1"
  local baseline_count="$2"
  local model_id="$3"
  jq -e --argjson baseline "${baseline_count}" --arg model "${model_id}" '
    .[$baseline:]
    | map(select((.model // "") == $model and (.status // "") != "completed"))
    | first // empty
  ' "${usage_file}"
}

refresh_automated_stage_evidence() {
  local expectation="$1"
  local since_epoch="$2"
  local model_id="$3"
  local marker="$4"
  if [[ "${expectation}" == "tool" ]]; then
    write_desktop_tool_evidence "${since_epoch}" "${model_id}" "${marker}" || return 1
  fi
  write_desktop_render_evidence "${since_epoch}" "${model_id}" "${SCREENSHOT_EVIDENCE}"
}

automated_stage_checkpoint_verified() {
  local usage_file="$1"
  local baseline_count="$2"
  local model_id="$3"
  local evidence_role="$4"
  local expectation="$5"
  local binding_file="$6"
  fresh_stage_usage "${usage_file}" "${baseline_count}" "${model_id}" >/dev/null || return 1
  jq -e --arg model "${model_id}" '
    .proof_found == true
    and .candidate_count == 1
    and .model == $model
    and .user_marker_found == true
    and .assistant_marker_found == true
    and .user_marker_count == 1
    and .assistant_marker_count == 1
    and (.thread_id | type) == "string"
    and (.thread_id | length) > 0
  ' "${binding_file}" >/dev/null || return 1
  case "${expectation}" in
    plain)
      jq -e --arg role "${evidence_role}" '([.[] | select(.role == $role)] | last) as $shot | $shot.captured == true and $shot.target_identity_verified == true and $shot.visual_checks.response_marker_visible == true and $shot.visual_checks.raw_protocol_visible == false' "${SCREENSHOT_EVIDENCE}" >/dev/null
      ;;
    markdown)
      jq -e --arg role "${evidence_role}" '
        [.[] | select(.role == $role and .captured == true and .target_identity_verified == true)] as $shots
        | ($shots | length) > 0
        and all($shots[]; .visual_checks.raw_protocol_visible != true)
        and any($shots[]; .visual_checks.heading_visible == true)
        and any($shots[]; .visual_checks.numbered_items_visible == true)
        and any($shots[]; .visual_checks.table_headers_visible == true)
        and any($shots[]; .visual_checks.bash_code_visible == true)
        and any($shots[]; .visual_checks.bold_conclusion_visible == true)
      ' "${SCREENSHOT_EVIDENCE}" >/dev/null
      ;;
    tool)
      jq -e '.proof_found == true and .function_call_found == true and .function_call_output_found == true and .process_exited_zero == true and .xml_leak_found == false and .raw_function_calls_found == false' "${DESKTOP_TOOL_EVIDENCE}" >/dev/null &&
        jq -e --arg role "${evidence_role}" '([.[] | select(.role == $role)] | last) as $shot | $shot.captured == true and $shot.target_identity_verified == true and $shot.visual_checks.tool_marker_visible == true and $shot.visual_checks.tool_execution_visible == true and $shot.visual_checks.raw_protocol_visible == false' "${SCREENSHOT_EVIDENCE}" >/dev/null
      ;;
    *) return 2 ;;
  esac
}

wait_for_automated_stage() {
  local baseline_count="$1"
  local model_id="$2"
  local evidence_role="$3"
  local expectation="$4"
  local marker="$5"
  local since_epoch="$6"
  local timeout_seconds="$7"
  local binding_file="${RUN_DIR}/automated-rollout-${evidence_role}.json"
  local deadline=$((SECONDS + timeout_seconds))
  local bound_model usage_status driver_code
  bound_model="$(jq -er '.model | select(type == "string" and length > 0)' "${binding_file}")" || return 6
  while (( SECONDS < deadline )); do
    verify_desktop_window_identity || return 1
    summarize_usage || return 4
    if fresh_stage_error "${OUT}/usage-events.json" "${baseline_count}" "${bound_model}" >"${RUN_DIR}/automated-stage-error.json" 2>/dev/null; then
      return 2
    fi
    usage_status=0
    submitted_model_usage_matches "${OUT}/usage-events.json" "${baseline_count}" "${binding_file}" >"${RUN_DIR}/automated-stage-usage.json" 2>/dev/null || usage_status=$?
    if [[ "${usage_status}" -eq 5 ]]; then
      return 5
    elif [[ "${usage_status}" -eq 6 ]]; then
      return 6
    elif [[ "${usage_status}" -eq 0 ]]; then
      if ! write_automated_rollout_binding "${CODEX_HOME_DIR}" "${since_epoch}" "${model_id}" "${marker}" "${binding_file}"; then
        return 6
      fi
      if ! capture_desktop_window "${evidence_role}" "${marker}" "${expectation}"; then
        sleep 1
        continue
      fi
      if ! refresh_automated_stage_evidence "${expectation}" "${since_epoch}" "${model_id}" "${marker}"; then
        sleep 1
        continue
      fi
      if automated_stage_checkpoint_verified "${OUT}/usage-events.json" "${baseline_count}" "${model_id}" "${evidence_role}" "${expectation}" "${binding_file}"; then
        return 0
      fi
      if [[ "${expectation}" == "markdown" ]]; then
        activate_isolated_desktop || return 1
        if ! "${AX_DRIVER_BINARY}" reveal --pid "$(jq -r '.pid' "${DESKTOP_WINDOW_IDENTITY}")" --window-identity "${DESKTOP_WINDOW_IDENTITY}" --text "RelayKit Rich Text Check" >"${RUN_DIR}/ax-reveal-${evidence_role}.json"; then
          driver_code="$(driver_failure_code "${RUN_DIR}/ax-reveal-${evidence_role}.json" "unknown")"
          [[ "${driver_code}" == "selector_not_unique" ]] || return 1
        elif ! jq -e '.status == "ok" and .code == "ok" and .window_verified == true and .candidate_count == 1 and .action_count == 1' "${RUN_DIR}/ax-reveal-${evidence_role}.json" >/dev/null; then
          return 1
        fi
      fi
    fi
    sleep 1
  done
  return 3
}

print_rc1_native_responses_contract() {
  jq -n '{
    profile:"rc1_native_responses_three_stage",
    stage_ids:["A","B","C"],
    submission_count_each:1,
    stage_A:"text_marker",
    stage_B:"native_markdown_structure",
    stage_C:"exact_shell_printf_marker_plus_pwd",
    desktop_websocket_to_gateway:true,
    gateway_sse_to_fixture:true,
    tool_roundtrip:true,
    attaches_existing_app_gateway:true
  }'
}

cleanup_rc1_native_responses_desktop() {
  local cleanup_status=0
  kill_pid_file "${DESKTOP_PID_FILE}"
  rm -f "${RUN_DIR}"/automated-query-*.txt >/dev/null 2>&1 || true
  remove_rc1_isolated_auth_link || cleanup_status=1
  return "${cleanup_status}"
}

configure_rc1_native_responses_paths() {
  local name
  for name in \
    RELAYKIT_RC1_RUN_ID RELAYKIT_RC1_DESKTOP_ROOT RELAYKIT_RC1_OUTPUT \
    RELAYKIT_RC1_APP_PID_FILE RELAYKIT_RC1_APP_WINDOW_IDENTITY \
    RELAYKIT_RC1_APP_BUNDLE RELAYKIT_RC1_APP_ZIP RELAYKIT_RC1_PROVIDER_CONFIG \
    RELAYKIT_RC1_USAGE_PATH RELAYKIT_RC1_PROVIDER_EVENTS; do
    [[ -n "${!name:-}" ]] || {
      echo "rc1 native Responses proof requires ${name}" >&2
      return 2
    }
  done
  [[ "${RELAYKIT_RC1_RUN_ID}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{5,127}$ ]] || return 2
  for name in \
    RELAYKIT_RC1_DESKTOP_ROOT RELAYKIT_RC1_OUTPUT RELAYKIT_RC1_APP_PID_FILE \
    RELAYKIT_RC1_APP_WINDOW_IDENTITY RELAYKIT_RC1_APP_BUNDLE RELAYKIT_RC1_APP_ZIP \
    RELAYKIT_RC1_PROVIDER_CONFIG RELAYKIT_RC1_USAGE_PATH RELAYKIT_RC1_PROVIDER_EVENTS; do
    [[ "${!name}" == /* ]] || {
      echo "${name} must be absolute" >&2
      return 2
    }
  done

  PROOF_ROOT="${RELAYKIT_RC1_DESKTOP_ROOT}"
  ISO_HOME="${PROOF_ROOT}/home"
  APP_SUPPORT_DIR="${ISO_HOME}/Library/Application Support/RelayKit"
  OFFICIAL_PROOF_ROOT="${PROOF_ROOT}/official-proof"
  APP_OFFICIAL_CODEX_HOME="${PROOF_ROOT}/app-owned-codex-home-unused"
  CODEX_HOME_DIR="${PROOF_ROOT}/rc1-desktop-codex-home"
  DESKTOP_USER_DATA_DIR="${PROOF_ROOT}/desktop-user-data"
  LOG_DIR="${PROOF_ROOT}/logs"
  RUN_DIR="${PROOF_ROOT}/run"
  OUT="${RELAYKIT_RC1_OUTPUT}"
  LAST_ROUTE_OUT="${OUT}/unused-last-route"
  LAST_COMPLETE_OUT="${OUT}/unused-last-complete"
  ZIP_PATH="${RELAYKIT_RC1_APP_ZIP}"
  APP_BUNDLE="${RELAYKIT_RC1_APP_BUNDLE}"
  APP_REAL_BINARY="${APP_BUNDLE}/Contents/MacOS/RelayKitApp.bin"
  BUNDLED_RELAY="${APP_BUNDLE}/Contents/MacOS/relay"
  PROVIDER_CONFIG="${RELAYKIT_RC1_PROVIDER_CONFIG}"
  USAGE_PATH="${RELAYKIT_RC1_USAGE_PATH}"
  PROVIDER_EVENTS="${RELAYKIT_RC1_PROVIDER_EVENTS}"
  CATALOG_PATH="${PROOF_ROOT}/model-catalog.json"
  CODEX_CONFIG="${CODEX_HOME_DIR}/config.toml"
  PROVIDER_PID_FILE="${RUN_DIR}/provider.pid"
  GATEWAY_PID_FILE="${RUN_DIR}/gateway.pid"
  APP_PID_FILE="${RELAYKIT_RC1_APP_PID_FILE}"
  APP_WINDOW_IDENTITY="${RELAYKIT_RC1_APP_WINDOW_IDENTITY}"
  DESKTOP_PID_FILE="${RUN_DIR}/codex-desktop.pid"
  PORT_FILE="${RUN_DIR}/gateway-port"
  PROVIDER_PORT_FILE="${RUN_DIR}/provider-port"
  PROVIDER_LOG="${LOG_DIR}/provider.log"
  GATEWAY_LOG="${LOG_DIR}/gateway.log"
  APP_LOG="${LOG_DIR}/relaykit-app.log"
  DESKTOP_LOG="${LOG_DIR}/codex-desktop.log"
  AX_DRIVER_BINARY="${RUN_DIR}/codex-desktop-ax-driver"
  AUTOMATED_CATALOG_LABELS_FILE="${RUN_DIR}/automated-model-labels.json"
  AUTOMATED_STAGE_EVIDENCE="${OUT}/automated-stages.json"
  AUTOMATED_SCENARIO_NORMALIZED="${RUN_DIR}/automated-scenario.json"
  DESKTOP_SANDBOX_PROFILE="${RUN_DIR}/codex-desktop-proof.sb"
  DESKTOP_SANDBOX_STATUS_FILE="${RUN_DIR}/desktop-sandbox-status"
  DESKTOP_WINDOW_IDENTITY="${RUN_DIR}/desktop-window-identity.json"
  APP_SCREENSHOT="${OUT}/app-owned-gateway.png"
  DESKTOP_TOOL_EVIDENCE="${OUT}/desktop-tool-evidence.json"
  DESKTOP_RENDER_EVIDENCE="${OUT}/desktop-render-evidence.json"
  SCREENSHOT_DIR="${OUT}/screenshots"
  SCREENSHOT_EVIDENCE="${OUT}/screenshots.json"
  TOOL_MARKER_FILE="${RUN_DIR}/tool-marker"
  TOOL_SINCE_FILE="${RUN_DIR}/tool-since-epoch"
  RC1_ISOLATED_AUTH_HOME="${RELAYKIT_RC1_ISOLATED_AUTH_HOME:-${REAL_HOME}/Library/Application Support/RelayKit/DesktopProof/official-proof/codex-home}"
  PROOF_SCOPE="rc1_native_responses"
}

setup_rc1_native_responses_attached_preflight() {
  local app_pid app_command bundled_models provider_config_hash
  [[ ! -e "${OUT}" ]] || {
    echo "rc1 native Responses output must be a fresh run-specific path" >&2
    return 1
  }
  for path in "${APP_PID_FILE}" "${APP_WINDOW_IDENTITY}" "${ZIP_PATH}" "${PROVIDER_CONFIG}" "${USAGE_PATH}" "${PROVIDER_EVENTS}"; do
    [[ -f "${path}" && ! -L "${path}" ]] || {
      echo "rc1 native Responses input is not a current regular file" >&2
      return 1
    }
  done
  [[ -d "${APP_BUNDLE}" && -x "${APP_REAL_BINARY}" && -x "${BUNDLED_RELAY}" ]] || return 1
  app_pid="$(cat "${APP_PID_FILE}")"
  [[ "${app_pid}" =~ ^[0-9]+$ ]] && kill -0 "${app_pid}" 2>/dev/null || return 1
  app_command="$(ps -p "${app_pid}" -o command= 2>/dev/null || true)"
  [[ "${app_command}" == "${APP_REAL_BINARY}"* ]] || return 1
  jq -e --argjson pid "${app_pid}" '
    .pid == $pid and (.window_id | type == "number" and . > 0)
  ' "${APP_WINDOW_IDENTITY}" >/dev/null || return 1
  curl -fsS --max-time 2 http://127.0.0.1:19777/healthz >/dev/null || return 1
  jq -e '
    (.providers | type == "array" and length == 1) and
    .providers[0].api_format == "openai_responses" and
    .providers[0].credential_ref.kind == "keychain" and
    (.providers[0].credential_ref.value | startswith("relaykit.provider.dogfood-")) and
    (.providers[0].models | type == "array" and length == 1) and
    ([.. | objects | select(has("key_file"))] | length == 0)
  ' "${PROVIDER_CONFIG}" >/dev/null || return 1
  PROOF_PROVIDER_MODEL_ID="$(jq -er '.providers[0].models[0].id' "${PROVIDER_CONFIG}")" || return 1
  provider_config_hash="$(file_hash "${PROVIDER_CONFIG}")"
  RELAYKIT_RC1_PROVIDER_CONFIG_SHA256="${provider_config_hash}"

  mkdir -p "${PROOF_ROOT}" "${ISO_HOME}" "${APP_SUPPORT_DIR}" "${OFFICIAL_PROOF_ROOT}" \
    "${CODEX_HOME_DIR}" "${DESKTOP_USER_DATA_DIR}" "${LOG_DIR}" "${RUN_DIR}" "${OUT}" "${SCREENSHOT_DIR}"
  chmod 700 "${PROOF_ROOT}" "${ISO_HOME}" "${APP_SUPPORT_DIR}" "${OFFICIAL_PROOF_ROOT}" \
    "${CODEX_HOME_DIR}" "${DESKTOP_USER_DATA_DIR}" "${LOG_DIR}" "${RUN_DIR}" "${OUT}"
  printf 'not_launched\n' >"${DESKTOP_SANDBOX_STATUS_FILE}"
  rm -f "${DESKTOP_WINDOW_IDENTITY}" "${TOOL_MARKER_FILE}" "${TOOL_SINCE_FILE}"
  printf '[]\n' >"${SCREENSHOT_EVIDENCE}"
  printf '{"proof_found":false,"function_call_found":false,"function_call_output_found":false,"process_exited_zero":false,"matched_provider_tool_count":0,"xml_leak_found":false,"raw_function_calls_found":false,"exact_shell_command_found":false,"pwd_output_found":false,"event_count":0,"events":[]}\n' >"${DESKTOP_TOOL_EVIDENCE}"
  printf '{}\n' >"${DESKTOP_RENDER_EVIDENCE}"
  printf '19777\n' >"${PORT_FILE}"
  STARTED_AT="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  APP_ZIP_SHA256="$(file_hash "${ZIP_PATH}")"
  APP_ZIP_BUILD_TIME_UTC="$(date -u -r "${ZIP_PATH}" +"%Y-%m-%dT%H:%M:%SZ")"
  APP_SERVER_SETUP_ID="rc1-native-${APP_ZIP_SHA256:0:16}"
  APP_SERVER_SESSION_ID="rc1-native:${RELAYKIT_RC1_RUN_ID}"
  capture_global_state
  capture_source_state

  CODEX_CLI_BINARY="$(resolve_codex_cli_binary || true)"
  [[ -n "${CODEX_CLI_BINARY}" && -x "${CODEX_CLI_BINARY}" ]] || return 1
  local resolved_auth_home
  resolved_auth_home="$(resolve_rc1_isolated_auth_home "${RC1_ISOLATED_AUTH_HOME}")" || {
    echo "RC1 isolated Codex Desktop login is unavailable" >&2
    return 1
  }
  rc1_isolated_auth_status "${resolved_auth_home}" "${CODEX_CLI_BINARY}" || {
    echo "RC1 isolated Codex Desktop login is not connected or changed during status check" >&2
    return 1
  }
  create_rc1_isolated_auth_link "${resolved_auth_home}" "${CODEX_HOME_DIR}" || {
    echo "RC1 isolated Codex Desktop auth link could not be prepared" >&2
    return 1
  }
  bundled_models="${RUN_DIR}/codex-bundled-models.json"
  "${CODEX_CLI_BINARY}" debug models --bundled >"${bundled_models}"
  merge_model_catalog "${bundled_models}" "${PROVIDER_CONFIG}" "${PROOF_SCOPE}" "${CATALOG_PATH}"
  cp "${CATALOG_PATH}" "${OUT}/model-catalog.json"
  write_codex_config 19777
  CFFIXED_USER_HOME="${ISO_HOME}" HOME="${ISO_HOME}" CODEX_HOME="${CODEX_HOME_DIR}" \
    "${CODEX_CLI_BINARY}" debug models >"${OUT}/codex-debug-models.json"
  jq -e --arg model "${PROOF_PROVIDER_MODEL_ID}" '([.models[].slug] | index($model)) != null' \
    "${OUT}/codex-debug-models.json" >/dev/null || return 1
  write_app_server_evidence
  jq -e --arg model "${PROOF_PROVIDER_MODEL_ID}" '([.provider[].model] | index($model)) != null' \
    "${OUT}/app-server.json" >/dev/null || return 1
  curl -fsS --max-time 5 http://127.0.0.1:19777/v1/models >"${OUT}/gateway-models.json"
  jq -e --arg model "${PROOF_PROVIDER_MODEL_ID}" '([.data[].id] | index($model)) != null' \
    "${OUT}/gateway-models.json" >/dev/null || return 1
  [[ "$(file_hash "${PROVIDER_CONFIG}")" == "${provider_config_hash}" ]] || return 1
}

write_rc1_native_responses_evidence() {
  local run_id="${RELAYKIT_RC1_RUN_ID}"
  local screenshot_path screenshot_sha usage_sha events_sha harness_sha scenario_sha config_sha stages_sha
  local failed_events
  summarize_usage
  jq -e --arg model "${PROOF_PROVIDER_MODEL_ID}" '
    [.[] | select(.model == $model and .status == "completed" and .http_status == 200 and .transport == "responses_websocket")] | length >= 3
  ' "${OUT}/usage-events.json" >/dev/null || return 1
  jq -s -e --arg run_id "${run_id}" '
    all(.[]; .run_id == $run_id) and
    ([.[] | select(.method == "POST" and .path == "/v1/responses" and .auth_present == true and (.event_types | index("response.completed")) != null)] | length >= 4) and
    any(.[]; (.event_types | index("response.output_item.added")) != null)
  ' "${PROVIDER_EVENTS}" >/dev/null || return 1
  jq -e '
    .proof_found == true and
    .function_call_found == true and
    .function_call_output_found == true and
    .process_exited_zero == true and
    .exact_shell_command_found == true and
    .pwd_output_found == true and
    .xml_leak_found == false and
    .raw_function_calls_found == false
  ' "${DESKTOP_TOOL_EVIDENCE}" >/dev/null || return 1
  jq -e '
    length == 3 and ([.[].id] == ["A","B","C"]) and
    all(.[];
      .state == "evidence_verified" and
      .submission_state == "submitted" and
      .submission_count == 1 and
      .error_code == null and
      .rollout_binding.proof_found == true
    )
  ' "${AUTOMATED_STAGE_EVIDENCE}" >/dev/null || return 1
  failed_events="$(jq '[.[] | .error_code | select(. != null)]' "${AUTOMATED_STAGE_EVIDENCE}")"
  [[ "${failed_events}" == "[]" ]] || return 1
  screenshot_path="$(jq -er '[.[] | select(.role == "rc1-tool" and .captured == true and .target_identity_verified == true)] | last | .path' "${SCREENSHOT_EVIDENCE}")" || return 1
  [[ "${screenshot_path}" == /* ]] || screenshot_path="${ROOT}/${screenshot_path}"
  [[ -f "${screenshot_path}" && ! -L "${screenshot_path}" ]] || return 1
  screenshot_sha="$(file_hash "${screenshot_path}")"
  jq -e --arg path "${screenshot_path#${ROOT}/}" --arg sha "${screenshot_sha}" '
    any(.[]; .role == "rc1-tool" and .path == $path and .sha256 == $sha and .visual_checks.tool_marker_visible == true and .visual_checks.tool_execution_visible == true and .visual_checks.raw_protocol_visible == false) or
    any(.[]; .role == "rc1-tool" and .path == ("/" + $path) and .sha256 == $sha and .visual_checks.tool_marker_visible == true and .visual_checks.tool_execution_visible == true and .visual_checks.raw_protocol_visible == false)
  ' "${SCREENSHOT_EVIDENCE}" >/dev/null || return 1
  jq -e '
    any(.[]; .role == "rc1-markdown" and .captured == true and .target_identity_verified == true and
      .visual_checks.heading_visible == true and .visual_checks.numbered_items_visible == true and
      .visual_checks.table_headers_visible == true and .visual_checks.bash_code_visible == true and
      .visual_checks.bold_conclusion_visible == true and .visual_checks.raw_protocol_visible == false)
  ' "${SCREENSHOT_EVIDENCE}" >/dev/null || return 1
  [[ "$(file_hash "${PROVIDER_CONFIG}")" == "${RELAYKIT_RC1_PROVIDER_CONFIG_SHA256}" ]] || return 1
  assert_proof_state_unchanged

  usage_sha="$(file_hash "${OUT}/usage-events.json")"
  events_sha="$(file_hash "${PROVIDER_EVENTS}")"
  harness_sha="$(file_hash "${ROOT}/scripts/codex-desktop-manual-proof.sh")"
  scenario_sha="$(file_hash "${SCENARIO_PATH}")"
  config_sha="$(file_hash "${PROVIDER_CONFIG}")"
  stages_sha="$(file_hash "${AUTOMATED_STAGE_EVIDENCE}")"
  jq -n \
    --arg run_id "${run_id}" --arg screenshot_path "${screenshot_path}" \
    --arg screenshot_sha "${screenshot_sha}" --arg usage_sha "${usage_sha}" \
    --arg events_sha "${events_sha}" --arg harness_sha "${harness_sha}" \
    --arg scenario_sha "${scenario_sha}" --arg config_sha "${config_sha}" \
    --arg stages_sha "${stages_sha}" --arg app_pid "$(cat "${APP_PID_FILE}")" \
    --arg usage_path "${OUT}/usage-events.json" --arg provider_events_path "${PROVIDER_EVENTS}" \
	    --slurpfile stages "${AUTOMATED_STAGE_EVIDENCE}" '{
	      status:"complete",
	      manual_status:"route_complete",
	      route_proof_status:"complete",
	      harness_exit_code:0,
	      run_id:$run_id,
      profile:"rc1_native_responses_three_stage",
      app_owned_gateway_attached:true,
      ui_saved_provider_config:true,
      desktop_websocket_to_gateway:true,
      gateway_sse_to_fixture:true,
      tool_roundtrip_verified:true,
      predicate_ledger:{
        exact_app_pid_attached:true,
        ui_saved_provider_config:true,
        isolated_desktop:true,
        stage_A_text_marker:true,
        stage_B_native_markdown_structure:true,
        stage_C_exact_shell_printf_marker_plus_pwd:true,
        exactly_one_submission_each:true,
        desktop_websocket_to_gateway:true,
        gateway_sse_to_fixture:true,
        function_call_output_roundtrip:true,
        run_and_hash_bindings_current:true
      },
      failed_events:[],
      stages:$stages[0],
      app_pid:($app_pid | tonumber),
      screenshot_path:$screenshot_path,
      screenshot_sha256:$screenshot_sha,
      usage_path:$usage_path,
      usage_sha256:$usage_sha,
      provider_events_path:$provider_events_path,
      provider_events_sha256:$events_sha,
      harness_sha256:$harness_sha,
      scenario_sha256:$scenario_sha,
      provider_config_sha256:$config_sha,
      stage_evidence_sha256:$stages_sha
    }' >"${OUT}/rc1-native-responses-evidence.json"
  chmod 600 "${OUT}/rc1-native-responses-evidence.json"
  jq -e '.failed_events == [] and (.predicate_ledger | all(.[]; . == true))' \
    "${OUT}/rc1-native-responses-evidence.json" >/dev/null
}

run_automated_proof() {
  local scenario_path="$1"
  local driver_source="${ROOT}/scripts/codex-desktop-ax-driver.swift"
  local catalog_labels="${AUTOMATED_CATALOG_LABELS_FILE}"
  local overall_since stage_timeout desktop_pid expected_stage_count standard_route_status gpt55_marker gpt56_marker
  local stage index=0 stage_id model_id model_label query_source query_copy response_marker evidence_role expectation
  local usage_baseline since_epoch submission_state="not_submitted" wait_status bind_status driver_code query_sha256
  local resolved_scenario_tmp resolution_error_file resolution_error

  [[ "${AX_DRIVER_SOURCE}" == "${driver_source}" ]] || {
    AUTO_ERROR_CODE="ax_driver_path_invalid"
    return 1
  }
  validate_automated_input_mode || {
    AUTO_ERROR_CODE="input_mode_invalid"
    return 1
  }
  validate_auto_scenario "${scenario_path}" >"${AUTOMATED_SCENARIO_NORMALIZED}" || {
    AUTO_ERROR_CODE="scenario_invalid"
    return 1
  }
  SCENARIO_PATH="${scenario_path}"
  SCENARIO_HASH_BEFORE="$(file_hash "${SCENARIO_PATH}")"
  chmod 600 "${AUTOMATED_SCENARIO_NORMALIZED}" || {
    AUTO_ERROR_CODE="scenario_staging_failed"
    return 1
  }
  prepare_automated_provider_inputs "${AUTOMATED_SCENARIO_NORMALIZED}" || {
    AUTO_ERROR_CODE="provider_input_missing_or_invalid"
    return 1
  }
  stage_timeout="$(jq -er '.stage_timeout_seconds' "${AUTOMATED_SCENARIO_NORMALIZED}")" || {
    AUTO_ERROR_CODE="scenario_timeout_invalid"
    return 1
  }
  expected_stage_count="$(jq -er '.stages | length | select(. > 0)' "${AUTOMATED_SCENARIO_NORMALIZED}")" || {
    AUTO_ERROR_CODE="scenario_stage_count_invalid"
    return 1
  }
  AUTO_ERROR_CODE="preflight_failed"
  if [[ "${RELAYKIT_RC1_ATTACH_APP_GATEWAY:-0}" == "1" ]]; then
    setup_rc1_native_responses_attached_preflight
  else
    AUTO_ERROR_CODE="global_state_capture_failed"
    capture_global_state
    AUTO_ERROR_CODE="preflight_failed"
    setup_preflight real
    AUTO_ERROR_CODE="preflight_evidence_failed"
    write_evidence "automated_preflight_passed" "not_started" "${CONFIG_BEFORE}" "${AUTH_BEFORE}" "${CONFIG_HASH_BEFORE}" "${AUTH_HASH_BEFORE}" "${NOTIFY_HASH_BEFORE}"
  fi
  resolved_scenario_tmp="${AUTOMATED_SCENARIO_NORMALIZED}.resolved"
  resolution_error_file="${RUN_DIR}/automated-scenario-resolution-error"
  if resolve_automated_scenario_models "${AUTOMATED_SCENARIO_NORMALIZED}" "${OUT}/app-server.json" >"${resolved_scenario_tmp}" 2>"${resolution_error_file}"; then
    chmod 600 "${resolved_scenario_tmp}"
    mv "${resolved_scenario_tmp}" "${AUTOMATED_SCENARIO_NORMALIZED}"
    rm -f "${resolution_error_file}"
  else
    resolution_error="$(head -n 1 "${resolution_error_file}" 2>/dev/null || true)"
    case "${resolution_error}" in
      current_official_catalog_empty|current_official_model_duplicate|current_official_catalog_invalid|model_label_resolution_failed|scenario_invalid)
        AUTO_ERROR_CODE="${resolution_error}"
        ;;
      *) AUTO_ERROR_CODE="model_label_resolution_failed" ;;
    esac
    rm -f "${resolved_scenario_tmp}" "${resolution_error_file}"
    return 1
  fi
  AUTOMATED_PROFILE="$(automated_profile_for_scenario "${AUTOMATED_SCENARIO_NORMALIZED}" "${PROOF_PROVIDER_MODEL_ID}")" || {
    AUTO_ERROR_CODE="scenario_profile_invalid"
    return 1
  }
  case "${AUTOMATED_PROFILE}" in
    standard_four_stage_dogfood) ;;
    single_tool_scenario)
      [[ "${expected_stage_count}" == "1" ]] || {
        AUTO_ERROR_CODE="custom_scenario_stage_count_invalid"
        return 1
      }
      ;;
    rc1_native_responses_three_stage)
      [[ "${RELAYKIT_RC1_ATTACH_APP_GATEWAY:-0}" == "1" && "${expected_stage_count}" == "3" ]] || {
        AUTO_ERROR_CODE="rc1_attach_contract_invalid"
        return 1
      }
      ;;
    custom_scenario) ;;
    *)
      AUTO_ERROR_CODE="scenario_profile_unknown"
      return 1
      ;;
  esac
  AUTO_ERROR_CODE="ax_driver_build_failed"
  build_automated_ax_driver
  AUTO_ERROR_CODE="desktop_catalog_labels_invalid"
  write_automated_catalog_labels "${AUTOMATED_CATALOG_LABELS_FILE}"
  AUTO_ERROR_CODE="desktop_launch_failed"
  launch_desktop
  AUTO_ERROR_CODE="desktop_activation_failed"
  activate_isolated_desktop
  AUTO_ERROR_CODE="desktop_window_identity_invalid"
  verify_desktop_window_identity
  AUTO_ERROR_CODE="desktop_initial_capture_failed"
  capture_desktop_window "before-automated-input"
  desktop_pid="$(jq -er '.pid | select(type == "number" and . > 0)' "${DESKTOP_WINDOW_IDENTITY}")" || {
    AUTO_ERROR_CODE="desktop_pid_invalid"
    return 1
  }
  overall_since="$(date +%s)"
  printf '[]\n' >"${AUTOMATED_STAGE_EVIDENCE}" || {
    AUTO_ERROR_CODE="stage_evidence_init_failed"
    return 1
  }

  while IFS= read -r stage; do
    index=$((index + 1))
    stage_id="$(jq -er '.id' <<<"${stage}")" || { AUTO_ERROR_CODE="stage_decode_failed"; return 1; }
    model_id="$(jq -er '.model_id' <<<"${stage}")" || { AUTO_ERROR_CODE="stage_decode_failed"; return 1; }
    model_label="$(jq -er '.model_label' <<<"${stage}")" || { AUTO_ERROR_CODE="stage_decode_failed"; return 1; }
    query_source="$(jq -er '.query_file' <<<"${stage}")" || { AUTO_ERROR_CODE="stage_decode_failed"; return 1; }
    response_marker="$(jq -er '.response_marker' <<<"${stage}")" || { AUTO_ERROR_CODE="stage_decode_failed"; return 1; }
    evidence_role="$(jq -er '.evidence_role' <<<"${stage}")" || { AUTO_ERROR_CODE="stage_decode_failed"; return 1; }
    expectation="$(jq -er '.expect' <<<"${stage}")" || { AUTO_ERROR_CODE="stage_decode_failed"; return 1; }
    query_copy="${RUN_DIR}/automated-query-${index}.txt"
    AUTO_ERROR_CODE="query_window_binding_invalid"
    verify_desktop_window_identity || return 1
    AUTO_ERROR_CODE="query_content_invalid"
    validate_postbinding_query_content "${query_source}" "${response_marker}" "${expectation}" || return 1
    AUTO_ERROR_CODE="query_staging_failed"
    query_sha256="$(copy_bound_query "${query_source}" "${query_copy}")" || return 1
    [[ "${query_sha256}" =~ ^[0-9a-f]{64}$ ]] || return 1
    AUTO_ERROR_CODE="usage_summary_failed"
    summarize_usage
    usage_baseline="$(jq -er 'length' "${OUT}/usage-events.json")" || { AUTO_ERROR_CODE="usage_baseline_failed"; return 1; }
    since_epoch="$(date +%s)"
    submission_state="not_submitted"
    AUTO_ERROR_CODE="stage_evidence_write_failed"
    write_automated_stage_state "${stage_id}" "${model_id}" "${evidence_role}" "${expectation}" "prepared" "${submission_state}" "${usage_baseline}"

    AUTO_ERROR_CODE="prepare_desktop_activation_failed"
    activate_isolated_desktop
    verify_desktop_window_identity
    if ! "${AX_DRIVER_BINARY}" prepare --pid "${desktop_pid}" --window-identity "${DESKTOP_WINDOW_IDENTITY}" --workspace "${ROOT}" >"${RUN_DIR}/ax-prepare-${index}.json"; then
      driver_code="$(driver_failure_code "${RUN_DIR}/ax-prepare-${index}.json" "unknown")"
      rm -f "${query_copy}"
      write_automated_stage_state "${stage_id}" "${model_id}" "${evidence_role}" "${expectation}" "failed" "${submission_state}" "${usage_baseline}" "prepare_${driver_code}" || true
      AUTO_ERROR_CODE="prepare_${driver_code}"
      return 1
    fi
    if ! jq -e '.status == "ok" and .code == "ok" and .window_verified == true and .composer_count == 1 and (.action_count >= 1 and .action_count <= 37)' "${RUN_DIR}/ax-prepare-${index}.json" >/dev/null; then
      rm -f "${query_copy}"
      AUTO_ERROR_CODE="prepare_report_invalid"
      return 1
    fi
    AUTO_ERROR_CODE="submit_desktop_activation_failed"
    activate_isolated_desktop
    verify_desktop_window_identity
    if ! "${AX_DRIVER_BINARY}" submit --pid "${desktop_pid}" --window-identity "${DESKTOP_WINDOW_IDENTITY}" --model-label "${model_label}" --catalog-labels-file "${catalog_labels}" --query-file "${query_copy}" >"${RUN_DIR}/ax-submit-${index}.json"; then
      driver_code="$(driver_failure_code "${RUN_DIR}/ax-submit-${index}.json" "unknown")"
      if [[ "${driver_code}" == "send_result_ambiguous" ]]; then
        submission_state="unknown_after_submit_attempt"
      fi
      rm -f "${query_copy}"
      write_automated_stage_state "${stage_id}" "${model_id}" "${evidence_role}" "${expectation}" "failed" "${submission_state}" "${usage_baseline}" "submit_${driver_code}" || true
      AUTO_ERROR_CODE="submit_${driver_code}"
      return 1
    fi
    if ! jq -e '.status == "ok" and .code == "ok" and .window_verified == true and .composer_count == 1 and .send_count == 1' "${RUN_DIR}/ax-submit-${index}.json" >/dev/null; then
      rm -f "${query_copy}"
      submission_state="unknown_after_submit_attempt"
      AUTO_ERROR_CODE="submit_report_invalid"
      return 1
    fi
    submission_state="submitted"
    rm -f "${query_copy}"
    AUTO_ERROR_CODE="stage_evidence_write_failed"
    write_automated_stage_state "${stage_id}" "${model_id}" "${evidence_role}" "${expectation}" "submitted" "${submission_state}" "${usage_baseline}"
    bind_status=0
    wait_for_submitted_rollout_binding "${CODEX_HOME_DIR}" "${since_epoch}" "${model_id}" "${response_marker}" "${RUN_DIR}/automated-rollout-${evidence_role}.json" "${stage_timeout}" || bind_status=$?
    if [[ "${bind_status}" -ne 0 ]]; then
      resolution_error="$(jq -r '.binding_status // "rollout_not_found"' "${RUN_DIR}/automated-rollout-${evidence_role}.json" 2>/dev/null || printf 'rollout_not_found')"
      AUTO_ERROR_CODE="submitted_${resolution_error}"
      write_automated_stage_state "${stage_id}" "${model_id}" "${evidence_role}" "${expectation}" "failed" "${submission_state}" "${usage_baseline}" "${AUTO_ERROR_CODE}" || true
      return 1
    fi
    if ! submitted_model_selection_matches "${RUN_DIR}/automated-rollout-${evidence_role}.json" "${model_id}"; then
      AUTO_ERROR_CODE="submitted_model_selection_mismatch"
      write_automated_stage_state "${stage_id}" "${model_id}" "${evidence_role}" "${expectation}" "failed" "${submission_state}" "${usage_baseline}" "${AUTO_ERROR_CODE}" || true
      return 1
    fi
    if [[ "${expectation}" == "tool" ]]; then
      printf '%s\n' "${response_marker}" >"${TOOL_MARKER_FILE}" || { AUTO_ERROR_CODE="tool_marker_write_failed"; return 1; }
      printf '%s\n' "${since_epoch}" >"${TOOL_SINCE_FILE}" || { AUTO_ERROR_CODE="tool_marker_write_failed"; return 1; }
    fi
    wait_status=0
    wait_for_automated_stage "${usage_baseline}" "${model_id}" "${evidence_role}" "${expectation}" "${response_marker}" "${since_epoch}" "${stage_timeout}" || wait_status=$?
    if [[ "${wait_status}" -ne 0 ]]; then
      case "${wait_status}" in
        5) AUTO_ERROR_CODE="submitted_model_usage_mismatch" ;;
        6) AUTO_ERROR_CODE="submitted_rollout_binding_changed" ;;
        *) AUTO_ERROR_CODE="observation_failed_${wait_status}" ;;
      esac
      write_automated_stage_state "${stage_id}" "${model_id}" "${evidence_role}" "${expectation}" "failed" "${submission_state}" "${usage_baseline}" "${AUTO_ERROR_CODE}"
      return 1
    fi
    AUTO_ERROR_CODE="stage_evidence_write_failed"
    write_automated_stage_state "${stage_id}" "${model_id}" "${evidence_role}" "${expectation}" "evidence_verified" "${submission_state}" "${usage_baseline}"
    automated_stages_complete "${AUTOMATED_STAGE_EVIDENCE}" "${index}" || {
      AUTO_ERROR_CODE="stage_thread_or_evidence_not_unique"
      return 1
    }
  done < <(jq -c '.stages[]' "${AUTOMATED_SCENARIO_NORMALIZED}")

  if [[ "${index}" -ne "${expected_stage_count}" ]] || ! automated_stages_complete "${AUTOMATED_STAGE_EVIDENCE}" "${expected_stage_count}"; then
    AUTO_ERROR_CODE="scenario_stage_completion_mismatch"
    return 1
  fi
  case "${AUTOMATED_PROFILE}" in
    standard_four_stage_dogfood)
      gpt55_marker="$(jq -er '.stages[] | select(.evidence_role == "gpt55-response" and .model_id == "gpt-5.5") | .response_marker' "${AUTOMATED_SCENARIO_NORMALIZED}")" || {
        AUTO_ERROR_CODE="gpt55_marker_missing"
        return 1
      }
      gpt56_marker="$(jq -er '.stages[] | select(.evidence_role == "gpt56-response" and .model_id == "gpt-5.6-luna") | .response_marker' "${AUTOMATED_SCENARIO_NORMALIZED}")" || {
        AUTO_ERROR_CODE="gpt56_marker_missing"
        return 1
      }
      AUTO_ERROR_CODE="render_evidence_failed"
      write_desktop_render_evidence "${overall_since}" "${PROOF_PROVIDER_MODEL_ID}" "${SCREENSHOT_EVIDENCE}" "${gpt55_marker}" "${gpt56_marker}"
      standard_route_status="$(route_outcome_from_usage_file "${OUT}/usage-events.json" "${PROOF_PROVIDER_MODEL_ID}" "${DESKTOP_TOOL_EVIDENCE}" "${SCREENSHOT_EVIDENCE}" "${DESKTOP_RENDER_EVIDENCE}")" || {
        AUTO_ERROR_CODE="standard_route_evaluation_failed"
        return 1
      }
      if [[ "${standard_route_status}" != "complete" ]]; then
        AUTO_ERROR_CODE="standard_route_${standard_route_status}"
        return 1
      fi
      ;;
    single_tool_scenario)
      if ! custom_tool_scenario_complete "${AUTOMATED_STAGE_EVIDENCE}" "${expected_stage_count}" "${DESKTOP_TOOL_EVIDENCE}" "${SCREENSHOT_EVIDENCE}"; then
        AUTO_ERROR_CODE="custom_tool_evidence_incomplete"
        return 1
      fi
      ;;
    rc1_native_responses_three_stage)
      AUTO_ERROR_CODE="rc1_native_responses_evidence_incomplete"
      write_rc1_native_responses_evidence || return 1
      ;;
    custom_scenario) ;;
    *)
      AUTO_ERROR_CODE="scenario_profile_unknown"
      return 1
      ;;
  esac
  if [[ "${AUTOMATED_PROFILE}" == "rc1_native_responses_three_stage" ]]; then
    cleanup_rc1_native_responses_desktop
    AUTO_ERROR_CODE="proof_state_changed"
    assert_proof_state_unchanged
    AUTO_ERROR_CODE="result_encoding_failed"
    jq -n \
      --arg evidence "${OUT}/rc1-native-responses-evidence.json" \
      --arg profile "${AUTOMATED_PROFILE}" \
      --slurpfile stages "${AUTOMATED_STAGE_EVIDENCE}" \
	      '{status:"complete",manual_status:"route_complete",route_proof_status:"complete",harness_exit_code:0,profile:$profile,evidence:$evidence,human_intervention_count:0,stages:$stages[0]}'
    return 0
  fi
  cleanup_processes
  AUTO_ERROR_CODE="final_evidence_failed"
  write_evidence "route_complete" "complete" "${CONFIG_BEFORE}" "${AUTH_BEFORE}" "${CONFIG_HASH_BEFORE}" "${AUTH_HASH_BEFORE}" "${NOTIFY_HASH_BEFORE}"
  AUTO_ERROR_CODE="evidence_preservation_failed"
  preserve_existing_route_evidence "${OUT}" "${LAST_ROUTE_OUT}" "${LAST_COMPLETE_OUT}"
  AUTO_ERROR_CODE="proof_state_changed"
  assert_proof_state_unchanged
  AUTO_ERROR_CODE="result_encoding_failed"
  jq -n --arg evidence "${OUT}/evidence.json" --arg profile "${AUTOMATED_PROFILE}" --slurpfile stages "${AUTOMATED_STAGE_EVIDENCE}" '{status:"complete",profile:$profile,evidence:$evidence,human_intervention_count:0,stages:$stages[0]}'
}

ensure_official_login_connected() {
  local preflight_status
  preflight_status="$(official_gateway_preflight_status)"
  if [[ "${preflight_status}" == "connected" ]]; then
    reset_route_usage_after_preflight
    return 0
  fi

  local route_status="official_preflight_${preflight_status}"
  [[ "${preflight_status}" == "auth_required" ]] && route_status="official_auth_required"
  write_evidence "awaiting_official_app_login" "${route_status}" "${CONFIG_BEFORE}" "${AUTH_BEFORE}" "${CONFIG_HASH_BEFORE}" "${AUTH_HASH_BEFORE}" "${NOTIFY_HASH_BEFORE}"
  assert_proof_state_unchanged
  if [[ "${PROOF_INPUT_MODE}" == "automated_ax" ]]; then
    echo "{\"status\":\"precondition_failed\",\"error_code\":\"${route_status}\"}" >&2
    return 1
  fi

  cat <<EOF
RelayKit App is running from the extracted local zip, but its isolated official login is not usable yet.

In the RelayKit menu-bar App that is already open:
1. Open "OpenAI Official / Codex Official".
2. If it says login is available, Disconnect first because the route preflight rejected that session.
3. Choose Connect Official and complete the device link/code shown inside RelayKit App.
4. Return here and press Enter. Codex Desktop will not launch before this check succeeds.

This preflight is login gating only and is excluded from Desktop route evidence.
EOF
  wait_for_user_continue

  [[ -f "${APP_PID_FILE}" ]] && kill -0 "$(cat "${APP_PID_FILE}")" 2>/dev/null || {
    echo "RelayKit App exited before official login verification" >&2
    return 1
  }
  curl -fsS --max-time 1 http://127.0.0.1:19777/healthz >/dev/null || {
    echo "RelayKit App gateway stopped before official login verification" >&2
    return 1
  }
  preflight_status="$(official_gateway_preflight_status)"
  if [[ "${preflight_status}" != "connected" ]]; then
    route_status="official_preflight_${preflight_status}"
    [[ "${preflight_status}" == "auth_required" ]] && route_status="official_auth_required"
    write_evidence "route_incomplete" "${route_status}" "${CONFIG_BEFORE}" "${AUTH_BEFORE}" "${CONFIG_HASH_BEFORE}" "${AUTH_HASH_BEFORE}" "${NOTIFY_HASH_BEFORE}"
    echo "RelayKit official login preflight remains incomplete: ${route_status}" >&2
    return 1
  fi
  reset_route_usage_after_preflight
}

case "${MODE}" in
  rc1-native-responses-three-stage)
    configure_rc1_native_responses_paths
    mkdir -p "${PROOF_ROOT}" "${RUN_DIR}"
    chmod 700 "${PROOF_ROOT}" "${RUN_DIR}"
    PROOF_INPUT_MODE="automated_ax"
    RELAYKIT_RC1_ATTACH_APP_GATEWAY=1
    RELAYKIT_DESKTOP_PROOF_REAL_PROVIDER_CONFIG="${PROVIDER_CONFIG}"
    RELAYKIT_DESKTOP_PROOF_PUBLIC_MODEL_ID="$(jq -er '.providers[0].models[0].id' "${PROVIDER_CONFIG}")"
    PROOF_PROVIDER_MODEL_ID="${RELAYKIT_DESKTOP_PROOF_PUBLIC_MODEL_ID}"
    trap cleanup_rc1_native_responses_desktop EXIT INT TERM HUP
    validate_automated_input_mode
    AUTO_SCENARIO_PATH="$(scenario_argument "$@")" || exit 2
    run_automated_proof "${AUTO_SCENARIO_PATH}"
    exit 0
    ;;
  run-auto)
    trap cleanup_automated_run EXIT
    trap handle_automated_signal INT TERM HUP
    validate_automated_input_mode || {
      AUTO_ERROR_CODE="input_mode_invalid"
      exit 2
    }
    AUTO_SCENARIO_PATH="$(scenario_argument "$@")" || {
      AUTO_ERROR_CODE="scenario_argument_invalid"
      exit 2
    }
    run_automated_proof "${AUTO_SCENARIO_PATH}"
    exit 0
    ;;
  run)
    trap cleanup_and_verify_global_state EXIT
    validate_input_mode
    capture_global_state
    setup_preflight real
    write_evidence "relaykit_app_ready" "not_started_manual_user_step" "${CONFIG_BEFORE}" "${AUTH_BEFORE}" "${CONFIG_HASH_BEFORE}" "${AUTH_HASH_BEFORE}" "${NOTIFY_HASH_BEFORE}"
    assert_proof_state_unchanged
    ensure_official_login_connected
    write_evidence "official_login_preflight_passed" "not_started_manual_user_step" "${CONFIG_BEFORE}" "${AUTH_BEFORE}" "${CONFIG_HASH_BEFORE}" "${AUTH_HASH_BEFORE}" "${NOTIFY_HASH_BEFORE}"
    assert_proof_state_unchanged
    launch_desktop
    TOOL_MARKER="RELAYKITTOOL$(date -u +%Y%m%d%H%M%S)$$"
    printf '%s\n' "${TOOL_MARKER}" >"${TOOL_MARKER_FILE}"
    date +%s >"${TOOL_SINCE_FILE}"
    activate_isolated_desktop
    verify_desktop_window_identity
    capture_desktop_window "before-manual-input"
    write_evidence "awaiting_user_action" "awaiting_gpt55_gui_request" "${CONFIG_BEFORE}" "${AUTH_BEFORE}" "${CONFIG_HASH_BEFORE}" "${AUTH_HASH_BEFORE}" "${NOTIFY_HASH_BEFORE}"
    assert_proof_state_unchanged
    cat <<EOF
RelayKit App-first isolated Desktop proof is ready.

RelayKit App: ${APP_BUNDLE}
Gateway: http://127.0.0.1:$(cat "${PORT_FILE}")/v1
Isolated CODEX_HOME: ${CODEX_HOME_DIR}
Isolated Desktop PID: $(jq -r '.pid' "${DESKTOP_WINDOW_IDENTITY}")
Isolated Desktop window: $(jq -r '.window_id' "${DESKTOP_WINDOW_IDENTITY}")
Evidence: ${OUT}/evidence.json

Keep this terminal open. Select this workspace: ${ROOT}

Stage 1/4 - select official gpt-5.5 and send exactly:
Reply with one sentence explaining why local gateway logs must redact credentials. Start with RelayKit Official 55 Live:

Wait for the visible reply, then press Enter here.
EOF
    wait_for_verified_stage_checkpoint "gpt55-response"
    assert_proof_state_unchanged
    write_evidence "awaiting_user_action" "awaiting_gpt56_gui_request" "${CONFIG_BEFORE}" "${AUTH_BEFORE}" "${CONFIG_HASH_BEFORE}" "${AUTH_HASH_BEFORE}" "${NOTIFY_HASH_BEFORE}"
    cat <<'EOF'
Stage 2/4 - select official gpt-5.6-luna and send exactly:
Reply with one sentence explaining why this proof must use the current Desktop bundled CLI. Start with RelayKit Official 56 Live:

Wait for the visible reply, then press Enter here.
EOF
    wait_for_verified_stage_checkpoint "gpt56-response"
    assert_proof_state_unchanged
    write_evidence "awaiting_user_action" "awaiting_provider_markdown_request" "${CONFIG_BEFORE}" "${AUTH_BEFORE}" "${CONFIG_HASH_BEFORE}" "${AUTH_HASH_BEFORE}" "${NOTIFY_HASH_BEFORE}"
    cat <<EOF
Stage 3/4 - select ${PROOF_PROVIDER_MODEL_ID} and send exactly:
Render exactly this Markdown structure and no extra sections:
- level-two heading text: RelayKit Rich Text Check
- numbered item 1 text: First route check
- numbered item 2 text: Second route check
- exactly two table columns named status and route
- table row: ready and official
- table row: ready and provider
- a bash fenced code block containing: echo relaykit
- bold conclusion text: RELAYKIT_FORMAT_OK
Do not call tools.

Wait for the fully rendered reply, then press Enter here.
EOF
    wait_for_verified_stage_checkpoint "provider-markdown"
    assert_proof_state_unchanged
    write_evidence "awaiting_user_action" "awaiting_provider_tool_request" "${CONFIG_BEFORE}" "${AUTH_BEFORE}" "${CONFIG_HASH_BEFORE}" "${AUTH_HASH_BEFORE}" "${NOTIFY_HASH_BEFORE}"
    cat <<EOF
Stage 4/4 - keep ${PROOF_PROVIDER_MODEL_ID} selected and send exactly:
Use the shell tool to run exactly: printf '${TOOL_MARKER}\\n'. Then report only the exact tool output. Do not inspect any files.

Wait until the visible tool block shows the executed printf command and exact marker output, then press Enter here.
EOF
    wait_for_verified_stage_checkpoint "provider-tool"
    assert_proof_state_unchanged
    sleep 1
    write_desktop_tool_evidence "$(cat "${TOOL_SINCE_FILE}")" "${PROOF_PROVIDER_MODEL_ID}" "$(cat "${TOOL_MARKER_FILE}")"
    write_desktop_render_evidence "$(cat "${TOOL_SINCE_FILE}")" "${PROOF_PROVIDER_MODEL_ID}" "${SCREENSHOT_EVIDENCE}"
    cleanup_processes
    ROUTE_STATUS="$(manual_route_status)"
    if [[ "${ROUTE_STATUS}" == "complete" ]]; then
      if [[ "${PROOF_INPUT_MODE}" == "manual_user_only" ]]; then
        write_evidence "route_complete" "complete" "${CONFIG_BEFORE}" "${AUTH_BEFORE}" "${CONFIG_HASH_BEFORE}" "${AUTH_HASH_BEFORE}" "${NOTIFY_HASH_BEFORE}"
      else
        write_evidence "same_profile_cli_route_complete" "same_profile_cli_route_complete" "${CONFIG_BEFORE}" "${AUTH_BEFORE}" "${CONFIG_HASH_BEFORE}" "${AUTH_HASH_BEFORE}" "${NOTIFY_HASH_BEFORE}"
      fi
      assert_proof_state_unchanged
      if [[ "${PROOF_INPUT_MODE}" == "manual_user_only" ]]; then
        echo "RelayKit route proof complete: official=verified provider=verified tool=confirmed display=clean evidence=${OUT}/evidence.json"
      else
        echo "RelayKit same-profile CLI route proof complete; Desktop GUI input/display remains unverified: ${OUT}/evidence.json"
      fi
    else
      write_evidence "route_incomplete" "${ROUTE_STATUS}" "${CONFIG_BEFORE}" "${AUTH_BEFORE}" "${CONFIG_HASH_BEFORE}" "${AUTH_HASH_BEFORE}" "${NOTIFY_HASH_BEFORE}"
      assert_proof_state_unchanged
      echo "RelayKit route proof incomplete: ${ROUTE_STATUS}; evidence=${OUT}/evidence.json" >&2
      exit 1
    fi
    ;;
  --setup-only|setup)
    trap cleanup_and_verify_global_state EXIT
    capture_global_state
    setup_preflight fixture
    cleanup_processes
    write_evidence "fixture_plumbing_preflight_passed" "not_started_manual_user_step" "${CONFIG_BEFORE}" "${AUTH_BEFORE}" "${CONFIG_HASH_BEFORE}" "${AUTH_HASH_BEFORE}" "${NOTIFY_HASH_BEFORE}"
    assert_proof_state_unchanged
    echo "RelayKit fixture catalog/picker plumbing preflight passed: ${OUT}/evidence.json"
    ;;
  status)
    if [[ -f "${OUT}/evidence.json" ]]; then
      jq '.' "${OUT}/evidence.json"
    else
      echo "No manual Desktop proof evidence found at ${OUT}/evidence.json" >&2
      exit 1
    fi
    ;;
  cleanup)
    cleanup_processes
    echo "RelayKit manual Desktop proof processes stopped"
    ;;
  --purge|purge)
    cleanup_processes
    delete_proof_keychain_items
    rm -rf "${PROOF_ROOT}" "${OUT}"
    echo "RelayKit manual Desktop proof state removed"
    ;;
  --print-desktop-binary)
    if ! resolve_codex_app_binary; then
      echo "Codex Desktop app with bundle id com.openai.codex was not found" >&2
      exit 1
    fi
    ;;
  --print-desktop-codex-binary)
    if ! resolve_codex_cli_binary; then
      echo "Codex Desktop bundled codex CLI was not found" >&2
      exit 1
    fi
    ;;
  --print-rc1-native-responses-contract)
    print_rc1_native_responses_contract
    ;;
  --test-stop-pid-file)
    [[ -n "${2:-}" ]] || exit 2
    kill_pid_file "$2"
    ;;
  --test-stale-desktop-lock-cleanup)
    [[ -n "${3:-}" && -z "${4:-}" ]] || exit 2
    cleanup_stale_isolated_desktop_locks "$2" "$3"
    ;;
  --test-global-state-guard)
    [[ -n "${6:-}" ]] || exit 2
    CONFIG_BEFORE="$2"
    AUTH_BEFORE="$3"
    CONFIG_HASH_BEFORE="$4"
    AUTH_HASH_BEFORE="$5"
    NOTIFY_HASH_BEFORE="$6"
    assert_global_state_unchanged
    ;;
  --test-source-snapshot-hash)
    [[ -n "${2:-}" ]] || exit 2
    source_snapshot_hash "$2"
    ;;
  --test-source-state-guard)
    [[ -n "${3:-}" ]] || exit 2
    assert_source_snapshot_unchanged "$2" "$3"
    ;;
  --test-harness-snapshot-hash)
    [[ -n "${2:-}" ]] || exit 2
    harness_snapshot_hash "$2"
    ;;
  --test-scenario-state-guard)
    [[ -n "${3:-}" ]] || exit 2
    SCENARIO_PATH="$2"
    SCENARIO_HASH_BEFORE="$3"
    assert_scenario_unchanged
    ;;
  --test-product-artifact-state-guard)
    [[ -n "${3:-}" ]] || exit 2
    assert_product_artifact_unchanged "$2" "$3"
    ;;
  --test-provider-gateway-status)
    [[ -n "${3:-}" ]] || exit 2
    provider_gateway_status_from_file "$2" "$3"
    ;;
  --test-extracted-app-matches-zip)
    [[ -n "${4:-}" ]] || exit 2
    verify_extracted_app_matches_zip "$2" "$3" "$4"
    ;;
  --test-preserve-route-evidence)
    [[ -n "${4:-}" ]] || exit 2
    preserve_existing_route_evidence "$2" "$3" "$4"
    ;;
  --test-route-outcome)
    [[ -n "${6:-}" ]] || exit 2
    ROUTE_STATUS="$(route_outcome_from_usage_file "$2" "$3" "$4" "$5" "$6")"
    printf '%s\n' "${ROUTE_STATUS}"
    [[ "${ROUTE_STATUS}" == "complete" ]]
    ;;
  --test-stage-checkpoint)
    [[ -n "${6:-}" ]] || exit 2
    stage_checkpoint_verified "$2" "$3" "$4" "$5" "$6"
    printf 'verified\n'
    ;;
  --test-sandbox-policy)
    require_sandbox_policy
    ;;
  --test-write-desktop-sandbox-profile)
    [[ -n "${2:-}" ]] || exit 2
    write_desktop_sandbox_profile "$2"
    ;;
  --test-input-mode)
    validate_input_mode
    ;;
  --test-tool-ui-review-status)
    [[ -n "${4:-}" && -z "${5:-}" ]] || exit 2
    desktop_gui_tool_ui_review_status "$2" "$3" "$4"
    ;;
  --test-automated-input-mode)
    validate_automated_input_mode
    ;;
  --test-auto-scenario)
    [[ -n "${2:-}" ]] || exit 2
    validate_auto_scenario "$2"
    ;;
  --test-postbinding-query-content)
    [[ -n "${4:-}" && -z "${5:-}" ]] || exit 2
    validate_postbinding_query_content "$2" "$3" "$4"
    ;;
  --test-fresh-stage-usage)
    [[ -n "${4:-}" ]] || exit 2
    fresh_stage_usage "$2" "$3" "$4"
    ;;
  --test-fresh-completed-stage-usage)
    [[ -n "${3:-}" && -z "${4:-}" ]] || exit 2
    fresh_completed_stage_usage "$2" "$3"
    ;;
  --test-submitted-model-usage)
    [[ -n "${4:-}" && -z "${5:-}" ]] || exit 2
    submitted_model_usage_matches "$2" "$3" "$4"
    ;;
  --test-auto-rollout-binding)
    [[ -n "${6:-}" ]] || exit 2
    write_automated_rollout_binding "$2" "$3" "$4" "$5" "$6"
    ;;
  --test-submitted-model-selection)
    [[ -n "${3:-}" && -z "${4:-}" ]] || exit 2
    submitted_model_selection_matches "$2" "$3"
    ;;
  --test-automated-profile)
    [[ -n "${3:-}" ]] || exit 2
    automated_profile_for_scenario "$2" "$3"
    ;;
  --test-resolve-automated-model-label)
    [[ -n "${3:-}" ]] || exit 2
    resolve_automated_model_label "$2" "$3"
    ;;
  --test-resolve-automated-scenario-models)
    [[ -n "${3:-}" && -z "${4:-}" ]] || exit 2
    resolve_automated_scenario_models "$2" "$3"
    ;;
  --test-automated-stages-complete)
    [[ -n "${3:-}" ]] || exit 2
    automated_stages_complete "$2" "$3"
    ;;
  --test-custom-tool-scenario-complete)
    [[ -n "${5:-}" && -z "${6:-}" ]] || exit 2
    custom_tool_scenario_complete "$2" "$3" "$4" "$5"
    ;;
  --test-write-codex-config)
    [[ -n "${2:-}" ]] || exit 2
    if [[ -n "${3:-}" ]]; then
      [[ "${3}" == "fixture_plumbing_preflight" || "${3}" == "rc1_native_responses" ]] || exit 2
      PROOF_SCOPE="${3}"
    fi
    ensure_dirs
    write_codex_config "$2"
    ;;
  --test-real-provider-policy)
    validate_real_provider_policy
    ;;
  --test-merge-model-catalog)
    [[ -n "${5:-}" ]] || exit 2
    merge_model_catalog "$2" "$3" "$4" "$5"
    ;;
  --test-project-official-catalog)
    [[ -n "${5:-}" ]] || exit 2
    project_official_model_catalog "$2" "$3" "$4" "$5"
    ;;
  --test-sync-official-models)
    [[ -n "${4:-}" ]] || exit 2
    sync_official_models_to_provider_config "$2" "$3" "$4"
    ;;
  --test-write-app-server-evidence)
    [[ -n "${7:-}" && -z "${8:-}" ]] || exit 2
    [[ "$(basename "$2")" == "app-server.json" ]] || exit 2
    OUT="$(dirname "$2")"
    PROVIDER_CONFIG="$3"
    CODEX_CLI_BINARY="$4"
    APP_SERVER_SETUP_ID="$5"
    APP_SERVER_SESSION_ID="$6"
    APP_ZIP_SHA256="$7"
    write_app_server_evidence
    ;;
  --test-reset-run-markers)
    reset_run_markers
    cat "${DESKTOP_SANDBOX_STATUS_FILE}"
    ;;
  --test-rc1-isolated-auth-home)
    [[ -n "${2:-}" && -z "${3:-}" ]] || exit 2
    resolve_rc1_isolated_auth_home "$2"
    ;;
  --test-rc1-auth-status)
    [[ -n "${3:-}" && -z "${4:-}" ]] || exit 2
    rc1_isolated_auth_status "$2" "$3"
    ;;
  --test-rc1-auth-link-lifecycle)
    [[ -n "${3:-}" && -z "${4:-}" ]] || exit 2
    CODEX_HOME_DIR="$3"
    create_rc1_isolated_auth_link "$2" "${CODEX_HOME_DIR}"
    remove_rc1_isolated_auth_link
    ;;
  --test-tool-evidence)
    [[ -n "${6:-}" ]] || exit 2
    CODEX_HOME_DIR="$2"
    DESKTOP_TOOL_EVIDENCE="$3"
    write_desktop_tool_evidence "$4" "$5" "$6"
    ;;
  --test-render-evidence)
    [[ -n "${8:-}" ]] || exit 2
    CODEX_HOME_DIR="$2"
    DESKTOP_RENDER_EVIDENCE="$3"
    write_desktop_render_evidence "$4" "$5" "$6" "$7" "$8"
    ;;
  --test-screenshot-analysis)
    [[ -n "${3:-}" ]] || exit 2
    analyze_desktop_screenshot "$2" "$3" "${4:-}"
    ;;
  -h|--help|help)
    usage
    ;;
  *)
    usage
    exit 2
    ;;
esac
