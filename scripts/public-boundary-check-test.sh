#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK="${ROOT}/scripts/public-boundary-check.sh"
BUILD_SCRIPT="${ROOT}/script/build_app_bundle.sh"
DOGFOOD_SCRIPT="${ROOT}/scripts/local-beta-dogfood-smoke.sh"

fail() {
  printf 'public boundary contract test failed: %s\n' "$*" >&2
  exit 1
}

[[ -x "${CHECK}" ]] || fail "checker is missing"
grep -Fq 'go build -trimpath' "${BUILD_SCRIPT}" || fail "bundled gateway build must strip local source paths"
grep -Fq -- '-c release' "${BUILD_SCRIPT}" || fail "bundled App must use the release Swift configuration"
grep -Fq -- '-debug-prefix-map' "${BUILD_SCRIPT}" || fail "bundled App must remap debug source paths"
grep -Fq -- '-file-prefix-map' "${BUILD_SCRIPT}" || fail "bundled App must remap file source paths"
grep -Fq '"${HOME}=~"' "${BUILD_SCRIPT}" || fail "bundled App must remap home-derived build paths"
grep -Fq 'mktemp -d /tmp/relaykit-swift-build.XXXXXX' "${BUILD_SCRIPT}" ||
  fail "bundled App must create a fresh Swift scratch directory outside the home directory"
grep -Fq 'rm -rf -- "${swift_scratch}"' "${BUILD_SCRIPT}" ||
  fail "bundled App must clean only its bounded Swift scratch directory"
grep -Fq -- '--scratch-path "${swift_scratch}"' "${BUILD_SCRIPT}" ||
  fail "bundled App must use its scratch directory for every Swift invocation"
grep -Fq -- '-module-cache-path' "${BUILD_SCRIPT}" ||
  fail "bundled App must bind the Swift module cache to its scratch directory"
grep -Fq -- '-fmodules-cache-path=${clang_module_cache}' "${BUILD_SCRIPT}" ||
  fail "bundled App must bind the Clang module cache to its scratch directory"
for clang_prefix_map in debug file macro; do
  grep -Fq -- "-Xcc \"-f${clang_prefix_map}-prefix-map=\${prefix_map}\"" "${BUILD_SCRIPT}" ||
    fail "bundled App must remap Clang ${clang_prefix_map} paths"
done
grep -Fq 'scan_release_binary_for_personal_paths' "${BUILD_SCRIPT}" ||
  fail "bundle build must raw-scan binaries before signing"
if grep -Fq 'strings "${binary}"' "${BUILD_SCRIPT}"; then
  fail "bundle build must not depend on strings output for personal-path scanning"
fi

for forbidden_build_runtime_action in \
  'pkill' \
  'killall' \
  'lsof' \
  'launchctl' \
  '/Applications/' \
  '19777' \
  '18787' \
  'LaunchAgents' \
  '.codex/' \
  'agent-local-gateway'; do
  if grep -Fq "${forbidden_build_runtime_action}" "${BUILD_SCRIPT}"; then
    fail "bundle build/package entry must not inspect or terminate App, port, LaunchAgent, or shared runtime state: ${forbidden_build_runtime_action}"
  fi
done
if grep -Eq '(^|[^[:alnum:]_])(kill|killall|pkill)([[:space:]]|$)' "${BUILD_SCRIPT}"; then
  fail "bundle build/package entry must not terminate processes"
fi

grep -Fq 'APP_BUNDLE="${INSTALL_DIR}/RelayKitApp.app"' "${DOGFOOD_SCRIPT}" ||
  fail "dogfood must bind App ownership to its extracted artifact"
grep -Fq 'APP_REAL="${APP_BUNDLE}/Contents/MacOS/RelayKitApp.bin"' "${DOGFOOD_SCRIPT}" ||
  fail "dogfood must bind executable ownership to its extracted artifact"
grep -Fq 'BUNDLED_RELAY="${APP_BUNDLE}/Contents/MacOS/relay"' "${DOGFOOD_SCRIPT}" ||
  fail "dogfood must bind helper ownership to its extracted artifact"
grep -Fq 'APP_PID="$(pgrep -f "^${APP_REAL}$" | tail -1 || true)"' "${DOGFOOD_SCRIPT}" ||
  fail "dogfood must capture only its exact extracted App PID"
grep -Fq 'pkill -f "^${BUNDLED_RELAY} -listen 127.0.0.1:19777 "' "${DOGFOOD_SCRIPT}" ||
  fail "dogfood cleanup must target only its exact extracted helper"
grep -Fq 'pgrep -x RelayKitApp.bin' "${DOGFOOD_SCRIPT}" ||
  fail "dogfood must fail closed when another RelayKit App is running"
grep -Fq 'port_free 19777 || fail' "${DOGFOOD_SCRIPT}" ||
  fail "dogfood must fail closed when another 19777 listener exists"
if grep -Eq 'pkill[[:space:]]+-x[[:space:]]+("?RelayKitApp|"?RelayKitApp\.bin)' "${DOGFOOD_SCRIPT}"; then
  fail "dogfood must not terminate an unrelated RelayKit App by process name"
fi

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
