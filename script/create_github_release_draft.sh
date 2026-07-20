#!/usr/bin/env bash
set -euo pipefail

APP_NAME="RelayKitApp"
APP_MARKETING_VERSION="${RELAYKIT_APP_VERSION:-0.1.1}"
EXPECTED_TEAM_ID="WDZT4H533S"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="${ROOT_DIR}/dist"
TAG="v${APP_MARKETING_VERSION}"
RELEASE_DIR="${DIST_DIR}/github-release/${TAG}"
SIGNED_ZIP="${RELEASE_DIR}/${APP_NAME}-${APP_MARKETING_VERSION}-signed.zip"
SHA256_PATH="${SIGNED_ZIP}.sha256"
MANIFEST_PATH="${RELEASE_DIR}/manifest.json"
NOTES_PATH="${RELEASE_DIR}/release-notes.md"
VERIFY_DIR="${DIST_DIR}/verify-github-release"
EXTRACTED_APP="${VERIFY_DIR}/${APP_NAME}.app"

repo_target() {
  if [[ -n "${RELAYKIT_GITHUB_REPO:-}" ]]; then
    printf '%s\n' "${RELAYKIT_GITHUB_REPO}"
    return
  fi
  if [[ -n "${GH_REPO:-}" ]]; then
    printf '%s\n' "${GH_REPO}"
    return
  fi
  local origin
  origin="$(git -C "${ROOT_DIR}" remote get-url origin 2>/dev/null || true)"
  [[ -n "${origin}" ]] || return 1
  printf '%s\n' "${origin}" | sed -E 's#^git@github.com:##; s#^https://github.com/##; s#\.git$##'
}

fail() {
  echo "$1" >&2
  exit 1
}

repo="$(repo_target || true)"
[[ -n "${repo}" ]] || fail "missing GitHub repo target: set RELAYKIT_GITHUB_REPO or configure origin"
[[ -f "${SIGNED_ZIP}" && -f "${SHA256_PATH}" && -f "${MANIFEST_PATH}" ]] || fail "missing immutable signed release assets: run ./script/package_signed_release.sh first"
command -v gh >/dev/null 2>&1 || fail "missing gh CLI"
gh auth status >/dev/null 2>&1 || fail "gh CLI is not authenticated"

zip_sha256="$(/usr/bin/shasum -a 256 "${SIGNED_ZIP}" | /usr/bin/awk '{print $1}')"
checksum_sha256="$(/usr/bin/awk -v file="$(basename "${SIGNED_ZIP}")" 'NF == 2 && $2 == file { print $1 }' "${SHA256_PATH}")"
[[ "${checksum_sha256}" == "${zip_sha256}" ]] || fail "signed release checksum does not match zip"
jq -e --arg artifact_sha256 "${zip_sha256}" --arg version "${APP_MARKETING_VERSION}" --arg team_id "${EXPECTED_TEAM_ID}" '
  (.schema_version == 1) and (.app_name == "RelayKitApp") and
  (.artifact_sha256 == $artifact_sha256) and (.version == $version) and
  (.team_id == $team_id) and (.hardened_runtime == true) and
  (.source_commit_sha | test("^[0-9a-f]{40}$")) and
  (.source_snapshot_sha256 | test("^[0-9a-f]{64}$")) and
  (.app_tree_sha256 | test("^[0-9a-f]{64}$")) and
  (.app_executable_sha256 | test("^[0-9a-f]{64}$"))
' "${MANIFEST_PATH}" >/dev/null || fail "signed release manifest does not match zip"

rm -rf "${VERIFY_DIR}"
mkdir -p "${VERIFY_DIR}"
/usr/bin/ditto -x -k "${SIGNED_ZIP}" "${VERIFY_DIR}"
codesign --verify --deep --strict --verbose=4 "${EXTRACTED_APP}" >/dev/null
spctl -a -vvv -t exec "${EXTRACTED_APP}" >/dev/null
xcrun stapler validate "${EXTRACTED_APP}" >/dev/null

mkdir -p "${RELEASE_DIR}"
cat >"${NOTES_PATH}" <<NOTES
# RelayKit ${APP_MARKETING_VERSION} Dogfood Beta

This is a signed and notarized RelayKit dogfood beta for macOS testers.

- Beta: yes
- Minimum macOS: 14.0
- Bundle ID: dev.relaykit.app
- Signing: Developer ID signed
- Notarization: stapled and validated
- Auto-updater: not implemented yet; no appcast or Sparkle feed is published

Known limitations:

- Provider setup is local-only.
- Official Codex auth proof still uses the isolated RelayKit flow.
- Local usage history stays on the tester's Mac.
- Uninstall is manual: quit RelayKit, remove the app, and optionally remove RelayKit App Support data.
NOTES

gh release create "${TAG}" \
  --repo "${repo}" \
  --draft \
  --title "RelayKit ${APP_MARKETING_VERSION} Dogfood Beta" \
  --notes-file "${NOTES_PATH}" \
  "${SIGNED_ZIP}" \
  "${SHA256_PATH}" \
  "${MANIFEST_PATH}"

echo "RelayKit GitHub Release draft created for ${TAG}"
