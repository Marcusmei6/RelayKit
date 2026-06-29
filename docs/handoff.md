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

Continue from the completed Phase 3 adapter and Phase 4 docs/examples slice:

1. Re-run `cd gateway && go test ./... -count=1` before further gateway edits.
2. Re-attempt `relaykit_cr` when the provider route is healthy.
3. Decide whether to add safe Codex config activation code under the app lane, with backup/rollback tests first.
4. Run `docs/public-boundary-checklist.md` before any public push or release.
5. Keep the app directory documentation-only until the gateway contract is real.

## Dispatch Board

Plan id: `relaykit-phase1-gateway-mvp`

| Lane | Assignment | Owned Paths | Status |
| --- | --- | --- | --- |
| `relaykit_gateway` | Implement provider loading, catalog generation, `-config`, fake-upstream non-streaming Chat adapter, Phase 2 text streaming MVP, and Phase 3 Anthropic Messages MVP. | `gateway/`, `examples/`, `docs/spec/` | Done through Phase 3 MVP |
| `relaykit_worker` | Keep public docs/examples aligned with ProviderProfile and Codex local integration contracts. | `docs/handoff.md`, `docs/spec/`, `examples/` | Done for current slice |
| `relaykit_test` | Run `go test ./...`, `gofmt`, `go vet`, missing-config check, streaming acceptance, and private-string scan after implementation. | ignored validation artifacts only | Passed for Phase 2 |
| `relaykit_cr` | Review simplicity, public boundary, streaming correctness, and credential handling before any publish/push. | read-only | Pending: latest dispatch did not return after two waits |

## Suggested First Agent Assignment

Start a new development session in this repository and launch `relaykit_planner` first.

Recommended initial prompt:

```text
WORKTREE: /Users/marcusmacmini/workplace/RelayKit
BRANCH: main
PLAN: Re-attempt RelayKit CR for Phase 3/4, then plan safe Codex activation or Phase 3 hardening
OWNED PATHS: gateway/, examples/, docs/handoff.md, docs/development-plan.md
BLOCKED PATHS: app/, private provider configs, real credentials, hosted telemetry
Change Risk Tier: Tier 2
Validation Tier: Tier 2
CR Tier: Tier 2
STOP CONDITIONS: need real provider credentials, private provider details, destructive git operations, publishing/signing, or unclear public boundary

Use relaykit_planner as controller. Re-run gateway validation, re-attempt relaykit_cr if the provider route is healthy, then decide whether to implement safe Codex config activation with backup/rollback or harden Anthropic tool-use support. Do not push or publish.
```

Acceptance:

- `cd gateway && go test ./... -count=1` passes.
- Existing Phase 1, Phase 2, and Phase 3 tests keep passing.
- CR returns SHIP IT or actionable findings are addressed.
- Public-boundary scan has no disallowed hits.

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
