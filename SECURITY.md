# Security Policy

RelayKit is preparing for public beta. Please do not post secrets or private provider details in public issues.

## Reporting A Vulnerability

Use GitHub private vulnerability reporting when it is available for this repository. If it is not available yet, open a minimal public issue that says you need a private security channel, but do not include secrets, exploit details, private domains, tokens, raw logs, or screenshots with account data.

## Public-Safe Reports

Safe details:

- RelayKit version and build number.
- macOS version.
- Whether the package is local ad-hoc beta or signed beta.
- Redacted error messages.
- Reproduction steps using public demo config when possible.

Do not include:

- API keys, bearer tokens, cookies, or refresh tokens.
- `auth.json` contents.
- Real provider base URLs or private provider names.
- Keychain item names.
- Raw request or response bodies.
- Full logs or screenshots containing account/private-provider data.
