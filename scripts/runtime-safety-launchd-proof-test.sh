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
