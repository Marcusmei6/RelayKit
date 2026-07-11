# Backend contract

A backend is an executable script called exactly as:

```text
backend --model MODEL --query-file /absolute/path/query.txt \
  --expect plain|markdown|tool \
  --catalog-evidence /absolute/path/app-server.json \
  --catalog-sha256 SHA256 \
  --artifact-sha256 SHA256
```

Requirements:

- Treat `model` as opaque input. Resolve ids or visible labels inside the backend.
- Read the query from the supplied regular `0600` file; never require query text in argv or environment variables.
- Require explicit catalog evidence and verify its SHA-256. Never scan `dist/` for the first available catalog.
- Verify the current product artifact against the caller's artifact SHA-256.
- Apply provider preconditions only when the resolved model comes from the provider catalog. Official models must not be rejected solely because provider configuration is absent.
- Perform one submission attempt. Do not retry when Send may already have happened.
- Print one redacted JSON object containing model, expectation, submission state, evidence path, artifact SHA, and catalog SHA.
- Print a redacted JSON error to stderr and exit nonzero on failure.
- Never modify global Codex config/auth or fall back to human GUI interaction.

Set an absolute backend path with `RELAYKIT_DESKTOP_QUERY_BACKEND`. If it is unset, the runner looks for `scripts/codex-desktop-query-backend.sh` in the current Git repository.

RelayKit's default backend resolves `model` from caller-pinned catalog evidence, appends a public response marker to a private query copy, builds one stage with the requested expectation, and invokes the existing automation harness once. Override the backend when another desktop automation implementation should own submission.
