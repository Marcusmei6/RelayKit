#!/usr/bin/env bash
set -Eeu -o pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_APP_BUNDLE="${RELAYKIT_APP_BUNDLE:-${ROOT}/dist/RelayKitApp.app}"
APP_BUNDLE=""
APP_REAL=""
BUNDLED_RELAY=""
RUNTIME_ROOT=""
OUT=""
CATALOG_PORT=""
CATALOG_URL=""
RUNTIME_PORT=""
PID=""
FAKE_CATALOG_PID=""
PYTHON_RUNTIME_EXECUTABLE=""
SMOKE_CONFIG_DIR=""
REAL_QUIT_MENU_EVIDENCE=""
REUSE_FINAL_BUNDLE="${RELAYKIT_REUSE_FINAL_BUNDLE:-0}"
OWNED_PIDS=()
OWNED_EXECUTABLES=()
CURRENT_STAGE="bootstrap"
PRIMARY_RC=0
PRIMARY_STAGE="bootstrap"
FAILURE_REPORTED=0

set_stage() {
  local stage="$1"
  [[ "${stage}" =~ ^[a-z0-9][a-z0-9._-]*$ ]] || {
    echo "invalid fixed menu smoke stage" >&2
    return 2
  }
  CURRENT_STAGE="${stage}"
}

set_capture_evidence_stage() {
  local capture_name="$1"
  local phase="$2"
  local prefix
  case "${capture_name}" in
    connect) prefix="capture.connect" ;;
    official-sheet) prefix="capture.official-sheet" ;;
    real-demo) prefix="capture.real-demo" ;;
    provider-click-flow) prefix="capture.provider-click-flow" ;;
    provider-test-failure) prefix="capture.provider-test-failure" ;;
    detail) prefix="capture.detail" ;;
    detail-advanced-expanded) prefix="capture.detail-advanced-expanded" ;;
    detail-advanced-collapsed) prefix="capture.detail-advanced-collapsed" ;;
    import) prefix="capture.import" ;;
    usage) prefix="capture.usage" ;;
    usage-auto-refresh) prefix="capture.usage-auto-refresh" ;;
    usage-large) prefix="capture.usage-large" ;;
    usage-1m) prefix="capture.usage-1m" ;;
    usage-1y) prefix="capture.usage-1y" ;;
    usage-empty) prefix="capture.usage-empty" ;;
    settings) prefix="capture.settings" ;;
    settings-developer-expanded) prefix="capture.settings-developer-expanded" ;;
    settings-light) prefix="capture.settings-light" ;;
    usage-light) prefix="capture.usage-light" ;;
    official-light) prefix="capture.official-light" ;;
    provider-light) prefix="capture.provider-light" ;;
    settings-dark) prefix="capture.settings-dark" ;;
    usage-dark) prefix="capture.usage-dark" ;;
    official-dark) prefix="capture.official-dark" ;;
    provider-dark) prefix="capture.provider-dark" ;;
    provider) prefix="capture.provider" ;;
    *) return 2 ;;
  esac
  case "${phase}" in
    generic-jq) set_stage "${prefix}.generic-jq" ;;
    specific-jq) set_stage "${prefix}.specific-jq" ;;
    *) return 2 ;;
  esac
}

record_primary_failure() {
  local rc="$1"
  if ((PRIMARY_RC == 0)); then
    PRIMARY_RC="${rc}"
    PRIMARY_STAGE="${CURRENT_STAGE}"
  fi
}

record_err_trap() {
  local rc="$?"
  record_primary_failure "${rc}"
  return "${rc}"
}

desktop_acceptance_state_is_valid() {
  local evidence="$1"
  jq -e '
    . as $doc |
    ($doc.connect.desktop_acceptance_available | type == "boolean") and
    (
      if $doc.connect.desktop_acceptance_available then
        ($doc.connect.desktop_acceptance_global_files | type == "string") and
        ($doc.connect.desktop_acceptance_catalog | test("^catalog ok: [0-9]+ models$")) and
        ($doc.connect.desktop_acceptance_picker_data | test("^picker data has [0-9]+ routed models$")) and
        ($doc.connect.desktop_acceptance_route_proof | test("blocked|routed model|routed_model|ready|usage|not run|succeeded|missing")) and
        ($doc.connect.desktop_acceptance_manual_available | type == "boolean") and
        ($doc.connect.desktop_acceptance_manual_status | type == "string") and
        ($doc.connect.desktop_acceptance_manual_route_status | type == "string")
      else
        $doc.connect.desktop_acceptance_catalog == "not run" and
        $doc.connect.desktop_acceptance_picker_data == "not run" and
        $doc.connect.desktop_acceptance_route_proof == "not run" and
        $doc.connect.desktop_acceptance_global_files == "not run" and
        $doc.connect.desktop_acceptance_manual_available == false and
        $doc.connect.desktop_acceptance_manual_status == "not run" and
        $doc.connect.desktop_acceptance_manual_route_status == "not run"
      end
    ) and
    $doc.connect.desktop_acceptance_manual_entry_visible == false and
    ($doc.connect.desktop_acceptance_proof_root | type == "string") and
    ($doc.connect.desktop_acceptance_proof_root | endswith("Library/Application Support/RelayKit/DesktopProof")) and
    ($doc.connect.desktop_acceptance_start_command | type == "string") and
    ($doc.connect.desktop_acceptance_start_command | contains("./scripts/codex-desktop-manual-proof.sh"))
  ' "${evidence}" >/dev/null
}

canonical_executable_path() {
  local path="$1"
  local directory
  directory="$(cd "$(dirname "${path}")" 2>/dev/null && pwd -P)" || return 1
  printf '%s/%s\n' "${directory}" "$(basename "${path}")"
}

process_executable_path() {
  local pid="$1"
  [[ "${pid}" =~ ^[0-9]+$ ]] || return 1
  python3 - "${pid}" <<'PY'
import ctypes
import os
import sys

try:
    pid = int(sys.argv[1])
except (IndexError, ValueError):
    raise SystemExit(1)
buffer = ctypes.create_string_buffer(4096)
libproc = ctypes.CDLL("/usr/lib/libproc.dylib")
length = libproc.proc_pidpath(pid, buffer, len(buffer))
if length <= 0:
    raise SystemExit(1)
path = os.path.realpath(os.fsdecode(buffer.value))
if not os.path.isabs(path):
    raise SystemExit(1)
print(path)
PY
}

python_runtime_executable() {
  python3 - <<'PY'
import ctypes
import os

buffer = ctypes.create_string_buffer(4096)
libproc = ctypes.CDLL("/usr/lib/libproc.dylib")
length = libproc.proc_pidpath(os.getpid(), buffer, len(buffer))
if length <= 0:
    raise SystemExit(1)
print(os.path.realpath(os.fsdecode(buffer.value)))
PY
}

process_executable_matches() {
  local pid="$1"
  local expected="$2"
  local actual expected_canonical
  actual="$(process_executable_path "${pid}")" || return 1
  expected_canonical="$(canonical_executable_path "${expected}")" || return 1
  [[ "${actual}" == "${expected_canonical}" ]]
}

wait_for_process_executable_match() {
  local pid="$1"
  local expected="$2"
  local attempt
  for attempt in {1..40}; do
    if process_executable_matches "${pid}" "${expected}"; then
      return 0
    fi
    kill -0 "${pid}" 2>/dev/null || return 1
    sleep 0.05
  done
  return 1
}

register_owned_pid() {
  local pid="$1"
  local executable="$2"
  process_executable_matches "${pid}" "${executable}" || {
    echo "refusing to register PID ${pid}: executable identity mismatch" >&2
    return 1
  }
  OWNED_PIDS+=("${pid}")
  OWNED_EXECUTABLES+=("$(canonical_executable_path "${executable}")")
}

pid_is_owned_root() {
  local candidate="$1"
  local index
  for index in "${!OWNED_PIDS[@]}"; do
    if [[ "${OWNED_PIDS[${index}]}" == "${candidate}" ]] &&
       process_executable_matches "${candidate}" "${OWNED_EXECUTABLES[${index}]}"; then
      return 0
    fi
  done
  return 1
}

wait_for_exact_owned_pid_exit() {
  local pid="$1"
  local attempt
  for attempt in {1..40}; do
    if ! kill -0 "${pid}" 2>/dev/null; then
      wait "${pid}" >/dev/null 2>&1 || true
      return 0
    fi
    sleep 0.05
  done
  return 1
}

terminate_exact_owned_pid() {
  local pid="$1"
  local expected="$2"
  if ! kill -0 "${pid}" 2>/dev/null; then
    wait "${pid}" >/dev/null 2>&1 || true
    return 0
  fi
  process_executable_matches "${pid}" "${expected}" || return 1
  if ! kill -TERM "${pid}" >/dev/null 2>&1; then
    wait_for_exact_owned_pid_exit "${pid}" && return 0
    return 1
  fi
  wait_for_exact_owned_pid_exit "${pid}" && return 0
  process_executable_matches "${pid}" "${expected}" || return 1
  if ! kill -KILL "${pid}" >/dev/null 2>&1; then
    wait_for_exact_owned_pid_exit "${pid}" && return 0
    return 1
  fi
  wait_for_exact_owned_pid_exit "${pid}"
}

cleanup_owned_processes() {
  local candidate index rc=0
  for index in ${OWNED_PIDS[@]+"${!OWNED_PIDS[@]}"}; do
    candidate="${OWNED_PIDS[${index}]}"
    terminate_exact_owned_pid "${candidate}" "${OWNED_EXECUTABLES[${index}]}" || rc=1
  done
  OWNED_PIDS=()
  OWNED_EXECUTABLES=()
  return "${rc}"
}

runtime_root_is_guarded() {
  case "${RUNTIME_ROOT}" in
    /tmp/relaykit-menu-smoke.*|/private/tmp/relaykit-menu-smoke.*) return 0 ;;
    *) return 1 ;;
  esac
}

cleanup_runtime_root() {
  [[ -n "${RUNTIME_ROOT}" ]] || return 0
  runtime_root_is_guarded || {
    echo "refusing unsafe menu-smoke cleanup root: ${RUNTIME_ROOT}" >&2
    return 1
  }
  rm -rf -- "${RUNTIME_ROOT}"
  RUNTIME_ROOT=""
}

select_isolated_port() {
  python3 - <<'PY'
import socket

protected = {18787, 19777}
for _ in range(32):
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as listener:
        listener.bind(("127.0.0.1", 0))
        port = listener.getsockname()[1]
    if port not in protected:
        print(port)
        raise SystemExit(0)
raise SystemExit(1)
PY
}

cleanup() {
  cleanup_owned_processes
  PID=""
  FAKE_CATALOG_PID=""
}

cleanup_current_app() {
  local rc=0
  if [[ -n "${PID}" ]]; then
    terminate_exact_owned_pid "${PID}" "${APP_REAL}" || rc=1
  fi
  PID=""
  return "${rc}"
}

cleanup_isolated_preferences() {
  return 0
}

cleanup_desktop_acceptance_fixture() {
  return 0
}

cleanup_smoke_config() {
  [[ -n "${SMOKE_CONFIG_DIR}" ]] && rm -rf "${SMOKE_CONFIG_DIR}" >/dev/null 2>&1 || true
}

cleanup_fake_catalog() {
  cleanup_owned_processes
}

run_cleanup_component() {
  local stage="$1"
  local function_name="$2"
  local rc
  set_stage "${stage}"
  "${function_name}"
  rc="$?"
  if ((rc != 0)); then
    record_primary_failure "${rc}"
  fi
  return 0
}

finalize_menu_smoke() {
  local original_rc="$?"
  local final_rc
  trap - ERR EXIT
  set +e
  if ((original_rc != 0)); then
    record_primary_failure "${original_rc}"
  fi
  set_stage cleanup.defaults
  run_cleanup_component cleanup.defaults cleanup_isolated_preferences
  set_stage cleanup.processes
  run_cleanup_component cleanup.processes cleanup
  set_stage cleanup.acceptance
  run_cleanup_component cleanup.acceptance cleanup_desktop_acceptance_fixture
  set_stage cleanup.config
  run_cleanup_component cleanup.config cleanup_smoke_config
  set_stage cleanup.root
  run_cleanup_component cleanup.root cleanup_runtime_root
  final_rc="${PRIMARY_RC}"
  if ((final_rc != 0 && FAILURE_REPORTED == 0)); then
    printf 'RelayKit menu smoke failed: stage=%s rc=%s\n' "${PRIMARY_STAGE}" "${final_rc}" >&2
    FAILURE_REPORTED=1
  fi
  exit "${final_rc}"
}

trap 'record_err_trap' ERR
trap 'finalize_menu_smoke' EXIT

if [[ "${RELAYKIT_MENU_BAR_E2E_OBSERVABILITY_TEST:-0}" == "1" ]]; then
  set_stage test.forced-failure
  false
fi

visual_flow_is_valid() {
  case "$1" in
    connect|official-sheet|official-light|official-dark|real-demo|provider-click-flow|provider-light|provider-dark|provider-test-failure|detail|detail-advanced-expanded|detail-advanced-collapsed|import|usage|usage-auto-refresh|usage-large|usage-1m|usage-1y|usage-empty|settings|settings-developer-expanded|settings-light|usage-light|settings-dark|usage-dark|provider|real-quit|outside-click) return 0 ;;
    *) return 2 ;;
  esac
}

visual_mode_is_valid() {
  case "$1" in
    self-test|probe-window|capture|click-text|outside|type-text) return 0 ;;
    *) return 2 ;;
  esac
}

window_equivalence_diagnostic_target_is_valid() {
  case "$1" in
    ""|outside-click|first-ambiguity|first-ambiguity-private-visual|connect-root-anchor-observations|connect-root-public-anchor-candidates) return 0 ;;
    *) return 2 ;;
  esac
}

private_visual_diagnostic_dir_is_valid() {
  local directory="$1"
  local parent canonical_directory canonical_parent owner mode
  [[ -n "${directory}" && "${directory}" == /* ]] || return 2
  [[ "$(basename "${directory}")" == relaykit-window-diag.* ]] || return 2
  [[ -d "${directory}" && ! -L "${directory}" ]] || return 2
  parent="$(dirname "${directory}")"
  [[ -d "${parent}" && ! -L "${parent}" ]] || return 2
  canonical_directory="$(cd "${directory}" 2>/dev/null && pwd -P)" || return 2
  canonical_parent="$(cd "${parent}" 2>/dev/null && pwd -P)" || return 2
  [[ "${directory}" == "${canonical_directory}" && "${parent}" == "${canonical_parent}" ]] || return 2
  owner="$(/usr/bin/stat -f '%u' "${directory}" 2>/dev/null)" || return 2
  mode="$(/usr/bin/stat -f '%Lp' "${directory}" 2>/dev/null)" || return 2
  [[ "${owner}" == "$(/usr/bin/id -u)" && "${mode}" == "700" ]] || return 2
  [[ -z "$(find "${directory}" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]] || return 2
}

set_provider_action_stage() {
  local flow="$1"
  local phase="$2"
  case "${flow}" in
    provider-click-flow|provider-light|provider-dark) ;;
    *) return 2 ;;
  esac
  case "${phase}" in
    show-key|hide-key|type-key|test-connection|use-reachable|advanced) ;;
    *) return 2 ;;
  esac
  set_stage "capture.${flow}.action.${phase}"
}

set_provider_capture_visual_stage() {
  local flow="$1"
  local phase="$2"
  case "${flow}" in
    provider-click-flow|provider-light|provider-dark) ;;
    *) return 2 ;;
  esac
  case "${phase}" in
    provider-row-click|hidden-models-click) ;;
    *) return 2 ;;
  esac
  set_stage "capture.${flow}.${phase}"
}

set_visual_action_stage() {
  local flow="$1"
  local mode="$2"
  local phase="$3"
  local category="$4"
  local scope="${5:-}"
  if [[ -n "${phase}" ]]; then
    case "${scope:-action}" in
      action)
        set_provider_action_stage "${flow}" "${phase}" || return $?
        set_stage "flow.${flow}.action.${phase}.visual-${mode}.${category}"
        ;;
      capture)
        set_provider_capture_visual_stage "${flow}" "${phase}" || return $?
        set_stage "flow.${flow}.capture.${phase}.visual-${mode}.${category}"
        ;;
      *) return 2 ;;
    esac
  else
    [[ -z "${scope}" ]] || return 2
    set_stage "flow.${flow}.visual-${mode}.${category}"
  fi
}

set_pre_swift_identity_stage() {
  local flow="$1"
  local mode="$2"
  local phase="$3"
  local category="$4"
  local scope="${5:-}"
  if [[ -n "${phase}" ]]; then
    case "${scope:-action}" in
      action)
        set_provider_action_stage "${flow}" "${phase}" || return $?
        set_stage "flow.${flow}.action.${phase}.visual-${mode}.pre-swift-identity.${category}"
        ;;
      capture)
        set_provider_capture_visual_stage "${flow}" "${phase}" || return $?
        set_stage "flow.${flow}.capture.${phase}.visual-${mode}.pre-swift-identity.${category}"
        ;;
      *) return 2 ;;
    esac
  else
    [[ -z "${scope}" ]] || return 2
    set_stage "flow.${flow}.visual-${mode}.pre-swift-identity.${category}"
  fi
}

set_visual_swift_stage() {
  local flow="$1"
  local mode="$2"
  local phase="$3"
  visual_flow_is_valid "${flow}" || return $?
  visual_mode_is_valid "${mode}" || return $?
  case "${phase}" in
    invoke|success) set_stage "flow.${flow}.visual-${mode}.swift-${phase}" ;;
    *) return 2 ;;
  esac
}

return_visual_action_failure() {
  local flow="$1"
  local mode="$2"
  local rc="$3"
  local phase="${4:-}"
  local scope="${5:-}"
  local category
  case "${rc}" in
    71) category=window-identity ;;
    72) category=capture ;;
    73) category=geometry ;;
    74) category=label-contract ;;
    75) category=ocr ;;
    76) category=ocr-empty ;;
    77) category=stale-window ;;
    78) category=temp ;;
    79) category=perform ;;
    81) category=duplicate-match ;;
    82) category=low-confidence ;;
    83) category=out-of-window-invalid-bounds ;;
    84) category=target-absent-current-flow ;;
    85) category=wrong-flow-anchors ;;
    86) category=nonempty-unclassified ;;
    87) category=select-text ;;
    88) category=input-text ;;
    89) category=window-missing ;;
    90) category=window-ambiguous ;;
    91) category=captureable-content-unavailable ;;
    92) category=semantic-capture-unavailable ;;
    93) category=semantic-ocr-empty ;;
    94) category=semantic-anchor-missing ;;
    95) category=semantic-anchor-duplicate ;;
    96) category=semantic-anchor-ambiguous ;;
    97) category=identity-or-geometry ;;
    *) category=internal; rc=80 ;;
  esac
  set_visual_action_stage "${flow}" "${mode}" "${phase}" "${category}" "${scope}" || return $?
  return "${rc}"
}

visual_pid_is_alive() {
  kill -0 "$1" 2>/dev/null
}

pre_swift_process_identity() {
  local flow="$1"
  local mode="$2"
  local phase="${3:-}"
  local scope="${4:-}"
  local actual expected_canonical
  if [[ ! "${PID}" =~ ^[0-9]+$ ]] || ((PID <= 1)); then
    set_pre_swift_identity_stage "${flow}" "${mode}" "${phase}" pid-missing-or-invalid "${scope}" || return $?
    return 61
  fi
  if ! visual_pid_is_alive "${PID}"; then
    set_pre_swift_identity_stage "${flow}" "${mode}" "${phase}" pid-not-alive "${scope}" || return $?
    return 62
  fi
  if ! actual="$(process_executable_path "${PID}")"; then
    set_pre_swift_identity_stage "${flow}" "${mode}" "${phase}" proc-pidpath-unavailable "${scope}" || return $?
    return 63
  fi
  if ! expected_canonical="$(canonical_executable_path "${APP_REAL}")"; then
    set_pre_swift_identity_stage "${flow}" "${mode}" "${phase}" expected-canonical-unavailable "${scope}" || return $?
    return 64
  fi
  if [[ "${actual}" != "${expected_canonical}" ]]; then
    set_pre_swift_identity_stage "${flow}" "${mode}" "${phase}" executable-mismatch "${scope}" || return $?
    return 65
  fi
  set_pre_swift_identity_stage "${flow}" "${mode}" "${phase}" success "${scope}"
}

visual_action() {
  local mode="$1"
  local flow="${2:-connect}"
  local label="${3:-}"
  local output="${4:-}"
  local phase="${5:-}"
  local scope="${6:-}"
  visual_mode_is_valid "${mode}" || return $?
  visual_flow_is_valid "${flow}" || return $?
  if [[ -n "${phase}" ]]; then
    case "${scope:-action}" in
      action) set_provider_action_stage "${flow}" "${phase}" || return $? ;;
      capture) set_provider_capture_visual_stage "${flow}" "${phase}" || return $? ;;
      *) return 2 ;;
    esac
  elif [[ -n "${scope}" ]]; then
    return 2
  fi
  if [[ "${mode}" != "self-test" ]]; then
    local identity_rc
    if pre_swift_process_identity "${flow}" "${mode}" "${phase}" "${scope}"; then
      :
    else
      identity_rc="$?"
      return "${identity_rc}"
    fi
  fi
  set_visual_swift_stage "${flow}" "${mode}" invoke
  local visual_rc
  if swift - "${mode}" "${PID:-0}" "${APP_REAL:-/nonexistent}" "${flow}" "${label}" "${output}" <<'SWIFT'
import ApplicationServices
import AppKit
import CoreGraphics
import CryptoKit
import Darwin
import Foundation
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers
import Vision

enum VisualFailure: Error {
    case windowIdentity
    case windowMissing
    case windowAmbiguous
    case captureableContentUnavailable
    case semanticCaptureUnavailable
    case semanticOCREmpty
    case semanticAnchorMissing
    case semanticAnchorDuplicate
    case semanticAnchorAmbiguous
    case semanticIdentityOrGeometry
    case capture
    case geometry
    case labelContract
    case ocr
    case ocrEmpty
    case targetAbsentCurrentFlow
    case wrongFlowAnchors
    case nonemptyUnclassified
    case duplicateMatch
    case lowConfidence
    case invalidBounds
    case staleWindow
    case temp
    case perform
    case selectText
    case inputText
    case synthetic
}

struct TextHit {
    let text: String
    let confidence: Float
    let normalized: CGRect
}

struct WindowIdentity {
    let pid: Int32
    let executable: String
    let id: CGWindowID
    let bounds: CGRect
}

struct SemanticCandidate {
    let window: WindowIdentity
    let hits: [TextHit]
    let imageWidth: Int
    let imageHeight: Int
    let image: CGImage?

    init(window: WindowIdentity, hits: [TextHit], imageWidth: Int, imageHeight: Int, image: CGImage? = nil) {
        self.window = window
        self.hits = hits
        self.imageWidth = imageWidth
        self.imageHeight = imageHeight
        self.image = image
    }
}

struct SemanticMatch {
    let candidate: SemanticCandidate
    let normalizedAnchorBounds: CGRect
    let absoluteAnchorCenter: CGPoint
}

struct WindowEquivalenceResult: Equatable {
    let samePointBounds: Bool
    let samePixelDimensions: Bool
    let samePixelSHA256: Bool
    let sameExactAnchorNormalizedBBox: Bool
    let sameAbsoluteAnchorCenter: Bool
    let sameBackingScale: Bool
    let allRevalidateStable: Bool
}

struct WindowEquivalenceObservation {
    let pointBounds: CGRect
    let pixelWidth: Int
    let pixelHeight: Int
    let pixelSHA256: Data
    let exactAnchorNormalizedBBox: CGRect
    let absoluteAnchorCenter: CGPoint
    let backingScaleX: CGFloat
    let backingScaleY: CGFloat
    let revalidationStable: Bool
}

enum SemanticMatchBucket: Equatable {
    case zero
    case one
    case multiple
}

struct TemporalSemanticState: Equatable {
    var sawZero = false
    var sawOne = false
    var sawMultiple = false
    var sawTransition = false
    private var previous: SemanticMatchBucket?

    mutating func record(_ matchCount: Int) {
        let current: SemanticMatchBucket
        switch matchCount {
        case 0: current = .zero
        case 1: current = .one
        default: current = .multiple
        }
        if let previous, previous != current {
            sawTransition = true
        }
        switch current {
        case .zero: sawZero = true
        case .one: sawOne = true
        case .multiple: sawMultiple = true
        }
        previous = current
    }
}

enum AmbiguityMode: String, CaseIterable {
    case probeWindow = "probe-window"
    case capture = "capture"
    case clickText = "click-text"
    case outside = "outside"
    case typeText = "type-text"
    case unsupported = "unsupported"
}

struct AmbiguityTargetDiscriminability: Equatable {
    let mode: AmbiguityMode
    let targetLabelApplicable: Bool
    let currentTargetAllowlisted: Bool
    let exactlyOneCandidateHasUniqueExactTarget: Bool
    let otherCandidatesHaveTarget: Bool
}

enum SurfaceProfile: String, CaseIterable {
    case connectRoot = "connect-root"
    case officialSheet = "official-sheet"
    case providerForm = "provider-form"
    case usageRoot = "usage-root"
    case settingsRoot = "settings-root"
    case outsidePopover = "outside-popover"
    case realQuit = "real-quit"
    case unsupported = "unsupported"
}

enum AnchorValidHitCardinality: String, CaseIterable {
    case zero = "zero"
    case one = "one"
    case multipleCandidates = "multiple-candidates"
    case duplicateWithinCandidate = "duplicate-within-candidate"
    case mixed = "mixed"
}

enum ConnectRootProfileCardinality: String, CaseIterable {
    case zero = "zero"
    case one = "one"
    case multiple = "multiple"
}

struct AnchorObservationDiagnostic: Equatable {
    let exactObservationSeen: Bool
    let confidenceThresholdSeen: Bool
    let geometryValidSeen: Bool
    let validHitCardinality: AnchorValidHitCardinality
}

struct ConnectRootAnchorObservationDiagnostic: Equatable {
    let profileCardinality: ConnectRootProfileCardinality
    let relayKit: AnchorObservationDiagnostic
    let combinedOfficial: AnchorObservationDiagnostic
    let openAIOfficial: AnchorObservationDiagnostic
    let codexOfficial: AnchorObservationDiagnostic
    let sameCandidateRelayKitAndCombinedValid: Bool
    let sameCandidateRelayKitAndOpenAIOfficialValid: Bool
    let sameCandidateRelayKitAndCodexOfficialValid: Bool
    let sameCandidateRelayKitAndBothSplitOfficialValid: Bool
}

enum ConnectRootPublicAnchorKey: CaseIterable {
    case gatewayStopped
    case usageTab
    case codexCard
    case enableRelayKit
    case officialAuthBadge
    case localCLIEyebrow
}

struct PublicAnchorCandidateDiagnostic: Equatable {
    let observation: AnchorObservationDiagnostic
    let relayKitPairProfileCardinality: ConnectRootProfileCardinality
}

struct ConnectRootPublicAnchorCandidatesDiagnostic: Equatable {
    let gatewayStopped: PublicAnchorCandidateDiagnostic
    let usageTab: PublicAnchorCandidateDiagnostic
    let codexCard: PublicAnchorCandidateDiagnostic
    let enableRelayKit: PublicAnchorCandidateDiagnostic
    let officialAuthBadge: PublicAnchorCandidateDiagnostic
    let localCLIEyebrow: PublicAnchorCandidateDiagnostic
}

struct SurfaceProfileDiscriminability: Equatable {
    let profile: SurfaceProfile
    let allRequiredAnchorsAllowlisted: Bool
    let exactlyOneCandidateMatchesAllRequiredExactAnchors: Bool
    let otherCandidatesMatchAll: Bool
    let profileHasRequiredAlternativeGroup: Bool
    let atLeastOneCandidateSatisfiesAllRequiredAlternativeGroups: Bool
}

enum WindowEquivalenceInvalidReason: String, CaseIterable {
    case semanticCandidateCardinality = "semantic-candidate-cardinality"
    case semanticMultipleNotObserved = "semantic-multiple-not-observed"
    case outsideSemanticAmbiguityNotObserved = "outside-semantic-ambiguity-not-observed"
    case semanticAmbiguityNotObserved = "semantic-ambiguity-not-observed"
    case captureableContentUnavailable = "captureable-content-unavailable"
    case semanticCaptureUnavailable = "semantic-capture-unavailable"
    case semanticOCREmpty = "semantic-ocr-empty"
    case semanticAnchorMissing = "semantic-anchor-missing"
    case semanticAnchorDuplicate = "semantic-anchor-duplicate"
    case identityOrGeometry = "identity-or-geometry"
    case revalidationFailed = "revalidation-failed"
    case `internal` = "internal"
}

struct WindowEquivalenceDiagnosticOutput {
    let schema: String
    let exitCode: Int32
}

var semanticFlowContext = "connect"
var semanticVisualModeContext = "capture"

func almostEqual(_ lhs: CGFloat, _ rhs: CGFloat) -> Bool {
    abs(lhs - rhs) < 0.0001
}

func screenRect(hit: TextHit, imageWidth: Int, imageHeight: Int, bounds: CGRect) throws -> CGRect {
    guard imageWidth > 0, imageHeight > 0, bounds.width > 0, bounds.height > 0,
          hit.normalized.minX >= 0, hit.normalized.minY >= 0,
          hit.normalized.maxX <= 1, hit.normalized.maxY <= 1 else { throw VisualFailure.invalidBounds }
    let scaleX = CGFloat(imageWidth) / bounds.width
    let scaleY = CGFloat(imageHeight) / bounds.height
    guard almostEqual(scaleX, scaleY), almostEqual(scaleX, 1) || almostEqual(scaleX, 2) else {
        throw VisualFailure.geometry
    }
    return CGRect(
        x: bounds.minX + hit.normalized.minX * CGFloat(imageWidth) / scaleX,
        y: bounds.minY + (1 - hit.normalized.maxY) * CGFloat(imageHeight) / scaleY,
        width: hit.normalized.width * CGFloat(imageWidth) / scaleX,
        height: hit.normalized.height * CGFloat(imageHeight) / scaleY
    )
}

enum MissingTargetClassification: Equatable {
    case ocrEmpty
    case targetAbsentCurrentFlow
    case wrongFlowAnchors
    case nonemptyUnclassified
}

func classifyMissingTarget(flow: String, hits: [TextHit]) -> MissingTargetClassification {
    guard !hits.isEmpty else { return .ocrEmpty }
    let officialAnchors = ["AUTH", "Models", "Codex"]
    let providerAnchors = ["Saved Key Provider", "Hidden models", "Test connection"]
    let usageAnchors = ["1M", "1Y"]
    let settingsAnchors = ["Developer / Diagnostics"]
    let currentAnchors: [String]
    let otherAnchors: [String]
    switch flow {
    case "official-sheet", "official-light", "official-dark":
        currentAnchors = officialAnchors
        otherAnchors = providerAnchors + usageAnchors + settingsAnchors
    case "provider-click-flow", "provider-light", "provider-dark", "provider-test-failure", "detail-advanced-expanded", "detail-advanced-collapsed":
        currentAnchors = providerAnchors
        otherAnchors = officialAnchors + usageAnchors + settingsAnchors
    case "usage", "usage-auto-refresh", "usage-large", "usage-1m", "usage-1y", "usage-empty", "usage-light", "usage-dark":
        currentAnchors = usageAnchors
        otherAnchors = officialAnchors + providerAnchors + settingsAnchors
    case "settings", "settings-developer-expanded", "settings-light", "settings-dark":
        currentAnchors = settingsAnchors
        otherAnchors = officialAnchors + providerAnchors + usageAnchors
    default:
        currentAnchors = []
        otherAnchors = officialAnchors + providerAnchors + usageAnchors + settingsAnchors
    }
    let hasCurrentAnchor = currentAnchors.contains { anchor in hits.contains { $0.text == anchor } }
    if hasCurrentAnchor { return .targetAbsentCurrentFlow }
    let hasWrongFlowAnchor = otherAnchors.contains { anchor in hits.contains { $0.text == anchor } }
    if hasWrongFlowAnchor { return .wrongFlowAnchors }
    return .nonemptyUnclassified
}

func missingTargetFailure(flow: String, hits: [TextHit]) -> VisualFailure {
    switch classifyMissingTarget(flow: flow, hits: hits) {
    case .ocrEmpty: return .ocrEmpty
    case .targetAbsentCurrentFlow: return .targetAbsentCurrentFlow
    case .wrongFlowAnchors: return .wrongFlowAnchors
    case .nonemptyUnclassified: return .nonemptyUnclassified
    }
}

func uniqueExact(_ labels: [String], flow: String, hits: [TextHit], imageWidth: Int, imageHeight: Int, bounds: CGRect) throws -> CGRect {
    for label in labels {
        let exact = hits.filter { $0.text == label }
        if exact.isEmpty { continue }
        let confident = exact.filter { $0.confidence >= 0.80 }
        guard !confident.isEmpty else { throw VisualFailure.lowConfidence }
        guard confident.count == 1 else { throw VisualFailure.duplicateMatch }
        let match = try screenRect(hit: confident[0], imageWidth: imageWidth, imageHeight: imageHeight, bounds: bounds)
        guard bounds.contains(match) else { throw VisualFailure.invalidBounds }
        return match
    }
    throw missingTargetFailure(flow: flow, hits: hits)
}

func uniqueExact(_ label: String, flow: String, hits: [TextHit], imageWidth: Int, imageHeight: Int, bounds: CGRect) throws -> CGRect {
    try uniqueExact([label], flow: flow, hits: hits, imageWidth: imageWidth, imageHeight: imageHeight, bounds: bounds)
}

func validateIdentity(_ expectedPID: Int32, _ expectedExecutable: String, _ current: WindowIdentity, _ frozen: WindowIdentity? = nil) throws {
    guard current.pid == expectedPID,
          current.executable == expectedExecutable,
          current.id != 0,
          current.bounds.width > 0,
          current.bounds.height > 0 else { throw VisualFailure.windowIdentity }
    if let frozen {
        guard frozen.pid == current.pid,
              frozen.executable == current.executable,
              frozen.id == current.id,
              frozen.bounds.equalTo(current.bounds) else { throw VisualFailure.windowIdentity }
    }
}

func selectEligibleWindow(_ windows: [WindowIdentity], pid: Int32, expectedExecutable: String) throws -> WindowIdentity {
    guard !windows.isEmpty else { throw VisualFailure.windowMissing }
    guard windows.count == 1 else { throw VisualFailure.windowAmbiguous }
    let selected = windows[0]
    guard selected.pid == pid, selected.executable == expectedExecutable, selected.id != 0 else {
        throw VisualFailure.windowIdentity
    }
    guard selected.bounds.width > 0, selected.bounds.height > 0 else { throw VisualFailure.geometry }
    try validateIdentity(pid, expectedExecutable, selected)
    return selected
}

func eligibleWindowIdentities(_ items: [[String: Any]], pid: Int32, expectedExecutable: String) -> [WindowIdentity] {
    items.compactMap { item in
        guard (item[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
              (item[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue == true,
              let number = item[kCGWindowNumber as String] as? NSNumber,
              number.uint32Value != 0,
              let boundsDictionary = item[kCGWindowBounds as String] as? NSDictionary,
              let rawWidth = boundsDictionary["Width"] as? NSNumber,
              let rawHeight = boundsDictionary["Height"] as? NSNumber,
              rawWidth.doubleValue > 0, rawHeight.doubleValue > 0,
              let bounds = CGRect(dictionaryRepresentation: boundsDictionary),
              bounds.width > 0, bounds.height > 0 else { return nil }
        return WindowIdentity(pid: pid, executable: expectedExecutable, id: number.uint32Value, bounds: bounds)
    }
}

func captureableEligibleWindowIdentities(
    _ eligible: [WindowIdentity],
    captureableIDs: Set<CGWindowID>
) -> [WindowIdentity] {
    eligible.filter { captureableIDs.contains($0.id) }
}

func requiredCaptureableWindowIDs(_ ids: Set<CGWindowID>?) throws -> Set<CGWindowID> {
    guard let ids else { throw VisualFailure.captureableContentUnavailable }
    return ids
}

func withTemporaryCapture<T>(_ body: (URL) throws -> T) throws -> T {
    let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("relaykit-visual-\(UUID().uuidString).png")
    guard FileManager.default.createFile(atPath: url.path, contents: Data("fixture".utf8)) else { throw VisualFailure.temp }
    do {
        let result = try body(url)
        do { try FileManager.default.removeItem(at: url) } catch { throw VisualFailure.temp }
        return result
    } catch {
        try? FileManager.default.removeItem(at: url)
        throw error
    }
}

func visual_action_synthetic_contract() throws {
    let bounds = CGRect(x: 100, y: 200, width: 400, height: 300)
    let hit = TextHit(text: "Advanced", confidence: 0.99, normalized: CGRect(x: 0.25, y: 0.20, width: 0.20, height: 0.10))
    let one = try screenRect(hit: hit, imageWidth: 400, imageHeight: 300, bounds: bounds)
    let two = try screenRect(hit: hit, imageWidth: 800, imageHeight: 600, bounds: bounds)
    guard one.equalTo(two), almostEqual(one.minY, 410) else { throw VisualFailure.synthetic }
    _ = try uniqueExact("Advanced", flow: "provider-click-flow", hits: [hit], imageWidth: 400, imageHeight: 300, bounds: bounds)
    let matchFailures: [([TextHit], Int32)] = [
        ([], 76),
        ([hit, hit], 81),
        ([TextHit(text: "Advanced", confidence: 0.2, normalized: hit.normalized)], 82),
        ([TextHit(text: "Advanced", confidence: 0.99, normalized: CGRect(x: 0.95, y: 0.2, width: 0.2, height: 0.1))], 83)
    ]
    for (bad, expectedCode) in matchFailures {
        var actualCode: Int32 = 0
        do {
            _ = try uniqueExact("Advanced", flow: "provider-click-flow", hits: bad, imageWidth: 400, imageHeight: 300, bounds: bounds)
        } catch VisualFailure.ocrEmpty { actualCode = 76 }
          catch VisualFailure.duplicateMatch { actualCode = 81 }
          catch VisualFailure.lowConfidence { actualCode = 82 }
          catch VisualFailure.invalidBounds { actualCode = 83 }
          catch { actualCode = -1 }
        guard actualCode == expectedCode else { throw VisualFailure.synthetic }
    }
    let anchorHit: (String) -> TextHit = { text in
        TextHit(text: text, confidence: 0.99, normalized: hit.normalized)
    }
    guard classifyMissingTarget(flow: "official-sheet", hits: []) == .ocrEmpty,
          classifyMissingTarget(flow: "official-sheet", hits: [anchorHit("AUTH"), anchorHit("Models")]) == .targetAbsentCurrentFlow,
          classifyMissingTarget(flow: "official-sheet", hits: [anchorHit("Saved Key Provider"), anchorHit("Test connection")]) == .wrongFlowAnchors,
          classifyMissingTarget(flow: "official-sheet", hits: [anchorHit("Unclassified public fixture")]) == .nonemptyUnclassified else {
        throw VisualFailure.synthetic
    }
    let officialTargets = ["OpenAI Official / Codex Official", "AUTH", "OpenAI Official", "Codex Official"]
    for alternative in officialTargets {
        _ = try uniqueExact(officialTargets, flow: "official-sheet", hits: [anchorHit(alternative)], imageWidth: 400, imageHeight: 300, bounds: bounds)
    }
    let frozen = WindowIdentity(pid: 7, executable: "/public/RelayKitApp.bin", id: 9, bounds: bounds)
    try validateIdentity(7, "/public/RelayKitApp.bin", frozen, frozen)
    let syntheticProbeSuccess = try selectEligibleWindow([frozen], pid: 7, expectedExecutable: "/public/RelayKitApp.bin")
    guard syntheticProbeSuccess.id == frozen.id else { throw VisualFailure.synthetic }
    var syntheticProbeMissing = false
    do {
        _ = try selectEligibleWindow([], pid: 7, expectedExecutable: "/public/RelayKitApp.bin")
    } catch VisualFailure.windowMissing { syntheticProbeMissing = true }
    guard syntheticProbeMissing else { throw VisualFailure.synthetic }
    var syntheticProbeDuplicate = false
    do {
        _ = try selectEligibleWindow([frozen, frozen], pid: 7, expectedExecutable: "/public/RelayKitApp.bin")
    } catch VisualFailure.windowAmbiguous { syntheticProbeDuplicate = true }
    guard syntheticProbeDuplicate else { throw VisualFailure.synthetic }
    let syntheticProbeStale = WindowIdentity(pid: frozen.pid, executable: frozen.executable, id: 10, bounds: frozen.bounds)
    var syntheticProbeStaleRejected = false
    do {
        try validateIdentity(7, "/public/RelayKitApp.bin", syntheticProbeStale, frozen)
    } catch VisualFailure.windowIdentity { syntheticProbeStaleRejected = true }
    guard syntheticProbeStaleRejected else { throw VisualFailure.synthetic }
    let syntheticProbeIdentity = WindowIdentity(pid: 8, executable: frozen.executable, id: frozen.id, bounds: frozen.bounds)
    var syntheticProbeIdentityRejected = false
    do {
        _ = try selectEligibleWindow([syntheticProbeIdentity], pid: 7, expectedExecutable: frozen.executable)
    } catch VisualFailure.windowIdentity { syntheticProbeIdentityRejected = true }
    guard syntheticProbeIdentityRejected else { throw VisualFailure.synthetic }
    let syntheticProbeGeometry = WindowIdentity(pid: frozen.pid, executable: frozen.executable, id: frozen.id, bounds: .zero)
    var syntheticProbeGeometryRejected = false
    do {
        _ = try selectEligibleWindow([syntheticProbeGeometry], pid: 7, expectedExecutable: frozen.executable)
    } catch VisualFailure.geometry { syntheticProbeGeometryRejected = true }
    guard syntheticProbeGeometryRejected else { throw VisualFailure.synthetic }
    let syntheticZero = ProcessInfo.processInfo.environment["RELAYKIT_MENU_BAR_VISUAL_SYNTHETIC_TEST"] == "1" ? 0 : 1
    let syntheticProbeCounts = (events: syntheticZero, captures: syntheticZero, writes: syntheticZero)
    let syntheticOutsideCount = 1
    guard syntheticProbeCounts.events == 0, syntheticProbeCounts.captures == 0,
          syntheticProbeCounts.writes == 0, syntheticOutsideCount == 1 else { throw VisualFailure.synthetic }
    let validItem: [String: Any] = [
        kCGWindowOwnerPID as String: NSNumber(value: 7),
        kCGWindowIsOnscreen as String: NSNumber(value: true),
        kCGWindowNumber as String: NSNumber(value: 9),
        kCGWindowBounds as String: bounds.dictionaryRepresentation
    ]
    let secondValidItem: [String: Any] = [
        kCGWindowOwnerPID as String: NSNumber(value: 7),
        kCGWindowIsOnscreen as String: NSNumber(value: true),
        kCGWindowNumber as String: NSNumber(value: 10),
        kCGWindowBounds as String: bounds.dictionaryRepresentation
    ]
    let wrongPIDItem: [String: Any] = [
        kCGWindowOwnerPID as String: NSNumber(value: 8),
        kCGWindowIsOnscreen as String: NSNumber(value: true),
        kCGWindowNumber as String: NSNumber(value: 11),
        kCGWindowBounds as String: bounds.dictionaryRepresentation
    ]
    let syntheticInvalidWindowNumber: [String: Any] = [
        kCGWindowOwnerPID as String: NSNumber(value: 7),
        kCGWindowIsOnscreen as String: NSNumber(value: true),
        kCGWindowNumber as String: NSNumber(value: 0),
        kCGWindowBounds as String: bounds.dictionaryRepresentation
    ]
    let syntheticUnparseableBounds: [String: Any] = [
        kCGWindowOwnerPID as String: NSNumber(value: 7),
        kCGWindowIsOnscreen as String: NSNumber(value: true),
        kCGWindowNumber as String: NSNumber(value: 12),
        kCGWindowBounds as String: "invalid"
    ]
    let syntheticZeroBounds: [String: Any] = [
        kCGWindowOwnerPID as String: NSNumber(value: 7),
        kCGWindowIsOnscreen as String: NSNumber(value: true),
        kCGWindowNumber as String: NSNumber(value: 13),
        kCGWindowBounds as String: CGRect.zero.dictionaryRepresentation
    ]
    let syntheticNegativeBounds: [String: Any] = [
        kCGWindowOwnerPID as String: NSNumber(value: 7),
        kCGWindowIsOnscreen as String: NSNumber(value: true),
        kCGWindowNumber as String: NSNumber(value: 14),
        kCGWindowBounds as String: NSDictionary(dictionary: ["X": 0, "Y": 0, "Width": -1, "Height": 10])
    ]
    let syntheticEligibilityOneValidOneInvalid = eligibleWindowIdentities(
        [validItem, wrongPIDItem], pid: 7, expectedExecutable: frozen.executable
    )
    guard try selectEligibleWindow(syntheticEligibilityOneValidOneInvalid, pid: 7, expectedExecutable: frozen.executable).id == 9 else {
        throw VisualFailure.synthetic
    }
    let syntheticEligibilityTwoValid = eligibleWindowIdentities(
        [validItem, secondValidItem], pid: 7, expectedExecutable: frozen.executable
    )
    var syntheticEligibilityTwoValidRejected = false
    do {
        _ = try selectEligibleWindow(syntheticEligibilityTwoValid, pid: 7, expectedExecutable: frozen.executable)
    } catch VisualFailure.windowAmbiguous { syntheticEligibilityTwoValidRejected = true }
    guard syntheticEligibilityTwoValidRejected else { throw VisualFailure.synthetic }
    let syntheticEligibilityOnlyInvalid = eligibleWindowIdentities(
        [wrongPIDItem, syntheticInvalidWindowNumber, syntheticUnparseableBounds, syntheticZeroBounds, syntheticNegativeBounds],
        pid: 7,
        expectedExecutable: frozen.executable
    )
    guard syntheticEligibilityOnlyInvalid.isEmpty else { throw VisualFailure.synthetic }
    let syntheticProbeActionParity = (
        probe: try selectEligibleWindow(syntheticEligibilityOneValidOneInvalid, pid: 7, expectedExecutable: frozen.executable),
        action: try selectEligibleWindow(syntheticEligibilityOneValidOneInvalid, pid: 7, expectedExecutable: frozen.executable)
    )
    guard syntheticProbeActionParity.probe.id == syntheticProbeActionParity.action.id else { throw VisualFailure.synthetic }
    let syntheticCaptureableOneOfTwo = captureableEligibleWindowIdentities(
        syntheticEligibilityTwoValid,
        captureableIDs: Set([CGWindowID(9)])
    )
    guard try selectEligibleWindow(syntheticCaptureableOneOfTwo, pid: 7, expectedExecutable: frozen.executable).id == 9 else {
        throw VisualFailure.synthetic
    }
    let syntheticCaptureableBoth = captureableEligibleWindowIdentities(
        syntheticEligibilityTwoValid,
        captureableIDs: Set([CGWindowID(9), CGWindowID(10)])
    )
    var syntheticCaptureableBothRejected = false
    do {
        _ = try selectEligibleWindow(syntheticCaptureableBoth, pid: 7, expectedExecutable: frozen.executable)
    } catch VisualFailure.windowAmbiguous { syntheticCaptureableBothRejected = true }
    guard syntheticCaptureableBothRejected else { throw VisualFailure.synthetic }
    let syntheticCaptureableNone = captureableEligibleWindowIdentities(
        syntheticEligibilityTwoValid,
        captureableIDs: []
    )
    var syntheticCaptureableNoneRejected = false
    do {
        _ = try selectEligibleWindow(syntheticCaptureableNone, pid: 7, expectedExecutable: frozen.executable)
    } catch VisualFailure.windowMissing { syntheticCaptureableNoneRejected = true }
    guard syntheticCaptureableNoneRejected else { throw VisualFailure.synthetic }
    var syntheticCaptureableUnavailable = false
    do {
        _ = try requiredCaptureableWindowIDs(nil)
    } catch VisualFailure.captureableContentUnavailable { syntheticCaptureableUnavailable = true }
    guard syntheticCaptureableUnavailable else { throw VisualFailure.synthetic }
    let syntheticCaptureableExternalPID = captureableEligibleWindowIdentities(
        eligibleWindowIdentities([validItem, wrongPIDItem], pid: 7, expectedExecutable: frozen.executable),
        captureableIDs: Set([CGWindowID(9), CGWindowID(11)])
    )
    guard syntheticCaptureableExternalPID.count == 1, syntheticCaptureableExternalPID[0].id == 9 else {
        throw VisualFailure.synthetic
    }
    let syntheticCaptureableProbeActionParity = (
        probe: try selectEligibleWindow(syntheticCaptureableOneOfTwo, pid: 7, expectedExecutable: frozen.executable),
        action: try selectEligibleWindow(syntheticCaptureableOneOfTwo, pid: 7, expectedExecutable: frozen.executable)
    )
    guard syntheticCaptureableProbeActionParity.probe.id == syntheticCaptureableProbeActionParity.action.id else {
        throw VisualFailure.synthetic
    }
    let semanticRelayHit = TextHit(text: "RelayKit", confidence: 0.99, normalized: hit.normalized)
    let semanticQuitHit = TextHit(text: "Quit RelayKit", confidence: 0.99, normalized: hit.normalized)
    let semanticSecondWindow = WindowIdentity(pid: 7, executable: frozen.executable, id: 10, bounds: bounds)
    let semanticRelayCandidate = SemanticCandidate(window: frozen, hits: [semanticRelayHit], imageWidth: 400, imageHeight: 300)
    let semanticSecondCandidate = SemanticCandidate(window: semanticSecondWindow, hits: [semanticRelayHit], imageWidth: 400, imageHeight: 300)
    let semanticCombinedHit = TextHit(text: "OpenAI Official / Codex Official", confidence: 0.99, normalized: hit.normalized)
    let semanticUsageHit = TextHit(text: "Usage", confidence: 0.99, normalized: hit.normalized)
    let strictConnectFullCandidate = SemanticCandidate(
        window: semanticSecondWindow,
        hits: [semanticRelayHit, semanticUsageHit],
        imageWidth: 400,
        imageHeight: 300
    )
    let observationOpenAIHit = TextHit(text: "OpenAI Official", confidence: 0.99, normalized: hit.normalized)
    let observationCodexHit = TextHit(text: "Codex Official", confidence: 0.99, normalized: hit.normalized)
    let observationCandidate: (WindowIdentity, [TextHit]) -> SemanticCandidate = { window, hits in
        SemanticCandidate(window: window, hits: hits, imageWidth: 400, imageHeight: 300)
    }
    let combinedOnlyObservation = connectRootAnchorObservationDiagnostic(candidates: [
        observationCandidate(frozen, [semanticCombinedHit])
    ])
    guard combinedOnlyObservation.profileCardinality == .zero,
          combinedOnlyObservation.combinedOfficial.exactObservationSeen,
          combinedOnlyObservation.combinedOfficial.confidenceThresholdSeen,
          combinedOnlyObservation.combinedOfficial.geometryValidSeen,
          combinedOnlyObservation.combinedOfficial.validHitCardinality == .one,
          !combinedOnlyObservation.sameCandidateRelayKitAndCombinedValid else {
        throw VisualFailure.synthetic
    }
    let splitOnlyObservation = connectRootAnchorObservationDiagnostic(candidates: [
        observationCandidate(frozen, [observationOpenAIHit, observationCodexHit])
    ])
    guard splitOnlyObservation.profileCardinality == .zero,
          splitOnlyObservation.openAIOfficial.validHitCardinality == .one,
          splitOnlyObservation.codexOfficial.validHitCardinality == .one,
          !splitOnlyObservation.sameCandidateRelayKitAndBothSplitOfficialValid else {
        throw VisualFailure.synthetic
    }
    let allAnchorsObservation = connectRootAnchorObservationDiagnostic(candidates: [
        observationCandidate(frozen, [semanticRelayHit, semanticCombinedHit, observationOpenAIHit, observationCodexHit])
    ])
    guard allAnchorsObservation.profileCardinality == .one,
          allAnchorsObservation.sameCandidateRelayKitAndCombinedValid,
          allAnchorsObservation.sameCandidateRelayKitAndOpenAIOfficialValid,
          allAnchorsObservation.sameCandidateRelayKitAndCodexOfficialValid,
          allAnchorsObservation.sameCandidateRelayKitAndBothSplitOfficialValid else {
        throw VisualFailure.synthetic
    }
    let auxiliarySeparateObservation = connectRootAnchorObservationDiagnostic(candidates: [
        observationCandidate(frozen, [semanticRelayHit]),
        observationCandidate(semanticSecondWindow, [semanticCombinedHit]),
        observationCandidate(WindowIdentity(pid: 7, executable: frozen.executable, id: 12, bounds: bounds), [observationOpenAIHit]),
        observationCandidate(WindowIdentity(pid: 7, executable: frozen.executable, id: 13, bounds: bounds), [observationCodexHit])
    ])
    guard auxiliarySeparateObservation.profileCardinality == .zero,
          auxiliarySeparateObservation.relayKit.validHitCardinality == .one,
          auxiliarySeparateObservation.combinedOfficial.validHitCardinality == .one,
          auxiliarySeparateObservation.openAIOfficial.validHitCardinality == .one,
          auxiliarySeparateObservation.codexOfficial.validHitCardinality == .one,
          !auxiliarySeparateObservation.sameCandidateRelayKitAndCombinedValid,
          !auxiliarySeparateObservation.sameCandidateRelayKitAndOpenAIOfficialValid,
          !auxiliarySeparateObservation.sameCandidateRelayKitAndCodexOfficialValid,
          !auxiliarySeparateObservation.sameCandidateRelayKitAndBothSplitOfficialValid else {
        throw VisualFailure.synthetic
    }
    let lowObservation = connectRootAnchorObservationDiagnostic(candidates: [
        observationCandidate(frozen, [TextHit(text: semanticCombinedHit.text, confidence: 0.79, normalized: hit.normalized)])
    ])
    guard lowObservation.combinedOfficial.exactObservationSeen,
          !lowObservation.combinedOfficial.confidenceThresholdSeen,
          !lowObservation.combinedOfficial.geometryValidSeen,
          lowObservation.combinedOfficial.validHitCardinality == .zero else {
        throw VisualFailure.synthetic
    }
    let invalidGeometryObservation = connectRootAnchorObservationDiagnostic(candidates: [
        observationCandidate(frozen, [
            TextHit(
                text: semanticCombinedHit.text,
                confidence: 0.99,
                normalized: CGRect(x: 0.95, y: 0.2, width: 0.2, height: 0.1)
            )
        ])
    ])
    guard invalidGeometryObservation.combinedOfficial.exactObservationSeen,
          invalidGeometryObservation.combinedOfficial.confidenceThresholdSeen,
          !invalidGeometryObservation.combinedOfficial.geometryValidSeen,
          invalidGeometryObservation.combinedOfficial.validHitCardinality == .zero else {
        throw VisualFailure.synthetic
    }
    let duplicateObservation = connectRootAnchorObservationDiagnostic(candidates: [
        observationCandidate(frozen, [semanticCombinedHit, semanticCombinedHit])
    ])
    guard duplicateObservation.combinedOfficial.validHitCardinality == .duplicateWithinCandidate else {
        throw VisualFailure.synthetic
    }
    let multipleObservation = connectRootAnchorObservationDiagnostic(candidates: [
        observationCandidate(frozen, [semanticCombinedHit]),
        observationCandidate(semanticSecondWindow, [semanticCombinedHit])
    ])
    guard multipleObservation.combinedOfficial.validHitCardinality == .multipleCandidates else {
        throw VisualFailure.synthetic
    }
    let mixedObservation = connectRootAnchorObservationDiagnostic(candidates: [
        observationCandidate(frozen, [semanticCombinedHit, semanticCombinedHit]),
        observationCandidate(semanticSecondWindow, [semanticCombinedHit])
    ])
    guard mixedObservation.combinedOfficial.validHitCardinality == .mixed else {
        throw VisualFailure.synthetic
    }
    let profileMultipleObservation = connectRootAnchorObservationDiagnostic(candidates: [
        observationCandidate(frozen, [semanticRelayHit, semanticCombinedHit]),
        observationCandidate(semanticSecondWindow, [semanticRelayHit, semanticCombinedHit])
    ])
    guard profileMultipleObservation.profileCardinality == .multiple else { throw VisualFailure.synthetic }
    let allAnchorsSchema = connectRootAnchorObservationSchema(allAnchorsObservation)
    let expectedAllAnchorsSchema = [
        "DIAG_VALID=true",
        "connect_root_profile_cardinality=one",
        "relaykit_exact_observation_seen=true",
        "relaykit_confidence_threshold_seen=true",
        "relaykit_geometry_valid_seen=true",
        "relaykit_valid_hit_cardinality=one",
        "combined_official_exact_observation_seen=true",
        "combined_official_confidence_threshold_seen=true",
        "combined_official_geometry_valid_seen=true",
        "combined_official_valid_hit_cardinality=one",
        "openai_official_exact_observation_seen=true",
        "openai_official_confidence_threshold_seen=true",
        "openai_official_geometry_valid_seen=true",
        "openai_official_valid_hit_cardinality=one",
        "codex_official_exact_observation_seen=true",
        "codex_official_confidence_threshold_seen=true",
        "codex_official_geometry_valid_seen=true",
        "codex_official_valid_hit_cardinality=one",
        "same_candidate_relaykit_and_combined_valid=true",
        "same_candidate_relaykit_and_openai_official_valid=true",
        "same_candidate_relaykit_and_codex_official_valid=true",
        "same_candidate_relaykit_and_both_split_official_valid=true"
    ].joined(separator: "\n")
    guard allAnchorsSchema == expectedAllAnchorsSchema,
          !allAnchorsSchema.contains("OpenAI Official"),
          !allAnchorsSchema.contains("Codex Official"),
          !allAnchorsSchema.contains("RelayKit") else {
        throw VisualFailure.synthetic
    }
    let publicAnchorMappings: [(ConnectRootPublicAnchorKey, String)] = [
        (.gatewayStopped, "Stopped"),
        (.usageTab, "Usage"),
        (.codexCard, "Codex"),
        (.enableRelayKit, "Enable RelayKit"),
        (.officialAuthBadge, "AUTH"),
        (.localCLIEyebrow, "LOCAL CLI")
    ]
    for (key, label) in publicAnchorMappings {
        guard connectRootPublicAnchorText(key) == label else { throw VisualFailure.synthetic }
        let publicHit = TextHit(text: label, confidence: 0.99, normalized: hit.normalized)
        let diagnostic = connectRootPublicAnchorCandidatesDiagnostic(candidates: [
            observationCandidate(frozen, [semanticRelayHit]),
            observationCandidate(semanticSecondWindow, [semanticRelayHit, publicHit])
        ])
        let summary = connectRootPublicAnchorSummary(diagnostic, key: key)
        guard summary.observation.exactObservationSeen,
              summary.observation.confidenceThresholdSeen,
              summary.observation.geometryValidSeen,
              summary.observation.validHitCardinality == .one,
              summary.relayKitPairProfileCardinality == .one else {
            throw VisualFailure.synthetic
        }
    }
    let stoppedHit = TextHit(text: "Stopped", confidence: 0.99, normalized: hit.normalized)
    let publicAbsent = connectRootPublicAnchorCandidatesDiagnostic(candidates: [
        observationCandidate(frozen, [semanticRelayHit])
    ]).gatewayStopped
    guard !publicAbsent.observation.exactObservationSeen,
          publicAbsent.observation.validHitCardinality == .zero,
          publicAbsent.relayKitPairProfileCardinality == .zero else { throw VisualFailure.synthetic }
    let publicLow = connectRootPublicAnchorCandidatesDiagnostic(candidates: [
        observationCandidate(frozen, [
            semanticRelayHit,
            TextHit(text: stoppedHit.text, confidence: 0.79, normalized: hit.normalized)
        ])
    ]).gatewayStopped
    guard publicLow.observation.exactObservationSeen,
          !publicLow.observation.confidenceThresholdSeen,
          !publicLow.observation.geometryValidSeen,
          publicLow.observation.validHitCardinality == .zero,
          publicLow.relayKitPairProfileCardinality == .zero else { throw VisualFailure.synthetic }
    let publicInvalidGeometry = connectRootPublicAnchorCandidatesDiagnostic(candidates: [
        observationCandidate(frozen, [
            semanticRelayHit,
            TextHit(
                text: stoppedHit.text,
                confidence: 0.99,
                normalized: CGRect(x: 0.95, y: 0.2, width: 0.2, height: 0.1)
            )
        ])
    ]).gatewayStopped
    guard publicInvalidGeometry.observation.exactObservationSeen,
          publicInvalidGeometry.observation.confidenceThresholdSeen,
          !publicInvalidGeometry.observation.geometryValidSeen,
          publicInvalidGeometry.observation.validHitCardinality == .zero,
          publicInvalidGeometry.relayKitPairProfileCardinality == .zero else {
        throw VisualFailure.synthetic
    }
    let publicDuplicate = connectRootPublicAnchorCandidatesDiagnostic(candidates: [
        observationCandidate(frozen, [semanticRelayHit, stoppedHit, stoppedHit])
    ]).gatewayStopped
    guard publicDuplicate.observation.validHitCardinality == .duplicateWithinCandidate,
          publicDuplicate.relayKitPairProfileCardinality == .zero else { throw VisualFailure.synthetic }
    let publicMultiple = connectRootPublicAnchorCandidatesDiagnostic(candidates: [
        observationCandidate(frozen, [semanticRelayHit, stoppedHit]),
        observationCandidate(semanticSecondWindow, [stoppedHit])
    ]).gatewayStopped
    guard publicMultiple.observation.validHitCardinality == .multipleCandidates,
          publicMultiple.relayKitPairProfileCardinality == .one else { throw VisualFailure.synthetic }
    let publicMixed = connectRootPublicAnchorCandidatesDiagnostic(candidates: [
        observationCandidate(frozen, [semanticRelayHit, stoppedHit, stoppedHit]),
        observationCandidate(semanticSecondWindow, [semanticRelayHit, stoppedHit])
    ]).gatewayStopped
    guard publicMixed.observation.validHitCardinality == .mixed,
          publicMixed.relayKitPairProfileCardinality == .one else { throw VisualFailure.synthetic }
    let publicPairMultiple = connectRootPublicAnchorCandidatesDiagnostic(candidates: [
        observationCandidate(frozen, [semanticRelayHit, stoppedHit]),
        observationCandidate(semanticSecondWindow, [semanticRelayHit, stoppedHit])
    ]).gatewayStopped
    guard publicPairMultiple.relayKitPairProfileCardinality == .multiple else { throw VisualFailure.synthetic }
    let invalidRelayHit = TextHit(text: semanticRelayHit.text, confidence: 0.79, normalized: hit.normalized)
    let publicInvalidRelay = connectRootPublicAnchorCandidatesDiagnostic(candidates: [
        observationCandidate(frozen, [invalidRelayHit, stoppedHit])
    ]).gatewayStopped
    let publicDuplicateRelay = connectRootPublicAnchorCandidatesDiagnostic(candidates: [
        observationCandidate(frozen, [semanticRelayHit, semanticRelayHit, stoppedHit])
    ]).gatewayStopped
    guard publicInvalidRelay.relayKitPairProfileCardinality == .zero,
          publicDuplicateRelay.relayKitPairProfileCardinality == .zero else {
        throw VisualFailure.synthetic
    }
    let publicSchema = connectRootPublicAnchorCandidatesSchema(
        connectRootPublicAnchorCandidatesDiagnostic(candidates: [
            observationCandidate(frozen, [semanticRelayHit, stoppedHit])
        ])
    )
    guard publicSchema.split(separator: "\n").count == 31,
          publicSchema.hasPrefix("DIAG_VALID=true\n"),
          !publicAnchorMappings.contains(where: { publicSchema.contains($0.1) }) else {
        throw VisualFailure.synthetic
    }
    semanticFlowContext = "connect"
    let strictConnectSelected = try selectSemanticWindow(
        [semanticRelayCandidate, strictConnectFullCandidate],
        anchor: "RelayKit"
    )
    guard strictConnectSelected.id == semanticSecondWindow.id else { throw VisualFailure.synthetic }
    guard try selectSemanticWindow([strictConnectFullCandidate], anchor: "RelayKit").id == semanticSecondWindow.id else {
        throw VisualFailure.synthetic
    }
    let strictConnectProbeActionParity = (
        probe: try selectSemanticWindow([semanticRelayCandidate, strictConnectFullCandidate], anchor: "RelayKit"),
        action: try selectSemanticWindow([semanticRelayCandidate, strictConnectFullCandidate], anchor: "RelayKit")
    )
    guard strictConnectProbeActionParity.probe.id == strictConnectProbeActionParity.action.id else {
        throw VisualFailure.synthetic
    }
    semanticFlowContext = "outside-click"
    let strictOutsideProbeActionParity = (
        probe: try selectSemanticWindow([semanticRelayCandidate, strictConnectFullCandidate], anchor: "RelayKit"),
        action: try selectSemanticWindow([semanticRelayCandidate, strictConnectFullCandidate], anchor: "RelayKit")
    )
    guard strictOutsideProbeActionParity.probe.id == semanticSecondWindow.id,
          strictOutsideProbeActionParity.probe.id == strictOutsideProbeActionParity.action.id else {
        throw VisualFailure.synthetic
    }
    let strictOldCombinedCandidate = SemanticCandidate(
        window: frozen,
        hits: [semanticRelayHit, semanticCombinedHit],
        imageWidth: 400,
        imageHeight: 300
    )
    let strictDuplicateCandidate = SemanticCandidate(
        window: frozen,
        hits: [semanticRelayHit, semanticUsageHit, semanticUsageHit],
        imageWidth: 400,
        imageHeight: 300
    )
    let strictLowConfidenceCandidate = SemanticCandidate(
        window: frozen,
        hits: [semanticRelayHit, TextHit(text: semanticUsageHit.text, confidence: 0.79, normalized: hit.normalized)],
        imageWidth: 400,
        imageHeight: 300
    )
    let strictInvalidGeometryCandidate = SemanticCandidate(
        window: frozen,
        hits: [
            semanticRelayHit,
            TextHit(
                text: semanticUsageHit.text,
                confidence: 0.99,
                normalized: CGRect(x: 0.95, y: 0.2, width: 0.2, height: 0.1)
            )
        ],
        imageWidth: 400,
        imageHeight: 300
    )
    func strictSelectionIsMissing(_ candidates: [SemanticCandidate], flow: String) -> Bool {
        semanticFlowContext = flow
        do {
            _ = try selectSemanticWindow(candidates, anchor: "RelayKit")
            return false
        } catch VisualFailure.semanticAnchorMissing {
            return true
        } catch {
            return false
        }
    }
    guard strictSelectionIsMissing([semanticRelayCandidate], flow: "connect"),
          strictSelectionIsMissing([strictOldCombinedCandidate], flow: "connect"),
          strictSelectionIsMissing([observationCandidate(frozen, [semanticUsageHit])], flow: "connect"),
          strictSelectionIsMissing([strictDuplicateCandidate], flow: "connect"),
          strictSelectionIsMissing([strictLowConfidenceCandidate], flow: "connect"),
          strictSelectionIsMissing([strictInvalidGeometryCandidate], flow: "connect") else {
        throw VisualFailure.synthetic
    }
    semanticFlowContext = "connect"
    var strictTwoFullAmbiguous = false
    do {
        _ = try selectSemanticWindow([
            strictConnectFullCandidate,
            SemanticCandidate(
                window: frozen,
                hits: [semanticRelayHit, semanticUsageHit],
                imageWidth: 400,
                imageHeight: 300
            )
        ], anchor: "RelayKit")
    } catch VisualFailure.semanticAnchorAmbiguous {
        strictTwoFullAmbiguous = true
    }
    guard strictTwoFullAmbiguous else { throw VisualFailure.synthetic }
    let targetHit = TextHit(text: "Advanced", confidence: 0.99, normalized: hit.normalized)
    let targetOnceCandidate = SemanticCandidate(
        window: frozen,
        hits: [semanticRelayHit, targetHit],
        imageWidth: 400,
        imageHeight: 300
    )
    let targetSecondOnceCandidate = SemanticCandidate(
        window: semanticSecondWindow,
        hits: [semanticRelayHit, targetHit],
        imageWidth: 400,
        imageHeight: 300
    )
    let targetDuplicateCandidate = SemanticCandidate(
        window: semanticSecondWindow,
        hits: [semanticRelayHit, targetHit, targetHit],
        imageWidth: 400,
        imageHeight: 300
    )
    let syntheticAmbiguityModes: [(String, AmbiguityMode, Bool)] = [
        ("probe-window", .probeWindow, false),
        ("capture", .capture, false),
        ("click-text", .clickText, true),
        ("outside", .outside, false),
        ("type-text", .typeText, true),
        ("arbitrary-mode", .unsupported, false)
    ]
    for (rawMode, expectedMode, applicable) in syntheticAmbiguityModes {
        let result = ambiguityTargetDiscriminability(
            candidates: [targetOnceCandidate, semanticSecondCandidate],
            mode: rawMode,
            flow: "provider-click-flow",
            label: "Advanced"
        )
        guard result.mode == expectedMode, result.targetLabelApplicable == applicable else {
            throw VisualFailure.synthetic
        }
        if !applicable {
            guard !result.currentTargetAllowlisted,
                  !result.exactlyOneCandidateHasUniqueExactTarget,
                  !result.otherCandidatesHaveTarget else { throw VisualFailure.synthetic }
        }
    }
    let targetUniqueOnly = ambiguityTargetDiscriminability(
        candidates: [targetOnceCandidate, semanticSecondCandidate],
        mode: "click-text",
        flow: "provider-click-flow",
        label: "Advanced"
    )
    let targetUniqueWithOther = ambiguityTargetDiscriminability(
        candidates: [targetOnceCandidate, targetDuplicateCandidate],
        mode: "type-text",
        flow: "provider-click-flow",
        label: "Advanced"
    )
    let targetTwoUnique = ambiguityTargetDiscriminability(
        candidates: [targetOnceCandidate, targetSecondOnceCandidate],
        mode: "click-text",
        flow: "provider-click-flow",
        label: "Advanced"
    )
    let targetDuplicateOnly = ambiguityTargetDiscriminability(
        candidates: [targetDuplicateCandidate, semanticRelayCandidate],
        mode: "click-text",
        flow: "provider-click-flow",
        label: "Advanced"
    )
    guard targetUniqueOnly.currentTargetAllowlisted,
          targetUniqueOnly.exactlyOneCandidateHasUniqueExactTarget,
          !targetUniqueOnly.otherCandidatesHaveTarget,
          targetUniqueWithOther.currentTargetAllowlisted,
          targetUniqueWithOther.exactlyOneCandidateHasUniqueExactTarget,
          targetUniqueWithOther.otherCandidatesHaveTarget,
          !targetTwoUnique.exactlyOneCandidateHasUniqueExactTarget,
          !targetTwoUnique.otherCandidatesHaveTarget,
          !targetDuplicateOnly.exactlyOneCandidateHasUniqueExactTarget,
          !targetDuplicateOnly.otherCandidatesHaveTarget else { throw VisualFailure.synthetic }
    let targetNotAllowlisted = ambiguityTargetDiscriminability(
        candidates: [targetOnceCandidate, semanticSecondCandidate],
        mode: "click-text",
        flow: "connect",
        label: "Advanced"
    )
    guard targetNotAllowlisted.targetLabelApplicable,
          !targetNotAllowlisted.currentTargetAllowlisted,
          !targetNotAllowlisted.exactlyOneCandidateHasUniqueExactTarget,
          !targetNotAllowlisted.otherCandidatesHaveTarget else { throw VisualFailure.synthetic }
    let officialTargetCandidate = SemanticCandidate(
        window: frozen,
        hits: [semanticRelayHit, TextHit(text: "AUTH", confidence: 0.99, normalized: hit.normalized)],
        imageWidth: 400,
        imageHeight: 300
    )
    let officialTarget = ambiguityTargetDiscriminability(
        candidates: [officialTargetCandidate, semanticSecondCandidate],
        mode: "click-text",
        flow: "official-sheet",
        label: "OpenAI Official / Codex Official"
    )
    guard officialTarget.currentTargetAllowlisted,
          officialTarget.exactlyOneCandidateHasUniqueExactTarget,
          !officialTarget.otherCandidatesHaveTarget else { throw VisualFailure.synthetic }
    let syntheticSurfaceMappings: [(String, String, SurfaceProfile)] = [
        ("connect", "capture", .connectRoot),
        ("official-sheet", "probe-window", .connectRoot),
        ("official-light", "click-text", .connectRoot),
        ("official-dark", "capture", .officialSheet),
        ("official-sheet", "type-text", .unsupported),
        ("provider-click-flow", "click-text", .providerForm),
        ("provider-light", "capture", .providerForm),
        ("provider-dark", "capture", .providerForm),
        ("provider-test-failure", "probe-window", .providerForm),
        ("detail", "capture", .providerForm),
        ("detail-advanced-expanded", "click-text", .providerForm),
        ("detail-advanced-collapsed", "click-text", .providerForm),
        ("provider", "capture", .providerForm),
        ("usage", "capture", .usageRoot),
        ("usage-auto-refresh", "probe-window", .usageRoot),
        ("usage-large", "capture", .usageRoot),
        ("usage-1m", "click-text", .usageRoot),
        ("usage-1y", "click-text", .usageRoot),
        ("usage-empty", "capture", .usageRoot),
        ("usage-light", "capture", .usageRoot),
        ("usage-dark", "capture", .usageRoot),
        ("settings", "capture", .settingsRoot),
        ("settings-developer-expanded", "click-text", .settingsRoot),
        ("settings-light", "capture", .settingsRoot),
        ("settings-dark", "capture", .settingsRoot),
        ("outside-click", "probe-window", .outsidePopover),
        ("real-quit", "capture", .realQuit),
        ("import", "capture", .unsupported),
        ("real-demo", "capture", .unsupported),
        ("arbitrary-flow", "arbitrary-mode", .unsupported)
    ]
    for (surfaceFlow, surfaceMode, expectedProfile) in syntheticSurfaceMappings {
        guard surfaceProfile(flow: surfaceFlow, mode: surfaceMode) == expectedProfile else {
            throw VisualFailure.synthetic
        }
    }
    let expectedSurfaceAnchors: [(SurfaceProfile, [String])] = [
        (.connectRoot, ["RelayKit", "Usage"]),
        (.officialSheet, ["AUTH", "OpenAI Official", "Codex Official"]),
        (.providerForm, ["Test connection", "Advanced"]),
        (.usageRoot, ["RelayKit", "Usage", "Today tokens"]),
        (.settingsRoot, ["RelayKit", "Developer / Diagnostics"]),
        (.outsidePopover, ["RelayKit", "Usage"]),
        (.realQuit, ["Quit RelayKit"]),
        (.unsupported, [])
    ]
    guard expectedSurfaceAnchors.allSatisfy({ requiredAnchors(for: $0.0) == $0.1 }),
          expectedSurfaceAnchors.allSatisfy({ requiredAlternativeGroups(for: $0.0).isEmpty }),
          expectedSurfaceAnchors.dropLast().flatMap({ $0.1 }).allSatisfy(diagnosticSurfaceAnchorIsAllowlisted),
          diagnosticSurfaceAnchorIsAllowlisted("OpenAI Official / Codex Official"),
          !diagnosticSurfaceAnchorIsAllowlisted("Arbitrary diagnostic anchor") else {
        throw VisualFailure.synthetic
    }
    let makeSurfaceCandidate: (WindowIdentity, [TextHit]) -> SemanticCandidate = { window, hits in
        SemanticCandidate(window: window, hits: hits, imageWidth: 400, imageHeight: 300)
    }
    for (profile, anchors) in expectedSurfaceAnchors.dropLast() {
        let alternativeGroups = requiredAlternativeGroups(for: profile)
        let fullHits = (anchors + alternativeGroups.compactMap { $0.first }).map {
            TextHit(text: $0, confidence: 0.99, normalized: hit.normalized)
        }
        let full = makeSurfaceCandidate(frozen, fullHits)
        let secondFull = makeSurfaceCandidate(semanticSecondWindow, fullHits)
        let partial = makeSurfaceCandidate(semanticSecondWindow, Array(fullHits.dropLast()))
        let flowAndMode: (String, String)
        switch profile {
        case .connectRoot: flowAndMode = ("connect", "capture")
        case .officialSheet: flowAndMode = ("official-sheet", "capture")
        case .providerForm: flowAndMode = ("provider-click-flow", "click-text")
        case .usageRoot: flowAndMode = ("usage", "capture")
        case .settingsRoot: flowAndMode = ("settings", "capture")
        case .outsidePopover: flowAndMode = ("outside-click", "probe-window")
        case .realQuit: flowAndMode = ("real-quit", "capture")
        case .unsupported: throw VisualFailure.synthetic
        }
        let oneMatch = surfaceProfileDiscriminability(
            candidates: [full, partial], mode: flowAndMode.1, flow: flowAndMode.0
        )
        let twoMatches = surfaceProfileDiscriminability(
            candidates: [full, secondFull], mode: flowAndMode.1, flow: flowAndMode.0
        )
        let zeroMatches = surfaceProfileDiscriminability(
            candidates: [partial], mode: flowAndMode.1, flow: flowAndMode.0
        )
        guard oneMatch.profile == profile, oneMatch.allRequiredAnchorsAllowlisted,
              oneMatch.exactlyOneCandidateMatchesAllRequiredExactAnchors,
              !oneMatch.otherCandidatesMatchAll,
              oneMatch.profileHasRequiredAlternativeGroup == !alternativeGroups.isEmpty,
              oneMatch.atLeastOneCandidateSatisfiesAllRequiredAlternativeGroups,
              !twoMatches.exactlyOneCandidateMatchesAllRequiredExactAnchors,
              twoMatches.otherCandidatesMatchAll,
              !zeroMatches.exactlyOneCandidateMatchesAllRequiredExactAnchors,
              !zeroMatches.otherCandidatesMatchAll,
              zeroMatches.atLeastOneCandidateSatisfiesAllRequiredAlternativeGroups == alternativeGroups.isEmpty else {
            throw VisualFailure.synthetic
        }
    }
    let connectAnchors = requiredAnchors(for: .connectRoot)
    let duplicateAnchorHits = [
        TextHit(text: connectAnchors[0], confidence: 0.99, normalized: hit.normalized),
        TextHit(text: connectAnchors[0], confidence: 0.99, normalized: hit.normalized),
        TextHit(text: "OpenAI Official", confidence: 0.99, normalized: hit.normalized)
    ]
    let lowAnchorHits = [
        TextHit(text: connectAnchors[0], confidence: 0.79, normalized: hit.normalized),
        TextHit(text: "OpenAI Official", confidence: 0.99, normalized: hit.normalized)
    ]
    let invalidGeometryHits = [
        TextHit(text: connectAnchors[0], confidence: 0.99, normalized: CGRect(x: 0.95, y: 0.2, width: 0.2, height: 0.1)),
        TextHit(text: "OpenAI Official", confidence: 0.99, normalized: hit.normalized)
    ]
    for rejected in [duplicateAnchorHits, lowAnchorHits, invalidGeometryHits] {
        let result = surfaceProfileDiscriminability(
            candidates: [makeSurfaceCandidate(frozen, rejected)],
            mode: "capture",
            flow: "connect"
        )
        guard result.allRequiredAnchorsAllowlisted,
              !result.exactlyOneCandidateMatchesAllRequiredExactAnchors,
              !result.otherCandidatesMatchAll else { throw VisualFailure.synthetic }
    }
    let surfaceGroupFixtures: [([TextHit], Bool)] = [
        ([
            TextHit(text: "RelayKit", confidence: 0.99, normalized: hit.normalized),
            TextHit(text: "Usage", confidence: 0.99, normalized: hit.normalized)
        ], true),
        ([
            TextHit(text: "RelayKit", confidence: 0.99, normalized: hit.normalized),
            TextHit(text: "OpenAI Official", confidence: 0.99, normalized: hit.normalized),
            TextHit(text: "Codex Official", confidence: 0.99, normalized: hit.normalized)
        ], false),
        ([TextHit(text: "RelayKit", confidence: 0.99, normalized: hit.normalized)], false),
        ([TextHit(text: "Usage", confidence: 0.99, normalized: hit.normalized)], false),
        ([
            TextHit(text: "RelayKit", confidence: 0.99, normalized: hit.normalized),
            TextHit(text: "OpenAI Official / Codex Official", confidence: 0.99, normalized: hit.normalized)
        ], false),
        ([
            TextHit(text: "RelayKit", confidence: 0.99, normalized: hit.normalized),
            TextHit(text: "Usage", confidence: 0.99, normalized: hit.normalized),
            TextHit(text: "Usage", confidence: 0.99, normalized: hit.normalized)
        ], false),
        ([
            TextHit(text: "RelayKit", confidence: 0.99, normalized: hit.normalized),
            TextHit(text: "Usage", confidence: 0.79, normalized: hit.normalized)
        ], false),
        ([
            TextHit(text: "RelayKit", confidence: 0.99, normalized: hit.normalized),
            TextHit(text: "Usage", confidence: 0.99, normalized: CGRect(x: 0.95, y: 0.2, width: 0.2, height: 0.1))
        ], false)
    ]
    for (hits, fullProfileMatch) in surfaceGroupFixtures {
        let result = surfaceProfileDiscriminability(
            candidates: [makeSurfaceCandidate(frozen, hits)], mode: "capture", flow: "connect"
        )
        guard !result.profileHasRequiredAlternativeGroup,
              result.exactlyOneCandidateMatchesAllRequiredExactAnchors == fullProfileMatch,
              !result.otherCandidatesMatchAll,
              result.atLeastOneCandidateSatisfiesAllRequiredAlternativeGroups else {
            throw VisualFailure.synthetic
        }
    }
    let unsupportedSurface = surfaceProfileDiscriminability(
        candidates: [targetOnceCandidate], mode: "capture", flow: "import"
    )
    guard unsupportedSurface.profile == .unsupported,
          !unsupportedSurface.allRequiredAnchorsAllowlisted,
          !unsupportedSurface.exactlyOneCandidateMatchesAllRequiredExactAnchors,
          !unsupportedSurface.otherCandidatesMatchAll,
          !unsupportedSurface.profileHasRequiredAlternativeGroup,
          unsupportedSurface.atLeastOneCandidateSatisfiesAllRequiredAlternativeGroups else {
        throw VisualFailure.synthetic
    }
    let syntheticSemanticFlowAnchorMatrix = [
        "connect", "official-sheet", "official-light", "official-dark", "real-demo",
        "provider-click-flow", "provider-light", "provider-dark", "provider-test-failure",
        "detail", "detail-advanced-expanded", "detail-advanced-collapsed", "import",
        "usage", "usage-auto-refresh", "usage-large", "usage-1m", "usage-1y", "usage-empty",
        "settings", "settings-developer-expanded", "settings-light", "usage-light",
        "settings-dark", "usage-dark", "provider", "outside-click"
    ]
    for semanticFlow in syntheticSemanticFlowAnchorMatrix {
        guard try semanticAnchor(flow: semanticFlow) == "RelayKit" else { throw VisualFailure.synthetic }
    }
    guard try semanticAnchor(flow: "real-quit") == "Quit RelayKit" else { throw VisualFailure.synthetic }
    semanticFlowContext = "provider"
    let semanticSelected = try selectSemanticWindow([semanticRelayCandidate], anchor: "RelayKit")
    guard semanticSelected.id == frozen.id else { throw VisualFailure.synthetic }
    var syntheticSemanticAnchorMissing = false
    do {
        _ = try selectSemanticWindow([
            SemanticCandidate(window: frozen, hits: [anchorHit("Unclassified public fixture")], imageWidth: 400, imageHeight: 300)
        ], anchor: "RelayKit")
    } catch VisualFailure.semanticAnchorMissing { syntheticSemanticAnchorMissing = true }
    guard syntheticSemanticAnchorMissing else { throw VisualFailure.synthetic }
    var syntheticSemanticAnchorDuplicate = false
    do {
        _ = try selectSemanticWindow([
            SemanticCandidate(window: frozen, hits: [semanticRelayHit, semanticRelayHit], imageWidth: 400, imageHeight: 300)
        ], anchor: "RelayKit")
    } catch VisualFailure.semanticAnchorDuplicate { syntheticSemanticAnchorDuplicate = true }
    guard syntheticSemanticAnchorDuplicate else { throw VisualFailure.synthetic }
    var syntheticSemanticAnchorAmbiguous = false
    do {
        _ = try selectSemanticWindow([semanticRelayCandidate, semanticSecondCandidate], anchor: "RelayKit")
    } catch VisualFailure.semanticAnchorAmbiguous { syntheticSemanticAnchorAmbiguous = true }
    guard syntheticSemanticAnchorAmbiguous else { throw VisualFailure.synthetic }
    var syntheticSemanticOCREmpty = false
    do {
        _ = try selectSemanticWindow([
            SemanticCandidate(window: frozen, hits: [], imageWidth: 400, imageHeight: 300)
        ], anchor: "RelayKit")
    } catch VisualFailure.semanticOCREmpty { syntheticSemanticOCREmpty = true }
    guard syntheticSemanticOCREmpty else { throw VisualFailure.synthetic }
    var syntheticSemanticCaptureUnavailable = false
    do {
        try requireSemanticCaptureAvailable(syntheticZero != 0)
    } catch VisualFailure.semanticCaptureUnavailable { syntheticSemanticCaptureUnavailable = true }
    guard syntheticSemanticCaptureUnavailable else { throw VisualFailure.synthetic }
    var syntheticSemanticIdentityOrGeometry = false
    do {
        _ = try selectSemanticWindow([], anchor: "RelayKit")
    } catch VisualFailure.semanticIdentityOrGeometry { syntheticSemanticIdentityOrGeometry = true }
    guard syntheticSemanticIdentityOrGeometry else { throw VisualFailure.synthetic }
    semanticFlowContext = "real-quit"
    let syntheticSemanticRealQuit = try selectSemanticWindow([
        SemanticCandidate(window: frozen, hits: [semanticQuitHit], imageWidth: 400, imageHeight: 300)
    ], anchor: "Quit RelayKit")
    guard syntheticSemanticRealQuit.id == frozen.id else { throw VisualFailure.synthetic }
    semanticFlowContext = "provider"
    let syntheticSemanticProbeActionParity = (
        probe: try selectSemanticWindow([semanticRelayCandidate], anchor: "RelayKit"),
        action: try selectSemanticWindow([semanticRelayCandidate], anchor: "RelayKit")
    )
    guard syntheticSemanticProbeActionParity.probe.id == syntheticSemanticProbeActionParity.action.id else {
        throw VisualFailure.synthetic
    }
    let syntheticSemanticProbeCounts = (events: syntheticZero, writes: syntheticZero, temporaryFiles: syntheticZero)
    guard syntheticSemanticProbeCounts.events == 0, syntheticSemanticProbeCounts.writes == 0,
          syntheticSemanticProbeCounts.temporaryFiles == 0 else { throw VisualFailure.synthetic }
    let syntheticEquivalenceAllEqual = WindowEquivalenceResult(
        samePointBounds: true,
        samePixelDimensions: true,
        samePixelSHA256: true,
        sameExactAnchorNormalizedBBox: true,
        sameAbsoluteAnchorCenter: true,
        sameBackingScale: true,
        allRevalidateStable: true
    )
    var syntheticTemporalAll = TemporalSemanticState()
    [0, 1, 2].forEach { syntheticTemporalAll.record($0) }
    guard syntheticTemporalAll.sawZero, syntheticTemporalAll.sawOne,
          syntheticTemporalAll.sawMultiple, syntheticTemporalAll.sawTransition else {
        throw VisualFailure.synthetic
    }
    var syntheticTemporalImmediate = TemporalSemanticState()
    syntheticTemporalImmediate.record(2)
    guard !syntheticTemporalImmediate.sawZero, !syntheticTemporalImmediate.sawOne,
          syntheticTemporalImmediate.sawMultiple, !syntheticTemporalImmediate.sawTransition else {
        throw VisualFailure.synthetic
    }
    var syntheticTemporalNeverMultiple = TemporalSemanticState()
    for _ in 0..<120 { syntheticTemporalNeverMultiple.record(1) }
    guard !syntheticTemporalNeverMultiple.sawZero, syntheticTemporalNeverMultiple.sawOne,
          !syntheticTemporalNeverMultiple.sawMultiple, !syntheticTemporalNeverMultiple.sawTransition else {
        throw VisualFailure.synthetic
    }
    var syntheticTemporalAdjacentTransition = TemporalSemanticState()
    [0, 0, 1, 1, 0].forEach { syntheticTemporalAdjacentTransition.record($0) }
    guard syntheticTemporalAdjacentTransition.sawZero, syntheticTemporalAdjacentTransition.sawOne,
          !syntheticTemporalAdjacentTransition.sawMultiple,
          syntheticTemporalAdjacentTransition.sawTransition else { throw VisualFailure.synthetic }
    let expectedAllEqualSchema = [
        "DIAG_VALID=true",
        "saw_zero=true",
        "saw_one=true",
        "saw_multiple=true",
        "saw_transition=true",
        "same_point_bounds=true",
        "same_pixel_dimensions=true",
        "same_pixel_sha256=true",
        "same_exact_anchor_normalized_bbox=true",
        "same_absolute_anchor_center=true",
        "same_backing_scale=true",
        "all_revalidate_stable=true"
    ].joined(separator: "\n")
    guard windowEquivalenceDiagnosticSchema(
        syntheticEquivalenceAllEqual,
        temporal: syntheticTemporalAll
    ) == expectedAllEqualSchema else {
        throw VisualFailure.synthetic
    }
    let expectedOutsideAllEqualSchema = (
        ["DIAG_VALID=true"] + expectedAllEqualSchema.split(separator: "\n").dropFirst(5).map(String.init)
    ).joined(separator: "\n")
    guard outsideWindowEquivalenceDiagnosticSchema(syntheticEquivalenceAllEqual) == expectedOutsideAllEqualSchema,
          outsideWindowEquivalenceInvalidDiagnostic(.outsideSemanticAmbiguityNotObserved).schema ==
            "DIAG_VALID=false\nDIAG_REASON=outside-semantic-ambiguity-not-observed" else {
        throw VisualFailure.synthetic
    }
    let expectedFirstAmbiguitySchema = ([
        "DIAG_VALID=true",
        "AMBIGUITY_MODE=click-text",
        "target_label_applicable=true",
        "current_target_allowlisted=true",
        "exactly_one_candidate_has_unique_exact_target=true",
        "other_candidates_have_target=false",
        "SURFACE_PROFILE=provider-form",
        "all_required_anchors_allowlisted=true",
        "exactly_one_candidate_matches_all_required_exact_anchors=false",
        "other_candidates_match_all=false",
        "profile_has_required_alternative_group=false",
        "at_least_one_candidate_satisfies_all_required_alternative_groups=true"
    ] + expectedOutsideAllEqualSchema.split(separator: "\n").dropFirst().map(String.init)).joined(separator: "\n")
    let syntheticSurfaceForSchema = surfaceProfileDiscriminability(
        candidates: [targetOnceCandidate, semanticSecondCandidate],
        mode: "click-text",
        flow: "provider-click-flow"
    )
    guard firstAmbiguityWindowEquivalenceDiagnosticSchema(
        syntheticEquivalenceAllEqual,
        discriminability: targetUniqueOnly,
        surface: syntheticSurfaceForSchema
    ) == expectedFirstAmbiguitySchema,
    !expectedFirstAmbiguitySchema.contains("provider-click-flow"),
    !expectedFirstAmbiguitySchema.contains("Advanced") else { throw VisualFailure.synthetic }
    let syntheticEquivalenceEachFalse = (0..<7).map { index in
        WindowEquivalenceResult(
            samePointBounds: index != 0,
            samePixelDimensions: index != 1,
            samePixelSHA256: index != 2,
            sameExactAnchorNormalizedBBox: index != 3,
            sameAbsoluteAnchorCenter: index != 4,
            sameBackingScale: index != 5,
            allRevalidateStable: index != 6
        )
    }
    for result in syntheticEquivalenceEachFalse {
        let schema = windowEquivalenceDiagnosticSchema(result, temporal: syntheticTemporalAll)
        guard schema.split(separator: "\n").filter({ $0.hasSuffix("=false") }).count == 1 else {
            throw VisualFailure.synthetic
        }
    }
    func syntheticEquivalenceObservation(changed index: Int? = nil) -> WindowEquivalenceObservation {
        WindowEquivalenceObservation(
            pointBounds: index == 0 ? CGRect(x: 101, y: 200, width: 400, height: 300) : bounds,
            pixelWidth: index == 1 ? 401 : 400,
            pixelHeight: 300,
            pixelSHA256: index == 2 ? Data([9, 9, 9]) : Data([1, 2, 3]),
            exactAnchorNormalizedBBox: index == 3
                ? CGRect(x: 0.26, y: 0.20, width: 0.20, height: 0.10)
                : hit.normalized,
            absoluteAnchorCenter: index == 4 ? CGPoint(x: 181, y: 425) : CGPoint(x: 180, y: 425),
            backingScaleX: index == 5 ? 2 : 1,
            backingScaleY: 1,
            revalidationStable: index != 6
        )
    }
    let baseEquivalenceObservation = syntheticEquivalenceObservation()
    let syntheticEquivalenceZeroInvalid = allCandidateWindowEquivalence([])
    let syntheticEquivalenceOneInvalid = allCandidateWindowEquivalence([baseEquivalenceObservation])
    guard syntheticEquivalenceZeroInvalid == nil, syntheticEquivalenceOneInvalid == nil else {
        throw VisualFailure.synthetic
    }
    let syntheticEquivalenceTwoAllEqual = allCandidateWindowEquivalence([
        baseEquivalenceObservation, baseEquivalenceObservation
    ])
    let syntheticEquivalenceThreeAllEqual = allCandidateWindowEquivalence([
        baseEquivalenceObservation, baseEquivalenceObservation, baseEquivalenceObservation
    ])
    guard syntheticEquivalenceTwoAllEqual == syntheticEquivalenceAllEqual,
          syntheticEquivalenceThreeAllEqual == syntheticEquivalenceAllEqual else { throw VisualFailure.synthetic }
    let syntheticEquivalenceThreeEachFalse = (0..<7).compactMap { index in
        allCandidateWindowEquivalence([
            baseEquivalenceObservation,
            baseEquivalenceObservation,
            syntheticEquivalenceObservation(changed: index)
        ])
    }
    guard syntheticEquivalenceThreeEachFalse.count == 7 else { throw VisualFailure.synthetic }
    for result in syntheticEquivalenceThreeEachFalse {
        let booleans = [
            result.samePointBounds, result.samePixelDimensions, result.samePixelSHA256,
            result.sameExactAnchorNormalizedBBox, result.sameAbsoluteAnchorCenter,
            result.sameBackingScale, result.allRevalidateStable
        ]
        guard booleans.filter({ !$0 }).count == 1 else { throw VisualFailure.synthetic }
    }
    let syntheticEquivalenceMemberStale = syntheticEquivalenceThreeEachFalse[6]
    guard !syntheticEquivalenceMemberStale.allRevalidateStable else { throw VisualFailure.synthetic }
    let syntheticEquivalencePermutationInvariant = (0..<7).allSatisfy { index in
        let changed = syntheticEquivalenceObservation(changed: index)
        return allCandidateWindowEquivalence([baseEquivalenceObservation, changed, baseEquivalenceObservation])
            == allCandidateWindowEquivalence([changed, baseEquivalenceObservation, baseEquivalenceObservation])
    }
    guard syntheticEquivalencePermutationInvariant else { throw VisualFailure.synthetic }
    let syntheticEquivalenceInvalidCardinality = [syntheticEquivalenceZeroInvalid, syntheticEquivalenceOneInvalid]
    let cardinalityInvalidSchema = windowEquivalenceInvalidSchema(
        reason: .semanticCandidateCardinality,
        temporal: syntheticTemporalNeverMultiple
    )
    guard syntheticEquivalenceInvalidCardinality.allSatisfy({ $0 == nil }),
          cardinalityInvalidSchema == "DIAG_VALID=false\nDIAG_REASON=semantic-candidate-cardinality\nsaw_zero=false\nsaw_one=true\nsaw_multiple=false\nsaw_transition=false" else {
        throw VisualFailure.synthetic
    }
    let syntheticEquivalenceNeverMultiple = windowEquivalenceInvalidSchema(
        reason: .semanticMultipleNotObserved,
        temporal: syntheticTemporalNeverMultiple
    )
    guard syntheticEquivalenceNeverMultiple == "DIAG_VALID=false\nDIAG_REASON=semantic-multiple-not-observed\nsaw_zero=false\nsaw_one=true\nsaw_multiple=false\nsaw_transition=false" else {
        throw VisualFailure.synthetic
    }
    let syntheticEquivalenceStale = windowEquivalenceInvalidSchema(
        reason: .revalidationFailed,
        temporal: syntheticTemporalAll
    )
    guard syntheticEquivalenceStale == "DIAG_VALID=false\nDIAG_REASON=revalidation-failed\nsaw_zero=true\nsaw_one=true\nsaw_multiple=true\nsaw_transition=true" else {
        throw VisualFailure.synthetic
    }
    let syntheticEquivalenceInvalidReasons = WindowEquivalenceInvalidReason.allCases.map {
        windowEquivalenceInvalidSchema(reason: $0, temporal: syntheticTemporalAll)
    }
    guard syntheticEquivalenceInvalidReasons.count == 12,
          syntheticEquivalenceInvalidReasons.allSatisfy({
              $0.split(separator: "\n").count == 6 && $0.hasPrefix("DIAG_VALID=false\nDIAG_REASON=")
          }) else { throw VisualFailure.synthetic }
    let syntheticEquivalenceUnknownFallback = windowEquivalenceInvalidReason(
        for: NSError(domain: "public.synthetic", code: 1)
    )
    guard syntheticEquivalenceUnknownFallback == .internal else { throw VisualFailure.synthetic }
    let syntheticEquivalenceValidNoReason = windowEquivalenceDiagnosticSchema(
        syntheticEquivalenceAllEqual,
        temporal: syntheticTemporalAll
    )
    guard !syntheticEquivalenceValidNoReason.contains("DIAG_REASON=") else { throw VisualFailure.synthetic }
    let syntheticEquivalenceSchemaPrivacy = [expectedAllEqualSchema] + syntheticEquivalenceInvalidReasons
    let allowedSchemaKeys: Set<String> = [
        "DIAG_VALID", "same_point_bounds", "same_pixel_dimensions", "same_pixel_sha256",
        "same_exact_anchor_normalized_bbox", "same_absolute_anchor_center", "same_backing_scale",
        "all_revalidate_stable", "saw_zero", "saw_one", "saw_multiple", "saw_transition", "DIAG_REASON"
    ]
    let allowedReasons = Set(WindowEquivalenceInvalidReason.allCases.map { $0.rawValue })
    for schema in syntheticEquivalenceSchemaPrivacy {
        for line in schema.split(separator: "\n") {
            let pair = line.split(separator: "=", maxSplits: 1)
            guard pair.count == 2, allowedSchemaKeys.contains(String(pair[0])) else { throw VisualFailure.synthetic }
            if pair[0] == "DIAG_REASON" {
                guard allowedReasons.contains(String(pair[1])) else { throw VisualFailure.synthetic }
            } else {
                guard pair[1] == "true" || pair[1] == "false" else { throw VisualFailure.synthetic }
            }
        }
    }
    for stale in [
        WindowIdentity(pid: 8, executable: frozen.executable, id: frozen.id, bounds: bounds),
        WindowIdentity(pid: frozen.pid, executable: "/wrong", id: frozen.id, bounds: bounds),
        WindowIdentity(pid: frozen.pid, executable: frozen.executable, id: 10, bounds: bounds),
        WindowIdentity(pid: frozen.pid, executable: frozen.executable, id: frozen.id, bounds: CGRect(x: 101, y: 200, width: 400, height: 300))
    ] {
        var rejected = false
        do {
            try validateIdentity(7, "/public/RelayKitApp.bin", stale, frozen)
        } catch { rejected = true }
        guard rejected else { throw VisualFailure.synthetic }
    }
    var successPath = ""
    _ = try withTemporaryCapture { url in successPath = url.path; return 0 }
    guard !FileManager.default.fileExists(atPath: successPath) else { throw VisualFailure.synthetic }
    var failurePath = ""
    var bodyFailurePreserved = false
    do {
        _ = try withTemporaryCapture { url -> Int in failurePath = url.path; throw VisualFailure.synthetic }
    } catch VisualFailure.synthetic { bodyFailurePreserved = true }
    guard bodyFailurePreserved, !FileManager.default.fileExists(atPath: failurePath) else { throw VisualFailure.synthetic }
    guard allowed(label: "OpenAI Official", flow: "official-sheet"),
          allowed(label: "Codex Official", flow: "official-sheet"),
          !allowed(label: "arbitrary public-looking label", flow: "official-sheet"),
          allowedInput("relaykit-ui-smoke-key"),
          !allowedInput("unreviewed-input") else {
        throw VisualFailure.synthetic
    }
    let privateDirectory = "/private/tmp/relaykit-window-diag.\(UUID().uuidString)"
    guard mkdir(privateDirectory, 0o700) == 0 else { throw VisualFailure.synthetic }
    let privateFiles = [
        "\(privateDirectory)/window-0000.png",
        "\(privateDirectory)/window-0001.png"
    ]
    defer {
        for path in privateFiles { _ = unlink(path) }
        _ = rmdir(privateDirectory)
    }
    let privatePixels = Data(repeating: 0xff, count: 16)
    guard let privateProvider = CGDataProvider(data: privatePixels as CFData),
          let privateImage = CGImage(
              width: 2,
              height: 2,
              bitsPerComponent: 8,
              bitsPerPixel: 32,
              bytesPerRow: 8,
              space: CGColorSpaceCreateDeviceRGB(),
              bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
              provider: privateProvider,
              decode: nil,
              shouldInterpolate: false,
              intent: .defaultIntent
          ) else { throw VisualFailure.synthetic }
    let privateCandidates = [
        SemanticCandidate(window: frozen, hits: [semanticRelayHit], imageWidth: 2, imageHeight: 2, image: privateImage),
        SemanticCandidate(window: semanticSecondWindow, hits: [semanticRelayHit], imageWidth: 2, imageHeight: 2, image: privateImage)
    ]
    try writePrivateAmbiguityPNGs(candidates: privateCandidates, directory: privateDirectory)
    let privateEntries = try FileManager.default.contentsOfDirectory(atPath: privateDirectory).sorted()
    guard privateEntries == ["window-0000.png", "window-0001.png"] else { throw VisualFailure.synthetic }
    for path in privateFiles {
        var status = stat()
        guard lstat(path, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFREG,
              status.st_uid == getuid(),
              (status.st_mode & 0o777) == 0o600 else { throw VisualFailure.synthetic }
    }
    print("Visual action synthetic contract passed")
}

func canonical(_ path: String) -> String {
    URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
}

func executablePath(pid: Int32) throws -> String {
    var buffer = [CChar](repeating: 0, count: 4096)
    guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { throw VisualFailure.windowIdentity }
    return canonical(String(cString: buffer))
}

func windowItems(pid: Int32, expectedExecutable: String) throws -> [[String: Any]] {
    guard kill(pid, 0) == 0, try executablePath(pid: pid) == canonical(expectedExecutable),
          let raw = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
        throw VisualFailure.windowIdentity
    }
    return raw
}

func captureableWindowIDs() throws -> Set<CGWindowID> {
    let semaphore = DispatchSemaphore(value: 0)
    var ids: Set<CGWindowID>?
    Task {
        defer { semaphore.signal() }
        guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true) else {
            return
        }
        ids = Set(content.windows.map { $0.windowID })
    }
    guard semaphore.wait(timeout: .now() + 10) == .success else {
        throw VisualFailure.captureableContentUnavailable
    }
    return try requiredCaptureableWindowIDs(ids)
}

func selectedCaptureableWindowInfo(pid: Int32, expectedExecutable: String) throws -> WindowIdentity {
    let expected = canonical(expectedExecutable)
    let eligible = eligibleWindowIdentities(
        try windowItems(pid: pid, expectedExecutable: expectedExecutable),
        pid: pid,
        expectedExecutable: expected
    )
    let windows = captureableEligibleWindowIdentities(eligible, captureableIDs: try captureableWindowIDs())
    return try selectEligibleWindow(windows, pid: pid, expectedExecutable: expected)
}

func semanticAnchor(flow: String) throws -> String {
    switch flow {
    case "real-quit":
        return "Quit RelayKit"
    case "connect", "official-sheet", "official-light", "official-dark", "real-demo",
         "provider-click-flow", "provider-light", "provider-dark", "provider-test-failure",
         "detail", "detail-advanced-expanded", "detail-advanced-collapsed", "import",
         "usage", "usage-auto-refresh", "usage-large", "usage-1m", "usage-1y", "usage-empty",
         "settings", "settings-developer-expanded", "settings-light", "usage-light",
         "settings-dark", "usage-dark", "provider", "outside-click":
        return "RelayKit"
    default:
        throw VisualFailure.labelContract
    }
}

func requireSemanticCaptureAvailable(_ available: Bool) throws {
    guard available else { throw VisualFailure.semanticCaptureUnavailable }
}

func captureSemanticCandidate(_ window: WindowIdentity) throws -> SemanticCandidate {
    let image: CGImage
    do {
        image = try capture(window)
    } catch VisualFailure.geometry {
        throw VisualFailure.semanticIdentityOrGeometry
    } catch {
        throw VisualFailure.semanticCaptureUnavailable
    }
    let hits: [TextHit]
    do {
        hits = try recognizedText(image)
    } catch {
        throw VisualFailure.semanticOCREmpty
    }
    return SemanticCandidate(window: window, hits: hits, imageWidth: image.width, imageHeight: image.height, image: image)
}

func semanticMatches(_ candidates: [SemanticCandidate], anchor: String) throws -> [SemanticMatch] {
    guard !candidates.isEmpty else { throw VisualFailure.semanticIdentityOrGeometry }
    var matching: [SemanticMatch] = []
    for candidate in candidates {
        guard candidate.window.id != 0, candidate.window.bounds.width > 0, candidate.window.bounds.height > 0,
              candidate.imageWidth > 0, candidate.imageHeight > 0 else {
            throw VisualFailure.semanticIdentityOrGeometry
        }
        guard !candidate.hits.isEmpty else { throw VisualFailure.semanticOCREmpty }
        let exact = candidate.hits.filter { $0.text == anchor }
        guard exact.count <= 1 else { throw VisualFailure.semanticAnchorDuplicate }
        guard let hit = exact.first else { continue }
        guard hit.confidence >= 0.80 else { continue }
        let rect: CGRect
        do {
            rect = try screenRect(
                hit: hit,
                imageWidth: candidate.imageWidth,
                imageHeight: candidate.imageHeight,
                bounds: candidate.window.bounds
            )
        } catch {
            throw VisualFailure.semanticIdentityOrGeometry
        }
        guard candidate.window.bounds.contains(rect) else { throw VisualFailure.semanticIdentityOrGeometry }
        matching.append(SemanticMatch(
            candidate: candidate,
            normalizedAnchorBounds: hit.normalized,
            absoluteAnchorCenter: CGPoint(x: rect.midX, y: rect.midY)
        ))
    }
    return matching
}

func selectSemanticWindow(_ candidates: [SemanticCandidate], anchor: String) throws -> WindowIdentity {
    if ProcessInfo.processInfo.environment["RELAYKIT_WINDOW_EQUIVALENCE_DIAGNOSTIC_TARGET"] == "connect-root-anchor-observations",
       semanticFlowContext == "connect",
       semanticVisualModeContext == "probe-window" {
        let diagnostic = connectRootAnchorObservationDiagnostic(candidates: candidates)
        print(connectRootAnchorObservationSchema(diagnostic))
        exit(100)
    }
    if ProcessInfo.processInfo.environment["RELAYKIT_WINDOW_EQUIVALENCE_DIAGNOSTIC_TARGET"] == "connect-root-public-anchor-candidates",
       semanticFlowContext == "connect",
       semanticVisualModeContext == "probe-window" {
        let diagnostic = connectRootPublicAnchorCandidatesDiagnostic(candidates: candidates)
        print(connectRootPublicAnchorCandidatesSchema(diagnostic))
        exit(101)
    }
    let profile = surfaceProfile(flow: semanticFlowContext, mode: semanticVisualModeContext)
    switch profile {
    case .connectRoot, .outsidePopover:
        let required = requiredAnchors(for: profile)
        let matching = candidates.filter {
            candidateMatchesAllRequiredExactAnchors($0, anchors: required)
        }
        guard !matching.isEmpty else { throw VisualFailure.semanticAnchorMissing }
        guard matching.count == 1 else { throw VisualFailure.semanticAnchorAmbiguous }
        return matching[0].window
    default:
        break
    }
    let matching = try semanticMatches(candidates, anchor: anchor)
    guard !matching.isEmpty else { throw VisualFailure.semanticAnchorMissing }
    guard matching.count == 1 else { throw VisualFailure.semanticAnchorAmbiguous }
    return matching[0].candidate.window
}

func semanticCandidates(pid: Int32, expectedExecutable: String) throws -> [SemanticCandidate] {
    let expected = canonical(expectedExecutable)
    let items: [[String: Any]]
    do {
        items = try windowItems(pid: pid, expectedExecutable: expectedExecutable)
    } catch {
        throw VisualFailure.semanticIdentityOrGeometry
    }
    let eligible = eligibleWindowIdentities(items, pid: pid, expectedExecutable: expected)
    guard !eligible.isEmpty else { throw VisualFailure.semanticIdentityOrGeometry }
    let windows = captureableEligibleWindowIdentities(eligible, captureableIDs: try captureableWindowIDs())
    guard !windows.isEmpty else { throw VisualFailure.semanticIdentityOrGeometry }
    return try windows.map { try captureSemanticCandidate($0) }
}

func selectedSemanticWindowInfo(pid: Int32, expectedExecutable: String, flow: String) throws -> WindowIdentity {
    let anchor = try semanticAnchor(flow: flow)
    return try selectSemanticWindow(
        try semanticCandidates(pid: pid, expectedExecutable: expectedExecutable),
        anchor: anchor
    )
}

func rgbaData(_ image: CGImage) throws -> Data {
    let width = image.width
    let height = image.height
    guard width > 0, height > 0 else { throw VisualFailure.semanticCaptureUnavailable }
    var data = Data(count: width * height * 4)
    let rendered = data.withUnsafeMutableBytes { bytes -> Bool in
        guard let baseAddress = bytes.baseAddress,
              let context = CGContext(
                data: baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
              ) else { return false }
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return true
    }
    guard rendered else { throw VisualFailure.semanticCaptureUnavailable }
    return data
}

func allSemanticWindowsStable(
    _ frozen: [WindowIdentity],
    pid: Int32,
    expectedExecutable: String
) -> Bool {
    do {
        let expected = canonical(expectedExecutable)
        let eligible = eligibleWindowIdentities(
            try windowItems(pid: pid, expectedExecutable: expectedExecutable),
            pid: pid,
            expectedExecutable: expected
        )
        let current = captureableEligibleWindowIdentities(eligible, captureableIDs: try captureableWindowIDs())
        guard current.count == frozen.count else { return false }
        for original in frozen {
            let exact = current.filter { $0.id == original.id }
            guard exact.count == 1 else { return false }
            try validateIdentity(pid, expected, exact[0], original)
        }
        return true
    } catch {
        return false
    }
}

func windowEquivalenceObservation(
    _ match: SemanticMatch,
    revalidationStable: Bool
) throws -> WindowEquivalenceObservation {
    guard let image = match.candidate.image else { throw VisualFailure.semanticCaptureUnavailable }
    return WindowEquivalenceObservation(
        pointBounds: match.candidate.window.bounds,
        pixelWidth: match.candidate.imageWidth,
        pixelHeight: match.candidate.imageHeight,
        pixelSHA256: Data(SHA256.hash(data: try rgbaData(image))),
        exactAnchorNormalizedBBox: match.normalizedAnchorBounds,
        absoluteAnchorCenter: match.absoluteAnchorCenter,
        backingScaleX: CGFloat(match.candidate.imageWidth) / match.candidate.window.bounds.width,
        backingScaleY: CGFloat(match.candidate.imageHeight) / match.candidate.window.bounds.height,
        revalidationStable: revalidationStable
    )
}

func allCandidateWindowEquivalence(
    _ observations: [WindowEquivalenceObservation]
) -> WindowEquivalenceResult? {
    guard let reference = observations.first, observations.count >= 2 else { return nil }
    let remaining = observations.dropFirst()
    return WindowEquivalenceResult(
        samePointBounds: remaining.allSatisfy { $0.pointBounds.equalTo(reference.pointBounds) },
        samePixelDimensions: remaining.allSatisfy {
            $0.pixelWidth == reference.pixelWidth && $0.pixelHeight == reference.pixelHeight
        },
        samePixelSHA256: remaining.allSatisfy { $0.pixelSHA256 == reference.pixelSHA256 },
        sameExactAnchorNormalizedBBox: remaining.allSatisfy {
            $0.exactAnchorNormalizedBBox.equalTo(reference.exactAnchorNormalizedBBox)
        },
        sameAbsoluteAnchorCenter: remaining.allSatisfy {
            $0.absoluteAnchorCenter == reference.absoluteAnchorCenter
        },
        sameBackingScale: remaining.allSatisfy {
            $0.backingScaleX == reference.backingScaleX && $0.backingScaleY == reference.backingScaleY
        },
        allRevalidateStable: observations.allSatisfy { $0.revalidationStable }
    )
}

func temporalSemanticSchema(_ state: TemporalSemanticState) -> [String] {
    [
        "saw_zero=\(state.sawZero)",
        "saw_one=\(state.sawOne)",
        "saw_multiple=\(state.sawMultiple)",
        "saw_transition=\(state.sawTransition)"
    ]
}

func windowEquivalenceDiagnosticSchema(
    _ result: WindowEquivalenceResult,
    temporal state: TemporalSemanticState
) -> String {
    return ([
        "DIAG_VALID=true"
    ] + temporalSemanticSchema(state) + [
        "same_point_bounds=\(result.samePointBounds)",
        "same_pixel_dimensions=\(result.samePixelDimensions)",
        "same_pixel_sha256=\(result.samePixelSHA256)",
        "same_exact_anchor_normalized_bbox=\(result.sameExactAnchorNormalizedBBox)",
        "same_absolute_anchor_center=\(result.sameAbsoluteAnchorCenter)",
        "same_backing_scale=\(result.sameBackingScale)",
        "all_revalidate_stable=\(result.allRevalidateStable)"
    ]).joined(separator: "\n")
}

func outsideWindowEquivalenceDiagnosticSchema(_ result: WindowEquivalenceResult) -> String {
    [
        "DIAG_VALID=true",
        "same_point_bounds=\(result.samePointBounds)",
        "same_pixel_dimensions=\(result.samePixelDimensions)",
        "same_pixel_sha256=\(result.samePixelSHA256)",
        "same_exact_anchor_normalized_bbox=\(result.sameExactAnchorNormalizedBBox)",
        "same_absolute_anchor_center=\(result.sameAbsoluteAnchorCenter)",
        "same_backing_scale=\(result.sameBackingScale)",
        "all_revalidate_stable=\(result.allRevalidateStable)"
    ].joined(separator: "\n")
}

func outsideWindowEquivalenceInvalidDiagnostic(
    _ reason: WindowEquivalenceInvalidReason
) -> WindowEquivalenceDiagnosticOutput {
    WindowEquivalenceDiagnosticOutput(
        schema: "DIAG_VALID=false\nDIAG_REASON=\(reason.rawValue)",
        exitCode: 1
    )
}

func windowEquivalenceInvalidSchema(reason: WindowEquivalenceInvalidReason, temporal state: TemporalSemanticState) -> String {
    ([
        "DIAG_VALID=false",
        "DIAG_REASON=\(reason.rawValue)"
    ] + temporalSemanticSchema(state)).joined(separator: "\n")
}

func windowEquivalenceInvalidReason(for error: Error) -> WindowEquivalenceInvalidReason {
    switch error {
    case VisualFailure.captureableContentUnavailable:
        return .captureableContentUnavailable
    case VisualFailure.semanticCaptureUnavailable:
        return .semanticCaptureUnavailable
    case VisualFailure.semanticOCREmpty:
        return .semanticOCREmpty
    case VisualFailure.semanticAnchorMissing:
        return .semanticAnchorMissing
    case VisualFailure.semanticAnchorDuplicate:
        return .semanticAnchorDuplicate
    case VisualFailure.semanticAnchorAmbiguous:
        return .semanticCandidateCardinality
    case VisualFailure.semanticIdentityOrGeometry:
        return .identityOrGeometry
    default:
        return .internal
    }
}

func invalidWindowEquivalenceDiagnostic(
    _ reason: WindowEquivalenceInvalidReason,
    temporal state: TemporalSemanticState
) -> WindowEquivalenceDiagnosticOutput {
    WindowEquivalenceDiagnosticOutput(
        schema: windowEquivalenceInvalidSchema(reason: reason, temporal: state),
        exitCode: 1
    )
}

func windowEquivalenceDiagnostic(
    candidates: [SemanticCandidate],
    pid: Int32,
    expectedExecutable: String,
    flow: String,
    temporal state: TemporalSemanticState
) -> WindowEquivalenceDiagnosticOutput {
    do {
        let anchor = try semanticAnchor(flow: flow)
        let matches = try semanticMatches(candidates, anchor: anchor)
        guard matches.count >= 2 else {
            return invalidWindowEquivalenceDiagnostic(.semanticCandidateCardinality, temporal: state)
        }
        let revalidationStable = allSemanticWindowsStable(
            matches.map { $0.candidate.window },
            pid: pid,
            expectedExecutable: expectedExecutable
        )
        guard revalidationStable else {
            return invalidWindowEquivalenceDiagnostic(.revalidationFailed, temporal: state)
        }
        let observations = try matches.map {
            try windowEquivalenceObservation($0, revalidationStable: revalidationStable)
        }
        guard let result = allCandidateWindowEquivalence(observations) else {
            return invalidWindowEquivalenceDiagnostic(.semanticCandidateCardinality, temporal: state)
        }
        return WindowEquivalenceDiagnosticOutput(
            schema: windowEquivalenceDiagnosticSchema(result, temporal: state),
            exitCode: 0
        )
    } catch {
        return invalidWindowEquivalenceDiagnostic(windowEquivalenceInvalidReason(for: error), temporal: state)
    }
}

func outsideWindowEquivalenceDiagnostic(candidates: [SemanticCandidate], pid: Int32, expectedExecutable: String) throws -> WindowEquivalenceDiagnosticOutput {
    let anchor = try semanticAnchor(flow: "outside-click")
    let matches = try semanticMatches(candidates, anchor: anchor)
    guard matches.count > 1 else {
        return outsideWindowEquivalenceInvalidDiagnostic(.outsideSemanticAmbiguityNotObserved)
    }
    let expected = canonical(expectedExecutable)
    for match in matches {
        try validateIdentity(pid, expected, match.candidate.window)
    }
    let observations = try matches.map {
        try windowEquivalenceObservation($0, revalidationStable: true)
    }
    guard let result = allCandidateWindowEquivalence(observations) else {
        return outsideWindowEquivalenceInvalidDiagnostic(.outsideSemanticAmbiguityNotObserved)
    }
    return WindowEquivalenceDiagnosticOutput(
        schema: outsideWindowEquivalenceDiagnosticSchema(result),
        exitCode: 0
    )
}

func firstAmbiguityWindowEquivalenceDiagnostic(candidates: [SemanticCandidate], pid: Int32, expectedExecutable: String, mode: String, flow: String, label: String) throws -> WindowEquivalenceDiagnosticOutput {
    let anchor = try semanticAnchor(flow: flow)
    let matches = try semanticMatches(candidates, anchor: anchor)
    guard matches.count > 1 else {
        return outsideWindowEquivalenceInvalidDiagnostic(.semanticAmbiguityNotObserved)
    }
    let expected = canonical(expectedExecutable)
    for match in matches {
        try validateIdentity(pid, expected, match.candidate.window)
    }
    let observations = try matches.map {
        try windowEquivalenceObservation($0, revalidationStable: true)
    }
    guard let result = allCandidateWindowEquivalence(observations) else {
        return outsideWindowEquivalenceInvalidDiagnostic(.semanticAmbiguityNotObserved)
    }
    let discriminability = ambiguityTargetDiscriminability(candidates: candidates, mode: mode, flow: flow, label: label)
    let surface = surfaceProfileDiscriminability(candidates: candidates, mode: mode, flow: flow)
    return WindowEquivalenceDiagnosticOutput(
        schema: firstAmbiguityWindowEquivalenceDiagnosticSchema(result, discriminability: discriminability, surface: surface),
        exitCode: 0
    )
}

func temporalWindowEquivalenceDiagnostic(
    pid: Int32,
    expectedExecutable: String,
    flow: String
) -> WindowEquivalenceDiagnosticOutput {
    var state = TemporalSemanticState()
    do {
        let anchor = try semanticAnchor(flow: flow)
        for sample in 0..<120 {
            guard kill(pid, 0) == 0 else {
                return invalidWindowEquivalenceDiagnostic(.identityOrGeometry, temporal: state)
            }
            let candidates = try semanticCandidates(pid: pid, expectedExecutable: expectedExecutable)
            let matches = try semanticMatches(candidates, anchor: anchor)
            state.record(matches.count)
            if matches.count >= 2 {
                return windowEquivalenceDiagnostic(
                    candidates: candidates,
                    pid: pid,
                    expectedExecutable: expectedExecutable,
                    flow: flow,
                    temporal: state
                )
            }
            if sample < 119 {
                usleep(50_000)
            }
        }
        return invalidWindowEquivalenceDiagnostic(.semanticMultipleNotObserved, temporal: state)
    } catch {
        return invalidWindowEquivalenceDiagnostic(windowEquivalenceInvalidReason(for: error), temporal: state)
    }
}

func windowInfo(pid: Int32, expectedExecutable: String) throws -> WindowIdentity {
    return try selectedSemanticWindowInfo(pid: pid, expectedExecutable: expectedExecutable, flow: semanticFlowContext)
}

func probeWindowInfo(pid: Int32, expectedExecutable: String) throws -> WindowIdentity {
    return try selectedSemanticWindowInfo(pid: pid, expectedExecutable: expectedExecutable, flow: semanticFlowContext)
}

func capture(_ window: WindowIdentity) throws -> CGImage {
    let semaphore = DispatchSemaphore(value: 0)
    var captured: CGImage?
    Task {
        defer { semaphore.signal() }
        guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true),
              let scWindow = content.windows.first(where: { $0.windowID == window.id }) else { return }
        let configuration = SCStreamConfiguration()
        let scale = NSScreen.screens.first(where: { $0.frame.contains(CGPoint(x: window.bounds.midX, y: window.bounds.midY)) })?.backingScaleFactor ?? 2
        configuration.width = Int(window.bounds.width * scale)
        configuration.height = Int(window.bounds.height * scale)
        configuration.showsCursor = false
        captured = try? await SCScreenshotManager.captureImage(
            contentFilter: SCContentFilter(desktopIndependentWindow: scWindow),
            configuration: configuration
        )
    }
    guard semaphore.wait(timeout: .now() + 10) == .success,
          let image = captured, image.width > 0, image.height > 0 else { throw VisualFailure.capture }
    let scaleX = CGFloat(image.width) / window.bounds.width
    let scaleY = CGFloat(image.height) / window.bounds.height
    guard almostEqual(scaleX, scaleY), almostEqual(scaleX, 1) || almostEqual(scaleX, 2) else { throw VisualFailure.geometry }
    return image
}

func captureDisplayRect(_ rect: CGRect, screen: NSScreen) throws -> CGImage {
    guard let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
        throw VisualFailure.capture
    }
    let semaphore = DispatchSemaphore(value: 0)
    var captured: CGImage?
    Task {
        defer { semaphore.signal() }
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
              let display = content.displays.first(where: { $0.displayID == screenNumber.uint32Value }) else { return }
        let configuration = SCStreamConfiguration()
        configuration.sourceRect = CGRect(
            x: rect.minX - screen.frame.minX,
            y: rect.minY - screen.frame.minY,
            width: rect.width,
            height: rect.height
        )
        configuration.width = Int(rect.width * screen.backingScaleFactor)
        configuration.height = Int(rect.height * screen.backingScaleFactor)
        configuration.showsCursor = false
        captured = try? await SCScreenshotManager.captureImage(
            contentFilter: SCContentFilter(display: display, excludingWindows: []),
            configuration: configuration
        )
    }
    guard semaphore.wait(timeout: .now() + 10) == .success, let image = captured else { throw VisualFailure.capture }
    return image
}

func writePNG(_ image: CGImage, _ url: URL) throws {
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        throw VisualFailure.temp
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw VisualFailure.temp }
}

func privateVisualDiagnosticDirectory(_ path: String) throws -> URL {
    guard path.hasPrefix("/") else { throw VisualFailure.temp }
    let parentPath = (path as NSString).deletingLastPathComponent
    let directory = URL(fileURLWithPath: path, isDirectory: true)
    let parent = URL(fileURLWithPath: parentPath, isDirectory: true)
    var directoryCanonical = [CChar](repeating: 0, count: Int(PATH_MAX))
    var parentCanonical = [CChar](repeating: 0, count: Int(PATH_MAX))
    guard realpath(path, &directoryCanonical) != nil,
          realpath(parentPath, &parentCanonical) != nil,
          String(cString: directoryCanonical) == path,
          String(cString: parentCanonical) == parentPath,
          directory.lastPathComponent.hasPrefix("relaykit-window-diag."),
          directory.lastPathComponent.count > "relaykit-window-diag.".count else {
        throw VisualFailure.temp
    }
    var directoryStatus = stat()
    var parentStatus = stat()
    guard lstat(directory.path, &directoryStatus) == 0,
          lstat(parent.path, &parentStatus) == 0,
          (directoryStatus.st_mode & S_IFMT) == S_IFDIR,
          (parentStatus.st_mode & S_IFMT) == S_IFDIR,
          directoryStatus.st_uid == getuid(),
          (directoryStatus.st_mode & 0o777) == 0o700,
          try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty else {
        throw VisualFailure.temp
    }
    return directory
}

func writePrivateAmbiguityPNGs(candidates: [SemanticCandidate], directory path: String) throws {
    guard !candidates.isEmpty else { throw VisualFailure.temp }
    let directory = try privateVisualDiagnosticDirectory(path)
    var created: [URL] = []
    var completed = false
    defer {
        if !completed {
            for url in created { try? FileManager.default.removeItem(at: url) }
        }
    }
    for (index, candidate) in candidates.enumerated() {
        guard let image = candidate.image,
              image.width == candidate.imageWidth,
              image.height == candidate.imageHeight else { throw VisualFailure.temp }
        let name = String(format: "window-%04d.png", index)
        let url = directory.appendingPathComponent(name, isDirectory: false)
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else { throw VisualFailure.temp }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw VisualFailure.temp }
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw VisualFailure.temp }
        created.append(url)
        var closeNeeded = true
        defer { if closeNeeded { _ = close(descriptor) } }
        let bytes = data as Data
        let wroteAll = bytes.withUnsafeBytes { buffer -> Bool in
            guard let base = buffer.baseAddress else { return false }
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(descriptor, base.advanced(by: offset), buffer.count - offset)
                if written <= 0 { return false }
                offset += written
            }
            return true
        }
        guard wroteAll, fsync(descriptor) == 0, close(descriptor) == 0 else {
            throw VisualFailure.temp
        }
        closeNeeded = false
        var status = stat()
        guard lstat(url.path, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFREG,
              status.st_uid == getuid(),
              (status.st_mode & 0o777) == 0o600 else { throw VisualFailure.temp }
    }
    completed = true
}

func recognizedText(_ image: CGImage) throws -> [TextHit] {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = false
    request.recognitionLanguages = ["en-US", "zh-Hans"]
    do { try VNImageRequestHandler(cgImage: image, orientation: .up).perform([request]) } catch { throw VisualFailure.ocr }
    return (request.results ?? []).compactMap {
        guard let candidate = $0.topCandidates(1).first else { return nil }
        return TextHit(text: candidate.string, confidence: candidate.confidence, normalized: $0.boundingBox)
    }
}

func allowed(label: String, flow: String) -> Bool {
    let publicLabels: Set<String> = [
        "OpenAI Official / Codex Official", "AUTH", "OpenAI Official", "Codex Official",
        "Saved Key Provider", "Hidden models",
        "Paste API key", "Show API key", "Hide API key", "Test connection",
        "Use 1 reachable models", "Advanced", "Save", "1M", "1Y",
        "Developer / Diagnostics", "Quit RelayKit"
    ]
    guard publicLabels.contains(label) else { return false }
    switch label {
    case "OpenAI Official / Codex Official", "AUTH", "OpenAI Official", "Codex Official":
        return ["official-sheet", "official-light", "official-dark"].contains(flow)
    case "Saved Key Provider":
        return ["provider-click-flow", "provider-light", "provider-dark", "provider-test-failure"].contains(flow)
    case "Hidden models", "Paste API key", "Show API key", "Hide API key", "Test connection":
        return ["provider-click-flow", "provider-light", "provider-dark", "provider-test-failure"].contains(flow)
    case "Use 1 reachable models":
        return flow == "provider-click-flow"
    case "Advanced":
        return ["provider-click-flow", "provider-light", "provider-dark", "detail-advanced-expanded", "detail-advanced-collapsed"].contains(flow)
    case "Save":
        return ["provider-light", "provider-dark"].contains(flow)
    case "1M":
        return flow == "usage-1m"
    case "1Y":
        return flow == "usage-1y"
    case "Developer / Diagnostics":
        return flow == "settings-developer-expanded"
    case "Quit RelayKit":
        return flow == "real-quit"
    default:
        return false
    }
}

func allowedInput(_ input: String) -> Bool {
    input == "relaykit-ui-smoke-key"
}

func ambiguityMode(_ value: String) -> AmbiguityMode {
    switch value {
    case "probe-window": return .probeWindow
    case "capture": return .capture
    case "click-text": return .clickText
    case "outside": return .outside
    case "type-text": return .typeText
    default: return .unsupported
    }
}

func ambiguityTargetDiscriminability(
    candidates: [SemanticCandidate],
    mode rawMode: String,
    flow: String,
    label: String
) -> AmbiguityTargetDiscriminability {
    let mode = ambiguityMode(rawMode)
    let applicable = mode == .clickText || mode == .typeText
    let allowlisted = applicable && allowed(label: label, flow: flow)
    guard allowlisted else {
        return AmbiguityTargetDiscriminability(
            mode: mode,
            targetLabelApplicable: applicable,
            currentTargetAllowlisted: false,
            exactlyOneCandidateHasUniqueExactTarget: false,
            otherCandidatesHaveTarget: false
        )
    }
    let targetLabels = ["official-sheet", "official-light", "official-dark"].contains(flow)
        ? ["OpenAI Official / Codex Official", "AUTH", "OpenAI Official", "Codex Official"]
        : [label]
    let candidateTargetCounts = candidates.map { candidate in
        for target in targetLabels {
            let exact = candidate.hits.filter { $0.text == target }
            if exact.isEmpty { continue }
            return exact.filter { hit in
                guard hit.confidence >= 0.80,
                      let rect = try? screenRect(
                        hit: hit,
                        imageWidth: candidate.imageWidth,
                        imageHeight: candidate.imageHeight,
                        bounds: candidate.window.bounds
                      ) else { return false }
                return candidate.window.bounds.contains(rect)
            }.count
        }
        return 0
    }
    let uniqueCandidateCount = candidateTargetCounts.filter { $0 == 1 }.count
    let uniqueCandidateIndex = uniqueCandidateCount == 1 ? candidateTargetCounts.firstIndex(of: 1) : nil
    let otherCandidatesHaveTarget = uniqueCandidateIndex.map { selectedIndex in
        candidateTargetCounts.enumerated().contains { entry in
            entry.offset != selectedIndex && entry.element > 0
        }
    } ?? false
    return AmbiguityTargetDiscriminability(
        mode: mode,
        targetLabelApplicable: true,
        currentTargetAllowlisted: true,
        exactlyOneCandidateHasUniqueExactTarget: uniqueCandidateCount == 1,
        otherCandidatesHaveTarget: otherCandidatesHaveTarget
    )
}

func surfaceProfile(flow: String, mode: String) -> SurfaceProfile {
    switch flow {
    case "connect": return .connectRoot
    case "official-sheet", "official-light", "official-dark":
        switch mode {
        case "probe-window", "click-text": return .connectRoot
        case "capture": return .officialSheet
        default: return .unsupported
        }
    case "provider-click-flow", "provider-light", "provider-dark", "provider-test-failure",
         "detail", "detail-advanced-expanded", "detail-advanced-collapsed", "provider":
        return .providerForm
    case "usage", "usage-auto-refresh", "usage-large", "usage-1m", "usage-1y", "usage-empty", "usage-light", "usage-dark":
        return .usageRoot
    case "settings", "settings-developer-expanded", "settings-light", "settings-dark":
        return .settingsRoot
    case "outside-click": return .outsidePopover
    case "real-quit": return .realQuit
    default: return .unsupported
    }
}

func requiredAnchors(for profile: SurfaceProfile) -> [String] {
    switch profile {
    case .connectRoot: return ["RelayKit", "Usage"]
    case .officialSheet: return ["AUTH", "OpenAI Official", "Codex Official"]
    case .providerForm: return ["Test connection", "Advanced"]
    case .usageRoot: return ["RelayKit", "Usage", "Today tokens"]
    case .settingsRoot: return ["RelayKit", "Developer / Diagnostics"]
    case .outsidePopover: return ["RelayKit", "Usage"]
    case .realQuit: return ["Quit RelayKit"]
    case .unsupported: return []
    }
}

func requiredAlternativeGroups(for profile: SurfaceProfile) -> [[String]] {
    return []
}

func diagnosticSurfaceAnchorIsAllowlisted(_ anchor: String) -> Bool {
    let anchors: Set<String> = [
        "RelayKit", "AUTH", "OpenAI Official / Codex Official", "OpenAI Official", "Codex Official",
        "Test connection", "Advanced", "Usage", "Today tokens", "Developer / Diagnostics", "Quit RelayKit"
    ]
    return anchors.contains(anchor)
}

func candidateMatchesAllRequiredExactAnchors(_ candidate: SemanticCandidate, anchors: [String]) -> Bool {
    guard !anchors.isEmpty else { return false }
    return anchors.allSatisfy { anchor in
        let matching = candidate.hits.filter { hit in
            guard hit.text == anchor, hit.confidence >= 0.80,
                  let rect = try? screenRect(
                    hit: hit,
                    imageWidth: candidate.imageWidth,
                    imageHeight: candidate.imageHeight,
                    bounds: candidate.window.bounds
                  ) else { return false }
            return candidate.window.bounds.contains(rect)
        }
        return matching.count == 1
    }
}

func anchorObservationDiagnostic(
    candidates: [SemanticCandidate],
    anchor: String
) -> (summary: AnchorObservationDiagnostic, validCounts: [Int]) {
    var exactObservationSeen = false
    var confidenceThresholdSeen = false
    var geometryValidSeen = false
    let validCounts = candidates.map { candidate in
        candidate.hits.filter { hit in
            guard hit.text == anchor else { return false }
            exactObservationSeen = true
            guard hit.confidence >= 0.80 else { return false }
            confidenceThresholdSeen = true
            guard let rect = try? screenRect(
                hit: hit,
                imageWidth: candidate.imageWidth,
                imageHeight: candidate.imageHeight,
                bounds: candidate.window.bounds
            ), candidate.window.bounds.contains(rect) else { return false }
            geometryValidSeen = true
            return true
        }.count
    }
    let positiveCandidateCount = validCounts.filter { $0 > 0 }.count
    let duplicateCandidateCount = validCounts.filter { $0 > 1 }.count
    let cardinality: AnchorValidHitCardinality
    if positiveCandidateCount == 0 {
        cardinality = .zero
    } else if duplicateCandidateCount > 0 && positiveCandidateCount > 1 {
        cardinality = .mixed
    } else if duplicateCandidateCount > 0 {
        cardinality = .duplicateWithinCandidate
    } else if positiveCandidateCount == 1 {
        cardinality = .one
    } else {
        cardinality = .multipleCandidates
    }
    return (
        AnchorObservationDiagnostic(
            exactObservationSeen: exactObservationSeen,
            confidenceThresholdSeen: confidenceThresholdSeen,
            geometryValidSeen: geometryValidSeen,
            validHitCardinality: cardinality
        ),
        validCounts
    )
}

func connectRootAnchorObservationDiagnostic(
    candidates: [SemanticCandidate]
) -> ConnectRootAnchorObservationDiagnostic {
    let relayKit = anchorObservationDiagnostic(candidates: candidates, anchor: "RelayKit")
    let combinedOfficial = anchorObservationDiagnostic(
        candidates: candidates,
        anchor: "OpenAI Official / Codex Official"
    )
    let openAIOfficial = anchorObservationDiagnostic(candidates: candidates, anchor: "OpenAI Official")
    let codexOfficial = anchorObservationDiagnostic(candidates: candidates, anchor: "Codex Official")
    let indices = candidates.indices
    let fullProfileCount = indices.filter {
        relayKit.validCounts[$0] == 1 && combinedOfficial.validCounts[$0] == 1
    }.count
    let profileCardinality: ConnectRootProfileCardinality
    switch fullProfileCount {
    case 0: profileCardinality = .zero
    case 1: profileCardinality = .one
    default: profileCardinality = .multiple
    }
    return ConnectRootAnchorObservationDiagnostic(
        profileCardinality: profileCardinality,
        relayKit: relayKit.summary,
        combinedOfficial: combinedOfficial.summary,
        openAIOfficial: openAIOfficial.summary,
        codexOfficial: codexOfficial.summary,
        sameCandidateRelayKitAndCombinedValid: indices.contains {
            relayKit.validCounts[$0] == 1 && combinedOfficial.validCounts[$0] == 1
        },
        sameCandidateRelayKitAndOpenAIOfficialValid: indices.contains {
            relayKit.validCounts[$0] == 1 && openAIOfficial.validCounts[$0] == 1
        },
        sameCandidateRelayKitAndCodexOfficialValid: indices.contains {
            relayKit.validCounts[$0] == 1 && codexOfficial.validCounts[$0] == 1
        },
        sameCandidateRelayKitAndBothSplitOfficialValid: indices.contains {
            relayKit.validCounts[$0] == 1 &&
                openAIOfficial.validCounts[$0] == 1 && codexOfficial.validCounts[$0] == 1
        }
    )
}

func connectRootAnchorObservationSchema(_ diagnostic: ConnectRootAnchorObservationDiagnostic) -> String {
    [
        "DIAG_VALID=true",
        "connect_root_profile_cardinality=\(diagnostic.profileCardinality.rawValue)",
        "relaykit_exact_observation_seen=\(diagnostic.relayKit.exactObservationSeen)",
        "relaykit_confidence_threshold_seen=\(diagnostic.relayKit.confidenceThresholdSeen)",
        "relaykit_geometry_valid_seen=\(diagnostic.relayKit.geometryValidSeen)",
        "relaykit_valid_hit_cardinality=\(diagnostic.relayKit.validHitCardinality.rawValue)",
        "combined_official_exact_observation_seen=\(diagnostic.combinedOfficial.exactObservationSeen)",
        "combined_official_confidence_threshold_seen=\(diagnostic.combinedOfficial.confidenceThresholdSeen)",
        "combined_official_geometry_valid_seen=\(diagnostic.combinedOfficial.geometryValidSeen)",
        "combined_official_valid_hit_cardinality=\(diagnostic.combinedOfficial.validHitCardinality.rawValue)",
        "openai_official_exact_observation_seen=\(diagnostic.openAIOfficial.exactObservationSeen)",
        "openai_official_confidence_threshold_seen=\(diagnostic.openAIOfficial.confidenceThresholdSeen)",
        "openai_official_geometry_valid_seen=\(diagnostic.openAIOfficial.geometryValidSeen)",
        "openai_official_valid_hit_cardinality=\(diagnostic.openAIOfficial.validHitCardinality.rawValue)",
        "codex_official_exact_observation_seen=\(diagnostic.codexOfficial.exactObservationSeen)",
        "codex_official_confidence_threshold_seen=\(diagnostic.codexOfficial.confidenceThresholdSeen)",
        "codex_official_geometry_valid_seen=\(diagnostic.codexOfficial.geometryValidSeen)",
        "codex_official_valid_hit_cardinality=\(diagnostic.codexOfficial.validHitCardinality.rawValue)",
        "same_candidate_relaykit_and_combined_valid=\(diagnostic.sameCandidateRelayKitAndCombinedValid)",
        "same_candidate_relaykit_and_openai_official_valid=\(diagnostic.sameCandidateRelayKitAndOpenAIOfficialValid)",
        "same_candidate_relaykit_and_codex_official_valid=\(diagnostic.sameCandidateRelayKitAndCodexOfficialValid)",
        "same_candidate_relaykit_and_both_split_official_valid=\(diagnostic.sameCandidateRelayKitAndBothSplitOfficialValid)"
    ].joined(separator: "\n")
}

func connectRootPublicAnchorText(_ key: ConnectRootPublicAnchorKey) -> String {
    switch key {
    case .gatewayStopped: return "Stopped"
    case .usageTab: return "Usage"
    case .codexCard: return "Codex"
    case .enableRelayKit: return "Enable RelayKit"
    case .officialAuthBadge: return "AUTH"
    case .localCLIEyebrow: return "LOCAL CLI"
    }
}

func publicAnchorCandidateDiagnostic(
    candidates: [SemanticCandidate],
    key: ConnectRootPublicAnchorKey,
    relayKitValidCounts: [Int]
) -> PublicAnchorCandidateDiagnostic {
    let observation = anchorObservationDiagnostic(
        candidates: candidates,
        anchor: connectRootPublicAnchorText(key)
    )
    let pairCount = candidates.indices.filter {
        relayKitValidCounts[$0] == 1 && observation.validCounts[$0] == 1
    }.count
    let pairCardinality: ConnectRootProfileCardinality
    switch pairCount {
    case 0: pairCardinality = .zero
    case 1: pairCardinality = .one
    default: pairCardinality = .multiple
    }
    return PublicAnchorCandidateDiagnostic(
        observation: observation.summary,
        relayKitPairProfileCardinality: pairCardinality
    )
}

func connectRootPublicAnchorCandidatesDiagnostic(
    candidates: [SemanticCandidate]
) -> ConnectRootPublicAnchorCandidatesDiagnostic {
    let relayKit = anchorObservationDiagnostic(candidates: candidates, anchor: "RelayKit")
    return ConnectRootPublicAnchorCandidatesDiagnostic(
        gatewayStopped: publicAnchorCandidateDiagnostic(
            candidates: candidates, key: .gatewayStopped, relayKitValidCounts: relayKit.validCounts
        ),
        usageTab: publicAnchorCandidateDiagnostic(
            candidates: candidates, key: .usageTab, relayKitValidCounts: relayKit.validCounts
        ),
        codexCard: publicAnchorCandidateDiagnostic(
            candidates: candidates, key: .codexCard, relayKitValidCounts: relayKit.validCounts
        ),
        enableRelayKit: publicAnchorCandidateDiagnostic(
            candidates: candidates, key: .enableRelayKit, relayKitValidCounts: relayKit.validCounts
        ),
        officialAuthBadge: publicAnchorCandidateDiagnostic(
            candidates: candidates, key: .officialAuthBadge, relayKitValidCounts: relayKit.validCounts
        ),
        localCLIEyebrow: publicAnchorCandidateDiagnostic(
            candidates: candidates, key: .localCLIEyebrow, relayKitValidCounts: relayKit.validCounts
        )
    )
}

func connectRootPublicAnchorSummary(
    _ diagnostic: ConnectRootPublicAnchorCandidatesDiagnostic,
    key: ConnectRootPublicAnchorKey
) -> PublicAnchorCandidateDiagnostic {
    switch key {
    case .gatewayStopped: return diagnostic.gatewayStopped
    case .usageTab: return diagnostic.usageTab
    case .codexCard: return diagnostic.codexCard
    case .enableRelayKit: return diagnostic.enableRelayKit
    case .officialAuthBadge: return diagnostic.officialAuthBadge
    case .localCLIEyebrow: return diagnostic.localCLIEyebrow
    }
}

func connectRootPublicAnchorCandidatesSchema(
    _ diagnostic: ConnectRootPublicAnchorCandidatesDiagnostic
) -> String {
    [
        "DIAG_VALID=true",
        "gateway_stopped_exact_observation_seen=\(diagnostic.gatewayStopped.observation.exactObservationSeen)",
        "gateway_stopped_confidence_threshold_seen=\(diagnostic.gatewayStopped.observation.confidenceThresholdSeen)",
        "gateway_stopped_geometry_valid_seen=\(diagnostic.gatewayStopped.observation.geometryValidSeen)",
        "gateway_stopped_valid_hit_cardinality=\(diagnostic.gatewayStopped.observation.validHitCardinality.rawValue)",
        "gateway_stopped_relaykit_pair_profile_cardinality=\(diagnostic.gatewayStopped.relayKitPairProfileCardinality.rawValue)",
        "usage_tab_exact_observation_seen=\(diagnostic.usageTab.observation.exactObservationSeen)",
        "usage_tab_confidence_threshold_seen=\(diagnostic.usageTab.observation.confidenceThresholdSeen)",
        "usage_tab_geometry_valid_seen=\(diagnostic.usageTab.observation.geometryValidSeen)",
        "usage_tab_valid_hit_cardinality=\(diagnostic.usageTab.observation.validHitCardinality.rawValue)",
        "usage_tab_relaykit_pair_profile_cardinality=\(diagnostic.usageTab.relayKitPairProfileCardinality.rawValue)",
        "codex_card_exact_observation_seen=\(diagnostic.codexCard.observation.exactObservationSeen)",
        "codex_card_confidence_threshold_seen=\(diagnostic.codexCard.observation.confidenceThresholdSeen)",
        "codex_card_geometry_valid_seen=\(diagnostic.codexCard.observation.geometryValidSeen)",
        "codex_card_valid_hit_cardinality=\(diagnostic.codexCard.observation.validHitCardinality.rawValue)",
        "codex_card_relaykit_pair_profile_cardinality=\(diagnostic.codexCard.relayKitPairProfileCardinality.rawValue)",
        "enable_relaykit_exact_observation_seen=\(diagnostic.enableRelayKit.observation.exactObservationSeen)",
        "enable_relaykit_confidence_threshold_seen=\(diagnostic.enableRelayKit.observation.confidenceThresholdSeen)",
        "enable_relaykit_geometry_valid_seen=\(diagnostic.enableRelayKit.observation.geometryValidSeen)",
        "enable_relaykit_valid_hit_cardinality=\(diagnostic.enableRelayKit.observation.validHitCardinality.rawValue)",
        "enable_relaykit_relaykit_pair_profile_cardinality=\(diagnostic.enableRelayKit.relayKitPairProfileCardinality.rawValue)",
        "official_auth_badge_exact_observation_seen=\(diagnostic.officialAuthBadge.observation.exactObservationSeen)",
        "official_auth_badge_confidence_threshold_seen=\(diagnostic.officialAuthBadge.observation.confidenceThresholdSeen)",
        "official_auth_badge_geometry_valid_seen=\(diagnostic.officialAuthBadge.observation.geometryValidSeen)",
        "official_auth_badge_valid_hit_cardinality=\(diagnostic.officialAuthBadge.observation.validHitCardinality.rawValue)",
        "official_auth_badge_relaykit_pair_profile_cardinality=\(diagnostic.officialAuthBadge.relayKitPairProfileCardinality.rawValue)",
        "local_cli_eyebrow_exact_observation_seen=\(diagnostic.localCLIEyebrow.observation.exactObservationSeen)",
        "local_cli_eyebrow_confidence_threshold_seen=\(diagnostic.localCLIEyebrow.observation.confidenceThresholdSeen)",
        "local_cli_eyebrow_geometry_valid_seen=\(diagnostic.localCLIEyebrow.observation.geometryValidSeen)",
        "local_cli_eyebrow_valid_hit_cardinality=\(diagnostic.localCLIEyebrow.observation.validHitCardinality.rawValue)",
        "local_cli_eyebrow_relaykit_pair_profile_cardinality=\(diagnostic.localCLIEyebrow.relayKitPairProfileCardinality.rawValue)"
    ].joined(separator: "\n")
}

func candidateSatisfiesAllRequiredAlternativeGroups(
    _ candidate: SemanticCandidate,
    groups: [[String]]
) -> Bool {
    return groups.allSatisfy { group in
        group.contains(where: { alternative in
            let matching = candidate.hits.filter {
                guard $0.text == alternative, $0.confidence >= 0.80,
                      let rect = try? screenRect(
                        hit: $0,
                        imageWidth: candidate.imageWidth,
                        imageHeight: candidate.imageHeight,
                        bounds: candidate.window.bounds
                      ) else { return false }
                return candidate.window.bounds.contains(rect)
            }
            return matching.count == 1
        })
    }
}

func surfaceProfileDiscriminability(
    candidates: [SemanticCandidate],
    mode: String,
    flow: String
) -> SurfaceProfileDiscriminability {
    let profile = surfaceProfile(flow: flow, mode: mode)
    let anchors = requiredAnchors(for: profile)
    let alternativeGroups = requiredAlternativeGroups(for: profile)
    let profileHasRequiredAlternativeGroup = !alternativeGroups.isEmpty
    guard profile != .unsupported else {
        return SurfaceProfileDiscriminability(
            profile: .unsupported,
            allRequiredAnchorsAllowlisted: false,
            exactlyOneCandidateMatchesAllRequiredExactAnchors: false,
            otherCandidatesMatchAll: false,
            profileHasRequiredAlternativeGroup: false,
            atLeastOneCandidateSatisfiesAllRequiredAlternativeGroups: true
        )
    }
    let allRequiredAnchorsAllowlisted = !anchors.isEmpty &&
        anchors.allSatisfy(diagnosticSurfaceAnchorIsAllowlisted) &&
        alternativeGroups.flatMap { $0 }.allSatisfy(diagnosticSurfaceAnchorIsAllowlisted)
    guard allRequiredAnchorsAllowlisted else {
        return SurfaceProfileDiscriminability(
            profile: profile,
            allRequiredAnchorsAllowlisted: false,
            exactlyOneCandidateMatchesAllRequiredExactAnchors: false,
            otherCandidatesMatchAll: false,
            profileHasRequiredAlternativeGroup: profileHasRequiredAlternativeGroup,
            atLeastOneCandidateSatisfiesAllRequiredAlternativeGroups: false
        )
    }
    let matchingCandidates = candidates.filter {
        candidateMatchesAllRequiredExactAnchors($0, anchors: anchors) &&
            candidateSatisfiesAllRequiredAlternativeGroups($0, groups: alternativeGroups)
    }
    let atLeastOneCandidateSatisfiesAllRequiredAlternativeGroups = alternativeGroups.isEmpty || candidates.contains {
        candidateSatisfiesAllRequiredAlternativeGroups($0, groups: alternativeGroups)
    }
    return SurfaceProfileDiscriminability(
        profile: profile,
        allRequiredAnchorsAllowlisted: true,
        exactlyOneCandidateMatchesAllRequiredExactAnchors: matchingCandidates.count == 1,
        otherCandidatesMatchAll: matchingCandidates.count > 1,
        profileHasRequiredAlternativeGroup: profileHasRequiredAlternativeGroup,
        atLeastOneCandidateSatisfiesAllRequiredAlternativeGroups: atLeastOneCandidateSatisfiesAllRequiredAlternativeGroups
    )
}

func firstAmbiguityWindowEquivalenceDiagnosticSchema(
    _ result: WindowEquivalenceResult,
    discriminability: AmbiguityTargetDiscriminability,
    surface: SurfaceProfileDiscriminability
) -> String {
    [
        "DIAG_VALID=true",
        "AMBIGUITY_MODE=\(discriminability.mode.rawValue)",
        "target_label_applicable=\(discriminability.targetLabelApplicable)",
        "current_target_allowlisted=\(discriminability.currentTargetAllowlisted)",
        "exactly_one_candidate_has_unique_exact_target=\(discriminability.exactlyOneCandidateHasUniqueExactTarget)",
        "other_candidates_have_target=\(discriminability.otherCandidatesHaveTarget)",
        "SURFACE_PROFILE=\(surface.profile.rawValue)",
        "all_required_anchors_allowlisted=\(surface.allRequiredAnchorsAllowlisted)",
        "exactly_one_candidate_matches_all_required_exact_anchors=\(surface.exactlyOneCandidateMatchesAllRequiredExactAnchors)",
        "other_candidates_match_all=\(surface.otherCandidatesMatchAll)",
        "profile_has_required_alternative_group=\(surface.profileHasRequiredAlternativeGroup)",
        "at_least_one_candidate_satisfies_all_required_alternative_groups=\(surface.atLeastOneCandidateSatisfiesAllRequiredAlternativeGroups)",
        "same_point_bounds=\(result.samePointBounds)",
        "same_pixel_dimensions=\(result.samePixelDimensions)",
        "same_pixel_sha256=\(result.samePixelSHA256)",
        "same_exact_anchor_normalized_bbox=\(result.sameExactAnchorNormalizedBBox)",
        "same_absolute_anchor_center=\(result.sameAbsoluteAnchorCenter)",
        "same_backing_scale=\(result.sameBackingScale)",
        "all_revalidate_stable=\(result.allRevalidateStable)"
    ].joined(separator: "\n")
}

func revalidate(_ frozen: WindowIdentity, pid: Int32, expectedExecutable: String) throws {
    do {
        let current = try windowInfo(pid: pid, expectedExecutable: expectedExecutable)
        try validateIdentity(pid, canonical(expectedExecutable), current, frozen)
    } catch {
        throw VisualFailure.staleWindow
    }
}

func click(_ point: CGPoint) throws {
    guard let source = CGEventSource(stateID: .hidSystemState),
          let down = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left),
          let up = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left) else {
        throw VisualFailure.perform
    }
    down.post(tap: .cghidEventTap)
    usleep(80_000)
    up.post(tap: .cghidEventTap)
}

func selectAllText() throws {
    guard let source = CGEventSource(stateID: .hidSystemState),
          let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
          let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
        throw VisualFailure.selectText
    }
    down.flags = .maskCommand
    up.flags = .maskCommand
    down.post(tap: .cghidEventTap)
    usleep(80_000)
    up.post(tap: .cghidEventTap)
}

func inputText(_ text: String) throws {
    let characters = Array(text.utf16)
    guard !characters.isEmpty,
          let source = CGEventSource(stateID: .hidSystemState),
          let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
          let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
        throw VisualFailure.inputText
    }
    characters.withUnsafeBufferPointer { buffer in
        down.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress!)
    }
    down.post(tap: .cghidEventTap)
    usleep(80_000)
    up.post(tap: .cghidEventTap)
}

let args = CommandLine.arguments
guard args.count == 7 else { exit(2) }
let mode = args[1]
guard ["self-test", "probe-window", "capture", "click-text", "outside", "type-text"].contains(mode) else { exit(2) }
if mode == "self-test" {
    do { try visual_action_synthetic_contract(); exit(0) } catch { exit(1) }
}
guard let pid = Int32(args[2]) else { exit(2) }
let expectedExecutable = args[3]
let flow = args[4]
let label = args[5]
let output = args[6]
semanticFlowContext = flow
semanticVisualModeContext = mode

if mode == "probe-window",
   ProcessInfo.processInfo.environment["RELAYKIT_MENU_BAR_WINDOW_EQUIVALENCE_DIAGNOSTIC"] == "1" {
    let diagnostic = temporalWindowEquivalenceDiagnostic(
        pid: pid,
        expectedExecutable: expectedExecutable,
        flow: flow
    )
    print(diagnostic.schema)
    exit(diagnostic.exitCode)
}

do {
    let frozen: WindowIdentity
    let equivalenceDiagnosticTarget = ProcessInfo.processInfo.environment["RELAYKIT_WINDOW_EQUIVALENCE_DIAGNOSTIC_TARGET"] ?? ""
    if equivalenceDiagnosticTarget == "first-ambiguity" || equivalenceDiagnosticTarget == "first-ambiguity-private-visual" {
        let anchor = try semanticAnchor(flow: flow)
        let candidates = try semanticCandidates(pid: pid, expectedExecutable: expectedExecutable)
        let matches = try semanticMatches(candidates, anchor: anchor)
        if matches.count > 1 {
            if equivalenceDiagnosticTarget == "first-ambiguity-private-visual" {
                guard let directory = ProcessInfo.processInfo.environment["RELAYKIT_PRIVATE_VISUAL_DIAGNOSTIC_DIR"] else {
                    throw VisualFailure.temp
                }
                try writePrivateAmbiguityPNGs(candidates: matches.map { $0.candidate }, directory: directory)
                print("PRIVATE_VISUAL_DIAGNOSTIC_READY=true")
                exit(99)
            }
            let diagnostic = try firstAmbiguityWindowEquivalenceDiagnostic(candidates: candidates, pid: pid, expectedExecutable: expectedExecutable, mode: mode, flow: flow, label: label)
            print(diagnostic.schema)
            exit(98)
        }
        guard matches.count == 1 else { throw VisualFailure.semanticAnchorMissing }
        frozen = matches[0].candidate.window
    } else {
        if mode == "probe-window", flow == "outside-click",
           ProcessInfo.processInfo.environment["RELAYKIT_WINDOW_EQUIVALENCE_DIAGNOSTIC_TARGET"] == "outside-click" {
            let candidates = try semanticCandidates(pid: pid, expectedExecutable: expectedExecutable)
            let diagnostic = try outsideWindowEquivalenceDiagnostic(candidates: candidates, pid: pid, expectedExecutable: expectedExecutable)
            print(diagnostic.schema)
            exit(diagnostic.exitCode == 0 ? 0 : 98)
        }
        frozen = mode == "probe-window"
            ? try probeWindowInfo(pid: pid, expectedExecutable: expectedExecutable)
            : try windowInfo(pid: pid, expectedExecutable: expectedExecutable)
    }
    try validateIdentity(pid, canonical(expectedExecutable), frozen)
    if mode == "probe-window" { exit(0) }
    let image = try capture(frozen)
    if mode == "capture" {
        let root = ProcessInfo.processInfo.environment["RELAYKIT_RUNTIME_SAFETY_ROOT"] ?? ""
        let destination = URL(fileURLWithPath: output).standardizedFileURL
        guard !root.isEmpty, destination.path.hasPrefix(URL(fileURLWithPath: root).standardizedFileURL.path + "/") else {
            throw VisualFailure.temp
        }
        try revalidate(frozen, pid: pid, expectedExecutable: expectedExecutable)
        try writePNG(image, destination)
        exit(0)
    }
    if mode == "outside" {
        guard let display = NSScreen.screens.map({ $0.frame }).first(where: { $0.contains(CGPoint(x: frozen.bounds.midX, y: frozen.bounds.midY)) }) else {
            throw VisualFailure.geometry
        }
        let candidates = [
            CGPoint(x: frozen.bounds.minX - 12, y: frozen.bounds.midY),
            CGPoint(x: frozen.bounds.maxX + 12, y: frozen.bounds.midY),
            CGPoint(x: frozen.bounds.midX, y: frozen.bounds.minY - 12),
            CGPoint(x: frozen.bounds.midX, y: frozen.bounds.maxY + 12)
        ]
        guard let point = candidates.first(where: { display.contains($0) && !frozen.bounds.contains($0) }) else { throw VisualFailure.geometry }
        try revalidate(frozen, pid: pid, expectedExecutable: expectedExecutable)
        try click(point)
        usleep(300_000)
        let root = ProcessInfo.processInfo.environment["RELAYKIT_RUNTIME_SAFETY_ROOT"] ?? ""
        let destination = URL(fileURLWithPath: output).standardizedFileURL
        guard !root.isEmpty, destination.path.hasPrefix(URL(fileURLWithPath: root).standardizedFileURL.path + "/"),
              let screen = NSScreen.screens.first(where: { $0.frame.contains(CGPoint(x: frozen.bounds.midX, y: frozen.bounds.midY)) }) else {
            throw VisualFailure.temp
        }
        let closedImage = try captureDisplayRect(frozen.bounds, screen: screen)
        try writePNG(closedImage, destination)
        exit(0)
    }
    guard mode == "click-text" || mode == "type-text", allowed(label: label, flow: flow) else { throw VisualFailure.labelContract }
    if mode == "type-text" && !allowedInput(output) { throw VisualFailure.labelContract }
    try withTemporaryCapture { url in
        try writePNG(image, url)
        let hits = try recognizedText(image)
        let targets = (flow == "official-sheet" || flow == "official-light" || flow == "official-dark")
            ? ["OpenAI Official / Codex Official", "AUTH", "OpenAI Official", "Codex Official"]
            : [label]
        let rect = try uniqueExact(targets, flow: flow, hits: hits, imageWidth: image.width, imageHeight: image.height, bounds: frozen.bounds)
        try revalidate(frozen, pid: pid, expectedExecutable: expectedExecutable)
        try click(CGPoint(x: rect.midX, y: rect.midY))
        if mode == "type-text" {
            try revalidate(frozen, pid: pid, expectedExecutable: expectedExecutable)
            try selectAllText()
            try inputText(output)
        }
    }
    exit(0)
} catch VisualFailure.windowIdentity {
    exit(71)
} catch VisualFailure.windowMissing {
    exit(89)
} catch VisualFailure.windowAmbiguous {
    exit(90)
} catch VisualFailure.captureableContentUnavailable {
    exit(91)
} catch VisualFailure.semanticCaptureUnavailable {
    exit(92)
} catch VisualFailure.semanticOCREmpty {
    exit(93)
} catch VisualFailure.semanticAnchorMissing {
    exit(94)
} catch VisualFailure.semanticAnchorDuplicate {
    exit(95)
} catch VisualFailure.semanticAnchorAmbiguous {
    exit(96)
} catch VisualFailure.semanticIdentityOrGeometry {
    exit(97)
} catch VisualFailure.capture {
    exit(72)
} catch VisualFailure.geometry {
    exit(73)
} catch VisualFailure.labelContract {
    exit(74)
} catch VisualFailure.ocr {
    exit(75)
} catch VisualFailure.ocrEmpty {
    exit(76)
} catch VisualFailure.staleWindow {
    exit(77)
} catch VisualFailure.temp {
    exit(78)
} catch VisualFailure.perform {
    exit(79)
} catch VisualFailure.duplicateMatch {
    exit(81)
} catch VisualFailure.lowConfidence {
    exit(82)
} catch VisualFailure.invalidBounds {
    exit(83)
} catch VisualFailure.targetAbsentCurrentFlow {
    exit(84)
} catch VisualFailure.wrongFlowAnchors {
    exit(85)
} catch VisualFailure.nonemptyUnclassified {
    exit(86)
} catch VisualFailure.selectText {
    exit(87)
} catch VisualFailure.inputText {
    exit(88)
} catch {
    exit(80)
}
SWIFT
  then
    set_visual_swift_stage "${flow}" "${mode}" success
    return 0
  else
    visual_rc="$?"
  fi
  if [[ "${RELAYKIT_MENU_BAR_WINDOW_EQUIVALENCE_DIAGNOSTIC:-0}" == "1" && "${mode}" == "probe-window" ]]; then
    return "${visual_rc}"
  fi
  if [[ "${RELAYKIT_WINDOW_EQUIVALENCE_DIAGNOSTIC_TARGET:-}" == "first-ambiguity" && "${visual_rc}" == "98" ]]; then
    cleanup_current_app
    FAILURE_REPORTED=1
    exit 0
  fi
  if [[ "${RELAYKIT_WINDOW_EQUIVALENCE_DIAGNOSTIC_TARGET:-}" == "first-ambiguity-private-visual" && "${visual_rc}" == "99" ]]; then
    cleanup_current_app
    FAILURE_REPORTED=1
    exit 0
  fi
  if [[ "${RELAYKIT_WINDOW_EQUIVALENCE_DIAGNOSTIC_TARGET:-}" == "connect-root-anchor-observations" && "${flow}" == "connect" && "${mode}" == "probe-window" && "${visual_rc}" == "100" ]]; then
    cleanup_current_app
    FAILURE_REPORTED=1
    exit 0
  fi
  if [[ "${RELAYKIT_WINDOW_EQUIVALENCE_DIAGNOSTIC_TARGET:-}" == "connect-root-public-anchor-candidates" && "${flow}" == "connect" && "${mode}" == "probe-window" && "${visual_rc}" == "101" ]]; then
    cleanup_current_app
    FAILURE_REPORTED=1
    exit 0
  fi
  if [[ "${RELAYKIT_WINDOW_EQUIVALENCE_DIAGNOSTIC_TARGET:-}" == "outside-click" && "${mode}" == "probe-window" && "${visual_rc}" == "98" ]]; then
    return 1
  fi
  return_visual_action_failure "${flow}" "${mode}" "${visual_rc}" "${phase}" "${scope}"
}

visual_click_text() {
  visual_action click-text "$1" "$2" "" "${3:-}" "${4:-}"
}

visual_capture_window() {
  visual_action capture "$1" "" "$2"
}

visual_click_outside() {
  visual_action outside outside-click "" "$1"
}

window_readiness_context_is_valid() {
  case "$1" in
    connect|official-sheet|real-demo|provider-click-flow|provider-test-failure|detail|detail-advanced-expanded|detail-advanced-collapsed|import|usage|usage-auto-refresh|usage-large|usage-1m|usage-1y|usage-empty|settings|settings-developer-expanded|settings-light|usage-light|official-light|provider-light|settings-dark|usage-dark|official-dark|provider-dark|provider|outside-click) return 0 ;;
    *) return 2 ;;
  esac
}

set_capture_window_readiness_stage() {
  local context="$1"
  window_readiness_context_is_valid "${context}" || return $?
  set_stage "capture.${context}.semantic-window-readiness"
}

visual_probe_window() {
  visual_action probe-window "$1"
}

wait_for_capture_window_ready() {
  local context="$1"
  local attempt
  window_readiness_context_is_valid "${context}" || return $?
  for attempt in {1..120}; do
    if visual_probe_window "${context}"; then
      return 0
    fi
    if ! kill -0 "${PID}" 2>/dev/null; then
      return 1
    fi
    sleep 0.05
  done
  return 1
}

wait_for_outside_window_ready() {
  wait_for_capture_window_ready outside-click
}

ensure_outside_popover_open() {
  local probe_rc
  if visual_probe_window outside-click; then
    return 0
  else
    probe_rc="$?"
  fi
  case "${probe_rc}" in
    89)
      set_stage capture.outside-click.status-item-press
      press_unique_status_item
      ;;
    *) return "${probe_rc}" ;;
  esac
}

visual_type_exact_pid() {
  visual_action type-text "$1" "$2" "$3" "$4"
}

status_item_selector() {
  local mode="$1"
  local expected_executable
  case "${mode}" in
    probe|open|press) ;;
    *) return 2 ;;
  esac
  if [[ "${RELAYKIT_STATUS_ITEM_SELECTOR_SYNTHETIC_TEST:-0}" != "1" ]]; then
    process_executable_matches "${PID}" "${APP_REAL}" || return 31
  fi
  expected_executable="$(canonical_executable_path "${APP_REAL}")" || return 31
  swift - "${mode}" "${PID}" "${expected_executable}" >"${TMPDIR}status-item-selector.log" 2>&1 <<'SWIFT'
import ApplicationServices
import CoreGraphics
import Darwin
import Foundation

let maxDepth = 6
let maxVisited = 128

enum StatusItemSelectorFailure: Error {
  case rootTraversal
  case budget
  }

final class SyntheticNode {
  let role: String?
  let description: String?
  let position: CGPoint
  let size: CGSize
  let enabled: Bool
  let actions: [String]
  let performSucceeds: Bool
  var children: [SyntheticNode]

  init(
    role: String? = nil,
    description: String? = nil,
    position: CGPoint = .zero,
    size: CGSize = .zero,
    enabled: Bool = true,
    actions: [String] = [],
    performSucceeds: Bool = true,
    children: [SyntheticNode] = []
  ) {
    self.role = role
    self.description = description
    self.position = position
    self.size = size
    self.enabled = enabled
    self.actions = actions
    self.performSucceeds = performSucceeds
    self.children = children
    }
  }

func syntheticSelection(_ root: SyntheticNode) -> Int32 {
  var visited: [SyntheticNode] = []
  var candidates: [SyntheticNode] = []

  func walk(_ node: SyntheticNode, depth: Int) throws {
    if depth > maxDepth { throw StatusItemSelectorFailure.budget }
    if visited.contains(where: { $0 === node }) { return }
    if visited.count >= maxVisited { throw StatusItemSelectorFailure.budget }
    visited.append(node)
    let role = node.role
    let description = node.description
    let children = node.children
    if role == "AXMenuBarItem" && description == "RelayKit" {
      candidates.append(node)
    }
    for child in children {
      try walk(child, depth: depth + 1)
    }
    }

  do {
    try walk(root, depth: 0)
  } catch StatusItemSelectorFailure.budget {
    return 37
  } catch {
    return 36
  }
  guard candidates.count == 1 else { return 33 }
  let candidate = candidates[0]
  guard candidate.size.width > 0, candidate.size.height > 0 else { return 35 }
  return 0
  }

func syntheticEventCounts(_ mode: String) -> Int {
  mode == "probe" ? 0 : 1
  }

func syntheticStatusPress(_ root: SyntheticNode) -> (rc: Int32, presses: Int) {
  var visited: [SyntheticNode] = []
  var candidates: [SyntheticNode] = []

  func walk(_ node: SyntheticNode, depth: Int) throws {
    if depth > maxDepth { throw StatusItemSelectorFailure.budget }
    if visited.contains(where: { $0 === node }) { return }
    if visited.count >= maxVisited { throw StatusItemSelectorFailure.budget }
    visited.append(node)
    let role = node.role
    let description = node.description
    let children = node.children
    if role == "AXMenuBarItem" && description == "RelayKit" { candidates.append(node) }
    for child in children { try walk(child, depth: depth + 1) }
    }

  do {
    try walk(root, depth: 0)
  } catch StatusItemSelectorFailure.budget {
    return (37, 0)
  } catch {
    return (36, 0)
  }
  guard candidates.count == 1 else { return (33, 0) }
  let candidate = candidates[0]
  guard candidate.size.width > 0, candidate.size.height > 0 else { return (35, 0) }
  guard candidate.enabled == true else { return (38, 0) }
  guard candidate.actions.contains(kAXPressAction as String) else { return (39, 0) }
  let presses = 1
  guard candidate.performSucceeds else { return (40, presses) }
  return (0, presses)
  }

func runSyntheticContract() -> Bool {
  let target = SyntheticNode(
    role: "AXMenuBarItem",
    description: "RelayKit",
    position: CGPoint(x: 10, y: 20),
    size: CGSize(width: 24, height: 24)
  )
  let syntheticNested = SyntheticNode(children: [SyntheticNode(children: [target])])
  guard syntheticSelection(syntheticNested) == 0 else { return false }

  let syntheticZero = SyntheticNode()
  guard syntheticSelection(syntheticZero) == 33 else { return false }

  let syntheticDuplicate = SyntheticNode(children: [target, SyntheticNode(
    role: "AXMenuBarItem",
    description: "RelayKit",
    size: CGSize(width: 16, height: 16)
  )])
  guard syntheticSelection(syntheticDuplicate) == 33 else { return false }

  let syntheticCycle = SyntheticNode()
  let cycleContainer = SyntheticNode(children: [syntheticCycle, target])
  syntheticCycle.children = [cycleContainer]
  guard syntheticSelection(syntheticCycle) == 0 else { return false }

  let syntheticDepthBudget = SyntheticNode()
  var depthCursor = syntheticDepthBudget
  for _ in 0...maxDepth {
    let child = SyntheticNode()
    depthCursor.children = [child]
    depthCursor = child
  }
  guard syntheticSelection(syntheticDepthBudget) == 37 else { return false }

  let syntheticNodeBudget = SyntheticNode(children: (0..<maxVisited).map { _ in SyntheticNode() })
  guard syntheticSelection(syntheticNodeBudget) == 37 else { return false }

  let syntheticInvalidGeometry = SyntheticNode(children: [SyntheticNode(
    role: "AXMenuBarItem",
    description: "RelayKit",
    size: CGSize(width: 0, height: 16)
  )])
  guard syntheticSelection(syntheticInvalidGeometry) == 35 else { return false }

  let syntheticRoleDescription = SyntheticNode(children: [
    SyntheticNode(role: "AXButton", description: "RelayKit", size: CGSize(width: 16, height: 16)),
    SyntheticNode(role: "AXMenuBarItem", description: "Other", size: CGSize(width: 16, height: 16))
  ])
  guard syntheticSelection(syntheticRoleDescription) == 33 else { return false }

  let syntheticEventCounts = (probe: syntheticEventCounts("probe"), open: syntheticEventCounts("open"))
  let statusPressTarget = SyntheticNode(
    role: "AXMenuBarItem",
    description: "RelayKit",
    size: CGSize(width: 16, height: 16),
    actions: [kAXPressAction as String]
  )
  let syntheticStatusPressZero = syntheticStatusPress(SyntheticNode())
  let syntheticStatusPressDuplicate = syntheticStatusPress(SyntheticNode(children: [statusPressTarget, SyntheticNode(
    role: "AXMenuBarItem", description: "RelayKit", size: CGSize(width: 16, height: 16),
    actions: [kAXPressAction as String]
  )]))
  let syntheticStatusPressDisabled = syntheticStatusPress(SyntheticNode(children: [SyntheticNode(
    role: "AXMenuBarItem", description: "RelayKit", size: CGSize(width: 16, height: 16),
    enabled: false, actions: [kAXPressAction as String]
  )]))
  let syntheticStatusPressMissingAction = syntheticStatusPress(SyntheticNode(children: [SyntheticNode(
    role: "AXMenuBarItem", description: "RelayKit", size: CGSize(width: 16, height: 16)
  )]))
  let syntheticStatusPressPerformFailure = syntheticStatusPress(SyntheticNode(children: [SyntheticNode(
    role: "AXMenuBarItem", description: "RelayKit", size: CGSize(width: 16, height: 16),
    actions: [kAXPressAction as String], performSucceeds: false
  )]))
  let syntheticStatusPressCount = syntheticStatusPress(SyntheticNode(children: [statusPressTarget]))
  return syntheticEventCounts.probe == 0 && syntheticEventCounts.open == 1 &&
    syntheticStatusPressZero.rc == 33 && syntheticStatusPressDuplicate.rc == 33 &&
    syntheticStatusPressDisabled.rc == 38 && syntheticStatusPressMissingAction.rc == 39 &&
    syntheticStatusPressPerformFailure == (40, 1) && syntheticStatusPressCount == (0, 1)
  }

if ProcessInfo.processInfo.environment["RELAYKIT_STATUS_ITEM_SELECTOR_SYNTHETIC_TEST"] == "1" {
  guard runSyntheticContract() else { exit(36) }
  print("Status item selector synthetic contract passed")
  exit(0)
  }

func canonical(_ path: String) -> String {
  URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
  }

func executablePath(pid: Int32) -> String? {
  var buffer = [CChar](repeating: 0, count: 4096)
  guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
  return canonical(String(cString: buffer))
  }

func identityMatches(pid: Int32, expectedExecutable: String) -> Bool {
  kill(pid, 0) == 0 && executablePath(pid: pid) == canonical(expectedExecutable)
  }

guard CommandLine.arguments.count == 4, let pid = Int32(CommandLine.arguments[2]) else { exit(36) }
let mode = CommandLine.arguments[1]
let expectedExecutable = CommandLine.arguments[3]
guard identityMatches(pid: pid, expectedExecutable: expectedExecutable) else { exit(31) }
let root = AXUIElementCreateApplication(pid)
var visited: [AXUIElement] = []
var candidates: [AXUIElement] = []

func optionalString(_ element: AXUIElement, attribute: CFString) -> String? {
  var value: CFTypeRef?
  guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else { return nil }
  return value as? String
  }

func childElements(_ element: AXUIElement, isRoot: Bool) throws -> [AXUIElement] {
  var value: CFTypeRef?
  let result = AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value)
  if result == .success {
    guard let children = value as? [AXUIElement] else { throw StatusItemSelectorFailure.rootTraversal }
    return children
  }
  if !isRoot && (result == .noValue || result == .attributeUnsupported) { return [] }
  throw StatusItemSelectorFailure.rootTraversal
  }

func walk(_ element: AXUIElement, depth: Int, isRoot: Bool = false) throws {
  if depth > maxDepth { throw StatusItemSelectorFailure.budget }
  if visited.contains(where: { CFEqual($0, element) }) { return }
  if visited.count >= maxVisited { throw StatusItemSelectorFailure.budget }
  visited.append(element)
  let role = optionalString(element, attribute: kAXRoleAttribute as CFString)
  let description = optionalString(element, attribute: kAXDescriptionAttribute as CFString)
  let children = try childElements(element, isRoot: isRoot)
  if role == "AXMenuBarItem" && description == "RelayKit" {
    candidates.append(element)
  }
  for child in children {
    try walk(child, depth: depth + 1)
  }
  }

do {
  try walk(root, depth: 0, isRoot: true)
  } catch StatusItemSelectorFailure.rootTraversal {
  exit(32)
  } catch StatusItemSelectorFailure.budget {
  exit(37)
  } catch {
  exit(36)
  }
guard candidates.count == 1 else { exit(33) }
var positionValue: CFTypeRef?
var sizeValue: CFTypeRef?
guard AXUIElementCopyAttributeValue(candidates[0], kAXPositionAttribute as CFString, &positionValue) == .success,
      AXUIElementCopyAttributeValue(candidates[0], kAXSizeAttribute as CFString, &sizeValue) == .success,
      let positionAX = positionValue as! AXValue?,
      let sizeAX = sizeValue as! AXValue? else { exit(35) }
var position = CGPoint.zero
var size = CGSize.zero
guard AXValueGetValue(positionAX, .cgPoint, &position),
      AXValueGetValue(sizeAX, .cgSize, &size),
      size.width > 0, size.height > 0 else { exit(35) }
let point = CGPoint(x: position.x + size.width / 2, y: position.y + size.height / 2)
if mode == "press" {
  var enabledValue: CFTypeRef?
  guard AXUIElementCopyAttributeValue(candidates[0], kAXEnabledAttribute as CFString, &enabledValue) == .success,
        let enabled = enabledValue as? Bool,
        enabled == true else { exit(38) }
  var actionValues: CFArray?
  guard AXUIElementCopyActionNames(candidates[0], &actionValues) == .success,
        let actions = actionValues as? [String],
        actions.contains(kAXPressAction as String) else { exit(39) }
  guard identityMatches(pid: pid, expectedExecutable: expectedExecutable) else { exit(31) }
  guard AXUIElementPerformAction(candidates[0], kAXPressAction as CFString) == .success else { exit(40) }
  exit(0)
  }
if mode == "probe" { exit(0) }
guard mode == "open" else { exit(36) }
guard let source = CGEventSource(stateID: .hidSystemState),
      let down = CGEvent(mouseEventSource: source, mouseType: .rightMouseDown, mouseCursorPosition: point, mouseButton: .right),
      let up = CGEvent(mouseEventSource: source, mouseType: .rightMouseUp, mouseCursorPosition: point, mouseButton: .right) else { exit(36) }
guard identityMatches(pid: pid, expectedExecutable: expectedExecutable) else { exit(31) }
down.post(tap: .cghidEventTap)
usleep(100_000)
up.post(tap: .cghidEventTap)
SWIFT
}

status_item_is_ready() {
  status_item_selector probe
}

set_status_item_readiness_stage() {
  local result="$1"
  local category
  case "${result}" in
    0) category=ready ;;
    31) category=process-id ;;
    32) category=root-traversal ;;
    33) category=unique-item ;;
    35) category=positive-size ;;
    36) category=internal ;;
    37) category=budget ;;
    death) category=death ;;
    *) return 2 ;;
  esac
  set_stage "capture.real-quit.status-menu.readiness-wait.${category}"
}

wait_for_status_item_ready() {
  local attempt last_rc=31
  for attempt in {1..40}; do
    if status_item_is_ready; then
      set_status_item_readiness_stage 0
      return 0
    else
      last_rc="$?"
    fi
    if ! kill -0 "${PID}" 2>/dev/null; then
      set_status_item_readiness_stage death
      return 1
    fi
    sleep 0.05
  done
  set_status_item_readiness_stage "${last_rc}" || return $?
  return 1
}

open_unique_status_menu() {
  if status_item_selector open; then
    return 0
  fi
  return 1
}

press_unique_status_item() {
  status_item_selector press
}

set_real_quit_press_stage() {
  local result="$1"
  local category
  case "${result}" in
    0) category=pressed ;;
    41) category=process-id ;;
    42) category=root-traversal ;;
    43) category=budget ;;
    44) category=unique-item ;;
    45) category=disabled ;;
    46) category=missing-action ;;
    47) category=perform ;;
    48) category=internal ;;
    *) return 2 ;;
  esac
  set_stage "capture.real-quit.quit-click.${category}"
}

press_unique_quit_menu_item() {
  local rc expected_executable
  if [[ "${RELAYKIT_QUIT_PRESS_SYNTHETIC_TEST:-0}" != "1" ]] &&
     ! process_executable_matches "${PID}" "${APP_REAL}"; then
    set_real_quit_press_stage 41
    return 41
  fi
  expected_executable="$(canonical_executable_path "${APP_REAL}")" || {
    set_real_quit_press_stage 41
    return 41
  }
  if swift - "${PID}" "${expected_executable}" >"${TMPDIR}quit-menu-item-press.log" 2>&1 <<'SWIFT'
import ApplicationServices
import Darwin
import Foundation

let maxDepth = 6
let maxVisited = 128

enum QuitPressFailure: Error {
  case rootTraversal
  case budget
  }

final class SyntheticQuitNode {
  let role: String?
  let title: String?
  let name: String?
  let enabled: Bool
  let actions: [String]
  let performSucceeds: Bool
  var children: [SyntheticQuitNode]

  init(
    role: String? = nil,
    title: String? = nil,
    name: String? = nil,
    enabled: Bool = true,
    actions: [String] = [],
    performSucceeds: Bool = true,
    children: [SyntheticQuitNode] = []
  ) {
    self.role = role
    self.title = title
    self.name = name
    self.enabled = enabled
    self.actions = actions
    self.performSucceeds = performSucceeds
    self.children = children
    }
  }

func syntheticQuitPress(_ root: SyntheticQuitNode) -> (rc: Int32, presses: Int) {
  var visited: [SyntheticQuitNode] = []
  var candidates: [SyntheticQuitNode] = []

  func walk(_ node: SyntheticQuitNode, depth: Int) throws {
    if depth > maxDepth { throw QuitPressFailure.budget }
    if visited.contains(where: { $0 === node }) { return }
    if visited.count >= maxVisited { throw QuitPressFailure.budget }
    visited.append(node)
    let role = node.role
    let title = node.title
    let name = node.name
    let children = node.children
    if role == "AXMenuItem" && (title == "Quit RelayKit" || name == "Quit RelayKit") {
      candidates.append(node)
    }
    for child in children {
      try walk(child, depth: depth + 1)
    }
    }

  do {
    try walk(root, depth: 0)
  } catch QuitPressFailure.budget {
    return (43, 0)
  } catch {
    return (48, 0)
  }
  guard candidates.count == 1 else { return (44, 0) }
  let candidate = candidates[0]
  guard candidate.enabled == true else { return (45, 0) }
  guard candidate.actions.contains(kAXPressAction as String) else { return (46, 0) }
  let presses = 1
  guard candidate.performSucceeds else { return (47, presses) }
  return (0, presses)
  }

func runSyntheticQuitPressContract() -> Bool {
  let titleTarget = SyntheticQuitNode(
    role: "AXMenuItem",
    title: "Quit RelayKit",
    actions: [kAXPressAction as String]
  )
  let syntheticNestedQuit = SyntheticQuitNode(children: [SyntheticQuitNode(children: [titleTarget])])
  guard syntheticQuitPress(syntheticNestedQuit) == (0, 1) else { return false }

  let syntheticZeroQuit = SyntheticQuitNode()
  guard syntheticQuitPress(syntheticZeroQuit).rc == 44 else { return false }

  let syntheticDuplicateQuit = SyntheticQuitNode(children: [titleTarget, SyntheticQuitNode(
    role: "AXMenuItem",
    name: "Quit RelayKit",
    actions: [kAXPressAction as String]
  )])
  guard syntheticQuitPress(syntheticDuplicateQuit).rc == 44 else { return false }

  let syntheticDisabledQuit = SyntheticQuitNode(children: [SyntheticQuitNode(
    role: "AXMenuItem",
    title: "Quit RelayKit",
    enabled: false,
    actions: [kAXPressAction as String]
  )])
  guard syntheticQuitPress(syntheticDisabledQuit).rc == 45 else { return false }

  let syntheticMissingActionQuit = SyntheticQuitNode(children: [SyntheticQuitNode(
    role: "AXMenuItem",
    title: "Quit RelayKit"
  )])
  guard syntheticQuitPress(syntheticMissingActionQuit).rc == 46 else { return false }

  let syntheticCycleQuit = SyntheticQuitNode()
  let nameTarget = SyntheticQuitNode(
    role: "AXMenuItem",
    name: "Quit RelayKit",
    actions: [kAXPressAction as String]
  )
  syntheticCycleQuit.children = [SyntheticQuitNode(children: [syntheticCycleQuit, nameTarget])]
  guard syntheticQuitPress(syntheticCycleQuit) == (0, 1) else { return false }

  let syntheticDepthBudgetQuit = SyntheticQuitNode()
  var depthCursor = syntheticDepthBudgetQuit
  for _ in 0...maxDepth {
    let child = SyntheticQuitNode()
    depthCursor.children = [child]
    depthCursor = child
  }
  guard syntheticQuitPress(syntheticDepthBudgetQuit).rc == 43 else { return false }

  let syntheticNodeBudgetQuit = SyntheticQuitNode(children: (0..<maxVisited).map { _ in SyntheticQuitNode() })
  guard syntheticQuitPress(syntheticNodeBudgetQuit).rc == 43 else { return false }

  let syntheticPerformFailureQuit = SyntheticQuitNode(children: [SyntheticQuitNode(
    role: "AXMenuItem",
    title: "Quit RelayKit",
    actions: [kAXPressAction as String],
    performSucceeds: false
  )])
  guard syntheticQuitPress(syntheticPerformFailureQuit) == (47, 1) else { return false }

  let syntheticEventCountsQuit = (press: syntheticQuitPress(syntheticNestedQuit).presses, pointer: 0)
  return syntheticEventCountsQuit.press == 1 && syntheticEventCountsQuit.pointer == 0
  }

if ProcessInfo.processInfo.environment["RELAYKIT_QUIT_PRESS_SYNTHETIC_TEST"] == "1" {
  guard runSyntheticQuitPressContract() else { exit(48) }
  print("Quit menu item synthetic contract passed")
  exit(0)
  }

func canonical(_ path: String) -> String {
  URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
  }

func executablePath(pid: Int32) -> String? {
  var buffer = [CChar](repeating: 0, count: 4096)
  guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
  return canonical(String(cString: buffer))
  }

func identityMatches(pid: Int32, expectedExecutable: String) -> Bool {
  kill(pid, 0) == 0 && executablePath(pid: pid) == canonical(expectedExecutable)
  }

guard CommandLine.arguments.count == 3, let pid = Int32(CommandLine.arguments[1]) else { exit(48) }
let expectedExecutable = CommandLine.arguments[2]
guard identityMatches(pid: pid, expectedExecutable: expectedExecutable) else { exit(41) }
let root = AXUIElementCreateApplication(pid)
var visited: [AXUIElement] = []
var candidates: [AXUIElement] = []

func optionalString(_ element: AXUIElement, attribute: CFString) -> String? {
  var value: CFTypeRef?
  guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else { return nil }
  return value as? String
  }

func childElements(_ element: AXUIElement, isRoot: Bool) throws -> [AXUIElement] {
  var value: CFTypeRef?
  let result = AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value)
  if result == .success {
    guard let children = value as? [AXUIElement] else { throw QuitPressFailure.rootTraversal }
    return children
  }
  if !isRoot && (result == .noValue || result == .attributeUnsupported) { return [] }
  throw QuitPressFailure.rootTraversal
  }

func walk(_ element: AXUIElement, depth: Int, isRoot: Bool = false) throws {
  if depth > maxDepth { throw QuitPressFailure.budget }
  if visited.contains(where: { CFEqual($0, element) }) { return }
  if visited.count >= maxVisited { throw QuitPressFailure.budget }
  visited.append(element)
  let role = optionalString(element, attribute: kAXRoleAttribute as CFString)
  let title = optionalString(element, attribute: kAXTitleAttribute as CFString)
  let name = optionalString(element, attribute: "AXName" as CFString)
  let children = try childElements(element, isRoot: isRoot)
  if role == "AXMenuItem" && (title == "Quit RelayKit" || name == "Quit RelayKit") {
    candidates.append(element)
  }
  for child in children {
    try walk(child, depth: depth + 1)
  }
  }

do {
  try walk(root, depth: 0, isRoot: true)
  } catch QuitPressFailure.rootTraversal {
  exit(42)
  } catch QuitPressFailure.budget {
  exit(43)
  } catch {
  exit(48)
  }
guard candidates.count == 1 else { exit(44) }
var enabledValue: CFTypeRef?
guard AXUIElementCopyAttributeValue(candidates[0], kAXEnabledAttribute as CFString, &enabledValue) == .success,
      let enabled = enabledValue as? Bool,
      enabled == true else { exit(45) }
var actionValues: CFArray?
guard AXUIElementCopyActionNames(candidates[0], &actionValues) == .success,
      let actions = actionValues as? [String],
      actions.contains(kAXPressAction as String) else { exit(46) }
guard identityMatches(pid: pid, expectedExecutable: expectedExecutable) else { exit(41) }
guard AXUIElementPerformAction(candidates[0], kAXPressAction as CFString) == .success else { exit(47) }
SWIFT
  then
    rc=0
  else
    rc="$?"
  fi
  case "${rc}" in
    0|42|43|44|45|46|47|48) ;;
    *) rc=48 ;;
  esac
  set_real_quit_press_stage "${rc}"
  return "${rc}"
}

provider_click_flow_specific_predicate() {
  local evidence="$1"
  local diagnostic label json_type
  if ! diagnostic="$(jq -r '
    [
      {label:"provider_edit_opened", type:(.connect.provider_edit_opened | type), pass:(.connect.provider_edit_opened == true)},
      {label:"provider_edit_row_action_invoked", type:(.connect.provider_edit_row_action_invoked | type), pass:(.connect.provider_edit_row_action_invoked == true)},
      {label:"provider_edit_base_url_prefilled", type:(.connect.provider_edit_base_url_prefilled | type), pass:(.connect.provider_edit_base_url_prefilled == true)},
      {label:"provider_edit_models_loaded", type:(.connect.provider_edit_models_loaded | type), pass:(.connect.provider_edit_models_loaded == true)},
      {label:"provider_health_summary_visible", type:(.connect.provider_health_summary_visible | type), pass:(.connect.provider_health_summary_visible == true)},
      {label:"provider_health_saved_count", type:(.connect.provider_health_saved_count | type), pass:(.connect.provider_health_saved_count == 2)},
      {label:"provider_health_available_count", type:(.connect.provider_health_available_count | type), pass:(.connect.provider_health_available_count == 1)},
      {label:"provider_health_hidden_count", type:(.connect.provider_health_hidden_count | type), pass:(.connect.provider_health_hidden_count == 1)},
      {label:"provider_model_reachable_row_visible", type:(.connect.provider_model_reachable_row_visible | type), pass:(.connect.provider_model_reachable_row_visible == true)},
      {label:"provider_model_unavailable_row_visible", type:(.connect.provider_model_unavailable_row_visible | type), pass:(.connect.provider_model_unavailable_row_visible == true)},
      {label:"provider_hidden_models_toggle_visible", type:(.connect.provider_hidden_models_toggle_visible | type), pass:(.connect.provider_hidden_models_toggle_visible == true)},
      {label:"provider_hidden_model_reasons_visible", type:(.connect.provider_hidden_model_reasons_visible | type), pass:(.connect.provider_hidden_model_reasons_visible == true)},
      {label:"api_key_saved_state_visible", type:(.connect.api_key_saved_state_visible | type), pass:(.connect.api_key_saved_state_visible == true)},
      {label:"api_key_masked_field_visible", type:(.connect.api_key_masked_field_visible | type), pass:(.connect.api_key_masked_field_visible == true)},
      {label:"api_key_saved_mask_control_visible", type:(.connect.api_key_saved_mask_control_visible | type), pass:(.connect.api_key_saved_mask_control_visible == true)},
      {label:"api_key_saved_eye_visible", type:(.connect.api_key_saved_eye_visible | type), pass:(.connect.api_key_saved_eye_visible == true)},
      {label:"saved_key_fake_eye_visible", type:(.connect.saved_key_fake_eye_visible | type), pass:(.connect.saved_key_fake_eye_visible == false)},
      {label:"saved_key_disabled_eye_reason_visible", type:(.connect.saved_key_disabled_eye_reason_visible | type), pass:(.connect.saved_key_disabled_eye_reason_visible == false)},
      {label:"api_key_replace_visible", type:(.connect.api_key_replace_visible | type), pass:(.connect.api_key_replace_visible == false)},
      {label:"api_key_replace_available", type:(.connect.api_key_replace_available | type), pass:(.connect.api_key_replace_available == false)},
      {label:"provider_form_test_connection_visible", type:(.connect.provider_form_test_connection_visible | type), pass:(.connect.provider_form_test_connection_visible == true)},
      {label:"saved_key_plaintext_hidden", type:(.connect.saved_key_plaintext_hidden | type), pass:(.connect.saved_key_plaintext_hidden == true)}
    ] |
    if all(.[]; .pass) then "PASS"
    else (first(.[] | select(.pass | not)) | "\(.label)\t\(.type)")
    end
  ' "${evidence}" 2>/dev/null)"; then
    printf '%s\n' 'provider_edit_opened type=null' >&2
    return 1
  fi
  [[ "${diagnostic}" == "PASS" ]] && return 0
  label="${diagnostic%%$'\t'*}"
  json_type="${diagnostic#*$'\t'}"
  case "${label}" in
    provider_edit_opened|provider_edit_row_action_invoked|provider_edit_base_url_prefilled|provider_edit_models_loaded|provider_health_summary_visible|provider_health_saved_count|provider_health_available_count|provider_health_hidden_count|provider_model_reachable_row_visible|provider_model_unavailable_row_visible|provider_hidden_models_toggle_visible|provider_hidden_model_reasons_visible|api_key_saved_state_visible|api_key_masked_field_visible|api_key_saved_mask_control_visible|api_key_saved_eye_visible|saved_key_fake_eye_visible|saved_key_disabled_eye_reason_visible|api_key_replace_visible|api_key_replace_available|provider_form_test_connection_visible|saved_key_plaintext_hidden) ;;
    *) label=provider_edit_opened; json_type=null ;;
  esac
  case "${json_type}" in
    boolean|number|string|null|array|object) ;;
    *) label=provider_edit_opened; json_type=null ;;
  esac
  printf '%s type=%s\n' "${label}" "${json_type}" >&2
  return 1
}

set_provider_capture_stage() {
  local capture_name="$1"
  local phase="$2"
  case "${capture_name}" in
    provider-click-flow|provider-light|provider-dark) ;;
    *) return 2 ;;
  esac
  case "${phase}" in
    edit-open-check|provider-row-click|edit-ready-wait|health-ready-wait|hidden-models-click|hidden-reasons-wait|specific-predicate)
      set_stage "capture.${capture_name}.${phase}"
      ;;
    *) return 2 ;;
  esac
}

set_official_sheet_stage() {
  local capture_name="$1"
  local phase="$2"
  case "${capture_name}" in
    official-sheet|official-light|official-dark) ;;
    *) return 2 ;;
  esac
  case "${phase}" in
    opened-wait|specific-predicate|before-capture|before-verify|after-capture|after-verify)
      set_stage "capture.${capture_name}.${phase}"
      ;;
    *) return 2 ;;
  esac
}

wait_for_official_sheet_opened() {
  local evidence="$1"
  local rc classification
  if wait_for_jq "${evidence}" '.connect.official_sheet_opened == true'; then
    return 0
  else
    rc="$?"
  fi
  if ! classification="$(jq -r '
    if ((.connect.official_provider_row_actionable | type) != "boolean") or
       ((.connect.official_sheet_opened | type) != "boolean") then
      "evidence-type-invalid"
    elif .connect.official_provider_row_actionable == false and
         .connect.official_sheet_opened == false then
      "row-action-not-recorded"
    elif .connect.official_provider_row_actionable == true and
         .connect.official_sheet_opened == false then
      "sheet-appear-not-recorded"
    elif .connect.official_provider_row_actionable == true and
         .connect.official_sheet_opened == true then
      "sheet-recorded-after-timeout"
    elif .connect.official_provider_row_actionable == false and
         .connect.official_sheet_opened == true then
      "evidence-inconsistent"
    else
      "evidence-type-invalid"
    end
  ' "${evidence}" 2>/dev/null)"; then
    classification=evidence-type-invalid
  fi
  case "${classification}" in
    row-action-not-recorded|sheet-appear-not-recorded|sheet-recorded-after-timeout|evidence-inconsistent|evidence-type-invalid) ;;
    *) classification=evidence-type-invalid ;;
  esac
  printf '%s\n' "${classification}" >&2
  return "${rc}"
}

wait_for_provider_edit_ready() {
  local evidence="$1"
  local rc diagnostic label json_type
  if wait_for_jq "${evidence}" '.connect.provider_edit_opened == true and .connect.api_key_masked_field_visible == true'; then
    return 0
  else
    rc=$?
  fi
  if ! diagnostic="$(jq -r '
    [
      {label:"provider_edit_opened", type:(.connect.provider_edit_opened | type), pass:(.connect.provider_edit_opened == true)},
      {label:"api_key_masked_field_visible", type:(.connect.api_key_masked_field_visible | type), pass:(.connect.api_key_masked_field_visible == true)}
    ] |
    first(.[] | select(.pass | not)) |
    "\(.label)\t\(.type)"
  ' "${evidence}" 2>/dev/null)"; then
    diagnostic=$'provider_edit_opened\tnull'
  fi
  label="${diagnostic%%$'\t'*}"
  json_type="${diagnostic#*$'\t'}"
  case "${label}" in
    provider_edit_opened|api_key_masked_field_visible) ;;
    *) label=provider_edit_opened; json_type=null ;;
  esac
  case "${json_type}" in
    boolean|number|string|null|array|object) ;;
    *) label=provider_edit_opened; json_type=null ;;
  esac
  printf '%s type=%s\n' "${label}" "${json_type}" >&2
  return "${rc}"
}

usage_specific_predicate() {
  local evidence="$1"
  local diagnostic label json_type
  if jq -e '
      .usage.has_rows == true and
      .usage.empty_state_visible == false and
      .usage.auto_refresh_enabled == true and
      .usage.summary_background == true and
      .usage.token_unit_formatting == true and
      .usage.today_tokens == 150 and
      .usage.today_tokens_label == "150" and
      .usage.seven_day_tokens == 750 and
      .usage.all_time_tokens == 775 and
      .usage.requests == 7 and
      .usage.top_model_7d == "demo/claude-sonnet-4-6" and
      .usage.top_model_7d_readable == "claude-sonnet-4-6" and
      .usage.top_model_readable_visible == true and
      .usage.active_days == 4 and
      .usage.provider_group_names == ["Official Codex / OpenAI","Third-party providers"] and
      .usage.provider_source_shifted == true and
      .usage.model_count == 4 and
      .usage.activity_bucket_count_7d == 14 and
      .usage.activity_active_days_7d == 3 and
      .usage.activity_unit_labels == ["7D · half-day","1M · daily","1Y · weekly"] and
      .usage.activity_heatmap_visible == true and
      .usage.activity_range_control_visible == true and
      .usage.activity_unit_label_visible == true and
      .usage.cost_unavailable_visible == true
    ' "${evidence}" >/dev/null 2>&1; then
    return 0
  fi
  if ! diagnostic="$(jq -r '
    [
      {label:"has_rows", type:(.usage.has_rows | type), pass:(.usage.has_rows == true)},
      {label:"empty_state_visible", type:(.usage.empty_state_visible | type), pass:(.usage.empty_state_visible == false)},
      {label:"auto_refresh_enabled", type:(.usage.auto_refresh_enabled | type), pass:(.usage.auto_refresh_enabled == true)},
      {label:"summary_background", type:(.usage.summary_background | type), pass:(.usage.summary_background == true)},
      {label:"token_unit_formatting", type:(.usage.token_unit_formatting | type), pass:(.usage.token_unit_formatting == true)},
      {label:"today_tokens", type:(.usage.today_tokens | type), pass:(.usage.today_tokens == 150)},
      {label:"today_tokens_label", type:(.usage.today_tokens_label | type), pass:(.usage.today_tokens_label == "150")},
      {label:"seven_day_tokens", type:(.usage.seven_day_tokens | type), pass:(.usage.seven_day_tokens == 750)},
      {label:"all_time_tokens", type:(.usage.all_time_tokens | type), pass:(.usage.all_time_tokens == 775)},
      {label:"requests", type:(.usage.requests | type), pass:(.usage.requests == 7)},
      {label:"top_model_7d", type:(.usage.top_model_7d | type), pass:(.usage.top_model_7d == "demo/claude-sonnet-4-6")},
      {label:"top_model_7d_readable", type:(.usage.top_model_7d_readable | type), pass:(.usage.top_model_7d_readable == "claude-sonnet-4-6")},
      {label:"top_model_readable_visible", type:(.usage.top_model_readable_visible | type), pass:(.usage.top_model_readable_visible == true)},
      {label:"active_days", type:(.usage.active_days | type), pass:(.usage.active_days == 4)},
      {label:"provider_group_names", type:(.usage.provider_group_names | type), pass:(.usage.provider_group_names == ["Official Codex / OpenAI","Third-party providers"])},
      {label:"provider_source_shifted", type:(.usage.provider_source_shifted | type), pass:(.usage.provider_source_shifted == true)},
      {label:"model_count", type:(.usage.model_count | type), pass:(.usage.model_count == 4)},
      {label:"activity_bucket_count_7d", type:(.usage.activity_bucket_count_7d | type), pass:(.usage.activity_bucket_count_7d == 14)},
      {label:"activity_active_days_7d", type:(.usage.activity_active_days_7d | type), pass:(.usage.activity_active_days_7d == 3)},
      {label:"activity_unit_labels", type:(.usage.activity_unit_labels | type), pass:(.usage.activity_unit_labels == ["7D · half-day","1M · daily","1Y · weekly"])},
      {label:"activity_heatmap_visible", type:(.usage.activity_heatmap_visible | type), pass:(.usage.activity_heatmap_visible == true)},
      {label:"activity_range_control_visible", type:(.usage.activity_range_control_visible | type), pass:(.usage.activity_range_control_visible == true)},
      {label:"activity_unit_label_visible", type:(.usage.activity_unit_label_visible | type), pass:(.usage.activity_unit_label_visible == true)},
      {label:"cost_unavailable_visible", type:(.usage.cost_unavailable_visible | type), pass:(.usage.cost_unavailable_visible == true)}
    ] |
    first(.[] | select(.pass | not)) |
    "\(.label)\t\(.type)"
  ' "${evidence}" 2>/dev/null)"; then
    diagnostic=$'has_rows\tnull'
  fi
  label="${diagnostic%%$'\t'*}"
  json_type="${diagnostic#*$'\t'}"
  case "${label}" in
    has_rows|empty_state_visible|auto_refresh_enabled|summary_background|token_unit_formatting|today_tokens|today_tokens_label|seven_day_tokens|all_time_tokens|requests|top_model_7d|top_model_7d_readable|top_model_readable_visible|active_days|provider_group_names|provider_source_shifted|model_count|activity_bucket_count_7d|activity_active_days_7d|activity_unit_labels|activity_heatmap_visible|activity_range_control_visible|activity_unit_label_visible|cost_unavailable_visible) ;;
    *) label=has_rows; json_type=null ;;
  esac
  case "${json_type}" in
    boolean|number|string|null|array|object) ;;
    *) label=has_rows; json_type=null ;;
  esac
  printf 'FIRST_FAILED_CONJUNCT=%s type=%s\n' "${label}" "${json_type}" >&2
  return 1
}

final_aggregate_predicate() {
  local evidence="$1"
  local rc diagnostic label json_type
  if jq -e '
    .official_current_status as $officialStatus |
    .provider_config_path_is_app_support == false and
    .stale_tmp_provider_config_recovered == false and
    .status_summary_inline == true and
    .model_access_and_model_list_merged == true and
    .duplicate_empty_state == false and
    .official_provider_row_visible == true and
    .official_provider_row_managed_by_relaykit == true and
    .official_sheet_opened == true and
    .official_light_sheet_opened == true and
    .official_dark_sheet_opened == true and
    .official_auth_required_visible == false and
    .official_auth_cta_visible == true and
    (($officialStatus == "not connected" and .official_auth_cta_clicked == false) or
     ($officialStatus == "device login pending" and .official_auth_cta_clicked == true) or
     (($officialStatus == "login available" or $officialStatus == "route verified") and .official_auth_cta_clicked == false)) and
    .official_auth_cta_has_real_action == true and
    .official_auth_cta_disabled_as_unimplemented == false and
    .official_auth_unimplemented_visible == false and
    (($officialStatus == "not connected" and .official_auth_in_progress == false) or
     ($officialStatus == "device login pending" and .official_auth_in_progress == true and .official_auth_process_id_present == true) or
     (($officialStatus == "login available" or $officialStatus == "route verified") and .official_auth_in_progress == false)) and
    (($officialStatus == "not connected" and .official_connected_by_login_status == false) or
     ($officialStatus == "device login pending" and .official_device_url_captured == true and .official_device_code_captured == true and .official_device_code_copied == true and .official_copy_device_code_action_visible == true and .official_copy_device_code_clicked == true) or
     (($officialStatus == "login available" or $officialStatus == "route verified") and .official_connected_by_login_status == true and .official_connected_cta_disabled == true and .official_connected_device_code_hidden == true and .official_connected_click_does_not_start_login == true)) and
    ($officialStatus == "not connected" or .official_credential_ref_exists == true) and
    ($officialStatus == "not connected" or $officialStatus == "device login pending" or $officialStatus == "login available" or $officialStatus == "route verified") and
    .official_connected_by_login_status == ($officialStatus == "login available" or $officialStatus == "route verified") and
    .official_route_verified_status == ($officialStatus == "route verified") and
    (($officialStatus == "not connected" and .official_device_login_visible == false) or
     ($officialStatus == "device login pending" and .official_device_login_visible == true) or
     ($officialStatus == "login available" or $officialStatus == "route verified")) and
    .official_product_actions_visible == true and
    .official_authenticate_action_visible == true and
    .official_status_refresh_action_visible == true and
    .official_reauth_action_visible == false and
    .official_disconnect_action_visible == true and
    .official_isolated_desktop_entry_visible == false and
    .official_token_boundary_visible == true and
    .official_debug_status_visible == false and
    .official_debug_actions_visible == false and
    .official_mock_passthrough_status_visible == false and
    .official_not_connected_status_visible == ($officialStatus == "not connected") and
    (.official_device_login_pending_status_visible | type == "boolean") and
    (.official_login_available_status_visible | type == "boolean") and
    (.official_route_verified_status_visible | type == "boolean") and
    .official_state_details_collapsed == true and
    .official_state_details_expanded == false and
    .official_login_required_status_visible == false and
    .official_real_auth_not_verified_visible == false and
    .official_open_codex_desktop_action_visible == false and
    .official_run_isolated_check_action_visible == false and
    .official_copy_command_action_visible == false and
    .official_run_isolated_check_clicked == false and
    (($officialStatus == "not connected" and .official_open_signin_link_action_visible == false) or
     ($officialStatus == "device login pending" and .official_open_signin_link_action_visible == true) or
     ($officialStatus == "login available" or $officialStatus == "route verified")) and
    .official_open_signin_link_clicked == false and
    .header_models_match_unified_models == true and
    .real_quit_menu_visible == true and
    .outside_click_closes_popover == true and
    .connect_first_screen_locked == true and
    .protocol_tag_distinguishes_codex_route_and_upstream == true and
    .real_demo_provider_clicked == true and
    .real_demo_provider_config_path == true and
    .real_demo_base_url_visible == true and
    .real_demo_key_saved_visible == true and
    .real_demo_models_visible == true and
    .provider_edit_base_url_prefilled == true and
    .provider_edit_models_loaded == true and
    .provider_health_summary_visible == true and
    .provider_health_saved_count == 2 and
    .provider_health_available_count == 1 and
    .provider_health_hidden_count == 1 and
    .provider_model_reachable_row_visible == true and
    .provider_model_unavailable_row_visible == true and
    .provider_light_modal_opened == true and
    .provider_dark_modal_opened == true and
    .provider_hidden_models_toggle_visible == true and
    .provider_hidden_model_reasons_visible == true and
    .saved_key_plaintext_hidden == true and
    .saved_key_state_visible == true and
    .api_key_masked_field_visible == true and
    .api_key_saved_mask_control_visible == true and
    .api_key_saved_eye_visible == true and
    .saved_key_fake_eye_visible == false and
    .saved_key_disabled_eye_reason_visible == false and
    .saved_key_eye_toggle_works == true and
    .api_key_replace_visible == false and
    .api_key_new_eye_visible == true and
    .new_key_eye_toggle_works == true and
    .api_key_replace_available == false and
    .provider_test_connection_visible == true and
    .provider_test_success_connected == true and
    .provider_connection_counts_separated == true and
    .provider_connection_use_reachable_visible == true and
    .provider_connection_used_reachable_models_only == true and
    .provider_test_failure_network == true and
    .provider_click_flow_real_ax == true and
    .advanced_default_collapsed == true and
    .advanced_toggle_row_visible == true and
    .advanced_scrollable_when_expanded == true and
    .advanced_has_protocol_selector == true and
    .advanced_has_custom_models_url == true and
    .advanced_has_custom_auth_header == true and
    .advanced_has_upstream_model_override == true and
    .advanced_raw_fields_hidden == true and
    .advanced_can_collapse_after_expand == true and
    .usage_has_real_rows == true and
    .usage_auto_refresh_enabled == true and
    .usage_auto_refresh_updates_without_restart == true and
    .usage_summary_background == true and
    .usage_large_fixture_requests == 1800 and
    .usage_large_fixture_duration_ms < 5000 and
    .usage_empty_state_visible == true and
    .usage_today_tokens == 150 and
    .usage_today_tokens_label == "150" and
    .usage_seven_day_tokens == 750 and
    .usage_seven_day_tokens_label == "750" and
    .usage_all_time_tokens == 775 and
    .usage_all_time_tokens_label == "775" and
    .usage_requests == 7 and
    .usage_top_model_7d == "demo/claude-sonnet-4-6" and
    .usage_top_model_7d_readable == "claude-sonnet-4-6" and
    .usage_top_model_readable_visible == true and
    .usage_provider_groups == ["Official Codex / OpenAI","Third-party providers"] and
    .usage_provider_source_shifted == true and
    .usage_activity_heatmap_visible == true and
    .usage_activity_range_control_visible == true and
    .usage_activity_unit_labels == ["7D · half-day","1M · daily","1Y · weekly"] and
    .usage_activity_unit_label_visible == true and
    .usage_cost_unavailable_visible == true and
    .usage_token_unit_formatting == true and
    .settings_general_group_visible == true and
    .settings_gateway_group_visible == true and
    .settings_codex_group_visible == true and
    .settings_data_privacy_group_visible == true and
    .settings_developer_collapsed_by_default == true and
    .settings_developer_expands == true and
    .settings_manual_proof_hidden_when_collapsed == true and
    .settings_manual_proof_visible_when_expanded == true and
    .settings_gateway_port_isolated == true and
    .settings_global_codex_activate_visible == false and
    .global_config_auth_access_mode == "isolated-not-accessed"
  ' "${evidence}" >/dev/null 2>&1; then
    return 0
  else
    rc="$?"
  fi

  if ! diagnostic="$(jq -r '
    def field_type($key):
      if has($key) | not then "missing" else .[$key] | type end;
    . as $document |
    .official_current_status as $officialStatus |
    [
      {label:"provider_config_path_is_app_support", key:"provider_config_path_is_app_support", pass:(.provider_config_path_is_app_support == false)},
      {label:"stale_tmp_provider_config_recovered", key:"stale_tmp_provider_config_recovered", pass:(.stale_tmp_provider_config_recovered == false)},
      {label:"status_summary_inline", key:"status_summary_inline", pass:(.status_summary_inline == true)},
      {label:"model_access_and_model_list_merged", key:"model_access_and_model_list_merged", pass:(.model_access_and_model_list_merged == true)},
      {label:"duplicate_empty_state", key:"duplicate_empty_state", pass:(.duplicate_empty_state == false)},
      {label:"official_provider_row_visible", key:"official_provider_row_visible", pass:(.official_provider_row_visible == true)},
      {label:"official_provider_row_managed_by_relaykit", key:"official_provider_row_managed_by_relaykit", pass:(.official_provider_row_managed_by_relaykit == true)},
      {label:"official_sheet_opened", key:"official_sheet_opened", pass:(.official_sheet_opened == true)},
      {label:"official_light_sheet_opened", key:"official_light_sheet_opened", pass:(.official_light_sheet_opened == true)},
      {label:"official_dark_sheet_opened", key:"official_dark_sheet_opened", pass:(.official_dark_sheet_opened == true)},
      {label:"official_auth_required_visible", key:"official_auth_required_visible", pass:(.official_auth_required_visible == false)},
      {label:"official_auth_cta_visible", key:"official_auth_cta_visible", pass:(.official_auth_cta_visible == true)},
      {label:"official_auth_cta_clicked_by_status", key:"official_auth_cta_clicked", pass:((($officialStatus == "not connected" and .official_auth_cta_clicked == false) or ($officialStatus == "device login pending" and .official_auth_cta_clicked == true) or (($officialStatus == "login available" or $officialStatus == "route verified") and .official_auth_cta_clicked == false)))},
      {label:"official_auth_cta_has_real_action", key:"official_auth_cta_has_real_action", pass:(.official_auth_cta_has_real_action == true)},
      {label:"official_auth_cta_disabled_as_unimplemented", key:"official_auth_cta_disabled_as_unimplemented", pass:(.official_auth_cta_disabled_as_unimplemented == false)},
      {label:"official_auth_unimplemented_visible", key:"official_auth_unimplemented_visible", pass:(.official_auth_unimplemented_visible == false)},
      {label:"official_auth_progress_by_status", key:"official_auth_in_progress", pass:((($officialStatus == "not connected" and .official_auth_in_progress == false) or ($officialStatus == "device login pending" and .official_auth_in_progress == true and .official_auth_process_id_present == true) or (($officialStatus == "login available" or $officialStatus == "route verified") and .official_auth_in_progress == false)))},
      {label:"official_connected_state_by_status", key:"official_connected_by_login_status", pass:((($officialStatus == "not connected" and .official_connected_by_login_status == false) or ($officialStatus == "device login pending" and .official_device_url_captured == true and .official_device_code_captured == true and .official_device_code_copied == true and .official_copy_device_code_action_visible == true and .official_copy_device_code_clicked == true) or (($officialStatus == "login available" or $officialStatus == "route verified") and .official_connected_by_login_status == true and .official_connected_cta_disabled == true and .official_connected_device_code_hidden == true and .official_connected_click_does_not_start_login == true)))},
      {label:"official_credential_ref_by_status", key:"official_credential_ref_exists", pass:(($officialStatus == "not connected" or .official_credential_ref_exists == true))},
      {label:"official_current_status_allowed", key:"official_current_status", pass:(($officialStatus == "not connected" or $officialStatus == "device login pending" or $officialStatus == "login available" or $officialStatus == "route verified"))},
      {label:"official_connected_by_login_status_matches", key:"official_connected_by_login_status", pass:(.official_connected_by_login_status == ($officialStatus == "login available" or $officialStatus == "route verified"))},
      {label:"official_route_verified_status_matches", key:"official_route_verified_status", pass:(.official_route_verified_status == ($officialStatus == "route verified"))},
      {label:"official_device_login_visible_by_status", key:"official_device_login_visible", pass:((($officialStatus == "not connected" and .official_device_login_visible == false) or ($officialStatus == "device login pending" and .official_device_login_visible == true) or ($officialStatus == "login available" or $officialStatus == "route verified")))},
      {label:"official_product_actions_visible", key:"official_product_actions_visible", pass:(.official_product_actions_visible == true)},
      {label:"official_authenticate_action_visible", key:"official_authenticate_action_visible", pass:(.official_authenticate_action_visible == true)},
      {label:"official_status_refresh_action_visible", key:"official_status_refresh_action_visible", pass:(.official_status_refresh_action_visible == true)},
      {label:"official_reauth_action_visible", key:"official_reauth_action_visible", pass:(.official_reauth_action_visible == false)},
      {label:"official_disconnect_action_visible", key:"official_disconnect_action_visible", pass:(.official_disconnect_action_visible == true)},
      {label:"official_isolated_desktop_entry_visible", key:"official_isolated_desktop_entry_visible", pass:(.official_isolated_desktop_entry_visible == false)},
      {label:"official_token_boundary_visible", key:"official_token_boundary_visible", pass:(.official_token_boundary_visible == true)},
      {label:"official_debug_status_visible", key:"official_debug_status_visible", pass:(.official_debug_status_visible == false)},
      {label:"official_debug_actions_visible", key:"official_debug_actions_visible", pass:(.official_debug_actions_visible == false)},
      {label:"official_mock_passthrough_status_visible", key:"official_mock_passthrough_status_visible", pass:(.official_mock_passthrough_status_visible == false)},
      {label:"official_not_connected_status_visible", key:"official_not_connected_status_visible", pass:(.official_not_connected_status_visible == ($officialStatus == "not connected"))},
      {label:"official_device_login_pending_status_visible_type", key:"official_device_login_pending_status_visible", pass:((.official_device_login_pending_status_visible | type) == "boolean")},
      {label:"official_login_available_status_visible_type", key:"official_login_available_status_visible", pass:((.official_login_available_status_visible | type) == "boolean")},
      {label:"official_route_verified_status_visible_type", key:"official_route_verified_status_visible", pass:((.official_route_verified_status_visible | type) == "boolean")},
      {label:"official_state_details_collapsed", key:"official_state_details_collapsed", pass:(.official_state_details_collapsed == true)},
      {label:"official_state_details_expanded", key:"official_state_details_expanded", pass:(.official_state_details_expanded == false)},
      {label:"official_login_required_status_visible", key:"official_login_required_status_visible", pass:(.official_login_required_status_visible == false)},
      {label:"official_real_auth_not_verified_visible", key:"official_real_auth_not_verified_visible", pass:(.official_real_auth_not_verified_visible == false)},
      {label:"official_open_codex_desktop_action_visible", key:"official_open_codex_desktop_action_visible", pass:(.official_open_codex_desktop_action_visible == false)},
      {label:"official_run_isolated_check_action_visible", key:"official_run_isolated_check_action_visible", pass:(.official_run_isolated_check_action_visible == false)},
      {label:"official_copy_command_action_visible", key:"official_copy_command_action_visible", pass:(.official_copy_command_action_visible == false)},
      {label:"official_run_isolated_check_clicked", key:"official_run_isolated_check_clicked", pass:(.official_run_isolated_check_clicked == false)},
      {label:"official_open_signin_link_by_status", key:"official_open_signin_link_action_visible", pass:((($officialStatus == "not connected" and .official_open_signin_link_action_visible == false) or ($officialStatus == "device login pending" and .official_open_signin_link_action_visible == true) or ($officialStatus == "login available" or $officialStatus == "route verified")))},
      {label:"official_open_signin_link_clicked", key:"official_open_signin_link_clicked", pass:(.official_open_signin_link_clicked == false)},
      {label:"header_models_match_unified_models", key:"header_models_match_unified_models", pass:(.header_models_match_unified_models == true)},
      {label:"real_quit_menu_visible", key:"real_quit_menu_visible", pass:(.real_quit_menu_visible == true)},
      {label:"outside_click_closes_popover", key:"outside_click_closes_popover", pass:(.outside_click_closes_popover == true)},
      {label:"connect_first_screen_locked", key:"connect_first_screen_locked", pass:(.connect_first_screen_locked == true)},
      {label:"protocol_tag_distinguishes_codex_route_and_upstream", key:"protocol_tag_distinguishes_codex_route_and_upstream", pass:(.protocol_tag_distinguishes_codex_route_and_upstream == true)},
      {label:"real_demo_provider_clicked", key:"real_demo_provider_clicked", pass:(.real_demo_provider_clicked == true)},
      {label:"real_demo_provider_config_path", key:"real_demo_provider_config_path", pass:(.real_demo_provider_config_path == true)},
      {label:"real_demo_base_url_visible", key:"real_demo_base_url_visible", pass:(.real_demo_base_url_visible == true)},
      {label:"real_demo_key_saved_visible", key:"real_demo_key_saved_visible", pass:(.real_demo_key_saved_visible == true)},
      {label:"real_demo_models_visible", key:"real_demo_models_visible", pass:(.real_demo_models_visible == true)},
      {label:"provider_edit_base_url_prefilled", key:"provider_edit_base_url_prefilled", pass:(.provider_edit_base_url_prefilled == true)},
      {label:"provider_edit_models_loaded", key:"provider_edit_models_loaded", pass:(.provider_edit_models_loaded == true)},
      {label:"provider_health_summary_visible", key:"provider_health_summary_visible", pass:(.provider_health_summary_visible == true)},
      {label:"provider_health_saved_count", key:"provider_health_saved_count", pass:(.provider_health_saved_count == 2)},
      {label:"provider_health_available_count", key:"provider_health_available_count", pass:(.provider_health_available_count == 1)},
      {label:"provider_health_hidden_count", key:"provider_health_hidden_count", pass:(.provider_health_hidden_count == 1)},
      {label:"provider_model_reachable_row_visible", key:"provider_model_reachable_row_visible", pass:(.provider_model_reachable_row_visible == true)},
      {label:"provider_model_unavailable_row_visible", key:"provider_model_unavailable_row_visible", pass:(.provider_model_unavailable_row_visible == true)},
      {label:"provider_light_modal_opened", key:"provider_light_modal_opened", pass:(.provider_light_modal_opened == true)},
      {label:"provider_dark_modal_opened", key:"provider_dark_modal_opened", pass:(.provider_dark_modal_opened == true)},
      {label:"provider_hidden_models_toggle_visible", key:"provider_hidden_models_toggle_visible", pass:(.provider_hidden_models_toggle_visible == true)},
      {label:"provider_hidden_model_reasons_visible", key:"provider_hidden_model_reasons_visible", pass:(.provider_hidden_model_reasons_visible == true)},
      {label:"saved_key_plaintext_hidden", key:"saved_key_plaintext_hidden", pass:(.saved_key_plaintext_hidden == true)},
      {label:"saved_key_state_visible", key:"saved_key_state_visible", pass:(.saved_key_state_visible == true)},
      {label:"api_key_masked_field_visible", key:"api_key_masked_field_visible", pass:(.api_key_masked_field_visible == true)},
      {label:"api_key_saved_mask_control_visible", key:"api_key_saved_mask_control_visible", pass:(.api_key_saved_mask_control_visible == true)},
      {label:"api_key_saved_eye_visible", key:"api_key_saved_eye_visible", pass:(.api_key_saved_eye_visible == true)},
      {label:"saved_key_fake_eye_visible", key:"saved_key_fake_eye_visible", pass:(.saved_key_fake_eye_visible == false)},
      {label:"saved_key_disabled_eye_reason_visible", key:"saved_key_disabled_eye_reason_visible", pass:(.saved_key_disabled_eye_reason_visible == false)},
      {label:"saved_key_eye_toggle_works", key:"saved_key_eye_toggle_works", pass:(.saved_key_eye_toggle_works == true)},
      {label:"api_key_replace_visible", key:"api_key_replace_visible", pass:(.api_key_replace_visible == false)},
      {label:"api_key_new_eye_visible", key:"api_key_new_eye_visible", pass:(.api_key_new_eye_visible == true)},
      {label:"new_key_eye_toggle_works", key:"new_key_eye_toggle_works", pass:(.new_key_eye_toggle_works == true)},
      {label:"api_key_replace_available", key:"api_key_replace_available", pass:(.api_key_replace_available == false)},
      {label:"provider_test_connection_visible", key:"provider_test_connection_visible", pass:(.provider_test_connection_visible == true)},
      {label:"provider_test_success_connected", key:"provider_test_success_connected", pass:(.provider_test_success_connected == true)},
      {label:"provider_connection_counts_separated", key:"provider_connection_counts_separated", pass:(.provider_connection_counts_separated == true)},
      {label:"provider_connection_use_reachable_visible", key:"provider_connection_use_reachable_visible", pass:(.provider_connection_use_reachable_visible == true)},
      {label:"provider_connection_used_reachable_models_only", key:"provider_connection_used_reachable_models_only", pass:(.provider_connection_used_reachable_models_only == true)},
      {label:"provider_test_failure_network", key:"provider_test_failure_network", pass:(.provider_test_failure_network == true)},
      {label:"provider_click_flow_real_ax", key:"provider_click_flow_real_ax", pass:(.provider_click_flow_real_ax == true)},
      {label:"advanced_default_collapsed", key:"advanced_default_collapsed", pass:(.advanced_default_collapsed == true)},
      {label:"advanced_toggle_row_visible", key:"advanced_toggle_row_visible", pass:(.advanced_toggle_row_visible == true)},
      {label:"advanced_scrollable_when_expanded", key:"advanced_scrollable_when_expanded", pass:(.advanced_scrollable_when_expanded == true)},
      {label:"advanced_has_protocol_selector", key:"advanced_has_protocol_selector", pass:(.advanced_has_protocol_selector == true)},
      {label:"advanced_has_custom_models_url", key:"advanced_has_custom_models_url", pass:(.advanced_has_custom_models_url == true)},
      {label:"advanced_has_custom_auth_header", key:"advanced_has_custom_auth_header", pass:(.advanced_has_custom_auth_header == true)},
      {label:"advanced_has_upstream_model_override", key:"advanced_has_upstream_model_override", pass:(.advanced_has_upstream_model_override == true)},
      {label:"advanced_raw_fields_hidden", key:"advanced_raw_fields_hidden", pass:(.advanced_raw_fields_hidden == true)},
      {label:"advanced_can_collapse_after_expand", key:"advanced_can_collapse_after_expand", pass:(.advanced_can_collapse_after_expand == true)},
      {label:"usage_has_real_rows", key:"usage_has_real_rows", pass:(.usage_has_real_rows == true)},
      {label:"usage_auto_refresh_enabled", key:"usage_auto_refresh_enabled", pass:(.usage_auto_refresh_enabled == true)},
      {label:"usage_auto_refresh_updates_without_restart", key:"usage_auto_refresh_updates_without_restart", pass:(.usage_auto_refresh_updates_without_restart == true)},
      {label:"usage_summary_background", key:"usage_summary_background", pass:(.usage_summary_background == true)},
      {label:"usage_large_fixture_requests", key:"usage_large_fixture_requests", pass:(.usage_large_fixture_requests == 1800)},
      {label:"usage_large_fixture_duration_ms", key:"usage_large_fixture_duration_ms", pass:(.usage_large_fixture_duration_ms < 5000)},
      {label:"usage_empty_state_visible", key:"usage_empty_state_visible", pass:(.usage_empty_state_visible == true)},
      {label:"usage_today_tokens", key:"usage_today_tokens", pass:(.usage_today_tokens == 150)},
      {label:"usage_today_tokens_label", key:"usage_today_tokens_label", pass:(.usage_today_tokens_label == "150")},
      {label:"usage_seven_day_tokens", key:"usage_seven_day_tokens", pass:(.usage_seven_day_tokens == 750)},
      {label:"usage_seven_day_tokens_label", key:"usage_seven_day_tokens_label", pass:(.usage_seven_day_tokens_label == "750")},
      {label:"usage_all_time_tokens", key:"usage_all_time_tokens", pass:(.usage_all_time_tokens == 775)},
      {label:"usage_all_time_tokens_label", key:"usage_all_time_tokens_label", pass:(.usage_all_time_tokens_label == "775")},
      {label:"usage_requests", key:"usage_requests", pass:(.usage_requests == 7)},
      {label:"usage_top_model_7d", key:"usage_top_model_7d", pass:(.usage_top_model_7d == "demo/claude-sonnet-4-6")},
      {label:"usage_top_model_7d_readable", key:"usage_top_model_7d_readable", pass:(.usage_top_model_7d_readable == "claude-sonnet-4-6")},
      {label:"usage_top_model_readable_visible", key:"usage_top_model_readable_visible", pass:(.usage_top_model_readable_visible == true)},
      {label:"usage_provider_groups", key:"usage_provider_groups", pass:(.usage_provider_groups == ["Official Codex / OpenAI","Third-party providers"])},
      {label:"usage_provider_source_shifted", key:"usage_provider_source_shifted", pass:(.usage_provider_source_shifted == true)},
      {label:"usage_activity_heatmap_visible", key:"usage_activity_heatmap_visible", pass:(.usage_activity_heatmap_visible == true)},
      {label:"usage_activity_range_control_visible", key:"usage_activity_range_control_visible", pass:(.usage_activity_range_control_visible == true)},
      {label:"usage_activity_unit_labels", key:"usage_activity_unit_labels", pass:(.usage_activity_unit_labels == ["7D · half-day","1M · daily","1Y · weekly"])},
      {label:"usage_activity_unit_label_visible", key:"usage_activity_unit_label_visible", pass:(.usage_activity_unit_label_visible == true)},
      {label:"usage_cost_unavailable_visible", key:"usage_cost_unavailable_visible", pass:(.usage_cost_unavailable_visible == true)},
      {label:"usage_token_unit_formatting", key:"usage_token_unit_formatting", pass:(.usage_token_unit_formatting == true)},
      {label:"settings_general_group_visible", key:"settings_general_group_visible", pass:(.settings_general_group_visible == true)},
      {label:"settings_gateway_group_visible", key:"settings_gateway_group_visible", pass:(.settings_gateway_group_visible == true)},
      {label:"settings_codex_group_visible", key:"settings_codex_group_visible", pass:(.settings_codex_group_visible == true)},
      {label:"settings_data_privacy_group_visible", key:"settings_data_privacy_group_visible", pass:(.settings_data_privacy_group_visible == true)},
      {label:"settings_developer_collapsed_by_default", key:"settings_developer_collapsed_by_default", pass:(.settings_developer_collapsed_by_default == true)},
      {label:"settings_developer_expands", key:"settings_developer_expands", pass:(.settings_developer_expands == true)},
      {label:"settings_manual_proof_hidden_when_collapsed", key:"settings_manual_proof_hidden_when_collapsed", pass:(.settings_manual_proof_hidden_when_collapsed == true)},
      {label:"settings_manual_proof_visible_when_expanded", key:"settings_manual_proof_visible_when_expanded", pass:(.settings_manual_proof_visible_when_expanded == true)},
      {label:"settings_gateway_port_isolated", key:"settings_gateway_port_isolated", pass:(.settings_gateway_port_isolated == true)},
      {label:"settings_global_codex_activate_visible", key:"settings_global_codex_activate_visible", pass:(.settings_global_codex_activate_visible == false)},
      {label:"global_config_auth_access_mode", key:"global_config_auth_access_mode", pass:(.global_config_auth_access_mode == "isolated-not-accessed")}
    ] |
    first(.[] | select(.pass != true)) as $failed |
    if $failed == null then "parse-or-schema\tinvalid"
    else "\($failed.label)\t\($document | field_type($failed.key))"
    end
  ' "${evidence}" 2>/dev/null)"; then
    diagnostic=$'parse-or-schema\tinvalid'
  fi
  label="${diagnostic%%$'\t'*}"
  json_type="${diagnostic#*$'\t'}"
  case "${json_type}" in
    object|array|string|number|boolean|null|missing|invalid) ;;
    *) label=parse-or-schema; json_type=invalid ;;
  esac
  case "${label}" in
    provider_config_path_is_app_support|stale_tmp_provider_config_recovered|status_summary_inline|model_access_and_model_list_merged|duplicate_empty_state|official_provider_row_visible|official_provider_row_managed_by_relaykit|official_sheet_opened|official_light_sheet_opened|official_dark_sheet_opened|official_auth_required_visible|official_auth_cta_visible|official_auth_cta_clicked_by_status|official_auth_cta_has_real_action|official_auth_cta_disabled_as_unimplemented|official_auth_unimplemented_visible|official_auth_progress_by_status|official_connected_state_by_status|official_credential_ref_by_status|official_current_status_allowed|official_connected_by_login_status_matches|official_route_verified_status_matches|official_device_login_visible_by_status|official_product_actions_visible|official_authenticate_action_visible|official_status_refresh_action_visible|official_reauth_action_visible|official_disconnect_action_visible|official_isolated_desktop_entry_visible|official_token_boundary_visible|official_debug_status_visible|official_debug_actions_visible|official_mock_passthrough_status_visible|official_not_connected_status_visible|official_device_login_pending_status_visible_type|official_login_available_status_visible_type|official_route_verified_status_visible_type|official_state_details_collapsed|official_state_details_expanded|official_login_required_status_visible|official_real_auth_not_verified_visible|official_open_codex_desktop_action_visible|official_run_isolated_check_action_visible|official_copy_command_action_visible|official_run_isolated_check_clicked|official_open_signin_link_by_status|official_open_signin_link_clicked|header_models_match_unified_models|real_quit_menu_visible|outside_click_closes_popover|connect_first_screen_locked|protocol_tag_distinguishes_codex_route_and_upstream|real_demo_provider_clicked|real_demo_provider_config_path|real_demo_base_url_visible|real_demo_key_saved_visible|real_demo_models_visible|provider_edit_base_url_prefilled|provider_edit_models_loaded|provider_health_summary_visible|provider_health_saved_count|provider_health_available_count|provider_health_hidden_count|provider_model_reachable_row_visible|provider_model_unavailable_row_visible|provider_light_modal_opened|provider_dark_modal_opened|provider_hidden_models_toggle_visible|provider_hidden_model_reasons_visible|saved_key_plaintext_hidden|saved_key_state_visible|api_key_masked_field_visible|api_key_saved_mask_control_visible|api_key_saved_eye_visible|saved_key_fake_eye_visible|saved_key_disabled_eye_reason_visible|saved_key_eye_toggle_works|api_key_replace_visible|api_key_new_eye_visible|new_key_eye_toggle_works|api_key_replace_available|provider_test_connection_visible|provider_test_success_connected|provider_connection_counts_separated|provider_connection_use_reachable_visible|provider_connection_used_reachable_models_only|provider_test_failure_network|provider_click_flow_real_ax|advanced_default_collapsed|advanced_toggle_row_visible|advanced_scrollable_when_expanded|advanced_has_protocol_selector|advanced_has_custom_models_url|advanced_has_custom_auth_header|advanced_has_upstream_model_override|advanced_raw_fields_hidden|advanced_can_collapse_after_expand|usage_has_real_rows|usage_auto_refresh_enabled|usage_auto_refresh_updates_without_restart|usage_summary_background|usage_large_fixture_requests|usage_large_fixture_duration_ms|usage_empty_state_visible|usage_today_tokens|usage_today_tokens_label|usage_seven_day_tokens|usage_seven_day_tokens_label|usage_all_time_tokens|usage_all_time_tokens_label|usage_requests|usage_top_model_7d|usage_top_model_7d_readable|usage_top_model_readable_visible|usage_provider_groups|usage_provider_source_shifted|usage_activity_heatmap_visible|usage_activity_range_control_visible|usage_activity_unit_labels|usage_activity_unit_label_visible|usage_cost_unavailable_visible|usage_token_unit_formatting|settings_general_group_visible|settings_gateway_group_visible|settings_codex_group_visible|settings_data_privacy_group_visible|settings_developer_collapsed_by_default|settings_developer_expands|settings_manual_proof_hidden_when_collapsed|settings_manual_proof_visible_when_expanded|settings_gateway_port_isolated|settings_global_codex_activate_visible|global_config_auth_access_mode|parse-or-schema) ;;
    *) label=parse-or-schema; json_type=invalid ;;
  esac
  printf 'AGGREGATE_FIRST_FAILED_CONJUNCT=%s type=%s\n' "${label}" "${json_type}" >&2
  return "${rc}"
}

capture_context_is_valid() {
  case "$1" in
    connect|official-sheet|real-demo|provider-click-flow|provider-test-failure|detail|detail-advanced-expanded|detail-advanced-collapsed|import|usage|usage-auto-refresh|usage-large|usage-1m|usage-1y|usage-empty|settings|settings-developer-expanded|settings-light|usage-light|official-light|provider-light|settings-dark|usage-dark|official-dark|provider-dark|provider|real-quit|outside-click) return 0 ;;
    *) return 2 ;;
  esac
}

set_capture_app_launch_stage() {
  local context="$1"
  local phase="$2"
  capture_context_is_valid "${context}" || return $?
  case "${phase}" in
    spawn|identity-wait|register) set_stage "capture.${context}.app-launch.${phase}" ;;
    *) return 2 ;;
  esac
}

set_capture_app_identity_stage() {
  local context="$1"
  local category="$2"
  capture_context_is_valid "${context}" || return $?
  case "${category}" in
    pid-invalid|pid-not-alive|proc-pidpath-unavailable|expected-canonical-unavailable|executable-mismatch|success)
      set_stage "capture.${context}.app-identity.${category}"
      ;;
    *) return 2 ;;
  esac
}

if [[ "${RELAYKIT_MENU_BAR_VISUAL_SYNTHETIC_TEST:-0}" == "1" ]]; then
  visual_action self-test connect
  exit $?
fi

if [[ "${RELAYKIT_MENU_BAR_E2E_SOURCE_ONLY:-0}" == "1" ]]; then
  return 0 2>/dev/null || exit 0
fi

case "${RELAYKIT_WINDOW_EQUIVALENCE_DIAGNOSTIC_TARGET:-}" in
  ""|outside-click|first-ambiguity|connect-root-anchor-observations|connect-root-public-anchor-candidates) ;;
  first-ambiguity-private-visual)
    if ! private_visual_diagnostic_dir_is_valid "${RELAYKIT_PRIVATE_VISUAL_DIAGNOSTIC_DIR:-}"; then
      FAILURE_REPORTED=1
      exit 2
    fi
    ;;
  *) exit 2 ;;
esac

wait_for_jq() {
  local evidence="$1"
  local expression="$2"
  for _ in {1..60}; do
    if jq -e "${expression}" "${evidence}" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.2
  done
  jq -e "${expression}" "${evidence}" >/dev/null
}

require_app_identity() {
  local context="$1"
  local actual expected_canonical
  capture_context_is_valid "${context}" || return $?
  if [[ ! "${PID}" =~ ^[0-9]+$ ]] || ((PID <= 1)); then
    set_capture_app_identity_stage "${context}" pid-invalid
    echo "isolated RelayKit PID identity changed" >&2
    return 1
  fi
  if ! visual_pid_is_alive "${PID}"; then
    set_capture_app_identity_stage "${context}" pid-not-alive
    echo "isolated RelayKit PID identity changed" >&2
    return 1
  fi
  if ! actual="$(process_executable_path "${PID}")"; then
    set_capture_app_identity_stage "${context}" proc-pidpath-unavailable
    echo "isolated RelayKit PID identity changed" >&2
    return 1
  fi
  if ! expected_canonical="$(canonical_executable_path "${APP_REAL}")"; then
    set_capture_app_identity_stage "${context}" expected-canonical-unavailable
    echo "isolated RelayKit PID identity changed" >&2
    return 1
  fi
  if [[ "${actual}" != "${expected_canonical}" ]]; then
    set_capture_app_identity_stage "${context}" executable-mismatch
    echo "isolated RelayKit PID identity changed" >&2
    return 1
  fi
  set_capture_app_identity_stage "${context}" success
}

appearance_for_capture() {
  case "$1" in
    settings-light|usage-light|official-light|provider-light) printf 'light\n' ;;
    settings-dark|usage-dark|official-dark|provider-dark) printf 'dark\n' ;;
    connect|official-sheet|real-demo|provider-click-flow|provider-test-failure|detail|detail-advanced-expanded|detail-advanced-collapsed|import|usage|usage-auto-refresh|usage-large|usage-1m|usage-1y|usage-empty|settings|settings-developer-expanded|provider|real-quit|outside-click) printf 'system\n' ;;
    *) return 2 ;;
  esac
}

launch_isolated_app() {
  local context="$1"
  set_capture_app_launch_stage "${context}" spawn || return $?
  shift
  local log="$1"
  shift
  (
    cd "${RUNTIME_ROOT}"
    exec "${APP_REAL}" "$@"
  ) >"${log}" 2>&1 &
  PID="$!"
  set_capture_app_launch_stage "${context}" identity-wait
  wait_for_process_executable_match "${PID}" "${APP_REAL}"
  set_capture_app_launch_stage "${context}" register
  register_owned_pid "${PID}" "${APP_REAL}"
}

prepare_capture_prefix() {
  local context="$1"
  local evidence="$2"
  local log="$3"
  local required
  capture_context_is_valid "${context}" || return $?
  sleep 3
  if ! require_app_identity "${context}"; then
    cat "${log}" >&2
    exit 1
  fi
  set_stage evidence.wait
  for _ in {1..120}; do
    [[ -s "${evidence}" ]] && break
    sleep 0.25
  done
  test -s "${evidence}"
  case "${context}" in
    connect|official-sheet|official-light|official-dark|provider-click-flow|provider-light|provider-dark|real-demo) required='["tab-connect","cli-route","local-cli-scan","cli-selected-state","codex-target-state","claude-disabled-placeholder","configured-providers","import-candidates","status-summary-inline","model-access-merged","official-provider-row","add-strip","auth-blocked-state"]' ;;
    detail|detail-advanced-expanded|detail-advanced-collapsed|provider-test-failure) required='["tab-connect","cli-route","local-cli-scan","cli-selected-state","codex-target-state","claude-disabled-placeholder","configured-providers","import-candidates","provider-edit-modal","configured-provider-row-action","add-strip","auth-blocked-state","provider-codex-route-chip","provider-upstream-protocol-chip","provider-connection-test-entry"]' ;;
    import) required='["tab-connect","cli-route","local-cli-scan","cli-selected-state","codex-target-state","claude-disabled-placeholder","configured-providers","import-candidates","provider-import-modal","provider-import-mode","provider-import-prefilled-fields","provider-model-table","discovered-row-action","add-strip","auth-blocked-state"]' ;;
    usage|usage-light|usage-dark|usage-auto-refresh|usage-large|usage-1m|usage-1y) required='["tab-usage","usage-kpis","usage-provider-groups","usage-model-rollups","usage-activity-heatmap","usage-activity-range-control","usage-cost-unavailable","usage-auto-refresh-enabled","usage-activity-unit-label","usage-top-model-readable"]' ;;
    usage-empty) required='["tab-usage","usage-kpis","usage-provider-groups","usage-model-rollups","usage-activity-heatmap","usage-activity-range-control","usage-cost-unavailable","usage-empty-state"]' ;;
    settings|settings-light|settings-dark|settings-developer-expanded) required='["tab-settings","appearance-control","launch-login-control","settings-general-group","settings-gateway-group","settings-codex-group","settings-data-privacy-group","settings-developer-group","settings-developer-collapsed","settings-actions","advanced-paths"]' ;;
    provider) required='["add-strip","add-strip-action","tab-provider","provider-modal","provider-add-mode","provider-name-field","provider-base-url-field","provider-api-key-field","provider-connection-test-entry","provider-model-detection-entry","provider-model-table","provider-model-row","provider-model-id-main-field","provider-advanced-options"]' ;;
    *) required='[]' ;;
  esac
  set_capture_evidence_stage "${context}" generic-jq
  jq -e --argjson required "${required}" '
    . as $doc |
    $doc.status_item.visible == true and
    $doc.status_item.width > 0 and
    $doc.popover.shown == true and
    $doc.popover.ordinary_window == false and
    $doc.surface.kind == "menu-bar-popover" and
    ($doc.settings.appearance_mode | test("^(system|light|dark)$")) and
    ($doc.settings.launch_at_login_requested | type == "boolean") and
    ($doc.settings.launch_at_login_status | type == "string") and
    ($doc.connect.model_ids_redacted == true) and
    ($doc.connect.source_names_redacted == true) and
    ($doc.connect.demo_model_rows_present == false) and
    ($doc.surface.sections | index("global-status")) and
    (all($required[]; . as $section | ($doc.surface.sections | index($section))))
  ' "${evidence}" >/dev/null
}

capture() {
  local name="$1"
  shift
  local evidence="${OUT}/${name}.json"
  local appearance
  appearance="$(appearance_for_capture "${name}")"
  cleanup_current_app
  launch_isolated_app "${name}" "${TMPDIR}ui-smoke.log" --ui-smoke --ui-smoke-keep-open --ui-smoke-skip-gateway-exercise --ui-smoke-evidence "${evidence}" --ui-smoke-catalog-url "${CATALOG_URL}" "$@" --ui-smoke-usage-log "${USAGE_LOG_EMPTY}" --ui-smoke-appearance "${appearance}"
  prepare_capture_prefix "${name}" "${evidence}" "${TMPDIR}ui-smoke.log"
  set_capture_window_readiness_stage "${name}"
  if [[ "${RELAYKIT_MENU_BAR_WINDOW_EQUIVALENCE_DIAGNOSTIC:-0}" == "1" ]]; then
    local diagnostic_rc
    [[ "${name}" == "connect" ]] || return 2
    if visual_probe_window "${name}"; then
      diagnostic_rc=0
      set_stage capture.connect.window-equivalence-diagnostic-complete
    else
      diagnostic_rc="$?"
    fi
    cleanup_current_app
    FAILURE_REPORTED=1
    exit "${diagnostic_rc}"
  fi
  wait_for_capture_window_ready "${name}"
  set_capture_evidence_stage "${name}" specific-jq
  if [[ "${name}" == "connect" ]]; then
    jq -e '
      . as $doc |
      $doc.connect.provider_config_path_is_app_support == false and
      $doc.connect.stale_tmp_provider_config_recovered == false and
      (all($doc.connect.configured_provider_labels[]; test("Fixture Provider|Saved Key Provider") | not)) and
      $doc.connect.status_summary_inline == true and
      $doc.connect.model_access_and_model_list_merged == true and
      $doc.connect.duplicate_empty_state == false and
      $doc.connect.official_provider_row_visible == true and
      $doc.connect.official_provider_row_managed_by_relaykit == true and
      $doc.connect.header_models_match_unified_models == true and
      ($doc.connect.configured_provider_labels | length) == $doc.connect.configured_provider_count and
      $doc.connect.discovered_catalog_model_count == 3 and
      $doc.connect.discovered_catalog_source_group_count > 0 and
      $doc.connect.display_mode == "model-access" and
      $doc.connect.unified_model_count >= $doc.connect.unified_model_catalog_count and
      $doc.connect.unified_model_configured_count == ($doc.connect.configured_provider_model_labels | length) and
      $doc.connect.unified_model_catalog_count == 3 and
      $doc.connect.unified_model_has_official_and_provider_catalog_fixture == true and
      $doc.connect.unified_model_has_demo_fixture == true and
      $doc.connect.status_under_codex_card == false and
      $doc.connect.top_level_relaykit_status_visible == false and
      $doc.connect.catalog_url_uses_shared_18787 == false and
      ($doc.connect.discovered_row_labels | length) == $doc.connect.discovered_catalog_source_group_count and
      (all($doc.connect.discovered_row_labels[]; test("^source-[0-9]+$"))) and
      ($doc.connect.auth_state | test("auth required|credential reference needed")) and
      $doc.connect.add_strip_available == true and
      $doc.connect.cli_selected == "codex" and
      ($doc.connect | has("gateway_control_exercise") | not)
    ' "${evidence}" >/dev/null
    desktop_acceptance_state_is_valid "${evidence}"
  fi
  if [[ "${name}" == "official-sheet" || "${name}" == "official-light" || "${name}" == "official-dark" ]]; then
    visual_click_text "${name}" "OpenAI Official / Codex Official"
    set_official_sheet_stage "${name}" "opened-wait"
    wait_for_official_sheet_opened "${evidence}"
    set_official_sheet_stage "${name}" "specific-predicate"
    jq -e '
      .connect.official_provider_row_actionable == true and
      .connect.official_sheet_opened == true and
      .connect.official_auth_cta_visible == true and
      .connect.official_auth_cta_has_real_action == true and
      .connect.official_auth_cta_disabled_as_unimplemented == false and
      .connect.official_auth_unimplemented_visible == false and
      .connect.official_auth_cta_clicked == false and
      .connect.official_auth_in_progress == false and
      .connect.official_auth_process_id_present == false and
      (.connect.official_device_login_pending_status_visible | type == "boolean") and
      (.connect.official_login_available_status_visible | type == "boolean") and
      (.connect.official_route_verified_status_visible | type == "boolean") and
      .connect.official_state_details_collapsed == true and
      .connect.official_state_details_expanded == false and
      .connect.official_device_url_captured == false and
      .connect.official_device_code_captured == false and
      .connect.official_product_actions_visible == true and
      .connect.official_authenticate_action_visible == true and
      .connect.official_status_refresh_action_visible == true and
      .connect.official_reauth_action_visible == false and
      .connect.official_disconnect_action_visible == true and
      .connect.official_isolated_desktop_entry_visible == false and
      .connect.official_token_boundary_visible == true and
      .connect.official_debug_status_visible == false and
      .connect.official_debug_actions_visible == false and
      .connect.official_mock_passthrough_status_visible == false and
      .connect.official_login_required_status_visible == false and
      .connect.official_real_auth_not_verified_visible == false and
      .connect.official_open_codex_desktop_action_visible == false and
      .connect.official_run_isolated_check_action_visible == false and
      .connect.official_copy_command_action_visible == false and
      .connect.official_run_isolated_check_clicked == false and
      .connect.official_open_signin_link_clicked == false
    ' "${evidence}" >/dev/null
    set_official_sheet_stage "${name}" "before-capture"
    visual_capture_window "${name}" "${OUT}/official-cta-before.png"
    set_official_sheet_stage "${name}" "before-verify"
    test -s "${OUT}/official-cta-before.png"
    set_official_sheet_stage "${name}" "after-capture"
    visual_capture_window "${name}" "${OUT}/official-cta-after.png"
    set_official_sheet_stage "${name}" "after-verify"
    test -s "${OUT}/official-cta-after.png"
  fi
  if [[ "${name}" == "real-demo" ]]; then
    wait_for_jq "${evidence}" '.connect.real_demo_provider_clicked == true and .connect.real_demo_models_visible == true'
    jq -e '
      .connect.provider_config_path_is_app_support == false and
      .connect.real_demo_provider_clicked == true and
      .connect.real_demo_provider_config_path == true and
      .connect.real_demo_base_url_visible == true and
      .connect.real_demo_key_saved_visible == true and
      .connect.real_demo_models_visible == true and
      .connect.saved_key_fake_eye_visible == false
    ' "${evidence}" >/dev/null
    visual_capture_window "${name}" "${OUT}/real-user-demo-provider.png"
    test -s "${OUT}/real-user-demo-provider.png"
  fi
  if [[ "${name}" == "provider-click-flow" || "${name}" == "provider-light" || "${name}" == "provider-dark" ]]; then
    set_provider_capture_stage "${name}" "edit-open-check"
    if ! jq -e '.connect.provider_edit_opened == true' "${evidence}" >/dev/null; then
      set_provider_capture_stage "${name}" "provider-row-click"
      visual_click_text "${name}" "Saved Key Provider" "provider-row-click" capture
    fi
    set_provider_capture_stage "${name}" "edit-ready-wait"
    wait_for_provider_edit_ready "${evidence}"
    set_provider_capture_stage "${name}" "health-ready-wait"
    wait_for_jq "${evidence}" '
      .connect.provider_health_summary_visible == true and
      .connect.provider_health_saved_count == 2 and
      .connect.provider_health_available_count == 1 and
      .connect.provider_health_hidden_count == 1 and
      .connect.provider_hidden_models_toggle_visible == true
    '
    set_provider_action_stage "${name}" "type-key"
    visual_type_exact_pid "${name}" "Paste API key" "relaykit-ui-smoke-key" "type-key"
    wait_for_jq "${evidence}" '.connect.api_key_saved_mask_control_visible == true'
    set_provider_capture_stage "${name}" "hidden-models-click"
    visual_click_text "${name}" "Hidden models" "hidden-models-click" capture
    set_provider_capture_stage "${name}" "hidden-reasons-wait"
    wait_for_jq "${evidence}" '.connect.provider_hidden_model_reasons_visible == true'
    set_provider_capture_stage "${name}" "specific-predicate"
    provider_click_flow_specific_predicate "${evidence}"
    visual_capture_window "${name}" "${OUT}/provider-key-saved.png"
    test -s "${OUT}/provider-key-saved.png"
    set_provider_action_stage "${name}" "show-key"
    visual_click_text "${name}" "Show API key" "show-key"
    wait_for_jq "${evidence}" '.connect.saved_key_eye_toggle_works == true'
    set_provider_action_stage "${name}" "hide-key"
    visual_click_text "${name}" "Hide API key" "hide-key"
    wait_for_jq "${evidence}" '.connect.api_key_saved_mask_control_visible == true'
    set_provider_action_stage "${name}" "test-connection"
    visual_click_text "${name}" "Test connection" "test-connection"
    wait_for_jq "${evidence}" '.connect.provider_connection_connected_visible == true'
    jq -e '
      .connect.provider_connection_connected_visible == true and
      .connect.provider_connection_network_failed_visible == false and
      .connect.provider_connection_counts_separated == true and
      .connect.provider_connection_use_reachable_visible == true
    ' "${evidence}" >/dev/null
    visual_capture_window "${name}" "${OUT}/provider-test-success.png"
    test -s "${OUT}/provider-test-success.png"
    if [[ "${name}" == "provider-click-flow" ]]; then
      set_provider_action_stage "${name}" "use-reachable"
      visual_click_text "${name}" "Use 1 reachable models" "use-reachable"
      wait_for_jq "${evidence}" '.connect.provider_connection_used_reachable_models_only == true'
      visual_capture_window "${name}" "${OUT}/provider-use-reachable.png"
      test -s "${OUT}/provider-use-reachable.png"
    fi
    set_provider_action_stage "${name}" "advanced"
    visual_click_text "${name}" Advanced "advanced"
    wait_for_jq "${evidence}" '.connect.advanced_has_protocol_selector == true and .connect.advanced_has_custom_models_url == true'
    jq -e '
      .connect.advanced_scrollable_when_expanded == true and
      .connect.advanced_toggle_row_visible == true and
      .connect.advanced_has_protocol_selector == true and
      .connect.advanced_has_custom_models_url == true and
      .connect.advanced_has_custom_auth_header == true and
      .connect.advanced_has_upstream_model_override == true and
      .connect.advanced_raw_fields_hidden == true and
      .connect.ordinary_advanced_labels == ["Upstream protocol","Custom models URL","Custom auth header","Upstream model override"] and
      .connect.enabled_gateway_provider_protocols == ["anthropic_messages","openai_chat","openai_responses"] and
      .connect.planned_provider_protocols == []
    ' "${evidence}" >/dev/null
    visual_capture_window "${name}" "${OUT}/provider-advanced-simplified.png"
    test -s "${OUT}/provider-advanced-simplified.png"
    if [[ "${name}" != "provider-click-flow" ]]; then
      visual_click_text "${name}" "Save"
      sleep 0.8
    fi
  fi
  if [[ "${name}" == "provider-test-failure" ]]; then
    if ! jq -e '.connect.provider_edit_opened == true' "${evidence}" >/dev/null; then
      visual_click_text "${name}" "Saved Key Provider"
    fi
    wait_for_jq "${evidence}" '.connect.provider_edit_opened == true and .connect.provider_form_test_connection_visible == true'
    visual_click_text "${name}" "Test connection"
    wait_for_jq "${evidence}" '.connect.provider_connection_network_failed_visible == true'
    jq -e '
      .connect.provider_connection_network_failed_visible == true and
      .connect.provider_connection_reachable_visible == false and
      .connect.provider_connection_connected_visible == false
    ' "${evidence}" >/dev/null
    visual_capture_window "${name}" "${OUT}/provider-test-failure.png"
    test -s "${OUT}/provider-test-failure.png"
  fi
  if [[ "${name}" == detail* ]]; then
    jq -e '
      .connect.configured_provider_count == 1 and
      .connect.provider_edit_opened == true and
      .connect.provider_edit_row_action_invoked == true and
      .connect.provider_edit_has_save == true and
      .connect.provider_edit_has_add_cta == false and
      .connect.provider_edit_base_url_prefilled == true and
      .connect.provider_edit_models_loaded == true and
      .connect.provider_health_summary_visible == true and
      .connect.api_key_saved_state_visible == true and
      .connect.protocol_tag_distinguishes_codex_route_and_upstream == true and
      .connect.saved_key_plaintext_hidden == true and
      .connect.saved_key_state_visible == true and
      .connect.model_ids_redacted == true and
      .connect.source_names_redacted == true
    ' "${evidence}" >/dev/null
  fi
  if [[ "${name}" == "detail-advanced-expanded" ]]; then
    visual_click_text "${name}" Advanced
    wait_for_jq "${evidence}" '.connect.advanced_scrollable_when_expanded == true'
    jq -e '.connect.advanced_scrollable_when_expanded == true' "${evidence}" >/dev/null
  fi
  if [[ "${name}" == "detail-advanced-collapsed" ]]; then
    visual_click_text "${name}" Advanced
    wait_for_jq "${evidence}" '.connect.advanced_scrollable_when_expanded == true'
    visual_click_text "${name}" Advanced
    wait_for_jq "${evidence}" '.connect.advanced_can_collapse_after_expand == true'
    jq -e '.connect.advanced_can_collapse_after_expand == true' "${evidence}" >/dev/null
  fi
  if [[ "${name}" == "import" ]]; then
    jq -e '
      .connect.configured_provider_count == 0 and
      .connect.import_mode_opened == true and
      .connect.import_row_action_invoked == true and
      .connect.import_has_prefilled_fields == true and
      .connect.import_has_multiple_model_rows == true and
      .connect.import_model_list_bounded == true and
      .connect.import_selected_model_count > 1 and
      .connect.import_uses_first_model_only == false and
      .connect.import_bridge_host_detected == true and
      .connect.import_execution_base_url_prefilled == true and
      .connect.import_protocol_checked == true and
      (.connect.import_has_missing_required_fields | type == "boolean") and
      .connect.redacted_only_detail_opened == false and
      .connect.model_ids_redacted == true and
      .connect.source_names_redacted == true
    ' "${evidence}" >/dev/null
    if grep -Eq 'Source redacted|Model IDs redacted|not configured|reference only' "${evidence}"; then
      echo "import smoke regressed to redacted-only reference detail" >&2
      exit 1
    fi
  fi
  if [[ "${name}" == "usage-auto-refresh" ]]; then
    wait_for_jq "${evidence}" '.usage.today_tokens == 100 and .usage.refresh_count >= 1'
    python3 - "${USAGE_LOG_AUTO}" <<'PY'
import datetime
import json
import sys

today = datetime.datetime.utcnow().date().isoformat() + "T12:01:00Z"
with open(sys.argv[1], "a", encoding="utf-8") as f:
    f.write(json.dumps({
        "timestamp": today,
        "request_id": "ui-smoke-auto-appended",
        "provider_id": "demo",
        "model": "demo/claude-sonnet-4-6",
        "route": "/v1/responses",
        "transport": "responses_http",
        "status": "completed",
        "http_status": 200,
        "input_tokens": 100,
        "output_tokens": 150,
        "total_tokens": 250,
        "duration_ms": 120,
    }, separators=(",", ":")) + "\n")
PY
    wait_for_jq "${evidence}" '.usage.today_tokens == 350 and .usage.seven_day_tokens == 350 and .usage.all_time_tokens == 350 and .usage.requests == 2 and .usage.top_model_7d == "demo/claude-sonnet-4-6" and .usage.refresh_count >= 2'
  fi
  if [[ "${name}" == "usage-1m" ]]; then
    visual_click_text "${name}" "1M"
    sleep 0.5
  fi
  if [[ "${name}" == "usage-1y" ]]; then
    visual_click_text "${name}" "1Y"
    sleep 0.5
  fi
  if [[ "${name}" == "usage" || "${name}" == "usage-light" || "${name}" == "usage-dark" || "${name}" == "usage-1m" || "${name}" == "usage-1y" ]]; then
    usage_specific_predicate "${evidence}"
  fi
  if [[ "${name}" == "usage-large" ]]; then
    jq -e '
      .usage.has_rows == true and
      .usage.requests == 1800 and
      .usage.auto_refresh_enabled == true and
      .usage.summary_background == true and
      .usage.last_refresh_duration_ms < 5000 and
      .usage.activity_heatmap_visible == true
    ' "${evidence}" >/dev/null
  fi
  if [[ "${name}" == "usage-empty" ]]; then
    jq -e '
      .usage.has_rows == false and
      .usage.empty_state_visible == true and
      .usage.today_tokens == 0 and
      .usage.seven_day_tokens == 0 and
      .usage.all_time_tokens == 0 and
      .usage.requests == 0 and
      .usage.top_model_7d == "" and
      .usage.active_days == 0 and
      .usage.provider_group_names == [] and
      .usage.model_count == 0 and
      .usage.activity_bucket_count_7d == 14 and
      .usage.activity_active_days_7d == 0 and
      .usage.activity_unit_labels == ["7D · half-day","1M · daily","1Y · weekly"] and
      .usage.activity_heatmap_visible == true and
      .usage.activity_range_control_visible == true and
      .usage.activity_unit_label_visible == true and
      .usage.cost_unavailable_visible == true
    ' "${evidence}" >/dev/null
  fi
  if [[ "${name}" == settings* ]]; then
    jq -e '
      .settings.general_group_visible == true and
      .settings.gateway_group_visible == true and
      .settings.codex_group_visible == true and
      .settings.data_privacy_group_visible == true and
      .settings.developer_collapsed == true and
      (.settings.gateway_port | test("^127\\.0\\.0\\.1:[0-9]+$")) and
      .settings.gateway_port != "127.0.0.1:18787" and
      .settings.gateway_port != "127.0.0.1:19777" and
      .settings.global_codex_activate_visible == false and
      .settings.manual_proof_hidden_when_collapsed == true
    ' "${evidence}" >/dev/null
  fi
  if [[ "${name}" == "settings-developer-expanded" ]]; then
    visual_click_text "${name}" "Developer / Diagnostics"
    wait_for_jq "${evidence}" '.settings.developer_expanded == true and .settings.manual_proof_visible_when_expanded == true'
  fi
  if [[ "${name}" == "provider" ]]; then
    jq -e '
      .connect.add_strip_opens_provider_modal == true and
      .connect.add_form_has_save == true and
      .connect.add_form_has_gateway_port_control == false and
      .connect.provider_form_user_main_flow == true and
      .connect.provider_model_main_field_count == 1 and
      .connect.provider_display_name_visible_on_main == false and
      .connect.provider_upstream_model_visible_on_main == false and
      .connect.api_key_input_visible == true and
      .connect.provider_form_raw_protocol_visible == false and
      .connect.provider_form_credential_mode_visible == false and
      .connect.provider_form_keychain_ref_visible_on_main == false and
      .connect.provider_form_catalog_url_visible_on_main == false and
      .connect.provider_form_model_mapping_visible_on_main == false and
      .connect.provider_form_use_models_visible == false and
      .connect.provider_form_test_connection_visible == true and
      .connect.api_key_new_eye_visible == true and
      .connect.provider_form_detect_models_visible == true and
      .connect.provider_form_model_table_visible == true and
      .connect.protocol_tag_distinguishes_codex_route_and_upstream == true and
      .connect.advanced_default_collapsed == true
    ' "${evidence}" >/dev/null
  fi
  set_stage screenshot.capture
  visual_capture_window "${name}" "${OUT}/${name}.png"
  test -s "${OUT}/${name}.png"
  cleanup_current_app
}

capture_real_quit_menu() {
  set_stage quit.menu
  local evidence="${OUT}/real-quit-menu.json"
  local runtime_evidence="${OUT}/real-quit-runtime.json"
  local appearance
  appearance="$(appearance_for_capture real-quit)"
  cleanup_current_app
  launch_isolated_app real-quit "${TMPDIR}real-quit.log" --ui-smoke --ui-smoke-keep-open --ui-smoke-skip-gateway-exercise --ui-smoke-provider-config "${EMPTY_PROVIDER_CONFIG}" --ui-smoke-evidence "${runtime_evidence}" --ui-smoke-usage-log "${USAGE_LOG_EMPTY}" --ui-smoke-catalog-url "${CATALOG_URL}" --ui-smoke-appearance "${appearance}"
  sleep 1
  if ! require_app_identity real-quit; then
    cat "${TMPDIR}real-quit.log" >&2 || true
    exit 1
  fi
  set_stage capture.real-quit.status-menu.readiness-wait
  wait_for_status_item_ready
  set_stage capture.real-quit.status-menu.open-action
  open_unique_status_menu
  set_stage capture.real-quit.settle
  sleep 0.4
  set_stage capture.real-quit.capture
  visual_capture_window real-quit "${OUT}/real-quit-menu.png"
  set_stage capture.real-quit.capture-verify
  test -s "${OUT}/real-quit-menu.png"
  set_stage capture.real-quit.quit-click
  press_unique_quit_menu_item
  set_stage capture.real-quit.exit-wait
  for _ in {1..30}; do
    if ! kill -0 "${PID}" 2>/dev/null; then
      break
    fi
    sleep 0.2
  done
  set_stage capture.real-quit.exit-verify
  if kill -0 "${PID}" 2>/dev/null; then
    echo "Real Quit RelayKit menu item did not exit the app" >&2
    cat "${TMPDIR}real-quit-click.log" >&2 || true
    exit 1
  fi
  set_stage capture.real-quit.evidence-write
  jq -n --arg screenshot "${OUT}/real-quit-menu.png" \
    '{real_quit_menu_visible: true, screenshot: $screenshot}' >"${evidence}"
  REAL_QUIT_MENU_EVIDENCE="${evidence}"
  PID=""
  cleanup_current_app
}

capture_outside_click() {
  set_stage outside.click
  local evidence="${OUT}/outside-click.json" appearance outside_probe_rc
  cleanup_current_app
  appearance="$(appearance_for_capture outside-click)"
  launch_isolated_app outside-click "${TMPDIR}outside-click.log" --ui-smoke --ui-smoke-keep-open --ui-smoke-skip-gateway-exercise --ui-smoke-evidence "${evidence}" --ui-smoke-catalog-url "${CATALOG_URL}" --ui-smoke-provider-config "${EMPTY_PROVIDER_CONFIG}" --ui-smoke-usage-log "${USAGE_LOG_EMPTY}" --ui-smoke-appearance "${appearance}"
  sleep 3
  if ! require_app_identity outside-click; then
    cat "${TMPDIR}outside-click.log" >&2 || true
    exit 1
  fi
  wait_for_jq "${evidence}" '.popover.shown == true'
  set_stage capture.outside-click.initial-window-probe
  if ensure_outside_popover_open; then
    outside_probe_rc=0
  else
    outside_probe_rc="$?"
  fi
  if [[ "${RELAYKIT_WINDOW_EQUIVALENCE_DIAGNOSTIC_TARGET:-}" == "outside-click" ]]; then
    cleanup_current_app
    FAILURE_REPORTED=1
    exit "${outside_probe_rc}"
  fi
  if ((outside_probe_rc != 0)); then
    return "${outside_probe_rc}"
  fi
  set_stage capture.outside-click.semantic-window-readiness
  wait_for_outside_window_ready
  visual_click_outside "${OUT}/outside-click.png"
  wait_for_jq "${evidence}" '.popover.shown == false'
  test -s "${OUT}/outside-click.png"
  cleanup_current_app
}

set_stage preflight.build
cd "${ROOT}"
case "${REUSE_FINAL_BUNDLE}" in
  0)
    case "${RELAYKIT_SKIP_BUILD_VERIFY:-0}" in
      0) ./script/build_app_bundle.sh --verify >/dev/null ;;
      1) ;;
      *) echo "RELAYKIT_SKIP_BUILD_VERIFY must be 0 or 1" >&2; exit 2 ;;
    esac
    ;;
  1)
    [[ -x "${SOURCE_APP_BUNDLE}/Contents/MacOS/RelayKitApp.bin" && -x "${SOURCE_APP_BUNDLE}/Contents/MacOS/relay" ]] || {
      echo "reusable final App bundle is incomplete: ${SOURCE_APP_BUNDLE}" >&2
      exit 1
    }
    /usr/bin/codesign --verify --deep --strict "${SOURCE_APP_BUNDLE}"
    ;;
  *)
    echo "RELAYKIT_REUSE_FINAL_BUNDLE must be 0 or 1" >&2
    exit 2
    ;;
esac

set_stage runtime.root
RUNTIME_ROOT="$(mktemp -d /tmp/relaykit-menu-smoke.XXXXXX)"
case "${RUNTIME_ROOT}" in
  /tmp/relaykit-menu-smoke.*|/private/tmp/relaykit-menu-smoke.*) ;;
  *) echo "unsafe menu smoke runtime root" >&2; exit 1 ;;
esac
mkdir -p "${RUNTIME_ROOT}/home" "${RUNTIME_ROOT}/preferences" "${RUNTIME_ROOT}/codex" "${RUNTIME_ROOT}/tmp" "${RUNTIME_ROOT}/proof" "${RUNTIME_ROOT}/config"
HOME="${RUNTIME_ROOT}/home"
CFFIXED_USER_HOME="${RUNTIME_ROOT}/preferences"
CODEX_HOME="${RUNTIME_ROOT}/codex"
TMPDIR="${RUNTIME_ROOT}/tmp/"
RELAYKIT_RUNTIME_SAFETY_ROOT="${RUNTIME_ROOT}"
RELAYKIT_RUNTIME_SAFETY_TEST=1
export HOME CFFIXED_USER_HOME CODEX_HOME TMPDIR RELAYKIT_RUNTIME_SAFETY_ROOT
export RELAYKIT_RUNTIME_SAFETY_TEST
OUT="${RUNTIME_ROOT}/proof"
SMOKE_CONFIG_DIR="${RUNTIME_ROOT}/config"
APP_BUNDLE="${RUNTIME_ROOT}/RelayKitApp.app"
/usr/bin/ditto "${SOURCE_APP_BUNDLE}" "${APP_BUNDLE}"
/usr/bin/codesign --verify --deep --strict "${APP_BUNDLE}"
APP_REAL="${APP_BUNDLE}/Contents/MacOS/RelayKitApp.bin"
BUNDLED_RELAY="${APP_BUNDLE}/Contents/MacOS/relay"
set_stage runtime.ports
RUNTIME_PORT="$(select_isolated_port)"
CATALOG_PORT="$(select_isolated_port)"
[[ "${RUNTIME_PORT}" != "${CATALOG_PORT}" && "${RUNTIME_PORT}" != "18787" && "${RUNTIME_PORT}" != "19777" && "${CATALOG_PORT}" != "18787" && "${CATALOG_PORT}" != "19777" ]] || {
  echo "could not allocate distinct isolated ports" >&2
  exit 1
}
CATALOG_URL="http://127.0.0.1:${CATALOG_PORT}/v1/models"
RELAYKIT_RUNTIME_SAFETY_PORT="${RUNTIME_PORT}"
export RELAYKIT_RUNTIME_SAFETY_PORT
SMOKE_KEYCHAIN_REFERENCE="relaykit.ui-smoke.provider.fixture"
EMPTY_PROVIDER_CONFIG="${SMOKE_CONFIG_DIR}/user-providers.json"
FIXTURE_PROVIDER_CONFIG="${SMOKE_CONFIG_DIR}/fixture-providers.json"
FAIL_PROVIDER_CONFIG="${SMOKE_CONFIG_DIR}/failure-providers.json"
CONNECT_PROVIDER_CONFIG="${SMOKE_CONFIG_DIR}/connect-providers.json"
USAGE_LOG_FULL="${SMOKE_CONFIG_DIR}/usage-full.jsonl"
USAGE_LOG_EMPTY="${SMOKE_CONFIG_DIR}/usage-empty.jsonl"
USAGE_LOG_AUTO="${SMOKE_CONFIG_DIR}/usage-auto.jsonl"
USAGE_LOG_LARGE="${SMOKE_CONFIG_DIR}/usage-large.jsonl"
CATALOG_DIR="${SMOKE_CONFIG_DIR}/catalog"
mkdir -p "${CATALOG_DIR}/v1"
set_stage fixtures.write
cat >"${CATALOG_DIR}/v1/models" <<'JSON'
{
  "object": "list",
  "data": [
    {
      "id": "gpt-5.5",
      "owned_by": "openai",
      "source": "openai",
      "display_name": "GPT-5.5",
      "protocol": "responses",
      "transport": "relaykit_official_passthrough",
      "status": "ready",
      "visibility": "visible",
      "context_window": 128000
    },
    {
      "id": "demo/claude-haiku-4-5",
      "owned_by": "demo",
      "source": "demo",
      "display_name": "Demo Claude Haiku 4.5",
      "protocol": "responses",
      "transport": "local_relaykit",
      "bridge_host": "127.0.0.1:18791",
      "status": "ready",
      "visibility": "visible",
      "context_window": 200000
    },
    {
      "id": "demo/claude-sonnet-4-6",
      "owned_by": "demo",
      "source": "demo",
      "display_name": "Demo Claude Sonnet 4.6",
      "protocol": "responses",
      "transport": "local_relaykit",
      "bridge_host": "127.0.0.1:18791",
      "status": "ready",
      "visibility": "visible",
      "context_window": 200000
    }
  ]
}
JSON
cat >"${CATALOG_DIR}/provider-models" <<'JSON'
{
  "object": "list",
  "data": [
    {
      "id": "saved-coder-upstream",
      "object": "model",
      "owned_by": "fixture-provider"
    }
  ]
}
JSON
set_stage catalog.start
PYTHON_RUNTIME_EXECUTABLE="$(python_runtime_executable)"
python3 -m http.server "${CATALOG_PORT}" --bind 127.0.0.1 --directory "${CATALOG_DIR}" >"${TMPDIR}ui-smoke-catalog.log" 2>&1 &
FAKE_CATALOG_PID="$!"
set_stage catalog.identity
wait_for_process_executable_match "${FAKE_CATALOG_PID}" "${PYTHON_RUNTIME_EXECUTABLE}"
register_owned_pid "${FAKE_CATALOG_PID}" "${PYTHON_RUNTIME_EXECUTABLE}"
set_stage catalog.readiness
for _ in {1..20}; do
  if curl -fsS "${CATALOG_URL}" >/dev/null 2>&1; then
    break
  fi
  sleep 0.1
done
curl -fsS "${CATALOG_URL}" >/dev/null
cat >"${FIXTURE_PROVIDER_CONFIG}" <<JSON
{
  "providers": [
    {
      "id": "fixture-provider",
      "name": "Saved Key Provider",
      "base_url": "http://127.0.0.1:${CATALOG_PORT}/v1",
      "api_format": "anthropic_messages",
      "credential_ref": {
        "kind": "keychain",
        "value": "${SMOKE_KEYCHAIN_REFERENCE}"
      },
      "catalog": {
        "models_url": "http://127.0.0.1:${CATALOG_PORT}/provider-models"
      },
      "models": [
        {
          "id": "saved/coder",
          "display_name": "Saved Key Coder",
          "upstream_model": "saved-coder-upstream"
        },
        {
          "id": "saved/missing",
          "display_name": "Saved Missing",
          "upstream_model": "saved-missing-upstream"
        }
      ]
    }
  ]
}
JSON
cat >"${FAIL_PROVIDER_CONFIG}" <<JSON
{
  "providers": [
    {
      "id": "failure-provider",
      "name": "Saved Key Provider",
      "base_url": "http://127.0.0.1:9/v1",
      "api_format": "anthropic_messages",
      "credential_ref": {
        "kind": "keychain",
        "value": "${SMOKE_KEYCHAIN_REFERENCE}"
      },
      "models": [
        {
          "id": "saved/coder",
          "display_name": "Saved Key Coder"
        }
      ]
    }
  ]
}
JSON
cat >"${CONNECT_PROVIDER_CONFIG}" <<JSON
{
  "providers": [
    {
      "id": "demo",
      "name": "Demo Anthropic",
      "base_url": "http://127.0.0.1:${CATALOG_PORT}",
      "api_format": "anthropic_messages",
      "credential_ref": {
        "kind": "keychain",
        "value": "${SMOKE_KEYCHAIN_REFERENCE}"
      },
      "routing": {
        "source": "demo",
        "model_prefix": "demo/",
        "status": "enabled",
        "visible": true
      },
      "models": [
        {
          "id": "demo/claude-haiku-4-5",
          "display_name": "Claude Haiku 4.5"
        },
        {
          "id": "demo/claude-sonnet-4-6",
          "display_name": "Claude Sonnet 4.6"
        }
      ]
    }
  ]
}
JSON
python3 - "${USAGE_LOG_FULL}" "${USAGE_LOG_AUTO}" "${USAGE_LOG_LARGE}" <<'PY'
import datetime
import json
import sys

out, auto_out, large_out = sys.argv[1:4]
today = datetime.datetime.utcnow().date()

def ts(days):
    return (today - datetime.timedelta(days=days)).isoformat() + "T12:00:00Z"

events = [
    (0, "openai", "gpt-5.5", 60, 20, 80),
    (0, "openai", "gpt-5.5", 30, 40, 70),
    (1, "demo", "demo/claude-sonnet-4-6", 100, 80, 180),
    (1, "demo", "demo/claude-sonnet-4-6", 120, 90, 210),
    (1, "demo", "demo/claude-sonnet-4-6", 60, 50, 110),
    (6, "demo", "demo/claude-haiku-4-5", 40, 60, 100),
    (20, "openai", "gpt-5.1", 10, 15, 25),
]
with open(out, "w", encoding="utf-8") as f:
    for index, (days, provider, model, input_tokens, output_tokens, total_tokens) in enumerate(events, 1):
        f.write(json.dumps({
            "timestamp": ts(days),
            "request_id": f"ui-smoke-{index}",
            "provider_id": provider,
            "model": model,
            "route": "/v1/responses",
            "transport": "responses_http",
            "status": "completed",
            "http_status": 200,
            "input_tokens": input_tokens,
            "output_tokens": output_tokens,
            "total_tokens": total_tokens,
            "duration_ms": 100 + index,
        }, separators=(",", ":")) + "\n")
with open(auto_out, "w", encoding="utf-8") as f:
    f.write(json.dumps({
        "timestamp": ts(0),
        "request_id": "ui-smoke-auto-initial",
        "provider_id": "openai",
        "model": "gpt-5.5",
        "route": "/v1/responses",
        "transport": "responses_http",
        "status": "completed",
        "http_status": 200,
        "input_tokens": 40,
        "output_tokens": 60,
        "total_tokens": 100,
        "duration_ms": 100,
    }, separators=(",", ":")) + "\n")
with open(large_out, "w", encoding="utf-8") as f:
    models = ["gpt-5.5", "demo/claude-haiku-4-5", "demo/claude-sonnet-4-6"]
    providers = ["openai", "demo", "demo"]
    for index in range(1800):
        model_index = index % len(models)
        total = 50 + (index % 200)
        f.write(json.dumps({
            "timestamp": ts(index % 40),
            "request_id": f"ui-smoke-large-{index}",
            "provider_id": providers[model_index],
            "model": models[model_index],
            "route": "/v1/responses",
            "transport": "responses_http",
            "status": "completed",
            "http_status": 200,
            "input_tokens": total // 2,
            "output_tokens": total - (total // 2),
            "total_tokens": total,
            "duration_ms": 20,
        }, separators=(",", ":")) + "\n")
PY

set_stage capture.connect
capture connect --ui-smoke-tab connect --ui-smoke-provider-config "${EMPTY_PROVIDER_CONFIG}"
set_stage capture.official-sheet
capture official-sheet --ui-smoke-tab connect --ui-smoke-provider-config "${CONNECT_PROVIDER_CONFIG}" --ui-smoke-skip-gateway-exercise
jq -e '
  .providers[] |
  select(
    .id == "demo" and
    .name == "Demo Anthropic" and
    .credential_ref.kind == "keychain" and
    ((.routing.model_prefix // "") == "demo/") and
    ([.models[].id] | length >= 1)
  )
' "${CONNECT_PROVIDER_CONFIG}" >/dev/null
set_stage capture.real-demo
capture real-demo --ui-smoke-tab connect --ui-smoke-provider-config "${CONNECT_PROVIDER_CONFIG}" --ui-smoke-skip-gateway-exercise
set_stage capture.provider-click-flow
capture provider-click-flow --ui-smoke-tab connect --ui-smoke-detail --ui-smoke-provider-config "${FIXTURE_PROVIDER_CONFIG}" --ui-smoke-model-health-fixture
set_stage capture.provider-test-failure
capture provider-test-failure --ui-smoke-tab connect --ui-smoke-detail --ui-smoke-provider-config "${FAIL_PROVIDER_CONFIG}"
jq -e '
  .providers[0].credential_ref.kind == "keychain" and
  .providers[0].credential_ref.value == "relaykit.ui-smoke.provider.fixture" and
  (.providers[0] | has("api_key") | not)
' "${FIXTURE_PROVIDER_CONFIG}" >/dev/null
if grep -Eiq 'sk-|bearer |access_token|refresh_token|password|secret' "${FIXTURE_PROVIDER_CONFIG}"; then
  echo "provider click flow leaked a credential-looking value into provider config" >&2
  exit 1
fi
set_stage capture.detail
capture detail --ui-smoke-tab connect --ui-smoke-detail --ui-smoke-provider-config "${FIXTURE_PROVIDER_CONFIG}"
set_stage capture.detail-advanced-expanded
capture detail-advanced-expanded --ui-smoke-tab connect --ui-smoke-detail --ui-smoke-provider-config "${FIXTURE_PROVIDER_CONFIG}"
set_stage capture.detail-advanced-collapsed
capture detail-advanced-collapsed --ui-smoke-tab connect --ui-smoke-detail --ui-smoke-provider-config "${FIXTURE_PROVIDER_CONFIG}"
set_stage capture.import
capture import --ui-smoke-tab connect --ui-smoke-import --ui-smoke-provider-config "${EMPTY_PROVIDER_CONFIG}"
set_stage capture.usage
capture usage --ui-smoke-tab usage --ui-smoke-provider-config "${EMPTY_PROVIDER_CONFIG}" --ui-smoke-usage-log "${USAGE_LOG_FULL}"
set_stage capture.usage-auto-refresh
capture usage-auto-refresh --ui-smoke-tab usage --ui-smoke-provider-config "${EMPTY_PROVIDER_CONFIG}" --ui-smoke-usage-log "${USAGE_LOG_AUTO}" --ui-smoke-usage-refresh-interval 1
set_stage capture.usage-large
capture usage-large --ui-smoke-tab usage --ui-smoke-provider-config "${EMPTY_PROVIDER_CONFIG}" --ui-smoke-usage-log "${USAGE_LOG_LARGE}" --ui-smoke-usage-refresh-interval 1
set_stage capture.usage-1m
capture usage-1m --ui-smoke-tab usage --ui-smoke-provider-config "${EMPTY_PROVIDER_CONFIG}" --ui-smoke-usage-log "${USAGE_LOG_FULL}"
set_stage capture.usage-1y
capture usage-1y --ui-smoke-tab usage --ui-smoke-provider-config "${EMPTY_PROVIDER_CONFIG}" --ui-smoke-usage-log "${USAGE_LOG_FULL}"
set_stage capture.usage-empty
capture usage-empty --ui-smoke-tab usage --ui-smoke-provider-config "${EMPTY_PROVIDER_CONFIG}" --ui-smoke-usage-log "${USAGE_LOG_EMPTY}"
set_stage capture.settings
capture settings --ui-smoke-tab settings --ui-smoke-provider-config "${EMPTY_PROVIDER_CONFIG}"
set_stage capture.settings-developer-expanded
capture settings-developer-expanded --ui-smoke-tab settings --ui-smoke-provider-config "${EMPTY_PROVIDER_CONFIG}"
set_stage capture.settings-light
capture settings-light --ui-smoke-tab settings --ui-smoke-provider-config "${EMPTY_PROVIDER_CONFIG}"
jq -e '.settings.appearance_mode == "light"' "${OUT}/settings-light.json" >/dev/null
set_stage capture.usage-light
capture usage-light --ui-smoke-tab usage --ui-smoke-provider-config "${EMPTY_PROVIDER_CONFIG}" --ui-smoke-usage-log "${USAGE_LOG_FULL}"
jq -e '.settings.appearance_mode == "light"' "${OUT}/usage-light.json" >/dev/null
set_stage capture.official-light
capture official-light --ui-smoke-tab connect --ui-smoke-provider-config "${CONNECT_PROVIDER_CONFIG}" --ui-smoke-skip-gateway-exercise
cp "${OUT}/official-cta-before.png" "${OUT}/official-light.png"
set_stage capture.provider-light
capture provider-light --ui-smoke-tab connect --ui-smoke-detail --ui-smoke-provider-config "${FIXTURE_PROVIDER_CONFIG}" --ui-smoke-model-health-fixture
cp "${OUT}/provider-test-success.png" "${OUT}/provider-light.png"
set_stage capture.settings-dark
capture settings-dark --ui-smoke-tab settings --ui-smoke-provider-config "${EMPTY_PROVIDER_CONFIG}"
jq -e '.settings.appearance_mode == "dark"' "${OUT}/settings-dark.json" >/dev/null
set_stage capture.usage-dark
capture usage-dark --ui-smoke-tab usage --ui-smoke-provider-config "${EMPTY_PROVIDER_CONFIG}" --ui-smoke-usage-log "${USAGE_LOG_FULL}"
jq -e '.settings.appearance_mode == "dark"' "${OUT}/usage-dark.json" >/dev/null
set_stage capture.official-dark
capture official-dark --ui-smoke-tab connect --ui-smoke-provider-config "${CONNECT_PROVIDER_CONFIG}" --ui-smoke-skip-gateway-exercise
cp "${OUT}/official-cta-before.png" "${OUT}/official-dark.png"
set_stage capture.provider-dark
capture provider-dark --ui-smoke-tab connect --ui-smoke-detail --ui-smoke-provider-config "${FIXTURE_PROVIDER_CONFIG}" --ui-smoke-model-health-fixture
cp "${OUT}/provider-test-success.png" "${OUT}/provider-dark.png"
set_stage capture.provider
capture provider --ui-smoke-tab connect --ui-smoke-provider --ui-smoke-provider-config "${EMPTY_PROVIDER_CONFIG}"
set_stage capture.real-quit
capture_real_quit_menu
set_stage capture.outside-click
capture_outside_click
set_stage final.aggregate
jq -n \
  --slurpfile connect "${OUT}/connect.json" \
  --slurpfile official "${OUT}/official-sheet.json" \
  --slurpfile officialLight "${OUT}/official-light.json" \
  --slurpfile officialDark "${OUT}/official-dark.json" \
  --slurpfile realDemo "${OUT}/real-demo.json" \
  --slurpfile providerFlow "${OUT}/provider-click-flow.json" \
  --slurpfile providerLight "${OUT}/provider-light.json" \
  --slurpfile providerDark "${OUT}/provider-dark.json" \
  --slurpfile providerAdd "${OUT}/provider.json" \
  --slurpfile providerFailure "${OUT}/provider-test-failure.json" \
  --slurpfile detail "${OUT}/detail.json" \
  --slurpfile advancedExpanded "${OUT}/detail-advanced-expanded.json" \
  --slurpfile advancedCollapsed "${OUT}/detail-advanced-collapsed.json" \
  --slurpfile usage "${OUT}/usage.json" \
  --slurpfile usageAuto "${OUT}/usage-auto-refresh.json" \
  --slurpfile usageLarge "${OUT}/usage-large.json" \
  --slurpfile usageEmpty "${OUT}/usage-empty.json" \
  --slurpfile settingsMain "${OUT}/settings.json" \
  --slurpfile settingsDeveloper "${OUT}/settings-developer-expanded.json" \
  --slurpfile quitMenu "${OUT}/real-quit-menu.json" \
  --slurpfile outsideClick "${OUT}/outside-click.json" \
  '{
    provider_config_path_is_app_support: $connect[0].connect.provider_config_path_is_app_support,
    stale_tmp_provider_config_recovered: $connect[0].connect.stale_tmp_provider_config_recovered,
    status_summary_inline: $connect[0].connect.status_summary_inline,
    model_access_and_model_list_merged: $connect[0].connect.model_access_and_model_list_merged,
    duplicate_empty_state: $connect[0].connect.duplicate_empty_state,
    official_provider_row_visible: $connect[0].connect.official_provider_row_visible,
    official_provider_row_managed_by_relaykit: $connect[0].connect.official_provider_row_managed_by_relaykit,
    official_sheet_opened: $official[0].connect.official_sheet_opened,
    official_light_sheet_opened: ($officialLight[0].settings.appearance_mode == "light" and $officialLight[0].connect.official_sheet_opened == true),
    official_dark_sheet_opened: ($officialDark[0].settings.appearance_mode == "dark" and $officialDark[0].connect.official_sheet_opened == true),
    official_auth_required_visible: $official[0].connect.official_auth_required_visible,
    official_auth_cta_visible: $official[0].connect.official_auth_cta_visible,
    official_auth_cta_clicked: $official[0].connect.official_auth_cta_clicked,
    official_auth_cta_has_real_action: $official[0].connect.official_auth_cta_has_real_action,
    official_auth_cta_disabled_as_unimplemented: $official[0].connect.official_auth_cta_disabled_as_unimplemented,
    official_auth_unimplemented_visible: $official[0].connect.official_auth_unimplemented_visible,
    official_auth_in_progress: $official[0].connect.official_auth_in_progress,
    official_auth_process_id_present: $official[0].connect.official_auth_process_id_present,
    official_device_url_captured: $official[0].connect.official_device_url_captured,
    official_device_code_captured: $official[0].connect.official_device_code_captured,
    official_device_code_copied: $official[0].connect.official_device_code_copied,
    official_credential_ref_exists: $official[0].connect.official_credential_ref_exists,
    official_current_status: $official[0].connect.official_current_status,
    official_connected_by_login_status: $official[0].connect.official_connected_by_login_status,
    official_connected_cta_disabled: $official[0].connect.official_connected_cta_disabled,
    official_connected_device_code_hidden: $official[0].connect.official_connected_device_code_hidden,
    official_connected_click_does_not_start_login: $official[0].connect.official_connected_click_does_not_start_login,
    official_route_verified_status: $official[0].connect.official_route_verified_status,
    official_device_login_visible: $official[0].connect.official_device_login_visible,
    official_product_actions_visible: $official[0].connect.official_product_actions_visible,
    official_authenticate_action_visible: $official[0].connect.official_authenticate_action_visible,
    official_status_refresh_action_visible: $official[0].connect.official_status_refresh_action_visible,
    official_reauth_action_visible: $official[0].connect.official_reauth_action_visible,
    official_disconnect_action_visible: $official[0].connect.official_disconnect_action_visible,
    official_isolated_desktop_entry_visible: $official[0].connect.official_isolated_desktop_entry_visible,
    official_token_boundary_visible: $official[0].connect.official_token_boundary_visible,
    official_debug_status_visible: $official[0].connect.official_debug_status_visible,
    official_debug_actions_visible: $official[0].connect.official_debug_actions_visible,
    official_mock_passthrough_status_visible: $official[0].connect.official_mock_passthrough_status_visible,
    official_not_connected_status_visible: $official[0].connect.official_not_connected_status_visible,
    official_device_login_pending_status_visible: $official[0].connect.official_device_login_pending_status_visible,
    official_login_available_status_visible: $official[0].connect.official_login_available_status_visible,
    official_route_verified_status_visible: $official[0].connect.official_route_verified_status_visible,
    official_state_details_collapsed: $official[0].connect.official_state_details_collapsed,
    official_state_details_expanded: $official[0].connect.official_state_details_expanded,
    official_login_required_status_visible: $official[0].connect.official_login_required_status_visible,
    official_real_auth_not_verified_visible: $official[0].connect.official_real_auth_not_verified_visible,
    official_open_codex_desktop_action_visible: $official[0].connect.official_open_codex_desktop_action_visible,
    official_run_isolated_check_action_visible: $official[0].connect.official_run_isolated_check_action_visible,
    official_copy_command_action_visible: $official[0].connect.official_copy_command_action_visible,
    official_run_isolated_check_clicked: $official[0].connect.official_run_isolated_check_clicked,
    official_open_signin_link_action_visible: $official[0].connect.official_open_signin_link_action_visible,
    official_open_signin_link_clicked: $official[0].connect.official_open_signin_link_clicked,
    official_copy_device_code_action_visible: $official[0].connect.official_copy_device_code_action_visible,
    official_copy_device_code_clicked: $official[0].connect.official_copy_device_code_clicked,
    header_models_match_unified_models: $connect[0].connect.header_models_match_unified_models,
    real_quit_menu_visible: $quitMenu[0].real_quit_menu_visible,
    outside_click_closes_popover: ($outsideClick[0].popover.shown == false),
    connect_first_screen_locked: $connect[0].connect.connect_first_screen_locked,
    protocol_tag_distinguishes_codex_route_and_upstream: $detail[0].connect.protocol_tag_distinguishes_codex_route_and_upstream,
    real_demo_provider_clicked: $realDemo[0].connect.real_demo_provider_clicked,
    real_demo_provider_config_path: $realDemo[0].connect.real_demo_provider_config_path,
    real_demo_base_url_visible: $realDemo[0].connect.real_demo_base_url_visible,
    real_demo_key_saved_visible: $realDemo[0].connect.real_demo_key_saved_visible,
    real_demo_models_visible: $realDemo[0].connect.real_demo_models_visible,
    provider_edit_base_url_prefilled: $providerFlow[0].connect.provider_edit_base_url_prefilled,
    provider_edit_models_loaded: $providerFlow[0].connect.provider_edit_models_loaded,
    provider_health_summary_visible: $providerFlow[0].connect.provider_health_summary_visible,
    provider_health_saved_count: $providerFlow[0].connect.provider_health_saved_count,
    provider_health_available_count: $providerFlow[0].connect.provider_health_available_count,
    provider_health_hidden_count: $providerFlow[0].connect.provider_health_hidden_count,
    provider_hidden_models_toggle_visible: $providerFlow[0].connect.provider_hidden_models_toggle_visible,
    provider_hidden_model_reasons_visible: $providerFlow[0].connect.provider_hidden_model_reasons_visible,
    provider_model_reachable_row_visible: $providerFlow[0].connect.provider_model_reachable_row_visible,
    provider_model_unavailable_row_visible: $providerFlow[0].connect.provider_model_unavailable_row_visible,
    provider_light_modal_opened: ($providerLight[0].settings.appearance_mode == "light" and $providerLight[0].connect.provider_edit_opened == true),
    provider_dark_modal_opened: ($providerDark[0].settings.appearance_mode == "dark" and $providerDark[0].connect.provider_edit_opened == true),
    saved_key_plaintext_hidden: $providerFlow[0].connect.saved_key_plaintext_hidden,
    saved_key_state_visible: $providerFlow[0].connect.saved_key_state_visible,
    api_key_masked_field_visible: $providerFlow[0].connect.api_key_masked_field_visible,
    api_key_saved_mask_control_visible: $providerFlow[0].connect.api_key_saved_mask_control_visible,
    api_key_saved_eye_visible: $providerFlow[0].connect.api_key_saved_eye_visible,
    saved_key_fake_eye_visible: $providerFlow[0].connect.saved_key_fake_eye_visible,
    saved_key_disabled_eye_reason_visible: $providerFlow[0].connect.saved_key_disabled_eye_reason_visible,
    saved_key_eye_toggle_works: $providerFlow[0].connect.saved_key_eye_toggle_works,
    api_key_replace_visible: $providerFlow[0].connect.api_key_replace_visible,
    api_key_new_eye_visible: $providerAdd[0].connect.api_key_new_eye_visible,
    new_key_eye_toggle_works: $providerAdd[0].connect.new_key_eye_toggle_works,
    api_key_replace_available: $providerFlow[0].connect.api_key_replace_available,
    provider_test_connection_visible: $providerFlow[0].connect.provider_form_test_connection_visible,
    provider_test_success_connected: $providerFlow[0].connect.provider_connection_connected_visible,
    provider_connection_counts_separated: $providerFlow[0].connect.provider_connection_counts_separated,
    provider_connection_use_reachable_visible: $providerFlow[0].connect.provider_connection_use_reachable_visible,
    provider_connection_used_reachable_models_only: $providerFlow[0].connect.provider_connection_used_reachable_models_only,
    provider_test_failure_network: $providerFailure[0].connect.provider_connection_network_failed_visible,
    provider_click_flow_real_ax: $providerFlow[0].connect.api_key_eye_toggle_clicked,
    advanced_default_collapsed: $detail[0].connect.advanced_default_collapsed,
    advanced_toggle_row_visible: $providerFlow[0].connect.advanced_toggle_row_visible,
    advanced_scrollable_when_expanded: $providerFlow[0].connect.advanced_scrollable_when_expanded,
    advanced_has_protocol_selector: $providerFlow[0].connect.advanced_has_protocol_selector,
    advanced_has_custom_models_url: $providerFlow[0].connect.advanced_has_custom_models_url,
    advanced_has_custom_auth_header: $providerFlow[0].connect.advanced_has_custom_auth_header,
    advanced_has_upstream_model_override: $providerFlow[0].connect.advanced_has_upstream_model_override,
    advanced_raw_fields_hidden: $providerFlow[0].connect.advanced_raw_fields_hidden,
    advanced_can_collapse_after_expand: $advancedCollapsed[0].connect.advanced_can_collapse_after_expand,
    usage_has_real_rows: $usage[0].usage.has_rows,
    usage_auto_refresh_enabled: $usage[0].usage.auto_refresh_enabled,
    usage_auto_refresh_updates_without_restart: ($usageAuto[0].usage.today_tokens == 350 and $usageAuto[0].usage.refresh_count >= 2),
    usage_summary_background: $usage[0].usage.summary_background,
    usage_last_refresh_duration_ms: $usage[0].usage.last_refresh_duration_ms,
    usage_large_fixture_requests: $usageLarge[0].usage.requests,
    usage_large_fixture_duration_ms: $usageLarge[0].usage.last_refresh_duration_ms,
    usage_empty_state_visible: $usageEmpty[0].usage.empty_state_visible,
    usage_today_tokens: $usage[0].usage.today_tokens,
    usage_today_tokens_label: $usage[0].usage.today_tokens_label,
    usage_seven_day_tokens: $usage[0].usage.seven_day_tokens,
    usage_seven_day_tokens_label: $usage[0].usage.seven_day_tokens_label,
    usage_all_time_tokens: $usage[0].usage.all_time_tokens,
    usage_all_time_tokens_label: $usage[0].usage.all_time_tokens_label,
    usage_requests: $usage[0].usage.requests,
    usage_top_model_7d: $usage[0].usage.top_model_7d,
    usage_top_model_7d_readable: $usage[0].usage.top_model_7d_readable,
    usage_top_model_readable_visible: $usage[0].usage.top_model_readable_visible,
    usage_provider_groups: $usage[0].usage.provider_group_names,
    usage_provider_source_shifted: $usage[0].usage.provider_source_shifted,
    usage_provider_tokens_labels: $usage[0].usage.provider_tokens_labels,
    usage_activity_heatmap_visible: $usage[0].usage.activity_heatmap_visible,
    usage_activity_range_control_visible: $usage[0].usage.activity_range_control_visible,
    usage_activity_unit_labels: $usage[0].usage.activity_unit_labels,
    usage_activity_unit_label_visible: $usage[0].usage.activity_unit_label_visible,
    usage_cost_unavailable_visible: $usage[0].usage.cost_unavailable_visible,
    usage_token_unit_formatting: $usage[0].usage.token_unit_formatting,
    settings_general_group_visible: $settingsMain[0].settings.general_group_visible,
    settings_gateway_group_visible: $settingsMain[0].settings.gateway_group_visible,
    settings_codex_group_visible: $settingsMain[0].settings.codex_group_visible,
    settings_data_privacy_group_visible: $settingsMain[0].settings.data_privacy_group_visible,
    settings_developer_collapsed_by_default: $settingsMain[0].settings.developer_collapsed,
    settings_developer_expands: $settingsDeveloper[0].settings.developer_expanded,
    settings_manual_proof_hidden_when_collapsed: $settingsMain[0].settings.manual_proof_hidden_when_collapsed,
    settings_manual_proof_visible_when_expanded: $settingsDeveloper[0].settings.manual_proof_visible_when_expanded,
    settings_gateway_port_isolated: (
      ($settingsMain[0].settings.gateway_port | test("^127\\.0\\.0\\.1:[0-9]+$")) and
      $settingsMain[0].settings.gateway_port != "127.0.0.1:18787" and
      $settingsMain[0].settings.gateway_port != "127.0.0.1:19777"
    ),
    settings_global_codex_activate_visible: $settingsMain[0].settings.global_codex_activate_visible,
    global_config_auth_access_mode: "isolated-not-accessed"
  }' >"${OUT}/product-evidence.json"
final_aggregate_predicate "${OUT}/product-evidence.json"
set_stage final.copy
MANUAL_CHECK_OUT="${ROOT}/dist/manual-check"
mkdir -p "${MANUAL_CHECK_OUT}"
cp "${OUT}/connect.png" "${MANUAL_CHECK_OUT}/final-connect-provider-real.png"
cp "${OUT}/official-sheet.png" "${MANUAL_CHECK_OUT}/final-official-auth-flow.png"
cp "${OUT}/provider-key-saved.png" "${MANUAL_CHECK_OUT}/final-provider-key-models.png"
cp "${OUT}/provider-advanced-simplified.png" "${MANUAL_CHECK_OUT}/final-advanced-expanded.png"
cp "${OUT}/provider-test-success.png" "${MANUAL_CHECK_OUT}/final-provider-test-success.png"
cp "${OUT}/provider-use-reachable.png" "${MANUAL_CHECK_OUT}/final-provider-use-reachable.png"
cp "${OUT}/provider-test-failure.png" "${MANUAL_CHECK_OUT}/final-provider-test-failure.png"
cp "${OUT}/usage.png" "${MANUAL_CHECK_OUT}/final-usage-real-data.png"
cp "${OUT}/usage.png" "${MANUAL_CHECK_OUT}/final-usage-7d-activity.png"
cp "${OUT}/usage.png" "${MANUAL_CHECK_OUT}/final-usage-activity-heatmap.png"
cp "${OUT}/usage-1m.png" "${MANUAL_CHECK_OUT}/final-usage-1m-activity.png"
cp "${OUT}/usage-1y.png" "${MANUAL_CHECK_OUT}/final-usage-1y-activity.png"
cp "${OUT}/usage-empty.png" "${MANUAL_CHECK_OUT}/final-usage-empty.png"
cp "${OUT}/settings.png" "${MANUAL_CHECK_OUT}/final-settings-groups.png"
cp "${OUT}/settings-developer-expanded.png" "${MANUAL_CHECK_OUT}/final-settings-developer-expanded.png"
cp "${OUT}/usage-light.png" "${MANUAL_CHECK_OUT}/final-usage-light.png"
cp "${OUT}/usage-dark.png" "${MANUAL_CHECK_OUT}/final-usage-dark.png"
cp "${OUT}/settings-light.png" "${MANUAL_CHECK_OUT}/final-settings-light.png"
cp "${OUT}/settings-dark.png" "${MANUAL_CHECK_OUT}/final-settings-dark.png"
cp "${OUT}/official-light.png" "${MANUAL_CHECK_OUT}/final-official-light.png"
cp "${OUT}/provider-light.png" "${MANUAL_CHECK_OUT}/final-provider-light.png"
cp "${OUT}/official-dark.png" "${MANUAL_CHECK_OUT}/final-official-dark.png"
cp "${OUT}/provider-dark.png" "${MANUAL_CHECK_OUT}/final-provider-dark.png"
cp "${OUT}/official-cta-before.png" "${MANUAL_CHECK_OUT}/real-user-official-before.png"
cp "${OUT}/official-cta-after.png" "${MANUAL_CHECK_OUT}/real-user-official-after.png"
cp "${OUT}/real-user-demo-provider.png" "${MANUAL_CHECK_OUT}/real-user-demo-provider.png"
cleanup
if ((${#OWNED_PIDS[@]} != 0)); then
  echo "UI smoke retained an owned PID registry entry" >&2
  exit 1
fi
if [[ "${RELAYKIT_WINDOW_EQUIVALENCE_DIAGNOSTIC_TARGET:-}" == "first-ambiguity" ||
      "${RELAYKIT_WINDOW_EQUIVALENCE_DIAGNOSTIC_TARGET:-}" == "first-ambiguity-private-visual" ]]; then
  printf '%s\n' 'DIAG_VALID=false' 'DIAG_REASON=semantic-ambiguity-not-observed'
  FAILURE_REPORTED=1
  exit 1
fi

echo "RelayKit menu bar UI smoke passed: ${OUT}"
