#!/usr/bin/env bash
set -euo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNNER="${SKILL_DIR}/scripts/run-query.sh"

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

[[ -x "${RUNNER}" ]] || fail "run-query.sh is missing or not executable"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/relaykit-desktop-query-test.XXXXXX")"
trap 'rm -rf "${tmp}"' EXIT
query_file="${tmp}/query.txt"
backend="${tmp}/backend.sh"
catalog="${tmp}/catalog.json"
artifact="${tmp}/artifact.zip"

printf '%s\n' 'Explain the current RelayKit status.' >"${query_file}"
chmod 600 "${query_file}"
printf '%s\n' '{"official":[{"model":"gpt-5.5","displayName":"GPT-5.5"}],"provider":[]}' >"${catalog}"
printf '%s\n' 'artifact fixture' >"${artifact}"
catalog_sha="$(shasum -a 256 "${catalog}" | awk '{print $1}')"
artifact_sha="$(shasum -a 256 "${artifact}" | awk '{print $1}')"

cat >"${backend}" <<'BACKEND'
#!/usr/bin/env bash
set -euo pipefail
[[ "${1:-}" == "--model" && -n "${2:-}" && "${3:-}" == "--query-file" && -f "${4:-}" ]]
[[ "${5:-}" == "--expect" && "${6:-}" == "markdown" ]]
[[ "${7:-}" == "--catalog-evidence" && -f "${8:-}" ]]
[[ "${9:-}" == "--catalog-sha256" && -n "${10:-}" ]]
[[ "${11:-}" == "--artifact-sha256" && -n "${12:-}" && -z "${13:-}" ]]
jq -n \
  --arg model "$2" \
  --arg expect "$6" \
  --arg catalog_sha256 "${10}" \
  --arg artifact_sha256 "${12}" \
  --arg query_sha256 "$(shasum -a 256 "$4" | awk '{print $1}')" \
  '{status:"submitted",model:$model,expect:$expect,catalog_sha256:$catalog_sha256,artifact_sha256:$artifact_sha256,query_sha256:$query_sha256}'
BACKEND
chmod 700 "${backend}"

RELAYKIT_DESKTOP_QUERY_BACKEND="${backend}" \
RELAYKIT_DESKTOP_QUERY_ARTIFACT_PATH="${artifact}" \
  "${RUNNER}" \
    --model 'GPT-5.5' \
    --query-file "${query_file}" \
    --expect markdown \
    --catalog-evidence "${catalog}" \
    --catalog-sha256 "${catalog_sha}" \
    --artifact-sha256 "${artifact_sha}" >"${tmp}/result.json"

jq -e \
  --arg expected_sha "$(shasum -a 256 "${query_file}" | awk '{print $1}')" \
  --arg catalog_sha "${catalog_sha}" \
  --arg artifact_sha "${artifact_sha}" \
  '.status == "submitted" and .model == "GPT-5.5" and .expect == "markdown" and .catalog_sha256 == $catalog_sha and .artifact_sha256 == $artifact_sha and .query_sha256 == $expected_sha' \
  "${tmp}/result.json" >/dev/null || fail "runner did not pass model/query-file to the backend"

if rg -Fq 'Explain the current RelayKit status.' "${tmp}/result.json"; then
  fail "runner leaked query content into its result"
fi

chmod 644 "${query_file}"
if RELAYKIT_DESKTOP_QUERY_BACKEND="${backend}" \
  "${RUNNER}" --model 'GPT-5.5' --query-file "${query_file}" --expect markdown --catalog-evidence "${catalog}" --catalog-sha256 "${catalog_sha}" --artifact-sha256 "${artifact_sha}" >/dev/null 2>&1; then
  fail "runner accepted a non-0600 query file"
fi

if RELAYKIT_DESKTOP_QUERY_BACKEND="${backend}" \
  "${RUNNER}" --query-file "${query_file}" --expect markdown --catalog-evidence "${catalog}" --catalog-sha256 "${catalog_sha}" --artifact-sha256 "${artifact_sha}" >/dev/null 2>&1; then
  fail "runner accepted a missing model"
fi

chmod 600 "${query_file}"
if RELAYKIT_DESKTOP_QUERY_BACKEND="${backend}" \
  "${RUNNER}" --model 'GPT-5.5' --query-file "${query_file}" --expect invalid --catalog-evidence "${catalog}" --catalog-sha256 "${catalog_sha}" --artifact-sha256 "${artifact_sha}" >/dev/null 2>&1; then
  fail "runner accepted an invalid expectation"
fi

if RELAYKIT_DESKTOP_QUERY_BACKEND="${backend}" \
  "${RUNNER}" --model 'GPT-5.5' --query-file "${query_file}" --expect plain >/dev/null 2>&1; then
  fail "runner accepted missing explicit catalog/artifact evidence"
fi

printf '%s\n' 'relaykit-desktop-query runner tests passed'
