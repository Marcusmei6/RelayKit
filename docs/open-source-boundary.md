# Open Source Boundary

RelayKit must be publishable without cleanup.

## Allowed

- Public provider examples.
- Fake API keys in examples.
- Public API format adapters.
- Local-only usage logs with fake fixtures.
- Documentation comparing public projects.

## Forbidden

- Internal domains.
- Internal model IDs.
- Private relay names.
- JWTs, API keys, cookies, auth JSON, key files.
- Copied local gateway binary strings or decompiled code.
- Real usage logs.
- Private provider probes.

## Adapter Policy

Public adapters live in this repo. Private adapters are separate packages or local config loaded at runtime.

The public gateway should expose stable interfaces that make private adapters possible without requiring them.

