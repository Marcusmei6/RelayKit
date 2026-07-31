#!/usr/bin/env bash
set -euo pipefail

APP_NAME="RelayKitApp"
APP_PROCESS_NAME="${APP_NAME}.bin"
APP_MARKETING_VERSION="${RELAYKIT_APP_VERSION:-0.1.6}"
APP_BUILD_NUMBER="${RELAYKIT_BUILD_NUMBER:-17}"
BUNDLE_ID="dev.relaykit.app"
EXPECTED_TEAM_ID="WDZT4H533S"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RELEASE_DIR="${RELAYKIT_RELEASE_DIR:-${ROOT_DIR}/dist/github-release/v${APP_MARKETING_VERSION}}"
TARGET_APP="/Applications/${APP_NAME}.app"
SIGNED_ZIP_NAME="${APP_NAME}-${APP_MARKETING_VERSION}-signed.zip"
SHA256_NAME="${SIGNED_ZIP_NAME}.sha256"
MANIFEST_NAME="manifest.json"
CODESIGN_BIN="/usr/bin/codesign"
XCRUN_BIN="/usr/bin/xcrun"
SPCTL_BIN="/usr/sbin/spctl"
MV_BIN="/bin/mv"
TEST_MODE="${RELAYKIT_SIGNED_RELEASE_TEST_MODE:-0}"
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
  : "${RELAYKIT_TEST_XCRUN_BIN:?test mode requires RELAYKIT_TEST_XCRUN_BIN}"
  : "${RELAYKIT_TEST_SPCTL_BIN:?test mode requires RELAYKIT_TEST_SPCTL_BIN}"
  CODESIGN_BIN="${RELAYKIT_TEST_CODESIGN_BIN}"
  XCRUN_BIN="${RELAYKIT_TEST_XCRUN_BIN}"
  SPCTL_BIN="${RELAYKIT_TEST_SPCTL_BIN}"
  MV_BIN="${RELAYKIT_TEST_MV_BIN:-/bin/mv}"
fi

usage() {
  echo "usage: $0 [--release-dir /absolute/path/v<version>] [--target /absolute/path/RelayKitApp.app]" >&2
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

app_metadata() {
  local app="$1"
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${app}/Contents/Info.plist")" == "${APP_MARKETING_VERSION}" ]] || fail "unexpected App version"
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "${app}/Contents/Info.plist")" == "${APP_BUILD_NUMBER}" ]] || fail "unexpected App build"
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "${app}/Contents/Info.plist")" == "${BUNDLE_ID}" ]] || fail "unexpected App bundle id"
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "${app}/Contents/Info.plist")" == "${APP_PROCESS_NAME}" ]] ||
    fail "unexpected app executable"
  [[ -x "${app}/Contents/MacOS/${APP_PROCESS_NAME}" ]] || fail "missing app executable"
  [[ -x "${app}/Contents/MacOS/relay" ]] || fail "missing bundled relay helper"
}

verify_signed_app() {
  local app="$1"
  local signature_details designated_requirement
  app_metadata "${app}"
  "${CODESIGN_BIN}" --verify --deep --strict --verbose=4 "${app}" >/dev/null
  signature_details="$("${CODESIGN_BIN}" -dvvv --verbose=4 "${app}" 2>&1)" || fail "could not inspect App signature"
  grep -Fqx "Identifier=${BUNDLE_ID}" <<<"${signature_details}" || fail "signed App identifier is not ${BUNDLE_ID}"
  grep -Fqx "TeamIdentifier=${EXPECTED_TEAM_ID}" <<<"${signature_details}" || fail "signed App TeamIdentifier is not the expected RelayKit team"
  grep -Eq '^Authority=Developer ID Application:' <<<"${signature_details}" || fail "signed App authority is not Developer ID Application"
  grep -Eq '^Runtime Version=' <<<"${signature_details}" || fail "signed App is missing hardened runtime"
  designated_requirement="$("${CODESIGN_BIN}" -dr - "${app}" 2>&1)" || fail "could not inspect App designated requirement"
  grep -Fq "identifier \"${BUNDLE_ID}\"" <<<"${designated_requirement}" || fail "App designated requirement has the wrong identifier"
  grep -Fq "certificate leaf[subject.OU] = ${EXPECTED_TEAM_ID}" <<<"${designated_requirement}" || fail "App designated requirement has the wrong team anchor"
  "${XCRUN_BIN}" stapler validate "${app}" >/dev/null
  "${SPCTL_BIN}" -a -vvv -t exec "${app}" >/dev/null
}

validate_release_layout() {
  local count=0 entry name
  while IFS= read -r entry; do
    name="$(basename "${entry}")"
    case "${name}" in
      "${SIGNED_ZIP_NAME}"|"${SHA256_NAME}"|"${MANIFEST_NAME}") ;;
      *) fail "release directory contains an unexpected entry: ${name}" ;;
    esac
    count=$((count + 1))
  done < <(/usr/bin/find "${RELEASE_DIR}" -mindepth 1 -maxdepth 1 -print)
  [[ "${count}" -eq 3 ]] || fail "release directory must contain exactly the signed zip, checksum, and manifest"
}

verify_release() {
  local source_zip="${RELEASE_DIR}/${SIGNED_ZIP_NAME}"
  local source_checksum="${RELEASE_DIR}/${SHA256_NAME}"
  local source_manifest="${RELEASE_DIR}/${MANIFEST_NAME}"
  local snapshot_dir zip checksum manifest
  local checksum_hash zip_hash
  [[ "${RELEASE_DIR}" = /* && -d "${RELEASE_DIR}" && ! -L "${RELEASE_DIR}" ]] ||
    fail "release directory must be an absolute existing directory"
  validate_release_layout
  [[ -f "${source_zip}" && ! -L "${source_zip}" &&
     -f "${source_checksum}" && ! -L "${source_checksum}" &&
     -f "${source_manifest}" && ! -L "${source_manifest}" ]] ||
    fail "release files are incomplete"

  VERIFY_DIR="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/relaykit-install-verify.XXXXXX")"
  chmod 700 "${VERIFY_DIR}"
  snapshot_dir="${VERIFY_DIR}/release-snapshot"
  mkdir -m 700 "${snapshot_dir}"
  /bin/cp -p "${source_zip}" "${snapshot_dir}/${SIGNED_ZIP_NAME}"
  /bin/cp -p "${source_checksum}" "${snapshot_dir}/${SHA256_NAME}"
  /bin/cp -p "${source_manifest}" "${snapshot_dir}/${MANIFEST_NAME}"
  chmod 400 "${snapshot_dir}/${SIGNED_ZIP_NAME}" "${snapshot_dir}/${SHA256_NAME}" "${snapshot_dir}/${MANIFEST_NAME}"
  zip="${snapshot_dir}/${SIGNED_ZIP_NAME}"
  checksum="${snapshot_dir}/${SHA256_NAME}"
  manifest="${snapshot_dir}/${MANIFEST_NAME}"
  VERIFIED_MANIFEST_PATH="${manifest}"

  checksum_hash="$(/usr/bin/awk -v file="${SIGNED_ZIP_NAME}" 'NF == 2 && $2 == file { print $1 }' "${checksum}")"
  [[ "${checksum_hash}" =~ ^[0-9a-f]{64}$ ]] || fail "invalid signed zip checksum"
  zip_hash="$(sha256 "${zip}")"
  [[ "${checksum_hash}" == "${zip_hash}" ]] || fail "signed zip checksum mismatch"

  /usr/bin/ditto -x -k "${zip}" "${VERIFY_DIR}"
  EXTRACTED_APP="${VERIFY_DIR}/${APP_NAME}.app"
  [[ -d "${EXTRACTED_APP}" ]] || fail "signed zip is missing ${APP_NAME}.app"
  verify_signed_app "${EXTRACTED_APP}"
  local tree_hash executable_hash helper_hash version build bundle_id
  tree_hash="$(app_tree_sha256 "${EXTRACTED_APP}")"
  executable_hash="$(sha256 "${EXTRACTED_APP}/Contents/MacOS/${APP_PROCESS_NAME}")"
  helper_hash="$(sha256 "${EXTRACTED_APP}/Contents/MacOS/relay")"
  version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${EXTRACTED_APP}/Contents/Info.plist")"
  build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "${EXTRACTED_APP}/Contents/Info.plist")"
  bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "${EXTRACTED_APP}/Contents/Info.plist")"
  jq -e \
    --arg artifact_sha256 "${zip_hash}" \
    --arg app_tree_sha256 "${tree_hash}" \
    --arg app_executable_sha256 "${executable_hash}" \
    --arg bundled_helper_executable_sha256 "${helper_hash}" \
    --arg version "${version}" \
    --arg build "${build}" \
    --arg bundle_id "${bundle_id}" \
    --arg expected_version "${APP_MARKETING_VERSION}" \
    --arg expected_build "${APP_BUILD_NUMBER}" \
    --arg expected_bundle_id "${BUNDLE_ID}" \
    --arg expected_team_id "${EXPECTED_TEAM_ID}" \
    --argjson required_names "${REQUIRED_CHECK_NAMES_JSON}" '
      (
        .hosted_ci.checks[0].details_url
        | capture("^https://github\\.com/(?<repo>[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)/actions/runs/[0-9]+(/job/[0-9]+)?$")
        | .repo
      ) as $ci_repo
      | ("https://github.com/" + $ci_repo + "/actions/runs/") as $run_prefix
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
      (.source_clean == true) and
      (.source_commit_sha | test("^[0-9a-f]{40}$")) and
      (.source_snapshot_sha256 | test("^[0-9a-f]{64}$")) and
      (.artifact_sha256 == $artifact_sha256) and
      (.app_tree_sha256 == $app_tree_sha256) and
      (.app_executable_sha256 == $app_executable_sha256) and
      (.bundled_helper_executable_sha256 == $bundled_helper_executable_sha256) and
      (.version == $version) and (.build == $build) and (.bundle_id == $bundle_id) and
      (.version == $expected_version) and (.build == $expected_build) and (.bundle_id == $expected_bundle_id) and
      (.team_id == $expected_team_id) and (.hardened_runtime == true) and
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
    ' "${manifest}" >/dev/null || fail "release manifest does not match signed zip payload"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --release-dir) RELEASE_DIR="${2:-}"; shift 2 ;;
    --target) TARGET_APP="${2:-}"; shift 2 ;;
    *) usage; exit 2 ;;
  esac
done

[[ "${TARGET_APP}" = /* && "$(basename "${TARGET_APP}")" == "${APP_NAME}.app" ]] ||
  fail "target must be an absolute ${APP_NAME}.app path"
TARGET_PARENT="$(dirname "${TARGET_APP}")"
[[ -d "${TARGET_PARENT}" ]] || fail "target parent does not exist: ${TARGET_PARENT}"

VERIFY_DIR=""
VERIFIED_MANIFEST_PATH=""
STAGE_DIR=""
BACKUP_APP=""
TARGET_REPLACED=false
cleanup() {
  local status=$?
  [[ -n "${VERIFY_DIR}" ]] && rm -rf "${VERIFY_DIR}"
  [[ -n "${STAGE_DIR}" ]] && rm -rf "${STAGE_DIR}"
  if [[ ${status} -ne 0 && -n "${BACKUP_APP}" && -e "${BACKUP_APP}" ]]; then
    if [[ -e "${TARGET_APP}" ]] && ! rm -rf "${TARGET_APP}"; then
      echo "RelayKit rollback failed to remove the rejected App; backup retained at: ${BACKUP_APP}" >&2
      status=1
    elif ! "${MV_BIN}" "${BACKUP_APP}" "${TARGET_APP}"; then
      echo "RelayKit rollback failed; backup retained at: ${BACKUP_APP}" >&2
      status=1
    fi
  elif [[ ${status} -ne 0 && "${TARGET_REPLACED}" == "true" && -e "${TARGET_APP}" ]]; then
    rm -rf "${TARGET_APP}"
  fi
  exit "${status}"
}
trap cleanup EXIT

verify_release
STAGE_DIR="$(/usr/bin/mktemp -d "${TARGET_PARENT}/.${APP_NAME}.install.XXXXXX")"
/usr/bin/ditto "${EXTRACTED_APP}" "${STAGE_DIR}/${APP_NAME}.app"
verify_signed_app "${STAGE_DIR}/${APP_NAME}.app"

if [[ -e "${TARGET_APP}" ]]; then
  [[ -d "${TARGET_APP}" ]] || fail "existing target is not an app bundle: ${TARGET_APP}"
  BACKUP_APP="${TARGET_PARENT}/.${APP_NAME}.backup.$(/bin/date -u +%Y%m%dT%H%M%SZ).$$"
  [[ ! -e "${BACKUP_APP}" ]] || fail "backup path already exists: ${BACKUP_APP}"
  "${MV_BIN}" "${TARGET_APP}" "${BACKUP_APP}"
fi
"${MV_BIN}" "${STAGE_DIR}/${APP_NAME}.app" "${TARGET_APP}"
TARGET_REPLACED=true
rm -rf "${STAGE_DIR}"
STAGE_DIR=""

verify_signed_app "${TARGET_APP}"
[[ "$(app_tree_sha256 "${TARGET_APP}")" == "$(jq -r '.app_tree_sha256' "${VERIFIED_MANIFEST_PATH}")" ]] ||
  fail "installed app tree hash does not match manifest"
[[ "$(sha256 "${TARGET_APP}/Contents/MacOS/${APP_PROCESS_NAME}")" == "$(jq -r '.app_executable_sha256' "${VERIFIED_MANIFEST_PATH}")" ]] ||
  fail "installed app executable hash does not match manifest"
[[ "$(sha256 "${TARGET_APP}/Contents/MacOS/relay")" == "$(jq -r '.bundled_helper_executable_sha256' "${VERIFIED_MANIFEST_PATH}")" ]] ||
  fail "installed bundled helper hash does not match manifest"

echo "RelayKit installed atomically: ${TARGET_APP}"
if [[ -n "${BACKUP_APP}" ]]; then
  echo "Previous app backed up at: ${BACKUP_APP}"
  printf "Rollback: quit RelayKit, remove '%s', then move '%s' back to '%s'\n" "${TARGET_APP}" "${BACKUP_APP}" "${TARGET_APP}"
fi
