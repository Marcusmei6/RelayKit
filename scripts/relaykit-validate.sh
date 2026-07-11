#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
base=""
head=""
mode=""
changed_files_file=""
full=false
live_query=false

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
    *) fail "invalid_arguments" ;;
  esac
done

[[ -n "${base}" && -n "${head}" && -n "${mode}" ]] || fail "invalid_arguments"
base_sha="$(git -C "${ROOT}" rev-parse --verify "${base}^{commit}" 2>/dev/null)" || fail "base_invalid"
head_sha="$(git -C "${ROOT}" rev-parse --verify "${head}^{commit}" 2>/dev/null)" || fail "head_invalid"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/relaykit-validate.XXXXXX")"
trap 'rm -rf "${tmp}"' EXIT
changed_input="${tmp}/changed-files.bin"
changed_format="nul"

if [[ -n "${changed_files_file}" ]]; then
  [[ "${changed_files_file}" = /* && -f "${changed_files_file}" && ! -L "${changed_files_file}" ]] || fail "changed_files_fixture_invalid"
  [[ "$(stat -f '%u:%Lp' "${changed_files_file}")" == "$(id -u):600" ]] || fail "changed_files_fixture_permissions"
  cp "${changed_files_file}" "${changed_input}"
  changed_format="lines"
else
  git -C "${ROOT}" diff --name-only -z --diff-filter=ACMRTUXB "${base_sha}" "${head_sha}" -- >"${changed_input}"
fi

plan="${tmp}/plan.json"
set +e
python3 - "${ROOT}" "${base_sha}" "${head_sha}" "${changed_input}" "${changed_format}" "${full}" "${live_query}" >"${plan}" <<'PY'
import json
import shlex
import sys
from pathlib import PurePosixPath

root, base, head, changed_path, changed_format, full_raw, live_raw = sys.argv[1:]
raw = open(changed_path, "rb").read()
if changed_format == "nul":
    files = [part.decode("utf-8") for part in raw.split(b"\0") if part]
else:
    files = [line.strip() for line in raw.decode("utf-8").splitlines() if line.strip()]
files = sorted(set(files))
full = full_raw == "true"
live = live_raw == "true"

classes = set()
shell_files = []
gateway_dirs = set()

def is_docs(path):
    name = PurePosixPath(path).name
    return path.startswith("docs/") or path.startswith(".github/") or name in {
        "README.md", "SECURITY.md", "CONTRIBUTING.md", "CODE_OF_CONDUCT.md"
    } or path.endswith((".md", ".markdown"))

for path in files:
    lower = path.lower()
    if is_docs(path) and not path.startswith(".agents/skills/"):
        classes.add("docs")
        continue
    if path.startswith(".codex/agents/") or path == "AGENTS.md":
        classes.add("workflow")
    if path.startswith(".agents/skills/"):
        classes.add("skill")
    if path.startswith("scripts/relaykit-validate"):
        classes.update(("validation", "shell"))
    if path.startswith("scripts/codex-desktop-query-backend"):
        classes.update(("skill", "harness", "shell", "ax"))
    if path.startswith("scripts/codex-desktop-manual-proof"):
        classes.update(("harness", "shell"))
    if path.startswith("scripts/codex-desktop-ax-driver"):
        classes.update(("ax", "harness"))
        if path.endswith(".sh"):
            classes.add("shell")
    if path.endswith(".sh"):
        classes.add("shell")
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
        if path.endswith(".sh"):
            classes.add("shell")
            shell_files.append(path)
    if path.endswith((".entitlements", "/Info.plist")):
        classes.add("packaging")

if not files:
    classes.add("no_changes")

targeted_live_classes = {"keychain", "gateway_lifecycle", "adapter", "catalog", "ax"}
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
add("diff-check", f"git diff --check {quoted_base} {quoted_head} --", "all changes require a whitespace/error check")
add("public-boundary", "./scripts/public-boundary-check.sh", "all plans preserve the public repository boundary")

if "docs" in classes:
    add("docs-consistency", f"./scripts/relaykit-validate-docs.sh --base {quoted_base} --head {quoted_head}", "changed documentation must keep tracked local links valid")
if shell_files:
    quoted = " ".join(shlex.quote(path) for path in sorted(set(shell_files)))
    add("shell-syntax", f"bash -n {quoted}", "changed shell files require syntax validation")
if "validation" in classes:
    add("validation-selector-contract", "./scripts/relaykit-validate-test.sh", "validation routing changes require fixture matrix tests")
if "skill" in classes:
    add("desktop-query-runner-contract", ".agents/skills/relaykit-desktop-query/scripts/run-query-test.sh", "Skill interface changes require runner contract tests")
    add("desktop-query-backend-contract", "./scripts/codex-desktop-query-backend-test.sh", "default backend changes require focused contract tests")
if "harness" in classes:
    add("manual-proof-contract", "./scripts/codex-desktop-manual-proof-test.sh", "proof harness changes require focused evidence and safety tests")
if "ax" in classes:
    add("ax-driver-contract", "./scripts/codex-desktop-ax-driver-test.sh", "AX changes require deterministic selector tests")
if "workflow" in classes:
    tomls = [path for path in files if path.startswith(".codex/agents/") and path.endswith(".toml")]
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
        "test -n \"${RELAYKIT_VALIDATE_LIVE_MODEL:-}\" && test -n \"${RELAYKIT_VALIDATE_LIVE_QUERY_FILE:-}\" && test -n \"${RELAYKIT_VALIDATE_CATALOG_EVIDENCE:-}\" && test -n \"${RELAYKIT_VALIDATE_CATALOG_SHA256:-}\" && test -n \"${RELAYKIT_VALIDATE_ARTIFACT_SHA256:-}\" && .agents/skills/relaykit-desktop-query/scripts/run-query.sh --model \"${RELAYKIT_VALIDATE_LIVE_MODEL}\" --query-file \"${RELAYKIT_VALIDATE_LIVE_QUERY_FILE}\" --expect \"${RELAYKIT_VALIDATE_LIVE_EXPECT:-plain}\" --catalog-evidence \"${RELAYKIT_VALIDATE_CATALOG_EVIDENCE}\" --catalog-sha256 \"${RELAYKIT_VALIDATE_CATALOG_SHA256}\" --artifact-sha256 \"${RELAYKIT_VALIDATE_ARTIFACT_SHA256}\"",
        "an explicit high-risk plan requested one targeted Skill query",
    )
if "packaging" in classes:
    add("package-verify", "./script/package_release.sh --verify", "packaging inputs require package verification")
    add("extracted-app-dogfood", "RELAYKIT_DOGFOOD_REUSE_CURRENT_ZIP=1 ./scripts/local-beta-dogfood-smoke.sh", "packaging inputs require extracted-App dogfood")
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
        "extracted-app-dogfood": "no packaging input changed",
        "menu-ui-smoke": "no App UI or lifecycle change requires GUI smoke",
        "live-desktop-query": "no explicit justified --live-query request",
        "full-desktop-e2e": "--full was not explicitly requested",
    }[command_id]
    skipped.append({"id": command_id, "command": command, "reason": reason})
    reasons[command_id] = reason

requires_build = bool(classes & {"gateway", "app_ui", "keychain", "gateway_lifecycle", "packaging"})
requires_package = "packaging" in classes
requires_gui = bool(classes & {"app_ui", "keychain", "gateway_lifecycle", "packaging"}) or live or full

print(json.dumps({
    "status": "planned",
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
  command="$(printf '%s' "${encoded}" | base64 -D)"
  command_id="$(jq -r --arg command "${command}" '.selected_commands[] | select(.command == $command) | .id' "${plan}")"
  attempt=1
  status=1
  while (( attempt <= 2 )); do
    set +e
    (cd "${ROOT}" && /bin/bash -lc "${command}") >&2
    status=$?
    set -e
    [[ "${status}" -eq 0 ]] && break
    attempt=$((attempt + 1))
  done
  jq -nc --arg id "${command_id}" --arg command "${command}" --argjson attempts "$((attempt > 2 ? 2 : attempt))" --argjson exit_status "${status}" \
    '{id:$id,command:$command,attempts:$attempts,exit_status:$exit_status,status:(if $exit_status == 0 then "passed" else "failed" end)}' >>"${results}"
  [[ "${status}" -eq 0 ]] || overall_status=1
done < <(jq -r '.selected_commands[].command | @base64' "${plan}")

jq -s '.' "${results}" >"${tmp}/results.json"
jq --slurpfile results "${tmp}/results.json" --arg status "$([[ "${overall_status}" -eq 0 ]] && printf passed || printf failed)" \
  '. + {status:$status,execution_results:$results[0]}' "${plan}"
exit "${overall_status}"
