# Scripts

Keep scripts small and local-development focused.

Allowed examples:

- build helper;
- run local smoke test;
- install/uninstall local user LaunchAgents for RelayKit-owned helper state;
- package Mac app once the app exists.

Do not add scripts that depend on private infrastructure.

## GitHub Actions CI

The repository defines four public-safe workflows under `.github/workflows/`. Before a first push, run the focused workflow contract locally:

```bash
bash -n scripts/github-actions-contract-test.sh
./scripts/github-actions-contract-test.sh
./scripts/github-required-checks-test.sh
```

The contract checks full-SHA action pins, read-only permissions, concurrency cancellation, job timeouts, required commands, and the absence of secrets, live-provider, shared-runtime, signing, and release behavior. The workflows produce no uploaded artifacts. They are GitHub-ready but have not run on GitHub because this checkout has no remote.

On the first separately authorized push, confirm these exact checks appear: `Fast Public Boundary`, `Fast Shell Contracts`, `Fast Go Quality`, `macOS App`, `macOS Runtime Safety`, and `Protocol Contract`. Require all six on `main` only after their first GitHub run passes.

After a commit has run on GitHub, write the public-safe same-SHA evidence used by signed packaging:

```bash
./scripts/github-required-checks.sh \
  --repo owner/repo \
  --sha 0123456789abcdef0123456789abcdef01234567 \
  --output /absolute/path/ci-evidence.json
```

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

When sequencing dogfood and Desktop route proof against one immutable artifact, set `RELAYKIT_DOGFOOD_ZIP_PATH` to the absolute verified zip path. An explicit path skips the unrelated local package rebuild by default; `RELAYKIT_DOGFOOD_REUSE_CURRENT_ZIP=0` can request a rebuild only when that is intentional. Without the path override, dogfood keeps the local `dist/RelayKitApp-local.zip` default; relative overrides fail closed.

## Signed Beta Package

```bash
RELAYKIT_SIGNING_IDENTITY="Developer ID Application: Example Team (TEAMID)" \
RELAYKIT_NOTARYTOOL_PROFILE="relaykit-notary" \
RELAYKIT_APPLE_TEAM_ID="TEAMID" \
RELAYKIT_CI_EVIDENCE_PATH=/absolute/path/ci-evidence.json \
RELAYKIT_APP_VERSION=0.1.6 \
RELAYKIT_BUILD_NUMBER=17 \
./script/package_signed_release.sh
```

The signed package script requires external Apple distribution credentials and an absolute CI evidence file for the clean current HEAD. Without either it fails closed and does not finalize `dist/github-release/v<version>/RelayKitApp-<version>-signed.zip`.

When inputs are present, the script freezes the source commit and archive hash, builds the complete bundle itself, copies that exact build into a private package directory, and rechecks the source identity before and after signing/notarization. It signs the bundled `relay` helper first, signs `RelayKitApp.app` with hardened runtime, submits to notarization, staples, validates, and emits one non-writable three-file release directory: the signed zip, its checksum, and a manifest binding the source SHA, clean state, version/build, zip/App-tree/App-executable/helper hashes, and hosted check/run evidence. Finalizing an externally prepared App is restricted to offline test mode.

Auto-updater runtime work is intentionally not part of this script. Sparkle 2/appcast policy is documented in `docs/update-policy.md`; the signed-beta prerequisite passed, but the updater runtime and feed remain unimplemented.

## GitHub Release Draft

```bash
RELAYKIT_GITHUB_REPO=owner/repo ./script/create_github_release_draft.sh
```

The draft script requires the exact three-file output from `package_signed_release.sh`. It copies those files to a private snapshot, re-extracts and verifies that snapshot with absolute Apple tool paths, freshly queries the manifest's exact source SHA, and requires the new check evidence to match the embedded evidence. Existing releases and tags are rejected. The script creates a new lightweight tag at the source SHA and uploads the same snapshot bytes to a GitHub draft release; an ambiguous remote failure is reconciled by a run marker, removing only that run's draft and the exact expected tag. Cleanup failures stay visible and retain coherent remote state. The script never publishes the release or an appcast.

## Public Boundary Check

```bash
./scripts/public-boundary-check.sh
```

The check scans tracked files for private provider references, credential-shaped content, auth/log artifacts, machine-local paths or identifiers, and accidentally tracked private/build paths. `./scripts/public-boundary-check-test.sh` locks the tracked-only rule, fake-sentinel policy, and fail-closed private/build path behavior.

## Menu-Bar UI Smoke

```bash
./scripts/menu-bar-e2e-smoke.sh
```

The UI smoke launches `dist/RelayKitApp.app` through LaunchServices, captures the menu-bar popover and provider sheet under `dist/ui-smoke/`, verifies redacted local catalog/source grouping, Settings state including Light appearance persistence, provider modal fields, and cleans up RelayKit-owned app/helper processes.

After `./script/package_release.sh --verify` has produced the final extracted bundle, reuse it without rebuilding:

```bash
RELAYKIT_REUSE_FINAL_BUNDLE=1 \
RELAYKIT_APP_BUNDLE=dist/verify-release/RelayKitApp.app \
  ./scripts/menu-bar-e2e-smoke.sh
```

Reuse mode verifies the supplied bundle with `codesign` and fails if the App or bundled helper executable is missing.

## RC1 Public Proofs

```bash
RELAYKIT_RC1_APP_BUNDLE=dist/verify-release/RelayKitApp.app \
  ./scripts/rc1-native-responses-proof.sh
RELAYKIT_RC1_APP_BUNDLE=dist/verify-release/RelayKitApp.app \
  ./scripts/rc1-helper-lifecycle-proof.sh
```

The Wave 2 native proof starts an ordinary extracted App against an empty isolated provider destination, creates an `openai_responses` provider through exact PID/window-bound AX, verifies a Keychain-reference-only saved config, relaunches the same App, verifies restored protocol/URL/model/saved-key state, and starts the bundled Gateway through the UI. It then attaches an isolated Codex Desktop to that App-owned Gateway for exactly three one-submit stages: plain text, native Markdown, and an exact `printf '<marker>\n'; pwd` tool roundtrip. The loopback fixture supports models, non-streaming Responses, SSE, Markdown, `function_call`, and `function_call_output`; its log contains only run id, method, path, model-rewrite/auth booleans, and event types.

Wave 1 focused contracts passed. Wave 2 harness, fixture, manifest, and negative-branch contracts are implemented, but this implementation lane does not claim a fresh App/Desktop/package E2E. The live proof and immutable phase-B manifest must be produced later by `relaykit_test`; historical `observation_failed_*` evidence remains failed and cannot satisfy the manifest. The lifecycle proof remains separate: it starts the same App-owned helper, kills the App without graceful cleanup, and requires the helper to exit and release `19777`. Neither proof reads real credentials, mutates global Codex files, controls LaunchAgents, or changes the shared `18787` listener.

## Runtime Safety Fault Injection

```bash
./scripts/runtime-safety-fault-injection-test.sh
./scripts/runtime-safety-fault-injection.sh
./scripts/runtime-safety-launchd-proof-test.sh
./scripts/runtime-safety-launchd-proof.sh
```

The first command is an offline contract test. The targeted harness builds the current source in a temporary isolated layout, exercises managed App/helper failure cases on one random loopback port, and writes only redacted evidence to `dist/runtime-safety/evidence.json`. It treats `18787`, installed `19777`, global Codex files, and user LaunchAgents as read-only guards.

The launchd proof has a separate offline contract and an explicitly authorized live gate. The live gate bootstraps one uniquely labeled temporary job from `/tmp`, uses two random non-protected ports, exercises graceful release, App loss, helper crash, and simultaneous App/helper loss, then boots out that exact job. Its evidence records config recovery, cached-client continuity, new-client direct routing, helper restart/retention, mode, global guards, and cleanup. It never writes `~/Library/LaunchAgents` and must not run against installed `19777` or `18787`.

Focused non-live contracts are:

```bash
./scripts/codex-desktop-ax-driver-test.sh
./scripts/codex-desktop-manual-proof-test.sh
./scripts/rc1-native-responses-proof-fixture-test.sh
./scripts/rc1-native-responses-manifest-test.sh
./scripts/rc1-native-responses-proof-test.sh
```

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

The project Skill `$relaykit-desktop-query` is a smaller one-query dispatcher selected only as a high-risk validation leaf. It accepts `plain`, `markdown`, or `tool`, requires caller-pinned catalog SHA-256, setup id, session id, and artifact SHA-256 matching the catalog's `relaykit_lineage`, and returns redacted model/submission/evidence metadata. The manual-proof app-server producer writes that lineage atomically into its current catalog evidence. Official models use a targeted one-shot App-first lifecycle with an official-only temporary gateway config, so they do not require provider setup. Provider models retain the compatibility full-harness path and require an ignored local provider config. The Skill does not scan stale `dist` candidates, choose validation scope, aggregate stages, or produce `automated_gui_complete` by itself.

The reuse flags are mandatory for harness/test-only reruns. The harness verifies that the existing extracted App is byte-identical to the fixed zip and still runs codesign verification; a mismatch fails closed. Record the zip SHA before and after the run and do not invoke `package_release.sh` for an evidence/assertion-only change.

Evidence separates `product_artifact_sha256`, `harness_sha256`, and `scenario_sha256`, with before/after/unchanged fields for every mutable proof layer. The run fails closed if the zip, harness, AX driver, private scenario, or product source changes while evidence is being collected. `source_snapshot_sha256_*` covers product package inputs only; `harness_sha256` covers the proof script plus AX driver. These hashes are independent: changing the harness requires a new proof run, not a new product package.

The automated path becomes accepted only after a fresh four-stage run exits `0` and its current evidence records `desktop_gui_route_proof=automated_gui_complete` plus `human_intervention_count=0`. Separate custom/diagnostic runs cannot be aggregated into that result. A single GUI stage may produce multiple upstream usage events; all matching events must be completed/200, and the unique rollout/thread/marker binding proves one GUI submission. Custom completion preserves last-route/custom evidence without replacing the reserved full-standard last-complete slot. Accessibility permission, authenticated Desktop state, and repository-external provider configuration are one-time prerequisites; after they are present, the standard run must not ask anyone to select a model, paste or type a query, click Send, or press Enter.

The current accepted local result is preserved in `dist/codex-desktop-manual-proof/evidence.json`, `dist/codex-desktop-manual-proof-last-route/evidence.json`, and `dist/codex-desktop-manual-proof-last-complete/evidence.json`. All three bind product artifact `f81b7ce...`, harness `97e685f...`, and private scenario `334288c...` to one zero-human four-stage run. These ignored artifacts are current-machine evidence, not checked-in fixtures.

For a future signed-package proof, set `RELAYKIT_DESKTOP_PROOF_ZIP_PATH=/absolute/path/RelayKitApp-<version>-signed.zip`. The harness skips the local rebuild, extracts that exact zip, and records its path and SHA-256 in current-run evidence.

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

## Changed-File Validation Fast Path

```bash
./scripts/relaykit-validate.sh --base <commit> --head <commit> --plan-only
./scripts/relaykit-validate.sh --base <commit> --head <commit> --worktree --plan-only
./scripts/relaykit-validate.sh --base <commit> --head <commit> --execute
./scripts/relaykit-validate.sh --plan-only --rc1
```

The selector emits changed files, change classes, selected and skipped commands, reasons, and explicit build/package/GUI/live/full booleans. Without `--worktree`, a dirty repository fails closed; with it, committed, staged, unstaged, untracked, and deleted paths are unioned. Deleted scripts and Agent TOML remain risk-classified but are not passed to syntax parsers. Project Agent config and workflow-contract changes select the workflow contract test. Docs, workflow, Skill, and harness changes remain on focused checks. Gateway paths select affected Go packages; ordinary App UI selects one Swift build/validation plus no-model menu smoke. Package and extracted-App dogfood are selected only by packaging inputs. A paid query requires both a justified high-risk class and `--live-query`; full four-stage E2E requires `--full`. Live/full failures record one attempt; safe local commands may run at most twice.

`--rc1` is a fixed profile, not another changed-file heuristic. It selects one package build followed by menu, native Responses, and helper lifecycle proof against the same extracted final bundle. It never selects a paid live query or the four-stage Desktop E2E.

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
