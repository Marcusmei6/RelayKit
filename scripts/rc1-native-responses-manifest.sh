#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  printf 'RC1 native Responses manifest failed: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat >&2 <<'EOF'
usage: rc1-native-responses-manifest.sh \
  --native-evidence PATH --desktop-evidence PATH --stage-ledger PATH \
  --tool-evidence PATH --screenshot-ledger PATH --provider-config PATH \
  --protocol-evidence PATH --guard-evidence PATH --app-zip PATH \
  --extracted-app PATH --usage PATH --provider-events PATH \
  --harness PATH --scenario PATH --output PATH
EOF
  exit 2
}

native_evidence=""
desktop_evidence=""
stage_ledger=""
tool_evidence=""
screenshot_ledger=""
provider_config=""
protocol_evidence=""
guard_evidence=""
app_zip=""
extracted_app=""
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
    --stage-ledger) stage_ledger="$2" ;;
    --tool-evidence) tool_evidence="$2" ;;
    --screenshot-ledger) screenshot_ledger="$2" ;;
    --provider-config) provider_config="$2" ;;
    --protocol-evidence) protocol_evidence="$2" ;;
    --guard-evidence) guard_evidence="$2" ;;
    --app-zip) app_zip="$2" ;;
    --extracted-app) extracted_app="$2" ;;
    --usage) usage_evidence="$2" ;;
    --provider-events) provider_events="$2" ;;
    --harness) harness="$2" ;;
    --scenario) scenario="$2" ;;
    --output) output="$2" ;;
    *) usage ;;
  esac
  shift 2
done

for name in native_evidence desktop_evidence stage_ledger tool_evidence screenshot_ledger \
  provider_config protocol_evidence guard_evidence app_zip extracted_app usage_evidence \
  provider_events harness scenario output; do
  [[ -n "${!name}" ]] || fail "missing --${name//_/-}"
done
[[ "${output}" == /* ]] || fail "output path must be absolute"

require_file() {
  local path="$1" label="$2"
  [[ "${path}" == /* ]] || fail "${label} path must be absolute"
  [[ -f "${path}" && ! -L "${path}" ]] || fail "${label} must be a current regular file"
}

for pair in \
  "${native_evidence}|native evidence" \
  "${desktop_evidence}|Desktop evidence" \
  "${stage_ledger}|Desktop stage ledger" \
  "${tool_evidence}|Desktop tool evidence" \
  "${screenshot_ledger}|screenshot ledger" \
  "${provider_config}|provider config" \
  "${protocol_evidence}|protocol validation evidence" \
  "${guard_evidence}|cleanup/runtime guard evidence" \
  "${app_zip}|App zip" \
  "${usage_evidence}|usage evidence" \
  "${provider_events}|provider events" \
  "${harness}|harness" \
  "${scenario}|scenario"; do
  require_file "${pair%%|*}" "${pair#*|}"
done
[[ "${extracted_app}" == /* && -d "${extracted_app}" && ! -L "${extracted_app}" ]] ||
  fail "extracted App must be a current absolute directory"

sha256() {
  /usr/bin/shasum -a 256 "$1" | awk '{print $1}'
}

bundle_sha256() {
  (
    cd "$1"
    while IFS= read -r -d '' item; do
      local_path="${item#./}"
      mode="$(stat -f '%Lp' "${item}")"
      if [[ -L "${item}" ]]; then
        printf 'symlink\0%s\0%s\0%s\0' "${local_path}" "${mode}" "$(readlink "${item}")"
      elif [[ -f "${item}" ]]; then
        printf 'file\0%s\0%s\0%s\0' "${local_path}" "${mode}" "$(sha256 "${item}")"
      elif [[ -d "${item}" ]]; then
        printf 'directory\0%s\0%s\0' "${local_path}" "${mode}"
      else
        printf 'other\0%s\0%s\0' "${local_path}" "${mode}"
      fi
    done < <(find . -mindepth 1 -print0 | LC_ALL=C sort -z)
  ) | /usr/bin/shasum -a 256 | awk '{print $1}'
}

resolve_screenshot_path() {
  local path="$1"
  if [[ "${path}" == /* ]]; then
    printf '%s\n' "${path}"
  else
    printf '%s/%s\n' "${ROOT}" "${path}"
  fi
}

tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/relaykit-responses-manifest.XXXXXX")"
temporary="${output}.tmp.$$"
trap 'rm -rf "${tmp_dir}"; rm -f "${temporary}"' EXIT

screenshot_bindings="${tmp_dir}/screenshot-bindings.jsonl"
: >"${screenshot_bindings}"
while IFS=$'\t' read -r role ledger_path expected_sha identity_path expected_identity_sha ledger_pid ledger_window_id; do
  resolved="$(resolve_screenshot_path "${ledger_path}")"
  actual_sha=""
  resolved_identity="" actual_identity_sha="" identity_pid="" identity_window_id="" identity_verified=false
  if [[ -f "${resolved}" && ! -L "${resolved}" ]]; then
    actual_sha="$(sha256 "${resolved}")"
  fi
  if [[ "${role}" == ordinary-* ]]; then
    resolved_identity="$(resolve_screenshot_path "${identity_path}")"
    if [[ -f "${resolved_identity}" && ! -L "${resolved_identity}" ]]; then
      actual_identity_sha="$(sha256 "${resolved_identity}")"
      identity_pid="$(jq -er '.pid | select(type == "number" and . > 0)' "${resolved_identity}" 2>/dev/null || true)"
      identity_window_id="$(jq -er '.window_id | select(type == "number" and . > 0)' "${resolved_identity}" 2>/dev/null || true)"
      if [[ "${actual_identity_sha}" == "${expected_identity_sha}" && "${identity_pid}" == "${ledger_pid}" &&
            "${identity_window_id}" == "${ledger_window_id}" ]]; then
        identity_verified=true
      fi
    fi
  fi
  jq -n \
    --arg role "${role}" --arg path "${resolved}" \
    --arg expected_sha256 "${expected_sha}" --arg actual_sha256 "${actual_sha}" \
    --arg identity_path "${resolved_identity}" --arg expected_identity_sha256 "${expected_identity_sha}" \
    --arg actual_identity_sha256 "${actual_identity_sha}" --argjson identity_verified "${identity_verified}" \
    '{kind:"screenshot",role:$role,path:$path,expected_sha256:$expected_sha256,
      sha256:(if $actual_sha256 == "" then null else $actual_sha256 end),
      identity_path:(if $identity_path == "" then null else $identity_path end),
      expected_identity_sha256:(if $expected_identity_sha256 == "" then null else $expected_identity_sha256 end),
      actual_identity_sha256:(if $actual_identity_sha256 == "" then null else $actual_identity_sha256 end),
      identity_verified:$identity_verified}' >>"${screenshot_bindings}"
done < <(jq -r '.[]? | [(.role // ""),(.path // ""),(.sha256 // ""),(.identity_path // ""),
  (.identity_sha256 // ""),((.pid // "") | tostring),((.window_id // "") | tostring)] | @tsv' "${screenshot_ledger}")
screenshot_bindings_json="$(jq -s '.' "${screenshot_bindings}")"

native_sha256="$(sha256 "${native_evidence}")"
desktop_sha256="$(sha256 "${desktop_evidence}")"
stage_sha256="$(sha256 "${stage_ledger}")"
tool_sha256="$(sha256 "${tool_evidence}")"
screenshot_ledger_sha256="$(sha256 "${screenshot_ledger}")"
provider_config_sha256="$(sha256 "${provider_config}")"
protocol_sha256="$(sha256 "${protocol_evidence}")"
protocol_log_path="$(jq -er '.log.path | select(type == "string" and startswith("/"))' "${protocol_evidence}")" ||
  fail "protocol validation log path is invalid"
require_file "${protocol_log_path}" "protocol validation log"
protocol_log_sha256="$(sha256 "${protocol_log_path}")"
guard_sha256="$(sha256 "${guard_evidence}")"
app_zip_sha256="$(sha256 "${app_zip}")"
mkdir -p "${tmp_dir}/package-binding"
/usr/bin/unzip -q "${app_zip}" -d "${tmp_dir}/package-binding" || fail "App zip could not be extracted for manifest binding"
[[ -d "${tmp_dir}/package-binding/RelayKitApp.app" ]] || fail "App zip does not contain RelayKitApp.app"
app_zip_tree_sha256="$(bundle_sha256 "${tmp_dir}/package-binding/RelayKitApp.app")"
extracted_app_sha256="$(bundle_sha256 "${extracted_app}")"
usage_sha256="$(sha256 "${usage_evidence}")"
provider_events_sha256="$(sha256 "${provider_events}")"
harness_sha256="$(sha256 "${harness}")"
scenario_sha256="$(sha256 "${scenario}")"
empty_sha256="$(printf '' | /usr/bin/shasum -a 256 | awk '{print $1}')"

mkdir -p "$(dirname "${output}")"
jq -n \
  --slurpfile native "${native_evidence}" \
  --slurpfile desktop "${desktop_evidence}" \
  --slurpfile stages "${stage_ledger}" \
  --slurpfile tool "${tool_evidence}" \
  --slurpfile screenshots "${screenshot_ledger}" \
  --slurpfile provider "${provider_config}" \
  --slurpfile protocol "${protocol_evidence}" \
  --slurpfile guard "${guard_evidence}" \
  --slurpfile usage "${usage_evidence}" \
  --slurpfile events "${provider_events}" \
  --arg native_evidence "${native_evidence}" --arg native_sha "${native_sha256}" \
  --arg desktop_evidence "${desktop_evidence}" --arg desktop_sha "${desktop_sha256}" \
  --arg stage_ledger "${stage_ledger}" --arg stage_sha "${stage_sha256}" \
  --arg tool_evidence "${tool_evidence}" --arg tool_sha "${tool_sha256}" \
  --arg screenshot_ledger "${screenshot_ledger}" --arg screenshot_ledger_sha "${screenshot_ledger_sha256}" \
  --arg provider_config "${provider_config}" --arg provider_sha "${provider_config_sha256}" \
  --arg protocol_evidence "${protocol_evidence}" --arg protocol_sha "${protocol_sha256}" \
  --arg protocol_log_path "${protocol_log_path}" --arg protocol_log_sha "${protocol_log_sha256}" \
  --arg protocol_server_sha "$(sha256 "${ROOT}/gateway/internal/server/server.go")" \
  --arg protocol_responses_sha "$(sha256 "${ROOT}/gateway/internal/server/openai_responses.go")" \
  --arg protocol_server_test_sha "$(sha256 "${ROOT}/gateway/internal/server/server_test.go")" \
  --arg protocol_provider_test_sha "$(sha256 "${ROOT}/gateway/internal/server/provider_test.go")" \
  --arg protocol_git_head "$(git -C "${ROOT}" rev-parse HEAD)" \
  --arg protocol_git_diff_sha "$(git -C "${ROOT}" diff HEAD --binary | /usr/bin/shasum -a 256 | awk '{print $1}')" \
  --arg guard_evidence "${guard_evidence}" --arg guard_sha "${guard_sha256}" \
  --arg app_zip "${app_zip}" --arg app_zip_sha "${app_zip_sha256}" \
  --arg app_zip_tree_sha "${app_zip_tree_sha256}" \
  --arg extracted_app "${extracted_app}" --arg extracted_app_sha "${extracted_app_sha256}" \
  --arg usage_path "${usage_evidence}" --arg usage_sha "${usage_sha256}" \
  --arg events_path "${provider_events}" --arg events_sha "${provider_events_sha256}" \
  --arg harness "${harness}" --arg harness_sha "${harness_sha256}" \
  --arg scenario "${scenario}" --arg scenario_sha "${scenario_sha256}" \
  --arg empty_sha "${empty_sha256}" \
  --argjson screenshot_bindings "${screenshot_bindings_json}" '
  def passed_check($name):
    any($protocol[0].checks[]?; .name == $name and .status == "passed");
  def stage($id): first($stages[0][]? | select(.id == $id));
  def stage_pass($id; $expect):
    (stage($id)) as $stage |
    ($stage != null and $stage.expect == $expect and $stage.state == "evidence_verified" and
      $stage.submission_state == "submitted" and $stage.submission_count == 1 and
      $stage.error_code == null and $stage.rollout_binding.proof_found == true);
  def shot($role): [$screenshots[0][]? | select(.role == $role and .captured == true and .target_identity_verified == true)];
  def report_ok($report; $command):
    ($report.status == "ok" and $report.code == "ok" and $report.command == $command and
      $report.window_verified == true and ($report.action_count | type) == "number" and $report.action_count > 0);
  def historical_failures:
    [($native[0].failed_events[]?),($desktop[0].failed_events[]?),
      ($stages[0][]?.error_code | select(. != null)),
      ($protocol[0].failed_events[]?),($guard[0].failed_events[]?)] | unique;

  ($native[0].run_id // null) as $run_id |
  ($provider[0].providers[0].models[0].id // null) as $model |
  [$events[] | select(.method == "POST")] as $posts |
  (if ($posts | length) >= 4 then ($posts | length) - 4 else -1 end) as $post_retry_count |
  (shot("rc1-text")) as $plain_shots |
  (shot("rc1-markdown")) as $markdown_shots |
  (shot("rc1-tool")) as $tool_shots |
  ([
    {role:"ordinary-connect-light",appearance:"light",state:"connect"},
    {role:"ordinary-official-collapsed-light",appearance:"light",state:"official-collapsed"},
    {role:"ordinary-official-expanded-light",appearance:"light",state:"official-expanded"},
    {role:"ordinary-official-scrolled-light",appearance:"light",state:"official-scrolled"},
    {role:"ordinary-provider-collapsed-light",appearance:"light",state:"provider-collapsed"},
    {role:"ordinary-provider-expanded-light",appearance:"light",state:"provider-expanded"},
    {role:"ordinary-provider-scrolled-light",appearance:"light",state:"provider-scrolled"},
    {role:"ordinary-connect-dark",appearance:"dark",state:"connect"},
    {role:"ordinary-official-collapsed-dark",appearance:"dark",state:"official-collapsed"},
    {role:"ordinary-official-expanded-dark",appearance:"dark",state:"official-expanded"},
    {role:"ordinary-official-scrolled-dark",appearance:"dark",state:"official-scrolled"},
    {role:"ordinary-provider-collapsed-dark",appearance:"dark",state:"provider-collapsed"},
    {role:"ordinary-provider-expanded-dark",appearance:"dark",state:"provider-expanded"},
    {role:"ordinary-provider-scrolled-dark",appearance:"dark",state:"provider-scrolled"}
  ]) as $ordinary_expected |
  {
    app_ui_protocol_saved:
      ($native[0].schema_version == 2 and
       report_ok($native[0].observations.provider_configure; "relaykit-provider-configure") and
       report_ok($native[0].observations.provider_verify; "relaykit-provider-verify") and
       $provider[0].providers[0].api_format == "openai_responses"),
    keychain_reference_only:
      (($provider[0].providers | type) == "array" and ($provider[0].providers | length) == 1 and
       $provider[0].providers[0].credential_ref.kind == "keychain" and
       ($provider[0].providers[0].credential_ref.value | type) == "string" and
       (($provider[0].providers[0].credential_ref.value // "") | startswith("relaykit.provider.")) and
       ([($provider[0] | .. | objects) | select(has("key_file") or has("api_key") or has("token") or has("secret"))] | length) == 0),
    app_restart_persistence:
      (($native[0].observations.first_window_identity.pid | type) == "number" and
       ($native[0].observations.second_window_identity.pid | type) == "number" and
       $native[0].observations.first_window_identity.pid != $native[0].observations.second_window_identity.pid and
       report_ok($native[0].observations.provider_verify; "relaykit-provider-verify")),
    package_tree_bound: ($app_zip_tree_sha == $extracted_app_sha),
    protocol_evidence_current_source:
      ($protocol[0].producer == "rc1-native-responses-proof" and
       $protocol[0].exit_code == 0 and
       ($protocol[0].command | startswith("go test ./internal/server -run ^(TestNativeOpenAIResponsesNonStreamingPreservesProtocol|")) and
       $protocol[0].git_head == $protocol_git_head and $protocol[0].git_diff_sha256 == $protocol_git_diff_sha and
       $protocol[0].log.path == $protocol_log_path and $protocol[0].log.sha256 == $protocol_log_sha and
       $protocol[0].source_sha256["gateway/internal/server/server.go"] == $protocol_server_sha and
       $protocol[0].source_sha256["gateway/internal/server/openai_responses.go"] == $protocol_responses_sha and
       $protocol[0].source_sha256["gateway/internal/server/server_test.go"] == $protocol_server_test_sha and
       $protocol[0].source_sha256["gateway/internal/server/provider_test.go"] == $protocol_provider_test_sha and
       ([ $protocol[0].checks[] | .name ] | sort) ==
         ["gateway_native_http","gateway_native_sse","request_duplicate_fields_rejected","response_duplicate_fields_rejected"] and
       all($protocol[0].checks[]; .status == "passed")),
    gateway_native_http_verified: passed_check("gateway_native_http"),
    gateway_native_sse_verified:
      (passed_check("gateway_native_sse") and $desktop[0].gateway_sse_to_fixture == true and
       ($posts | length) >= 4 and all($posts[]; (.event_types | index("response.completed")) != null)),
    gateway_native_websocket_verified:
      ($desktop[0].desktop_websocket_to_gateway == true and
       ($usage[0] | type) == "array" and ($usage[0] | length) >= 3 and
       all($usage[0][]; .transport == "responses_websocket")),
    desktop_plain_verified:
      (stage_pass("A"; "plain") and ($plain_shots | length) > 0 and
       any($plain_shots[]; .visual_checks.response_marker_visible == true and .visual_checks.raw_protocol_visible == false)),
    desktop_markdown_verified:
      (stage_pass("B"; "markdown") and ($markdown_shots | length) > 0 and
       any($markdown_shots[]; .visual_checks.heading_visible == true) and
       any($markdown_shots[]; .visual_checks.numbered_items_visible == true) and
       any($markdown_shots[]; .visual_checks.table_headers_visible == true) and
       any($markdown_shots[]; .visual_checks.bash_code_visible == true) and
       any($markdown_shots[]; .visual_checks.bold_conclusion_visible == true) and
       all($markdown_shots[]; .visual_checks.raw_protocol_visible != true)),
    desktop_tool_verified:
      (stage_pass("C"; "tool") and ($tool_shots | length) > 0 and
       any($tool_shots[]; .visual_checks.tool_marker_visible == true and
         .visual_checks.tool_execution_visible == true and .visual_checks.raw_protocol_visible == false) and
       $tool[0].proof_found == true and $tool[0].function_call_found == true and
       ($desktop[0].desktop_window_identity.pid | type) == "number" and $desktop[0].desktop_window_identity.pid > 0 and
       ($desktop[0].desktop_window_identity.window_id | type) == "number" and $desktop[0].desktop_window_identity.window_id > 0 and
       all($screenshots[0][] | select(.role == "rc1-text" or .role == "rc1-markdown" or .role == "rc1-tool");
         (.pid | type) == "number" and .pid > 0 and (.window_id | type) == "number" and .window_id > 0 and
         .pid == $desktop[0].desktop_window_identity.pid and .window_id == $desktop[0].desktop_window_identity.window_id)),
    ordinary_ui_screenshots_verified:
      (([$screenshots[0][] | select(.role | startswith("ordinary-")) |
          {role,appearance,state,captured,target_identity_verified}] | sort_by(.role)) ==
       ($ordinary_expected | map(. + {captured:true,target_identity_verified:true}) | sort_by(.role)) and
       all($screenshots[0][] | select(.role | startswith("ordinary-"));
         (.pid | type) == "number" and .pid > 0 and (.window_id | type) == "number" and .window_id > 0) and
       all($screenshot_bindings[] | select(.role | startswith("ordinary-")); .identity_verified == true) and
       ([$screenshots[0][].role] | sort) ==
       (($ordinary_expected | map(.role)) + ["rc1-text","rc1-markdown","rc1-tool"] | sort)),
    tool_process_exited_zero: ($tool[0].process_exited_zero == true),
    function_call_output_roundtrip:
      ($desktop[0].tool_roundtrip_verified == true and
       $tool[0].function_call_output_found == true and $tool[0].matched_provider_tool_count == 1),
    upstream_path_is_responses:
      (($posts | length) >= 4 and all($posts[]; .path == "/v1/responses")),
    upstream_model_rewrite_verified:
      (($posts | length) >= 4 and all($posts[]; .model_rewrite == true)),
    post_retry_count: $post_retry_count,
    request_duplicate_fields_rejected: passed_check("request_duplicate_fields_rejected"),
    response_duplicate_fields_rejected: passed_check("response_duplicate_fields_rejected"),
    current_run_usage_only:
      (($usage[0] | type) == "array" and ($usage[0] | length) >= 3 and
       all($usage[0][]; .model == $model and .status == "completed" and .http_status == 200) and
       ($events | length) > 0 and all($events[]; .run_id == $run_id)),
    global_config_unchanged:
      ($guard[0].global_config.before_sha256 == $guard[0].global_config.after_sha256 and
       (($guard[0].global_config.after_sha256 // "") | test("^[0-9a-f]{64}$"))),
    global_auth_unchanged:
      ($guard[0].global_auth.before_sha256 == $guard[0].global_auth.after_sha256 and
       (($guard[0].global_auth.after_sha256 // "") | test("^[0-9a-f]{64}$"))),
    shared_18787_unchanged:
      ($guard[0].shared_18787.before_snapshot_sha256 == $guard[0].shared_18787.after_snapshot_sha256 and
       (($guard[0].shared_18787.after_snapshot_sha256 // "") | test("^[0-9a-f]{64}$"))),
    temporary_ports_released:
      (($guard[0].ports | type) == "array" and
       any(($guard[0].ports // [])[]; .kind == "gateway" and .port == 19777 and .after_listener_count == 0) and
       any(($guard[0].ports // [])[]; .kind == "fixture_temp" and (.port | type) == "number" and .after_listener_count == 0) and
       all(($guard[0].ports // [])[]; .after_listener_count == 0)),
    tracked_worktree_clean:
      ($guard[0].tracked_worktree.status_line_count == 0 and
       $guard[0].tracked_worktree.porcelain_sha256 == $empty_sha),
    structured_evidence_pass:
      ($native[0].schema_version == 2 and $protocol[0].schema_version == 1 and $guard[0].schema_version == 1 and
       $run_id != null and $desktop[0].run_id == $run_id and $protocol[0].run_id == $run_id and $guard[0].run_id == $run_id and
       $desktop[0].status == "complete" and $desktop[0].manual_status == "route_complete" and
       $desktop[0].route_proof_status == "complete" and $desktop[0].harness_exit_code == 0 and
       $desktop[0].profile == "rc1_native_responses_three_stage" and
       ($stages[0] | type) == "array" and ($stages[0] | length) == 3 and
       ([($stages[0][] | .id)] | sort) == ["A","B","C"] and
       $desktop[0].stages == $stages[0] and historical_failures == [] and
       report_ok($native[0].observations.gateway_start; "relaykit-gateway-start") and
       $native[0].observations.initial_provider_config.providers == [] and
       $native[0].app_zip_sha256 == $app_zip_sha and
       $native[0].extracted_app_sha256 == $extracted_app_sha and
       $native[0].provider_config_sha256 == $provider_sha and
       $desktop[0].stage_evidence_sha256 == $stage_sha and
       $desktop[0].usage_sha256 == $usage_sha and $desktop[0].provider_events_sha256 == $events_sha and
       $desktop[0].harness_sha256 == $harness_sha and $desktop[0].scenario_sha256 == $scenario_sha and
       $desktop[0].provider_config_sha256 == $provider_sha and
       $desktop[0].screenshot_sha256 == (first($screenshot_bindings[] | select(.path == $desktop[0].screenshot_path)) | .sha256) and
       ($screenshot_bindings | length) == ($screenshots[0] | length) and ($screenshot_bindings | length) >= 3 and
       all($screenshot_bindings[]; .sha256 != null and .sha256 == .expected_sha256) and
       ($guard[0].cleanup | type) == "array" and
       ($guard[0].cleanup | map(.name)) == ["app","helper","fixture","keychain"] and
       all(($guard[0].cleanup // [])[]; .status == "completed" and .exit_code == 0) and
       ($guard[0].processes | type) == "array" and
       ($guard[0].processes | map(.name)) == ["app","helper","fixture"] and
       all(($guard[0].processes // [])[]; .status == "exited"))
  } as $ledger |
  (historical_failures +
    [$ledger | to_entries[] |
      select((if .key == "post_retry_count" then .value != 0 else .value != true end)) | .key] | unique) as $failed |
  {
    phase_b: (if ($failed | length) == 0 then "PASS" else "FAIL" end),
    run_id: $run_id,
    provider_api_format: ($provider[0].providers[0].api_format // null),
    predicate_ledger: $ledger,
    failed_events: $failed,
    bindings: ([
      {kind:"native_evidence",path:$native_evidence,sha256:$native_sha},
      {kind:"desktop_evidence",path:$desktop_evidence,sha256:$desktop_sha},
      {kind:"desktop_stage_ledger",path:$stage_ledger,sha256:$stage_sha},
      {kind:"desktop_tool_evidence",path:$tool_evidence,sha256:$tool_sha},
      {kind:"screenshot_ledger",path:$screenshot_ledger,sha256:$screenshot_ledger_sha},
      {kind:"provider_config",path:$provider_config,sha256:$provider_sha},
      {kind:"protocol_validation",path:$protocol_evidence,sha256:$protocol_sha},
      {kind:"protocol_validation_log",path:$protocol_log_path,sha256:$protocol_log_sha},
      {kind:"cleanup_runtime_guard",path:$guard_evidence,sha256:$guard_sha},
      {kind:"app_zip",path:$app_zip,sha256:$app_zip_sha},
      {kind:"extracted_app",path:$extracted_app,sha256:$extracted_app_sha},
      {kind:"usage",path:$usage_path,sha256:$usage_sha},
      {kind:"provider_events",path:$events_path,sha256:$events_sha},
      {kind:"harness",path:$harness,sha256:$harness_sha},
      {kind:"scenario",path:$scenario,sha256:$scenario_sha}
    ] + $screenshot_bindings)
  }
' >"${temporary}"
chmod 600 "${temporary}"
mv -f "${temporary}" "${output}"
trap - EXIT
rm -rf "${tmp_dir}"

if jq -e '.phase_b == "PASS" and .failed_events == []' "${output}" >/dev/null; then
  printf '%s\n' "${output}"
  exit 0
fi
printf 'RC1 native Responses manifest derived FAIL: %s\n' "${output}" >&2
exit 1
