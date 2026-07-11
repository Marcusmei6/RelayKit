#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${ROOT}/scripts/menu-bar-e2e-smoke.sh"
APP_VIEW_SOURCE="${ROOT}/app/Sources/RelayKitApp/Views/ContentView.swift"

fail() {
  echo "menu bar smoke contract test failed: $*" >&2
  exit 1
}

bash -n "${SCRIPT}"

if grep -Fq 'kAXParentAttribute' "${SCRIPT}"; then
  fail "AX actions must not climb to unrelated parent controls"
fi
if grep -Fq 'haystack.contains(needle)' "${SCRIPT}"; then
  fail "AX actions must not use substring identity matching"
fi
grep -Fq 'func exactIdentity(_ element: AXUIElement) -> Bool' "${SCRIPT}" ||
  fail "AX helpers must define exact title/description/identifier matching"
grep -Fq 'func pressDescendant(_ element: AXUIElement' "${SCRIPT}" ||
  fail "AX press must descend to a real button"
grep -Fq 'kAXRadioButtonRole' "${SCRIPT}" ||
  fail "segmented controls must press an exact AXRadioButton"
grep -Fq 'func focusTextFieldDescendant(_ element: AXUIElement' "${SCRIPT}" ||
  fail "AX focus must descend to a real text field"
grep -Fq 'press_ax_label "OpenAI Official / Codex Official"' "${SCRIPT}" ||
  fail "Official provider row must use its complete exact identity"
grep -Fq '.accessibilityIdentifier("settings-developer-toggle")' "${APP_VIEW_SOURCE}" ||
  fail "Developer disclosure needs a stable exact AX identifier"
grep -Fq '.smokeRecordOnly("settings-developer-group", recorder: smokeSectionRecorder)' "${APP_VIEW_SOURCE}" ||
  fail "Developer container markers must not override the disclosure identifier"
grep -Fq 'press_ax_label "settings-developer-toggle"' "${SCRIPT}" ||
  fail "Developer disclosure must be pressed by exact identifier"
if grep -Fq 'press_ax_label "保存"' "${SCRIPT}"; then
  fail "provider save must use the stable Save provider AX label"
fi
grep -Fq 'press_ax_label "Save provider"' "${SCRIPT}" ||
  fail "provider save must use its exact stable AX label"
capture_body="$(sed -n '/^capture() {/,/^}/p' "${SCRIPT}")"
cleanup_line="$(grep -n 'cleanup_smoke_keychain_credential' <<<"${capture_body}" | head -1 | cut -d: -f1 || true)"
open_line="$(grep -n '/usr/bin/open -n' <<<"${capture_body}" | head -1 | cut -d: -f1 || true)"
[[ -n "${cleanup_line}" && -n "${open_line}" && "${cleanup_line}" -lt "${open_line}" ]] ||
  fail "each capture must remove the old smoke item before the App creates its own Keychain item"

echo "Menu bar smoke contract tests passed"
