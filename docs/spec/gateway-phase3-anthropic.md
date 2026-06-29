# Gateway Phase 3 Anthropic MVP

Phase 3 adds a minimal public Anthropic Messages adapter. It uses fake upstream tests only and keeps private provider extensions out of the repository.

## Request Mapping

| Anthropic Messages field | Internal canonical | OpenAI-compatible client view |
| --- | --- | --- |
| `model` | model id | `model` |
| `messages[].role` | message role | `input[].role` |
| `messages[].content` text blocks | message text | `input` text/content |
| `system` | system instruction | system message or Responses instruction field |
| `tools` | tool definitions | Responses tools |

Phase 3 MVP sends `model`, `messages`, `max_tokens`, and `stream` when requested.

## Response Mapping

| Anthropic response field | Internal canonical | Responses field |
| --- | --- | --- |
| `id` | upstream id | `id` or synthesized response id |
| `model` | model id | `model` |
| text content block | assistant text | `output[].content[].text` |
| `tool_use` | tool call | `output[].tool_call` |
| `usage` | token usage | `usage` |

Phase 3 MVP maps text content blocks and usage. Tool-use blocks remain part of the public contract but are deferred until tool-call routing is implemented.

## Tool Use And Stop Reasons

| Anthropic concept | Responses concept |
| --- | --- |
| `tool_use` | tool call |
| `tool_result` | function/tool output |
| `end_turn` | completed |
| `tool_use` stop reason | requires tool output |
| `max_tokens` | incomplete |
| `stop_sequence` | completed with stop metadata |

## Streaming Mapping

| Anthropic stream event | Responses SSE |
| --- | --- |
| `message_start` | `response.created` |
| `content_block_delta` text | `response.output_text.delta` |
| `content_block_delta` tool data | `response.tool_call.*` |
| `message_delta` stop/usage | final metadata |
| `message_stop` | `response.completed` |

Phase 3 MVP streams text deltas, final stop reason, and usage when present.

## Unsupported Fields

Unsupported public fields must be rejected when they change execution semantics, and ignored only when they are metadata. Private provider extensions do not belong in this repository.

## Not In Phase 3 MVP

- Anthropic tool-use execution;
- private Anthropic-compatible provider presets;
- real provider smoke tests;
- client config activation.
