# RelayKit Mac App

The Mac app is a SwiftUI shell around the gateway helper.

## Build

```bash
cd gateway
go build -o bin/relaykit-gateway ./cmd/gateway
cd app
swift build
```

## Run

```bash
cd app
swift run RelayKitApp
```

The development app expects a gateway binary at `../gateway/bin/relaykit-gateway` and starts it with:

```bash
../gateway/bin/relaykit-gateway -listen 127.0.0.1:19777 -config <provider-config-path>
```

## Current MVP

- start and stop the gateway process launched by this app;
- show gateway status;
- call `/healthz`;
- call `/v1/models` and list model IDs;
- activate Codex config through the gateway CLI with explicit `-source` and `-target` paths.

## Not In This Slice

- Keychain credential storage;
- LaunchAgent install;
- provider editing;
- log tail;
- signing, notarization, or release packaging.
