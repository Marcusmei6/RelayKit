#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="${ROOT}/dist/RelayKitApp.app/Contents/MacOS/RelayKitApp"
APP_REAL="${ROOT}/dist/RelayKitApp.app/Contents/MacOS/RelayKitApp.bin"
BUNDLED_RELAY="${ROOT}/dist/RelayKitApp.app/Contents/MacOS/relay"
OUT="${ROOT}/dist/ui-smoke"
PID=""

cleanup() {
  if [[ -n "${PID}" ]] && kill -0 "${PID}" 2>/dev/null; then
    kill "${PID}" >/dev/null 2>&1 || true
    wait "${PID}" >/dev/null 2>&1 || true
  fi
  pkill -x RelayKitApp.bin >/dev/null 2>&1 || true
  pkill -f "${APP_REAL}" >/dev/null 2>&1 || true
  pkill -f "${BUNDLED_RELAY}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

capture() {
  local name="$1"
  shift
  local evidence="${OUT}/${name}.json"
  "${APP}" --ui-smoke --ui-smoke-evidence "${evidence}" "$@" >/tmp/relaykit-ui-smoke.log 2>&1 &
  PID="$!"
  sleep 2
  if ! kill -0 "${PID}" 2>/dev/null; then
    cat /tmp/relaykit-ui-smoke.log >&2
    exit 1
  fi
  test -s "${evidence}"
  case "${name}" in
    connect) required='["tab-connect","cli-route","model-list"]' ;;
    usage) required='["tab-usage","usage-kpis","usage-rows"]' ;;
    settings) required='["tab-settings","settings-actions","advanced-paths"]' ;;
    provider) required='["tab-provider","provider-modal","credential-reference-form"]' ;;
    *) required='[]' ;;
  esac
  jq -e --argjson required "${required}" '
    . as $doc |
    $doc.status_item.visible == true and
    $doc.status_item.width > 0 and
    $doc.popover.shown == true and
    $doc.popover.ordinary_window == false and
    $doc.surface.kind == "menu-bar-popover" and
    ($doc.surface.sections | index("global-status")) and
    (all($required[]; . as $section | ($doc.surface.sections | index($section))))
  ' "${evidence}" >/dev/null
  /usr/sbin/screencapture -x "${OUT}/${name}.png"
  test -s "${OUT}/${name}.png"
  kill "${PID}" >/dev/null 2>&1 || true
  wait "${PID}" >/dev/null 2>&1 || true
  PID=""
  cleanup
}

cd "${ROOT}"
./script/build_and_run.sh --verify >/dev/null
rm -rf "${OUT}"
mkdir -p "${OUT}"

capture connect --ui-smoke-tab connect
capture usage --ui-smoke-tab usage
capture settings --ui-smoke-tab settings
capture provider --ui-smoke-tab connect --ui-smoke-provider

if pgrep -x RelayKitApp.bin >/dev/null || pgrep -f "${BUNDLED_RELAY}" >/dev/null; then
  echo "UI smoke left stale RelayKit-owned app or gateway process" >&2
  exit 1
fi

echo "RelayKit menu bar UI smoke passed: ${OUT}"
