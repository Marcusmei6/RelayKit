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

relaykit_layer25_other_frontmost_metadata='{
  "current_identity": {"pid":4201,"window_id":42},
  "process_running": true,
  "bundle_identifier": "dev.relaykit.app",
  "frontmost_pid": 9999,
  "accessibility_trusted": true,
  "windows": [
    {"owner_pid":4201,"window_id":41,"layer":0},
    {"owner_pid":4201,"window_id":42,"layer":25},
    {"owner_pid":9999,"window_id":42,"layer":0}
  ],
  "ax_window_numbers": [42,null]
}'
relaykit_layer25_nil_frontmost_metadata='{
  "current_identity": {"pid":4201,"window_id":42},
  "process_running": true,
  "bundle_identifier": "dev.relaykit.app",
  "frontmost_pid": null,
  "accessibility_trusted": true,
  "windows": [
    {"owner_pid":4201,"window_id":41,"layer":0},
    {"owner_pid":4201,"window_id":42,"layer":25},
    {"owner_pid":9999,"window_id":42,"layer":0}
  ],
  "ax_window_numbers": [42,null]
}'
for relaykit_command in relaykit-provider-configure relaykit-provider-verify relaykit-gateway-start; do
  for frontmost_case in other nil; do
    case "${frontmost_case}" in
      other) relaykit_metadata="${relaykit_layer25_other_frontmost_metadata}" ;;
      nil) relaykit_metadata="${relaykit_layer25_nil_frontmost_metadata}" ;;
    esac
    case "${relaykit_command}" in
      relaykit-provider-configure)
        run_bound_window_success \
          "${relaykit_command}-layer25-${frontmost_case}-frontmost" "${relaykit_command}" 4201 42 \
          "${relaykit_configure_options[@]}" <<<"${relaykit_metadata}"
        ;;
      relaykit-provider-verify)
        run_bound_window_success \
          "${relaykit_command}-layer25-${frontmost_case}-frontmost" "${relaykit_command}" 4201 42 \
          "${relaykit_verify_options[@]}" <<<"${relaykit_metadata}"
        ;;
      relaykit-gateway-start)
        run_bound_window_success \
          "${relaykit_command}-layer25-${frontmost_case}-frontmost" "${relaykit_command}" 4201 42 \
          <<<"${relaykit_metadata}"
        ;;
    esac
  done
done

run_bound_window_success relaykit-unnumbered-fallback relaykit-gateway-start 4202 52 <<'JSON'
{
  "current_identity": {"pid":4202,"window_id":52},
  "process_running": true,
  "bundle_identifier": "dev.relaykit.app",
  "frontmost_pid": null,
  "accessibility_trusted": true,
  "windows": [
    {"owner_pid":4202,"window_id":51,"layer":0},
    {"owner_pid":4202,"window_id":52,"layer":25},
    {"owner_pid":9999,"window_id":52,"layer":25}
  ],
  "ax_window_numbers": [null]
}
JSON

relaykit_empty_windows_single_popover_metadata='{
  "current_identity": {"pid":4203,"window_id":53},
  "process_running": true,
  "bundle_identifier": "dev.relaykit.app",
  "frontmost_pid": null,
  "accessibility_trusted": true,
  "windows": [{"owner_pid":4203,"window_id":53,"layer":25}],
  "ax_windows_available": true,
  "ax_windows_malformed": false,
  "ax_window_numbers": [],
  "ax_window_node_ids": [],
  "root_id": 0,
  "nodes": [
    {"id":0,"role":"AXApplication","children_status":"success","children":[1,2]},
    {"id":1,"role":"AXPopover","children_status":"success","children":[3]},
    {"id":2,"role":"AXButton","children_status":"noValue","children":[]},
    {"id":3,"role":"AXButton","children_status":"noValue","children":[]}
  ],
  "expected_action_root_id": 1,
  "semantic_target_ids": [2,3],
  "expected_semantic_target_count": 1
}'
for relaykit_command in relaykit-provider-configure relaykit-provider-verify relaykit-gateway-start; do
  case "${relaykit_command}" in
    relaykit-provider-configure)
      run_bound_window_success \
        "${relaykit_command}-empty-windows-single-popover" "${relaykit_command}" 4203 53 \
        "${relaykit_configure_options[@]}" <<<"${relaykit_empty_windows_single_popover_metadata}"
      ;;
    relaykit-provider-verify)
      run_bound_window_success \
        "${relaykit_command}-empty-windows-single-popover" "${relaykit_command}" 4203 53 \
        "${relaykit_verify_options[@]}" <<<"${relaykit_empty_windows_single_popover_metadata}"
      ;;
    relaykit-gateway-start)
      run_bound_window_success \
        "${relaykit_command}-empty-windows-single-popover" "${relaykit_command}" 4203 53 \
        <<<"${relaykit_empty_windows_single_popover_metadata}"
      ;;
  esac
  jq -e '.candidate_count == 1' "${last_stdout}" >/dev/null ||
    fail "${relaykit_command} did not bind exactly one RelayKit popover"
done

for children_failure_location in root below-popover sibling-after-popover; do
  for children_failure_kind in cannotComplete malformed; do
    if [[ "${children_failure_kind}" == "malformed" ]]; then
      children_failure_status=success
      children_failure_value=',"children_value":"malformed"'
    else
      children_failure_status="${children_failure_kind}"
      children_failure_value=''
    fi
    case "${children_failure_location}" in
      root)
        children_failure_nodes='[
          {"id":0,"role":"AXApplication","children_status":"'"${children_failure_status}"'"'"${children_failure_value}"',"children":[1]},
          {"id":1,"role":"AXPopover","children_status":"success","children":[]}
        ]'
        expected_children_failure_count=0
        ;;
      below-popover)
        children_failure_nodes='[
          {"id":0,"role":"AXApplication","children_status":"success","children":[1]},
          {"id":1,"role":"AXPopover","children_status":"'"${children_failure_status}"'"'"${children_failure_value}"',"children":[2]},
          {"id":2,"role":"AXButton","children_status":"success","children":[]}
        ]'
        expected_children_failure_count=1
        ;;
      sibling-after-popover)
        children_failure_nodes='[
          {"id":0,"role":"AXApplication","children_status":"success","children":[1,2]},
          {"id":1,"role":"AXPopover","children_status":"success","children":[]},
          {"id":2,"role":"AXGroup","children_status":"'"${children_failure_status}"'"'"${children_failure_value}"',"children":[3]},
          {"id":3,"role":"AXButton","children_status":"success","children":[]}
        ]'
        expected_children_failure_count=1
        ;;
    esac
    run_bound_window_failure window_selector_not_unique \
      "relaykit-children-${children_failure_location}-${children_failure_kind}" \
      relaykit-gateway-start 4212 64 <<JSON
{
  "current_identity":{"pid":4212,"window_id":64},"process_running":true,
  "bundle_identifier":"dev.relaykit.app","frontmost_pid":null,"accessibility_trusted":true,
  "windows":[{"owner_pid":4212,"window_id":64,"layer":25}],
  "ax_windows_available":true,"ax_windows_malformed":false,"ax_window_numbers":[],
  "ax_window_node_ids":[],"root_id":0,"nodes":${children_failure_nodes}
}
JSON
    jq -e --argjson count "${expected_children_failure_count}" \
      '.candidate_count == $count' "${last_stdout}" >/dev/null ||
      fail "${children_failure_location} ${children_failure_kind} children did not fail closed"
  done
done

run_bound_window_success relaykit-children-success-empty relaykit-gateway-start 4213 65 <<'JSON'
{
  "current_identity":{"pid":4213,"window_id":65},"process_running":true,
  "bundle_identifier":"dev.relaykit.app","frontmost_pid":null,"accessibility_trusted":true,
  "windows":[{"owner_pid":4213,"window_id":65,"layer":25}],
  "ax_windows_available":true,"ax_windows_malformed":false,"ax_window_numbers":[],
  "ax_window_node_ids":[],"root_id":0,
  "nodes":[
    {"id":0,"role":"AXApplication","children_status":"success","children":[1]},
    {"id":1,"role":"AXPopover","children_status":"success","children":[]}
  ],
  "expected_action_root_id":1
}
JSON

run_bound_window_success relaykit-children-no-value-leaf relaykit-gateway-start 4214 66 <<'JSON'
{
  "current_identity":{"pid":4214,"window_id":66},"process_running":true,
  "bundle_identifier":"dev.relaykit.app","frontmost_pid":null,"accessibility_trusted":true,
  "windows":[{"owner_pid":4214,"window_id":66,"layer":25}],
  "ax_windows_available":true,"ax_windows_malformed":false,"ax_window_numbers":[],
  "ax_window_node_ids":[],"root_id":0,
  "nodes":[
    {"id":0,"role":"AXApplication","children_status":"success","children":[1]},
    {"id":1,"role":"AXPopover","children_status":"noValue","children_value":"malformed","children":[99]}
  ],
  "expected_action_root_id":1
}
JSON

for failing_children_status in attributeUnsupported invalidUIElement failure; do
  run_bound_window_failure window_selector_not_unique \
    "relaykit-children-status-${failing_children_status}" relaykit-gateway-start 4215 67 <<JSON
{
  "current_identity":{"pid":4215,"window_id":67},"process_running":true,
  "bundle_identifier":"dev.relaykit.app","frontmost_pid":null,"accessibility_trusted":true,
  "windows":[{"owner_pid":4215,"window_id":67,"layer":25}],
  "ax_windows_available":true,"ax_windows_malformed":false,"ax_window_numbers":[],
  "ax_window_node_ids":[],"root_id":0,
  "nodes":[
    {"id":0,"role":"AXApplication","children_status":"${failing_children_status}","children":[1]},
    {"id":1,"role":"AXPopover","children_status":"noValue","children":[]}
  ]
}
JSON
  jq -e '.candidate_count == 0' "${last_stdout}" >/dev/null ||
    fail "${failing_children_status} children status did not fail closed"
done

run_bound_window_failure window_selector_not_unique \
  relaykit-children-success-missing relaykit-gateway-start 4216 68 <<'JSON'
{
  "current_identity":{"pid":4216,"window_id":68},"process_running":true,
  "bundle_identifier":"dev.relaykit.app","frontmost_pid":null,"accessibility_trusted":true,
  "windows":[{"owner_pid":4216,"window_id":68,"layer":25}],
  "ax_windows_available":true,"ax_windows_malformed":false,"ax_window_numbers":[],
  "ax_window_node_ids":[],"root_id":0,
  "nodes":[
    {"id":0,"role":"AXApplication","children_status":"success","children_value":"missing","children":[1]},
    {"id":1,"role":"AXPopover","children_status":"noValue","children":[]}
  ]
}
JSON
jq -e '.candidate_count == 0' "${last_stdout}" >/dev/null ||
  fail "success with missing children value did not fail closed"

run_bound_window_failure window_selector_not_unique relaykit-empty-windows-zero-popovers relaykit-gateway-start 4204 54 <<'JSON'
{
  "current_identity":{"pid":4204,"window_id":54},"process_running":true,
  "bundle_identifier":"dev.relaykit.app","frontmost_pid":null,"accessibility_trusted":true,
  "windows":[{"owner_pid":4204,"window_id":54,"layer":25}],
  "ax_windows_available":true,"ax_windows_malformed":false,"ax_window_numbers":[],
  "ax_window_node_ids":[],"root_id":0,
  "nodes":[{"id":0,"role":"AXApplication","children":[1]},{"id":1,"role":"AXGroup","children":[]}]
}
JSON
jq -e '.candidate_count == 0' "${last_stdout}" >/dev/null ||
  fail "zero RelayKit popovers did not report count 0"

run_bound_window_failure window_selector_not_unique relaykit-empty-windows-two-popovers relaykit-gateway-start 4205 55 <<'JSON'
{
  "current_identity":{"pid":4205,"window_id":55},"process_running":true,
  "bundle_identifier":"dev.relaykit.app","frontmost_pid":null,"accessibility_trusted":true,
  "windows":[{"owner_pid":4205,"window_id":55,"layer":25}],
  "ax_windows_available":true,"ax_windows_malformed":false,"ax_window_numbers":[],
  "ax_window_node_ids":[],"root_id":0,
  "nodes":[
    {"id":0,"role":"AXApplication","children":[1,2]},
    {"id":1,"role":"AXPopover","children":[]},
    {"id":2,"role":"AXPopover","children":[]}
  ]
}
JSON
jq -e '.candidate_count == 2' "${last_stdout}" >/dev/null ||
  fail "multiple RelayKit popovers did not report the exact count"

run_bound_window_failure window_selector_not_unique relaykit-empty-windows-truncated relaykit-gateway-start 4206 56 <<'JSON'
{
  "current_identity":{"pid":4206,"window_id":56},"process_running":true,
  "bundle_identifier":"dev.relaykit.app","frontmost_pid":null,"accessibility_trusted":true,
  "windows":[{"owner_pid":4206,"window_id":56,"layer":25}],
  "ax_windows_available":true,"ax_windows_malformed":false,"ax_window_numbers":[],
  "ax_window_node_ids":[],"root_id":0,
  "nodes":[
    {"id":0,"role":"AXApplication","children":[1]},
    {"id":1,"role":"AXPopover","children":[2]},
    {"id":2,"role":"AXGroup","children":[3]},
    {"id":3,"role":"AXGroup","children":[4]},
    {"id":4,"role":"AXGroup","children":[5]},
    {"id":5,"role":"AXGroup","children":[6]},
    {"id":6,"role":"AXGroup","children":[7]},
    {"id":7,"role":"AXGroup","children":[8]},
    {"id":8,"role":"AXGroup","children":[9]},
    {"id":9,"role":"AXGroup","children":[10]},
    {"id":10,"role":"AXGroup","children":[11]},
    {"id":11,"role":"AXGroup","children":[12]},
    {"id":12,"role":"AXGroup","children":[13]},
    {"id":13,"role":"AXGroup","children":[14]},
    {"id":14,"role":"AXGroup","children":[]}
  ]
}
JSON
jq -e '.candidate_count == 1' "${last_stdout}" >/dev/null ||
  fail "truncated RelayKit traversal did not preserve the observed popover count"

run_bound_window_failure window_selector_not_unique relaykit-empty-windows-cycle relaykit-gateway-start 4207 57 <<'JSON'
{
  "current_identity":{"pid":4207,"window_id":57},"process_running":true,
  "bundle_identifier":"dev.relaykit.app","frontmost_pid":null,"accessibility_trusted":true,
  "windows":[{"owner_pid":4207,"window_id":57,"layer":25}],
  "ax_windows_available":true,"ax_windows_malformed":false,"ax_window_numbers":[],
  "ax_window_node_ids":[],"root_id":0,
  "nodes":[
    {"id":0,"role":"AXApplication","children":[1]},
    {"id":1,"role":"AXPopover","children":[0]}
  ]
}
JSON
jq -e '.candidate_count == 1' "${last_stdout}" >/dev/null ||
  fail "cycle-safe RelayKit traversal lost the observed popover count"

for unavailable_case in unavailable malformed; do
  if [[ "${unavailable_case}" == "unavailable" ]]; then
    ax_windows_available=false
    ax_windows_malformed=false
  else
    ax_windows_available=true
    ax_windows_malformed=true
  fi
  run_bound_window_failure window_selector_not_unique \
    "relaykit-ax-windows-${unavailable_case}" relaykit-gateway-start 4208 58 <<JSON
{
  "current_identity":{"pid":4208,"window_id":58},"process_running":true,
  "bundle_identifier":"dev.relaykit.app","frontmost_pid":null,"accessibility_trusted":true,
  "windows":[{"owner_pid":4208,"window_id":58,"layer":25}],
  "ax_windows_available":${ax_windows_available},"ax_windows_malformed":${ax_windows_malformed},
  "ax_window_numbers":[],"ax_window_node_ids":[],"root_id":0,
  "nodes":[{"id":0,"role":"AXApplication","children":[1]},{"id":1,"role":"AXPopover","children":[]}]
}
JSON
  jq -e '.candidate_count == 0' "${last_stdout}" >/dev/null ||
    fail "RelayKit ${unavailable_case} AX windows did not fail closed with count 0"
done

run_bound_window_success relaykit-nonempty-window-match relaykit-gateway-start 4209 59 <<'JSON'
{
  "current_identity":{"pid":4209,"window_id":59},"process_running":true,
  "bundle_identifier":"dev.relaykit.app","frontmost_pid":null,"accessibility_trusted":true,
  "windows":[{"owner_pid":4209,"window_id":59,"layer":25}],
  "ax_windows_available":true,"ax_windows_malformed":false,"ax_window_numbers":[59],
  "ax_window_node_ids":[2],"root_id":0,
  "nodes":[
    {"id":0,"role":"AXApplication","children":[1,2]},
    {"id":1,"role":"AXPopover","children":[]},
    {"id":2,"role":"AXWindow","children":[3]},
    {"id":3,"role":"AXButton","children":[]}
  ],
  "expected_action_root_id":2,"semantic_target_ids":[1,3],"expected_semantic_target_count":1
}
JSON
jq -e '.candidate_count == 1' "${last_stdout}" >/dev/null ||
  fail "nonempty matching AX window did not preserve the existing binding path"

for nonempty_case in mismatch ambiguous; do
  if [[ "${nonempty_case}" == "mismatch" ]]; then
    ax_window_numbers='[999]'
    ax_window_node_ids='[2]'
    expected_count=1
  else
    ax_window_numbers='[null,null]'
    ax_window_node_ids='[2,3]'
    expected_count=2
  fi
  run_bound_window_failure window_selector_not_unique \
    "relaykit-nonempty-${nonempty_case}-no-popover-fallback" relaykit-gateway-start 4210 60 <<JSON
{
  "current_identity":{"pid":4210,"window_id":60},"process_running":true,
  "bundle_identifier":"dev.relaykit.app","frontmost_pid":null,"accessibility_trusted":true,
  "windows":[{"owner_pid":4210,"window_id":60,"layer":25}],
  "ax_windows_available":true,"ax_windows_malformed":false,
  "ax_window_numbers":${ax_window_numbers},"ax_window_node_ids":${ax_window_node_ids},"root_id":0,
  "nodes":[
    {"id":0,"role":"AXApplication","children":[1,2,3]},
    {"id":1,"role":"AXPopover","children":[]},
    {"id":2,"role":"AXWindow","children":[]},
    {"id":3,"role":"AXWindow","children":[]}
  ]
}
JSON
  jq -e --argjson count "${expected_count}" '.candidate_count == $count' "${last_stdout}" >/dev/null ||
    fail "nonempty ${nonempty_case} AX windows did not fail without popover fallback"
done

run_bound_window_failure window_selector_not_unique desktop-empty-windows-popover inspect 4302 62 <<'JSON'
{
  "current_identity":{"pid":4302,"window_id":62},"process_running":true,
  "bundle_identifier":"com.openai.codex","frontmost_pid":4302,"accessibility_trusted":true,
  "windows":[{"owner_pid":4302,"window_id":62,"layer":0}],
  "ax_windows_available":true,"ax_windows_malformed":false,"ax_window_numbers":[],
  "ax_window_node_ids":[],"root_id":0,
  "nodes":[{"id":0,"role":"AXApplication","children":[1]},{"id":1,"role":"AXPopover","children":[]}]
}
JSON
jq -e '.candidate_count == 0' "${last_stdout}" >/dev/null ||
  fail "Desktop incorrectly used the RelayKit popover binding"

run_bound_window_failure window_selector_not_unique relaykit-application-root-popover relaykit-gateway-start 4211 63 <<'JSON'
{
  "current_identity":{"pid":4211,"window_id":63},"process_running":true,
  "bundle_identifier":"dev.relaykit.app","frontmost_pid":null,"accessibility_trusted":true,
  "windows":[{"owner_pid":4211,"window_id":63,"layer":25}],
  "ax_windows_available":true,"ax_windows_malformed":false,"ax_window_numbers":[],
  "ax_window_node_ids":[],"root_id":0,
  "nodes":[{"id":0,"role":"AXPopover","children":[]}]
}
JSON
jq -e '.candidate_count == 0' "${last_stdout}" >/dev/null ||
  fail "RelayKit application root was accepted as the action root"

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
jq -e '.candidate_count == 2' "${last_stdout}" >/dev/null ||
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
      "role_counts","status","truncated"
    ] and
    .status == "ok" and
    (.ax_windows_available | type == "boolean") and
    (.ax_windows_count | type == "number") and
    (.numbered_window_count | type == "number") and
    (.matching_window_count | type == "number") and
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

run_ax_inspect_success relaykit-ax-structure 4601 42 <<'JSON'
{
  "current_identity":{"pid":4601,"window_id":42},
  "process_running":true,
  "bundle_identifier":"dev.relaykit.app",
  "frontmost_pid":4601,
  "accessibility_trusted":true,
  "windows":[{"owner_pid":4601,"window_id":42,"layer":25}],
  "ax_windows_available":true,
  "ax_windows_count":2,
  "root_id":0,
  "nodes":[
    {"id":0,"role":"AXApplication","children":[1,2]},
    {"id":1,"role":"AXWindow","subrole":"AXStandardWindow","window_number":42,"children":[]},
    {"id":2,"role":"AXButton","subrole":null,"children":[],"sensitive_value":"RELAYKIT_PRIVATE_SENTINEL"}
  ]
}
JSON
jq -e '
  .ax_windows_available == true and .ax_windows_count == 2 and
  .numbered_window_count == 1 and .matching_window_count == 1 and
  .truncated == false and (.nodes | length) == 3 and
  .nodes[0] == {
    ordinal:0,parent:null,depth:0,role:"AXApplication",subrole:null,child_count:2,
    window_number_present:false,matches_expected_window:false
  } and
  .nodes[1].parent == 0 and .nodes[1].matches_expected_window == true and
  .role_counts == [
    {role:"AXApplication",count:1},{role:"AXButton",count:1},{role:"AXWindow",count:1}
  ] and
  .depth_counts == [{depth:0,count:1},{depth:1,count:2}]
' "${last_ax_inspect}" >/dev/null || fail "AX inspect structural summary is incorrect"
if rg -Fq 'RELAYKIT_PRIVATE_SENTINEL' "${last_ax_inspect}"; then
  fail "AX inspect serialized a non-allowlisted sensitive attribute"
fi

run_ax_inspect_failure process_identity_mismatch relaykit-ax-wrong-bundle 4602 52 <<'JSON'
{
  "current_identity":{"pid":4602,"window_id":52},
  "process_running":true,
  "bundle_identifier":"com.openai.codex",
  "frontmost_pid":4602,
  "accessibility_trusted":true,
  "windows":[{"owner_pid":4602,"window_id":52,"layer":25}],
  "ax_windows_available":true,"ax_windows_count":1,"root_id":0,
  "nodes":[{"id":0,"role":"AXApplication","children":[]}]
}
JSON

run_ax_inspect_failure window_identity_changed relaykit-ax-wrong-window 4603 62 <<'JSON'
{
  "current_identity":{"pid":4603,"window_id":62},
  "process_running":true,
  "bundle_identifier":"dev.relaykit.app",
  "frontmost_pid":4603,
  "accessibility_trusted":true,
  "windows":[{"owner_pid":4603,"window_id":63,"layer":25}],
  "ax_windows_available":true,"ax_windows_count":1,"root_id":0,
  "nodes":[{"id":0,"role":"AXApplication","children":[]}]
}
JSON

run_ax_inspect_failure frontmost_identity_mismatch relaykit-ax-not-frontmost 4604 72 <<'JSON'
{
  "current_identity":{"pid":4604,"window_id":72},
  "process_running":true,
  "bundle_identifier":"dev.relaykit.app",
  "frontmost_pid":9999,
  "accessibility_trusted":true,
  "windows":[{"owner_pid":4604,"window_id":72,"layer":25}],
  "ax_windows_available":true,"ax_windows_count":1,"root_id":0,
  "nodes":[{"id":0,"role":"AXApplication","children":[]}]
}
JSON

run_ax_inspect_failure accessibility_permission_unavailable relaykit-ax-untrusted-diagnostic 4605 82 <<'JSON'
{
  "current_identity":{"pid":4605,"window_id":82},
  "process_running":true,
  "bundle_identifier":"dev.relaykit.app",
  "frontmost_pid":4605,
  "accessibility_trusted":false,
  "windows":[{"owner_pid":4605,"window_id":82,"layer":25}],
  "ax_windows_available":true,"ax_windows_count":1,"root_id":0,
  "nodes":[{"id":0,"role":"AXApplication","children":[]}]
}
JSON

run_ax_inspect_success relaykit-ax-cycle 4610 92 <<'JSON'
{
  "current_identity":{"pid":4610,"window_id":92},
  "process_running":true,
  "bundle_identifier":"dev.relaykit.app",
  "frontmost_pid":4610,
  "accessibility_trusted":true,
  "windows":[{"owner_pid":4610,"window_id":92,"layer":25}],
  "ax_windows_available":false,"ax_windows_count":0,"root_id":0,
  "nodes":[
    {"id":0,"role":"AXApplication","children":[1]},
    {"id":1,"role":"AXGroup","children":[0]}
  ]
}
JSON
jq -e '.truncated == true and (.nodes | length) == 2 and ([.nodes[].ordinal] == [0,1])' \
  "${last_ax_inspect}" >/dev/null || fail "AX inspect did not stop a cycle"

depth_metadata="${tmp_dir}/relaykit-ax-depth-generated.json"
jq -n '{
  current_identity:{pid:4611,window_id:102},process_running:true,
  bundle_identifier:"dev.relaykit.app",frontmost_pid:4611,accessibility_trusted:true,
  windows:[{owner_pid:4611,window_id:102,layer:25}],
  ax_windows_available:true,ax_windows_count:1,root_id:0,
  nodes:[range(0;15) as $id | {id:$id,role:"AXGroup",children:(if $id < 14 then [$id + 1] else [] end)}]
}' >"${depth_metadata}"
run_ax_inspect_success relaykit-ax-depth 4611 102 <"${depth_metadata}"
jq -e '.truncated == true and (.nodes | length) == 13 and ([.nodes[].depth] | max) == 12' \
  "${last_ax_inspect}" >/dev/null || fail "AX inspect exceeded depth 12"

node_metadata="${tmp_dir}/relaykit-ax-nodes-generated.json"
jq -n '{
  current_identity:{pid:4612,window_id:112},process_running:true,
  bundle_identifier:"dev.relaykit.app",frontmost_pid:4612,accessibility_trusted:true,
  windows:[{owner_pid:4612,window_id:112,layer:25}],
  ax_windows_available:true,ax_windows_count:1,root_id:0,
  nodes:([{id:0,role:"AXApplication",children:[range(1;520)]}] +
    [range(1;520) as $id | {id:$id,role:"AXGroup",children:[]}])
}' >"${node_metadata}"
run_ax_inspect_success relaykit-ax-nodes 4612 112 <"${node_metadata}"
jq -e '.truncated == true and (.nodes | length) == 512' "${last_ax_inspect}" >/dev/null ||
  fail "AX inspect exceeded 512 nodes"

diagnostic_source_body="$(sed -n '/private struct AXDiagnosticNodeRecord/,/private func executeInspect/p' "${SOURCE}")"
for forbidden_attribute in \
  kAXTitleAttribute kAXDescriptionAttribute kAXHelpAttribute kAXValueAttribute \
  AXIdentifier AXLabel AXPlaceholderValue AXURL AXDocument NSPasteboard CGWindowBounds; do
  if rg -Fq "${forbidden_attribute}" <<<"${diagnostic_source_body}"; then
    fail "AX inspect queried or serialized forbidden detail: ${forbidden_attribute}"
  fi
done
for required_attribute in kAXRoleAttribute kAXSubroleAttribute kAXChildrenAttribute axWindowNumber kAXWindowsAttribute; do
  rg -Fq "${required_attribute}" <<<"${diagnostic_source_body}" ||
    fail "AX inspect omitted required structural attribute: ${required_attribute}"
done
if rg -Fq 'boundWindowIndex' <<<"${diagnostic_source_body}"; then
  fail "AX inspect must not select or fall back to an AX window index"
fi
grep -Fq 'AXUIElementCreateApplication(context.pid)' <<<"${diagnostic_source_body}" ||
  fail "AX inspect must traverse from the exact App AX root"
grep -Fq 'maximumAXDiagnosticDepth = 12' "${SOURCE}" || fail "AX inspect depth bound changed"
grep -Fq 'maximumAXDiagnosticNodes = 512' "${SOURCE}" || fail "AX inspect node bound changed"

bound_window_test_body="$(sed -n '/private func executeBoundWindowTest/,/^}/p' "${SOURCE}")"
test "$(rg -c 'resolveBoundActionRoot' <<<"${bound_window_test_body}")" -eq 1 ||
  fail "dynamic tests must enter the production shared full resolver exactly once"
if rg -Fq 'verifyWindowServerIdentity' <<<"${bound_window_test_body}"; then
  fail "dynamic tests must not assemble a partial WindowServer-only resolver"
fi

bound_window_production_body="$(sed -n '/private func verifyBoundWindow/,/private struct SemanticRecord/p' "${SOURCE}")"
grep -Fq 'NSWorkspace.shared.frontmostApplication?.processIdentifier' <<<"${bound_window_production_body}" ||
  fail "normal production resolution must use the real NSWorkspace frontmost application"
grep -Fq 'resolveBoundActionRoot' <<<"${bound_window_production_body}" ||
  fail "normal production resolution must enter the shared full resolver"

relaykit_binding_body="$(sed -n '/private func uniqueRelayKitPopoverRoot/,/private func verifyBoundWindow/p' "${SOURCE}")"
grep -Fq 'maximumRelayKitBindingDepth = 12' "${SOURCE}" ||
  fail "RelayKit popover binding depth must remain 12"
grep -Fq 'maximumRelayKitBindingNodes = 512' "${SOURCE}" ||
  fail "RelayKit popover binding node limit must remain 512"
for required_binding_text in AXPopover kAXRoleAttribute kAXChildrenAttribute identical; do
  rg -Fq "${required_binding_text}" <<<"${relaykit_binding_body}" ||
    fail "RelayKit popover binding is missing ${required_binding_text}"
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
  fail "production RelayKit popover traversal is not cycle-safe by AX identity"
for forbidden_binding_text in \
  kAXTitleAttribute kAXDescriptionAttribute kAXHelpAttribute kAXValueAttribute \
  AXIdentifier AXLabel AXPlaceholderValue kAXPositionAttribute kAXSizeAttribute \
  CGWindowBounds localizedCaseInsensitiveContains localizedStandardContains 'range(of:'; do
  if rg -Fq "${forbidden_binding_text}" <<<"${relaykit_binding_body}"; then
    fail "RelayKit popover binding used a weak selector: ${forbidden_binding_text}"
  fi
done
grep -Fq 'depth > 0' <<<"${relaykit_binding_body}" ||
  fail "RelayKit popover binding may return the application root"
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

for relaykit_command in relaykit-provider-configure relaykit-provider-verify relaykit-gateway-start; do
  rg -Fq "${relaykit_command}" "${SOURCE}" ||
    fail "driver is missing concrete RelayKit action ${relaykit_command}"
done
rg -Fq 'dev.relaykit.app' "${SOURCE}" || fail "RelayKit AX actions must bind the exact App bundle identity"
rg -Fq 'provider-provider-name-field' "${SOURCE}" || fail "provider setup must use the exact name field identifier"
rg -Fq 'provider-api-base-url-field' "${SOURCE}" || fail "provider setup must use the exact URL field identifier"
rg -Fq 'api-key-new-input-field' "${SOURCE}" || fail "provider setup must use the exact key field identifier"
rg -Fq 'provider-model-id-field' "${SOURCE}" || fail "provider setup must use the exact model field identifier"
rg -Fq 'provider-upstream-protocol-option-openai_responses' "${SOURCE}" || fail "provider setup must select the exact Responses option"
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
