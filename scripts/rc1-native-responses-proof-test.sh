#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${ROOT}/scripts/rc1-native-responses-proof.sh"
FIXTURE="${ROOT}/scripts/rc1-native-responses-proof-fixture.py"
MANUAL_PROOF="${ROOT}/scripts/codex-desktop-manual-proof.sh"
MANIFEST="${ROOT}/scripts/rc1-native-responses-manifest.sh"

fail() {
  printf 'RC1 native Responses proof contract failed: %s\n' "$*" >&2
  exit 1
}

[[ -x "${SCRIPT}" ]] || fail "proof script is missing"
[[ -f "${FIXTURE}" ]] || fail "standalone loopback fixture is missing"
[[ -x "${MANIFEST}" ]] || fail "phase-b manifest builder is missing"
bash -n "${SCRIPT}"

contract="$(${SCRIPT} --print-contract)"
jq -e '
  .proof == "rc1_native_responses_chain" and
  .app_first == true and
  .ordinary_extracted_app == true and
  .provider_destination_initially_empty == true and
  .provider_created_through_exact_ax == true and
  .provider_protocol == "openai_responses" and
  .credential_storage == "keychain_reference_only" and
  .relaunch_restoration_required == true and
  .gateway_started_through_ui == true and
  .desktop_profile == "rc1_native_responses_three_stage" and
  .desktop_stage_count == 3 and
  .desktop_websocket_to_gateway_required == true and
  .gateway_sse_to_fixture_required == true and
  .shared_18787_mutation == false and
  .global_codex_mutation == false and
  .launch_agent_mutation == false and
  .real_provider_request == false and
  .evidence_contains_request_or_response_body == false
' <<<"${contract}" >/dev/null || fail "public proof contract is invalid"

grep -Fq '"providers": []' "${SCRIPT}" || fail "proof must begin from an empty isolated provider destination"
grep -Fq 'relaykit-provider-configure' "${SCRIPT}" || fail "proof must create the provider through the exact AX driver"
grep -Fq 'relaykit-provider-verify' "${SCRIPT}" || fail "proof must verify restored UI values after relaunch"
grep -Fq 'relaykit-gateway-start' "${SCRIPT}" || fail "proof must start the App-owned gateway through exact AX"
grep -Fq 'rc1-native-responses-three-stage' "${SCRIPT}" || fail "proof must delegate Desktop traffic to the dedicated three-stage harness"
grep -Fq 'rc1-native-responses-proof-fixture.py' "${SCRIPT}" || fail "proof must use the standalone fixture"
grep -Fq 'rc1-native-responses-manifest.sh' "${SCRIPT}" || fail "proof must derive phase-b from the dedicated manifest"
grep -Fq 'predicate_ledger' "${SCRIPT}" || fail "proof evidence must expose named predicates"
grep -Fq 'failed_events' "${SCRIPT}" || fail "proof evidence must expose failed events"

if rg -n 'credential_ref[^\n]*key_file|kind[^\n]*key_file|credential_file=' "${SCRIPT}" >/dev/null; then
  fail "proof must not inject a key-file credential"
fi
if rg -n -- '--ui-smoke-provider-config[^\n]*(provider_config|providers\.json)' "${SCRIPT}" >/dev/null &&
   rg -n 'jq -n.*providers:\[\{' "${SCRIPT}" >/dev/null; then
  fail "proof must not inject a completed provider object"
fi
if rg -n 'curl .*19777/v1/responses|curl .*--data.*v1/responses' "${SCRIPT}" >/dev/null; then
  fail "curl-only traffic must not be accepted as the Desktop chain proof"
fi
if rg -n 'stale|observation_failed' "${SCRIPT}" | rg -n 'passed|verified|relabel' >/dev/null; then
  fail "proof must not relabel stale or failed evidence"
fi
if rg -n 'python3 - .*<<' "${SCRIPT}" >/dev/null; then
  fail "the loopback provider fixture must not remain embedded in the shell harness"
fi

grep -Fq 'rc1-native-responses-three-stage)' "${MANUAL_PROOF}" ||
  fail "manual proof is missing the dedicated three-stage entry"

printf '%s\n' 'RelayKit RC1 native Responses proof contract tests passed'
