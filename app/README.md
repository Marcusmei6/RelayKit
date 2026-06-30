# RelayKit Mac App

The Mac app is a SwiftUI shell around the gateway helper.

## Build

```bash
cd gateway
go build -o bin/relay ./cmd/gateway
cd ../app
swift build
```

## Run

```bash
cd app
swift run RelayKitApp
```

The development app expects a gateway binary at `../gateway/bin/relay` and starts it with:

```bash
../gateway/bin/relay -listen 127.0.0.1:19777 -config <provider-config-path>
```

## Current MVP

- start and stop the gateway process launched by this app;
- show gateway status;
- call `/healthz`;
- call `/v1/models` and list model IDs;
- activate Codex config through the gateway CLI with explicit `-source` and `-target` paths.
- remember the last provider config path locally with `UserDefaults`.
- show local usage summaries from an explicit JSONL path.
- load and save explicit provider config JSON after local validation and backup.

## Smoke

From the repository root:

```bash
./scripts/local-alpha-smoke.sh
```

The smoke also runs `swift run RelayKitAppValidationTests`, which checks provider config validation rejects credential fields and base URLs with userinfo, query strings, or fragments.

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
- provider credential editing;
- signing, notarization, or release packaging.
