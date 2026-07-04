#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${ROOT}/dist/reference-model-coverage.json"
USAGE_OUT="${ROOT}/dist/reference-usage-source-coverage.json"
URL="${RELAYKIT_REFERENCE_MODELS_URL:-http://127.0.0.1:18787/v1/models}"
USAGE_LOG="${RELAYKIT_REFERENCE_USAGE_LOG:-${HOME}/.config/agent-local-gateway/usage.jsonl}"
KEEP_SOURCE_NAMES="${RELAYKIT_REFERENCE_KEEP_SOURCE_NAMES:-0}"
KEEP_MODEL_IDS="${RELAYKIT_REFERENCE_KEEP_MODEL_IDS:-0}"

mkdir -p "${ROOT}/dist"

curl -fsS "${URL}" |
  jq --arg keep_source_names "${KEEP_SOURCE_NAMES}" --arg keep_model_ids "${KEEP_MODEL_IDS}" '[
    .data[]
    | {
        source: (.owned_by // .source // "unknown"),
        model_id: .id
      }
  ]
  | group_by(.source)
  | to_entries
  | map({
      source: (if $keep_source_names == "1" then .value[0].source else "source-\(.key + 1)" end),
      model_count: (.value | length),
      representative_model_id: (if $keep_model_ids == "1" then .value[0].model_id else "<redacted>" end),
      model_id_redacted: ($keep_model_ids != "1"),
      relaykit_representation: "provider id/name/base_url/api_format/credential_ref/capabilities/routing/models",
      route_status: "not_routed",
      blocker: "requires explicit public provider config and credential reference before RelayKit can route this source"
    })' >"${OUT}"

jq . "${OUT}"
echo "RelayKit reference model coverage written: ${OUT}"

if [[ -f "${USAGE_LOG}" ]]; then
  tail -200 "${USAGE_LOG}" |
    jq -s '[
      .[]
      | select(type == "object")
      | {
          source: (.source // "unknown"),
          status: (.status // "unknown")
        }
    ]
    | group_by(.source)
    | to_entries
    | map({
        source: "source-\(.key + 1)",
        request_count: (.value | length),
        success_count: (.value | map(select(.status == "success")) | length),
        source_name_redacted: true,
        model_ids_redacted: true,
        routing_drift: (.value[0].source == "official"),
        drift_note: (if .value[0].source == "official" then "actual source category was official" else "none" end)
      })' >"${USAGE_OUT}"
else
  jq -n '[{
    source: "unavailable",
    request_count: 0,
    success_count: 0,
    source_name_redacted: true,
    model_ids_redacted: true,
    routing_drift: false,
    drift_note: "agent-local-gateway usage log unavailable"
  }]' >"${USAGE_OUT}"
fi

jq . "${USAGE_OUT}"
echo "RelayKit reference usage source coverage written: ${USAGE_OUT}"
