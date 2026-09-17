# Changelog

## 0.2.0

- `JsonSchema.coerce` treats `null` for an optional, non-nullable property as
  not given, applying the default if there is one. Models send `null` for
  parameters they skip, and `ToolExecutor` used to reject those calls. `null`
  for a required property is still rejected.

- `UntrustedContentLedger` on `AgenticContext.untrustedContent`: which tools
  brought text into a run that the application did not write. Shared by every
  scope in a run, and impossible to clear.

## 0.1.1

- Shortened the package description to the 60-180 character window pana
  scores against. Search engines truncate anything longer, so the ten points
  it withheld were pointing at a real defect: the useful half of the sentence
  was never being shown.

## 0.1.0

Initial release of the foundation layer.

### Added

- **Messaging** — `Message`, `MessageRole` and a sealed `ContentPart` hierarchy
  covering text, reasoning, images, files, audio, tool calls and tool results.
  `ConversationHistory` extensions for trimming and for finding unanswered tool
  calls. `TokenUsage` with cache and reasoning accounting, and addition.
- **Schema** — `JsonSchema`, an immutable validating subset of JSON Schema
  matched to what LLM providers actually accept, with full-violation reporting,
  `coerce` for the near-misses models really produce, and `toStrict()` for
  guaranteed structured output.
- **Errors** — `AgenticException` and eighteen concrete failures, each with a
  stable code, an `isRetryable` answer and JSON serialisation. Errors accumulate
  `annotations` as they propagate.
- **Cancellation** — `CancellationToken`/`CancellationTokenSource` with
  callbacks, future racing, stream binding that closes the underlying socket,
  token merging and clock-driven deadlines.
- **Resilience** — `RetryPolicy` with budgets and `Retry-After` support;
  `ExponentialBackoff`, `LinearBackoff`, `ConstantBackoff` and
  `FixedScheduleBackoff` with four jitter modes; `CircuitBreaker` with a
  half-open probe phase.
- **Events** — `AgenticEvent` and `BroadcastEventBus` with bounded replay for
  late subscribers, typed `on<T>()` filtering and run-scoped selection.
- **Telemetry** — `StructuredLogger` with bound fields, child scopes and
  credential redaction by default; `Tracer` with spans, events, sampling and
  pluggable exporters.
- **Primitives** — web-safe monotonic `Ulid`, injectable `Clock`, `Disposable`
  and `DisposableBag`, checked JSON accessors, `Result`, typed `Registry`.
- **Context** — `AgenticContext` bundling run identity, logger, bus, tracer,
  clock, IDs, cancellation and deadlines, with scoped derivation.
- **Testing** — `package:agentic_core/testing.dart` exports `FakeClock`,
  `SequentialIdGenerator`, `InMemoryLogSink` and `InMemorySpanExporter`.
