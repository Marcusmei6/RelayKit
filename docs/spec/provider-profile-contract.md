# Provider Profile Contract

This contract extends the Phase 1 provider profile with public-safe metadata needed by the menu-bar provider form and Open Design prototype vocabulary. It is intentionally conservative: RelayKit may store references and capability facts, but it must never store, print, display, or commit raw credential values.

## Credential References

`credential_ref` is optional. It describes where a credential can be found without embedding the credential:

```json
{
  "credential_ref": {
    "kind": "env",
    "value": "RELAYKIT_PROVIDER_TOKEN",
    "header": "Authorization"
  }
}
```

Supported reference kinds:

| kind | value contract | runtime status |
| --- | --- | --- |
| `env` | Environment variable name, matching `[A-Za-z_][A-Za-z0-9_]*`. Optional `header` selects a safe HTTP header name. | Implemented. Gateway reads the environment variable and injects the upstream auth header. |
| `keychain` | Local generic-password item service name using only letters, numbers, `.`, `_`, `:`, `@`, `/`, and `-`. Optional `header` selects a safe HTTP header name. | Implemented for local macOS runtime. The app writes the value to Keychain and provider JSON stores only this reference. App-owned launches resolve referenced items with Security.framework and send them once through an anonymous stdin pipe; the gateway keeps them in memory and injects only the configured upstream auth header. Standalone launches retain the local Keychain fallback. |
| `key_file` | Absolute path or home-relative path beginning with `/` or `~/`. Optional `header` selects a safe HTTP header name. | Implemented for local runtime. Gateway reads the file and injects only the configured upstream auth header. |

`auth_env` remains supported for backwards compatibility. New app-created provider entries should prefer `credential_ref.kind = "env"`.

Rejected values:

- literal API keys, bearer tokens, passwords, cookies, JWTs, or other secret-looking strings;
- unsupported kinds such as `api_key`;
- key-file references that are relative paths;
- header names containing spaces, credentials, or non-token characters;
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

## Catalog Metadata

`catalog` is optional public metadata for read-only model discovery:

```json
{
  "catalog": {
    "models_url": "https://example.test/v1/models",
    "key_header": "Authorization"
  }
}
```

Rules:

- `models_url` must be an absolute `http` or `https` URL.
- `models_url` must not contain user info, query strings, or fragments.
- `key_header` is a safe header reference only. It is not a credential value and must not include bearer prefixes, API keys, or token material.

Catalog metadata tells RelayKit where a provider's public model list can be discovered. It does not authorize execution by itself.

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
- public source and display prefix routing metadata;
- base URL;
- API format;
- credential reference as `credential_ref`;
- catalog models URL and key-header reference metadata;
- model id, display name, upstream model, and context window;
- boolean capability metadata and route visibility/priority.

Env, Keychain, and key-file credential references are executable in the gateway today. The app provider form may write a Keychain credential value to macOS Keychain, but provider JSON must contain only `credential_ref.kind = "keychain"` and the item reference. App-created routes are enabled only from explicit provider metadata and credential references; raw credential values never belong in provider JSON.
