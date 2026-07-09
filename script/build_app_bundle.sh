#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-build}"
APP_NAME="RelayKitApp"
APP_PROCESS_NAME="${APP_NAME}.bin"
BUNDLE_ID="dev.relaykit.app"
MIN_SYSTEM_VERSION="14.0"
APP_MARKETING_VERSION="${RELAYKIT_APP_VERSION:-0.1.0}"
APP_BUILD_NUMBER="${RELAYKIT_BUILD_NUMBER:-1}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="${ROOT_DIR}/dist"
APP_BUNDLE="${DIST_DIR}/${APP_NAME}.app"
APP_CONTENTS="${APP_BUNDLE}/Contents"
APP_MACOS="${APP_CONTENTS}/MacOS"
APP_RESOURCES="${APP_CONTENTS}/Resources"
APP_REAL_BINARY="${APP_MACOS}/${APP_NAME}.bin"
BUNDLED_GATEWAY="${APP_MACOS}/relay"
INFO_PLIST="${APP_CONTENTS}/Info.plist"

usage() {
  echo "usage: $0 [build|--verify]" >&2
}

stop_app() {
  pkill -x "${APP_NAME}" >/dev/null 2>&1 || true
  pkill -x "${APP_PROCESS_NAME}" >/dev/null 2>&1 || true
  pkill -f "${APP_REAL_BINARY}" >/dev/null 2>&1 || true
  if [[ "${RELAYKIT_KEEP_GATEWAY:-0}" != "1" ]]; then
    pkill -f "${BUNDLED_GATEWAY}" >/dev/null 2>&1 || true
  fi
}

build_bundle() {
  cd "${ROOT_DIR}/gateway"
  go build -o bin/relay ./cmd/gateway

  cd "${ROOT_DIR}/app"
  swift build
  local build_binary
  build_binary="$(swift build --show-bin-path)/${APP_NAME}"

  rm -rf "${APP_BUNDLE}"
  mkdir -p "${APP_MACOS}" "${APP_RESOURCES}"
  cp "${build_binary}" "${APP_REAL_BINARY}"
  cp "${ROOT_DIR}/gateway/bin/relay" "${BUNDLED_GATEWAY}"
  cp "${ROOT_DIR}/examples/providers.example.json" "${APP_RESOURCES}/providers.example.json"
  cp "${ROOT_DIR}/examples/codex.config.example.toml" "${APP_RESOURCES}/codex.config.example.toml"
  chmod +x "${APP_REAL_BINARY}"
  chmod +x "${BUNDLED_GATEWAY}"

  cat >"${INFO_PLIST}" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>${APP_NAME}.bin</string>
  <key>CFBundleIdentifier</key>
  <string>${BUNDLE_ID}</string>
  <key>CFBundleName</key>
  <string>RelayKit</string>
  <key>CFBundleDisplayName</key>
  <string>RelayKit</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>${APP_MARKETING_VERSION}</string>
  <key>CFBundleVersion</key>
  <string>${APP_BUILD_NUMBER}</string>
  <key>LSMinimumSystemVersion</key>
  <string>${MIN_SYSTEM_VERSION}</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
PLIST

  /usr/bin/codesign --force --sign - "${BUNDLED_GATEWAY}"
  /usr/bin/codesign --force --sign - "${APP_BUNDLE}"
}

verify_bundle() {
  local executable
  executable="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "${INFO_PLIST}")"
  if [[ "${executable}" != "${APP_NAME}.bin" ]]; then
    echo "CFBundleExecutable must point at the real Mach-O binary, got: ${executable}" >&2
    exit 1
  fi
  if ! /usr/bin/file "${APP_REAL_BINARY}" | grep -q 'Mach-O'; then
    echo "Real app executable is not a Mach-O binary: ${APP_REAL_BINARY}" >&2
    exit 1
  fi
  codesign --verify --deep --strict --verbose=4 "${APP_BUNDLE}" >/dev/null
  "${APP_REAL_BINARY}" --verify-bundled-gateway
}

case "${MODE}" in
  build)
    stop_app
    build_bundle
    ;;
  --verify|verify)
    stop_app
    build_bundle
    verify_bundle
    ;;
  *)
    usage
    exit 2
    ;;
esac
