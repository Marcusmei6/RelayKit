#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/relaykit-signed-release-test.XXXXXX")"
cleanup() {
  chmod -R u+w "${TMP_DIR}" 2>/dev/null || true
  rm -rf "${TMP_DIR}"
}
trap cleanup EXIT

fail() {
  echo "signed release packaging test failed: $1" >&2
  exit 1
}

expect_package_root_rejection() {
  local label="$1"
  shift
  local stderr_path="${TMP_DIR}/${label}.stderr"
  if "$@" >"${TMP_DIR}/${label}.stdout" 2>"${stderr_path}"; then
    fail "${label} unexpectedly succeeded"
  fi
  grep -Fxq 'test package mode requires repository-external absolute dist and release roots' "${stderr_path}" ||
    fail "${label} did not fail at the canonical package-root boundary"
}

MOCK_BIN="${TMP_DIR}/mock-bin"
mkdir -p "${MOCK_BIN}" "${TMP_DIR}/release-root" "${TMP_DIR}/Applications"
for tool in codesign xcrun spctl; do
  printf '%s\n' '#!/usr/bin/env bash' 'set -euo pipefail' \
    'printf '\''%s\n'\'' "$(basename "$0") $*" >>"${RELAYKIT_TEST_TOOL_LOG}"' >"${MOCK_BIN}/${tool}"
  chmod +x "${MOCK_BIN}/${tool}"
done
cat >"${MOCK_BIN}/codesign" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$(basename "$0") $*" >>"${RELAYKIT_TEST_TOOL_LOG}"
if [[ -n "${RELAYKIT_TEST_MUTATE_INSTALL_RELEASE_DIR:-}" &&
      -n "${RELAYKIT_TEST_MUTATE_INSTALL_MARKER:-}" &&
      ! -e "${RELAYKIT_TEST_MUTATE_INSTALL_MARKER}" ]]; then
  release_dir="${RELAYKIT_TEST_MUTATE_INSTALL_RELEASE_DIR}"
  chmod u+w "${release_dir}"
  chmod u+w \
    "${release_dir}/RelayKitApp-0.1.1-signed.zip" \
    "${release_dir}/RelayKitApp-0.1.1-signed.zip.sha256" \
    "${release_dir}/manifest.json"
  printf 'changed after installer snapshot\n' >>"${release_dir}/RelayKitApp-0.1.1-signed.zip"
  jq '.source_commit_sha = ("0" * 40)' \
    "${release_dir}/manifest.json" >"${release_dir}/manifest.json.tmp"
  mv "${release_dir}/manifest.json.tmp" "${release_dir}/manifest.json"
  : >"${RELAYKIT_TEST_MUTATE_INSTALL_MARKER}"
fi
if [[ -n "${RELAYKIT_TEST_FAIL_APP_PATH:-}" && "$*" == *"${RELAYKIT_TEST_FAIL_APP_PATH}"* ]]; then
  exit 1
fi
if [[ "$*" == *"-dvvv"* ]]; then
  printf '%s\n' \
    "Identifier=dev.relaykit.app" \
    "Authority=Developer ID Application: RelayKit Test (WDZT4H533S)" \
    "TeamIdentifier=WDZT4H533S" \
    "Runtime Version=14.0" >&2
fi
if [[ "$*" == *"-dr -"* ]]; then
  printf '%s\n' 'designated => identifier "dev.relaykit.app" and anchor apple generic and certificate leaf[subject.OU] = WDZT4H533S' >&2
fi
SH
chmod +x "${MOCK_BIN}/codesign"
printf '%s\n' '#!/usr/bin/env bash' 'set -euo pipefail' \
  'if [[ "${RELAYKIT_TEST_FAIL_ROLLBACK_MOVE:-0}" == "1" && "${1:-}" == *".RelayKitApp.backup."* ]]; then exit 73; fi' \
  'exec /bin/mv "$@"' >"${MOCK_BIN}/mv"
chmod +x "${MOCK_BIN}/mv"
printf '%s\n' '#!/usr/bin/env bash' 'set -euo pipefail' 'exit 99' >"${MOCK_BIN}/strings"
chmod +x "${MOCK_BIN}/strings"

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

SOURCE_SHA="$(git -C "${ROOT_DIR}" rev-parse HEAD)"
CI_EVIDENCE="${TMP_DIR}/ci-evidence.json"
jq -n --arg sha "${SOURCE_SHA}" '
  [
    "Fast Public Boundary",
    "Fast Shell Contracts",
    "Fast Go Quality",
    "macOS App",
    "macOS Runtime Safety",
    "Protocol Contract"
  ] as $names
  | {
      schema_version: 1,
      source_commit_sha: $sha,
      checks: [
        range(0; 6) as $index
        | {
            id: (101 + $index),
            name: $names[$index],
            details_url: ("https://github.com/example/relaykit/actions/runs/" + ((1101 + $index) | tostring) + "/job/" + ((101 + $index) | tostring)),
            conclusion: "success",
            app_slug: "github-actions"
          }
      ],
      actions_runs: [
        range(0; 6) as $index
        | {
            id: (1101 + $index),
            url: ("https://github.com/example/relaykit/actions/runs/" + ((1101 + $index) | tostring))
          }
      ]
    }
' >"${CI_EVIDENCE}"

cat >"${MOCK_BIN}/gh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  auth)
    exit 0
    ;;
  api)
    printf 'gh %s\n' "$*" >>"${RELAYKIT_TEST_TOOL_LOG}"
    if [[ "$*" == "api --paginate --slurp repos/example/relaykit/releases?per_page=100" ]]; then
      if [[ -e "${RELAYKIT_TEST_RELEASE_STATE}" ]]; then
        jq -s '[.]' "${RELAYKIT_TEST_RELEASE_STATE}"
      else
        printf '[[]]\n'
      fi
    elif [[ "$*" == *"/check-runs?per_page=100"* ]]; then
      if [[ -n "${RELAYKIT_TEST_MUTATE_DRAFT_RELEASE_DIR:-}" &&
            -n "${RELAYKIT_TEST_MUTATE_DRAFT_MARKER:-}" &&
            ! -e "${RELAYKIT_TEST_MUTATE_DRAFT_MARKER}" ]]; then
        release_dir="${RELAYKIT_TEST_MUTATE_DRAFT_RELEASE_DIR}"
        chmod u+w "${release_dir}"
        chmod u+w \
          "${release_dir}/RelayKitApp-0.1.1-signed.zip" \
          "${release_dir}/RelayKitApp-0.1.1-signed.zip.sha256" \
          "${release_dir}/manifest.json"
        printf 'changed after draft snapshot\n' >>"${release_dir}/RelayKitApp-0.1.1-signed.zip"
        jq '.source_commit_sha = ("0" * 40)' \
          "${release_dir}/manifest.json" >"${release_dir}/manifest.json.tmp"
        mv "${release_dir}/manifest.json.tmp" "${release_dir}/manifest.json"
        : >"${RELAYKIT_TEST_MUTATE_DRAFT_MARKER}"
      fi
      jq --arg sha "${RELAYKIT_TEST_SOURCE_SHA}" --arg mismatch "${RELAYKIT_TEST_GH_MISMATCH:-0}" '
        [
          {
            total_count: (.checks | length),
            check_runs: [
              .checks[]
              | {
                  id: (if $mismatch == "1" and .name == "Protocol Contract" then (.id + 9000) else .id end),
                  name: .name,
                  head_sha: $sha,
                  status: "completed",
                  conclusion: .conclusion,
                  app: {slug: .app_slug},
                  details_url: .details_url
                }
            ]
          }
        ]
      ' "${RELAYKIT_TEST_CI_EVIDENCE}"
    elif [[ "$*" == "api repos/example/relaykit/git/matching-refs/tags/${RELAYKIT_TEST_RELEASE_TAG}" ]]; then
      if [[ -e "${RELAYKIT_TEST_TAG_STATE}" ]]; then
        jq -n \
          --arg ref "refs/tags/${RELAYKIT_TEST_RELEASE_TAG}" \
          --arg sha "$(<"${RELAYKIT_TEST_TAG_STATE}")" \
          '[{ref: $ref, object: {type: "commit", sha: $sha}}]'
      else
        printf '[]\n'
      fi
    elif [[ "$*" == "api --method POST repos/example/relaykit/git/refs -f ref=refs/tags/${RELAYKIT_TEST_RELEASE_TAG} -f sha=${RELAYKIT_TEST_SOURCE_SHA}" ]]; then
      printf '%s\n' "${RELAYKIT_TEST_SOURCE_SHA}" >"${RELAYKIT_TEST_TAG_STATE}"
      [[ "${RELAYKIT_TEST_FAIL_TAG_CREATE_AFTER_REMOTE:-0}" != "1" ]] || exit 76
      printf '{"ref":"refs/tags/%s"}\n' "${RELAYKIT_TEST_RELEASE_TAG}"
    elif [[ "$*" == "api repos/example/relaykit/git/ref/tags/${RELAYKIT_TEST_RELEASE_TAG} --jq .object.type + \":\" + .object.sha" ]]; then
      [[ "$(<"${RELAYKIT_TEST_TAG_STATE}")" == "${RELAYKIT_TEST_SOURCE_SHA}" ]]
      printf 'commit:%s\n' "${RELAYKIT_TEST_SOURCE_SHA}"
    elif [[ "$*" == "api --method DELETE repos/example/relaykit/releases/9001" ]]; then
      [[ "${RELAYKIT_TEST_FAIL_RELEASE_DELETE:-0}" != "1" ]] || exit 77
      rm -f "${RELAYKIT_TEST_RELEASE_STATE}"
    elif [[ "$*" == "api --method DELETE repos/example/relaykit/git/refs/tags/${RELAYKIT_TEST_RELEASE_TAG}" ]]; then
      [[ "${RELAYKIT_TEST_FAIL_TAG_DELETE:-0}" != "1" ]] || exit 78
      rm -f "${RELAYKIT_TEST_TAG_STATE}"
    else
      exit 64
    fi
    ;;
  release)
    shift
    [[ "${1:-}" == "create" && "${2:-}" == "${RELAYKIT_TEST_RELEASE_TAG}" ]] || exit 64
    shift 2
    repo=""
    target=""
    title=""
    notes_file=""
    draft=false
    verify_tag=false
    assets=()
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --repo) repo="${2:-}"; shift 2 ;;
        --target) target="${2:-}"; shift 2 ;;
        --title) title="${2:-}"; shift 2 ;;
        --notes-file) notes_file="${2:-}"; shift 2 ;;
        --draft) draft=true; shift ;;
        --verify-tag) verify_tag=true; shift ;;
        --*) exit 64 ;;
        *) assets+=("$1"); shift ;;
      esac
    done
    [[ "${repo}" == "example/relaykit" &&
       "${target}" == "${RELAYKIT_TEST_SOURCE_SHA}" &&
       "${title}" == "RelayKit 0.1.1 Dogfood Beta" &&
       "${draft}" == "true" &&
       "${verify_tag}" == "true" &&
       -f "${notes_file}" &&
       "${#assets[@]}" -eq 3 ]] || exit 64
    expected_names=(
      "RelayKitApp-0.1.1-signed.zip"
      "RelayKitApp-0.1.1-signed.zip.sha256"
      "manifest.json"
    )
    for expected_name in "${expected_names[@]}"; do
      matched=""
      for asset in "${assets[@]}"; do
        if [[ "$(basename "${asset}")" == "${expected_name}" ]]; then
          matched="${asset}"
          break
        fi
      done
      [[ -n "${matched}" && "${matched}" == *"/release-snapshot/"* &&
         "${matched}" != "${RELAYKIT_TEST_ORIGINAL_RELEASE_DIR}/"* ]] || exit 64
      case "${expected_name}" in
        RelayKitApp-0.1.1-signed.zip)
          expected_hash="${RELAYKIT_TEST_EXPECTED_ZIP_SHA256}"
          ;;
        RelayKitApp-0.1.1-signed.zip.sha256)
          expected_hash="${RELAYKIT_TEST_EXPECTED_CHECKSUM_SHA256}"
          ;;
        manifest.json)
          expected_hash="${RELAYKIT_TEST_EXPECTED_MANIFEST_SHA256}"
          ;;
      esac
      actual_hash="$(/usr/bin/shasum -a 256 "${matched}" | /usr/bin/awk '{print $1}')"
      [[ "${actual_hash}" == "${expected_hash}" ]] || exit 64
    done
    jq -n \
      --arg tag "${RELAYKIT_TEST_RELEASE_TAG}" \
      --arg title "${title}" \
      --rawfile body "${notes_file}" \
      '{
        id: 9001,
        tag_name: $tag,
        name: $title,
        body: $body,
        draft: true
      }' >"${RELAYKIT_TEST_RELEASE_STATE}"
    /bin/cp "${notes_file}" "${RELAYKIT_TEST_CAPTURED_NOTES}"
    [[ "${RELAYKIT_TEST_FORCE_RELEASE_FAILURE:-0}" != "1" ]] || exit 75
    printf 'release create tag=%s target=%s draft=%s verify_tag=%s\n' \
      "${RELAYKIT_TEST_RELEASE_TAG}" "${target}" "${draft}" "${verify_tag}" >>"${RELAYKIT_TEST_GH_LOG}"
    ;;
  *)
    exit 64
    ;;
esac
SH
chmod +x "${MOCK_BIN}/gh"

cat >"${MOCK_BIN}/build-app-bundle" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf 'build version=%s build=%s args=%s\n' \
  "${RELAYKIT_APP_VERSION:-}" "${RELAYKIT_BUILD_NUMBER:-}" "$*" >>"${RELAYKIT_TEST_TOOL_LOG}"
[[ "$*" == "--verify" ]]
target="${RELAYKIT_TEST_SIGNED_RELEASE_DIST_DIR}/RelayKitApp.app"
rm -rf "${target}"
mkdir -p "${RELAYKIT_TEST_SIGNED_RELEASE_DIST_DIR}"
/usr/bin/ditto "${RELAYKIT_TEST_BUILD_FIXTURE_APP}" "${target}"
if [[ -n "${RELAYKIT_TEST_MUTATE_CALLER_EVIDENCE:-}" ]]; then
  jq '.test_mutated_after_fresh_query = true' \
    "${RELAYKIT_TEST_MUTATE_CALLER_EVIDENCE}" >"${RELAYKIT_TEST_MUTATE_CALLER_EVIDENCE}.tmp"
  mv "${RELAYKIT_TEST_MUTATE_CALLER_EVIDENCE}.tmp" "${RELAYKIT_TEST_MUTATE_CALLER_EVIDENCE}"
fi
if [[ -n "${RELAYKIT_TEST_MUTATE_SOURCE_IDENTITY_FILE:-}" ]]; then
  jq '.commit = ("0" * 40)' \
    "${RELAYKIT_TEST_MUTATE_SOURCE_IDENTITY_FILE}" >"${RELAYKIT_TEST_MUTATE_SOURCE_IDENTITY_FILE}.tmp"
  mv "${RELAYKIT_TEST_MUTATE_SOURCE_IDENTITY_FILE}.tmp" "${RELAYKIT_TEST_MUTATE_SOURCE_IDENTITY_FILE}"
fi
SH
chmod +x "${MOCK_BIN}/build-app-bundle"

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
  "RELAYKIT_GITHUB_REPO=example/relaykit"
  "RELAYKIT_CI_EVIDENCE_PATH=${CI_EVIDENCE}"
  "RELAYKIT_RELEASE_ROOT=${TMP_DIR}/release-root"
  "RELAYKIT_APP_VERSION=0.1.1"
  "RELAYKIT_BUILD_NUMBER=2"
)

if "${TEST_ENV[@]}" "RELAYKIT_CI_EVIDENCE_PATH=" \
  "RELAYKIT_RELEASE_ROOT=${TMP_DIR}/missing-evidence-release" \
  "${ROOT_DIR}/script/package_signed_release.sh" --finalize-prepared-app "${APP}" >/dev/null 2>&1; then
  fail "test finalization accepted missing CI evidence"
fi
[[ ! -e "${TMP_DIR}/missing-evidence-release/v0.1.1" ]] || fail "missing CI evidence created a release directory"

MISMATCHED_CI_EVIDENCE="${TMP_DIR}/mismatched-ci-evidence.json"
jq '.source_commit_sha = ("0" * 40)' "${CI_EVIDENCE}" >"${MISMATCHED_CI_EVIDENCE}"
if "${TEST_ENV[@]}" \
  "RELAYKIT_CI_EVIDENCE_PATH=${MISMATCHED_CI_EVIDENCE}" \
  "RELAYKIT_RELEASE_ROOT=${TMP_DIR}/mismatched-evidence-release" \
  "${ROOT_DIR}/script/package_signed_release.sh" --finalize-prepared-app "${APP}" >/dev/null 2>&1; then
  fail "test finalization accepted mismatched CI evidence"
fi
[[ ! -e "${TMP_DIR}/mismatched-evidence-release/v0.1.1" ]] || fail "mismatched CI evidence created a release directory"

NO_RUNS_CI_EVIDENCE="${TMP_DIR}/no-runs-ci-evidence.json"
jq '.actions_runs = []' "${CI_EVIDENCE}" >"${NO_RUNS_CI_EVIDENCE}"
if "${TEST_ENV[@]}" \
  "RELAYKIT_CI_EVIDENCE_PATH=${NO_RUNS_CI_EVIDENCE}" \
  "RELAYKIT_RELEASE_ROOT=${TMP_DIR}/no-runs-evidence-release" \
  "${ROOT_DIR}/script/package_signed_release.sh" --finalize-prepared-app "${APP}" >/dev/null 2>&1; then
  fail "test finalization accepted CI evidence without an Actions run"
fi
[[ ! -e "${TMP_DIR}/no-runs-evidence-release/v0.1.1" ]] || fail "empty Actions runs created a release directory"

MISMATCHED_RUNS_CI_EVIDENCE="${TMP_DIR}/mismatched-runs-ci-evidence.json"
jq '.actions_runs[0].id += 9000' "${CI_EVIDENCE}" >"${MISMATCHED_RUNS_CI_EVIDENCE}"
if "${TEST_ENV[@]}" \
  "RELAYKIT_CI_EVIDENCE_PATH=${MISMATCHED_RUNS_CI_EVIDENCE}" \
  "RELAYKIT_RELEASE_ROOT=${TMP_DIR}/mismatched-runs-evidence-release" \
  "${ROOT_DIR}/script/package_signed_release.sh" --finalize-prepared-app "${APP}" >/dev/null 2>&1; then
  fail "test finalization accepted Actions runs that were not derived from check URLs"
fi
[[ ! -e "${TMP_DIR}/mismatched-runs-evidence-release/v0.1.1" ]] || fail "mismatched Actions runs created a release directory"

WRONG_REPO_CI_EVIDENCE="${TMP_DIR}/wrong-repo-ci-evidence.json"
jq '.checks[5].details_url = "https://github.com/other/relaykit/actions/runs/1106/job/106"' \
  "${CI_EVIDENCE}" >"${WRONG_REPO_CI_EVIDENCE}"
if "${TEST_ENV[@]}" \
  "RELAYKIT_CI_EVIDENCE_PATH=${WRONG_REPO_CI_EVIDENCE}" \
  "RELAYKIT_RELEASE_ROOT=${TMP_DIR}/wrong-repo-evidence-release" \
  "${ROOT_DIR}/script/package_signed_release.sh" --finalize-prepared-app "${APP}" >/dev/null 2>&1; then
  fail "test finalization accepted a check URL from a different repository"
fi
[[ ! -e "${TMP_DIR}/wrong-repo-evidence-release/v0.1.1" ]] || fail "wrong-repo evidence created a release directory"

if "${TEST_ENV[@]}" \
  "RELAYKIT_SIGNED_RELEASE_TEST_ALLOW_PACKAGE=1" \
  "RELAYKIT_TEST_SIGNED_RELEASE_DIST_DIR=" \
  "${ROOT_DIR}/script/package_signed_release.sh" >/dev/null 2>&1; then
  fail "full package test mode accepted a missing isolated dist directory"
fi
expect_package_root_rejection "literal-repo-dist" \
  "${TEST_ENV[@]}" \
  "RELAYKIT_SIGNED_RELEASE_TEST_ALLOW_PACKAGE=1" \
  "RELAYKIT_TEST_SIGNED_RELEASE_DIST_DIR=${ROOT_DIR}/dist/test-package" \
  "${ROOT_DIR}/script/package_signed_release.sh"
expect_package_root_rejection "parent-alias-repo-dist" \
  "${TEST_ENV[@]}" \
  "RELAYKIT_SIGNED_RELEASE_TEST_ALLOW_PACKAGE=1" \
  "RELAYKIT_TEST_SIGNED_RELEASE_DIST_DIR=${ROOT_DIR}/../RelayKit/dist/test-package" \
  "${ROOT_DIR}/script/package_signed_release.sh"
REPO_SYMLINK="${TMP_DIR}/repo-symlink"
ln -s "${ROOT_DIR}" "${REPO_SYMLINK}"
expect_package_root_rejection "symlink-alias-repo-dist" \
  "${TEST_ENV[@]}" \
  "RELAYKIT_SIGNED_RELEASE_TEST_ALLOW_PACKAGE=1" \
  "RELAYKIT_TEST_SIGNED_RELEASE_DIST_DIR=${REPO_SYMLINK}/dist/test-package" \
  "${ROOT_DIR}/script/package_signed_release.sh"
expect_package_root_rejection "literal-repo-release" \
  "${TEST_ENV[@]}" \
  "RELAYKIT_SIGNED_RELEASE_TEST_ALLOW_PACKAGE=1" \
  "RELAYKIT_TEST_SIGNED_RELEASE_DIST_DIR=${TMP_DIR}/isolated-dist" \
  "RELAYKIT_RELEASE_ROOT=${ROOT_DIR}/dist/github-release-test" \
  "${ROOT_DIR}/script/package_signed_release.sh"
expect_package_root_rejection "parent-alias-repo-release" \
  "${TEST_ENV[@]}" \
  "RELAYKIT_SIGNED_RELEASE_TEST_ALLOW_PACKAGE=1" \
  "RELAYKIT_TEST_SIGNED_RELEASE_DIST_DIR=${TMP_DIR}/isolated-dist" \
  "RELAYKIT_RELEASE_ROOT=${ROOT_DIR}/../RelayKit/dist/github-release-test" \
  "${ROOT_DIR}/script/package_signed_release.sh"
expect_package_root_rejection "symlink-alias-repo-release" \
  "${TEST_ENV[@]}" \
  "RELAYKIT_SIGNED_RELEASE_TEST_ALLOW_PACKAGE=1" \
  "RELAYKIT_TEST_SIGNED_RELEASE_DIST_DIR=${TMP_DIR}/isolated-dist" \
  "RELAYKIT_RELEASE_ROOT=${REPO_SYMLINK}/dist/github-release-test" \
  "${ROOT_DIR}/script/package_signed_release.sh"

ORCHESTRATION_FIXTURE_APP="${TMP_DIR}/orchestration-fixture/RelayKitApp.app"
mkdir -p "$(dirname "${ORCHESTRATION_FIXTURE_APP}")"
/usr/bin/ditto "${APP}" "${ORCHESTRATION_FIXTURE_APP}"
/usr/libexec/PlistBuddy -c 'Set :CFBundleShortVersionString 0.1.6' "${ORCHESTRATION_FIXTURE_APP}/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleVersion 17' "${ORCHESTRATION_FIXTURE_APP}/Contents/Info.plist"
ORCHESTRATION_DIST="${TMP_DIR}/orchestration-dist"
ORCHESTRATION_RELEASE_ROOT="${TMP_DIR}/orchestration-release"
ORCHESTRATION_CALLER_CI="${TMP_DIR}/orchestration-caller-ci.json"
ORCHESTRATION_LOG="${TMP_DIR}/orchestration.log"
ORCHESTRATION_SOURCE_IDENTITY="${TMP_DIR}/orchestration-source-identity.json"
cp "${CI_EVIDENCE}" "${ORCHESTRATION_CALLER_CI}"
jq -n \
  --arg commit "${SOURCE_SHA}" \
  --arg snapshot "$(git -C "${ROOT_DIR}" archive --format=tar HEAD | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}')" \
  '{commit: $commit, snapshot: $snapshot}' >"${ORCHESTRATION_SOURCE_IDENTITY}"
: >"${ORCHESTRATION_LOG}"
if "${TEST_ENV[@]}" \
  "RELAYKIT_TEST_TOOL_LOG=${ORCHESTRATION_LOG}" \
  "RELAYKIT_SIGNED_RELEASE_TEST_ALLOW_PACKAGE=1" \
  "RELAYKIT_TEST_BUILD_APP_BUNDLE_BIN=${MOCK_BIN}/build-app-bundle" \
  "RELAYKIT_TEST_BUILD_FIXTURE_APP=${ORCHESTRATION_FIXTURE_APP}" \
  "RELAYKIT_TEST_SIGNED_RELEASE_DIST_DIR=${TMP_DIR}/orchestration-drift-dist" \
  "RELAYKIT_TEST_SOURCE_IDENTITY_FILE=${ORCHESTRATION_SOURCE_IDENTITY}" \
  "RELAYKIT_TEST_MUTATE_SOURCE_IDENTITY_FILE=${ORCHESTRATION_SOURCE_IDENTITY}" \
  "RELAYKIT_TEST_SOURCE_SHA=${SOURCE_SHA}" \
  "RELAYKIT_TEST_CI_EVIDENCE=${CI_EVIDENCE}" \
  "RELAYKIT_CI_EVIDENCE_PATH=${CI_EVIDENCE}" \
  "RELAYKIT_RELEASE_ROOT=${TMP_DIR}/orchestration-drift-release" \
  "RELAYKIT_APP_VERSION=0.1.6" \
  "RELAYKIT_BUILD_NUMBER=17" \
  "RELAYKIT_SIGNING_IDENTITY=Developer ID Application: RelayKit Test" \
  "RELAYKIT_NOTARYTOOL_PROFILE=relaykit-test" \
  "${ROOT_DIR}/script/package_signed_release.sh" >/dev/null 2>&1; then
  fail "default package orchestration accepted source identity drift after build"
fi
[[ ! -e "${TMP_DIR}/orchestration-drift-release/v0.1.6" ]] ||
  fail "source identity drift created a signed release"
jq -n \
  --arg commit "${SOURCE_SHA}" \
  --arg snapshot "$(git -C "${ROOT_DIR}" archive --format=tar HEAD | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}')" \
  '{commit: $commit, snapshot: $snapshot}' >"${ORCHESTRATION_SOURCE_IDENTITY}"
"${TEST_ENV[@]}" \
  "RELAYKIT_TEST_TOOL_LOG=${ORCHESTRATION_LOG}" \
  "RELAYKIT_SIGNED_RELEASE_TEST_ALLOW_PACKAGE=1" \
  "RELAYKIT_TEST_BUILD_APP_BUNDLE_BIN=${MOCK_BIN}/build-app-bundle" \
  "RELAYKIT_TEST_BUILD_FIXTURE_APP=${ORCHESTRATION_FIXTURE_APP}" \
  "RELAYKIT_TEST_SIGNED_RELEASE_DIST_DIR=${ORCHESTRATION_DIST}" \
  "RELAYKIT_TEST_SOURCE_IDENTITY_FILE=${ORCHESTRATION_SOURCE_IDENTITY}" \
  "RELAYKIT_TEST_MUTATE_CALLER_EVIDENCE=${ORCHESTRATION_CALLER_CI}" \
  "RELAYKIT_TEST_SOURCE_SHA=${SOURCE_SHA}" \
  "RELAYKIT_TEST_CI_EVIDENCE=${CI_EVIDENCE}" \
  "RELAYKIT_CI_EVIDENCE_PATH=${ORCHESTRATION_CALLER_CI}" \
  "RELAYKIT_RELEASE_ROOT=${ORCHESTRATION_RELEASE_ROOT}" \
  "RELAYKIT_APP_VERSION=0.1.6" \
  "RELAYKIT_BUILD_NUMBER=17" \
  "RELAYKIT_SIGNING_IDENTITY=Developer ID Application: RelayKit Test" \
  "RELAYKIT_NOTARYTOOL_PROFILE=relaykit-test" \
  "${ROOT_DIR}/script/package_signed_release.sh" >/dev/null
ORCHESTRATION_MANIFEST="${ORCHESTRATION_RELEASE_ROOT}/v0.1.6/manifest.json"
[[ -f "${ORCHESTRATION_MANIFEST}" ]] || fail "default package orchestration did not produce a manifest"
jq -e '.test_mutated_after_fresh_query == true' "${ORCHESTRATION_CALLER_CI}" >/dev/null ||
  fail "default package orchestration did not exercise caller-evidence mutation"
jq -e --slurp '
  .[0].version == "0.1.6" and
  .[0].build == "17" and
  .[0].hosted_ci == .[1] and
  (.[0].hosted_ci | has("test_mutated_after_fresh_query") | not)
' "${ORCHESTRATION_MANIFEST}" "${CI_EVIDENCE}" >/dev/null ||
  fail "default package manifest did not embed the fresh CI query result"
query_line="$(grep -n '^gh api ' "${ORCHESTRATION_LOG}" | head -1 | cut -d: -f1)"
build_line="$(grep -n '^build version=0.1.6 build=17 args=--verify$' "${ORCHESTRATION_LOG}" | head -1 | cut -d: -f1)"
codesign_line="$(grep -n '^codesign --force ' "${ORCHESTRATION_LOG}" | head -1 | cut -d: -f1)"
[[ -n "${query_line}" && -n "${build_line}" && -n "${codesign_line}" &&
   "${query_line}" -lt "${build_line}" && "${build_line}" -lt "${codesign_line}" ]] ||
  fail "default package orchestration did not preserve query -> build -> codesign order"
grep -Eq '^codesign --force .*relaykit-signed-package\.[^/]+/RelayKitApp\.app(/Contents/MacOS/relay)?$' "${ORCHESTRATION_LOG}" ||
  fail "default package orchestration did not sign its private frozen App"
grep -Eq '^xcrun notarytool submit .*relaykit-signed-package\.[^/]+/RelayKitApp-notary\.zip ' "${ORCHESTRATION_LOG}" ||
  fail "default package orchestration did not notarize its private frozen App"
if grep -Fq "${ORCHESTRATION_DIST}/RelayKitApp.app" "${ORCHESTRATION_LOG}"; then
  fail "default package orchestration signed or notarized the mutable build output"
fi

if env -u RELAYKIT_SIGNED_RELEASE_TEST_MODE -u RELAYKIT_TEST_CODESIGN_BIN -u RELAYKIT_TEST_XCRUN_BIN -u RELAYKIT_TEST_SPCTL_BIN \
  -u RELAYKIT_SIGNING_IDENTITY -u RELAYKIT_NOTARYTOOL_PROFILE -u RELAYKIT_APPLE_TEAM_ID \
  "RELAYKIT_RELEASE_ROOT=${TMP_DIR}/release-root" "RELAYKIT_APP_VERSION=0.1.1" "RELAYKIT_BUILD_NUMBER=2" \
  "${ROOT_DIR}/script/package_signed_release.sh" >/dev/null 2>&1; then
  fail "credential-free signed release path unexpectedly succeeded"
fi
[[ ! -e "${TMP_DIR}/release-root/v0.1.1" ]] || fail "missing-credential path created a release directory"

production_finalize_log="${TMP_DIR}/production-finalize.log"
if env -u RELAYKIT_SIGNED_RELEASE_TEST_MODE \
  "RELAYKIT_APP_VERSION=0.1.1" \
  "RELAYKIT_BUILD_NUMBER=2" \
  "${ROOT_DIR}/script/package_signed_release.sh" --finalize-prepared-app "${APP}" \
  >"${TMP_DIR}/production-finalize.stdout" 2>"${production_finalize_log}"; then
  fail "production path accepted an externally prepared App"
fi
grep -Fxq -- '--finalize-prepared-app is restricted to offline test mode' "${production_finalize_log}" ||
  fail "production prepared-App rejection was not explicit"

LEAK_APP="${TMP_DIR}/prepared-with-synthetic-path/RelayKitApp.app"
SYNTHETIC_ROOT="/""Users"
SYNTHETIC_PATH="${SYNTHETIC_ROOT}/RELAYKIT_FAKE_X0_USER_DO_NOT_USE/workspace"
mkdir -p "$(dirname "${LEAK_APP}")"
cp -R "${APP}" "${LEAK_APP}"
printf '%s' "${SYNTHETIC_PATH}" >>"${LEAK_APP}/Contents/MacOS/RelayKitApp.bin"
leak_log="${TMP_DIR}/synthetic-path-rejection.log"
if "${TEST_ENV[@]}" "${ROOT_DIR}/script/package_signed_release.sh" --finalize-prepared-app "${LEAK_APP}" >"${TMP_DIR}/synthetic-path-rejection.stdout" 2>"${leak_log}"; then
  fail "prepared App with a synthetic personal path was accepted"
fi
grep -Fq 'release binary personal-path scan failed: app-executable' "${leak_log}" ||
  fail "prepared App rejection did not identify the binary role"
if grep -Fq "${SYNTHETIC_PATH}" "${leak_log}"; then
  fail "prepared App rejection exposed the matched path"
fi
[[ ! -e "${TMP_DIR}/release-root/v0.1.1" ]] || fail "synthetic path rejection created a release directory"

"${TEST_ENV[@]}" "${ROOT_DIR}/script/package_signed_release.sh" --finalize-prepared-app "${APP}"

IMMUTABLE_RELEASE_DIR="${TMP_DIR}/release-root/v0.1.1"
RELEASE_DIR="${IMMUTABLE_RELEASE_DIR}"
[[ ! -e "${RELEASE_DIR}/RelayKitApp.app" ]] || fail "immutable release retained a mutable unpacked App"
[[ -f "${RELEASE_DIR}/RelayKitApp-0.1.1-signed.zip" ]] || fail "release zip missing"
[[ -f "${RELEASE_DIR}/RelayKitApp-0.1.1-signed.zip.sha256" ]] || fail "release checksum missing"
[[ -f "${RELEASE_DIR}/manifest.json" ]] || fail "release manifest missing"
[[ "$(find "${RELEASE_DIR}" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')" == "3" ]] || fail "release directory contains unexpected top-level entries"
python3 - "${RELEASE_DIR}" <<'PY' || fail "finalized release contains writable paths"
import os
import stat
import sys

root = sys.argv[1]
for current_root, directories, files in os.walk(root):
    for path in [current_root, *[os.path.join(current_root, name) for name in directories + files]]:
        if os.lstat(path).st_mode & (stat.S_IWUSR | stat.S_IWGRP | stat.S_IWOTH):
            raise SystemExit(1)
PY
jq -e '
  .schema_version == 2 and .version == "0.1.1" and .build == "2" and
  .source_clean == true and
  .bundle_id == "dev.relaykit.app" and
  .team_id == "WDZT4H533S" and .hardened_runtime == true and
  (.source_commit_sha | test("^[0-9a-f]{40}$")) and
  (.source_snapshot_sha256 | test("^[0-9a-f]{64}$")) and
  (.artifact_sha256 | test("^[0-9a-f]{64}$")) and
  (.app_tree_sha256 | test("^[0-9a-f]{64}$")) and
  (.app_executable_sha256 | test("^[0-9a-f]{64}$")) and
  (.bundled_helper_executable_sha256 | test("^[0-9a-f]{64}$")) and
  (.hosted_ci.source_commit_sha == .source_commit_sha) and
  (.hosted_ci.checks | length == 6) and
  (.hosted_ci.actions_runs | length == 6)
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

INSTALL_TOCTOU_RELEASE_DIR="${TMP_DIR}/install-toctou-release"
/usr/bin/ditto "${IMMUTABLE_RELEASE_DIR}" "${INSTALL_TOCTOU_RELEASE_DIR}"
INSTALL_TOCTOU_TARGET="${TMP_DIR}/Applications/InstallSnapshot/RelayKitApp.app"
INSTALL_TOCTOU_MARKER="${TMP_DIR}/install-toctou-mutated"
mkdir -p "$(dirname "${INSTALL_TOCTOU_TARGET}")"
"${TEST_ENV[@]}" \
  "RELAYKIT_TEST_MUTATE_INSTALL_RELEASE_DIR=${INSTALL_TOCTOU_RELEASE_DIR}" \
  "RELAYKIT_TEST_MUTATE_INSTALL_MARKER=${INSTALL_TOCTOU_MARKER}" \
  "${ROOT_DIR}/script/install_signed_release.sh" \
  --release-dir "${INSTALL_TOCTOU_RELEASE_DIR}" --target "${INSTALL_TOCTOU_TARGET}" >/dev/null
[[ -f "${INSTALL_TOCTOU_MARKER}" && -x "${INSTALL_TOCTOU_TARGET}/Contents/MacOS/RelayKitApp.bin" ]] ||
  fail "installer did not consume its private snapshot after source mutation"

MUTABLE_RELEASE_DIR="${TMP_DIR}/mutable-release"
/usr/bin/ditto "${IMMUTABLE_RELEASE_DIR}" "${MUTABLE_RELEASE_DIR}"
chmod -R u+w "${MUTABLE_RELEASE_DIR}"
RELEASE_DIR="${MUTABLE_RELEASE_DIR}"

printf 'unexpected\n' >"${RELEASE_DIR}/unexpected.txt"
EXTRA_ENTRY_TARGET="${TMP_DIR}/Applications/ExtraEntry/RelayKitApp.app"
mkdir -p "$(dirname "${EXTRA_ENTRY_TARGET}")"
if "${TEST_ENV[@]}" "${ROOT_DIR}/script/install_signed_release.sh" \
  --release-dir "${RELEASE_DIR}" --target "${EXTRA_ENTRY_TARGET}" >/dev/null 2>&1; then
  fail "installer accepted a release directory with an added entry"
fi
[[ ! -e "${EXTRA_ENTRY_TARGET}" ]] || fail "unexpected release entry touched install target"
rm -f "${RELEASE_DIR}/unexpected.txt"

HELPER_MISMATCH_TARGET="${TMP_DIR}/Applications/HelperMismatch/RelayKitApp.app"
mkdir -p "$(dirname "${HELPER_MISMATCH_TARGET}")"
cp "${RELEASE_DIR}/manifest.json" "${TMP_DIR}/manifest.valid.json"
jq '.bundled_helper_executable_sha256 = ("0" * 64)' "${TMP_DIR}/manifest.valid.json" >"${RELEASE_DIR}/manifest.json"
if "${TEST_ENV[@]}" "${ROOT_DIR}/script/install_signed_release.sh" \
  --release-dir "${RELEASE_DIR}" --target "${HELPER_MISMATCH_TARGET}" >/dev/null 2>&1; then
  fail "installer accepted a bundled helper hash mismatch"
fi
[[ ! -e "${HELPER_MISMATCH_TARGET}" ]] || fail "helper hash mismatch touched target"
cp "${TMP_DIR}/manifest.valid.json" "${RELEASE_DIR}/manifest.json"

for manifest_case in empty-runs mismatched-runs wrong-repo; do
  case "${manifest_case}" in
    empty-runs)
      jq '.hosted_ci.actions_runs = []' "${TMP_DIR}/manifest.valid.json" >"${RELEASE_DIR}/manifest.json"
      ;;
    mismatched-runs)
      jq '.hosted_ci.actions_runs[0].id += 9000' "${TMP_DIR}/manifest.valid.json" >"${RELEASE_DIR}/manifest.json"
      ;;
    wrong-repo)
      jq '.hosted_ci.checks[5].details_url = "https://github.com/other/relaykit/actions/runs/1106/job/106"' \
        "${TMP_DIR}/manifest.valid.json" >"${RELEASE_DIR}/manifest.json"
      ;;
  esac
  manifest_case_target="${TMP_DIR}/Applications/Manifest-${manifest_case}/RelayKitApp.app"
  mkdir -p "$(dirname "${manifest_case_target}")"
  if "${TEST_ENV[@]}" "${ROOT_DIR}/script/install_signed_release.sh" \
    --release-dir "${RELEASE_DIR}" --target "${manifest_case_target}" >/dev/null 2>&1; then
    fail "installer accepted ${manifest_case} hosted CI evidence"
  fi
  [[ ! -e "${manifest_case_target}" ]] || fail "${manifest_case} evidence touched install target"
done
cp "${TMP_DIR}/manifest.valid.json" "${RELEASE_DIR}/manifest.json"

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
cp "${RELEASE_DIR}/RelayKitApp-0.1.1-signed.zip" "${TMP_DIR}/valid-release.zip"
cp "${RELEASE_DIR}/RelayKitApp-0.1.1-signed.zip" "${TMP_DIR}/bad.zip"
printf '%s\n' tampered >>"${TMP_DIR}/bad.zip"
mv "${TMP_DIR}/bad.zip" "${RELEASE_DIR}/RelayKitApp-0.1.1-signed.zip"
if "${TEST_ENV[@]}" "${ROOT_DIR}/script/install_signed_release.sh" --release-dir "${RELEASE_DIR}" --target "${BAD_TARGET}" >/dev/null 2>&1; then
  fail "installer accepted a checksum-mismatched zip"
fi
[[ ! -e "${BAD_TARGET}" ]] || fail "checksum failure touched target"
cp "${TMP_DIR}/valid-release.zip" "${RELEASE_DIR}/RelayKitApp-0.1.1-signed.zip"

GH_LOG="${TMP_DIR}/gh.log"
: >"${GH_LOG}"
TAG_STATE="${TMP_DIR}/tag-state"
RELEASE_STATE="${TMP_DIR}/release-state.json"
CAPTURED_NOTES="${TMP_DIR}/captured-release-notes.md"
DRAFT_MUTATION_MARKER="${TMP_DIR}/draft-toctou-mutated"
DRAFT_EXPECTED_ZIP_SHA256="$(/usr/bin/shasum -a 256 "${RELEASE_DIR}/RelayKitApp-0.1.1-signed.zip" | awk '{print $1}')"
DRAFT_EXPECTED_CHECKSUM_SHA256="$(/usr/bin/shasum -a 256 "${RELEASE_DIR}/RelayKitApp-0.1.1-signed.zip.sha256" | awk '{print $1}')"
DRAFT_EXPECTED_MANIFEST_SHA256="$(/usr/bin/shasum -a 256 "${RELEASE_DIR}/manifest.json" | awk '{print $1}')"
DRAFT_ENV=(
  "${TEST_ENV[@]}"
  "RELAYKIT_TEST_SOURCE_SHA=${SOURCE_SHA}"
  "RELAYKIT_TEST_CI_EVIDENCE=${CI_EVIDENCE}"
  "RELAYKIT_TEST_GH_LOG=${GH_LOG}"
  "RELAYKIT_TEST_RELEASE_TAG=v0.1.1"
  "RELAYKIT_TEST_TAG_STATE=${TAG_STATE}"
  "RELAYKIT_TEST_RELEASE_STATE=${RELEASE_STATE}"
  "RELAYKIT_TEST_ORIGINAL_RELEASE_DIR=${RELEASE_DIR}"
  "RELAYKIT_TEST_EXPECTED_ZIP_SHA256=${DRAFT_EXPECTED_ZIP_SHA256}"
  "RELAYKIT_TEST_EXPECTED_CHECKSUM_SHA256=${DRAFT_EXPECTED_CHECKSUM_SHA256}"
  "RELAYKIT_TEST_EXPECTED_MANIFEST_SHA256=${DRAFT_EXPECTED_MANIFEST_SHA256}"
  "RELAYKIT_TEST_CAPTURED_NOTES=${CAPTURED_NOTES}"
  "RELAYKIT_GITHUB_REPO=example/relaykit"
  "RELAYKIT_RELEASE_DIR=${RELEASE_DIR}"
)
draft_stderr="${TMP_DIR}/draft.stderr"
cp "${RELEASE_DIR}/manifest.json" "${TMP_DIR}/draft-manifest.valid.json"
jq '.build = "999"' "${TMP_DIR}/draft-manifest.valid.json" >"${RELEASE_DIR}/manifest.json"
if "${DRAFT_ENV[@]}" "${ROOT_DIR}/script/create_github_release_draft.sh" >/dev/null 2>&1; then
  fail "draft accepted a manifest with the wrong build"
fi
[[ "$(grep -c '^release create ' "${GH_LOG}")" == "0" ]] || fail "wrong manifest build reached gh release create"
cp "${TMP_DIR}/draft-manifest.valid.json" "${RELEASE_DIR}/manifest.json"
for manifest_case in empty-runs mismatched-runs wrong-repo; do
  case "${manifest_case}" in
    empty-runs)
      jq '.hosted_ci.actions_runs = []' "${TMP_DIR}/draft-manifest.valid.json" >"${RELEASE_DIR}/manifest.json"
      ;;
    mismatched-runs)
      jq '.hosted_ci.actions_runs[0].id += 9000' "${TMP_DIR}/draft-manifest.valid.json" >"${RELEASE_DIR}/manifest.json"
      ;;
    wrong-repo)
      jq '.hosted_ci.checks[5].details_url = "https://github.com/other/relaykit/actions/runs/1106/job/106"' \
        "${TMP_DIR}/draft-manifest.valid.json" >"${RELEASE_DIR}/manifest.json"
      ;;
  esac
  if "${DRAFT_ENV[@]}" "${ROOT_DIR}/script/create_github_release_draft.sh" >/dev/null 2>&1; then
    fail "draft accepted ${manifest_case} hosted CI evidence"
  fi
  [[ "$(grep -c '^release create ' "${GH_LOG}")" == "0" ]] ||
    fail "${manifest_case} hosted CI evidence reached gh release create"
done
cp "${TMP_DIR}/draft-manifest.valid.json" "${RELEASE_DIR}/manifest.json"

printf 'unexpected\n' >"${RELEASE_DIR}/unexpected.txt"
if "${DRAFT_ENV[@]}" "${ROOT_DIR}/script/create_github_release_draft.sh" >/dev/null 2>&1; then
  fail "draft accepted a release directory with an added entry"
fi
rm -f "${RELEASE_DIR}/unexpected.txt"

if "${DRAFT_ENV[@]}" "RELAYKIT_TEST_GH_MISMATCH=1" \
  "${ROOT_DIR}/script/create_github_release_draft.sh" >/dev/null 2>&1; then
  fail "draft accepted fresh CI evidence that differed from the manifest"
fi
[[ "$(grep -c '^release create ' "${GH_LOG}")" == "0" ]] || fail "CI mismatch reached gh release create"

printf '%s\n' "${SOURCE_SHA}" >"${TAG_STATE}"
if "${DRAFT_ENV[@]}" "${ROOT_DIR}/script/create_github_release_draft.sh" >/dev/null 2>&1; then
  fail "draft reused a pre-existing release tag"
fi
rm -f "${TAG_STATE}"

if "${DRAFT_ENV[@]}" "RELAYKIT_TEST_FAIL_TAG_CREATE_AFTER_REMOTE=1" \
  "${ROOT_DIR}/script/create_github_release_draft.sh" >/dev/null 2>&1; then
  fail "ambiguous remote tag-creation failure unexpectedly succeeded"
fi
[[ ! -e "${TAG_STATE}" && ! -e "${RELEASE_STATE}" ]] ||
  fail "ambiguous tag-creation failure left remote state"

if "${DRAFT_ENV[@]}" "RELAYKIT_TEST_FORCE_RELEASE_FAILURE=1" \
  "${ROOT_DIR}/script/create_github_release_draft.sh" >/dev/null 2>&1; then
  fail "forced draft creation failure unexpectedly succeeded"
fi
[[ ! -e "${TAG_STATE}" && ! -e "${RELEASE_STATE}" ]] ||
  fail "failed draft creation did not roll back its draft and source tag"

cleanup_failure_stderr="${TMP_DIR}/draft-cleanup-failure.stderr"
if "${DRAFT_ENV[@]}" \
  "RELAYKIT_TEST_FORCE_RELEASE_FAILURE=1" \
  "RELAYKIT_TEST_FAIL_RELEASE_DELETE=1" \
  "${ROOT_DIR}/script/create_github_release_draft.sh" \
  >"${TMP_DIR}/draft-cleanup-failure.stdout" 2>"${cleanup_failure_stderr}"; then
  fail "draft cleanup failure unexpectedly succeeded"
fi
[[ -e "${TAG_STATE}" && -e "${RELEASE_STATE}" ]] ||
  fail "unreconciled draft cleanup did not retain coherent remote state"
grep -Fq 'could not delete failed GitHub draft release 9001' "${cleanup_failure_stderr}" ||
  fail "draft cleanup deletion failure was not reported"
grep -Fq 'retaining v0.1.1 because failed draft state could not be reconciled safely' "${cleanup_failure_stderr}" ||
  fail "draft cleanup failure did not report retained tag state"
rm -f "${TAG_STATE}" "${RELEASE_STATE}"

jq -n \
  --arg tag "v0.1.1" \
  '{
    id: 9001,
    tag_name: $tag,
    name: "Existing draft",
    body: "not created by this run",
    draft: true
  }' >"${RELEASE_STATE}"
if "${DRAFT_ENV[@]}" "${ROOT_DIR}/script/create_github_release_draft.sh" >/dev/null 2>&1; then
  fail "draft reused a pre-existing GitHub release"
fi
[[ -e "${RELEASE_STATE}" && ! -e "${TAG_STATE}" ]] ||
  fail "pre-existing release was mutated during rejection"
rm -f "${RELEASE_STATE}"

if ! "${DRAFT_ENV[@]}" \
  "RELAYKIT_TEST_MUTATE_DRAFT_RELEASE_DIR=${RELEASE_DIR}" \
  "RELAYKIT_TEST_MUTATE_DRAFT_MARKER=${DRAFT_MUTATION_MARKER}" \
  "${ROOT_DIR}/script/create_github_release_draft.sh" 2>"${draft_stderr}"; then
  /bin/cat "${draft_stderr}" >&2
  fail "valid draft creation failed"
fi
[[ ! -s "${draft_stderr}" ]] || fail "draft emitted unexpected stderr"
[[ "$(grep -c '^release create ' "${GH_LOG}")" == "1" ]] || fail "draft did not call gh release create exactly once"
[[ -f "${DRAFT_MUTATION_MARKER}" ]] || fail "draft TOCTOU fixture did not mutate the original release"
[[ "$(<"${TAG_STATE}")" == "${SOURCE_SHA}" ]] || fail "draft tag was not bound to the manifest source SHA"
NOTES_PATH="${CAPTURED_NOTES}"
for heading in "## Install" "## Uninstall" "## Rollback" "## Known limitations"; do
  grep -Fq "${heading}" "${NOTES_PATH}" || fail "draft release notes omitted ${heading}"
done
grep -Fq 'retains the prior App in a timestamped backup and prints the exact rollback command' "${NOTES_PATH}" ||
  fail "draft release notes omitted generic installer rollback guidance"
grep -Fq -- '- Build: 2' "${NOTES_PATH}" || fail "draft release notes omitted the expected build"
if grep -Fq 'Previous app backed up at:' "${NOTES_PATH}"; then
  fail "draft release notes claimed an actual backup before installation"
fi
[[ ! -e "${RELEASE_DIR}/release-notes.md" ]] || fail "draft wrote mutable notes into the immutable package directory"
[[ "$(/usr/bin/shasum -a 256 "${RELEASE_DIR}/RelayKitApp-0.1.1-signed.zip" | awk '{print $1}')" != "${DRAFT_EXPECTED_ZIP_SHA256}" ]] ||
  fail "draft TOCTOU fixture did not change the original zip"

printf '%s\n' 'signed release packaging tests passed'
