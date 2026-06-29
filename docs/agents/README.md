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

## Continuation Gate

Planner must not stop just because one slice or commit is complete. After every clean commit or parked blocker, it must re-read `docs/development-plan.md` and `docs/handoff.md`, rebuild the dispatch board, and continue to the next safe P0/P1 item when all of these are true:

- `main` is clean and validation for the previous slice passed;
- the next item has clear owned paths and no dependency on real credentials, signing, publishing, private providers, hosted telemetry, or destructive operations;
- the work can stay inside the current milestone or the next listed milestone in `docs/development-plan.md`;
- a specialist lane can own the work without overlapping another writer.

Planner may stop only when the current milestone and the next safe milestone item are both complete, blocked, or require a human/product decision. The final response must name the next candidate item and why it did not start.

## Spec Gap Repair Gate

Planner owns small missing contracts. If the next safe item is blocked only by missing local details such as schema, path, field list, error code, redaction rule, or a narrow interface contract, planner must write conservative defaults into `docs/development-plan.md`, `docs/handoff.md`, or `docs/spec/*.md`, then continue implementation.

Do not ask for human input for small local defaults when the conservative choice is reversible and public-safe. Human input is allowed only when the missing decision changes product scope, public API compatibility, security posture, irreversible user data behavior, real credentials, private providers, signing, publishing, hosted telemetry, or destructive operations.

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

## Current Milestone Handoff

New implementation sessions should start with `relaykit_planner`, run the smoke baseline, then continue from `docs/development-plan.md` rather than a single-feature prompt. The current safe next milestone is Phase 5 local usage JSONL:

1. Use the conservative usage contract in `docs/development-plan.md`.
2. Write local JSONL only; no cloud upload or hosted telemetry.
3. Do not record request bodies, response bodies, prompts, headers, cookies, API keys, private domains, or raw credential-bearing URLs.
4. Continue to README/handoff closeout and the next safe hardening item if validation passes.
