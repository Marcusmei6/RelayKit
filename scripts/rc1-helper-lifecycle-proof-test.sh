#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${ROOT}/scripts/rc1-helper-lifecycle-proof.sh"

fail() {
  printf 'RC1 helper lifecycle proof contract failed: %s\n' "$*" >&2
  exit 1
}

[[ -x "${SCRIPT}" ]] || fail "proof script is missing"
bash -n "${SCRIPT}"
contract="$(${SCRIPT} --print-contract)"
jq -e '
  .proof == "rc1_helper_lifecycle" and
  .app_first == true and
  .final_bundle == "dist/verify-release/RelayKitApp.app" and
  .parent_loss == "sigkill_app" and
  .helper_exit_required == true and
  .app_listener == "127.0.0.1:19777" and
  .shared_18787_mutation == false and
  .global_codex_mutation == false and
  .launch_agent_mutation == false and
  .provider_request == false
' <<<"${contract}" >/dev/null || fail "public lifecycle contract is invalid"
grep -Fq '/usr/bin/open -n "${APP_BUNDLE}"' "${SCRIPT}" || fail "proof must launch the final App first"
grep -Fq 'press_ax_identifier gateway-start' "${SCRIPT}" || fail "proof must start the helper through the App control"
grep -Fq 'pgrep -P "${APP_PID}"' "${SCRIPT}" || fail "proof must identify the App-owned child helper"
grep -Fq 'kill -KILL "${APP_PID}"' "${SCRIPT}" || fail "proof must bypass graceful App cleanup"
grep -Fq 'helper survived abrupt App parent loss' "${SCRIPT}" || fail "proof must fail when the helper remains alive"
if grep -Eq 'security (find|add|delete)|Library/LaunchAgents|/v1/responses' "${SCRIPT}"; then
  fail "lifecycle proof must not read credentials, touch LaunchAgents, or send a provider request"
fi

printf '%s\n' 'RelayKit RC1 helper lifecycle proof contract tests passed'
