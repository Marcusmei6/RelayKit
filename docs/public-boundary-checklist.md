# Public Boundary Checklist

Run this before any public push, release, or package handoff.

| Step | Evidence required |
| --- | --- |
| Replace `.codex/agents/*.toml` model IDs with public defaults. | `rg -n "model\\s*=|model_provider|model_hub|traex|relay/" .codex/agents docs` shows no private route values in publishable docs/config. |
| Scan for private route shapes. | `rg -n "relay/|model_hub|traex|internal[-_.a-z0-9]*\\.|corp[-_.a-z0-9]*\\." .` returns only documented checklist patterns or local-only notes removed before publish. |
| Scan for credential shapes. | `rg -n "api[_-]?key|secret|token|jwt|cookie|authorization" .` returns only boundary docs, fake examples/tests, credential validation/redaction tests, or implementation code that assembles provider auth headers from environment variables. No literal real credential values. |
| Check credential references only. | Provider configs may contain `auth_env` or `credential_ref`, but values must be references only. No provider JSON may contain raw key material. |
| Confirm examples are fake. | `jq . examples/providers.example.json` succeeds and contains only loopback/public fake values. |
| Verify fresh-clone basics. | `test -f LICENSE && test -f README.md && test -f gateway/go.mod`; then run README build commands on a machine with Go. |
| Check no private gateway code was copied. | Review gateway changes against public specs in `docs/spec/`; no private provider behavior, domains, logs, or decompiled strings. |
| Redact logs before sharing. | Logs contain no request bodies, tokens, cookies, local usernames, private domains, or real provider names. |

Publishing is blocked until every row has evidence.
