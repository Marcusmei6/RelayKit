#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${ROOT}/dist/reference-model-coverage.json"
URL="${RELAYKIT_REFERENCE_MODELS_URL:-http://127.0.0.1:18787/v1/models}"

mkdir -p "${ROOT}/dist"

curl -fsS "${URL}" |
  jq '[
    .data[]
    | {
        source: (.owned_by // .source // "unknown"),
        model_id: .id
      }
  ]
  | group_by(.source)
  | map({
      source: .[0].source,
      model_count: length,
      representative_model_id: (.[0].model_id | if contains("/") then "<redacted>" else . end),
      model_id_redacted: (.[0].model_id | contains("/")),
      relaykit_representation: "provider id/name/base_url/api_format/auth_env/models",
      route_status: "not_routed",
      blocker: "requires explicit public provider config and credential reference before RelayKit can route this source"
    })' >"${OUT}"

jq . "${OUT}"
echo "RelayKit reference model coverage written: ${OUT}"
