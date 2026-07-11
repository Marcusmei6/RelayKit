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
/usr/bin/xcrun swiftc "${SOURCE}" -o "${binary}"

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

self_test=(env RELAYKIT_AX_DRIVER_SELF_TEST=1 "${binary}" self-test)

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

submit_body="$(sed -n '/private func executeSubmit/,/private func syntheticRecord/p' "${SOURCE}")"
test "$(rg -c 'waitForUniqueApplicationOverlaySelector' <<<"${submit_body}")" -eq 2 ||
  fail "only the two native model-menu selectors may use the application overlay"
test "$(rg -c 'applicationOverlayNode' <<<"${submit_body}")" -eq 2 ||
  fail "native model-menu presses must resolve exact same-PID overlay nodes"

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
