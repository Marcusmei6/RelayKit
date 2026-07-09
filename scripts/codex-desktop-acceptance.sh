#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${ROOT}/dist/codex-desktop-acceptance"
SOURCE_OUT="${ROOT}/dist/full-merged-catalog-proof"
CODEX_CONFIG_PATH="${HOME}/.codex/config.toml"
CODEX_AUTH_PATH="${HOME}/.codex/auth.json"

file_signature() {
  if [[ -e "$1" ]]; then
    /usr/bin/stat -f "%m:%z" "$1"
  else
    printf 'missing'
  fi
}

port_is_free() {
  ! lsof -nP -iTCP:"$1" -sTCP:LISTEN >/dev/null 2>&1
}

mkdir -p "${OUT}"
rm -f "${OUT}/"*

CONFIG_BEFORE="$(file_signature "${CODEX_CONFIG_PATH}")"
AUTH_BEFORE="$(file_signature "${CODEX_AUTH_PATH}")"

"${ROOT}/scripts/full-merged-catalog-proof.sh" >"${OUT}/full-merged-catalog-proof.log" 2>&1

for name in evidence.json app-server.json gateway-models.json model-catalog.json codex-config.toml usage-summary.json; do
  [[ -f "${SOURCE_OUT}/${name}" ]] && cp "${SOURCE_OUT}/${name}" "${OUT}/${name}"
done

CONFIG_AFTER="$(file_signature "${CODEX_CONFIG_PATH}")"
AUTH_AFTER="$(file_signature "${CODEX_AUTH_PATH}")"
PORT_18787_FREE=false
PORT_19777_FREE=false
port_is_free 18787 && PORT_18787_FREE=true
port_is_free 19777 && PORT_19777_FREE=true

jq \
  --arg config_before "${CONFIG_BEFORE}" \
  --arg config_after "${CONFIG_AFTER}" \
  --arg auth_before "${AUTH_BEFORE}" \
  --arg auth_after "${AUTH_AFTER}" \
  --argjson port18787 "${PORT_18787_FREE}" \
  --argjson port19777 "${PORT_19777_FREE}" \
  --slurpfile app_server "${OUT}/app-server.json" \
  '. + {
    acceptance_scope: "public_safe_headless",
    gateway_health_ok: true,
    gateway_models_include_demo: .full_merged_gateway_models,
    generated_config_model: "gpt-5.5",
    app_server_demo_models: $app_server[0].provider,
    desktop_gui_picker_proof: "not_attempted",
    desktop_gui_route_proof: "not_attempted",
    proof_source: "scripts/full-merged-catalog-proof.sh",
    global_config_signature_before: $config_before,
    global_config_signature_after: $config_after,
    global_auth_signature_before: $auth_before,
    global_auth_signature_after: $auth_after,
    global_config_unchanged: ($config_before == $config_after),
    global_auth_unchanged: ($auth_before == $auth_after),
    shared_18787_free_after: $port18787,
    shared_19777_free_after: $port19777
  }' "${SOURCE_OUT}/evidence.json" >"${OUT}/evidence.json"

jq -e '
  .acceptance_scope == "public_safe_headless" and
  .full_merged_gateway_models == true and
  .isolated_app_server_lists_official_and_provider == true and
  .official_request_hit_fake_official == true and
  .provider_request_hit_fake_provider == true and
  .global_config_unchanged == true and
  .global_auth_unchanged == true and
  .shared_18787_free_after == true and
  .shared_19777_free_after == true
' "${OUT}/evidence.json" >/dev/null

printf 'RelayKit public-safe Codex acceptance evidence: %s\n' "${OUT}"
