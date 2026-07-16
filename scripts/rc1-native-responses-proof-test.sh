#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${ROOT}/scripts/rc1-native-responses-proof.sh"
FIXTURE="${ROOT}/scripts/rc1-native-responses-proof-fixture.py"
MANUAL_PROOF="${ROOT}/scripts/codex-desktop-manual-proof.sh"
MANIFEST="${ROOT}/scripts/rc1-native-responses-manifest.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/relaykit-window-selector-test.XXXXXX")"
TMP="$(cd "${TMP}" && pwd -P)"
full_test_pid=""

cleanup() {
  if [[ -n "${full_test_pid}" ]] && kill -0 "${full_test_pid}" 2>/dev/null; then
    kill -TERM "${full_test_pid}" >/dev/null 2>&1 || true
    wait "${full_test_pid}" >/dev/null 2>&1 || true
  fi
  rm -rf "${TMP}"
}
trap cleanup EXIT INT TERM HUP

fail() {
  printf 'RC1 native Responses proof contract failed: %s\n' "$*" >&2
  exit 1
}

[[ -x "${SCRIPT}" ]] || fail "proof script is missing"
[[ -f "${FIXTURE}" ]] || fail "standalone loopback fixture is missing"
[[ -x "${MANIFEST}" ]] || fail "phase-b manifest builder is missing"
bash -n "${SCRIPT}"

ax_ready_identity="${TMP}/ax-ready-identity.json"
ax_ready_diagnostic="${TMP}/ax-ready-diagnostic.json"
ax_ready_driver="${TMP}/ax-ready-driver"
ax_ready_counter="${TMP}/ax-ready-counter"
jq -n '{pid:4242,window_id:101}' >"${ax_ready_identity}"
chmod 600 "${ax_ready_identity}"
cat >"${ax_ready_driver}" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
count="$(cat "${AX_READY_COUNTER}" 2>/dev/null || printf 0)"
count=$((count + 1))
printf '%s\n' "${count}" >"${AX_READY_COUNTER}"
diagnostic=''
while [[ "$#" -gt 0 ]]; do
  if [[ "$1" == '--diagnostic-output' ]]; then diagnostic="$2"; break; fi
  shift
done
if [[ "${count}" -eq 1 ]]; then
  printf '%s\n' '{"status":"error","code":"window_selector_not_unique","command":"relaykit-ax-inspect"}'
  exit 5
fi
printf '%s\n' '{"ax_windows_count":0,"window_server_surface_count":1,"ax_popover_count":1,"semantic_identifier_count":2}' >"${diagnostic}"
chmod 600 "${diagnostic}"
printf '%s\n' '{"status":"ok","code":"ok","command":"relaykit-ax-inspect","window_verified":true,"action_count":0,"ax_windows_count":0,"window_server_surface_count":1,"ax_popover_count":1,"semantic_identifier_count":2}'
SH
chmod 700 "${ax_ready_driver}"
AX_READY_COUNTER="${ax_ready_counter}" "${SCRIPT}" --test-wait-relaykit-ax-surface \
  "${ax_ready_driver}" "${ax_ready_identity}" "${ax_ready_diagnostic}" 4242
[[ "$(cat "${ax_ready_counter}")" == 2 ]] || fail "RelayKit AX readiness did not stop after the first exact semantic surface"
jq -e '.window_server_surface_count == 1 and .ax_popover_count == 1 and .semantic_identifier_count == 2' "${ax_ready_diagnostic}" >/dev/null ||
  fail "RelayKit AX readiness did not retain exact diagnostic evidence"

ax_ready_body="$(sed -n '/^wait_for_relaykit_ax_surface()/,/^}/p' "${SCRIPT}")"
for required_ready_text in RELAYKIT_AX_DRIVER_DIAGNOSTIC relaykit-ax-inspect window_server_surface_count ax_popover_count semantic_identifier_count action_count; do
  rg -Fq "${required_ready_text}" <<<"${ax_ready_body}" ||
    fail "RelayKit AX readiness is missing ${required_ready_text}"
done
for forbidden_ready_text in relaykit-provider-configure provider-form-save CGEvent OCR kAXPositionAttribute kAXSizeAttribute; do
  if rg -Fq "${forbidden_ready_text}" <<<"${ax_ready_body}"; then
    fail "RelayKit AX readiness crossed into product actions: ${forbidden_ready_text}"
  fi
done
launch_ordinary_body="$(sed -n '/^launch_ordinary_app()/,/^}/p' "${SCRIPT}")"
rg -Uq 'write_exact_app_window_identity(.|\n)*wait_for_relaykit_ax_surface(.|\n)*return 0' <<<"${launch_ordinary_body}" ||
  fail "ordinary App launch does not wait for the exact semantic AX surface"
if grep -Fq 'activate_exact_app' <<<"${launch_ordinary_body}"; then
  fail "ordinary native Popover launch must not activate RelayKit after exact binding"
fi
grep -Fq 'RELAYKIT_OFFICIAL_PROOF_ROOT=${RC1_PERSISTENT_PROOF_ROOT}/official-proof' <<<"${launch_ordinary_body}" ||
  fail "ordinary App launch does not use the persistent isolated official proof root"
if grep -Fq 'RELAYKIT_OFFICIAL_PROOF_ROOT=${OUT}/app-official-proof' <<<"${launch_ordinary_body}"; then
  fail "ordinary App launch still uses an App-rejected dist proof root"
fi

desktop_launch_body="$(sed -n '/^RELAYKIT_DESKTOP_PROOF_INPUT_MODE=automated_ax/,/manual-proof-result.json/p' "${SCRIPT}")"
grep -Fq 'RELAYKIT_RC1_DESKTOP_ROOT="${RC1_PERSISTENT_PROOF_ROOT}"' <<<"${desktop_launch_body}" ||
  fail "RC1 Desktop launch does not reuse the persistent isolated Desktop profile"
grep -Fq 'RELAYKIT_RC1_OUTPUT="${OUT}/desktop-evidence"' <<<"${desktop_launch_body}" ||
  fail "RC1 Desktop current-run evidence is no longer isolated under the fresh output"

ax_repro_failure="${TMP}/ax-repro-failure.txt"
ax_repro_status=0
env -u RELAYKIT_RC1_APP_BUNDLE -u RELAYKIT_RC1_AX_INSPECT_OUT \
  "${SCRIPT}" --window-ax-inspect-repro >"${ax_repro_failure}" 2>&1 || ax_repro_status=$?
[[ "${ax_repro_status}" -ne 0 ]] || fail "AX inspect repro unexpectedly ran without explicit inputs"
rg -Fq 'AX inspect repro requires RELAYKIT_RC1_APP_BUNDLE' "${ax_repro_failure}" ||
  fail "AX inspect repro did not fail at its explicit App bundle gate"
if rg -Fq 'three-stage native Responses Desktop proof failed' "${ax_repro_failure}"; then
  fail "AX inspect repro fell through into the full RC1 proof"
fi

ax_repro_body="$(sed -n '/run_window_ax_inspect_repro()/,/^}/p' "${SCRIPT}")"
for required_repro_text in \
  'RELAYKIT_RC1_APP_BUNDLE' \
  'RELAYKIT_RC1_AX_INSPECT_OUT' \
  'open_exact_menu_bar_popover' \
  'write_exact_app_window_identity' \
  'RELAYKIT_AX_DRIVER_DIAGNOSTIC=1' \
  'relaykit-ax-inspect' \
  '--diagnostic-output' \
  'window-identity.json' \
  'ax-tree.json' \
  'ax-driver-report.json'; do
  rg -Fq -- "${required_repro_text}" <<<"${ax_repro_body}" ||
    fail "AX inspect repro is missing bounded behavior: ${required_repro_text}"
done
grep -Fq 'find_exact_app_pid' <<<"${launch_body:-$(sed -n '/^launch_ax_inspect_app()/,/^}/p' "${SCRIPT}")}" ||
  fail "focused AX inspect launch helper lost exact PID discovery"
[[ "$(rg -c '^[[:space:]]+relaykit-ax-inspect --pid' <<<"${ax_repro_body}")" -eq 1 ]] ||
  fail "AX inspect repro must invoke the diagnostic exactly once"
for forbidden_repro_text in \
  PROVIDER_NAME SYNTHETIC_KEY KEYCHAIN_CREATED wait_for_gateway \
  rc1-native-responses-three-stage scenario.json provider-events app-usage \
  desktop-evidence native-app-evidence manifest.json BUNDLED_RELAY; do
  if rg -Fq "${forbidden_repro_text}" <<<"${ax_repro_body}"; then
    fail "AX inspect repro expanded into forbidden proof scope: ${forbidden_repro_text}"
  fi
done

ax_repro_dispatch="$(sed -n '/--window-ax-inspect-repro/,/\[\[ "\$#" -eq 0 \]\]/p' "${SCRIPT}")"
grep -Fq 'run_window_ax_inspect_repro' <<<"${ax_repro_dispatch}" ||
  fail "AX inspect repro flag is not dispatched"
grep -Fq 'exit 0' <<<"${ax_repro_dispatch}" ||
  fail "AX inspect repro flag can fall through into another proof mode"
if rg -Fq 'run_window_identity_repro' <<<"${ax_repro_dispatch}"; then
  fail "AX inspect repro must not fall back to the window identity repro"
fi

fake_bundle="${TMP}/RelayKitApp.app"
fake_app="${fake_bundle}/Contents/MacOS/RelayKitApp.bin"
fake_relay="${fake_bundle}/Contents/MacOS/relay"
mkdir -p "$(dirname "${fake_app}")"
cat >"${fake_app}" <<'SH'
#!/usr/bin/env bash
exit 0
SH
cp "${fake_app}" "${fake_relay}"
chmod 700 "${fake_app}" "${fake_relay}"

launch_body="$(sed -n '/^launch_ax_inspect_app()/,/^}/p' "${SCRIPT}")"
[[ -n "${launch_body}" ]] || fail "proof is missing the focused AX inspect launch helper"
fake_open="${TMP}/fake-open"
cat >"${fake_open}" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$2" >>"${FAKE_OPEN_LOG}"
[[ -z "${FAKE_OPEN_STDERR:-}" ]] || printf '%s\n' "${FAKE_OPEN_STDERR}" >&2
exit "${FAKE_OPEN_EXIT}"
SH
chmod 700 "${fake_open}"
launch_contract="${TMP}/launch-contract"
printf '%s\n' '#!/usr/bin/env bash' 'set -euo pipefail' >"${launch_contract}"
sed "s#/usr/bin/open#${fake_open}#" <<<"${launch_body}" >>"${launch_contract}"
cat >>"${launch_contract}" <<'SH'
sleep() { :; }
find_exact_app_pid() { [[ "${FAKE_PID_COUNT}" == 1 ]] && printf '%s\n' 4242; }
APP_BUNDLE="$1"; AX_INSPECT_TEMP="$2"; mkdir -p "${AX_INSPECT_TEMP}"
APP_PID=""; AX_INSPECT_FAILURE=repro_failed; AX_INSPECT_APP_LAUNCHED=false; AX_INSPECT_LAUNCHED_PID=""
AX_INSPECT_OPEN_INVOCATION_COUNT=0; AX_INSPECT_OPEN_SUCCESS_COUNT=0; AX_INSPECT_OPEN_EXIT_STATUS=0
AX_INSPECT_OPEN_STDERR_CATEGORY=not_invoked; AX_INSPECT_EXACT_PID_COUNT=0; AX_INSPECT_APP_LAUNCH_COUNT=0
helper_exit=0; launch_ax_inspect_app || helper_exit=$?
jq -n --arg bundle "${APP_BUNDLE}" --arg failure "${AX_INSPECT_FAILURE}" \
  --arg category "${AX_INSPECT_OPEN_STDERR_CATEGORY}" --argjson helper_exit "${helper_exit}" \
  --argjson invocation "${AX_INSPECT_OPEN_INVOCATION_COUNT}" --argjson success "${AX_INSPECT_OPEN_SUCCESS_COUNT}" \
  --argjson open_exit "${AX_INSPECT_OPEN_EXIT_STATUS}" --argjson exact_pid "${AX_INSPECT_EXACT_PID_COUNT}" \
  --argjson app_launch "${AX_INSPECT_APP_LAUNCH_COUNT}" \
  '{app_bundle_path:$bundle,failure:$failure,helper_exit:$helper_exit,open_invocation_count:$invocation,
    open_success_count:$success,open_exit_status:$open_exit,open_stderr_category:$category,
    exact_pid_count:$exact_pid,app_launch_count:$app_launch}'
SH
chmod 700 "${launch_contract}"

run_launch_case() {
  local name="$1" bundle="$2" open_exit="$3" open_stderr="$4" pid_count="$5"
  local invocation="$6" success="$7" category="$8" exact_pid="$9" app_launch="${10}" helper_exit="${11}" failure="${12}"
  local log="${TMP}/${name}.open-log" result="${TMP}/${name}.json" stderr="${TMP}/${name}.stderr"
  : >"${log}"
  FAKE_OPEN_LOG="${log}" FAKE_OPEN_EXIT="${open_exit}" FAKE_OPEN_STDERR="${open_stderr}" FAKE_PID_COUNT="${pid_count}" \
    "${launch_contract}" "${bundle}" "${TMP}/${name}.run" >"${result}" 2>"${stderr}"
  [[ ! -s "${stderr}" ]] || fail "${name} exposed raw open stderr"
  jq -e --arg bundle "${bundle}" --arg category "${category}" --arg failure "${failure}" \
    --argjson helper_exit "${helper_exit}" --argjson invocation "${invocation}" \
    --argjson success "${success}" --argjson open_exit "${open_exit}" --argjson exact_pid "${exact_pid}" \
    --argjson app_launch "${app_launch}" '.app_bundle_path == $bundle and .open_invocation_count == $invocation and
      .open_success_count == $success and .open_exit_status == $open_exit and .open_stderr_category == $category and
      .exact_pid_count == $exact_pid and .app_launch_count == $app_launch and
      .helper_exit == $helper_exit and .failure == $failure' "${result}" >/dev/null || fail "${name} launch evidence mismatch"
  [[ "$(wc -l <"${log}" | tr -d ' ')" -eq "${invocation}" ]] || fail "${name} open invocation count mismatch"
  [[ "${invocation}" -eq 0 || "$(cat "${log}")" == "${bundle}" ]] || fail "${name} did not target the exact App bundle"
  [[ ! -e "${TMP}/${name}.run/open.stderr" ]] || fail "${name} retained raw open stderr"
}

run_launch_case launch-invalid-suffix "${TMP}/app" 0 '' 0 0 0 not_invoked 0 0 2 app_bundle_path_invalid
run_launch_case launch-open-failed "${fake_bundle}" 23 'private fake open detail' 0 1 0 open_failed_with_stderr 0 0 23 open_failed
run_launch_case launch-pid-absent "${fake_bundle}" 0 '' 0 1 1 none 0 0 1 exact_pid_absent
run_launch_case launch-exact-pid "${fake_bundle}" 0 'private fake open warning' 1 1 1 open_succeeded_with_stderr 1 1 0 repro_failed

status_item_body="$(sed -n '/^read_exact_status_item_state()/,/^}/p;/^open_exact_menu_bar_popover()/,/^}/p' "${SCRIPT}")"
grep -Fq 'read_exact_status_item_state' <<<"${status_item_body}" ||
  fail "proof is missing exact-PID status item readiness"
grep -Fq 'native menu-bar popover' <<<"${status_item_body}" ||
  fail "proof does not use native popover terminology"
status_item_contract="${TMP}/status-item-contract"
cat >"${status_item_contract}" <<SH
#!/usr/bin/env bash
set -euo pipefail
STATUS_ITEM_READINESS_ATTEMPTS=100
STATUS_ITEM_READINESS_INTERVAL=0.1
APP_PID=4242
fail() { printf '%s\n' "\$*" >&2; exit 1; }
${status_item_body}
open_exact_menu_bar_popover
SH
chmod 700 "${status_item_contract}"
status_item_bin="${TMP}/status-item-bin"
mkdir -p "${status_item_bin}"
cat >"${status_item_bin}/osascript" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
pid="$2"
action="$3"
index="$(cat "${STATUS_ITEM_STATE}" 2>/dev/null || printf 0)"
line="$(sed -n "$((index + 1))p" "${STATUS_ITEM_SEQUENCE}")"
[[ -n "${line}" ]] || line="$(tail -n 1 "${STATUS_ITEM_SEQUENCE}")"
printf '%s\n' "$((index + 1))" >"${STATUS_ITEM_STATE}"
case "${line}" in
  error:-1719)
    [[ "${action}" == "click" ]] && printf 'final pid=%s\n' "${pid}" >>"${STATUS_ITEM_LOG}" ||
      printf 'poll pid=%s\n' "${pid}" >>"${STATUS_ITEM_LOG}"
    printf '%s\n' 'synthetic System Events error (-1719)' >&2
    exit 1
    ;;
  error:*)
    printf 'poll pid=%s\n' "${pid}" >>"${STATUS_ITEM_LOG}"
    printf '%s\n' 'synthetic nontransient read failure' >&2
    exit 1
    ;;
  counts:*)
    IFS=: read -r _ process_count bar_count item_count <<<"${line}"
    if [[ "${action}" == "click" ]]; then
      if [[ "${process_count}/${bar_count}/${item_count}" == "1/1/1" ]]; then
        printf 'click pid=%s\n' "${pid}" >>"${STATUS_ITEM_LOG}"
      else
        printf 'final pid=%s\n' "${pid}" >>"${STATUS_ITEM_LOG}"
      fi
    else
      printf 'poll pid=%s\n' "${pid}" >>"${STATUS_ITEM_LOG}"
    fi
    printf '%s\t%s\t%s\n' "${process_count}" "${bar_count}" "${item_count}"
    ;;
  *)
    printf 'poll pid=%s\n' "${pid}" >>"${STATUS_ITEM_LOG}"
    printf '%s\n' 'malformed synthetic output'
    ;;
esac
SH
chmod 700 "${status_item_bin}/osascript"

run_status_item_case() {
  local name="$1"
  local sequence="$2"
  local expected_status="$3"
  local expected_code="$4"
  local expected_polls="$5"
  local expected_finals="$6"
  local expected_clicks="$7"
  local sequence_path="${TMP}/${name}.sequence"
  local state_path="${TMP}/${name}.state"
  local log_path="${TMP}/${name}.log"
  local stderr="${TMP}/${name}.stderr"
  local status=0
  printf '%s\n' "${sequence}" | tr ' ' '\n' >"${sequence_path}"
  : >"${log_path}"
  PATH="${status_item_bin}:${PATH}" STATUS_ITEM_SEQUENCE="${sequence_path}" \
    STATUS_ITEM_STATE="${state_path}" STATUS_ITEM_LOG="${log_path}" \
    "${status_item_contract}" >"${TMP}/${name}.stdout" 2>"${stderr}" || status=$?
  [[ "${status}" -eq "${expected_status}" ]] || fail "${name} exit mismatch"
  if [[ -n "${expected_code}" ]]; then
    [[ "$(cat "${stderr}")" == "${expected_code}" ]] || fail "${name} failure was not sanitized"
  else
    [[ ! -s "${stderr}" ]] || fail "${name} emitted unexpected stderr"
  fi
  [[ "$(rg -c '^poll pid=4242$' "${log_path}" || true)" -eq "${expected_polls}" ]] || fail "${name} poll count changed"
  [[ "$(rg -c '^final pid=4242$' "${log_path}" || true)" -eq "${expected_finals}" ]] || fail "${name} final recheck count changed"
  [[ "$(rg -c '^click pid=4242$' "${log_path}" || true)" -eq "${expected_clicks}" ]] || fail "${name} click count changed"
}

run_status_item_case readiness-success \
  'error:-1719 counts:1:0:0 counts:1:1:0 counts:1:1:1' 0 '' 4 0 1
run_status_item_case readiness-timeout \
  'error:-1719 counts:1:0:0 counts:1:1:0' 1 status_item_readiness_timeout 100 0 0
run_status_item_case readiness-nonunique 'counts:1:1:2' 1 status_item_not_unique 1 0 0
run_status_item_case readiness-malformed 'malformed' 1 status_item_read_error 1 0 0
run_status_item_case readiness-nontransient 'error:42' 1 status_item_read_error 1 0 0
run_status_item_case readiness-negative 'counts:1:-1:0' 1 status_item_read_error 1 0 0
run_status_item_case readiness-process-loss 'counts:0:0:0' 1 status_item_read_error 1 0 0
run_status_item_case readiness-final-drift 'counts:1:1:1 counts:1:1:2' 1 status_item_not_unique 1 1 0
run_status_item_case readiness-final-unavailable 'counts:1:1:1 error:-1719' \
  1 status_item_click_unavailable 1 1 0
[[ "$(rg -c 'click item 1 of statusItems' <<<"${status_item_body}")" -eq 1 ]] ||
  fail "status item helper must contain exactly one click"
if grep -Fq 'set frontmost of targetProcess to true' <<<"${status_item_body}"; then
  fail "status item helper must not activate the nonactivating RelayKit panel"
fi

fake_failure_driver="${TMP}/fake-ax-driver-failure"
cat >"${fake_failure_driver}" <<'SH'
#!/usr/bin/env bash
[[ -z "${OWNED_FAULT_PARENT:-}" ]] || chmod 500 "${OWNED_FAULT_PARENT}"
printf '%s\n' '{"ax_windows_count":1,"candidate_count":0,"code":"window_selector_not_unique","command":"relaykit-ax-inspect","ax_popover_count":0,"semantic_identifier_count":0,"status":"error","window_server_surface_count":1}'
exit 4
SH
chmod 700 "${fake_failure_driver}"

fake_success_driver="${TMP}/fake-ax-driver-success"
cat >"${fake_success_driver}" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[[ -z "${OWNED_FAULT_PARENT:-}" ]] || chmod 500 "${OWNED_FAULT_PARENT}"
diagnostic_output=""
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --diagnostic-output) diagnostic_output="$2"; shift 2 ;;
    *) shift ;;
  esac
done
[[ -n "${diagnostic_output}" ]]
jq -n '{
  status:"ok",ax_windows_available:true,ax_windows_count:0,
  window_server_surface_count:1,ax_popover_count:1,semantic_identifier_count:1,truncated:false,
  nodes:[{ordinal:0,parent:null,depth:0,role:"AXPopover",subrole:null,
    child_count:1,bound_surface_root:true},
    {ordinal:1,parent:0,depth:1,role:"AXButton",subrole:null,
    child_count:0,bound_surface_root:false}],
  role_counts:[{role:"AXButton",count:1},{role:"AXPopover",count:1}],
  depth_counts:[{depth:0,count:1},{depth:1,count:1}]
}' >"${diagnostic_output}"
chmod 600 "${diagnostic_output}"
printf '%s\n' '{"action_count":0,"ax_popover_count":1,"ax_windows_count":0,"code":"ok","command":"relaykit-ax-inspect","semantic_identifier_count":1,"status":"ok","window_server_surface_count":1,"window_verified":true}'
SH
chmod 700 "${fake_success_driver}"

fake_popover_success_driver="${TMP}/fake-ax-driver-popover-success"
cp "${fake_success_driver}" "${fake_popover_success_driver}"
chmod 700 "${fake_popover_success_driver}"
fake_popover_proxy_driver="${TMP}/fake-ax-driver-popover-proxy"
cp "${fake_popover_success_driver}" "${fake_popover_proxy_driver}"
chmod 700 "${fake_popover_proxy_driver}"

fake_no_semantic_driver="${TMP}/fake-ax-driver-no-semantic"
cp "${fake_success_driver}" "${fake_no_semantic_driver}"
sed -i '' 's/semantic_identifier_count:1/semantic_identifier_count:0/' "${fake_no_semantic_driver}"
chmod 700 "${fake_no_semantic_driver}"

fake_nonunique_ax_driver="${TMP}/fake-ax-driver-nonunique-window"
cp "${fake_success_driver}" "${fake_nonunique_ax_driver}"
sed -i '' 's/ax_popover_count:1/ax_popover_count:2/' "${fake_nonunique_ax_driver}"
chmod 700 "${fake_nonunique_ax_driver}"

fake_duplicate_windowserver_driver="${TMP}/fake-ax-driver-duplicate-windowserver"
cat >"${fake_duplicate_windowserver_driver}" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
diagnostic_output=""
for ((index=1; index <= $#; index++)); do
  if [[ "${!index}" == "--diagnostic-output" ]]; then
    next=$((index + 1)); diagnostic_output="${!next}"; break
  fi
done
"${FAKE_SUCCESS_DRIVER}" "$@"
window_diagnostic="$(dirname "${diagnostic_output}")/window-diagnostic.json"
jq '.candidates += [.candidates[0]]' "${window_diagnostic}" >"${window_diagnostic}.tmp"
chmod 600 "${window_diagnostic}.tmp"; mv "${window_diagnostic}.tmp" "${window_diagnostic}"
SH
chmod 700 "${fake_duplicate_windowserver_driver}"

fake_drift_driver="${TMP}/fake-ax-driver-drift"
cat >"${fake_drift_driver}" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
marker="${OWNED_ROOT}/.relaykit-rc1-ax-inspect-owned"
case "${OWNED_DRIFT_KIND}" in
  app) mv "${OWNED_ROOT}/RelayKitApp.app" "${OWNED_ROOT}.saved-app"; mkdir -p "${OWNED_ROOT}/RelayKitApp.app/Contents/MacOS"; cp "${FAKE_APP}" "${OWNED_ROOT}/RelayKitApp.app/Contents/MacOS/RelayKitApp.bin" ;;
  marker) mv "${marker}" "${OWNED_ROOT}.saved-marker"; printf '%s\n' "${OWNED_ROOT}/RelayKitApp.app" >"${marker}"; chmod 600 "${marker}" ;;
  root) mv "${OWNED_ROOT}" "${OWNED_ROOT}.saved-root"; mkdir -m 700 "${OWNED_ROOT}"; mkdir -p "${OWNED_ROOT}/RelayKitApp.app/Contents/MacOS"; cp "${FAKE_APP}" "${OWNED_ROOT}/RelayKitApp.app/Contents/MacOS/RelayKitApp.bin"; printf '%s\n' "${OWNED_ROOT}/RelayKitApp.app" >"${marker}"; chmod 600 "${marker}" ;;
  extra) for n in {1..300}; do : >"${OWNED_ROOT}/RelayKitApp.app/Contents/MacOS/pad-${n}"; done; (while [[ -e "${OWNED_ROOT}/RelayKitApp.app/Contents/MacOS/RelayKitApp.bin" ]]; do :; done; : >"${OWNED_ROOT}/appeared-during-cleanup") & ;;
esac
exec "${FAKE_SUCCESS_DRIVER}" "$@"
SH
chmod 700 "${fake_drift_driver}"

run_ax_contract="${TMP}/run-ax-contract"
printf '%s\n' '#!/usr/bin/env bash' 'set -euo pipefail' >"${run_ax_contract}"
sed -n '/^run_ax()/,/^}/p;/^atomic_copy_private()/,/^}/p' "${SCRIPT}" >>"${run_ax_contract}"
run_ax_body="$(sed -n '/^run_ax()/,/^}/p' "${SCRIPT}")"
! rg -Fq 'activate_exact_app' <<<"${run_ax_body}" ||
  fail "exact AX actions must not reactivate the transient Popover between steps"
rg -Fq 'sleep 0.25' <<<"${run_ax_body}" ||
  fail "exact AX actions do not wait for the Popover tree to settle"
printf '%s\n' 'activate_exact_app() { :; }' 'OUT="$1"' 'report="$2"' 'shift 2' 'if run_ax "${report}" "$@"; then exit 0; else exit "$?"; fi' >>"${run_ax_contract}"
chmod 700 "${run_ax_contract}"
run_ax_success_root="${TMP}/run-ax-success"; run_ax_failure_root="${TMP}/run-ax-failure"
mkdir -p "${run_ax_success_root}/run" "${run_ax_failure_root}/run"
cat >"${run_ax_success_root}/run/codex-desktop-ax-driver" <<'SH'
#!/usr/bin/env bash
printf '%s\n' '{"action_count":0,"code":"ok","command":"relaykit-provider-protocol-probe","status":"ok","window_verified":true}'
SH
cat >"${run_ax_failure_root}/run/codex-desktop-ax-driver" <<'SH'
#!/usr/bin/env bash
printf '%s\n' '{"candidate_count":2,"code":"relaykit_protocol_identifier_multiple","command":"relaykit-provider-protocol-probe","status":"error"}'
exit 6
SH
chmod 700 "${run_ax_success_root}/run/codex-desktop-ax-driver" "${run_ax_failure_root}/run/codex-desktop-ax-driver"
run_ax_success_report="${TMP}/run-ax-success.json"
(umask 022; "${run_ax_contract}" "${run_ax_success_root}" "${run_ax_success_report}" probe)
[[ "$(stat -f '%Lp' "${run_ax_success_report}")" == "600" ]] || fail "run_ax success report is not 0600"
jq -e '(keys | sort) == ["action_count","code","command","status","window_verified"] and .status == "ok" and .code == "ok" and .command == "relaykit-provider-protocol-probe" and .window_verified == true and .action_count == 0' "${run_ax_success_report}" >/dev/null || fail "run_ax success content changed"
! compgen -G "${run_ax_success_report}.tmp.*" >/dev/null || fail "run_ax success left a temporary report"
run_ax_failure_report="${TMP}/run-ax-failure.json"; run_ax_failure_status=0
(umask 022; "${run_ax_contract}" "${run_ax_failure_root}" "${run_ax_failure_report}" probe) || run_ax_failure_status=$?
[[ "${run_ax_failure_status}" -eq 6 && "$(stat -f '%Lp' "${run_ax_failure_report}")" == "600" ]] || fail "run_ax failure status or mode changed"
jq -e '(keys | sort) == ["candidate_count","code","command","status"] and .status == "error" and .code == "relaykit_protocol_identifier_multiple" and .command == "relaykit-provider-protocol-probe" and .candidate_count == 2' "${run_ax_failure_report}" >/dev/null || fail "run_ax failure content changed"
! compgen -G "${run_ax_failure_report}.tmp.*" >/dev/null || fail "run_ax failure left a temporary report"
mv_fault_bin="${TMP}/mv-fault-bin"; mv_fault_dir="${TMP}/run-ax-mv-fault"
mkdir -p "${mv_fault_bin}" "${mv_fault_dir}"
cat >"${mv_fault_bin}/mv" <<'SH'
#!/usr/bin/env bash
exit 73
SH
chmod 700 "${mv_fault_bin}/mv"
mv_fault_report="${mv_fault_dir}/report.json"; mv_fault_status=0
(umask 022; PATH="${mv_fault_bin}:${PATH}" "${run_ax_contract}" "${run_ax_success_root}" "${mv_fault_report}" probe) || mv_fault_status=$?
[[ "${mv_fault_status}" -ne 0 ]] || fail "run_ax mv fault unexpectedly succeeded"
[[ ! -e "${mv_fault_report}" ]] || fail "run_ax mv fault published a report"
! compgen -G "${mv_fault_report}.tmp.*" >/dev/null || fail "run_ax mv fault left a report temporary"
[[ -z "$(find "${mv_fault_dir}" -mindepth 1 -print -quit)" ]] || fail "run_ax mv fault left another temporary"
atomic_copy_body="$(sed -n '/^atomic_copy_private()/,/^}/p' "${SCRIPT}")"
for required_atomic_copy_text in '/bin/cp "${source}" "${temporary}" || { /bin/rm -f "${temporary}"; return 1; }' 'chmod 600 "${temporary}" || { /bin/rm -f "${temporary}"; return 1; }' 'mv -f "${temporary}" "${target}" || { /bin/rm -f "${temporary}"; return 1; }'; do
  grep -Fq "${required_atomic_copy_text}" <<<"${atomic_copy_body}" || fail "atomic_copy_private is missing checked cleanup: ${required_atomic_copy_text}"
done

fake_mutating_driver="${TMP}/fake-ax-driver-mutates-config"
cp "${fake_success_driver}" "${fake_mutating_driver}"
sed -i '' '/^diagnostic_output=""$/a\
printf "%s\\n" "unexpected config drift" >"${HOME}/.codex/config.toml"' "${fake_mutating_driver}"
chmod 700 "${fake_mutating_driver}"

fake_auth_mutating_driver="${TMP}/fake-ax-driver-mutates-auth"
cp "${fake_success_driver}" "${fake_auth_mutating_driver}"
sed -i '' '/^diagnostic_output=""$/a\
printf "%s\\n" "unexpected auth drift" >"${HOME}/.codex/auth.json"' "${fake_auth_mutating_driver}"
chmod 700 "${fake_auth_mutating_driver}"

test_home="${TMP}/home"
mkdir -p "${test_home}/.codex"
printf '%s\n' 'synthetic config baseline' >"${test_home}/.codex/config.toml"
printf '%s\n' '{"synthetic":"auth baseline"}' >"${test_home}/.codex/auth.json"
chmod 600 "${test_home}/.codex/config.toml" "${test_home}/.codex/auth.json"
test_config_sha="$(/usr/bin/shasum -a 256 "${test_home}/.codex/config.toml" | awk '{print $1}')"
test_auth_sha="$(/usr/bin/shasum -a 256 "${test_home}/.codex/auth.json" | awk '{print $1}')"
test_rebaseline_evidence="${TMP}/config-rebaseline.json"
jq -n \
  --arg config_sha "${test_config_sha}" \
  --arg auth_sha "${test_auth_sha}" '{
    schema_version:1,
    observation:"external_pre_run_config_replacement",
    previous_config_sha256:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    new_config_sha256:$config_sha,
    auth_sha256:$auth_sha,
    config_stat:{inode:1,birth:"test",mtime:"test",ctime:"test",mode:"0600",size:26},
    latest_diagnostic_started_at:"2026-07-14T23:56:43+0800",
    latest_diagnostic_finalized_at:"2026-07-14T23:56:45+0800",
    replacement_predated_relaykit_run:true,
    latest_relaykit_run_changed_config:false,
    latest_relaykit_run_changed_auth:false,
    new_baseline_effective_for_future_fresh_runs:true,
    global_files_written:false,
    recorded_at:"2026-07-14T16:11:06Z"
  }' >"${test_rebaseline_evidence}"
chmod 600 "${test_rebaseline_evidence}"
test_rebaseline_sha="$(/usr/bin/shasum -a 256 "${test_rebaseline_evidence}" | awk '{print $1}')"

assert_private_json() {
  local path="$1"
  [[ -f "${path}" && ! -L "${path}" ]] || fail "stable evidence is missing: ${path}"
  [[ "$(stat -f '%Lp' "${path}")" == "600" ]] || fail "stable evidence is not 0600: ${path}"
  jq -e . "${path}" >/dev/null || fail "stable evidence is not JSON: ${path}"
}

assert_manifest_hashes() {
  local manifest="$1"
  local root="$2"
  while IFS=$'\t' read -r path status expected_hash; do
    if [[ "${status}" == "created" ]]; then
      [[ -f "${root}/${path}" ]] || fail "manifest created artifact is absent: ${path}"
      [[ "$(/usr/bin/shasum -a 256 "${root}/${path}" | awk '{print $1}')" == "${expected_hash}" ]] ||
        fail "manifest hash mismatch: ${path}"
    else
      [[ "${status}" == "not_created" && "${expected_hash}" == "null" ]] ||
        fail "manifest absence state is invalid: ${path}"
      [[ ! -e "${root}/${path}" ]] || fail "manifest marked an existing artifact not_created: ${path}"
    fi
  done < <(jq -r '.artifacts[] | [.path,.status,(.sha256 // "null")] | @tsv' "${manifest}")
}

tracked_paths=(
  app/Sources/RelayKitApp/App/RelayKitApp.swift app/Sources/RelayKitAppValidationTests/main.swift
  scripts/codex-desktop-ax-driver.swift scripts/codex-desktop-ax-driver-test.sh
  scripts/rc1-native-responses-proof.sh scripts/rc1-native-responses-proof-test.sh
)
tracked_hashes="$(for path in "${tracked_paths[@]}"; do
  jq -n --arg key "${path}" --arg value "$(/usr/bin/shasum -a 256 "${ROOT}/${path}" | awk '{print $1}')" '{key:$key,value:$value}'
done | jq -s 'from_entries')"

run_ax_rebaseline_gate_failure() {
  local name="$1"
  local evidence_path="$2"
  local evidence_sha="$3"
  local expected_message="$4"
  local exact_root="${TMP}/${name}-output"
  local stderr="${TMP}/${name}.stderr"
  local status=0
  local env_args=(
    -u RELAYKIT_RC1_CONFIG_REBASELINE_EVIDENCE
    -u RELAYKIT_RC1_CONFIG_REBASELINE_EVIDENCE_SHA256
  )
  if [[ -n "${evidence_path}" ]]; then
    env_args+=(
      "RELAYKIT_RC1_CONFIG_REBASELINE_EVIDENCE=${evidence_path}"
      "RELAYKIT_RC1_CONFIG_REBASELINE_EVIDENCE_SHA256=${evidence_sha}"
    )
  fi
  env "${env_args[@]}" \
    HOME="${test_home}" \
    RELAYKIT_RC1_APP_BUNDLE="${fake_bundle}" \
    RELAYKIT_RC1_AX_INSPECT_OUT="${exact_root}" \
    RELAYKIT_RC1_AX_INSPECT_TEST=1 \
    RELAYKIT_RC1_AX_INSPECT_FAKE_DRIVER="${fake_success_driver}" \
    "${SCRIPT}" --window-ax-inspect-repro >"${TMP}/${name}.stdout" 2>"${stderr}" || status=$?
  [[ "${status}" -ne 0 ]] || fail "${name} diagnostic rebaseline gate unexpectedly passed"
  [[ ! -e "${exact_root}" ]] || fail "${name} diagnostic rebaseline gate wrote setup output"
  rg -Fq "${expected_message}" "${stderr}" ||
    fail "${name} diagnostic rebaseline gate reported the wrong failure"
}

make_owned_root() {
  local root="$1" bundle="${2:-$1/RelayKitApp.app}" marker="$1/.relaykit-rc1-ax-inspect-owned"
  mkdir -p "${bundle}/Contents/MacOS"; cp "${fake_app}" "${bundle}/Contents/MacOS/RelayKitApp.bin"
  chmod 700 "${root}"; printf '%s\n' "$(cd "${bundle}" && pwd -P)" >"${marker}"; chmod 600 "${marker}"
}

owned_contract="${TMP}/owned-contract"
printf '%s\n' '#!/usr/bin/env bash' 'set -euo pipefail' >"${owned_contract}"
sed -n '/^paths_overlap()/,/^}/p;/^owned_temp_ax_inspect()/,/^}/p' "${SCRIPT}" >>"${owned_contract}"
cat >>"${owned_contract}" <<'SH'
ROOT="$4"; HOME="$5"; AX_INSPECT_OWNED_TEMP_ROOT="$1"; APP_BUNDLE="$2"; AX_INSPECT_OUT="$3"
AX_INSPECT_OWNED_TEMP_CLEANUP_REQUIRED=false; AX_INSPECT_OWNED_TEMP_APP_REMOVED=false
status=0; owned_temp_ax_inspect validate || status=$?
printf '%s\n' "${AX_INSPECT_OWNED_TEMP_APP_REMOVED}"
exit "${status}"
SH
chmod 700 "${owned_contract}"

assert_owned_rejected() {
  local name="$1" root="$2" bundle="$3" out="$4" worktree="$5" home="$6" preserved="$7" status=0 removed
  removed="$(${owned_contract} "${root}" "${bundle}" "${out}" "${worktree}" "${home}" 2>/dev/null)" || status=$?
  [[ "${status}" -ne 0 && "${removed}" == false && -e "${root}" && -e "${preserved}" ]] || fail "${name} owned validation did not reject without deletion"
}

wait_for_full_test_marker() {
  local marker="$1"
  for _ in {1..500}; do
    [[ -e "${marker}" ]] && return 0
    kill -0 "${full_test_pid}" 2>/dev/null || return 1
    sleep 0.01
  done
  return 1
}

run_public_full_proof_setup_case() {
  local name="$1"
  local mutate_config="$2"
  local expected_exit="$3"
  local use_rebaseline="${4:-false}"
  local exact_out="${TMP}/${name}-output"
  local stdout="${TMP}/${name}.stdout"
  local stderr="${TMP}/${name}.stderr"
  local status=0
  local env_args=(
    -u RELAYKIT_RC1_CONFIG_REBASELINE_EVIDENCE
    -u RELAYKIT_RC1_CONFIG_REBASELINE_EVIDENCE_SHA256
  )
  if [[ "${use_rebaseline}" == "true" ]]; then
    env_args+=(
      "RELAYKIT_RC1_CONFIG_REBASELINE_EVIDENCE=${test_rebaseline_evidence}"
      "RELAYKIT_RC1_CONFIG_REBASELINE_EVIDENCE_SHA256=${test_rebaseline_sha}"
    )
  fi

  env "${env_args[@]}" \
    HOME="${test_home}" \
    RELAYKIT_RC1_APP_BUNDLE="${fake_bundle}" \
    RELAYKIT_RC1_NATIVE_RESPONSES_OUT="${exact_out}" \
    RELAYKIT_RC1_FULL_PROOF_TEST_STOP_AFTER_SETUP=1 \
    "${SCRIPT}" >"${stdout}" 2>"${stderr}" &
  full_test_pid="$!"
  if ! wait_for_full_test_marker "${exact_out}/run/full-proof-test-ready"; then
    wait "${full_test_pid}" >/dev/null 2>&1 || true
    full_test_pid=""
    fail "${name} public full proof did not reach fresh test setup"
  fi
  if [[ "${mutate_config}" == "true" ]]; then
    printf '%s\n' 'within-run config drift' >"${test_home}/.codex/config.toml"
    chmod 600 "${test_home}/.codex/config.toml"
  fi
  : >"${exact_out}/run/full-proof-test-continue"
  wait "${full_test_pid}" || status=$?
  full_test_pid=""

  [[ "${status}" -eq "${expected_exit}" ]] ||
    fail "${name} public full proof exit mismatch: expected ${expected_exit}, got ${status}"
  [[ -d "${exact_out}/run" && -d "${test_home}/Library/Application Support/RelayKit/DesktopProof" ]] ||
    fail "${name} public full proof did not create fresh private setup"
  for forbidden_setup_artifact in \
    providers.json app-usage.jsonl provider-events.jsonl scenario.json manifest.json \
    run/fixture-port run/app.pid; do
    [[ ! -e "${exact_out}/${forbidden_setup_artifact}" ]] ||
      fail "${name} test-only stop crossed into fixture/App/Desktop setup"
  done
  if rg -Fq 'config rebaseline evidence' "${stderr}"; then
    fail "${name} public full proof required diagnostic rebaseline evidence"
  fi
  if [[ "${expected_exit}" -eq 0 ]]; then
    rg -Fq 'public full proof test setup passed' "${stdout}" ||
      fail "${name} public full proof did not report the deterministic stop"
  else
    rg -Fq 'global Codex config changed' "${stderr}" ||
      fail "${name} within-run drift did not fail at final equality"
  fi
}

run_ax_finalizer_case() {
  local name="$1"
  local fake_driver="$2"
  local expected_exit="$3"
  local expected_status="$4"
  local expected_tree="$5"
  local expected_config_unchanged="${6:-true}"
  local expected_app_stopped="${7:-true}"
  local expected_shared_18787_unchanged="${8:-true}"
  local expected_port_19777_unchanged="${9:-true}"
  local expected_transient_removed="${10:-true}"
  local expected_auth_unchanged="${11:-true}"
  local owned="${12:-false}" case_bundle="${fake_bundle}" owned_root=""
  local drift="${13:-}" expected_owned_removed="${14:-${owned}}"
  local force_dead_pid="${15:-false}"
  local exact_parent="${TMP}/${name}-parent"
  local exact_root="${exact_parent}/inspect-output"
  local stdout="${TMP}/${name}.stdout"
  local stderr="${TMP}/${name}.stderr"
  local status=0
  mkdir -p "${exact_parent}"
  if [[ "${owned}" == "true" ]]; then
    owned_root="${TMP}/${name}-owned"; case_bundle="${owned_root}/RelayKitApp.app"
    make_owned_root "${owned_root}"; : >"${owned_root}-unrelated"
  fi

  env ${owned_root:+RELAYKIT_RC1_AX_INSPECT_OWNED_TEMP_ROOT="${owned_root}"} \
  HOME="${test_home}" RELAYKIT_RC1_APP_BUNDLE="${case_bundle}" \
  RELAYKIT_RC1_AX_INSPECT_OUT="${exact_root}" \
  RELAYKIT_RC1_AX_INSPECT_TEST=1 \
  RELAYKIT_RC1_AX_INSPECT_FAKE_DRIVER="${fake_driver}" \
  RELAYKIT_RC1_AX_INSPECT_TEST_FORCE_DEAD_PID="${force_dead_pid}" \
  OWNED_DRIFT_KIND="${drift}" OWNED_ROOT="${owned_root}" FAKE_APP="${fake_app}" FAKE_SUCCESS_DRIVER="${fake_success_driver}" \
  RELAYKIT_RC1_AX_INSPECT_TEST_FORCE_APP_STOPPED_FALSE="$([[ "${expected_app_stopped}" == "false" ]] && printf true || printf false)" \
  RELAYKIT_RC1_AX_INSPECT_TEST_FORCE_SHARED_18787_FALSE="$([[ "${expected_shared_18787_unchanged}" == "false" ]] && printf true || printf false)" \
  RELAYKIT_RC1_AX_INSPECT_TEST_FORCE_PORT_19777_FALSE="$([[ "${expected_port_19777_unchanged}" == "false" ]] && printf true || printf false)" \
  RELAYKIT_RC1_AX_INSPECT_TEST_FORCE_TRANSIENT_REMOVED_FALSE="$([[ "${expected_transient_removed}" == "false" ]] && printf true || printf false)" \
  RELAYKIT_RC1_CONFIG_REBASELINE_EVIDENCE="${test_rebaseline_evidence}" \
  RELAYKIT_RC1_CONFIG_REBASELINE_EVIDENCE_SHA256="${test_rebaseline_sha}" \
    "${SCRIPT}" --window-ax-inspect-repro >"${stdout}" 2>"${stderr}" || status=$?
  [[ "${status}" -eq "${expected_exit}" ]] ||
    fail "${name} did not preserve exit ${expected_exit}: got ${status}"
  [[ "$(stat -f '%Lp' "${exact_root}")" == "700" ]] || fail "${name} output root is not 0700"
  [[ ! -e "${exact_root}/.run" ]] || fail "${name} left transient .run state"
  [[ "$(rg -c -F "INSPECT_OUT=${exact_root}" "${stdout}")" -eq 2 ]] ||
    fail "${name} did not print the exact output root before launch and on exit"
  [[ -z "$(find "${exact_parent}" -maxdepth 1 -type f -print -quit)" ]] ||
    fail "${name} substituted the parent directory for the exact root"
  [[ "${owned}" == "false" && -d "${case_bundle}" || "${expected_owned_removed}" == "true" && ! -e "${owned_root}" || "${expected_owned_removed}" == "false" && -e "${owned_root}" ]] ||
    fail "${name} owned/immutable App cleanup changed"
  [[ "${owned}" == "false" || -e "${owned_root}-unrelated" ]] || fail "${name} removed unrelated content"

  for artifact in \
    run-metadata.json window-identity.json pre-click-window-diagnostic.json window-diagnostic.json ax-driver-report.json \
    cleanup.json result.json evidence-manifest.json; do
    assert_private_json "${exact_root}/${artifact}"
  done
  jq -e '
    (keys | sort) == ["captured_at","height","pid","width","window_id"] and
    (.pid | type == "number") and .pid > 0 and .window_id == 101
  ' "${exact_root}/window-identity.json" >/dev/null || fail "${name} stable identity schema is invalid"
  jq -e '
    (keys | sort) == ["candidates","captured_at","eligible_count","largest_candidate_count",
      "owner_window_count","pid","selected_window_id","status"] and
    .status == "selected" and (.pid | type == "number") and .pid > 0 and .selected_window_id == 101 and
    (.candidates | all(.[]; (keys | sort) == ["area","eligible","height","layer","width","window_id"]))
  ' "${exact_root}/window-diagnostic.json" >/dev/null || fail "${name} stable window diagnostic schema is invalid"
  jq -e '
    (keys | sort) == ["candidates","captured_at","eligible_count","largest_candidate_count",
      "owner_window_count","pid","status"] and
    .status == "no_eligible_window" and .eligible_count == 0 and .captured_at == "2026-07-16T00:00:00.000Z"
  ' "${exact_root}/pre-click-window-diagnostic.json" >/dev/null ||
    fail "${name} pre-click lifecycle diagnostic is invalid"
  if [[ "${expected_tree}" == "created" ]]; then
    assert_private_json "${exact_root}/ax-tree.json"
  else
    [[ ! -e "${exact_root}/ax-tree.json" ]] || fail "${name} wrote an empty failure tree"
  fi

  jq -e \
    --arg root "${exact_root}" --arg app_bundle "${case_bundle}" \
    --arg driver_hash "$(/usr/bin/shasum -a 256 "${fake_driver}" | awk '{print $1}')" \
    --argjson tracked_hashes "${tracked_hashes}" \
    --arg evidence_path "${test_rebaseline_evidence}" \
    --arg evidence_hash "${test_rebaseline_sha}" '
    (keys | sort) == ["app_binary_sha256","app_bundle_path","ax_driver_binary_sha256","ax_driver_source_sha256",
      "config_rebaseline_evidence_path","config_rebaseline_evidence_sha256",
      "full_e2e_invocation_count","inspect_out","mode","package_invocation_count","schema_version","tracked_files_sha256"] and
    .schema_version == 1 and .mode == "window_ax_inspect_repro" and .inspect_out == $root and
    .app_bundle_path == $app_bundle and .ax_driver_binary_sha256 == $driver_hash and
    .tracked_files_sha256 == $tracked_hashes and .package_invocation_count == 0 and .full_e2e_invocation_count == 0 and
    .config_rebaseline_evidence_path == $evidence_path and
    .config_rebaseline_evidence_sha256 == $evidence_hash and
    (.app_binary_sha256 | test("^[0-9a-f]{64}$")) and
    (.ax_driver_source_sha256 | test("^[0-9a-f]{64}$"))
  ' "${exact_root}/run-metadata.json" >/dev/null || fail "${name} run metadata schema is invalid"
  jq -e \
    --argjson config_unchanged "${expected_config_unchanged}" \
    --argjson auth_unchanged "${expected_auth_unchanged}" \
    --argjson app_stopped "${expected_app_stopped}" \
    --argjson shared_18787_unchanged "${expected_shared_18787_unchanged}" \
    --argjson port_19777_unchanged "${expected_port_19777_unchanged}" \
    --argjson transient_removed "${expected_transient_removed}" --argjson owned "${owned}" \
    --argjson owned_removed "${expected_owned_removed}" '
    (keys | sort) == ["app_launched","app_stop_attempted","app_stopped","global_auth_unchanged",
      "global_config_unchanged","owned_temp_app_removed","owned_temp_cleanup_required","port_19777_unchanged",
      "probe_binary_removed","schema_version","shared_18787_unchanged","transient_removed"] and
    .schema_version == 1 and .app_launched == false and .app_stop_attempted == false and
    .app_stopped == $app_stopped and .global_auth_unchanged == $auth_unchanged and
    .global_config_unchanged == $config_unchanged and
    .port_19777_unchanged == $port_19777_unchanged and
    .shared_18787_unchanged == $shared_18787_unchanged and
    .transient_removed == $transient_removed and .owned_temp_cleanup_required == $owned and
    .owned_temp_app_removed == $owned_removed and .probe_binary_removed == true
  ' "${exact_root}/cleanup.json" >/dev/null || fail "${name} cleanup schema is invalid"
  jq -e --arg status "${expected_status}" --arg tree "${expected_tree}" --argjson exit_code "${expected_exit}" '
    (keys | sort) == ["app_launch_count","ax_tree","driver_ax_popover_count","driver_ax_windows_count",
      "driver_candidate_count","driver_code","driver_command","driver_semantic_identifier_count",
      "driver_status","driver_window_server_surface_count","exact_pid_count","exit_code","failure","full_e2e_invocation_count",
      "open_exit_status","open_invocation_count","open_stderr_category","open_success_count",
      "package_invocation_count","same_run_lifecycle_verified","schema_version","status",
      "surface_absent_before_click","surface_appeared_after_click"] and
    .schema_version == 1 and .status == $status and .exit_code == $exit_code and .ax_tree == $tree and
    .driver_command == "relaykit-ax-inspect" and .open_invocation_count == 0 and .open_success_count == 0 and
    .open_exit_status == 0 and .open_stderr_category == "not_invoked" and .exact_pid_count == 1 and
    .app_launch_count == 0 and .package_invocation_count == 0 and .full_e2e_invocation_count == 0 and
    .surface_absent_before_click == true and .surface_appeared_after_click == true and
    .same_run_lifecycle_verified == true
  ' "${exact_root}/result.json" >/dev/null || fail "${name} result schema is invalid"
  jq -e --arg root "${exact_root}" --arg status "${expected_status}" '
    (keys | sort) == ["artifacts","failure","inspect_out","schema_version","status"] and
    .schema_version == 1 and .inspect_out == $root and .status == $status and
    (if $status == "passed" then .failure == "none" else .failure != "none" end) and
    ([.artifacts[].name] == ["run_metadata","window_identity","pre_click_window_diagnostic","window_diagnostic","driver_report","ax_tree","cleanup","result"]) and
    (.artifacts | all(.[];
      (keys | sort) == ["name","path","sha256","status"] and
      (.status == "created" or .status == "not_created")))
  ' "${exact_root}/evidence-manifest.json" >/dev/null || fail "${name} evidence manifest schema is invalid"
  assert_manifest_hashes "${exact_root}/evidence-manifest.json" "${exact_root}"

  if jq -e '[.. | objects | keys[]] | any(. == "text" or . == "title" or . == "value" or
      . == "url" or . == "document" or . == "provider" or . == "model" or . == "secret" or
      . == "clipboard" or . == "screenshot" or . == "coordinates" or . == "position" or . == "size")' \
      "${exact_root}"/*.json >/dev/null; then
    fail "${name} stable evidence exposed a sensitive schema key"
  fi
  last_finalizer_root="${exact_root}"
}

run_ax_finalizer_case failure-finalizer "${fake_failure_driver}" 4 failed not_created
jq -e '
  .status == "error" and .command == "relaykit-ax-inspect" and
  .code == "window_selector_not_unique" and .candidate_count == 0 and
  .ax_windows_count == 1 and .window_server_surface_count == 1 and
  .ax_popover_count == 0 and .semantic_identifier_count == 0
' "${last_finalizer_root}/ax-driver-report.json" >/dev/null || fail "failure driver report was not preserved exactly"
jq -e '
  .failure == "driver_failed" and .driver_status == "error" and
  .driver_code == "window_selector_not_unique" and .driver_candidate_count == 0 and
  .driver_ax_windows_count == 1 and .driver_window_server_surface_count == 1 and
  .driver_ax_popover_count == 0 and .driver_semantic_identifier_count == 0
' "${last_finalizer_root}/result.json" >/dev/null || fail "failure result lost the driver error"
jq -e '.artifacts[] | select(.name == "ax_tree") | .status == "not_created" and .sha256 == null' \
  "${last_finalizer_root}/evidence-manifest.json" >/dev/null || fail "absent failure tree was not recorded as not_created"

run_ax_finalizer_case success-finalizer "${fake_success_driver}" 0 passed created
jq -e '
  .status == "ok" and .code == "ok" and .command == "relaykit-ax-inspect" and
  .ax_windows_count == 0 and .window_server_surface_count == 1 and
  .ax_popover_count == 1 and .semantic_identifier_count == 1
' \
  "${last_finalizer_root}/ax-driver-report.json" >/dev/null || fail "success driver report was not preserved exactly"
jq -e '
  .failure == "none" and .driver_status == "ok" and .driver_code == "ok" and
  .driver_candidate_count == null and .driver_ax_windows_count == 0 and
  .driver_window_server_surface_count == 1 and .driver_ax_popover_count == 1 and
  .driver_semantic_identifier_count == 1
' "${last_finalizer_root}/result.json" >/dev/null || fail "success result is invalid"

run_ax_finalizer_case popover-success-finalizer "${fake_popover_success_driver}" 0 passed created
jq -e '
  .status == "ok" and .code == "ok" and .command == "relaykit-ax-inspect" and
	  .ax_windows_count == 0 and .window_server_surface_count == 1 and
  .ax_popover_count == 1 and .semantic_identifier_count == 1
' "${last_finalizer_root}/ax-driver-report.json" >/dev/null || fail "popover success driver report is invalid"
jq -e '
	  .status == "ok" and .ax_windows_count == 0 and .window_server_surface_count == 1 and
  .ax_popover_count == 1 and .semantic_identifier_count == 1 and
  .nodes[0].role == "AXPopover"
' "${last_finalizer_root}/ax-tree.json" >/dev/null || fail "popover success tree is invalid"
jq -e '
	  .status == "passed" and .failure == "none" and .driver_ax_windows_count == 0 and
  .driver_window_server_surface_count == 1 and .driver_ax_popover_count == 1 and
  .driver_semantic_identifier_count == 1
	' "${last_finalizer_root}/result.json" >/dev/null || fail "popover success result is invalid"

	run_ax_finalizer_case popover-proxy-finalizer "${fake_popover_proxy_driver}" 0 passed created
	jq -e '
	  .status == "passed" and .failure == "none" and .driver_ax_windows_count == 0 and
	  .driver_window_server_surface_count == 1 and .driver_ax_popover_count == 1 and
	  .driver_semantic_identifier_count == 1
	' "${last_finalizer_root}/result.json" >/dev/null || fail "popover proxy result is invalid"

run_ax_finalizer_case no-semantic-finalizer "${fake_no_semantic_driver}" 4 failed not_created
jq -e '
  .failure == "ax_binding_not_exact" and .driver_status == "ok" and
  .driver_code == "ok" and .exit_code == 4
' "${last_finalizer_root}/result.json" >/dev/null ||
  fail "missing RelayKit semantic identifier was allowed to pass"
jq -e '.status == "failed" and .failure == "ax_binding_not_exact"' \
  "${last_finalizer_root}/evidence-manifest.json" >/dev/null ||
  fail "failed semantic binding manifest implied PASS"

run_ax_finalizer_case dead-pid-finalizer "${fake_success_driver}" 4 failed created \
  true true true true true true false '' false true
jq -e '.failure == "ax_binding_not_exact" and .exact_pid_count == 1 and .exit_code == 4' \
  "${last_finalizer_root}/result.json" >/dev/null ||
  fail "dead exact PID was allowed to pass"

run_ax_finalizer_case nonunique-ax-finalizer "${fake_nonunique_ax_driver}" 4 failed not_created
jq -e '.failure == "ax_binding_not_exact" and .driver_code == "ok" and .exit_code == 4' \
  "${last_finalizer_root}/result.json" >/dev/null ||
  fail "nonunique matching AXWindow evidence was allowed to pass"

run_ax_finalizer_case duplicate-windowserver-finalizer "${fake_duplicate_windowserver_driver}" 4 failed created
jq -e '.failure == "ax_binding_not_exact" and .driver_code == "ok" and .exit_code == 4' \
  "${last_finalizer_root}/result.json" >/dev/null ||
  fail "duplicate exact WindowServer identity evidence was allowed to pass"

run_ax_finalizer_case owned-success "${fake_success_driver}" 0 passed created true true true true true true true
run_ax_finalizer_case owned-driver-failure "${fake_failure_driver}" 4 failed not_created true true true true true true true
run_ax_finalizer_case owned-app-swap "${fake_drift_driver}" 4 failed created true true true true true true true app false
run_ax_finalizer_case owned-marker-swap "${fake_drift_driver}" 4 failed created true true true true true true true marker false
run_ax_finalizer_case owned-root-swap "${fake_drift_driver}" 4 failed created true true true true true true true root false
run_ax_finalizer_case owned-extra-race "${fake_drift_driver}" 4 failed created true true true true true true true extra false

run_owned_delete_fault_case() {
  local name="$1" driver="$2" failure="$3" parent root bundle out status=0
  parent="${TMP}/${name}-fault"
  root="${parent}/owned"; bundle="${root}/RelayKitApp.app"; out="${TMP}/${name}-fault-out"
  make_owned_root "${root}"
  HOME="${test_home}" OWNED_FAULT_PARENT="${parent}" RELAYKIT_RC1_APP_BUNDLE="${bundle}" \
  RELAYKIT_RC1_AX_INSPECT_OUT="${out}" RELAYKIT_RC1_AX_INSPECT_OWNED_TEMP_ROOT="${root}" \
  RELAYKIT_RC1_AX_INSPECT_TEST=1 RELAYKIT_RC1_AX_INSPECT_FAKE_DRIVER="${driver}" \
  RELAYKIT_RC1_CONFIG_REBASELINE_EVIDENCE="${test_rebaseline_evidence}" \
  RELAYKIT_RC1_CONFIG_REBASELINE_EVIDENCE_SHA256="${test_rebaseline_sha}" \
    "${SCRIPT}" --window-ax-inspect-repro >"${TMP}/${name}.stdout" 2>"${TMP}/${name}.stderr" || status=$?
  chmod 700 "${parent}"
  [[ "${status}" -eq 4 && -d "${root}" ]] || fail "${name} deletion failure did not fail closed"
  jq -e '.owned_temp_cleanup_required == true and .owned_temp_app_removed == false' "${out}/cleanup.json" >/dev/null ||
    fail "${name} deletion failure cleanup evidence is invalid"
  jq -e --arg failure "${failure}" '.exit_code == 4 and .failure == $failure' "${out}/result.json" >/dev/null ||
    fail "${name} deletion failure overwrote the first failure"
  assert_manifest_hashes "${out}/evidence-manifest.json" "${out}"
}
run_owned_delete_fault_case owned-delete-failure "${fake_success_driver}" cleanup_invariant_failed
run_owned_delete_fault_case owned-driver-delete-failure "${fake_failure_driver}" driver_failed

run_ax_finalizer_case cleanup-app-stopped "${fake_success_driver}" 4 failed created true false
jq -e '.failure == "cleanup_invariant_failed" and .driver_status == "ok" and .driver_code == "ok"' \
  "${last_finalizer_root}/result.json" >/dev/null || fail "app_stopped cleanup failure passed"

run_ax_finalizer_case cleanup-shared-18787 "${fake_success_driver}" 4 failed created true true false
jq -e '.failure == "cleanup_invariant_failed" and .driver_status == "ok" and .driver_code == "ok"' \
  "${last_finalizer_root}/result.json" >/dev/null || fail "shared 18787 cleanup failure passed"

run_ax_finalizer_case cleanup-port-19777 "${fake_success_driver}" 4 failed created true true true false
jq -e '.failure == "cleanup_invariant_failed" and .driver_status == "ok" and .driver_code == "ok"' \
  "${last_finalizer_root}/result.json" >/dev/null || fail "port 19777 cleanup failure passed"

run_ax_finalizer_case cleanup-transient "${fake_success_driver}" 4 failed created true true true true false
jq -e '.failure == "cleanup_invariant_failed" and .driver_status == "ok" and .driver_code == "ok"' \
  "${last_finalizer_root}/result.json" >/dev/null || fail "transient cleanup failure passed"

run_ax_finalizer_case cleanup-multiple "${fake_success_driver}" 4 failed created true false false true false
jq -e '.failure == "cleanup_invariant_failed" and .driver_status == "ok" and .driver_code == "ok"' \
  "${last_finalizer_root}/result.json" >/dev/null || fail "multiple cleanup failures passed"

run_ax_finalizer_case driver-and-cleanup "${fake_failure_driver}" 4 failed not_created true false false false false
jq -e '
  .failure == "driver_failed" and .driver_status == "error" and
  .driver_code == "window_selector_not_unique" and .driver_candidate_count == 0 and .exit_code == 4
' "${last_finalizer_root}/result.json" >/dev/null ||
  fail "driver failure was overwritten by cleanup failure"

run_ax_finalizer_case config-drift-finalizer "${fake_mutating_driver}" 4 failed created false
jq -e '
  .failure == "cleanup_invariant_failed" and .driver_status == "ok" and .driver_code == "ok" and
  .exit_code == 4
' "${last_finalizer_root}/result.json" >/dev/null || fail "config drift finalizer did not fail closed"
printf '%s\n' 'synthetic config baseline' >"${test_home}/.codex/config.toml"
chmod 600 "${test_home}/.codex/config.toml"

run_ax_finalizer_case auth-drift-finalizer "${fake_auth_mutating_driver}" \
  4 failed created true true true true true false
jq -e '
  .failure == "cleanup_invariant_failed" and .driver_status == "ok" and .driver_code == "ok" and
  .exit_code == 4
' "${last_finalizer_root}/result.json" >/dev/null || fail "auth drift finalizer did not fail closed"
printf '%s\n' '{"synthetic":"auth baseline"}' >"${test_home}/.codex/auth.json"
chmod 600 "${test_home}/.codex/auth.json"

run_ax_rebaseline_gate_failure missing-rebaseline '' '' \
  'config rebaseline evidence must be an explicit regular absolute path'
run_ax_rebaseline_gate_failure wrong-rebaseline-path "${TMP}/missing-rebaseline.json" \
  "${test_rebaseline_sha}" 'config rebaseline evidence must be an explicit regular absolute path'
run_ax_rebaseline_gate_failure wrong-rebaseline-hash "${test_rebaseline_evidence}" \
  '0000000000000000000000000000000000000000000000000000000000000000' \
  'config rebaseline evidence SHA-256 changed'

mkdir -p "${TMP}/worktree" "${TMP}/worktree-safe" "${TMP}/home-safe"
validation_root="${TMP}/owned-validation"; make_owned_root "${validation_root}"; validation_bundle="${validation_root}/RelayKitApp.app"
assert_owned_rejected output-equals-root "${validation_root}" "${validation_bundle}" "${validation_root}" "${TMP}/worktree" "${test_home}" "${validation_bundle}"
assert_owned_rejected output-under-root "${validation_root}" "${validation_bundle}" "${validation_root}/output" "${TMP}/worktree" "${test_home}" "${validation_bundle}"
ln -s "${validation_root}" "${TMP}/owned-output-alias"; assert_owned_rejected output-parent-alias "${validation_root}" "${validation_bundle}" "${TMP}/owned-output-alias/output" "${TMP}/worktree" "${test_home}" "${validation_bundle}"
for relation in equal ancestor descendant; do
  protected="${validation_root}"; [[ "${relation}" == ancestor ]] && protected="${TMP}"; [[ "${relation}" == descendant ]] && protected="${validation_bundle}/Contents"
  assert_owned_rejected "worktree-${relation}" "${validation_root}" "${validation_bundle}" "${TMP}/out-worktree-${relation}" "${protected}" "${TMP}/home-safe" "${validation_bundle}"
  assert_owned_rejected "home-${relation}" "${validation_root}" "${validation_bundle}" "${TMP}/out-home-${relation}" "${TMP}/worktree-safe" "${protected}" "${validation_bundle}"
done
alias_target="${TMP}/owned-alias-target"; make_owned_root "${alias_target}"; mkdir "${TMP}/alias-parent"; ln -s "${TMP}" "${TMP}/alias-parent/link"
assert_owned_rejected root-parent-alias "${TMP}/alias-parent/link/owned-alias-target" "${alias_target}/RelayKitApp.app" "${TMP}/alias-out" "${TMP}/worktree-safe" "${TMP}/home-safe" "${alias_target}/RelayKitApp.app"
marker_target="${TMP}/marker-target"; printf '%s\n' "${validation_bundle}" >"${marker_target}"; chmod 600 "${marker_target}"; rm "${validation_root}/.relaykit-rc1-ax-inspect-owned"; ln -s "${marker_target}" "${validation_root}/.relaykit-rc1-ax-inspect-owned"
assert_owned_rejected marker-symlink "${validation_root}" "${validation_bundle}" "${TMP}/marker-out" "${TMP}/worktree-safe" "${TMP}/home-safe" "${marker_target}"
app_link_root="${TMP}/app-link-root"; mkdir -m 700 "${app_link_root}"; ln -s "${fake_bundle}" "${app_link_root}/RelayKitApp.app"; printf '%s\n' "${fake_bundle}" >"${app_link_root}/.relaykit-rc1-ax-inspect-owned"; chmod 600 "${app_link_root}/.relaykit-rc1-ax-inspect-owned"
assert_owned_rejected app-symlink "${app_link_root}" "${app_link_root}/RelayKitApp.app" "${TMP}/app-link-out" "${TMP}/worktree-safe" "${TMP}/home-safe" "${fake_bundle}"
extra_root="${TMP}/owned-extra"; make_owned_root "${extra_root}"; : >"${extra_root}/unrelated"
assert_owned_rejected third-entry "${extra_root}" "${extra_root}/RelayKitApp.app" "${TMP}/extra-out" "${TMP}/worktree-safe" "${TMP}/home-safe" "${extra_root}/unrelated"
owned_cleanup_body="$(sed -n '/^owned_temp_ax_inspect()/,/^}/p' "${SCRIPT}")"
grep -Fq 'rm -rf -- "${AX_INSPECT_OWNED_APP_REAL}"' <<<"${owned_cleanup_body}" || fail "owned cleanup lost exact App-only recursion"
! grep -Fq 'rm -rf -- "${root}"' <<<"${owned_cleanup_body}" || fail "owned cleanup still recursively deletes its root"
grep -Fq 'rmdir -- "${AX_INSPECT_OWNED_ROOT_REAL}"' <<<"${owned_cleanup_body}" || fail "owned cleanup lost empty-root rmdir"
! rg -q 'find .*-(delete|exec)|rm -rf.*OWNED_ROOT_REAL' <<<"${owned_cleanup_body}" || fail "owned cleanup added generic deletion"

signal_driver="${TMP}/fake-ax-driver-signal"
cat >"${signal_driver}" <<'SH'
#!/usr/bin/env bash
while [[ "$1" != "--diagnostic-output" ]]; do shift; done
diagnostic="$2"; : >"${diagnostic%/*}/codex-desktop-ax-driver"; : >"${SIGNAL_READY}"
while [[ ! -e "${SIGNAL_CONTINUE}" ]]; do sleep 0.01; done
jq -n '{status:"ok",ax_windows_available:true,ax_windows_count:1,window_server_surface_count:1,
  ax_popover_count:0,truncated:false,nodes:[],role_counts:[],depth_counts:[]}' >"${diagnostic}"
printf '%s\n' '{"ax_windows_count":1,"code":"ok","command":"relaykit-ax-inspect","ax_popover_count":0,"semantic_identifier_count":0,"status":"ok","window_server_surface_count":1,"window_verified":true}'
SH
chmod 700 "${signal_driver}"
run_owned_signal_case() {
  local name="$1" drift="$2" owned bundle out ready continue status=0 removed=true
  owned="${TMP}/${name}-owned"
  bundle="${owned}/RelayKitApp.app"; out="${TMP}/${name}-out"; ready="${TMP}/${name}.ready"; continue="${TMP}/${name}.continue"
  make_owned_root "${owned}"
  HOME="${test_home}" SIGNAL_READY="${ready}" SIGNAL_CONTINUE="${continue}" \
  RELAYKIT_RC1_APP_BUNDLE="${bundle}" RELAYKIT_RC1_AX_INSPECT_OUT="${out}" \
  RELAYKIT_RC1_AX_INSPECT_OWNED_TEMP_ROOT="${owned}" RELAYKIT_RC1_AX_INSPECT_TEST=1 \
  RELAYKIT_RC1_AX_INSPECT_FAKE_DRIVER="${signal_driver}" RELAYKIT_RC1_CONFIG_REBASELINE_EVIDENCE="${test_rebaseline_evidence}" \
  RELAYKIT_RC1_CONFIG_REBASELINE_EVIDENCE_SHA256="${test_rebaseline_sha}" \
    "${SCRIPT}" --window-ax-inspect-repro >"${TMP}/${name}.stdout" 2>"${TMP}/${name}.stderr" &
  full_test_pid=$!; wait_for_full_test_marker "${ready}" || fail "${name} did not reach the controlled driver"
  if [[ "${drift}" == true ]]; then
    mv "${owned}/.relaykit-rc1-ax-inspect-owned" "${owned}.saved-marker"
    printf '%s\n' "${bundle}" >"${owned}/.relaykit-rc1-ax-inspect-owned"; chmod 600 "${owned}/.relaykit-rc1-ax-inspect-owned"; removed=false
  fi
  kill -TERM "${full_test_pid}"; : >"${continue}"; wait "${full_test_pid}" || status=$?; full_test_pid=""
  [[ "${status}" -eq 143 && ! -e "${out}/.run" ]] || fail "${name} did not preserve signal status/transient cleanup"
  [[ "${removed}" == true && ! -e "${owned}" || "${removed}" == false && -e "${owned}" ]] || fail "${name} owned deletion state changed"
  jq -e '.failure == "signal" and .exit_code == 143' "${out}/result.json" >/dev/null || fail "${name} result is invalid"
  jq -e --argjson removed "${removed}" '.owned_temp_cleanup_required == true and .owned_temp_app_removed == $removed and .probe_binary_removed == true' \
    "${out}/cleanup.json" >/dev/null || fail "${name} cleanup evidence is invalid"
}
run_owned_signal_case owned-signal false
run_owned_signal_case owned-signal-drift true

run_public_full_proof_setup_case public-full-proof-same false 0
run_public_full_proof_setup_case public-full-proof-rebaseline false 0 true
run_public_full_proof_setup_case public-full-proof-drift true 1
for rejected_mode in "PROVIDER_CONFIGURE""_ONLY" "provider_configure""_only" "provider-configure""-only"; do
  if grep -Fq "${rejected_mode}" "${SCRIPT}"; then
    fail "rejected provider configure-only mode is still present"
  fi
done
grep -Fq 'RELAYKIT_RC1_PROVIDER_PROTOCOL_PROBE_ONLY' "${SCRIPT}" ||
  fail "proof is missing the explicit provider protocol probe mode"
grep -Fq 'PROVIDER_FORM_MODEL="dogfood-native-responses"' "${SCRIPT}" ||
  fail "proof does not bind the provider form model id"
grep -Fq 'PROVIDER_PUBLIC_MODEL="custom/${PROVIDER_FORM_MODEL}"' "${SCRIPT}" ||
  fail "proof does not bind the saved public model id"
grep -Fq 'PROVIDER_UPSTREAM_MODEL="native-upstream"' "${SCRIPT}" ||
  fail "proof does not bind the upstream model id separately"
proof_upstream_model="$(sed -n 's/^PROVIDER_UPSTREAM_MODEL="\([^"]*\)"$/\1/p' "${SCRIPT}")"
fixture_upstream_model="$(sed -n 's/^UPSTREAM_MODEL = "\([^"]*\)"$/\1/p' "${FIXTURE}")"
[[ -n "${proof_upstream_model}" && -n "${fixture_upstream_model}" ]] ||
  fail "proof or fixture upstream model contract is missing"
[[ "${proof_upstream_model}" == "${fixture_upstream_model}" ]] ||
  fail "proof provider upstream model must match the fixture catalog model"
[[ "$(rg -c -- '--upstream-model-id "\$\{PROVIDER_UPSTREAM_MODEL\}"' "${SCRIPT}")" -eq 3 ]] ||
  fail "configure, protocol probe, and relaunch verify must bind the upstream model independently"
grep -Fq '.models[0].upstream_model == $upstream_model' "${SCRIPT}" ||
  fail "saved provider assertion does not verify the upstream model mapping"
probe_stop_body="$(sed -n '/if \[\[ "${RELAYKIT_RC1_PROVIDER_PROTOCOL_PROBE_ONLY/,/^fi$/p' "${SCRIPT}" | tail -n +2)"
[[ "$(rg -c 'relaykit-provider-protocol-probe --pid' <<<"${probe_stop_body}")" -eq 1 ]] ||
  fail "protocol probe boundary must invoke the new command exactly once"
grep -Fq 'ax-provider-protocol-probe.json' <<<"${probe_stop_body}" ||
  fail "protocol probe report is not preserved"
grep -Fq '.providers == []' <<<"${probe_stop_body}" ||
  fail "protocol probe does not prove the provider config remained empty"
grep -Fq 'KEYCHAIN_CREATED=false' <<<"${probe_stop_body}" ||
  fail "protocol probe does not keep Keychain ownership disarmed"
grep -Fq 'exit 0' <<<"${probe_stop_body}" || fail "protocol probe can continue into the ordinary chain"
if rg -q 'relaykit-provider-configure|provider-form-save|ax-provider-verify|gateway|desktop|scenario|manual|manifest|security|delete-dogfood-keychain|KEYCHAIN_CREATED=true' <<<"${probe_stop_body}"; then
  fail "protocol probe crossed a forbidden downstream boundary"
fi
grep -Fq 'RELAYKIT_RC1_PROVIDER_PROTOCOL_PROBE_ONLY:-0}' "${SCRIPT}" ||
  fail "cleanup does not explicitly disable Keychain deletion in probe mode"
printf '%s\n' 'synthetic config baseline' >"${test_home}/.codex/config.toml"
chmod 600 "${test_home}/.codex/config.toml"

drift_evidence="${TMP}/config-rebaseline-drift.json"
jq '.new_config_sha256 = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"' \
  "${test_rebaseline_evidence}" >"${drift_evidence}"
chmod 600 "${drift_evidence}"
drift_evidence_sha="$(/usr/bin/shasum -a 256 "${drift_evidence}" | awk '{print $1}')"
drift_root="${TMP}/drift-output"
drift_status=0
HOME="${test_home}" \
RELAYKIT_RC1_APP_BUNDLE="${fake_bundle}" \
RELAYKIT_RC1_AX_INSPECT_OUT="${drift_root}" \
RELAYKIT_RC1_AX_INSPECT_TEST=1 \
RELAYKIT_RC1_AX_INSPECT_FAKE_DRIVER="${fake_success_driver}" \
RELAYKIT_RC1_CONFIG_REBASELINE_EVIDENCE="${drift_evidence}" \
RELAYKIT_RC1_CONFIG_REBASELINE_EVIDENCE_SHA256="${drift_evidence_sha}" \
  "${SCRIPT}" --window-ax-inspect-repro >"${TMP}/drift.stdout" 2>"${TMP}/drift.stderr" || drift_status=$?
[[ "${drift_status}" -ne 0 ]] || fail "config baseline drift did not stop the future repro"
[[ ! -e "${drift_root}" ]] || fail "config baseline drift wrote a future run root"
rg -Fq 'global Codex config no longer matches the rebaseline evidence' "${TMP}/drift.stderr" ||
  fail "config baseline drift did not report the bounded stop reason"

grep -Fq 'if [[ "${RELAYKIT_RC1_AX_INSPECT_TEST:-0}" == "1" ]]' <<<"${ax_repro_body}" ||
  fail "fake AX driver is not protected by the explicit test gate"
grep -Fq 'driver_binary="${RELAYKIT_RC1_AX_INSPECT_FAKE_DRIVER}"' <<<"${ax_repro_body}" ||
  fail "test gate does not bind the explicit fake driver"
grep -Fq '/usr/bin/xcrun swiftc "${AX_SOURCE}" -o "${driver_binary}"' <<<"${ax_repro_body}" ||
  fail "production AX inspect stopped compiling the real driver"
trap_line="$(rg -n 'trap ax_inspect_exit_handler EXIT' <<<"${ax_repro_body}" | cut -d: -f1)"
compile_line="$(rg -n '/usr/bin/xcrun swiftc' <<<"${ax_repro_body}" | cut -d: -f1)"
metadata_line="$(rg -n 'run-metadata.json' <<<"${ax_repro_body}" | cut -d: -f1)"
launch_line="$(rg -n '^[[:space:]]+launch_ax_inspect_app \|\|' <<<"${ax_repro_body}" | cut -d: -f1)"
[[ "${trap_line}" -lt "${compile_line}" && "${compile_line}" -lt "${metadata_line}" && "${metadata_line}" -lt "${launch_line}" ]] ||
  fail "trap/compile/metadata/launch ordering changed"
[[ "$(rg -c '/usr/bin/open' <<<"${launch_body}")" -eq 1 ]] || fail "focused launch helper must invoke open exactly once"
! rg -q 'RELAYKIT_[A-Z0-9_]*FAKE_OPEN' "${SCRIPT}" || fail "production added a fake-open environment gate"
for signal_status in 130 143 129; do
  rg -Fq "ax_inspect_signal_handler ${signal_status}" "${SCRIPT}" ||
    fail "AX inspect finalizer is missing signal status ${signal_status}"
done

run_selected_case() {
  local name="$1"
  local pid="$2"
  local metadata="${TMP}/${name}-metadata.json"
  local identity="${TMP}/${name}-identity.json"
  local diagnostic="${TMP}/${name}-diagnostic.json"
  cat >"${metadata}"
  "${SCRIPT}" --select-window-identity "${pid}" "${identity}" "${diagnostic}" "${metadata}" ||
    fail "${name} selector unexpectedly failed"
  [[ "$(stat -f '%Lp' "${identity}")" == "600" ]] || fail "${name} identity permissions are not 0600"
  [[ "$(stat -f '%Lp' "${diagnostic}")" == "600" ]] || fail "${name} diagnostic permissions are not 0600"
  jq -e '
    (keys | sort) == ["captured_at","height","pid","width","window_id"] and
    (.captured_at | type == "string" and length > 0)
  ' "${identity}" >/dev/null || fail "${name} identity schema is invalid"
  jq -e '
    (keys | sort) == ["candidates","captured_at","eligible_count","largest_candidate_count","owner_window_count","pid","selected_window_id","status"] and
    .status == "selected" and
    (.selected_window_id | type == "number") and
    (.candidates | all(.[];
      (keys | sort) == ["area","eligible","height","layer","width","window_id"]))
  ' "${diagnostic}" >/dev/null || fail "${name} selected diagnostic schema is invalid"
}

run_failed_case() {
  local name="$1"
  local pid="$2"
  local expected_status="$3"
  local metadata="${TMP}/${name}-metadata.json"
  local identity="${TMP}/${name}-identity.json"
  local diagnostic="${TMP}/${name}-diagnostic.json"
  cat >"${metadata}"
  printf '%s\n' stale >"${identity}"
  if "${SCRIPT}" --select-window-identity "${pid}" "${identity}" "${diagnostic}" "${metadata}"; then
    fail "${name} selector unexpectedly succeeded"
  fi
  [[ ! -e "${identity}" ]] || fail "${name} failure left an identity file"
  [[ "$(stat -f '%Lp' "${diagnostic}")" == "600" ]] || fail "${name} diagnostic permissions are not 0600"
  jq -e --arg status "${expected_status}" '
    (keys | sort) == ["candidates","captured_at","eligible_count","largest_candidate_count","owner_window_count","pid","status"] and
    .status == $status and
    (has("selected_window_id") | not) and
    (.candidates | all(.[];
      (keys | sort) == ["area","eligible","height","layer","width","window_id"]))
  ' "${diagnostic}" >/dev/null || fail "${name} failure diagnostic schema is invalid"
}

run_selected_case nonzero-layer 4101 <<'JSON'
{
  "app_valid": true,
  "windows": [
    {"owner_pid":4101,"window_id":101,"layer":7,"width":640,"height":480,"bounds_valid":true}
  ]
}
JSON
jq -e '
  .pid == 4101 and .window_id == 101 and .width == 640 and .height == 480
' "${TMP}/nonzero-layer-identity.json" >/dev/null || fail "nonzero-layer window was not selected"
jq -e '
  .pid == 4101 and .owner_window_count == 1 and .eligible_count == 1 and
  .largest_candidate_count == 1 and .selected_window_id == 101 and
  .candidates == [{"window_id":101,"layer":7,"width":640,"height":480,"area":307200,"eligible":true}]
' "${TMP}/nonzero-layer-diagnostic.json" >/dev/null || fail "nonzero-layer diagnostic is incorrect"

run_failed_case unique-largest 4102 eligible_window_not_unique <<'JSON'
{
  "app_valid": true,
  "windows": [
    {"owner_pid":4102,"window_id":201,"layer":0,"width":400,"height":400,"bounds_valid":true},
    {"owner_pid":4102,"window_id":202,"layer":3,"width":800,"height":500,"bounds_valid":true}
  ]
}
JSON
jq -e '
  .owner_window_count == 2 and .eligible_count == 2 and .largest_candidate_count == 1 and
  ([.candidates[] | [.window_id,.width,.height,.area,.eligible]] ==
    [[201,400,400,160000,true],[202,800,500,400000,true]])
' "${TMP}/unique-largest-diagnostic.json" >/dev/null || fail "multiple eligible windows did not fail closed"

run_selected_case foreign-larger 4103 <<'JSON'
{
  "app_valid": true,
  "windows": [
    {"owner_pid":9999,"window_id":301,"layer":0,"width":1400,"height":1000,"bounds_valid":true},
    {"owner_pid":4103,"window_id":302,"layer":5,"width":500,"height":500,"bounds_valid":true}
  ]
}
JSON
jq -e '
  .selected_window_id == 302 and .owner_window_count == 1 and .eligible_count == 1 and
  .largest_candidate_count == 1 and (.candidates | map(.window_id)) == [302]
' "${TMP}/foreign-larger-diagnostic.json" >/dev/null || fail "foreign larger window affected exact-PID selection"

run_failed_case none-eligible 4104 no_eligible_window <<'JSON'
{
  "app_valid": true,
  "windows": [
    {"owner_pid":4104,"window_id":401,"layer":2,"width":399,"height":900,"bounds_valid":true},
    {"owner_pid":4104,"window_id":402,"layer":4,"width":800,"height":399,"bounds_valid":true}
  ]
}
JSON
jq -e '
  .pid == 4104 and .owner_window_count == 2 and .eligible_count == 0 and
  .largest_candidate_count == 0 and
  ([.candidates[] | [.window_id,.width,.height,.eligible]] ==
    [[401,399,900,false],[402,800,399,false]])
' "${TMP}/none-eligible-diagnostic.json" >/dev/null || fail "no-eligible diagnostic counts or dimensions are incorrect"

run_failed_case tied-largest 4105 eligible_window_not_unique <<'JSON'
{
  "app_valid": true,
  "windows": [
    {"owner_pid":4105,"window_id":501,"layer":1,"width":600,"height":500,"bounds_valid":true},
    {"owner_pid":4105,"window_id":502,"layer":9,"width":500,"height":600,"bounds_valid":true}
  ]
}
JSON
jq -e '
  .pid == 4105 and .owner_window_count == 2 and .eligible_count == 2 and
  .largest_candidate_count == 2 and
  ([.candidates[] | [.window_id,.area,.eligible]] == [[501,300000,true],[502,300000,true]])
' "${TMP}/tied-largest-diagnostic.json" >/dev/null || fail "ambiguous-largest diagnostic is incorrect"

run_failed_case app-invalid 4106 app_invalid <<'JSON'
{
  "app_valid": false,
  "windows": [
    {"owner_pid":4106,"window_id":601,"layer":0,"width":900,"height":700,"bounds_valid":true}
  ]
}
JSON
jq -e '
  .pid == 4106 and .owner_window_count == 0 and .eligible_count == 0 and
  .largest_candidate_count == 0 and .candidates == []
' "${TMP}/app-invalid-diagnostic.json" >/dev/null || fail "app-invalid diagnostic is incorrect"

if rg -n 'kCGWindowLayer[^\n]*==[[:space:]]*0|candidates\.count[[:space:]]*==[[:space:]]*1' "${SCRIPT}" >/dev/null; then
  fail "legacy layer-zero or single-candidate selector remains"
fi

for counter in ax_windows_count window_server_surface_count ax_popover_count semantic_identifier_count; do
  count="$(rg -Foc ".${counter} | nonnegative_integer" "${SCRIPT}" || true)"
  [[ "${count}" -ge 2 ]] || fail "${counter} is not type-checked in report and tree evidence"
done

contract="$(${SCRIPT} --print-contract)"
jq -e '
  .proof == "rc1_native_responses_chain" and
  .app_first == true and
  .ordinary_extracted_app == true and
  .provider_destination_initially_empty == true and
  .provider_created_through_exact_ax == true and
  .provider_protocol == "openai_responses" and
  .credential_storage == "keychain_reference_only" and
  .relaunch_restoration_required == true and
  .gateway_started_through_ui == true and
  .desktop_profile == "rc1_native_responses_three_stage" and
  .desktop_stage_count == 3 and
  .desktop_websocket_to_gateway_required == true and
  .gateway_sse_to_fixture_required == true and
  .shared_18787_mutation == false and
  .global_codex_mutation == false and
  .launch_agent_mutation == false and
  .real_provider_request == false and
  .evidence_contains_request_or_response_body == false
' <<<"${contract}" >/dev/null || fail "public proof contract is invalid"

grep -Fq '"providers": []' "${SCRIPT}" || fail "proof must begin from an empty isolated provider destination"
grep -Fq 'relaykit-provider-configure' "${SCRIPT}" || fail "proof must create the provider through the exact AX driver"
grep -Fq 'relaykit-provider-verify' "${SCRIPT}" || fail "proof must verify restored UI values after relaunch"
grep -Fq 'relaykit-gateway-start' "${SCRIPT}" || fail "proof must start the App-owned gateway through exact AX"
grep -Fq 'rc1-native-responses-three-stage' "${SCRIPT}" || fail "proof must delegate Desktop traffic to the dedicated three-stage harness"
grep -Fq 'rc1-native-responses-proof-fixture.py' "${SCRIPT}" || fail "proof must use the standalone fixture"
grep -Fq 'rc1-native-responses-manifest.sh' "${SCRIPT}" || fail "proof must derive phase-b from the dedicated manifest"
grep -Fq 'predicate_ledger' "${SCRIPT}" || fail "proof evidence must expose named predicates"
grep -Fq 'failed_events' "${SCRIPT}" || fail "proof evidence must expose failed events"
grep -Fq 'manual_status == "route_complete"' "${SCRIPT}" || fail "proof must require a successful manual status"
grep -Fq 'route_proof_status == "complete"' "${SCRIPT}" || fail "proof must require a complete route status"
grep -Fq 'harness_exit_code == 0' "${SCRIPT}" || fail "proof must require a zero harness exit"

native_manifest_body="$(sed -n '/native_evidence="${OUT}\/native-app-evidence.json"/,/phase-b manifest did not derive PASS/p' "${SCRIPT}")"
if rg -q '[A-Za-z0-9_]+:[[:space:]]*true' <<<"${native_manifest_body}"; then
  fail "native/manifest closeout still contains a hand-written true ledger"
fi
for required_input in \
  '--stage-ledger "${stage_ledger}"' \
  '--tool-evidence "${tool_evidence}"' \
  '--screenshot-ledger "${all_screenshot_ledger}"' \
  '--protocol-evidence "${PROTOCOL_EVIDENCE}"' \
  '--guard-evidence "${OUT}/cleanup-runtime-guard.json"' \
  '--extracted-app "${APP_BUNDLE}"'; do
  grep -Fq -- "${required_input}" <<<"${native_manifest_body}" ||
    fail "manifest invocation is missing ${required_input}"
done
grep -Fq 'run_protocol_validation' "${SCRIPT}" ||
  fail "proof does not generate fresh protocol validation evidence"
if grep -Fq 'RELAYKIT_RC1_PROTOCOL_VALIDATION_EVIDENCE' "${SCRIPT}"; then
  fail "proof still accepts externally supplied protocol validation evidence"
fi
for protocol_contract_text in \
  'producer:"rc1-native-responses-proof"' \
  'gateway/internal/server/server.go' \
  'gateway/internal/server/openai_responses.go' \
  'gateway/internal/server/server_test.go' \
  'gateway/internal/server/provider_test.go'; do
  grep -Fq "${protocol_contract_text}" "${SCRIPT}" ||
    fail "fresh protocol evidence is missing ${protocol_contract_text}"
done

cleanup_guard_line="$(rg -n '^write_cleanup_runtime_guard "\$\{global_config_before\}"' "${SCRIPT}" | tail -1 | cut -d: -f1)"
manifest_call_line="$(rg -n '^"\$\{MANIFEST\}" \\' "${SCRIPT}" | tail -1 | cut -d: -f1)"
[[ -n "${cleanup_guard_line}" && -n "${manifest_call_line}" && "${cleanup_guard_line}" -lt "${manifest_call_line}" ]] ||
  fail "manifest command is not after cleanup/runtime/git guard generation"
cleanup_guard_body="$(sed -n '/^write_cleanup_runtime_guard()/,/^}/p' "${SCRIPT}")"
for cleanup_guard_text in \
  'stop_app' 'kill -TERM "${helper_pid}"' 'kill -TERM "${fixture_pid}"' \
  '--delete-dogfood-keychain "${KEYCHAIN_SERVICE}"' 'sha256 "${HOME}/.codex/config.toml"' \
  'sha256 "${HOME}/.codex/auth.json"' 'listener_snapshot 18787' 'listener_snapshot 19777' \
  'listener_snapshot "${FIXTURE_PORT}"' 'status --porcelain=v1 --untracked-files=no'; do
  grep -Fq -- "${cleanup_guard_text}" <<<"${cleanup_guard_body}" ||
    fail "cleanup guard is missing ${cleanup_guard_text}"
done

for ui_contract_text in \
  'relaykit-ui-evidence --pid "${APP_PID}" --window-identity "${identity_path}" --stage "${stage}"' \
  'capture_ordinary_ui_appearance light' \
  'capture_ordinary_ui_appearance dark' \
  'capture_bound_popover "${official_identity}"' \
  'capture_bound_popover "${provider_identity}"' \
  'jq -s '\''.[0] + .[1]'\'' "${screenshot_ledger}" "${OUT}/ordinary-ui-screenshots.json"' \
  '--screenshot-ledger "${all_screenshot_ledger}"'; do
  grep -Fq -- "${ui_contract_text}" "${SCRIPT}" ||
    fail "ordinary transient UI evidence contract is missing ${ui_contract_text}"
done
ui_capture_body="$(sed -n '/^capture_bound_popover()/,/^}/p' "${SCRIPT}")"
grep -Fq '/usr/sbin/screencapture -x -l "${window_id}"' <<<"${ui_capture_body}" ||
  fail "ordinary UI screenshots are not cropped to the exact bound WindowServer surface"
! grep -Eq 'screencapture.*(-R|OCR|title)' <<<"${ui_capture_body}" ||
  fail "ordinary UI screenshots added a forbidden coordinate, OCR, or title fallback"

if rg -n 'credential_ref[^\n]*key_file|kind[^\n]*key_file|credential_file=' "${SCRIPT}" >/dev/null; then
  fail "proof must not inject a key-file credential"
fi
if rg -n -- '--ui-smoke-provider-config[^\n]*(provider_config|providers\.json)' "${SCRIPT}" >/dev/null &&
   rg -n 'jq -n.*providers:\[\{' "${SCRIPT}" >/dev/null; then
  fail "proof must not inject a completed provider object"
fi
if rg -n 'curl .*19777/v1/responses|curl .*--data.*v1/responses' "${SCRIPT}" >/dev/null; then
  fail "curl-only traffic must not be accepted as the Desktop chain proof"
fi
if rg -n 'stale|observation_failed' "${SCRIPT}" | rg -n 'passed|verified|relabel' >/dev/null; then
  fail "proof must not relabel stale or failed evidence"
fi
if rg -n 'python3 - .*<<' "${SCRIPT}" >/dev/null; then
  fail "the loopback provider fixture must not remain embedded in the shell harness"
fi

grep -Fq 'rc1-native-responses-three-stage)' "${MANUAL_PROOF}" ||
  fail "manual proof is missing the dedicated three-stage entry"

printf '%s\n' 'RelayKit RC1 native Responses proof contract tests passed'
