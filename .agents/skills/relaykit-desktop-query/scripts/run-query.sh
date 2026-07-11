#!/usr/bin/env bash
set -euo pipefail

fail() {
  jq -n --arg code "$1" '{status:"failed",error_code:$code}' >&2
  exit 1
}

[[ "${1:-}" == "--model" && -n "${2:-}" && "${3:-}" == "--query-file" && -n "${4:-}" && -z "${5:-}" ]] ||
  fail "invalid_arguments"

model="$2"
query_file="$4"
backend="${RELAYKIT_DESKTOP_QUERY_BACKEND:-}"

[[ "${model}" != *$'\n'* && "${model}" != *$'\r'* && "${#model}" -le 256 ]] ||
  fail "model_invalid"
[[ "${query_file}" = /* && -f "${query_file}" && ! -L "${query_file}" ]] ||
  fail "query_file_invalid"
[[ "$(stat -f '%u:%Lp:%z' "${query_file}")" == "$(id -u):600:"* ]] ||
  fail "query_file_permissions"
query_size="$(stat -f '%z' "${query_file}")"
[[ "${query_size}" -gt 0 && "${query_size}" -le 1048576 ]] ||
  fail "query_file_size"

if [[ -z "${backend}" ]]; then
  repo_root="$(git -C "$(pwd)" rev-parse --show-toplevel 2>/dev/null || true)"
  [[ -n "${repo_root}" ]] && backend="${repo_root}/scripts/codex-desktop-query-backend.sh"
fi

[[ "${backend}" = /* && -f "${backend}" && -x "${backend}" && ! -L "${backend}" ]] ||
  fail "backend_unavailable"

exec "${backend}" --model "${model}" --query-file "${query_file}"
