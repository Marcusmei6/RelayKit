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

relaykit_layer25_metadata='{
  "windows": [
    {"owner_pid":4201,"window_id":41,"layer":0},
    {"owner_pid":4201,"window_id":42,"layer":25},
    {"owner_pid":9999,"window_id":42,"layer":0}
  ],
  "ax_window_numbers": [42,null]
}'
for relaykit_command in relaykit-provider-configure relaykit-provider-verify relaykit-gateway-start; do
  case "${relaykit_command}" in
    relaykit-provider-configure)
      run_bound_window_success \
        "${relaykit_command}-layer25" "${relaykit_command}" 4201 42 \
        "${relaykit_configure_options[@]}" <<<"${relaykit_layer25_metadata}"
      ;;
    relaykit-provider-verify)
      run_bound_window_success \
        "${relaykit_command}-layer25" "${relaykit_command}" 4201 42 \
        "${relaykit_verify_options[@]}" <<<"${relaykit_layer25_metadata}"
      ;;
    relaykit-gateway-start)
      run_bound_window_success \
        "${relaykit_command}-layer25" "${relaykit_command}" 4201 42 \
        <<<"${relaykit_layer25_metadata}"
      ;;
  esac
done

run_bound_window_success relaykit-unnumbered-fallback relaykit-gateway-start 4202 52 <<'JSON'
{
  "windows": [
    {"owner_pid":4202,"window_id":51,"layer":0},
    {"owner_pid":4202,"window_id":52,"layer":25},
    {"owner_pid":9999,"window_id":52,"layer":25}
  ],
  "ax_window_numbers": [null]
}
JSON

run_bound_window_success desktop-layer0 inspect 4301 61 <<'JSON'
{
  "windows": [
    {"owner_pid":4301,"window_id":61,"layer":0},
    {"owner_pid":4301,"window_id":62,"layer":25},
    {"owner_pid":9999,"window_id":61,"layer":0}
  ],
  "ax_window_numbers": [61,null]
}
JSON

run_bound_window_failure window_identity_changed relaykit-wrong-id relaykit-gateway-start 4401 71 <<'JSON'
{
  "windows": [{"owner_pid":4401,"window_id":72,"layer":25}],
  "ax_window_numbers": [71]
}
JSON
jq -e '.candidate_count == 0' "${last_stdout}" >/dev/null ||
  fail "RelayKit wrong WindowServer ID did not fail with zero exact matches"

run_bound_window_failure window_identity_changed relaykit-missing-id relaykit-gateway-start 4402 81 <<'JSON'
{
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
  "windows": [{"owner_pid":4404,"window_id":101,"layer":25}],
  "ax_window_numbers": [null,null]
}
JSON
jq -e '.candidate_count == 2' "${last_stdout}" >/dev/null ||
  fail "RelayKit multiple unnumbered AX windows did not fail closed"

run_bound_window_failure window_identity_changed desktop-nonzero-layer inspect 4501 111 <<'JSON'
{
  "windows": [{"owner_pid":4501,"window_id":111,"layer":25}],
  "ax_window_numbers": [111]
}
JSON
jq -e '.candidate_count == 0' "${last_stdout}" >/dev/null ||
  fail "Desktop accepted a nonzero-layer WindowServer identity"

run_bound_window_failure window_selector_not_unique desktop-fallback-count inspect 4502 121 <<'JSON'
{
  "windows": [
    {"owner_pid":4502,"window_id":121,"layer":0},
    {"owner_pid":4502,"window_id":122,"layer":0}
  ],
  "ax_window_numbers": [null]
}
JSON
jq -e '.candidate_count == 1' "${last_stdout}" >/dev/null ||
  fail "Desktop fallback stopped counting same-PID layer-zero windows"

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
