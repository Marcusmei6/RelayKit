---
name: relaykit-desktop-query
description: Send one planned high-risk validation query through a selected Codex Desktop model with explicit current catalog evidence. Use only when RelayKit's changed-file validation plan selects live-desktop-query.
---

# RelayKit Desktop Query

Accept these logical inputs:

- `model`: the model id or visible model label understood by the configured backend;
- `query`: the complete query text to send.
- `expect`: optional `plain`, `markdown`, or `tool`; defaults to `plain`.
- `catalog_evidence` plus its expected SHA-256, setup id, and session id: an explicitly selected current app-server catalog whose `relaykit_lineage` also binds the current artifact SHA-256.
- `artifact_sha256`: the expected current RelayKit zip SHA-256.

## Run

1. Require a `relaykit-validate.sh` plan whose `selected_commands` contains `live-desktop-query`, plus explicit authorization when the query may incur model cost.
2. Create a unique temporary directory with mode `0700` and a query file with mode `0600`.
3. Write `query` only to that file. Do not put query text in argv or an environment variable.
4. Invoke the runner from the RelayKit repository root:

   ```bash
   .agents/skills/relaykit-desktop-query/scripts/run-query.sh \
     --model "$MODEL" \
     --query-file "/absolute/path/to/query.txt" \
     --expect "${EXPECT:-plain}" \
     --catalog-evidence "/absolute/path/to/current/app-server.json" \
     --catalog-sha256 "$CATALOG_SHA256" \
     --catalog-setup-id "$CATALOG_SETUP_ID" \
     --catalog-session-id "$CATALOG_SESSION_ID" \
     --artifact-sha256 "$ARTIFACT_SHA256"
   ```

5. Let the runner select the backend from `RELAYKIT_DESKTOP_QUERY_BACKEND`, or from the repository default `scripts/codex-desktop-query-backend.sh`. Read [references/backend-contract.md](references/backend-contract.md) only when adding or changing a backend.
6. Return only the backend's redacted model, expectation, submission state, evidence path, artifact SHA, and catalog SHA. Do not return query or response text.
7. On failure, report the error code without asking a person to select a model, type the query, or click Send. Do not retry after Send may have occurred.
8. Remove the temporary directory on success, failure, or interruption.

Keep orchestration here. Put GUI details, app launch, model selection, query entry, and submission in backend scripts.

This Skill is a targeted single-query leaf. It does not choose validation scope, replace package or UI tests, aggregate a four-stage route proof, or implement the persistent session controller described in the session lifecycle design.

The default backend runs official models through a one-shot App-first lifecycle with an official-only gateway config. It reuses the fixed extracted artifact and persistent isolated login/profile, submits once through the PID/window-bound AX driver, records current-run usage/rollout/screenshot evidence, then stops the owned App/Desktop/gateway. Provider models remain on the compatibility full-harness path and require the caller's ignored local provider configuration.
