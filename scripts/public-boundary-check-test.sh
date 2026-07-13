#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK="${ROOT}/scripts/public-boundary-check.sh"

fail() {
  printf 'public boundary contract test failed: %s\n' "$*" >&2
  exit 1
}

[[ -x "${CHECK}" ]] || fail "checker is missing"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/relaykit-public-boundary-test.XXXXXX")"
trap 'rm -rf "${tmp}"' EXIT

new_repo() {
  local repo="$1"
  mkdir -p "${repo}/scripts" "${repo}/docs/private"
  cp "${CHECK}" "${repo}/scripts/public-boundary-check.sh"
  chmod 700 "${repo}/scripts/public-boundary-check.sh"
  printf 'docs/private/\n' >"${repo}/.gitignore"
  git -C "${repo}" init -q
  git -C "${repo}" config user.email relaykit@example.test
  git -C "${repo}" config user.name 'RelayKit Boundary Test'
}

commit_repo() {
  local repo="$1"
  git -C "${repo}" add .
  git -C "${repo}" commit -qm fixture
}

safe_repo="${tmp}/safe"
new_repo "${safe_repo}"
printf '%s\n' \
  'Loopback: http://127.0.0.1:19777' \
  'Public fixture: https://provider.example.test/v1' \
  'Fixture marker: RELAYKIT_FAKE_SENTINEL_DO_NOT_USE' \
  'Policy: machine identifiers stay in local environment inputs' \
  'RFC documentation addresses: 192.0.2.10 198.51.100.20 203.0.113.30' \
  'Portable paths: $HOME/RelayKit and /tmp/relaykit-proof' >"${safe_repo}/safe.md"
printf '%s\n' '/Users/ignored-user/private' 'ssh ignored@192.168.44.8' >"${safe_repo}/docs/private/local.md"
commit_repo "${safe_repo}"
printf '%s\n' '/Users/untracked-user/private' >"${safe_repo}/untracked.txt"
"${safe_repo}/scripts/public-boundary-check.sh" >/dev/null || fail "allowed public fixtures were rejected"

assert_blocked() {
  local name="$1"
  local sentinel="$2"
  local repo="${tmp}/${name}"
  new_repo "${repo}"
  printf '%s\n' "${sentinel}" >"${repo}/leak.md"
  commit_repo "${repo}"
  if "${repo}/scripts/public-boundary-check.sh" >"${repo}/stdout" 2>"${repo}/stderr"; then
    fail "${name} tracked leak was accepted"
  fi
  grep -Fq 'public boundary check failed' "${repo}/stderr" || fail "${name} failure was not actionable"
}

assert_blocked personal-users-path 'Workspace: /Users/alice/workplace/RelayKit'
assert_blocked private-ssh-target 'ssh build-user@192.168.44.8'
assert_blocked machine-identifier 'Mac Pro `C02FAKE12345` is the acceptance host'
assert_blocked private-ip-10 'Gateway host: 10.23.4.5'
assert_blocked private-ip-172 'Gateway host: 172.20.4.5'
assert_blocked private-ip-192 'Gateway host: 192.168.44.8'
assert_blocked credential-shape "$(printf '%s%s%s' 's' 'k-' '12345678901234567890')"

assert_tracked_path_blocked() {
  local name="$1"
  local path="$2"
  local repo="${tmp}/${name}"
  new_repo "${repo}"
  mkdir -p "$(dirname "${repo}/${path}")"
  printf '%s\n' 'RELAYKIT_FAKE_SENTINEL_DO_NOT_USE' >"${repo}/${path}"
  git -C "${repo}" add .
  git -C "${repo}" add -f "${path}"
  git -C "${repo}" commit -qm fixture
  if "${repo}/scripts/public-boundary-check.sh" >"${repo}/stdout" 2>"${repo}/stderr"; then
    fail "${name} tracked path was accepted"
  fi
  grep -Fq 'Tracked private/build paths:' "${repo}/stderr" || fail "${name} did not identify the tracked path class"
  grep -Fq 'public boundary check failed' "${repo}/stderr" || fail "${name} failure was not actionable"
}

assert_tracked_path_blocked tracked-docs-private docs/private/fixture.md
assert_tracked_path_blocked tracked-scripts-private scripts/private/fixture.sh
assert_tracked_path_blocked tracked-dist dist/evidence.json
assert_tracked_path_blocked tracked-gateway-build gateway/bin/relay
assert_tracked_path_blocked tracked-app-build app/.build/fixture

printf '%s\n' 'RelayKit public boundary contract tests passed'
