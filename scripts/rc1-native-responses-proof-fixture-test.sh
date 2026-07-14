#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURE="${ROOT}/scripts/rc1-native-responses-proof-fixture.py"

fail() {
  printf 'RC1 native Responses fixture contract failed: %s\n' "$*" >&2
  exit 1
}

[[ -f "${FIXTURE}" ]] || fail "fixture is missing"
python3 -c 'import pathlib; compile(pathlib.Path(__import__("sys").argv[1]).read_text(encoding="utf-8"), __import__("sys").argv[1], "exec")' "${FIXTURE}"
contract="$(python3 "${FIXTURE}" --print-contract)"
jq -e '
  .bind == "127.0.0.1" and
  .paths == ["/v1/models", "/v1/responses"] and
  .modes == ["plain", "markdown", "tool", "function_call_output"] and
  .supports_nonstream == true and
  .supports_sse == true and
  .log_fields == ["run_id", "method", "path", "model_rewrite", "auth_present", "event_types"]
' <<<"${contract}" >/dev/null || fail "fixture contract is invalid"

tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/relaykit-responses-fixture-test.XXXXXX")"
fixture_pid=""
cleanup() {
  if [[ -n "${fixture_pid}" ]] && kill -0 "${fixture_pid}" 2>/dev/null; then
    kill "${fixture_pid}" >/dev/null 2>&1 || true
    wait "${fixture_pid}" >/dev/null 2>&1 || true
  fi
  rm -rf "${tmp_dir}"
}
trap cleanup EXIT

port_file="${tmp_dir}/port"
events_file="${tmp_dir}/events.jsonl"
run_id="fixture-run-001"
auth_header_name="$(printf '%s%s' 'Authoriz' 'ation')"
auth_header_scheme="$(printf '%s%s' 'Bear' 'er')"
synthetic_auth_header="${auth_header_name}: ${auth_header_scheme} RELAYKIT_FAKE_SENTINEL_DO_NOT_USE"
python3 "${FIXTURE}" serve \
  --port-file "${port_file}" \
  --events "${events_file}" \
  --run-id "${run_id}" \
  --synthetic-key RELAYKIT_FAKE_SENTINEL_DO_NOT_USE >"${tmp_dir}/stdout" 2>"${tmp_dir}/stderr" &
fixture_pid="$!"
for _ in {1..80}; do
  [[ -s "${port_file}" ]] && break
  sleep 0.05
done
[[ -s "${port_file}" ]] || fail "fixture did not start"
port="$(cat "${port_file}")"

curl -fsS "http://127.0.0.1:${port}/v1/models" >"${tmp_dir}/models.json"
jq -e '([.data[].id] | index("native-upstream")) != null' "${tmp_dir}/models.json" >/dev/null

for mode in plain markdown; do
  jq -n --arg mode "${mode}" '{model:"native-upstream",input:"RELAYKIT_FIXTURE_MARKER",stream:false,metadata:{relaykit_fixture_mode:$mode}}' >"${tmp_dir}/${mode}-request.json"
  curl -fsS -H "${synthetic_auth_header}" -H 'Content-Type: application/json' \
    --data-binary "@${tmp_dir}/${mode}-request.json" "http://127.0.0.1:${port}/v1/responses" >"${tmp_dir}/${mode}.json"
  jq -e '.object == "response" and .status == "completed" and .model == "native-upstream"' "${tmp_dir}/${mode}.json" >/dev/null
done
jq -e '.output[0].content[0].text | contains("RELAYKIT_FIXTURE_MARKER")' "${tmp_dir}/plain.json" >/dev/null
jq -e '.output[0].content[0].text | contains("## RelayKit Rich Text Check") and contains("| status | route |") and contains("```bash")' "${tmp_dir}/markdown.json" >/dev/null

jq -n '{model:"native-upstream",input:"run RELAYKIT_TOOL_MARKER",stream:true,metadata:{relaykit_fixture_mode:"tool"}}' >"${tmp_dir}/tool-request.json"
curl -fsS -N -H "${synthetic_auth_header}" -H 'Content-Type: application/json' \
  --data-binary "@${tmp_dir}/tool-request.json" "http://127.0.0.1:${port}/v1/responses" >"${tmp_dir}/tool.sse"
rg -F 'response.output_item.added' "${tmp_dir}/tool.sse" >/dev/null
rg -F '"type":"function_call"' "${tmp_dir}/tool.sse" >/dev/null
tool_command="$(jq -Rr '
  select(startswith("data: ")) |
  ltrimstr("data: ") | fromjson |
  select(.type == "response.output_item.added" and .item.type == "function_call") |
  .item.arguments | fromjson | .cmd
' "${tmp_dir}/tool.sse")"
[[ "${tool_command}" == "printf 'RELAYKIT_TOOL_MARKER\\n'; pwd" ]] || fail "fixture tool command is not exact"

jq -n '{model:"native-upstream",input:[{type:"function_call_output",call_id:"call_fixture",output:"RELAYKIT_TOOL_MARKER\n/tmp/fixture"}],stream:true,metadata:{relaykit_fixture_mode:"function_call_output"}}' >"${tmp_dir}/output-request.json"
curl -fsS -N -H "${synthetic_auth_header}" -H 'Content-Type: application/json' \
  --data-binary "@${tmp_dir}/output-request.json" "http://127.0.0.1:${port}/v1/responses" >"${tmp_dir}/output.sse"
rg -F 'response.output_text.delta' "${tmp_dir}/output.sse" >/dev/null
rg -F 'response.completed' "${tmp_dir}/output.sse" >/dev/null

jq -s -e --arg run_id "${run_id}" '
  length >= 5 and
  all(.[];
    (.run_id == $run_id) and
    ((keys | sort) == (["run_id", "method", "path", "model_rewrite", "auth_present", "event_types"] | sort)) and
    (.event_types | type == "array")
  ) and
  any(.[]; .path == "/v1/responses" and .auth_present == true and (.event_types | index("response.completed")) != null)
' "${events_file}" >/dev/null || fail "fixture events are not run-bound and redacted"
if rg -F 'RELAYKIT_FAKE_SENTINEL_DO_NOT_USE' "${events_file}" || rg -F 'RELAYKIT_TOOL_MARKER' "${events_file}"; then
  fail "fixture log leaked credential, request, response, or marker content"
fi

printf '%s\n' 'RelayKit RC1 native Responses fixture tests passed'
