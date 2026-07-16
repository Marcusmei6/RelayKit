#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MANIFEST="${ROOT}/scripts/rc1-native-responses-manifest.sh"

fail() {
  printf 'RC1 native Responses manifest contract failed: %s\n' "$*" >&2
  exit 1
}

sha() { /usr/bin/shasum -a 256 "$1" | awk '{print $1}'; }
bundle_sha() {
  (
    cd "$1"
    while IFS= read -r -d '' item; do
      local_path="${item#./}"
      mode="$(stat -f '%Lp' "${item}")"
      if [[ -L "${item}" ]]; then
        printf 'symlink\0%s\0%s\0%s\0' "${local_path}" "${mode}" "$(readlink "${item}")"
      elif [[ -f "${item}" ]]; then
        printf 'file\0%s\0%s\0%s\0' "${local_path}" "${mode}" "$(sha "${item}")"
      elif [[ -d "${item}" ]]; then
        printf 'directory\0%s\0%s\0' "${local_path}" "${mode}"
      fi
    done < <(find . -mindepth 1 -print0 | LC_ALL=C sort -z)
  ) | /usr/bin/shasum -a 256 | awk '{print $1}'
}
mutate() {
  local filter="$1" path="$2"
  jq "${filter}" "${path}" >"${path}.tmp"
  mv "${path}.tmp" "${path}"
}

[[ -x "${MANIFEST}" ]] || fail "manifest script is missing"
bash -n "${MANIFEST}"

tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/relaykit-responses-manifest-test.XXXXXX")"
trap 'rm -rf "${tmp_dir}"' EXIT
run_id="manifest-run-001"

write_fixture() {
  rm -rf "${tmp_dir:?}"/*
  mkdir -p "${tmp_dir}/RelayKitApp.app/Contents/MacOS"
  printf 'app binary\n' >"${tmp_dir}/RelayKitApp.app/Contents/MacOS/RelayKitApp.bin"
  printf 'gateway binary\n' >"${tmp_dir}/RelayKitApp.app/Contents/MacOS/relay"
  for file in harness.sh scenario.json; do
    printf 'immutable %s\n' "${file}" >"${tmp_dir}/${file}"
  done
  (cd "${tmp_dir}" && /usr/bin/zip -qry app.zip RelayKitApp.app)
  printf 'ok\n' >"${tmp_dir}/protocol.log"
  printf '{"pid":101,"window_id":201}\n' >"${tmp_dir}/ordinary-identity.json"
  for role in rc1-text rc1-markdown rc1-tool; do
    printf 'screenshot %s\n' "${role}" >"${tmp_dir}/${role}.png"
  done
  for appearance in light dark; do
    for state in connect official-collapsed official-expanded official-scrolled provider-collapsed provider-expanded provider-scrolled; do
      printf 'ordinary screenshot %s %s\n' "${state}" "${appearance}" >"${tmp_dir}/ordinary-${state}-${appearance}.png"
    done
  done
  printf '{"providers":[{"api_format":"openai_responses","credential_ref":{"kind":"keychain","value":"relaykit.provider.fixture"},"models":[{"id":"custom/native-model","upstream_model":"native-upstream"}]}]}\n' >"${tmp_dir}/providers.json"

  jq -n \
    --arg plain "${tmp_dir}/rc1-text.png" --arg plain_sha "$(sha "${tmp_dir}/rc1-text.png")" \
    --arg markdown "${tmp_dir}/rc1-markdown.png" --arg markdown_sha "$(sha "${tmp_dir}/rc1-markdown.png")" \
    --arg tool "${tmp_dir}/rc1-tool.png" --arg tool_sha "$(sha "${tmp_dir}/rc1-tool.png")" '[
      {role:"rc1-text",path:$plain,sha256:$plain_sha,captured:true,target_identity_verified:true,pid:303,window_id:404,
       visual_checks:{response_marker_visible:true,raw_protocol_visible:false}},
      {role:"rc1-markdown",path:$markdown,sha256:$markdown_sha,captured:true,target_identity_verified:true,pid:303,window_id:404,
       visual_checks:{heading_visible:true,numbered_items_visible:true,table_headers_visible:true,bash_code_visible:true,bold_conclusion_visible:true,raw_protocol_visible:false}},
      {role:"rc1-tool",path:$tool,sha256:$tool_sha,captured:true,target_identity_verified:true,pid:303,window_id:404,
       visual_checks:{tool_marker_visible:true,tool_execution_visible:true,raw_protocol_visible:false}}
    ]' >"${tmp_dir}/screenshots.json"
  for appearance in light dark; do
    for state in connect official-collapsed official-expanded official-scrolled provider-collapsed provider-expanded provider-scrolled; do
      path="${tmp_dir}/ordinary-${state}-${appearance}.png"
      jq -n --arg role "ordinary-${state}-${appearance}" --arg path "${path}" --arg sha256 "$(sha "${path}")" \
        --arg appearance "${appearance}" --arg state "${state}" \
        --arg identity_path "${tmp_dir}/ordinary-identity.json" --arg identity_sha256 "$(sha "${tmp_dir}/ordinary-identity.json")" \
        '{role:$role,path:$path,sha256:$sha256,appearance:$appearance,state:$state,captured:true,target_identity_verified:true,
          pid:101,window_id:201,identity_path:$identity_path,identity_sha256:$identity_sha256}' \
        >>"${tmp_dir}/ordinary-screenshots.jsonl"
    done
  done
  jq -s '.' "${tmp_dir}/ordinary-screenshots.jsonl" >"${tmp_dir}/ordinary-screenshots.json"
  jq -s '.[0] + .[1]' "${tmp_dir}/screenshots.json" "${tmp_dir}/ordinary-screenshots.json" >"${tmp_dir}/screenshots.all.json"
  mv "${tmp_dir}/screenshots.all.json" "${tmp_dir}/screenshots.json"

  jq -n '[
    {id:"A",expect:"plain",state:"evidence_verified",submission_state:"submitted",submission_count:1,error_code:null,rollout_binding:{proof_found:true}},
    {id:"B",expect:"markdown",state:"evidence_verified",submission_state:"submitted",submission_count:1,error_code:null,rollout_binding:{proof_found:true}},
    {id:"C",expect:"tool",state:"evidence_verified",submission_state:"submitted",submission_count:1,error_code:null,rollout_binding:{proof_found:true}}
  ]' >"${tmp_dir}/stages.json"
  jq -n '{proof_found:true,function_call_found:true,function_call_output_found:true,process_exited_zero:true,
    matched_provider_tool_count:1,exact_shell_command_found:true,pwd_output_found:true,xml_leak_found:false,raw_function_calls_found:false}' \
    >"${tmp_dir}/tool.json"
  jq -n '[range(0;3) | {model:"custom/native-model",status:"completed",http_status:200,transport:"responses_websocket"}]' \
    >"${tmp_dir}/usage.json"
  : >"${tmp_dir}/provider-events.jsonl"
  for _ in {1..4}; do
    jq -nc --arg run_id "${run_id}" '{run_id:$run_id,method:"POST",path:"/v1/responses",model_rewrite:true,auth_present:true,
      event_types:["response.created","response.output_item.added","response.completed"]}' >>"${tmp_dir}/provider-events.jsonl"
  done
  jq -n --arg run_id "${run_id}" --arg log_path "${tmp_dir}/protocol.log" --arg log_sha "$(sha "${tmp_dir}/protocol.log")" \
    --arg server_sha "$(sha "${ROOT}/gateway/internal/server/server.go")" \
    --arg responses_sha "$(sha "${ROOT}/gateway/internal/server/openai_responses.go")" \
    --arg server_test_sha "$(sha "${ROOT}/gateway/internal/server/server_test.go")" \
    --arg provider_test_sha "$(sha "${ROOT}/gateway/internal/server/provider_test.go")" \
    --arg git_head "$(git -C "${ROOT}" rev-parse HEAD)" \
    --arg git_diff_sha "$(git -C "${ROOT}" diff HEAD --binary | /usr/bin/shasum -a 256 | awk '{print $1}')" '{
    schema_version:1,run_id:$run_id,producer:"rc1-native-responses-proof",
    command:"go test ./internal/server -run ^(TestNativeOpenAIResponsesNonStreamingPreservesProtocol|TestNativeOpenAIResponsesStreamsEventsAndReportsTruncation|TestResponsesRejectsEveryDuplicateTopLevelNativeRequest|TestNativeResponsesNonStreamingRejectsDuplicateTopLevelUpstreamResponse)$ -count=1",
    exit_code:0,git_head:$git_head,git_diff_sha256:$git_diff_sha,
    log:{path:$log_path,sha256:$log_sha},
    source_sha256:{
      "gateway/internal/server/server.go":$server_sha,
      "gateway/internal/server/openai_responses.go":$responses_sha,
      "gateway/internal/server/server_test.go":$server_test_sha,
      "gateway/internal/server/provider_test.go":$provider_test_sha
    },checks:[
    {name:"gateway_native_http",status:"passed"},
    {name:"gateway_native_sse",status:"passed"},
    {name:"request_duplicate_fields_rejected",status:"passed"},
    {name:"response_duplicate_fields_rejected",status:"passed"}
  ],failed_events:[]}' >"${tmp_dir}/protocol.json"
  empty_sha="$(printf '' | /usr/bin/shasum -a 256 | awk '{print $1}')"
  jq -n --arg run_id "${run_id}" --arg empty_sha "${empty_sha}" --arg state_sha "$(printf stable | /usr/bin/shasum -a 256 | awk '{print $1}')" '{
    schema_version:1,run_id:$run_id,
    global_config:{before_sha256:$state_sha,after_sha256:$state_sha},
    global_auth:{before_sha256:$state_sha,after_sha256:$state_sha},
    shared_18787:{before_snapshot_sha256:$state_sha,after_snapshot_sha256:$state_sha},
    cleanup:["app","helper","fixture","keychain"] | map({name:.,status:"completed",exit_code:0}),
    processes:["app","helper","fixture"] | map({name:.,pid:123,status:"exited"}),
    ports:[{kind:"gateway",port:19777,after_listener_count:0},{kind:"fixture_temp",port:43210,after_listener_count:0}],
    tracked_worktree:{status_line_count:0,porcelain_sha256:$empty_sha},failed_events:[]
  }' >"${tmp_dir}/guard.json"
  jq -n --arg run_id "${run_id}" \
    --arg app "$(sha "${tmp_dir}/app.zip")" \
    --arg extracted "$(bundle_sha "${tmp_dir}/RelayKitApp.app")" \
    --arg config "$(sha "${tmp_dir}/providers.json")" '{
    schema_version:2,run_id:$run_id,
    observations:{
      initial_provider_config:{providers:[]},
      first_window_identity:{pid:101,window_id:1},
      provider_configure:{status:"ok",code:"ok",command:"relaykit-provider-configure",window_verified:true,action_count:16},
      second_window_identity:{pid:202,window_id:2},
      provider_verify:{status:"ok",code:"ok",command:"relaykit-provider-verify",window_verified:true,action_count:4},
      gateway_start:{status:"ok",code:"ok",command:"relaykit-gateway-start",window_verified:true,action_count:2}
    },failed_events:[],app_zip_sha256:$app,extracted_app_sha256:$extracted,provider_config_sha256:$config
  }' >"${tmp_dir}/native.json"
  jq -n --arg run_id "${run_id}" \
    --arg screenshot "${tmp_dir}/rc1-tool.png" --arg screenshot_sha "$(sha "${tmp_dir}/rc1-tool.png")" \
    --arg usage "${tmp_dir}/usage.json" --arg usage_sha "$(sha "${tmp_dir}/usage.json")" \
    --arg events "${tmp_dir}/provider-events.jsonl" --arg events_sha "$(sha "${tmp_dir}/provider-events.jsonl")" \
    --arg harness_sha "$(sha "${tmp_dir}/harness.sh")" --arg scenario_sha "$(sha "${tmp_dir}/scenario.json")" \
    --arg config_sha "$(sha "${tmp_dir}/providers.json")" --arg stages_sha "$(sha "${tmp_dir}/stages.json")" \
    --slurpfile stages "${tmp_dir}/stages.json" '{
      status:"complete",manual_status:"route_complete",route_proof_status:"complete",harness_exit_code:0,
      run_id:$run_id,profile:"rc1_native_responses_three_stage",desktop_websocket_to_gateway:true,
      gateway_sse_to_fixture:true,tool_roundtrip_verified:true,failed_events:[],stages:$stages[0],
      desktop_window_identity:{pid:303,window_id:404},
      screenshot_path:$screenshot,screenshot_sha256:$screenshot_sha,usage_path:$usage,usage_sha256:$usage_sha,
      provider_events_path:$events,provider_events_sha256:$events_sha,harness_sha256:$harness_sha,
      scenario_sha256:$scenario_sha,provider_config_sha256:$config_sha,stage_evidence_sha256:$stages_sha
    }' >"${tmp_dir}/desktop.json"
}

args() {
  printf '%s\0' \
    --native-evidence "${tmp_dir}/native.json" \
    --desktop-evidence "${tmp_dir}/desktop.json" \
    --stage-ledger "${tmp_dir}/stages.json" \
    --tool-evidence "${tmp_dir}/tool.json" \
    --screenshot-ledger "${tmp_dir}/screenshots.json" \
    --provider-config "${tmp_dir}/providers.json" \
    --protocol-evidence "${tmp_dir}/protocol.json" \
    --guard-evidence "${tmp_dir}/guard.json" \
    --app-zip "${tmp_dir}/app.zip" \
    --extracted-app "${tmp_dir}/RelayKitApp.app" \
    --usage "${tmp_dir}/usage.json" \
    --provider-events "${tmp_dir}/provider-events.jsonl" \
    --harness "${tmp_dir}/harness.sh" \
    --scenario "${tmp_dir}/scenario.json" \
    --output "${tmp_dir}/manifest.json"
}

run_manifest() {
  local manifest_args=()
  while IFS= read -r -d '' value; do manifest_args+=("${value}"); done < <(args)
  "${MANIFEST}" "${manifest_args[@]}"
}

expect_failure() {
  local label="$1" expected_event="$2" status=0
  run_manifest >/dev/null 2>&1 || status=$?
  [[ "${status}" -ne 0 ]] || fail "manifest accepted ${label}"
  jq -e --arg event "${expected_event}" '.phase_b == "FAIL" and (.failed_events | index($event)) != null' \
    "${tmp_dir}/manifest.json" >/dev/null || fail "${label} did not emit a bound phase_b FAIL for ${expected_event}"
}

write_fixture
run_manifest >/dev/null
jq -e --arg run_id "${run_id}" '
  .phase_b == "PASS" and .run_id == $run_id and .failed_events == [] and
  .predicate_ledger.post_retry_count == 0 and
  (.predicate_ledger | to_entries | all(.[]; if .key == "post_retry_count" then .value == 0 else .value == true end)) and
  ([.bindings[].kind] | index("extracted_app")) != null and
  ([.bindings[] | select(.kind == "screenshot")] | length) == 17 and
  ([.bindings[].kind] | index("protocol_validation_log")) != null and
  all(.bindings[]; .sha256 | test("^[0-9a-f]{64}$"))
' "${tmp_dir}/manifest.json" >/dev/null || fail "manifest did not derive a fully bound PASS"

write_fixture
mutate '.observations.provider_configure.status="error"' "${tmp_dir}/native.json"
expect_failure "native evidence failure" app_ui_protocol_saved

write_fixture
chmod 600 "${tmp_dir}/RelayKitApp.app/Contents/MacOS/relay"
mutate ".extracted_app_sha256=\"$(bundle_sha "${tmp_dir}/RelayKitApp.app")\"" "${tmp_dir}/native.json"
expect_failure "package tree mode drift" package_tree_bound

write_fixture
mutate '.route_proof_status="observation_failed_3"' "${tmp_dir}/desktop.json"
expect_failure "Desktop evidence failure" structured_evidence_pass

write_fixture
mutate '.[1].state="failed"' "${tmp_dir}/stages.json"
stages_sha="$(sha "${tmp_dir}/stages.json")"
jq --arg stages_sha "${stages_sha}" --slurpfile stages "${tmp_dir}/stages.json" '.stage_evidence_sha256=$stages_sha | .stages=$stages[0]' \
  "${tmp_dir}/desktop.json" >"${tmp_dir}/desktop.tmp" && mv "${tmp_dir}/desktop.tmp" "${tmp_dir}/desktop.json"
expect_failure "stage ledger failure" desktop_markdown_verified

write_fixture
mutate '.process_exited_zero=false' "${tmp_dir}/tool.json"
expect_failure "tool evidence failure" tool_process_exited_zero

write_fixture
mutate 'map(if .role == "rc1-text" then .visual_checks.response_marker_visible=false else . end)' "${tmp_dir}/screenshots.json"
expect_failure "screenshot evidence failure" desktop_plain_verified

write_fixture
mutate 'map(if .role == "rc1-tool" then .window_id=999 else . end)' "${tmp_dir}/screenshots.json"
expect_failure "Desktop screenshot identity drift" desktop_tool_verified

write_fixture
mutate 'del(.desktop_window_identity.pid)' "${tmp_dir}/desktop.json"
expect_failure "missing Desktop identity" desktop_tool_verified

write_fixture
mutate 'map(if .role == "rc1-text" then del(.pid) else . end)' "${tmp_dir}/screenshots.json"
expect_failure "missing Desktop screenshot identity" desktop_tool_verified

write_fixture
mutate 'map(if .role == "ordinary-connect-light" then .pid=999 else . end)' "${tmp_dir}/screenshots.json"
expect_failure "ordinary screenshot identity drift" ordinary_ui_screenshots_verified

write_fixture
mutate '.[0].status="failed"' "${tmp_dir}/usage.json"
mutate ".usage_sha256=\"$(sha "${tmp_dir}/usage.json")\"" "${tmp_dir}/desktop.json"
expect_failure "usage evidence failure" current_run_usage_only

write_fixture
mutate '.path="/v1/chat/completions"' "${tmp_dir}/provider-events.jsonl"
mutate ".provider_events_sha256=\"$(sha "${tmp_dir}/provider-events.jsonl")\"" "${tmp_dir}/desktop.json"
expect_failure "provider-event failure" upstream_path_is_responses

write_fixture
mutate '.providers[0].api_format="openai_chat"' "${tmp_dir}/providers.json"
config_sha="$(sha "${tmp_dir}/providers.json")"
mutate ".provider_config_sha256=\"${config_sha}\"" "${tmp_dir}/native.json"
mutate ".provider_config_sha256=\"${config_sha}\"" "${tmp_dir}/desktop.json"
expect_failure "provider config failure" app_ui_protocol_saved

write_fixture
mutate '(.checks[] | select(.name == "gateway_native_http")).status="failed"' "${tmp_dir}/protocol.json"
expect_failure "protocol validation failure" gateway_native_http_verified

write_fixture
mutate '.git_diff_sha256=("0" * 64)' "${tmp_dir}/protocol.json"
expect_failure "stale protocol source binding" protocol_evidence_current_source

write_fixture
mutate '.checks += [.checks[0]]' "${tmp_dir}/protocol.json"
expect_failure "duplicate protocol check" protocol_evidence_current_source

write_fixture
mutate '.ports[1].after_listener_count=1' "${tmp_dir}/guard.json"
expect_failure "runtime cleanup guard failure" temporary_ports_released

write_fixture
mutate '.tracked_worktree.status_line_count=1' "${tmp_dir}/guard.json"
expect_failure "git guard failure" tracked_worktree_clean

write_fixture
mutate '.cleanup=[]' "${tmp_dir}/guard.json"
expect_failure "empty cleanup ledger" structured_evidence_pass

write_fixture
mutate '.processes=[.processes[1],.processes[0],.processes[2]]' "${tmp_dir}/guard.json"
expect_failure "reordered process ledger" structured_evidence_pass

write_fixture
mutate 'map(select(.role != "ordinary-provider-scrolled-dark"))' "${tmp_dir}/screenshots.json"
expect_failure "missing ordinary UI screenshot" ordinary_ui_screenshots_verified

write_fixture
mutate '.harness_sha256=("0" * 64)' "${tmp_dir}/desktop.json"
expect_failure "immutable hash failure" structured_evidence_pass

write_fixture
mutate '.failed_events=["observation_failed_3"]' "${tmp_dir}/desktop.json"
expect_failure "historical failure" observation_failed_3

write_fixture
mutate 'del(.checks[] | select(.name == "response_duplicate_fields_rejected"))' "${tmp_dir}/protocol.json"
expect_failure "missing predicate" response_duplicate_fields_rejected

write_fixture
mutate 'del(.global_auth.after_sha256)' "${tmp_dir}/guard.json"
expect_failure "missing guard predicate" global_auth_unchanged

printf '%s\n' 'RelayKit RC1 native Responses manifest tests passed'
