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

new_git_repo() {
  local repo="$1"
  mkdir -p "${repo}/scripts"
  cp "${VALIDATE}" "${repo}/scripts/relaykit-validate.sh"
  chmod 700 "${repo}/scripts/relaykit-validate.sh"
  git -C "${repo}" init -q
  git -C "${repo}" config user.email relaykit@example.test
  git -C "${repo}" config user.name 'RelayKit Test'
  printf '%s\n' 'tracked baseline' >"${repo}/tracked.txt"
  git -C "${repo}" add .
  git -C "${repo}" commit -qm baseline
}

rc1_repo="${tmp}/rc1-repo"
new_git_repo "${rc1_repo}"
"${rc1_repo}/scripts/relaykit-validate.sh" --plan-only --rc1 >"${tmp}/rc1.json"
jq -e '
  .status == "planned" and
  .validation_profile == "rc1" and
  .change_classes == ["rc1"] and
  [.selected_commands[].id] == [
    "diff-check",
    "public-boundary",
    "swift-build",
    "swift-validation",
    "go-all",
    "go-vet",
    "gofmt-check",
    "package-verify",
    "menu-ui-smoke-final-bundle",
    "rc1-native-responses-proof",
    "rc1-helper-lifecycle-proof"
  ] and
  .requires_build == true and
  .requires_package == true and
  .requires_gui == true and
  .requires_live_query == false and
  .requires_full_e2e == false and
  any(.selected_commands[]; .id == "menu-ui-smoke-final-bundle" and (.command | contains("dist/verify-release/RelayKitApp.app"))) and
  any(.selected_commands[]; .id == "rc1-native-responses-proof") and
  any(.selected_commands[]; .id == "rc1-helper-lifecycle-proof")
' "${tmp}/rc1.json" >/dev/null || fail "RC1 profile did not select the unique final matrix"

signed_beta_repo="${tmp}/signed-beta-repo"
new_git_repo "${signed_beta_repo}"
"${signed_beta_repo}/scripts/relaykit-validate.sh" --plan-only --signed-beta >"${tmp}/signed-beta.json"
jq -e '
  .status == "planned" and
  .validation_profile == "signed-beta" and
  .release_version == "v0.1.0" and
  .execution_allowed == false and
  [.plan_steps[].id] == [
    "sign-package",
    "notarization-accepted",
    "staple-ticket",
    "gatekeeper-assessment",
    "install-dogfood",
    "private-route-stage-1",
    "private-route-stage-2",
    "private-route-stage-3",
    "private-route-stage-4",
    "private-route-stage-5",
    "private-route-stage-6",
    "cleanup",
    "manifest"
  ] and
  all(.plan_steps[]; (.owner == "relaykit_release" or .owner == "relaykit_test")) and
  ([.plan_steps[] | select(.owner == "relaykit_release")] | length) == 4 and
  ([.plan_steps[] | select(.owner == "relaykit_test")] | length) == 9 and
  ([.plan_steps[] | select(.id | startswith("private-route-stage-"))] | length) == 6 and
  all(.plan_steps[] | select(.id | startswith("private-route-stage-"));
    (.action | contains("real private route stage")) and
    (.action | contains("repository-external private dogfood scenario"))) and
  (.plan_steps[] | select(.id == "notarization-accepted") | .acceptance | contains("Accepted")) and
  (.plan_steps[] | select(.id == "staple-ticket") | .action | contains("stapler")) and
  (.plan_steps[] | select(.id == "gatekeeper-assessment") | .action | contains("Gatekeeper")) and
  (.plan_steps[] | select(.id == "install-dogfood") | .action | contains("signed zip")) and
  (.plan_steps[] | select(.id == "cleanup") | .action | contains("shared resources")) and
  (.plan_steps[] | select(.id == "manifest") | .action | contains("redacted signed-beta manifest")) and
  .requires_build == true and
  .requires_package == true and
  .requires_gui == true and
  .requires_live_query == true and
  .requires_full_e2e == true
' "${tmp}/signed-beta.json" >/dev/null || fail "Signed Beta profile did not return the fixed owner-tagged Case 1 plan"

printf '%s\n' 'dirty implementation lane' >>"${signed_beta_repo}/tracked.txt"
"${signed_beta_repo}/scripts/relaykit-validate.sh" --plan-only --signed-beta >"${tmp}/signed-beta-dirty.json"
jq -e '.status == "planned" and .validation_profile == "signed-beta" and .execution_allowed == false' "${tmp}/signed-beta-dirty.json" >/dev/null ||
  fail "Signed Beta plan-only profile was blocked by an implementation-lane worktree"

signed_beta_execute_status=0
"${signed_beta_repo}/scripts/relaykit-validate.sh" --execute --signed-beta >"${tmp}/signed-beta-execute.stdout" 2>"${tmp}/signed-beta-execute.json" || signed_beta_execute_status=$?
[[ "${signed_beta_execute_status}" -eq 2 && ! -s "${tmp}/signed-beta-execute.stdout" ]] ||
  fail "Signed Beta profile did not fail closed under --execute"
jq -e -s 'length == 1 and .[0].status == "failed" and .[0].error_code == "signed_beta_plan_only"' "${tmp}/signed-beta-execute.json" >/dev/null ||
  fail "Signed Beta execute rejection was not machine-readable"

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

write_fixture keychain app/Sources/RelayKitCore/KeychainCredentialStore.swift
plan_fixture keychain --live-query
jq -e '
  (.change_classes | index("keychain")) != null and
  .requires_live_query == true and
  .requires_full_e2e == false
' "${tmp}/keychain.json" >/dev/null || fail "Keychain targeted live-query plan is invalid"
selected keychain live-desktop-query || fail "Keychain targeted plan omitted the Skill leaf"

write_fixture adapter gateway/internal/server/server.go
plan_fixture adapter --live-query
jq -e '(.change_classes | index("gateway_runtime")) != null and .requires_live_query == true' "${tmp}/adapter.json" >/dev/null ||
  fail "gateway runtime targeted live-query plan is invalid"

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
selected workflow agent-workflow-contract || fail "workflow plan omitted the project workflow contract"
jq -e 'any(.selected_commands[]; .id == "agent-config-syntax" and (.command | contains("relaykit-validate-agent-config.sh")))' "${tmp}/workflow.json" >/dev/null ||
  fail "workflow plan depends on a non-portable TOML parser"

write_fixture workflow-config .codex/config.toml
plan_fixture workflow-config
jq -e '(.change_classes | index("workflow")) != null' "${tmp}/workflow-config.json" >/dev/null ||
  fail "project Agent config was not classified as workflow"
selected workflow-config agent-workflow-contract || fail "project Agent config omitted the workflow contract"

write_fixture workflow-contract-script scripts/relaykit-agent-workflow-test.sh
plan_fixture workflow-contract-script
jq -e '(.change_classes | index("workflow")) != null and (.change_classes | index("shell")) != null' "${tmp}/workflow-contract-script.json" >/dev/null ||
  fail "workflow contract script was not classified as workflow shell"
selected workflow-contract-script agent-workflow-contract || fail "workflow contract script did not select itself"

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

write_fixture full gateway/internal/server/server.go
plan_fixture full --full
jq -e '.requires_full_e2e == true and .requires_live_query == true and .requires_gui == true' "${tmp}/full.json" >/dev/null ||
  fail "explicit full plan did not select full E2E"
selected full full-desktop-e2e || fail "explicit --full omitted full E2E"

write_fixture sensitive-paths \
  gateway/internal/server/server.go \
  app/Sources/RelayKitApp/Stores/AppModel.swift \
  app/Sources/RelayKitApp/Services/GatewayProcess.swift \
  app/Sources/RelayKitCore/GatewayCredentialHandoff.swift \
  app/Sources/RelayKitCore/KeychainCredentialStore.swift \
  app/Sources/RelayKitApp/App/RelayKitApp.swift
plan_fixture sensitive-paths --live-query
jq -e '
  (.change_classes | index("gateway_runtime")) != null and
  (.change_classes | index("gateway_lifecycle")) != null and
  (.change_classes | index("keychain")) != null and
  .requires_live_query == true
' "${tmp}/sensitive-paths.json" >/dev/null || fail "current sensitive paths were not classified exactly"

assert_sensitive_class() {
  local name="$1"
  local path="$2"
  local class="$3"
  write_fixture "${name}" "${path}"
  plan_fixture "${name}"
  jq -e --arg class "${class}" '(.change_classes | index($class)) != null' "${tmp}/${name}.json" >/dev/null ||
    fail "${path} omitted ${class} classification"
}

assert_sensitive_class sensitive-server gateway/internal/server/server.go gateway_runtime
assert_sensitive_class sensitive-app-model app/Sources/RelayKitApp/Stores/AppModel.swift gateway_lifecycle
assert_sensitive_class sensitive-gateway-process app/Sources/RelayKitApp/Services/GatewayProcess.swift gateway_lifecycle
assert_sensitive_class sensitive-handoff app/Sources/RelayKitCore/GatewayCredentialHandoff.swift gateway_lifecycle
assert_sensitive_class sensitive-handoff-keychain app/Sources/RelayKitCore/GatewayCredentialHandoff.swift keychain
assert_sensitive_class sensitive-keychain app/Sources/RelayKitCore/KeychainCredentialStore.swift keychain
assert_sensitive_class sensitive-app app/Sources/RelayKitApp/App/RelayKitApp.swift gateway_lifecycle

delete_repo="${tmp}/delete-repo"
new_git_repo "${delete_repo}"
mkdir -p "${delete_repo}/gateway/internal/server"
printf '%s\n' 'package server' >"${delete_repo}/gateway/internal/server/server.go"
git -C "${delete_repo}" add gateway/internal/server/server.go
git -C "${delete_repo}" commit -qm 'add critical path'
delete_base="$(git -C "${delete_repo}" rev-parse HEAD)"
git -C "${delete_repo}" rm -q gateway/internal/server/server.go
git -C "${delete_repo}" commit -qm 'delete critical path'
"${delete_repo}/scripts/relaykit-validate.sh" --base "${delete_base}" --head HEAD --live-query --plan-only >"${tmp}/deleted.json"
jq -e '
  (.changed_files | index("gateway/internal/server/server.go")) != null and
  (.change_classes | index("gateway_runtime")) != null and
  any(.selected_commands[]; .id == "live-desktop-query")
' "${tmp}/deleted.json" >/dev/null || fail "committed deletion of a critical path was not selected"

deleted_syntax_repo="${tmp}/deleted-syntax-repo"
new_git_repo "${deleted_syntax_repo}"
mkdir -p "${deleted_syntax_repo}/.codex/agents"
printf '%s\n' '#!/usr/bin/env bash' 'exit 0' >"${deleted_syntax_repo}/scripts/removed-validation.sh"
printf '%s\n' 'name = "removed"' >"${deleted_syntax_repo}/.codex/agents/removed.toml"
git -C "${deleted_syntax_repo}" add scripts/removed-validation.sh .codex/agents/removed.toml
git -C "${deleted_syntax_repo}" commit -qm 'add syntax fixtures'
deleted_syntax_base="$(git -C "${deleted_syntax_repo}" rev-parse HEAD)"
git -C "${deleted_syntax_repo}" rm -q scripts/removed-validation.sh .codex/agents/removed.toml
git -C "${deleted_syntax_repo}" commit -qm 'delete syntax fixtures'
"${deleted_syntax_repo}/scripts/relaykit-validate.sh" --base "${deleted_syntax_base}" --head HEAD --plan-only >"${tmp}/deleted-syntax.json"
jq -e '
  (.changed_files | index("scripts/removed-validation.sh")) != null and
  (.changed_files | index(".codex/agents/removed.toml")) != null and
  (.change_classes | index("shell")) != null and
  (.change_classes | index("workflow")) != null and
  all(.selected_commands[]; (.command | contains("removed-validation.sh") or contains("removed.toml")) | not) and
  any(.selected_commands[]; .id == "agent-workflow-contract")
' "${tmp}/deleted-syntax.json" >/dev/null || fail "deleted syntax files were passed to parsers or lost their risk classification"

worktree_repo="${tmp}/worktree-repo"
new_git_repo "${worktree_repo}"
worktree_base="$(git -C "${worktree_repo}" rev-parse HEAD)"
printf '%s\n' 'committed' >"${worktree_repo}/committed.md"
git -C "${worktree_repo}" add committed.md
git -C "${worktree_repo}" commit -qm committed
printf '%s\n' 'staged' >"${worktree_repo}/staged.md"
git -C "${worktree_repo}" add staged.md
printf '%s\n' 'unstaged change' >>"${worktree_repo}/tracked.txt"
printf '%s\n' 'untracked' >"${worktree_repo}/untracked.md"
"${worktree_repo}/scripts/relaykit-validate.sh" --base "${worktree_base}" --head HEAD --worktree --plan-only >"${tmp}/worktree.json"
jq -e '
  .changed_files == ["committed.md", "staged.md", "tracked.txt", "untracked.md"]
' "${tmp}/worktree.json" >/dev/null || fail "--worktree did not union committed, staged, unstaged, and untracked files"
dirty_status=0
"${worktree_repo}/scripts/relaykit-validate.sh" --base "${worktree_base}" --head HEAD --plan-only >"${tmp}/dirty.stdout" 2>"${tmp}/dirty.json" || dirty_status=$?
[[ "${dirty_status}" -ne 0 && ! -s "${tmp}/dirty.stdout" ]] || fail "dirty repository passed without --worktree"
jq -e -s 'length == 1 and .[0].error_code == "dirty_worktree"' "${tmp}/dirty.json" >/dev/null ||
  fail "dirty repository rejection was not machine-readable"

execute_repo="${tmp}/execute-repo"
new_git_repo "${execute_repo}"
mkdir -p "${execute_repo}/.agents/skills/relaykit-desktop-query/scripts" "${execute_repo}/gateway/internal/server"
printf '%s\n' 'package server' >"${execute_repo}/gateway/internal/server/server.go"
printf '%s\n' 'module example.test/relaykit/gateway' '' 'go 1.22' >"${execute_repo}/gateway/go.mod"
for script in public-boundary-check.sh relaykit-validate-docs.sh codex-desktop-query-backend-test.sh codex-desktop-ax-driver-test.sh; do
  printf '%s\n' '#!/usr/bin/env bash' 'exit 0' >"${execute_repo}/scripts/${script}"
  chmod 700 "${execute_repo}/scripts/${script}"
done
printf '%s\n' '#!/usr/bin/env bash' 'exit 0' >"${execute_repo}/scripts/codex-desktop-manual-proof-test.sh"
chmod 700 "${execute_repo}/scripts/codex-desktop-manual-proof-test.sh"
cat >"${execute_repo}/.agents/skills/relaykit-desktop-query/scripts/run-query-test.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod 700 "${execute_repo}/.agents/skills/relaykit-desktop-query/scripts/run-query-test.sh"
cat >"${execute_repo}/.agents/skills/relaykit-desktop-query/scripts/run-query.sh" <<'SH'
#!/usr/bin/env bash
count="$(cat "${RELAYKIT_TEST_LIVE_COUNTER}" 2>/dev/null || printf 0)"
printf '%s\n' "$((count + 1))" >"${RELAYKIT_TEST_LIVE_COUNTER}"
exit 1
SH
chmod 700 "${execute_repo}/.agents/skills/relaykit-desktop-query/scripts/run-query.sh"
cat >"${execute_repo}/scripts/codex-desktop-manual-proof.sh" <<'SH'
#!/usr/bin/env bash
count="$(cat "${RELAYKIT_TEST_FULL_COUNTER}" 2>/dev/null || printf 0)"
printf '%s\n' "$((count + 1))" >"${RELAYKIT_TEST_FULL_COUNTER}"
exit 1
SH
chmod 700 "${execute_repo}/scripts/codex-desktop-manual-proof.sh"
git -C "${execute_repo}" add .
git -C "${execute_repo}" commit -qm fixtures

write_execute_fixture() {
  local path="$1"
  local value="$2"
  printf '%s\n' "${value}" >"${path}"
  chmod 600 "${path}"
}

live_fixture="${tmp}/execute-live.txt"
write_execute_fixture "${live_fixture}" scripts/codex-desktop-query-backend.sh
touch "${tmp}/query.txt" "${tmp}/catalog.json" "${tmp}/artifact.zip"
chmod 600 "${tmp}/query.txt" "${tmp}/catalog.json"
live_status=0
RELAYKIT_TEST_LIVE_COUNTER="${tmp}/live.counter" \
RELAYKIT_VALIDATE_LIVE_MODEL=public-model \
RELAYKIT_VALIDATE_LIVE_QUERY_FILE="${tmp}/query.txt" \
RELAYKIT_VALIDATE_CATALOG_EVIDENCE="${tmp}/catalog.json" \
RELAYKIT_VALIDATE_CATALOG_SHA256="$(printf 'a%.0s' {1..64})" \
RELAYKIT_VALIDATE_CATALOG_SETUP_ID=current-setup \
RELAYKIT_VALIDATE_CATALOG_SESSION_ID=current-session \
RELAYKIT_VALIDATE_ARTIFACT_SHA256="$(printf 'b%.0s' {1..64})" \
  "${execute_repo}/scripts/relaykit-validate.sh" --base HEAD --head HEAD --changed-files-file "${live_fixture}" --live-query --execute >"${tmp}/live-execute.json" 2>/dev/null || live_status=$?
[[ "${live_status}" -ne 0 && "$(cat "${tmp}/live.counter")" == "1" ]] || fail "live desktop query was retried after failure"
jq -e 'any(.execution_results[]; .id == "live-desktop-query" and .attempts == 1 and .status == "failed")' "${tmp}/live-execute.json" >/dev/null ||
  fail "live desktop query result did not record one attempt"

full_fixture="${tmp}/execute-full.txt"
write_execute_fixture "${full_fixture}" gateway/internal/server/server.go
full_status=0
RELAYKIT_TEST_FULL_COUNTER="${tmp}/full.counter" \
RELAYKIT_VALIDATE_FULL_SCENARIO="${tmp}/scenario.json" \
  "${execute_repo}/scripts/relaykit-validate.sh" --base HEAD --head HEAD --changed-files-file "${full_fixture}" --full --execute >"${tmp}/full-execute.json" 2>/dev/null || full_status=$?
[[ "${full_status}" -ne 0 && "$(cat "${tmp}/full.counter")" == "1" ]] || fail "full desktop E2E was retried after failure"
jq -e 'any(.execution_results[]; .id == "full-desktop-e2e" and .attempts == 1 and .status == "failed")' "${tmp}/full-execute.json" >/dev/null ||
  fail "full desktop E2E result did not record one attempt"

cat >"${execute_repo}/scripts/public-boundary-check.sh" <<'SH'
#!/usr/bin/env bash
count="$(cat "${RELAYKIT_TEST_SAFE_COUNTER}" 2>/dev/null || printf 0)"
printf '%s\n' "$((count + 1))" >"${RELAYKIT_TEST_SAFE_COUNTER}"
exit 1
SH
chmod 700 "${execute_repo}/scripts/public-boundary-check.sh"
safe_fixture="${tmp}/execute-safe.txt"
write_execute_fixture "${safe_fixture}" docs/handoff.md
safe_status=0
RELAYKIT_TEST_SAFE_COUNTER="${tmp}/safe.counter" \
  "${execute_repo}/scripts/relaykit-validate.sh" --base HEAD --head HEAD --changed-files-file "${safe_fixture}" --execute >"${tmp}/safe-execute.json" 2>/dev/null || safe_status=$?
[[ "${safe_status}" -ne 0 && "$(cat "${tmp}/safe.counter")" == "2" ]] || fail "safe local command did not stop after two attempts"
jq -e 'any(.execution_results[]; .id == "public-boundary" and .attempts == 2 and .status == "failed")' "${tmp}/safe-execute.json" >/dev/null ||
  fail "safe local failure did not record two attempts"

printf '%s\n' "RelayKit validation selector fixture tests passed"
