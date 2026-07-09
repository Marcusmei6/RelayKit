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

echo "RelayKit public boundary check passed"
