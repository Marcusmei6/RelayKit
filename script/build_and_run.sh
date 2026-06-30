#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="RelayKitApp"
APP_PROCESS_NAME="${APP_NAME}.bin"
BUNDLE_ID="dev.relaykit.app"
MIN_SYSTEM_VERSION="14.0"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="${ROOT_DIR}/dist"
APP_BUNDLE="${DIST_DIR}/${APP_NAME}.app"
APP_CONTENTS="${APP_BUNDLE}/Contents"
APP_MACOS="${APP_CONTENTS}/MacOS"
APP_BINARY="${APP_MACOS}/${APP_NAME}"
APP_REAL_BINARY="${APP_MACOS}/${APP_NAME}.bin"
BUNDLED_GATEWAY="${APP_MACOS}/relay"
INFO_PLIST="${APP_CONTENTS}/Info.plist"

usage() {
  echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
}

build_bundle() {
  cd "${ROOT_DIR}/gateway"
  go build -o bin/relay ./cmd/gateway

  cd "${ROOT_DIR}/app"
  swift build
  local build_binary
  build_binary="$(swift build --show-bin-path)/${APP_NAME}"

  rm -rf "${APP_BUNDLE}"
  mkdir -p "${APP_MACOS}"
  cp "${build_binary}" "${APP_REAL_BINARY}"
  cp "${ROOT_DIR}/gateway/bin/relay" "${BUNDLED_GATEWAY}"
  cat >"${APP_BINARY}" <<APP_WRAPPER
#!/usr/bin/env bash
set -euo pipefail
cd "${ROOT_DIR}/app"
exec "\$(dirname "\$0")/${APP_NAME}.bin" "\$@"
APP_WRAPPER
  chmod +x "${APP_BINARY}"
  chmod +x "${APP_REAL_BINARY}"
  chmod +x "${BUNDLED_GATEWAY}"

  cat >"${INFO_PLIST}" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>${APP_NAME}</string>
  <key>CFBundleIdentifier</key>
  <string>${BUNDLE_ID}</string>
  <key>CFBundleName</key>
  <string>RelayKit</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>LSMinimumSystemVersion</key>
  <string>${MIN_SYSTEM_VERSION}</string>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
PLIST
}

open_app() {
  /usr/bin/open -n "${APP_BUNDLE}"
}

stop_app() {
  pkill -x "${APP_NAME}" >/dev/null 2>&1 || true
  pkill -x "${APP_PROCESS_NAME}" >/dev/null 2>&1 || true
  pkill -f "${APP_REAL_BINARY}" >/dev/null 2>&1 || true
}

stop_app
build_bundle

case "${MODE}" in
  run)
    open_app
    ;;
  --debug|debug)
    lldb -- "${APP_BINARY}"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"${APP_NAME}\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"${BUNDLE_ID}\""
    ;;
  --verify|verify)
    open_app
    sleep 2
    app_pid="$(pgrep -x "${APP_PROCESS_NAME}" | head -1)"
    if [[ -z "${app_pid}" ]]; then
      echo "${APP_NAME} did not launch" >&2
      exit 1
    fi
    if command -v lsof >/dev/null 2>&1; then
      app_cwd="$(lsof -a -p "${app_pid}" -d cwd -Fn | sed -n 's/^n//p')"
      if [[ "${app_cwd}" != "${ROOT_DIR}/app" ]]; then
        echo "${APP_NAME} launched with unexpected cwd: ${app_cwd}" >&2
        stop_app
        exit 1
      fi
    fi
    stop_app
    "${APP_BINARY}" --verify-bundled-gateway --provider-config "${ROOT_DIR}/examples/providers.example.json"
    ;;
  *)
    usage
    exit 2
    ;;
esac
