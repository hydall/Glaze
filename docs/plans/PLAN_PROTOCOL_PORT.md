# Port Anthropic / Gemini / OpenRouter protocols from SillyTavern

Status: done — all protocols implemented. Transport layer lives in `lib/core/llm/transport/`, message converters in `lib/core/llm/converters/`. Schema v23 added `api_configs.protocol`. See `docs/ARCHITECTURE.md` § 1.
Source of truth in SillyTavern:
- `src/prompt-converters.js` — pure converters (claude/google/openrouter caching/etc).
- `src/endpoints/backends/chat-completions.js` — per-provider HTTP/SSE transport.
- `src/endpoints/anthropic.js`, `google.js`, `openrouter.js`.

## Scope (decided)

In:
- **Anthropic** (`/v1/messages`) — prefill, vision (1 image / msg), extended thinking, cache_control.
- **Google Gemini AI Studio** (`streamGenerateContent`) — vision, thinking budget, safety settings.
- **OpenRouter** — dedicated transport with hardcoded `https://openrouter.ai/api/v1`, HTTP-Referer/X-Title, cache_control at depth for Claude through OR, reasoning signatures.
- **OpenAI** — refactor of current `SseClient` into a transport; behavior unchanged.
- **Vision** — single image per message (already exists as `ChatMessage.imagePath`); converters base64-encode it per provider.
- **Extended thinking** — Claude `thinking.budget_tokens`, Gemini `generationConfig.thinkingConfig.thinkingBudget`.

Out of scope (this iteration):
- Vertex AI (OAuth), Cohere, Mistral, AI21, xAI, Kobold, OpenAI Responses API.
- Tool/function calling, audio/video blocks, multi-image messages.

## Decisions

- **No separate prefill field.** User puts an `assistant`-role block at the end of the preset; `AnthropicChatTransport` detects last assistant message and uses it as Anthropic prefill (trim trailing whitespace; merge prefill back into final delivered text). With extended thinking enabled, prefill is dropped with a `debugPrint`.
- **OpenRouter is its own `LlmProtocol`** (not a flag on OpenAI). UI is explicit.
- **`ChatTransport` abstraction owns provider differences.** Consumers (`StreamGenerationService`, `SummaryService`, `MemoryDraftGenerator`, `SavedMessageWriter`, `ApiConnectionTester`, `InfoBlockService`, etc.) stop knowing OpenAI chunk shape.
- **Converters are pure functions** (no Riverpod, no Dio). Live in `lib/core/llm/converters/`.
- **Drift migration adds nullable column** `ApiConfig.protocol` (default `'openai'` for existing rows). No rename, no breaking change.
- **Vision base64-encoded** for all providers (universal). MIME inferred from extension.

## File layout

```
lib/core/llm/transport/
├── chat_transport.dart              # abstract ChatTransport
├── chat_transport_request.dart      # input (model, messages, params, attachments)
├── chat_transport_event.dart        # sealed: TextDelta / ReasoningDelta / Usage / Done / Error
├── openai_chat_transport.dart       # wraps current SseClient logic
├── anthropic_chat_transport.dart    # /v1/messages + SSE
├── gemini_chat_transport.dart       # streamGenerateContent + SSE
├── openrouter_chat_transport.dart   # OpenAI + OR extensions
└── transport_factory.dart           # selects by ApiConfig.protocol

lib/core/llm/converters/
├── openai_messages.dart       # PromptMessage[] -> OpenAI content (text + image_url parts)
├── claude_messages.dart       # -> Anthropic system + messages, prefill-aware
├── gemini_messages.dart       # -> contents + systemInstruction
├── openrouter_messages.dart   # OpenAI + cachingAtDepthForOpenRouterClaude + signatures
├── message_merger.dart        # port of mergeMessages
└── attachment_encoder.dart    # imagePath -> base64 + mime
```

## Provider-specific notes

### Anthropic
- URL: from `ApiConfig.endpoint` (default `https://api.anthropic.com`) + `/v1/messages`.
- Headers: `x-api-key`, `anthropic-version: 2023-06-01`, `content-type: application/json`. Add `anthropic-beta` when thinking is on.
- Body shape: `model`, `system` (separate), `messages: [{role, content[]}]`, `max_tokens`, `temperature`, `top_p`, optional `thinking: {type: enabled, budget_tokens}`, optional `stream: true`.
- Vision part: `{type: "image", source: {type: "base64", media_type, data}}`.
- Prefill: last assistant message → no `messages` append; trim trailing whitespace; prepend its content to the streamed text before delivering to consumers.
- SSE events: `content_block_delta` with `delta.type: text_delta` → `TextDelta`; `delta.type: thinking_delta` → `ReasoningDelta`; `message_delta` for usage; `message_stop` for done.
- cache_control: emitted on system block and on selected message blocks per `cachingAtDepthForClaude`.

### Gemini AI Studio
- URL: `https://generativelanguage.googleapis.com/v1beta/models/{model}:streamGenerateContent?alt=sse&key={apiKey}`.
- Body: `contents: [{role, parts: [{text}|{inlineData}]}]`, `systemInstruction`, `generationConfig: {temperature, topP, maxOutputTokens, thinkingConfig: {thinkingBudget}}`, `safetySettings: [...]`.
- Role mapping: `assistant` → `model`. System messages → `systemInstruction`.
- Vision part: `{inlineData: {mimeType, data}}`.
- SSE: chunks contain `candidates[0].content.parts[].text`; thought parts have `parts[].thought: true` → `ReasoningDelta`. Usage in `usageMetadata`.

### OpenRouter
- URL hardcoded `https://openrouter.ai/api/v1/chat/completions`.
- Headers: `Authorization: Bearer`, `HTTP-Referer: https://github.com/hydall/GlazeFlutter`, `X-Title: GlazeFlutter`.
- Body: OpenAI-compatible; plus per-model extras (cache_control depth for Claude via OR, signatures).
- SSE: same shape as OpenAI.

### OpenAI
- Behavior unchanged. Transport is a thin wrapper over the current `SseClient` body builder + parser.

## Migration & back-compat

- Existing `ApiConfig` rows → `protocol = 'openai'`.
- `SseClient` kept as public API initially; internally delegates to factory. Removed after all consumers migrate.
- Drift migration is additive (no rename, no drop). Schema version bumped, `onUpgrade` handler adds the column with default.

## Phase list

1. Drift migration + `LlmProtocol` enum + `ApiConfig.protocol` + UI selector in `api_settings_screen.dart` (+ default URLs/models per protocol).
2. `ChatTransport` contract + `ChatTransportEvent` sealed + Riverpod factory.
3. `OpenAiChatTransport` — refactor current `SseClient` body/SSE into transport; keep `SseClient` shim.
4. Pure converters + unit tests (`openai_messages`, `claude_messages`, `gemini_messages`, `openrouter_messages`, `message_merger`, `attachment_encoder`). Use SillyTavern fixtures.
5. `AnthropicChatTransport` (incl. prefill + thinking).
6. `GeminiChatTransport` (incl. thinking + safety).
7. `OpenRouterChatTransport` (incl. cache_control depth + signatures).
8. `ApiConnectionTester` branches per protocol + chat/runtime consumers (`StreamGenerationService`, bridge text generation, `InfoBlockService`, `MemoryDraftGenerator`) go through `ChatTransport` factory instead of `SseClient`.
9. Manual smoke test by user via `flutter run` for each protocol.

## Open items (track if discovered mid-impl)

- Default models per protocol — TBD; mirror SillyTavern `constants.js` lists in UI dropdowns.
- Anthropic cache TTL UI — currently `cacheControlTtl` string on `SseClient`; verify it's surfaced in `ApiConfig`.
- Image size guardrails (Anthropic limit ~5 MB) — warn via `debugPrint`, not block.
