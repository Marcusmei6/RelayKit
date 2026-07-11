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
./scripts/public-boundary-check.sh
./script/build_app_bundle.sh --verify
./script/package_release.sh --verify
./scripts/menu-bar-e2e-smoke.sh
./scripts/menu-bar-e2e-smoke-test.sh
./scripts/local-beta-dogfood-smoke.sh
./scripts/local-beta-dogfood-smoke-test.sh
./scripts/export-diagnostics.sh
./scripts/export-diagnostics-test.sh
./scripts/codex-desktop-acceptance.sh
./scripts/codex-desktop-manual-proof-test.sh
./scripts/full-merged-catalog-proof.sh
git diff --check
```

Also run the scans listed in `docs/public-boundary-checklist.md`.

## Proof Layers

Public-safe scripts:

- `scripts/menu-bar-e2e-smoke.sh`: launches the local app with isolated fixtures, verifies the Connect/Usage/Settings product surface, and writes evidence to `dist/ui-smoke/`.
- `scripts/local-beta-dogfood-smoke.sh`: rebuilds `dist/RelayKitApp-local.zip`, extracts it under `dist/dogfood-local-beta/install/`, launches that extracted app bundle, records Gatekeeper rejection as expected local beta friction, and writes public-safe evidence/screenshots to `dist/dogfood-local-beta/`.
- `scripts/export-diagnostics.sh`: writes a redacted aggregate diagnostics bundle under `dist/diagnostics/` with version, bundle id, gateway health, provider/model counts, usage aggregate, and allowlisted recent error types. Unknown or contaminated error labels become `other`; a failed sensitive-content scan removes `diagnostics.json`. It must not export provider URLs, credentials, headers, raw request/response bodies, copied Codex auth files, or Keychain item names.
- `scripts/export-diagnostics-test.sh`: injects private URL, Keychain, header, request/response, provider, and error-label sentinels into isolated fixtures and proves none appear in the exported bundle.
- `scripts/codex-desktop-acceptance.sh`: builds an isolated Codex config/catalog around a loopback gateway and fake/demo provider contract.
- `scripts/codex-desktop-manual-proof.sh`: creates isolated state under `~/Library/Application Support/RelayKit/DesktopProof/` and launches isolated Codex Desktop for user-assisted GUI route proof. Fixture setup uses a random safe loopback port; the real App-first path uses the extracted RelayKit App's normal `19777` lifecycle and refuses to proceed if that port is already occupied. It discovers the current Desktop executable by bundle id `com.openai.codex`, uses the matching app-bundled `Contents/Resources/codex` catalog/app-server binary, preserves current official model metadata, and merges every configured provider model with its public display and upstream names. A default `sandbox-exec` profile denies writes to global Codex config/auth, and before/after global, source, plus harness hashes fail closed on any change. Setup-only proves official + demo provider picker data; full proof still requires real isolated Desktop requests and writes evidence to `dist/codex-desktop-manual-proof/`. Only attempts with current-run usage may replace `dist/codex-desktop-manual-proof-last-route/`, and their process-bound screenshots are preserved with the evidence.
- `scripts/codex-desktop-manual-proof-test.sh`: verifies Desktop executable and bundled CLI discovery, current official catalog preservation, full provider-model merging, official gateway allowlist synchronization, fail-closed global/source/harness state guards, last-route preservation, route outcome semantics, current-run tool evidence, interactive Desktop AX readiness, and bounded cleanup when an Electron process ignores `SIGTERM`.
- `scripts/full-merged-catalog-proof.sh`: proves official + demo provider catalog merge and request routing with loopback upstreams.

Private/local real-provider proof scripts are kept out of tracked public files under ignored local paths such as `scripts/private/`. They may be useful on one developer machine, but they are not the public default contract.

## Beta Boundary

`./script/build_app_bundle.sh --verify` builds and verifies the app bundle without opening the GUI. `./script/package_release.sh --verify` produces `dist/RelayKitApp-local.zip` through that headless path. This is an ad-hoc signed local beta artifact for bundle integrity only, not a Developer ID signed or notarized public release.

Current release status:

- local beta: ready.
- open-source public-safe: ready.
- local beta packaging pipeline: ready.
- signed beta scaffolding: present, blocked until real Apple distribution inputs exist.
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

While Apple approval is pending, the active goal is `RelayKit Beta Dogfood Hardening`: make the local ad-hoc beta usable, diagnosable, and feedback-ready without Developer ID signing. Do not implement updater runtime, Sparkle, Tauri updater, real signing, notarization, publishing, global Codex config/auth mutation, shared `18787` takeover, or legacy `agent-local-gateway` control in this lane.

Current dogfood status:

- The current full zip dogfood evidence is bound to `dist/RelayKitApp-local.zip` SHA-256 `10a0c25dd351c888f18f4476cc573e0f91f356ed6b7c4e4d4f7f46100cfc8b45`, built at `2026-07-11T07:49:00Z`. Evidence records the extracted app path and normal `/usr/bin/open` LaunchServices lifecycle; `RelayKitApp.bin --ui-smoke` is not used for the dogfood claim.
- The tracked dogfood harness now requires normal LaunchServices launch from the current extracted zip, exact AX actions, full fixture provider setup, reopen persistence, a fresh reachable-model re-probe, real right-click Quit, bounded `19777` release, and RelayKit-owned WindowServer screenshots.
- The current extracted App stores provider keys with Security.framework, reads only referenced Keychain items in the App process, and sends a versioned credential map to its bundled gateway once through an anonymous stdin pipe. The gateway keeps that map in memory and fails closed when an App-provided reference is absent; it does not fall back to `/usr/bin/security` in App mode. Standalone/headless gateway launches retain the existing local Keychain fallback.
- The current dogfood run proves Detect models, Test connection, Use reachable, failure filtering, actionable URL/key/model errors, right-click Quit, bounded `19777` release, provider persistence, masked Keychain state after reopen, and a fresh `1 available / 0 hidden` re-probe. The fixture Keychain setup is test preparation, not proof of real-user authorization.
- Eleven current-run WindowServer screenshots were reviewed image by image. They contain no black obstruction, unrelated Codex window, or Keychain authorization prompt; Usage is visibly labeled `fixture`, the reopened provider shows one available model, and the complete Quit menu is present.
- `connect-first-screen.png` and the other dogfood captures prove RelayKit App product state only. They must not be cited as current Codex request-route evidence.
- Fixture provider evidence proves catalog/picker/credential plumbing only. It does not prove a real provider model, tool call, or rich-text compatibility.
- Fresh diagnostics were regenerated after the implementation diff. `dist/diagnostics/redaction-scan.json` reports `passed=true`; the sentinel self-test proves private URL, Keychain, provider, header, request/response, and contaminated error-label values are not exported.
- Keep the older acceptance conclusion unchanged: P1a backend/data-source acceptance passed; P1b Desktop GUI picker/selection/route proof was blocked because there was no isolated authenticated Desktop entry. Do not keep forcing that old blocked goal or relabel it complete.

Current Desktop setup evidence:

- `dist/codex-desktop-acceptance/evidence.json` is current setup/plumbing evidence only. It proves a public-safe merged catalog, isolated app-server model listing, official/provider loopback routing contracts, unchanged global Codex signatures, and released `18787`/`19777`; its `acceptance_scope` is `public_safe_headless` and both Desktop GUI proof fields remain `not_attempted`.
- The real App-first harness uses the current Desktop-bundled Codex executable and the isolated account model cache, keeps the generated default at `gpt-5.5`, preserves current official metadata, and merges all configured provider models. It no longer promotes the stale bundled GPT-5.2 entry into the product picker; the gateway's typed unsupported-model response remains defensive behavior only.
- The completed `manual_user_only` run is bound to the same current zip SHA-256 `10a0c25dd351c888f18f4476cc573e0f91f356ed6b7c4e4d4f7f46100cfc8b45`, product source snapshot SHA-256 `2f2357543fe2df8fe24c64deea1dba8166516bbbb708d5a22d7cd51732360f42`, and harness SHA-256 `ca412014f62c54d777b31aa458a7a84f0101c88f2727f18dd779792cf56e4e79`. Its exact AX picker evidence includes GPT-5.6 Sol/Terra/Luna, GPT-5.5, GPT-5.4, GPT-5.4 Mini, GPT-5.3 Codex Spark, and both configured provider models; GPT-5.2 is absent.
- This picker result corrects the stale mid-run requirement that treated GPT-5.2 as a GUI acceptance stage. The four request stages are GPT-5.5, GPT-5.6 Luna, provider Markdown, and provider shell/tool.
- Current setup and route evidence remain separate: setup/plumbing is represented by headless acceptance and zip dogfood; real request/rendering is represented only by the completed manual Desktop proof below.

Last Desktop route evidence:

- `dist/codex-desktop-manual-proof/evidence.json` records the current fresh completed run started at `2026-07-11T07:48:55Z`. It has `route_proof_status=complete`, `manual_status=route_complete`, `usage_event_count=10`, Official GPT-5.5 and GPT-5.6 Luna completed/200 usage, and three completed/200 provider events.
- Process-bound screenshots for isolated Desktop PID `78193`, window `28497` prove visible GPT-5.5 and GPT-5.6 replies, rendered provider heading/list/table/bash/bold Markdown, and the provider tool block with the fresh marker. Current-run rollout evidence contains a matching `exec_command` function call/output with `Process exited with code 0`.
- The completed run records `mock_ok_used=false`, `old_usage_evidence_used=false`, no raw XML/`function_calls`, unchanged global config/auth/notify hashes, unchanged product source and manual harness hashes, and released `19777`/`18787`.
- `dist/codex-desktop-manual-proof-last-route/evidence.json` remains the automatically preserved prior incomplete attempt (`awaiting_provider_tool_request`, zip SHA-256 `aa7090cf...`). It is historical failure evidence only and must not be cited as the current completed route proof.

Manual proof rerun contract:

1. Run the harness in its default `manual_user_only` mode and keep its terminal open.
2. The harness/AX setup check verifies the current official plus configured provider model picker before route proof; do not ask the user to validate GPT-5.2.
3. Send the generated GPT-5.5 request, GPT-5.6 Luna request, provider Markdown request, and provider shell/tool request, waiting for each visible result before advancing the terminal stage.
4. Return to the proof terminal and press Enter after each stage. GUI completion requires process-bound screenshots, fresh completed/200 usage for both lanes, a matched function call plus output, correct Markdown/tool rendering, and no raw XML/`function_calls`.
5. The tool checkpoint regenerates current-run rollout evidence before evaluation and combines matching exit-zero evidence with the visible tool command/marker; localized Desktop success text is not treated as route success by itself.

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
./scripts/codex-desktop-manual-proof.sh cleanup
pkill -x RelayKitApp.bin || true
pkill -f 'RelayKitApp.app/Contents/MacOS/relay' || true
rm -rf "$HOME/Library/Application Support/RelayKit/DesktopProof"
```

Only delete broader `~/Library/Application Support/RelayKit` data when you intentionally want to remove local RelayKit provider configuration and usage history.
