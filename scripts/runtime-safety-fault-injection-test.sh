#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HARNESS="${ROOT}/scripts/runtime-safety-fault-injection.sh"

fail() {
  printf 'Runtime safety fault-injection contract failed: %s\n' "$*" >&2
  exit 1
}

[[ -x "${HARNESS}" ]] || fail "harness is missing or not executable"
bash -n "${HARNESS}"

contract="$(${HARNESS} --print-contract)"
jq -e '
  .proof == "runtime_safety_fault_injection" and
  .source == "current_checkout" and
  .runtime == "isolated_source_app" and
  .network == "loopback_health_only" and
  .protected_ports == [18787, 19777] and
  .global_files == "read_only_non_content_guards" and
  .launch_agents == "read_only_aggregate_guard" and
  .provider_requests == false and
  .gui_automation == false and
  .cases == [
    "graceful_quit",
    "app_sigterm",
    "app_sigkill",
    "helper_sigterm",
    "helper_sigkill",
    "helper_startup_fail",
    "config_drift",
    "restore_failure"
  ] and
  .evidence_fields == [
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
' <<<"${contract}" >/dev/null || fail "public contract or evidence schema is invalid"

require_source() {
  grep -Fq "$1" "${HARNESS}" || fail "missing source contract: $1"
}

require_source 'set -euo pipefail'
require_source 'trap cleanup EXIT'
require_source "trap 'on_signal 130' INT"
require_source "trap 'on_signal 143' TERM"
require_source "trap 'on_signal 129' HUP"
require_source 'mktemp -d'
require_source 'env -i'
require_source 'HOME="${case_home}"'
require_source 'CODEX_HOME="${case_codex_home}"'
require_source 'CFFIXED_USER_HOME="${case_home}"'
require_source 'RELAYKIT_RUNTIME_SAFETY_TEST=1'
require_source 'RELAYKIT_RUNTIME_SAFETY_PORT="${RUNTIME_PORT}"'
require_source 'rev-parse HEAD'
require_source 'source_sha'
require_source 'harness_sha'
require_source 'harness_test_sha'
require_source 'safe_outcome'
require_source 'wait_for_stable_expected_listener'
require_source 'source_app_listener_not_stable'
require_source 'restore_failure_diagnostics'
require_source 'global_guards'
require_source 'installed_runtime_unchanged'
require_source 'cleanup'
require_source 'OWNED_APP_PIDS'
require_source 'OWNED_HELPER_PIDS'
require_source 'OWNED_BLOCKER_PIDS'
require_source '"${go_bin}" build'
require_source '"${swift_bin}" build'
require_source '"${swiftc_bin}" "${controller_source}"'
require_source 'NSRunningApplication(processIdentifier: processIdentifier)'
require_source 'application.terminate()'
require_source 'launch_managed_case || case_fail "${FAILURE_CODE}"'
require_source '"${GRACEFUL_CONTROLLER}" "${APP_PID}"'
require_source 'case_pass product_lifecycle "${outcome}"'
require_source 'LaunchAgents'
require_source '.codex/config.toml'
require_source '.codex/auth.json'

for case_name in graceful_quit app_sigterm app_sigkill helper_sigterm helper_sigkill helper_startup_fail config_drift restore_failure; do
  require_source "run_${case_name}"
done

if grep -Eq '/v1/responses|security (find|add|delete)|launchctl|/usr/bin/open|RELAYKIT_RUNTIME_SAFETY_(HOST|BASE_URL)' "${HARNESS}"; then
  fail "harness contains provider, credential, LaunchAgent, GUI, or host/base-URL override behavior"
fi
if grep -Fq 'graceful_config_path' "${HARNESS}"; then
  fail "graceful quit must exercise the product lifecycle"
fi

[[ "$(${HARNESS} --evaluate-safety false false false)" == "managed_base_url_removed" ]] \
  || fail "restored config must allow the helper to exit"
[[ "$(${HARNESS} --evaluate-safety true true true)" == "healthy_expected_listener" ]] \
  || fail "managed config must require a live expected listener"
if ${HARNESS} --evaluate-safety true false false >/dev/null 2>&1; then
  fail "managed config with a dead helper/listener must be unsafe"
fi

printf '%s\n' 'Runtime safety fault-injection offline contract tests passed'
