# Gateway Phase 1 Spec

Phase 1 makes the gateway useful without private providers: load public provider profiles, expose a model catalog, and translate one non-streaming Responses request through an OpenAI Chat-compatible upstream.

## ProviderProfile JSON

`examples/providers.example.json` is the public fixture shape:

```json
{
  "providers": [
    {
      "id": "local-openai-compatible",
      "name": "Local OpenAI Compatible",
      "base_url": "http://127.0.0.1:11434/v1",
      "api_format": "openai_chat",
      "auth_env": "RELAYKIT_EXAMPLE_API_KEY",
      "models": [
        {
          "id": "qwen3-coder",
          "display_name": "Qwen3 Coder",
          "context_window": 128000
        }
      ]
    }
  ]
}
```

Required provider fields: `id`, `name`, `base_url`, `api_format`, `models`.

Optional provider field: `auth_env`. It names an environment variable and must never contain a secret value.

Required model fields: `id`. Optional model fields: `display_name`, `context_window`.

Post-P0 public metadata such as `credential_ref`, `capabilities`, `routing`, and `upstream_model` is specified in `docs/spec/provider-profile-contract.md`. `auth_env` remains supported for existing configs; new app-created provider entries prefer `credential_ref.kind = "env"`.

Validation rules:

- reject empty `providers`;
- reject missing provider `id`, `base_url`, `api_format`, or empty `models`;
- reject unsupported `api_format`; Phase 1 supports only `openai_chat`;
- reject model entries with empty `id`;
- accept local fake providers without a populated `auth_env` value.

Acceptance test to be written when Go is available: Given `examples/providers.example.json`, when the config loader reads it, then it returns one provider with model `qwen3-coder` and no secret values.

## Config Loader

The gateway should load provider profiles from a JSON file path passed by CLI flag. Path resolution is plain filesystem resolution from the current working directory unless the user provides an absolute path.

Errors should be small and stable:

- unreadable file: `config_read_error`;
- invalid JSON: `config_parse_error`;
- invalid profile shape: `config_validation_error`;
- unsupported API format: `unsupported_provider_format`.

Acceptance test to be written when Go is available: Given a missing config path, when the gateway starts with `-config missing.json`, then startup fails with `config_read_error`.

## `/v1/models`

`GET /v1/models` derives its response from loaded provider profiles.

The response keeps the OpenAI-compatible `data` array and also mirrors it as `models` for Codex catalog refresh compatibility. `model_health` may include redacted aggregate counts such as `healthy` and `unhealthy`; it must not include raw upstream URLs, headers, credentials, or private failure bodies.

For every configured model:

- `id` is the configured model id;
- `object` is `model`;
- `owned_by` is the provider id;
- `created` may be a deterministic zero value or gateway startup time.

Acceptance test to be written when Go is available: Given the public example config, when `/v1/models` is requested, then the response contains `qwen3-coder` owned by `local-openai-compatible`.

## OpenAI Chat Adapter

Phase 1 supports one non-streaming path:

Client `POST /v1/responses` request:

```json
{
  "model": "qwen3-coder",
  "input": "Say hi"
}
```

Upstream Chat request:

```json
{
  "model": "qwen3-coder",
  "messages": [
    { "role": "user", "content": "Say hi" }
  ],
  "stream": false
}
```

If `input` is already an array of message-like objects, preserve `role` and text content where possible. Unsupported fields should be ignored in Phase 1 unless they change routing or safety.

Upstream Chat response fields map back to Responses shape:

| Chat field | Responses field |
| --- | --- |
| `id` | `id` when present, otherwise synthesize `resp_<chat id or timestamp>` |
| `model` | `model` |
| `choices[0].message.content` | `output_text` and `output[0].content[0].text` |
| `choices[0].finish_reason` | `status = completed` for `stop`; otherwise `status = incomplete` |
| `usage` | normalized Responses `usage` with `total_tokens` derived from input/output tokens when needed |

Acceptance test to be written when Go is available: Given a fake upstream Chat server returning `choices[0].message.content = "hi"`, when `/v1/responses` receives `{"model":"qwen3-coder","input":"Say hi"}`, then the gateway returns Responses-shaped JSON containing output text `hi`.

## CLI Flags

- `-listen`: loopback listen address, default `127.0.0.1:19777`.
- `-config`: provider profile JSON path, default `../examples/providers.example.json` when running from `gateway/`.

Acceptance test to be written when Go is available: Given `-listen 127.0.0.1:0 -config <fixture>`, when the gateway starts in a test, then it binds locally and loads the fixture.

## Not In Phase 1

- streaming;
- Anthropic adapter;
- Keychain;
- app config activation;
- usage event logging;
- private provider presets.
