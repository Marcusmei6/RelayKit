# RelayKit Development Plan

## Goal

Build a public, Apple-native local gateway kit for agentic coding tools, starting with Codex-compatible routing while keeping the architecture general enough for future clients.

## Product Shape

RelayKit should sit between Beacon and CC Switch:

- lighter and more native than CC Switch;
- more capable as a gateway than Beacon;
- safe to publish without private infrastructure.

## Architecture

```text
SwiftUI/AppKit app
  -> starts and controls Go helper
  -> stores secrets in Keychain
  -> writes client config
  -> shows status, logs, usage

Go gateway helper
  -> exposes loopback HTTP API
  -> loads provider profiles
  -> adapts public upstream APIs
  -> writes local usage events
  -> generates model catalog
```

## Phase 0: Repository Foundation

Status: complete.

- Initialized Git repository.
- Added open-source boundary docs.
- Added `app/` and `gateway/` ownership rules.
- Added minimal gateway with `/healthz`, `/v1/models`, `/v1/responses`.
- Added tests and initial commits.

## Phase 1: Gateway MVP

Status: complete.

- Defined `ProviderProfile` schema.
- Loaded profiles from JSON.
- Added OpenAI Chat adapter.
- Added model catalog generator.
- Added request/response tests.
- Added CLI flags for config path and listen address.

Minimal public `ProviderProfile` contract:

```json
{
  "id": "local-openai-compatible",
  "name": "Local OpenAI Compatible",
  "base_url": "http://127.0.0.1:11434/v1",
  "api_format": "openai_chat",
  "auth_env": "RELAYKIT_EXAMPLE_API_KEY",
  "models": [
    {
      "id": "qwen3-coder",
      "display_name": "Qwen3 Coder",
      "context_window": 128000
    }
  ]
}
```

Phase 1 should reject missing `id`, `base_url`, `api_format`, or empty `models`. `auth_env` is optional for local fake providers and must name an environment variable, not contain a secret.

## Phase 2: Streaming MVP

Status: complete for text streaming MVP.

- Added SSE parser.
- Translated Chat Completions stream into Responses stream.
- Preserved output text, finish reason, and usage when present.
- Added malformed/truncated stream tests.

## Phase 3: Anthropic Adapter

Status: complete for Messages MVP.

- Added Messages request adapter.
- Added Messages stream adapter.
- Kept unsupported fields explicit and tested.
- Tool-use hardening remains a later focused item.

## Phase 4: Mac App MVP

Status: local usable alpha complete.

- Created SwiftUI app shell.
- Added a repository-local `./script/build_and_run.sh` entrypoint that builds the gateway binary, bundles it inside a SwiftPM macOS app bundle, and opens the app.
- Added development gateway helper lifecycle.
- Showed gateway status.
- Read `/healthz` and `/v1/models`.
- Activated Codex config with explicit source/target paths and backup/rollback output.
- Added local alpha smoke script.
- Kept the default provider config pointed at the public no-secret demo file, `examples/providers.example.json`.
- Keychain credential storage remains deferred until explicitly selected.

## Phase 4.5: Helper Lifecycle Hardening

Status: local LaunchAgent flow complete.

- Added the smallest LaunchAgent flow for the existing built gateway binary.
- Kept explicit provider config paths.
- Did not add credentials, signing, notarization, or publishing.
- Kept uninstall/stop behavior scoped to RelayKit-owned helper state.
- Kept the listen address fixed at `127.0.0.1:19777` and helper stdout/stderr at `/tmp/relay.{out,err}.log` for this local alpha slice.
- Preserve `./scripts/local-alpha-smoke.sh` as the baseline, including temporary LaunchAgent install/status/health/logs/uninstall coverage.

## Phase 5: Local Observability

Status: local usage view implemented.

- Added a local helper log tail command for `/tmp/relay.{out,err}.log`.
- Added local usage JSONL writes with the conservative contract below.
- Added local usage summary by day/provider/model.
- Added app usage view backed by the local summary CLI, including request, token, and duration aggregates.
- Covered local usage summary in the alpha smoke.
- Keep cloud upload out of scope.

Minimal usage JSONL contract:

- Path: `~/Library/Application Support/RelayKit/usage.jsonl` for the app/helper flow; tests may pass an explicit temporary path.
- Format: one JSON object per completed gateway request.
- Allowed fields: timestamp, request id, provider id, model, route, streaming flag, status, HTTP status, input tokens, output tokens, total tokens, duration milliseconds, and error code.
- Forbidden fields: request body, response body, prompts, tool arguments, headers, authorization values, cookies, API keys, local usernames, private domains, and raw upstream URLs containing credentials.
- Unknown token counts may be omitted or written as zero; do not invent estimates.
- Writes are local-only append operations. No cloud upload, daemon sync, or hosted telemetry.
- App summary may read this file and aggregate by day/provider/model only.
- Summary output is a JSON array sorted by day, provider id, and model. Fields: day, provider id, model, requests, input tokens, output tokens, total tokens, and duration milliseconds.

These defaults are intentionally conservative and are not a product blocker. If a later caller needs more fields, add them behind review with a public-boundary test.

## Phase 5.5: Local Configuration Editing

Status: minimal provider config editor implemented.

- Added provider config editing without secrets.
- Edit only public provider metadata and model list through explicit JSON text: provider id, display name, base URL, API format, auth env var name, model id, display name, and context window.
- Never edit, display, or store API keys, bearer tokens, cookies, or credential values.
- Preserve explicit config paths; no default writes to private provider configs.
- Validate JSON before displaying or writing and keep backup behavior for existing files.
- Reject credential-looking keys/values and base URLs with userinfo, query strings, or fragments before writing.
- Cover the credential-boundary validator through the SwiftPM `RelayKitAppValidationTests` executable run by local smoke.

## Phase 3.5/3.6: Anthropic Tool-Use Hardening

Status: tool-use mapping implemented for non-streaming and streaming fake upstreams.

- Mapped minimal Anthropic `tool_use` blocks to Responses `function_call` output items using fake upstream tests.
- Preserve unsupported cases as explicit errors or documented omissions.
- Did not add real provider calls or private provider behavior.
- Streaming tool-use mapping is implemented for fake upstream streams.

Minimal streaming tool-use contract:

- Fake upstream tests only; no real providers.
- Map `content_block_start` tool-use metadata to a Responses `function_call` item start when enough name/id data is present.
- Accumulate `input_json_delta` fragments into the function call arguments string without parsing or executing it.
- Emit a final function call output item before `response.completed`.
- If a stream ends with incomplete tool arguments, emit `response.error` and do not invent valid JSON.
- Keep text delta streaming behavior unchanged.
- Do not execute tools or record tool arguments in usage JSONL.

## Phase 6: Local Release Readiness

Status: README refreshed and agent model routes scrubbed to public defaults.

- Made README install/run commands match the current local alpha.
- Added macOS ad-hoc local zip packaging with extraction and bundled-gateway verification.
- Run `docs/public-boundary-checklist.md`.
- Scrubbed `.codex/agents/*.toml` to public model defaults.
- Keep Developer ID signing, notarization, publishing, and GitHub push out of scope until explicitly requested.

## Phase 7: P0 Menu-Bar Control Center

Status: local P0 regression complete; remaining items require future schema or distribution decisions.

- Primary surface is a menu-bar resident control-center, not a dashboard window.
- Main tabs are `接入`, `Usage`, and `设置`.
- `接入` owns CLI selection, Codex active target state, disabled Claude Code placeholder, redacted local catalog rows, catalog detail overlay, and provider add entry. Gateway port/health/model state stays in the global header; lifecycle smoke may exercise start/stop/restart without putting those controls back in the Connect catalog card.
- `Usage` reads real local usage summaries only; empty state is allowed, mock cards are not.
- `设置` may show only settings wired to real state; unfinished settings stay hidden or disabled.
- Provider/model add uses a form sheet that writes the current public provider schema. JSON editing remains a fallback, not the primary P0 path.
- Provider form P0 persists provider id/name, source/prefix routing metadata, base/catalog URLs, API format, credential reference, model mapping, context window, and safe capability/priority metadata.
- Credentials are references only: env var, Keychain item name, or key-file reference. Never store or display credential values.
- P0 regression includes screenshot evidence under `dist/ui-smoke/`, redacted reference model coverage under `dist/reference-model-coverage.json`, and a temporary Codex E2E smoke under `dist/codex-e2e/` that never writes real `~/.codex/config.toml`.
- Replay/Kaboo-style UI conformance repair keeps the status item compact and visible, opens an anchored popover, moves global gateway/Codex state into the header across tabs, makes `Usage` KPI/card-first with real local data or a real empty state, and presents `设置` as real action cards with raw paths behind Advanced controls.
- Normal LaunchServices launch is covered by the local bundle contract: `CFBundleExecutable` points at the real Mach-O `RelayKitApp.bin`; local scripts call that binary directly for verification so the app bundle remains code-signable.
- `设置` includes real persisted Appearance (`System` / `Light` / `Dark`) and a real macOS Launch at login row backed by `SMAppService`; the switch is refreshed from macOS status, and local unsigned login-item failures are reported as macOS status/error instead of fake success.
- Menu-bar UI smoke now writes screenshot plus evidence JSON under `dist/ui-smoke/` and verifies `open -n dist/RelayKitApp.app --args ...`, compact status-item visibility, anchored popover state, semantic tab sections, Settings state, Light appearance persistence, provider modal capture, and stale RelayKit-owned process cleanup.
- Connect now treats the running local `agent-local-gateway` reference service as read-only catalog input, groups discovered models by public source/owner, records only redacted source/model counts in smoke evidence, and keeps execution auth state explicit instead of listing private model IDs as configured RelayKit routes.
- Gateway OpenAI Chat streaming Responses events must stay compatible with Codex CLI: accept Responses input message parts, emit output item/content part lifecycle events before text deltas, and include Responses-shaped usage totals in `response.completed`.
- Remaining non-P0 work: Claude Code adaptation, advanced provider capability schema/import, signing/notarization/publishing, and real public provider presets.

## Phase 7.5: Provider Credential and Capability Contract

Status: public-safe contract implemented for env, Keychain, and key-file references.

- `docs/spec/provider-profile-contract.md` defines `credential_ref`, `capabilities`, `routing`, `catalog`, and model `upstream_model`.
- Gateway config loading validates public-safe credential references and metadata, rejects secret-looking values, requires catalog model URLs to be http(s) URLs without credentials/query/fragment, and still routes by explicit model id.
- Runtime auth supports `credential_ref.kind = "env"`, `credential_ref.kind = "keychain"`, `credential_ref.kind = "key_file"`, and legacy `auth_env`.
- Direct Keychain and key-file providers are probed during `/v1/models` with a bounded local timeout. Unhealthy models are omitted from the ready catalog and only redacted aggregate health counts are returned.
- The app provider form writes source/prefix/protocol/base/catalog/model-mapping metadata and credential references through `credential_ref`; optional Keychain credential input is written only to macOS Keychain.
- Remaining work that requires explicit selection: credential migration UI, public provider presets, and richer capability discovery/import.

## Phase 7.6: Beta Dogfood Hardening

Status: Gate 0 local Beta Dogfood Hardening is verified for its fixed product candidate. Apple Developer identity and notarization credentials are now prepared, but Signed Beta packaging, notarization, stapling, publishing, and updater work remain outside the current RC1 product-closeout goal.

- Accept dogfood only from the current `dist/RelayKitApp-local.zip` extracted app and a normal LaunchServices lifecycle.
- Public demo providers prove setup, Keychain, catalog, filtering, and actionable error plumbing only. Real route compatibility requires an ignored local provider input.
- Real Desktop setup projects the official picker from the isolated account model cache, not the stale bundled fallback alone. The current contract includes GPT-5.6 variants, GPT-5.5, and GPT-5.3 Codex Spark, excludes GPT-5.2 from the picker, and still keeps a typed unsupported-model gateway error as defensive behavior.
- Isolated Desktop route success requires fresh completed Official and provider usage, a real function call plus output, process-bound current-run screenshots, and no raw XML/`function_calls` display.
- The GUI route sequence is GPT-5.5, GPT-5.6 Luna, provider Markdown, and provider shell/tool. GPT-5.2 is not a GUI acceptance stage.
- Route-proof evidence records three independent layers: `product_artifact_sha256` for the zip, `harness_sha256` for the proof script plus AX driver, and `scenario_sha256` for the private scenario. It also retains the product source snapshot and individual harness file hashes. Any layer changing during a live run fails closed, but a harness-only change does not trigger a product rebuild.
- Setup-only evidence, old usage, fixed mock replies, manually post-processed evidence, and requests that appear in the development thread are not route proof.
- The current coherent product candidate is bound to zip SHA-256 `f81b7ce1553131bb4fde3db3e6005df2e8478384e5f316828339101da093b848` and product source snapshot `19aa2c30ef9a44e7c400f9a2595e0fa4cb4527c9e68a04b5fdef55e978c71882`. One fresh standard invocation completed all four GUI stages with harness SHA-256 `97e685f050ef82d9d2e18d4661811d812c3b0ddbc0598a611fbd7b4833c4c7e0`, scenario SHA-256 `334288ccf885c42f99366ff9694de34d0e78688f8e2e6082f366bfe5f1f8fa19`, `desktop_gui_route_proof=automated_gui_complete`, and zero human intervention.
- Current extracted-zip dogfood now matches that same `f81b7ce...` artifact. Normal LaunchServices launch, Connect/Settings/Usage, gateway restart, provider persistence/re-probe, saved Keychain state, actionable errors, right-click Quit, and bounded `19777` release passed; all ten current-run screenshots were reviewed and contain no black obstruction, unrelated Codex window, or Keychain prompt.
- The adjacent screenshot issues were harness-only false negatives. The final analyzer verifies structured Markdown inside the assistant response region, rejects prompt-only and flattened text, can reveal a unique exact heading through the bound AX window, and aggregates process-bound captures without weakening raw-protocol checks. The fixed zip and extracted App were reused byte-for-byte; no package rebuild was performed for these harness changes.
- Isolated Desktop sandbox policy denies writes to the physical global `.codex` tree, Codex/OpenAI Application Support state, Codex/CUA preferences, LaunchAgents, and the legacy gateway config while allowing only the isolated DesktopProof state. A real `sandbox-exec` self-test enforces this boundary; hash/signature/notify changes still fail closed with no repair path.
- The accepted result comes from one `run-auto --scenario` invocation, not aggregation. Formal, last-route, and reserved last-complete evidence preserve that same result. The separate `$relaykit-desktop-query` dispatcher remains a one-query tool and cannot satisfy this gate by itself.
- One GUI stage may legitimately produce multiple matching upstream usage events. The evaluator requires every matching event to be completed/200 and separately requires a unique rollout thread with one user marker and one assistant marker, instead of treating usage cardinality as submission cardinality.
- Custom-scenario completion may update last-route/custom evidence only. It cannot overwrite the reserved full-standard last-complete slot.
- Validation is tiered. Product changes run focused tests, then one package plus full E2E after the coherent root-cause group is complete. Harness/test changes run focused self-tests and reuse the fixed zip/extracted App with `RELAYKIT_DESKTOP_PROOF_REUSE_CURRENT_ZIP=1` and `RELAYKIT_DESKTOP_PROOF_REUSE_EXTRACTED_APP=1`. Docs-only changes run documentation/public-boundary/diff checks and do not build or launch GUI.
- Accessibility permission, authenticated Desktop state, and repository-external provider configuration are one-time prerequisites. Once present, routine automated validation must never ask a human to select a model, paste or type a query, click Send, or press Enter; auth/selector/PID/window failures must fail fast with machine-readable evidence.
- Fresh Swift, Go, proof self-tests, extracted-App dogfood, menu AX smoke, public-safe acceptance, diagnostics redaction, public-boundary, shell syntax, and diff checks passed. Build/package verification remains bound to the fixed product artifact and was intentionally not repeated after harness-only changes.
- Do not add signing, notarization, updater runtime, publishing, shared port `18787` takeover, global Codex config/auth mutation, or LaunchAgent control to this phase.

## Phase 7.7: Validation Fast Path and Desktop Query Skill

Status: selector, Skill contracts, evidence-state fix, and the post-fix live Skill E2E are verified. The default backend routes official models through a targeted one-shot App-first lifecycle with no provider precondition; provider models retain the compatibility full-harness path. The first live request exposed a cleanup defect after its GPT-5.5 response completed: the lifecycle omitted the owned `19777` port file, so the App-spawned gateway fallback was not identified. After the root fix, a fresh Skill invocation exited `0` with one Send, completed/200 usage, a unique rollout marker binding, a process-bound GUI screenshot, empty stderr, unchanged global Codex files, and both protected ports released by the helper. Beta Dogfood Hardening evidence remains accepted and was not rerun by this phase.

- `scripts/relaykit-validate.sh` is the deterministic changed-file selector. Its JSON plan records files, classes, selected/skipped commands, reasons, and build/package/GUI/live/full requirements before execution.
- Docs and workflow/Skill/harness changes stay on syntax and focused contract tests. Gateway changes select affected Go packages. Ordinary App UI selects Swift build/validation plus no-model menu smoke. Packaging inputs alone select package and extracted-App dogfood.
- A single paid `$relaykit-desktop-query` request is an explicit high-risk leaf selected with `--live-query`; it is never the default validation entry. Full four-stage proof requires `--full` and is not part of this phase's execution.
- The Skill accepts `plain`, `markdown`, or `tool`, requires explicit catalog evidence with caller-pinned catalog SHA-256 plus matching setup/session/artifact lineage, and does not search stale `dist` directories.
- The Skill remains one-shot. Persistent prepare/query/status/finalize/stop lifecycle, watchdog, and finalization profiles remain the next-session design, not this phase.
- Future manual-proof evidence reports GUI tool review as verified for both `manual_user_only` and `automated_ax` when current-run rollout, process-bound screenshot, and render evidence agree. Previously accepted artifacts are not rewritten.
- The initial failed lifecycle remains archived at `dist/validation-fast-path/live-skill-request-evidence.json`; it records a completed request followed by `gateway_port_not_released`, not a model failure. The authoritative post-fix result is `dist/validation-fast-path/postfix-live-skill-result.json`, which points to the fresh targeted-query evidence under `dist/codex-desktop-query/`. That run exited `0` in 39 seconds and proves current-run GPT-5.5 completed/200 usage, one user/assistant marker pair, a bound Desktop screenshot, clean protocol rendering, exact cleanup, and global state preservation.
- Group one coherent root-cause change before execution, never repeat an unchanged validation layer, and retry the same failing command at most once.

## Task Ownership

- `relaykit_planner` (`gpt-5.6-sol` / `xhigh`) is the sole delegation owner and owns roadmap, bounded dispatch, convergence, validation/review gates, and public boundary. It runs at most two disjoint write lanes and never auto-expands backlog.
- `relaykit_gateway` (`gpt-5.6-luna` / `xhigh`) owns only `gateway/**` protocol, routing, catalog, config, usage, and tests.
- `relaykit_app` (`gpt-5.6-luna` / `xhigh`) owns only `app/**` SwiftUI/AppKit, Keychain, helper lifecycle, config activation, and tests.
- `relaykit_worker` (`gpt-5.6-sol` / `high`) owns assigned docs, examples, project Agent/Skill config, and ordinary tooling; it never substitutes for App or Gateway.
- `relaykit_test` (`gpt-5.6-luna` / `medium`): Eligible Tier 0/1 Fast Path executes the Planner exact command allowlist directly; otherwise Test executes the selector-generated plan. Its workspace write access is limited to ignored build/test artifacts, with byte-identical tracked-worktree status required before and after execution.
- `relaykit_cr` (`gpt-5.6-sol` / `high`) owns read-only findings and never edits or delegates.
- `relaykit_release` (`gpt-5.6-luna` / `xhigh`) owns assigned packaging/signing/notarization/release paths, not product business code.

## Phase 7.8: Workflow 5.6 Migration and Fast Path Safety

Status: Workflow 5.6 is current on `main`; the seven-role model matrix and minimal Main/Planner responsibility contract are implemented.

- Keep `max_threads = 8` and `max_depth = 2`; allowed efforts are xhigh, high, and medium, and no role uses Ultra or Max.
- The exact seven-role model matrix is Planner Sol/xhigh, Gateway Terra/high, App Terra/high, Worker Sol/high, Test Luna/medium, CR Sol/high, and Release Terra/high; Ultra and Max are forbidden.
- Main/root owns goal registration, pause/resume, risk assessment, and user confirmation. Main/root does not decompose tasks or implement changes. Planner decomposes work, designates and dispatches bounded roles, and owns remediation.
- Main/root may approve one batch of 1-3 test messages only for the current task-bound isolated proof/session. Main/root approves only; the Planner-designated `relaykit_test` or `relaykit_worker` sends the messages. The batch is limited to 3 messages, stays bound to that isolated proof/session, does not read, refresh, copy, or migrate credentials, and does not touch global config/auth, LaunchAgents, shared services, or port `18787`. It does not publish, sign, delete, perform irreversible actions, automatically retry, or expand the approved count. More than 3 messages, any retry or count expansion, auth/login, shared ports or services, global config/auth, signing or release, and destructive or irreversible actions require user confirmation.
- Test, CR, and Release are sequential gates after implementation lanes close.
- Backlog Expansion is explicit opt-in and disabled by default.
- Tier 0/1 Fast Validation Path is eligible only when all of these are true: Validation Tier is 0 or 1; changed paths are limited to docs, public agent TOML, the workflow contract test, or ordinary project config; scope excludes app/**, gateway/**, credentials, Keychain, auth, shared services, LaunchAgents, port 18787, global Codex config, build, package, GUI, network, live requests, signing, and release; and Planner supplies an exact command allowlist.
- An eligible Fast Path uses exactly one Planner, one bounded Worker, one Test, and one CR. Test executes the exact allowlist directly without selector generation or `relaykit-validate.sh --plan-only`. Tier 2/3 and every ineligible change retain the selector path.
- Main/root still performs no decomposition or implementation, but may verbatim-correct a missing ROLE field, field-name typo, or command-transcription error without replanning. Allow at most one remediation. After a test-assertion-only fix, rerun only the corresponding test and minimal CR recheck without repeating passed runtime metadata. Nonblocking Medium/Low findings become backlog evidence without scope expansion.

Signed Beta live-gate exception: `execution_allowed=false` from the signed-beta plan means plan-only and forbids selector-driven automatic execution; it does not deny a separately user-authorized, Planner-bounded one-time live gate.

The only permitted global config/auth interaction is the designated read-only non-content metadata/hash/signature guard. The guard must not mutate, copy, repair, restore, refresh, migrate, parse, inspect, print, or disclose global content. It may accept the current pre-run metadata/hash/signature as the baseline, must require exact before/after equality, and must fail closed on any mismatch or guard error.

For this exception, Planner must bind one exact isolated session, artifact, scenario, and command allowlist to one fresh run: at most six commands, each command exactly once, with no retry, continuation, aggregation, relabeling, or reuse. The allowlist must encode redaction, the non-content global guard, no other global config/auth or shared-service/LaunchAgent access, no port `18787`, exact cleanup, and current run-bound evidence.

`relaykit_test` directly executes only that exact allowlist and must not rerun or reinterpret the selector, plan, scenario, or author inputs. Main/root performs mechanical dispatch only. Ordinary selector-path and Fast Path semantics remain unchanged. This exception does not expand or replace the ordinary 1-3 test-message approval rule.

- Fast Path execution gives safe local commands at most two attempts and live/full commands exactly one. Committed deletions are selected, but deleted shell/TOML paths are never passed to syntax parsers. `--worktree` unions committed/staged/unstaged/untracked paths, and dirty repositories fail without it. `.codex/config.toml` and the workflow contract script select the full workflow contract. Exact current Gateway/App sensitive paths drive high-risk selection.
- The manual-proof app-server producer atomically writes `relaykit_lineage` with current setup id, session id, and product artifact SHA-256. The query backend accepts only one structured `status=complete` result with submitted state and evidence path; an exit-zero failed/invalid result remains a redacted failure, and non-structured success stderr is not forwarded.

See `docs/agents/README.md` for the assignment header and dispatch rules.

## Phase 7.9: RC1 Public Proof Remediation

Status: implementation complete for its bound artifact; the fresh final matrix passed in `relaykit_test`, independent `relaykit_cr` passed, and `automated_classifier=false` was preserved for local ad-hoc RC1 acceptance. Phase 7.10 records the newer product-level candidate result; Signed Beta remains a separate, unexecuted distribution lane.

- The tracked remote-Mac acceptance guide and resume helper are machine-neutral. Real host, account, address, and checkout paths are local environment inputs only; the pre-remediation originals remain in ignored `docs/private/` and `scripts/private/` archives.
- `scripts/public-boundary-check.sh` scans tracked text for personal home paths, private network addresses, SSH targets, and machine identifiers in addition to existing provider, credential, and sensitive-path gates. Its contract proves ignored and untracked fixture content stays out of scope while forcibly tracked private/build paths fail.
- Public fake fixtures use an explicit `RELAYKIT_FAKE_SENTINEL_...` marker that is not credential-shaped. A fake marker may prove redaction or routing behavior; it must never weaken rejection of credential-shaped content.
- `scripts/rc1-native-responses-proof.sh` launches the final extracted App first, starts its bundled helper through the App UI, and proves one native OpenAI Responses request against a loopback-only fake upstream. Evidence contains booleans, counts, paths, and artifact hashes only—not request/response bodies.
- `scripts/rc1-helper-lifecycle-proof.sh` launches the same final extracted App, starts its helper through the App UI, kills the App without graceful cleanup, and requires the parent-bound helper to exit and release `19777`.
- `scripts/menu-bar-e2e-smoke.sh` accepts `RELAYKIT_REUSE_FINAL_BUNDLE=1`, verifies the supplied bundle signature, and skips rebuilding so the menu, native Responses, and lifecycle proofs can share one extracted package artifact.
- `./scripts/relaykit-validate.sh --plan-only --rc1` selects one fixed RC1 matrix: diff/public-boundary checks, Swift and Go validation, one package build, then menu/native/lifecycle proof against `dist/verify-release/RelayKitApp.app`. This matrix uses fake loopback traffic only; it does not select a paid live query or the four-stage Desktop proof.
- Implementation lanes must run only the focused contract commands. Package creation, menu GUI smoke, native App-first proof, helper lifecycle proof, and final matrix execution belong to `relaykit_test`.

## Phase 7.10: RC1 Native Responses Chain Wave 2

Status: complete for the local ad-hoc RC1 product gate. Signed Beta remains a separate, unexecuted distribution lane. The fixed zip SHA-256 is `8a4050017c4ca21b85c3ef645c02d31cfbe0e901c38b5578f74ddf5cdb76d3dc`; its fresh extraction and the exercised App tree both hash to `0e965ee792beb2a62c7494db3acb4b6e5c2c3bc03bc06c381323c14a740bca5c` under the current bundle-tree algorithm.

- The native 480x760 `NSPopover` remains the product surface. Failed custom AX role/parent/attachment retries were removed. The historical `exact remote AXPopover proof blocked` conclusion remains accurate but is separated from the product gate.
- Two current-package ordinary launches passed zero-surface-before and unique same-PID WindowServer-surface-after checks. The current App-first flow saved a Keychain-reference-only native Responses provider, restored it after reopening the same extracted App, retained one reachable/available model, exposed it from the App-owned gateway, and passed the ordinary right-click Quit/19777-release gate.
- One isolated Desktop run completed the plain, Markdown, and real shell/tool stages with exact PID/window and rollout bindings. Markdown structure and the native tool block are visible in current-run screenshots; the function call/output match, the command exited 0, and no raw XML/`function_calls` or unresolved tool payload was accepted.

- The top-level proof begins with an empty isolated provider destination and uses exact RelayKit PID/window-bound AX to save provider name, loopback URL, synthetic key, model, and `openai_responses`. It rejects completed provider injection, `key_file`, and curl-only proof.
- Saved config must contain `api_format=openai_responses` and a Keychain reference only. The same extracted App must relaunch and expose the restored protocol, URL, model, and saved-key state before its bundled Gateway is started through the UI.
- The dedicated `rc1_native_responses_three_stage` Desktop profile attaches to the App-owned Gateway and UI-saved config. Stages A/B/C each have exactly one submission and require, respectively, a text marker, native Markdown structure, and the exact shell command plus `pwd` with a verified `function_call_output` roundtrip.
- Current evidence is run-bound and hash-bound. A PASS manifest requires every named predicate, empty `failed_events`, all three stages in `evidence_verified/submitted` state, Desktop WebSocket ingress, Gateway SSE egress, tool roundtrip, matching run ids, and current harness/scenario/App zip/screenshot/usage/provider-event/provider-config hashes.
- Historical `observation_failed_*` evidence remains failed and untouched. It cannot be relabeled, copied, or used to derive phase-B PASS.
- Failed candidates `462d3b2bfe9a2a5a910e0c6d4091a1fd1ec67b29b0ae9fd63ce18045c3005001` and `be70c14b22483fb28e62f51854d0659d4f567fd7837b53690d302a0e2b9c1c2f`, plus historical run `rc1-native-20260716T111701Z-external-sandbox`, remain ineligible for the current candidate.
- The RC1 stage ledger, process-bound screenshots, rollout binding, usage, provider events, and tool evidence are authoritative for A/B/C. The generic manual-proof render summary is a separate schema and must not override or substitute for the RC1 stage result.
- Current-candidate Desktop AX/manual/RC1 contracts, Swift, Go test/vet/gofmt, public-boundary, diagnostics redaction, frozen package verification, current App/Desktop evidence, and cleanup checks passed. `dist/rc1-final-current-run-20260717/final/product-evidence.json` is the current product truth; the manifest is generated from it only after the tracked worktree is committed and clean.

## Phase 7.11: Native Official Responses Proxy

Status: complete in installed Developer-ID/notarized v0.1.5 build 14. Earlier builds exposed catalog schema, startup ordering, and Codex 0.142.3 compaction-retry incompatibilities; build 14 passes installed catalog, dual-provider, and same-thread provider -> Official -> provider -> Official gates.

- Replace the `codex_home` official route's per-request `codex exec` subprocess with a native Responses reverse proxy. Preserve the inbound Responses body, replace only the public model id with its upstream mapping, and use the isolated Codex login's OAuth access token plus `ChatGPT-Account-Id`.
- Forward only the explicit Codex protocol header allowlist. Never forward the inbound Desktop Authorization header, cookies, provider credentials, or arbitrary headers.
- Support native JSON and SSE on `POST /v1/responses`, SSE-to-Desktop WebSocket bridging, and `POST /v1/responses/compact` to the official `/responses/compact` endpoint. Compaction output remains an opaque Responses item; RelayKit must not decode or invent encrypted compaction content.
- On one upstream 401, refresh once through the public Codex OAuth client contract, atomically update only the isolated `auth.json`, preserve unknown/root/token fields, and retry the original request once. RelayKit writers share a cross-process lock and compare the exact auth snapshot under that lock before rename; an external update observed before the guarded write wins. Errors and usage remain sanitized.
- Remove the obsolete subprocess prompt flattening, deterministic shell-decision shim, 120-second subprocess timeout, structural trace, and their fixtures. Provider adapters and non-`codex_home` compatibility paths remain unchanged.
- Mixed-history preservation: Responses assistant message parts use output_text. The Anthropic adapter now preserves those assistant turns instead of dropping them and merging adjacent user instructions; a focused RED/GREEN regression covers user/assistant/user ordering and latest-user isolation.
- Headerless official SSE compatibility: a current-package same-thread provider -> official run proved that the live Codex backend can return HTTP 200 with a valid terminal SSE body and no Content-Type header. Official streaming now accepts only an absent header or an explicit text/event-stream header, while the existing strict bounded SSE parser still rejects malformed/truncated bodies. A focused RED/GREEN regression and real isolated source-helper WebSocket turns pass.
- Headerless official compact compatibility: the live unary backend likewise returns HTTP 200 valid compact-history JSON without Content-Type and without normal Responses status/model fields. Only the compact route accepts the absent header; a separate 16 MiB-bounded strict object/output-item validator preserves opaque compaction fields, rejects output:null and malformed items, and leaves ordinary JSON routing unchanged. Focused RED/GREEN tests and a real isolated source-helper compact request pass.
- Provider-to-official remote-compaction-v2 fallback: pre-turn compaction on a model switch starts with the previous model. Adapter-backed providers cannot return the reserved encrypted compaction item. Newer Codex cores retry an InvalidRequest with the incoming Official model, but the installed 0.142.3 core fails the turn instead. Codex 0.142.3 emits an Official-model prewarm immediately before the previous-provider compaction request. RelayKit records a 30-second, one-shot target hint keyed by exact session/thread, with 256-byte ID and 256-entry fail-closed bounds and routes the untouched compaction request only when that hint names an exact configured Official model; provider targets, missing/expired/consumed hints, and ordinary turns cannot cross the route boundary. Without that proof it retains the local InvalidRequest, and native Responses providers remain untouched. Focused RED/GREEN covers exact multi-model selection, one-shot/provider rejection, and both HTTP/WebSocket transports.
- Catalog schema compatibility: Codex 0.142.3 rejects the entire generated catalog when `supports_reasoning_summaries` is absent and silently exposes its built-in fallback list. RelayKit now fills this older required boolean only when the current Desktop template omits it. A focused RED/GREEN merge regression and isolated real `model/list` proof restore all ten entries, including both configured provider models.
- Upgrade compatibility: ordinary App startup no longer runs `codex login status` to decide whether an existing isolated login is connected. It validates only the local `auth.json` structure (`chatgpt` mode plus non-empty access/account/refresh fields), never logs or displays values, and reserves Codex execution for first-time device authorization and catalog projection. Catalog projection prefers the Desktop bundled CLI, then controlled absolute executable paths in `~/.local/bin` and Homebrew; it always runs fresh under the RelayKit-isolated account and never reuses an unversioned persisted catalog. Ordinary launch now performs that local auth-file check synchronously while `AppModel` is initialized, resolves AppKit executable state on MainActor, builds the fresh catalog in a detached task, and reuses that catalog for both runtime projection and the merged picker catalog before starting one complete gateway. This removes the transient provider-only helper without blocking UI establishment on the Codex subprocess.
- Source evidence: focused RED/GREEN tests cover native auth/header isolation, compact routing, HTTP SSE, Desktop WebSocket bridging, public model rewriting, one refresh/retry, atomic auth persistence, unknown-field preservation, and isolated App auth-state validation without a Codex subprocess. `go test ./... -count=1`, `go vet ./...`, `gofmt -l`, `swift build`, public-boundary, and diff checks pass. The full validation executable builds and reaches its later Keychain fixture; SSH execution remains blocked there with macOS `-25308`, so the console GUI run is still required.
- The first hand-written live WebSocket probe upgraded successfully but produced an immediate `response.error`. It is preserved as an invalid-harness failure, not product PASS/FAIL evidence: a later loopback capture showed a real Codex 0.142.3 request includes `client_metadata`, `include`, `instructions`, `prompt_cache_key`, `store`, tools, and other fields absent from that probe. The unchanged candidate successfully passed that real-client body through a loopback Responses upstream over HTTP; this local result does not replace the pending Desktop WebSocket/same-thread gate.
- Two ad-hoc controlled-install attempts were rolled back and are ineligible for release evidence. The first exposed ambiguous LaunchServices targeting plus incomplete process cleanup. The second used an exact bundle path after the auth-state fix: it successfully rewrote the persisted runtime to the official Codex endpoint and restored all seven official models, but an ad-hoc identity cannot stand in for the installed Developer-ID identity when the App loads the existing provider Keychain reference. Exact recovery restored installed v0.1.4 and its helper; the migrated runtime now reports official 7 / provider 1 / configured 2. Final installed-candidate validation must use the Developer-ID-signed build.
- Accepted Medium risk: a non-cooperating external process could still write the RelayKit-owned isolated `auth.json` in the tiny interval after the guarded comparison and before rename. The product does not spawn Codex while serving requests, RelayKit instances honor the lock, and normal device login/catalog work is outside that request interval. A future stronger ownership protocol is required if arbitrary external writers to RelayKit's isolated CODEX_HOME become supported.
- Current Mini runtime is installed v0.1.5 build 14 with its App-owned `19777` helper healthy (Official 7, configured models 2). The immutable signed package is bound to clean source `971d052`; rollback backup remains under `/Applications/.RelayKitApp.backup.20260721T200307Z.6933` until release handoff is accepted.
- Installed release gates are complete: both provider models are present in real `model/list`, each completed a turn, and one isolated persisted thread completed provider 1 -> Official -> provider 2 -> Official with both natural provider -> Official compactions succeeding. Global config/auth and isolated Official auth hashes remained unchanged; port 18787 was untouched.

## Phase 7.12: Responses Request Size Boundary Source Closeout

Status: source implementation and focused review are complete; a fresh packaged release candidate is pending. Installed Developer-ID/notarized v0.1.5 build 14 remains the current release candidate and does not include this source change.

- Responses requests use one 32 MiB decoded-body ceiling across identity HTTP, zstd HTTP, and WebSocket transports.
- WebSocket rejects a declared oversized frame before payload allocation. It permits only the bounded 64 KiB envelope overhead needed for `response.create`, while WebSocket control payloads retain the protocol ceiling of 125 bytes.
- `/_relaykit/provider-test` has an independent 64 KiB request limit.
- Focused exact-boundary, over-limit, zstd, WebSocket-envelope, pre-allocation, and no-upstream-on-rejection tests passed. The bound source-only diff SHA-256 is `51ef04bafed6a0a7bbf429c6d95b0597d262df55d18fc45f332105c7dbcf4cbd`; the authorized Test/check result and Final CR both passed with no findings.
- This closeout does not claim a package, GUI run, full Desktop E2E, live query, signing, installation, or release. The selector path remains required for the complete candidate because it includes `gateway/**`.

## Phase 7.13: Signed Beta Personal-Path Source Closeout

Status: source remediation was revised after formal failure; fresh selector Test and CR remain pending.

- Build 15 is immutable, historical, and ineligible because the formal candidate scan found a personal absolute path in its primary executable. Do not re-sign, overwrite, relabel, or reuse Build 15 or its evidence. The earlier diagnostic did not yield a separate rule identifier or byte offset; that missing provenance does not weaken the fail-closed disposition.
- The revised source routes every Swift release build through a newly empty `/tmp` scratch path, with dedicated Swift and Clang module caches. It maps both workspace and home-derived prefixes through Swift frontend debug/file maps and Clang importer debug/file/macro maps. The bundle build raw-scans the App executable and bundled relay helper before signing, without emitting any matched path bytes.
- Signed-release finalization applies the same raw-byte invariant to the prepared App, staged App, retained release App, and extracted signed-zip payload. A rejection reports only binary role, a sanitized rule identifier, and count.
- Focused regression coverage uses an unmistakably synthetic path fixture while `strings` is unavailable, and proves that finalization rejects it before creating an immutable release directory.
- Selector package isolation remediation removes all process termination from the headless bundle build/verify entry. Its focused source contract forbids process-name, installed-App, port-owner, LaunchAgent, and shared-runtime termination there, while preserving dogfood's fail-closed preflight for an existing App or `19777` listener and its exact extracted-artifact cleanup boundary. No package or dogfood runtime was executed; formal selector Test and CR remain pending.
- This revised source closeout does not claim a successful clean release build, Build 16, package creation, signing, notarization, installation, GUI validation, network validation, publication, or runtime acceptance. A fresh selector Test followed by CR and Release gates is required before any new Build 16 release operation.

## Phase 7.14: Codex 0.145 Persistent Responses WebSocket and Graceful Quit

Status: source implementation and focused validation are complete; selector/menu/package/dogfood/live/install/release gates remain pending.

- Verified root cause: the Codex Desktop embedded CLI `0.145.0-alpha.30` keeps one Responses WebSocket open and serially reuses it. RelayKit closed the connection after each terminal response event, so the next turn failed with `Broken pipe` or `Connection reset`.
- One reader now owns inbound WebSocket frames for the lifetime of the connection. Sequential `response.create` requests reuse that connection, while an in-flight client close cancels the corresponding upstream request. Ping/pong handling and existing request-size, protocol, routing, and sanitization invariants remain unchanged.
- Graceful App termination now uses the existing guarded `codex-config-status` / disable state. When RelayKit is enabled, termination restores the RelayKit-managed Codex config fields before shutting down the helper. Config drift or restore failure cancels termination and keeps the gateway alive; Codex auth is not read or modified.
- Focused native and Official sequential regressions passed. Focused race validation, including client-close cancellation, passed. Full `go test ./...`, `go vet`, Swift build with the macOS 15.4 SDK, and the GUI Terminal `RelayKitAppValidationTests` run passed.
- These source-level results do not claim selector completion, menu or package validation, dogfood, live Desktop proof, installation, signing, notarization, publication, or release. Build 15 remains immutable and ineligible, and Build 16 has not been built. The existing Build 15/Build 16 packaging-remediation gates remain in force.

## Phase 7.15: P0 Runtime Safety and GitHub-Ready CI

Status: runtime-safety candidate complete at `5992d6d`; `dist/runtime-safety/evidence.json` binds that source commit and the tracked harness/test hashes, runtime-safety is 8/8 PASS, and four GitHub Actions workflows are committed for public CI. Later CI/documentation-only commits do not replace the runtime candidate. Installed Build 16 remains the historical/current shared runtime and was untouched. Build 17 signed beta is the next distribution goal.

- `fast-gates` covers the public boundary, shell contracts, and Go test/vet/gofmt.
- `macos-app` covers Swift build, `RelayKitAppValidationTests`, and headless bundle/package verification.
- `macos-runtime-safety` runs the offline contract and isolated eight-case fault harness without login, credentials, provider requests, global config mutation, protected ports, signing, or release work.
- `protocol-contract` runs deterministic loopback adapter and Responses tests only.
- Every action is pinned to a full commit SHA; workflows use `contents: read`, cancel superseded runs, set job timeouts, and upload no artifacts.
- Catalog P0 at `3f7f8e7` preserves configured models through discovery failures, records route-confirmed reachability, and keeps fingerprinted/timestamped last-known-good state. Responses P0 at `7afff32` locks single-terminal ordering, persistent WebSocket turns, cancellation, malformed/truncated failures, and tool-call lifecycle; it deliberately does not invent an unproven WebSocket-to-HTTP client fallback.
- Residual runtime risk remains explicit: simultaneous App/helper loss is not guaranteed recoverable or reboot-safe. The null stderr sink is lifecycle-safe but leaves early startup failures generic.
- The checkout has no Git remote, so CI is GitHub-ready rather than GitHub-green. A later authorized first push must confirm the six exact checks listed in `docs/handoff.md` and `docs/release-readiness.md`, then require them on an up-to-date `main` branch.
- Before any Build 17 draft/upload, release automation verifies that those checks succeeded for the artifact manifest's exact `source_commit_sha`. The gate is implemented locally, but no remote same-SHA result is claimed by the current source-only lane.

## Phase 7.16: Build 17 Pre-Freeze Release Tooling

Status: source tooling implemented with focused local contracts; Build 17 distribution remains pending.

- Planned distribution metadata is marketing `0.1.6`, build `17`; release scripts remain environment-driven.
- The six required GitHub check names are exact, and both macOS jobs install Go from the checked-in module files using the pinned setup action.
- Hosted shell/App checks execute the required-check evidence, signed-release orchestration, and explicit-zip proof contracts; the portable proof contract uses test-only temporary fixtures.
- Signed finalization requires absolute same-SHA CI evidence for clean HEAD. Manifest schema 2 binds source, version/build, artifact/App tree, App executable, bundled helper, checks, and deduplicated Actions runs. Production packaging freezes commit/archive identity, builds its own App, signs/notarizes a private frozen copy, and rechecks source identity before locking a three-file zip/checksum/manifest directory; the externally prepared-App entry point is test-only.
- Installation and draft creation consume private snapshots of the immutable package. Draft creation re-queries the manifest SHA, rejects existing release/tag state, creates and verifies a new lightweight tag at that exact commit, and uploads the same snapshot bytes. Ambiguous failures delete only the current run's marked draft and exact expected tag; unreconciled cleanup remains a visible failure. It creates drafts only.
- General Desktop proof accepts one explicit absolute zip, skips rebuilding it, extracts it, and records path plus SHA-256.
- No remote query, push, branch-protection change, package, signing, notarization, install, GUI/live proof, draft creation, or publication is completed by this source lane.
- Focused contracts cover canonical test roots, production prepared-App rejection, post-build source drift, private build-byte freezing, exact immutable layout, post-validation mutation, exact draft assets/arguments, source-SHA tag binding, ambiguous tag/draft creation, and visible cleanup failure.

## Phase 7.17: P0 Two-Epoch Data Plane Lifecycle

Status: source implementation is committed through `aa3dddd`; focused/full source validation, the random-port eight-case fault matrix, all six hosted checks, and the live isolated launchd proof pass. Independent Test/CR, Build 18, and installed same-Codex E2E remain pending.

- Build 17 (`0.1.6` build `17`, source `cc0fa013...`, zip SHA-256 `41e4d4fc...`) is signed, notarized, stapled, Gatekeeper-accepted, and immutable, but it remains uninstalled and is ineligible as the final candidate because it predates this lifecycle fix.
- Restoring the managed Codex fields creates a new disk-config epoch for future clients. It does not reconfigure an already-running Codex process that cached `19777`.
- The packaged data plane is owned by a RelayKit `SMAppService.agent` and a launchd socket. App lifecycle and data-plane lifecycle are separate.
- App Quit/Disable restores managed fields, then releases ownership. The helper retains Official service in `official_fallback`; provider routes fail with typed `restart_codex_required`, and App-provided provider credentials are cleared.
- A disabled-but-running App may adopt fallback with credentials only so the App's explicit provider-test endpoint remains usable. Codex provider routes remain blocked.
- Helper crash is restartable without leaving an enabled route pointed at a missing listener. App loss and simultaneous App/helper loss use field-level recovery plus socket activation.
- The launchd helper may start before App adoption only when socket activation, an owner-only control token, and a positive unowned-recovery timer are all configured. Direct helpers still require a live parent PID. The reviewed launchd plist uses a one-second nonzero throttle so repeated helper loss does not exceed the cached client's single-request recovery budget.
- Short idle and WebSocket disconnect are not retirement signals. The fallback service is observable and controlled by launchd; logout removes the GUI-domain process, and the next login reconciles any stale managed route before future clients rely on it.
- Local verification uses random ports and an isolated fixture. The live launchd proof uses a unique temporary label and never writes user LaunchAgents or touches global Codex auth/config, installed `19777`, or `18787`.
- Hosted run `30944489758` proves `graceful_release`, `app_loss`, `helper_crash`, and `app_helper_loss` on clean product commit `aa3dddd`, including cached requests, config restoration/new-client direct routing, helper restart, global guards, and cleanup.
- Upgrade activation is separate from byte installation. A session currently using the old `19777` data plane must not quit that old App from within itself. Install new bytes from an independent control channel, keep the old data plane alive for the cached epoch, and activate the new App only after that epoch is retired or handed off.

## Release Gate

First public release requires:

- no private strings in repository;
- `go test ./...` passes;
- README has install/build instructions;
- one public provider works end-to-end;
- Codex config activation has backup and rollback;
- no hosted telemetry.
