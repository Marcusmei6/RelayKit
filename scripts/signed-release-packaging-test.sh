#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/relaykit-signed-release-test.XXXXXX")"
cleanup() { rm -rf "${TMP_DIR}"; }
trap cleanup EXIT

fail() {
  echo "signed release packaging test failed: $1" >&2
  exit 1
}

MOCK_BIN="${TMP_DIR}/mock-bin"
mkdir -p "${MOCK_BIN}" "${TMP_DIR}/release-root" "${TMP_DIR}/Applications"
for tool in codesign xcrun spctl; do
  printf '%s\n' '#!/usr/bin/env bash' 'set -euo pipefail' \
    'printf '\''%s\n'\'' "$(basename "$0") $*" >>"${RELAYKIT_TEST_TOOL_LOG}"' >"${MOCK_BIN}/${tool}"
  chmod +x "${MOCK_BIN}/${tool}"
done
printf '%s\n' '#!/usr/bin/env bash' 'set -euo pipefail' \
  'printf '\''%s\n'\'' "$(basename "$0") $*" >>"${RELAYKIT_TEST_TOOL_LOG}"' \
  'if [[ -n "${RELAYKIT_TEST_FAIL_APP_PATH:-}" && "$*" == *"${RELAYKIT_TEST_FAIL_APP_PATH}"* ]]; then exit 1; fi' \
  'if [[ "$*" == *"-dvvv"* ]]; then printf '\''%s\n'\'' "Identifier=dev.relaykit.app" "Authority=Developer ID Application: RelayKit Test (WDZT4H533S)" "TeamIdentifier=WDZT4H533S" "Runtime Version=14.0" >&2; fi' \
  'if [[ "$*" == *"-dr -"* ]]; then printf '\''%s\n'\'' '\''designated => identifier "dev.relaykit.app" and anchor apple generic and certificate leaf[subject.OU] = WDZT4H533S'\'' >&2; fi' \
  >"${MOCK_BIN}/codesign"
chmod +x "${MOCK_BIN}/codesign"
printf '%s\n' '#!/usr/bin/env bash' 'set -euo pipefail' \
  'if [[ "${RELAYKIT_TEST_FAIL_ROLLBACK_MOVE:-0}" == "1" && "${1:-}" == *".RelayKitApp.backup."* ]]; then exit 73; fi' \
  'exec /bin/mv "$@"' >"${MOCK_BIN}/mv"
chmod +x "${MOCK_BIN}/mv"

APP="${TMP_DIR}/prepared/RelayKitApp.app"
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources"
printf '%s\n' \
  '<?xml version="1.0" encoding="UTF-8"?>' \
  '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
  '<plist version="1.0"><dict>' \
  '<key>CFBundleExecutable</key><string>RelayKitApp.bin</string>' \
  '<key>CFBundleIdentifier</key><string>dev.relaykit.app</string>' \
  '<key>CFBundleIconFile</key><string>RelayKitApp</string>' \
  '<key>CFBundleShortVersionString</key><string>0.1.1</string>' \
  '<key>CFBundleVersion</key><string>2</string>' \
  '</dict></plist>' >"${APP}/Contents/Info.plist"
printf '%s\n' '#!/usr/bin/env bash' 'exit 0' >"${APP}/Contents/MacOS/RelayKitApp.bin"
printf '%s\n' '#!/usr/bin/env bash' 'exit 0' >"${APP}/Contents/MacOS/relay"
chmod +x "${APP}/Contents/MacOS/RelayKitApp.bin" "${APP}/Contents/MacOS/relay"
printf '%s\n' 'public fixture resource' >"${APP}/Contents/Resources/providers.example.json"
printf '%s\n' 'fixture icon' >"${APP}/Contents/Resources/RelayKitApp.icns"

TEST_ENV=(
  env
  "PATH=${MOCK_BIN}:${PATH}"
  "RELAYKIT_TEST_TOOL_LOG=${TMP_DIR}/tool.log"
  "RELAYKIT_SIGNED_RELEASE_TEST_MODE=1"
  "RELAYKIT_TEST_CODESIGN_BIN=${MOCK_BIN}/codesign"
  "RELAYKIT_TEST_XCRUN_BIN=${MOCK_BIN}/xcrun"
  "RELAYKIT_TEST_SPCTL_BIN=${MOCK_BIN}/spctl"
  "RELAYKIT_TEST_MV_BIN=${MOCK_BIN}/mv"
  "RELAYKIT_APPLE_TEAM_ID=WDZT4H533S"
  "RELAYKIT_RELEASE_ROOT=${TMP_DIR}/release-root"
  "RELAYKIT_APP_VERSION=0.1.1"
  "RELAYKIT_BUILD_NUMBER=2"
)
if env -u RELAYKIT_SIGNED_RELEASE_TEST_MODE -u RELAYKIT_TEST_CODESIGN_BIN -u RELAYKIT_TEST_XCRUN_BIN -u RELAYKIT_TEST_SPCTL_BIN \
  -u RELAYKIT_SIGNING_IDENTITY -u RELAYKIT_NOTARYTOOL_PROFILE -u RELAYKIT_APPLE_TEAM_ID \
  "RELAYKIT_RELEASE_ROOT=${TMP_DIR}/release-root" "RELAYKIT_APP_VERSION=0.1.1" "RELAYKIT_BUILD_NUMBER=2" \
  "${ROOT_DIR}/script/package_signed_release.sh" >/dev/null 2>&1; then
  fail "credential-free signed release path unexpectedly succeeded"
fi
[[ ! -e "${TMP_DIR}/release-root/v0.1.1" ]] || fail "missing-credential path created a release directory"
"${TEST_ENV[@]}" "${ROOT_DIR}/script/package_signed_release.sh" --finalize-prepared-app "${APP}"

RELEASE_DIR="${TMP_DIR}/release-root/v0.1.1"
[[ -d "${RELEASE_DIR}/RelayKitApp.app" ]] || fail "release app was not retained"
[[ -f "${RELEASE_DIR}/RelayKitApp-0.1.1-signed.zip" ]] || fail "release zip missing"
[[ -f "${RELEASE_DIR}/RelayKitApp-0.1.1-signed.zip.sha256" ]] || fail "release checksum missing"
[[ -f "${RELEASE_DIR}/manifest.json" ]] || fail "release manifest missing"
[[ "$(find "${RELEASE_DIR}" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')" == "4" ]] || fail "release directory contains unexpected top-level entries"
jq -e '
  .schema_version == 1 and .version == "0.1.1" and .build == "2" and
  .source_clean == true and
  .bundle_id == "dev.relaykit.app" and
  .team_id == "WDZT4H533S" and .hardened_runtime == true and
  (.source_commit_sha | test("^[0-9a-f]{40}$")) and
  (.source_snapshot_sha256 | test("^[0-9a-f]{64}$")) and
  (.artifact_sha256 | test("^[0-9a-f]{64}$")) and
  (.app_tree_sha256 | test("^[0-9a-f]{64}$")) and
  (.app_executable_sha256 | test("^[0-9a-f]{64}$"))
' "${RELEASE_DIR}/manifest.json" >/dev/null || fail "manifest schema is incomplete"

if "${TEST_ENV[@]}" "${ROOT_DIR}/script/package_signed_release.sh" --finalize-prepared-app "${APP}" >/dev/null 2>&1; then
  fail "immutable release directory was overwritten"
fi

OLD_APP="${TMP_DIR}/Applications/RelayKitApp.app"
mkdir -p "${OLD_APP}/Contents/MacOS"
printf '%s\n' old >"${OLD_APP}/old-marker"
"${TEST_ENV[@]}" "${ROOT_DIR}/script/install_signed_release.sh" \
  --release-dir "${RELEASE_DIR}" --target "${OLD_APP}"
[[ ! -f "${OLD_APP}/old-marker" ]] || fail "old target was not replaced"
[[ -x "${OLD_APP}/Contents/MacOS/RelayKitApp.bin" ]] || fail "installed executable missing"
BACKUP_COUNT="$(find "${TMP_DIR}/Applications" -maxdepth 1 -type d -name '.RelayKitApp.backup.*' | wc -l | tr -d ' ')"
[[ "${BACKUP_COUNT}" == "1" ]] || fail "existing target was not backed up exactly once"
grep -Fq 'codesign --verify' "${TMP_DIR}/tool.log" || fail "codesign validation was not invoked"
grep -Fq 'xcrun stapler validate' "${TMP_DIR}/tool.log" || fail "stapler validation was not invoked"
grep -Fq 'spctl -a -vvv -t exec' "${TMP_DIR}/tool.log" || fail "Gatekeeper validation was not invoked"

ROLLBACK_TARGET="${TMP_DIR}/Applications/Rollback/RelayKitApp.app"
mkdir -p "${ROLLBACK_TARGET}/Contents"
printf '%s\n' 'original app' >"${ROLLBACK_TARGET}/old-marker"
if "${TEST_ENV[@]}" "RELAYKIT_TEST_FAIL_APP_PATH=${ROLLBACK_TARGET}" \
  "${ROOT_DIR}/script/install_signed_release.sh" --release-dir "${RELEASE_DIR}" --target "${ROLLBACK_TARGET}" >/dev/null 2>&1; then
  fail "installer unexpectedly passed post-install verification failure"
fi
[[ -f "${ROLLBACK_TARGET}/old-marker" ]] || fail "post-install verification failure did not restore the previous app"

ROLLBACK_FAILURE_TARGET="${TMP_DIR}/Applications/RollbackFailure/RelayKitApp.app"
mkdir -p "${ROLLBACK_FAILURE_TARGET}/Contents"
printf '%s\n' 'original app' >"${ROLLBACK_FAILURE_TARGET}/old-marker"
rollback_failure_log="${TMP_DIR}/rollback-failure.log"
if "${TEST_ENV[@]}" "RELAYKIT_TEST_FAIL_APP_PATH=${ROLLBACK_FAILURE_TARGET}" "RELAYKIT_TEST_FAIL_ROLLBACK_MOVE=1" \
  "${ROOT_DIR}/script/install_signed_release.sh" --release-dir "${RELEASE_DIR}" --target "${ROLLBACK_FAILURE_TARGET}" >"${TMP_DIR}/rollback-failure.stdout" 2>"${rollback_failure_log}"; then
  fail "installer unexpectedly passed a rollback restoration failure"
fi
grep -Fq 'rollback failed; backup retained at:' "${rollback_failure_log}" || fail "rollback failure was not reported with its retained backup"
[[ "$(find "$(dirname "${ROLLBACK_FAILURE_TARGET}")" -maxdepth 1 -type d -name '.RelayKitApp.backup.*' | wc -l | tr -d ' ')" == "1" ]] || fail "rollback failure did not retain exactly one backup"

BAD_TARGET="${TMP_DIR}/Applications/BadTarget/RelayKitApp.app"
mkdir -p "$(dirname "${BAD_TARGET}")"
cp "${RELEASE_DIR}/RelayKitApp-0.1.1-signed.zip" "${TMP_DIR}/bad.zip"
printf '%s\n' tampered >>"${TMP_DIR}/bad.zip"
mv "${TMP_DIR}/bad.zip" "${RELEASE_DIR}/RelayKitApp-0.1.1-signed.zip"
if "${TEST_ENV[@]}" "${ROOT_DIR}/script/install_signed_release.sh" --release-dir "${RELEASE_DIR}" --target "${BAD_TARGET}" >/dev/null 2>&1; then
  fail "installer accepted a checksum-mismatched zip"
fi
[[ ! -e "${BAD_TARGET}" ]] || fail "checksum failure touched target"

printf '%s\n' 'signed release packaging tests passed'
