#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="RelayKitApp"
APP_PROCESS_NAME="${APP_NAME}.bin"
BUNDLE_ID="dev.relaykit.app"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="${ROOT_DIR}/dist"
APP_BUNDLE="${DIST_DIR}/${APP_NAME}.app"
APP_MACOS="${APP_BUNDLE}/Contents/MacOS"
APP_REAL_BINARY="${APP_MACOS}/${APP_NAME}.bin"
APP_BINARY="${APP_REAL_BINARY}"
BUNDLED_GATEWAY="${APP_MACOS}/relay"

usage() {
  echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
}

open_app() {
  /usr/bin/open -n "${APP_BUNDLE}"
}

stop_app() {
  pkill -x "${APP_NAME}" >/dev/null 2>&1 || true
  pkill -x "${APP_PROCESS_NAME}" >/dev/null 2>&1 || true
  pkill -f "${APP_REAL_BINARY}" >/dev/null 2>&1 || true
  if [[ "${RELAYKIT_KEEP_GATEWAY:-0}" != "1" ]]; then
    pkill -f "${BUNDLED_GATEWAY}" >/dev/null 2>&1 || true
  fi
}

build_mode="build"
if [[ "${MODE}" == "--verify" || "${MODE}" == "verify" ]]; then
  build_mode="--verify"
fi
"${ROOT_DIR}/script/build_app_bundle.sh" "${build_mode}"

case "${MODE}" in
  run)
    open_app
    ;;
  --debug|debug)
    lldb -- "${APP_BINARY}"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"${APP_PROCESS_NAME}\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"${BUNDLE_ID}\""
    ;;
  --verify|verify)
    open_app
    app_pid=""
    for _ in 1 2 3 4 5 6 7 8; do
      app_pids="$(pgrep -x "${APP_PROCESS_NAME}" || true)"
      app_pid="$(printf '%s\n' "${app_pids}" | sed -n '1p')"
      if [[ -n "${app_pid}" ]]; then
        break
      fi
      sleep 1
    done
    if [[ -z "${app_pid}" ]]; then
      echo "${APP_NAME} did not launch" >&2
      exit 1
    fi
    stop_app
    "${APP_BINARY}" --verify-bundled-gateway
    ;;
  *)
    usage
    exit 2
    ;;
esac
