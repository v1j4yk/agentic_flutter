---
name: agentic-llm-middleware-retry-fallback-cache
description: >-
  Use when adding cross-cutting behaviour around a model in agentic_llm:
  RetryingChatModel, FallbackChatModel, CachingChatModel, ObservableChatModel,
  SwitchableChatModel and writing your own decorator with DelegatingChatModel.
  Covers the order to compose them in and why it matters. Read this for
  "retry on 429", "fail over to another provider", or "stop paying for the same
  answer twice".
license: MIT
metadata:
  package: agentic_llm
  min-version: 0.2.0
---

# Model middleware, as decorators

There is no pipeline to configure. Each decorator is a `ChatModel` wrapping a
`ChatModel`, so composition is a constructor call and the order is visible at
the call site.

```dart
final model = ObservableChatModel(        // logs, traces, publishes events
  RetryingChatModel(                      // retries transient failures
    CachingChatModel(                     // serves repeats from cache
      FallbackChatModel([gpt, claude, local]),  // routes around a dead provider
      cache: InMemoryChatCache(),
    ),
    policy: RetryPolicy.interactive,
  ),
);
```

Read it outside-in: observe everything, retry what fails, serve from cache where
possible, fail over underneath.

## Order matters

- **Cache inside retry**, not outside: outside, a failed first attempt is what
  gets cached, and the retry never happens.
- **Observability outermost**, or your dashboard shows one call where three
  happened, and the retries you are paying for are invisible.
- **Fallback innermost**, so a retry re-enters the chooser and can land on a
  different provider rather than hammering the dead one.

## What each one does

```dart
RetryingChatModel(inner, policy: RetryPolicy.interactive);
```
Retries only failures whose `isRetryable` is true, honouring `Retry-After`. A
stream is retried **only before the first chunk**: once a token has reached the
caller the answer cannot be restarted without duplicating text.

```dart
FallbackChatModel(
  [primary, secondary, local],
  failureThreshold: 3,
  resetTimeout: const Duration(seconds: 30),
);
```
Tries each in order, skipping any whose circuit is open, and publishes
`LlmFailoverOccurred` when it moves on. `info` reports the first model's, so put
the one whose capabilities you rely on first.

```dart
CachingChatModel(inner, cache: InMemoryChatCache(maxEntries: 100, ttl: Duration(hours: 1)));
```
Keyed on `ChatRequest.cacheKey`. By default only deterministic requests are
cached — `defaultShouldCache` skips anything with tools or a temperature that
makes the answer vary. Pass `shouldCache:` to change that, and implement
`ChatCache` for a persistent one.

```dart
ObservableChatModel(inner, logPrompts: false);
```
Emits `LlmRequestStarted`, `LlmFirstTokenReceived`, `LlmResponseCompleted` and
`LlmRequestFailed`, and opens a span. `logPrompts` is off by default because
prompts are large and often personal.

```dart
SwitchableChatModel(initial);   // change model at run time; see agentic-llm-choose-provider
```

## Writing your own

```dart
final class HouseStyleChatModel extends DelegatingChatModel {
  const HouseStyleChatModel(super.inner, {required this.style});

  final String style;

  @override
  Future<ChatResponse> generate(ChatRequest request, {AgenticContext? context}) {
    return super.generate(
      request.copyWith(
        messages: [Message.system(style), ...request.messages],
      ),
      context: context,
    );
  }
}
```

`DelegatingChatModel` forwards `info`, `stream` and `dispose`, so override only
what you change. A decorator of your own is indistinguishable from the shipped
ones, which is the point of the design.

Useful hooks on the request: `copyWith`, `withMessages`, `providerOptions` for
provider-specific fields, and `metadata`, which travels through to the response
untouched.

## Disposal

Decorators forward `dispose`, so disposing the outermost disposes the chain —
which closes the HTTP clients. Where an agent owns the model, pass
`ownsModel: true` and let the agent do it; otherwise dispose it yourself when
the screen or process ends.

## Common mistakes

- Wrapping in the wrong order and then wondering why nothing is cached or why
  the dashboard under-counts.
- Retrying a `ValidationException` or `AuthenticationException` by widening
  `retryIf` — neither improves on a second attempt.
- Caching requests that carry tools, so the agent gets a stale tool call.
- Building a "middleware pipeline" abstraction on top of this. Composition is
  already a constructor call.
- Forgetting that `FallbackChatModel.info` is the first model's, then asking for
  a capability only the second one has.

## See also

- `agentic-core-errors-and-retry` — retry policies and circuit breakers
- `agentic-llm-choose-provider` — the adapters being wrapped
- `agentic-core-tracing-and-events` — what ObservableChatModel emits
