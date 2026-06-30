# Scripts

Keep scripts small and local-development focused.

Allowed examples:

- build helper;
- run local smoke test;
- install/uninstall local user LaunchAgents for RelayKit-owned helper state;
- package Mac app once the app exists.

Do not add scripts that depend on private infrastructure.

## Local Helper

```bash
cd gateway
go build -o bin/relay ./cmd/gateway
cd ..
./scripts/relaykit-helper.sh install --config "$PWD/examples/providers.example.json"
./scripts/relaykit-helper.sh status
./scripts/relaykit-helper.sh logs --lines 80
./scripts/relaykit-helper.sh uninstall
```

The helper script writes only `~/Library/LaunchAgents/dev.relaykit.gateway.plist`, requires an explicit provider config path, and stores absolute binary/config paths in the plist. Phase 4.5 keeps the listen address fixed at `127.0.0.1:19777` and writes helper stdout/stderr to `/tmp/relay.{out,err}.log`.
`logs` reads those local helper stdout/stderr files only; it does not upload, redact, or collect usage events.

## Local Release Package

```bash
./script/package_release.sh --verify
```

The package script builds the local app bundle, writes `dist/RelayKitApp-local.zip`, extracts it under `dist/verify-release/`, and verifies the extracted bundled gateway plus public demo provider and Codex config examples. It does not sign, notarize, publish, or upload anything.
