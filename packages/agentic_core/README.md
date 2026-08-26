# agentic_core

Foundation layer of the [agentic](https://github.com/v1j4yk/agentic_flutter)
framework: the vocabulary every other package speaks.

Pure Dart, two dependencies (`meta`, `collection`), no knowledge of any
provider, transport or UI framework. Everything here is either an immutable
value object or a port that adapters implement — which is what lets a Flutter
app, a server and a CLI share one domain model.

> Most applications should depend on `agentic_flutter`, which re-exports this
> along with the rest of the framework. Depend on `agentic_core` directly when
> you are writing a plugin: a tool, a provider or a store should not pull in a
> whole framework.

## Installation

```yaml
dependencies:
  agentic_core: ^0.1.0
```

## What is in here

| Area | Types |
|---|---|
| **Messaging** | `Message`, `MessageRole`, `ContentPart` (text, reasoning, image, file, audio, tool call, tool result), `TokenUsage` |
| **Schema** | `JsonSchema`, `SchemaValidationResult`, `SchemaViolation` |
| **Errors** | `AgenticException` and 18 concrete failures |
| **Cancellation** | `CancellationToken`, `CancellationTokenSource` |
| **Resilience** | `RetryPolicy`, `BackoffStrategy`, `Jitter`, `CircuitBreaker` |
| **Events** | `AgenticEvent`, `EventBus`, `BroadcastEventBus` |
| **Telemetry** | `AgenticLogger`, `StructuredLogger`, `Tracer`, `Span` |
| **Primitives** | `Ulid`, `Clock`, `Disposable`, `Result`, `Registry` |
| **Context** | `AgenticContext` |

---

## Messages are not strings

A modern LLM turn is a sequence of typed parts. Modelling it as `String` forces
every multimodal and tool-using feature to be bolted on later as a parallel
field, which is how wrappers end up with `content`, `imageUrl`, `toolCalls` and
`functionCall` all describing the same turn.

```dart
final message = Message.user(
  'What is in this photo?',
  parts: [ImagePart.bytes(jpegBytes, mimeType: 'image/jpeg')],
);

message.text;          // 'What is in this photo?' — text parts only
message.isMultimodal;  // true
message.hasToolCalls;  // false
```

`ContentPart` is `sealed`, which is the deliberate opposite of most extension
points here. Every provider adapter must translate every part; sealing means
adding a modality is a compile error in each adapter that has not handled it,
rather than a silent dropped image.

History is a plain `List<Message>` with extensions, so it works with
`ListView.builder` and everything else Dart already gives you:

```dart
history.takeRecent(20);      // trims, but never drops the system prompt
history.pendingToolCalls;    // calls with no result yet — a top cause of 400s
history.systemMessages;      // for providers with a dedicated system field
```

## Schemas that expect a language model

`JsonSchema` covers exactly the subset providers accept — no `$ref`, no remote
resolution, nothing that would add a network path to a mobile app for features
that cannot be used. In exchange it does the thing a general validator cannot:
repair the mistakes models actually make.

```dart
final schema = JsonSchema.object(
  properties: {
    'query': JsonSchema.string(description: 'What to search for'),
    'limit': JsonSchema.integer(minimum: 1, maximum: 50, defaultValue: 10),
  },
  required: {'query'},
);

// The model sent limit as a string. Repaired, not rejected — a wasted round
// trip for an unambiguous mistake is a bad trade.
schema.coerce({'query': 'x', 'limit': '5'});  // {'query': 'x', 'limit': 5}

// Ambiguity is never guessed. "yes" could mean anything.
JsonSchema.boolean().coerce('yes');           // 'yes' — left for validation
```

Validation reports **every** violation, phrased so the text can be handed
straight back to a model as a repair instruction:

```dart
schema.validate({'limit': 500}).violations;
// /query: Required property `query` is missing (What to search for).
// /limit: Expected a value <= 50, got 500.
```

`toStrict()` converts a naturally-written schema into the dialect required for
guaranteed structured output — closing objects and expressing optionality as
nullable types — so you do not write it twice.

## Errors that answer the only question retry logic asks

Every failure is an `AgenticException` with a stable `code` and an
`isRetryable` answer, so no retry policy ever pattern-matches on a provider's
error prose.

```dart
try {
  await model.generate(request);
} on AgenticException catch (error, stackTrace) {
  logger.error(error.message, error: error, stackTrace: stackTrace);
  if (error.isRetryable) scheduleRetry();
}
```

Retryability is derived, not asserted: a `ProviderException` with no status is
a transport failure and highly retryable; 5xx, 408, 409, 425 and 429 are
transient; 400 is not. `RateLimitException` is retryable and
`QuotaExceededException` is not — waiting fixes a throttle but never restores a
spent credit balance.

Errors also accumulate context as they unwind, first-writer-wins:

```dart
error.annotations;  // {retry.attempts: 3, retry.operation: openai.chat, ...}
```

The hierarchy is `base`, not `sealed`, so a third-party provider or store can
add its own failure type. That is a deliberate trade of exhaustive switching for
an open plugin ecosystem.

## Cancellation, because users close screens

An agent run can spend a minute in a tool loop. Without cancellation it keeps
burning tokens, battery and rate limit on a result nobody will read.

```dart
final source = CancellationTokenSource();
final answer = agent.run(prompt, cancellation: source.token);

// The user navigated away.
source.cancel('user navigated away');
```

Cancellation surfaces as `CancelledException` — never a silent early return,
which would be indistinguishable from success — and is never retryable. Binding
a stream tears down the subscription, which is what actually closes the socket
on a streaming completion:

```dart
token.bind(model.stream(request));  // ends with an error, not a quiet close
```

## Resilience tuned for real networks

```dart
const policy = RetryPolicy(
  maxAttempts: 4,
  backoff: ExponentialBackoff(initial: Duration(milliseconds: 200)),
  maxElapsed: Duration(seconds: 20),
);

await policy.execute(
  (attempt) => provider.send(request),
  operation: 'openai.chat.completions',
  cancellation: token,
);
```

Jitter is on by default. When an app loses connectivity for ten seconds, every
in-flight request fails at once; with a deterministic schedule they all retry at
the same instant and keep colliding — a self-inflicted thundering herd against
the provider that just throttled you.

The policy honours a provider's `Retry-After` when it is longer than the local
schedule, races its own sleep against cancellation, and checks the budget
*before* sleeping so it never waits into a deadline it already cannot meet.
`RetryPolicy.interactive` and `RetryPolicy.background` are tuned presets.

`CircuitBreaker` fails fast when a dependency is comprehensively down, which is
also what makes provider failover cheap:

```dart
try {
  return await breaker.execute(() => primary.generate(request));
} on CircuitOpenException {
  return await fallback.generate(request);  // fail over, do not wait
}
```

Its default counts everything *except* caller-side failures — notably not
cancellations, because a user closing a screen five times must not take a
provider offline for everybody.

## Observability that is free until you want it

```dart
final context = AgenticContext.root(
  logger: StructuredLogger(level: LogLevel.debug),
  events: BroadcastEventBus(),
  tracer: Tracer(exporter: InMemorySpanExporter()),
  timeout: const Duration(minutes: 2),
);

final answer = await context.step('llm.generate', (scope, span) async {
  span.setAttribute('llm.model', 'gpt-4o');
  return model.generate(request, context: scope);
});
```

Defaults are inert — `NoopLogger`, `NoopEventBus`, a non-exporting `Tracer` — so
a library using the framework produces no output unless the host application
asked for it.

Credential-shaped log fields are redacted by default:

```dart
logger.info('configured', fields: {'apiKey': 'sk-proj-1234567890abcdef'});
// apiKey=sk-p***24
```

The event bus replays recent events to late subscribers, which is what fixes
the classic "the first token is always missing" bug when a Flutter widget
subscribes a frame after the run started.

## Testability ships in the box

```dart
import 'package:agentic_core/testing.dart';

final clock = FakeClock(autoAdvance: true);

await policy.execute(failingAction, operation: 'x', clock: clock);

// Not "it eventually failed" — the exact schedule.
expect(clock.requestedDelays, [
  Duration(milliseconds: 100),
  Duration(milliseconds: 200),
]);
```

`testing.dart` also exports `SequentialIdGenerator`, `InMemoryLogSink` and
`InMemorySpanExporter`. They live in the published package, not just in its own
test folder, so plugin authors test against the same doubles the framework does.

## Performance notes

- **`isEnabled` before expensive logs.** Disabled levels short-circuit before
  any field map is allocated: `if (logger.isEnabled(LogLevel.debug)) …`.
- **Tracing costs nothing when unsampled.** A sampled-out span discards its
  export and children inherit the decision, so a trace is never half-recorded.
- **Cancellation tokens are cheap to poll.** `isCancelled` is one field read;
  the completer behind `whenCancelled` is allocated lazily.
- **`Ulid` is web-safe.** Encoding uses `~/` and `%`, not bit shifts, because
  Flutter Web truncates bitwise operations to 32 bits and would silently corrupt
  a 48-bit timestamp.
- **Prefer URIs to inline bytes on mobile.** A 4 MB photo inlined as base64
  becomes a 5.3 MB request body.

## Common mistakes

- **Sending a turn with unanswered tool calls.** Check
  `history.pendingToolCalls` before you send; providers reject the request.
- **Varying the system prompt per request.** It defeats provider prompt caching,
  usually the largest single cost saving available. Watch
  `TokenUsage.cacheHitRate` to see whether caching is working.
- **Swallowing `CancelledException` in a tool.** It must propagate, or a
  cancelled run looks like a completed one.
- **Treating `isRetryable` as "should retry".** It answers "is this transient?".
  Idempotency and budget are the policy's decisions, not the error's.
- **Retrying a whole `DisposableBag` teardown on failure.** Disposal already
  continues past a failure and reports them together; do not wrap it in a retry.

## Documentation

Every public member carries documentation with rationale, and the analyzer
enforces it. See the [architecture notes](https://github.com/v1j4yk/agentic_flutter/blob/main/doc/architecture.md)
for how this layer relates to the rest of the framework.

## Licence

MIT
