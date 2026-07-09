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
./script/build_app_bundle.sh --verify
```

The build script creates `dist/RelayKitApp.app`, ad-hoc signs the bundled `relay` helper and app bundle, verifies bundle structure and code signature, and runs the bundled gateway verifier. It does not open the GUI app.

```bash
./script/package_release.sh --verify
```

The package script builds the local app bundle through the headless build path, writes `dist/RelayKitApp-local.zip`, extracts it under `dist/verify-release/`, and verifies the extracted bundled gateway plus public demo provider and Codex config examples without opening the GUI app. It does not Developer ID sign, notarize, publish, or upload anything.

## Signed Beta Package

```bash
RELAYKIT_SIGNING_IDENTITY="Developer ID Application: Example Team (TEAMID)" \
RELAYKIT_NOTARYTOOL_PROFILE="relaykit-notary" \
RELAYKIT_APPLE_TEAM_ID="TEAMID" \
./script/package_signed_release.sh
```

The signed package script requires external Apple distribution credentials. Without them it exits before signing with `missing Developer ID signing identity / notarization credentials` and does not create `dist/github-release/v<version>/RelayKitApp-<version>-signed.zip`.

When credentials are present, the script builds the complete bundle, signs the bundled `relay` helper first, signs `RelayKitApp.app` with hardened runtime, submits to notarization, staples, validates, and emits GitHub Release-ready zip plus checksum files.

Auto-updater runtime work is intentionally not part of this script. Sparkle 2/appcast policy is documented in `docs/update-policy.md` and remains blocked until a real signed beta passes.

## GitHub Release Draft

```bash
RELAYKIT_GITHUB_REPO=owner/repo ./script/create_github_release_draft.sh
```

The draft script requires an existing signed zip and checksum from `package_signed_release.sh`. It re-extracts the zip, verifies `codesign`, `spctl`, and `stapler`, writes local release notes under `dist/github-release/v<version>/`, then creates a GitHub draft release with the signed zip and checksum. It does not publish an appcast or Sparkle feed.

## Public Boundary Check

```bash
./scripts/public-boundary-check.sh
```

The check scans tracked files for private provider references, credential-shaped content, auth/log artifacts, and accidentally tracked private/build paths.

## Menu-Bar UI Smoke

```bash
./scripts/menu-bar-e2e-smoke.sh
```

The UI smoke launches `dist/RelayKitApp.app` through LaunchServices, captures the menu-bar popover and provider sheet under `dist/ui-smoke/`, verifies redacted local catalog/source grouping, Settings state including Light appearance persistence, provider modal fields, and cleans up RelayKit-owned app/helper processes.

## Direct Replacement Check

```bash
RELAYKIT_ACCEPTANCE_URL=http://127.0.0.1:18787 ./scripts/direct-replacement-check.sh
```

The direct replacement check is read-only. It verifies the configured listener is not `agent-local-gateway` or a bridge process, then checks `/healthz` and the Codex-compatible `/v1/models.models` catalog shape. It does not stop services, edit Codex config, or read provider credentials.
