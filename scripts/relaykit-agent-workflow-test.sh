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
    "relaykit_planner": ("relaykit-planner.toml", "gpt-5.6-sol", "xhigh", "workspace-write"),
    "relaykit_gateway": ("relaykit-gateway.toml", "gpt-5.6-terra", "high", "workspace-write"),
    "relaykit_app": ("relaykit-app.toml", "gpt-5.6-terra", "high", "workspace-write"),
    "relaykit_worker": ("relaykit-worker.toml", "gpt-5.6-sol", "high", "workspace-write"),
    "relaykit_test": ("relaykit-test.toml", "gpt-5.6-luna", "medium", "workspace-write"),
    "relaykit_cr": ("relaykit-cr.toml", "gpt-5.6-sol", "high", "read-only"),
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
        if raw == '"""':
            body = []
            while index < len(lines) and lines[index] != '"""':
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
    values = parse_agent(agent_dir / filename)
    agents[role] = values
    assert values["name"] == role, role
    assert values["model"] == model, role
    assert values["model_reasoning_effort"] == effort, role
    assert values["sandbox_mode"] == sandbox, role
    assert registrations[role] == f"agents/{filename}", role

efforts = {values["model_reasoning_effort"] for values in agents.values()}
assert efforts <= {"xhigh", "high", "medium"}, efforts
assert "ultra" not in efforts
assert "max" not in efforts

responsibility_contract = (
    "Main/root owns goal registration, pause/resume, risk assessment, and user confirmation. "
    "Main/root does not decompose tasks or implement changes. "
    "Planner decomposes work, designates and dispatches bounded roles, and owns remediation."
)
approval_contract = (
    "Main/root may approve one batch of 1-3 test messages only for the current task-bound isolated proof/session. "
    "Main/root approves only; the Planner-designated `relaykit_test` or `relaykit_worker` sends the messages. "
    "The batch is limited to 3 messages, stays bound to that isolated proof/session, does not read, refresh, copy, "
    "or migrate credentials, and does not touch global config/auth, LaunchAgents, shared services, or port `18787`. "
    "It does not publish, sign, delete, perform irreversible actions, automatically retry, or expand the approved count. "
    "More than 3 messages, any retry or count expansion, auth/login, shared ports or services, global config/auth, "
    "signing or release, and destructive or irreversible actions require user confirmation."
)
fast_path_contract = (
    "Tier 0/1 Fast Validation Path is eligible only when all of these are true: Validation Tier is 0 or 1; "
    "changed paths are limited to docs, public agent TOML, the workflow contract test, or ordinary project config; "
    "scope excludes app/**, gateway/**, credentials, Keychain, auth, shared services, LaunchAgents, port 18787, "
    "global Codex config, build, package, GUI, network, live requests, signing, and release; and Planner supplies an "
    "exact command allowlist."
)
fast_path_execution_contract = (
    "An eligible Fast Path uses exactly one Planner, one bounded Worker, one Test, and one CR. Test executes the exact "
    "allowlist directly without selector generation or `relaykit-validate.sh --plan-only`. Tier 2/3 and every ineligible "
    "change retain the selector path."
)
fast_path_closeout_contract = (
    "Main/root still performs no decomposition or implementation, but may verbatim-correct a missing ROLE field, "
    "field-name typo, or command-transcription error without replanning. Allow at most one remediation. After a "
    "test-assertion-only fix, rerun only the corresponding test and minimal CR recheck without repeating passed runtime "
    "metadata. Nonblocking Medium/Low findings become backlog evidence without scope expansion."
)
signed_beta_exception_contract = (
    "Signed Beta live-gate exception: `execution_allowed=false` from the signed-beta plan means plan-only and forbids "
    "selector-driven automatic execution; it does not deny a separately user-authorized, Planner-bounded one-time live gate."
)
signed_beta_global_guard_contract = (
    "The only permitted global config/auth interaction is the designated read-only non-content metadata/hash/signature "
    "guard. The guard must not mutate, copy, repair, restore, refresh, migrate, parse, inspect, print, or disclose global "
    "content. It may accept the current pre-run metadata/hash/signature as the baseline, must require exact before/after "
    "equality, and must fail closed on any mismatch or guard error."
)
signed_beta_bounds_contract = (
    "For this exception, Planner must bind one exact isolated session, artifact, scenario, and command allowlist to one fresh "
    "run: at most six commands, each command exactly once, with no retry, continuation, aggregation, relabeling, or reuse. "
    "The allowlist must encode redaction, the non-content global guard, no other global config/auth or shared-service/LaunchAgent "
    "access, no port `18787`, exact cleanup, and current run-bound evidence."
)
signed_beta_execution_contract = (
    "`relaykit_test` directly executes only that exact allowlist and must not rerun or reinterpret the selector, plan, "
    "scenario, or author inputs. Main/root performs mechanical dispatch only. Ordinary selector-path and Fast Path semantics "
    "remain unchanged. This exception does not expand or replace the ordinary 1-3 test-message approval rule."
)

contract_sources = {
    "planner": agents["relaykit_planner"]["developer_instructions"],
    "test": agents["relaykit_test"]["developer_instructions"],
    "agents-doc": (root / "docs" / "agents" / "README.md").read_text(encoding="utf-8"),
    "development-plan": (root / "docs" / "development-plan.md").read_text(encoding="utf-8"),
    "handoff": (root / "docs" / "handoff.md").read_text(encoding="utf-8"),
}
test_summary_contract = (
    "Eligible Tier 0/1 Fast Path executes the Planner exact command allowlist directly; otherwise Test executes the "
    "selector-generated plan."
)
assert all(test_summary_contract in contract_sources[name] for name in ("agents-doc", "development-plan"))
for name, source in contract_sources.items():
    assert responsibility_contract in source, name
    assert approval_contract in source, name
    assert fast_path_contract in source, name
    assert fast_path_execution_contract in source, name
    assert fast_path_closeout_contract in source, name
signed_beta_contracts = (
    signed_beta_exception_contract,
    signed_beta_global_guard_contract,
    signed_beta_bounds_contract,
    signed_beta_execution_contract,
)
for name, source in contract_sources.items():
    for contract in signed_beta_contracts:
        assert source.count(contract) == 1, (name, contract)

print("RelayKit agent workflow contract tests passed")
PY
