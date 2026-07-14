#!/usr/bin/env bash
set -euo pipefail

fail() {
  printf 'RC1 native Responses manifest failed: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat >&2 <<'EOF'
usage: rc1-native-responses-manifest.sh \
  --native-evidence PATH --desktop-evidence PATH --provider-config PATH \
  --app-zip PATH --screenshot PATH --usage PATH --provider-events PATH \
  --harness PATH --scenario PATH --output PATH
EOF
  exit 2
}

native_evidence=""
desktop_evidence=""
provider_config=""
app_zip=""
screenshot=""
usage_evidence=""
provider_events=""
harness=""
scenario=""
output=""

while (($# > 0)); do
  (($# >= 2)) || usage
  case "$1" in
    --native-evidence) native_evidence="$2" ;;
    --desktop-evidence) desktop_evidence="$2" ;;
    --provider-config) provider_config="$2" ;;
    --app-zip) app_zip="$2" ;;
    --screenshot) screenshot="$2" ;;
    --usage) usage_evidence="$2" ;;
    --provider-events) provider_events="$2" ;;
    --harness) harness="$2" ;;
    --scenario) scenario="$2" ;;
    --output) output="$2" ;;
    *) usage ;;
  esac
  shift 2
done

for name in native_evidence desktop_evidence provider_config app_zip screenshot usage_evidence provider_events harness scenario output; do
  [[ -n "${!name}" ]] || fail "missing --${name//_/-}"
done
[[ "${output}" == /* ]] || fail "output path must be absolute"

require_evidence_file() {
  local path="$1"
  local label="$2"
  [[ "${path}" == /* ]] || fail "${label} path must be absolute"
  [[ -f "${path}" && ! -L "${path}" ]] || fail "${label} must be a current regular file"
}

require_evidence_file "${native_evidence}" "native evidence"
require_evidence_file "${desktop_evidence}" "desktop evidence"
require_evidence_file "${provider_config}" "provider config"
require_evidence_file "${app_zip}" "App zip"
require_evidence_file "${screenshot}" "screenshot"
require_evidence_file "${usage_evidence}" "usage evidence"
require_evidence_file "${provider_events}" "provider events"
require_evidence_file "${harness}" "harness"
require_evidence_file "${scenario}" "scenario"

sha256() {
  /usr/bin/shasum -a 256 "$1" | awk '{print $1}'
}

native_run_id="$(jq -er '.run_id | select(type == "string" and test("^[A-Za-z0-9][A-Za-z0-9._-]{5,127}$"))' "${native_evidence}")" \
  || fail "native evidence has no safe run id"
desktop_run_id="$(jq -er '.run_id | select(type == "string")' "${desktop_evidence}")" \
  || fail "Desktop evidence has no run id"
[[ "${native_run_id}" == "${desktop_run_id}" ]] || fail "evidence run ids differ"

required_native_predicates='[
  "ordinary_app_started",
  "empty_provider_destination",
  "provider_created_via_exact_ax",
  "provider_json_openai_responses",
  "credential_keychain_ref_only",
  "app_relaunched",
  "restored_protocol",
  "restored_url",
  "restored_model",
  "restored_saved_key_state",
  "gateway_started_via_ui"
]'

jq -e --argjson required "${required_native_predicates}" '
  . as $root |
  .status == "passed" and
  .failed_events == [] and
  (.predicate_ledger | type == "object") and
  ((.predicate_ledger | keys | sort) == ($required | sort)) and
  all($required[]; $root.predicate_ledger[.] == true)
' "${native_evidence}" >/dev/null || fail "native predicate ledger is incomplete or false"

jq -e '
  .status == "complete" and
  .profile == "rc1_native_responses_three_stage" and
  .desktop_websocket_to_gateway == true and
  .gateway_sse_to_fixture == true and
  .tool_roundtrip_verified == true and
  .failed_events == [] and
  (.stages | type == "array" and length == 3) and
  ([.stages[].id] | sort) == ["A", "B", "C"] and
  all(.stages[];
    .state == "evidence_verified" and
    .submission_state == "submitted" and
    .submission_count == 1
  )
' "${desktop_evidence}" >/dev/null || fail "Desktop three-stage evidence is incomplete or failed"

jq -e '
  (.providers | type == "array" and length == 1) and
  .providers[0].api_format == "openai_responses" and
  .providers[0].credential_ref.kind == "keychain" and
  (.providers[0].credential_ref.value | type == "string" and startswith("relaykit.provider.")) and
  ([.. | objects | select(has("key_file"))] | length == 0) and
  ([.. | objects | select(has("api_key") or has("token") or has("secret"))] | length == 0)
' "${provider_config}" >/dev/null || fail "provider config is not OpenAI Responses with a Keychain reference only"

app_zip_sha256="$(sha256 "${app_zip}")"
screenshot_sha256="$(sha256 "${screenshot}")"
usage_sha256="$(sha256 "${usage_evidence}")"
provider_events_sha256="$(sha256 "${provider_events}")"
harness_sha256="$(sha256 "${harness}")"
scenario_sha256="$(sha256 "${scenario}")"

[[ "$(jq -er '.app_zip_sha256' "${native_evidence}")" == "${app_zip_sha256}" ]] \
  || fail "App zip hash is stale or relabeled"
[[ "$(jq -er '.screenshot_sha256' "${desktop_evidence}")" == "${screenshot_sha256}" ]] \
  || fail "screenshot hash is stale or relabeled"
[[ "$(jq -er '.usage_sha256' "${desktop_evidence}")" == "${usage_sha256}" ]] \
  || fail "usage hash is stale or relabeled"
[[ "$(jq -er '.provider_events_sha256' "${desktop_evidence}")" == "${provider_events_sha256}" ]] \
  || fail "provider-event hash is stale or relabeled"
[[ "$(jq -er '.harness_sha256' "${desktop_evidence}")" == "${harness_sha256}" ]] \
  || fail "harness hash is stale or relabeled"
[[ "$(jq -er '.scenario_sha256' "${desktop_evidence}")" == "${scenario_sha256}" ]] \
  || fail "scenario hash is stale or relabeled"

mkdir -p "$(dirname "${output}")"
temporary="${output}.tmp.$$"
trap 'rm -f "${temporary}"' EXIT
jq -n \
  --arg run_id "${native_run_id}" \
  --arg native_evidence "${native_evidence}" --arg native_sha "$(sha256 "${native_evidence}")" \
  --arg desktop_evidence "${desktop_evidence}" --arg desktop_sha "$(sha256 "${desktop_evidence}")" \
  --arg provider_config "${provider_config}" --arg provider_sha "$(sha256 "${provider_config}")" \
  --arg app_zip "${app_zip}" --arg app_sha "${app_zip_sha256}" \
  --arg screenshot "${screenshot}" --arg screenshot_sha "${screenshot_sha256}" \
  --arg usage "${usage_evidence}" --arg usage_sha "${usage_sha256}" \
  --arg provider_events "${provider_events}" --arg provider_events_sha "${provider_events_sha256}" \
  --arg harness "${harness}" --arg harness_sha "${harness_sha256}" \
  --arg scenario "${scenario}" --arg scenario_sha "${scenario_sha256}" '
  {
    phase_b: "PASS",
    run_id: $run_id,
    provider_api_format: "openai_responses",
    predicate_ledger: {
      native_predicates_complete: true,
      failed_events_empty: true,
      three_stages_verified: true,
      one_submission_per_stage: true,
      desktop_websocket_to_gateway: true,
      gateway_sse_to_fixture: true,
      tool_roundtrip_verified: true,
      provider_openai_responses: true,
      provider_keychain_ref_only: true,
      run_ids_bound: true,
      immutable_hashes_bound: true
    },
    failed_events: [],
    bindings: [
      {kind:"native_evidence", path:$native_evidence, sha256:$native_sha},
      {kind:"desktop_evidence", path:$desktop_evidence, sha256:$desktop_sha},
      {kind:"provider_config", path:$provider_config, sha256:$provider_sha},
      {kind:"app_zip", path:$app_zip, sha256:$app_sha},
      {kind:"screenshot", path:$screenshot, sha256:$screenshot_sha},
      {kind:"usage", path:$usage, sha256:$usage_sha},
      {kind:"provider_events", path:$provider_events, sha256:$provider_events_sha},
      {kind:"harness", path:$harness, sha256:$harness_sha},
      {kind:"scenario", path:$scenario, sha256:$scenario_sha}
    ]
  }
' >"${temporary}"
chmod 600 "${temporary}"
mv -f "${temporary}" "${output}"
trap - EXIT
printf '%s\n' "${output}"
