#!/usr/bin/env bash
set -euo pipefail

APP_NAME="RelayKitApp"
APP_PROCESS_NAME="${APP_NAME}.bin"
APP_MARKETING_VERSION="${RELAYKIT_APP_VERSION:-0.1.6}"
APP_BUILD_NUMBER="${RELAYKIT_BUILD_NUMBER:-17}"
BUNDLE_ID="dev.relaykit.app"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
TEST_MODE="${RELAYKIT_SIGNED_RELEASE_TEST_MODE:-0}"
TEST_ALLOW_PACKAGE="${RELAYKIT_SIGNED_RELEASE_TEST_ALLOW_PACKAGE:-0}"
TEST_RELEASE_ROOT=""

canonical_path() {
  /usr/bin/python3 - "$1" <<'PY'
import os
import sys

print(os.path.realpath(sys.argv[1]))
PY
}

DIST_DIR="${ROOT_DIR}/dist"
if [[ "${TEST_MODE}" == "1" && "${TEST_ALLOW_PACKAGE}" == "1" ]]; then
  : "${RELAYKIT_TEST_SIGNED_RELEASE_DIST_DIR:?test package mode requires an isolated dist directory}"
  : "${RELAYKIT_RELEASE_ROOT:?test package mode requires an isolated release root}"
  [[ "${RELAYKIT_TEST_SIGNED_RELEASE_DIST_DIR}" = /* &&
     "${RELAYKIT_RELEASE_ROOT}" = /* ]] || {
    echo "test package mode requires repository-external absolute dist and release roots" >&2
    exit 2
  }
  DIST_DIR="$(canonical_path "${RELAYKIT_TEST_SIGNED_RELEASE_DIST_DIR}")"
  TEST_RELEASE_ROOT="$(canonical_path "${RELAYKIT_RELEASE_ROOT}")"
  case "${DIST_DIR}" in
    "${ROOT_DIR}"|"${ROOT_DIR}"/*)
      echo "test package mode requires repository-external absolute dist and release roots" >&2
      exit 2
      ;;
  esac
  case "${TEST_RELEASE_ROOT}" in
    "${ROOT_DIR}"|"${ROOT_DIR}"/*)
      echo "test package mode requires repository-external absolute dist and release roots" >&2
      exit 2
      ;;
  esac
elif [[ "${TEST_MODE}" == "1" && -n "${RELAYKIT_TEST_SIGNED_RELEASE_DIST_DIR:-}" ]]; then
  [[ "${RELAYKIT_TEST_SIGNED_RELEASE_DIST_DIR}" = /* ]] || {
    echo "test signed release dist directory must be absolute" >&2
    exit 2
  }
  DIST_DIR="${RELAYKIT_TEST_SIGNED_RELEASE_DIST_DIR}"
fi
APP_BUNDLE="${DIST_DIR}/${APP_NAME}.app"
BUNDLED_RELAY="${APP_BUNDLE}/Contents/MacOS/relay"
RELEASE_ROOT="${RELAYKIT_RELEASE_ROOT:-${DIST_DIR}/github-release}"
[[ -n "${TEST_RELEASE_ROOT}" ]] && RELEASE_ROOT="${TEST_RELEASE_ROOT}"
RELEASE_DIR="${RELEASE_ROOT}/v${APP_MARKETING_VERSION}"
SIGNED_ZIP_NAME="${APP_NAME}-${APP_MARKETING_VERSION}-signed.zip"
SIGNED_ZIP="${RELEASE_DIR}/${SIGNED_ZIP_NAME}"
SHA256_NAME="${SIGNED_ZIP_NAME}.sha256"
MANIFEST_NAME="manifest.json"
NOTARY_ZIP="${DIST_DIR}/${APP_NAME}-notary.zip"
CODESIGN_BIN="/usr/bin/codesign"
XCRUN_BIN="/usr/bin/xcrun"
SPCTL_BIN="/usr/sbin/spctl"
BUILD_APP_BUNDLE_BIN="${ROOT_DIR}/script/build_app_bundle.sh"
CI_EVIDENCE_PATH="${RELAYKIT_CI_EVIDENCE_PATH:-}"
RELEASE_STAGE_DIR=""
RELEASE_VERIFY_DIR=""
FRESH_CI_DIR=""
VERIFIED_CI_EVIDENCE_PATH=""
VERIFIED_CI_EVIDENCE_SHA256=""
VERIFIED_CI_SOURCE_SHA=""
VERIFIED_CI_REPO=""
REQUIRED_CHECK_NAMES_JSON='[
  "Fast Public Boundary",
  "Fast Shell Contracts",
  "Fast Go Quality",
  "macOS App",
  "macOS Runtime Safety",
  "Protocol Contract"
]'

SIGNING_IDENTITY="${RELAYKIT_SIGNING_IDENTITY:-}"
NOTARYTOOL_PROFILE="${RELAYKIT_NOTARYTOOL_PROFILE:-}"
APPLE_TEAM_ID="${RELAYKIT_APPLE_TEAM_ID:-}"

if [[ "${TEST_MODE}" == "1" ]]; then
  : "${RELAYKIT_TEST_CODESIGN_BIN:?test mode requires RELAYKIT_TEST_CODESIGN_BIN}"
  : "${RELAYKIT_TEST_XCRUN_BIN:?test mode requires RELAYKIT_TEST_XCRUN_BIN}"
  : "${RELAYKIT_TEST_SPCTL_BIN:?test mode requires RELAYKIT_TEST_SPCTL_BIN}"
  CODESIGN_BIN="${RELAYKIT_TEST_CODESIGN_BIN}"
  XCRUN_BIN="${RELAYKIT_TEST_XCRUN_BIN}"
  SPCTL_BIN="${RELAYKIT_TEST_SPCTL_BIN}"
  if [[ "${TEST_ALLOW_PACKAGE}" == "1" ]]; then
    : "${RELAYKIT_TEST_BUILD_APP_BUNDLE_BIN:?test package mode requires RELAYKIT_TEST_BUILD_APP_BUNDLE_BIN}"
    BUILD_APP_BUNDLE_BIN="${RELAYKIT_TEST_BUILD_APP_BUNDLE_BIN}"
  fi
fi

cleanup_release() {
  local status=$?
  [[ -n "${RELEASE_VERIFY_DIR}" ]] && rm -rf "${RELEASE_VERIFY_DIR}"
  [[ -n "${RELEASE_STAGE_DIR}" ]] && rm -rf "${RELEASE_STAGE_DIR}"
  [[ -n "${FRESH_CI_DIR}" ]] && rm -rf "${FRESH_CI_DIR}"
  exit "${status}"
}
trap cleanup_release EXIT

usage() {
  echo "usage: $0 [--finalize-prepared-app /absolute/path/RelayKitApp.app]" >&2
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

source_snapshot_sha256() {
  git -C "${ROOT_DIR}" archive --format=tar HEAD | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}'
}

require_clean_source() {
  [[ "${TEST_MODE}" == "1" ]] && return
  [[ -z "$(git -C "${ROOT_DIR}" status --porcelain=v1 --untracked-files=all)" ]] ||
    fail "signed release requires a clean source worktree"
}

verify_ci_evidence() {
  local evidence="$1"
  local expected_sha="$2"
  local expected_repo="$3"
  local require_regular_file="${4:-1}"
  if [[ "${require_regular_file}" == "1" ]]; then
    [[ "${evidence}" = /* && -f "${evidence}" ]] || fail "CI evidence must be an absolute existing file"
  else
    [[ "${evidence}" = /* && -r "${evidence}" ]] || fail "embedded CI evidence is unreadable"
  fi
  jq -e \
    --arg source_commit_sha "${expected_sha}" \
    --arg repo "${expected_repo}" \
    --argjson required_names "${REQUIRED_CHECK_NAMES_JSON}" '
      ("https://github.com/" + $repo + "/actions/runs/") as $run_prefix
      | ([
          .checks[].details_url
          | ltrimstr($run_prefix)
          | split("/")[0]
          | {
              id: tonumber,
              url: ($run_prefix + .)
            }
        ] | unique_by(.id)) as $derived_runs
      |
      (.schema_version == 1) and
      (.source_commit_sha == $source_commit_sha) and
      (.checks | type == "array") and
      ([.checks[].name] == $required_names) and
      ([.checks[].id] | unique | length == 6) and
      (all(.checks[];
        (.id | type) == "number" and
        (.conclusion == "success") and
        (.app_slug == "github-actions") and
        (.details_url | type) == "string" and
        (.details_url | startswith($run_prefix)) and
        (.details_url | ltrimstr($run_prefix) | test("^[0-9]+(/job/[0-9]+)?$")) and
        ((keys | sort) == ["app_slug", "conclusion", "details_url", "id", "name"])
      )) and
      (.actions_runs | type == "array") and
      (.actions_runs | length >= 1) and
      (.actions_runs == $derived_runs) and
      (all(.actions_runs[];
        (.id | type) == "number" and
        (.url | type) == "string" and
        (.url | startswith($run_prefix)) and
        (.url | ltrimstr($run_prefix) | test("^[0-9]+$")) and
        ((keys | sort) == ["id", "url"])
      ))
    ' "${evidence}" >/dev/null || fail "CI evidence does not contain the six successful checks for current HEAD"
}

github_repo_target() {
  local target="${RELAYKIT_GITHUB_REPO:-}"
  if [[ -z "${target}" ]]; then
    local origin
    origin="$(git -C "${ROOT_DIR}" remote get-url origin 2>/dev/null || true)"
    case "${origin}" in
      git@github.com:*) target="${origin#git@github.com:}" ;;
      https://github.com/*) target="${origin#https://github.com/}" ;;
      ssh://git@github.com/*) target="${origin#ssh://git@github.com/}" ;;
      *) return 1 ;;
    esac
    target="${target%.git}"
  fi
  [[ "${target}" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || return 1
  printf '%s\n' "${target}"
}

require_ci_evidence_for_head() {
  local source_commit repo fresh_evidence current_verified_hash
  source_commit="$(git -C "${ROOT_DIR}" rev-parse HEAD)"
  [[ "${source_commit}" =~ ^[0-9a-f]{40}$ ]] || fail "could not resolve current source commit"
  repo="$(github_repo_target || true)"
  [[ -n "${repo}" ]] || fail "missing GitHub repo target: set RELAYKIT_GITHUB_REPO or configure a GitHub origin"

  if [[ -n "${VERIFIED_CI_EVIDENCE_PATH}" &&
        "${VERIFIED_CI_SOURCE_SHA}" == "${source_commit}" &&
        "${VERIFIED_CI_REPO}" == "${repo}" &&
        -f "${VERIFIED_CI_EVIDENCE_PATH}" ]]; then
    current_verified_hash="$(sha256 "${VERIFIED_CI_EVIDENCE_PATH}")"
    [[ "${current_verified_hash}" == "${VERIFIED_CI_EVIDENCE_SHA256}" ]] ||
      fail "verified CI evidence changed before release finalization"
    return
  fi

  verify_ci_evidence "${CI_EVIDENCE_PATH}" "${source_commit}" "${repo}"
  if [[ "${TEST_MODE}" == "1" && "${TEST_ALLOW_PACKAGE}" != "1" ]]; then
    VERIFIED_CI_EVIDENCE_PATH="${CI_EVIDENCE_PATH}"
    VERIFIED_CI_EVIDENCE_SHA256="$(sha256 "${VERIFIED_CI_EVIDENCE_PATH}")"
    VERIFIED_CI_SOURCE_SHA="${source_commit}"
    VERIFIED_CI_REPO="${repo}"
    return
  fi

  FRESH_CI_DIR="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/relaykit-package-ci.XXXXXX")"
  chmod 700 "${FRESH_CI_DIR}"
  fresh_evidence="${FRESH_CI_DIR}/evidence.json"
  "${ROOT_DIR}/scripts/github-required-checks.sh" \
    --repo "${repo}" \
    --sha "${source_commit}" \
    --output "${fresh_evidence}"
  chmod 600 "${fresh_evidence}"
  verify_ci_evidence "${fresh_evidence}" "${source_commit}" "${repo}"
  jq -e --slurp '.[0] == .[1]' "${CI_EVIDENCE_PATH}" "${fresh_evidence}" >/dev/null ||
    fail "fresh GitHub checks do not match RELAYKIT_CI_EVIDENCE_PATH"
  VERIFIED_CI_EVIDENCE_PATH="${fresh_evidence}"
  VERIFIED_CI_EVIDENCE_SHA256="$(sha256 "${VERIFIED_CI_EVIDENCE_PATH}")"
  VERIFIED_CI_SOURCE_SHA="${source_commit}"
  VERIFIED_CI_REPO="${repo}"
}

assert_verified_ci_evidence_unchanged() {
  local source_commit="$1"
  [[ -n "${VERIFIED_CI_EVIDENCE_PATH}" &&
      -f "${VERIFIED_CI_EVIDENCE_PATH}" &&
      "${VERIFIED_CI_SOURCE_SHA}" == "${source_commit}" &&
      -n "${VERIFIED_CI_REPO}" ]] ||
    fail "verified CI evidence is unavailable for release finalization"
  [[ "$(sha256 "${VERIFIED_CI_EVIDENCE_PATH}")" == "${VERIFIED_CI_EVIDENCE_SHA256}" ]] ||
    fail "verified CI evidence changed before release finalization"
  verify_ci_evidence "${VERIFIED_CI_EVIDENCE_PATH}" "${source_commit}" "${VERIFIED_CI_REPO}"
}

app_executable() {
  local app="$1"
  /usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "${app}/Contents/Info.plist"
}

scan_release_binary_for_personal_paths() {
  local role="$1"
  local binary="$2"
  local count

  if ! count="$(python3 - "${binary}" <<'PY'
import re
import sys

with open(sys.argv[1], "rb") as binary:
    data = binary.read()
patterns = (b"/" + b"Users/[^/\x00]+/", b"/" + b"home/[^/\x00]+/")
print(sum(len(re.findall(pattern, data)) for pattern in patterns))
PY
  )"; then
    fail "release binary personal-path scan unavailable: ${role}"
  fi
  if [[ ! "${count}" =~ ^[0-9]+$ ]] || (( count > 0 )); then
    fail "release binary personal-path scan failed: ${role} (rule=personal-absolute-path count=${count})"
  fi
}

verify_app_metadata() {
  local app="$1"
  local executable version build bundle_id
  executable="$(app_executable "${app}")"
  version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${app}/Contents/Info.plist")"
  build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "${app}/Contents/Info.plist")"
  bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "${app}/Contents/Info.plist")"
  [[ "${executable}" == "${APP_PROCESS_NAME}" ]] || fail "unexpected app executable: ${executable}"
  [[ -x "${app}/Contents/MacOS/${executable}" ]] || fail "missing app executable: ${app}/Contents/MacOS/${executable}"
  [[ -x "${app}/Contents/MacOS/relay" ]] || fail "missing bundled relay helper: ${app}/Contents/MacOS/relay"
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "${app}/Contents/Info.plist")" == "RelayKitApp" ]] || fail "unexpected app icon metadata"
  [[ -f "${app}/Contents/Resources/RelayKitApp.icns" ]] || fail "missing Finder app icon"
  [[ "${version}" == "${APP_MARKETING_VERSION}" ]] || fail "app version ${version} does not match requested ${APP_MARKETING_VERSION}"
  [[ "${build}" == "${APP_BUILD_NUMBER}" ]] || fail "app build ${build} does not match requested ${APP_BUILD_NUMBER}"
  [[ "${bundle_id}" == "${BUNDLE_ID}" ]] || fail "unexpected bundle id: ${bundle_id}"
}

verify_signed_app() {
  local app="$1"
  local signature_details designated_requirement
  verify_app_metadata "${app}"
  scan_release_binary_for_personal_paths app-executable "${app}/Contents/MacOS/${APP_PROCESS_NAME}"
  scan_release_binary_for_personal_paths bundled-relay "${app}/Contents/MacOS/relay"
  "${CODESIGN_BIN}" --verify --deep --strict --verbose=4 "${app}" >/dev/null
  signature_details="$("${CODESIGN_BIN}" -dvvv --verbose=4 "${app}" 2>&1)" || fail "could not inspect App signature"
  grep -Fqx "Identifier=${BUNDLE_ID}" <<<"${signature_details}" || fail "signed App identifier is not ${BUNDLE_ID}"
  grep -Fqx "TeamIdentifier=${APPLE_TEAM_ID}" <<<"${signature_details}" || fail "signed App TeamIdentifier is not the expected RelayKit team"
  grep -Eq '^Authority=Developer ID Application:' <<<"${signature_details}" || fail "signed App authority is not Developer ID Application"
  grep -Eq '^Runtime Version=' <<<"${signature_details}" || fail "signed App is missing hardened runtime"
  designated_requirement="$("${CODESIGN_BIN}" -dr - "${app}" 2>&1)" || fail "could not inspect App designated requirement"
  grep -Fq "identifier \"${BUNDLE_ID}\"" <<<"${designated_requirement}" || fail "App designated requirement has the wrong identifier"
  grep -Fq "certificate leaf[subject.OU] = ${APPLE_TEAM_ID}" <<<"${designated_requirement}" || fail "App designated requirement has the wrong team anchor"
  "${XCRUN_BIN}" stapler validate "${app}" >/dev/null
  "${SPCTL_BIN}" -a -vvv -t exec "${app}" >/dev/null
}

verify_manifest() {
  local release_dir="$1"
  local app="${release_dir}/${APP_NAME}.app"
  local zip="${release_dir}/${SIGNED_ZIP_NAME}"
  local checksum="${release_dir}/${SHA256_NAME}"
  local manifest="${release_dir}/${MANIFEST_NAME}"
  local checksum_hash zip_hash tree_hash executable_hash helper_hash source_commit

  [[ -f "${zip}" && -f "${checksum}" && -f "${manifest}" && -d "${app}" ]] ||
    fail "release layout is incomplete: ${release_dir}"
  checksum_hash="$(/usr/bin/awk -v file="${SIGNED_ZIP_NAME}" 'NF == 2 && $2 == file { print $1 }' "${checksum}")"
  [[ "${checksum_hash}" =~ ^[0-9a-f]{64}$ ]] || fail "invalid signed zip checksum: ${checksum}"
  zip_hash="$(sha256 "${zip}")"
  [[ "${checksum_hash}" == "${zip_hash}" ]] || fail "signed zip checksum mismatch"
  tree_hash="$(app_tree_sha256 "${app}")"
  executable_hash="$(sha256 "${app}/Contents/MacOS/${APP_PROCESS_NAME}")"
  helper_hash="$(sha256 "${app}/Contents/MacOS/relay")"
  source_commit="$(git -C "${ROOT_DIR}" rev-parse HEAD)"
  jq -e \
    --arg version "${APP_MARKETING_VERSION}" \
    --arg build "${APP_BUILD_NUMBER}" \
    --arg bundle_id "${BUNDLE_ID}" \
    --arg artifact_sha256 "${zip_hash}" \
    --arg app_tree_sha256 "${tree_hash}" \
    --arg app_executable_sha256 "${executable_hash}" \
    --arg bundled_helper_executable_sha256 "${helper_hash}" \
    --arg source_commit_sha "${source_commit}" \
    --arg team_id "${APPLE_TEAM_ID}" '
      (.schema_version == 2) and
      (.app_name == "RelayKitApp") and
      (.version == $version) and
      (.build == $build) and
      (.bundle_id == $bundle_id) and
      (.team_id == $team_id) and
      (.hardened_runtime == true) and
      (.source_clean == true) and
      (.source_commit_sha == $source_commit_sha) and
      (.source_snapshot_sha256 | test("^[0-9a-f]{64}$")) and
      (.artifact_sha256 == $artifact_sha256) and
      (.app_tree_sha256 == $app_tree_sha256) and
      (.app_executable_sha256 == $app_executable_sha256) and
      (.bundled_helper_executable_sha256 == $bundled_helper_executable_sha256) and
      (.hosted_ci.source_commit_sha == .source_commit_sha) and
      (.hosted_ci.checks | length == 6)
    ' "${manifest}" >/dev/null || fail "release manifest does not match its artifacts"
  verify_ci_evidence <(jq '.hosted_ci' "${manifest}") "${source_commit}" "${VERIFIED_CI_REPO}" 0
  jq -e --slurp '.[0].hosted_ci == .[1]' "${manifest}" "${VERIFIED_CI_EVIDENCE_PATH}" >/dev/null ||
    fail "release manifest did not embed the verified CI evidence"
}

verify_release_payload() {
  local release_dir="$1"
  local extracted_app
  RELEASE_VERIFY_DIR="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/relaykit-signed-release.XXXXXX")"
  /usr/bin/ditto -x -k "${release_dir}/${SIGNED_ZIP_NAME}" "${RELEASE_VERIFY_DIR}"
  extracted_app="${RELEASE_VERIFY_DIR}/${APP_NAME}.app"
  [[ -d "${extracted_app}" ]] || fail "signed zip is missing ${APP_NAME}.app"
  [[ "$(app_tree_sha256 "${release_dir}/${APP_NAME}.app")" == "$(app_tree_sha256 "${extracted_app}")" ]] ||
    fail "release app and signed zip payload tree hashes differ"
  [[ "$(sha256 "${release_dir}/${APP_NAME}.app/Contents/MacOS/${APP_PROCESS_NAME}")" == "$(sha256 "${extracted_app}/Contents/MacOS/${APP_PROCESS_NAME}")" ]] ||
    fail "release app and signed zip executable hashes differ"
  [[ "$(sha256 "${release_dir}/${APP_NAME}.app/Contents/MacOS/relay")" == "$(sha256 "${extracted_app}/Contents/MacOS/relay")" ]] ||
    fail "release app and signed zip bundled helper hashes differ"
  verify_signed_app "${release_dir}/${APP_NAME}.app"
  verify_signed_app "${extracted_app}"
  rm -rf "${RELEASE_VERIFY_DIR}"
  RELEASE_VERIFY_DIR=""
}

finalize_prepared_app() {
  local prepared_app="$1"
  local release_parent stage_dir stage_app source_commit source_snapshot tree_hash executable_hash helper_hash artifact_hash
  [[ "${prepared_app}" = /* && -d "${prepared_app}" ]] || fail "prepared app must be an absolute existing bundle path"
  require_clean_source
  source_commit="$(git -C "${ROOT_DIR}" rev-parse HEAD)"
  require_ci_evidence_for_head
  if [[ "${TEST_MODE}" != "1" ]]; then
    if missing_distribution_inputs; then
      fail_missing_distribution_inputs
    fi
    verify_distribution_inputs
  fi
  [[ ! -e "${RELEASE_DIR}" ]] || fail "immutable release directory already exists: ${RELEASE_DIR}"
  verify_signed_app "${prepared_app}"

  release_parent="$(dirname "${RELEASE_DIR}")"
  mkdir -p "${release_parent}"
  stage_dir="$(/usr/bin/mktemp -d "${release_parent}/.v${APP_MARKETING_VERSION}.staging.XXXXXX")"
  RELEASE_STAGE_DIR="${stage_dir}"
  stage_app="${stage_dir}/${APP_NAME}.app"
  /usr/bin/ditto "${prepared_app}" "${stage_app}"
  verify_signed_app "${stage_app}"
  (
    cd "${stage_dir}"
    /usr/bin/ditto -c -k --keepParent "${APP_NAME}.app" "${SIGNED_ZIP_NAME}"
    /usr/bin/shasum -a 256 "${SIGNED_ZIP_NAME}" >"${SHA256_NAME}"
  )

  source_snapshot="$(source_snapshot_sha256)"
  tree_hash="$(app_tree_sha256 "${stage_app}")"
  executable_hash="$(sha256 "${stage_app}/Contents/MacOS/${APP_PROCESS_NAME}")"
  helper_hash="$(sha256 "${stage_app}/Contents/MacOS/relay")"
  artifact_hash="$(sha256 "${stage_dir}/${SIGNED_ZIP_NAME}")"
  assert_verified_ci_evidence_unchanged "${source_commit}"
  jq -n \
    --slurpfile hosted_ci "${VERIFIED_CI_EVIDENCE_PATH}" \
    --arg source_commit_sha "${source_commit}" \
    --arg source_snapshot_sha256 "${source_snapshot}" \
    --arg artifact_sha256 "${artifact_hash}" \
    --arg app_tree_sha256 "${tree_hash}" \
    --arg app_executable_sha256 "${executable_hash}" \
    --arg bundled_helper_executable_sha256 "${helper_hash}" \
    --arg version "${APP_MARKETING_VERSION}" \
    --arg build "${APP_BUILD_NUMBER}" \
    --arg bundle_id "${BUNDLE_ID}" \
    --arg team_id "${APPLE_TEAM_ID}" '
      {
        schema_version: 2,
        app_name: "RelayKitApp",
        source_commit_sha: $source_commit_sha,
        source_snapshot_sha256: $source_snapshot_sha256,
        artifact_sha256: $artifact_sha256,
        app_tree_sha256: $app_tree_sha256,
        app_executable_sha256: $app_executable_sha256,
        bundled_helper_executable_sha256: $bundled_helper_executable_sha256,
        version: $version,
        build: $build,
        bundle_id: $bundle_id,
        team_id: $team_id,
        hardened_runtime: true,
        source_clean: true,
        hosted_ci: $hosted_ci[0]
      }
    ' >"${stage_dir}/${MANIFEST_NAME}"

  verify_manifest "${stage_dir}"
  verify_release_payload "${stage_dir}"
  mv "${stage_dir}" "${RELEASE_DIR}"
  RELEASE_STAGE_DIR=""
  echo "RelayKit immutable signed beta package verified: ${SIGNED_ZIP}"
  echo "RelayKit signed beta checksum: ${RELEASE_DIR}/${SHA256_NAME}"
  echo "RelayKit signed beta manifest: ${RELEASE_DIR}/${MANIFEST_NAME}"
}

missing_distribution_inputs() {
  [[ -z "${SIGNING_IDENTITY}" || -z "${NOTARYTOOL_PROFILE}" || -z "${APPLE_TEAM_ID}" ]]
}

fail_missing_distribution_inputs() {
  echo "missing Developer ID signing identity / notarization credentials" >&2
  echo "Set RELAYKIT_SIGNING_IDENTITY, RELAYKIT_NOTARYTOOL_PROFILE, and RELAYKIT_APPLE_TEAM_ID outside git." >&2
  exit 64
}

verify_distribution_inputs() {
  [[ "${TEST_MODE}" == "1" ]] && return
  if ! security find-identity -v -p codesigning 2>/dev/null | grep -Fq "${SIGNING_IDENTITY}"; then
    fail_missing_distribution_inputs
  fi
  if ! xcrun notarytool history --keychain-profile "${NOTARYTOOL_PROFILE}" --team-id "${APPLE_TEAM_ID}" >/dev/null 2>&1; then
    fail_missing_distribution_inputs
  fi
}

package_signed_release() {
  [[ "${TEST_MODE}" != "1" || "${TEST_ALLOW_PACKAGE}" == "1" ]] ||
    fail "test mode only supports --finalize-prepared-app unless package orchestration is explicitly enabled"
  if missing_distribution_inputs; then
    fail_missing_distribution_inputs
  fi
  require_clean_source
  require_ci_evidence_for_head
  verify_distribution_inputs
  [[ ! -e "${RELEASE_DIR}" ]] || fail "immutable release directory already exists: ${RELEASE_DIR}"

  RELAYKIT_APP_VERSION="${APP_MARKETING_VERSION}" \
    RELAYKIT_BUILD_NUMBER="${APP_BUILD_NUMBER}" \
    "${BUILD_APP_BUNDLE_BIN}" --verify >&2
  "${CODESIGN_BIN}" --force --timestamp --options runtime --sign "${SIGNING_IDENTITY}" "${BUNDLED_RELAY}"
  "${CODESIGN_BIN}" --force --timestamp --options runtime --sign "${SIGNING_IDENTITY}" "${APP_BUNDLE}"
  "${CODESIGN_BIN}" --verify --deep --strict --verbose=4 "${APP_BUNDLE}"
  "${CODESIGN_BIN}" -dvvv --entitlements :- "${APP_BUNDLE}"

  rm -f "${NOTARY_ZIP}"
  (
    cd "${DIST_DIR}"
    /usr/bin/ditto -c -k --keepParent "$(basename "${APP_BUNDLE}")" "$(basename "${NOTARY_ZIP}")"
  )
  "${XCRUN_BIN}" notarytool submit "${NOTARY_ZIP}" --keychain-profile "${NOTARYTOOL_PROFILE}" --team-id "${APPLE_TEAM_ID}" --wait
  "${XCRUN_BIN}" stapler staple "${APP_BUNDLE}"
  rm -f "${NOTARY_ZIP}"
  finalize_prepared_app "${APP_BUNDLE}"
}

case "${1:-}" in
  "") package_signed_release ;;
  --finalize-prepared-app)
    [[ $# -eq 2 ]] || { usage; exit 2; }
    finalize_prepared_app "$2"
    ;;
  *) usage; exit 2 ;;
esac
