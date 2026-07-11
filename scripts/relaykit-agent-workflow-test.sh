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
    "relaykit_test": ("relaykit-test.toml", "gpt-5.6-luna", "medium", "read-only"),
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
    "at most two concurrent write lanes",
    "Test, CR, and Release gates are sequential",
    "Never run these three roles concurrently",
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
    "nested generic `spawn_agent(task_name=...)`",
    "continues only inside the supplied plan",
    "requires explicit Backlog Expansion opt-in",
):
    assert required in workflow_docs, required

for role, values in agents.items():
    if role == "relaykit_planner":
        continue
    assert "do not delegate to other agents" in values["developer_instructions"].lower(), role

assert "Own only gateway/**" in agents["relaykit_gateway"]["developer_instructions"]
assert "Own only app/**" in agents["relaykit_app"]["developer_instructions"]
assert "docs/**, examples/**, .codex/**, .agents/**" in agents["relaykit_worker"]["developer_instructions"]
assert "Do not edit app/** or gateway/**" in agents["relaykit_worker"]["developer_instructions"]
assert "Execute only the selector-generated validation plan" in agents["relaykit_test"]["developer_instructions"]
assert "Only review. Do not edit files." in agents["relaykit_cr"]["developer_instructions"]
assert "only packaging, signing, notarization, release helpers, and release documentation" in agents["relaykit_release"]["developer_instructions"]
assert "Do not modify app/** or gateway/** product business code" in agents["relaykit_release"]["developer_instructions"]

print("RelayKit agent workflow contract tests passed")
PY
