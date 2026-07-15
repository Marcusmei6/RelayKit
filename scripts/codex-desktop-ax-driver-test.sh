#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE="${ROOT}/scripts/codex-desktop-ax-driver.swift"

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

test -f "${SOURCE}" || fail "Codex Desktop AX driver source is missing"

tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/relaykit-ax-driver-test.XXXXXX")"
trap 'rm -rf "${tmp_dir}"' EXIT

binary="${tmp_dir}/codex-desktop-ax-driver"
/usr/bin/xcrun swiftc -D RELAYKIT_AX_DRIVER_TESTING "${SOURCE}" -o "${binary}"

capture_index=0
last_stdout=""

assert_redacted_json() {
  local output_file="$1"
  jq -e -s '
    length == 1 and
    (.[0] | type == "object") and
    ((.[0] | keys) - [
      "action_count",
      "candidate_count",
      "code",
      "command",
      "composer_count",
      "model_picker_count",
      "send_count",
      "status",
      "window_verified"
    ] | length == 0)
  ' "${output_file}" >/dev/null || fail "driver output is not one redacted JSON object"

  if rg -qi 'prompt|sha|hash|tree|clipboard|workspace' "${output_file}"; then
    fail "driver output exposed forbidden input or AX detail"
  fi
}

run_success() {
  capture_index=$((capture_index + 1))
  local stdout_file="${tmp_dir}/stdout-${capture_index}.json"
  local stderr_file="${tmp_dir}/stderr-${capture_index}.txt"
  if ! "$@" >"${stdout_file}" 2>"${stderr_file}"; then
    fail "expected success from: $*"
  fi
  test ! -s "${stderr_file}" || fail "driver wrote non-JSON diagnostics to stderr"
  assert_redacted_json "${stdout_file}"
  jq -e '.status == "ok" and .code == "ok"' "${stdout_file}" >/dev/null ||
    fail "driver success did not report the redacted ok envelope"
  last_stdout="${stdout_file}"
}

run_failure() {
  local expected_code="$1"
  shift
  capture_index=$((capture_index + 1))
  local stdout_file="${tmp_dir}/stdout-${capture_index}.json"
  local stderr_file="${tmp_dir}/stderr-${capture_index}.txt"
  local status=0
  "$@" >"${stdout_file}" 2>"${stderr_file}" || status=$?
  test "${status}" -ne 0 || fail "expected failure from: $*"
  test ! -s "${stderr_file}" || fail "driver wrote non-JSON diagnostics to stderr"
  assert_redacted_json "${stdout_file}"
  jq -e --arg code "${expected_code}" '.status == "error" and .code == $code' "${stdout_file}" >/dev/null ||
    fail "driver failure did not report ${expected_code}"
  last_stdout="${stdout_file}"
}

run_failure invalid_arguments "${binary}" inspect
run_failure invalid_arguments "${binary}" reveal --pid 1 --window-identity "${tmp_dir}/window.json"
run_failure invalid_arguments "${binary}" ready --pid 1 --window-identity "${tmp_dir}/window.json"
run_failure invalid_arguments \
  "${binary}" prepare --pid 1 --window-identity "${tmp_dir}/window.json"
run_failure invalid_arguments \
  "${binary}" submit --pid 1 --window-identity "${tmp_dir}/window.json" \
  --model-label "Official GPT-5.5" --catalog-labels-file "${tmp_dir}/catalog.json"
run_failure invalid_command "${binary}" self-test --scenario exact
run_failure invalid_arguments "${binary}" relaykit-provider-configure --pid 1 --window-identity "${tmp_dir}/window.json"
run_failure invalid_arguments "${binary}" relaykit-provider-protocol-probe --pid 1 --window-identity "${tmp_dir}/window.json"
run_failure invalid_arguments "${binary}" relaykit-provider-verify --pid 1 --window-identity "${tmp_dir}/window.json"
run_failure invalid_arguments "${binary}" relaykit-gateway-start --pid 1
run_failure invalid_command \
  "${binary}" relaykit-ax-inspect --pid 1 --window-identity "${tmp_dir}/window.json" \
  --diagnostic-output "${tmp_dir}/ax-inspect.json"
run_failure invalid_arguments env RELAYKIT_AX_DRIVER_DIAGNOSTIC=1 \
  "${binary}" relaykit-ax-inspect --pid 1 --window-identity "${tmp_dir}/window.json"

self_test=(env RELAYKIT_AX_DRIVER_SELF_TEST=1 "${binary}" self-test)

write_window_identity() {
  local path="$1"
  local pid="$2"
  local window_id="$3"
  jq -n --argjson pid "${pid}" --argjson window_id "${window_id}" \
    '{pid:$pid,window_id:$window_id}' >"${path}"
  chmod 600 "${path}"
}

run_bound_window_success() {
  local name="$1"
  local command="$2"
  local pid="$3"
  local window_id="$4"
  shift 4
  local identity="${tmp_dir}/${name}-identity.json"
  local metadata="${tmp_dir}/${name}-metadata.json"
  write_window_identity "${identity}" "${pid}" "${window_id}"
  cat >"${metadata}"
  chmod 600 "${metadata}"
  run_success env \
    RELAYKIT_AX_DRIVER_SELF_TEST=1 \
    RELAYKIT_AX_DRIVER_BOUND_WINDOW_TEST_INPUT="${metadata}" \
    "${binary}" "${command}" --pid "${pid}" --window-identity "${identity}" "$@"
  jq -e --arg command "${command}" \
    '.command == $command and .window_verified == true' "${last_stdout}" >/dev/null ||
    fail "${name} did not prove the production bound window"
}

run_bound_window_failure() {
  local expected_code="$1"
  local name="$2"
  local command="$3"
  local pid="$4"
  local window_id="$5"
  shift 5
  local identity="${tmp_dir}/${name}-identity.json"
  local metadata="${tmp_dir}/${name}-metadata.json"
  write_window_identity "${identity}" "${pid}" "${window_id}"
  cat >"${metadata}"
  chmod 600 "${metadata}"
  run_failure "${expected_code}" env \
    RELAYKIT_AX_DRIVER_SELF_TEST=1 \
    RELAYKIT_AX_DRIVER_BOUND_WINDOW_TEST_INPUT="${metadata}" \
    "${binary}" "${command}" --pid "${pid}" --window-identity "${identity}" "$@"
}

relaykit_configure_options=(
  --provider-name "Dogfood Dynamic Window"
  --base-url "http://127.0.0.1:19779/v1"
  --synthetic-key "RELAYKIT_FAKE_DYNAMIC_WINDOW_DO_NOT_USE"
  --model-id "dogfood/dynamic-window"
)
relaykit_verify_options=(
  --provider-name "Dogfood Dynamic Window"
  --base-url "http://127.0.0.1:19779/v1"
  --model-id "dogfood/dynamic-window"
)

run_bound_window_failure window_selector_not_unique \
  relaykit-exact-number-non-window-role relaykit-gateway-start 4801 301 <<'JSON'
{
  "current_identity":{"pid":4801,"window_id":301},"process_running":true,
  "bundle_identifier":"dev.relaykit.app","frontmost_pid":null,"accessibility_trusted":true,
  "windows":[{"owner_pid":4801,"window_id":301,"layer":25}],
  "ax_window_numbers":[301],"ax_window_node_ids":[1],"root_id":0,
  "nodes":[
    {"id":0,"role":"AXApplication","children":[1]},
    {"id":1,"role":"AXGroup","identifier":"provider-add-entry","children":[]}
  ]
}
JSON
jq -e '.candidate_count == 0' "${last_stdout}" >/dev/null ||
  fail "RelayKit accepted an exact window number on a non-AXWindow role"

run_bound_window_failure relaykit_semantic_node_missing \
  relaykit-exact-window-without-semantic-node relaykit-gateway-start 4802 302 <<'JSON'
{
  "current_identity":{"pid":4802,"window_id":302},"process_running":true,
  "bundle_identifier":"dev.relaykit.app","frontmost_pid":null,"accessibility_trusted":true,
  "windows":[{"owner_pid":4802,"window_id":302,"layer":25}],
  "ax_window_numbers":[302],"ax_window_node_ids":[1],"root_id":0,
  "nodes":[
    {"id":0,"role":"AXApplication","children":[1]},
    {"id":1,"role":"AXWindow","children":[2]},
    {"id":2,"role":"AXButton","identifier":"unrelated-control","children":[]}
  ]
}
JSON
jq -e '.candidate_count == 0' "${last_stdout}" >/dev/null ||
  fail "RelayKit semantic-node failure did not report candidate count 0"

run_bound_window_success relaykit-exact-window-provider-add-entry relaykit-gateway-start 4803 303 <<'JSON'
{
  "current_identity":{"pid":4803,"window_id":303},"process_running":true,
  "bundle_identifier":"dev.relaykit.app","frontmost_pid":null,"accessibility_trusted":true,
  "windows":[{"owner_pid":4803,"window_id":303,"layer":25}],
  "ax_window_numbers":[303],"ax_window_node_ids":[1],"root_id":0,
  "nodes":[
    {"id":0,"role":"AXApplication","children":[1]},
    {"id":1,"role":"AXWindow","children":[2]},
    {"id":2,"role":"AXButton","identifier":"provider-add-entry","children":[]}
  ]
}
JSON

run_bound_window_success relaykit-exact-window-with-distractors relaykit-gateway-start 4804 304 <<'JSON'
{
  "current_identity":{"pid":4804,"window_id":304},"process_running":true,
  "bundle_identifier":"dev.relaykit.app","frontmost_pid":null,"accessibility_trusted":true,
  "windows":[{"owner_pid":4804,"window_id":304,"layer":25}],
  "ax_window_numbers":[999,304,null],"ax_window_node_ids":[1,2,3],"root_id":0,
  "nodes":[
    {"id":0,"role":"AXApplication","children":[1,2,3]},
    {"id":1,"role":"AXWindow","children":[]},
    {"id":2,"role":"AXWindow","children":[4]},
    {"id":3,"role":"AXWindow","children":[5]},
    {"id":4,"role":"AXRow","identifier":"official-provider-row","children":[]},
    {"id":5,"role":"AXButton","identifier":"provider-add-entry","children":[]}
  ],
  "expected_action_root_id":2
}
JSON

run_bound_window_failure window_selector_not_unique \
  relaykit-application-only-empty-ax-windows relaykit-gateway-start 4805 305 <<'JSON'
{
  "current_identity":{"pid":4805,"window_id":305},"process_running":true,
  "bundle_identifier":"dev.relaykit.app","frontmost_pid":null,"accessibility_trusted":true,
  "windows":[{"owner_pid":4805,"window_id":305,"layer":25}],
  "ax_windows_status":"success","ax_windows_value_present":true,
  "ax_window_numbers":[],"ax_window_node_ids":[],"root_id":0,
  "nodes":[{"id":0,"role":"AXApplication","children":[]}]
}
JSON
jq -e '.candidate_count == 0' "${last_stdout}" >/dev/null ||
  fail "application-only tree with successful empty AXWindows did not report candidate count 0"

for exact_failure_case in mismatch unnumbered; do
  case "${exact_failure_case}" in
    mismatch)
      exact_numbers='[999]'; exact_ids='[1]'
      ;;
    unnumbered)
      exact_numbers='[null]'; exact_ids='[1]'
      ;;
  esac
  run_bound_window_failure window_selector_not_unique \
    "relaykit-${exact_failure_case}" relaykit-gateway-start 4805 305 <<JSON
{
  "current_identity":{"pid":4805,"window_id":305},"process_running":true,
  "bundle_identifier":"dev.relaykit.app","frontmost_pid":null,"accessibility_trusted":true,
  "windows":[{"owner_pid":4805,"window_id":305,"layer":25}],
  "ax_window_numbers":${exact_numbers},"ax_window_node_ids":${exact_ids},"root_id":0,
  "nodes":[
    {"id":0,"role":"AXApplication","children":[1]},
    {"id":1,"role":"AXWindow","identifier":"provider-add-entry","children":[]}
  ]
}
JSON
  jq -e '.candidate_count == 0' "${last_stdout}" >/dev/null ||
    fail "${exact_failure_case} did not fail with exact candidate count 0"
done

run_bound_window_failure window_identity_changed \
  relaykit-zero-windowserver-window relaykit-gateway-start 4806 306 <<'JSON'
{
  "current_identity":{"pid":4806,"window_id":306},"process_running":true,
  "bundle_identifier":"dev.relaykit.app","frontmost_pid":null,"accessibility_trusted":true,
  "windows":[],"ax_window_numbers":[306],"ax_window_node_ids":[1],"root_id":0,
  "nodes":[
    {"id":0,"role":"AXApplication","children":[1]},
    {"id":1,"role":"AXWindow","identifier":"provider-add-entry","children":[]}
  ]
}
JSON
jq -e '.candidate_count == 0' "${last_stdout}" >/dev/null ||
  fail "zero WindowServer windows did not report candidate count 0"

run_bound_window_failure window_selector_not_unique \
  relaykit-multiple-exact-numbered-windows relaykit-gateway-start 4807 307 <<'JSON'
{
  "current_identity":{"pid":4807,"window_id":307},"process_running":true,
  "bundle_identifier":"dev.relaykit.app","frontmost_pid":null,"accessibility_trusted":true,
  "windows":[{"owner_pid":4807,"window_id":307,"layer":25}],
  "ax_window_numbers":[307,307],"ax_window_node_ids":[1,2],"root_id":0,
  "nodes":[
    {"id":0,"role":"AXApplication","children":[1,2]},
    {"id":1,"role":"AXWindow","identifier":"provider-add-entry","children":[]},
    {"id":2,"role":"AXWindow","identifier":"official-provider-row","children":[]}
  ]
}
JSON
jq -e '.candidate_count == 2' "${last_stdout}" >/dev/null ||
  fail "multiple exact AXWindow matches did not report actual count 2"

for traversal_case in malformed error; do
  if [[ "${traversal_case}" == malformed ]]; then
    traversal_status=success
    traversal_value=',"children_value":"malformed"'
  else
    traversal_status=cannotComplete
    traversal_value=''
  fi
  run_bound_window_failure relaykit_semantic_traversal_incomplete \
    "relaykit-semantic-traversal-${traversal_case}" relaykit-gateway-start 4808 308 <<JSON
{
  "current_identity":{"pid":4808,"window_id":308},"process_running":true,
  "bundle_identifier":"dev.relaykit.app","frontmost_pid":null,"accessibility_trusted":true,
  "windows":[{"owner_pid":4808,"window_id":308,"layer":25}],
  "ax_window_numbers":[308],"ax_window_node_ids":[1],"root_id":0,
  "nodes":[
    {"id":0,"role":"AXApplication","children":[1]},
    {"id":1,"role":"AXWindow","identifier":"provider-add-entry","children_status":"${traversal_status}"${traversal_value},"children":[2]},
    {"id":2,"role":"AXButton","children":[]}
  ]
}
JSON
done

truncated_metadata="${tmp_dir}/relaykit-semantic-traversal-truncated.json"
jq -n '{
  current_identity:{pid:4809,window_id:309},process_running:true,
  bundle_identifier:"dev.relaykit.app",frontmost_pid:null,accessibility_trusted:true,
  windows:[{owner_pid:4809,window_id:309,layer:25}],
  ax_window_numbers:[309],ax_window_node_ids:[0],root_id:0,
  nodes:[range(0;15) as $id | {
    id:$id,role:(if $id == 0 then "AXWindow" else "AXGroup" end),
    identifier:(if $id == 1 then "provider-add-entry" else null end),
    children:(if $id < 14 then [$id + 1] else [] end)
  }]
}' >"${truncated_metadata}"
run_bound_window_failure relaykit_semantic_traversal_incomplete \
  relaykit-semantic-traversal-truncated relaykit-gateway-start 4809 309 <"${truncated_metadata}"

relaykit_exact_window_metadata='{
  "current_identity":{"pid":4201,"window_id":42},"process_running":true,
  "bundle_identifier":"dev.relaykit.app","frontmost_pid":9999,"accessibility_trusted":true,
  "windows":[
    {"owner_pid":4201,"window_id":42,"layer":25},
    {"owner_pid":4201,"window_id":43,"layer":0},
    {"owner_pid":9999,"window_id":42,"layer":0}
  ],
  "ax_window_numbers":[43,42,null],"ax_window_node_ids":[1,2,3],"root_id":0,
  "nodes":[
    {"id":0,"role":"AXApplication","children":[1,2,3]},
    {"id":1,"role":"AXWindow","children":[]},
    {"id":2,"role":"AXWindow","children":[4]},
    {"id":3,"role":"AXGroup","children":[]},
    {"id":4,"role":"AXButton","identifier":"provider-add-entry","children":[]}
  ],
  "expected_action_root_id":2
}'
for relaykit_command in relaykit-provider-configure relaykit-provider-protocol-probe relaykit-provider-verify relaykit-gateway-start; do
  case "${relaykit_command}" in
    relaykit-provider-configure|relaykit-provider-protocol-probe)
      relaykit_options=("${relaykit_configure_options[@]}")
      ;;
    relaykit-provider-verify)
      relaykit_options=("${relaykit_verify_options[@]}")
      ;;
    relaykit-gateway-start)
      relaykit_options=()
      ;;
  esac
  for frontmost_pid in 9999 null; do
    relaykit_metadata="$(jq -c --argjson frontmost_pid "${frontmost_pid}"       '.frontmost_pid=$frontmost_pid' <<<"${relaykit_exact_window_metadata}")"
    run_bound_window_success       "${relaykit_command}-exact-window-frontmost-${frontmost_pid}" "${relaykit_command}" 4201 42       ${relaykit_options[@]+"${relaykit_options[@]}"} <<<"${relaykit_metadata}"
    jq -e '.candidate_count == 1' "${last_stdout}" >/dev/null ||
      fail "${relaykit_command} did not bind one exact semantic AXWindow"
  done
done
run_bound_window_success desktop-layer0 inspect 4301 61 <<'JSON'
{
  "current_identity": {"pid":4301,"window_id":61},
  "process_running": true,
  "bundle_identifier": "com.openai.codex",
  "frontmost_pid": 4301,
  "accessibility_trusted": true,
  "windows": [
    {"owner_pid":4301,"window_id":61,"layer":0},
    {"owner_pid":4301,"window_id":62,"layer":25},
    {"owner_pid":9999,"window_id":61,"layer":0}
  ],
  "ax_window_numbers": [61,null]
}
JSON

run_bound_window_failure window_identity_changed relaykit-identity-reread-mismatch relaykit-gateway-start 4400 70 <<'JSON'
{
  "current_identity": {"pid":4400,"window_id":71},
  "process_running": true,
  "bundle_identifier": "dev.relaykit.app",
  "frontmost_pid": null,
  "accessibility_trusted": true,
  "windows": [{"owner_pid":4400,"window_id":70,"layer":25}],
  "ax_window_numbers": [70]
}
JSON

run_bound_window_failure process_unavailable relaykit-process-missing relaykit-gateway-start 4400 70 <<'JSON'
{
  "current_identity": {"pid":4400,"window_id":70},
  "process_running": false,
  "bundle_identifier": "dev.relaykit.app",
  "frontmost_pid": null,
  "accessibility_trusted": true,
  "windows": [{"owner_pid":4400,"window_id":70,"layer":25}],
  "ax_window_numbers": [70]
}
JSON

run_bound_window_failure process_identity_mismatch relaykit-bundle-wrong relaykit-gateway-start 4400 70 <<'JSON'
{
  "current_identity": {"pid":4400,"window_id":70},
  "process_running": true,
  "bundle_identifier": "com.openai.codex",
  "frontmost_pid": null,
  "accessibility_trusted": true,
  "windows": [{"owner_pid":4400,"window_id":70,"layer":25}],
  "ax_window_numbers": [70]
}
JSON

run_bound_window_failure window_identity_changed relaykit-wrong-id relaykit-gateway-start 4401 71 <<'JSON'
{
  "current_identity": {"pid":4401,"window_id":71},
  "process_running": true,
  "bundle_identifier": "dev.relaykit.app",
  "frontmost_pid": null,
  "accessibility_trusted": true,
  "windows": [{"owner_pid":4401,"window_id":72,"layer":25}],
  "ax_window_numbers": [71]
}
JSON
jq -e '.candidate_count == 0' "${last_stdout}" >/dev/null ||
  fail "RelayKit wrong WindowServer ID did not fail with zero exact matches"

run_bound_window_failure window_identity_changed relaykit-missing-id relaykit-gateway-start 4402 81 <<'JSON'
{
  "current_identity": {"pid":4402,"window_id":81},
  "process_running": true,
  "bundle_identifier": "dev.relaykit.app",
  "frontmost_pid": null,
  "accessibility_trusted": true,
  "windows": [
    {"owner_pid":4402,"layer":25},
    {"owner_pid":9999,"window_id":81,"layer":25}
  ],
  "ax_window_numbers": [81]
}
JSON
jq -e '.candidate_count == 0' "${last_stdout}" >/dev/null ||
  fail "RelayKit missing same-PID WindowServer ID did not fail closed"

run_bound_window_failure window_identity_changed relaykit-multiple-exact relaykit-gateway-start 4403 91 <<'JSON'
{
  "current_identity": {"pid":4403,"window_id":91},
  "process_running": true,
  "bundle_identifier": "dev.relaykit.app",
  "frontmost_pid": null,
  "accessibility_trusted": true,
  "windows": [
    {"owner_pid":4403,"window_id":91,"layer":0},
    {"owner_pid":4403,"window_id":91,"layer":25}
  ],
  "ax_window_numbers": [91]
}
JSON
jq -e '.candidate_count == 2' "${last_stdout}" >/dev/null ||
  fail "RelayKit duplicate exact WindowServer entries did not fail closed"

run_bound_window_failure window_selector_not_unique relaykit-multiple-unnumbered relaykit-gateway-start 4404 101 <<'JSON'
{
  "current_identity": {"pid":4404,"window_id":101},
  "process_running": true,
  "bundle_identifier": "dev.relaykit.app",
  "frontmost_pid": null,
  "accessibility_trusted": true,
  "windows": [{"owner_pid":4404,"window_id":101,"layer":25}],
  "ax_window_numbers": [null,null]
}
JSON
jq -e '.candidate_count == 0' "${last_stdout}" >/dev/null ||
  fail "RelayKit multiple unnumbered AX windows did not fail closed"

run_bound_window_failure accessibility_permission_unavailable relaykit-ax-untrusted relaykit-gateway-start 4405 102 <<'JSON'
{
  "current_identity": {"pid":4405,"window_id":102},
  "process_running": true,
  "bundle_identifier": "dev.relaykit.app",
  "frontmost_pid": null,
  "accessibility_trusted": false,
  "windows": [{"owner_pid":4405,"window_id":102,"layer":25}],
  "ax_window_numbers": [102]
}
JSON

run_bound_window_failure window_identity_changed desktop-nonzero-layer inspect 4501 111 <<'JSON'
{
  "current_identity": {"pid":4501,"window_id":111},
  "process_running": true,
  "bundle_identifier": "com.openai.codex",
  "frontmost_pid": 4501,
  "accessibility_trusted": true,
  "windows": [{"owner_pid":4501,"window_id":111,"layer":25}],
  "ax_window_numbers": [111]
}
JSON
jq -e '.candidate_count == 0' "${last_stdout}" >/dev/null ||
  fail "Desktop accepted a nonzero-layer WindowServer identity"

run_bound_window_failure window_selector_not_unique desktop-fallback-count inspect 4502 121 <<'JSON'
{
  "current_identity": {"pid":4502,"window_id":121},
  "process_running": true,
  "bundle_identifier": "com.openai.codex",
  "frontmost_pid": 4502,
  "accessibility_trusted": true,
  "windows": [
    {"owner_pid":4502,"window_id":121,"layer":0},
    {"owner_pid":4502,"window_id":122,"layer":0}
  ],
  "ax_window_numbers": [null]
}
JSON
jq -e '.candidate_count == 1' "${last_stdout}" >/dev/null ||
  fail "Desktop fallback stopped counting same-PID layer-zero windows"

run_bound_window_failure frontmost_identity_mismatch desktop-other-frontmost inspect 4503 131 <<'JSON'
{
  "current_identity": {"pid":4503,"window_id":131},
  "process_running": true,
  "bundle_identifier": "com.openai.codex",
  "frontmost_pid": 9999,
  "accessibility_trusted": true,
  "windows": [{"owner_pid":4503,"window_id":131,"layer":0}],
  "ax_window_numbers": [131]
}
JSON

run_bound_window_failure frontmost_identity_mismatch desktop-nil-frontmost inspect 4504 141 <<'JSON'
{
  "current_identity": {"pid":4504,"window_id":141},
  "process_running": true,
  "bundle_identifier": "com.openai.codex",
  "frontmost_pid": null,
  "accessibility_trusted": true,
  "windows": [{"owner_pid":4504,"window_id":141,"layer":0}],
  "ax_window_numbers": [141]
}
JSON

assert_ax_inspect_schema() {
  local path="$1"
  [[ "$(stat -f '%Lp' "${path}")" == "600" ]] ||
    fail "AX inspect output permissions are not 0600"
  jq -e '
    (keys | sort) == [
      "ax_windows_available","ax_windows_count","depth_counts",
      "matching_window_count","nodes","numbered_window_count",
      "role_counts","semantic_identifier_count","status","truncated"
    ] and
    .status == "ok" and
    (.ax_windows_available | type == "boolean") and
    (.ax_windows_count | type == "number") and
    (.numbered_window_count | type == "number") and
    (.matching_window_count | type == "number") and
    (.semantic_identifier_count | type == "number") and
    (.truncated | type == "boolean") and
    (.nodes | all(.[];
      (keys | sort) == [
        "child_count","depth","matches_expected_window","ordinal","parent",
        "role","subrole","window_number_present"
      ] and
      (.ordinal | type == "number") and
      ((.parent | type) == "number" or .parent == null) and
      (.depth | type == "number") and
      (.role | type == "string") and
      ((.subrole | type) == "string" or .subrole == null) and
      (.child_count | type == "number") and
      (.window_number_present | type == "boolean") and
      (.matches_expected_window | type == "boolean"))) and
    (.role_counts | all(.[];
      (keys | sort) == ["count","role"] and
      (.role | type == "string") and (.count | type == "number"))) and
    (.depth_counts | all(.[];
      (keys | sort) == ["count","depth"] and
      (.depth | type == "number") and (.count | type == "number")))
  ' "${path}" >/dev/null || fail "AX inspect output escaped its allowlisted schema"
}

run_ax_inspect_success() {
  local name="$1"
  local pid="$2"
  local window_id="$3"
  local identity="${tmp_dir}/${name}-identity.json"
  local metadata="${tmp_dir}/${name}-metadata.json"
  local output="${tmp_dir}/${name}-ax-inspect.json"
  write_window_identity "${identity}" "${pid}" "${window_id}"
  cat >"${metadata}"
  chmod 600 "${metadata}"
  run_success env \
    RELAYKIT_AX_DRIVER_SELF_TEST=1 \
    RELAYKIT_AX_DRIVER_DIAGNOSTIC=1 \
    RELAYKIT_AX_DRIVER_DIAGNOSTIC_TEST_INPUT="${metadata}" \
    "${binary}" relaykit-ax-inspect --pid "${pid}" --window-identity "${identity}" \
    --diagnostic-output "${output}"
  jq -e '.command == "relaykit-ax-inspect" and .window_verified == true and .action_count == 0' \
    "${last_stdout}" >/dev/null || fail "AX inspect stdout was not redacted"
  assert_ax_inspect_schema "${output}"
  last_ax_inspect="${output}"
}

run_ax_inspect_failure() {
  local expected_code="$1"
  local name="$2"
  local pid="$3"
  local window_id="$4"
  local identity="${tmp_dir}/${name}-identity.json"
  local metadata="${tmp_dir}/${name}-metadata.json"
  local output="${tmp_dir}/${name}-ax-inspect.json"
  write_window_identity "${identity}" "${pid}" "${window_id}"
  cat >"${metadata}"
  chmod 600 "${metadata}"
  run_failure "${expected_code}" env \
    RELAYKIT_AX_DRIVER_SELF_TEST=1 \
    RELAYKIT_AX_DRIVER_DIAGNOSTIC=1 \
    RELAYKIT_AX_DRIVER_DIAGNOSTIC_TEST_INPUT="${metadata}" \
    "${binary}" relaykit-ax-inspect --pid "${pid}" --window-identity "${identity}" \
    --diagnostic-output "${output}"
  [[ ! -e "${output}" ]] || fail "${name} traversed or wrote diagnostics after identity failure"
}

run_ax_inspect_success relaykit-ax-exact-semantic-window 4601 42 <<'JSON'
{
  "current_identity":{"pid":4601,"window_id":42},
  "process_running":true,
  "bundle_identifier":"dev.relaykit.app",
  "frontmost_pid":9999,
  "accessibility_trusted":true,
  "windows":[{"owner_pid":4601,"window_id":42,"layer":25}],
  "ax_windows_available":true,
  "ax_windows_count":2,
  "ax_window_numbers":[41,42],
  "ax_window_node_ids":[1,2],
  "root_id":0,
  "nodes":[
    {"id":0,"role":"AXApplication","children":[1,2]},
    {"id":1,"role":"AXWindow","subrole":"AXStandardWindow","window_number":41,"children":[]},
    {"id":2,"role":"AXWindow","subrole":"AXStandardWindow","window_number":42,"children":[3]},
    {"id":3,"role":"AXButton","identifier":"provider-add-entry","children":[],"sensitive_value":"RELAYKIT_PRIVATE_SENTINEL"}
  ]
}
JSON
jq -e '
  .ax_windows_available == true and .ax_windows_count == 2 and
  .numbered_window_count == 1 and .matching_window_count == 1 and
  .semantic_identifier_count == 1 and .truncated == false and
  (.nodes | length) == 2 and
  .nodes[0] == {
    ordinal:0,parent:null,depth:0,role:"AXWindow",subrole:"AXStandardWindow",child_count:1,
    window_number_present:true,matches_expected_window:true
  } and
  .nodes[1].parent == 0 and .nodes[1].role == "AXButton" and
  .role_counts == [{role:"AXButton",count:1},{role:"AXWindow",count:1}] and
  .depth_counts == [{depth:0,count:1},{depth:1,count:1}]
' "${last_ax_inspect}" >/dev/null || fail "AX inspect exact-window structural summary is incorrect"
if rg -Fq 'RELAYKIT_PRIVATE_SENTINEL' "${last_ax_inspect}"; then
  fail "AX inspect serialized a non-allowlisted sensitive attribute"
fi

run_ax_inspect_success relaykit-ax-single-snapshot-second-read-error 4610 82 <<'JSON'
{
  "current_identity":{"pid":4610,"window_id":82},"process_running":true,
  "bundle_identifier":"dev.relaykit.app","frontmost_pid":null,"accessibility_trusted":true,
  "windows":[{"owner_pid":4610,"window_id":82,"layer":25}],
  "ax_windows_available":true,"ax_window_numbers":[82],"ax_window_node_ids":[1],"root_id":0,
  "expected_max_children_reads":1,
  "nodes":[
    {"id":0,"role":"AXApplication","children":[1]},
    {"id":1,"role":"AXWindow","window_number":82,"children":[2],
     "second_children_status":"cannotComplete","second_children":[3]},
    {"id":2,"role":"AXButton","identifier":"provider-add-entry","children":[]},
    {"id":3,"role":"AXGroup","children":[]}
  ]
}
JSON
jq -e '(.nodes | length) == 2 and .nodes[1].role == "AXButton"' "${last_ax_inspect}" >/dev/null ||
  fail "AX inspect did not preserve the first immutable snapshot"

run_ax_inspect_success relaykit-ax-single-snapshot-second-read-different 4611 83 <<'JSON'
{
  "current_identity":{"pid":4611,"window_id":83},"process_running":true,
  "bundle_identifier":"dev.relaykit.app","frontmost_pid":null,"accessibility_trusted":true,
  "windows":[{"owner_pid":4611,"window_id":83,"layer":25}],
  "ax_windows_available":true,"ax_window_numbers":[83],"ax_window_node_ids":[1],"root_id":0,
  "expected_max_children_reads":1,
  "nodes":[
    {"id":0,"role":"AXApplication","children":[1]},
    {"id":1,"role":"AXWindow","window_number":83,"children":[2],"second_children":[3],
     "second_children_status":"success","second_children_value":"array"},
    {"id":2,"role":"AXRow","identifier":"official-provider-row","children":[]},
    {"id":3,"role":"AXGroup","children":[]}
  ]
}
JSON
jq -e '(.nodes | length) == 2 and .nodes[1].role == "AXRow" and .semantic_identifier_count == 1' \
  "${last_ax_inspect}" >/dev/null || fail "AX inspect diagnostic drifted from its verified snapshot"

run_ax_inspect_success relaykit-ax-no-value-leaf 4612 84 <<'JSON'
{
  "current_identity":{"pid":4612,"window_id":84},"process_running":true,
  "bundle_identifier":"dev.relaykit.app","frontmost_pid":null,"accessibility_trusted":true,
  "windows":[{"owner_pid":4612,"window_id":84,"layer":25}],
  "ax_windows_available":true,"ax_window_numbers":[84],"ax_window_node_ids":[1],"root_id":0,
  "expected_max_children_reads":1,
  "nodes":[
    {"id":0,"role":"AXApplication","children":[1]},
    {"id":1,"role":"AXWindow","window_number":84,"children":[2]},
    {"id":2,"role":"AXButton","identifier":"provider-add-entry","children_status":"noValue","children":[]}
  ]
}
JSON
jq -e '.nodes[1].child_count == 0 and .truncated == false' "${last_ax_inspect}" >/dev/null ||
  fail "AX inspect rejected an explicit noValue leaf"

run_ax_inspect_failure relaykit_semantic_traversal_incomplete relaykit-ax-first-read-error 4613 85 <<'JSON'
{
  "current_identity":{"pid":4613,"window_id":85},"process_running":true,
  "bundle_identifier":"dev.relaykit.app","frontmost_pid":null,"accessibility_trusted":true,
  "windows":[{"owner_pid":4613,"window_id":85,"layer":25}],
  "ax_windows_available":true,"ax_window_numbers":[85],"ax_window_node_ids":[1],"root_id":0,
  "expected_max_children_reads":1,
  "nodes":[
    {"id":0,"role":"AXApplication","children":[1]},
    {"id":1,"role":"AXWindow","window_number":85,"identifier":"provider-add-entry",
     "children_status":"cannotComplete","children":[]}
  ]
}
JSON

ax_inspect_truncated_metadata="${tmp_dir}/relaykit-ax-truncated-snapshot.json"
jq -n '{
  current_identity:{pid:4614,window_id:86},process_running:true,
  bundle_identifier:"dev.relaykit.app",frontmost_pid:null,accessibility_trusted:true,
  windows:[{owner_pid:4614,window_id:86,layer:25}],
  ax_windows_available:true,ax_window_numbers:[86],ax_window_node_ids:[0],root_id:0,
  expected_max_children_reads:1,
  nodes:[range(0;14) as $id | {
    id:$id,role:(if $id == 0 then "AXWindow" else "AXGroup" end),
    window_number:(if $id == 0 then 86 else null end),
    identifier:(if $id == 1 then "provider-add-entry" else null end),
    children:(if $id < 13 then [$id + 1] else [] end)
  }]
}' >"${ax_inspect_truncated_metadata}"
run_ax_inspect_failure relaykit_semantic_traversal_incomplete \
  relaykit-ax-truncated-snapshot 4614 86 <"${ax_inspect_truncated_metadata}"

run_ax_inspect_failure relaykit_semantic_node_missing relaykit-ax-no-semantic 4602 52 <<'JSON'
{
  "current_identity":{"pid":4602,"window_id":52},"process_running":true,
  "bundle_identifier":"dev.relaykit.app","frontmost_pid":null,"accessibility_trusted":true,
  "windows":[{"owner_pid":4602,"window_id":52,"layer":25}],
  "ax_windows_available":true,"ax_windows_count":1,
  "ax_window_numbers":[52],"ax_window_node_ids":[1],"root_id":0,
  "nodes":[
    {"id":0,"role":"AXApplication","children":[1]},
    {"id":1,"role":"AXWindow","window_number":52,"children":[2]},
    {"id":2,"role":"AXButton","identifier":"unrelated-control","children":[]}
  ]
}
JSON
jq -e '.candidate_count == 0' "${last_stdout}" >/dev/null ||
  fail "AX inspect no-semantic failure lost candidate count 0"

run_ax_inspect_failure window_selector_not_unique relaykit-ax-multiple-exact 4603 62 <<'JSON'
{
  "current_identity":{"pid":4603,"window_id":62},"process_running":true,
  "bundle_identifier":"dev.relaykit.app","frontmost_pid":null,"accessibility_trusted":true,
  "windows":[{"owner_pid":4603,"window_id":62,"layer":25}],
  "ax_windows_available":true,"ax_windows_count":2,
  "ax_window_numbers":[62,62],"ax_window_node_ids":[1,2],"root_id":0,
  "nodes":[
    {"id":0,"role":"AXApplication","children":[1,2]},
    {"id":1,"role":"AXWindow","window_number":62,"identifier":"provider-add-entry","children":[]},
    {"id":2,"role":"AXWindow","window_number":62,"identifier":"official-provider-row","children":[]}
  ]
}
JSON
jq -e '.candidate_count == 2' "${last_stdout}" >/dev/null ||
  fail "AX inspect multiple exact windows lost actual candidate count"

run_ax_inspect_failure relaykit_semantic_traversal_incomplete relaykit-ax-malformed-tree 4604 72 <<'JSON'
{
  "current_identity":{"pid":4604,"window_id":72},"process_running":true,
  "bundle_identifier":"dev.relaykit.app","frontmost_pid":null,"accessibility_trusted":true,
  "windows":[{"owner_pid":4604,"window_id":72,"layer":25}],
  "ax_windows_available":true,"ax_windows_count":1,
  "ax_window_numbers":[72],"ax_window_node_ids":[1],"root_id":0,
  "nodes":[
    {"id":0,"role":"AXApplication","children":[1]},
    {"id":1,"role":"AXWindow","window_number":72,"identifier":"provider-add-entry",
     "children_status":"success","children_value":"malformed","children":[2]},
    {"id":2,"role":"AXButton","children":[]}
  ]
}
JSON
diagnostic_source_body="$(
  sed -n '/private func relayKitAXChildren/,/private func relayKitSemanticBinding(root/p' "${SOURCE}"
  sed -n '/private struct AXDiagnosticNodeRecord/,/private func executeInspect/p' "${SOURCE}"
)"
for forbidden_attribute in \
  kAXTitleAttribute kAXDescriptionAttribute kAXHelpAttribute kAXValueAttribute \
  AXIdentifier AXLabel AXPlaceholderValue AXURL AXDocument NSPasteboard CGWindowBounds; do
  if rg -Fq "${forbidden_attribute}" <<<"${diagnostic_source_body}"; then
    fail "AX inspect queried or serialized forbidden detail: ${forbidden_attribute}"
  fi
done
for required_attribute in kAXRoleAttribute kAXSubroleAttribute kAXChildrenAttribute axWindowNumber; do
  rg -Fq "${required_attribute}" <<<"${diagnostic_source_body}" ||
    fail "AX inspect omitted required structural attribute: ${required_attribute}"
done
diagnostic_execution_body="$(sed -n '/private func executeRelayKitAXInspect/,/private func executeInspect/p' "${SOURCE}")"
test "$(rg -c 'captureVerifiedRelayKitAXInspectSnapshot' <<<"${diagnostic_execution_body}")" -eq 1 ||
  fail "AX inspect must capture exactly one verified immutable snapshot"
grep -Fq 'makeAXDiagnosticReport(snapshot: snapshot)' <<<"${diagnostic_execution_body}" ||
  fail "AX inspect report must derive only from the verified snapshot"
if rg -Fq 'verifyBoundWindow' <<<"${diagnostic_execution_body}"; then
  fail "AX inspect retained the old binding traversal before snapshot capture"
fi
if rg -Fq 'AXUIElementCreateApplication(context.pid)' <<<"${diagnostic_execution_body}"; then
  test "$(rg -Fc 'AXUIElementCreateApplication(context.pid)' <<<"${diagnostic_execution_body}")" -eq 1 ||
    fail "AX inspect queried the AX application more than once"
fi
snapshot_capture_body="$(sed -n '/private func captureVerifiedRelayKitAXInspectSnapshot/,/private func makeAXDiagnosticReport/p' "${SOURCE}")"
test "$(rg -Fc 'let nodeChildren = children(node)' <<<"${snapshot_capture_body}")" -eq 1 ||
  fail "AX inspect snapshot must contain one children read site"
snapshot_report_body="$(sed -n '/private func makeAXDiagnosticReport/,/private func writeAtomicPrivateJSON/p' "${SOURCE}")"
for forbidden_report_text in AXUIElementCopyAttributeValue 'children(' 'identifier(' 'windowNumber(' 'role(' 'subrole('; do
  if rg -Fq "${forbidden_report_text}" <<<"${snapshot_report_body}"; then
    fail "AX inspect report performed a live read: ${forbidden_report_text}"
  fi
done
grep -Fq 'maximumAXDiagnosticDepth = 12' "${SOURCE}" || fail "AX inspect depth bound changed"
grep -Fq 'maximumAXDiagnosticNodes = 512' "${SOURCE}" || fail "AX inspect node bound changed"

bound_window_test_body="$(sed -n '/private func executeBoundWindowTest/,/^}/p' "${SOURCE}")"
test "$(rg -c 'resolveBoundActionRoot' <<<"${bound_window_test_body}")" -eq 1 ||
  fail "dynamic tests must enter the production shared full resolver exactly once"
if rg -Fq 'verifyWindowServerIdentity' <<<"${bound_window_test_body}"; then
  fail "dynamic tests must not assemble a partial WindowServer-only resolver"
fi
test "$(rg -c 'normalizedAXWindows' <<<"${bound_window_test_body}")" -eq 1 ||
  fail "dynamic tests must use the production AXWindows normalizer exactly once"

bound_window_production_body="$(sed -n '/private func verifyBoundWindow/,/private struct SemanticRecord/p' "${SOURCE}")"
grep -Fq 'NSWorkspace.shared.frontmostApplication?.processIdentifier' <<<"${bound_window_production_body}" ||
  fail "normal production resolution must use the real NSWorkspace frontmost application"
grep -Fq 'resolveBoundActionRoot' <<<"${bound_window_production_body}" ||
  fail "normal production resolution must enter the shared full resolver"
grep -Fq 'normalizedAXWindows' <<<"${bound_window_production_body}" ||
  fail "normal production resolution must use the shared AXWindows normalizer"

relaykit_binding_body="$(sed -n '/private let maximumRelayKitSemanticDepth/,/private func verifyBoundWindow/p' "${SOURCE}")"
grep -Fq 'maximumRelayKitSemanticDepth = 12' "${SOURCE}" ||
  fail "RelayKit semantic binding depth must remain 12"
grep -Fq 'maximumRelayKitSemanticNodes = 512' "${SOURCE}" ||
  fail "RelayKit semantic binding node limit must remain 512"
for required_binding_text in kAXWindowRole axIdentifierAttribute provider-add-entry official-provider-row kAXChildrenAttribute identical; do
  rg -Fq "${required_binding_text}" <<<"${relaykit_binding_body}" ||
    fail "RelayKit exact AXWindow binding is missing ${required_binding_text}"
done
grep -Fq 'AXUIElementCopyAttributeValue' <<<"${relaykit_binding_body}" ||
  fail "production RelayKit children provider must preserve AX query status"
for required_children_normalizer_text in 'case .success' 'case .noValue'; do
  rg -Fq "${required_children_normalizer_text}" <<<"${relaykit_binding_body}" ||
    fail "production RelayKit children normalizer is missing ${required_children_normalizer_text}"
done
if rg -F 'kAXChildrenAttribute' <<<"${relaykit_binding_body}" | rg -Fq '?? []'; then
  fail "production RelayKit children provider collapsed query failure into an empty leaf"
fi
grep -Fq 'CFEqual' <<<"${relaykit_binding_body}" ||
  fail "production RelayKit semantic traversal is not cycle-safe by AX identity"
for forbidden_binding_text in \
  kAXTitleAttribute kAXDescriptionAttribute kAXHelpAttribute kAXValueAttribute \
  AXLabel AXPlaceholderValue kAXPositionAttribute kAXSizeAttribute AXPopover \
  CGWindowBounds localizedCaseInsensitiveContains localizedStandardContains 'range(of:'; do
  if rg -Fq "${forbidden_binding_text}" <<<"${relaykit_binding_body}"; then
    fail "RelayKit exact AXWindow binding used a weak selector: ${forbidden_binding_text}"
  fi
done
grep -Fq 'collectAXNodes(from: bound.window)' "${SOURCE}" ||
  fail "semantic search must remain scoped to the rebound action root"

run_success "${self_test[@]}" --scenario exact
jq -e '.candidate_count == 1' "${last_stdout}" >/dev/null ||
  fail "exact selector did not ignore a substring-only distractor"

run_failure selector_not_unique "${self_test[@]}" --scenario zero
jq -e '.candidate_count == 0' "${last_stdout}" >/dev/null ||
  fail "zero-candidate selector failure did not report count 0"

run_failure selector_not_unique "${self_test[@]}" --scenario multiple
jq -e '.candidate_count == 2' "${last_stdout}" >/dev/null ||
  fail "multiple-candidate selector failure did not report count 2"

run_success "${self_test[@]}" --scenario reveal-exact
jq -e '.candidate_count == 1' "${last_stdout}" >/dev/null ||
  fail "Markdown reveal did not select one exact heading"

run_failure selector_not_unique "${self_test[@]}" --scenario reveal-multiple
jq -e '.candidate_count == 2' "${last_stdout}" >/dev/null ||
  fail "Markdown reveal did not fail closed on duplicate headings"

run_success "${self_test[@]}" --scenario window-fallback
jq -e '.candidate_count == 1' "${last_stdout}" >/dev/null ||
  fail "single CGWindow plus single AXWindow did not produce the bounded window fallback"

run_failure window_selector_not_unique "${self_test[@]}" --scenario window-ambiguous
jq -e '.candidate_count == 2' "${last_stdout}" >/dev/null ||
  fail "multiple unnumbered AX windows did not fail closed"

run_success "${self_test[@]}" --scenario model-ui-labels
jq -e '.candidate_count == 1' "${last_stdout}" >/dev/null ||
  fail "Codex model UI label projection did not select one exact picker"

run_success "${self_test[@]}" --scenario send-structure
jq -e '.candidate_count == 1' "${last_stdout}" >/dev/null ||
  fail "composer-local send structure did not select one exact button"

run_success "${self_test[@]}" --scenario composer-value
jq -e '.candidate_count == 1' "${last_stdout}" >/dev/null ||
  fail "composer value normalization did not preserve internal content"

run_success "${self_test[@]}" --scenario empty-composer
jq -e '.candidate_count == 1' "${last_stdout}" >/dev/null ||
  fail "Codex placeholder-backed empty composer was not recognized exactly"

for missing_scenario in protocol-identifier-distractors protocol-identifier-zero; do
  run_failure relaykit_protocol_identifier_missing "${self_test[@]}" --scenario "${missing_scenario}"
  jq -e '.candidate_count == 0' "${last_stdout}" >/dev/null ||
    fail "${missing_scenario} did not report exact identifier count 0"
done

run_failure relaykit_protocol_identifier_multiple \
  "${self_test[@]}" --scenario protocol-identifier-multiple
jq -e '.candidate_count == 2' "${last_stdout}" >/dev/null ||
  fail "duplicate protocol identifiers did not report exact count 2"

for disabled_scenario in \
  protocol-identifier-disabled-false \
  protocol-identifier-disabled-missing \
  protocol-identifier-disabled-malformed \
  protocol-identifier-disabled-unreadable; do
  run_failure relaykit_protocol_identifier_disabled "${self_test[@]}" --scenario "${disabled_scenario}"
  jq -e '.candidate_count == 1' "${last_stdout}" >/dev/null ||
    fail "${disabled_scenario} did not preserve exact identifier count 1"
done

run_success "${self_test[@]}" --scenario protocol-same-node-success
jq -e '.candidate_count == 1' "${last_stdout}" >/dev/null ||
  fail "same-node protocol value did not verify exactly one identifier"

run_success "${self_test[@]}" --scenario protocol-values-both-expected
run_success "${self_test[@]}" --scenario protocol-selected-value-success

for conflict_scenario in \
  protocol-value-conflict-value-expected \
  protocol-value-conflict-selected-expected; do
  run_failure relaykit_protocol_value_conflict "${self_test[@]}" --scenario "${conflict_scenario}"
  jq -e '.candidate_count == 1' "${last_stdout}" >/dev/null ||
    fail "${conflict_scenario} did not preserve exact identifier count 1"
done

for malformed_scenario in \
  protocol-value-expected-selected-malformed \
  protocol-value-expected-selected-unreadable; do
  run_failure relaykit_protocol_value_not_verified "${self_test[@]}" --scenario "${malformed_scenario}"
done

run_failure relaykit_protocol_value_split "${self_test[@]}" --scenario protocol-value-split
jq -e '.candidate_count == 1' "${last_stdout}" >/dev/null ||
  fail "split protocol value did not preserve exact identifier count 1"

for unverified_scenario in \
  protocol-value-not-verified \
  protocol-value-unreadable \
  protocol-value-split-unreadable \
  protocol-traversal-truncated; do
  run_failure relaykit_protocol_value_not_verified "${self_test[@]}" --scenario "${unverified_scenario}"
  jq -e '.candidate_count == 1' "${last_stdout}" >/dev/null ||
    fail "${unverified_scenario} did not preserve exact identifier count 1"
done

query_file="${tmp_dir}/query.txt"
printf '%s\n' 'RELAYKIT_PRIVATE_QUERY_SENTINEL' >"${query_file}"
chmod 644 "${query_file}"
run_failure query_file_permissions \
  "${self_test[@]}" --scenario query-permissions --query-file "${query_file}"

chmod 600 "${query_file}"
run_success "${self_test[@]}" --scenario query-permissions --query-file "${query_file}"
if rg -Fq 'RELAYKIT_PRIVATE_QUERY_SENTINEL' "${last_stdout}"; then
  fail "query content leaked through self-test output"
fi

query_link="${tmp_dir}/query-link.txt"
ln -s "${query_file}" "${query_link}"
run_failure query_file_not_regular \
  "${self_test[@]}" --scenario query-permissions --query-file "${query_link}"

catalog_file="${tmp_dir}/catalog.json"
printf '%s\n' '["Official GPT-5.5","Official GPT-5.5 Extended"]' >"${catalog_file}"
chmod 644 "${catalog_file}"
run_failure catalog_file_permissions \
  "${self_test[@]}" --scenario catalog-exact \
  --catalog-labels-file "${catalog_file}" --model-label "Official GPT-5.5"

chmod 600 "${catalog_file}"
run_success "${self_test[@]}" --scenario catalog-exact \
  --catalog-labels-file "${catalog_file}" --model-label "Official GPT-5.5"
jq -e '.candidate_count == 1' "${last_stdout}" >/dev/null ||
  fail "catalog exact selector did not ignore a longer label"

run_failure model_label_not_in_catalog \
  "${self_test[@]}" --scenario catalog-exact \
  --catalog-labels-file "${catalog_file}" --model-label "Official GPT"

printf '%s\n' '{"labels":["Official GPT-5.5"]}' >"${catalog_file}"
chmod 600 "${catalog_file}"
run_failure catalog_file_invalid \
  "${self_test[@]}" --scenario catalog-exact \
  --catalog-labels-file "${catalog_file}" --model-label "Official GPT-5.5"

for forbidden in \
  NSPasteboard \
  pbcopy \
  CGEventCreate \
  CGEventPost \
  kAXPositionAttribute \
  kAXSizeAttribute \
  AXValueCreate \
  localizedCaseInsensitiveContains \
  localizedStandardContains \
  CryptoKit \
  CC_SHA256 \
  shasum; do
  if rg -Fq "${forbidden}" "${SOURCE}"; then
    fail "driver uses forbidden API or matching strategy: ${forbidden}"
  fi
done

if rg -q 'range\(of:' "${SOURCE}"; then
  fail "driver must not select AX elements by substring range"
fi

test "$(rg -c 'AXUIElementPerformAction' "${SOURCE}")" -eq 1 ||
  fail "all AX actions must pass through one verified action boundary"
test "$(rg -c 'AXUIElementSetAttributeValue' "${SOURCE}")" -eq 1 ||
  fail "all composer writes must pass through one verified mutation boundary"

prepare_body="$(sed -n '/private func executePrepare/,/private func executeSubmit/p' "${SOURCE}")"
if rg -Fq 'if composerMatches.isEmpty' <<<"${prepare_body}"; then
  fail "prepare must always open a fresh workspace task instead of reusing an existing composer"
fi
test "$(rg -c 'workspaceOpenerSelector' <<<"${prepare_body}")" -eq 1 ||
  fail "prepare must open exactly one fresh workspace task"
grep -Fq 'waitForFreshComposer' <<<"${prepare_body}" ||
  fail "prepare must wait for a new composer identity after opening a fresh task"
grep -Fq 'CFEqual' "${SOURCE}" ||
  fail "fresh-task preparation must compare the old and new composer identities"
grep -Fq 'semanticSnapshot' "${SOURCE}" ||
  fail "fresh-task preparation must detect a semantic tree transition when Chromium reuses AX nodes"
grep -Fq 'composerIsEmpty(' "${SOURCE}" ||
  fail "the bounded Chromium fallback must require one empty writable composer"
grep -Fq 'placeholder: copyAXString(candidate, axPlaceholderValueAttribute)' "${SOURCE}" ||
  fail "placeholder-backed empty composers must use the element's exact AX placeholder"
grep -Fq '"\n随心输入"' "${SOURCE}" ||
  fail "Codex 150 localized AX empty-composer sentinel must be matched exactly"
grep -Fq 'actual == expected.replacingOccurrences(of: "\n", with: " ")' "${SOURCE}" ||
  fail "multiline composer readback must allow only Chromium's one-for-one LF flattening"

submit_body="$(sed -n '/private func executeSubmit/,/private func relayKitIdentifierSelector/p' "${SOURCE}")"
test "$(rg -c 'waitForUniqueApplicationOverlaySelector' <<<"${submit_body}")" -eq 2 ||
  fail "only the two native model-menu selectors may use the application overlay"
test "$(rg -c 'applicationOverlayNode' <<<"${submit_body}")" -eq 2 ||
  fail "native model-menu presses must resolve exact same-PID overlay nodes"

for relaykit_command in relaykit-provider-configure relaykit-provider-protocol-probe relaykit-provider-verify relaykit-gateway-start; do
  rg -Fq "${relaykit_command}" "${SOURCE}" ||
    fail "driver is missing concrete RelayKit action ${relaykit_command}"
done
rg -Fq 'dev.relaykit.app' "${SOURCE}" || fail "RelayKit AX actions must bind the exact App bundle identity"
rg -Fq 'provider-provider-name-field' "${SOURCE}" || fail "provider setup must use the exact name field identifier"
rg -Fq 'provider-api-base-url-field' "${SOURCE}" || fail "provider setup must use the exact URL field identifier"
rg -Fq 'api-key-new-input-field' "${SOURCE}" || fail "provider setup must use the exact key field identifier"
rg -Fq 'provider-model-id-field' "${SOURCE}" || fail "provider setup must use the exact model field identifier"
rg -Fq 'provider-upstream-protocol-option-openai_responses' "${SOURCE}" || fail "provider setup must select the exact Responses option"
rg -Fq 'verifyRelayKitProtocolSelection' "${SOURCE}" || fail "provider setup must classify the post-selection protocol state"
rg -Fq 'axIdentifierAttribute' "${SOURCE}" || fail "protocol verification must read the exact AXIdentifier attribute"
draft_helper_body="$(sed -n '/private func performRelayKitProviderDraftSelection/,/^}/p' "${SOURCE}")"
configure_body="$(sed -n '/private func executeRelayKitProviderConfigure/,/^}/p' "${SOURCE}")"
probe_body="$(sed -n '/private func executeRelayKitProviderProtocolProbe/,/^}/p' "${SOURCE}")"
rg -Fq 'relaykit-provider-protocol-probe' "${SOURCE}" || fail "driver is missing the protocol probe command"
[[ "$(rg -c 'case relayKitProviderProtocolProbe = ' "${SOURCE}")" -eq 1 ]] || fail "driver must define exactly one new command"
[[ "$(wc -l <<<"${draft_helper_body}" | tr -d ' ')" -le 90 ]] || fail "shared draft selection helper exceeds 90 lines"
[[ "$(rg -c 'provider-form-save' "${SOURCE}")" -eq 1 ]] || fail "production must contain exactly one literal provider-form-save"
for forbidden_downstream_text in provider-form-save relaykit-provider-configure relaykit-provider-verify relaykit-gateway-start executeRelayKitProviderConfigure executeRelayKitProviderVerify executeRelayKitGatewayStart provider-saved-key-state gateway-start; do
  for pre_save_body in "${draft_helper_body}" "${probe_body}"; do
    ! rg -Fq "${forbidden_downstream_text}" <<<"${pre_save_body}" || fail "helper or probe crossed into ${forbidden_downstream_text}"
  done
done
[[ "$(rg -c 'performRelayKitProviderDraftSelection' <<<"${configure_body}")" -eq 1 ]] ||
  fail "provider configure must call the shared draft selection helper once"
[[ "$(rg -c 'performRelayKitProviderDraftSelection' <<<"${probe_body}")" -eq 1 ]] ||
  fail "protocol probe must call the shared draft selection helper once"
[[ "$(rg -c 'provider-form-save' <<<"${configure_body}")" -eq 1 ]] ||
  fail "provider configure must retain exactly one Save action"
rg -Uq 'performRelayKitProviderDraftSelection(.|\n)*provider-form-save' <<<"${configure_body}" ||
  fail "provider configure must call the shared helper before Save"
if rg -Fq 'waitForRelayKitSemantic(' <<<"${configure_body}"; then
  fail "provider configure must not verify protocol selection through merged semantic strings"
fi
rg -Fq 'provider-saved-key-state' "${SOURCE}" || fail "relaunch verification must require the saved-key UI state"
rg -Fq 'gateway-start' "${SOURCE}" || fail "gateway start must use the exact App control"

for required_source_text in \
  'performVerifiedPress' \
  'performVerifiedWrite' \
  'verifyBoundWindow' \
  'AXWindowNumber' \
  'New task in \(workspace)' \
  '在 \(workspace) 中新建任务' \
  '"Send"' \
  '"发送"'; do
  rg -Fq "${required_source_text}" "${SOURCE}" ||
    fail "driver source is missing required deterministic behavior: ${required_source_text}"
done

printf '%s\n' "Codex Desktop AX driver tests passed"
