# Changelog

## 0.3.1

- Updated package documentation for the published 0.3.x release line.

## 0.3.0

### Added

- Every provider request now carries `traceparent` (and `tracestate`) when the
  `AgenticContext` has a trace. Providers do not read it; the proxy, gateway or
  backend in front of one does — and without it, "the model call" and "the
  request that reached our proxy" are two unrelated traces, so nobody can say
  which turn was slow. Trace headers are merged beneath the configured ones, so
  a name collision can never displace authentication.

### Added

- **Model constants for every provider.** `AnthropicModels.opus`, `.sonnet`,
  `.haiku`; `OpenAiModels`, `GeminiModels`, `GrokModels`, `DeepSeekModels` and
  `MistralModels`. `model` is still a plain `String` everywhere, so any
  identifier a provider serves works, including one released after this
  package: the constants are a convenience, not a whitelist.
- **`ModelDirectory.listModels()`** on the OpenAI-compatible, Anthropic and
  Gemini adapters, following each provider's pagination to the end. This is
  what a model picker in an app should read, because only the provider knows
  what a given key may call today. Ollama and llama.cpp answer it too.
- **`SwitchableChatModel`**, so the model can be changed at run time — from a
  settings screen, say — without rebuilding the agent holding it, which would
  otherwise lose the session. A request in flight finishes on the model it
  started.
- `LlmHttpTransport.getJson`, the read-only call the listing endpoints need.

### Changed

- **Default model identifiers now name models that exist.** Every default had
  gone stale, and two were retired outright:

  | Adapter | Was | Now |
  |---|---|---|
  | `OpenAiCompatibleChatModel.openAi` | `gpt-4o` | `gpt-5.6` |
  | `AnthropicChatModel` | `claude-sonnet-4-20250514` (retired) | `claude-sonnet-5` |
  | `OpenAiCompatibleChatModel.grok` | `grok-2-latest` (retired) | `grok-4.6` |
  | `GeminiChatModel` | `gemini-2.5-flash` | `gemini-3.8-flash` |
  | `GeminiEmbeddingModel` | `gemini-embedding-001` | `gemini-embedding-2` |

  Pass `model` explicitly to pin any of them. `text-embedding-3-small` is
  unchanged, and still current.

- `packages/agentic_integration` gained `bin/check_models.dart`, run nightly in
  CI: it asks each provider for its model list and fails when a name this
  framework ships is no longer served. The two defaults that rotted before were
  both found by users, not by us.

### Breaking

- **`GeminiEmbeddingModel` defaults to a different embedding model**, and
  embedding spaces are not comparable across models: an index written with
  `gemini-embedding-001` cannot be searched with `gemini-embedding-2` queries,
  and the results are plausible nonsense rather than an error. Either pass
  `model: GeminiModels.embeddingLegacy` to keep an existing index working, or
  re-embed every document.
- **`OpenAiCompatibleChatModel.deepSeek` and `.mistral` now require `model`.**
  Both providers publish dated identifiers or serve retired names through their
  replacements, so a default was deciding — silently, and differently over time
  — which model you pay for. `DeepSeekModels` and `MistralModels` name the
  published options.

## 0.2.0

- Released with the rest of the framework at 0.2.0, which it now
  depends on. No changes to this package's API or behaviour.

## 0.1.2

Fixes for Gemini. No API changes; upgrade with `dart pub upgrade`.

- `GeminiChatModel` defaults to `gemini-2.5-flash`. The previous default,
  `gemini-2.0-flash`, has been retired by Google and returns 404.
- `GeminiEmbeddingModel` defaults to `gemini-embedding-001`. The previous
  default, `text-embedding-004`, has been retired and returns 404. Because
  `RagIndexer` records a failed document in its report rather than throwing,
  this showed up as documents indexed into zero passages, not as an error. The
  default of 768 dimensions is unchanged.
- An API key Google rejects is now an `AuthenticationException`. Google reports
  a bad key as `400 INVALID_ARGUMENT` with reason `API_KEY_INVALID`, which was
  mapped by status alone to a generic `ProviderException`, so apps never showed
  their "check your key" message to Gemini users.

## 0.1.1

- Shortened the package description to the 60-180 character window pana
  scores against. Search engines truncate anything longer, so the ten points
  it withheld were pointing at a real defect: the useful half of the sentence
  was never being shown.

## 0.1.0

Initial release of the model layer.

### Added

- **Ports** — `ChatModel` and `EmbeddingModel`, with `ChatRequest`,
  `ChatResponse`, `ModelInfo`, `ModelCapability` and `ModelPricing`.
  Capability negotiation fails unsupported requests with a message naming the
  missing feature rather than a provider 400.
- **Streaming** — `ChatChunk`, `ToolCallDelta` and `ChatResponseBuilder`, which
  reassembles fragmented tool-call JSON, keeps parallel calls apart, orders by
  provider index and tolerates truncation. A collected stream produces the same
  `ChatResponse` a non-streaming call would.
- **Transport** — a shared HTTP client with cancellation, timeouts, and error
  mapping onto the core hierarchy, including the 429-versus-quota distinction
  and `Retry-After` in both legal formats. A specification-compliant
  server-sent-event decoder that survives chunk boundaries and multi-byte
  splits.
- **Providers** — `OpenAiCompatibleChatModel` (OpenAI, DeepSeek, Grok, Mistral,
  Together, Groq, Ollama, llama.cpp), `AnthropicChatModel`, `GeminiChatModel`,
  plus OpenAI-compatible and Gemini embedding adapters.
- **Middleware** — `RetryingChatModel`, `FallbackChatModel` with per-provider
  circuit breakers, `CachingChatModel` with `ChatCache` and `InMemoryChatCache`,
  and `ObservableChatModel` for logs, traces and events.
- **Events** — `LlmRequestStarted`, `LlmFirstTokenReceived`,
  `LlmResponseCompleted`, `LlmRequestFailed` and `LlmFailoverOccurred`.
- **Testing** — `package:agentic_llm/testing.dart` exports `FakeChatModel`,
  `FakeTurn` and `FakeEmbeddingModel`.
