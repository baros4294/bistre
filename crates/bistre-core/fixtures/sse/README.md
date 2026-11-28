# SSE wire fixtures

One directory per `ProviderDialect::as_str()` value; each `<name>.sse` file is a complete
response body exactly as the provider streams it (LF line endings, blank line after each event).
Tests load them with `test_support::sse_fixture(dialect, name)` and serve them through
`test_support::MockServer`.

| File | Shape |
|---|---|
| `openai/text.sse` | Responses API: `response.created`, two `response.output_text.delta`, `response.completed` with usage |
| `anthropic/text.sse` | Messages API: `message_start`, text block with `ping`, `message_delta` (`end_turn`), `message_stop` |
| `google_gemini/text_interactions.sse` | Interactions API: two `step.delta` text events, `interaction.completed` with usage |
| `google_gemini/text_generate_content.sse` | `streamGenerateContent?alt=sse`: two candidate chunks, `finishReason: STOP`, `usageMetadata` |
| `custom_openai/text.sse` | Chat Completions: two chunks, usage-only chunk, `[DONE]` |

Provenance: written by hand from each provider's published streaming reference, not captured
from a live account. They are `[UNVERIFIED]` against the live docs until the W4 protocol pass
re-checks every event name and field (tracked in `tasks.md`).
