---
name: agentic-llm-local-models
description: >-
  Use when running a model locally with agentic_llm — Ollama, llama.cpp or any
  OpenAI-compatible server — including capability declarations for small
  models, tool calling that small models get wrong, local embeddings, and
  falling back between a local and a hosted model. Read this for offline or
  private inference, or when a local model returns malformed tool calls.
license: MIT
metadata:
  package: agentic_llm
  min-version: 0.2.0
---

# Local models

## Connecting

```dart
final ollama = OpenAiCompatibleChatModel.ollama(model: 'qwen2.5:7b');
final llama  = OpenAiCompatibleChatModel.llamaCpp();          // localhost:8080
final other  = OpenAiCompatibleChatModel.custom(
  baseUrl: Uri.parse('http://192.168.1.10:1234/v1'),          // LM Studio, vLLM, …
  model: 'my-model',
  provider: 'lmstudio',
  isLocal: true,
  capabilities: ModelCapabilities.localMinimal,
);
```

No API key, no cost. `isLocal: true` marks the model as free, so cost budgets
and usage reporting do not invent numbers.

On a device, `localhost` is the device: an Ollama server on your laptop is not
reachable from an Android emulator at `127.0.0.1`. Use the host's LAN address,
or `10.0.2.2` for the Android emulator.

## Capabilities: declare what is true

The local constructors default to `ModelCapabilities.localMinimal`, and that is
deliberate. Many local models advertise tool calling through Ollama and then
emit malformed calls, or accept a JSON schema and ignore it. Claiming a
capability the model does not have produces a plausible-looking wrong answer
deep inside an agent loop; refusing up front produces a clear error.

Once you have verified a specific model, say so:

```dart
OpenAiCompatibleChatModel.ollama(
  model: 'qwen2.5:7b',
  capabilities: const {
    ModelCapability.toolCalling,
    ModelCapability.streaming,
    ModelCapability.systemPrompt,
  },
);
```

Verify by running the tools you actually ship, not a toy one: tool choice
degrades fastest on small models when there are several similar tools.

## Getting usable behaviour from a small model

1. **Fewer tools.** Three, with sharply different descriptions, beats ten.
2. **Shorter instructions.** A 7B model follows one paragraph, not a page.
3. **Lower `maxIterations`.** A small model that is going to loop will loop
   early; `AgentBudget.interactive` is a good starting bound.
4. **Prefer extraction over reasoning.** Local models are good at
   classification, tagging, rewriting and summarising; they are poor at
   multi-step tool use.
5. **Expect repair.** Argument validation and repair in `agentic_tools` exists
   because models send `"5"` where a number is required — this is where it earns
   its place.

## Local embeddings

```dart
final embedder = OpenAiCompatibleEmbeddingModel.ollama(
  model: 'nomic-embed-text',
  dimensions: 768,
);
```

`dimensions` must match what the model produces and what the vector store was
created with; `EmbeddingIndex` refuses a mismatch at construction rather than
after an ingestion run. Changing embedding model invalidates an index — the
spaces are not comparable, so re-embed rather than mixing.

## Hybrid: local first, hosted when it matters

```dart
final model = FallbackChatModel([
  OpenAiCompatibleChatModel.ollama(model: 'qwen2.5:7b'),
  OpenAiCompatibleChatModel.openAi(apiKey: key, model: OpenAiModels.balanced),
]);
```

Failover covers "the local server is not running". For a deliberate choice —
private data stays local, hard questions go to a hosted model — hold both and
pick, or use `SwitchableChatModel` so the choice can follow a setting.

## Why this matters on a phone

Local inference is the one thing a Flutter app can do that a server framework
cannot: it works on a plane, it costs nothing per token, and the user's data
never leaves the device. The adapters here talk to a *server* speaking the
OpenAI format; running weights inside the app process is a different problem
(LiteRT-LM, llama.cpp bindings) and not what these constructors do.

## Common mistakes

- Pointing at `localhost` from a device or emulator.
- Declaring `ModelCapabilities.frontier` on a 7B model because it "supports
  tools".
- Mixing embeddings from two models in one index.
- Giving a local model the same twelve tools as a frontier model and concluding
  local models do not work.
- Forgetting the model has to be pulled first: `ollama pull qwen2.5:7b`.

## See also

- `agentic-llm-choose-provider` — capabilities and model naming
- `agentic-llm-middleware-retry-fallback-cache` — failover between models
- `agentic-vector-choose-store` — where local embeddings end up
