# RelayKit Handoff

## Public Status

RelayKit is a local macOS menu-bar app plus bundled gateway for bridging Codex-compatible clients to official and user-configured provider routes. The repository should stay public-safe: examples, tests, and smoke fixtures use demo providers, loopback servers, or `https://example.test`; real provider details belong only in a user's local App Support config.

## Current Truth (2026-07-28, P0 runtime safety and GitHub-ready CI)

The runtime-safety candidate at `5992d6d` passed all eight fault cases. The fresh evidence is `dist/runtime-safety/evidence.json`; it binds source commit `5992d6d`, the tracked harness SHA-256, and the tracked harness-test SHA-256. Later CI/documentation-only commits do not replace that runtime candidate. This is a source-candidate result, not a new installed or distributed build. Installed Build 16 remains the historical/current shared runtime and was not stopped, replaced, rebuilt, signed, or otherwise touched by this lane. Build 17 signed beta remains the next distribution goal.

Four GitHub Actions workflows now define public-boundary, shell, Go, Swift/App, runtime-safety, and deterministic protocol gates. The checkout currently has no Git remote, so these workflows are GitHub-ready but have not run on GitHub and must not be described as GitHub-green.

When a public remote is created and the first branch is pushed in a separately authorized lane, protect `main` with these exact required checks:

- `Fast Gates / Public boundary`
- `Fast Gates / Shell contracts`
- `Fast Gates / Go test, vet, and format`
- `macOS App / Swift and headless package validation`
- `macOS Runtime Safety / Offline contract and fault harness`
- `Protocol Contract / Loopback adapters and Responses`

Suggested first-push sequence: create the public repository/remote, push `main`, confirm all six checks appear and pass on GitHub, then enable branch protection requiring those exact checks and an up-to-date branch. This lane does not create a remote, push, sign, package a release, or publish anything.

## Current Truth (2026-07-23, Codex 0.145 persistent Responses WebSocket and graceful quit)

The current Codex Desktop embedded CLI `0.145.0-alpha.30` keeps one Responses WebSocket open and serially reuses it. RelayKit previously closed the connection after every terminal response event, so the next turn on that same connection failed with `Broken pipe` or `Connection reset`.

The source fix gives one reader ownership of inbound frames for the connection lifetime and permits sequential `response.create` requests to reuse the connection. Closing the client during an in-flight response cancels its upstream request. Ping/pong behavior and the existing request-size, protocol, routing, and sanitization invariants remain intact.

Graceful App quit now uses the existing guarded `codex-config-status` / disable state. If RelayKit is enabled, the App restores the RelayKit-managed Codex config fields before helper shutdown. Config drift or restore failure cancels quit and keeps the gateway alive instead of leaving Codex pointed at a stopped helper. Codex auth remains untouched.

Focused native and Official sequential regressions passed, as did focused race coverage including client-close cancellation, full `go test ./...`, `go vet`, Swift build with the macOS 15.4 SDK, and GUI Terminal `RelayKitAppValidationTests`. These are source-level implementation results only: selector, menu, package, dogfood, live Desktop, install, signing, notarization, publication, and release gates are not yet claimed.

Build 15 remains immutable, historical, and ineligible. Build 16 has not been built. The existing personal-path and package-isolation remediation truth below remains authoritative and must be carried into the next selector, CR, and Release sequence.

Update (2026-07-23, live real-backend RED/GREEN and committed source): the fix is committed on `main` as `bed6f3b` with a clean tracked worktree. A live proof replayed one real captured Codex Responses request body (12 input items, client_metadata, prompt_cache_key, include, reasoning) twice on a single reused WebSocket against the real official backend through an isolated-port helper. The pre-fix gateway (parent `0027e1a`) completed turn 1 and then closed the connection on turn 2 (`__CLOSE__`), reproducing the client `Connection reset`/`Broken pipe`; the fixed gateway completed both turns with 13 streaming events each. Graceful-quit config restore was proven end-to-end in isolation (enabled then disabled, zero leftover 19777/openai_base_url lines) using the exact enable/status/disable subcommands the quit path calls. A full unsigned build produced a clean Build 16 bundle: the Build 15 personal-path scanner passed and both binaries scanned zero personal-path hits. Signing and notarization remain GUI-login-keychain-gated (SSH reports the login keychain locked / errSecInternalComponent; no passwordless sudo; launchctl asuser needs root), so Build 16 signing is the only remaining step. Machine-local untracked runners are staged: `scripts/private/package-build16-gui.sh` (GUI sign/notarize into `dist/signed-candidates/build-16/v0.1.5`, refuses to run while 19777 is bound) and `scripts/private/install-verify-build16.sh` (SSH-runnable atomic install plus post-install health/model/config verification). Installed app remains Developer-ID build 14 with a healthy App-owned 19777 helper; global Codex config and port 18787 are untouched.

## Current Truth (2026-07-22, Responses request limit source closeout)

The Responses request-size source change is closed out at source level and is pending a fresh packaged release candidate. Installed Developer-ID/notarized v0.1.5 build 14 remains the current release candidate; no package, GUI, full Desktop E2E, live query, signing, installation, or release completion is claimed for this newer source.

Responses requests now share one 32 MiB decoded-body ceiling across identity HTTP, zstd HTTP, and WebSocket. WebSocket rejects a declared oversized frame before payload allocation and permits only the bounded 64 KiB envelope overhead needed for `response.create`; control payloads retain the 125-byte WebSocket protocol ceiling. `/_relaykit/provider-test` uses an independent 64 KiB request limit.

Focused exact-boundary, over-limit, zstd, WebSocket-envelope, pre-allocation, and no-upstream-on-rejection tests passed. The bound source-only diff SHA-256 remains `51ef04bafed6a0a7bbf429c6d95b0597d262df55d18fc45f332105c7dbcf4cbd`; the authorized Test/check result passed, and Final CR passed with Critical/High/Medium/Low all clear. Because the complete candidate includes `gateway/**`, the next validation cycle must begin with a fresh selector plan before Test, CR, and any Release lane proceed sequentially.

## Current Truth (2026-07-22, Codex catalog schema compatibility)

The installed v0.1.5 build 10 passed the original reopened long-thread provider -> official remote-compaction-v2 gate and returned the exact Desktop marker, but the model picker exposed only one previously selected provider model instead of both configured provider models. Runtime config, `/v1/models`, and the generated catalog all contained both entries; the failure occurred when Codex core loaded the generated catalog.

The active Mini app-server (`~/.local/bin/codex 0.142.3`) emits `configWarning: Invalid configuration; using defaults` because every generated model lacks the older schema's required boolean `supports_reasoning_summaries`. The apparent five-model result is the built-in fallback catalog, not item-level filtering. A temporary catalog that adds only this field loads successfully and `model/list` returns all ten catalog entries, including both provider models; `max` and `ultra` reasoning levels are accepted and are not the cause.

The source fix normalizes every official template entry by adding `supports_reasoning_summaries=true` only when absent, preserves an explicit value, and derives provider entries from that compatible template. A focused TDD regression failed before the fix and passes afterward; the full SSH validation executable then proceeds to the known GUI-Keychain-only fixture (`-25308`). The GUI-Keychain run, Developer-ID signing, notarization, install, and installed-runtime gates now pass in v0.1.5 build 14.

The signed/notarized build 11 package was deliberately not installed: pre-install tracing found ordinary startup still hard-required a discoverable Desktop bundle, which would stop the helper on this upgrade state. A proposed persisted-catalog fallback was rejected in CR because it lacked version, account, and freshness binding. The final source uses the same controlled executable policy as login: prefer the Desktop bundled CLI, then an absolute executable in `~/.local/bin` or Homebrew, and run a fresh account-projected `debug models`. The Mini fallback CLI 0.142.3 returns a schema-compatible catalog under the RelayKit-isolated account, avoiding stale cross-version cache reuse.

Build 12 was signed/notarized and its schema-compatible provider catalog contained both configured provider models, but the installed post-start gate observed a transient `official_model_count=0`: `AppModel.init()` scheduled an asynchronous auth refresh while the app delegate immediately started a provider-only gateway. Build 12 was rolled back to healthy build 10. The build 13 source synchronously validates the existing isolated `auth.json` during initialization, resolves the controlled Codex executable on MainActor, builds one fresh catalog off MainActor, and then starts one complete gateway; manual auth refresh retains reconciliation and catalog rebuild behavior. Focused RED/GREEN tests cover file-backed auth loading and forbid the asynchronous initializer path.

Build 13 was signed/notarized and installed successfully: one App/helper, Official 7, both configured provider models in `model/list`, all catalog entries schema-compatible, and each provider completed an isolated exact-marker turn. The same-thread provider -> Official gate then proved Codex 0.142.3 does not perform the newer InvalidRequest retry and fails pre-sampling compaction. Build 13 therefore remains an installed diagnostic candidate, not the release package. The build 14 source uses the old core's immediately preceding prewarm as an explicit one-shot route proof keyed by exact session/thread with bounded IDs/capacity; only an exact configured Official target can carry the untouched compaction request through native Official Responses, while provider/missing/consumed hints remain local failures. HTTP and WebSocket RED/GREEN regressions cover this older-core path and ensure the adapter upstream is never called.

Build 14 is the installed release candidate. Its manifest binds clean product source `971d052e1849c12be1d6814d78f6f034505164c2`, build `14`, and signed zip SHA-256 `8f890433c0f39dd1bd7148287ef8dfe90b8f7166255a27ded057ef2241d6f7bf`. Installed gates report one App/helper, Official 7, configured provider models 2, a ten-entry schema-compatible catalog, both provider models in real Codex 0.142.3 `model/list`, and unchanged global config/auth plus isolated Official auth hashes. In one isolated persisted thread, provider 1 -> Official -> provider 2 -> Official completed four turns with no error events; both provider -> Official transitions passed natural pre-turn remote compaction. Provider 2 echoed earlier markers along with the current marker, but the turn completed successfully and the following Official turn returned the exact final marker.

## Current Truth (2026-07-22, provider-to-official remote-compaction-v2 fallback)

The notarized v0.1.5 build 9 package from 8ce3a54 passed isolated compact transport and same-thread short-history switching, but a real reopened long Desktop thread disproved the release claim. On provider -> official switching, Codex 0.145 performs pre-turn remote compaction v2 with the previous provider model. RelayKit's Anthropic/chat adapters treated the reserved compaction_trigger as ordinary chat input, returned normal message items, and Codex terminated with `remote compaction v2 expected exactly one compaction output item, got 0`. Build 9 is therefore invalidated and must remain running only until its signed replacement is installed.

A redacted copied-thread diagnostic established the complete data flow without reading conversation content. The request retained client_metadata, request_kind=compaction, compaction metadata, and a final compaction_trigger. The official model returns exactly one compaction item and completes successfully. The defect occurs only when an adapter-backed provider receives that reserved request: such adapters cannot produce the encrypted Responses compaction item, and inventing one locally would violate the opaque-compaction boundary.

The minimal fix rejects compaction_trigger before calling non-native provider adapters with structured invalid_request_error. Codex classifies InvalidRequest as model-specific and retries pre-turn compaction with the incoming/current official model. Native OpenAI Responses providers remain untouched because they may support the protocol themselves. A focused RED first proved the old adapter emitted a normal completed message and called upstream; GREEN proves no provider call and a response.failed invalid_request_error. Full Go/race/vet/gofmt, Swift build, public-boundary, and diff gates pass. A copied failing old thread then completed thread/compact/start through the official fallback and produced an exact official follow-up marker after compaction.

Build a fresh Developer-ID/notarized v0.1.5 build 10, atomically replace build 9, then rerun the original reopened long Desktop thread path provider -> official through natural remote compaction v2. The release gate requires no final task error plus successful post-compaction continuation/model switching; isolated short-history and direct compact probes are insufficient substitutes.

## Current Truth (2026-07-22, headerless official compact response)

The notarized v0.1.5 build 8 package from c2e3034 was installed atomically with valid Developer-ID signature, hardened runtime, notarization, staple, Gatekeeper, manifest/checksum binding, App-parented helper, and unchanged global Codex config/auth hashes. A fresh real Codex WebSocket thread passed provider -> official -> provider -> official: all four exact markers were correct, all turns shared one thread id, provider and official each completed twice, and no client-visible failure occurred. This proves both headerless SSE and mixed Responses history preservation in the installed package.

The remaining explicit compact gate exposed the same backend header omission on the unary endpoint. The live official /responses/compact response was HTTP 200, about 69 KiB, valid JSON with id/object/output/usage, ten message items and one compaction_summary, but no Content-Type. Build 8 rejected it before parsing and returned a sanitized 502 protocol_error, so build 8 is not releasable.

The source fix is intentionally compact-only: an absent media-type header is accepted only for /responses/compact, while any non-empty non-JSON media type is still rejected and ordinary non-streaming /responses remains unchanged. A dedicated bounded parser requires one top-level JSON object, an actual output array, and object items with non-empty type fields; it preserves opaque fields such as encrypted_content and supports the backend response.compaction shape without requiring normal Responses status/model fields. Focused RED/GREEN tests pass, including rejection of output:null. Full Go/race/vet/gofmt, Swift build, public-boundary, and diff gates pass. A real official-only source helper on isolated port 19779 then returned the exact compact request as HTTP 200 application/json with the expected item types and completed usage; global and isolated auth hashes stayed unchanged.

Commit this fix, produce fresh Developer-ID/notarized v0.1.5 build 9 in the Mini GUI Keychain session, atomically replace build 8, and rerun the explicit current-package compact request. Keep installed build 8 and its healthy helper running until replacement because the global Codex config remains RelayKit-managed.

## Current Truth (2026-07-22, mixed Responses history preservation)

The notarized v0.1.5 build 7 package from cb1cca8 was installed atomically and restored an App-parented healthy helper with manifest-bound executable, official 7 / provider 1 / configured 2, and unchanged global Codex config/auth hashes. A real current-package Codex WebSocket thread completed provider -> official -> provider -> official without client transport failures, proving the headerless official SSE fix. However, both later provider turns returned the immediately preceding official marker instead of their fresh provider marker, so build 7 is not releasable.

The remaining defect is deterministic in the Responses-to-Anthropic adapter. Real mixed history represents assistant text as content parts with type output_text. chatMessages accepted only input_text/text, silently dropped every assistant message, and anthropicMessages then merged adjacent user instructions into one conflicting prompt. A focused RED regression produced one merged user message instead of the required user/assistant/user sequence. The minimal fix recognizes output_text, preserves alternating roles and the latest user instruction, and passes focused plus full Go/race/vet/gofmt, Swift build, public-boundary, and diff checks.

Build one fresh Developer-ID/notarized v0.1.5 build 8 after committing this fix, replace build 7 atomically, and rerun the same-thread provider -> official -> provider -> official marker sequence. Keep installed build 7 and its helper running until replacement because the global Codex config remains RelayKit-managed.

## Current Truth (2026-07-22, headerless official SSE compatibility)

The notarized v0.1.5 build 6 package was produced and installed from main at 4222970. Signature, hardened runtime, notarization, staple, Gatekeeper, manifest hashes, atomic install, App-parented helper startup, health (official 7 / provider 1 / configured 2), and global config/auth hash guards passed. A current-package same-thread Codex run then exposed one remaining protocol defect: the provider turn completed, but the first official turn failed over WebSocket and HTTP fallback because RelayKit required an explicit text/event-stream Content-Type before reading the upstream body.

A redacted direct diagnostic using the exact real-client request established the backend contract: HTTP 200, no Content-Type header, 13 valid SSE data records, and a terminal response.completed event. No response content, credential, account id, or authorization header was emitted. The source fix accepts a missing Content-Type only for native official streaming responses and still delegates the body to the existing strict bounded SSE parser; any non-empty non-SSE media type remains rejected. A focused RED regression failed with the old 502 and passes after the two-line production change. Full Go, race, vet, gofmt, Swift build, public-boundary, and diff gates pass.

An official-only source helper on an isolated port then completed real Codex WebSocket turns with exact markers and no client-visible errors; the RelayKit-isolated auth file stayed hash-identical. The available Codex 0.145 app-server completed both manual and low-threshold compaction through ordinary /responses and did not invoke /responses/compact, so the explicit remote endpoint remains unclaimed rather than being relabeled as PASS. Mini has no /Applications/Codex.app and SSH is not AX-trusted, so Desktop GUI/process-bound screenshot evidence also remains pending.

The signed build 6 artifact is invalidated by the headerless-SSE defect. Build one fresh Developer-ID/notarized v0.1.5 build 7 after committing this fix, install it atomically, and rerun provider -> official -> provider -> official in one real client thread. Keep the currently installed build 6 App/helper alive until replacement because the global Codex config still contains RelayKit managed fields.

## Current Truth (2026-07-22, native official startup compatibility)

The native proxy source at `a6cd9dd` passed Go/race/public-boundary review, but pre-release validation found one upgrade blocker: App startup still used `codex login status` to decide whether the existing RelayKit-isolated login was connected. On the Mini the ordinary Codex app/CLI location was no longer discoverable, so the App started a provider-only helper even though its isolated `auth.json` remained complete. The fix now validates the isolated auth file locally and structurally, requires `chatgpt` mode plus non-empty access/account/refresh fields, never emits values, and uses the Codex binary only for first-time device authorization.

Focused validation after the fix passes: full Go test/vet/gofmt, Swift build (including the new auth-state fixture), signed-release contract tests, public-boundary, and diff checks. The full Swift validation executable still requires the console GUI Keychain session; SSH reaches the existing Keychain fixture and exits with macOS `-25308`. Both ad-hoc v0.1.5 controlled-install attempts are invalidated and must not be released. The exact-path attempt did migrate the runtime to the fixed official endpoint and recovered all seven official models, but ad-hoc code identity is not an acceptable substitute for the installed Developer-ID identity when loading the saved provider Keychain reference. The installed App was rolled back and exactly recovered to v0.1.4 build 5; health is now official 7 / provider 1 / configured 2. Because the real Codex config currently contains both RelayKit-managed fields, that App and its App-owned `19777` helper must stay running until the signed candidate is installed or RelayKit is explicitly disabled.

One minimal hand-written official WebSocket live probe failed immediately after upgrade and is not eligible evidence. A no-network loopback capture subsequently proved the probe omitted many fields carried by a real Codex 0.142.3 request; the candidate transparently passed the real-client body through a Responses fixture. Do not retry or relabel the failed live run. The next live action must be one newly bound current-package Desktop same-thread sequence after the fresh signed install. Developer-ID signing/notarization must run from the Mini GUI login Keychain session: SSH `notarytool` reports the default Keychain locked and a temporary sign fails with `errSecInternalComponent`. A local ignored `0700` runner is prepared at `scripts/private/package-v0.1.5-gui.sh`; it contains only public signing metadata/profile references and no credential value.

## Current Truth (2026-07-21, native official Responses refactor)

The same-thread switching failure is confirmed as an official-route architecture defect, not a provider credential defect. The old `codex_home` path spawned one ephemeral `codex exec` process per request, flattened structured Responses history into a prompt, waited for a complete output file, and enforced a two-minute timeout. It also had no `/v1/responses/compact` route. Real long Desktop threads therefore failed either with remote-compaction output errors or with a 120-second timeout followed by WebSocket `Broken pipe`.

Phase 7.11 replaces that path with a native official Responses proxy:

- App runtime config now points official traffic at the ChatGPT Codex backend and no longer writes `codex_binary`.
- Gateway forwards the raw Responses request to `/responses` or `/responses/compact`, with a strict Codex protocol-header allowlist, isolated OAuth Bearer, and `ChatGPT-Account-Id`. Inbound Desktop Authorization, cookies, provider credentials, and arbitrary headers are not forwarded.
- HTTP JSON/SSE and Desktop WebSocket ingress use the existing validated native Responses event pipeline, preserve tools/structured history, restore the public model id, and retain real usage.
- One upstream 401 performs one OAuth refresh, atomically updates only the isolated Codex `auth.json` while preserving unknown fields, and retries once. RelayKit writers use a cross-process lock and exact snapshot guard so observed external updates win. No auth value enters client responses, usage, tests, or tracked config.
- The subprocess implementation, explicit shell shim, structural trace, and obsolete fixtures/tests were removed.

Current source gates pass: `go test ./... -count=1`, `go vet ./...`, clean `gofmt -l`, `swift build`, `public-boundary-check.sh`, and `git diff --check`. New loopback tests cover official auth/header isolation, compact routing, HTTP SSE, Desktop WebSocket bridging, public model rewriting, and 401 refresh persistence/retry. `RelayKitAppValidationTests` still needs a console GUI Keychain session; SSH execution built successfully but correctly failed Keychain interaction with `-25308`. Selector-required menu smoke, current package, and isolated same-thread live switching/compaction proof remain pending. No global Codex config/auth, shared service, LaunchAgent, or port `18787` was changed.

Independent CR closed the arbitrary-OAuth-target High finding and compact-usage Low finding. One Medium risk is accepted for this candidate: a non-cooperating external process could write RelayKit's isolated `auth.json` after the guarded comparison but before atomic rename. RelayKit no longer spawns Codex during requests, all RelayKit helpers honor the lock, and normal product flow owns that isolated home; arbitrary concurrent external writers are not a supported workflow.

## Current Truth (2026-07-21, recovery + new candidate)

Immediate incident: a prior Enable-for-Codex/validation run left the real global `~/.codex/config.toml` pointing at RelayKit's `openai_base_url=http://127.0.0.1:19777/v1` plus RelayKit `model_catalog_json` while the App/gateway were NOT running. Codex Desktop then failed every request with `stream disconnected before completion: error sending request for url (http://127.0.0.1:19777/v1/responses)`. This violated the AGENTS.md shared-runtime boundary (validation must not leave the global config enabled without a running gateway/rollback).

Recovery performed (surgical, matches `codexconfig.Disable` semantics):
- Backed up global config to `~/.codex/config.toml.bak.pre-recovery-20260721T102301Z`.
- Removed ONLY the two RelayKit-managed root lines (`openai_base_url`, `model_catalog_json`). User `model`, notify, MCP, projects, hooks, sandbox and all other fields preserved. Codex now falls back to the official endpoint.
- Archived stale state to `~/Library/Application Support/RelayKit/codex-config-state.json.disabled-recovery-20260721T103016Z` so status reads `disabled`, not `drifted`.
- Global `~/.codex/auth.json` was never read or modified. `18787`/`19777` have no listener.

New authoritative signed candidate: v0.1.4 build 5, built from frozen HEAD `e9ecd63`.
- `dist/github-release/v0.1.4/RelayKitApp-0.1.4-signed.zip`, SHA-256 `5d423688d9feb1263234dfac9bea36e1c64ffea59467b6a30a7c28029ac741ab`.
- Developer ID signed, hardened runtime, notarized (Accepted, submission `68737f4b-c034-4be7-bf2d-f4f4a8d57b35`), stapled, Gatekeeper `Notarized Developer ID accepted`; signed-zip re-extraction re-verified.
- manifest binds `source_commit_sha=e9ecd63`, `source_clean=true`.
- Supersedes stale v0.1.1 (c26aef4), v0.1.2 (3fb65fb), v0.1.3 (aacf51a); none were built from HEAD.

Source gates on HEAD e9ecd63 all pass: `go test ./... -count=1`, `go vet`, `gofmt -l`, `swift build`, `RelayKitAppValidationTests` (run inside the console GUI session for Keychain), `public-boundary-check.sh`, `git diff --check`, clean worktree.

Pending (needs user-in-the-loop per objective): install v0.1.4 to `/Applications` (currently v0.1.3), then real ordinary Codex Desktop same-thread E2E (Case 4/5) with a real third-party provider credential.

### Install + runtime verification (2026-07-21, v0.1.4)

- Installed v0.1.4 build 5 to /Applications atomically via script/install_signed_release.sh. Post-install executable SHA matches manifest ac8424c5...5325. Old v0.1.3 backed up at /Applications/.RelayKitApp.backup.20260721T112446Z.37437 (rollback: quit app, remove app, move backup back).
- Case 1: LSUIElement menu-bar app installed with normal Finder app icon; status item present.
- Case 2: ordinary launch auto-started the bundled gateway on 127.0.0.1:19777 (parent-pid bound to app 37693). Health: status ok, provider_count 1, official_model_count 7, configured_model_count 2, model_health healthy 9 / hidden 0.
- Real route proof through the installed App gateway (NOT fixtures): a configured third-party provider model returned status completed with real token usage; official gpt-5.6-terra returned status completed. A real third-party provider key is already present in the App Keychain reference.

### Remaining (needs user at the physical machine)

The SSH-bridged automation is NOT Accessibility-trusted (AXIsProcessTrusted=false, System Events -1719). So Case 3/4/5 cannot be driven remotely:
- Case 3: click Connect page "Enable RelayKit" (id codex-relaykit-toggle), confirm the dialog. This rebuilds the catalog WITH provider models and writes the two managed fields to the real ~/.codex/config.toml while the gateway is live.
- Case 4/5: fully quit + relaunch ordinary Codex Desktop, then in ONE thread: official -> provider (Markdown) -> provider (real shell/tool) -> official, capturing thread_id/model/usage/screenshots.

Global state left safe: ~/.codex/config.toml has NO 19777/managed fields (Codex uses official). codex-config-state absent (disabled). auth.json untouched. The App gateway listening on 19777 is harmless because config is disabled.

## Signed Beta v0.1.0 Current Candidate

Status: **signed beta candidate complete; public release unpublished**. The current artifact is `dist/github-release/v0.1.0/RelayKitApp-0.1.0-signed.zip`, SHA-256 `116928bda89b6ca9a266bd7e1b3b820fc811d45f6ba118be16a367c619cf1a78`. It uses release/trimmed-path binaries and passed the archive personal-path scan, Developer ID signing, hardened runtime, fresh notarization acceptance, stapling, Gatekeeper validation, signed-zip dogfood, and the menu-bar right-click Quit lifecycle. The redacted release verification is `dist/signed-beta-v0.1.0/path-clean-six-stage-20260720T162614Z/replacement-release-evidence.redacted.json`.

Current setup evidence and current route evidence are separate. `dist/dogfood-local-beta/evidence.json` binds the extracted ordinary-App lifecycle, Provider/Keychain persistence, gateway restart, actionable error states, and cleanup directly to the immutable current release zip; its provider is explicitly a fixture and makes no real-model compatibility claim. `dist/signed-beta-v0.1.0/path-clean-six-stage-20260720T162614Z/final-evidence/` is the current-package Desktop route evidence. Its six unique stages each have one submission and an exact rollout binding: Official plain/Markdown, provider plain/Markdown/tool, and Official tool. All six are `evidence_verified`, with no human intervention.

The final Official tool stage contains one native function call and matching output in the exact bound session, the fresh marker, workspace `pwd`, and exit code 0. The provider tool stage independently contains a real function call/output, fresh marker, workspace path, and exit code 0. The process-bound screenshots show native tool blocks and the required Markdown structure without bare XML, `function_calls`, or unresolved protocol JSON.

The product defect was the first-leg explicit shell prompt terminator: current Desktop input adds one terminal LF. Commit `c2581ac` accepts exactly that one terminal LF while preserving rejection of remaining or internal newlines. No rejected second-leg payload was used as the root-cause claim.

Cleanup passed: the App, bundled gateway, and isolated Desktop stopped; `19777` and `18787` were free; and the global config/auth guards passed unchanged. The public GitHub Release remains unpublished and the updater is not implemented.

Current product scope:

- `app/`: SwiftUI/AppKit menu-bar shell, provider form, Keychain references, usage view, settings, and bundled gateway lifecycle.
- `gateway/`: local HTTP/WebSocket gateway, model catalog, provider adapters, official credential reference support, and sanitized usage events.
- `scripts/`: public-safe smoke/proof scripts that use isolated state and loopback ports.
- `docs/`: public product, engineering, beta, and release-readiness notes.

### Build 15 Personal-Path Source Remediation

This source closeout supersedes any earlier candidate wording above for Build 15 only. Build 15 is immutable, historical, and ineligible: the formal candidate scan found a personal absolute path in its primary executable. Do not re-sign, overwrite, relabel, or reuse Build 15 or its evidence. The failed diagnostic did not provide an independent rule ID, hit count, or byte position, but that missing source attribution does not alter the fail-closed classification.

After the formal failure, the source remediation was revised: each Swift release build now uses a newly empty `/tmp` scratch path with dedicated Swift and Clang module caches; it maps workspace and home-derived prefixes through Swift frontend debug/file maps and Clang importer debug/file/macro maps. The raw-byte scanner remains fail-closed for both release executables before signing and for prepared, staged, retained, and extracted signed-release payloads. The regression fixture is unmistakably synthetic, is rejected while `strings` is unavailable, and confirms the rejection reports only binary role, rule ID, and count.

The selector package/dogfood isolation remediation is now source-complete and pending formal Test/CR. The headless bundle build/verify entry no longer stops processes or inspects installed-App, port-owner, LaunchAgent, or shared-runtime state. Focused source contracts preserve dogfood's fail-closed checks for an already-running App or occupied `19777` and constrain cleanup to the exact extracted App PID and bundled helper path. This lane did not run package, dogfood, GUI, network, signing, notarization, install, release, or runtime commands.

No successful clean release build, Build 16, package, signing, notarization, installation, GUI, network, live, or publication result is claimed here. Fresh selector Test and sequential `relaykit_cr` and `relaykit_release` gates remain pending before a new Build 16 can be created.

## Public Boundary

Do not commit private provider names, real provider domains, API keys, bearer tokens, copied `auth.json`, Keychain item names from a real machine, user screenshots with private data, or local usage logs.

Validation must not mutate shared Codex state:

- Do not write `~/.codex/config.toml`.
- Do not write or copy `~/.codex/auth.json`.
- Do not touch `~/Library/LaunchAgents/*`.
- Do not start legacy `agent-local-gateway`, tunnels, or bridges.
- Do not bind `127.0.0.1:18787`.

The normal RelayKit App gateway path listens on `127.0.0.1:19777`. Isolated proof scripts may choose random loopback ports so they do not interfere with the app or shared services.

## Historical Local/RC1 Verification Commands

The commands below belong to the earlier local/RC1 product gate. They are historical reference only and do not complete the current Signed Beta candidate or replace its fresh six-stage current-package proof:

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

## Historical RC1 Public Proof Handoff

### Native Responses Chain Wave 2 product closeout

Historical product status was `complete` for the local ad-hoc RC1 product gate. The fixed zip was `dist/RelayKitApp-local.zip`, SHA-256 `8a4050017c4ca21b85c3ef645c02d31cfbe0e901c38b5578f74ddf5cdb76d3dc`; the fresh zip extraction and exercised `dist/verify-release/RelayKitApp.app` both had tree SHA-256 `0e965ee792beb2a62c7494db3acb4b6e5c2c3bc03bc06c381323c14a740bca5c`, and the executable SHA-256 was `bf9c16b0c24569f5cc289a47b9ac619afede55d23032788ef9ea3b96c533f7ca`. `dist/rc1-final-current-run-20260717/final/product-evidence.json` is historical RC1 evidence only. It is not a PASS input for the Signed Beta candidate.

The product keeps the native 480x760 `NSPopover`. The failed custom popover-window accessibility role, parent, and repeated attachment machinery has been removed. Its accurate historical conclusion remains `exact remote AXPopover proof blocked`; that remote projection is no longer treated as the sole product gate and must not be "fixed" by restoring a panel, titled/proxy window, private AX API, OCR, title matching, or loose fallback.

Two fresh ordinary launches of the current extracted App passed the product-surface preflight under `dist/rc1-final-current-run-20260717/preflight/`: each had no product surface before the exact status-item action and exactly one same-PID WindowServer surface afterward. The product flow then started from an empty provider destination, saved one `openai_responses` provider with a Keychain reference and no plaintext key, reported one reachable/available model, exited, reopened the same extracted App, restored the masked saved-key state and reachable model, and exposed that model through the App-owned gateway. Process-bound screenshots are under `dist/rc1-final-current-run-20260717/screenshots/`. The ordinary right-click Quit gate reused the same extracted App and verified the exact `Quit RelayKit` item, App exit, and bounded `19777` release; its clean menu crop is under `dist/rc1-final-current-run-20260717/final/menu-bar-smoke/`.

The current isolated Desktop A/B/C route is complete under `dist/rc1-final-current-run-20260717/desktop-evidence-3/`. One current run bound the Desktop PID/window, App-owned gateway, provider config, harness SHA-256 `9525c7b5f92897e9630ad642f0af171367e6abaf66ea9f62743d80e49569cd57`, and scenario SHA-256 `407458079050d754198d9f1da831db1a309049983a906f763d2f354d9cfb6b67`. Plain text, structured Markdown, and the real shell/tool stage each had one submitted rollout binding and current-run completed evidence. The Markdown screenshot contains the required heading, numbered list, table, fenced bash block, and bold conclusion; the tool evidence contains a matching function call/output, workspace output, and exit code 0. No bare XML, `function_calls`, unresolved tool JSON, auth error, historical usage, CLI fallback, or mock OK was accepted.

The failed zip candidates `462d3b2bfe9a2a5a910e0c6d4091a1fd1ec67b29b0ae9fd63ce18045c3005001` and `be70c14b22483fb28e62f51854d0659d4f567fd7837b53690d302a0e2b9c1c2f`, plus the previously accepted run `rc1-native-20260716T111701Z-external-sandbox` and zip `abf74744aedbe699e20b37064802d8753e40424d8886e68d2c32954eadec776a`, are historical and ineligible for the current candidate. They must not be copied, relabeled, or mixed into current evidence.

The generic `desktop-render-evidence.json` retains broader manual-proof fields and is not the authority for this three-stage RC1 profile. RC1 rendering is decided by the stage ledger, process-bound screenshot ledger, rollout binding, usage, and tool evidence above; evidence layers must not be mixed.

Historical `observation_failed_*` artifacts remain failed and untouched. They are explicitly ineligible for manifest PASS and must not be copied or relabeled as current evidence.

Current-candidate validation passed the Desktop AX driver, manual-proof and RC1 proof contract tests, Swift build and `RelayKitAppValidationTests`, Go tests/vet/gofmt, public-boundary, diagnostics redaction, frozen package/code-signature/bundled-gateway verification, and diff checks. Cleanup deleted only the dedicated fixture Keychain item and temporary proof state; App/Desktop/fixture processes stopped, `19777` and the fixture port were released, `18787` remained free, and global Codex config/auth SHA-256 values matched their before signatures. The current manifest is derived only after this tracked commit is clean and lives beside `final/product-evidence.json`.

The accepted unique matrix used no paid or real-provider request and was selected with:

```bash
./scripts/relaykit-validate.sh --plan-only --rc1
```

The fixed order builds and verifies one package, then reuses `dist/verify-release/RelayKitApp.app` for:

- `scripts/menu-bar-e2e-smoke.sh` with `RELAYKIT_REUSE_FINAL_BUNDLE=1`;
- `scripts/rc1-native-responses-proof.sh`, which proves App-first `openai_responses` routing against a local fake upstream;
- `scripts/rc1-helper-lifecycle-proof.sh`, which proves the App-owned helper exits after abrupt parent loss.

Both proofs fail if `19777` is already occupied, preserve the listener snapshot on `18787`, hash-check global Codex config/auth before and after, do not touch LaunchAgents, and write aggregate public-safe evidence under ignored `dist/`. The native proof sends only a loopback fixture request; the lifecycle proof sends no provider request.

The tracked remote-Mac acceptance material is now portable and requires explicit local `RELAYKIT_ACCEPTANCE_HOST`. The machine-specific originals remain ignored archives and must not be staged or regenerated.

Developer ID identity and the notarization credential profile are prepared, but this RC1 product-closeout goal does not create a signed artifact or perform notarization, stapling, publishing, or updater work.

## Proof Layers

Public-safe scripts:

- `scripts/menu-bar-e2e-smoke.sh`: launches the local app with isolated fixtures, verifies the Connect/Usage/Settings product surface, and writes evidence to `dist/ui-smoke/`.
- `scripts/rc1-native-responses-proof.sh`: proves the final extracted App can start its bundled helper and preserve a native Responses request/response contract through a loopback fake upstream.
- `scripts/rc1-helper-lifecycle-proof.sh`: proves the helper is parent-bound to the final extracted App and exits after abrupt App loss without LaunchAgent or shared-service control.
- `scripts/local-beta-dogfood-smoke.sh`: rebuilds `dist/RelayKitApp-local.zip`, extracts it under `dist/dogfood-local-beta/install/`, launches that extracted app bundle, records Gatekeeper rejection as expected local beta friction, and writes public-safe evidence/screenshots to `dist/dogfood-local-beta/`.
- `scripts/export-diagnostics.sh`: writes a redacted aggregate diagnostics bundle under `dist/diagnostics/` with version, bundle id, gateway health, provider/model counts, usage aggregate, and allowlisted recent error types. Unknown or contaminated error labels become `other`; a failed sensitive-content scan removes `diagnostics.json`. It must not export provider URLs, credentials, headers, raw request/response bodies, copied Codex auth files, or Keychain item names.
- `scripts/export-diagnostics-test.sh`: injects private URL, Keychain, header, request/response, provider, and error-label sentinels into isolated fixtures and proves none appear in the exported bundle.
- `scripts/codex-desktop-acceptance.sh`: builds an isolated Codex config/catalog around a loopback gateway and fake/demo provider contract.
- `scripts/codex-desktop-manual-proof.sh`: creates isolated state under `~/Library/Application Support/RelayKit/DesktopProof/` and launches isolated Codex Desktop for GUI route proof. The historical RC1 proof used one explicitly authorized `run-auto --scenario /absolute/path/scenario.json` invocation with no human interaction. Its caller keeps query bodies in private `0600` temporary files. Fixture setup uses a random safe loopback port; the real App-first path uses the extracted RelayKit App's normal `19777` lifecycle and refuses to proceed if that port is already occupied. It discovers the current Desktop executable by bundle id `com.openai.codex`, uses the matching app-bundled `Contents/Resources/codex` catalog/app-server binary, preserves current official model metadata, and merges every configured provider model with its public display and upstream names. The default `sandbox-exec` profile denies writes to the physical global `.codex` tree, Codex/OpenAI Application Support state, Codex/CUA preference files, LaunchAgents, and the legacy gateway config while allowing the isolated DesktopProof tree. Before/after global, source, plus harness hashes fail closed on any change. Setup-only proves official + demo provider picker data; full proof still requires real isolated Desktop requests and writes evidence to `dist/codex-desktop-manual-proof/`. Only current-run evidence may advance preserved attempt/complete state, and process-bound screenshots stay with that evidence. `$relaykit-desktop-query` is a separate single-query dispatcher and is not full route proof.
- `scripts/codex-desktop-manual-proof-test.sh`: verifies Desktop executable and bundled CLI discovery, current official catalog preservation, full provider-model merging, official gateway allowlist synchronization, fail-closed global/source/harness state guards, last-route preservation, route outcome semantics, current-run tool evidence, interactive Desktop AX readiness, and bounded cleanup when an Electron process ignores `SIGTERM`.
- `scripts/full-merged-catalog-proof.sh`: proves official + demo provider catalog merge and request routing with loopback upstreams.

Private/local real-provider proof scripts are kept out of tracked public files under ignored local paths such as `scripts/private/`. They may be useful on one developer machine, but they are not the public default contract.

## Beta Boundary

`./script/build_app_bundle.sh --verify` builds and verifies the app bundle without opening the GUI. `./script/package_release.sh --verify` produces `dist/RelayKitApp-local.zip` through that headless path. This is an ad-hoc signed local beta artifact for bundle integrity only, not a Developer ID signed or notarized public release.

Historical RC1 release status:

- local beta: ready.
- open-source public-safe: ready.
- local beta packaging pipeline: ready.
- Desktop native Responses proof: complete for the current local artifact through the fresh A/B/C run above. The earlier four-stage standard route proof is a separate evidence layer; neither makes the artifact a signed beta.
- signed beta scaffolding and local Apple distribution inputs: present.
- signed beta: not executed in the current RC1 product-closeout goal.
- public release: not complete.
- updater runtime: deferred until a signed and notarized artifact exists.

Historical RC1 boundary: Developer ID and notary-profile readiness no longer blocked later distribution work, but that RC1 goal stopped before `package_signed_release.sh`, notarization submission, stapling, Gatekeeper validation, GitHub Release creation, or updater metadata. That historical boundary does not describe the current fixed signed, notarized, and stapled artifact.

Do not describe the local ad-hoc package as a signed beta. Do not mock notarization success.

The completed local hardening objective is `RelayKit Beta Dogfood Hardening`: make the local ad-hoc beta usable, diagnosable, and feedback-ready independently of the distribution lane. During the current RC1 closeout, do not implement updater runtime, Sparkle, Tauri updater, signing, notarization, publishing, global Codex config/auth mutation, shared `18787` takeover, or legacy `agent-local-gateway` control.

Historical dogfood status:

- The current full zip dogfood evidence is bound to fixed artifact SHA-256 `f81b7ce1553131bb4fde3db3e6005df2e8478384e5f316828339101da093b848`, built at `2026-07-11T16:56:10Z`. Evidence records the extracted app path and normal `/usr/bin/open` LaunchServices lifecycle; `RelayKitApp.bin --ui-smoke` is not used for the dogfood claim. The dogfood harness reused the fixed zip and did not rebuild it.
- The tracked dogfood harness now requires normal LaunchServices launch from the current extracted zip, exact AX actions, full fixture provider setup, reopen persistence, a fresh reachable-model re-probe, real right-click Quit, bounded `19777` release, and RelayKit-owned WindowServer screenshots.
- The current extracted App stores provider keys with Security.framework, reads only referenced Keychain items in the App process, and sends a versioned credential map to its bundled gateway once through an anonymous stdin pipe. The gateway keeps that map in memory and fails closed when an App-provided reference is absent; it does not fall back to `/usr/bin/security` in App mode. Standalone/headless gateway launches retain the existing local Keychain fallback.
- The first fresh run exposed a real AX identity defect on the visible `Use reachable` button. The product fix only changes that control's smoke marker to record-only so its unique identifier remains on the real `AXButton`; the rerun then proved Detect models, Test connection, Use reachable, failure filtering, actionable URL/key/model errors, right-click Quit, bounded `19777` release, provider persistence, masked Keychain state after reopen, and a fresh `1 available / 0 hidden` re-probe. The fixture Keychain setup is test preparation, not proof of real-user authorization.
- Ten current-run WindowServer screenshots were reviewed image by image. They contain no black obstruction, unrelated Codex window, or Keychain authorization prompt; Usage is visibly labeled `fixture`, the reopened provider shows one available model, and the complete Quit menu is present. The bad-key state is asserted through exact AX text and is intentionally not captured while macOS secure-input redaction is active.
- `connect-first-screen.png` and the other dogfood captures prove RelayKit App product state only. They must not be cited as current Codex request-route evidence.
- Fixture provider evidence proves catalog/picker/credential plumbing only. It does not prove a real provider model, tool call, or rich-text compatibility.
- Fresh diagnostics were regenerated after the implementation diff. `dist/diagnostics/redaction-scan.json` reports `passed=true`; the sentinel self-test proves private URL, Keychain, provider, header, request/response, and contaminated error-label values are not exported.
- Keep the older acceptance conclusion unchanged: P1a backend/data-source acceptance passed; P1b Desktop GUI picker/selection/route proof was blocked because there was no isolated authenticated Desktop entry. Do not keep forcing that old blocked goal or relabel it complete.

Historical Gate 0 closeout evidence:

- The fixed candidate is zip SHA-256 `f81b7ce1553131bb4fde3db3e6005df2e8478384e5f316828339101da093b848` with product-source snapshot `19aa2c30ef9a44e7c400f9a2595e0fa4cb4527c9e68a04b5fdef55e978c71882`. Harness-only changes reused that zip and its byte-identical extracted App; they did not rebuild the product artifact.
- The fresh full-standard route run records harness SHA-256 `97e685f050ef82d9d2e18d4661811d812c3b0ddbc0598a611fbd7b4833c4c7e0` and private scenario SHA-256 `334288ccf885c42f99366ff9694de34d0e78688f8e2e6082f366bfe5f1f8fa19`. Product, product-source, harness, AX driver, and scenario layers remained unchanged throughout the run.
- The route guard recorded global config SHA-256 `797fc3a497c51a7c40b2280fd72330b3f7c038f611a92d0e024ea5b2473af78b` and auth SHA-256 `e39d2073d5fee94ab016df8e70341b064569981fd61be486135690113683f043` before and after. Signatures, content hashes, and the config `notify` hash were unchanged; no repair path ran.
- The isolated Desktop sandbox fails closed on writes to the physical global `.codex` tree, Codex/OpenAI Application Support directories, Codex/CUA preferences, LaunchAgents, and the legacy gateway config while allowing the isolated DesktopProof tree. RelayKit does not repair or restore global Codex files.
- The fresh validation matrix passed: public-safe Desktop acceptance, menu-bar AX smoke, Swift validation, extracted-App dogfood and its contract tests, manual-proof and AX-driver self-tests, Go tests, `go vet`, `gofmt -l`, diagnostics redaction, public-boundary, shell syntax, and `git diff --check`. Build/package verification belongs to the already fixed product artifact and was intentionally not repeated after harness-only changes.
- Ports `18787` and `19777` were listener-free after the final run. Signed beta remains a separate Apple-approval blocker and updater runtime remains deferred.

Current Validation Fast Path work:

- Workflow 5.6 is current on `main`. The exact seven-role model matrix is Planner Sol/xhigh, Gateway Terra/high, App Terra/high, Worker Sol/high, Test Luna/medium, CR Sol/high, and Release Terra/high; Ultra and Max are forbidden.
- Main/root owns goal registration, pause/resume, risk assessment, and user confirmation. Main/root does not decompose tasks or implement changes. Planner decomposes work, designates and dispatches bounded roles, and owns remediation.
- Main/root may approve one batch of 1-3 test messages only for the current task-bound isolated proof/session. Main/root approves only; the Planner-designated `relaykit_test` or `relaykit_worker` sends the messages. The batch is limited to 3 messages, stays bound to that isolated proof/session, does not read, refresh, copy, or migrate credentials, and does not touch global config/auth, LaunchAgents, shared services, or port `18787`. It does not publish, sign, delete, perform irreversible actions, automatically retry, or expand the approved count. More than 3 messages, any retry or count expansion, auth/login, shared ports or services, global config/auth, signing or release, and destructive or irreversible actions require user confirmation.
- Test uses checked-in `workspace-write` only for ignored validation artifacts and must prove byte-identical tracked-worktree status before and after; CR remains checked-in `read-only`.
- Tier 0/1 Fast Validation Path is eligible only when all of these are true: Validation Tier is 0 or 1; changed paths are limited to docs, public agent TOML, the workflow contract test, or ordinary project config; scope excludes app/**, gateway/**, credentials, Keychain, auth, shared services, LaunchAgents, port 18787, global Codex config, build, package, GUI, network, live requests, signing, and release; and Planner supplies an exact command allowlist.
- An eligible Fast Path uses exactly one Planner, one bounded Worker, one Test, and one CR. Test executes the exact allowlist directly without selector generation or `relaykit-validate.sh --plan-only`. Tier 2/3 and every ineligible change retain the selector path.
- Main/root still performs no decomposition or implementation, but may verbatim-correct a missing ROLE field, field-name typo, or command-transcription error without replanning. Allow at most one remediation. After a test-assertion-only fix, rerun only the corresponding test and minimal CR recheck without repeating passed runtime metadata. Nonblocking Medium/Low findings become backlog evidence without scope expansion.
- This workflow lane must not touch `app/Sources/**`, `gateway/**`, global Codex config/auth, LaunchAgents, shared gateway state, package artifacts, Desktop GUI, or model endpoints.

Signed Beta live-gate exception: `execution_allowed=false` from the signed-beta plan means plan-only and forbids selector-driven automatic execution; it does not deny a separately user-authorized, Planner-bounded one-time live gate.

The only permitted global config/auth interaction is the designated read-only non-content metadata/hash/signature guard. The guard must not mutate, copy, repair, restore, refresh, migrate, parse, inspect, print, or disclose global content. It may accept the current pre-run metadata/hash/signature as the baseline, must require exact before/after equality, and must fail closed on any mismatch or guard error.

For this exception, Planner must bind one exact isolated session, artifact, scenario, and command allowlist to one fresh run: at most six commands, each command exactly once, with no retry, continuation, aggregation, relabeling, or reuse. The allowlist must encode redaction, the non-content global guard, no other global config/auth or shared-service/LaunchAgent access, no port `18787`, exact cleanup, and current run-bound evidence.

`relaykit_test` directly executes only that exact allowlist and must not rerun or reinterpret the selector, plan, scenario, or author inputs. Main/root performs mechanical dispatch only. Ordinary selector-path and Fast Path semantics remain unchanged. This exception does not expand or replace the ordinary 1-3 test-message approval rule.

- Beta Dogfood Hardening remains complete at artifact SHA-256 `f81b7ce1553131bb4fde3db3e6005df2e8478384e5f316828339101da093b848`; this lane does not rebuild, package, dogfood, or rerun the four-stage proof.
- `scripts/relaykit-validate.sh` now maps committed deletions and exact sensitive product paths to focused commands before execution. It rejects a dirty repository unless `--worktree` explicitly unions committed, staged, unstaged, and untracked paths. Safe local failures stop after two attempts; paid Skill queries and full E2E are explicit justified flags that execute once and are never retried.
- `$relaykit-desktop-query` requires caller-pinned catalog SHA-256, setup id, session id, and artifact SHA-256. The manual-proof app-server producer now atomically writes that exact `relaykit_lineage`, so the production evidence path and query consumer share one contract and a stale catalog cannot pass with only its own matching SHA. The backend accepts only a structured completed/submitted result, treats exit-zero failed status as failure, and suppresses non-structured success stderr. It supports `plain`, `markdown`, and `tool`, and returns redacted machine-readable metadata without query or response bodies.
- The changed-file selector now classifies project Agent config and its workflow contract script, runs the workflow contract for either, and retains deletion risk classes without passing deleted shell/TOML paths to parsers. These are focused workflow/harness corrections; no App or Gateway product source changed and no package, GUI, network, or model validation was run.
- Official model selection now uses `scripts/codex-desktop-query-official-once.sh`, a targeted one-shot App-first lifecycle with an official-only temporary gateway config. It reuses the fixed extracted App and persistent isolated login/profile, resolves the live picker label, submits once through the PID/window-bound AX driver, verifies current-run usage/rollout/screenshot evidence, and stops the owned runtime. Provider preconditions apply only to models resolved from the provider catalog; those models retain the compatibility full-harness path.
- The accepted four-stage evidence files are preserved byte-for-byte. Their `desktop_gui_tool_ui_review=rollout_verified_gui_display_not_verified` value is a historical schema inconsistency: the same evidence already has current-run tool proof, a process-bound screenshot, and `tool_gui_verified=true`. Future `automated_ax` evidence uses `derived_from_current_run_rollout_and_process_bound_screenshot` without rewriting the accepted artifact.
- The earlier pre-submit `provider_input_missing_or_invalid` attempt and the first targeted request's post-response `gateway_port_not_released` failure remain archived as root-cause evidence; neither is the latest result. After the owned-port fix, a fresh invocation entered through the Skill runner, launched the extracted RelayKit App before isolated Codex Desktop, selected GPT-5.5, pressed Send once, and exited `0` in 39 seconds. Current-run evidence records completed/200 official usage, one unique user/assistant marker binding, and a process-bound screenshot with the visible reply, no auth error, and no raw protocol text. Stderr is empty, the helper released `19777` itself, and global config/auth hashes remained unchanged. The redacted result is `dist/validation-fast-path/postfix-live-skill-result.json`; its evidence path is under `dist/codex-desktop-query/RELAYKIT_DESKTOP_QUERY_20260711T225926Z_66455/`.

Historical Desktop setup evidence:

- `dist/codex-desktop-acceptance/evidence.json` is current setup/plumbing evidence only. It proves a public-safe merged catalog, isolated app-server model listing, official/provider loopback routing contracts, unchanged global Codex signatures, and released `18787`/`19777`; its `acceptance_scope` is `public_safe_headless` and both Desktop GUI proof fields remain `not_attempted`.
- The real App-first harness uses the current Desktop-bundled Codex executable and the isolated account model cache, keeps the generated default at `gpt-5.5`, preserves current official metadata, and merges all configured provider models. It no longer promotes the stale bundled GPT-5.2 entry into the product picker; the gateway's typed unsupported-model response remains defensive behavior only.
- The current setup projection includes GPT-5.6 Sol/Terra/Luna, GPT-5.5, GPT-5.4, GPT-5.4 Mini, GPT-5.3 Codex Spark, and configured provider models; GPT-5.2 is absent. Setup/catalog proof remains distinct from live request/render proof.
- This picker result corrects the stale mid-run requirement that treated GPT-5.2 as a GUI acceptance stage. The four request stages are GPT-5.5, GPT-5.6 Luna, provider Markdown, and provider shell/tool.
- Current setup and route evidence remain separate: headless acceptance and zip dogfood prove setup/plumbing; the manual-proof evidence directories below prove the live request/render path. Fixture provider setup still does not prove real-provider compatibility.

Historical Desktop route evidence:

- `dist/codex-desktop-manual-proof/evidence.json`, `dist/codex-desktop-manual-proof-last-route/evidence.json`, and `dist/codex-desktop-manual-proof-last-complete/evidence.json` preserve the same fresh full-standard result: `route_proof_status=complete`, `desktop_gui_route_proof=automated_gui_complete`, `human_intervention_count=0`, and `usage_event_count=12`.
- One invocation submitted four uniquely bound GUI stages. GPT-5.5 and GPT-5.6 Luna each produced fresh completed/200 Official usage and a visible reply. The provider Markdown and provider tool stages produced only current-run completed/200 provider usage; multiple upstream events within a stage are accepted only because every matching event completed and one rollout thread has exactly one user marker and one assistant marker.
- The provider Markdown screenshot visibly contains a second-level heading, two numbered items, a two-column status/route table, a fenced bash block, and a bold conclusion. The provider tool screenshot plus rollout evidence prove a real `exec_command` function call, matching `function_call_output`, exact fresh output, and `Process exited with code 0`.
- The five process-bound screenshots are `before-automated-input-1.png`, `gpt55-response-1.png`, `gpt56-response-1.png`, `provider-markdown-1.png`, and `provider-tool-1.png`. They were reviewed against the exact isolated PID/window and contain no unrelated window or Keychain prompt.
- `markdown_render_verified`, `tool_gui_verified`, and `raw_protocol_absent` are true. No bare `<function_calls>`, `<invoke>`, `<parameter>`, `<tool_call>`, raw XML, or unresolved tool JSON was accepted.
- The completed run used the current Desktop-bundled Codex CLI, did not use mock OK, old usage, CLI fallback, or manually edited evidence, and released both protected ports.

Historical Signed Beta failed candidate:

Preserve artifact SHA-256 `c481ae5607c813f8f907f3c7b82252e7c709f7e10b77b1176688215736f720f3` and the superseded path-bearing candidate `c340a53682d0a615ab0409c3be8f0a290f720aa5a488c774349be615fc5020ee` as historical/ineligible. Neither is the current candidate, and their evidence must not be relabeled or mixed into the `116928...1a78` manifest.

Versioning, install/uninstall instructions, privacy docs, updater policy, and the signed package script are reserved in `docs/release-readiness.md`, `docs/update-policy.md`, and `docs/updater-readiness.md`.

## Post-Gate User Feedback Loop

The current `116928...1a78` six-stage package proof passed. Public publication is still a separate decision; for bounded beta feedback use:

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
