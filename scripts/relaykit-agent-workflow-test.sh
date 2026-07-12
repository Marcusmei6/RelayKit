#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AGENT_DIR="${ROOT}/.codex/agents"

"${ROOT}/scripts/relaykit-validate-agent-config.sh" "${AGENT_DIR}"/*.toml >/dev/null

python3 - "${ROOT}" <<'PY'
import ast
import re
import sys
from pathlib import Path

root = Path(sys.argv[1])
agent_dir = root / ".codex" / "agents"

expected = {
    "relaykit_planner": ("relaykit-planner.toml", "gpt-5.6-sol", "ultra", "workspace-write"),
    "relaykit_gateway": ("relaykit-gateway.toml", "gpt-5.6-sol", "high", "workspace-write"),
    "relaykit_app": ("relaykit-app.toml", "gpt-5.6-sol", "high", "workspace-write"),
    "relaykit_worker": ("relaykit-worker.toml", "gpt-5.6-sol", "high", "workspace-write"),
    "relaykit_test": ("relaykit-test.toml", "gpt-5.6-luna", "medium", "workspace-write"),
    "relaykit_cr": ("relaykit-cr.toml", "gpt-5.6-sol", "xhigh", "read-only"),
    "relaykit_release": ("relaykit-release.toml", "gpt-5.6-terra", "high", "workspace-write"),
}


def parse_agent(path):
    values = {}
    lines = path.read_text(encoding="utf-8").splitlines()
    index = 0
    while index < len(lines):
        line = lines[index]
        index += 1
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        match = re.match(r"^([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$", line)
        if not match:
            raise AssertionError(f"{path}:{index}: invalid assignment")
        key, raw = match.groups()
        if raw == '\"\"\"':
            body = []
            while index < len(lines) and lines[index] != '\"\"\"':
                body.append(lines[index])
                index += 1
            if index >= len(lines):
                raise AssertionError(f"{path}: unterminated string")
            index += 1
            values[key] = "\n".join(body)
        else:
            values[key] = ast.literal_eval(raw)
    return values


project_text = (root / ".codex" / "config.toml").read_text(encoding="utf-8")
assert re.search(r"(?m)^max_threads\s*=\s*8$", project_text)
assert re.search(r"(?m)^max_depth\s*=\s*2$", project_text)
registrations = dict(re.findall(
    r'(?ms)^\[agents\.([A-Za-z0-9_]+)\]\s*\nconfig_file\s*=\s*"([^"]+)"',
    project_text,
))
assert set(registrations) == set(expected), registrations

agents = {}
for role, (filename, model, effort, sandbox) in expected.items():
    path = agent_dir / filename
    assert path.is_file(), path
    values = parse_agent(path)
    agents[role] = values
    assert values["name"] == role, (path, values["name"])
    assert values["model"] == model, (path, values["model"])
    assert values["model_reasoning_effort"] == effort, (path, values["model_reasoning_effort"])
    assert values["sandbox_mode"] == sandbox, (path, values["sandbox_mode"])
    assert registrations[role] == f"agents/{filename}", (role, registrations[role])

efforts = [values["model_reasoning_effort"] for values in agents.values()]
assert efforts.count("ultra") == 1
assert "max" not in efforts
assert agents["relaykit_planner"]["model_reasoning_effort"] == "ultra"

planner = agents["relaykit_planner"]["developer_instructions"]
for required in (
    "only RelayKit role allowed to decide delegation",
    "Project role selection is root-mediated",
    "Do not call a nested generic `spawn_agent`",
    "PARENT DISPATCH REQUIRED",
    "Main/root is a mechanical dispatcher only",
    "must not patch files, redirect findings, choose another role, expand owned paths, change tiers, or bypass Planner",
    "returns each role's complete result to Planner",
    "at most two concurrent write lanes",
    "Test, CR, and Release gates are sequential",
    "Never run these three roles concurrently",
    "Every CR finding returns through Main/root to Planner",
    "Main/root must not send CR findings directly to an implementation role",
    "Planner dispositions every finding",
    "new bounded assignment to the correct original owning specialist",
    "remediation result returns to Planner",
    "fresh selector plan",
    "relaykit_test and relaykit_cr again, sequentially",
    "root-review fallback applies only when CR is unavailable after its bounded retry",
    "must never bypass actual CR findings",
    "CR UNAVAILABLE",
    "Main/root returns that unavailable result to Planner",
    "Main/root must not invoke the root review or decide closeout",
    "records CR UNAVAILABLE only in controller evidence and must not write any repository file",
    "same base commit, HEAD commit, changed-file set, complete diff SHA-256, and tracked-worktree snapshot",
    "returns the complete fallback review result to Planner",
    "Planner alone decides closeout",
    "fallback is forbidden when relaykit_cr returned actual findings",
    "reversible, public-safe, repository-local reads, edits, and focused checks",
    "supplied plan, owned paths, and assigned risk tier",
    "without asking the user again",
    "may pre-authorize those actions in the specialist assignment",
    "Main/root launches only the exact Planner-selected specialist",
    "The specialist performs the pre-authorized operation",
    "Main/root returns the specialist's complete result to Planner",
    "scope, ownership, risk-tier, validation-plan, or shared-state changes",
    "User approval remains required for product-scope or public-API changes, security changes, irreversible data behavior, real credentials, private providers, signing, publishing, hosted telemetry, destructive operations, paid or live requests, shared runtime mutation, or port 18787 takeover",
    "Backlog Expansion Gate is disabled by default",
    "BACKLOG EXPANSION: enabled",
    "task crossing app/** and gateway/** must be split",
    "selector's explicit boundary",
):
    assert required in planner, required

workflow_docs = (root / "docs" / "agents" / "README.md").read_text(encoding="utf-8")
for required in (
    "Project role selection is root-mediated",
    "PARENT DISPATCH REQUIRED",
    "Main/root is a mechanical dispatcher only",
    "must not patch files, redirect findings, choose another role, expand owned paths, change tiers, or bypass Planner",
    "returns each role's complete result to Planner",
    "nested generic `spawn_agent(task_name=...)`",
    "Every CR finding returns through Main/root to Planner",
    "Main/root must not send CR findings directly to an implementation role",
    "Planner dispositions every finding",
    "new bounded assignment to the correct original owning specialist",
    "remediation result returns to Planner",
    "fresh selector plan",
    "relaykit_test and relaykit_cr again, sequentially",
    "root-review fallback applies only when CR is unavailable after its bounded retry",
    "must never bypass actual CR findings",
    "CR UNAVAILABLE",
    "Main/root returns that unavailable result to Planner",
    "Main/root must not invoke the root review or decide closeout",
    "records CR UNAVAILABLE only in controller evidence and must not write any repository file",
    "same base commit, HEAD commit, changed-file set, complete diff SHA-256, and tracked-worktree snapshot",
    "returns the complete fallback review result to Planner",
    "Planner alone decides closeout",
    "fallback is forbidden when relaykit_cr returned actual findings",
    "reversible, public-safe, repository-local reads, edits, and focused checks",
    "supplied plan, owned paths, and assigned risk tier",
    "without asking the user again",
    "may pre-authorize those actions in the specialist assignment",
    "Main/root launches only the exact Planner-selected specialist",
    "The specialist performs the pre-authorized operation",
    "Main/root returns the specialist's complete result to Planner",
    "scope, ownership, risk-tier, validation-plan, or shared-state changes",
    "User approval remains required for product-scope or public-API changes, security changes, irreversible data behavior, real credentials, private providers, signing, publishing, hosted telemetry, destructive operations, paid or live requests, shared runtime mutation, or port 18787 takeover",
    "continues only inside the supplied plan",
    "requires explicit Backlog Expansion opt-in",
):
    assert required in workflow_docs, required

ambiguous_authorization = "Main/root merely carries out " + "that authorization"
assert ambiguous_authorization not in planner, ambiguous_authorization
assert ambiguous_authorization not in workflow_docs, ambiguous_authorization
ambiguous_fallback = "record the failure in `docs/handoff.md` and run a root-session read-only review"
assert ambiguous_fallback not in workflow_docs, ambiguous_fallback
for forbidden_handoff_write in (
    "records the unavailable state in docs/handoff.md",
    "record the failure in `docs/handoff.md`",
):
    assert forbidden_handoff_write not in planner, forbidden_handoff_write
    assert forbidden_handoff_write not in workflow_docs, forbidden_handoff_write
loose_same_diff = "read-only review over the same diff"
assert loose_same_diff not in planner, loose_same_diff
assert loose_same_diff not in workflow_docs, loose_same_diff

for role, values in agents.items():
    if role == "relaykit_planner":
        continue
    assert "do not delegate to other agents" in values["developer_instructions"].lower(), role

assert "Own only gateway/**" in agents["relaykit_gateway"]["developer_instructions"]
assert "Own only app/**" in agents["relaykit_app"]["developer_instructions"]
assert "docs/**, examples/**, .codex/**, .agents/**" in agents["relaykit_worker"]["developer_instructions"]
assert "Do not edit app/** or gateway/**" in agents["relaykit_worker"]["developer_instructions"]
assert "Execute only the selector-generated validation plan" in agents["relaykit_test"]["developer_instructions"]
assert "tracked-worktree" in agents["relaykit_test"]["developer_instructions"]
assert "setup id" in agents["relaykit_test"]["developer_instructions"]
assert "session id" in agents["relaykit_test"]["developer_instructions"]
assert "Only review. Do not edit files." in agents["relaykit_cr"]["developer_instructions"]
assert "Return every finding through Main/root to Planner" in agents["relaykit_cr"]["developer_instructions"]
assert "only packaging, signing, notarization, release helpers, and release documentation" in agents["relaykit_release"]["developer_instructions"]
assert "Do not modify app/** or gateway/** product business code" in agents["relaykit_release"]["developer_instructions"]

development_plan = (root / "docs" / "development-plan.md").read_text(encoding="utf-8")
handoff = (root / "docs" / "handoff.md").read_text(encoding="utf-8")
for current_truth in (
    "Workflow 5.6 is current on `main`",
    "fresh exact `relaykit_planner` and `relaykit_worker` runtime smoke",
    "authoritative parent/root `turn_context` and direct role-thread metadata",
    "Static TOML and Agent self-report are not runtime proof",
    "The responsibility contract is implemented",
    "Acceptance requires fresh sequential `relaykit_test` and `relaykit_cr` evidence returned to Planner",
    "Transient gate outcomes belong in controller evidence and require no source edit after CR",
    "An unchanged-diff CR `SHIP IT` after Test `PASS` permits Planner to close the objective without a source edit",
):
    assert current_truth in development_plan, current_truth
    assert current_truth in handoff, current_truth
for transient_state in (
    "Independent `relaykit_test` passed",
    "CR1 returned `NEEDS REMEDIATION`",
    "RK-WF-5.6-MAIN-PLANNER-CLOSEOUT-R1",
    "fresh `relaykit_test` and `relaykit_cr` remain pending",
    "Final closeout is not claimed",
):
    assert transient_state not in development_plan, transient_state
    assert transient_state not in handoff, transient_state
assert "active pre-merge gate" not in handoff
assert "merge this feature branch into `main`" not in development_plan
stale_pending = "pending independent " + "`relaykit_test` and `relaykit_cr`"
assert stale_pending not in development_plan, stale_pending
assert stale_pending not in handoff, stale_pending

print("RelayKit agent workflow contract tests passed")
PY
