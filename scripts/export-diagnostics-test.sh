#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${ROOT}/scripts/export-diagnostics.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

TEST_HOME="${TMP_DIR}/home"
OUT_DIR="${TMP_DIR}/diagnostics"
APP_SUPPORT="${TEST_HOME}/Library/Application Support/RelayKit"
mkdir -p "${APP_SUPPORT}"

cat >"${APP_SUPPORT}/providers.json" <<'JSON'
{
  "providers": [
    {
      "id": "private-provider-sentinel",
      "base_url": "https://private-provider.invalid/v1",
      "credential_ref": {"kind": "keychain", "value": "private-keychain-sentinel"},
      "models": [{"id": "private/model-one"}, {"id": "private/model-two"}]
    }
  ]
}
JSON

cat >"${APP_SUPPORT}/usage.jsonl" <<'JSONL'
{"status":"completed","total_tokens":12,"provider_id":"private-provider-sentinel","model":"private/model-one","request_body":"private-request-sentinel"}
{"status":"failed","error_type":"auth_required","headers":"Bearer private-header-sentinel"}
{"status":"failed","error_type":"https://private-error.invalid/Bearer-private-error-sentinel","response_body":"private-response-sentinel"}
JSONL

HOME="${TEST_HOME}" "${SCRIPT}" "${OUT_DIR}" >/dev/null

jq -e '
  .providers.configured_count == 1 and
  .providers.configured_model_count == 2 and
  .usage.event_count == 3 and
  .usage.total_tokens == 12 and
  .usage.failed_event_count == 2 and
  .usage.recent_error_types == ["auth_required", "other"]
' "${OUT_DIR}/diagnostics.json" >/dev/null
jq -e '.passed == true' "${OUT_DIR}/redaction-scan.json" >/dev/null

if rg -i 'private-|Bearer|https?://|credential_ref|keychain|request_body|response_body|headers' "${OUT_DIR}" >/dev/null; then
  echo "diagnostics test found sensitive fixture content in exported files" >&2
  exit 1
fi

echo "Diagnostics redaction test passed"
