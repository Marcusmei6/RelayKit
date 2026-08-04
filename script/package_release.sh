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

select_isolated_verify_port() {
  /usr/bin/python3 - "${ROOT_DIR}/app/Sources/RelayKitCore/RelayKitRuntimeEndpoint.swift" <<'PY'
import re
import socket
import sys

source = open(sys.argv[1], encoding="utf-8").read()
protected = {int(value) for value in re.findall(r"(?:productPort\s*=\s*|port\s*==\s*)(\d+)", source)}
for _ in range(20):
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as listener:
        listener.bind(("127.0.0.1", 0))
        port = listener.getsockname()[1]
    if port not in protected:
        print(port)
        break
else:
    raise SystemExit(1)
PY
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
  test -f "${EXTRACTED_APP}/Contents/_CodeSignature/CodeResources"
  local provisioning_path
  provisioning_path="$(find "${EXTRACTED_APP}/Contents" \( -name 'embedded.mobileprovision' -o -name '*.mobileprovision' -o -name '*.provisionprofile' \) -print -quit)"
  if [[ -n "${provisioning_path}" ]]; then
    echo "macOS local beta must not include provisioning profiles: ${provisioning_path}" >&2
    exit 1
  fi
  codesign --verify --deep --strict --verbose=4 "${EXTRACTED_APP}" >/dev/null
  local signing_details
  signing_details="$(codesign -dvvv "${EXTRACTED_APP}" 2>&1)"
  if ! grep -q 'Signature=adhoc' <<<"${signing_details}"; then
    echo "Local beta package must be macOS ad-hoc signed" >&2
    exit 1
  fi
  if ! grep -q 'TeamIdentifier=not set' <<<"${signing_details}"; then
    echo "Local beta package must not have a Developer ID team identifier" >&2
    exit 1
  fi
  local verify_port
  verify_port="$(select_isolated_verify_port)" || {
    echo "Could not allocate an isolated extracted-bundle verification port" >&2
    exit 1
  }
  env RELAYKIT_RUNTIME_SAFETY_TEST=1 RELAYKIT_RUNTIME_SAFETY_PORT="${verify_port}" \
    "${EXTRACTED_APP}/Contents/MacOS/RelayKitApp.bin" --verify-bundled-gateway
  echo "RelayKit local beta package verified: ${artifact}"
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
