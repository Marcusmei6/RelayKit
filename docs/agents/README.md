# RelayKit Agent Workflow

This file defines RelayKit's project-scoped agent workflow. It is a routing map, not a custom workflow engine.

Project agents live in `.codex/agents/` and are registered by `.codex/config.toml`. Keep these agents project-scoped so the public repository carries its own development workflow without depending on a user's global setup.

This checkout is configured for local Mac mini execution and intentionally mirrors private local model routing. Before publishing RelayKit to a public GitHub repository, scrub `.codex/agents/*.toml` back to public model names and keep this table free of private route values.

## Agents

| Agent | Model | Role | Writes? | Use when | Must not do |
| --- | --- | --- | --- | --- | --- |
| `relaykit_planner` | local private route / `xhigh` | Controller | Narrow docs/workflow only | Split work, assign lanes, enforce gates, maintain handoff | Implement product code, claim dispatch without evidence, handle secrets |
| `relaykit_worker` | local private route / `high` | General worker | Yes | Bounded docs/examples/small cross-cutting tasks | Broaden scope, merge/push, edit private data |
| `relaykit_gateway` | local private route / `high` | Go gateway worker | Yes | Server, adapters, config, catalog, usage events | Edit app UI, copy private gateway behavior |
| `relaykit_app` | local private route / `xhigh` | Apple app worker | Yes | SwiftUI/AppKit shell, Keychain, helper lifecycle, config activation | Implement protocol adapters or SSE parsing in Swift |
| `relaykit_test` | local private route / `xhigh` | Validator | Ignored artifacts only | Focused validation, command evidence, tier adequacy | Fix code, add tests, bless unverified claims |
| `relaykit_cr` | stable local route / `xhigh` | Reviewer | No | Correctness, simplicity, public-boundary, security-sensitive review | Edit files |
| `relaykit_release` | local private route / `high` | Release validator | Ignored artifacts only | Packaging, signing readiness, public repo hygiene | Sign/notarize/publish without explicit user request |

## Default Flow

1. Root session starts `relaykit_planner` for non-trivial project work.
2. Planner builds a dispatch board with plan id, branch/worktree, owned paths, blocked paths, dependencies, tiers, validators, and stop conditions.
3. If planner cannot spawn specialists, it outputs `PARENT DISPATCH REQUIRED`; root launches the listed agents and returns results to planner.
4. Implementation lanes go to `relaykit_gateway`, `relaykit_app`, or `relaykit_worker`.
5. Validation goes to `relaykit_test`; review goes to `relaykit_cr`.
6. Release/package scope also requires `relaykit_release`.
7. Planner updates `docs/handoff.md` and relevant plan docs before final handoff.

If `relaykit_cr` fails to start, returns a provider route error, or does not return after one bounded retry, record the failure in `docs/handoff.md` and run a root-session read-only review over the same diff. Passing tests plus a clean public-boundary scan plus root review may close the lane; do not let CR provider availability become the only blocker.

## Assignment Header

Every specialist assignment must start with:

```text
WORKTREE:
BRANCH:
PLAN:
OWNED PATHS:
BLOCKED PATHS:
Change Risk Tier:
Validation Tier:
CR Tier:
STOP CONDITIONS:
```

Missing fields are a controller bug. The specialist should stop and ask for a corrected assignment.

## Tiers

Change Risk / Validation / CR tiers are intentionally simple:

- Tier 0: docs-only, handoff, plan, comments.
- Tier 1: workflow config, examples, public docs, scripts.
- Tier 2: normal gateway/app implementation.
- Tier 3: secrets, Keychain, config activation, helper lifecycle, external network, release/signing.

Tier 3 always needs security-sensitive review and cannot be downgraded to docs-only review.

## Public Boundary Gate

Every lane must preserve the open-source boundary:

- no internal domains;
- no internal model IDs in product code, examples, provider presets, README, or release artifacts;
- no JWTs, API keys, cookies, auth JSON, or key files;
- no real usage logs;
- no copied private gateway code or decompiled behavior;
- no private provider presets.

Use public fixtures and fake values only.

The `.codex/agents/*.toml` model routes are a local-development exception while this repository remains private on this Mac mini. They are not release-safe.

## First Development Handoff

The first real implementation session should start with `relaykit_planner` and focus on Gateway MVP:

1. Define provider profile schema.
2. Load `examples/providers.example.json`.
3. Generate model catalog from public profiles.
4. Add OpenAI-compatible Chat adapter using fake upstream tests.
5. Keep SwiftUI implementation deferred until the gateway contract is stable.
