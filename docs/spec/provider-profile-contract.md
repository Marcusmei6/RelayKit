# Provider Profile Contract

This contract extends the Phase 1 provider profile with public-safe metadata needed by the menu-bar provider form and Open Design prototype vocabulary. It is intentionally conservative: RelayKit may store references and capability facts, but it must never store, print, display, or commit raw credential values.

## Credential References

`credential_ref` is optional. It describes where a credential can be found without embedding the credential:

```json
{
  "credential_ref": {
    "kind": "env",
    "value": "RELAYKIT_PROVIDER_TOKEN"
  }
}
```

Supported reference kinds:

| kind | value contract | runtime status |
| --- | --- | --- |
| `env` | Environment variable name, matching `[A-Za-z_][A-Za-z0-9_]*`. | Implemented. Gateway reads the environment variable and injects the upstream auth header. |
| `keychain` | Local item reference using only letters, numbers, `.`, `_`, `:`, `@`, `/`, and `-`. | Contract only. Do not read Keychain until the security/product decision is made. |
| `key_file` | Absolute path or home-relative path beginning with `/` or `~/`. | Contract only. Do not read key files until the security/product decision is made. |

`auth_env` remains supported for backwards compatibility. New app-created provider entries should prefer `credential_ref.kind = "env"`.

Rejected values:

- literal API keys, bearer tokens, passwords, cookies, JWTs, or other secret-looking strings;
- unsupported kinds such as `api_key`;
- key-file references that are relative paths;
- multi-line references.

## Capability Metadata

`capabilities` is optional and may contain only boolean facts:

```json
{
  "capabilities": {
    "streaming": true,
    "tools": false,
    "usage": true,
    "reasoning": false
  }
}
```

These values are metadata about observed or configured upstream behavior. They are not credential-bearing and must not cause RelayKit to invent behavior. If a capability is not known, omit the field.

## Routing Metadata

`routing` is optional public metadata:

```json
{
  "routing": {
    "source": "custom",
    "model_prefix": "custom/",
    "priority": 100,
    "status": "enabled",
    "visible": true
  }
}
```

Rules:

- `source` is a public-safe slug: lowercase letters, digits, and `-`, starting with a lowercase letter.
- `model_prefix` is the same slug format plus a trailing `/`.
- `priority` is non-negative.
- `status` is `enabled` or `disabled`. Disabled providers are omitted from `/v1/models` and are not routable.
- `visible` is boolean.

Routing metadata does not replace explicit model IDs in `models`. The gateway still routes by configured model ID.

## Model Metadata

Each model may optionally include `upstream_model`:

```json
{
  "id": "custom/coder",
  "display_name": "Coder",
  "upstream_model": "coder",
  "context_window": 128000
}
```

When `upstream_model` is present, RelayKit routes by the public `id` but sends `upstream_model` to the upstream provider. Responses and local usage keep the public RelayKit model id. `upstream_model` must not contain credential-looking strings.

## Current App Alignment

The provider add sheet persists only fields that are implemented honestly today:

- provider id and name;
- base URL;
- API format;
- env credential reference as `credential_ref`;
- model id and display name;
- context window.

Keychain/key-file references and manual capability toggles remain hidden or contract-only until product/security decisions select them explicitly.
