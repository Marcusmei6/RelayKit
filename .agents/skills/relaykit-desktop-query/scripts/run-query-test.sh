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

printf '%s\n' 'Explain the current RelayKit status.' >"${query_file}"
chmod 600 "${query_file}"

cat >"${backend}" <<'BACKEND'
#!/usr/bin/env bash
set -euo pipefail
[[ "${1:-}" == "--model" && -n "${2:-}" && "${3:-}" == "--query-file" && -f "${4:-}" ]]
jq -n \
  --arg model "$2" \
  --arg query_sha256 "$(shasum -a 256 "$4" | awk '{print $1}')" \
  '{status:"submitted",model:$model,query_sha256:$query_sha256}'
BACKEND
chmod 700 "${backend}"

RELAYKIT_DESKTOP_QUERY_BACKEND="${backend}" \
  "${RUNNER}" --model 'GPT-5.5' --query-file "${query_file}" >"${tmp}/result.json"

jq -e \
  --arg expected_sha "$(shasum -a 256 "${query_file}" | awk '{print $1}')" \
  '.status == "submitted" and .model == "GPT-5.5" and .query_sha256 == $expected_sha' \
  "${tmp}/result.json" >/dev/null || fail "runner did not pass model/query-file to the backend"

if rg -Fq 'Explain the current RelayKit status.' "${tmp}/result.json"; then
  fail "runner leaked query content into its result"
fi

chmod 644 "${query_file}"
if RELAYKIT_DESKTOP_QUERY_BACKEND="${backend}" \
  "${RUNNER}" --model 'GPT-5.5' --query-file "${query_file}" >/dev/null 2>&1; then
  fail "runner accepted a non-0600 query file"
fi

if RELAYKIT_DESKTOP_QUERY_BACKEND="${backend}" \
  "${RUNNER}" --query-file "${query_file}" >/dev/null 2>&1; then
  fail "runner accepted a missing model"
fi

printf '%s\n' 'relaykit-desktop-query runner tests passed'
