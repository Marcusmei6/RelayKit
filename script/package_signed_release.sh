#!/usr/bin/env bash
set -euo pipefail

APP_NAME="RelayKitApp"
APP_MARKETING_VERSION="${RELAYKIT_APP_VERSION:-0.1.0}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="${ROOT_DIR}/dist"
APP_BUNDLE="${DIST_DIR}/${APP_NAME}.app"
BUNDLED_RELAY="${APP_BUNDLE}/Contents/MacOS/relay"
RELEASE_DIR="${DIST_DIR}/github-release/v${APP_MARKETING_VERSION}"
SIGNED_ZIP="${RELEASE_DIR}/${APP_NAME}-${APP_MARKETING_VERSION}-signed.zip"
SHA256_PATH="${SIGNED_ZIP}.sha256"
NOTARY_ZIP="${DIST_DIR}/${APP_NAME}-notary.zip"
VERIFY_DIR="${DIST_DIR}/verify-signed-release"
EXTRACTED_APP="${VERIFY_DIR}/${APP_NAME}.app"

SIGNING_IDENTITY="${RELAYKIT_SIGNING_IDENTITY:-}"
NOTARYTOOL_PROFILE="${RELAYKIT_NOTARYTOOL_PROFILE:-}"
APPLE_TEAM_ID="${RELAYKIT_APPLE_TEAM_ID:-}"

missing_distribution_inputs() {
  [[ -z "${SIGNING_IDENTITY}" || -z "${NOTARYTOOL_PROFILE}" || -z "${APPLE_TEAM_ID}" ]]
}

fail_missing_distribution_inputs() {
  mkdir -p "${RELEASE_DIR}"
  rm -rf "${VERIFY_DIR}"
  rm -f "${SIGNED_ZIP}" "${SHA256_PATH}" "${NOTARY_ZIP}"
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

if missing_distribution_inputs; then
  fail_missing_distribution_inputs
fi
verify_distribution_inputs

"${ROOT_DIR}/script/build_app_bundle.sh" --verify >&2

mkdir -p "${RELEASE_DIR}"
rm -rf "${VERIFY_DIR}"
rm -f "${SIGNED_ZIP}" "${SHA256_PATH}" "${NOTARY_ZIP}"

codesign --force --timestamp --options runtime --sign "${SIGNING_IDENTITY}" "${BUNDLED_RELAY}"
codesign --force --timestamp --options runtime --sign "${SIGNING_IDENTITY}" "${APP_BUNDLE}"
codesign --verify --deep --strict --verbose=4 "${APP_BUNDLE}"
codesign -dvvv --entitlements :- "${APP_BUNDLE}"

(
  cd "${DIST_DIR}"
  /usr/bin/ditto -c -k --keepParent "$(basename "${APP_BUNDLE}")" "$(basename "${NOTARY_ZIP}")"
)

xcrun notarytool submit "${NOTARY_ZIP}" --keychain-profile "${NOTARYTOOL_PROFILE}" --team-id "${APPLE_TEAM_ID}" --wait
xcrun stapler staple "${APP_BUNDLE}"
xcrun stapler validate "${APP_BUNDLE}"
spctl -a -vvv -t exec "${APP_BUNDLE}"

(
  cd "${DIST_DIR}"
  /usr/bin/ditto -c -k --keepParent "$(basename "${APP_BUNDLE}")" "${SIGNED_ZIP}"
)

shasum -a 256 "${SIGNED_ZIP}" >"${SHA256_PATH}"
rm -f "${NOTARY_ZIP}"

mkdir -p "${VERIFY_DIR}"
/usr/bin/ditto -x -k "${SIGNED_ZIP}" "${VERIFY_DIR}"
codesign --verify --deep --strict --verbose=4 "${EXTRACTED_APP}"
spctl -a -vvv -t exec "${EXTRACTED_APP}"
xcrun stapler validate "${EXTRACTED_APP}"

echo "RelayKit signed beta package verified: ${SIGNED_ZIP}"
echo "RelayKit signed beta checksum: ${SHA256_PATH}"
