#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LABEL="dev.relaykit.gateway"
PLIST="${HOME}/Library/LaunchAgents/${LABEL}.plist"
BINARY="${ROOT}/gateway/bin/relaykit-gateway"
LISTEN="127.0.0.1:19777"
OUT_LOG="/tmp/relaykit-gateway.out.log"
ERR_LOG="/tmp/relaykit-gateway.err.log"

usage() {
  cat <<EOF
Usage:
  $0 install --config /path/to/providers.json [--binary /path/to/relaykit-gateway]
  $0 uninstall
  $0 status
  $0 logs [--lines 80] [--follow]
EOF
}

escape_xml() {
  /usr/bin/sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g'
}

absolute_path() {
  local path="$1"
  local dir
  local base
  dir="$(cd "$(dirname "${path}")" && pwd -P)"
  base="$(basename "${path}")"
  printf '%s/%s' "${dir}" "${base}"
}

is_running() {
  launchctl print "gui/$(id -u)/${LABEL}" 2>/dev/null | /usr/bin/grep -q "state = running"
}

install_helper() {
  local config=""
  local binary="${BINARY}"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --config)
        if [[ $# -lt 2 || -z "${2:-}" ]]; then
          echo "--config is required" >&2
          exit 2
        fi
        config="${2:-}"
        shift 2
        ;;
      --binary)
        if [[ $# -lt 2 || -z "${2:-}" ]]; then
          echo "--binary value is required" >&2
          exit 2
        fi
        binary="${2:-}"
        shift 2
        ;;
      *)
        usage >&2
        exit 2
        ;;
    esac
  done
  if [[ -z "${config}" ]]; then
    echo "--config is required" >&2
    exit 2
  fi
  if [[ ! -x "${binary}" ]]; then
    echo "gateway binary is not executable: ${binary}" >&2
    exit 1
  fi
  if [[ ! -f "${config}" ]]; then
    echo "provider config does not exist: ${config}" >&2
    exit 1
  fi
  binary="$(absolute_path "${binary}")"
  config="$(absolute_path "${config}")"

  mkdir -p "$(dirname "${PLIST}")"
  launchctl bootout "gui/$(id -u)" "${PLIST}" >/dev/null 2>&1 || true
  cat >"${PLIST}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>$(printf '%s' "${binary}" | escape_xml)</string>
    <string>-listen</string>
    <string>${LISTEN}</string>
    <string>-config</string>
    <string>$(printf '%s' "${config}" | escape_xml)</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <false/>
  <key>StandardOutPath</key>
  <string>${OUT_LOG}</string>
  <key>StandardErrorPath</key>
  <string>${ERR_LOG}</string>
</dict>
</plist>
EOF
  launchctl bootstrap "gui/$(id -u)" "${PLIST}"
  sleep 1
  if ! is_running; then
    echo "gateway LaunchAgent did not stay running" >&2
    if [[ -f "${ERR_LOG}" ]]; then
      tail -n 20 "${ERR_LOG}" >&2
    fi
    launchctl bootout "gui/$(id -u)" "${PLIST}" >/dev/null 2>&1 || true
    rm -f "${PLIST}"
    exit 1
  fi
  echo "installed ${LABEL}"
  echo "plist: ${PLIST}"
}

uninstall_helper() {
  launchctl bootout "gui/$(id -u)" "${PLIST}" >/dev/null 2>&1 || true
  rm -f "${PLIST}"
  echo "uninstalled ${LABEL}"
}

status_helper() {
  if is_running; then
    echo "running ${LABEL}"
  else
    echo "not running ${LABEL}"
  fi
}

logs_helper() {
  local lines="80"
  local follow="false"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --lines)
        if [[ $# -lt 2 || ! "${2:-}" =~ ^[0-9]+$ ]]; then
          echo "--lines requires a non-negative integer" >&2
          exit 2
        fi
        lines="$2"
        shift 2
        ;;
      --follow)
        follow="true"
        shift
        ;;
      *)
        usage >&2
        exit 2
        ;;
    esac
  done

  local files=()
  [[ -f "${OUT_LOG}" ]] && files+=("${OUT_LOG}")
  [[ -f "${ERR_LOG}" ]] && files+=("${ERR_LOG}")
  if [[ ${#files[@]} -eq 0 ]]; then
    echo "no RelayKit helper logs found"
    exit 0
  fi

  if [[ "${follow}" == "true" ]]; then
    tail -n "${lines}" -f "${files[@]}"
  else
    tail -n "${lines}" "${files[@]}"
  fi
}

case "${1:-}" in
  install)
    shift
    install_helper "$@"
    ;;
  uninstall)
    uninstall_helper
    ;;
  status)
    status_helper
    ;;
  logs)
    shift
    logs_helper "$@"
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
