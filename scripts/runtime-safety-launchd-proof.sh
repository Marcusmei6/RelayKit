#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EVIDENCE_DIR="${ROOT}/dist/runtime-safety-launchd"
EVIDENCE_PATH="${EVIDENCE_DIR}/evidence.json"
PHYSICAL_HOME="${HOME}"
WORK_ROOT=""
LABEL=""
PLIST=""
HELPER=""
TOKEN_PATH=""
TARGET=""
STATE=""
CONFIG=""
USAGE=""
PORT=""
UPSTREAM_PORT=""
BASE_URL=""
UPSTREAM_URL=""
PARENT_PID=""
UPSTREAM_PID=""
BOOTSTRAPPED=false
STATUS=failed
FAILURE=not_started
CASE_JSON='[]'
CONFIG_BEFORE=""
AUTH_BEFORE=""
LAUNCH_AGENTS_BEFORE=""
PORT_18787_BEFORE=""
PORT_19777_BEFORE=""
SOURCE_SHA=""
SOURCE_CLEAN=false
HARNESS_SHA=""
HARNESS_TEST_SHA=""
STARTUP_DIAGNOSTIC=none

print_contract() {
  jq -n '{
    proof: "runtime_safety_launchd",
    runtime: "isolated_launchd_socket_activation",
    cases: ["graceful_release", "app_loss", "unowned_restart", "helper_crash", "app_helper_loss"],
    shared_guards: ["global_config", "global_auth", "user_launch_agents", "18787", "19777"],
    writes_user_launch_agents: false,
    fixture_only: true
  }'
}

if [[ "${1:-}" == "--print-contract" ]]; then
  [[ "$#" -eq 1 ]] || exit 2
  print_contract
  exit 0
fi
[[ "$#" -eq 0 ]] || exit 2

signature() {
  local path="$1"
  if [[ ! -e "${path}" && ! -L "${path}" ]]; then
    printf absent
    return
  fi
  { /usr/bin/stat -f '%HT|%Sp|%z|%m|%i' "${path}"; /usr/bin/shasum -a 256 "${path}"; } |
    /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}'
}

launch_agents_signature() {
  local directory="${PHYSICAL_HOME}/Library/LaunchAgents"
  if [[ ! -d "${directory}" ]]; then
    printf absent
    return
  fi
  while IFS= read -r path; do
    printf '%s|' "$(/usr/bin/shasum -a 256 <<<"${path}" | /usr/bin/awk '{print $1}')"
    signature "${path}"
    printf '\n'
  done < <(/usr/bin/find "${directory}" -maxdepth 1 -type f -print | LC_ALL=C /usr/bin/sort) |
    /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}'
}

listener_snapshot() {
  local port="$1" pids
  pids="$(/usr/sbin/lsof -nP -a -iTCP@127.0.0.1:"${port}" -sTCP:LISTEN -t 2>/dev/null | LC_ALL=C sort -u || true)"
  [[ -n "${pids}" ]] || { printf absent; return; }
  while IFS= read -r pid; do
    /bin/ps -ww -o pid=,ppid=,lstart=,command= -p "${pid}"
  done <<<"${pids}" | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}'
}

port_is_free() {
  [[ -z "$(/usr/sbin/lsof -nP -a -iTCP@127.0.0.1:"$1" -sTCP:LISTEN -t 2>/dev/null || true)" ]]
}

pick_ports() {
  local candidate attempt
  for ((attempt = 0; attempt < 300; attempt++)); do
    candidate=$((22000 + (RANDOM % 30000)))
    [[ "${candidate}" != 18787 && "${candidate}" != 19777 ]] || continue
    port_is_free "${candidate}" || continue
    PORT="${candidate}"
    break
  done
  [[ -n "${PORT}" ]] || return 1
  for ((attempt = 0; attempt < 300; attempt++)); do
    candidate=$((22000 + (RANDOM % 30000)))
    [[ "${candidate}" != "${PORT}" && "${candidate}" != 18787 && "${candidate}" != 19777 ]] || continue
    port_is_free "${candidate}" || continue
    UPSTREAM_PORT="${candidate}"
    break
  done
  [[ -n "${UPSTREAM_PORT}" ]]
  BASE_URL="http://127.0.0.1:${PORT}/v1"
  UPSTREAM_URL="http://127.0.0.1:${UPSTREAM_PORT}"
}

pid_alive() {
  [[ -n "$1" ]] && /bin/kill -0 "$1" 2>/dev/null
}

wait_pid_exit() {
  local pid="$1" index
  for ((index = 0; index < 80; index++)); do
    pid_alive "${pid}" || return 0
    /bin/sleep 0.1
  done
  return 1
}

helper_pid() {
  [[ -n "${HELPER}" ]] || return 0
  /usr/bin/pgrep -f "^${HELPER//\//\\/} .*launchd-socket-name RelayKitGateway" 2>/dev/null |
    LC_ALL=C /usr/bin/sort -u | /usr/bin/head -1
}

wait_health() {
  local index
  for ((index = 0; index < 80; index++)); do
    /usr/bin/curl -fsS --max-time 1 "http://127.0.0.1:${PORT}/healthz" >/dev/null 2>&1 && return 0
    /bin/sleep 0.1
  done
  return 1
}

wait_upstream() {
  local index
  for ((index = 0; index < 80; index++)); do
    /usr/bin/curl -fsS --max-time 1 "${UPSTREAM_URL}/healthz" >/dev/null 2>&1 && return 0
    /bin/sleep 0.1
  done
  return 1
}

classify_launchd_health_failure() {
  local stderr_path="${WORK_ROOT}/helper.stderr"
  if grep -Fq 'launchd socket activation failed:' "${stderr_path}" 2>/dev/null; then
    printf launchd_socket_activation_failed
  elif grep -Fq 'launchd socket activation returned' "${stderr_path}" 2>/dev/null; then
    printf launchd_socket_descriptor_count_invalid
  elif grep -Fq 'gateway config failed:' "${stderr_path}" 2>/dev/null; then
    printf launchd_gateway_config_failed
  elif grep -Fq 'gateway control token failed validation' "${stderr_path}" 2>/dev/null; then
    printf launchd_control_token_invalid
  elif grep -Fq 'gateway listen failed:' "${stderr_path}" 2>/dev/null; then
    printf launchd_gateway_listen_failed
  elif grep -Fq 'gateway failed:' "${stderr_path}" 2>/dev/null; then
    printf launchd_gateway_serve_failed
  elif grep -Fq 'managed Codex recovery' "${stderr_path}" 2>/dev/null; then
    printf launchd_managed_recovery_invalid
  elif grep -Eq 'flag provided but not defined|invalid value .* for flag' "${stderr_path}" 2>/dev/null; then
    printf launchd_argument_invalid
  elif grep -Fq 'relaykit gateway listening on' "${stderr_path}" 2>/dev/null; then
    printf launchd_helper_started_health_unreachable
  elif [[ ! -s "${stderr_path}" ]]; then
    printf launchd_helper_not_started
  else
    printf launchd_helper_start_failed
  fi
}

redacted_launchd_startup_diagnostic() {
  /usr/bin/tail -n 6 "${WORK_ROOT}/helper.stderr" 2>/dev/null |
    /usr/bin/sed -E \
      -e 's#/tmp/relaykit-launchd-safety\.[^ /]+#<tmp>#g' \
      -e 's#https?://127\.0\.0\.1:[0-9]+#http://127.0.0.1:<port>#g' \
      -e 's#[[:xdigit:]]{24,}#<redacted>#g' |
    /usr/bin/tr '\r\n' '  ' |
    /usr/bin/cut -c1-512
}

gateway_mode() {
  /usr/bin/curl -fsS --max-time 1 "http://127.0.0.1:${PORT}/healthz" | jq -er '.mode'
}

enable_route() {
  "${HELPER}" enable-codex-config -target "${TARGET}" -catalog "${WORK_ROOT}/catalog.json" \
    -state "${STATE}" -base-url "${BASE_URL}" >/dev/null
}

route_status() {
  "${HELPER}" codex-config-status -target "${TARGET}" -state "${STATE}" 2>/dev/null
}

adopt() {
  local index
  for ((index = 0; index < 20; index++)); do
    if printf '%s' '{"version":1,"credentials":{}}' |
      "${HELPER}" gateway-control -endpoint "http://127.0.0.1:${PORT}" -token-file "${TOKEN_PATH}" \
        -action adopt -parent-pid "${PARENT_PID}" >/dev/null 2>&1; then
      return 0
    fi
    /bin/sleep 0.1
  done
  return 1
}

release() {
  "${HELPER}" gateway-control -endpoint "http://127.0.0.1:${PORT}" -token-file "${TOKEN_PATH}" \
    -action release -parent-pid "${PARENT_PID}" >/dev/null
}

cached_request() {
  /usr/bin/curl -fsS --max-time 3 -H 'Content-Type: application/json' \
    --data '{"model":"runtime-safety-official","input":"fixture continuity"}' \
    "${BASE_URL}/responses" | jq -e '.status == "completed"' >/dev/null
}

direct_request() {
  grep -Fq "openai_base_url = \"${UPSTREAM_URL}/v1\"" "${TARGET}" &&
    /usr/bin/curl -fsS --max-time 3 -H 'Content-Type: application/json' \
      --data '{"model":"runtime-safety-official","input":"fixture direct"}' \
      "${UPSTREAM_URL}/v1/responses" | jq -e '.status == "completed"' >/dev/null
}

start_parent() {
  local ready="${WORK_ROOT}/parent-owner.ready" index
  rm -f "${ready}"
  /usr/bin/python3 - "${TOKEN_PATH}" "${ready}" <<'PY' &
import fcntl
import pathlib
import sys
import time

with open(sys.argv[1], "rb") as lease:
    fcntl.flock(lease.fileno(), fcntl.LOCK_EX)
    pathlib.Path(sys.argv[2]).write_text("ready", encoding="utf-8")
    time.sleep(600)
PY
  PARENT_PID=$!
  for ((index = 0; index < 50; index++)); do
    [[ -f "${ready}" ]] && return 0
    /bin/sleep 0.05
  done
  return 1
}

stop_parent() {
  if pid_alive "${PARENT_PID}"; then
    /bin/kill -KILL "${PARENT_PID}" 2>/dev/null || true
    wait_pid_exit "${PARENT_PID}" || return 1
  fi
  PARENT_PID=""
}

record_case() {
  local name="$1" safe_outcome="$2" helper_restarted="$3" config_restored="$4"
  local mode_after="$5" cached_before="$6" cached_after="$7" new_direct="$8"
  CASE_JSON="$(
    jq -c \
      --arg name "${name}" \
      --arg safe_outcome "${safe_outcome}" \
      --arg mode_after "${mode_after}" \
      --argjson helper_restarted "${helper_restarted}" \
      --argjson config_restored "${config_restored}" \
      --argjson cached_before "${cached_before}" \
      --argjson cached_after "${cached_after}" \
      --argjson new_direct "${new_direct}" \
      '. + [{
        name:$name,
        status:"passed",
        safe_outcome:$safe_outcome,
        socket_activated:true,
        helper_restarted:$helper_restarted,
        config_restored:$config_restored,
        mode_after:$mode_after,
        cached_request_before:$cached_before,
        cached_request_after:$cached_after,
        new_direct_after_restore:$new_direct
      }]' <<<"${CASE_JSON}"
  )"
}

wait_restored_fallback() {
  local index
  for ((index = 0; index < 80; index++)); do
    if [[ "$(route_status || true)" == disabled && "$(gateway_mode 2>/dev/null || true)" == official_fallback ]]; then
      return 0
    fi
    /bin/sleep 0.1
  done
  return 1
}

cleanup() {
  local incoming=$?
  trap - EXIT INT TERM HUP
  set +e
  stop_parent >/dev/null 2>&1 || true
  if [[ "${BOOTSTRAPPED}" == true ]]; then
    /bin/launchctl bootout "gui/$(/usr/bin/id -u)/${LABEL}" >/dev/null 2>&1 || true
  fi
  if pid_alive "${UPSTREAM_PID}"; then
    /bin/kill -TERM "${UPSTREAM_PID}" 2>/dev/null || true
    wait_pid_exit "${UPSTREAM_PID}" || /bin/kill -KILL "${UPSTREAM_PID}" 2>/dev/null || true
  fi
  local service_removed=true helpers_stopped=true ports_released=true global_guards=true cleanup_ok=true
  if [[ -n "${LABEL}" ]] && /bin/launchctl print "gui/$(/usr/bin/id -u)/${LABEL}" >/dev/null 2>&1; then
    service_removed=false
  fi
  [[ -z "$(helper_pid || true)" ]] || helpers_stopped=false
  port_is_free "${PORT}" || ports_released=false
  port_is_free "${UPSTREAM_PORT}" || ports_released=false
  [[ "$(signature "${PHYSICAL_HOME}/.codex/config.toml")" == "${CONFIG_BEFORE}" ]] || global_guards=false
  [[ "$(signature "${PHYSICAL_HOME}/.codex/auth.json")" == "${AUTH_BEFORE}" ]] || global_guards=false
  [[ "$(launch_agents_signature)" == "${LAUNCH_AGENTS_BEFORE}" ]] || global_guards=false
  [[ "$(listener_snapshot 18787)" == "${PORT_18787_BEFORE}" ]] || global_guards=false
  [[ "$(listener_snapshot 19777)" == "${PORT_19777_BEFORE}" ]] || global_guards=false
  [[ "${service_removed}" == true && "${helpers_stopped}" == true && "${ports_released}" == true && "${global_guards}" == true ]] || cleanup_ok=false
  mkdir -p "${EVIDENCE_DIR}"
  jq -n \
    --arg status "$([[ "${incoming}" -eq 0 && "${STATUS}" == passed && "${cleanup_ok}" == true ]] && printf passed || printf failed)" \
    --arg failure "${FAILURE}" \
    --arg source_sha "${SOURCE_SHA}" \
    --arg harness_sha "${HARNESS_SHA}" \
    --arg harness_test_sha "${HARNESS_TEST_SHA}" \
    --arg startup_diagnostic "${STARTUP_DIAGNOSTIC}" \
    --argjson source_clean "${SOURCE_CLEAN}" \
    --argjson cases "${CASE_JSON}" \
    --argjson service_removed "${service_removed}" \
    --argjson helpers_stopped "${helpers_stopped}" \
    --argjson ports_released "${ports_released}" \
    --argjson global_guards "${global_guards}" \
    '{
      schema_version:1,
      proof:"runtime_safety_launchd",
      status:$status,
      failure:$failure,
      fixture_only:true,
      source_commit_sha:$source_sha,
      source_clean:$source_clean,
      harness_sha256:$harness_sha,
      harness_test_sha256:$harness_test_sha,
      startup_diagnostic:$startup_diagnostic,
      cases:$cases,
      global_guards_unchanged:$global_guards,
      cleanup:{
        service_removed:$service_removed,
        helper_processes_stopped:$helpers_stopped,
        ports_released:$ports_released
      }
    }' >"${EVIDENCE_PATH}"
  chmod 600 "${EVIDENCE_PATH}"
  jq -c '{status,failure,startup_diagnostic,cases,global_guards_unchanged,cleanup}' "${EVIDENCE_PATH}" >&2
  [[ -z "${WORK_ROOT}" ]] || rm -rf "${WORK_ROOT}"
  [[ "${incoming}" -eq 0 && "${STATUS}" == passed && "${cleanup_ok}" == true ]] || exit 1
}

trap cleanup EXIT
trap 'FAILURE=interrupted; exit 130' INT
trap 'FAILURE=interrupted; exit 143' TERM
trap 'FAILURE=interrupted; exit 129' HUP

FAILURE=preflight_tools
command -v go >/dev/null
command -v jq >/dev/null
SOURCE_SHA="$(git -C "${ROOT}" rev-parse HEAD)"
if git -C "${ROOT}" diff --quiet && git -C "${ROOT}" diff --cached --quiet &&
  [[ -z "$(git -C "${ROOT}" ls-files --others --exclude-standard)" ]]; then
  SOURCE_CLEAN=true
fi
HARNESS_SHA="$(/usr/bin/shasum -a 256 "${BASH_SOURCE[0]}" | /usr/bin/awk '{print $1}')"
HARNESS_TEST_SHA="$(/usr/bin/shasum -a 256 "${ROOT}/scripts/runtime-safety-launchd-proof-test.sh" | /usr/bin/awk '{print $1}')"
FAILURE=preflight_isolation
pick_ports
CONFIG_BEFORE="$(signature "${PHYSICAL_HOME}/.codex/config.toml")"
AUTH_BEFORE="$(signature "${PHYSICAL_HOME}/.codex/auth.json")"
LAUNCH_AGENTS_BEFORE="$(launch_agents_signature)"
PORT_18787_BEFORE="$(listener_snapshot 18787)"
PORT_19777_BEFORE="$(listener_snapshot 19777)"

WORK_ROOT="$(mktemp -d /tmp/relaykit-launchd-safety.XXXXXX)"
chmod 700 "${WORK_ROOT}"
HELPER="${WORK_ROOT}/relay"
FAILURE=helper_build
(cd "${ROOT}/gateway" && go build -trimpath -o "${HELPER}" ./cmd/gateway)
TOKEN_PATH="${WORK_ROOT}/control.token"
TARGET="${WORK_ROOT}/config.toml"
STATE="${WORK_ROOT}/state.json"
CONFIG="${WORK_ROOT}/gateway-runtime.json"
USAGE="${WORK_ROOT}/usage.jsonl"
printf '%064d\n' 0 >"${TOKEN_PATH}"
printf 'model = "runtime-safety-official"\nopenai_base_url = "%s/v1"\n' "${UPSTREAM_URL}" >"${TARGET}"
printf '%s\n' '{"models":[]}' >"${WORK_ROOT}/catalog.json"
printf '%s\n' fixture-key >"${WORK_ROOT}/official.key"
chmod 600 "${TOKEN_PATH}" "${TARGET}" "${WORK_ROOT}/catalog.json" "${WORK_ROOT}/official.key"
cat >"${CONFIG}" <<JSON
{"official_passthrough":{"base_url":"${UPSTREAM_URL}/v1","credential_ref":{"kind":"key_file","value":"${WORK_ROOT}/official.key"},"models":[{"id":"runtime-safety-official"}]},"providers":[]}
JSON
chmod 600 "${CONFIG}"

FAILURE=fixture_start
/usr/bin/python3 - "${UPSTREAM_PORT}" >"${WORK_ROOT}/upstream.out" 2>"${WORK_ROOT}/upstream.err" <<'PY' &
import json, sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
class H(BaseHTTPRequestHandler):
    def log_message(self, *_): pass
    def do_GET(self):
        if self.path != "/healthz":
            self.send_error(404); return
        self.send_response(200); self.send_header("Content-Type", "application/json"); self.end_headers()
        self.wfile.write(b'{"status":"ok"}')
    def do_POST(self):
        self.rfile.read(int(self.headers.get("Content-Length", "0")))
        self.send_response(200); self.send_header("Content-Type", "application/json"); self.end_headers()
        if self.path.endswith("/chat/completions"):
            body={"id":"fixture","model":"runtime-safety-official","choices":[{"message":{"role":"assistant","content":"fixture"},"finish_reason":"stop"}],"usage":{"prompt_tokens":1,"completion_tokens":1,"total_tokens":2}}
        else:
            body={"id":"fixture","object":"response","model":"runtime-safety-official","status":"completed","output":[],"usage":{"input_tokens":1,"output_tokens":1,"total_tokens":2}}
        self.wfile.write(json.dumps(body,separators=(",",":")).encode())
ThreadingHTTPServer(("127.0.0.1",int(sys.argv[1])),H).serve_forever()
PY
UPSTREAM_PID=$!
FAILURE=fixture_health
wait_upstream

LABEL="dev.relaykit.runtime-safety.$(/usr/bin/uuidgen | tr '[:upper:]' '[:lower:]')"
PLIST="${WORK_ROOT}/${LABEL}.plist"
cat >"${PLIST}" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>${LABEL}</string>
<key>ProgramArguments</key><array>
<string>${HELPER}</string><string>-listen</string><string>127.0.0.1:${PORT}</string>
<string>-launchd-socket-name</string><string>RelayKitGateway</string>
<string>-config</string><string>${CONFIG}</string><string>-usage-log</string><string>${USAGE}</string>
<string>-managed-codex-target</string><string>${TARGET}</string><string>-managed-codex-state</string><string>${STATE}</string>
<string>-control-token-file</string><string>${TOKEN_PATH}</string>
<string>-initial-official-fallback</string><string>-restore-unowned-after</string><string>30s</string>
</array>
<key>RunAtLoad</key><true/><key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
<key>ThrottleInterval</key><integer>1</integer>
<key>Umask</key><integer>63</integer>
<key>StandardOutPath</key><string>${WORK_ROOT}/helper.stdout</string>
<key>StandardErrorPath</key><string>${WORK_ROOT}/helper.stderr</string>
<key>Sockets</key><dict><key>RelayKitGateway</key><dict>
<key>SockFamily</key><string>IPv4</string><key>SockNodeName</key><string>127.0.0.1</string>
<key>SockServiceName</key><string>${PORT}</string><key>SockType</key><string>stream</string>
</dict></dict>
</dict></plist>
PLIST
/usr/bin/plutil -lint "${PLIST}" >/dev/null

FAILURE=launchd_bootstrap
/bin/launchctl bootstrap "gui/$(/usr/bin/id -u)" "${PLIST}"
BOOTSTRAPPED=true
FAILURE=launchd_health
if ! wait_health; then
  FAILURE="$(classify_launchd_health_failure)"
  STARTUP_DIAGNOSTIC="$(redacted_launchd_startup_diagnostic)"
  exit 1
fi

FAILURE=initial_enable
enable_route
start_parent
FAILURE=initial_adopt
adopt
FAILURE=initial_cached_request
cached_request
FAILURE=graceful_release
graceful_helper="$(helper_pid)"
[[ -n "${graceful_helper}" ]]
release
stop_parent
wait_restored_fallback
cached_request
direct_request
[[ "$(helper_pid)" == "${graceful_helper}" ]]
record_case graceful_release restored_config_with_fallback_listener false true official_fallback true true true

FAILURE=app_loss
enable_route
start_parent
adopt
cached_request
app_loss_helper="$(helper_pid)"
[[ -n "${app_loss_helper}" ]]
stop_parent
wait_restored_fallback
cached_request
direct_request
[[ "$(helper_pid)" == "${app_loss_helper}" ]]
record_case app_loss restored_config_with_fallback_listener false true official_fallback true true true

FAILURE=unowned_restart
enable_route
cached_request
old_helper="$(helper_pid)"
[[ -n "${old_helper}" ]]
/bin/kill -KILL "${old_helper}"
wait_pid_exit "${old_helper}"
cached_request
wait_restored_fallback
direct_request
new_helper="$(helper_pid)"
[[ -n "${new_helper}" && "${new_helper}" != "${old_helper}" ]]
record_case unowned_restart restored_config_before_unowned_listener true true official_fallback true true true

FAILURE=helper_crash
enable_route
start_parent
adopt
cached_request
old_helper="$(helper_pid)"
[[ -n "${old_helper}" ]]
/bin/kill -KILL "${old_helper}"
wait_pid_exit "${old_helper}"
adopt
new_helper="$(helper_pid)"
[[ -n "${new_helper}" && "${new_helper}" != "${old_helper}" ]]
[[ "$(route_status)" == enabled && "$(gateway_mode)" == managed ]]
cached_request
record_case helper_crash managed_config_with_restarted_listener true false managed true true false

FAILURE=app_helper_loss
cached_request
old_helper="${new_helper}"
/bin/kill -KILL "${PARENT_PID}" "${old_helper}"
wait_pid_exit "${PARENT_PID}"
PARENT_PID=""
wait_pid_exit "${old_helper}"
cached_request
wait_restored_fallback
direct_request
final_helper="$(helper_pid)"
[[ -n "${final_helper}" && "${final_helper}" != "${old_helper}" ]]
record_case app_helper_loss restored_config_with_restarted_fallback_listener true true official_fallback true true true

STATUS=passed
FAILURE=none
