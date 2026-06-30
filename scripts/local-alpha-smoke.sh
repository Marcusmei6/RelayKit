#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GATEWAY_PID=""
HELPER_INSTALLED="false"
TMPDIR_RELAYKIT=""
HELPER_LABEL="dev.relaykit.gateway"
HELPER_PLIST="${HOME}/Library/LaunchAgents/${HELPER_LABEL}.plist"

cleanup() {
  if [[ -n "${TMPDIR_RELAYKIT}" ]]; then
    rm -rf "${TMPDIR_RELAYKIT}"
  fi
  if [[ "${HELPER_INSTALLED}" == "true" ]]; then
    "${ROOT}/scripts/relaykit-helper.sh" uninstall >/dev/null 2>&1 || true
  fi
  if [[ -n "${GATEWAY_PID}" ]] && kill -0 "${GATEWAY_PID}" 2>/dev/null; then
    kill "${GATEWAY_PID}"
  fi
}
trap cleanup EXIT

cd "${ROOT}/gateway"
go test ./... -count=1
go vet ./...
test -z "$(gofmt -l .)"
go build -o bin/relay ./cmd/gateway

./bin/relay -listen 127.0.0.1:19777 -config ../examples/providers.example.json >/tmp/relaykit-alpha-gateway.log 2>&1 &
GATEWAY_PID="$!"
sleep 2
if ! kill -0 "${GATEWAY_PID}" 2>/dev/null; then
  cat /tmp/relaykit-alpha-gateway.log >&2
  exit 1
fi
curl -fsS http://127.0.0.1:19777/healthz >/dev/null
curl -fsS http://127.0.0.1:19777/v1/models >/dev/null
kill "${GATEWAY_PID}"
wait "${GATEWAY_PID}" 2>/dev/null || true
GATEWAY_PID=""

tmpdir="$(mktemp -d)"
TMPDIR_RELAYKIT="${tmpdir}"
printf 'model = "relaykit-smoke"\n' >"${tmpdir}/codex.source.toml"
printf 'model = "old"\n' >"${tmpdir}/codex.target.toml"
./bin/relay activate-codex-config -source "${tmpdir}/codex.source.toml" -target "${tmpdir}/codex.target.toml" >/dev/null
grep -q 'relaykit-smoke' "${tmpdir}/codex.target.toml"
printf '%s\n' '{"timestamp":"2026-06-30T01:02:03Z","provider_id":"p1","model":"m1","input_tokens":1,"output_tokens":2,"total_tokens":3,"duration_ms":10}' >"${tmpdir}/usage.jsonl"
./bin/relay summarize-usage -path "${tmpdir}/usage.jsonl" | grep -q '"requests":1'

cd "${ROOT}"
if [[ -f "${HELPER_PLIST}" ]] || launchctl print "gui/$(id -u)/${HELPER_LABEL}" >/dev/null 2>&1; then
  echo "RelayKit LaunchAgent already exists; stop/uninstall it before running local alpha smoke" >&2
  exit 1
fi
./scripts/relaykit-helper.sh install --binary "${ROOT}/gateway/bin/relay" --config "${ROOT}/examples/providers.example.json" >/dev/null
HELPER_INSTALLED="true"
./scripts/relaykit-helper.sh status | grep -qx "running ${HELPER_LABEL}"
curl -fsS http://127.0.0.1:19777/healthz >/dev/null
curl -fsS http://127.0.0.1:19777/v1/models >/dev/null
./scripts/relaykit-helper.sh logs --lines 5 >/dev/null
./scripts/relaykit-helper.sh uninstall >/dev/null
HELPER_INSTALLED="false"

cd "${ROOT}/app"
swift build
swift run RelayKitAppValidationTests

echo "RelayKit local alpha smoke passed"
