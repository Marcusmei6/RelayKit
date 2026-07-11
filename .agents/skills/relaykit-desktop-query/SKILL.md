---
name: relaykit-desktop-query
description: Send one query through a selected Codex Desktop model by passing model and query parameters to a reusable desktop-automation backend script. Use when a RelayKit development or validation task explicitly asks to run a Codex Desktop query without human model selection, typing, or Send clicks.
---

# RelayKit Desktop Query

Accept exactly two logical inputs:

- `model`: the model id or visible model label understood by the configured backend;
- `query`: the complete query text to send.

## Run

1. Require explicit authorization when the query may incur model cost.
2. Create a unique temporary directory with mode `0700` and a query file with mode `0600`.
3. Write `query` only to that file. Do not put query text in argv or an environment variable.
4. Invoke the runner from the RelayKit repository root:

   ```bash
   .agents/skills/relaykit-desktop-query/scripts/run-query.sh \
     --model "$MODEL" \
     --query-file "/absolute/path/to/query.txt"
   ```

5. Let the runner select the backend from `RELAYKIT_DESKTOP_QUERY_BACKEND`, or from the repository default `scripts/codex-desktop-query-backend.sh`. Read [references/backend-contract.md](references/backend-contract.md) only when adding or changing a backend.
6. Return the backend's machine-readable result. On failure, report the error code without asking a person to select a model, type the query, or click Send.
7. Remove the temporary directory on success, failure, or interruption.

Keep orchestration here. Put GUI details, app launch, model selection, query entry, and submission in backend scripts.
