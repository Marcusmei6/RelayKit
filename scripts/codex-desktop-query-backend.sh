#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  jq -n --arg code "$1" '{status:"failed",error_code:$code}' >&2
  exit 1
}

[[ "${1:-}" == "--model" && -n "${2:-}" && "${3:-}" == "--query-file" && -n "${4:-}" && -z "${5:-}" ]] ||
  fail "invalid_arguments"

model="$2"
query_file="$4"
harness="${RELAYKIT_DESKTOP_QUERY_HARNESS:-${ROOT}/scripts/codex-desktop-manual-proof.sh}"
catalog_evidence="${RELAYKIT_DESKTOP_QUERY_CATALOG_EVIDENCE:-}"

[[ "${query_file}" = /* && -f "${query_file}" && ! -L "${query_file}" && "$(stat -f '%Lp' "${query_file}")" == "600" ]] ||
  fail "query_file_invalid"
[[ -x "${harness}" ]] || fail "harness_unavailable"

if [[ -z "${catalog_evidence}" ]]; then
  for candidate in \
    "${ROOT}/dist/codex-desktop-automated-provider-complete/app-server.json" \
    "${ROOT}/dist/codex-desktop-manual-proof-last-custom-complete/app-server.json" \
    "${ROOT}/dist/codex-desktop-manual-proof/app-server.json" \
    "${ROOT}/dist/codex-desktop-manual-proof-last-route/app-server.json"; do
    if [[ -f "${candidate}" ]]; then
      catalog_evidence="${candidate}"
      break
    fi
  done
fi
[[ -f "${catalog_evidence}" ]] || fail "catalog_evidence_unavailable"

resolved_model="$(jq -ce --arg requested "${model}" '
  [.official[]?, .provider[]?]
  | map(select(.model == $requested or .displayName == $requested))
  | select(length == 1)
  | .[0]
' "${catalog_evidence}" 2>/dev/null)" || fail "model_not_unique_or_missing"
model_id="$(jq -er '.model' <<<"${resolved_model}")"
model_label="$(jq -er '.displayName' <<<"${resolved_model}")"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/relaykit-desktop-query-backend.XXXXXX")"
chmod 700 "${tmp}"
trap 'rm -rf "${tmp}"' EXIT
staged_query="${tmp}/query.txt"
scenario="${tmp}/scenario.json"
marker="RELAYKIT_DESKTOP_QUERY_$(date -u +%Y%m%dT%H%M%SZ)_$$"

cp "${query_file}" "${staged_query}"
printf '\n\nFor automation verification, end the response with a separate final line containing exactly: %s\n' "${marker}" >>"${staged_query}"
chmod 600 "${staged_query}"
[[ "$(stat -f '%z' "${staged_query}")" -le 65536 ]] || fail "query_file_size"

jq -n \
  --arg model_id "${model_id}" \
  --arg model_label "${model_label}" \
  --arg query_file "${staged_query}" \
  --arg marker "${marker}" \
  '{
    version: 1,
    stage_timeout_seconds: 420,
    stages: [{
      id: "desktop-query",
      model_id: $model_id,
      model_label: $model_label,
      query_file: $query_file,
      response_marker: $marker,
      evidence_role: "desktop-query-response",
      expect: "plain"
    }]
  }' >"${scenario}"
chmod 600 "${scenario}"

harness_stdout="${tmp}/harness.stdout"
harness_stderr="${tmp}/harness.stderr"
filtered_stderr="${tmp}/harness.filtered.stderr"
harness_status=0
set +e
if [[ "${harness}" == "${ROOT}/scripts/codex-desktop-manual-proof.sh" ]]; then
  provider_config="${RELAYKIT_DESKTOP_PROOF_REAL_PROVIDER_CONFIG:-${HOME}/Library/Application Support/RelayKit/DesktopProof/real-provider-input.json}"
  provider_model="${RELAYKIT_DESKTOP_PROOF_PUBLIC_MODEL_ID:-}"
  if [[ -z "${provider_model}" ]]; then
    provider_model="$(jq -r '.provider[0].model // empty' "${catalog_evidence}")"
  fi
  [[ -f "${provider_config}" && -n "${provider_model}" ]] || fail "provider_precondition_unavailable"
  RELAYKIT_DESKTOP_PROOF_REAL_PROVIDER_CONFIG="${provider_config}" \
  RELAYKIT_DESKTOP_PROOF_PUBLIC_MODEL_ID="${provider_model}" \
  RELAYKIT_DESKTOP_PROOF_REUSE_CURRENT_ZIP="${RELAYKIT_DESKTOP_PROOF_REUSE_CURRENT_ZIP:-1}" \
  RELAYKIT_DESKTOP_PROOF_INPUT_MODE=automated_ax \
    "${harness}" run-auto --scenario "${scenario}" </dev/null >"${harness_stdout}" 2>"${harness_stderr}"
  harness_status=$?
else
  "${harness}" run-auto --scenario "${scenario}" </dev/null >"${harness_stdout}" 2>"${harness_stderr}"
  harness_status=$?
fi
set -e

grep -Ev 'Terminated: 15.*sandbox-exec' "${harness_stderr}" >"${filtered_stderr}" || true
if [[ "${harness_status}" -ne 0 ]]; then
  [[ -s "${filtered_stderr}" ]] && cat "${filtered_stderr}" >&2
  [[ -s "${harness_stdout}" ]] && cat "${harness_stdout}" >&2
  exit "${harness_status}"
fi

jq -e -s 'length == 1 and (.[0] | type == "object")' "${harness_stdout}" >/dev/null ||
  fail "harness_result_invalid"
[[ -s "${filtered_stderr}" ]] && cat "${filtered_stderr}" >&2
cat "${harness_stdout}"
