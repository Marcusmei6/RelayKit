#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

python3 - "${ROOT}" <<'PY'
from pathlib import Path
import re
import sys

root = Path(sys.argv[1])
workflow_dir = root / ".github" / "workflows"
required = {
    "fast-gates.yml": (
        "name: Fast Gates / Public boundary",
        "name: Fast Gates / Shell contracts",
        "name: Fast Gates / Go test, vet, and format",
        "./scripts/public-boundary-check.sh",
        "./scripts/github-actions-contract-test.sh",
        "go test ./...",
        "go vet ./...",
        "gofmt -l .",
    ),
    "macos-app.yml": (
        "name: macOS App / Swift and headless package validation",
        "swift build",
        "swift run RelayKitAppValidationTests",
        "./script/build_app_bundle.sh --verify",
        "./script/package_release.sh --verify",
    ),
    "macos-runtime-safety.yml": (
        "name: macOS Runtime Safety / Offline contract and fault harness",
        "./scripts/runtime-safety-fault-injection-test.sh",
        "./scripts/runtime-safety-fault-injection.sh",
    ),
    "protocol-contract.yml": (
        "name: Protocol Contract / Loopback adapters and Responses",
        "go test ./internal/server -count=1",
        "TestResponsesProxiesToFakeOpenAIChat",
        "TestNativeOpenAIResponsesNonStreamingPreservesProtocol",
        "TestResponsesP0ToolCallLifecycle",
    ),
}

forbidden = (
    "secrets.",
    "upload-artifact",
    "package_signed_release",
    "create_github_release",
    "notarytool",
    "relaykit_signing_identity",
    "relaykit_apple_team_id",
    "launchctl",
    "~/.codex",
    "/applications/relaykitapp.app",
)

errors = []

for filename, snippets in required.items():
    path = workflow_dir / filename
    if not path.is_file():
        errors.append(f"missing workflow: {filename}")
        continue

    text = path.read_text(encoding="utf-8")
    lower = text.lower()
    if not re.search(r"(?m)^on:\s*$", text):
        errors.append(f"{filename}: missing trigger block")
    for trigger in ("pull_request", "push"):
        if not re.search(rf"(?m)^  {trigger}:\s*$", text):
            errors.append(f"{filename}: missing {trigger} trigger")
    if not re.search(r"(?m)^permissions:\s*\n  contents: read\s*$", text):
        errors.append(f"{filename}: permissions must be contents read")
    if not re.search(r"(?m)^concurrency:\s*\n  group: .+\n  cancel-in-progress: true\s*$", text):
        errors.append(f"{filename}: missing cancel-in-progress concurrency")

    permission_block = re.search(r"(?m)^permissions:\s*\n((?:  .+\n?)*)", text)
    if permission_block and permission_block.group(1).strip() != "contents: read":
        errors.append(f"{filename}: unexpected permission")

    uses_lines = re.findall(r"(?m)^\s*-?\s*uses:\s*(\S+)\s*$", text)
    if not uses_lines:
        errors.append(f"{filename}: no pinned checkout action")
    for action in uses_lines:
        if not re.fullmatch(r"[^@\s]+@[0-9a-f]{40}", action):
            errors.append(f"{filename}: action is not pinned to a full SHA: {action}")

    jobs_match = re.search(r"(?m)^jobs:\s*$", text)
    if not jobs_match:
        errors.append(f"{filename}: missing jobs")
    else:
        jobs_text = text[jobs_match.end():]
        starts = list(re.finditer(r"(?m)^  ([A-Za-z0-9_-]+):\s*$", jobs_text))
        if not starts:
            errors.append(f"{filename}: no jobs parsed")
        for index, start in enumerate(starts):
            end = starts[index + 1].start() if index + 1 < len(starts) else len(jobs_text)
            block = jobs_text[start.end():end]
            if not re.search(r"(?m)^    timeout-minutes: [1-9][0-9]*\s*$", block):
                errors.append(f"{filename}: job {start.group(1)} lacks timeout-minutes")

    for snippet in snippets:
        if snippet not in text:
            errors.append(f"{filename}: missing required command: {snippet}")
    for token in forbidden:
        if token in lower:
            errors.append(f"{filename}: forbidden live/release token: {token}")

runtime_text = (workflow_dir / "macos-runtime-safety.yml").read_text(encoding="utf-8")
if re.search(r"\b(18787|19777)\b|/v1/responses|https?://|keychain|login", runtime_text, re.IGNORECASE):
    errors.append("macos-runtime-safety.yml: workflow must not use protected ports, login, Keychain, providers, or network endpoints")

protocol_text = (workflow_dir / "protocol-contract.yml").read_text(encoding="utf-8")
if "go test ./..." in protocol_text or re.search(r"https?://|curl\s", protocol_text, re.IGNORECASE):
    errors.append("protocol-contract.yml: protocol job must remain deterministic and package-scoped")

if errors:
    for error in errors:
        print(f"GitHub Actions contract failed: {error}", file=sys.stderr)
    raise SystemExit(1)

print("GitHub Actions workflow contract passed")
PY
