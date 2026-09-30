# Migrating to 0.3.0

Version 0.3.0 adds model discovery and switching, W3C trace propagation,
OTLP export, trajectory assertions, and Agent Skills across the framework.
It also changes a few defaults and constructors that require action.

## Required changes

### Pin DeepSeek and Mistral models

`OpenAiCompatibleChatModel.deepSeek` and `.mistral` now require an explicit
`model`. Use the supplied constants or a provider model name:

```dart
final deepSeek = OpenAiCompatibleChatModel.deepSeek(
  apiKey: apiKey,
  model: DeepSeekModels.flash,
);

final mistral = OpenAiCompatibleChatModel.mistral(
  apiKey: apiKey,
  model: MistralModels.medium,
);
```

### Handle the new Gemini embedding default

`GeminiEmbeddingModel` now defaults to `gemini-embedding-2`. Embedding spaces
are not interchangeable. An index written with `gemini-embedding-001` must be
queried with the legacy model or rebuilt completely.

To keep an existing index working temporarily:

```dart
final embeddings = GeminiEmbeddingModel(
  apiKey: apiKey,
  model: GeminiModels.embeddingLegacy,
);
```

The preferred migration is to re-embed every document with the new model and
then switch both indexing and querying to it.

## Default model changes

The following defaults now name currently supported provider models:

| Adapter | Previous default | 0.3.0 default |
|---|---|---|
| OpenAI-compatible OpenAI | `gpt-4o` | `gpt-5.6` |
| Anthropic | `claude-sonnet-4-20250514` | `claude-sonnet-5` |
| OpenAI-compatible Grok | `grok-2-latest` | `grok-4.6` |
| Gemini chat | `gemini-2.5-flash` | `gemini-3.8-flash` |
| Gemini embeddings | `gemini-embedding-001` | `gemini-embedding-2` |

Pass `model` explicitly when an application must keep a particular provider
model or price profile.

## New capabilities

- Use `ModelDirectory.listModels()` to discover models available to a provider.
- Use `SwitchableChatModel` to change the model without rebuilding an agent.
- Trace headers can enter and leave through `TraceContext` and
  `AgenticContext.root(traceContext:)`.
- Provider and streamable HTTP MCP requests propagate `traceparent` and
  `tracestate` when a trace is active.
- `agentic_otel` exports spans over OTLP with batching support.
- `agentic_test` can assert tool trajectories, emit JUnit XML, and compare
  reports against regression baselines.
- Agent Skills are included in every published package.
