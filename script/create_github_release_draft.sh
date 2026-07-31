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
NOTES_PATH=""
VERIFY_DIR=""
FRESH_CI_DIR=""
TEST_MODE="${RELAYKIT_SIGNED_RELEASE_TEST_MODE:-0}"
CODESIGN_BIN="/usr/bin/codesign"
SPCTL_BIN="/usr/sbin/spctl"
XCRUN_BIN="/usr/bin/xcrun"
TAG_CREATION_ATTEMPTED=false
RELEASE_CREATION_ATTEMPTED=false
RELEASE_RUN_MARKER=""
source_commit_sha=""
repo=""
REQUIRED_CHECK_NAMES_JSON='[
  "Fast Public Boundary",
  "Fast Shell Contracts",
  "Fast Go Quality",
  "macOS App",
  "macOS Runtime Safety",
  "Protocol Contract"
]'

if [[ "${TEST_MODE}" == "1" ]]; then
  : "${RELAYKIT_TEST_CODESIGN_BIN:?test mode requires RELAYKIT_TEST_CODESIGN_BIN}"
  : "${RELAYKIT_TEST_SPCTL_BIN:?test mode requires RELAYKIT_TEST_SPCTL_BIN}"
  : "${RELAYKIT_TEST_XCRUN_BIN:?test mode requires RELAYKIT_TEST_XCRUN_BIN}"
  CODESIGN_BIN="${RELAYKIT_TEST_CODESIGN_BIN}"
  SPCTL_BIN="${RELAYKIT_TEST_SPCTL_BIN}"
  XCRUN_BIN="${RELAYKIT_TEST_XCRUN_BIN}"
fi

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

remote_releases_for_tag() {
  gh api --paginate --slurp "repos/${repo}/releases?per_page=100" |
    jq -c --arg tag "${TAG}" '[.[][] | select(.tag_name == $tag)]'
}

remote_exact_tag_refs() {
  gh api "repos/${repo}/git/matching-refs/tags/${TAG}" |
    jq -c --arg ref "refs/tags/${TAG}" '[.[] | select(.ref == $ref)]'
}

reconcile_failed_remote_mutation() {
  local cleanup_failed=0 releases owned_count foreign_count release_id remaining_refs tag_count tag_target

  if [[ "${RELEASE_CREATION_ATTEMPTED}" == "true" ]]; then
    if [[ -z "${RELEASE_RUN_MARKER}" ]]; then
      echo "could not reconcile failed draft creation: missing run marker" >&2
      cleanup_failed=1
    elif ! releases="$(remote_releases_for_tag)"; then
      echo "could not query GitHub releases after failed draft creation" >&2
      cleanup_failed=1
    else
      owned_count="$(jq --arg marker "${RELEASE_RUN_MARKER}" \
        '[.[] | select(.draft == true and ((.body // "") | contains($marker)))] | length' <<<"${releases}")"
      foreign_count="$(jq --arg marker "${RELEASE_RUN_MARKER}" \
        '[.[] | select((.draft != true) or (((.body // "") | contains($marker)) | not))] | length' <<<"${releases}")"
      if [[ "${foreign_count}" != "0" ]]; then
        echo "failed draft creation found an unowned release for ${TAG}; remote state was not deleted" >&2
        cleanup_failed=1
      elif [[ "${owned_count}" != "0" ]]; then
        while IFS= read -r release_id; do
          [[ "${release_id}" =~ ^[0-9]+$ ]] || {
            echo "failed draft creation returned an invalid release id" >&2
            cleanup_failed=1
            continue
          }
          if ! gh api --method DELETE "repos/${repo}/releases/${release_id}" >/dev/null; then
            if ! releases="$(remote_releases_for_tag)"; then
              echo "could not query GitHub releases after a failed cleanup request" >&2
              cleanup_failed=1
            elif jq -e --argjson id "${release_id}" 'any(.[]; .id == $id)' <<<"${releases}" >/dev/null; then
              echo "could not delete failed GitHub draft release ${release_id}" >&2
              cleanup_failed=1
            fi
          fi
        done < <(jq -r --arg marker "${RELEASE_RUN_MARKER}" \
          '.[] | select(.draft == true and ((.body // "") | contains($marker))) | .id' <<<"${releases}")
        if ! releases="$(remote_releases_for_tag)" || [[ "$(jq 'length' <<<"${releases}")" != "0" ]]; then
          echo "failed GitHub draft release is still present after cleanup" >&2
          cleanup_failed=1
        fi
      fi
    fi
  fi

  if [[ "${TAG_CREATION_ATTEMPTED}" == "true" ]]; then
    if [[ "${cleanup_failed}" != "0" ]]; then
      echo "retaining ${TAG} because failed draft state could not be reconciled safely" >&2
    elif ! remaining_refs="$(remote_exact_tag_refs)"; then
      echo "could not query GitHub tag after failed draft creation" >&2
      cleanup_failed=1
    else
      tag_count="$(jq 'length' <<<"${remaining_refs}")"
      if [[ "${tag_count}" == "1" ]]; then
        tag_target="$(jq -r '.[0].object.type + ":" + .[0].object.sha' <<<"${remaining_refs}")"
        if [[ "${tag_target}" != "commit:${source_commit_sha}" ]]; then
          echo "failed draft creation found ${TAG} at an unexpected target; tag was not deleted" >&2
          cleanup_failed=1
        elif ! gh api --method DELETE "repos/${repo}/git/refs/tags/${TAG}" >/dev/null; then
          if ! remaining_refs="$(remote_exact_tag_refs)" ||
             [[ "$(jq 'length' <<<"${remaining_refs}")" != "0" ]]; then
            echo "could not delete failed GitHub release tag ${TAG}" >&2
            cleanup_failed=1
          fi
        fi
      elif [[ "${tag_count}" != "0" ]]; then
        echo "failed draft creation found multiple exact GitHub release tags" >&2
        cleanup_failed=1
      fi
      if [[ "${cleanup_failed}" == "0" ]]; then
        if ! remaining_refs="$(remote_exact_tag_refs)" ||
           [[ "$(jq 'length' <<<"${remaining_refs}")" != "0" ]]; then
          echo "failed GitHub release tag is still present after cleanup" >&2
          cleanup_failed=1
        fi
      fi
    fi
  fi

  [[ "${cleanup_failed}" == "0" ]]
}

cleanup() {
  local status=$?
  if [[ "${status}" -ne 0 &&
        ( "${TAG_CREATION_ATTEMPTED}" == "true" || "${RELEASE_CREATION_ATTEMPTED}" == "true" ) &&
        -n "${repo}" ]]; then
    if ! reconcile_failed_remote_mutation; then
      status=1
    fi
  fi
  [[ -n "${VERIFY_DIR}" ]] && rm -rf "${VERIFY_DIR}"
  [[ -n "${FRESH_CI_DIR}" ]] && rm -rf "${FRESH_CI_DIR}"
  exit "${status}"
}
trap cleanup EXIT

validate_release_layout() {
  local count=0 entry name
  while IFS= read -r entry; do
    name="$(basename "${entry}")"
    case "${name}" in
      "$(basename "${SIGNED_ZIP}")"|"$(basename "${SHA256_PATH}")"|"$(basename "${MANIFEST_PATH}")") ;;
      *) fail "release directory contains an unexpected entry: ${name}" ;;
    esac
    count=$((count + 1))
  done < <(/usr/bin/find "${RELEASE_DIR}" -mindepth 1 -maxdepth 1 -print)
  [[ "${count}" -eq 3 ]] || fail "release directory must contain exactly the signed zip, checksum, and manifest"
}

repo="$(repo_target || true)"
[[ -n "${repo}" ]] || fail "missing GitHub repo target: set RELAYKIT_GITHUB_REPO or configure origin"
[[ "${repo}" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || fail "GitHub repo target must be owner/repo"
[[ -d "${RELEASE_DIR}" && ! -L "${RELEASE_DIR}" ]] || fail "release directory must be a real directory"
validate_release_layout
[[ -f "${SIGNED_ZIP}" && -f "${SHA256_PATH}" && -f "${MANIFEST_PATH}" ]] || fail "missing immutable signed release assets: run ./script/package_signed_release.sh first"
[[ ! -L "${SIGNED_ZIP}" && ! -L "${SHA256_PATH}" && ! -L "${MANIFEST_PATH}" ]] ||
  fail "release assets must not be symlinks"
command -v gh >/dev/null 2>&1 || fail "missing gh CLI"
gh auth status >/dev/null 2>&1 || fail "gh CLI is not authenticated"

VERIFY_DIR="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/relaykit-draft-verify.XXXXXX")"
chmod 700 "${VERIFY_DIR}"
SNAPSHOT_DIR="${VERIFY_DIR}/release-snapshot"
mkdir -m 700 "${SNAPSHOT_DIR}"
/bin/cp -p "${SIGNED_ZIP}" "${SNAPSHOT_DIR}/$(basename "${SIGNED_ZIP}")"
/bin/cp -p "${SHA256_PATH}" "${SNAPSHOT_DIR}/$(basename "${SHA256_PATH}")"
/bin/cp -p "${MANIFEST_PATH}" "${SNAPSHOT_DIR}/$(basename "${MANIFEST_PATH}")"
SIGNED_ZIP="${SNAPSHOT_DIR}/$(basename "${SIGNED_ZIP}")"
SHA256_PATH="${SNAPSHOT_DIR}/$(basename "${SHA256_PATH}")"
MANIFEST_PATH="${SNAPSHOT_DIR}/$(basename "${MANIFEST_PATH}")"
chmod 400 "${SIGNED_ZIP}" "${SHA256_PATH}" "${MANIFEST_PATH}"
NOTES_PATH="${VERIFY_DIR}/release-notes.md"

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

EXTRACTED_APP="${VERIFY_DIR}/${APP_NAME}.app"
/usr/bin/ditto -x -k "${SIGNED_ZIP}" "${VERIFY_DIR}"
[[ -d "${EXTRACTED_APP}" ]] || fail "signed zip is missing ${APP_NAME}.app"
[[ "$(app_tree_sha256 "${EXTRACTED_APP}")" == "$(jq -r '.app_tree_sha256' "${MANIFEST_PATH}")" ]] ||
  fail "signed zip App tree does not match manifest"
[[ "$(sha256 "${EXTRACTED_APP}/Contents/MacOS/${APP_PROCESS_NAME}")" == "$(jq -r '.app_executable_sha256' "${MANIFEST_PATH}")" ]] ||
  fail "signed zip App executable does not match manifest"
[[ "$(sha256 "${EXTRACTED_APP}/Contents/MacOS/relay")" == "$(jq -r '.bundled_helper_executable_sha256' "${MANIFEST_PATH}")" ]] ||
  fail "signed zip bundled helper does not match manifest"
"${CODESIGN_BIN}" --verify --deep --strict --verbose=4 "${EXTRACTED_APP}" >/dev/null
"${SPCTL_BIN}" -a -vvv -t exec "${EXTRACTED_APP}" >/dev/null
"${XCRUN_BIN}" stapler validate "${EXTRACTED_APP}" >/dev/null

source_commit_sha="$(jq -r '.source_commit_sha' "${MANIFEST_PATH}")"
FRESH_CI_DIR="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/relaykit-draft-ci.XXXXXX")"
fresh_ci_evidence="${FRESH_CI_DIR}/evidence.json"
"${ROOT_DIR}/scripts/github-required-checks.sh" \
  --repo "${repo}" \
  --sha "${source_commit_sha}" \
  --output "${fresh_ci_evidence}"
jq -e --slurp '.[0].hosted_ci == .[1]' "${MANIFEST_PATH}" "${fresh_ci_evidence}" >/dev/null ||
  fail "fresh GitHub checks do not match the signed release manifest"

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
RELEASE_RUN_MARKER="relaykit-release-run:$(
  printf '%s:%s:%s:%s\n' "${source_commit_sha}" "$$" "$(/bin/date +%s)" "${RANDOM}" |
    /usr/bin/shasum -a 256 |
    /usr/bin/awk '{print $1}'
)"
printf '\n<!-- %s -->\n' "${RELEASE_RUN_MARKER}" >>"${NOTES_PATH}"

existing_release_count="$(remote_releases_for_tag | jq 'length')"
[[ "${existing_release_count}" == "0" ]] || fail "GitHub release already exists: ${TAG}"
existing_tag_count="$(
  gh api "repos/${repo}/git/matching-refs/tags/${TAG}" |
    jq --arg ref "refs/tags/${TAG}" '[.[] | select(.ref == $ref)] | length'
)"
[[ "${existing_tag_count}" == "0" ]] || fail "release tag already exists: ${TAG}"
TAG_CREATION_ATTEMPTED=true
gh api --method POST "repos/${repo}/git/refs" \
  -f ref="refs/tags/${TAG}" \
  -f sha="${source_commit_sha}" >/dev/null
tag_target="$(
  gh api "repos/${repo}/git/ref/tags/${TAG}" --jq '.object.type + ":" + .object.sha'
)"
[[ "${tag_target}" == "commit:${source_commit_sha}" ]] ||
  fail "created release tag does not resolve to the manifest source commit"

RELEASE_CREATION_ATTEMPTED=true
gh release create "${TAG}" \
  --repo "${repo}" \
  --draft \
  --verify-tag \
  --target "${source_commit_sha}" \
  --title "RelayKit ${APP_MARKETING_VERSION} Dogfood Beta" \
  --notes-file "${NOTES_PATH}" \
  "${SIGNED_ZIP}" \
  "${SHA256_PATH}" \
  "${MANIFEST_PATH}"

echo "RelayKit GitHub Release draft created for ${TAG}"
