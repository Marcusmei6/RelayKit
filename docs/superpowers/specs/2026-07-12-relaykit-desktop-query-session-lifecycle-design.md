# RelayKit Desktop Query Session Lifecycle Design

Date: 2026-07-12

## Status and decision

Extend `$relaykit-desktop-query` from an ephemeral one-query dispatcher into a session-aware GUI automation interface while preserving the current one-shot behavior as the compatibility default.

The selected design uses an optional, opaque `session_id`. A caller that omits it gets safe one-shot behavior unless it explicitly asks to keep the runtime. A caller that supplies it can submit multiple independent Codex tasks through the same isolated RelayKit App, gateway, and Codex Desktop runtime, then choose when to stop that runtime.

Version 1 supports at most one active persistent GUI session because the App-first proof lifecycle owns isolated port `19777` and one isolated Desktop profile. The session identifier prevents stale or cross-task attachment; it does not imply concurrent GUI sessions.

## Current facts that shape the design

The current project Skill accepts only `model` and `query`, generates one `plain` stage, invokes `run-auto`, and closes every process. The main development flow instead validates four independent tasks in one App-first runtime: GPT-5.5 plain text, GPT-5.6 Luna plain text, provider Markdown, and a provider tool call. Each task requires a fresh task, exactly one submission, completed/200 usage, unique rollout/thread/marker binding, and a PID/window-bound screenshot.

Recent live validation exposed the following compatibility requirements:

- a clean checkout must contain the AX driver and `run-auto` harness; success that depends on untracked files is not releasable;
- RelayKit App must start and make `19777` healthy before isolated Codex Desktop starts;
- a newly ad-hoc-signed App can lose an existing Keychain ACL and require a visible macOS authorization precondition before any paid request;
- a model's stable ID can remain unchanged while the Codex picker label changes, so submission must resolve the visible label from the live runtime catalog rather than trust a caller-supplied label;
- a completed request cannot be combined with later requests after the App zip, source, harness, driver, catalog, or isolated config hash changes;
- ambiguous submission must never be retried automatically;
- repeatedly starting and stopping the App and Desktop magnifies Swift cold-start, Keychain, accessibility, and window-readiness failures.

## Goals

1. Preserve the existing `model + query` one-shot invocation.
2. Let a main Agent prepare one isolated GUI runtime, submit multiple queries through it, and stop it explicitly at the end.
3. Detect the exact App, gateway, Desktop process, window, catalog, and evidence state before every action.
4. Reuse only a runtime owned by the supplied session identifier.
5. Keep per-query evidence independent while allowing an explicitly finalized multi-stage proof when all stages share pinned runtime hashes.
6. Fail before submission when a precondition is missing, and never fall back to human model selection, typing, Send clicks, Computer Use, coordinates, or a non-GUI API substitute.
7. Keep global Codex config/auth, port `18787`, LaunchAgents, and legacy gateway state untouched.

## Non-goals

- Multiple simultaneous persistent GUI sessions in version 1.
- Bypassing a macOS password or Keychain authorization dialog.
- Treating a backend/API response as Desktop GUI proof.
- Retrying a request after Send may have occurred.
- Reusing the user's primary Codex window or an unrelated RelayKit App process.
- Promoting unrelated one-query results into the four-stage route-proof gate.

## Public Skill interface

The Skill exposes five operations through its runner and default backend:

```text
prepare
query
status
finalize
stop
```

### Query

```bash
.agents/skills/relaykit-desktop-query/scripts/run-query.sh query \
  --model MODEL \
  --query-file /absolute/path/query.txt \
  [--session-id SESSION_ID] \
  [--startup fresh|reuse-or-start|require-existing] \
  [--after stop|keep-background|keep-visible] \
  [--idle-timeout-seconds SECONDS] \
  [--expect plain|markdown|tool] \
  [--evidence-role ROLE]
```

The legacy form remains valid and maps to `query --startup fresh --after stop --expect plain`:

```bash
run-query.sh --model MODEL --query-file /absolute/path/query.txt
```

### Prepare

`prepare` performs the complete no-cost App-first preflight and leaves a ready runtime when requested. A later `query` may reuse it.

```bash
run-query.sh prepare \
  [--session-id SESSION_ID] \
  [--startup fresh|reuse-or-start|require-existing] \
  [--after stop|keep-background|keep-visible] \
  [--idle-timeout-seconds SECONDS]
```

Preparation validates Keychain/provider readiness, live models, global guards, the App gateway, the isolated Desktop window, and the exact automation source. It submits no model request.

### Status, finalize, and stop

```bash
run-query.sh status [--session-id SESSION_ID]
run-query.sh finalize --session-id SESSION_ID \
  [--profile standard-four-stage] \
  [--after stop|keep-background|keep-visible]
run-query.sh stop [--session-id SESSION_ID]
```

Without a session identifier, `status` reports `absent`, a single redacted active-session summary, or `multiple` without adopting anything. `stop` may omit the identifier only when exactly one owned session exists; otherwise it fails closed.

## Defaults and compatibility

| Caller input | Effective behavior |
| --- | --- |
| Legacy `--model/--query-file` only | Create fresh runtime, submit once, verify, stop everything |
| No session ID with `--after keep-*` | Create a generated session ID, return it, keep the runtime |
| Session ID supplied, startup omitted | `require-existing` |
| Session ID supplied, after omitted | `keep-background` |
| `reuse-or-start` with a ready supplied session | Reuse it |
| `reuse-or-start` with no session or an absent session | Create a new generated session; never invent or trust a caller path |
| Another active session owns `19777` | Return `session_conflict`; do not kill or adopt it |

Session IDs are backend-generated opaque values containing only lowercase ASCII letters, digits, and hyphens. They are never treated as paths.

`idle-timeout-seconds` defaults to `1800` for a persistent session and is bounded to `60..7200`. It has no effect on a one-shot invocation that stops immediately.

The model input remains backward compatible with either a model ID or a visible label. The runtime resolves it to exactly one live stable model ID before submission, stores that ID in evidence, and derives the current picker label from the live catalog and AX projection. An ambiguous or missing match fails before Send.

## Main development flow

The intended adaptive flow is:

```text
prepare or first query
  startup=reuse-or-start
  after=keep-background
  -> returns session_id

middle queries
  session_id=<returned id>
  startup=require-existing
  after=keep-background
  -> same App/gateway/Desktop; a fresh Codex task per query

final query or finalize
  session_id=<returned id>
  after=stop
  -> verify and persist evidence, then stop owned processes
```

For the current four-stage route proof, callers also pass the explicit expectation and evidence role for each query. `finalize --profile standard-four-stage` accepts only the required model/expectation/role set and only when all four requests were made by the same session with unchanged pinned hashes. It then writes the same full-proof classification expected by the project gate. It must not aggregate requests from different sessions or source hashes.

## Session state and ownership

Private session state lives under:

```text
~/Library/Application Support/RelayKit/DesktopProof/query-sessions/<session-id>/
```

Directories use mode `0700`; manifests, locks, command inputs, and query copies use mode `0600`. A manifest records only redacted operational metadata:

- schema version and session ID;
- state, creation time, last activity, and idle deadline;
- exact RelayKit App binary path, PID, and process start time;
- gateway PID, port, ownership, and health result;
- exact Codex binary path, PID, process start time, isolated HOME/CODEX_HOME/user-data-dir, and window identity;
- App zip, source snapshot, harness, AX driver, isolated config, and live catalog hashes;
- request IDs, model IDs, expectations, evidence roles, submission states, and evidence paths;
- global config/auth signatures captured at session start.

Process start time is recorded with PID to prevent PID-reuse attachment. Every mutating operation takes an atomic session lock. A concurrent query returns `session_busy` and does not wait indefinitely or submit.

## State machine

```text
absent
  -> starting
  -> precondition_required | ready

ready | parked
  -> busy
  -> ready | parked | ambiguous | degraded | stale

ready | parked | ambiguous | degraded | stale
  -> stopping
  -> closed
```

`precondition_required` means no paid request was submitted. It includes a typed reason such as `keychain_authorization_required`, `official_login_required`, or `provider_unavailable`.

`ambiguous` means Send may have occurred. The session remains available for inspection, no automatic retry is allowed, and `finalize` cannot pass until current-run evidence resolves the request.

`stale` means a pinned package/source/harness/config/catalog boundary changed. The session may be stopped but cannot accept more requests or be finalized as one proof.

## Runtime detection and refresh

Before every prepare, query, finalize, or stop action, the controller verifies:

1. the manifest and lock belong to the requested session;
2. PID plus process start time and executable path match the manifest;
3. the RelayKit App comes from the pinned extracted bundle;
4. port `19777` is owned by that App/gateway and `/healthz` plus `/v1/models` respond;
5. Codex uses the pinned isolated user-data-dir and CODEX_HOME;
6. the recorded window still belongs to the exact Codex PID;
7. global Codex config/auth and protected shared state are unchanged;
8. App zip, source, harness, AX driver, isolated config, and catalog hashes still match;
9. the requested model ID resolves exactly once in the live app-server catalog.

Soft refresh is automatic: activate the exact Desktop PID, rediscover its window when the old window ID disappeared, refresh the live catalog, and create a fresh task before submission. Visible labels are derived from the live model ID mapping and current AX semantics.

Hard restart never occurs inside an existing evidence session. If an owned component died or hashes changed, the current session becomes `degraded` or `stale`; the main Agent stops it and starts a new session ID. Unowned processes and ports always produce `runtime_conflict`.

## App and window placement

- `after=stop`: persist evidence, then stop isolated Codex, RelayKit App, gateway, helper processes, and the session watchdog.
- `after=keep-background`: leave RelayKit's menu-bar App and gateway running, park the isolated Codex window in the background, and reactivate it on the next query.
- `after=keep-visible`: leave the isolated Codex window visible for debugging or review.

Parking never changes the user's primary Codex window. Stop and cleanup target only exact session-owned PIDs and paths.

Persistent sessions have a default 30-minute idle timeout. A private watchdog checks the session lease at bounded intervals and stops only the exact owned runtime after expiry. Each successful command refreshes the lease. The watchdog is a child process, not a LaunchAgent.

## Submission and evidence rules

Each query:

1. writes the caller query only to a private `0600` file;
2. adds a unique response marker to a private copy;
3. opens a fresh task in the pinned workspace;
4. resolves and verifies the live model picker selection;
5. writes and reads back the composer value;
6. presses Send exactly once;
7. waits for matching completed/200 usage, unique rollout/thread/marker binding, and a process-bound screenshot;
8. applies the selected `plain`, `markdown`, or `tool` evidence contract;
9. extracts the uniquely bound assistant reply into a private `0600` response file, excluding the automation marker;
10. removes transient query copies and returns one JSON result.

Per-request redacted evidence is written under:

```text
dist/codex-desktop-query/<session-id>/<request-id>/
```

Private rollouts, logs, and session state remain under DesktopProof. Query or response bodies are not copied into public evidence. A full-profile finalization writes a separate aggregate manifest that references immutable per-request evidence and pinned hashes.

The result JSON contains the session ID, request ID, stable model ID, lifecycle state, submission state, private `response_file` path, response SHA-256, redacted evidence path, and whether cleanup is required. It does not print the query or assistant reply text by default. The main Agent may read the private response file to decide the next query without contaminating public evidence or shell argv.

## Error and cleanup policy

- Failure before Send: report a typed error and zero-submission state. A legacy one-shot runtime is cleaned; a requested persistent runtime follows its `after` policy unless it is unsafe.
- Failure after a verified Send: do not retry. Preserve evidence and return the observed failure.
- Ambiguous Send: force the session to `ambiguous`, keep it available even if `after=stop` was requested, and return `cleanup_required=true`; the main Agent may inspect, resolve, or explicitly stop it.
- Global/shared-state mutation: fail the operation, stop owned processes when safe, and never repair or rewrite the global files.
- Interruption: the operation trap releases its lock and the watchdog retains ownership; one-shot mode performs bounded cleanup.
- `SIGKILL` or power loss: the next status/prepare call detects stale ownership using PID start time, and the idle watchdog covers the normal orphan case.

## Clean-checkout and production gates

Implementation cannot be considered usable until:

1. `run-auto`, the AX driver, and their tests exist in the committed baseline;
2. the Skill and backend pass from a clean checkout without relying on dirty or untracked files;
3. the no-cost `prepare` path works App-first and reports Keychain/login/provider preconditions before any request;
4. a stable signed build, or another approved credential handoff, avoids recurring Keychain ACL prompts for unattended production use;
5. the legacy one-shot flow and persistent multi-query flow both preserve global config/auth and avoid port `18787`;
6. documentation distinguishes single-query evidence, session evidence, and the finalized four-stage proof.

Until gate 4 is met, the Skill is suitable for controlled local development after one explicit OS authorization, but it is not fully unattended across newly ad-hoc-signed builds.

## Test strategy

Implementation follows test-first development.

Focused contract tests cover:

- legacy argument compatibility;
- generated and supplied session IDs;
- defaults for `startup` and `after`;
- bounded idle timeout parsing and lease refresh;
- manifest permissions and PID start-time validation;
- absent, ready, busy, degraded, stale, ambiguous, and closed states;
- no-session status/stop ambiguity;
- App-first launch ordering;
- exact ownership of `19777` and refusal to touch `18787`;
- live model-ID-to-label resolution and label drift;
- same-session reuse with unchanged App/Desktop PIDs;
- fresh task creation per query;
- plain, Markdown, and tool evidence;
- private assistant response extraction and marker removal;
- source/package/harness/config hash drift;
- one submission only and no retry after ambiguity;
- background parking, visible keep, explicit stop, and idle expiry;
- global config/auth and public-boundary redaction.

Forward validation then runs:

1. clean-checkout no-cost `prepare`;
2. one legacy query that starts and stops once;
3. two queries using one returned session ID, proving the same App/Desktop PIDs and two distinct task/rollout bindings;
4. a final query or explicit stop that releases `19777` and all owned processes;
5. the actual four-stage development profile, only after explicit paid-request authorization, followed by `finalize` and full evidence review.

## Implementation boundaries

The Skill remains orchestration and user-facing guidance. Deterministic lifecycle work belongs in scripts:

- update the Skill runner for operations and compatibility parsing;
- add a focused session controller for manifests, locks, status, parking, leases, and stop;
- refactor the existing manual-proof harness into reusable start/submit/verify/stop functions instead of duplicating GUI logic;
- keep exact AX model selection and submission in the tracked AX driver;
- update the default backend to translate one Skill query into one session request;
- update project agent instructions and proof documentation only after the behavior is verified.

The first implementation step is to establish a clean committed automation baseline. Session work must not be built on the current dirty-only AX/harness state.
