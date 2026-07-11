#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VALIDATE="${ROOT}/scripts/relaykit-validate.sh"

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

[[ -x "${VALIDATE}" ]] || fail "relaykit validation selector is missing"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/relaykit-validate-test.XXXXXX")"
trap 'rm -rf "${tmp}"' EXIT

write_fixture() {
  local name="$1"
  shift
  printf '%s\n' "$@" >"${tmp}/${name}.txt"
  chmod 600 "${tmp}/${name}.txt"
}

plan_fixture() {
  local name="$1"
  shift
  "${VALIDATE}" \
    --base HEAD \
    --head HEAD \
    --changed-files-file "${tmp}/${name}.txt" \
    "$@" \
    --plan-only >"${tmp}/${name}.json"
  jq -e '
    (.changed_files | type) == "array" and
    (.change_classes | type) == "array" and
    (.selected_commands | type) == "array" and
    (.skipped_commands | type) == "array" and
    (.reasons | type) == "object" and
    ([.requires_build, .requires_package, .requires_gui, .requires_live_query, .requires_full_e2e] | all(type == "boolean"))
  ' "${tmp}/${name}.json" >/dev/null || fail "${name} plan schema is invalid"
}

selected() {
  local name="$1"
  local command_id="$2"
  jq -e --arg id "${command_id}" 'any(.selected_commands[]; .id == $id)' "${tmp}/${name}.json" >/dev/null
}

not_selected() {
  ! selected "$@"
}

write_fixture docs docs/handoff.md docs/development-plan.md
plan_fixture docs
jq -e '
  .change_classes == ["docs"] and
  .requires_build == false and
  .requires_package == false and
  .requires_gui == false and
  .requires_live_query == false and
  .requires_full_e2e == false
' "${tmp}/docs.json" >/dev/null || fail "docs-only plan selected a heavy validation layer"
selected docs diff-check || fail "docs-only plan omitted diff check"
selected docs docs-consistency || fail "docs-only plan omitted documentation consistency"
selected docs public-boundary || fail "docs-only plan omitted public boundary"
not_selected docs swift-build || fail "docs-only plan selected Swift build"
"${VALIDATE}" --base HEAD --head HEAD --changed-files-file "${tmp}/docs.txt" --execute >"${tmp}/docs-execute.json"
jq -e '.status == "passed" and (.execution_results | length) == 3 and all(.execution_results[]; .status == "passed" and .attempts == 1)' "${tmp}/docs-execute.json" >/dev/null ||
  fail "selector execute mode did not return successful machine-readable results"

write_fixture harness scripts/codex-desktop-manual-proof.sh
plan_fixture harness
jq -e '
  (.change_classes | index("harness")) != null and
  .requires_package == false and
  .requires_full_e2e == false and
  .requires_live_query == false
' "${tmp}/harness.json" >/dev/null || fail "harness plan selected package, full E2E, or live query"
selected harness shell-syntax || fail "harness plan omitted shell syntax"
selected harness manual-proof-contract || fail "harness plan omitted focused manual-proof tests"
not_selected harness package-verify || fail "harness plan selected package verification"

write_fixture gateway gateway/internal/config/config.go
plan_fixture gateway
jq -e '
  (.change_classes | index("gateway")) != null and
  .requires_gui == false and
  .requires_live_query == false and
  .requires_package == false
' "${tmp}/gateway.json" >/dev/null || fail "gateway-only plan selected App GUI, live query, or package"
selected gateway go-focused || fail "gateway-only plan omitted focused Go tests"
not_selected gateway menu-ui-smoke || fail "gateway-only plan selected App UI smoke"

write_fixture app app/Sources/RelayKitApp/Views/ContentView.swift
plan_fixture app
jq -e '
  (.change_classes | index("app_ui")) != null and
  .requires_build == true and
  .requires_gui == true and
  .requires_live_query == false and
  .requires_package == false
' "${tmp}/app.json" >/dev/null || fail "ordinary App UI plan has the wrong validation boundary"
selected app swift-build || fail "ordinary App UI plan omitted Swift build"
selected app swift-validation || fail "ordinary App UI plan omitted Swift validation"
selected app menu-ui-smoke || fail "ordinary App UI plan omitted UI smoke"
not_selected app live-desktop-query || fail "ordinary App UI plan selected a model request"

write_fixture keychain app/Sources/RelayKitCore/KeychainStore.swift
plan_fixture keychain --live-query
jq -e '
  (.change_classes | index("keychain")) != null and
  .requires_live_query == true and
  .requires_full_e2e == false
' "${tmp}/keychain.json" >/dev/null || fail "Keychain targeted live-query plan is invalid"
selected keychain live-desktop-query || fail "Keychain targeted plan omitted the Skill leaf"

write_fixture adapter gateway/internal/server/anthropic_adapter.go
plan_fixture adapter --live-query
jq -e '(.change_classes | index("adapter")) != null and .requires_live_query == true' "${tmp}/adapter.json" >/dev/null ||
  fail "adapter targeted live-query plan is invalid"

write_fixture catalog gateway/internal/catalog/catalog.go
plan_fixture catalog --live-query
jq -e '(.change_classes | index("catalog")) != null and .requires_live_query == true' "${tmp}/catalog.json" >/dev/null ||
  fail "catalog targeted live-query plan is invalid"

write_fixture workflow .codex/agents/relaykit-test.toml .agents/skills/relaykit-desktop-query/SKILL.md
plan_fixture workflow
jq -e '
  (.change_classes | index("workflow")) != null and
  (.change_classes | index("skill")) != null and
  .requires_build == false and
  .requires_package == false and
  .requires_gui == false
' "${tmp}/workflow.json" >/dev/null || fail "workflow/skill plan selected a heavy layer"
selected workflow desktop-query-runner-contract || fail "Skill plan omitted runner tests"
selected workflow agent-config-syntax || fail "workflow plan omitted agent config syntax"
jq -e 'any(.selected_commands[]; .id == "agent-config-syntax" and (.command | contains("relaykit-validate-agent-config.sh")))' "${tmp}/workflow.json" >/dev/null ||
  fail "workflow plan depends on a non-portable TOML parser"

agent_validator="${ROOT}/scripts/relaykit-validate-agent-config.sh"
[[ -x "${agent_validator}" ]] || fail "agent config validator is missing"
"${agent_validator}" "${ROOT}/.codex/agents/relaykit-test.toml"
invalid_agent="${tmp}/invalid-agent.toml"
printf '%s\n' 'name = "broken"' 'developer_instructions = """unterminated' >"${invalid_agent}"
if "${agent_validator}" "${invalid_agent}" >/dev/null 2>&1; then
  fail "agent config validator accepted malformed TOML"
fi

write_fixture desktop-query-backend scripts/codex-desktop-query-backend.sh
plan_fixture desktop-query-backend --live-query
jq -e '(.change_classes | index("ax")) != null and .requires_live_query == true and .requires_full_e2e == false' "${tmp}/desktop-query-backend.json" >/dev/null ||
  fail "Desktop query backend was not classified as a targeted AX live-query leaf"
selected desktop-query-backend live-desktop-query || fail "Desktop query backend plan omitted its targeted Skill E2E"

write_fixture desktop-query-official scripts/codex-desktop-query-official-once.sh
plan_fixture desktop-query-official --live-query
jq -e '(.change_classes | index("ax")) != null and (.change_classes | index("harness")) != null and .requires_live_query == true and .requires_package == false and .requires_full_e2e == false' "${tmp}/desktop-query-official.json" >/dev/null ||
  fail "targeted official lifecycle was not classified as an AX live-query leaf"
selected desktop-query-official desktop-query-backend-contract || fail "targeted official lifecycle plan omitted backend contract tests"
selected desktop-query-official live-desktop-query || fail "targeted official lifecycle plan omitted its explicit Skill E2E"
not_selected desktop-query-official package-verify || fail "targeted official lifecycle plan selected package verification"

write_fixture packaging script/package_release.sh
plan_fixture packaging
jq -e '
  (.change_classes | index("packaging")) != null and
  .requires_build == true and
  .requires_package == true and
  .requires_gui == true and
  .requires_full_e2e == false
' "${tmp}/packaging.json" >/dev/null || fail "packaging plan boundary is invalid"
selected packaging package-verify || fail "packaging plan omitted package verification"
selected packaging extracted-app-dogfood || fail "packaging plan omitted extracted-App dogfood"
not_selected packaging full-desktop-e2e || fail "packaging plan selected full E2E without --full"

invalid_plan_status=0
"${VALIDATE}" --base HEAD --head HEAD --changed-files-file "${tmp}/gateway.txt" --live-query --plan-only >"${tmp}/invalid-live-plan.json" 2>/dev/null || invalid_plan_status=$?
if [[ "${invalid_plan_status}" -eq 0 ]]; then
  fail "ordinary gateway change accepted targeted live query"
fi
jq -e '.status == "failed" and .error_code == "live_query_not_justified"' "${tmp}/invalid-live-plan.json" >/dev/null ||
  fail "rejected live-query plan did not return machine-readable JSON"

write_fixture full gateway/internal/server/anthropic_adapter.go
plan_fixture full --full
jq -e '.requires_full_e2e == true and .requires_live_query == true and .requires_gui == true' "${tmp}/full.json" >/dev/null ||
  fail "explicit full plan did not select full E2E"
selected full full-desktop-e2e || fail "explicit --full omitted full E2E"

printf '%s\n' "RelayKit validation selector fixture tests passed"
