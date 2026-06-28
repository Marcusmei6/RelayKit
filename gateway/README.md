# RelayKit Gateway

The gateway is a local loopback HTTP helper. It provides client-facing OpenAI-compatible surfaces and routes requests to configured upstream providers.

First milestone:

- `GET /healthz`
- `GET /v1/models`
- `POST /v1/responses`

The current implementation is a safe placeholder: it proves the server shape and returns deterministic local responses. Real adapters will be added behind tests.

Next implementation slice:

- load `examples/providers.example.json`;
- return configured model IDs from `/v1/models`;
- translate one non-streaming Responses request through an OpenAI Chat-compatible fake upstream;
- add `-config` for the config path while keeping `-listen` loopback by default.
