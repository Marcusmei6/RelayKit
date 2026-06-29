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
Local alpha smoke is covered by `scripts/local-alpha-smoke.sh`.
Durable local helper lifecycle is covered by `scripts/relaykit-helper.sh`, which installs/uninstalls only `~/Library/LaunchAgents/dev.relaykit.gateway.plist` and requires an explicit provider config path.
Local helper log tail is available through `scripts/relaykit-helper.sh logs`; it reads only `/tmp/relaykit-gateway.{out,err}.log` and does not collect or upload usage events.
Public pre-publish checklist drafted at `docs/public-boundary-checklist.md`.

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
- Final `relaykit_cr` dispatch was attempted for Phase 3/4 and did not return after a five-minute wait plus a one-minute retry; treat as a workflow/provider availability blocker, not a code failure. Follow-up fix changed `relaykit_cr` to a stable local route and documented root read-only review as the fallback when CR provider availability fails.
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
  - `cd gateway && go build -o bin/relaykit-gateway ./cmd/gateway` produced the dev helper binary used by the app.
  - A built gateway binary smoke returned `{"status":"ok"}` from `/healthz` and model IDs from `/v1/models`.
  - The app uses the configured gateway binary for both server start and Codex config activation.
  - `relaykit_test` passed Mac MVP shell validation.
  - `relaykit_cr` returned SHIP IT after confirming the helper lifecycle and activation path use the configured binary.
- Local usable alpha hardening:
  - provider config path is persisted with `UserDefaults`;
  - gateway startup reports immediate helper exit as an error instead of showing a false running state;
  - `scripts/local-alpha-smoke.sh` builds the gateway, runs gateway tests/vet/gofmt, checks `/healthz` and `/v1/models`, and builds the app.
- Phase 4.5 helper lifecycle validation passed:
  - missing `--config` fails with `--config is required`;
  - missing provider config path fails before writing a LaunchAgent;
  - `scripts/relaykit-helper.sh uninstall` affects only the RelayKit-owned LaunchAgent label;
  - `scripts/relaykit-helper.sh install --config examples/providers.example.json --binary gateway/bin/relaykit-gateway` installed `dev.relaykit.gateway` and normalized both paths to absolute plist arguments;
  - `/healthz` and `/v1/models` worked through the LaunchAgent-started helper;
  - `scripts/relaykit-helper.sh uninstall` removed the LaunchAgent and stopped the helper.
  - deliberate Phase 4.5 simplifications: `127.0.0.1:19777` is hardcoded, and helper stdout/stderr go to `/tmp/relaykit-gateway.{out,err}.log`.
- Phase 5 local log-tail start:
  - `scripts/relaykit-helper.sh logs --lines 5` reads existing helper stdout/stderr logs when present;
  - `scripts/relaykit-helper.sh logs --lines nope` exits with an explicit `--lines requires a non-negative integer` error;
  - this is local helper stdout/stderr only, not usage JSONL or cloud telemetry.

## Important Decisions

- Project name: RelayKit.
- Public scope: local model routing kit for agentic coding tools.
- First client target: Codex compatibility.
- UI direction: Apple-native SwiftUI/AppKit shell, deferred until gateway contract stabilizes.
- Gateway direction: Go helper, not Swift.
- Open-source boundary: no private adapters, internal model IDs, internal URLs, tokens, or copied local gateway implementation.
- Workflow direction: use project-scoped RelayKit agents in `.codex/agents/`, with `relaykit_planner` as controller and parent-mediated dispatch when a child planner cannot spawn specialists.
- Local execution routing: project agents currently mirror a private local runtime split. Exact local model IDs are intentionally omitted from publishable docs; inspect `.codex/agents/*.toml` only on this private checkout.

## Next Workstream

Continue from the completed Phase 3 adapter, Phase 4 activation CLI, local usable Mac alpha, Phase 4.5 helper lifecycle, and the first Phase 5 log-tail utility:

1. Re-run `./scripts/local-alpha-smoke.sh` before further alpha edits.
2. Choose the next safe item from `docs/development-plan.md`: usage JSONL without cloud upload, provider config editing without secrets, or Anthropic/tool-use hardening.
3. Keep the documented root read-only review fallback for future CR provider failures.
4. Run `docs/public-boundary-checklist.md` before any public push or release.
5. Add Keychain/provider editing only after the gateway and app shell review gates stay green.
6. Use the planner continuation gate in `docs/agents/README.md`; do not stop after one commit if the next safe item in `docs/development-plan.md` is still available.

## Dispatch Board

Plan id: `relaykit-local-alpha-to-helper-lifecycle`

| Lane | Assignment | Owned Paths | Status |
| --- | --- | --- | --- |
| `relaykit_gateway` | Implement provider loading, catalog generation, `-config`, fake-upstream non-streaming Chat adapter, Phase 2 text streaming MVP, and Phase 3 Anthropic Messages MVP. | `gateway/`, `examples/`, `docs/spec/` | Done through Phase 3 MVP |
| `relaykit_app` | Implement SwiftUI/AppKit shell, helper lifecycle, health/models UI, and safe activation UI. | `app/` | Mac MVP shell implemented |
| `relaykit_app` | Add smallest LaunchAgent or packaged-helper flow for the existing built gateway binary. | `app/`, `scripts/`, `docs/handoff.md` | Done for local LaunchAgent flow |
| `relaykit_app` | Add local helper log tail for LaunchAgent stdout/stderr. | `scripts/`, `app/README.md`, `docs/handoff.md`, `docs/development-plan.md` | Done for local log tail |
| `relaykit_worker` | Keep public docs/examples aligned with ProviderProfile and Codex local integration contracts. | `docs/handoff.md`, `docs/spec/`, `examples/` | Done for current slice |
| `relaykit_test` | Run `go test ./...`, Swift build, missing-config check, streaming/activation acceptance, and private-string scan after implementation. | ignored validation artifacts only | Passed for Mac MVP shell |
| `relaykit_cr` | Review simplicity, public boundary, Anthropic/Codex integration correctness, and credential handling before any publish/push. | read-only | Stable route configured; fallback is root read-only review after one failed retry |

## Suggested First Agent Assignment

Start a new development session in this repository and launch `relaykit_planner` first.

Recommended initial prompt:

```text
WORKTREE: /Users/marcusmacmini/workplace/RelayKit
BRANCH: main
PLAN: RelayKit local alpha to durable helper lifecycle, with planner continuation gate
OWNED PATHS: app/, scripts/, docs/handoff.md, docs/development-plan.md, docs/agents/README.md
BLOCKED PATHS: private provider configs, real credentials, hosted telemetry, public GitHub push, signing, notarization, publishing
Change Risk Tier: Tier 2
Validation Tier: Tier 2
CR Tier: Tier 2
STOP CONDITIONS: need real provider credentials, private provider details, destructive git operations, publishing/signing/notarization, or unclear public boundary

Use relaykit_planner as controller. Run ./scripts/local-alpha-smoke.sh, then implement the smallest LaunchAgent or packaged-helper flow for the existing built gateway binary. After each passing commit, apply docs/agents/README.md Continuation Gate and continue to the next safe item from docs/development-plan.md. Do not push, publish, sign, notarize, or add real credentials.
```

Acceptance:

- `./scripts/local-alpha-smoke.sh` passes.
- `cd app && swift build` passes.
- CR returns SHIP IT or actionable findings are addressed.
- Public-boundary scan has no disallowed hits.
- Handoff states why the planner stopped instead of taking the next safe item.

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
