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

Phase 2 and Phase 3 stubs drafted at `docs/spec/gateway-phase2-streaming.md` and `docs/spec/gateway-phase3-anthropic.md`.
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

Continue from the completed Phase 1 gateway slice:

1. Re-run `cd gateway && go test ./... -count=1` before further gateway edits.
2. Decide whether to harden Phase 1 before Phase 2: request timeouts, richer Responses input arrays, or stricter response validation.
3. Start Phase 2 streaming from `docs/spec/gateway-phase2-streaming.md` only after a fresh validation pass.
4. Run `docs/public-boundary-checklist.md` before any public push or release.
5. Keep the app directory documentation-only until the gateway contract is real.

## Dispatch Board

Plan id: `relaykit-phase1-gateway-mvp`

| Lane | Assignment | Owned Paths | Status |
| --- | --- | --- | --- |
| `relaykit_gateway` | Implement provider loading, catalog generation, `-config`, and fake-upstream non-streaming Chat adapter. | `gateway/`, `examples/` | Done for Phase 1 |
| `relaykit_worker` | Keep public docs/examples aligned with the minimal ProviderProfile contract. | `docs/handoff.md`, `docs/development-plan.md`, `gateway/README.md`, `examples/` | Done for current slice |
| `relaykit_test` | Run `go test ./...`, `gofmt`, `go vet`, missing-config check, and private-string scan after implementation. | ignored validation artifacts only | Passed for Phase 1 |
| `relaykit_cr` | Review simplicity, public boundary, and credential handling before any publish/push. | read-only | First review findings fixed; second dispatch blocked by local provider route |

## Suggested First Agent Assignment

Start a new development session in this repository and launch `relaykit_planner` first.

Recommended initial prompt:

```text
WORKTREE: /Users/marcusmacmini/workplace/RelayKit
BRANCH: main
PLAN: RelayKit Gateway Phase 2 streaming MVP from docs/spec/gateway-phase2-streaming.md, after fresh Phase 1 validation
OWNED PATHS: gateway/, examples/, docs/handoff.md, docs/development-plan.md
BLOCKED PATHS: app/, private provider configs, real credentials, hosted telemetry
Change Risk Tier: Tier 2
Validation Tier: Tier 2
CR Tier: Tier 2
STOP CONDITIONS: need real provider credentials, private provider details, destructive git operations, publishing/signing, or unclear public boundary

Use relaykit_planner as controller. Build the dispatch board, re-run Phase 1 validation, then implement Phase 2 streaming against docs/spec/gateway-phase2-streaming.md only. Do not start SwiftUI yet.
```

Acceptance:

- `cd gateway && go test ./... -count=1` passes.
- Existing Phase 1 tests keep passing.
- Streaming tests use fake upstreams only.
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
