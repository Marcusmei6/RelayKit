#!/usr/bin/env bash
set -euo pipefail

APP_NAME="RelayKitApp"
APP_PROCESS_NAME="${APP_NAME}.bin"
APP_MARKETING_VERSION="${RELAYKIT_APP_VERSION:-0.1.6}"
APP_BUILD_NUMBER="${RELAYKIT_BUILD_NUMBER:-17}"
EXPECTED_TEAM_ID="WDZT4H533S"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="${ROOT_DIR}/dist"
TAG="v${APP_MARKETING_VERSION}"
RELEASE_DIR="${RELAYKIT_RELEASE_DIR:-${DIST_DIR}/github-release/${TAG}}"
SIGNED_ZIP="${RELEASE_DIR}/${APP_NAME}-${APP_MARKETING_VERSION}-signed.zip"
SHA256_PATH="${SIGNED_ZIP}.sha256"
MANIFEST_PATH="${RELEASE_DIR}/manifest.json"
NOTES_PATH="${RELEASE_DIR}/release-notes.md"
VERIFY_DIR=""
FRESH_CI_DIR=""
REQUIRED_CHECK_NAMES_JSON='[
  "Fast Public Boundary",
  "Fast Shell Contracts",
  "Fast Go Quality",
  "macOS App",
  "macOS Runtime Safety",
  "Protocol Contract"
]'

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

sha256() {
  /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'
}

app_tree_sha256() {
  local app="$1"
  [[ -d "${app}" ]] || fail "missing app bundle: ${app}"
  (
    local path relative mode kind
    while IFS= read -r path; do
      relative="${path#"${app}"/}"
      [[ "${path}" == "${app}" ]] && relative="."
      mode="$(/usr/bin/stat -f '%Lp' "${path}")"
      if [[ -L "${path}" ]]; then
        kind="symlink"
        printf '%s\0%s\0%s\0%s\0' "${kind}" "${relative}" "${mode}" "$(/usr/bin/readlink "${path}")"
      elif [[ -f "${path}" ]]; then
        kind="file"
        printf '%s\0%s\0%s\0%s\0' "${kind}" "${relative}" "${mode}" "$(sha256 "${path}")"
      elif [[ -d "${path}" ]]; then
        printf '%s\0%s\0%s\0' "directory" "${relative}" "${mode}"
      else
        fail "unsupported app tree entry: ${path}"
      fi
    done < <(LC_ALL=C /usr/bin/find "${app}" -depth -print | LC_ALL=C /usr/bin/sort)
  ) | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}'
}

cleanup() {
  [[ -n "${VERIFY_DIR}" ]] && rm -rf "${VERIFY_DIR}"
  [[ -n "${FRESH_CI_DIR}" ]] && rm -rf "${FRESH_CI_DIR}"
}
trap cleanup EXIT

repo="$(repo_target || true)"
[[ -n "${repo}" ]] || fail "missing GitHub repo target: set RELAYKIT_GITHUB_REPO or configure origin"
[[ "${repo}" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || fail "GitHub repo target must be owner/repo"
[[ -f "${SIGNED_ZIP}" && -f "${SHA256_PATH}" && -f "${MANIFEST_PATH}" ]] || fail "missing immutable signed release assets: run ./script/package_signed_release.sh first"
command -v gh >/dev/null 2>&1 || fail "missing gh CLI"
gh auth status >/dev/null 2>&1 || fail "gh CLI is not authenticated"

zip_sha256="$(sha256 "${SIGNED_ZIP}")"
checksum_sha256="$(/usr/bin/awk -v file="$(basename "${SIGNED_ZIP}")" 'NF == 2 && $2 == file { print $1 }' "${SHA256_PATH}")"
[[ "${checksum_sha256}" == "${zip_sha256}" ]] || fail "signed release checksum does not match zip"
jq -e \
  --arg artifact_sha256 "${zip_sha256}" \
  --arg version "${APP_MARKETING_VERSION}" \
  --arg build "${APP_BUILD_NUMBER}" \
  --arg team_id "${EXPECTED_TEAM_ID}" \
  --arg repo "${repo}" \
  --argjson required_names "${REQUIRED_CHECK_NAMES_JSON}" '
  ("https://github.com/" + $repo + "/actions/runs/") as $run_prefix
  | ([
      .hosted_ci.checks[].details_url
      | ltrimstr($run_prefix)
      | split("/")[0]
      | {
          id: tonumber,
          url: ($run_prefix + .)
        }
    ] | unique_by(.id)) as $derived_runs
  |
  (.schema_version == 2) and (.app_name == "RelayKitApp") and
  (.artifact_sha256 == $artifact_sha256) and (.version == $version) and (.build == $build) and
  (.team_id == $team_id) and (.hardened_runtime == true) and (.source_clean == true) and
  (.source_commit_sha | test("^[0-9a-f]{40}$")) and
  (.source_snapshot_sha256 | test("^[0-9a-f]{64}$")) and
  (.app_tree_sha256 | test("^[0-9a-f]{64}$")) and
  (.app_executable_sha256 | test("^[0-9a-f]{64}$")) and
  (.bundled_helper_executable_sha256 | test("^[0-9a-f]{64}$")) and
  (.hosted_ci.schema_version == 1) and
  (.hosted_ci.source_commit_sha == .source_commit_sha) and
  ([.hosted_ci.checks[].name] == $required_names) and
  ([.hosted_ci.checks[].id] | unique | length == 6) and
  (all(.hosted_ci.checks[];
    (.id | type) == "number" and
    (.conclusion == "success") and
    (.app_slug == "github-actions") and
    (.details_url | type) == "string" and
    (.details_url | startswith($run_prefix)) and
    (.details_url | ltrimstr($run_prefix) | test("^[0-9]+(/job/[0-9]+)?$")) and
    ((keys | sort) == ["app_slug", "conclusion", "details_url", "id", "name"])
  )) and
  (.hosted_ci.actions_runs | type == "array") and
  (.hosted_ci.actions_runs | length >= 1) and
  (.hosted_ci.actions_runs == $derived_runs) and
  (all(.hosted_ci.actions_runs[];
    (.id | type) == "number" and
    (.url | type) == "string" and
    (.url | startswith($run_prefix)) and
    (.url | ltrimstr($run_prefix) | test("^[0-9]+$")) and
    ((keys | sort) == ["id", "url"])
  ))
' "${MANIFEST_PATH}" >/dev/null || fail "signed release manifest does not match zip"

VERIFY_DIR="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/relaykit-draft-verify.XXXXXX")"
EXTRACTED_APP="${VERIFY_DIR}/${APP_NAME}.app"
/usr/bin/ditto -x -k "${SIGNED_ZIP}" "${VERIFY_DIR}"
[[ -d "${EXTRACTED_APP}" ]] || fail "signed zip is missing ${APP_NAME}.app"
[[ "$(app_tree_sha256 "${EXTRACTED_APP}")" == "$(jq -r '.app_tree_sha256' "${MANIFEST_PATH}")" ]] ||
  fail "signed zip App tree does not match manifest"
[[ "$(sha256 "${EXTRACTED_APP}/Contents/MacOS/${APP_PROCESS_NAME}")" == "$(jq -r '.app_executable_sha256' "${MANIFEST_PATH}")" ]] ||
  fail "signed zip App executable does not match manifest"
[[ "$(sha256 "${EXTRACTED_APP}/Contents/MacOS/relay")" == "$(jq -r '.bundled_helper_executable_sha256' "${MANIFEST_PATH}")" ]] ||
  fail "signed zip bundled helper does not match manifest"
codesign --verify --deep --strict --verbose=4 "${EXTRACTED_APP}" >/dev/null
spctl -a -vvv -t exec "${EXTRACTED_APP}" >/dev/null
xcrun stapler validate "${EXTRACTED_APP}" >/dev/null

source_commit_sha="$(jq -r '.source_commit_sha' "${MANIFEST_PATH}")"
FRESH_CI_DIR="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/relaykit-draft-ci.XXXXXX")"
fresh_ci_evidence="${FRESH_CI_DIR}/evidence.json"
"${ROOT_DIR}/scripts/github-required-checks.sh" \
  --repo "${repo}" \
  --sha "${source_commit_sha}" \
  --output "${fresh_ci_evidence}"
jq -e --slurp '.[0].hosted_ci == .[1]' "${MANIFEST_PATH}" "${fresh_ci_evidence}" >/dev/null ||
  fail "fresh GitHub checks do not match the signed release manifest"

mkdir -p "${RELEASE_DIR}"
cat >"${NOTES_PATH}" <<NOTES
# RelayKit ${APP_MARKETING_VERSION} Dogfood Beta

This is a signed and notarized RelayKit dogfood beta for macOS testers.

- Beta: yes
- Build: ${APP_BUILD_NUMBER}
- Minimum macOS: 14.0
- Bundle ID: dev.relaykit.app
- Signing: Developer ID signed
- Notarization: stapled and validated
- Auto-updater: not implemented yet; no appcast or Sparkle feed is published

## Install

Verify the downloaded checksum, extract the signed zip, quit an older RelayKit if it is running, and move \`RelayKitApp.app\` to \`/Applications\`.

## Uninstall

Quit RelayKit, remove \`/Applications/RelayKitApp.app\`, and optionally remove RelayKit App Support data if local provider settings and usage history are no longer needed.

## Rollback

When \`install_signed_release.sh\` replaces an existing App, it retains the prior App in a timestamped backup and prints the exact rollback command. Follow that printed command if rollback is needed; no backup exists until an install actually replaces an App.

## Known limitations

- Provider setup is local-only.
- Official Codex auth proof still uses the isolated RelayKit flow.
- Local usage history stays on the tester's Mac.
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
