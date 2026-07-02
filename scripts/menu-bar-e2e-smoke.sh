#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="${ROOT}/dist/RelayKitApp.app/Contents/MacOS/RelayKitApp"
OUT="${ROOT}/dist/ui-smoke"
PID=""

cleanup() {
  if [[ -n "${PID}" ]] && kill -0 "${PID}" 2>/dev/null; then
    kill "${PID}" >/dev/null 2>&1 || true
    wait "${PID}" >/dev/null 2>&1 || true
  fi
  pkill -x RelayKitApp.bin >/dev/null 2>&1 || true
}
trap cleanup EXIT

capture() {
  local name="$1"
  shift
  "${APP}" --ui-smoke "$@" >/tmp/relaykit-ui-smoke.log 2>&1 &
  PID="$!"
  sleep 2
  if ! kill -0 "${PID}" 2>/dev/null; then
    cat /tmp/relaykit-ui-smoke.log >&2
    exit 1
  fi
  /usr/sbin/screencapture -x "${OUT}/${name}.png"
  test -s "${OUT}/${name}.png"
  kill "${PID}" >/dev/null 2>&1 || true
  wait "${PID}" >/dev/null 2>&1 || true
  PID=""
}

cd "${ROOT}"
./script/build_and_run.sh --verify >/dev/null
rm -rf "${OUT}"
mkdir -p "${OUT}"

capture connect --ui-smoke-tab connect
capture usage --ui-smoke-tab usage
capture settings --ui-smoke-tab settings
capture provider --ui-smoke-tab connect --ui-smoke-provider

echo "RelayKit menu bar UI smoke passed: ${OUT}"
