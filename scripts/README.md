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

When sequencing zip dogfood and Desktop route proof against one artifact, set `RELAYKIT_DOGFOOD_REUSE_CURRENT_ZIP=1` for `scripts/local-beta-dogfood-smoke.sh` after the zip has already been built and verified. The default remains `0`, which rebuilds the package; unsupported values fail closed.

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

## Local Beta Dogfood

```bash
./scripts/local-beta-dogfood-smoke.sh
```

The dogfood smoke rebuilds `dist/RelayKitApp-local.zip`, extracts it under `dist/dogfood-local-beta/install/`, and launches that extracted app through LaunchServices with its normal lifecycle. It records the current zip hash/build time/extracted path, drives Connect/Settings/Usage/provider setup through exact AX identities, reopens the same extracted app, re-probes the saved provider, and captures RelayKit-owned WindowServer windows under `dist/dogfood-local-beta/`. Gatekeeper rejection is expected for this local ad-hoc beta and is recorded as friction, not as signed beta success.

The provider lane is fixture plumbing only. It verifies Keychain persistence, Detect models, Test connection, Use reachable, model filtering, actionable base URL/key/model errors, restart persistence, real right-click Quit, and bounded release of port `19777`; it does not claim real provider model compatibility. For App-owned launches, RelayKit reads referenced credentials with Security.framework and sends them once to the bundled gateway through an anonymous stdin pipe. The gateway keeps them in memory, and the harness never reads or rewrites the item with `/usr/bin/security`.

## Codex Desktop Route Proof

```bash
./scripts/codex-desktop-manual-proof.sh --setup-only
./scripts/codex-desktop-manual-proof-test.sh
```

The intended standard live path is one explicitly authorized invocation of the locked harness. Its caller creates a `0700` temporary directory, writes private query and scenario files with mode `0600`, and invokes the interface with no human input:

```bash
RELAYKIT_DESKTOP_PROOF_REUSE_CURRENT_ZIP=1 \
RELAYKIT_DESKTOP_PROOF_REUSE_EXTRACTED_APP=1 \
  ./scripts/codex-desktop-manual-proof.sh run-auto --scenario /absolute/path/scenario.json
```

The project Skill `$relaykit-desktop-query` is a smaller one-query dispatcher. It passes one model plus one private `0600` query file to a configured backend; it does not aggregate stages and cannot produce `automated_gui_complete` by itself.

The reuse flags are mandatory for harness/test-only reruns. The harness verifies that the existing extracted App is byte-identical to the fixed zip and still runs codesign verification; a mismatch fails closed. Record the zip SHA before and after the run and do not invoke `package_release.sh` for an evidence/assertion-only change.

Evidence separates `product_artifact_sha256`, `harness_sha256`, and `scenario_sha256`, with before/after/unchanged fields for every mutable proof layer. The run fails closed if the zip, harness, AX driver, private scenario, or product source changes while evidence is being collected. `source_snapshot_sha256_*` covers product package inputs only; `harness_sha256` covers the proof script plus AX driver. These hashes are independent: changing the harness requires a new proof run, not a new product package.

The automated path becomes accepted only after a fresh four-stage run exits `0` and its current evidence records `desktop_gui_route_proof=automated_gui_complete` plus `human_intervention_count=0`. Separate custom/diagnostic runs cannot be aggregated into that result. A single GUI stage may produce multiple upstream usage events; all matching events must be completed/200, and the unique rollout/thread/marker binding proves one GUI submission. Custom completion preserves last-route/custom evidence without replacing the reserved full-standard last-complete slot. Accessibility permission, authenticated Desktop state, and repository-external provider configuration are one-time prerequisites; after they are present, the standard run must not ask anyone to select a model, paste or type a query, click Send, or press Enter.

The current accepted local result is preserved in `dist/codex-desktop-manual-proof/evidence.json`, `dist/codex-desktop-manual-proof-last-route/evidence.json`, and `dist/codex-desktop-manual-proof-last-complete/evidence.json`. All three bind product artifact `f81b7ce...`, harness `97e685f...`, and private scenario `334288c...` to one zero-human four-stage run. These ignored artifacts are current-machine evidence, not checked-in fixtures.

The default manual entry remains a compatibility path:

```bash
RELAYKIT_DESKTOP_PROOF_REAL_PROVIDER_CONFIG="$HOME/path/to/local-providers.json" \
RELAYKIT_DESKTOP_PROOF_PUBLIC_MODEL_ID="public/provider-model-id" \
  ./scripts/codex-desktop-manual-proof.sh
./scripts/codex-desktop-manual-proof.sh cleanup
```

The proof harness creates isolated state under `~/Library/Application Support/RelayKit/DesktopProof/`, generates an isolated `CODEX_HOME/config.toml`, starts RelayKit on a random non-18787/non-19777 loopback port, and writes redacted evidence under `dist/codex-desktop-manual-proof/`. `--setup-only` verifies merged official + demo provider picker data without opening Codex Desktop. The compatibility mode requires an ignored or repository-external local provider config with no inline secret plus one selected public model id, discovers Codex Desktop by bundle id `com.openai.codex`, launches it with isolated HOME/CODEX_HOME/user data under `sandbox-exec`, and waits for manual requests. It clears isolated usage at run start, binds screenshots to one verified isolated PID/window id, and derives tool-call/output plus raw-protocol checks from current-run isolated rollout files without exporting request or response bodies. Only attempts with current-run usage can replace the preserved route-evidence directories, and their process-bound screenshot directory is preserved with the evidence. It never copies global Codex auth files.

Unsandboxed Desktop proof is disabled and fails closed. The sandbox denies writes to the physical global `.codex` tree, Codex/OpenAI Application Support directories, Codex/CUA preference files, LaunchAgents, and legacy gateway config while allowing the isolated DesktopProof tree. Global config/auth signatures and SHA-256, Codex `notify`, app/gateway source snapshot, or tracked harness changes fail the run with no repair/write fallback. Dedicated DesktopProof Keychain fixtures are removed only through the extracted RelayKit App code identity, never through `/usr/bin/security`. The self-test executes real `sandbox-exec` writes against every protected path, covers the global/source/harness guards and route failure branches, derives current-run rollout tool evidence, and verifies bounded cleanup when Electron ignores `SIGTERM`.

Validation cadence is tiered:

- Product inputs (`app/Sources/**`, `gateway/**`, bundled resources) get focused tests first; package and full GUI proof run once after the coherent root-cause group is complete.
- Harness/test inputs (`scripts/codex-desktop-*`, AX driver, screenshot/evidence assertions) never rebuild the package and always reuse the fixed zip/extracted App.
- Docs-only changes run documentation, public-boundary, and diff checks without building, packaging, or launching GUI.

## Diagnostics

```bash
./scripts/export-diagnostics.sh
./scripts/export-diagnostics-test.sh
```

The diagnostics export writes redacted aggregate state under `dist/diagnostics/`: app version, bundle id, gateway port/health, provider/model counts, usage aggregates, and allowlisted recent error types. Unknown labels become `other`, and a failed sensitive-content scan removes the diagnostics payload. The self-test injects private URL, Keychain, header, request/response, provider, and error-label sentinels and proves none are exported.

## Direct Replacement Check

```bash
RELAYKIT_ACCEPTANCE_URL=http://127.0.0.1:18787 ./scripts/direct-replacement-check.sh
```

The direct replacement check is read-only. It verifies the configured listener is not `agent-local-gateway` or a bridge process, then checks `/healthz` and the Codex-compatible `/v1/models.models` catalog shape. It does not stop services, edit Codex config, or read provider credentials.
