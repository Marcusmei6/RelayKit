#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-build}"
APP_NAME="RelayKitApp"
BUNDLE_ID="dev.relaykit.app"
MIN_SYSTEM_VERSION="14.0"
APP_MARKETING_VERSION="${RELAYKIT_APP_VERSION:-0.1.1}"
APP_BUILD_NUMBER="${RELAYKIT_BUILD_NUMBER:-2}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="${ROOT_DIR}/dist"
APP_BUNDLE="${DIST_DIR}/${APP_NAME}.app"
APP_CONTENTS="${APP_BUNDLE}/Contents"
APP_MACOS="${APP_CONTENTS}/MacOS"
APP_RESOURCES="${APP_CONTENTS}/Resources"
APP_LAUNCH_AGENTS="${APP_CONTENTS}/Library/LaunchAgents"
APP_REAL_BINARY="${APP_MACOS}/${APP_NAME}.bin"
BUNDLED_GATEWAY="${APP_MACOS}/relay"
INFO_PLIST="${APP_CONTENTS}/Info.plist"
GATEWAY_AGENT_PLIST="${APP_LAUNCH_AGENTS}/dev.relaykit.gateway.plist"

usage() {
  echo "usage: $0 [build|--verify]" >&2
}

scan_release_binary_for_personal_paths() {
  local role="$1"
  local binary="$2"
  local count

  if ! count="$(python3 - "${binary}" <<'PY'
import re
import sys

with open(sys.argv[1], "rb") as binary:
    data = binary.read()
patterns = (b"/" + b"Users/[^/\x00]+/", b"/" + b"home/[^/\x00]+/")
print(sum(len(re.findall(pattern, data)) for pattern in patterns))
PY
  )"; then
    echo "release binary personal-path scan unavailable: ${role}" >&2
    exit 1
  fi
  if [[ ! "${count}" =~ ^[0-9]+$ ]] || (( count > 0 )); then
    echo "release binary personal-path scan failed: ${role} (rule=personal-absolute-path count=${count})" >&2
    exit 1
  fi
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

run_isolated_app_verifier() (
  local verify_port="$1"
  local verifier="$2"
  shift 2
  local verify_root verifier_rc=0 cleanup_rc=0 cleanup_done=0

  verify_root="$(mktemp -d /tmp/relaykit-bundle-verify.XXXXXX)"
  case "${verify_root}" in
    /tmp/relaykit-bundle-verify.*|/private/tmp/relaykit-bundle-verify.*) ;;
    *) echo "Unsafe bundled-gateway verification root" >&2; return 1 ;;
  esac

  cleanup_isolated_app_verifier() {
    if ((cleanup_done != 0)); then
      return "${cleanup_rc}"
    fi
    cleanup_done=1
    cleanup_rc=0
    case "${verify_root}" in
      /tmp/relaykit-bundle-verify.*|/private/tmp/relaykit-bundle-verify.*)
        rm -rf -- "${verify_root}" || cleanup_rc="$?"
        ;;
      *) cleanup_rc=1 ;;
    esac
    return "${cleanup_rc}"
  }

  finish_isolated_app_verifier() {
    local incoming_rc="$1"
    trap - EXIT
    trap '' HUP INT TERM
    if cleanup_isolated_app_verifier; then
      cleanup_rc=0
    else
      cleanup_rc="$?"
    fi
    if ((incoming_rc != 0)); then
      if ((cleanup_rc != 0)); then
        echo "isolated App verifier and cleanup both failed; preserving verifier result" >&2
      fi
      exit "${incoming_rc}"
    fi
    if ((cleanup_rc != 0)); then
      echo "isolated App verifier cleanup failed" >&2
      exit "${cleanup_rc}"
    fi
    exit 0
  }
  trap 'finish_isolated_app_verifier "$?"' EXIT
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM

  mkdir -p "${verify_root}/home" "${verify_root}/preferences" "${verify_root}/codex" "${verify_root}/tmp"
  cd "${verify_root}"
  if env \
    HOME="${verify_root}/home" \
    CFFIXED_USER_HOME="${verify_root}/preferences" \
    CODEX_HOME="${verify_root}/codex" \
    TMPDIR="${verify_root}/tmp/" \
    RELAYKIT_RUNTIME_SAFETY_ROOT="${verify_root}" \
    RELAYKIT_RUNTIME_SAFETY_TEST=1 \
    RELAYKIT_RUNTIME_SAFETY_PORT="${verify_port}" \
    "${verifier}" "$@"; then
    verifier_rc=0
  else
    verifier_rc="$?"
  fi
  finish_isolated_app_verifier "${verifier_rc}"
)

build_bundle() {
  cd "${ROOT_DIR}/gateway"
  go build -trimpath -o bin/relay ./cmd/gateway

  cd "${ROOT_DIR}/app"
  local swift_scratch
  swift_scratch="$(mktemp -d /tmp/relaykit-swift-build.XXXXXX)"
  trap 'rm -rf -- "${swift_scratch}"' RETURN
  local swift_module_cache="${swift_scratch}/swift-module-cache"
  local clang_module_cache="${swift_scratch}/clang-module-cache"
  mkdir -p "${swift_module_cache}" "${clang_module_cache}"
  local -a swift_build_args=(
    -c release
    -Xswiftc -module-cache-path -Xswiftc "${swift_module_cache}"
    -Xcc "-fmodules-cache-path=${clang_module_cache}"
  )
  local prefix_map
  for prefix_map in "${ROOT_DIR}=." "${HOME}=~"; do
    swift_build_args+=(
      -Xswiftc -debug-prefix-map -Xswiftc "${prefix_map}"
      -Xswiftc -file-prefix-map -Xswiftc "${prefix_map}"
      -Xcc "-fdebug-prefix-map=${prefix_map}"
      -Xcc "-ffile-prefix-map=${prefix_map}"
      -Xcc "-fmacro-prefix-map=${prefix_map}"
    )
  done
  swift build --scratch-path "${swift_scratch}" "${swift_build_args[@]}"
  local build_binary
  build_binary="$(swift build --scratch-path "${swift_scratch}" "${swift_build_args[@]}" --show-bin-path)/${APP_NAME}"

  rm -rf "${APP_BUNDLE}"
  mkdir -p "${APP_MACOS}" "${APP_RESOURCES}" "${APP_LAUNCH_AGENTS}"
  cp "${build_binary}" "${APP_REAL_BINARY}"
  cp "${ROOT_DIR}/gateway/bin/relay" "${BUNDLED_GATEWAY}"
  cp "${ROOT_DIR}/examples/providers.example.json" "${APP_RESOURCES}/providers.example.json"
  cp "${ROOT_DIR}/examples/codex.config.example.toml" "${APP_RESOURCES}/codex.config.example.toml"
  cp "${ROOT_DIR}/app/Resources/RelayKitApp.icns" "${APP_RESOURCES}/RelayKitApp.icns"
  cp "${ROOT_DIR}/app/Resources/dev.relaykit.gateway.plist" "${APP_LAUNCH_AGENTS}/dev.relaykit.gateway.plist"
  chmod +x "${APP_REAL_BINARY}"
  chmod +x "${BUNDLED_GATEWAY}"

  scan_release_binary_for_personal_paths app-executable "${APP_REAL_BINARY}"
  scan_release_binary_for_personal_paths bundled-relay "${BUNDLED_GATEWAY}"

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
  <key>CFBundleIconFile</key>
  <string>RelayKitApp</string>
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
  if [[ ! -f "${APP_CONTENTS}/_CodeSignature/CodeResources" ]]; then
    echo "App bundle is missing _CodeSignature/CodeResources" >&2
    exit 1
  fi
  if [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "${INFO_PLIST}")" != "RelayKitApp" || ! -f "${APP_RESOURCES}/RelayKitApp.icns" ]]; then
    echo "App bundle is missing the Finder icon contract" >&2
    exit 1
  fi
  /usr/bin/plutil -lint "${GATEWAY_AGENT_PLIST}" >/dev/null
  if ! cmp -s "${ROOT_DIR}/app/Resources/dev.relaykit.gateway.plist" "${GATEWAY_AGENT_PLIST}"; then
    echo "App bundle background gateway plist differs from its reviewed source" >&2
    exit 1
  fi
  local provisioning_path
  provisioning_path="$(find "${APP_CONTENTS}" \( -name 'embedded.mobileprovision' -o -name '*.mobileprovision' -o -name '*.provisionprofile' \) -print -quit)"
  if [[ -n "${provisioning_path}" ]]; then
    echo "macOS local beta must not include provisioning profiles: ${provisioning_path}" >&2
    exit 1
  fi
  codesign --verify --deep --strict --verbose=4 "${APP_BUNDLE}" >/dev/null
  local signing_details
  signing_details="$(codesign -dvvv "${APP_BUNDLE}" 2>&1)"
  if ! grep -q 'Signature=adhoc' <<<"${signing_details}"; then
    echo "Local beta must be macOS ad-hoc signed" >&2
    exit 1
  fi
  if ! grep -q 'TeamIdentifier=not set' <<<"${signing_details}"; then
    echo "Local beta must not have a Developer ID team identifier" >&2
    exit 1
  fi
  local verify_port
  verify_port="$(select_isolated_verify_port)" || {
    echo "Could not allocate an isolated bundled-gateway verification port" >&2
    exit 1
  }
  run_isolated_app_verifier "${verify_port}" "${APP_REAL_BINARY}" --verify-bundled-gateway
}

if [[ "${RELAYKIT_BUILD_APP_BUNDLE_SOURCE_ONLY:-0}" == "1" ]]; then
  return 0 2>/dev/null || exit 0
fi

case "${MODE}" in
  build)
    build_bundle
    ;;
  --verify|verify)
    build_bundle
    verify_bundle
    ;;
  *)
    usage
    exit 2
    ;;
esac
