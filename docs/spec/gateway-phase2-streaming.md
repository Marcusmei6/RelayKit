# Gateway Phase 2 Streaming MVP

Phase 2 adds a minimal public streaming path: translate OpenAI Chat-compatible SSE chunks from a fake upstream into Responses-style SSE frames. It keeps the adapter small and avoids real provider calls.

## Responses SSE Events

RelayKit should emit:

- `response.created`: synthesize when upstream stream starts;
- `response.output_text.delta`: preserve text deltas from upstream Chat chunks;
- `response.completed`: synthesize when upstream sends `[DONE]`;
- error frame: synthesize on malformed chunks or upstream failure.

## Chat SSE Mapping

| Upstream Chat stream item | RelayKit action |
| --- | --- |
| first chunk with role/model/id | synthesize `response.created` |
| `choices[].delta.content` | preserve as `response.output_text.delta` |
| `usage` | include in `response.completed` when present |
| `choices[].finish_reason` | preserve into final completion metadata |
| `[DONE]` | synthesize `response.completed` |
| unknown public field | drop unless needed for usage or finish metadata |

## Interruption Behavior

- client disconnect: cancel upstream request;
- upstream truncation: emit one error frame if the client is still connected;
- malformed chunk: stop stream and emit one error frame;
- timeout: use the gateway server timeout policy once it exists.

## Not In Phase 2 MVP

- tool-call streaming synthesis;
- Anthropic streaming;
- retry framework;
- resumable streams;
- hosted telemetry.
