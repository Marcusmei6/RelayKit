# RelayKit

RelayKit is a local model routing kit for agentic coding tools. The first target is OpenAI Codex compatibility, but the project name and architecture intentionally avoid locking the product to one client.

## What It Is

RelayKit combines:

- a lightweight Apple-native Mac app for profiles, status, and local control;
- a portable local gateway helper for protocol translation and model routing;
- safe public configuration examples that never require private infrastructure.

## First Public Scope

- Local loopback gateway.
- Codex-compatible `/v1/models` and `/v1/responses` surfaces.
- OpenAI-compatible Chat Completions upstream adapter.
- Anthropic Messages upstream adapter.
- Generated model catalog for clients that support external catalogs.
- Local-only usage event log.
- Local LaunchAgent helper lifecycle for this checkout.
- Minimal SwiftUI app for gateway control, usage summaries, and provider config JSON editing without secrets.

## Out Of Scope For The First Release

- Private provider adapters.
- Cloud sync.
- Hosted usage reporting.
- Multi-tool all-in-one management.
- Marketplace-style provider sponsorships or commercial presets.

## Repository Layout

```text
app/        SwiftUI macOS app shell
gateway/    Go local gateway helper
docs/       architecture, roadmap, product decisions, handoff notes
examples/   public sample provider and Codex config files
scripts/    developer helper scripts
```

## Local Alpha Smoke

From the repository root:

```bash
./scripts/local-alpha-smoke.sh
```

The smoke builds the gateway and app, runs gateway tests/vet/format checks, verifies `/healthz` and `/v1/models`, and runs the app-side provider config validation executable.

## Gateway Development

```bash
cd gateway
go test ./...
go build -o bin/relaykit-gateway ./cmd/gateway
./bin/relaykit-gateway -listen 127.0.0.1:19777 -config ../examples/providers.example.json
```

Then in another terminal:

```bash
curl http://127.0.0.1:19777/healthz
curl http://127.0.0.1:19777/v1/models
```

## Mac App

```bash
cd app
swift build
swift run RelayKitApp
```

The development app expects the gateway binary at `../gateway/bin/relaykit-gateway`.

## Durable Local Helper

```bash
cd gateway
go build -o bin/relaykit-gateway ./cmd/gateway
cd ..
./scripts/relaykit-helper.sh install --config "$PWD/examples/providers.example.json"
./scripts/relaykit-helper.sh status
./scripts/relaykit-helper.sh logs --lines 80
./scripts/relaykit-helper.sh uninstall
```

The helper script affects only `~/Library/LaunchAgents/dev.relaykit.gateway.plist` and uses explicit provider config paths.

## Public Release Readiness

Before any public push or release, run `docs/public-boundary-checklist.md`. `.codex/agents/*.toml` currently contains local development model routes and must be scrubbed to public defaults before publishing.
