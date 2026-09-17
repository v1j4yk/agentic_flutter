# Changelog

## Unreleased

- **Fix:** `GeminiChatModel` defaults to `gemini-2.5-flash`. The previous
  default, `gemini-2.0-flash`, has been retired and returns 404.
- **Fix:** an API key Google rejects is an `AuthenticationException`. Google
  reports a bad key as `400 INVALID_ARGUMENT` with reason `API_KEY_INVALID`,
  which was mapped by status alone to a generic `ProviderException` — so apps
  never showed their "check your key" message to Gemini users.
- **Fix:** `GeminiEmbeddingModel` defaults to `gemini-embedding-001`. The
  previous default, `text-embedding-004`, has been retired by Google and
  returns 404, so every index built with the default silently failed to
  embed: `RagIndexer` records a failed document in its report rather than
  throwing, and apps saw documents indexed into zero passages. The 768
  default dimensions are unchanged and sent as `outputDimensionality`.

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
