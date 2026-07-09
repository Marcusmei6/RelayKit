#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="${1:-${ROOT}/dist/diagnostics}"
APP_BUNDLE="${ROOT}/dist/RelayKitApp.app"
INFO_PLIST="${APP_BUNDLE}/Contents/Info.plist"
PROVIDERS_PATH="${HOME}/Library/Application Support/RelayKit/providers.json"
USAGE_PATH="${HOME}/Library/Application Support/RelayKit/usage.jsonl"
DIAGNOSTICS_JSON="${OUT_DIR}/diagnostics.json"
SCAN_JSON="${OUT_DIR}/redaction-scan.json"

mkdir -p "${OUT_DIR}"

plist_value() {
  local key="$1"
  if [[ -f "${INFO_PLIST}" ]]; then
    /usr/libexec/PlistBuddy -c "Print :${key}" "${INFO_PLIST}" 2>/dev/null || true
  fi
}

gateway_health="unavailable"
if curl -fsS --max-time 1 http://127.0.0.1:19777/healthz >/dev/null 2>&1; then
  gateway_health="ok"
fi

provider_count=0
provider_model_count=0
if [[ -f "${PROVIDERS_PATH}" ]]; then
  provider_count="$(jq '.providers // [] | length' "${PROVIDERS_PATH}" 2>/dev/null || echo 0)"
  provider_model_count="$(jq '[.providers // [] | .[] | .models // [] | length] | add // 0' "${PROVIDERS_PATH}" 2>/dev/null || echo 0)"
fi

usage_events=0
usage_total_tokens=0
usage_failed_events=0
recent_error_types='[]'
if [[ -f "${USAGE_PATH}" ]]; then
  usage_events="$(jq -s 'length' "${USAGE_PATH}" 2>/dev/null || echo 0)"
  usage_total_tokens="$(jq -s '[.[].total_tokens // 0] | add // 0' "${USAGE_PATH}" 2>/dev/null || echo 0)"
  usage_failed_events="$(jq -s '[.[] | select((.status // "") != "completed")] | length' "${USAGE_PATH}" 2>/dev/null || echo 0)"
  recent_error_types="$(tail -n 100 "${USAGE_PATH}" | jq -s '[.[].error_type // empty] | unique | sort' 2>/dev/null || echo '[]')"
fi

jq -n \
  --arg version "$(plist_value CFBundleShortVersionString)" \
  --arg build "$(plist_value CFBundleVersion)" \
  --arg bundle_id "$(plist_value CFBundleIdentifier)" \
  --arg gateway_port "127.0.0.1:19777" \
  --arg gateway_health "${gateway_health}" \
  --argjson provider_count "${provider_count}" \
  --argjson provider_model_count "${provider_model_count}" \
  --argjson usage_events "${usage_events}" \
  --argjson usage_total_tokens "${usage_total_tokens}" \
  --argjson usage_failed_events "${usage_failed_events}" \
  --argjson recent_error_types "${recent_error_types}" \
  '{
    relaykit: {
      version: $version,
      build: $build,
      bundle_id: $bundle_id
    },
    gateway: {
      port: $gateway_port,
      health: $gateway_health
    },
    providers: {
      configured_count: $provider_count,
      configured_model_count: $provider_model_count
    },
    usage: {
      event_count: $usage_events,
      total_tokens: $usage_total_tokens,
      failed_event_count: $usage_failed_events,
      recent_error_types: $recent_error_types
    },
    redaction: {
      scan: "required"
    }
  }' >"${DIAGNOSTICS_JSON}"

forbidden='(sk-[A-Za-z0-9_-]{10,}|Bearer[[:space:]]+|Authorization|api[_-]?key|auth\.json|base_url|models_url|credential_ref|keychain|https?://|request_body|response_body|headers)'
if LC_ALL=C grep -Eiq "${forbidden}" "${DIAGNOSTICS_JSON}"; then
  jq -n '{passed:false, reason:"forbidden diagnostic content pattern found"}' >"${SCAN_JSON}"
  echo "diagnostics redaction scan failed: ${DIAGNOSTICS_JSON}" >&2
  exit 1
fi

jq -n '{passed:true}' >"${SCAN_JSON}"
echo "RelayKit diagnostics exported: ${DIAGNOSTICS_JSON}"
