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

cat >"${fake_harness}" <<'HARNESS'
#!/usr/bin/env bash
set -euo pipefail
[[ "${1:-}" == "run-auto" && "${2:-}" == "--scenario" && -f "${3:-}" ]]
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
  .stages[0].expect == "plain"
' "${scenario}" >/dev/null
printf '%s\n' 'fake-harness: Terminated: 15 sandbox-exec cleanup' >&2
jq -n --arg marker "${marker}" '{status:"complete",profile:"custom_scenario",marker:$marker}' | tee "${RELAYKIT_DESKTOP_QUERY_TEST_CAPTURE}"
HARNESS
chmod 700 "${fake_harness}"

RELAYKIT_DESKTOP_QUERY_HARNESS="${fake_harness}" \
RELAYKIT_DESKTOP_QUERY_CATALOG_EVIDENCE="${catalog_evidence}" \
RELAYKIT_DESKTOP_QUERY_TEST_CAPTURE="${capture_file}" \
  "${RUNNER}" --model 'gpt-5.5' --query-file "${query_file}" >"${tmp}/result.json" 2>"${tmp}/stderr.txt"

jq -e '.status == "complete" and .profile == "custom_scenario" and (.marker | startswith("RELAYKIT_DESKTOP_QUERY_"))' "${tmp}/result.json" >/dev/null ||
  fail "default backend did not complete the one-stage harness contract"
cmp "${tmp}/result.json" "${capture_file}" >/dev/null ||
  fail "runner did not preserve the backend result"
[[ ! -s "${tmp}/stderr.txt" ]] ||
  fail "successful backend leaked harness cleanup noise"

if RELAYKIT_DESKTOP_QUERY_HARNESS="${fake_harness}" \
  RELAYKIT_DESKTOP_QUERY_CATALOG_EVIDENCE="${catalog_evidence}" \
  RELAYKIT_DESKTOP_QUERY_TEST_CAPTURE="${capture_file}" \
  "${RUNNER}" --model 'missing-model' --query-file "${query_file}" >/dev/null 2>&1; then
  fail "default backend accepted an unknown model"
fi

printf '%s\n' 'codex-desktop-query backend tests passed'
