# RelayKit Mac App

The Mac app is a menu-bar resident SwiftUI/AppKit control center around the gateway helper.

## Build

```bash
cd gateway
go build -o bin/relay ./cmd/gateway
cd ../app
swift build
```

## Run

From the repository root:

```bash
./script/build_and_run.sh
```

This builds `gateway/bin/relay`, bundles it inside `dist/RelayKitApp.app`, and opens the menu-bar app. The app starts with the bundled gateway and bundled public no-secret demo provider config.

For a direct SwiftPM run:

```bash
cd app
swift run RelayKitApp
```

The bundled app starts its bundled `relay` helper. A direct SwiftPM run falls back to `../gateway/bin/relay` and starts it with:

```bash
../gateway/bin/relay -listen 127.0.0.1:19777 -config <provider-config-path>
```

## Current MVP

- start and stop the gateway process launched by this app;
- live in the menu bar and open a compact popover/control-center;
- show gateway status;
- call `/healthz`;
- call `/v1/models` and show redacted local catalog/source grouping;
- activate Codex config through the gateway CLI with explicit `-source` and `-target` paths.
- remember the last provider config path locally with `UserDefaults`.
- persist Appearance (`System`, `Light`, `Dark`) and refresh Launch at login from macOS `SMAppService` status.
- show local usage summaries from an explicit JSONL path.
- load and save explicit provider config JSON after local validation and backup.
- add provider metadata through a form that stores routing/catalog/capability fields and credential references only.

## Smoke

From the repository root:

```bash
./scripts/local-alpha-smoke.sh
./scripts/menu-bar-e2e-smoke.sh
./scripts/codex-e2e-smoke.sh
```

The smoke also checks explicit Codex config activation, local usage summary, temporary LaunchAgent install/status/health/logs/uninstall, bundled app gateway startup, and `swift run RelayKitAppValidationTests`, which checks provider config validation rejects credential fields and base/catalog URLs with userinfo, query strings, fragments, or unsupported catalog schemes.
The menu-bar smoke launches the packaged app through LaunchServices in UI-smoke mode and captures `接入`, `Usage`, `设置`, Light Settings, and provider sheet screenshots under `dist/ui-smoke/`. Connect evidence records only redacted catalog/source counts, not raw model IDs.
The Codex E2E smoke uses only temporary `CODEX_HOME` and `HOME` directories, points Codex at the RelayKit loopback gateway, and writes redacted evidence under `dist/codex-e2e/`.

## Local Release Package

From the repository root:

```bash
./script/package_release.sh --verify
```

This writes `dist/RelayKitApp-local.zip`, extracts it under `dist/verify-release/`, confirms the extracted app contains `Contents/MacOS/relay` plus the bundled public demo provider and Codex config examples, opens the extracted app, and verifies the extracted bundled gateway. It does not sign, notarize, publish, or write a real Codex config.

## Durable Local Helper

The app Start/Stop buttons control the foreground helper process launched by the app. For a local user LaunchAgent flow, use the repo script from the repository root:

```bash
cd gateway
go build -o bin/relay ./cmd/gateway
cd ..
./scripts/relaykit-helper.sh install --config "$PWD/examples/providers.example.json"
./scripts/relaykit-helper.sh status
./scripts/relaykit-helper.sh logs --lines 80
./scripts/relaykit-helper.sh uninstall
```

The script writes only `~/Library/LaunchAgents/dev.relaykit.gateway.plist`, requires an explicit provider config path, and stores absolute binary/config paths in the plist. Phase 4.5 keeps the listen address fixed at `127.0.0.1:19777` and writes helper stdout/stderr to `/tmp/relay.{out,err}.log`.
`logs` reads those local helper stdout/stderr files only; it does not upload, redact, or collect usage events.

## Not In This Slice

- Keychain credential storage;
- executable Keychain/key-file credential resolution;
- signing, notarization, or public distribution.
