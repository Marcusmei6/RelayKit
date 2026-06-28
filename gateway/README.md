# RelayKit Gateway

The gateway is a local loopback HTTP helper. It provides client-facing OpenAI-compatible surfaces and routes requests to configured upstream providers.

First milestone:

- `GET /healthz`
- `GET /v1/models`
- `POST /v1/responses`

The current implementation is a safe placeholder: it proves the server shape and returns deterministic local responses. Real adapters will be added behind tests.

