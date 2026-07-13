#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${ROOT}/scripts/rc1-native-responses-proof.sh"

fail() {
  printf 'RC1 native Responses proof contract failed: %s\n' "$*" >&2
  exit 1
}

[[ -x "${SCRIPT}" ]] || fail "proof script is missing"
bash -n "${SCRIPT}"
contract="$(${SCRIPT} --print-contract)"
jq -e '
  .proof == "rc1_native_responses" and
  .app_first == true and
  .final_bundle == "dist/verify-release/RelayKitApp.app" and
  .provider_fixture == "loopback_openai_responses" and
  .app_listener == "127.0.0.1:19777" and
  .shared_18787_mutation == false and
  .global_codex_mutation == false and
  .launch_agent_mutation == false and
  .real_provider_request == false and
  .evidence_contains_request_or_response_body == false
' <<<"${contract}" >/dev/null || fail "public proof contract is invalid"
grep -Fq '/usr/bin/open -n "${APP_BUNDLE}"' "${SCRIPT}" || fail "proof must launch the final App first"
grep -Fq 'press_ax_identifier gateway-start' "${SCRIPT}" || fail "proof must start the helper through the App control"
grep -Fq 'api_format:"openai_responses"' "${SCRIPT}" || fail "proof must configure native Responses"
grep -Fq 'http://127.0.0.1:19777/v1/responses' "${SCRIPT}" || fail "proof must enter through the App-owned gateway"
grep -Fq 'pgrep -P "${APP_PID}"' "${SCRIPT}" || fail "proof must bind the helper to the App process"
if grep -Eq 'security (find|add|delete)|Library/LaunchAgents' "${SCRIPT}"; then
  fail "proof must not read Keychain values or touch LaunchAgents"
fi

printf '%s\n' 'RelayKit RC1 native Responses proof contract tests passed'
