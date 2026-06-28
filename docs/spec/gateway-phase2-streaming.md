# Gateway Phase 2 Streaming Stub

Stub: pending Phase 1 acceptance. This file sketches the streaming contract only; do not implement it until Phase 1 passes.

## Responses SSE Events

Stub: pending Phase 1 acceptance.

RelayKit should emit:

- `response.created`: synthesize when upstream stream starts;
- `response.output_text.delta`: preserve text deltas from upstream Chat chunks;
- `response.tool_call.*`: synthesize only when public upstream tool-call deltas are present;
- `response.completed`: synthesize when upstream sends `[DONE]`;
- error frame: synthesize on malformed chunks or upstream failure.

## Chat SSE Mapping

Stub: pending Phase 1 acceptance.

| Upstream Chat stream item | RelayKit action |
| --- | --- |
| first chunk with role/model/id | synthesize `response.created` |
| `choices[].delta.content` | preserve as `response.output_text.delta` |
| `choices[].delta.tool_calls` | preserve enough data to synthesize `response.tool_call.*` |
| `choices[].finish_reason` | preserve into final completion metadata |
| `[DONE]` | synthesize `response.completed` |
| unknown public field | drop unless needed for usage or finish metadata |

## Interruption Behavior

Stub: pending Phase 1 acceptance.

- client disconnect: cancel upstream request;
- upstream truncation: emit one error frame if the client is still connected;
- malformed chunk: stop stream and emit one error frame;
- timeout: use the gateway server timeout policy once it exists.

## Not In This Stub

Stub: pending Phase 1 acceptance.

- Anthropic streaming;
- retry framework;
- resumable streams;
- hosted telemetry.
