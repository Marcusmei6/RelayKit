#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GATEWAY_PID=""

cleanup() {
  if [[ -n "${GATEWAY_PID}" ]] && kill -0 "${GATEWAY_PID}" 2>/dev/null; then
    kill "${GATEWAY_PID}"
  fi
}
trap cleanup EXIT

cd "${ROOT}/gateway"
go test ./... -count=1
go vet ./...
test -z "$(gofmt -l .)"
go build -o bin/relaykit-gateway ./cmd/gateway

./bin/relaykit-gateway -listen 127.0.0.1:19777 -config ../examples/providers.example.json >/tmp/relaykit-alpha-gateway.log 2>&1 &
GATEWAY_PID="$!"
sleep 2
if ! kill -0 "${GATEWAY_PID}" 2>/dev/null; then
  cat /tmp/relaykit-alpha-gateway.log >&2
  exit 1
fi
curl -fsS http://127.0.0.1:19777/healthz >/dev/null
curl -fsS http://127.0.0.1:19777/v1/models >/dev/null

cd "${ROOT}/app"
swift build
swift run RelayKitAppValidationTests

echo "RelayKit local alpha smoke passed"
