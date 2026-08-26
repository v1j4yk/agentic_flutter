# agentic_llm

Provider-independent language model access for the
[agentic](https://github.com/v1j4yk/agentic_flutter) framework.

One `ChatModel` port. Three genuinely different wire formats behind it. Cross-
cutting behaviour — retries, failover, caching, instrumentation — composed as
plain decorators.

## Installation

```yaml
dependencies:
  agentic_llm: ^0.1.0
```

## Providers

| Adapter | Covers | Notes |
|---|---|---|
| `OpenAiCompatibleChatModel` | OpenAI, DeepSeek, Grok, Mistral, Together, Groq, Fireworks, OpenRouter, **Ollama**, **llama.cpp** | Named constructors for the common hosts; `.custom()` for anything else |
| `AnthropicChatModel` | Claude | System hoisting, thinking blocks, batched tool results |
| `GeminiChatModel` | Gemini | `contents`/`parts`, OpenAPI schema subset |
| `OpenAiCompatibleEmbeddingModel` | OpenAI, Mistral, Ollama, … | |
| `GeminiEmbeddingModel` | Gemini | Task-typed, asymmetric embeddings |

Eight of those speak one wire format, so they share one adapter. Writing eight
near-identical adapters would mean eight copies of the same tool-call assembly
drifting apart with every fix.

```dart
final gpt    = OpenAiCompatibleChatModel.openAi(apiKey: key, model: 'gpt-4o');
final claude = AnthropicChatModel(apiKey: anthropicKey);
final gemini = GeminiChatModel(apiKey: googleKey);
final local  = OpenAiCompatibleChatModel.ollama(model: 'qwen2.5:7b');
```

Adding a provider the framework does not ship is a class implementing
`ChatModel` in your own package. Nothing here changes.

## The basics

```dart
final answer = await model.prompt(
  'Explain Dart records in one sentence.',
  system: 'You are concise.',
);
```

Or with the full request object:

```dart
final response = await model.generate(
  ChatRequest(
    messages: history,
    tools: registry.select(tags: {'research'}),
    temperature: 0.2,
    maxOutputTokens: 512,
  ),
  context: context,
);

response.ensureComplete();   // throws if truncated — see below
response.text;
response.toolCalls;
response.usage.totalTokens;
response.cost;               // when the model has pricing configured
```

### Always check the finish reason

`FinishReason.length` means the answer was **cut off**. Its JSON will not parse,
its tool call is half-written, its prose ends mid-sentence. Treating that as a
normal answer is how a silent data-corruption bug ships.

`ensureComplete()` is one call and it throws with a message naming the fix.

## Streaming

```dart
await for (final chunk in model.stream(request, context: context)) {
  if (chunk.textDelta case final delta?) buffer.write(delta);
}
```

Or collect it, when you want the streaming transport but not the incremental UI:

```dart
final response = await model.stream(request).collect();
```

The assembled response is **identical** to what `generate` would have produced.
Nothing above this layer needs to know which mode was used.

### What the accumulator is actually doing

Tool calls arrive as fragments of a JSON string, spread across chunks, with
parallel calls interleaved and distinguished only by an index:

```text
{"index":0,"id":"call_1","function":{"name":"search_web","arguments":""}}
{"index":0,"function":{"arguments":"{\"qu"}}
{"index":0,"function":{"arguments":"ery\":\"da"}}
{"index":0,"function":{"arguments":"rt 3\"}"}}
```

No fragment is valid JSON. `ChatResponseBuilder` reassembles them, keeps
parallel calls apart, orders by the provider's index rather than by arrival, and
— importantly — **tolerates truncation**: a stream cut off by the token limit
yields empty arguments plus the raw text, so the tool executor reports what is
missing and the model repairs it, instead of the whole run throwing.

`ChatResponseBuilder` doubles as a live view for UI:

```dart
final builder = ChatResponseBuilder();
await for (final chunk in model.stream(request)) {
  builder.add(chunk);
  setState(() => visible = builder.text);
}
final response = builder.build();
```

## Middleware

Every decorator is a `ChatModel` wrapping a `ChatModel`:

```dart
final model = ObservableChatModel(       // logs, traces, publishes events
  RetryingChatModel(                     // retries transient failures
    CachingChatModel(                    // serves repeats from cache
      FallbackChatModel([                // routes around a dead provider
        OpenAiCompatibleChatModel.openAi(apiKey: key),
        AnthropicChatModel(apiKey: anthropicKey),
        OpenAiCompatibleChatModel.ollama(model: 'qwen2.5:7b'),
      ]),
      cache: InMemoryChatCache(),
    ),
    policy: RetryPolicy.interactive,
  ),
);
```

Order is visible at the call site, and it matters: a cache outside the retry
caches nothing when the first attempt fails, and observation inside the retry
hides the retries from your dashboard.

A few behaviours worth knowing:

- **Streams are retried only before the first chunk.** Replaying after a token
  has been delivered would emit a second beginning, and a UI that already
  rendered the first sentence would show duplicated text.
- **Failover skips a provider whose circuit is open**, so the fallback is
  instant rather than preceded by another timeout. An exhausted quota fails over
  even though it is not retryable; a malformed request does not, because every
  provider rejects it identically.
- **Caching is off for creative requests by default** — the caller asked for
  variety, and the same sentence every time reads as a bug. Truncated answers
  are never cached, and a cache hit reports **zero** usage so a cost meter does
  not double-count.
- **Ordering your own decorator in** takes one class: extend
  `DelegatingChatModel` and override what you need.

## Tool calling

```dart
final response = await model.generate(
  ChatRequest(messages: history, tools: registry.all),
);

if (response.hasToolCalls) {
  final results = await executor.executeAllAsMessages(
    response.toolCalls,
    context: context,
  );
  // Append `response.message` and `results`, and send again.
}
```

`ToolChoice.none` on the final turn is the clean way to end a loop: the tools
stay described, so the model's earlier calls still make sense, but it must
answer in prose rather than calling a fourth search.

## Structured output

```dart
final invoice = await model.generateStructured<Invoice>(
  ChatRequest.prompt('Extract the invoice from this text: …'),
  name: 'invoice',
  schema: invoiceSchema,
  fromJson: Invoice.fromJson,
);
```

This uses guaranteed structured output where the model has it and falls back to
JSON mode where it does not — and validates against your schema either way, so
the fallback is weaker in cost, not in correctness. Schemas are converted to
each provider's strict dialect automatically; you write one schema.

On a provider with no structured-output mode at all, forcing a single tool call
achieves the same thing: `ToolChoice.tool('extract')` with a tool whose
parameters are the shape you want.

## Capability negotiation

```dart
if (model.info.supports(ModelCapability.vision)) {
  parts.add(ImagePart.bytes(photo, mimeType: 'image/jpeg'));
}
```

Requests carry their own requirements, so an unsupported feature fails with a
message naming it rather than as a provider 400:

```text
CapabilityNotSupportedException: `ollama:qwen2.5` does not support
structuredOutput.
```

Local adapters declare **conservative** capabilities on purpose. Many local
models advertise tool calling through Ollama and then emit malformed calls;
claiming it here would push that breakage into every agent above. Pass
`capabilities:` explicitly once you have verified a specific model.

## Errors

Every failure is an `AgenticException` with a stable code and an honest
`isRetryable`, mapped once in the shared transport:

| Upstream | Becomes | Retryable |
|---|---|---|
| 401 | `AuthenticationException` | no |
| 403 | `PermissionDeniedException` | no |
| 429 | `RateLimitException` (honours `Retry-After`, both formats) | yes |
| 429 + `insufficient_quota` | `QuotaExceededException` | **no** |
| 400 | `ProviderException` | no |
| 5xx | `ProviderException` | yes |
| socket / DNS / TLS | `ProviderException`, no status | yes |

That 429 split is the one that matters most: waiting fixes a throttle but never
restores a spent credit balance, and a retry loop against a billing failure is a
support-ticket generator.

## Cost accounting

```dart
final model = OpenAiCompatibleChatModel.openAi(
  apiKey: key,
  pricing: const ModelPricing(
    inputPerMillion: 2.5,
    outputPerMillion: 10,
    cachedInputPerMillion: 1.25,
  ),
);

response.cost;                 // estimated, per call
usage.cacheHitRate;            // is prompt caching actually working?
```

Prices are configuration, not constants baked into an adapter — they change.
Cached prompt tokens are billed at the cached rate, which is what makes a stable
system prompt across many turns an order of magnitude cheaper.

## Testing

```dart
import 'package:agentic_llm/testing.dart';

final model = FakeChatModel.toolCall(
  toolCalls: [ToolCallPart(id: 'c1', name: 'search_web', arguments: {'query': 'dart'})],
  then: 'Dart 3 added records and patterns.',
);

await agent.run('What is new in Dart 3?');

expect(model.callCount, 2);
expect(model.lastRequest.tools!.names, contains('search_web'));
```

`FakeChatModel` records every request, so you can assert on *what was sent* —
the question a mocking framework cannot answer. `FakeTurn.chunks` replays a
provider's exact fragmentation, which is the only way to test an accumulator
against reality.

## Performance notes

- **Share one model instance.** Each adapter owns an `http.Client`, and reusing
  it is the difference between one TLS handshake and one per turn.
- **Keep the system prompt byte-stable** to hit provider prompt caching; watch
  `usage.cacheHitRate` to confirm it is working.
- **Prefer URIs to inline images** on mobile: a 4 MB photo becomes a 5.3 MB
  base64 body.
- **Cancel abandoned streams.** Cancelling the subscription closes the socket;
  a stream left running is generated and billed in full.
- **`stream_options.include_usage` is set for you** on OpenAI-compatible hosts —
  without it, streamed responses report no usage at all.

## Common mistakes

- **Ignoring `finishReason`.** See above; this is the big one.
- **Summing usage across chunks.** Some providers send a running total on every
  chunk, so summing multiplies the bill by the chunk count. The builder replaces
  rather than accumulates.
- **Retrying a stream mid-flight.** Produces duplicated text that looks like a
  model defect.
- **Trusting a local model's advertised capabilities.**
- **Sending a turn with unanswered tool calls.** Check
  `history.pendingToolCalls` first; providers reject the request.
- **Putting a raw user identifier in `ChatRequest.user`.** Send a hash.

## Example

[`example/agentic_llm_example.dart`](example/agentic_llm_example.dart) runs
offline against a scripted model and demonstrates the middleware stack,
streaming, tool calling and cost accounting. Export `OPENAI_API_KEY` or
`ANTHROPIC_API_KEY` to point the same code at a real provider.

## Licence

MIT
