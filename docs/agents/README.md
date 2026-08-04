# RelayKit Agent Workflow

This file defines RelayKit's project-scoped agent workflow. It is a routing map, not a custom workflow engine.

Project agents live in `.codex/agents/` and are registered by `.codex/config.toml`. Keep these agents project-scoped so the public repository carries its own development workflow without depending on a user's global setup.

The checked-in agent configs use public model names. Keep private/local model routing out of the repository; use local untracked overrides if a machine needs them.

## Agents

| Agent | Model | Role | Writes? | Use when | Must not do |
| --- | --- | --- | --- | --- | --- |
| `relaykit_planner` | `gpt-5.6-sol` / `xhigh` | Controller and sole delegation owner | Planning/handoff only | Split work, assign at most two disjoint write lanes, enforce gates, converge evidence | Implement product code, auto-expand backlog, claim runtime metadata from self-report |
| `relaykit_gateway` | `gpt-5.6-luna` / `xhigh` | Go gateway specialist | `gateway/**` only | Protocols, routes, config, catalog, usage events, gateway tests | Edit App/docs/Agent config, delegate, copy private gateway behavior |
| `relaykit_app` | `gpt-5.6-luna` / `xhigh` | Apple app specialist | `app/**` only | SwiftUI/AppKit, Keychain, helper lifecycle, config activation | Edit gateway/docs/Agent config, delegate, implement protocol adapters in Swift |
| `relaykit_worker` | `gpt-5.6-sol` / `high` | Bounded project worker | Assigned docs/examples/config/tooling only | `docs/**`, `examples/**`, `.codex/**`, `.agents/**`, ordinary scripts | Edit App/Gateway, act as a cross-product generalist, delegate, merge/push |
| `relaykit_test` | `gpt-5.6-luna` / `medium` | Tracked-source read-only validator | Ignored test/build artifacts only | Eligible Tier 0/1 Fast Path executes the Planner exact command allowlist directly; otherwise Test executes the selector-generated plan. | Change, repair, restore, or stage tracked paths; add unplanned commands; delegate; drive live GUI manually |
| `relaykit_cr` | `gpt-5.6-sol` / `high` | Read-only reviewer | No | Correctness, simplicity, public-boundary, security-sensitive review | Edit files or delegate |
| `relaykit_release` | `gpt-5.6-luna` / `xhigh` | Release specialist | Assigned release/package paths only | Packaging, signing/notarization readiness, release docs | Edit product business code, delegate, sign/publish without authorization |

## Default Flow

1. Root session starts `relaykit_planner` for non-trivial project work.
2. Planner builds a dispatch board with plan id, branch/worktree, owned paths, blocked paths, dependencies, tiers, validators, and stop conditions.
3. Planner is the only project role that decides delegation. It may authorize at most two concurrent write lanes, and their owned paths must not overlap.
4. Project role selection is root-mediated. Planner outputs `PARENT DISPATCH REQUIRED`. Main/root is a mechanical dispatcher only: it launches only those exact registered roles and returns each role's complete result to Planner. Main/root must not patch files, redirect findings, choose another role, expand owned paths, change tiers, or bypass Planner. Planner remains the sole owner of decomposition, delegation, remediation, validation, and closeout decisions, and must not use nested generic `spawn_agent(task_name=...)`, because that inherits Planner model/effort instead of loading the specialist config.
5. Implementation lanes go to `relaykit_gateway`, `relaykit_app`, or `relaykit_worker`. Cross-App/Gateway work is always split into two specialist lanes.
6. Close implementation lanes, then run `relaykit_test`, then `relaykit_cr`, then `relaykit_release` when release scope exists. These gates never run concurrently.
7. Planner updates `docs/handoff.md` and relevant plan docs before final handoff.

Every CR finding returns through Main/root to Planner. Main/root must not send CR findings directly to an implementation role. Planner dispositions every finding and, when remediation is required, emits a new bounded assignment to the correct original owning specialist. The remediation result returns to Planner. Selector-path remediation receives a fresh selector plan before relaykit_test and relaykit_cr run again, sequentially; Fast Path remediation follows the bounded rerun rule below.

## Tier 0/1 Fast Validation Path

Tier 0/1 Fast Validation Path is eligible only when all of these are true: Validation Tier is 0 or 1; changed paths are limited to docs, public agent TOML, the workflow contract test, or ordinary project config; scope excludes app/**, gateway/**, credentials, Keychain, auth, shared services, LaunchAgents, port 18787, global Codex config, build, package, GUI, network, live requests, signing, and release; and Planner supplies an exact command allowlist.

An eligible Fast Path uses exactly one Planner, one bounded Worker, one Test, and one CR. Test executes the exact allowlist directly without selector generation or `relaykit-validate.sh --plan-only`. Tier 2/3 and every ineligible change retain the selector path.

Main/root still performs no decomposition or implementation, but may verbatim-correct a missing ROLE field, field-name typo, or command-transcription error without replanning. Allow at most one remediation. After a test-assertion-only fix, rerun only the corresponding test and minimal CR recheck without repeating passed runtime metadata. Nonblocking Medium/Low findings become backlog evidence without scope expansion.

## Desktop Live Validation Gate

Every selector-path validation lane starts with `./scripts/relaykit-validate.sh --base <commit> --head <commit> --plan-only`. The changed-file selector, not a generic tier label, decides whether the lane needs syntax, focused contracts, Swift/Go work, UI smoke, package, a live query, or full E2E. By default the repository must be clean; pass `--worktree` to deliberately plan the union of committed, staged, unstaged, and untracked paths. Execute the plan only after one coherent root-cause group is ready; do not repeat unchanged layers. Safe, side-effect-free local failures may be retried once. Live and full commands execute once and are never retried.

Signed Beta live-gate exception: `execution_allowed=false` from the signed-beta plan means plan-only and forbids selector-driven automatic execution; it does not deny a separately user-authorized, Planner-bounded one-time live gate.

The only permitted global config/auth interaction is the designated read-only non-content metadata/hash/signature guard. The guard must not mutate, copy, repair, restore, refresh, migrate, parse, inspect, print, or disclose global content. It may accept the current pre-run metadata/hash/signature as the baseline, must require exact before/after equality, and must fail closed on any mismatch or guard error.

For this exception, Planner must bind one exact isolated session, artifact, scenario, and command allowlist to one fresh run: at most six commands, each command exactly once, with no retry, continuation, aggregation, relabeling, or reuse. The allowlist must encode redaction, the non-content global guard, no other global config/auth or shared-service/LaunchAgent access, no port `18787`, exact cleanup, and current run-bound evidence.

`relaykit_test` directly executes only that exact allowlist and must not rerun or reinterpret the selector, plan, scenario, or author inputs. Main/root performs mechanical dispatch only. Ordinary selector-path and Fast Path semantics remain unchanged. This exception does not expand or replace the ordinary 1-3 test-message approval rule.

`relaykit_test` uses `workspace-write` because selected Swift/package commands may need ignored build outputs. That access does not grant source ownership: Test records `git status --porcelain=v1 --untracked-files=no` before and after execution, requires the snapshots to be byte-identical, and fails with `tracked_worktree_changed` instead of repairing any tracked change.

Desktop live validation is opt-in because it can send paid requests. A single explicitly authorized query may use `$relaykit-desktop-query` only when the plan selects `live-desktop-query`. The caller supplies explicit current catalog evidence plus catalog/artifact hashes and current setup/session ids; the catalog's `relaykit_lineage` must match all three. The Skill never chooses the first available `dist` catalog. The four-stage route-proof gate remains the tracked `./scripts/codex-desktop-manual-proof.sh run-auto --scenario /absolute/path/scenario.json` interface and cannot be satisfied by one dispatcher result. Neither path may ask a human to select a model, paste or type a query, click Send, or press Enter.

Accessibility permission, authenticated Desktop state, and repository-external provider configuration are one-time system prerequisites. A daily proof must then finish with no human intervention or fail with a bounded machine-readable auth/selector/PID/window error. Only harness exit `0` plus current evidence containing `desktop_gui_route_proof=automated_gui_complete` and `human_intervention_count=0` counts as automated Desktop success.

If `relaykit_cr` fails to start, returns a provider route error, or does not return after one bounded retry, treat the outcome as CR UNAVAILABLE. Main/root returns that unavailable result to Planner. Main/root must not invoke the root review or decide closeout. Main/root must not write unavailable or fallback-review state. Planner records CR UNAVAILABLE only in controller evidence and must not write any repository file. Planner may authorize fallback review only for the exact unchanged Test-verified diff with the same base commit, HEAD commit, changed-file set, complete diff SHA-256, and tracked-worktree snapshot. The fallback review verifies that identity before review and returns the complete fallback review result to Planner. Planner alone decides closeout from the passed tests, clean public-boundary scan, and fallback review. This root-review fallback applies only when CR is unavailable after its bounded retry and must never bypass actual CR findings. The fallback is forbidden when relaykit_cr returned actual findings; do not let CR provider availability become the only blocker.

## Approval Boundary

Main/root owns goal registration, pause/resume, risk assessment, and user confirmation. Main/root does not decompose tasks or implement changes. Planner decomposes work, designates and dispatches bounded roles, and owns remediation.

Main/root may approve one batch of 1-3 test messages only for the current task-bound isolated proof/session. Main/root approves only; the Planner-designated `relaykit_test` or `relaykit_worker` sends the messages. The batch is limited to 3 messages, stays bound to that isolated proof/session, does not read, refresh, copy, or migrate credentials, and does not touch global config/auth, LaunchAgents, shared services, or port `18787`. It does not publish, sign, delete, perform irreversible actions, automatically retry, or expand the approved count. More than 3 messages, any retry or count expansion, auth/login, shared ports or services, global config/auth, signing or release, and destructive or irreversible actions require user confirmation.

## Continuation Gate

Planner continues only inside the supplied plan. After every clean commit or parked blocker, it re-reads `docs/development-plan.md` and `docs/handoff.md`, rebuilds the dispatch board, and continues to the next assigned item when all of these are true:

- `main` is clean and validation for the previous slice passed;
- the next item has clear owned paths and no dependency on real credentials, signing, publishing, private providers, hosted telemetry, or destructive operations;
- the work stays inside the current assignment and does not require Backlog Expansion;
- a specialist lane can own the work without overlapping another writer.

Planner stops when the supplied plan is complete, blocked, or requires a human/product decision. It must not dispatch the next milestone merely because it is listed in `docs/development-plan.md`; that requires explicit Backlog Expansion opt-in.

## Spec Gap Repair Gate

Planner owns small missing contracts. If the next safe item is blocked only by missing local details such as schema, path, field list, error code, redaction rule, or a narrow interface contract, planner must write conservative defaults into `docs/development-plan.md`, `docs/handoff.md`, or `docs/spec/*.md`, then continue implementation.

Do not ask for human input for small local defaults when the conservative choice is reversible and public-safe. Human input is allowed only when the missing decision changes product scope, public API compatibility, security posture, irreversible user data behavior, real credentials, private providers, signing, publishing, hosted telemetry, or destructive operations.

## Backlog Expansion Gate

Backlog expansion is disabled by default. Planner may enable it only when the user explicitly asks or the assignment header contains `BACKLOG EXPANSION: enabled`. Without that opt-in, the current plan is the complete work boundary and Planner must not invent follow-on items merely to keep lanes busy.

When explicitly enabled, read the existing plan and handoff sources, add only local, reversible, public-safe items with clear ownership and validation, then rebuild the dispatch board. The two-write-lane limit and App/Gateway ownership split still apply.

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
