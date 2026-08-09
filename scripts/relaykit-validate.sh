#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
base=""
head=""
mode=""
changed_files_file=""
full=false
live_query=false
include_worktree=false
rc1=false
signed_beta=false

fail() {
  jq -n --arg code "$1" '{status:"failed",error_code:$code}' >&2
  exit 2
}

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --base) base="${2:-}"; shift 2 ;;
    --head) head="${2:-}"; shift 2 ;;
    --changed-files-file) changed_files_file="${2:-}"; shift 2 ;;
    --plan-only|--execute)
      [[ -z "${mode}" ]] || fail "mode_not_unique"
      mode="${1#--}"
      shift
      ;;
    --full) full=true; shift ;;
    --live-query) live_query=true; shift ;;
    --worktree) include_worktree=true; shift ;;
    --rc1) rc1=true; shift ;;
    --signed-beta) signed_beta=true; shift ;;
    *) fail "invalid_arguments" ;;
  esac
done

[[ -n "${mode}" ]] || fail "invalid_arguments"
if [[ "${signed_beta}" == true && "${mode}" == "execute" ]]; then
  fail "signed_beta_plan_only"
fi
if [[ "${signed_beta}" == true ]]; then
  [[ "${rc1}" == false && "${full}" == false && "${live_query}" == false && "${include_worktree}" == false && -z "${changed_files_file}" ]] || fail "signed_beta_profile_not_unique"
  base="${base:-HEAD}"
  head="${head:-HEAD}"
elif [[ "${rc1}" == true ]]; then
  [[ "${full}" == false && "${live_query}" == false && "${include_worktree}" == false ]] || fail "rc1_profile_not_unique"
  base="${base:-HEAD}"
  head="${head:-HEAD}"
else
  [[ -n "${base}" && -n "${head}" ]] || fail "invalid_arguments"
fi
base_sha="$(git -C "${ROOT}" rev-parse --verify "${base}^{commit}" 2>/dev/null)" || fail "base_invalid"
head_sha="$(git -C "${ROOT}" rev-parse --verify "${head}^{commit}" 2>/dev/null)" || fail "head_invalid"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/relaykit-validate.XXXXXX")"
trap 'rm -rf "${tmp}"' EXIT
changed_input="${tmp}/changed-files.bin"
changed_format="nul"

if [[ -n "${changed_files_file}" ]]; then
  [[ "${include_worktree}" == false ]] || fail "changed_files_fixture_with_worktree"
  [[ "${changed_files_file}" = /* && -f "${changed_files_file}" && ! -L "${changed_files_file}" ]] || fail "changed_files_fixture_invalid"
  python3 - "${changed_files_file}" "$(id -u)" <<'PY' || fail "changed_files_fixture_permissions"
import os
import stat
import sys

path, expected_uid = sys.argv[1], int(sys.argv[2])
metadata = os.stat(path, follow_symlinks=False)
if metadata.st_uid != expected_uid or stat.S_IMODE(metadata.st_mode) != 0o600:
    raise SystemExit(1)
PY
  cp "${changed_files_file}" "${changed_input}"
  changed_format="lines"
else
  if [[ "${signed_beta}" == false && "${include_worktree}" == false && -n "$(git -C "${ROOT}" status --porcelain)" ]]; then
    fail "dirty_worktree"
  fi
  git -C "${ROOT}" diff --name-only -z --diff-filter=ACDMRTUXB "${base_sha}" "${head_sha}" -- >"${changed_input}"
  if [[ "${include_worktree}" == true ]]; then
    git -C "${ROOT}" diff --cached --name-only -z --diff-filter=ACDMRTUXB -- >>"${changed_input}"
    git -C "${ROOT}" diff --name-only -z --diff-filter=ACDMRTUXB -- >>"${changed_input}"
    git -C "${ROOT}" ls-files --others --exclude-standard -z >>"${changed_input}"
  fi
fi

plan="${tmp}/plan.json"
set +e
python3 - "${ROOT}" "${base_sha}" "${head_sha}" "${changed_input}" "${changed_format}" "${full}" "${live_query}" "${rc1}" "${signed_beta}" >"${plan}" <<'PY'
import json
import shlex
import sys
from pathlib import Path, PurePosixPath

root, base, head, changed_path, changed_format, full_raw, live_raw, rc1_raw, signed_beta_raw = sys.argv[1:]
raw = open(changed_path, "rb").read()
if changed_format == "nul":
    files = [part.decode("utf-8") for part in raw.split(b"\0") if part]
else:
    files = [line.strip() for line in raw.decode("utf-8").splitlines() if line.strip()]
files = sorted(set(files))
full = full_raw == "true"
live = live_raw == "true"
rc1 = rc1_raw == "true"
signed_beta = signed_beta_raw == "true"

classes = set()
shell_files = []
gateway_dirs = set()
sensitive_paths = {
    "gateway/internal/server/server.go": {"gateway_runtime"},
    "app/Sources/RelayKitApp/Stores/AppModel.swift": {"gateway_lifecycle"},
    "app/Sources/RelayKitApp/Services/GatewayProcess.swift": {"gateway_lifecycle"},
    "app/Sources/RelayKitCore/GatewayCredentialHandoff.swift": {"keychain", "gateway_lifecycle"},
    "app/Sources/RelayKitCore/KeychainCredentialStore.swift": {"keychain"},
    "app/Sources/RelayKitApp/App/RelayKitApp.swift": {"gateway_lifecycle"},
}

def is_docs(path):
    name = PurePosixPath(path).name
    return path.startswith("docs/") or path.startswith(".github/") or name in {
        "README.md", "SECURITY.md", "CONTRIBUTING.md", "CODE_OF_CONDUCT.md"
    } or path.endswith((".md", ".markdown"))

for path in files:
    lower = path.lower()
    classes.update(sensitive_paths.get(path, set()))
    if is_docs(path) and not path.startswith(".agents/skills/"):
        classes.add("docs")
        continue
    if path.startswith(".codex/agents/") or path in {
        ".codex/config.toml",
        "AGENTS.md",
        "scripts/relaykit-agent-workflow-test.sh",
    }:
        classes.add("workflow")
    if path.startswith(".agents/skills/"):
        classes.add("skill")
    if path.startswith("scripts/relaykit-validate"):
        classes.update(("validation", "shell"))
    if path.startswith(".github/workflows/") or path in {
        "scripts/github-actions-contract-test.sh",
        "scripts/github-required-checks.sh",
        "scripts/github-required-checks-test.sh",
    }:
        classes.add("github_ci")
    if path in {
        "script/package_signed_release.sh",
        "script/install_signed_release.sh",
        "script/create_github_release_draft.sh",
        "scripts/signed-release-packaging-test.sh",
    }:
        classes.add("signed_release_contract")
    if path.startswith("scripts/codex-desktop-query-backend") or path == "scripts/codex-desktop-query-official-once.sh":
        classes.update(("skill", "harness", "shell", "ax"))
    if path.startswith("scripts/codex-desktop-manual-proof"):
        classes.update(("harness", "shell"))
    if path.startswith("scripts/codex-desktop-ax-driver"):
        classes.update(("ax", "harness"))
    if path.endswith(".sh"):
        classes.add("shell")
        if (Path(root) / path).is_file():
            shell_files.append(path)
    if path.startswith("gateway/"):
        classes.add("gateway")
        directory = str(PurePosixPath(path).parent)
        gateway_dirs.add("./" + directory.removeprefix("gateway/"))
        if any(token in lower for token in ("adapter", "anthropic", "responses")):
            classes.add("adapter")
        if any(token in lower for token in ("catalog", "model_catalog", "/models")):
            classes.add("catalog")
    if path.startswith("app/Sources/"):
        classes.add("app_ui")
        if any(token in lower for token in ("keychain", "credential")):
            classes.add("keychain")
        if any(token in lower for token in ("gatewayprocess", "appdelegate", "relaykitapp.swift")):
            classes.add("gateway_lifecycle")
    if path.startswith("script/") and any(token in lower for token in ("package", "release", "build_app_bundle", "sign", "notary")):
        classes.add("packaging")
    if path.endswith((".entitlements", "/Info.plist")):
        classes.add("packaging")

if not files:
    classes.add("no_changes")

targeted_live_classes = {"keychain", "gateway_lifecycle", "gateway_runtime", "adapter", "catalog", "ax"}
if live and not (classes & targeted_live_classes):
    print(json.dumps({"status":"failed","error_code":"live_query_not_justified"}))
    raise SystemExit(3)
if full and not (classes & (targeted_live_classes | {"packaging"})):
    print(json.dumps({"status":"failed","error_code":"full_e2e_not_justified"}))
    raise SystemExit(3)

selected = []
known = {}
reasons = {}

def add(command_id, command, reason):
    if command_id in known:
        return
    item = {"id": command_id, "command": command, "reason": reason}
    known[command_id] = item
    selected.append(item)
    reasons[command_id] = reason

quoted_base = shlex.quote(base)
quoted_head = shlex.quote(head)
if signed_beta:
    plan_steps = [
        {
            "id": "sign-package",
            "owner": "relaykit_release",
            "action": "Build and Developer ID sign the v0.1.6 build 17 package with Hardened Runtime using release-owned credentials outside the repository",
            "acceptance": "The bundled helper and App pass strict codesign verification",
        },
        {
            "id": "notarization-accepted",
            "owner": "relaykit_release",
            "action": "Submit the signed package for Apple notarization and wait for a terminal result",
            "acceptance": "The current submission status is Accepted before any later step begins",
        },
        {
            "id": "staple-ticket",
            "owner": "relaykit_release",
            "action": "Run stapler staple and stapler validate on the accepted App bundle",
            "acceptance": "The notarization ticket is attached and validates successfully",
        },
        {
            "id": "gatekeeper-assessment",
            "owner": "relaykit_release",
            "action": "Run Gatekeeper assessment on the stapled App bundle",
            "acceptance": "Gatekeeper accepts the Developer ID signed and notarized App",
        },
        {
            "id": "install-dogfood",
            "owner": "relaykit_test",
            "action": "Install and launch dogfood from the signed zip rather than the repository checkout",
            "acceptance": "The installed App identity and artifact hash match the signed package",
        },
        *[
            {
                "id": f"private-route-stage-{stage}",
                "owner": "relaykit_test",
                "action": f"Run real private route stage {stage} from the repository-external private dogfood scenario",
                "acceptance": "Current-run route, visible result, usage, and process binding evidence all pass without recording private values",
            }
            for stage in range(1, 7)
        ],
        {
            "id": "cleanup",
            "owner": "relaykit_test",
            "action": "Stop only Case 1-owned processes, remove isolated state, and verify shared resources were untouched",
            "acceptance": "Owned processes and isolated listeners are gone while port 18787 and global Codex state remain unchanged",
        },
        {
            "id": "manifest",
            "owner": "relaykit_test",
            "action": "Write a redacted signed-beta manifest binding package, notarization, install, six route stages, and cleanup evidence",
            "acceptance": "The manifest contains hashes, statuses, owner results, and no credentials or private route values",
        },
    ]
    print(json.dumps({
        "status": "planned",
        "validation_profile": "signed-beta",
        "release_version": "v0.1.6",
        "release_build": "17",
        "execution_allowed": False,
        "base": base,
        "head": head,
        "changed_files": files,
        "change_classes": ["signed-beta"],
        "plan_steps": plan_steps,
        "selected_commands": [],
        "skipped_commands": [],
        "reasons": {step["id"]: step["acceptance"] for step in plan_steps},
        "requires_build": True,
        "requires_package": True,
        "requires_gui": True,
        "requires_live_query": True,
        "requires_full_e2e": True,
        "requires_signing": True,
        "requires_notarization": True,
        "requires_private_routes": True,
    }, sort_keys=True))
    raise SystemExit(0)

if rc1:
    add("diff-check", "git diff --check", "RC1 final validation requires a clean whitespace/error check")
    add("public-boundary", "./scripts/public-boundary-check.sh", "RC1 must remain publishable without cleanup")
    add("swift-build", "cd app && swift build", "RC1 builds the Apple-native App source")
    add("swift-validation", "cd app && swift run RelayKitAppValidationTests", "RC1 runs focused App contracts")
    add("go-all", "cd gateway && go test ./... -count=1", "RC1 runs the complete gateway test suite")
    add("go-vet", "cd gateway && go vet ./...", "RC1 runs gateway static analysis")
    add("gofmt-check", "cd gateway && test -z \"$(gofmt -l .)\"", "RC1 rejects unformatted Go source")
    add("package-verify", "./script/package_release.sh --verify", "RC1 builds one final zip and extracted App bundle")
    add(
        "menu-ui-smoke-final-bundle",
        "RELAYKIT_REUSE_FINAL_BUNDLE=1 RELAYKIT_APP_BUNDLE=dist/verify-release/RelayKitApp.app ./scripts/menu-bar-e2e-smoke.sh",
        "RC1 menu smoke reuses the final extracted bundle",
    )
    add(
        "rc1-native-responses-proof",
        "RELAYKIT_RC1_APP_BUNDLE=dist/verify-release/RelayKitApp.app ./scripts/rc1-native-responses-proof.sh",
        "RC1 proves App-first native Responses routing against a loopback fixture",
    )
    add(
        "rc1-helper-lifecycle-proof",
        "RELAYKIT_RC1_APP_BUNDLE=dist/verify-release/RelayKitApp.app ./scripts/rc1-helper-lifecycle-proof.sh",
        "RC1 proves the App-owned helper exits after abrupt parent loss",
    )
    print(json.dumps({
        "status": "planned",
        "validation_profile": "rc1",
        "base": base,
        "head": head,
        "changed_files": files,
        "change_classes": ["rc1"],
        "selected_commands": selected,
        "skipped_commands": [],
        "reasons": reasons,
        "requires_build": True,
        "requires_package": True,
        "requires_gui": True,
        "requires_live_query": False,
        "requires_full_e2e": False,
    }, sort_keys=True))
    raise SystemExit(0)

add("diff-check", f"git diff --check {quoted_base} {quoted_head} --", "all changes require a whitespace/error check")
add("public-boundary", "./scripts/public-boundary-check.sh", "all plans preserve the public repository boundary")

if "docs" in classes:
    add("docs-consistency", f"./scripts/relaykit-validate-docs.sh --base {quoted_base} --head {quoted_head}", "changed documentation must keep tracked local links valid")
if shell_files:
    quoted = " ".join(shlex.quote(path) for path in sorted(set(shell_files)))
    add("shell-syntax", f"bash -n {quoted}", "changed shell files require syntax validation")
if "validation" in classes:
    add("validation-selector-contract", "./scripts/relaykit-validate-test.sh", "validation routing changes require fixture matrix tests")
if "github_ci" in classes:
    add("github-actions-contract", "./scripts/github-actions-contract-test.sh", "GitHub workflow changes require the pinned public CI contract")
    add("github-required-checks-contract", "./scripts/github-required-checks-test.sh", "required-check evidence changes require fail-closed mock coverage")
if "signed_release_contract" in classes:
    add("signed-release-packaging-contract", "./scripts/signed-release-packaging-test.sh", "signed release tooling changes require offline packaging and draft mocks")
if "skill" in classes:
    add("desktop-query-runner-contract", ".agents/skills/relaykit-desktop-query/scripts/run-query-test.sh", "Skill interface changes require runner contract tests")
    add("desktop-query-backend-contract", "./scripts/codex-desktop-query-backend-test.sh", "default backend changes require focused contract tests")
if "harness" in classes:
    add("manual-proof-contract", "./scripts/codex-desktop-manual-proof-test.sh", "proof harness changes require focused evidence and safety tests")
if "ax" in classes:
    add("ax-driver-contract", "./scripts/codex-desktop-ax-driver-test.sh", "AX changes require deterministic selector tests")
if "workflow" in classes:
    add("agent-workflow-contract", "./scripts/relaykit-agent-workflow-test.sh", "workflow changes require the project role and ownership contract")
    tomls = [
        path for path in files
        if path.startswith(".codex/agents/")
        and path.endswith(".toml")
        and (Path(root) / path).is_file()
    ]
    if tomls:
        args = " ".join(shlex.quote(path) for path in tomls)
        add("agent-config-syntax", f"./scripts/relaykit-validate-agent-config.sh {args}", "changed agent TOML must parse without optional Python modules")
if "gateway" in classes:
    packages = " ".join(shlex.quote(path) for path in sorted(gateway_dirs)) or "./..."
    add("go-focused", f"cd gateway && go test {packages} -count=1", "gateway changes run only affected package tests by default")
if classes & {"app_ui", "keychain", "gateway_lifecycle"}:
    add("swift-build", "cd app && swift build", "App source changes require one Swift build")
    add("swift-validation", "cd app && swift run RelayKitAppValidationTests", "App source changes require focused validation")
    add("menu-ui-smoke", "./scripts/menu-bar-e2e-smoke.sh", "App UI and lifecycle changes require a no-model UI smoke")
if live:
    add(
        "live-desktop-query",
        "test -n \"${RELAYKIT_VALIDATE_LIVE_MODEL:-}\" && test -n \"${RELAYKIT_VALIDATE_LIVE_QUERY_FILE:-}\" && test -n \"${RELAYKIT_VALIDATE_CATALOG_EVIDENCE:-}\" && test -n \"${RELAYKIT_VALIDATE_CATALOG_SHA256:-}\" && test -n \"${RELAYKIT_VALIDATE_CATALOG_SETUP_ID:-}\" && test -n \"${RELAYKIT_VALIDATE_CATALOG_SESSION_ID:-}\" && test -n \"${RELAYKIT_VALIDATE_ARTIFACT_SHA256:-}\" && .agents/skills/relaykit-desktop-query/scripts/run-query.sh --model \"${RELAYKIT_VALIDATE_LIVE_MODEL}\" --query-file \"${RELAYKIT_VALIDATE_LIVE_QUERY_FILE}\" --expect \"${RELAYKIT_VALIDATE_LIVE_EXPECT:-plain}\" --catalog-evidence \"${RELAYKIT_VALIDATE_CATALOG_EVIDENCE}\" --catalog-sha256 \"${RELAYKIT_VALIDATE_CATALOG_SHA256}\" --catalog-setup-id \"${RELAYKIT_VALIDATE_CATALOG_SETUP_ID}\" --catalog-session-id \"${RELAYKIT_VALIDATE_CATALOG_SESSION_ID}\" --artifact-sha256 \"${RELAYKIT_VALIDATE_ARTIFACT_SHA256}\"",
        "an explicit high-risk plan requested one targeted Skill query",
    )
if "packaging" in classes:
    add("package-verify", "./script/package_release.sh --verify", "packaging inputs require package verification")
if full:
    add(
        "full-desktop-e2e",
        "test -n \"${RELAYKIT_VALIDATE_FULL_SCENARIO:-}\" && RELAYKIT_DESKTOP_PROOF_REUSE_CURRENT_ZIP=1 RELAYKIT_DESKTOP_PROOF_REUSE_EXTRACTED_APP=1 ./scripts/codex-desktop-manual-proof.sh run-auto --scenario \"${RELAYKIT_VALIDATE_FULL_SCENARIO}\"",
        "full four-stage E2E was explicitly requested for a critical class",
    )

catalog = {
    "swift-build": "cd app && swift build",
    "package-verify": "./script/package_release.sh --verify",
    "extracted-app-dogfood": "RELAYKIT_DOGFOOD_REUSE_CURRENT_ZIP=1 ./scripts/local-beta-dogfood-smoke.sh",
    "menu-ui-smoke": "./scripts/menu-bar-e2e-smoke.sh",
    "live-desktop-query": "$relaykit-desktop-query targeted request",
    "full-desktop-e2e": "./scripts/codex-desktop-manual-proof.sh run-auto --scenario ...",
}
selected_ids = {item["id"] for item in selected}
skipped = []
for command_id, command in catalog.items():
    if command_id in selected_ids:
        continue
    reason = {
        "swift-build": "no App source change requires a Swift build",
        "package-verify": "no packaging input changed",
        "extracted-app-dogfood": "requires separate authorization because it uses the exclusive installed App, port 19777, and user state",
        "menu-ui-smoke": "no App UI or lifecycle change requires GUI smoke",
        "live-desktop-query": "no explicit justified --live-query request",
        "full-desktop-e2e": "--full was not explicitly requested",
    }[command_id]
    skipped.append({"id": command_id, "command": command, "reason": reason})
    reasons[command_id] = reason

requires_build = bool(classes & {"gateway", "app_ui", "keychain", "gateway_lifecycle", "packaging"})
requires_package = "packaging" in classes
requires_gui = bool(classes & {"app_ui", "keychain", "gateway_lifecycle"}) or live or full

print(json.dumps({
    "status": "planned",
    "validation_profile": "changed-files",
    "base": base,
    "head": head,
    "changed_files": files,
    "change_classes": sorted(classes),
    "selected_commands": selected,
    "skipped_commands": skipped,
    "reasons": reasons,
    "requires_build": requires_build,
    "requires_package": requires_package,
    "requires_gui": requires_gui,
    "requires_live_query": live or full,
    "requires_full_e2e": full,
}, sort_keys=True))
PY
plan_status=$?
set -e
if [[ "${plan_status}" -ne 0 ]]; then
  cat "${plan}"
  exit "${plan_status}"
fi

if [[ "${mode}" == "plan-only" ]]; then
  cat "${plan}"
  exit 0
fi

results="${tmp}/results.jsonl"
overall_status=0
while IFS= read -r encoded; do
  command="$(python3 - "${encoded}" <<'PY'
import base64
import sys

sys.stdout.buffer.write(base64.b64decode(sys.argv[1], validate=True))
PY
  )" || fail "command_decode_failed"
  command_id="$(jq -r --arg command "${command}" '.selected_commands[] | select(.command == $command) | .id' "${plan}")"
  attempt_limit=2
  [[ "${command_id}" == "live-desktop-query" || "${command_id}" == "full-desktop-e2e" ]] && attempt_limit=1
  attempts=0
  status=1
  for ((attempt = 1; attempt <= attempt_limit; attempt++)); do
    attempts="${attempt}"
    set +e
    (cd "${ROOT}" && /bin/bash -lc "${command}") >&2
    status=$?
    set -e
    [[ "${status}" -eq 0 ]] && break
  done
  jq -nc --arg id "${command_id}" --arg command "${command}" --argjson attempts "${attempts}" --argjson exit_status "${status}" \
    '{id:$id,command:$command,attempts:$attempts,exit_status:$exit_status,status:(if $exit_status == 0 then "passed" else "failed" end)}' >>"${results}"
  [[ "${status}" -eq 0 ]] || overall_status=1
done < <(jq -r '.selected_commands[].command | @base64' "${plan}")

jq -s '.' "${results}" >"${tmp}/results.json"
jq --slurpfile results "${tmp}/results.json" --arg status "$([[ "${overall_status}" -eq 0 ]] && printf passed || printf failed)" \
  '. + {status:$status,execution_results:$results[0]}' "${plan}"
exit "${overall_status}"
