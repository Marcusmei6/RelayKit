#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${ROOT}/scripts/rc1-native-responses-proof.sh"
FIXTURE="${ROOT}/scripts/rc1-native-responses-proof-fixture.py"
MANUAL_PROOF="${ROOT}/scripts/codex-desktop-manual-proof.sh"
MANIFEST="${ROOT}/scripts/rc1-native-responses-manifest.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/relaykit-window-selector-test.XXXXXX")"
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
  'find_exact_app_pid' \
  'open_exact_app_popover' \
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

fake_failure_driver="${TMP}/fake-ax-driver-failure"
cat >"${fake_failure_driver}" <<'SH'
#!/usr/bin/env bash
printf '%s\n' '{"candidate_count":0,"code":"window_selector_not_unique","command":"relaykit-ax-inspect","status":"error"}'
exit 4
SH
chmod 700 "${fake_failure_driver}"

fake_success_driver="${TMP}/fake-ax-driver-success"
cat >"${fake_success_driver}" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
diagnostic_output=""
while [[ "$#" -gt 0 ]]; do
  if [[ "$1" == "--diagnostic-output" ]]; then
    diagnostic_output="$2"
    break
  fi
  shift
done
[[ -n "${diagnostic_output}" ]]
jq -n '{
  status:"ok",ax_windows_available:true,ax_windows_count:1,
  numbered_window_count:1,matching_window_count:0,truncated:false,
  nodes:[{ordinal:0,parent:null,depth:0,role:"AXApplication",subrole:null,
    child_count:0,window_number_present:false,matches_expected_window:false}],
  role_counts:[{role:"AXApplication",count:1}],depth_counts:[{depth:0,count:1}]
}' >"${diagnostic_output}"
chmod 600 "${diagnostic_output}"
printf '%s\n' '{"action_count":0,"code":"ok","command":"relaykit-ax-inspect","status":"ok","window_verified":true}'
SH
chmod 700 "${fake_success_driver}"

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
  local exact_out="${TMP}/${name}-output"
  local stdout="${TMP}/${name}.stdout"
  local stderr="${TMP}/${name}.stderr"
  local status=0

  env -u RELAYKIT_RC1_CONFIG_REBASELINE_EVIDENCE \
    -u RELAYKIT_RC1_CONFIG_REBASELINE_EVIDENCE_SHA256 \
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
  [[ -d "${exact_out}/run" && -d "${exact_out}/desktop-root" ]] ||
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
  local exact_parent="${TMP}/${name}-parent"
  local exact_root="${exact_parent}/inspect-output"
  local stdout="${TMP}/${name}.stdout"
  local stderr="${TMP}/${name}.stderr"
  local status=0
  mkdir -p "${exact_parent}"

  HOME="${test_home}" \
  RELAYKIT_RC1_APP_BUNDLE="${fake_bundle}" \
  RELAYKIT_RC1_AX_INSPECT_OUT="${exact_root}" \
  RELAYKIT_RC1_AX_INSPECT_TEST=1 \
  RELAYKIT_RC1_AX_INSPECT_FAKE_DRIVER="${fake_driver}" \
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

  for artifact in \
    run-metadata.json window-identity.json window-diagnostic.json ax-driver-report.json \
    cleanup.json result.json evidence-manifest.json; do
    assert_private_json "${exact_root}/${artifact}"
  done
  jq -e '
    (keys | sort) == ["captured_at","height","pid","width","window_id"] and
    .pid == 4242 and .window_id == 101
  ' "${exact_root}/window-identity.json" >/dev/null || fail "${name} stable identity schema is invalid"
  jq -e '
    (keys | sort) == ["candidates","captured_at","eligible_count","largest_candidate_count",
      "owner_window_count","pid","selected_window_id","status"] and
    .status == "selected" and .pid == 4242 and .selected_window_id == 101 and
    (.candidates | all(.[]; (keys | sort) == ["area","eligible","height","layer","width","window_id"]))
  ' "${exact_root}/window-diagnostic.json" >/dev/null || fail "${name} stable window diagnostic schema is invalid"
  if [[ "${expected_tree}" == "created" ]]; then
    assert_private_json "${exact_root}/ax-tree.json"
  else
    [[ ! -e "${exact_root}/ax-tree.json" ]] || fail "${name} wrote an empty failure tree"
  fi

  jq -e \
    --arg root "${exact_root}" \
    --arg evidence_path "${test_rebaseline_evidence}" \
    --arg evidence_hash "${test_rebaseline_sha}" '
    (keys | sort) == ["app_binary_sha256","ax_driver_source_sha256",
      "config_rebaseline_evidence_path","config_rebaseline_evidence_sha256",
      "inspect_out","mode","schema_version"] and
    .schema_version == 1 and .mode == "window_ax_inspect_repro" and .inspect_out == $root and
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
    --argjson transient_removed "${expected_transient_removed}" '
    (keys | sort) == ["app_launched","app_stop_attempted","app_stopped","global_auth_unchanged",
      "global_config_unchanged","port_19777_unchanged","schema_version","shared_18787_unchanged","transient_removed"] and
    .schema_version == 1 and .app_launched == false and .app_stop_attempted == false and
    .app_stopped == $app_stopped and .global_auth_unchanged == $auth_unchanged and
    .global_config_unchanged == $config_unchanged and
    .port_19777_unchanged == $port_19777_unchanged and
    .shared_18787_unchanged == $shared_18787_unchanged and
    .transient_removed == $transient_removed
  ' "${exact_root}/cleanup.json" >/dev/null || fail "${name} cleanup schema is invalid"
  jq -e --arg status "${expected_status}" --arg tree "${expected_tree}" --argjson exit_code "${expected_exit}" '
    (keys | sort) == ["ax_tree","driver_candidate_count","driver_code","driver_command","driver_status",
      "exit_code","failure","schema_version","status"] and
    .schema_version == 1 and .status == $status and .exit_code == $exit_code and .ax_tree == $tree and
    .driver_command == "relaykit-ax-inspect"
  ' "${exact_root}/result.json" >/dev/null || fail "${name} result schema is invalid"
  jq -e --arg root "${exact_root}" '
    (keys | sort) == ["artifacts","inspect_out","schema_version"] and
    .schema_version == 1 and .inspect_out == $root and
    ([.artifacts[].name] == ["run_metadata","window_identity","window_diagnostic","driver_report","ax_tree","cleanup","result"]) and
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
  .code == "window_selector_not_unique" and .candidate_count == 0
' "${last_finalizer_root}/ax-driver-report.json" >/dev/null || fail "failure driver report was not preserved exactly"
jq -e '
  .failure == "driver_failed" and .driver_status == "error" and
  .driver_code == "window_selector_not_unique" and .driver_candidate_count == 0
' "${last_finalizer_root}/result.json" >/dev/null || fail "failure result lost the driver error"
jq -e '.artifacts[] | select(.name == "ax_tree") | .status == "not_created" and .sha256 == null' \
  "${last_finalizer_root}/evidence-manifest.json" >/dev/null || fail "absent failure tree was not recorded as not_created"

run_ax_finalizer_case success-finalizer "${fake_success_driver}" 0 passed created
jq -e '.status == "ok" and .code == "ok" and .command == "relaykit-ax-inspect"' \
  "${last_finalizer_root}/ax-driver-report.json" >/dev/null || fail "success driver report was not preserved exactly"
jq -e '
  .failure == "none" and .driver_status == "ok" and .driver_code == "ok" and
  .driver_candidate_count == null
' "${last_finalizer_root}/result.json" >/dev/null || fail "success result is invalid"

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

run_public_full_proof_setup_case public-full-proof-same false 0
run_public_full_proof_setup_case public-full-proof-drift true 1
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

run_selected_case unique-largest 4102 <<'JSON'
{
  "app_valid": true,
  "windows": [
    {"owner_pid":4102,"window_id":201,"layer":0,"width":400,"height":400,"bounds_valid":true},
    {"owner_pid":4102,"window_id":202,"layer":3,"width":800,"height":500,"bounds_valid":true}
  ]
}
JSON
jq -e '
  .window_id == 202 and .width == 800 and .height == 500
' "${TMP}/unique-largest-identity.json" >/dev/null || fail "unique largest window was not selected"
jq -e '
  .owner_window_count == 2 and .eligible_count == 2 and .largest_candidate_count == 1 and
  .selected_window_id == 202 and
  ([.candidates[] | [.window_id,.width,.height,.area,.eligible]] ==
    [[201,400,400,160000,true],[202,800,500,400000,true]])
' "${TMP}/unique-largest-diagnostic.json" >/dev/null || fail "unique-largest diagnostic counts or dimensions are incorrect"

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

run_failed_case tied-largest 4105 ambiguous_largest_window <<'JSON'
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
