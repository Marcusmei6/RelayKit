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
press_descendant_body="$(sed -n '/^func pressDescendant(_ element: AXUIElement/,/^}/p' "${SCRIPT}")"
if grep -Fq 'AXUIElementCopyActionNames' <<<"${press_descendant_body}" ||
   grep -Fq 'actionsRef as? [String]' <<<"${press_descendant_body}"; then
  fail "AX button descendants must not enumerate or cast action names before pressing"
fi
grep -Fq 'AXUIElementPerformAction(target, kAXPressAction as CFString) == .success' "${SCRIPT}" ||
  fail "the unique AX button target must perform the press action directly"
grep -Fq 'let attempts = 30' "${SCRIPT}" ||
  fail "AX press must use a bounded readiness poll"
grep -Fq 'if exactMatches.count > 1 { exit(3) }' "${SCRIPT}" ||
  fail "AX press must fail closed when an exact identity is not unique"
grep -Fq 'if actionable.count > 1 { exit(3) }' "${SCRIPT}" ||
  fail "AX press must fail closed when an exact wrapper contains multiple actionable controls"
grep -Fq 'usleep(200_000)' "${SCRIPT}" ||
  fail "AX press readiness polling must remain bounded and explicit"
grep -Fq 'kAXRadioButtonRole' "${SCRIPT}" ||
  fail "segmented controls must press an exact AXRadioButton"
grep -Fq 'func focusTextFieldDescendant(_ element: AXUIElement' "${SCRIPT}" ||
  fail "AX focus must descend to a real text field"
grep -Fq 'press_ax_label "official-provider-row"' "${SCRIPT}" ||
  fail "Official provider row must use its stable exact AX identifier"
if grep -Fq 'press_ax_label "OpenAI Official / Codex Official"' "${SCRIPT}"; then
  fail "Official provider row must not use visible text as its AX identity"
fi
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
grep -Fq 'RELAYKIT_REUSE_FINAL_BUNDLE' "${SCRIPT}" ||
  fail "menu smoke must support explicit final-bundle reuse"
grep -Fq '/usr/bin/codesign --verify --deep --strict "${APP_BUNDLE}"' "${SCRIPT}" ||
  fail "reused final bundle must be verified before launch"
grep -Fq '.connect.enabled_gateway_provider_protocols == ["anthropic_messages","openai_chat","openai_responses"]' "${SCRIPT}" ||
  fail "menu smoke must accept the RC1 native Responses provider protocol"
grep -Fq '.connect.planned_provider_protocols == []' "${SCRIPT}" ||
  fail "menu smoke must not describe native Responses as planned"
capture_body="$(sed -n '/^capture() {/,/^}/p' "${SCRIPT}")"
cleanup_line="$(grep -n 'cleanup_smoke_keychain_credential' <<<"${capture_body}" | head -1 | cut -d: -f1 || true)"
open_line="$(grep -n '/usr/bin/open -n' <<<"${capture_body}" | head -1 | cut -d: -f1 || true)"
[[ -n "${cleanup_line}" && -n "${open_line}" && "${cleanup_line}" -lt "${open_line}" ]] ||
  fail "each capture must remove the old smoke item before the App creates its own Keychain item"

make_valid_desktop_acceptance_evidence() {
  local path="$1"
  mkdir -p "$(dirname "${path}")"
  cat >"${path}" <<'JSON'
{
  "full_merged_gateway_models": true,
  "isolated_app_server_lists_official_and_provider": true,
  "official_request_hit_fake_official": true,
  "provider_request_hit_fake_provider": true,
  "unknown_model_rejected": true,
  "official_auth_not_in_provider_config_or_logs_or_evidence": true,
  "global_config_signature_before": "missing",
  "global_config_signature_after": "missing",
  "global_auth_signature_before": "missing",
  "global_auth_signature_after": "missing",
  "global_config_unchanged": true,
  "global_auth_unchanged": true,
  "gateway_port_released": true,
  "shared_18787_free_after": true,
  "shared_19777_free_after": true,
  "acceptance_scope": "public_safe_headless",
  "gateway_health_ok": true,
  "gateway_models_include_demo": true,
  "generated_config_model": "gpt-5.5",
  "app_server_demo_models": [
    {
      "displayName": "Demo Public Model",
      "hidden": false,
      "model": "demo/public-model"
    }
  ],
  "desktop_gui_picker_proof": "not_attempted",
  "desktop_gui_route_proof": "not_attempted",
  "proof_source": "scripts/full-merged-catalog-proof.sh"
}
JSON
}

bundle_hash() {
  local bundle="$1"
  find "${bundle}" -type f -print0 | sort -z | xargs -0 shasum -a 256 | shasum -a 256 | awk '{print $1}'
}

run_final_bundle_evidence_contract() (
  RELAYKIT_MENU_BAR_E2E_SOURCE_ONLY=1 source "${SCRIPT}"
  local case_root app_bundle source destination bundle_before existing_before actual_destination expected_destination
  case_root="$(mktemp -d /tmp/relaykit-menu-evidence-test.XXXXXX)"
  trap 'rm -rf "${case_root}"' EXIT
  app_bundle="${case_root}/final/RelayKitApp.app"
  source="${case_root}/source/evidence.json"
  destination="${case_root}/final/codex-desktop-acceptance/evidence.json"
  mkdir -p "${app_bundle}/Contents/MacOS"
  printf 'frozen bundle fixture\n' >"${app_bundle}/Contents/MacOS/RelayKitApp.bin"
  make_valid_desktop_acceptance_evidence "${source}"
  bundle_before="$(bundle_hash "${app_bundle}")"

  APP_BUNDLE="${app_bundle}"
  DESKTOP_ACCEPTANCE_SOURCE="${source}"
  prepare_final_bundle_desktop_acceptance_evidence
  actual_destination="$(cd "$(dirname "${DESKTOP_ACCEPTANCE_DESTINATION}")" && pwd -P)/$(basename "${DESKTOP_ACCEPTANCE_DESTINATION}")"
  expected_destination="$(cd "$(dirname "${destination}")" && pwd -P)/$(basename "${destination}")"
  [[ "${actual_destination}" == "${expected_destination}" ]] ||
    fail "reused App parent must determine the desktop acceptance sibling path"
  cmp -s "${source}" "${destination}" ||
    fail "redacted desktop acceptance evidence was not placed beside the reused App"
  [[ "$(bundle_hash "${app_bundle}")" == "${bundle_before}" ]] ||
    fail "desktop acceptance placement changed the reused App bundle"
  cleanup_final_bundle_desktop_acceptance_evidence
  [[ ! -e "${destination}" && ! -d "$(dirname "${destination}")" ]] ||
    fail "new sibling desktop acceptance evidence was not removed by cleanup"
  [[ "$(bundle_hash "${app_bundle}")" == "${bundle_before}" ]] ||
    fail "desktop acceptance cleanup changed the reused App bundle"

  mkdir -p "$(dirname "${destination}")"
  printf 'preexisting destination bytes\n' >"${destination}"
  existing_before="$(shasum -a 256 "${destination}" | awk '{print $1}')"
  prepare_final_bundle_desktop_acceptance_evidence
  cmp -s "${source}" "${destination}" ||
    fail "redacted evidence did not replace the sibling destination during the smoke"
  cleanup_final_bundle_desktop_acceptance_evidence
  [[ "$(shasum -a 256 "${destination}" | awk '{print $1}')" == "${existing_before}" ]] ||
    fail "preexisting sibling evidence was not restored byte-for-byte"

  DESKTOP_ACCEPTANCE_SOURCE="${case_root}/missing/evidence.json"
  rm -rf "$(dirname "${destination}")"
  if prepare_final_bundle_desktop_acceptance_evidence; then
    fail "missing desktop acceptance source must fail closed"
  fi
  [[ ! -e "${destination}" ]] ||
    fail "missing source failure must occur before destination placement"

  DESKTOP_ACCEPTANCE_SOURCE="${case_root}/invalid/evidence.json"
  mkdir -p "$(dirname "${DESKTOP_ACCEPTANCE_SOURCE}")"
  printf '{"acceptance_scope":"invalid"}\n' >"${DESKTOP_ACCEPTANCE_SOURCE}"
  if prepare_final_bundle_desktop_acceptance_evidence; then
    fail "invalid desktop acceptance source must fail closed"
  fi
  [[ ! -e "${destination}" ]] ||
    fail "invalid source failure must occur before destination placement"
  [[ "$(bundle_hash "${app_bundle}")" == "${bundle_before}" ]] ||
    fail "failed evidence preparation changed the reused App bundle"
)

run_final_bundle_evidence_contract

echo "Menu bar smoke contract tests passed"
