# Changelog

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
