# RelayKit Handoff

## Current State

The repository has been initialized as a public-safe skeleton. It contains docs, ownership rules, public examples, and a minimal Go gateway placeholder.

Current verification on the initializing machine:

- File/path sanity check passed.
- Private-string quick scan passed for known local internal keywords.
- `go test ./...` was not run because `go`/`gofmt` are not installed on this machine's PATH.

## Important Decisions

- Project name: RelayKit.
- Public scope: local model routing kit for agentic coding tools.
- First client target: Codex compatibility.
- UI direction: Apple-native SwiftUI/AppKit shell, deferred until gateway contract stabilizes.
- Gateway direction: Go helper, not Swift.
- Open-source boundary: no private adapters, internal model IDs, internal URLs, tokens, or copied local gateway implementation.
- Workflow direction: use project-scoped RelayKit agents in `.codex/agents/`, with `relaykit_planner` as controller and parent-mediated dispatch when a child planner cannot spawn specialists.
- Local execution routing: project agents currently mirror the Iris runtime split: planner on `relay/model_hub/es1_orange_o47` / `xhigh`, worker and gateway on `traex/doubao-seed-2.1-pro` / `high`, test on `gpt-5.3-codex-spark` / `xhigh`, CR on `traex/gpt-5.5` / `xhigh`, app on `gpt-5.5` / `xhigh`, release on `gpt-5.5` / `high`.

## Next Workstream

Start with Phase 1 from `docs/development-plan.md`:

1. Define provider profile schema.
2. Load `examples/providers.example.json`.
3. Generate catalog from public profiles.
4. Add OpenAI-compatible Chat adapter behind tests.
5. Keep the app directory documentation-only until the gateway contract is real.

## Suggested First Agent Assignment

Start a new development session in this repository and launch `relaykit_planner` first.

Recommended initial prompt:

```text
WORKTREE: /Users/marcusmacmini/workplace/RelayKit
BRANCH: main
PLAN: RelayKit Phase 1 Gateway MVP
OWNED PATHS: gateway/, examples/, docs/handoff.md, docs/development-plan.md
BLOCKED PATHS: app/, private provider configs, real credentials, hosted telemetry
Change Risk Tier: Tier 2
Validation Tier: Tier 2
CR Tier: Tier 2
STOP CONDITIONS: need real provider credentials, private provider details, destructive git operations, publishing/signing, or unclear public boundary

Use relaykit_planner as controller. Build the dispatch board and implement Gateway MVP only. Do not start SwiftUI yet.
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
