---
name: agentic-core-errors-and-retry
description: >-
  Use when handling failures in a Dart or Flutter project built on the agentic
  framework: catching AgenticException and its subtypes, deciding what is worth
  retrying, configuring RetryPolicy and backoff, using CircuitBreaker, or
  choosing between throwing and returning Result. Covers what isRetryable
  means, why parsing provider error strings is the wrong move, and which
  exception each failure maps to.
license: MIT
metadata:
  package: agentic_core
  min-version: 0.2.0
---

# Errors, retries and circuit breaking

## Every failure is typed, coded and classified

Catch `AgenticException` — or a subtype — never a bare `Exception`:

```dart
try {
  final answer = await agent.ask('What changed in Dart 3.11?');
} on RateLimitException catch (error) {
  // isRetryable is the framework's answer, not yours to infer from a message.
  showSnack('Busy. Retrying in ${error.retryAfter ?? const Duration(seconds: 5)}.');
} on AuthenticationException {
  showKeyScreen();
} on AgenticException catch (error) {
  log.error('${error.code}: ${error.message}', error: error);
}
```

The subtypes you will actually meet:

| Exception | Means | Retryable |
|---|---|---|
| `RateLimitException` | 429, with `retryAfter` when the provider sent one | yes |
| `QuotaExceededException` | the account is out of credit | **no** |
| `AuthenticationException` | bad or missing key | **no** |
| `ProviderException` | 5xx, transport failure, malformed answer | usually |
| `ValidationException` | arguments did not match a schema | **no** |
| `ToolExecutionException` | a tool failed in a way it could not return | depends |
| `CapabilityNotSupportedException` | the model cannot do what was asked | **no** |
| `CancelledException` | a caller cancelled, or a deadline passed | **no** |
| `AgenticTimeoutException` | an operation exceeded its budget | yes |
| `CircuitOpenException` | a breaker is open and refusing calls | later |

**Never branch on message text.** `error.isRetryable` and `error.code` are the
contract; a message is for a human. Provider wording changes without notice,
which is how an outage becomes an incident.

## Retrying

`RetryPolicy` is a value, and three are ready-made:

```dart
RetryPolicy.interactive;   // few attempts, short waits — someone is watching
RetryPolicy.background;    // more attempts, longer waits — nobody is
RetryPolicy.none;          // fail on the first error
```

Use one directly for your own calls:

```dart
final report = await RetryPolicy.background.execute(
  (attempt) => api.fetchReport(id),
  operation: 'fetch_report',       // named in logs and in the timeout message
  cancellation: context.cancellation,
  clock: context.clock,            // injected, so tests do not really sleep
);
```

Or wrap a model, which is the usual case:

```dart
final model = RetryingChatModel(inner, policy: RetryPolicy.interactive);
```

Customise when the defaults do not fit:

```dart
const RetryPolicy(
  maxAttempts: 5,
  backoff: ExponentialBackoff(),   // or LinearBackoff, ConstantBackoff, FixedScheduleBackoff
  maxElapsed: Duration(minutes: 2),
  respectRetryAfter: true,         // a provider's Retry-After wins over the backoff
);
```

Only failures whose `isRetryable` is true are retried. Add `retryIf` to narrow
that further; do not use it to widen it.

## Circuit breaking

Retrying a provider that is down wastes the user's battery and your money.

```dart
final breaker = CircuitBreaker(
  name: 'openai',
  failureThreshold: 5,     // consecutive failures before it opens
  successThreshold: 2,     // successes in half-open before it closes
  resetTimeout: const Duration(seconds: 30),
);

final response = await breaker.execute(() => model.generate(request));
// While open: CircuitOpenException immediately, no call made.
```

`FallbackChatModel` already contains one per model, so a dead provider is
skipped rather than retried on every turn.

## Exceptions or `Result`

The framework throws, because that is Dart's asynchronous idiom and `Result`
everywhere would mean `switch (await x)` at every call site. `Result` is the
opt-in for fan-out, batches and isolate boundaries, where a failure is data:

```dart
final results = await Future.wait(ids.map((id) => Result.guardAsync(() => fetch(id))));
final (values, failures) = Result.partition(results);
```

## Writing your own failure

`AgenticException` is `base`: extend it, never implement it, so members can be
added in a minor release.

```dart
final class PaymentDeclinedException extends AgenticException {
  PaymentDeclinedException(super.message, {super.details});

  @override
  String get code => 'payment_declined';

  @override
  bool get isRetryable => false;   // a declined card does not improve on retry
}
```

Annotate rather than re-wrap when you catch and rethrow, so the original stack
survives:

```dart
} on AgenticException catch (error) {
  error.annotate('orderId', id);
  rethrow;
}
```

## Common mistakes

- `catch (e)` with no type, which swallows `CancelledException` and turns a
  cancelled run into a fake failure.
- Retrying a `ValidationException` or `AuthenticationException` — neither is
  going to succeed on attempt two.
- Using a real `Duration` delay in tests instead of passing the injected
  `Clock`, which makes a retry test take minutes.
- Building retry logic around a `try`/`catch` loop instead of `RetryPolicy`,
  losing `Retry-After`, jitter and cancellation.

## See also

- `agentic-core-cancellation-and-context` — deadlines and cooperative cancellation
- `agentic-core-tracing-and-events` — seeing the retries you configured
- `agentic-llm-middleware-retry-fallback-cache` — the decorators that wrap a model
