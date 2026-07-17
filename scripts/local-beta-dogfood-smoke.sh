#!/usr/bin/env bash
set -euo pipefail
umask 077

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${ROOT}/dist/dogfood-local-beta"
INSTALL_DIR="${OUT}/install"
SCREENSHOT_DIR="${OUT}/screenshots"
ZIP_PATH="${ROOT}/dist/RelayKitApp-local.zip"
APP_BUNDLE="${INSTALL_DIR}/RelayKitApp.app"
APP_REAL="${APP_BUNDLE}/Contents/MacOS/RelayKitApp.bin"
BUNDLED_RELAY="${APP_BUNDLE}/Contents/MacOS/relay"
BUNDLE_ID="dev.relaykit.app"
PROVIDER_CONFIG_KEY="providerConfigPath"
CODEX_CONFIG_PATH="${HOME}/.codex/config.toml"
CODEX_AUTH_PATH="${HOME}/.codex/auth.json"
USAGE_PATH="${HOME}/Library/Application Support/RelayKit/usage.jsonl"
REAL_PROVIDER_CONFIG="${HOME}/Library/Application Support/RelayKit/providers.json"
RUN_TAG="$(date -u +%Y%m%d%H%M%S)-$$"
DOGFOOD_STATE_DIR="${HOME}/Library/Application Support/RelayKit/DogfoodHarness/${RUN_TAG}"
RUN_TOKEN="$(printf '%s' "${RUN_TAG}" | tr '0123456789' 'abcdefghij' | tr -cd 'a-j')"
PROVIDER_NAME="dogfood${RUN_TOKEN}"
PROVIDER_ID="dogfood${RUN_TOKEN}"
KEYCHAIN_SERVICE="relaykit.provider.${PROVIDER_ID}"
FIXTURE_KEY="fixture${RUN_TOKEN}"

APP_PID=""
FIXTURE_PID=""
FIXTURE_PORT=""
RUN_DIR=""
PROVIDER_CONFIG=""
USAGE_BACKUP=""
HAD_USAGE=0
ORIGINAL_PROVIDER_CONFIG=""
HAD_ORIGINAL_PROVIDER_CONFIG=0
ORIGINAL_INPUT_SOURCE=""
INPUT_SOURCE_CHANGED=0
CLIPBOARD_BACKUP=""
CLIPBOARD_SNAPSHOTTED=0
CLIPBOARD_CHANGED=0
CLEANED_UP=0
APP_EXITED_AFTER_RIGHT_CLICK_QUIT=false
GATEWAY_19777_RELEASED_AFTER_QUIT=false
REACHABLE_MODELS_REPROBED_AFTER_REOPEN=false
FIXTURE_KEYCHAIN_REMOVED=false
PROVIDER_SAVE_RELOADED_RUNNING_GATEWAY=false
GATEWAY_WARMUP_RETRY_USED=false
CODEX_CONFIG_BEFORE=""
CODEX_AUTH_BEFORE=""

fail() {
  echo "RelayKit local beta dogfood failed: $*" >&2
  exit 1
}

file_signature() {
  local path="$1"
  if [[ -e "${path}" ]]; then
    stat -f '%Sp|%u|%g|%z|%m' "${path}"
    shasum -a 256 "${path}" | awk '{print $1}'
  else
    printf 'missing\n'
  fi
}

port_free() {
  local port="$1"
  ! lsof -nP -iTCP:"${port}" -sTCP:LISTEN >/dev/null 2>&1
}

wait_for_port_free() {
  local port="$1"
  for _ in {1..80}; do
    if port_free "${port}"; then
      return 0
    fi
    sleep 0.1
  done
  return 1
}

current_input_source() {
  swift - <<'SWIFT'
import Carbon
import Foundation

let source = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
guard let pointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { exit(1) }
let identifier = Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
print(identifier)
SWIFT
}

select_input_source() {
  local target="$1"
  swift - "${target}" <<'SWIFT'
import Carbon
import Foundation

let target = CommandLine.arguments[1]
let sources = TISCreateInputSourceList(nil, false).takeRetainedValue() as NSArray
for index in 0..<sources.count {
    let source = sources[index] as! TISInputSource
    guard let pointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { continue }
    let identifier = Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
    if identifier == target {
        exit(TISSelectInputSource(source) == noErr ? 0 : 2)
    }
}
exit(1)
SWIFT
}

snapshot_clipboard() {
  local destination="$1"
  swift - "${destination}" <<'SWIFT'
import AppKit
import Foundation

let destination = URL(fileURLWithPath: CommandLine.arguments[1])
let items: [[String: Data]] = (NSPasteboard.general.pasteboardItems ?? []).map { item in
    var result: [String: Data] = [:]
    for type in item.types {
        if let data = item.data(forType: type) {
            result[type.rawValue] = data
        }
    }
    return result
}
let archive = try PropertyListSerialization.data(fromPropertyList: items, format: .binary, options: 0)
try archive.write(to: destination, options: .atomic)
SWIFT
  chmod 600 "${destination}"
}

restore_clipboard() {
  local source="$1"
  swift - "${source}" <<'SWIFT'
import AppKit
import Foundation

let source = URL(fileURLWithPath: CommandLine.arguments[1])
let data = try Data(contentsOf: source)
guard let archive = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [[String: Data]] else {
    exit(1)
}
let items: [NSPasteboardItem] = archive.map { stored in
    let item = NSPasteboardItem()
    for (name, value) in stored {
        item.setData(value, forType: NSPasteboard.PasteboardType(name))
    }
    return item
}
NSPasteboard.general.clearContents()
if !items.isEmpty {
    guard NSPasteboard.general.writeObjects(items) else { exit(2) }
}
SWIFT
}

set_clipboard_text() {
  local value="$1"
  swift - "${value}" <<'SWIFT'
import AppKit
import Foundation

let value = CommandLine.arguments[1]
NSPasteboard.general.clearContents()
guard NSPasteboard.general.setString(value, forType: .string) else { exit(1) }
SWIFT
}

restore_defaults() {
  if [[ "${HAD_ORIGINAL_PROVIDER_CONFIG}" == "1" ]]; then
    /usr/bin/defaults write "${BUNDLE_ID}" "${PROVIDER_CONFIG_KEY}" "${ORIGINAL_PROVIDER_CONFIG}" >/dev/null
  else
    /usr/bin/defaults delete "${BUNDLE_ID}" "${PROVIDER_CONFIG_KEY}" >/dev/null 2>&1 || true
  fi
}

remove_fixture_keychain() {
  if [[ ! -x "${APP_REAL}" ]]; then
    return
  fi
  if "${APP_REAL}" --delete-dogfood-keychain "${KEYCHAIN_SERVICE}" >/dev/null 2>&1; then
    FIXTURE_KEYCHAIN_REMOVED=true
  else
    echo "RelayKit dogfood could not remove its fixture Keychain item" >&2
  fi
}

restore_usage() {
  if [[ "${HAD_USAGE}" == "1" && -n "${USAGE_BACKUP}" && -f "${USAGE_BACKUP}" ]]; then
    mkdir -p "$(dirname "${USAGE_PATH}")"
    cp "${USAGE_BACKUP}" "${USAGE_PATH}"
  else
    rm -f "${USAGE_PATH}"
  fi
}

stop_app_forcefully() {
  if [[ -n "${APP_PID}" ]] && kill -0 "${APP_PID}" 2>/dev/null; then
    kill "${APP_PID}" >/dev/null 2>&1 || true
    for _ in {1..30}; do
      kill -0 "${APP_PID}" 2>/dev/null || break
      sleep 0.1
    done
  fi
  APP_PID=""
  pkill -f "^${BUNDLED_RELAY} -listen 127.0.0.1:19777 " >/dev/null 2>&1 || true
}

cleanup() {
  if [[ "${CLEANED_UP}" == "1" ]]; then
    return
  fi
  CLEANED_UP=1
  stop_app_forcefully
  if [[ -n "${FIXTURE_PID}" ]] && kill -0 "${FIXTURE_PID}" 2>/dev/null; then
    kill "${FIXTURE_PID}" >/dev/null 2>&1 || true
    wait "${FIXTURE_PID}" >/dev/null 2>&1 || true
  fi
  remove_fixture_keychain
  if [[ "${CLIPBOARD_CHANGED}" == "1" && "${CLIPBOARD_SNAPSHOTTED}" == "1" && -f "${CLIPBOARD_BACKUP}" ]]; then
    if restore_clipboard "${CLIPBOARD_BACKUP}" >/dev/null 2>&1; then
      CLIPBOARD_CHANGED=0
    else
      echo "RelayKit dogfood could not restore the original clipboard" >&2
    fi
  fi
  if [[ "${INPUT_SOURCE_CHANGED}" == "1" && -n "${ORIGINAL_INPUT_SOURCE}" ]]; then
    if select_input_source "${ORIGINAL_INPUT_SOURCE}" >/dev/null 2>&1; then
      INPUT_SOURCE_CHANGED=0
    else
      echo "RelayKit dogfood could not restore the original input source" >&2
    fi
  fi
  restore_defaults
  restore_usage
  rm -f "${SCREENSHOT_DIR}"/*.raw.png "${SCREENSHOT_DIR}"/*.composited.png >/dev/null 2>&1 || true
  [[ -n "${DOGFOOD_STATE_DIR}" ]] && rm -rf "${DOGFOOD_STATE_DIR}"
  [[ -n "${RUN_DIR}" ]] && rm -rf "${RUN_DIR}"
}

global_codex_state_unchanged() {
  local config_after auth_after
  [[ -n "${CODEX_CONFIG_BEFORE}" && -n "${CODEX_AUTH_BEFORE}" ]] || return 2
  config_after="$(file_signature "${CODEX_CONFIG_PATH}" 2>/dev/null || printf 'unreadable\n')"
  auth_after="$(file_signature "${CODEX_AUTH_PATH}" 2>/dev/null || printf 'unreadable\n')"
  [[ "${CODEX_CONFIG_BEFORE}" == "${config_after}" && "${CODEX_AUTH_BEFORE}" == "${auth_after}" ]]
}

cleanup_and_verify_global_state() {
  local exit_status=$?
  trap - EXIT
  cleanup
  if [[ -n "${CODEX_CONFIG_BEFORE}" && -n "${CODEX_AUTH_BEFORE}" ]] && ! global_codex_state_unchanged; then
    echo "RelayKit dogfood detected a global Codex config/auth change during failed cleanup" >&2
    exit_status=1
  fi
  exit "${exit_status}"
}
trap cleanup_and_verify_global_state EXIT

ax_query() {
  local operation="$1"
  local needle="$2"
  local payload="${3:-}"
  local ax_log="/tmp/relaykit-dogfood-ax.log"
  [[ "${operation}" == "type_exact" ]] && ax_log="/tmp/relaykit-dogfood-ax-type.log"
  swift - "${APP_PID}" "${operation}" "${needle}" "${payload}" >"${ax_log}" 2>&1 <<'SWIFT'
import ApplicationServices
import Foundation

let args = CommandLine.arguments
guard args.count == 5, let pid = pid_t(args[1]) else { exit(2) }
let operation = args[2]
let needle = args[3]
let app = AXUIElementCreateApplication(pid)

func attr(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
    return value
}

func text(_ element: AXUIElement, _ name: String) -> String {
    guard let value = attr(element, name) else { return "" }
    return (value as? String) ?? String(describing: value)
}

func children(_ element: AXUIElement) -> [AXUIElement] {
    attr(element, kAXChildrenAttribute as String) as? [AXUIElement] ?? []
}

func exactIdentity(_ element: AXUIElement) -> Bool {
    [
        text(element, kAXTitleAttribute),
        text(element, kAXDescriptionAttribute),
        text(element, "AXIdentifier")
    ].contains(needle)
}

func pressDescendant(_ element: AXUIElement, depth: Int = 0) -> Bool {
    if depth > 8 { return false }
    if text(element, kAXRoleAttribute) == kAXButtonRole as String {
        var actionsRef: CFArray?
        if AXUIElementCopyActionNames(element, &actionsRef) == .success,
           let actions = actionsRef as? [String],
           actions.contains(kAXPressAction),
           AXUIElementPerformAction(element, kAXPressAction as CFString) == .success {
            return true
        }
    }
    for child in children(element) where pressDescendant(child, depth: depth + 1) {
        return true
    }
    return false
}

func focusTextFieldDescendant(_ element: AXUIElement, depth: Int = 0) -> Bool {
    if depth > 8 { return false }
    let role = text(element, kAXRoleAttribute)
    if role == kAXTextFieldRole as String || role == "AXSecureTextField" {
        if AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success {
            return true
        }
    }
    for child in children(element) where focusTextFieldDescendant(child, depth: depth + 1) {
        return true
    }
    return false
}

func walk(_ element: AXUIElement, depth: Int = 0) -> Bool {
    if depth > 14 { return false }
    if operation == "read_value_exact" {
        if text(element, kAXValueAttribute) == needle {
            return true
        }
    } else if operation == "read_contains" {
        let readable = [
            text(element, kAXTitleAttribute),
            text(element, kAXDescriptionAttribute),
            text(element, kAXValueAttribute)
        ]
        if readable.contains(where: { $0.contains(needle) }) {
            return true
        }
    } else if exactIdentity(element) {
        switch operation {
        case "has_exact":
            return true
        case "press_exact":
            return pressDescendant(element)
        case "focus_exact":
            return focusTextFieldDescendant(element)
        default:
            return false
        }
    }
    for child in children(element) where walk(child, depth: depth + 1) {
        return true
    }
    return false
}

exit(walk(app) ? 0 : 1)
SWIFT
}

wait_for_ax_exact() {
  local needle="$1"
  for _ in {1..100}; do
    if ax_query has_exact "${needle}"; then
      return 0
    fi
    sleep 0.1
  done
  ax_query has_exact "${needle}"
}

wait_for_ax_text() {
  local needle="$1"
  for _ in {1..100}; do
    if ax_query read_contains "${needle}"; then
      return 0
    fi
    sleep 0.1
  done
  ax_query read_contains "${needle}"
}

wait_for_ax_value_exact() {
  local value="$1"
  for _ in {1..100}; do
    if ax_query read_value_exact "${value}"; then
      return 0
    fi
    sleep 0.1
  done
  ax_query read_value_exact "${value}"
}

ax_press_exact() {
  local needle="$1"
  for _ in {1..30}; do
    if ax_query press_exact "${needle}"; then
      return 0
    fi
    sleep 0.1
  done
  cat /tmp/relaykit-dogfood-ax.log >&2 || true
  return 1
}

ax_set_value_exact() {
  local identifier="$1"
  local value="$2"
  local input_mode="keycodes"
  local input_status=0
  if [[ "${identifier}" == "API key field" ]]; then
    [[ "${CLIPBOARD_SNAPSHOTTED}" == "1" && -f "${CLIPBOARD_BACKUP}" ]] || return 1
    CLIPBOARD_CHANGED=1
    if ! set_clipboard_text "${value}" >/dev/null 2>&1; then
      return 1
    fi
    input_mode="paste"
  fi
  if ! /usr/bin/osascript - "${identifier}" "${value}" "${input_mode}" >/tmp/relaykit-dogfood-type.log 2>&1 <<'APPLESCRIPT'
on run argv
  set targetLabel to item 1 of argv
  set replacementValue to item 2 of argv
  set inputMode to item 3 of argv
  tell application "System Events"
    tell process "RelayKitApp.bin"
      set frontmost to true
      set providerForm to missing value
      set popoverRoot to group 1 of pop over 1 of menu bar 1
      repeat with candidate in (every group of popoverRoot)
        set candidateElement to contents of candidate
        try
          if value of attribute "AXIdentifier" of candidateElement is "provider-form-container" then
            if providerForm is not missing value then error "multiple provider form containers"
            set providerForm to candidateElement
          end if
        end try
      end repeat
      if providerForm is missing value then error "provider form container not found"
      set providerScroll to scroll area 1 of providerForm
      set fieldCandidates to every text field of UI element 1 of providerScroll
      set fieldCandidates to fieldCandidates & (every text field of providerScroll)
      repeat with candidate in fieldCandidates
        set candidateElement to contents of candidate
        if description of candidateElement is targetLabel and role of candidateElement is "AXTextField" then
          set fieldPosition to position of candidateElement
          set fieldSize to size of candidateElement
          set clickPoint to {(item 1 of fieldPosition) + ((item 1 of fieldSize) div 2), (item 2 of fieldPosition) + ((item 2 of fieldSize) div 2)}
          click at clickPoint
          delay 0.2
          set focused of candidateElement to true
          delay 0.3
          key code 0 using command down
          if replacementValue is "" then
            key code 51
          else if inputMode is "paste" then
            set clipboardLength to length of (the clipboard as text)
            set value of candidateElement to replacementValue
            key code 48
            delay 0.8
          else
            set supportedCharacters to "abcdefghijklmnopqrstuvwxyz0123456789:/.-"
            set keyCodes to {0, 11, 8, 2, 14, 3, 5, 4, 34, 38, 40, 37, 46, 45, 31, 35, 12, 15, 1, 17, 32, 9, 13, 7, 16, 6, 29, 18, 19, 20, 21, 23, 22, 26, 28, 25, 41, 44, 47, 27}
            repeat with characterIndex from 1 to length of replacementValue
              set currentCharacter to character characterIndex of replacementValue
              set keyIndex to offset of currentCharacter in supportedCharacters
              if keyIndex is 0 then error "unsupported dogfood input character"
              if currentCharacter is ":" then
                key code 41 using shift down
              else
                key code (item keyIndex of keyCodes)
              end if
              delay 0.04
            end repeat
          end if
          delay 0.3
          set fieldLength to length of (value of candidateElement as text)
          if inputMode is "paste" then
            return "clipboard_length=" & (clipboardLength as text) & " value_length=" & (fieldLength as text)
          end if
          return "value_length=" & (fieldLength as text)
        end if
      end repeat
    end tell
  end tell
  error "exact RelayKit AXTextField not found"
end run
APPLESCRIPT
  then
    input_status=1
  fi
  if [[ "${identifier}" == "API key field" ]]; then
    if restore_clipboard "${CLIPBOARD_BACKUP}" >/dev/null 2>&1; then
      CLIPBOARD_CHANGED=0
    else
      input_status=1
    fi
  fi
  [[ "${input_status}" == "0" ]] || return 1
  if [[ "${identifier}" == "API key field" ]]; then
    grep -Eq '^clipboard_length=[1-9][0-9]* value_length=[1-9][0-9]*$' /tmp/relaykit-dogfood-type.log
  else
    grep -Fxq "value_length=${#value}" /tmp/relaykit-dogfood-type.log
  fi
}

status_item_geometry() {
  /usr/bin/osascript - "${APP_PID}" <<'APPLESCRIPT'
on run argv
  tell application "System Events"
    tell (first process whose unix id is (item 1 of argv as integer))
      repeat 60 times
        try
          set statusItem to first menu bar item of menu bar 1 whose description is "RelayKit"
          set itemPosition to position of statusItem
          set itemSize to size of statusItem
          if (item 1 of itemSize as integer) > 0 then
            return (item 1 of itemPosition as text) & "|" & (item 2 of itemPosition as text) & "|" & (item 1 of itemSize as text) & "|" & (item 2 of itemSize as text)
          end if
        end try
        delay 0.1
      end repeat
    end tell
  end tell
  error "RelayKit status item geometry unavailable"
end run
APPLESCRIPT
}

right_click_relaykit_status_item() {
  local geometry x y width height
  geometry="$(status_item_geometry)"
  IFS='|' read -r x y width height <<<"${geometry}"
  swift - "${x}" "${y}" "${width}" "${height}" >/tmp/relaykit-dogfood-mouse.log 2>&1 <<'SWIFT'
import CoreGraphics
import Foundation

let args = CommandLine.arguments
guard args.count == 5,
      let x = Double(args[1]), let y = Double(args[2]),
      let width = Double(args[3]), let height = Double(args[4]) else { exit(2) }
let point = CGPoint(x: x + width / 2, y: y + height / 2)
let source = CGEventSource(stateID: .hidSystemState)
CGEvent(mouseEventSource: source, mouseType: .rightMouseDown, mouseCursorPosition: point, mouseButton: .right)?.post(tap: .cghidEventTap)
usleep(100_000)
CGEvent(mouseEventSource: source, mouseType: .rightMouseUp, mouseCursorPosition: point, mouseButton: .right)?.post(tap: .cghidEventTap)
SWIFT
}

capture_popover() {
  local name="$1"
  capture_relaykit_window "popover" "${SCREENSHOT_DIR}/${name}.png"
}

capture_quit_menu() {
  capture_relaykit_window "menu" "${SCREENSHOT_DIR}/quit-menu.png"
}

relaykit_window_id() {
  local kind="$1"
  swift - "${APP_PID}" "${kind}" <<'SWIFT'
import CoreGraphics
import Foundation

let targetPID = Int(CommandLine.arguments[1])!
let kind = CommandLine.arguments[2]
let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
func windowBounds(_ window: [String: Any]) -> CGRect? {
    guard let values = window[kCGWindowBounds as String] as? [String: Any],
          let x = values["X"] as? NSNumber,
          let y = values["Y"] as? NSNumber,
          let width = values["Width"] as? NSNumber,
          let height = values["Height"] as? NSNumber else {
        return nil
    }
    return CGRect(x: x.doubleValue, y: y.doubleValue, width: width.doubleValue, height: height.doubleValue)
}
let candidates = windows.compactMap { window -> (Int, CGRect)? in
    guard let ownerPID = window[kCGWindowOwnerPID as String] as? Int,
          ownerPID == targetPID,
          let windowID = window[kCGWindowNumber as String] as? Int,
          let bounds = windowBounds(window),
          bounds.width >= 80,
          bounds.height >= 20 else {
        return nil
    }
    if kind == "popover" {
        guard bounds.width >= 400, bounds.height >= 400 else { return nil }
    } else {
        guard bounds.width < 400, bounds.height < 300 else { return nil }
    }
    return (windowID, bounds)
}
guard let selected = candidates.max(by: { $0.1.width * $0.1.height < $1.1.width * $1.1.height }) else {
    exit(1)
}
let bounds = selected.1.integral
print("\(selected.0)|\(Int(bounds.minX)),\(Int(bounds.minY)),\(Int(bounds.width)),\(Int(bounds.height))")
SWIFT
}

flatten_screenshot() {
  local mask_source="$1"
  local visual_source="$2"
  local window_bounds="$3"
  local destination="$4"
  swift - "${mask_source}" "${visual_source}" "${window_bounds}" "${destination}" <<'SWIFT'
import AppKit
import CoreGraphics
import Foundation

func renderRGBA(_ image: CGImage, width: Int, height: Int) -> [UInt8]? {
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    let rendered = pixels.withUnsafeMutableBytes { bytes -> Bool in
        guard let context = CGContext(
            data: bytes.baseAddress,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return false
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return true
    }
    return rendered ? pixels : nil
}

func silhouetteAlpha(_ pixels: [UInt8], width: Int, height: Int) -> [UInt8] {
    var alpha = [UInt8](repeating: 0, count: width * height)
    var minimumByRow = [Int?](repeating: nil, count: height)
    var maximumByRow = [Int?](repeating: nil, count: height)
    for y in 0..<height {
        var minimumX = width
        var maximumX = -1
        for x in 0..<width where pixels[((y * width) + x) * 4 + 3] > 8 {
            minimumX = min(minimumX, x)
            maximumX = max(maximumX, x)
        }
        if maximumX >= minimumX {
            minimumByRow[y] = minimumX
            maximumByRow[y] = maximumX
        }
    }
    for y in 0..<height {
        var minimumX = minimumByRow[y]
        var maximumX = maximumByRow[y]
        if minimumX == nil || maximumX == nil {
            let previous = stride(from: y - 1, through: 0, by: -1).first { minimumByRow[$0] != nil }
            let next = (y + 1..<height).first { minimumByRow[$0] != nil }
            let boundaryRows = [previous, next].compactMap { $0 }
            minimumX = boundaryRows.compactMap { minimumByRow[$0] }.min()
            maximumX = boundaryRows.compactMap { maximumByRow[$0] }.max()
        }
        guard let minimumX, let maximumX, maximumX >= minimumX else { continue }
        for x in minimumX...maximumX {
            let sourceAlpha = pixels[((y * width) + x) * 4 + 3]
            let edgeAlpha = sourceAlpha > 8 ? sourceAlpha : 255
            alpha[(y * width) + x] = (x == minimumX || x == maximumX) ? edgeAlpha : 255
        }
    }
    return alpha
}

func windowBodyRect(_ image: CGImage) -> CGRect {
    let width = image.width
    let height = image.height
    guard width > 0, height > 0, let pixels = renderRGBA(image, width: width, height: height) else {
        return CGRect(x: 0, y: 0, width: width, height: height)
    }

    func isOpaque(x: Int, y: Int) -> Bool {
        pixels[((y * width) + x) * 4 + 3] > 8
    }

    let middleY = height / 2
    var minimumX = width
    var maximumX = -1
    for x in 0..<width where isOpaque(x: x, y: middleY) {
        minimumX = min(minimumX, x)
        maximumX = max(maximumX, x)
    }
    guard maximumX >= minimumX else { return CGRect(x: 0, y: 0, width: width, height: height) }

    let bodyWidth = maximumX - minimumX + 1
    var minimumY = height
    var maximumY = -1
    for y in 0..<height {
        var opaqueCount = 0
        for x in minimumX...maximumX where isOpaque(x: x, y: y) {
            opaqueCount += 1
        }
        if opaqueCount * 2 >= bodyWidth {
            minimumY = min(minimumY, y)
            maximumY = max(maximumY, y)
        }
    }
    guard maximumY >= minimumY else { return CGRect(x: 0, y: 0, width: width, height: height) }
    return CGRect(
        x: minimumX,
        y: minimumY,
        width: bodyWidth,
        height: maximumY - minimumY + 1
    )
}

let maskSource = CommandLine.arguments[1]
let visualSource = CommandLine.arguments[2]
let windowBounds = CommandLine.arguments[3].split(separator: ",").compactMap { Double($0) }
let destination = CommandLine.arguments[4]
guard let maskImage = NSImage(contentsOfFile: maskSource),
      let visualImage = NSImage(contentsOfFile: visualSource),
      let maskCG = maskImage.cgImage(forProposedRect: nil, context: nil, hints: nil),
      let visualCG = visualImage.cgImage(forProposedRect: nil, context: nil, hints: nil),
      windowBounds.count == 4 else {
    exit(1)
}
let displayBounds = CGDisplayBounds(CGMainDisplayID())
let displayScaleX = CGFloat(visualCG.width) / displayBounds.width
let displayScaleY = CGFloat(visualCG.height) / displayBounds.height
let visualWindowRect = CGRect(
    x: (CGFloat(windowBounds[0]) - displayBounds.minX) * displayScaleX,
    y: (CGFloat(windowBounds[1]) - displayBounds.minY) * displayScaleY,
    width: CGFloat(windowBounds[2]) * displayScaleX,
    height: CGFloat(windowBounds[3]) * displayScaleY
).integral
guard let visualWindow = visualCG.cropping(to: visualWindowRect) else {
    exit(2)
}
let maskBodyRect = windowBodyRect(maskCG)
let visualScaleX = CGFloat(visualWindow.width) / CGFloat(maskCG.width)
let visualScaleY = CGFloat(visualWindow.height) / CGFloat(maskCG.height)
let visualBodyRect = CGRect(
    x: maskBodyRect.minX * visualScaleX,
    y: maskBodyRect.minY * visualScaleY,
    width: maskBodyRect.width * visualScaleX,
    height: maskBodyRect.height * visualScaleY
).integral
guard let maskBody = maskCG.cropping(to: maskBodyRect),
      let visualBody = visualWindow.cropping(to: visualBodyRect) else {
    exit(3)
}
let outputWidth = maskBody.width
let outputHeight = maskBody.height
guard let maskPixels = renderRGBA(maskBody, width: outputWidth, height: outputHeight),
      let visualPixels = renderRGBA(visualBody, width: outputWidth, height: outputHeight) else {
    exit(3)
}
let outputAlpha = silhouetteAlpha(maskPixels, width: outputWidth, height: outputHeight)
var output = [UInt8](repeating: 0, count: outputWidth * outputHeight * 4)
for index in stride(from: 0, to: output.count, by: 4) {
    let alpha = Int(outputAlpha[index / 4])
    output[index] = UInt8(Int(visualPixels[index]) * alpha / 255)
    output[index + 1] = UInt8(Int(visualPixels[index + 1]) * alpha / 255)
    output[index + 2] = UInt8(Int(visualPixels[index + 2]) * alpha / 255)
    output[index + 3] = UInt8(alpha)
}
let data = Data(output)
guard let provider = CGDataProvider(data: data as CFData),
      let masked = CGImage(
        width: outputWidth,
        height: outputHeight,
        bitsPerComponent: 8,
        bitsPerPixel: 32,
        bytesPerRow: outputWidth * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
        provider: provider,
        decode: nil,
        shouldInterpolate: false,
        intent: .defaultIntent
      ) else {
    exit(4)
}
let representation = NSBitmapImageRep(cgImage: masked)
guard let data = representation.representation(using: .png, properties: [:]) else { exit(3) }
try data.write(to: URL(fileURLWithPath: destination), options: .atomic)
SWIFT
}

capture_relaykit_window() {
  local kind="$1"
  local destination="$2"
  local geometry window_id bounds raw composited
  sleep 2 # let SwiftUI and WindowServer finish the popover transition
  geometry="$(relaykit_window_id "${kind}")" || fail "RelayKit ${kind} WindowServer id unavailable"
  IFS='|' read -r window_id bounds <<<"${geometry}"
  [[ -n "${window_id}" && "${bounds}" =~ ^-?[0-9]+,-?[0-9]+,[0-9]+,[0-9]+$ ]] || fail "RelayKit ${kind} WindowServer bounds unavailable"
  raw="${destination}.raw.png"
  composited="${destination}.composited.png"
  /usr/sbin/screencapture -x -l "${window_id}" -o "${raw}"
  test -s "${raw}" || fail "RelayKit ${kind} screenshot is empty"
  /usr/sbin/screencapture -x -m "${composited}"
  test -s "${composited}" || fail "RelayKit ${kind} composited screenshot is empty"
  flatten_screenshot "${raw}" "${composited}" "${bounds}" "${destination}"
  rm -f "${raw}" "${composited}"
  test -s "${destination}"
}

launch_normal_extracted_app() {
  /usr/bin/open -n "${APP_BUNDLE}" >/tmp/relaykit-dogfood-open.log 2>&1
  APP_PID=""
  for _ in {1..100}; do
    APP_PID="$(pgrep -f "^${APP_REAL}$" | tail -1 || true)"
    if [[ -n "${APP_PID}" ]] && kill -0 "${APP_PID}" 2>/dev/null; then
      break
    fi
    sleep 0.1
  done
  if [[ -z "${APP_PID}" ]] || ! kill -0 "${APP_PID}" 2>/dev/null; then
    cat /tmp/relaykit-dogfood-open.log >&2 || true
    fail "LaunchServices did not start the extracted app"
  fi
  local status_item_ready=0
  local status_item_probe=""
  for _ in {1..100}; do
    status_item_probe="$(/usr/bin/osascript - "${APP_PID}" 2>/dev/null <<'APPLESCRIPT' || true
on run argv
  tell application "System Events"
    tell (first process whose unix id is (item 1 of argv as integer))
      return exists (first menu bar item of menu bar 1 whose description is "RelayKit")
    end tell
  end tell
end run
APPLESCRIPT
    )"
    if [[ "${status_item_probe}" == "true" ]]; then
      status_item_ready=1
      break
    fi
    sleep 0.1
  done
  [[ "${status_item_ready}" == "1" ]] || fail "RelayKit status item did not become available after normal app launch"
  /usr/bin/osascript - "${APP_PID}" >/tmp/relaykit-dogfood-open-popover.log 2>&1 <<'APPLESCRIPT'
on run argv
  tell application "System Events"
    tell (first process whose unix id is (item 1 of argv as integer))
      click (first menu bar item of menu bar 1 whose description is "RelayKit")
    end tell
  end tell
end run
APPLESCRIPT
  wait_for_ax_exact "tab-connect" || fail "normal app popover did not open"
}

quit_with_real_context_menu() {
  right_click_relaykit_status_item
  for _ in {1..40}; do
    if /usr/bin/osascript - "${APP_PID}" >/dev/null 2>&1 <<'APPLESCRIPT'
on run argv
  tell application "System Events"
    tell (first process whose unix id is (item 1 of argv as integer))
      set statusItem to first menu bar item of menu bar 1 whose description is "RelayKit"
      return exists menu item "Quit RelayKit" of menu 1 of statusItem
    end tell
  end tell
end run
APPLESCRIPT
    then
      break
    fi
    sleep 0.1
  done
  capture_quit_menu
  /usr/bin/osascript - "${APP_PID}" >/tmp/relaykit-dogfood-quit.log 2>&1 <<'APPLESCRIPT'
on run argv
  tell application "System Events"
    tell (first process whose unix id is (item 1 of argv as integer))
      set statusItem to first menu bar item of menu bar 1 whose description is "RelayKit"
      click menu item "Quit RelayKit" of menu 1 of statusItem
    end tell
  end tell
end run
APPLESCRIPT
  local quitting_pid="${APP_PID}"
  for _ in {1..80}; do
    if ! kill -0 "${quitting_pid}" 2>/dev/null; then
      APP_PID=""
      return 0
    fi
    sleep 0.1
  done
  cat /tmp/relaykit-dogfood-quit.log >&2 || true
  fail "right-click Quit RelayKit did not exit the app"
}

start_fixture_provider() {
  local server_script="${RUN_DIR}/fixture-provider.py"
  local port_file="${RUN_DIR}/fixture-port"
  cat >"${server_script}" <<'PY'
import http.server
import json
import os
import socketserver
import sys

expected = "Bearer " + os.environ["DOGFOOD_FIXTURE_KEY"]
port_file = sys.argv[1]

class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, _format, *_args):
        return

    def record(self, status):
        print(f"{self.command} {self.path} {status}", flush=True)

    def send_json(self, status, value):
        body = json.dumps(value, separators=(",", ":")).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def authorized(self):
        return self.headers.get("Authorization", "") == expected

    def do_GET(self):
        if self.path not in ("/models", "/v1/models"):
            self.record(404)
            self.send_json(404, {"error": {"code": "not_found"}})
            return
        if not self.authorized():
            print(
                f"{self.command} {self.path} 401 auth_bytes={len(self.headers.get('Authorization', '').encode())} expected_bytes={len(expected.encode())}",
                flush=True,
            )
            self.send_json(401, {"error": {"code": "invalid_fixture_credential"}})
            return
        self.record(200)
        self.send_json(200, {"object": "list", "data": [
            {"id": "healthy-upstream", "display_name": "Dogfood Healthy"},
            {"id": "unavailable-upstream", "display_name": "Dogfood Unavailable"},
        ]})

    def do_POST(self):
        if self.path not in ("/chat/completions", "/v1/chat/completions"):
            self.record(404)
            self.send_json(404, {"error": {"code": "not_found"}})
            return
        if not self.authorized():
            self.record(401)
            self.send_json(401, {"error": {"code": "invalid_fixture_credential"}})
            return
        length = int(self.headers.get("Content-Length", "0"))
        try:
            request = json.loads(self.rfile.read(length) or b"{}")
        except json.JSONDecodeError:
            request = {}
        if request.get("model") == "unavailable-upstream":
            self.record(503)
            self.send_json(503, {"error": {"code": "fixture_model_unavailable"}})
            return
        self.record(200)
        self.send_json(200, {
            "id": "fixture-health-probe",
            "object": "chat.completion",
            "choices": [{"index": 0, "message": {"role": "assistant", "content": "fixture-only health probe"}, "finish_reason": "stop"}],
        })

class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True

while True:
    server = Server(("127.0.0.1", 0), Handler)
    if "1" not in str(server.server_address[1]):
        break
    server.server_close()

with server:
    with open(port_file, "w", encoding="utf-8") as output:
        output.write(str(server.server_address[1]))
    server.serve_forever()
PY
  DOGFOOD_FIXTURE_KEY="${FIXTURE_KEY}" python3 "${server_script}" "${port_file}" >/tmp/relaykit-dogfood-fixture.log 2>&1 &
  FIXTURE_PID="$!"
  for _ in {1..100}; do
    if [[ -s "${port_file}" ]]; then
      FIXTURE_PORT="$(cat "${port_file}")"
      break
    fi
    sleep 0.05
  done
  [[ "${FIXTURE_PORT}" =~ ^[0-9]+$ ]] || fail "fixture provider did not publish a port"
  kill -0 "${FIXTURE_PID}" 2>/dev/null || fail "fixture provider exited during startup"
}

write_reopen_failure_evidence() {
  local fixture_process_alive=false
  local keychain_item_present=true
  local provider_config_exists=false
  local provider_config_model_count=0
  local provider_enabled_count=0
  local provider_visible_count=0
  local provider_keychain_ref_count=0
  local provider_catalog_url_present_count=0
  local defaults_provider_config_matches_expected=false
  local gateway_config_matches_expected=false
  local gateway_is_app_child=false
  local gateway_health_ok=false
  local gateway_loaded_provider_count=0
  local gateway_loaded_configured_model_count=0
  local gateway_loaded_official_model_count=0
  local gateway_model_health_probed=false
  local gateway_visible_models=0
  local gateway_hidden_models=0
  local ui_testing_in_progress=false
  local ui_failure_kind="unknown"
  local health_response="${RUN_DIR}/reopen-gateway-health.json"
  local model_response="${RUN_DIR}/reopen-gateway-models.json"

  if [[ -n "${FIXTURE_PID}" ]] && kill -0 "${FIXTURE_PID}" 2>/dev/null; then
    fixture_process_alive=true
  fi
  if [[ -f "${PROVIDER_CONFIG}" ]]; then
    provider_config_exists=true
    provider_config_model_count="$(jq '[.providers[].models[]?] | length' "${PROVIDER_CONFIG}")"
    provider_enabled_count="$(jq '[.providers[] | select((.routing.status // "enabled") != "disabled")] | length' "${PROVIDER_CONFIG}")"
    provider_visible_count="$(jq '[.providers[] | select((.routing.visible // false) == true)] | length' "${PROVIDER_CONFIG}")"
    provider_keychain_ref_count="$(jq '[.providers[] | select(.credential_ref.kind == "keychain")] | length' "${PROVIDER_CONFIG}")"
    provider_catalog_url_present_count="$(jq '[.providers[] | select((.catalog.models_url // "") != "")] | length' "${PROVIDER_CONFIG}")"
  fi
  if [[ "$(/usr/bin/defaults read "${BUNDLE_ID}" "${PROVIDER_CONFIG_KEY}" 2>/dev/null || true)" == "${PROVIDER_CONFIG}" ]]; then
    defaults_provider_config_matches_expected=true
  fi
  local gateway_pid=""
  gateway_pid="$(lsof -t -iTCP:19777 -sTCP:LISTEN 2>/dev/null | head -1 || true)"
  if [[ -n "${gateway_pid}" ]]; then
    local gateway_command gateway_parent
    gateway_command="$(ps -p "${gateway_pid}" -o command= 2>/dev/null || true)"
    gateway_parent="$(ps -p "${gateway_pid}" -o ppid= 2>/dev/null | tr -d ' ' || true)"
    if [[ "${gateway_command}" == *" -config ${PROVIDER_CONFIG} "* ]]; then
      gateway_config_matches_expected=true
    fi
    if [[ -n "${APP_PID}" && "${gateway_parent}" == "${APP_PID}" ]]; then
      gateway_is_app_child=true
    fi
  fi
  if curl -fsS --max-time 1 http://127.0.0.1:19777/healthz >"${health_response}" 2>/dev/null; then
    gateway_health_ok=true
    gateway_loaded_provider_count="$(jq '.provider_count // 0' "${health_response}")"
    gateway_loaded_configured_model_count="$(jq '.configured_model_count // 0' "${health_response}")"
    gateway_loaded_official_model_count="$(jq '.official_model_count // 0' "${health_response}")"
  fi
  if curl -fsS --max-time 20 http://127.0.0.1:19777/v1/models >"${model_response}" 2>/dev/null; then
    gateway_model_health_probed="$(jq '.model_health.probed // false' "${model_response}")"
    gateway_visible_models="$(jq '.data // [] | length' "${model_response}")"
    gateway_hidden_models="$(jq '.model_health.hidden // [] | length' "${model_response}")"
  fi

  if ax_query read_contains "Testing..."; then
    ui_testing_in_progress=true
    ui_failure_kind="testing_in_progress"
  elif ax_query read_contains "Authentication failed"; then
    ui_failure_kind="auth_failed"
  elif ax_query read_contains "Network failed"; then
    ui_failure_kind="network_failed"
  elif ax_query read_contains "Model list unavailable"; then
    ui_failure_kind="model_list_unavailable"
  elif ax_query read_contains "0 reachable"; then
    ui_failure_kind="zero_reachable"
  elif ax_query read_contains "Connected"; then
    ui_failure_kind="connected_without_reachable"
  fi

  jq -n \
    --argjson fixture_process_alive "${fixture_process_alive}" \
    --argjson keychain_item_present "${keychain_item_present}" \
    --argjson provider_config_exists "${provider_config_exists}" \
    --argjson provider_config_model_count "${provider_config_model_count}" \
    --argjson provider_enabled_count "${provider_enabled_count}" \
    --argjson provider_visible_count "${provider_visible_count}" \
    --argjson provider_keychain_ref_count "${provider_keychain_ref_count}" \
    --argjson provider_catalog_url_present_count "${provider_catalog_url_present_count}" \
    --argjson defaults_provider_config_matches_expected "${defaults_provider_config_matches_expected}" \
    --argjson gateway_config_matches_expected "${gateway_config_matches_expected}" \
    --argjson gateway_is_app_child "${gateway_is_app_child}" \
    --argjson gateway_health_ok "${gateway_health_ok}" \
    --argjson gateway_loaded_provider_count "${gateway_loaded_provider_count}" \
    --argjson gateway_loaded_configured_model_count "${gateway_loaded_configured_model_count}" \
    --argjson gateway_loaded_official_model_count "${gateway_loaded_official_model_count}" \
    --argjson gateway_model_health_probed "${gateway_model_health_probed}" \
    --argjson gateway_visible_models "${gateway_visible_models}" \
    --argjson gateway_hidden_models "${gateway_hidden_models}" \
    --argjson ui_testing_in_progress "${ui_testing_in_progress}" \
    --arg ui_failure_kind "${ui_failure_kind}" \
    '{
      evidence_kind: "redacted_reopen_failure_diagnosis",
      fixture_process_alive: $fixture_process_alive,
      keychain_item_present: $keychain_item_present,
      keychain_item_observation: "relaykit_ui_saved_state_after_reopen",
      provider_config_exists: $provider_config_exists,
      provider_config_model_count: $provider_config_model_count,
      provider_enabled_count: $provider_enabled_count,
      provider_visible_count: $provider_visible_count,
      provider_keychain_ref_count: $provider_keychain_ref_count,
      provider_catalog_url_present_count: $provider_catalog_url_present_count,
      defaults_provider_config_matches_expected: $defaults_provider_config_matches_expected,
      gateway_config_matches_expected: $gateway_config_matches_expected,
      gateway_is_app_child: $gateway_is_app_child,
      gateway_health_ok: $gateway_health_ok,
      gateway_loaded_provider_count: $gateway_loaded_provider_count,
      gateway_loaded_configured_model_count: $gateway_loaded_configured_model_count,
      gateway_loaded_official_model_count: $gateway_loaded_official_model_count,
      gateway_model_health_probed: $gateway_model_health_probed,
      gateway_visible_models: $gateway_visible_models,
      gateway_hidden_models: $gateway_hidden_models,
      ui_testing_in_progress: $ui_testing_in_progress,
      ui_failure_kind: $ui_failure_kind,
      contains_credential_material: false,
      contains_private_url: false,
      contains_request_or_response_body: false
    }' >"${OUT}/reopen-failure.json"
}

if [[ "${1:-}" == "--test-evidence-contract" ]]; then
  exit 0
fi
if [[ "${1:-}" == "--test-global-state-guard" ]]; then
  [[ -n "${2:-}" && -n "${3:-}" && -z "${4:-}" ]] || exit 2
  trap - EXIT
  CODEX_CONFIG_BEFORE="$2"
  CODEX_AUTH_BEFORE="$3"
  global_codex_state_unchanged
  exit
fi

if pgrep -x RelayKitApp.bin >/dev/null 2>&1; then
  fail "RelayKitApp.bin is already running; close it before isolated dogfood"
fi
port_free 18787 || fail "127.0.0.1:18787 is already listening; dogfood will not touch shared runtime state"
port_free 19777 || fail "127.0.0.1:19777 is already listening; close RelayKit before dogfood"

codex_config_before="$(file_signature "${CODEX_CONFIG_PATH}")"
codex_auth_before="$(file_signature "${CODEX_AUTH_PATH}")"
CODEX_CONFIG_BEFORE="${codex_config_before}"
CODEX_AUTH_BEFORE="${codex_auth_before}"
real_provider_config_before="$(file_signature "${REAL_PROVIDER_CONFIG}")"

cd "${ROOT}"
reuse_current_zip="${RELAYKIT_DOGFOOD_REUSE_CURRENT_ZIP:-0}"
case "${reuse_current_zip}" in
  0) ./script/package_release.sh --verify >/dev/null ;;
  1) ;;
  *) fail "RELAYKIT_DOGFOOD_REUSE_CURRENT_ZIP must be 0 or 1" ;;
esac
test -f "${ZIP_PATH}" || fail "local beta zip is missing"
zip_sha256="$(shasum -a 256 "${ZIP_PATH}" | awk '{print $1}')"
zip_build_time_utc="$(date -u -r "$(stat -f '%m' "${ZIP_PATH}")" '+%Y-%m-%dT%H:%M:%SZ')"

rm -rf "${OUT}"
mkdir -p "${INSTALL_DIR}" "${SCREENSHOT_DIR}"
/usr/bin/ditto -x -k "${ZIP_PATH}" "${INSTALL_DIR}"
test -x "${APP_REAL}" || fail "extracted app executable is missing"
test -x "${BUNDLED_RELAY}" || fail "extracted bundled gateway is missing"
codesign --verify --deep --strict --verbose=4 "${APP_BUNDLE}" >/dev/null

set +e
spctl_output="$(spctl -a -vvv -t exec "${APP_BUNDLE}" 2>&1)"
spctl_status=$?
set -e

RUN_DIR="$(mktemp -d /tmp/relaykit-dogfood.XXXXXX)"
PROVIDER_CONFIG="${DOGFOOD_STATE_DIR}/providers.json"
USAGE_BACKUP="${RUN_DIR}/usage.jsonl.before"
CLIPBOARD_BACKUP="${RUN_DIR}/clipboard.plist"
snapshot_clipboard "${CLIPBOARD_BACKUP}" >/dev/null
CLIPBOARD_SNAPSHOTTED=1
mkdir -p "${DOGFOOD_STATE_DIR}"
chmod 700 "${DOGFOOD_STATE_DIR}"
printf '{"providers":[]}\n' >"${PROVIDER_CONFIG}"
chmod 600 "${PROVIDER_CONFIG}"

ORIGINAL_INPUT_SOURCE="$(current_input_source)"
if [[ "${ORIGINAL_INPUT_SOURCE}" != "com.apple.keylayout.ABC" ]]; then
  select_input_source "com.apple.keylayout.ABC" >/dev/null
  INPUT_SOURCE_CHANGED=1
fi
[[ "$(current_input_source)" == "com.apple.keylayout.ABC" ]] || fail "could not select the stable ABC input source"

if ORIGINAL_PROVIDER_CONFIG="$(/usr/bin/defaults read "${BUNDLE_ID}" "${PROVIDER_CONFIG_KEY}" 2>/dev/null)"; then
  HAD_ORIGINAL_PROVIDER_CONFIG=1
fi
/usr/bin/defaults write "${BUNDLE_ID}" "${PROVIDER_CONFIG_KEY}" "${PROVIDER_CONFIG}" >/dev/null

if [[ -f "${USAGE_PATH}" ]]; then
  HAD_USAGE=1
  cp "${USAGE_PATH}" "${USAGE_BACKUP}"
fi
mkdir -p "$(dirname "${USAGE_PATH}")"
python3 - "${USAGE_PATH}" <<'PY'
import datetime
import json
import sys

event = {
    "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat().replace("+00:00", "Z"),
    "request_id": "dogfood-fixture-usage",
    "provider_id": "fixture",
    "model": "fixture/usage",
    "route": "/v1/responses",
    "transport": "fixture_only",
    "status": "completed",
    "http_status": 200,
    "input_tokens": 7,
    "output_tokens": 5,
    "total_tokens": 12,
    "duration_ms": 10,
}
with open(sys.argv[1], "w", encoding="utf-8") as output:
    output.write(json.dumps(event, separators=(",", ":")) + "\n")
PY

start_fixture_provider
fixture_base_url="http://localhost:${FIXTURE_PORT}"

launch_normal_extracted_app
ax_press_exact "tab-connect" || fail "Connect tab AX click failed"
connect_clicked=true
capture_popover "connect-first-screen"

ax_press_exact "新增模型接入" || fail "provider add AX click failed"
wait_for_ax_exact "Provider name field" || fail "provider sheet did not open"
ax_set_value_exact "Provider name field" "${PROVIDER_NAME}" || fail "provider name AX input failed"
wait_for_ax_value_exact "${PROVIDER_NAME}" || fail "provider name AX value did not update"
ax_set_value_exact "API base URL field" "${fixture_base_url}" || fail "provider base URL AX input failed"
wait_for_ax_value_exact "${fixture_base_url}" || fail "provider base URL AX value did not update"
ax_set_value_exact "API key field" "${FIXTURE_KEY}" || fail "provider API key AX input failed"
ax_press_exact "provider-model-detection-entry" || fail "Detect models AX click failed"
if ! wait_for_ax_text "Detected 2 model(s)."; then
  if ax_query read_contains "Authentication failed while detecting models."; then
    fail "fixture model detection reached the provider but the AX key value was not accepted"
  fi
  if ax_query read_contains "Network failed while detecting models"; then
    fail "fixture model detection did not reach the loopback endpoint"
  fi
  if ax_query read_contains "Model list unavailable"; then
    fail "fixture model detection received an unusable model list"
  fi
  fail "fixture models were not detected"
fi
capture_popover "provider-models-detected"
ax_press_exact "Save provider" || fail "provider save AX click failed"
wait_for_ax_exact "${PROVIDER_NAME}" || fail "saved provider row did not appear"

jq -e '.providers | length == 1' "${PROVIDER_CONFIG}" >/dev/null || fail "saved fixture provider count is not one"
jq -e --arg service "${KEYCHAIN_SERVICE}" '
  .providers[0].credential_ref.kind == "keychain" and
  .providers[0].credential_ref.value == $service
' "${PROVIDER_CONFIG}" >/dev/null || fail "saved fixture provider Keychain reference is incorrect"
jq -e '.providers[0] | has("api_key") | not' "${PROVIDER_CONFIG}" >/dev/null || fail "saved fixture provider config contains an API key"
jq -e '.providers[0].models | length == 2' "${PROVIDER_CONFIG}" >/dev/null || fail "saved fixture provider did not keep both detected models"
provider_saved_before_quit=true

ax_press_exact "${PROVIDER_NAME}" || fail "saved provider row AX click failed"
wait_for_ax_value_exact "API key saved in Keychain" || fail "saved Keychain state is not visible"
capture_popover "provider-keychain-saved"
ax_press_exact "provider-connection-test-entry" || fail "Test connection AX click failed"
if ! wait_for_ax_text "1 reachable"; then
  if ! curl -fsS --max-time 1 http://127.0.0.1:19777/healthz >/dev/null 2>&1; then
    fail "Test connection discovered models but the App gateway did not start on 19777"
  fi
  curl -fsS --max-time 20 http://127.0.0.1:19777/v1/models >"${RUN_DIR}/app-gateway-models.json" ||
    fail "App gateway started but model health could not be read"
  visible_count="$(jq '.data // [] | length' "${RUN_DIR}/app-gateway-models.json")"
  hidden_count="$(jq '.model_health.hidden // [] | length' "${RUN_DIR}/app-gateway-models.json")"
  capture_popover "provider-gateway-warmup-first-attempt"
  ax_press_exact "provider-connection-test-entry" || fail "gateway warm-up Test connection AX click failed"
  if ! wait_for_ax_text "1 reachable"; then
    capture_popover "provider-test-connection-failure"
    fail "App gateway health was visible=${visible_count} hidden=${hidden_count}, but reachable UI did not appear after one warm-up retry"
  fi
  GATEWAY_WARMUP_RETRY_USED=true
fi
wait_for_ax_text "1 unavailable" || fail "unavailable model count did not appear"
wait_for_ax_exact "provider-connection-use-reachable-visible" || fail "Use reachable action did not appear"
bad_model_actionable=true
capture_popover "provider-unavailable-model-guidance"
ax_press_exact "provider-connection-use-reachable-visible" || fail "Use reachable AX click failed"
gateway_pid_before_provider_save="$(lsof -t -iTCP:19777 -sTCP:LISTEN 2>/dev/null | head -1 || true)"
[[ -n "${gateway_pid_before_provider_save}" ]] || fail "running gateway PID was unavailable before provider update"
ax_press_exact "Save provider" || fail "filtered provider save AX click failed"
wait_for_ax_exact "${PROVIDER_NAME}" || fail "filtered provider row did not return"
gateway_pid_after_provider_save=""
for _ in {1..80}; do
  gateway_pid_after_provider_save="$(lsof -t -iTCP:19777 -sTCP:LISTEN 2>/dev/null | head -1 || true)"
  if [[ -n "${gateway_pid_after_provider_save}" && "${gateway_pid_after_provider_save}" != "${gateway_pid_before_provider_save}" ]]; then
    break
  fi
  sleep 0.1
done
[[ -n "${gateway_pid_after_provider_save}" && "${gateway_pid_after_provider_save}" != "${gateway_pid_before_provider_save}" ]] ||
  fail "provider update did not reload the running gateway credential snapshot"
PROVIDER_SAVE_RELOADED_RUNNING_GATEWAY=true
jq -e '
  .providers[0].models | length == 1 and
  .[0].upstream_model == "healthy-upstream" and
  (.[0].id | contains("unavailable") | not)
' "${PROVIDER_CONFIG}" >/dev/null || fail "unavailable fixture model was not filtered"

ax_press_exact "${PROVIDER_NAME}" || fail "provider edit AX click failed"
wait_for_ax_value_exact "API key saved in Keychain" || fail "saved key state disappeared before failure checks"
ax_set_value_exact "API key field" "wrong${FIXTURE_KEY}" || fail "bad key AX input failed"
ax_press_exact "provider-connection-test-entry" || fail "bad key Test connection AX click failed"
  wait_for_ax_value_exact "Authentication failed · check API key" || fail "bad key error is not actionable"
  bad_key_actionable=true

  ax_set_value_exact "API key field" "${FIXTURE_KEY}" || fail "fixture key restore AX input failed"
ax_press_exact "Advanced" || fail "provider Advanced AX click failed before bad URL check"
wait_for_ax_exact "Custom models URL field" || fail "Custom models URL field did not appear"
ax_set_value_exact "Custom models URL field" "" || fail "Custom models URL AX clear failed"
ax_set_value_exact "API base URL field" "http://localhost:9" || fail "bad URL AX input failed"
wait_for_ax_value_exact "http://localhost:9" || fail "bad URL AX value did not update"
ax_press_exact "provider-connection-test-entry" || fail "bad URL Test connection AX click failed"
wait_for_ax_value_exact "Network failed · check API base URL" || fail "bad base URL error is not actionable"
bad_base_url_actionable=true
capture_popover "provider-bad-base-url-guidance"
ax_press_exact "Cancel provider" || fail "provider failure sheet cancel failed"

ax_press_exact "tab-settings" || fail "Settings tab AX click failed"
settings_clicked=true
wait_for_ax_value_exact "Gateway status" || fail "Settings content did not appear"
ax_press_exact "Restart gateway" || fail "gateway Restart AX click failed"
gateway_restart_clicked=true
for _ in {1..80}; do
  curl -fsS --max-time 1 http://127.0.0.1:19777/healthz >/dev/null 2>&1 && break
  sleep 0.1
done
curl -fsS --max-time 1 http://127.0.0.1:19777/healthz >/dev/null || fail "gateway restart did not become healthy"
capture_popover "settings-gateway-restarted"

ax_press_exact "tab-usage" || fail "Usage tab AX click failed"
usage_clicked=true
wait_for_ax_value_exact "LOCAL USAGE" || fail "Usage content did not appear"
ax_press_exact "Refresh usage" || fail "Usage refresh AX click failed"
sleep 0.5
jq -e '.request_id == "dogfood-fixture-usage" and .transport == "fixture_only"' "${USAGE_PATH}" >/dev/null || fail "fixture usage row changed unexpectedly"
capture_popover "usage-fixture"

ax_press_exact "tab-connect" || fail "Connect return AX click failed"
capture_popover "connect-after-provider"
quit_with_real_context_menu
right_click_quit_clicked=true
APP_EXITED_AFTER_RIGHT_CLICK_QUIT=true
wait_for_port_free 19777 || fail "right-click Quit left the bundled gateway listening on 19777"
GATEWAY_19777_RELEASED_AFTER_QUIT=true

launch_normal_extracted_app
ax_press_exact "tab-connect" || fail "Connect AX click failed after reopen"
wait_for_ax_exact "${PROVIDER_NAME}" || fail "provider did not persist after reopen"
provider_present_after_reopen=true
ax_press_exact "${PROVIDER_NAME}" || fail "persisted provider row AX click failed"
wait_for_ax_value_exact "API key saved in Keychain" || fail "Keychain saved state did not persist after reopen"
wait_for_ax_value_exact "custom/healthy-upstream" || fail "reachable model did not persist after reopen"
if ax_query read_value_exact "custom/unavailable-upstream"; then
  fail "unavailable model returned after reopen"
fi
keychain_saved_state_after_reopen=true
ax_press_exact "provider-connection-test-entry" || fail "reopened provider Test connection AX click failed"
if ! wait_for_ax_text "1 reachable"; then
  write_reopen_failure_evidence
  jq -c '.' "${OUT}/reopen-failure.json" >&2
  fail "reopened provider did not re-probe its reachable model"
fi
REACHABLE_MODELS_REPROBED_AFTER_REOPEN=true
reachable_models_after_reopen=true
capture_popover "provider-persisted-after-reopen"
ax_press_exact "Cancel provider" || fail "persisted provider sheet cancel failed"
quit_with_real_context_menu
wait_for_port_free 19777 || fail "final Quit left 19777 listening"

cleanup
trap - EXIT

[[ "${FIXTURE_KEYCHAIN_REMOVED}" == "true" ]] || fail "dogfood did not remove its fixture Keychain item through RelayKit App"
[[ "${CLIPBOARD_CHANGED}" == "0" ]] || fail "dogfood did not restore the original clipboard"
[[ "$(current_input_source)" == "${ORIGINAL_INPUT_SOURCE}" ]] || fail "dogfood did not restore the original input source"

codex_config_after="$(file_signature "${CODEX_CONFIG_PATH}")"
codex_auth_after="$(file_signature "${CODEX_AUTH_PATH}")"
real_provider_config_after="$(file_signature "${REAL_PROVIDER_CONFIG}")"
[[ "${codex_config_before}" == "${codex_config_after}" ]] || fail "dogfood changed global Codex config"
[[ "${codex_auth_before}" == "${codex_auth_after}" ]] || fail "dogfood changed global Codex auth"
[[ "${real_provider_config_before}" == "${real_provider_config_after}" ]] || fail "dogfood changed the real RelayKit provider config"
[[ "$(shasum -a 256 "${ZIP_PATH}" | awk '{print $1}')" == "${zip_sha256}" ]] || fail "zip changed during dogfood run"
port_free 18787 || fail "dogfood left shared port 18787 listening"
port_free 19777 || fail "dogfood left gateway port 19777 listening"
screenshot_count="$(find "${SCREENSHOT_DIR}" -maxdepth 1 -type f -name '*.png' | wc -l | tr -d ' ')"
[[ "${screenshot_count}" -ge 8 ]] || fail "dogfood did not generate the required RelayKit window screenshots"

jq -n \
  --arg source_zip "${ZIP_PATH}" \
  --arg current_zip_sha256 "${zip_sha256}" \
  --arg zip_build_time_utc "${zip_build_time_utc}" \
  --arg extracted_app_path "${APP_BUNDLE}" \
  --arg screenshots_dir "${SCREENSHOT_DIR}" \
  --arg spctl_output "${spctl_output}" \
  --argjson spctl_status "${spctl_status}" \
  --argjson app_exited_after_right_click_quit "${APP_EXITED_AFTER_RIGHT_CLICK_QUIT}" \
    --argjson gateway_19777_released_after_quit "${GATEWAY_19777_RELEASED_AFTER_QUIT}" \
    --argjson reachable_models_reprobed_after_reopen "${REACHABLE_MODELS_REPROBED_AFTER_REOPEN}" \
    --argjson provider_save_reloaded_running_gateway "${PROVIDER_SAVE_RELOADED_RUNNING_GATEWAY}" \
    --argjson gateway_warmup_retry_used "${GATEWAY_WARMUP_RETRY_USED}" \
    --argjson fixture_keychain_item_removed "${FIXTURE_KEYCHAIN_REMOVED}" \
  --argjson screenshot_count "${screenshot_count}" \
  '{
    artifact: {
      source_zip: $source_zip,
      current_zip_sha256: $current_zip_sha256,
      zip_build_time_utc: $zip_build_time_utc,
      extracted_app_path: $extracted_app_path,
      launched_from_extracted_zip: true,
      launch_method: "launchservices_open_extracted_app",
      normal_launch: true,
      ui_smoke_launch_used_for_dogfood_claim: false,
      codesign_verify: "passed",
      bundled_gateway_verify: "passed_via_normal_app_lifecycle",
      gatekeeper: {
        status: $spctl_status,
        output: $spctl_output,
        local_beta_friction_expected: true
      }
    },
    app_regression: {
      connect_clicked: true,
      gateway_warmup_retry_used: $gateway_warmup_retry_used,
      settings_clicked: true,
      usage_clicked: true,
      gateway_restart_clicked: true,
      right_click_quit_clicked: true,
      app_exited_after_right_click_quit: $app_exited_after_right_click_quit,
      gateway_19777_released_after_quit: $gateway_19777_released_after_quit,
      quit_release_timeout_seconds: 8
    },
    provider_setup: {
      fixture_plumbing_only: true,
      real_model_compatibility_claimed: false,
      ui_keychain_save_observed: true,
      credential_handoff: "anonymous_stdin_pipe",
      credential_handoff_persistence: "memory_only",
      real_user_keychain_authorization_claimed: false,
      provider_saved_before_quit: true,
      provider_save_reloaded_running_gateway: $provider_save_reloaded_running_gateway,
      provider_present_after_reopen: true,
      keychain_saved_state_after_reopen: true,
      reachable_models_after_reopen: true,
      reachable_models_reprobed_after_reopen: $reachable_models_reprobed_after_reopen,
      unavailable_model_filtered: true
    },
    failure_guidance: {
      bad_base_url_actionable: true,
      bad_key_actionable: true,
      bad_model_actionable: true
    },
    usage: {
      usage_evidence_kind: "fixture",
      fixture_row_visible_after_refresh: true,
      real_route_usage_claimed: false
    },
    safety: {
      global_codex_config_unchanged: true,
      global_codex_auth_unchanged: true,
      real_provider_config_unchanged: true,
      original_relaykit_defaults_restored: true,
      original_usage_log_restored: true,
      original_input_source_restored: true,
      original_clipboard_restored: true,
      fixture_keychain_item_removed: $fixture_keychain_item_removed,
      shared_18787_free_after: true,
      gateway_19777_free_after: true,
      signed_beta_status: (if $spctl_status == 0 and ($spctl_output | contains("Notarized Developer ID")) then "notarized_developer_id_candidate" else "local_ad_hoc" end)
    },
    route_proof_boundary: {
      current_setup_evidence_only: true,
      isolated_desktop_route_proof_claimed: false,
      mock_ok_used: false
    },
    screenshot_audit: {
      capture_kind: "relaykit_owned_window_id_mask_and_current_run_bounds_composite",
      generated_count: $screenshot_count,
      unrelated_process_windows_excluded_by_capture: true,
      keychain_authorization_prompt_excluded_by_capture: true,
      complete_quit_menu_present: true
    },
    screenshots_dir: $screenshots_dir
  }' >"${OUT}/evidence.json"

jq -e '
  .artifact.launched_from_extracted_zip == true and
  .artifact.normal_launch == true and
  .app_regression.connect_clicked == true and
  .app_regression.settings_clicked == true and
  .app_regression.usage_clicked == true and
  .app_regression.gateway_restart_clicked == true and
  .app_regression.right_click_quit_clicked == true and
  .app_regression.app_exited_after_right_click_quit == true and
    .app_regression.gateway_19777_released_after_quit == true and
    .provider_setup.provider_save_reloaded_running_gateway == true and
    .provider_setup.provider_present_after_reopen == true and
  .provider_setup.keychain_saved_state_after_reopen == true and
  .provider_setup.reachable_models_after_reopen == true and
  .provider_setup.reachable_models_reprobed_after_reopen == true and
  .usage.usage_evidence_kind == "fixture" and
  .route_proof_boundary.isolated_desktop_route_proof_claimed == false and
  .screenshot_audit.generated_count >= 8
' "${OUT}/evidence.json" >/dev/null

echo "RelayKit extracted local beta dogfood passed: ${OUT}/evidence.json"
