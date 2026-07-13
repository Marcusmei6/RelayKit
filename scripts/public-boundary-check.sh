#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

fail() {
  echo "public boundary check failed: $1" >&2
  exit 1
}

print_hits() {
  local title="$1"
  local hits="$2"
  if [[ -n "${hits}" ]]; then
    echo "${title}" >&2
    printf '%s\n' "${hits}" >&2
  fi
}

PRIVATE_PROVIDER_PATTERN='cc''club|CC''CLUB|claude-code''\.club|Claude Code'' Club|relaykit\.provider\.cc''club'
private_hits="$(git grep -n -I -E "${PRIVATE_PROVIDER_PATTERN}" -- . ':!docs/private/**' ':!scripts/private/**' || true)"
print_hits "Private provider/domain hits:" "${private_hits}"
[[ -z "${private_hits}" ]] || fail "tracked files contain private provider/domain references"

SECRET_SHAPE_PATTERN='sk-[A-Za-z0-9_-]{20,}|Bearer[[:space:]]+[A-Za-z0-9._-]{20,}|"(refresh_token|access_token)"[[:space:]]*:|BEGIN (RSA|OPENSSH|PRIVATE) KEY|AKIA[0-9A-Z]{16}'
secret_hits="$(git grep -n -I -E "${SECRET_SHAPE_PATTERN}" -- . ':!docs/private/**' ':!scripts/private/**' || true)"
secret_hits="$(printf '%s\n' "${secret_hits}" | grep -Ev '(^$|_test\.(go|swift):|gateway/internal/config/config\.go:)' || true)"
print_hits "Credential-shaped hits:" "${secret_hits}"
[[ -z "${secret_hits}" ]] || fail "tracked files contain credential-shaped content"

sensitive_paths="$(git ls-files | grep -E '(^|/)(auth\.json|.*\.log$|.*usage.*\.jsonl$|.*conversation.*\.js$)|\.(pem|key|p12|mobileprovision)$' || true)"
print_hits "Sensitive tracked paths:" "${sensitive_paths}"
[[ -z "${sensitive_paths}" ]] || fail "tracked files include sensitive artifact paths"

private_paths="$(git ls-files docs/private scripts/private dist gateway/bin app/.build || true)"
print_hits "Tracked private/build paths:" "${private_paths}"
[[ -z "${private_paths}" ]] || fail "ignored private/build paths are tracked"

portable_boundary_hits="$(python3 - "${ROOT_DIR}" <<'PY'
import ipaddress
import pathlib
import re
import subprocess
import sys

root = pathlib.Path(sys.argv[1])
tracked = subprocess.run(
    ["git", "-C", str(root), "ls-files", "-z"],
    check=True,
    stdout=subprocess.PIPE,
).stdout.split(b"\0")
skip = {
    "scripts/public-boundary-check.sh",
    "scripts/public-boundary-check-test.sh",
}
users_path = re.compile(r"/Users/[^\s'\"`]+")
ipv4 = re.compile(r"(?<![\d.])(?:\d{1,3}\.){3}\d{1,3}(?![\d.])")
ssh_target = re.compile(r"\bssh\b[^\n]*?\b[^\s@]+@((?:\d{1,3}\.){3}\d{1,3})", re.IGNORECASE)
mac_identifier = re.compile(r"\bMac\s+Pro\s+`([A-Z0-9]{8,16})`", re.IGNORECASE)
labeled_identifier = re.compile(
    r"\b(?:machine(?:\s+(?:id|identifier))?|serial(?:\s+number)?|hardware\s+uuid|device\s+id)"
    r"\s*(?:is|=|:)?\s*[`'\"]?(?=[A-Z0-9-]*\d)([A-Z0-9][A-Z0-9-]{7,35})",
    re.IGNORECASE,
)
private_networks = tuple(
    ipaddress.ip_network(value) for value in ("10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16")
)

def private_address(value):
    try:
        address = ipaddress.ip_address(value)
    except ValueError:
        return False
    return any(address in network for network in private_networks)

for encoded in tracked:
    if not encoded:
        continue
    relative = encoded.decode("utf-8", "strict")
    if relative in skip:
        continue
    path = root / relative
    try:
        body = path.read_bytes()
    except (OSError, ValueError):
        continue
    if b"\0" in body:
        continue
    text = body.decode("utf-8", "replace")
    for number, line in enumerate(text.splitlines(), 1):
        categories = []
        if users_path.search(line):
            categories.append("personal-users-path")
        ssh_match = ssh_target.search(line)
        if ssh_match and private_address(ssh_match.group(1)):
            categories.append("private-network-ssh-target")
        if mac_identifier.search(line) or labeled_identifier.search(line):
            categories.append("machine-identifier")
        if any(private_address(match.group(0)) for match in ipv4.finditer(line)):
            categories.append("private-ipv4-address")
        for category in dict.fromkeys(categories):
            print(f"{relative}:{number}:{category}")
PY
)"
print_hits "Non-portable tracked content:" "${portable_boundary_hits}"
[[ -z "${portable_boundary_hits}" ]] || fail "tracked files contain machine-local paths or network identifiers"

echo "RelayKit public boundary check passed"
