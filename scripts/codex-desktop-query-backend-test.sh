#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNNER="${ROOT}/.agents/skills/relaykit-desktop-query/scripts/run-query.sh"
BACKEND="${ROOT}/scripts/codex-desktop-query-backend.sh"
OFFICIAL_LIFECYCLE="${ROOT}/scripts/codex-desktop-query-official-once.sh"

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

[[ -x "${BACKEND}" ]] || fail "default desktop-query backend is missing"
[[ -x "${OFFICIAL_LIFECYCLE}" ]] || fail "targeted official lifecycle is missing"
if rg -Fq 'run_automated_proof' "${OFFICIAL_LIFECYCLE}" ||
   rg -Fq 'prepare_automated_provider_inputs' "${OFFICIAL_LIFECYCLE}" ||
   rg -Fq 'prepare_real_provider_config' "${OFFICIAL_LIFECYCLE}" ||
   rg -Fq 'RELAYKIT_DESKTOP_PROOF_REAL_PROVIDER_CONFIG' "${OFFICIAL_LIFECYCLE}"; then
  fail "targeted official lifecycle still depends on full provider proof setup"
fi
rg -Fq 'source "${HARNESS}" --help' "${OFFICIAL_LIFECYCLE}" ||
  fail "targeted official lifecycle does not load the established fail-closed helpers"
rg -Fq 'providers: []' "${OFFICIAL_LIFECYCLE}" ||
  fail "targeted official lifecycle does not generate an official-only gateway config"
rg -Fq 'assert_global_state_unchanged' "${OFFICIAL_LIFECYCLE}" ||
  fail "targeted official lifecycle does not guard global Codex state"
rg -Fq 'restore_isolated_config' "${OFFICIAL_LIFECYCLE}" ||
  fail "targeted official lifecycle does not restore isolated config"
rg -Fq "printf '19777\\n' >\"\${PORT_FILE}\"" "${OFFICIAL_LIFECYCLE}" ||
  fail "targeted official lifecycle does not bind cleanup to its owned gateway port"
if rg -Fq 'package_release.sh' "${OFFICIAL_LIFECYCLE}"; then
  fail "targeted official lifecycle may not rebuild or package"
fi

tmp="$(mktemp -d "${TMPDIR:-/tmp}/relaykit-desktop-query-backend-test.XXXXXX")"
trap 'rm -rf "${tmp}"' EXIT
query_file="${tmp}/query.txt"
catalog_evidence="${tmp}/app-server.json"
artifact="${tmp}/artifact.zip"
fake_harness="${tmp}/fake-harness.sh"
fake_official_lifecycle="${tmp}/fake-official-lifecycle.sh"
capture_file="${tmp}/capture.json"

printf '%s\n' 'Summarize RelayKit in one sentence.' >"${query_file}"
chmod 600 "${query_file}"

printf '%s\n' 'artifact fixture' >"${artifact}"
artifact_sha="$(shasum -a 256 "${artifact}" | awk '{print $1}')"
jq -n --arg artifact_sha256 "${artifact_sha}" '{
  relaykit_lineage: {setup_id:"current-setup",session_id:"current-session",artifact_sha256:$artifact_sha256},
  official: [{model:"gpt-5.5",displayName:"GPT-5.5"}],
  provider: [{model:"public/provider-model",displayName:"Public Provider Model"}]
}' >"${catalog_evidence}"
chmod 600 "${catalog_evidence}"
catalog_sha="$(shasum -a 256 "${catalog_evidence}" | awk '{print $1}')"

cat >"${fake_harness}" <<'HARNESS'
#!/usr/bin/env bash
set -euo pipefail
[[ "${1:-}" == "run-auto" && "${2:-}" == "--scenario" && -f "${3:-}" ]]
[[ -z "${RELAYKIT_DESKTOP_PROOF_REAL_PROVIDER_CONFIG:-}" ]]
scenario="$3"
[[ "$(stat -f '%Lp' "${scenario}")" == "600" ]]
query="$(jq -er '.stages[0].query_file' "${scenario}")"
marker="$(jq -er '.stages[0].response_marker' "${scenario}")"
[[ -f "${query}" && "$(stat -f '%Lp' "${query}")" == "600" ]]
grep -Fq 'Summarize RelayKit in one sentence.' "${query}"
grep -Fq "${marker}" "${query}"
jq -e '
  .version == 1 and
  (.stages | length) == 1 and
  .stages[0].model_id == "gpt-5.5" and
  .stages[0].model_label == "GPT-5.5" and
  .stages[0].expect == "markdown"
' "${scenario}" >/dev/null
printf '%s\n' 'fake-harness: Terminated: 15 sandbox-exec cleanup' >&2
jq -n --arg marker "${marker}" '{status:"complete",profile:"custom_scenario",evidence:"/tmp/redacted-evidence.json",human_intervention_count:0,stages:[{submission_state:"submitted"}],marker:$marker}' | tee "${RELAYKIT_DESKTOP_QUERY_TEST_CAPTURE}"
HARNESS
chmod 700 "${fake_harness}"

cat >"${fake_official_lifecycle}" <<'LIFECYCLE'
#!/usr/bin/env bash
set -euo pipefail
[[ "${1:-}" == "--model" && "${2:-}" == "gpt-5.5" ]]
[[ "${3:-}" == "--query-file" && -f "${4:-}" && "$(stat -f '%Lp' "${4}")" == "600" ]]
[[ "${5:-}" == "--expect" && "${6:-}" == "markdown" ]]
[[ "${7:-}" == "--catalog-evidence" && -f "${8:-}" ]]
[[ "${9:-}" == "--catalog-sha256" && "${10:-}" =~ ^[0-9a-f]{64}$ ]]
[[ "${11:-}" == "--artifact-sha256" && "${12:-}" =~ ^[0-9a-f]{64}$ ]]
jq -n '{status:"complete",submission_state:"submitted",evidence:"/tmp/redacted-official-evidence.json"}'
LIFECYCLE
chmod 700 "${fake_official_lifecycle}"

RELAYKIT_DESKTOP_QUERY_HARNESS="${fake_harness}" \
RELAYKIT_DESKTOP_QUERY_OFFICIAL_LIFECYCLE="${fake_official_lifecycle}" \
RELAYKIT_DESKTOP_QUERY_CATALOG_EVIDENCE="${catalog_evidence}" \
RELAYKIT_DESKTOP_QUERY_TEST_CAPTURE="${capture_file}" \
RELAYKIT_DESKTOP_QUERY_ARTIFACT_PATH="${artifact}" \
  "${RUNNER}" \
    --model 'gpt-5.5' \
    --query-file "${query_file}" \
    --expect markdown \
    --catalog-evidence "${catalog_evidence}" \
    --catalog-sha256 "${catalog_sha}" \
    --catalog-setup-id current-setup \
    --catalog-session-id current-session \
    --artifact-sha256 "${artifact_sha}" >"${tmp}/result.json" 2>"${tmp}/stderr.txt"

jq -e \
  --arg catalog_sha "${catalog_sha}" \
  --arg artifact_sha "${artifact_sha}" \
  '.status == "complete" and .model == "gpt-5.5" and .expect == "markdown" and .submission_state == "submitted" and .evidence_path == "/tmp/redacted-official-evidence.json" and .catalog_sha256 == $catalog_sha and .artifact_sha256 == $artifact_sha and (keys | sort) == ["artifact_sha256","catalog_sha256","evidence_path","expect","model","status","submission_state"]' \
  "${tmp}/result.json" >/dev/null ||
  fail "default backend did not complete the targeted official lifecycle contract"
[[ ! -s "${capture_file}" ]] ||
  fail "official query invoked the full harness instead of the targeted lifecycle"
[[ ! -s "${tmp}/stderr.txt" ]] ||
  fail "successful backend leaked harness cleanup noise"

status_failed_lifecycle="${tmp}/status-failed-lifecycle.sh"
cat >"${status_failed_lifecycle}" <<'LIFECYCLE'
#!/usr/bin/env bash
set -euo pipefail
jq -nc '{status:"failed",error_code:"synthetic_failed_status",submission_state:"not_submitted",evidence:"/tmp/failed-status-evidence.json"}'
LIFECYCLE
chmod 700 "${status_failed_lifecycle}"
status_failed_exit=0
RELAYKIT_DESKTOP_QUERY_HARNESS="${fake_harness}" \
RELAYKIT_DESKTOP_QUERY_OFFICIAL_LIFECYCLE="${status_failed_lifecycle}" \
RELAYKIT_DESKTOP_QUERY_ARTIFACT_PATH="${artifact}" \
  "${RUNNER}" --model 'gpt-5.5' --query-file "${query_file}" --expect plain --catalog-evidence "${catalog_evidence}" --catalog-sha256 "${catalog_sha}" --catalog-setup-id current-setup --catalog-session-id current-session --artifact-sha256 "${artifact_sha}" \
  >"${tmp}/status-failed.stdout" 2>"${tmp}/status-failed.json" || status_failed_exit=$?
[[ "${status_failed_exit}" -ne 0 && ! -s "${tmp}/status-failed.stdout" ]] ||
  fail "exit-zero harness result with failed status was accepted"
jq -e -s 'length == 1 and .[0].status == "failed" and .[0].error_code == "synthetic_failed_status"' "${tmp}/status-failed.json" >/dev/null ||
  fail "exit-zero failed harness status was not returned as one redacted failure"

noisy_success_lifecycle="${tmp}/noisy-success-lifecycle.sh"
cat >"${noisy_success_lifecycle}" <<'LIFECYCLE'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' 'private successful harness diagnostic must not escape' >&2
jq -nc '{status:"complete",submission_state:"submitted",evidence:"/tmp/noisy-success-evidence.json"}'
LIFECYCLE
chmod 700 "${noisy_success_lifecycle}"
RELAYKIT_DESKTOP_QUERY_HARNESS="${fake_harness}" \
RELAYKIT_DESKTOP_QUERY_OFFICIAL_LIFECYCLE="${noisy_success_lifecycle}" \
RELAYKIT_DESKTOP_QUERY_ARTIFACT_PATH="${artifact}" \
  "${RUNNER}" --model 'gpt-5.5' --query-file "${query_file}" --expect plain --catalog-evidence "${catalog_evidence}" --catalog-sha256 "${catalog_sha}" --catalog-setup-id current-setup --catalog-session-id current-session --artifact-sha256 "${artifact_sha}" \
  >"${tmp}/noisy-success.json" 2>"${tmp}/noisy-success.stderr"
jq -e '.status == "complete" and .evidence_path == "/tmp/noisy-success-evidence.json"' "${tmp}/noisy-success.json" >/dev/null ||
  fail "successful structured harness result was not preserved"
[[ ! -s "${tmp}/noisy-success.stderr" ]] ||
  fail "successful backend leaked non-structured harness stderr"

if RELAYKIT_DESKTOP_QUERY_HARNESS="${fake_harness}" \
  RELAYKIT_DESKTOP_QUERY_CATALOG_EVIDENCE="${catalog_evidence}" \
  RELAYKIT_DESKTOP_QUERY_TEST_CAPTURE="${capture_file}" \
  RELAYKIT_DESKTOP_QUERY_ARTIFACT_PATH="${artifact}" \
  "${RUNNER}" --model 'missing-model' --query-file "${query_file}" --expect plain --catalog-evidence "${catalog_evidence}" --catalog-sha256 "${catalog_sha}" --catalog-setup-id current-setup --catalog-session-id current-session --artifact-sha256 "${artifact_sha}" >/dev/null 2>&1; then
  fail "default backend accepted an unknown model"
fi

failing_official_lifecycle="${tmp}/failing-official-lifecycle.sh"
cat >"${failing_official_lifecycle}" <<'LIFECYCLE'
#!/usr/bin/env bash
set -euo pipefail
jq -nc '{status:"failed",error_code:"official_login_required",submission_state:"not_submitted",evidence:"/tmp/official-pre-submit-evidence.json"}' >&2
exit 1
LIFECYCLE
chmod 700 "${failing_official_lifecycle}"

official_failure_status=0
RELAYKIT_DESKTOP_QUERY_HARNESS="${fake_harness}" \
RELAYKIT_DESKTOP_QUERY_OFFICIAL_LIFECYCLE="${failing_official_lifecycle}" \
RELAYKIT_DESKTOP_QUERY_ARTIFACT_PATH="${artifact}" \
  "${RUNNER}" --model 'gpt-5.5' --query-file "${query_file}" --expect plain --catalog-evidence "${catalog_evidence}" --catalog-sha256 "${catalog_sha}" --catalog-setup-id current-setup --catalog-session-id current-session --artifact-sha256 "${artifact_sha}" \
  >"${tmp}/official-failure.stdout" 2>"${tmp}/official-failure.json" || official_failure_status=$?
[[ "${official_failure_status}" -ne 0 && ! -s "${tmp}/official-failure.stdout" ]] ||
  fail "failed targeted official lifecycle returned success output"
jq -e -s '
  length == 1 and
  .[0].status == "failed" and
  .[0].error_code == "official_login_required" and
  .[0].submission_state == "not_submitted" and
  .[0].evidence_path == "/tmp/official-pre-submit-evidence.json"
' "${tmp}/official-failure.json" >/dev/null ||
  fail "targeted official lifecycle failure lost its pre-submit state"

if RELAYKIT_DESKTOP_QUERY_HARNESS="${fake_harness}" \
  RELAYKIT_DESKTOP_QUERY_ARTIFACT_PATH="${artifact}" \
  "${RUNNER}" --model 'gpt-5.5' --query-file "${query_file}" --expect plain --catalog-evidence "${catalog_evidence}" --catalog-sha256 deadbeef --catalog-setup-id current-setup --catalog-session-id current-session --artifact-sha256 "${artifact_sha}" >/dev/null 2>&1; then
  fail "default backend accepted a stale catalog hash"
fi

if RELAYKIT_DESKTOP_QUERY_HARNESS="${fake_harness}" \
  RELAYKIT_DESKTOP_QUERY_ARTIFACT_PATH="${artifact}" \
  "${RUNNER}" --model 'gpt-5.5' --query-file "${query_file}" --expect plain >/dev/null 2>&1; then
  fail "default backend silently selected an existing dist catalog"
fi

if RELAYKIT_DESKTOP_QUERY_HARNESS="${fake_harness}" \
  RELAYKIT_DESKTOP_QUERY_ARTIFACT_PATH="${artifact}" \
  "${RUNNER}" --model 'public/provider-model' --query-file "${query_file}" --expect tool --catalog-evidence "${catalog_evidence}" --catalog-sha256 "${catalog_sha}" --catalog-setup-id current-setup --catalog-session-id current-session --artifact-sha256 "${artifact_sha}" >/dev/null 2>&1; then
  fail "provider query accepted a missing provider precondition"
fi

failing_harness="${tmp}/failing-harness.sh"
cat >"${failing_harness}" <<'HARNESS'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' 'private harness diagnostic must not escape' >&2
jq -n '{status:"failed",error_code:"provider_input_missing_or_invalid",evidence:"/tmp/pre-submit-evidence.json",human_intervention_count:0}' >&2
exit 1
HARNESS
chmod 700 "${failing_harness}"

failure_status=0
RELAYKIT_DESKTOP_QUERY_HARNESS="${failing_harness}" \
RELAYKIT_DESKTOP_QUERY_ARTIFACT_PATH="${artifact}" \
  "${RUNNER}" --model 'gpt-5.5' --query-file "${query_file}" --expect plain --catalog-evidence "${catalog_evidence}" --catalog-sha256 "${catalog_sha}" --catalog-setup-id current-setup --catalog-session-id current-session --artifact-sha256 "${artifact_sha}" \
  >"${tmp}/failure.stdout" 2>"${tmp}/failure.json" || failure_status=$?
[[ "${failure_status}" -ne 0 && ! -s "${tmp}/failure.stdout" ]] || fail "failed backend returned success output"
jq -e -s \
  --arg catalog_sha "${catalog_sha}" \
  --arg artifact_sha "${artifact_sha}" \
  'length == 1 and .[0].status == "failed" and .[0].error_code == "provider_input_missing_or_invalid" and .[0].model == "gpt-5.5" and .[0].expect == "plain" and .[0].submission_state == "not_submitted" and .[0].evidence_path == "/tmp/pre-submit-evidence.json" and .[0].catalog_sha256 == $catalog_sha and .[0].artifact_sha256 == $artifact_sha' \
  "${tmp}/failure.json" >/dev/null || fail "failed backend did not return one redacted machine-readable result"
if rg -Fq 'private harness diagnostic' "${tmp}/failure.json"; then
  fail "failed backend leaked raw harness diagnostics"
fi

stale_catalog="${tmp}/stale-app-server.json"
jq -n --arg artifact_sha256 "${artifact_sha}" '{
  relaykit_lineage: {setup_id:"stale-setup",session_id:"stale-session",artifact_sha256:$artifact_sha256},
  official: [{model:"gpt-5.5",displayName:"GPT-5.5"}],
  provider: []
}' >"${stale_catalog}"
chmod 600 "${stale_catalog}"
stale_catalog_sha="$(shasum -a 256 "${stale_catalog}" | awk '{print $1}')"
stale_status=0
RELAYKIT_DESKTOP_QUERY_HARNESS="${fake_harness}" \
RELAYKIT_DESKTOP_QUERY_ARTIFACT_PATH="${artifact}" \
  "${RUNNER}" --model 'gpt-5.5' --query-file "${query_file}" --expect plain --catalog-evidence "${stale_catalog}" --catalog-sha256 "${stale_catalog_sha}" --catalog-setup-id current-setup --catalog-session-id current-session --artifact-sha256 "${artifact_sha}" \
  >"${tmp}/stale.stdout" 2>"${tmp}/stale.json" || stale_status=$?
[[ "${stale_status}" -ne 0 && ! -s "${tmp}/stale.stdout" ]] || fail "stale catalog lineage passed with its own matching SHA"
jq -e -s 'length == 1 and .[0].error_code == "catalog_lineage_stale"' "${tmp}/stale.json" >/dev/null ||
  fail "stale catalog lineage rejection was not machine-readable"

printf '%s\n' 'codex-desktop-query backend tests passed'
