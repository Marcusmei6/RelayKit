#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROOF="${ROOT}/scripts/runtime-safety-launchd-proof.sh"

fail() {
  printf 'Launchd runtime-safety contract failed: %s\n' "$*" >&2
  exit 1
}

[[ -x "${PROOF}" ]] || fail "proof script is missing or not executable"
bash -n "${PROOF}"

contract="$("${PROOF}" --print-contract)"
jq -e '
  .proof == "runtime_safety_launchd" and
  .runtime == "isolated_launchd_socket_activation" and
  .cases == ["graceful_release", "app_loss", "unowned_restart", "helper_crash", "app_helper_loss"] and
  .shared_guards == ["global_config", "global_auth", "user_launch_agents", "18787", "19777"] and
  .writes_user_launch_agents == false and
  .fixture_only == true
' <<<"${contract}" >/dev/null || fail "public contract is invalid"

valid_digest="$(printf 'a%.0s' {1..64})"
parsed_digest="$(
  printf 'gateway control status: managed\nruntime_config_sha256=%s\n' "${valid_digest}" |
    "${PROOF}" --parse-runtime-config-sha256
)" || fail "valid runtime config digest was rejected"
[[ "${parsed_digest}" == "${valid_digest}" ]] || fail "parser must return only the runtime config digest"

if printf '%s\n' 'gateway control status: managed' | "${PROOF}" --parse-runtime-config-sha256 >/dev/null 2>&1; then
  fail "missing runtime config digest was accepted"
fi
if printf '%s\n' 'runtime_config_sha256=' | "${PROOF}" --parse-runtime-config-sha256 >/dev/null 2>&1; then
  fail "empty runtime config digest was accepted"
fi
if printf 'runtime_config_sha256=%s\n' "${valid_digest/a/A}" | "${PROOF}" --parse-runtime-config-sha256 >/dev/null 2>&1; then
  fail "uppercase runtime config digest was accepted"
fi
if printf 'runtime_config_sha256=%s\n' "${valid_digest%?}" | "${PROOF}" --parse-runtime-config-sha256 >/dev/null 2>&1; then
  fail "63-character runtime config digest was accepted"
fi
if printf 'runtime_config_sha256=%sa\n' "${valid_digest}" | "${PROOF}" --parse-runtime-config-sha256 >/dev/null 2>&1; then
  fail "65-character runtime config digest was accepted"
fi
if printf 'runtime_config_sha256=g%s\n' "${valid_digest:1}" | "${PROOF}" --parse-runtime-config-sha256 >/dev/null 2>&1; then
  fail "non-hex runtime config digest was accepted"
fi
if printf ' runtime_config_sha256=%s\n' "${valid_digest}" | "${PROOF}" --parse-runtime-config-sha256 >/dev/null 2>&1; then
  fail "whitespace-wrapped runtime config digest was accepted"
fi
if printf 'runtime_config_sha256=%s\nruntime_config_sha256=%s\n' "${valid_digest}" "${valid_digest}" |
  "${PROOF}" --parse-runtime-config-sha256 >/dev/null 2>&1; then
  fail "duplicate runtime config digest was accepted"
fi
if "${PROOF}" --parse-runtime-config-sha256 extra </dev/null >/dev/null 2>&1; then
  fail "parser accepted an unexpected argument"
fi
if "${PROOF}" --unexpected-contract-entry >/dev/null 2>&1; then
  fail "proof accepted an unexpected mode"
fi

status_source="$(sed -n '/^gateway_runtime_config_sha256() {$/,/^}$/p' "${PROOF}")"
[[ "${status_source}" == *'gateway-control -endpoint "http://127.0.0.1:${PORT}" -token-file "${TOKEN_PATH}"'* ]] \
  || fail "runtime digest status must use the isolated endpoint and control token"
[[ "${status_source}" == *'-action status 2>/dev/null'* ]] \
  || fail "runtime digest status must be encrypted and must not emit a log"
[[ "${status_source}" == *'parse_runtime_config_sha256'* ]] \
  || fail "runtime digest status must use the strict parser"
[[ "${status_source}" != *'${CONFIG}'* && "${status_source}" != *'shasum'* ]] \
  || fail "runtime digest status must not read or hash the runtime config"

adopt_source="$(sed -n '/^adopt() {$/,/^}$/p' "${PROOF}")"
[[ "${adopt_source}" == *'for ((index = 0; index < 20; index++))'*'/bin/sleep 0.1'* ]] \
  || fail "adopt must preserve the bounded retry contract"
[[ "${adopt_source}" == *'if digest="$(gateway_runtime_config_sha256)"; then'*'{"version":1,"credentials":{}}'*'-action adopt'* ]] \
  || fail "each adopt retry must obtain and parse fresh status before credential adoption"
[[ "${adopt_source}" == *'-token-file "${TOKEN_PATH}"'*'-parent-pid "${PARENT_PID}"'* ]] \
  || fail "adopt must preserve the control token and parent PID"
[[ "${adopt_source}" == *'-runtime-config-sha256 "${digest}"'* ]] \
  || fail "adopt must bind the fresh runtime config digest"
[[ "${adopt_source}" != *'${CONFIG}'* && "${adopt_source}" != *'shasum'* ]] \
  || fail "adopt must not read or hash the runtime config"

for required in \
  '-launchd-socket-name' \
  'launchctl bootstrap' \
  'launchctl bootout' \
  'ThrottleInterval' \
  'fcntl.flock' \
  'unowned_restart' \
  'RelayKitGateway' \
  'cached_request' \
  'direct_request' \
  'source_commit_sha' \
  'harness_sha256' \
  'safe_outcome' \
  'helper_restarted' \
  'config_restored' \
  'cached_request_after' \
  'new_direct_after_restore' \
  'StandardErrorPath' \
  'classify_launchd_health_failure' \
  'wait_upstream' \
  'launchd_socket_activation_failed' \
  'startup_diagnostic' \
  'redacted_launchd_startup_diagnostic' \
  'helper_processes_stopped' \
  'global_guards_unchanged' \
  'runtime-safety-launchd'; do
  grep -Fq -- "${required}" "${PROOF}" || fail "missing contract: ${required}"
done

if grep -Eq 'Library/LaunchAgents/.+\\.plist|security (find|add|delete)|127\\.0\\.0\\.1:18787|127\\.0\\.0\\.1:19777' "${PROOF}"; then
  fail "proof writes user LaunchAgents, accesses Keychain, or targets protected ports"
fi

printf '%s\n' 'Launchd runtime-safety offline contract tests passed'
