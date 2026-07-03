# RelayKit Handoff

## Current State

The repository has been initialized as a public-safe skeleton. It contains docs, ownership rules, public examples, and a minimal Go gateway Phase 1 implementation.

The previous Go toolchain blocker is resolved on this Mac mini. `go` and `gofmt` are available at `/opt/homebrew/bin/`, installed through Homebrew.

Phase 1 implementation now covers `docs/spec/gateway-phase1.md`:

- provider profile loading from JSON;
- stable config error codes;
- `/v1/models` generated from configured providers;
- `-listen` and `-config` gateway flags;
- non-streaming `/v1/responses` to OpenAI Chat-compatible upstream translation, covered with a fake upstream test.

Phase 2 streaming MVP implemented at `docs/spec/gateway-phase2-streaming.md`.
Phase 3 Anthropic Messages MVP implemented at `docs/spec/gateway-phase3-anthropic.md`.
Phase 4 Codex local integration is documented at `docs/spec/codex-local-integration.md` and `examples/codex.config.example.toml`.
Safe Codex config activation now has a minimal gateway primitive in `gateway/internal/codexconfig` and an explicit CLI caller, `gateway activate-codex-config -source <path> -target <path>`; it only writes an explicitly supplied target path, backs up existing files first, and has no default `~/.codex` target.
Mac MVP app shell exists in `app/` as a SwiftPM SwiftUI app. It can start/stop an explicitly configured gateway binary, check `/healthz`, read `/v1/models`, and call the explicit Codex config activation CLI.
The app can be launched from the repository root with `./script/build_and_run.sh`; the script builds `gateway/bin/relay`, bundles it into `dist/RelayKitApp.app/Contents/MacOS/relay`, bundles the public demo provider config into `Contents/Resources/providers.example.json`, bundles the public Codex config example into `Contents/Resources/codex.config.example.toml`, and opens the app as a foreground macOS app. Codex Desktop also has a checked-in Run action at `.codex/environments/environment.toml` pointing to that script.
Local release packaging is covered by `./script/package_release.sh --verify`; it creates `dist/RelayKitApp-local.zip`, extracts it under `dist/verify-release/`, verifies the extracted app contains `Contents/MacOS/relay` plus both bundled public demo config examples, opens the extracted app, and checks the extracted bundled gateway through `/healthz` and `/v1/models`. The artifact is unsigned and not notarized.
P0 menu-bar control-center regression is complete for the local public-safe scope. The primary app surface is menu-bar resident with a compact visible status item and an anchored small popover/control-center, tabs `接入` / `Usage` / `设置`, real gateway controls, real usage summaries or a real empty state, disabled Claude Code placeholder only, and a form-based provider modal overlay. The provider form writes the current public provider schema and stores credential references only. The replay/Kaboo-style UI repair moved gateway/port/health/models/Codex state into the global header, rebuilt `接入` around CLI/provider/model workflows, made `Usage` KPI/card-first instead of path-field-first, moved raw local paths behind Advanced settings, and kept unfinished controls hidden or disabled. `./scripts/menu-bar-e2e-smoke.sh` captures UI screenshots plus evidence JSON under `dist/ui-smoke/` and now checks compact status-item visibility, anchored popover state, expected semantic sections, and stale RelayKit-owned process cleanup; `./scripts/reference-model-coverage.sh` writes redacted local reference gateway source coverage to `dist/reference-model-coverage.json`; `./scripts/codex-e2e-smoke.sh` uses a temporary `CODEX_HOME`/`HOME`, fake local upstream, and RelayKit loopback gateway to prove Codex routes through RelayKit and produces local usage evidence under `dist/codex-e2e/`.
Post-P0 provider metadata now has a public-safe contract at `docs/spec/provider-profile-contract.md`. Gateway config loading and app validation understand `credential_ref`, `capabilities`, `routing`, and model `upstream_model`. Runtime auth supports legacy `auth_env` and `credential_ref.kind = "env"` only; Keychain and key-file references remain validated metadata until the credential storage milestone is explicitly selected.
Local alpha smoke is covered by `scripts/local-alpha-smoke.sh`; it builds the gateway binary, checks foreground `/healthz` and `/v1/models`, exercises explicit Codex config activation, checks local usage summary, temporarily installs/uninstalls the LaunchAgent helper, builds the app, verifies the bundled app gateway, and runs app validation tests.
Durable local helper lifecycle is covered by `scripts/relaykit-helper.sh`, which installs/uninstalls only `~/Library/LaunchAgents/dev.relaykit.gateway.plist` and requires an explicit provider config path.
Local helper log tail is available through `scripts/relaykit-helper.sh logs`; it reads only `/tmp/relay.{out,err}.log` and does not collect or upload usage events.
Local usage JSONL is written by the gateway to `~/Library/Application Support/RelayKit/usage.jsonl` by default, with tests injecting a temp path. It records only allowed metadata fields and token counts; it does not record request/response bodies, prompts, headers, cookies, auth values, API keys, private domains, or raw upstream URLs.
The Mac app has a Usage section that calls the gateway binary's local `summarize-usage` command for an explicit usage JSONL path.
The Mac app has a minimal Provider Config editor for explicit JSON files. It validates public provider fields, rejects credential-looking keys/values and base URLs with userinfo, query strings, or fragments, and backs up existing files before saving.
Public pre-publish checklist drafted at `docs/public-boundary-checklist.md`.

Integrated SwiftUI Mac alpha checklist status:

- Gateway binary builds as `gateway/bin/relay`: satisfied by `./scripts/local-alpha-smoke.sh`.
- User can launch the app with one command from the repository root: satisfied by `./script/build_and_run.sh`.
- SwiftUI app can start/stop the bundled gateway binary without `go run`: satisfied by app helper lifecycle wiring and `./script/build_and_run.sh --verify`.
- Local unsigned release zip can be built and verified: satisfied by `./script/package_release.sh --verify`.
- Menu-bar resident control-center shell: satisfied; current shell uses a compact AppKit `NSStatusItem` plus anchored `NSPopover`, keeps real gateway controls, and records screenshot/evidence JSON through the UI smoke.
- Temporary Codex E2E through RelayKit: satisfied by `./scripts/codex-e2e-smoke.sh`, which does not write real `~/.codex/config.toml`.
- Codex connection state reads only the explicit target path entered in the app and reports whether it points at RelayKit loopback; it does not default to or inspect real `~/.codex/config.toml`.
- App uses an explicit provider config path and stores no credential values: satisfied for the current public config editor slice.
- Provider add sheet writes public provider metadata through `ProviderConfigDraftWriter`; env credentials are stored as `credential_ref`, while advanced capability metadata remains hidden unless loaded from validated JSON.
- Provider credential/capability contract is implemented for validation and env runtime auth; Keychain/key-file resolution remains a future product/security decision.
- App can call `/healthz` and `/v1/models`, and displays model IDs: satisfied by app client/UI wiring and smoke coverage for the endpoints.
- App can run explicit Codex config activation through the gateway CLI with source/target paths: satisfied by app wiring and smoke coverage.
- App can load/save public provider config JSON without credential fields: satisfied by app validation tests.
- App can show local usage summary from an explicit usage JSONL path: satisfied by app wiring and smoke coverage for the summary CLI.
- Local helper/LaunchAgent flow is documented and smoke-tested, but not permanently installed: satisfied by `scripts/relaykit-helper.sh` and smoke cleanup.
- Local alpha smoke proves gateway plus app validation pass: satisfied on this machine.
- Handoff documents what a user can run today: satisfied by README, app/gateway/script README files, and this checklist.

Local no-secret demo path:

1. From the repository root, run `./script/build_and_run.sh`.
2. In the app, leave the default gateway binary path as the bundled `relay` helper.
3. Leave the default provider config path as the bundled public demo config.
4. Click Start, then Health, then Refresh Models.
5. Use Load Config to inspect the public provider JSON, Refresh Usage for local usage summaries, and Codex Config Activation only with an explicit temporary target path.

Latest committed baseline before Phase 1 implementation:

- `128c033 docs: record relaykit handoff blocker`

Current verification on this machine:

- `cd gateway && go test ./... -count=1` passed.
- `cd gateway && gofmt -l .` returned empty.
- `cd gateway && go vet ./...` passed.
- `git diff --check` passed.
- Private-string scan passed for publishable docs, examples, and gateway product surfaces.
- Missing config startup check returns `config_read_error`.
- `relaykit_test` validation passed all Phase 1 acceptance rows.
- `relaykit_cr` first review returned NEEDS WORK for ignored test write errors and one avoidable single-use abstraction; both were fixed. A second CR dispatch was attempted but failed at the local subagent provider route with `502 Bad Gateway` / connection refused, not a code finding.
- Phase 2 validation passed:
  - `cd gateway && go test ./... -count=1` passed.
  - `cd gateway && go vet ./...` passed.
  - `cd gateway && gofmt -l .` returned empty.
  - `git diff --check` passed.
  - `relaykit_test` passed Phase 2 acceptance and public-boundary checks.
  - `relaykit_cr` dispatch was attempted but did not return after two five-minute waits; treat as a workflow/provider availability blocker, not a code failure.
- Phase 3 validation passed before commit `1202f69 feat: add gateway anthropic adapter`:
  - `cd gateway && go test ./... -count=1` passed.
  - `cd gateway && go vet ./...` passed.
  - `cd gateway && test -z "$(gofmt -l .)"` passed.
  - `git diff --check` passed.
  - `jq . examples/providers.example.json` passed.
  - Public-boundary scan had only documented checklist regex hits and standard auth header assembly.
- Phase 4 Codex local integration docs/examples slice committed as `b4501f2 docs: add codex local integration spec`.
- Final `relaykit_test` validation passed Phase 3 and Phase 4 checks.
- Final `relaykit_cr` dispatch was attempted for Phase 3/4 and did not return after a five-minute wait plus a one-minute retry; treat as a workflow/provider availability blocker, not a code failure. Follow-up fix changed `relaykit_cr` to a stable checked-in public default route and documented root read-only review as the fallback when CR provider availability fails.
- Codex config activation primitive validation passed:
  - `cd gateway && go test ./... -count=1` passed.
  - `cd gateway && go vet ./...` passed.
  - `cd gateway && test -z "$(gofmt -l .)"` passed.
  - `git diff --check` passed.
  - `relaykit_test` passed the explicit-target, backup, restore, no-home-default, and public-boundary checks.
  - `relaykit_cr` returned SHIP IT with no Critical/High/Medium/Low findings.
- Codex config activation CLI caller validation passed:
  - `go test ./cmd/gateway -count=1` covered missing `-target` rejection and explicit source-to-target activation with rollback output.
  - `relaykit_test` passed the CLI caller validation and public-boundary checks.
  - `relaykit_cr` returned SHIP IT for the CLI caller with no severity findings.
  - A `relaykit_planner` control dispatch disconnected with `magic number mismatch`; root continued under the documented parent-mediated workflow.
- Mac MVP app shell validation passed:
  - `cd app && swift build` passed.
  - `cd app && swift run RelayKitApp` launched and was stopped manually after startup.
  - `cd gateway && go build -o bin/relay ./cmd/gateway` produced the dev helper binary used by the app.
  - A built gateway binary smoke returned `{"status":"ok"}` from `/healthz` and model IDs from `/v1/models`.
  - The app uses the configured gateway binary for both server start and Codex config activation.
  - `relaykit_test` passed Mac MVP shell validation.
  - `relaykit_cr` returned SHIP IT after confirming the helper lifecycle and activation path use the configured binary.
- Local usable alpha hardening:
  - provider config path is persisted with `UserDefaults`;
  - gateway startup reports immediate helper exit as an error instead of showing a false running state;
  - `scripts/local-alpha-smoke.sh` builds the gateway, runs gateway tests/vet/gofmt, checks `/healthz` and `/v1/models`, checks activation and usage summary CLI paths, temporarily exercises the LaunchAgent helper flow, and builds the app.
- Phase 4.5 helper lifecycle validation passed:
  - missing `--config` fails with `--config is required`;
  - missing provider config path fails before writing a LaunchAgent;
  - `scripts/relaykit-helper.sh uninstall` affects only the RelayKit-owned LaunchAgent label;
  - `scripts/relaykit-helper.sh install --config examples/providers.example.json --binary gateway/bin/relay` installed `dev.relaykit.gateway` and normalized both paths to absolute plist arguments;
  - `/healthz` and `/v1/models` worked through the LaunchAgent-started helper;
  - `scripts/relaykit-helper.sh uninstall` removed the LaunchAgent and stopped the helper.
  - deliberate Phase 4.5 simplifications: `127.0.0.1:19777` is hardcoded, and helper stdout/stderr go to `/tmp/relay.{out,err}.log`.
- Phase 5 local log-tail start:
  - `scripts/relaykit-helper.sh logs --lines 5` reads existing helper stdout/stderr logs when present;
  - `scripts/relaykit-helper.sh logs --lines nope` exits with an explicit `--lines requires a non-negative integer` error;
  - this is local helper stdout/stderr only, not usage JSONL or cloud telemetry.
- Phase 5 local usage JSONL:
  - gateway accepts `-usage-log <path>` and defaults to the local app support usage path;
  - completed `/v1/responses` requests append one JSON line with provider/model/route/status/token metadata;
  - focused tests prove prompts, response body text, auth headers, cookies, env token values, API-key-looking prompt text, and upstream URLs are not written.
- Phase 5 local usage summary:
  - `gateway summarize-usage -path <usage.jsonl>` aggregates by day/provider/model and prints the conservative JSON summary contract;
  - missing usage files return an empty summary instead of creating user data.
- Phase 5 app usage view:
  - app exposes a usage JSONL path field and Refresh Usage button;
  - the view displays day/provider/model/request/input/output/total/duration aggregates returned by the local gateway binary summary command.
- Phase 5.5 provider config editing:
  - app exposes explicit Load Config and Save Config actions for the configured provider JSON path;
  - load and save validate required provider/model fields, supported API formats, base URLs without userinfo/query/fragment, and no credential-looking keys/values before display or write;
  - existing files are copied to timestamped `.bak.<unix>` backups before write;
  - `swift run RelayKitAppValidationTests` covers valid config plus userinfo, query, fragment, and credential-key rejection.
- Phase 3.5 Anthropic tool-use hardening:
  - non-streaming Anthropic `tool_use` blocks map to Responses `function_call` output items with fake upstream coverage;
  - streaming Anthropic `tool_use` blocks map to Responses `function_call` output items before completion with fake upstream coverage;
  - incomplete streaming tool arguments emit `response.error`.
- Phase 6 local release readiness:
  - root README, app README, and script docs now match the current local alpha and local package commands;
  - `./script/package_release.sh --verify` builds `dist/RelayKitApp-local.zip`, extracts it, opens the extracted app, and verifies the extracted bundled gateway through `/healthz` and `/v1/models`;
  - `.codex/agents/*.toml` now uses public model defaults; keep private/local routing in untracked machine-local overrides only.

## Important Decisions

- Project name: RelayKit.
- Public scope: local model routing kit for agentic coding tools.
- First client target: Codex compatibility.
- UI direction: Apple-native SwiftUI/AppKit shell, deferred until gateway contract stabilizes.
- Gateway direction: Go helper, not Swift.
- Open-source boundary: no private adapters, internal model IDs, internal URLs, tokens, or copied local gateway implementation.
- Workflow direction: use project-scoped RelayKit agents in `.codex/agents/`, with `relaykit_planner` as controller and parent-mediated dispatch when a child planner cannot spawn specialists.
- Local execution routing: checked-in project agents use public model defaults. Private runtime splits belong outside the repository.

## Next Workstream

Continue from the completed Phase 3 adapter, Phase 4 activation CLI, local usable Mac alpha, Phase 4.5 helper lifecycle, Phase 5 log-tail utility, Phase 5 usage JSONL writer, app usage view, provider config editor, Anthropic tool-use mapping, and local release readiness docs:

1. Re-run `./scripts/local-alpha-smoke.sh` before further alpha edits.
2. Choose the next safe item from `docs/development-plan.md`: Keychain/credential storage, signing, publishing, or public push/release validation only after explicit selection.
3. Keep the documented root read-only review fallback for future CR provider failures.
4. Run `docs/public-boundary-checklist.md` before any public push or release.
5. Add Keychain/credential storage only after the gateway and app shell review gates stay green.
6. Use the planner Continuation Gate, Spec Gap Repair Gate, and Backlog Expansion Gate in `docs/agents/README.md`; do not stop after one commit if the next safe item is available, and do not treat small missing local contracts as human blockers.

Backlog expansion result: after re-reading the plan, handoff, README files, and public-boundary checklist, fewer than two safe implementation lanes remain. The remaining candidates are Keychain credential storage, signing/publishing readiness, and public push/release validation; each requires explicit selection or crosses current stop conditions.

## Dispatch Board

Plan id: `relaykit-local-alpha-to-helper-lifecycle`

| Lane | Assignment | Owned Paths | Status |
| --- | --- | --- | --- |
| `relaykit_gateway` | Implement provider loading, catalog generation, `-config`, fake-upstream non-streaming Chat adapter, Phase 2 text streaming MVP, and Phase 3 Anthropic Messages MVP. | `gateway/`, `examples/`, `docs/spec/` | Done through Phase 3 MVP |
| `relaykit_app` | Implement SwiftUI/AppKit shell, helper lifecycle, health/models UI, and safe activation UI. | `app/` | Mac MVP shell implemented |
| `relaykit_app` | Add smallest LaunchAgent or packaged-helper flow for the existing built gateway binary. | `app/`, `scripts/`, `docs/handoff.md` | Done for local LaunchAgent flow |
| `relaykit_app` | Add local helper log tail for LaunchAgent stdout/stderr. | `scripts/`, `app/README.md`, `docs/handoff.md`, `docs/development-plan.md` | Done for local log tail |
| `relaykit_gateway` | Add local usage JSONL writer using the conservative Phase 5 contract. | `gateway/`, `docs/handoff.md`, `docs/development-plan.md` | Done for local writer |
| `relaykit_gateway` | Add local usage summary CLI by day/provider/model. | `gateway/`, `docs/handoff.md`, `docs/development-plan.md` | Done for local summary |
| `relaykit_app` | Add minimal app usage view backed by local summary CLI. | `app/`, `docs/handoff.md`, `docs/development-plan.md` | Done for local app view |
| `relaykit_app` | Add provider config editing without secrets. | `app/`, `docs/handoff.md`, `docs/development-plan.md` | Done for minimal JSON editor |
| `relaykit_gateway` | Harden Anthropic tool-use mapping with fake upstream tests. | `gateway/`, `docs/handoff.md` | Done for non-streaming tool_use |
| `relaykit_gateway` | Add Anthropic streaming tool-use mapping using the Phase 3.6 contract. | `gateway/`, `docs/spec/gateway-phase3-anthropic.md`, `docs/handoff.md` | Done for streaming tool_use |
| `relaykit_worker` | Refresh README/local release readiness and public scrub notes. | `README.md`, `app/README.md`, `gateway/README.md`, `docs/public-boundary-checklist.md`, `docs/handoff.md` | Done for README/scrub notes |
| `relaykit_worker` | Keep public docs/examples aligned with ProviderProfile and Codex local integration contracts. | `docs/handoff.md`, `docs/spec/`, `examples/` | Done for current slice |
| `relaykit_test` | Run `go test ./...`, Swift build, missing-config check, streaming/activation acceptance, and private-string scan after implementation. | ignored validation artifacts only | Passed for Mac MVP shell |
| `relaykit_cr` | Review simplicity, public boundary, Anthropic/Codex integration correctness, and credential handling before any publish/push. | read-only | Public default route configured; fallback is root read-only review after one failed retry |

## Suggested First Agent Assignment

Start a new development session in this repository and launch `relaykit_planner` first.

Recommended initial prompt:

```text
WORKTREE: /path/to/RelayKit
BRANCH: main
PLAN: RelayKit local alpha hardening backlog, with planner continuation/spec-gap/backlog gates
OWNED PATHS: gateway/, app/, scripts/, docs/handoff.md, docs/development-plan.md, docs/agents/README.md
BLOCKED PATHS: private provider configs, real credentials, hosted telemetry, public GitHub push, signing, notarization, publishing
Change Risk Tier: Tier 2
Validation Tier: Tier 2
CR Tier: Tier 2
STOP CONDITIONS: need real provider credentials, private provider details, destructive git operations, publishing/signing/notarization, or unclear public boundary

Use relaykit_planner as controller. Run ./scripts/local-alpha-smoke.sh, then choose the next explicit lane from docs/development-plan.md. Current remaining candidates require explicit selection: Keychain/credential storage, signing/publishing readiness, or public push/release validation. After each passing commit, apply docs/agents/README.md Continuation Gate, Spec Gap Repair Gate, and Backlog Expansion Gate, then continue to the next safe item. Do not push, publish, sign, notarize, upload telemetry, or add real credentials.
```

Acceptance:

- `./scripts/local-alpha-smoke.sh` passes.
- `cd gateway && go test ./... -count=1` passes.
- `cd app && swift build` passes.
- CR returns SHIP IT or actionable findings are addressed.
- Public-boundary scan has no disallowed hits.
- Handoff states why the planner stopped instead of taking the next safe item.
- Handoff states the backlog expansion result when fewer than two safe lanes remain.

## Workflow Assets Added

- `.codex/config.toml`
- `.codex/agents/relaykit-planner.toml`
- `.codex/agents/relaykit-worker.toml`
- `.codex/agents/relaykit-gateway.toml`
- `.codex/agents/relaykit-app.toml`
- `.codex/agents/relaykit-test.toml`
- `.codex/agents/relaykit-cr.toml`
- `.codex/agents/relaykit-release.toml`
- `docs/agents/README.md`
