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

## Out Of Scope For The First Release

- Private provider adapters.
- Cloud sync.
- Hosted usage reporting.
- Multi-tool all-in-one management.
- Marketplace-style provider sponsorships or commercial presets.

## Repository Layout

```text
app/        Apple-native app shell plans and future SwiftUI source
gateway/    Go local gateway helper
docs/       architecture, roadmap, product decisions, handoff notes
examples/   public sample provider and Codex config files
scripts/    developer helper scripts
```

## Development

```bash
cd gateway
go test ./...
go run ./cmd/gateway -listen 127.0.0.1:19777
```

Then in another terminal:

```bash
curl http://127.0.0.1:19777/healthz
curl http://127.0.0.1:19777/v1/models
```

