# RelayKit Handoff

## Current State

The repository has been initialized as a public-safe skeleton. It contains docs, ownership rules, public examples, and a minimal Go gateway placeholder.

This session could not safely implement gateway code because `go` and `gofmt` are not installed on PATH. Per the project goal, work continued only on docs/spec tasks.

Phase 1 spec drafted at `docs/spec/gateway-phase1.md`; awaiting Go toolchain for implementation.
Phase 2 and Phase 3 stubs drafted at `docs/spec/gateway-phase2-streaming.md` and `docs/spec/gateway-phase3-anthropic.md`.
Public pre-publish checklist drafted at `docs/public-boundary-checklist.md`.

Latest committed work:

- `e9e5f37 docs: specify gateway phase contracts`
- Current HEAD records this handoff closeout and the repeated Go/gofmt blocker.

Current verification on the initializing machine:

- File/path sanity check passed.
- `go test ./...` was not run because `go`/`gofmt` are not installed on this machine's PATH.
- `git diff --check` passed during docs validation.
- Private-string scan passed for publishable docs, examples, and gateway product surfaces.
- Toolchain recheck: `go: missing from PATH`; `gofmt: missing from PATH`.

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

Start with toolchain readiness, then Phase 1 from `docs/spec/gateway-phase1.md`:

1. Install Go >= 1.22 or make `go` and `gofmt` available on PATH.
2. Run `go test ./...` from `gateway/` to establish the current baseline.
3. Implement Phase 1 against `docs/spec/gateway-phase1.md`.
4. Run `docs/public-boundary-checklist.md` before any public push or release.
5. Keep the app directory documentation-only until the gateway contract is real.

## Dispatch Board

Plan id: `relaykit-phase1-gateway-mvp`

| Lane | Assignment | Owned Paths | Status |
| --- | --- | --- | --- |
| `relaykit_gateway` | Implement provider loading, catalog generation, `-config`, and fake-upstream non-streaming Chat adapter once Go is available. | `gateway/`, `examples/` | Blocked: `go`/`gofmt` missing |
| `relaykit_worker` | Keep public docs/examples aligned with the minimal ProviderProfile contract. | `docs/handoff.md`, `docs/development-plan.md`, `gateway/README.md`, `examples/` | Done for docs-only slice |
| `relaykit_test` | Run `go test ./...`, `gofmt`, and private-string scan after implementation. | ignored validation artifacts only | Blocked until Go is available |
| `relaykit_cr` | Review simplicity, public boundary, and credential handling before any publish/push. | read-only | Docs-only slice reviewed; public-boundary issue fixed |

## Suggested First Agent Assignment

Start a new development session in this repository and launch `relaykit_planner` first.

Recommended initial prompt:

```text
WORKTREE: /Users/marcusmacmini/workplace/RelayKit
BRANCH: main
PLAN: RelayKit Phase 1 Gateway MVP from docs/spec/gateway-phase1.md
OWNED PATHS: gateway/, examples/, docs/handoff.md, docs/development-plan.md
BLOCKED PATHS: app/, private provider configs, real credentials, hosted telemetry
Change Risk Tier: Tier 2
Validation Tier: Tier 2
CR Tier: Tier 2
STOP CONDITIONS: need real provider credentials, private provider details, destructive git operations, publishing/signing, or unclear public boundary

Use relaykit_planner as controller. Build the dispatch board and implement Gateway MVP against docs/spec/gateway-phase1.md only. Do not start SwiftUI yet.
```

Acceptance:

- `go test ./...` passes.
- Gateway loads a public example provider file.
- `/v1/models` returns configured model IDs.
- Non-streaming `/v1/responses` can call a fake upstream in tests and return Responses-shaped JSON.

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
