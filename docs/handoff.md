# RelayKit Handoff

## Public Status

RelayKit is a local macOS menu-bar app plus bundled gateway for bridging Codex-compatible clients to official and user-configured provider routes. The repository should stay public-safe: examples, tests, and smoke fixtures use demo providers, loopback servers, or `https://example.test`; real provider details belong only in a user's local App Support config.

Current product scope:

- `app/`: SwiftUI/AppKit menu-bar shell, provider form, Keychain references, usage view, settings, and bundled gateway lifecycle.
- `gateway/`: local HTTP/WebSocket gateway, model catalog, provider adapters, official credential reference support, and sanitized usage events.
- `scripts/`: public-safe smoke/proof scripts that use isolated state and loopback ports.
- `docs/`: public product, engineering, beta, and release-readiness notes.

## Public Boundary

Do not commit private provider names, real provider domains, API keys, bearer tokens, copied `auth.json`, Keychain item names from a real machine, user screenshots with private data, or local usage logs.

Validation must not mutate shared Codex state:

- Do not write `~/.codex/config.toml`.
- Do not write or copy `~/.codex/auth.json`.
- Do not touch `~/Library/LaunchAgents/*`.
- Do not start legacy `agent-local-gateway`, tunnels, or bridges.
- Do not bind `127.0.0.1:18787`.

The normal RelayKit App gateway path listens on `127.0.0.1:19777`. Isolated proof scripts may choose random loopback ports so they do not interfere with the app or shared services.

## Current Verification Commands

Run these before claiming the beta candidate is ready:

```bash
cd app && swift build
cd app && swift run RelayKitAppValidationTests
cd gateway && go test ./... -count=1
cd gateway && go vet ./...
cd gateway && test -z "$(gofmt -l .)"
./scripts/menu-bar-e2e-smoke.sh
./scripts/codex-desktop-acceptance.sh
./scripts/full-merged-catalog-proof.sh
git diff --check
```

Also run the scans listed in `docs/public-boundary-checklist.md`.

## Proof Layers

Public-safe scripts:

- `scripts/menu-bar-e2e-smoke.sh`: launches the local app with isolated fixtures, verifies the Connect/Usage/Settings product surface, and writes evidence to `dist/ui-smoke/`.
- `scripts/codex-desktop-acceptance.sh`: builds an isolated Codex config/catalog around a loopback gateway and fake/demo provider contract.
- `scripts/full-merged-catalog-proof.sh`: proves official + demo provider catalog merge and request routing with loopback upstreams.

Private/local real-provider proof scripts are kept out of tracked public files under ignored local paths such as `scripts/private/`. They may be useful on one developer machine, but they are not the public default contract.

## Beta Boundary

`./script/build_app_bundle.sh --verify` builds and verifies the app bundle without opening the GUI. `./script/package_release.sh --verify` produces `dist/RelayKitApp-local.zip` through that headless path. This is an ad-hoc signed local beta artifact for bundle integrity only, not a Developer ID signed or notarized public release.

Current release status:

- local beta: ready.
- open-source public-safe: ready.
- pre-signed release pipeline: ready.
- signed beta: blocked by Apple Developer Program approval.
- public release: not complete.
- updater runtime: deferred until a signed and notarized artifact exists.

Blocked signed beta reason: external Apple approval pending. Current evidence must be preserved:

- Apple Developer Account still shows membership pending /待处理.
- Certificates page shows Access Unavailable.
- `security find-identity -p codesigning -v | grep "Developer ID Application"` has no output on this Mac.
- `./script/package_signed_release.sh` exits 64 when `RELAYKIT_SIGNING_IDENTITY`, `RELAYKIT_NOTARYTOOL_PROFILE`, or `RELAYKIT_APPLE_TEAM_ID` is missing.
- `dist/github-release/v<version>/RelayKitApp-<version>-signed.zip`, its `.sha256`, and `dist/RelayKitApp-notary.zip` must not exist after that failure.

Do not describe the local ad-hoc package as a signed beta. Do not mock notarization success.

While Apple approval is pending, the active goal is `pre-signed beta readiness while Apple approval pending`: keep local beta, public-safe checks, release dry-runs, fail-fast signed packaging, GitHub Release draft structure, checksum naming, version bump documentation, and resume steps ready. Do not implement updater runtime, Sparkle, Tauri updater, Connect-page changes, gateway routing changes, or model adapter changes in this lane.

Apple approval resume checklist:

1. Confirm `security find-identity -p codesigning -v | grep "Developer ID Application"` finds the Developer ID Application identity.
2. Store notarization credentials with `xcrun notarytool store-credentials` outside git.
3. Export `RELAYKIT_SIGNING_IDENTITY`, `RELAYKIT_NOTARYTOOL_PROFILE`, `RELAYKIT_APPLE_TEAM_ID`, and `RELAYKIT_GITHUB_REPO`.
4. Run `./script/package_signed_release.sh`.
5. Verify `codesign --verify --deep --strict --verbose=4 dist/RelayKitApp.app`, `spctl -a -vvv -t exec dist/RelayKitApp.app`, and `xcrun stapler validate dist/RelayKitApp.app`.
6. Install dogfood from the signed zip, not from the repo checkout.
7. Create the GitHub Release draft with `./script/create_github_release_draft.sh`.

Versioning, install/uninstall instructions, privacy docs, updater policy, and the signed package script are reserved in `docs/release-readiness.md`, `docs/update-policy.md`, and `docs/updater-readiness.md`.

## User Feedback Loop

The next useful milestone is a small real-user beta, not more private machine proof. Use:

- `docs/beta-test-guide.md` for install, provider setup, local verification, and cleanup.
- `docs/feedback-template.md` for structured feedback without asking users to share keys, tokens, provider base URLs, or raw private logs.

## Cleanup

Local generated artifacts are ignored:

- `dist/`
- `docs/private/`
- `scripts/private/`
- `local-conversation-page-*.js`
- `local-conversation-thread-*.js`
- `remote-conversation-page-*.js`

To reset local proof state:

```bash
pkill -x RelayKitApp.bin || true
pkill -f 'RelayKitApp.app/Contents/MacOS/relay' || true
rm -rf "$HOME/Library/Application Support/RelayKit/DesktopProof"
```

Only delete broader `~/Library/Application Support/RelayKit` data when you intentionally want to remove local RelayKit provider configuration and usage history.
