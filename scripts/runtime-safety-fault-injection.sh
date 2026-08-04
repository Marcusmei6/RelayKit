#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EVIDENCE_DIR="${ROOT}/dist/runtime-safety"
EVIDENCE_PATH="${EVIDENCE_DIR}/evidence.json"
PHYSICAL_HOME="${HOME}"
RUNTIME_PORT=""
RUN_BASE_URL=""
SOURCE_SHA=""
HARNESS_SHA=""
HARNESS_TEST_SHA=""
WORK_ROOT=""
BUILT_HELPER=""
APP_BINARY=""
GRACEFUL_CONTROLLER=""
HELPER_SHA=""
APP_PID=""
HELPER_PID=""
BLOCKER_PID=""
OWNED_APP_PIDS=()
OWNED_HELPER_PIDS=()
OWNED_BLOCKER_PIDS=()
CURRENT_TARGET=""
CURRENT_STATE=""
CURRENT_CODEX_DIR=""
CURRENT_CASE_INDEX=-1
OVERALL_STATUS="failed"
FAILURE_CODE="not_started"
FAILURE_PHASE="preflight"
RESTORE_INJECTION_EFFECTIVE=false
RESTORE_DIAGNOSTICS_CAPTURED=false
RESTORE_CONFIG_POINTS_TO_RUN_BASE=false
RESTORE_RECOVERY_DECISION="not_observed"
RESTORE_HELPER_ALIVE=false
RESTORE_LISTENER_EXISTS=false
RESTORE_HELPER_EXIT_STATUS="not_observed"
RESTORE_HELPER_EXIT_SIGNAL="not_observed"
GATEWAY_STDOUT_SINK="unknown"
GATEWAY_STDERR_SINK="unknown"
GLOBAL_BEFORE_READY=false
CONFIG_UNCHANGED=false
AUTH_UNCHANGED=false
LAUNCH_AGENTS_UNCHANGED=false
PORT_19777_UNCHANGED=false
PORT_18787_UNCHANGED=false
CLEANUP_APP_PROCESSES=false
CLEANUP_HELPER_PROCESSES=false
CLEANUP_RUNTIME_PORT=false
CLEANUP_TEMP=false
FINALIZED=false

CASE_NAMES=(
  graceful_quit
  app_sigterm
  app_sigkill
  helper_sigterm
  helper_sigkill
  helper_startup_fail
  config_drift
  restore_failure
)
CASE_STATUSES=(not_run not_run not_run not_run not_run not_run not_run not_run)
CASE_SCOPES=(none none none none none none none none)
CASE_OUTCOMES=(none none none none none none none none)

print_contract() {
  jq -n '{
    proof: "runtime_safety_fault_injection",
    source: "current_checkout",
    runtime: "isolated_source_app",
    network: "loopback_health_only",
    protected_ports: [18787, 19777],
    global_files: "read_only_non_content_guards",
    launch_agents: "read_only_aggregate_guard",
    provider_requests: false,
    gui_automation: false,
    cases: [
      "graceful_quit",
      "app_sigterm",
      "app_sigkill",
      "helper_sigterm",
      "helper_sigkill",
      "helper_startup_fail",
      "config_drift",
      "restore_failure"
    ],
    evidence_fields: [
      "schema_version",
      "proof",
      "status",
      "source_sha",
      "harness_sha",
      "harness_test_sha",
      "random_port",
      "cases",
      "restore_failure_diagnostics",
      "global_guards",
      "installed_runtime_unchanged",
      "cleanup"
    ]
  }'
}

classify_safety_state() {
  local config_points="$1" helper_alive="$2" listener_exists="$3"
  if [[ "${config_points}" == false ]]; then
    printf 'managed_base_url_removed'
    return 0
  fi
  if [[ "${config_points}" == true && "${helper_alive}" == true && "${listener_exists}" == true ]]; then
    printf 'healthy_expected_listener'
    return 0
  fi
  return 1
}

if [[ "${1:-}" == "--print-contract" ]]; then
  [[ "$#" -eq 1 ]] || exit 2
  print_contract
  exit 0
fi
if [[ "${1:-}" == "--evaluate-safety" ]]; then
  [[ "$#" -eq 4 ]] || exit 2
  for value in "$2" "$3" "$4"; do
    [[ "${value}" == true || "${value}" == false ]] || exit 2
  done
  classify_safety_state "$2" "$3" "$4"
  exit $?
fi
[[ "$#" -eq 0 ]] || exit 2

hash_text() {
  printf '%s' "$1" | shasum -a 256 | awk '{print $1}'
}

file_signature() {
  local path="$1" metadata content_hash
  if [[ ! -e "${path}" && ! -L "${path}" ]]; then
    printf 'absent'
    return
  fi
  metadata="$(stat -f '%HT|%Sp|%z|%m|%i' "${path}" 2>/dev/null)" || return 1
  content_hash="$(shasum -a 256 "${path}" 2>/dev/null | awk '{print $1}')" || return 1
  hash_text "${metadata}|${content_hash}"
}

capture_gateway_sink_contract() {
  local source start_block
  source="${ROOT}/app/Sources/RelayKitApp/Services/GatewayProcess.swift"
  [[ -f "${source}" ]] || return 1
  start_block="$(sed -n '/func start(/,/func makeStartProcess/p' "${source}")" || return 1
  [[ "${start_block}" == *'process.standardOutput = FileHandle.nullDevice'* ]] || return 1
  [[ "${start_block}" == *'process.standardError = FileHandle.nullDevice'* ]] || return 1
  GATEWAY_STDOUT_SINK=null_device
  GATEWAY_STDERR_SINK=null_device
}

launch_agents_signature() {
  local directory="${PHYSICAL_HOME}/Library/LaunchAgents" aggregate="" path name_hash signature
  if [[ ! -d "${directory}" ]]; then
    printf 'absent'
    return
  fi
  while IFS= read -r path; do
    name_hash="$(hash_text "${path}")" || return 1
    signature="$(file_signature "${path}")" || return 1
    aggregate="${aggregate}${name_hash}|${signature}"$'\n'
  done < <(find "${directory}" -maxdepth 1 -type f -print 2>/dev/null | LC_ALL=C sort)
  hash_text "${aggregate}"
}

listener_pids() {
  lsof -nP -a -iTCP@127.0.0.1:"$1" -sTCP:LISTEN -t 2>/dev/null | LC_ALL=C sort -u || true
}

listener_snapshot() {
  local port="$1" pids pid executable executable_hash binary_signature parent started aggregate=""
  pids="$(listener_pids "${port}")"
  if [[ -z "${pids}" ]]; then
    printf 'absent'
    return
  fi
  while IFS= read -r pid; do
    [[ "${pid}" =~ ^[0-9]+$ ]] || return 1
    executable="$(lsof -a -p "${pid}" -d txt -Fn 2>/dev/null | sed -n 's/^n//p' | head -1)"
    [[ -n "${executable}" ]] || return 1
    executable_hash="$(hash_text "${executable}")" || return 1
    binary_signature="$(file_signature "${executable}")" || return 1
    parent="$(ps -o ppid= -p "${pid}" 2>/dev/null | tr -d ' ')" || return 1
    started="$(ps -o lstart= -p "${pid}" 2>/dev/null | tr -s ' ')" || return 1
    aggregate="${aggregate}${pid}|${parent}|${started}|${executable_hash}|${binary_signature}"$'\n'
  done <<<"${pids}"
  hash_text "${aggregate}"
}

capture_global_before() {
  CONFIG_BEFORE="$(file_signature "${PHYSICAL_HOME}/.codex/config.toml")" || return 1
  AUTH_BEFORE="$(file_signature "${PHYSICAL_HOME}/.codex/auth.json")" || return 1
  LAUNCH_AGENTS_BEFORE="$(launch_agents_signature)" || return 1
  PORT_19777_BEFORE="$(listener_snapshot 19777)" || return 1
  PORT_18787_BEFORE="$(listener_snapshot 18787)" || return 1
  GLOBAL_BEFORE_READY=true
}

capture_global_after() {
  local value
  [[ "${GLOBAL_BEFORE_READY}" == true ]] || return 1
  value="$(file_signature "${PHYSICAL_HOME}/.codex/config.toml")" || return 1
  [[ "${value}" == "${CONFIG_BEFORE}" ]] && CONFIG_UNCHANGED=true
  value="$(file_signature "${PHYSICAL_HOME}/.codex/auth.json")" || return 1
  [[ "${value}" == "${AUTH_BEFORE}" ]] && AUTH_UNCHANGED=true
  value="$(launch_agents_signature)" || return 1
  [[ "${value}" == "${LAUNCH_AGENTS_BEFORE}" ]] && LAUNCH_AGENTS_UNCHANGED=true
  value="$(listener_snapshot 19777)" || return 1
  [[ "${value}" == "${PORT_19777_BEFORE}" ]] && PORT_19777_UNCHANGED=true
  value="$(listener_snapshot 18787)" || return 1
  [[ "${value}" == "${PORT_18787_BEFORE}" ]] && PORT_18787_UNCHANGED=true
}

pid_is_alive() {
  local state
  [[ -n "$1" ]] || return 1
  kill -0 "$1" 2>/dev/null || return 1
  state="$(ps -o stat= -p "$1" 2>/dev/null | tr -d ' ')"
  [[ -n "${state}" && "${state}" != Z* ]]
}

wait_for_pid_exit() {
  local pid="$1" attempts="${2:-100}" index
  for ((index = 0; index < attempts; index++)); do
    pid_is_alive "${pid}" || return 0
    sleep 0.1
  done
  return 1
}

runtime_port_is_free() {
  [[ -z "$(listener_pids "${RUNTIME_PORT}")" ]]
}

target_points_to_run_base() {
  [[ -n "${CURRENT_TARGET}" && -f "${CURRENT_TARGET}" ]] || return 1
  grep -Fq "openai_base_url = \"${RUN_BASE_URL}\"" "${CURRENT_TARGET}"
}

listener_pid() {
  local pids count
  pids="$(listener_pids "${RUNTIME_PORT}")"
  count="$(printf '%s\n' "${pids}" | sed '/^$/d' | wc -l | tr -d ' ')"
  [[ "${count}" == "1" ]] || return 1
  printf '%s' "${pids}"
}

is_expected_helper_pid() {
  local pid="$1" executable signature
  executable="$(lsof -a -p "${pid}" -d txt -Fn 2>/dev/null | sed -n 's/^n//p' | head -1)"
  [[ -n "${executable}" ]] || return 1
  signature="$(file_signature "${executable}")" || return 1
  [[ "${signature}" == "${HELPER_SHA}" ]]
}

expected_listener_is_healthy() {
  local pid
  curl -fsS --max-time 1 "http://127.0.0.1:${RUNTIME_PORT}/healthz" >/dev/null 2>&1 || return 1
  pid="$(listener_pid)" || return 1
  is_expected_helper_pid "${pid}"
}

safe_outcome() {
  local config_points=false helper_alive=false listener_exists=false
  target_points_to_run_base && config_points=true
  pid_is_alive "${HELPER_PID}" && helper_alive=true
  expected_listener_is_healthy && listener_exists=true
  classify_safety_state "${config_points}" "${helper_alive}" "${listener_exists}"
}

capture_restore_failure_diagnostics() {
  RESTORE_DIAGNOSTICS_CAPTURED=true
  RESTORE_CONFIG_POINTS_TO_RUN_BASE=false
  RESTORE_HELPER_ALIVE=false
  RESTORE_LISTENER_EXISTS=false
  target_points_to_run_base && RESTORE_CONFIG_POINTS_TO_RUN_BASE=true
  pid_is_alive "${HELPER_PID}" && RESTORE_HELPER_ALIVE=true
  expected_listener_is_healthy && RESTORE_LISTENER_EXISTS=true
  if [[ "${RESTORE_HELPER_ALIVE}" == true ]]; then
    RESTORE_HELPER_EXIT_STATUS=running
    RESTORE_HELPER_EXIT_SIGNAL=none
  else
    RESTORE_HELPER_EXIT_STATUS=exited_or_unobservable
    RESTORE_HELPER_EXIT_SIGNAL=unobservable
  fi
  if [[ "${RESTORE_CONFIG_POINTS_TO_RUN_BASE}" == false ]]; then
    RESTORE_RECOVERY_DECISION=shutdown_after_restore
  elif [[ "${RESTORE_HELPER_ALIVE}" == true && "${RESTORE_LISTENER_EXISTS}" == true ]]; then
    RESTORE_RECOVERY_DECISION=retain_listener
  else
    RESTORE_RECOVERY_DECISION=unresolved
  fi
}

case_begin() {
  local name="$1" index
  for index in "${!CASE_NAMES[@]}"; do
    if [[ "${CASE_NAMES[$index]}" == "${name}" ]]; then
      CURRENT_CASE_INDEX="${index}"
      CASE_STATUSES[$index]=running
      CASE_SCOPES[$index]=product_lifecycle
      CASE_OUTCOMES[$index]=pending
      FAILURE_CODE="${name}_incomplete"
      FAILURE_PHASE="${name}"
      return
    fi
  done
  return 1
}

case_pass() {
  local scope="$1" outcome="$2"
  CASE_STATUSES[$CURRENT_CASE_INDEX]=passed
  CASE_SCOPES[$CURRENT_CASE_INDEX]="${scope}"
  CASE_OUTCOMES[$CURRENT_CASE_INDEX]="${outcome}"
  CURRENT_CASE_INDEX=-1
  FAILURE_CODE=none
}

case_fail() {
  local code="$1"
  if ((CURRENT_CASE_INDEX >= 0)); then
    CASE_STATUSES[$CURRENT_CASE_INDEX]=failed
    CASE_OUTCOMES[$CURRENT_CASE_INDEX]=unsafe
  fi
  FAILURE_CODE="${code}"
  FAILURE_PHASE="${code}"
  return 1
}

select_random_port() {
  local attempt candidate
  for ((attempt = 0; attempt < 200; attempt++)); do
    candidate=$((20000 + (RANDOM % 40000)))
    [[ "${candidate}" != 18787 && "${candidate}" != 19777 ]] || continue
    [[ -z "$(listener_pids "${candidate}")" ]] || continue
    RUNTIME_PORT="${candidate}"
    RUN_BASE_URL="http://127.0.0.1:${RUNTIME_PORT}/v1"
    return
  done
  return 1
}

build_current_products() {
  local swift_scratch="${WORK_ROOT}/swift-build" build_home="${WORK_ROOT}/build-home" candidates count go_bin go_module_cache swift_bin swiftc_bin controller_source
  go_bin="$(command -v go)" || return 1
  [[ "${go_bin}" == /* && -x "${go_bin}" ]] || return 1
  go_module_cache="$("${go_bin}" env GOMODCACHE 2>/dev/null)" || return 1
  [[ -n "${go_module_cache}" ]] || return 1
  swift_bin="$(command -v swift)" || return 1
  [[ "${swift_bin}" == /* && -x "${swift_bin}" ]] || return 1
  swiftc_bin="$(command -v swiftc)" || return 1
  [[ "${swiftc_bin}" == /* && -x "${swiftc_bin}" ]] || return 1
  mkdir -p "${WORK_ROOT}/gateway-build" "${WORK_ROOT}/go-cache" "${swift_scratch}" "${build_home}" "${WORK_ROOT}/build-logs"
  BUILT_HELPER="${WORK_ROOT}/gateway-build/relay"
  (
    cd "${ROOT}/gateway"
    env -i HOME="${build_home}" PATH="/usr/bin:/bin:/usr/sbin:/sbin" GOCACHE="${WORK_ROOT}/go-cache" \
      GOMODCACHE="${go_module_cache}" "${go_bin}" build -trimpath -o "${BUILT_HELPER}" ./cmd/gateway
  ) >"${WORK_ROOT}/build-logs/go.log" 2>&1 || return 1
  env -i HOME="${build_home}" CFFIXED_USER_HOME="${build_home}" PATH="/usr/bin:/bin:/usr/sbin:/sbin" \
    TMPDIR="${WORK_ROOT}" CLANG_MODULE_CACHE_PATH="${WORK_ROOT}/clang-cache" \
    SWIFTPM_MODULECACHE_OVERRIDE="${WORK_ROOT}/swift-module-cache" \
    "${swift_bin}" build --package-path "${ROOT}/app" --scratch-path "${swift_scratch}" -c debug --product RelayKitApp \
    >"${WORK_ROOT}/build-logs/swift.log" 2>&1 || return 1
  candidates="$(find "${swift_scratch}" -type f -name RelayKitApp -perm -111 -print)"
  count="$(printf '%s\n' "${candidates}" | sed '/^$/d' | wc -l | tr -d ' ')"
  [[ "${count}" == "1" ]] || return 1
  APP_BINARY="${candidates}"
  controller_source="${WORK_ROOT}/graceful-termination-controller.swift"
  GRACEFUL_CONTROLLER="${WORK_ROOT}/graceful-termination-controller"
  cat >"${controller_source}" <<'SWIFT'
import AppKit
import Foundation

guard CommandLine.arguments.count == 2,
      let processIdentifier = pid_t(CommandLine.arguments[1]),
      let application = NSRunningApplication(processIdentifier: processIdentifier),
      application.terminate() else {
    exit(1)
}
SWIFT
  env -i HOME="${build_home}" CFFIXED_USER_HOME="${build_home}" PATH="/usr/bin:/bin:/usr/sbin:/sbin" \
    TMPDIR="${WORK_ROOT}" CLANG_MODULE_CACHE_PATH="${WORK_ROOT}/controller-clang-cache" \
    "${swiftc_bin}" "${controller_source}" -o "${GRACEFUL_CONTROLLER}" \
    >"${WORK_ROOT}/build-logs/controller.log" 2>&1 || return 1
  [[ -x "${BUILT_HELPER}" && -x "${APP_BINARY}" && -x "${GRACEFUL_CONTROLLER}" ]] || return 1
}

prepare_layout() {
  mkdir -p "${WORK_ROOT}/layout/app/gateway/bin"
  cp "${BUILT_HELPER}" "${WORK_ROOT}/layout/app/gateway/bin/relay"
  chmod 700 "${WORK_ROOT}/layout/app/gateway/bin/relay"
  HELPER_SHA="$(file_signature "${WORK_ROOT}/layout/app/gateway/bin/relay")"
}

prepare_case() {
  local name="$1" case_root support
  case_root="${WORK_ROOT}/cases/${name}"
  runtime_port_is_free || return 1
  mkdir -p "${case_root}/home/.codex" "${case_root}/home/Library/Application Support/RelayKit" \
    "${case_root}/codex-home" "${case_root}/tmp" "${case_root}/logs"
  chmod 700 "${case_root}" "${case_root}/home" "${case_root}/home/.codex" "${case_root}/codex-home" "${case_root}/tmp"
  support="${case_root}/home/Library/Application Support/RelayKit"
  CURRENT_TARGET="${case_root}/home/.codex/config.toml"
  CURRENT_STATE="${support}/codex-config-state.json"
  CURRENT_CODEX_DIR="${case_root}/home/.codex"
  printf 'model = "fixture-model"\n' >"${CURRENT_TARGET}"
  printf '%s\n' '{"models":[]}' >"${support}/codex-model-catalog.json"
  printf '%s\n' '{"providers":[{"id":"fixture","name":"Fixture","base_url":"http://127.0.0.1:9/v1","api_format":"openai_chat","models":[{"id":"fixture-model"}]}]}' >"${support}/providers.json"
  chmod 600 "${CURRENT_TARGET}" "${support}/codex-model-catalog.json" "${support}/providers.json"
  CASE_HOME="${case_root}/home"
  CASE_CODEX_HOME="${case_root}/codex-home"
  CASE_TMP="${case_root}/tmp"
  CASE_LOGS="${case_root}/logs"
  CASE_CATALOG="${support}/codex-model-catalog.json"
  CASE_PROVIDER_CONFIG="${support}/providers.json"
  CASE_RUNTIME_CONFIG="${support}/gateway-runtime.json"
}

enable_route() {
  "${BUILT_HELPER}" enable-codex-config -target "${CURRENT_TARGET}" -catalog "${CASE_CATALOG}" \
    -state "${CURRENT_STATE}" -base-url "${RUN_BASE_URL}" >"${CASE_LOGS}/enable.log" 2>&1
  [[ "$("${BUILT_HELPER}" codex-config-status -target "${CURRENT_TARGET}" -state "${CURRENT_STATE}" 2>/dev/null)" == "enabled" ]]
}

disable_route() {
  if [[ -f "${CURRENT_STATE}" ]]; then
    "${BUILT_HELPER}" disable-codex-config -target "${CURRENT_TARGET}" -state "${CURRENT_STATE}" \
      >"${CASE_LOGS}/disable.log" 2>&1 || return 1
  fi
  ! target_points_to_run_base
}

launch_source_app() {
  local case_home="${CASE_HOME}" case_codex_home="${CASE_CODEX_HOME}"
  (
    cd "${WORK_ROOT}/layout/app"
    exec env -i HOME="${case_home}" CODEX_HOME="${case_codex_home}" CFFIXED_USER_HOME="${case_home}" \
      PATH="/usr/bin:/bin:/usr/sbin:/sbin" TMPDIR="${CASE_TMP}" \
      RELAYKIT_RUNTIME_SAFETY_TEST=1 RELAYKIT_RUNTIME_SAFETY_PORT="${RUNTIME_PORT}" \
      "${APP_BINARY}" --ui-smoke-provider-config "${CASE_PROVIDER_CONFIG}"
  ) >"${CASE_LOGS}/app.stdout" 2>"${CASE_LOGS}/app.stderr" &
  APP_PID=$!
  OWNED_APP_PIDS+=("${APP_PID}")
  pid_is_alive "${APP_PID}"
}

wait_for_expected_listener() {
  local index
  for ((index = 0; index < 120; index++)); do
    expected_listener_is_healthy && return 0
    sleep 0.1
  done
  return 1
}

wait_for_stable_expected_listener() {
  local index pid stable_pid="" stable_checks=0
  for ((index = 0; index < 200; index++)); do
    if expected_listener_is_healthy && pid="$(listener_pid)"; then
      if [[ "${pid}" == "${stable_pid}" ]]; then
        stable_checks=$((stable_checks + 1))
      else
        stable_pid="${pid}"
        stable_checks=1
      fi
      [[ "${stable_checks}" -ge 20 ]] && return 0
    else
      stable_pid=""
      stable_checks=0
    fi
    sleep 0.1
  done
  return 1
}

verify_app_helper_ownership() {
  local parent command
  HELPER_PID="$(listener_pid)" || return 1
  is_expected_helper_pid "${HELPER_PID}" || return 1
  OWNED_HELPER_PIDS+=("${HELPER_PID}")
  parent="$(ps -o ppid= -p "${HELPER_PID}" 2>/dev/null | tr -d ' ')" || return 1
  [[ "${parent}" == "${APP_PID}" ]] || return 1
  command="$(ps -ww -o command= -p "${HELPER_PID}" 2>/dev/null)" || return 1
  [[ "${command}" == *"-parent-pid ${APP_PID}"* ]] || return 1
  [[ "${command}" == *"-managed-codex-target ${CURRENT_TARGET}"* ]] || return 1
  [[ "${command}" == *"-managed-codex-state ${CURRENT_STATE}"* ]] || return 1
}

launch_managed_case() {
  enable_route || {
    FAILURE_CODE=managed_route_enable_failed
    return 1
  }
  launch_source_app || {
    FAILURE_CODE=source_app_launch_failed
    return 1
  }
  if ! wait_for_expected_listener; then
    if ! pid_is_alive "${APP_PID}"; then
      FAILURE_CODE=source_app_exited_before_listener
    elif [[ ! -f "${CASE_RUNTIME_CONFIG}" ]]; then
      FAILURE_CODE=source_app_runtime_config_missing
    elif [[ -z "$(pgrep -P "${APP_PID}" 2>/dev/null || true)" ]]; then
      FAILURE_CODE=source_app_helper_not_running
    else
      FAILURE_CODE=source_app_listener_unhealthy
    fi
    return 1
  fi
  wait_for_stable_expected_listener || {
    FAILURE_CODE=source_app_listener_not_stable
    return 1
  }
  verify_app_helper_ownership || {
    FAILURE_CODE=source_app_helper_ownership_failed
    return 1
  }
}

stop_case_processes() {
  local ok=true app_to_reap="${APP_PID}" blocker_to_reap="${BLOCKER_PID}"
  if [[ -n "${CURRENT_CODEX_DIR}" && -d "${CURRENT_CODEX_DIR}" ]]; then
    chmod 700 "${CURRENT_CODEX_DIR}" 2>/dev/null || ok=false
  fi
  if target_points_to_run_base; then
    disable_route || ok=false
  fi
  if pid_is_alive "${APP_PID}"; then
    kill -KILL "${APP_PID}" 2>/dev/null || true
    wait_for_pid_exit "${APP_PID}" 50 || ok=false
  fi
  if pid_is_alive "${HELPER_PID}"; then
    if target_points_to_run_base; then
      ok=false
    else
      kill -TERM "${HELPER_PID}" 2>/dev/null || true
      wait_for_pid_exit "${HELPER_PID}" 80 || {
        kill -KILL "${HELPER_PID}" 2>/dev/null || true
        wait_for_pid_exit "${HELPER_PID}" 30 || ok=false
      }
    fi
  fi
  if pid_is_alive "${BLOCKER_PID}"; then
    kill -TERM "${BLOCKER_PID}" 2>/dev/null || true
    wait_for_pid_exit "${BLOCKER_PID}" 30 || {
      kill -KILL "${BLOCKER_PID}" 2>/dev/null || true
      wait_for_pid_exit "${BLOCKER_PID}" 20 || ok=false
    }
  fi
  [[ -z "${app_to_reap}" ]] || wait "${app_to_reap}" 2>/dev/null || true
  [[ -z "${blocker_to_reap}" ]] || wait "${blocker_to_reap}" 2>/dev/null || true
  APP_PID=""
  HELPER_PID=""
  BLOCKER_PID=""
  runtime_port_is_free || ok=false
  [[ "${ok}" == true ]]
}

run_graceful_quit() {
  local outcome index
  case_begin graceful_quit
  prepare_case graceful_quit || case_fail graceful_quit_setup_failed
  launch_managed_case || case_fail "${FAILURE_CODE}"
  "${GRACEFUL_CONTROLLER}" "${APP_PID}" >"${CASE_LOGS}/graceful-controller.log" 2>&1 \
    || case_fail graceful_quit_request_failed
  wait_for_pid_exit "${APP_PID}" 100 || case_fail graceful_quit_app_survived
  for ((index = 0; index < 120; index++)); do
    if outcome="$(safe_outcome)"; then break; fi
    sleep 0.1
  done
  [[ -n "${outcome:-}" ]] || case_fail graceful_quit_unsafe
  stop_case_processes || case_fail graceful_quit_cleanup_failed
  case_pass product_lifecycle "${outcome}"
}

run_app_signal_case() {
  local name="$1" signal="$2" outcome index
  case_begin "${name}"
  prepare_case "${name}" || case_fail "${name}_setup_failed"
  launch_managed_case || case_fail "${name}_launch_failed"
  kill -"${signal}" "${APP_PID}" || case_fail "${name}_signal_failed"
  wait_for_pid_exit "${APP_PID}" 100 || case_fail "${name}_app_survived"
  for ((index = 0; index < 120; index++)); do
    if outcome="$(safe_outcome)"; then break; fi
    sleep 0.1
  done
  [[ -n "${outcome:-}" ]] || case_fail "${name}_unsafe"
  stop_case_processes || case_fail "${name}_cleanup_failed"
  case_pass product_lifecycle "${outcome}"
}

run_app_sigterm() {
  run_app_signal_case app_sigterm TERM
}

run_app_sigkill() {
  run_app_signal_case app_sigkill KILL
}

run_helper_signal_case() {
  local name="$1" signal="$2" old_helper new_helper outcome
  case_begin "${name}"
  prepare_case "${name}" || case_fail "${name}_setup_failed"
  launch_managed_case || case_fail "${name}_launch_failed"
  old_helper="${HELPER_PID}"
  kill -"${signal}" "${old_helper}" || case_fail "${name}_signal_failed"
  wait_for_pid_exit "${old_helper}" 100 || case_fail "${name}_helper_survived"
  wait_for_expected_listener || case_fail "${name}_listener_not_recovered"
  new_helper="$(listener_pid)" || case_fail "${name}_listener_ambiguous"
  [[ "${new_helper}" != "${old_helper}" ]] || case_fail "${name}_pid_not_replaced"
  HELPER_PID="${new_helper}"
  verify_app_helper_ownership || case_fail "${name}_ownership_failed"
  outcome="$(safe_outcome)" || case_fail "${name}_unsafe"
  stop_case_processes || case_fail "${name}_cleanup_failed"
  case_pass product_lifecycle "${outcome}"
}

run_helper_sigterm() {
  run_helper_signal_case helper_sigterm TERM
}

run_helper_sigkill() {
  run_helper_signal_case helper_sigkill KILL
}

start_port_blocker() {
  env -i PATH="/usr/bin:/bin:/usr/sbin:/sbin" /usr/bin/python3 - "${RUNTIME_PORT}" \
    >"${CASE_LOGS}/blocker.stdout" 2>"${CASE_LOGS}/blocker.stderr" <<'PY' &
import socket
import sys

server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
server.bind(("127.0.0.1", int(sys.argv[1])))
server.listen()
while True:
    connection, _ = server.accept()
    connection.close()
PY
  BLOCKER_PID=$!
  OWNED_BLOCKER_PIDS+=("${BLOCKER_PID}")
  local index owner
  for ((index = 0; index < 50; index++)); do
    owner="$(listener_pid 2>/dev/null || true)"
    [[ "${owner}" == "${BLOCKER_PID}" ]] && return 0
    sleep 0.1
  done
  return 1
}

run_helper_startup_fail() {
  local index outcome status
  case_begin helper_startup_fail
  prepare_case helper_startup_fail || case_fail helper_startup_fail_setup_failed
  enable_route || case_fail helper_startup_fail_enable_failed
  start_port_blocker || case_fail helper_startup_fail_blocker_failed
  launch_source_app || case_fail helper_startup_fail_app_failed
  for ((index = 0; index < 120; index++)); do
    status="$("${BUILT_HELPER}" codex-config-status -target "${CURRENT_TARGET}" -state "${CURRENT_STATE}" 2>/dev/null || true)"
    [[ "${status}" == "disabled" ]] && break
    sleep 0.1
  done
  [[ "${status:-}" == "disabled" ]] || case_fail helper_startup_fail_route_retained
  [[ -z "$(pgrep -P "${APP_PID}" -f "${WORK_ROOT}/layout/app/gateway/bin/relay" 2>/dev/null || true)" ]] || case_fail helper_startup_fail_child_survived
  outcome="$(safe_outcome)" || case_fail helper_startup_fail_unsafe
  stop_case_processes || case_fail helper_startup_fail_cleanup_failed
  case_pass product_lifecycle "${outcome}"
}

run_config_drift() {
  local drift_catalog outcome index
  case_begin config_drift
  prepare_case config_drift || case_fail config_drift_setup_failed
  launch_managed_case || case_fail config_drift_launch_failed
  drift_catalog="${CASE_HOME}/Library/Application Support/RelayKit/drifted-catalog.json"
  printf 'model = "fixture-model"\nopenai_base_url = "%s"\nmodel_catalog_json = "%s"\n' \
    "${RUN_BASE_URL}" "${drift_catalog}" >"${CURRENT_TARGET}"
  chmod 600 "${CURRENT_TARGET}"
  [[ "$("${BUILT_HELPER}" codex-config-status -target "${CURRENT_TARGET}" -state "${CURRENT_STATE}" 2>/dev/null)" == "drifted" ]] \
    || case_fail config_drift_not_detected
  target_points_to_run_base || case_fail config_drift_base_url_changed
  kill -KILL "${APP_PID}" || case_fail config_drift_signal_failed
  wait_for_pid_exit "${APP_PID}" 100 || case_fail config_drift_app_survived
  for ((index = 0; index < 120; index++)); do
    if outcome="$(safe_outcome)"; then break; fi
    sleep 0.1
  done
  [[ -n "${outcome:-}" ]] || case_fail config_drift_unsafe
  grep -Fq "model_catalog_json = \"${drift_catalog}\"" "${CURRENT_TARGET}" || case_fail config_drift_catalog_not_preserved
  stop_case_processes || case_fail config_drift_cleanup_failed
  case_pass product_lifecycle "${outcome}"
}

run_restore_failure() {
  local outcome index retained_pid
  case_begin restore_failure
  prepare_case restore_failure || case_fail restore_failure_setup_failed
  launch_managed_case || case_fail restore_failure_launch_failed
  retained_pid="${HELPER_PID}"
  chmod 500 "${CURRENT_CODEX_DIR}" || case_fail restore_failure_injection_failed
  if disable_route; then
    case_fail restore_failure_injection_ineffective
  fi
  RESTORE_INJECTION_EFFECTIVE=true
  target_points_to_run_base || case_fail restore_failure_injection_removed_route
  kill -KILL "${APP_PID}" || case_fail restore_failure_signal_failed
  wait_for_pid_exit "${APP_PID}" 100 || case_fail restore_failure_app_survived
  for ((index = 0; index < 120; index++)); do
    if expected_listener_is_healthy && target_points_to_run_base; then break; fi
    sleep 0.1
  done
  capture_restore_failure_diagnostics
  [[ "$(listener_pid 2>/dev/null || true)" == "${retained_pid}" ]] || case_fail restore_failure_listener_not_retained
  outcome="$(safe_outcome)" || case_fail restore_failure_unsafe
  [[ "${outcome}" == "healthy_expected_listener" ]] || case_fail restore_failure_route_not_protected
  [[ "${RESTORE_RECOVERY_DECISION}" == "retain_listener" ]] || case_fail restore_failure_decision_not_observed
  chmod 700 "${CURRENT_CODEX_DIR}" || case_fail restore_failure_permission_cleanup_failed
  stop_case_processes || case_fail restore_failure_cleanup_failed
  case_pass product_lifecycle "${outcome}"
}

write_evidence() {
  local cases_json='[]' index temp_evidence personal_home_pattern
  mkdir -p "${EVIDENCE_DIR}"
  for index in "${!CASE_NAMES[@]}"; do
    cases_json="$(jq -c \
      --arg name "${CASE_NAMES[$index]}" \
      --arg status "${CASE_STATUSES[$index]}" \
      --arg scope "${CASE_SCOPES[$index]}" \
      --arg outcome "${CASE_OUTCOMES[$index]}" \
      '. + [{name:$name,status:$status,scope:$scope,safe_outcome:$outcome}]' <<<"${cases_json}")"
  done
  temp_evidence="$(mktemp "${EVIDENCE_DIR}/.evidence.XXXXXX")"
  jq -n \
    --arg status "${OVERALL_STATUS}" \
    --arg source_sha "${SOURCE_SHA}" \
    --arg harness_sha "${HARNESS_SHA}" \
    --arg harness_test_sha "${HARNESS_TEST_SHA}" \
    --arg failure "${FAILURE_CODE}" \
    --arg failure_phase "${FAILURE_PHASE}" \
    --argjson random_port "${RUNTIME_PORT:-0}" \
    --argjson cases "${cases_json}" \
    --argjson restore_injection_effective "${RESTORE_INJECTION_EFFECTIVE}" \
    --argjson restore_diagnostics_captured "${RESTORE_DIAGNOSTICS_CAPTURED}" \
    --argjson restore_config_points "${RESTORE_CONFIG_POINTS_TO_RUN_BASE}" \
    --arg restore_recovery_decision "${RESTORE_RECOVERY_DECISION}" \
    --argjson restore_helper_alive "${RESTORE_HELPER_ALIVE}" \
    --argjson restore_listener_exists "${RESTORE_LISTENER_EXISTS}" \
    --arg restore_helper_exit_status "${RESTORE_HELPER_EXIT_STATUS}" \
    --arg restore_helper_exit_signal "${RESTORE_HELPER_EXIT_SIGNAL}" \
    --arg gateway_stdout_sink "${GATEWAY_STDOUT_SINK}" \
    --arg gateway_stderr_sink "${GATEWAY_STDERR_SINK}" \
    --argjson config_unchanged "${CONFIG_UNCHANGED}" \
    --argjson auth_unchanged "${AUTH_UNCHANGED}" \
    --argjson launch_agents_unchanged "${LAUNCH_AGENTS_UNCHANGED}" \
    --argjson port_19777_unchanged "${PORT_19777_UNCHANGED}" \
    --argjson port_18787_unchanged "${PORT_18787_UNCHANGED}" \
    --argjson app_processes_stopped "${CLEANUP_APP_PROCESSES}" \
    --argjson helper_processes_stopped "${CLEANUP_HELPER_PROCESSES}" \
    --argjson runtime_port_released "${CLEANUP_RUNTIME_PORT}" \
    --argjson temp_removed "${CLEANUP_TEMP}" \
    '{
      schema_version: 2,
      proof: "runtime_safety_fault_injection",
      status: $status,
      source_sha: $source_sha,
      harness_sha: $harness_sha,
      harness_test_sha: $harness_test_sha,
      random_port: $random_port,
      failure: $failure,
      failure_phase: $failure_phase,
      cases: $cases,
      restore_failure_diagnostics: {
        injection_effective: $restore_injection_effective,
        captured_before_cleanup: $restore_diagnostics_captured,
        config_points_to_run_base: $restore_config_points,
        recovery_decision: $restore_recovery_decision,
        helper_alive: $restore_helper_alive,
        listener_exists: $restore_listener_exists,
        helper_exit_status: $restore_helper_exit_status,
        helper_exit_signal: $restore_helper_exit_signal,
        stdout_sink: $gateway_stdout_sink,
        stderr_sink: $gateway_stderr_sink
      },
      global_guards: {
        isolated_home: true,
        isolated_codex_home: true,
        config_unchanged: $config_unchanged,
        auth_unchanged: $auth_unchanged,
        launch_agents_unchanged: $launch_agents_unchanged
      },
      installed_runtime_unchanged: {
        port_19777: $port_19777_unchanged,
        port_18787: $port_18787_unchanged
      },
      cleanup: {
        app_processes_stopped: $app_processes_stopped,
        helper_processes_stopped: $helper_processes_stopped,
        random_port_released: $runtime_port_released,
        temp_removed: $temp_removed
      }
    }' >"${temp_evidence}"
  personal_home_pattern="/""Users/"
  if grep -Eq "${personal_home_pattern}|Authorization|Bearer |https?://|request_body|response_body|private_url|secret" "${temp_evidence}"; then
    rm -f "${temp_evidence}"
    return 1
  fi
  chmod 600 "${temp_evidence}"
  mv "${temp_evidence}" "${EVIDENCE_PATH}"
}

cleanup() {
  local incoming_status=$?
  local final_status="${incoming_status}" cleanup_ok=true processes_clean=true pid
  [[ "${FINALIZED}" == false ]] || exit "${incoming_status}"
  FINALIZED=true
  trap - EXIT INT TERM HUP
  set +e
  if ((CURRENT_CASE_INDEX == 7)) && [[ "${RESTORE_DIAGNOSTICS_CAPTURED}" != true ]]; then
    capture_restore_failure_diagnostics || true
  fi
  if ((CURRENT_CASE_INDEX >= 0)) && [[ "${CASE_STATUSES[$CURRENT_CASE_INDEX]}" == "running" ]]; then
    CASE_STATUSES[$CURRENT_CASE_INDEX]=failed
    CASE_OUTCOMES[$CURRENT_CASE_INDEX]=unsafe
  fi
  stop_case_processes || processes_clean=false
  CLEANUP_APP_PROCESSES=true
  for pid in "${OWNED_APP_PIDS[@]-}"; do
    pid_is_alive "${pid}" && CLEANUP_APP_PROCESSES=false
  done
  CLEANUP_HELPER_PROCESSES=true
  for pid in "${OWNED_HELPER_PIDS[@]-}"; do
    pid_is_alive "${pid}" && CLEANUP_HELPER_PROCESSES=false
  done
  for pid in "${OWNED_BLOCKER_PIDS[@]-}"; do
    pid_is_alive "${pid}" && processes_clean=false
  done
  [[ "${processes_clean}" == true ]] || cleanup_ok=false
  runtime_port_is_free && CLEANUP_RUNTIME_PORT=true
  if [[ -n "${WORK_ROOT}" ]]; then
    case "${WORK_ROOT}" in
      /tmp/relaykit-runtime-safety.*|/private/tmp/relaykit-runtime-safety.*) rm -rf "${WORK_ROOT}" ;;
      *) cleanup_ok=false ;;
    esac
    [[ ! -e "${WORK_ROOT}" ]] && CLEANUP_TEMP=true
  fi
  capture_global_after || cleanup_ok=false
  if [[ "${CONFIG_UNCHANGED}" != true || "${AUTH_UNCHANGED}" != true || "${LAUNCH_AGENTS_UNCHANGED}" != true ||
        "${PORT_19777_UNCHANGED}" != true || "${PORT_18787_UNCHANGED}" != true ]]; then
    cleanup_ok=false
    FAILURE_CODE=global_or_installed_runtime_changed
    FAILURE_PHASE=global_guard_verification
  fi
  if [[ "${CLEANUP_APP_PROCESSES}" != true || "${CLEANUP_HELPER_PROCESSES}" != true ||
        "${CLEANUP_RUNTIME_PORT}" != true || "${CLEANUP_TEMP}" != true ]]; then
    cleanup_ok=false
    FAILURE_CODE=cleanup_failed
    FAILURE_PHASE=cleanup
  fi
  if [[ "${cleanup_ok}" == true && "${incoming_status}" -eq 0 && "${OVERALL_STATUS}" == "passed" ]]; then
    final_status=0
  else
    OVERALL_STATUS=failed
    final_status=1
  fi
  write_evidence || final_status=1
  if [[ "${final_status}" -eq 0 ]]; then
    printf '%s\n' 'Runtime safety fault-injection PASS: dist/runtime-safety/evidence.json'
  else
    printf 'Runtime safety fault-injection FAIL: %s; evidence: dist/runtime-safety/evidence.json\n' "${FAILURE_CODE}" >&2
  fi
  exit "${final_status}"
}

on_signal() {
  FAILURE_CODE=interrupted
  exit "$1"
}

trap cleanup EXIT
trap 'on_signal 130' INT
trap 'on_signal 143' TERM
trap 'on_signal 129' HUP

SOURCE_SHA="$(git -C "${ROOT}" rev-parse HEAD 2>/dev/null)" || {
  FAILURE_CODE=source_sha_unavailable
  exit 1
}
HARNESS_SHA="$(shasum -a 256 "${BASH_SOURCE[0]}" | awk '{print $1}')" || {
  FAILURE_CODE=harness_sha_unavailable
  exit 1
}
HARNESS_TEST_SHA="$(shasum -a 256 "${ROOT}/scripts/runtime-safety-fault-injection-test.sh" | awk '{print $1}')" || {
  FAILURE_CODE=harness_test_sha_unavailable
  exit 1
}
capture_gateway_sink_contract || {
  FAILURE_CODE=gateway_sink_contract_invalid
  exit 1
}
[[ "${SOURCE_SHA}" =~ ^[0-9a-f]{40}$ ]] || {
  FAILURE_CODE=source_sha_invalid
  exit 1
}
select_random_port || {
  FAILURE_CODE=random_port_unavailable
  exit 1
}
capture_global_before || {
  FAILURE_CODE=global_guard_capture_failed
  exit 1
}
WORK_ROOT="$(mktemp -d "/tmp/relaykit-runtime-safety.XXXXXX")"
chmod 700 "${WORK_ROOT}"
build_current_products || {
  FAILURE_CODE=current_source_build_failed
  exit 1
}
prepare_layout || {
  FAILURE_CODE=isolated_layout_failed
  exit 1
}

run_graceful_quit
run_app_sigterm
run_app_sigkill
run_helper_sigterm
run_helper_sigkill
run_helper_startup_fail
run_config_drift
run_restore_failure

OVERALL_STATUS=passed
FAILURE_CODE=none
FAILURE_PHASE=complete
