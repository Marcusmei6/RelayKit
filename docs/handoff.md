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

## RC1 Public Proof Handoff

### Native Responses Chain Wave 2 checkpoint

Wave 1 focused contracts passed. Wave 2 now has checked-in non-live contracts for the redacted Responses fixture, exact RelayKit AX provider setup/reopen/Gateway actions, the App-owned-Gateway `rc1_native_responses_three_stage` Desktop profile, and the immutable phase-B manifest with negative branches. This is an implementation/focused-validation checkpoint only: this lane did not build a package, launch RelayKit App or Codex Desktop, write `dist/`, send live requests, or produce a fresh phase-B PASS.

The deferred `relaykit_test` run must bind one current App zip and extracted App to an initially empty isolated provider destination, save the provider through exact AX with `api_format=openai_responses` and a Keychain reference only, relaunch and verify restored UI state, start the bundled Gateway through the UI, then complete A/B/C once each through isolated Desktop. Acceptance additionally requires Desktop WebSocket usage, Gateway SSE fixture events, the exact `printf '<marker>\n'; pwd` call and `function_call_output`, process-bound screenshot evidence, empty `failed_events`, and matching run ids and hashes in the manifest. Independent `relaykit_cr` follows that Test result.

Do not rewrite historical proof artifacts. Any prior `observation_failed_*` record remains failed and is explicitly ineligible for manifest PASS.

The RC1 public-proof final matrix passed in a fresh `relaykit_test` lane, and an independent `relaykit_cr` review passed. The visual review type was `independent_visual_review`; `automated_classifier=false` was preserved and was not relabeled. This accepts the public-proof evidence for the local ad-hoc RC1 candidate only. Planner completion still requires a final release inspection of the current artifact.

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

Signed Beta remains pending real Apple distribution inputs. Developer ID signing, notarization, stapling, updater runtime, and publishing are incomplete.

## Proof Layers

Public-safe scripts:

- `scripts/menu-bar-e2e-smoke.sh`: launches the local app with isolated fixtures, verifies the Connect/Usage/Settings product surface, and writes evidence to `dist/ui-smoke/`.
- `scripts/rc1-native-responses-proof.sh`: proves the final extracted App can start its bundled helper and preserve a native Responses request/response contract through a loopback fake upstream.
- `scripts/rc1-helper-lifecycle-proof.sh`: proves the helper is parent-bound to the final extracted App and exits after abrupt App loss without LaunchAgent or shared-service control.
- `scripts/local-beta-dogfood-smoke.sh`: rebuilds `dist/RelayKitApp-local.zip`, extracts it under `dist/dogfood-local-beta/install/`, launches that extracted app bundle, records Gatekeeper rejection as expected local beta friction, and writes public-safe evidence/screenshots to `dist/dogfood-local-beta/`.
- `scripts/export-diagnostics.sh`: writes a redacted aggregate diagnostics bundle under `dist/diagnostics/` with version, bundle id, gateway health, provider/model counts, usage aggregate, and allowlisted recent error types. Unknown or contaminated error labels become `other`; a failed sensitive-content scan removes `diagnostics.json`. It must not export provider URLs, credentials, headers, raw request/response bodies, copied Codex auth files, or Keychain item names.
- `scripts/export-diagnostics-test.sh`: injects private URL, Keychain, header, request/response, provider, and error-label sentinels into isolated fixtures and proves none appear in the exported bundle.
- `scripts/codex-desktop-acceptance.sh`: builds an isolated Codex config/catalog around a loopback gateway and fake/demo provider contract.
- `scripts/codex-desktop-manual-proof.sh`: creates isolated state under `~/Library/Application Support/RelayKit/DesktopProof/` and launches isolated Codex Desktop for GUI route proof. The intended standard live interface is one explicitly authorized `run-auto --scenario /absolute/path/scenario.json` invocation; the default manual entry remains a compatibility path. Its caller keeps query bodies in private `0600` temporary files, and the harness never asks a human to select, type, click Send, or press Enter. Fixture setup uses a random safe loopback port; the real App-first path uses the extracted RelayKit App's normal `19777` lifecycle and refuses to proceed if that port is already occupied. It discovers the current Desktop executable by bundle id `com.openai.codex`, uses the matching app-bundled `Contents/Resources/codex` catalog/app-server binary, preserves current official model metadata, and merges every configured provider model with its public display and upstream names. The default `sandbox-exec` profile denies writes to the physical global `.codex` tree, Codex/OpenAI Application Support state, Codex/CUA preference files, LaunchAgents, and the legacy gateway config while allowing the isolated DesktopProof tree. Before/after global, source, plus harness hashes fail closed on any change. Setup-only proves official + demo provider picker data; full proof still requires real isolated Desktop requests and writes evidence to `dist/codex-desktop-manual-proof/`. Only current-run evidence may advance preserved attempt/complete state, and process-bound screenshots stay with that evidence. `$relaykit-desktop-query` is a separate single-query dispatcher and is not full route proof.
- `scripts/codex-desktop-manual-proof-test.sh`: verifies Desktop executable and bundled CLI discovery, current official catalog preservation, full provider-model merging, official gateway allowlist synchronization, fail-closed global/source/harness state guards, last-route preservation, route outcome semantics, current-run tool evidence, interactive Desktop AX readiness, and bounded cleanup when an Electron process ignores `SIGTERM`.
- `scripts/full-merged-catalog-proof.sh`: proves official + demo provider catalog merge and request routing with loopback upstreams.

Private/local real-provider proof scripts are kept out of tracked public files under ignored local paths such as `scripts/private/`. They may be useful on one developer machine, but they are not the public default contract.

## Beta Boundary

`./script/build_app_bundle.sh --verify` builds and verifies the app bundle without opening the GUI. `./script/package_release.sh --verify` produces `dist/RelayKitApp-local.zip` through that headless path. This is an ad-hoc signed local beta artifact for bundle integrity only, not a Developer ID signed or notarized public release.

Current release status:

- local beta: ready.
- open-source public-safe: ready.
- local beta packaging pipeline: ready.
- Desktop live proof: complete for the current local artifact through one fresh four-stage zero-human run; this does not make the artifact a signed beta.
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

The completed local hardening objective is `RelayKit Beta Dogfood Hardening`: make the local ad-hoc beta usable, diagnosable, and feedback-ready without Developer ID signing. While Apple approval is pending, do not implement updater runtime, Sparkle, Tauri updater, real signing, notarization, publishing, global Codex config/auth mutation, shared `18787` takeover, or legacy `agent-local-gateway` control in this lane.

Current dogfood status:

- The current full zip dogfood evidence is bound to fixed artifact SHA-256 `f81b7ce1553131bb4fde3db3e6005df2e8478384e5f316828339101da093b848`, built at `2026-07-11T16:56:10Z`. Evidence records the extracted app path and normal `/usr/bin/open` LaunchServices lifecycle; `RelayKitApp.bin --ui-smoke` is not used for the dogfood claim. The dogfood harness reused the fixed zip and did not rebuild it.
- The tracked dogfood harness now requires normal LaunchServices launch from the current extracted zip, exact AX actions, full fixture provider setup, reopen persistence, a fresh reachable-model re-probe, real right-click Quit, bounded `19777` release, and RelayKit-owned WindowServer screenshots.
- The current extracted App stores provider keys with Security.framework, reads only referenced Keychain items in the App process, and sends a versioned credential map to its bundled gateway once through an anonymous stdin pipe. The gateway keeps that map in memory and fails closed when an App-provided reference is absent; it does not fall back to `/usr/bin/security` in App mode. Standalone/headless gateway launches retain the existing local Keychain fallback.
- The first fresh run exposed a real AX identity defect on the visible `Use reachable` button. The product fix only changes that control's smoke marker to record-only so its unique identifier remains on the real `AXButton`; the rerun then proved Detect models, Test connection, Use reachable, failure filtering, actionable URL/key/model errors, right-click Quit, bounded `19777` release, provider persistence, masked Keychain state after reopen, and a fresh `1 available / 0 hidden` re-probe. The fixture Keychain setup is test preparation, not proof of real-user authorization.
- Ten current-run WindowServer screenshots were reviewed image by image. They contain no black obstruction, unrelated Codex window, or Keychain authorization prompt; Usage is visibly labeled `fixture`, the reopened provider shows one available model, and the complete Quit menu is present. The bad-key state is asserted through exact AX text and is intentionally not captured while macOS secure-input redaction is active.
- `connect-first-screen.png` and the other dogfood captures prove RelayKit App product state only. They must not be cited as current Codex request-route evidence.
- Fixture provider evidence proves catalog/picker/credential plumbing only. It does not prove a real provider model, tool call, or rich-text compatibility.
- Fresh diagnostics were regenerated after the implementation diff. `dist/diagnostics/redaction-scan.json` reports `passed=true`; the sentinel self-test proves private URL, Keychain, provider, header, request/response, and contaminated error-label values are not exported.
- Keep the older acceptance conclusion unchanged: P1a backend/data-source acceptance passed; P1b Desktop GUI picker/selection/route proof was blocked because there was no isolated authenticated Desktop entry. Do not keep forcing that old blocked goal or relabel it complete.

Current Gate 0 closeout evidence:

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

- Beta Dogfood Hardening remains complete at artifact SHA-256 `f81b7ce1553131bb4fde3db3e6005df2e8478384e5f316828339101da093b848`; this lane does not rebuild, package, dogfood, or rerun the four-stage proof.
- `scripts/relaykit-validate.sh` now maps committed deletions and exact sensitive product paths to focused commands before execution. It rejects a dirty repository unless `--worktree` explicitly unions committed, staged, unstaged, and untracked paths. Safe local failures stop after two attempts; paid Skill queries and full E2E are explicit justified flags that execute once and are never retried.
- `$relaykit-desktop-query` requires caller-pinned catalog SHA-256, setup id, session id, and artifact SHA-256. The manual-proof app-server producer now atomically writes that exact `relaykit_lineage`, so the production evidence path and query consumer share one contract and a stale catalog cannot pass with only its own matching SHA. The backend accepts only a structured completed/submitted result, treats exit-zero failed status as failure, and suppresses non-structured success stderr. It supports `plain`, `markdown`, and `tool`, and returns redacted machine-readable metadata without query or response bodies.
- The changed-file selector now classifies project Agent config and its workflow contract script, runs the workflow contract for either, and retains deletion risk classes without passing deleted shell/TOML paths to parsers. These are focused workflow/harness corrections; no App or Gateway product source changed and no package, GUI, network, or model validation was run.
- Official model selection now uses `scripts/codex-desktop-query-official-once.sh`, a targeted one-shot App-first lifecycle with an official-only temporary gateway config. It reuses the fixed extracted App and persistent isolated login/profile, resolves the live picker label, submits once through the PID/window-bound AX driver, verifies current-run usage/rollout/screenshot evidence, and stops the owned runtime. Provider preconditions apply only to models resolved from the provider catalog; those models retain the compatibility full-harness path.
- The accepted four-stage evidence files are preserved byte-for-byte. Their `desktop_gui_tool_ui_review=rollout_verified_gui_display_not_verified` value is a historical schema inconsistency: the same evidence already has current-run tool proof, a process-bound screenshot, and `tool_gui_verified=true`. Future `automated_ax` evidence uses `derived_from_current_run_rollout_and_process_bound_screenshot` without rewriting the accepted artifact.
- The earlier pre-submit `provider_input_missing_or_invalid` attempt and the first targeted request's post-response `gateway_port_not_released` failure remain archived as root-cause evidence; neither is the latest result. After the owned-port fix, a fresh invocation entered through the Skill runner, launched the extracted RelayKit App before isolated Codex Desktop, selected GPT-5.5, pressed Send once, and exited `0` in 39 seconds. Current-run evidence records completed/200 official usage, one unique user/assistant marker binding, and a process-bound screenshot with the visible reply, no auth error, and no raw protocol text. Stderr is empty, the helper released `19777` itself, and global config/auth hashes remained unchanged. The redacted result is `dist/validation-fast-path/postfix-live-skill-result.json`; its evidence path is under `dist/codex-desktop-query/RELAYKIT_DESKTOP_QUERY_20260711T225926Z_66455/`.

Current Desktop setup evidence:

- `dist/codex-desktop-acceptance/evidence.json` is current setup/plumbing evidence only. It proves a public-safe merged catalog, isolated app-server model listing, official/provider loopback routing contracts, unchanged global Codex signatures, and released `18787`/`19777`; its `acceptance_scope` is `public_safe_headless` and both Desktop GUI proof fields remain `not_attempted`.
- The real App-first harness uses the current Desktop-bundled Codex executable and the isolated account model cache, keeps the generated default at `gpt-5.5`, preserves current official metadata, and merges all configured provider models. It no longer promotes the stale bundled GPT-5.2 entry into the product picker; the gateway's typed unsupported-model response remains defensive behavior only.
- The current setup projection includes GPT-5.6 Sol/Terra/Luna, GPT-5.5, GPT-5.4, GPT-5.4 Mini, GPT-5.3 Codex Spark, and configured provider models; GPT-5.2 is absent. Setup/catalog proof remains distinct from live request/render proof.
- This picker result corrects the stale mid-run requirement that treated GPT-5.2 as a GUI acceptance stage. The four request stages are GPT-5.5, GPT-5.6 Luna, provider Markdown, and provider shell/tool.
- Current setup and route evidence remain separate: headless acceptance and zip dogfood prove setup/plumbing; the manual-proof evidence directories below prove the live request/render path. Fixture provider setup still does not prove real-provider compatibility.

Last Desktop route evidence:

- `dist/codex-desktop-manual-proof/evidence.json`, `dist/codex-desktop-manual-proof-last-route/evidence.json`, and `dist/codex-desktop-manual-proof-last-complete/evidence.json` preserve the same fresh full-standard result: `route_proof_status=complete`, `desktop_gui_route_proof=automated_gui_complete`, `human_intervention_count=0`, and `usage_event_count=12`.
- One invocation submitted four uniquely bound GUI stages. GPT-5.5 and GPT-5.6 Luna each produced fresh completed/200 Official usage and a visible reply. The provider Markdown and provider tool stages produced only current-run completed/200 provider usage; multiple upstream events within a stage are accepted only because every matching event completed and one rollout thread has exactly one user marker and one assistant marker.
- The provider Markdown screenshot visibly contains a second-level heading, two numbered items, a two-column status/route table, a fenced bash block, and a bold conclusion. The provider tool screenshot plus rollout evidence prove a real `exec_command` function call, matching `function_call_output`, exact fresh output, and `Process exited with code 0`.
- The five process-bound screenshots are `before-automated-input-1.png`, `gpt55-response-1.png`, `gpt56-response-1.png`, `provider-markdown-1.png`, and `provider-tool-1.png`. They were reviewed against the exact isolated PID/window and contain no unrelated window or Keychain prompt.
- `markdown_render_verified`, `tool_gui_verified`, and `raw_protocol_absent` are true. No bare `<function_calls>`, `<invoke>`, `<parameter>`, `<tool_call>`, raw XML, or unresolved tool JSON was accepted.
- The completed run used the current Desktop-bundled Codex CLI, did not use mock OK, old usage, CLI fallback, or manually edited evidence, and released both protected ports.

Automated Desktop route-proof contract:

1. Invoke the four-stage harness only after live requests are explicitly authorized. Accessibility permission, authenticated Desktop state, and repository-external provider configuration are one-time prerequisites.
2. Create a unique `0700` temporary directory with separate `0600` query files and a `0600` v1 scenario. Query bodies must not enter argv, environment variables, tracked files, reports, or evidence.
3. Invoke exactly `./scripts/codex-desktop-manual-proof.sh run-auto --scenario /absolute/path/scenario.json` with stdin closed. Do not add a manual fallback or resubmit an ambiguous paid request.
4. The harness selects the model and submits every stage itself. Auth, Keychain, Accessibility, PID/window, or selector failures must end with a bounded machine-readable error instead of asking a person to select, type, click Send, or press Enter.
5. For a harness-only rerun, set both `RELAYKIT_DESKTOP_PROOF_REUSE_CURRENT_ZIP=1` and `RELAYKIT_DESKTOP_PROOF_REUSE_EXTRACTED_APP=1`, verify the product artifact SHA before/after, and do not invoke a package script. Accept full-standard success only when the harness exits `0` and current evidence records `desktop_gui_route_proof=automated_gui_complete`, `human_intervention_count=0`, unchanged product/harness/scenario layers, and the fixed product artifact SHA. The accepted current result satisfies this contract.

Manual compatibility rerun contract:

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
