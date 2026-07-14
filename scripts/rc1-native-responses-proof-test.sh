#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${ROOT}/scripts/rc1-native-responses-proof.sh"
FIXTURE="${ROOT}/scripts/rc1-native-responses-proof-fixture.py"
MANUAL_PROOF="${ROOT}/scripts/codex-desktop-manual-proof.sh"
MANIFEST="${ROOT}/scripts/rc1-native-responses-manifest.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/relaykit-window-selector-test.XXXXXX")"

cleanup() {
  rm -rf "${TMP}"
}
trap cleanup EXIT INT TERM HUP

fail() {
  printf 'RC1 native Responses proof contract failed: %s\n' "$*" >&2
  exit 1
}

[[ -x "${SCRIPT}" ]] || fail "proof script is missing"
[[ -f "${FIXTURE}" ]] || fail "standalone loopback fixture is missing"
[[ -x "${MANIFEST}" ]] || fail "phase-b manifest builder is missing"
bash -n "${SCRIPT}"

run_selected_case() {
  local name="$1"
  local pid="$2"
  local metadata="${TMP}/${name}-metadata.json"
  local identity="${TMP}/${name}-identity.json"
  local diagnostic="${TMP}/${name}-diagnostic.json"
  cat >"${metadata}"
  "${SCRIPT}" --select-window-identity "${pid}" "${identity}" "${diagnostic}" "${metadata}" ||
    fail "${name} selector unexpectedly failed"
  [[ "$(stat -f '%Lp' "${identity}")" == "600" ]] || fail "${name} identity permissions are not 0600"
  [[ "$(stat -f '%Lp' "${diagnostic}")" == "600" ]] || fail "${name} diagnostic permissions are not 0600"
  jq -e '
    (keys | sort) == ["captured_at","height","pid","width","window_id"] and
    (.captured_at | type == "string" and length > 0)
  ' "${identity}" >/dev/null || fail "${name} identity schema is invalid"
  jq -e '
    (keys | sort) == ["candidates","captured_at","eligible_count","largest_candidate_count","owner_window_count","pid","selected_window_id","status"] and
    .status == "selected" and
    (.selected_window_id | type == "number") and
    (.candidates | all(.[];
      (keys | sort) == ["area","eligible","height","layer","width","window_id"]))
  ' "${diagnostic}" >/dev/null || fail "${name} selected diagnostic schema is invalid"
}

run_failed_case() {
  local name="$1"
  local pid="$2"
  local expected_status="$3"
  local metadata="${TMP}/${name}-metadata.json"
  local identity="${TMP}/${name}-identity.json"
  local diagnostic="${TMP}/${name}-diagnostic.json"
  cat >"${metadata}"
  printf '%s\n' stale >"${identity}"
  if "${SCRIPT}" --select-window-identity "${pid}" "${identity}" "${diagnostic}" "${metadata}"; then
    fail "${name} selector unexpectedly succeeded"
  fi
  [[ ! -e "${identity}" ]] || fail "${name} failure left an identity file"
  [[ "$(stat -f '%Lp' "${diagnostic}")" == "600" ]] || fail "${name} diagnostic permissions are not 0600"
  jq -e --arg status "${expected_status}" '
    (keys | sort) == ["candidates","captured_at","eligible_count","largest_candidate_count","owner_window_count","pid","status"] and
    .status == $status and
    (has("selected_window_id") | not) and
    (.candidates | all(.[];
      (keys | sort) == ["area","eligible","height","layer","width","window_id"]))
  ' "${diagnostic}" >/dev/null || fail "${name} failure diagnostic schema is invalid"
}

run_selected_case nonzero-layer 4101 <<'JSON'
{
  "app_valid": true,
  "windows": [
    {"owner_pid":4101,"window_id":101,"layer":7,"width":640,"height":480,"bounds_valid":true}
  ]
}
JSON
jq -e '
  .pid == 4101 and .window_id == 101 and .width == 640 and .height == 480
' "${TMP}/nonzero-layer-identity.json" >/dev/null || fail "nonzero-layer window was not selected"
jq -e '
  .pid == 4101 and .owner_window_count == 1 and .eligible_count == 1 and
  .largest_candidate_count == 1 and .selected_window_id == 101 and
  .candidates == [{"window_id":101,"layer":7,"width":640,"height":480,"area":307200,"eligible":true}]
' "${TMP}/nonzero-layer-diagnostic.json" >/dev/null || fail "nonzero-layer diagnostic is incorrect"

run_selected_case unique-largest 4102 <<'JSON'
{
  "app_valid": true,
  "windows": [
    {"owner_pid":4102,"window_id":201,"layer":0,"width":400,"height":400,"bounds_valid":true},
    {"owner_pid":4102,"window_id":202,"layer":3,"width":800,"height":500,"bounds_valid":true}
  ]
}
JSON
jq -e '
  .window_id == 202 and .width == 800 and .height == 500
' "${TMP}/unique-largest-identity.json" >/dev/null || fail "unique largest window was not selected"
jq -e '
  .owner_window_count == 2 and .eligible_count == 2 and .largest_candidate_count == 1 and
  .selected_window_id == 202 and
  ([.candidates[] | [.window_id,.width,.height,.area,.eligible]] ==
    [[201,400,400,160000,true],[202,800,500,400000,true]])
' "${TMP}/unique-largest-diagnostic.json" >/dev/null || fail "unique-largest diagnostic counts or dimensions are incorrect"

run_selected_case foreign-larger 4103 <<'JSON'
{
  "app_valid": true,
  "windows": [
    {"owner_pid":9999,"window_id":301,"layer":0,"width":1400,"height":1000,"bounds_valid":true},
    {"owner_pid":4103,"window_id":302,"layer":5,"width":500,"height":500,"bounds_valid":true}
  ]
}
JSON
jq -e '
  .selected_window_id == 302 and .owner_window_count == 1 and .eligible_count == 1 and
  .largest_candidate_count == 1 and (.candidates | map(.window_id)) == [302]
' "${TMP}/foreign-larger-diagnostic.json" >/dev/null || fail "foreign larger window affected exact-PID selection"

run_failed_case none-eligible 4104 no_eligible_window <<'JSON'
{
  "app_valid": true,
  "windows": [
    {"owner_pid":4104,"window_id":401,"layer":2,"width":399,"height":900,"bounds_valid":true},
    {"owner_pid":4104,"window_id":402,"layer":4,"width":800,"height":399,"bounds_valid":true}
  ]
}
JSON
jq -e '
  .pid == 4104 and .owner_window_count == 2 and .eligible_count == 0 and
  .largest_candidate_count == 0 and
  ([.candidates[] | [.window_id,.width,.height,.eligible]] ==
    [[401,399,900,false],[402,800,399,false]])
' "${TMP}/none-eligible-diagnostic.json" >/dev/null || fail "no-eligible diagnostic counts or dimensions are incorrect"

run_failed_case tied-largest 4105 ambiguous_largest_window <<'JSON'
{
  "app_valid": true,
  "windows": [
    {"owner_pid":4105,"window_id":501,"layer":1,"width":600,"height":500,"bounds_valid":true},
    {"owner_pid":4105,"window_id":502,"layer":9,"width":500,"height":600,"bounds_valid":true}
  ]
}
JSON
jq -e '
  .pid == 4105 and .owner_window_count == 2 and .eligible_count == 2 and
  .largest_candidate_count == 2 and
  ([.candidates[] | [.window_id,.area,.eligible]] == [[501,300000,true],[502,300000,true]])
' "${TMP}/tied-largest-diagnostic.json" >/dev/null || fail "ambiguous-largest diagnostic is incorrect"

run_failed_case app-invalid 4106 app_invalid <<'JSON'
{
  "app_valid": false,
  "windows": [
    {"owner_pid":4106,"window_id":601,"layer":0,"width":900,"height":700,"bounds_valid":true}
  ]
}
JSON
jq -e '
  .pid == 4106 and .owner_window_count == 0 and .eligible_count == 0 and
  .largest_candidate_count == 0 and .candidates == []
' "${TMP}/app-invalid-diagnostic.json" >/dev/null || fail "app-invalid diagnostic is incorrect"

if rg -n 'kCGWindowLayer[^\n]*==[[:space:]]*0|candidates\.count[[:space:]]*==[[:space:]]*1' "${SCRIPT}" >/dev/null; then
  fail "legacy layer-zero or single-candidate selector remains"
fi

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
