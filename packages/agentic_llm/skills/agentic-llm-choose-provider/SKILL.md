---
name: agentic-llm-choose-provider
description: >-
  Use when wiring up a model in agentic_llm, or changing which one an app uses:
  the OpenAI-compatible, Anthropic and Gemini adapters, the model-name
  constants for every provider, listing what a key may call with
  listModels(), switching model at run time with SwitchableChatModel, and
  capability negotiation. Read this for "which model string do I pass",
  "let the user pick a model", or a 404 from a provider.
license: MIT
metadata:
  package: agentic_llm
  min-version: 0.3.0
---

# Choosing a provider and a model

## One port, three wire formats

```dart
final gpt    = OpenAiCompatibleChatModel.openAi(apiKey: key);
final claude = AnthropicChatModel(apiKey: anthropicKey);
final gemini = GeminiChatModel(apiKey: googleKey);
final local  = OpenAiCompatibleChatModel.ollama(model: 'qwen2.5:7b');
```

One adapter covers every provider speaking OpenAI's `/chat/completions` format
— OpenAI, DeepSeek, Grok, Mistral, Together, Groq, Fireworks, OpenRouter,
Ollama, llama.cpp — through named constructors, plus
`OpenAiCompatibleChatModel.custom(...)` for anything else. Anthropic and Gemini
differ structurally and have their own.

Everything above this layer takes `ChatModel`, so swapping providers changes one
line.

## Naming a model

`model` is always a plain `String`, so any identifier a provider serves works,
including one released after this package. The constants are a convenience:

```dart
AnthropicChatModel(apiKey: key, model: AnthropicModels.opus);   // .sonnet, .haiku
GeminiChatModel(apiKey: key, model: GeminiModels.flashLite);
OpenAiCompatibleChatModel.openAi(apiKey: key, model: OpenAiModels.flagship);
OpenAiCompatibleChatModel.grok(apiKey: key, model: GrokModels.previous);
OpenAiCompatibleChatModel.deepSeek(apiKey: key, model: DeepSeekModels.pro);
OpenAiCompatibleChatModel.mistral(apiKey: key, model: MistralModels.small);
```

`.deepSeek` and `.mistral` **require** `model`: both publish dated identifiers
or serve retired names through their replacements, so a default there would
quietly decide which model you pay for.

## Ask the provider what it serves

Constants go stale and documentation lags. The adapters implement
`ModelDirectory`, which is what a model picker should read — only the provider
knows what a given key may call today:

```dart
for (final available in await claude.listModels()) {
  print('${available.id}  ${available.label}');
}
```

Ollama and llama.cpp answer the same call, so the picker works against a local
server too. A rejected key throws `AuthenticationException` rather than
returning an empty list.

## Let the user change it

A model chosen in a settings screen must take effect without rebuilding the
agent holding it — an agent rebuilt mid-conversation loses its session:

```dart
final model = SwitchableChatModel(
  AnthropicChatModel(apiKey: key, model: AnthropicModels.sonnet),
);
final agent = ToolCallingAgent(info: info, model: model, budget: AgentBudget.interactive);

// Later, from the settings screen.
await model.switchTo(AnthropicChatModel(apiKey: key, model: AnthropicModels.opus));
```

A request already in flight finishes on the model it started, because swapping
underneath a half-streamed answer would interleave two models' tokens. Pass
`disposePrevious: false` when the models are cached and switched back and forth.

## Capabilities are declared, and checked

```dart
model.info.supports(ModelCapability.toolCalling);
model.info.requireCapability(ModelCapability.vision);   // throws if absent
model.info.contextWindow;
model.info.qualifiedId;                                  // 'anthropic:claude-sonnet-5'
```

Each constructor declares an honest capability set, and a request asking for
more fails with `CapabilityNotSupportedException` before the call. Two
consequences worth knowing:

- `AnthropicChatModel` does **not** declare `structuredOutput`. Claiming it
  would be a lie; `generateStructured` forces a tool call instead, which works
  better.
- `ollama` and `llamaCpp` default to `ModelCapabilities.localMinimal`, because
  many local models advertise tool calling and then emit malformed calls. Pass
  `capabilities:` explicitly once you have verified a specific model.

## Cost accounting

```dart
OpenAiCompatibleChatModel.openAi(
  apiKey: key,
  pricing: const ModelPricing(inputPerMillion: 0.25, outputPerMillion: 2.0),
);
```

Without `pricing`, `response.cost` is null and an `AgentBudget.maxCost` never
trips. Local models really are free, so `isLocal` models need no pricing.

## When a name goes stale anyway

It will: a model identifier is a fact about someone else's product. Two defaults
here have already been outlived, and one failed silently — a retired embedding
model surfaced as documents indexed into zero passages. `melos run models:check`
compares every name this package ships against each provider's live list, and
runs nightly in CI.

## Common mistakes

- Hard-coding a dated model identifier in application code, where nothing will
  ever tell you it was retired.
- Rebuilding the agent to change model, losing the session.
- Assuming a local model can call tools because it says so.
- Putting the API key in the app: a key in a binary is a published key. See
  `agentic-flutter-secrets-and-keys`.

## See also

- `agentic-llm-structured-output` — getting typed data back
- `agentic-llm-middleware-retry-fallback-cache` — retries, failover, caching
- `agentic-llm-local-models` — Ollama and llama.cpp in detail
