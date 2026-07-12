#!/usr/bin/env bash
set -euo pipefail

fail() {
  jq -n --arg code "$1" '{status:"failed",error_code:$code}' >&2
  exit 1
}

model=""
query_file=""
expect="plain"
catalog_evidence=""
catalog_sha256=""
catalog_setup_id=""
catalog_session_id=""
artifact_sha256=""

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --model) model="${2:-}"; shift 2 ;;
    --query-file) query_file="${2:-}"; shift 2 ;;
    --expect) expect="${2:-}"; shift 2 ;;
    --catalog-evidence) catalog_evidence="${2:-}"; shift 2 ;;
    --catalog-sha256) catalog_sha256="${2:-}"; shift 2 ;;
    --catalog-setup-id) catalog_setup_id="${2:-}"; shift 2 ;;
    --catalog-session-id) catalog_session_id="${2:-}"; shift 2 ;;
    --artifact-sha256) artifact_sha256="${2:-}"; shift 2 ;;
    *) fail "invalid_arguments" ;;
  esac
done

[[ -n "${model}" && -n "${query_file}" && -n "${catalog_evidence}" && -n "${catalog_sha256}" && -n "${catalog_setup_id}" && -n "${catalog_session_id}" && -n "${artifact_sha256}" ]] ||
  fail "invalid_arguments"
backend="${RELAYKIT_DESKTOP_QUERY_BACKEND:-}"

[[ "${model}" != *$'\n'* && "${model}" != *$'\r'* && "${#model}" -le 256 ]] ||
  fail "model_invalid"
[[ "${expect}" == "plain" || "${expect}" == "markdown" || "${expect}" == "tool" ]] ||
  fail "expect_invalid"
[[ "${query_file}" = /* && -f "${query_file}" && ! -L "${query_file}" ]] ||
  fail "query_file_invalid"
[[ "$(stat -f '%u:%Lp:%z' "${query_file}")" == "$(id -u):600:"* ]] ||
  fail "query_file_permissions"
query_size="$(stat -f '%z' "${query_file}")"
[[ "${query_size}" -gt 0 && "${query_size}" -le 1048576 ]] ||
  fail "query_file_size"
[[ "${catalog_evidence}" = /* && -f "${catalog_evidence}" && ! -L "${catalog_evidence}" ]] ||
  fail "catalog_evidence_invalid"
catalog_mode="$(stat -f '%Lp' "${catalog_evidence}")"
[[ "$(stat -f '%u' "${catalog_evidence}")" == "$(id -u)" && "$((8#${catalog_mode} & 8#022))" -eq 0 ]] ||
  fail "catalog_evidence_permissions"
[[ "${catalog_sha256}" =~ ^[0-9a-f]{64}$ && "${artifact_sha256}" =~ ^[0-9a-f]{64}$ ]] ||
  fail "evidence_hash_invalid"
[[ "${catalog_setup_id}" =~ ^[A-Za-z0-9._:-]{1,128}$ && "${catalog_session_id}" =~ ^[A-Za-z0-9._:-]{1,128}$ ]] ||
  fail "catalog_lineage_invalid"

if [[ -z "${backend}" ]]; then
  repo_root="$(git -C "$(pwd)" rev-parse --show-toplevel 2>/dev/null || true)"
  [[ -n "${repo_root}" ]] && backend="${repo_root}/scripts/codex-desktop-query-backend.sh"
fi

[[ "${backend}" = /* && -f "${backend}" && -x "${backend}" && ! -L "${backend}" ]] ||
  fail "backend_unavailable"

exec "${backend}" \
  --model "${model}" \
  --query-file "${query_file}" \
  --expect "${expect}" \
  --catalog-evidence "${catalog_evidence}" \
  --catalog-sha256 "${catalog_sha256}" \
  --catalog-setup-id "${catalog_setup_id}" \
  --catalog-session-id "${catalog_session_id}" \
  --artifact-sha256 "${artifact_sha256}"
