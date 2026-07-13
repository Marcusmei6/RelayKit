# Remote Mac Acceptance

This optional acceptance path verifies RelayKit on a separate macOS host without checking in machine identity, account, address, or filesystem details. Keep real host data in local environment variables only.

## Prerequisites

- The target Mac is reachable over SSH.
- RelayKit is already installed or checked out on that host.
- The target RelayKit App owns its normal loopback listener at `127.0.0.1:19777`.
- No command in this flow reads provider credentials or changes Codex configuration.

Set the remote target locally:

```bash
export RELAYKIT_ACCEPTANCE_HOST='relaykit-user@relaykit-host.example'
export RELAYKIT_ACCEPTANCE_ROOT='RelayKit-acceptance'
```

`RELAYKIT_ACCEPTANCE_ROOT` may be absolute on the target or relative to the SSH account's home directory. Do not put real values in tracked files or reports.

## Run

```bash
./scripts/mac-pro-acceptance-resume.sh
```

The helper first performs a bounded SSH readiness check. It then runs the read-only direct replacement check and records only aggregate catalog counts. Override the target URL only when the remote RelayKit instance uses another isolated loopback port:

```bash
RELAYKIT_ACCEPTANCE_URL=http://127.0.0.1:19777 \
  ./scripts/mac-pro-acceptance-resume.sh
```

## Acceptance Criteria

- SSH returns within the bounded timeout.
- The listener is RelayKit-owned and `/healthz` reports `service=relaykit` and `status=ok`.
- `/v1/models` exposes matching public and Codex-compatible arrays with at least one healthy model.
- Output contains aggregate counts only.
- No provider names, model identifiers, provider configuration, credentials, raw logs, prompts, or machine identifiers enter tracked files or reports.

Real-provider request proof is deliberately outside this public helper. Keep any approved provider scenario in ignored or repository-external files and execute it only in the designated validation lane.
