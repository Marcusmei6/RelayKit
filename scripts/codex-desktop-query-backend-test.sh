#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNNER="${ROOT}/.agents/skills/relaykit-desktop-query/scripts/run-query.sh"
BACKEND="${ROOT}/scripts/codex-desktop-query-backend.sh"

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

[[ -x "${BACKEND}" ]] || fail "default desktop-query backend is missing"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/relaykit-desktop-query-backend-test.XXXXXX")"
trap 'rm -rf "${tmp}"' EXIT
query_file="${tmp}/query.txt"
catalog_evidence="${tmp}/app-server.json"
artifact="${tmp}/artifact.zip"
fake_harness="${tmp}/fake-harness.sh"
capture_file="${tmp}/capture.json"

printf '%s\n' 'Summarize RelayKit in one sentence.' >"${query_file}"
chmod 600 "${query_file}"

cat >"${catalog_evidence}" <<'JSON'
{
  "official": [
    {"model": "gpt-5.5", "displayName": "GPT-5.5"}
  ],
  "provider": [
    {"model": "public/provider-model", "displayName": "Public Provider Model"}
  ]
}
JSON
chmod 600 "${catalog_evidence}"
printf '%s\n' 'artifact fixture' >"${artifact}"
catalog_sha="$(shasum -a 256 "${catalog_evidence}" | awk '{print $1}')"
artifact_sha="$(shasum -a 256 "${artifact}" | awk '{print $1}')"

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

RELAYKIT_DESKTOP_QUERY_HARNESS="${fake_harness}" \
RELAYKIT_DESKTOP_QUERY_CATALOG_EVIDENCE="${catalog_evidence}" \
RELAYKIT_DESKTOP_QUERY_TEST_CAPTURE="${capture_file}" \
RELAYKIT_DESKTOP_QUERY_ARTIFACT_PATH="${artifact}" \
  "${RUNNER}" \
    --model 'gpt-5.5' \
    --query-file "${query_file}" \
    --expect markdown \
    --catalog-evidence "${catalog_evidence}" \
    --catalog-sha256 "${catalog_sha}" \
    --artifact-sha256 "${artifact_sha}" >"${tmp}/result.json" 2>"${tmp}/stderr.txt"

jq -e \
  --arg catalog_sha "${catalog_sha}" \
  --arg artifact_sha "${artifact_sha}" \
  '.status == "complete" and .model == "gpt-5.5" and .expect == "markdown" and .submission_state == "submitted" and .evidence_path == "/tmp/redacted-evidence.json" and .catalog_sha256 == $catalog_sha and .artifact_sha256 == $artifact_sha and (keys | sort) == ["artifact_sha256","catalog_sha256","evidence_path","expect","model","status","submission_state"]' \
  "${tmp}/result.json" >/dev/null ||
  fail "default backend did not complete the one-stage harness contract"
[[ ! -s "${tmp}/stderr.txt" ]] ||
  fail "successful backend leaked harness cleanup noise"

if RELAYKIT_DESKTOP_QUERY_HARNESS="${fake_harness}" \
  RELAYKIT_DESKTOP_QUERY_CATALOG_EVIDENCE="${catalog_evidence}" \
  RELAYKIT_DESKTOP_QUERY_TEST_CAPTURE="${capture_file}" \
  RELAYKIT_DESKTOP_QUERY_ARTIFACT_PATH="${artifact}" \
  "${RUNNER}" --model 'missing-model' --query-file "${query_file}" --expect plain --catalog-evidence "${catalog_evidence}" --catalog-sha256 "${catalog_sha}" --artifact-sha256 "${artifact_sha}" >/dev/null 2>&1; then
  fail "default backend accepted an unknown model"
fi

if RELAYKIT_DESKTOP_QUERY_HARNESS="${fake_harness}" \
  RELAYKIT_DESKTOP_QUERY_ARTIFACT_PATH="${artifact}" \
  "${RUNNER}" --model 'gpt-5.5' --query-file "${query_file}" --expect plain --catalog-evidence "${catalog_evidence}" --catalog-sha256 deadbeef --artifact-sha256 "${artifact_sha}" >/dev/null 2>&1; then
  fail "default backend accepted a stale catalog hash"
fi

if RELAYKIT_DESKTOP_QUERY_HARNESS="${fake_harness}" \
  RELAYKIT_DESKTOP_QUERY_ARTIFACT_PATH="${artifact}" \
  "${RUNNER}" --model 'gpt-5.5' --query-file "${query_file}" --expect plain >/dev/null 2>&1; then
  fail "default backend silently selected an existing dist catalog"
fi

if RELAYKIT_DESKTOP_QUERY_HARNESS="${fake_harness}" \
  RELAYKIT_DESKTOP_QUERY_ARTIFACT_PATH="${artifact}" \
  "${RUNNER}" --model 'public/provider-model' --query-file "${query_file}" --expect tool --catalog-evidence "${catalog_evidence}" --catalog-sha256 "${catalog_sha}" --artifact-sha256 "${artifact_sha}" >/dev/null 2>&1; then
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
  "${RUNNER}" --model 'gpt-5.5' --query-file "${query_file}" --expect plain --catalog-evidence "${catalog_evidence}" --catalog-sha256 "${catalog_sha}" --artifact-sha256 "${artifact_sha}" \
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

printf '%s\n' 'codex-desktop-query backend tests passed'
