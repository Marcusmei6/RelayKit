# RelayKit Handoff

## Public Status

RelayKit is a local macOS menu-bar app plus bundled gateway for bridging Codex-compatible clients to official and user-configured provider routes. The repository should stay public-safe: examples, tests, and smoke fixtures use demo providers, loopback servers, or `https://example.test`; real provider details belong only in a user's local App Support config.

## Signed Beta v0.1.0 Current Candidate

Status: **incomplete**. Product freeze is commit `8c231338792d83af6579521892c43414889ae809`; harness remediations are commits `8cce29d9036afecfe5eac5deee3f153296f5324a` and `4178c51a9a3348e17a81016e16b6d19aa1cc0efb`. The fixed zip with SHA-256 `bd229bf98caf22bce9b0e1e9a763ad0faf8c060b713ee984e0b7af276a46da8c` is already Developer ID signed, notarized, and stapled. Preserve this artifact; do not rebuild, repackage, re-sign, re-notarize, or re-staple it for the remaining gate.

The latest eligible attempt is the redacted manifest at `dist/signed-beta-v0.1.0/final-current-run-20260718T083620Z/manifest.json`. It ended with `query_content_invalid`: `official-plain` was submitted exactly once and reached `evidence_verified`, while each of the other five stages remained `not_submitted` with submission count `0`. The partial attempt is failed and ineligible; it establishes no route PASS.

Later Test and Worker lanes sent zero requests and failed at execution-role/infrastructure authorization. The current blocker is `EXECUTION_ROLE_AUTHORIZATION_BLOCKED`, and the required final fresh six-stage run remains unexecuted. Earlier Official tool-text behavior and authentication drift remain historical and ineligible; neither is the current blocker.

The current global auth hash is `2efbbf0d93ba4fd4430039315fbf2bc979d7624dac7c786f2883eeb23d3bf832`. After cleanup, with no later harness run, global config changed externally at epoch `1784365089` to SHA-256 `42703377da9d04fa93862cacd268c23a27f2b9ec2bc32cdb5c9d0acff3239488`. The change is not attributed to RelayKit; RelayKit did not read, restore, or rewrite the file. It was not an in-run guard failure. A future authorized run may take the then-current value as a read-only before-baseline and must require exact after-run equality.

The tracked worktree is clean, `19777` is free, and `18787` was untouched. Private route artifacts stay under ignored `dist/` and DesktopProof directories. Signed Beta v0.1.0 remains incomplete, the public GitHub Release is not published, and the updater is not implemented. Exact remote `AXPopover` binding remains a historical blocked item and is not a release gate.

The current completion sequence is: preserve the fixed artifact; run one fresh six-stage proof against that current package; clean up the proof session and produce its redacted manifest; obtain `relaykit_test` adjudication; obtain `relaykit_cr` review; then make the release decision. A real-user beta starts only after those gates.

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

Current Signed Beta completion sequence:

1. Preserve the fixed SHA-256 `bd229bf98caf22bce9b0e1e9a763ad0faf8c060b713ee984e0b7af276a46da8c` artifact without repeating package, signing, notarization, or stapling work.
2. Run one fresh six-stage proof against the current package.
3. Clean up the proof session and generate the redacted manifest.
4. Send the unchanged evidence to `relaykit_test` for adjudication.
5. After Test, send the unchanged result to `relaykit_cr` for review.
6. Make the release decision only after both gates.

Versioning, install/uninstall instructions, privacy docs, updater policy, and the signed package script are reserved in `docs/release-readiness.md`, `docs/update-policy.md`, and `docs/updater-readiness.md`.

## Post-Gate User Feedback Loop

The next milestone is the six-stage current-package proof, then `relaykit_test`, then `relaykit_cr`, and only then a release decision. If those gates approve the candidate, begin the small real-user beta using:

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
