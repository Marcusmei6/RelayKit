#!/usr/bin/env bash
set -euo pipefail

APP_NAME="RelayKitApp"
APP_PROCESS_NAME="${APP_NAME}.bin"
APP_MARKETING_VERSION="${RELAYKIT_APP_VERSION:-0.1.1}"
APP_BUILD_NUMBER="${RELAYKIT_BUILD_NUMBER:-2}"
BUNDLE_ID="dev.relaykit.app"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="${ROOT_DIR}/dist"
APP_BUNDLE="${DIST_DIR}/${APP_NAME}.app"
BUNDLED_RELAY="${APP_BUNDLE}/Contents/MacOS/relay"
RELEASE_ROOT="${RELAYKIT_RELEASE_ROOT:-${DIST_DIR}/github-release}"
RELEASE_DIR="${RELEASE_ROOT}/v${APP_MARKETING_VERSION}"
SIGNED_ZIP_NAME="${APP_NAME}-${APP_MARKETING_VERSION}-signed.zip"
SIGNED_ZIP="${RELEASE_DIR}/${SIGNED_ZIP_NAME}"
SHA256_NAME="${SIGNED_ZIP_NAME}.sha256"
MANIFEST_NAME="manifest.json"
NOTARY_ZIP="${DIST_DIR}/${APP_NAME}-notary.zip"
CODESIGN_BIN="/usr/bin/codesign"
XCRUN_BIN="/usr/bin/xcrun"
SPCTL_BIN="/usr/sbin/spctl"
TEST_MODE="${RELAYKIT_SIGNED_RELEASE_TEST_MODE:-0}"
RELEASE_STAGE_DIR=""
RELEASE_VERIFY_DIR=""

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
fi

cleanup_release() {
  local status=$?
  [[ -n "${RELEASE_VERIFY_DIR}" ]] && rm -rf "${RELEASE_VERIFY_DIR}"
  [[ -n "${RELEASE_STAGE_DIR}" ]] && rm -rf "${RELEASE_STAGE_DIR}"
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

app_executable() {
  local app="$1"
  /usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "${app}/Contents/Info.plist"
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
  local checksum_hash zip_hash tree_hash executable_hash

  [[ -f "${zip}" && -f "${checksum}" && -f "${manifest}" && -d "${app}" ]] ||
    fail "release layout is incomplete: ${release_dir}"
  checksum_hash="$(/usr/bin/awk -v file="${SIGNED_ZIP_NAME}" 'NF == 2 && $2 == file { print $1 }' "${checksum}")"
  [[ "${checksum_hash}" =~ ^[0-9a-f]{64}$ ]] || fail "invalid signed zip checksum: ${checksum}"
  zip_hash="$(sha256 "${zip}")"
  [[ "${checksum_hash}" == "${zip_hash}" ]] || fail "signed zip checksum mismatch"
  tree_hash="$(app_tree_sha256 "${app}")"
  executable_hash="$(sha256 "${app}/Contents/MacOS/${APP_PROCESS_NAME}")"
  jq -e \
    --arg version "${APP_MARKETING_VERSION}" \
    --arg build "${APP_BUILD_NUMBER}" \
    --arg bundle_id "${BUNDLE_ID}" \
    --arg artifact_sha256 "${zip_hash}" \
    --arg app_tree_sha256 "${tree_hash}" \
    --arg app_executable_sha256 "${executable_hash}" \
    --arg team_id "${APPLE_TEAM_ID}" '
      (.schema_version == 1) and
      (.app_name == "RelayKitApp") and
      (.version == $version) and
      (.build == $build) and
      (.bundle_id == $bundle_id) and
      (.team_id == $team_id) and
      (.hardened_runtime == true) and
      (.source_clean == true) and
      (.source_commit_sha | test("^[0-9a-f]{40}$")) and
      (.source_snapshot_sha256 | test("^[0-9a-f]{64}$")) and
      (.artifact_sha256 == $artifact_sha256) and
      (.app_tree_sha256 == $app_tree_sha256) and
      (.app_executable_sha256 == $app_executable_sha256)
    ' "${manifest}" >/dev/null || fail "release manifest does not match its artifacts"
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
  verify_signed_app "${release_dir}/${APP_NAME}.app"
  verify_signed_app "${extracted_app}"
  rm -rf "${RELEASE_VERIFY_DIR}"
  RELEASE_VERIFY_DIR=""
}

finalize_prepared_app() {
  local prepared_app="$1"
  local release_parent stage_dir stage_app staged_zip source_commit source_snapshot tree_hash executable_hash artifact_hash
  [[ "${prepared_app}" = /* && -d "${prepared_app}" ]] || fail "prepared app must be an absolute existing bundle path"
  if [[ "${TEST_MODE}" != "1" ]]; then
    if missing_distribution_inputs; then
      fail_missing_distribution_inputs
    fi
    verify_distribution_inputs
  fi
  require_clean_source
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

  source_commit="$(git -C "${ROOT_DIR}" rev-parse HEAD)"
  source_snapshot="$(source_snapshot_sha256)"
  tree_hash="$(app_tree_sha256 "${stage_app}")"
  executable_hash="$(sha256 "${stage_app}/Contents/MacOS/${APP_PROCESS_NAME}")"
  artifact_hash="$(sha256 "${stage_dir}/${SIGNED_ZIP_NAME}")"
  jq -n \
    --arg source_commit_sha "${source_commit}" \
    --arg source_snapshot_sha256 "${source_snapshot}" \
    --arg artifact_sha256 "${artifact_hash}" \
    --arg app_tree_sha256 "${tree_hash}" \
    --arg app_executable_sha256 "${executable_hash}" \
    --arg version "${APP_MARKETING_VERSION}" \
    --arg build "${APP_BUILD_NUMBER}" \
    --arg bundle_id "${BUNDLE_ID}" \
    --arg team_id "${APPLE_TEAM_ID}" '
      {
        schema_version: 1,
        app_name: "RelayKitApp",
        source_commit_sha: $source_commit_sha,
        source_snapshot_sha256: $source_snapshot_sha256,
        artifact_sha256: $artifact_sha256,
        app_tree_sha256: $app_tree_sha256,
        app_executable_sha256: $app_executable_sha256,
        version: $version,
        build: $build,
        bundle_id: $bundle_id,
        team_id: $team_id,
        hardened_runtime: true,
        source_clean: true
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
  if ! security find-identity -v -p codesigning 2>/dev/null | grep -Fq "${SIGNING_IDENTITY}"; then
    fail_missing_distribution_inputs
  fi
  if ! xcrun notarytool history --keychain-profile "${NOTARYTOOL_PROFILE}" --team-id "${APPLE_TEAM_ID}" >/dev/null 2>&1; then
    fail_missing_distribution_inputs
  fi
}

package_signed_release() {
  [[ "${TEST_MODE}" != "1" ]] || fail "test mode only supports --finalize-prepared-app"
  if missing_distribution_inputs; then
    fail_missing_distribution_inputs
  fi
  verify_distribution_inputs
  [[ ! -e "${RELEASE_DIR}" ]] || fail "immutable release directory already exists: ${RELEASE_DIR}"

  "${ROOT_DIR}/script/build_app_bundle.sh" --verify >&2
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
