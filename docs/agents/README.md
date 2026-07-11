# RelayKit Agent Workflow

This file defines RelayKit's project-scoped agent workflow. It is a routing map, not a custom workflow engine.

Project agents live in `.codex/agents/` and are registered by `.codex/config.toml`. Keep these agents project-scoped so the public repository carries its own development workflow without depending on a user's global setup.

The checked-in agent configs use public model names. Keep private/local model routing out of the repository; use local untracked overrides if a machine needs them.

## Agents

| Agent | Model | Role | Writes? | Use when | Must not do |
| --- | --- | --- | --- | --- | --- |
| `relaykit_planner` | `gpt-5.5` / `xhigh` | Controller | Narrow docs/workflow only | Split work, assign lanes, enforce gates, maintain handoff | Implement product code, claim dispatch without evidence, handle secrets |
| `relaykit_worker` | `gpt-5.4` / `high` | General worker | Yes | Bounded docs/examples/small cross-cutting tasks | Broaden scope, merge/push, edit private data |
| `relaykit_gateway` | `gpt-5.4` / `high` | Go gateway worker | Yes | Server, adapters, config, catalog, usage events | Edit app UI, copy private gateway behavior |
| `relaykit_app` | `gpt-5.5` / `xhigh` | Apple app worker | Yes | SwiftUI/AppKit shell, Keychain, helper lifecycle, config activation | Implement protocol adapters or SSE parsing in Swift |
| `relaykit_test` | `gpt-5.3-codex-spark` / `xhigh` | Validator | Ignored artifacts only | Focused validation, command evidence, tier adequacy, explicit Desktop live proof | Fix code, add tests, bless unverified claims, ask a human to drive Desktop proof |
| `relaykit_cr` | `gpt-5.5` / `xhigh` | Reviewer | No | Correctness, simplicity, public-boundary, security-sensitive review | Edit files |
| `relaykit_release` | `gpt-5.4` / `high` | Release validator | Ignored artifacts only | Packaging, signing readiness, public repo hygiene | Sign/notarize/publish without explicit user request |

## Default Flow

1. Root session starts `relaykit_planner` for non-trivial project work.
2. Planner builds a dispatch board with plan id, branch/worktree, owned paths, blocked paths, dependencies, tiers, validators, and stop conditions.
3. If planner cannot spawn specialists, it outputs `PARENT DISPATCH REQUIRED`; root launches the listed agents and returns results to planner.
4. Implementation lanes go to `relaykit_gateway`, `relaykit_app`, or `relaykit_worker`.
5. Validation goes to `relaykit_test`; review goes to `relaykit_cr`.
6. Release/package scope also requires `relaykit_release`.
7. Planner updates `docs/handoff.md` and relevant plan docs before final handoff.

## Desktop Live Validation Gate

Every validation lane starts with `./scripts/relaykit-validate.sh --base <commit> --head <commit> --plan-only`. The changed-file selector, not a generic tier label, decides whether the lane needs syntax, focused contracts, Swift/Go work, UI smoke, package, a live query, or full E2E. Execute the plan only after one coherent root-cause group is ready; do not repeat unchanged layers. Any command added after planning needs a recorded reason. The same failure may be retried once, then must be preserved and reported.

Desktop live validation is opt-in because it can send paid requests. A single explicitly authorized query may use `$relaykit-desktop-query` only when the plan selects `live-desktop-query`. The caller supplies explicit current catalog evidence plus catalog and artifact hashes; the Skill never chooses the first available `dist` catalog. The four-stage route-proof gate remains the tracked `./scripts/codex-desktop-manual-proof.sh run-auto --scenario /absolute/path/scenario.json` interface and cannot be satisfied by one dispatcher result. Neither path may ask a human to select a model, paste or type a query, click Send, or press Enter.

Accessibility permission, authenticated Desktop state, and repository-external provider configuration are one-time system prerequisites. A daily proof must then finish with no human intervention or fail with a bounded machine-readable auth/selector/PID/window error. Only harness exit `0` plus current evidence containing `desktop_gui_route_proof=automated_gui_complete` and `human_intervention_count=0` counts as automated Desktop success.

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

## Backlog Expansion Gate

If the dispatch board has fewer than two ready safe lanes, planner must expand the backlog before stopping. Read `docs/development-plan.md`, `docs/handoff.md`, `README.md`, `app/README.md`, `gateway/README.md`, and `docs/public-boundary-checklist.md`; add or refine P0/P1 items only when scope is local, reversible, public-safe, and has clear owned paths and validation.

After expansion, rebuild the dispatch board. If one safe lane remains, run it. Stop only when no safe lane remains, or the next lane needs real credentials, private providers, signing, publishing, hosted telemetry, destructive operations, public API/security posture changes, or irreversible user data behavior.

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

Private model routes are not release-safe and must stay out of checked-in agent configs.

## Current Milestone Handoff

New implementation sessions should start with `relaykit_planner`, run the smoke baseline, then continue from `docs/development-plan.md` rather than a single-feature prompt. Current completed local-alpha lanes include helper lifecycle, local observability, provider config editing, Anthropic tool-use hardening, macOS ad-hoc local beta packaging, and public agent-route scrub.

1. Use the current milestone backlog in `docs/development-plan.md`.
2. Choose Keychain/credential storage, signing/publishing readiness, or public push/release validation only after explicit selection.
3. Do not record or store credentials, request bodies, response bodies, prompts, headers, cookies, API keys, private domains, or raw credential-bearing URLs.
4. Continue to README/handoff closeout and the next safe hardening item if validation passes.
