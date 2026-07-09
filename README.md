# RelayKit

RelayKit is a local model routing kit for agentic coding tools. The first target is OpenAI Codex compatibility, but the project name and architecture intentionally avoid locking the product to one client.

License: MIT.

## What It Is

RelayKit combines:

- a lightweight Apple-native Mac app for profiles, status, and local control;
- a portable local gateway helper for protocol translation and model routing;
- safe public configuration examples that never require private infrastructure.

RelayKit does not bundle private providers, does not collect cloud telemetry, and does not ask users to submit API keys, `auth.json`, raw logs, or screenshots containing private account/provider data.

## First Public Scope

- Local loopback gateway.
- Codex-compatible `/v1/models` and `/v1/responses` surfaces.
- OpenAI-compatible Chat Completions upstream adapter.
- Anthropic Messages upstream adapter.
- Generated model catalog for clients that support external catalogs.
- Local-only usage event log.
- Local LaunchAgent helper lifecycle for this checkout.
- Menu-bar resident SwiftUI/AppKit control-center app for gateway control, usage summaries, provider config editing without secrets, and real local settings.

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
./scripts/menu-bar-e2e-smoke.sh
./scripts/codex-e2e-smoke.sh
```

The alpha smoke builds the gateway and app, runs gateway tests/vet/format checks, verifies `/healthz` and `/v1/models`, checks explicit Codex config activation, checks local usage summary, temporarily exercises the LaunchAgent helper flow, verifies the bundled app gateway, and runs the app-side provider config validation executable. The menu-bar smoke launches the packaged app through LaunchServices, saves control-center screenshots under `dist/ui-smoke/`, checks the menu-bar popover, Settings state, Light appearance persistence, provider modal, and redacted local reference catalog grouping. The Codex E2E smoke uses a temporary `CODEX_HOME` and fake local upstream, routes `codex exec` through RelayKit, and writes redacted evidence under `dist/codex-e2e/`.

## Gateway Development

```bash
cd gateway
go test ./...
go build -o bin/relay ./cmd/gateway
./bin/relay -listen 127.0.0.1:19777 -config ../examples/providers.example.json
```

Then in another terminal:

```bash
curl http://127.0.0.1:19777/healthz
curl http://127.0.0.1:19777/v1/models
```

## Mac App

```bash
./script/build_and_run.sh
```

The run script builds `gateway/bin/relay`, bundles it inside `dist/RelayKitApp.app`, and opens the menu-bar app. The app defaults to the bundled gateway and bundled public no-secret demo config.

For a lower-level SwiftPM run:

```bash
cd gateway
go build -o bin/relay ./cmd/gateway
cd ../app
swift run RelayKitApp
```

The bundled app uses its bundled `relay` helper. A direct SwiftPM run falls back to `../gateway/bin/relay`.

## Local Release Package

```bash
./script/package_release.sh --verify
```

This creates `dist/RelayKitApp-local.zip`, extracts it locally, verifies `RelayKitApp.app/Contents/MacOS/relay` plus the bundled public demo provider and Codex config examples, opens the extracted app, and checks the extracted bundled gateway through `/healthz` and `/v1/models`. The package is ad-hoc signed only for local bundle integrity; it is not Developer ID signed or notarized.

Install and uninstall notes live in `docs/install-uninstall.md`. Privacy boundaries live in `docs/privacy.md`.

## Signed Beta Package

The signed beta flow is reserved but requires external Apple credentials:

```bash
RELAYKIT_SIGNING_IDENTITY="Developer ID Application: Example Team (TEAMID)" \
RELAYKIT_NOTARYTOOL_PROFILE="relaykit-notary" \
RELAYKIT_APPLE_TEAM_ID="TEAMID" \
./script/package_signed_release.sh
```

Without those values the script fails with `missing Developer ID signing identity / notarization credentials` and does not produce a misleading signed artifact. Signing runs after the full bundle is assembled, signs the bundled `relay` helper first, then signs `RelayKitApp.app` with hardened runtime, submits to notarization, staples, validates, and writes GitHub Release-ready assets under `dist/github-release/v<version>/`.

`RELAYKIT_APP_VERSION` and `RELAYKIT_BUILD_NUMBER` are reserved now and flow into `CFBundleShortVersionString` and `CFBundleVersion`. Auto-updater support, including Sparkle 2/appcast work, is intentionally deferred until after a real signed beta exists.

## Durable Local Helper

```bash
cd gateway
go build -o bin/relay ./cmd/gateway
cd ..
./scripts/relaykit-helper.sh install --config "$PWD/examples/providers.example.json"
./scripts/relaykit-helper.sh status
./scripts/relaykit-helper.sh logs --lines 80
./scripts/relaykit-helper.sh uninstall
```

The helper script affects only `~/Library/LaunchAgents/dev.relaykit.gateway.plist` and uses explicit provider config paths.

## Public Release Readiness

Before any public push or release:

```bash
./scripts/public-boundary-check.sh
```

Then follow `docs/public-boundary-checklist.md` and `docs/release-readiness.md`. Checked-in `.codex/agents/*.toml` files use public model defaults; keep private/local routing in untracked machine-local overrides only.
