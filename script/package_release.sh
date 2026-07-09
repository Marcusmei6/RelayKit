#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-package}"
APP_NAME="RelayKitApp"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="${ROOT_DIR}/dist"
APP_BUNDLE="${DIST_DIR}/${APP_NAME}.app"
ZIP_PATH="${DIST_DIR}/RelayKitApp-local.zip"
VERIFY_DIR="${DIST_DIR}/verify-release"
EXTRACTED_APP="${VERIFY_DIR}/${APP_NAME}.app"

usage() {
  echo "usage: $0 [package|--verify]" >&2
}

package_app() {
  "${ROOT_DIR}/script/build_app_bundle.sh" --verify >&2
  rm -f "${ZIP_PATH}"
  (
    cd "${DIST_DIR}"
    /usr/bin/zip -qry "$(basename "${ZIP_PATH}")" "$(basename "${APP_BUNDLE}")"
  )
  echo "${ZIP_PATH}"
}

verify_package() {
  local artifact=""
  artifact="$(package_app)"
  rm -rf "${VERIFY_DIR}"
  mkdir -p "${VERIFY_DIR}"
  /usr/bin/unzip -q "${artifact}" -d "${VERIFY_DIR}"
  test -x "${EXTRACTED_APP}/Contents/MacOS/relay"
  test -f "${EXTRACTED_APP}/Contents/Resources/providers.example.json"
  test -f "${EXTRACTED_APP}/Contents/Resources/codex.config.example.toml"
  codesign --verify --deep --strict --verbose=4 "${EXTRACTED_APP}" >/dev/null
  "${EXTRACTED_APP}/Contents/MacOS/RelayKitApp.bin" --verify-bundled-gateway
  echo "RelayKit local release package verified: ${artifact}"
}

case "${MODE}" in
  package)
    package_app
    ;;
  --verify|verify)
    verify_package
    ;;
  *)
    usage
    exit 2
    ;;
esac
