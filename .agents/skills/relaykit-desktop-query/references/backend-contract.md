# Backend contract

A backend is an executable script called exactly as:

```text
backend --model MODEL --query-file /absolute/path/query.txt
```

Requirements:

- Treat `model` as opaque input. Resolve ids or visible labels inside the backend.
- Read the query from the supplied regular `0600` file; never require query text in argv or environment variables.
- Perform one submission attempt. Do not retry when Send may already have happened.
- Print one JSON object to stdout. Use `{"status":"submitted"}` for an accepted submission, or a more complete backend-specific success object.
- Print a redacted JSON error to stderr and exit nonzero on failure.
- Never modify global Codex config/auth or fall back to human GUI interaction.

Set an absolute backend path with `RELAYKIT_DESKTOP_QUERY_BACKEND`. If it is unset, the runner looks for `scripts/codex-desktop-query-backend.sh` in the current Git repository.

RelayKit's default backend resolves `model` from current isolated catalog evidence, appends a public response marker to a private query copy, builds one `plain` stage, and invokes the existing `run-auto` harness once. Override the backend when another desktop automation implementation should own submission.
