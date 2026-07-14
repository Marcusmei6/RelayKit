#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MANIFEST="${ROOT}/scripts/rc1-native-responses-manifest.sh"

fail() {
  printf 'RC1 native Responses manifest contract failed: %s\n' "$*" >&2
  exit 1
}

expect_failure() {
  local message="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    fail "${message}"
  fi
}

[[ -x "${MANIFEST}" ]] || fail "manifest script is missing"
bash -n "${MANIFEST}"

tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/relaykit-responses-manifest-test.XXXXXX")"
trap 'rm -rf "${tmp_dir}"' EXIT
run_id="manifest-run-001"
for file in app.zip screenshot.png usage.json provider-events.jsonl harness.sh scenario.json; do
  printf 'immutable %s\n' "${file}" >"${tmp_dir}/${file}"
done
printf '{"providers":[{"api_format":"openai_responses","credential_ref":{"kind":"keychain","value":"relaykit.provider.fixture"}}]}\n' >"${tmp_dir}/providers.json"
sha() { /usr/bin/shasum -a 256 "$1" | awk '{print $1}'; }

jq -n --arg run_id "${run_id}" \
  --arg app "$(sha "${tmp_dir}/app.zip")" \
  '{status:"passed",run_id:$run_id,predicate_ledger:{ordinary_app_started:true,empty_provider_destination:true,provider_created_via_exact_ax:true,provider_json_openai_responses:true,credential_keychain_ref_only:true,app_relaunched:true,restored_protocol:true,restored_url:true,restored_model:true,restored_saved_key_state:true,gateway_started_via_ui:true},failed_events:[],app_zip_sha256:$app}' >"${tmp_dir}/native.json"
jq -n --arg run_id "${run_id}" \
  --arg harness "$(sha "${tmp_dir}/harness.sh")" \
  --arg scenario "$(sha "${tmp_dir}/scenario.json")" \
  --arg screenshot "$(sha "${tmp_dir}/screenshot.png")" \
  --arg usage "$(sha "${tmp_dir}/usage.json")" \
  --arg events "$(sha "${tmp_dir}/provider-events.jsonl")" \
  '{status:"complete",run_id:$run_id,profile:"rc1_native_responses_three_stage",desktop_websocket_to_gateway:true,gateway_sse_to_fixture:true,tool_roundtrip_verified:true,failed_events:[],harness_sha256:$harness,scenario_sha256:$scenario,screenshot_sha256:$screenshot,usage_sha256:$usage,provider_events_sha256:$events,stages:[
    {id:"A",state:"evidence_verified",submission_state:"submitted",submission_count:1},
    {id:"B",state:"evidence_verified",submission_state:"submitted",submission_count:1},
    {id:"C",state:"evidence_verified",submission_state:"submitted",submission_count:1}
  ]}' >"${tmp_dir}/desktop.json"

args=(
  --native-evidence "${tmp_dir}/native.json"
  --desktop-evidence "${tmp_dir}/desktop.json"
  --provider-config "${tmp_dir}/providers.json"
  --app-zip "${tmp_dir}/app.zip"
  --screenshot "${tmp_dir}/screenshot.png"
  --usage "${tmp_dir}/usage.json"
  --provider-events "${tmp_dir}/provider-events.jsonl"
  --harness "${tmp_dir}/harness.sh"
  --scenario "${tmp_dir}/scenario.json"
  --output "${tmp_dir}/manifest.json"
)
"${MANIFEST}" "${args[@]}"
jq -e --arg run_id "${run_id}" '
  .phase_b == "PASS" and .run_id == $run_id and
  .provider_api_format == "openai_responses" and
  (.predicate_ledger | type == "object" and all(.[]; . == true)) and
  .failed_events == [] and
  (.bindings | all(.sha256 | test("^[0-9a-f]{64}$")))
' "${tmp_dir}/manifest.json" >/dev/null || fail "manifest did not derive a fully bound PASS"

for mutation in missing_predicate failed_event stale_run failed_stage screenshot_relabel wrong_api_format; do
  cp "${tmp_dir}/native.json" "${tmp_dir}/native-bad.json"
  cp "${tmp_dir}/desktop.json" "${tmp_dir}/desktop-bad.json"
  cp "${tmp_dir}/providers.json" "${tmp_dir}/providers-bad.json"
  case "${mutation}" in
    missing_predicate) jq 'del(.predicate_ledger.restored_model)' "${tmp_dir}/native.json" >"${tmp_dir}/native-bad.json" ;;
    failed_event) jq '.failed_events=["observation_failed_3"]' "${tmp_dir}/desktop.json" >"${tmp_dir}/desktop-bad.json" ;;
    stale_run) jq '.run_id="stale-run"' "${tmp_dir}/desktop.json" >"${tmp_dir}/desktop-bad.json" ;;
    failed_stage) jq '.stages[1].state="failed"' "${tmp_dir}/desktop.json" >"${tmp_dir}/desktop-bad.json" ;;
    screenshot_relabel) jq '.screenshot_sha256=("0" * 64)' "${tmp_dir}/desktop.json" >"${tmp_dir}/desktop-bad.json" ;;
    wrong_api_format) jq '.providers[0].api_format="openai_chat"' "${tmp_dir}/providers.json" >"${tmp_dir}/providers-bad.json" ;;
  esac
  bad_args=("${args[@]}")
  bad_args[1]="${tmp_dir}/native-bad.json"
  bad_args[3]="${tmp_dir}/desktop-bad.json"
  bad_args[5]="${tmp_dir}/providers-bad.json"
  expect_failure "manifest accepted ${mutation}" "${MANIFEST}" "${bad_args[@]}"
done

printf '%s\n' 'RelayKit RC1 native Responses manifest tests passed'
