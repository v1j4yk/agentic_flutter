---
name: agentic-core-tracing-and-events
description: >-
  Use when working out what an agent actually did, or adding observability to a
  Dart or Flutter project on the agentic framework: the typed event bus,
  structured logging with redaction, spans and traces, and writing your own
  event type. Covers which of the three to reach for, how to record events in a
  test, and why everything is inert until you opt in.
license: MIT
metadata:
  package: agentic_core
  min-version: 0.2.0
---

# Events, logs and traces

## Three channels, three jobs

| You want | Use | Shape |
|---|---|---|
| To react in code or draw a UI | `EventBus` | typed objects |
| A record a person reads later | `AgenticLogger` | levelled, structured |
| Timing and causality across a run | `Tracer` / `Span` | OpenTelemetry-shaped |

All three are inert by default — a `NoopEventBus`, a `NoopLogger`, a tracer
with no exporter — and cost nothing until configured. They travel on
`AgenticContext`, so anything that has the context can use them.

## Events

Everything the framework does publishes one: `LlmRequestStarted`,
`LlmResponseCompleted`, `ToolCallStarted`, `ToolApprovalRequested`,
`AgentRunCompleted`, `AgentBudgetExhausted`, `MemoriesRecalled`,
`ChunksRetrieved`, `McpToolCalled`, and more.

```dart
final bus = BroadcastEventBus(replayBufferSize: 64);
final context = AgenticContext.root(events: bus);

// Typed: only the events you asked for.
bus.on<AgentRunCompleted>().listen((event) {
  analytics.record(steps: event.iterations, cost: event.cost);
});

// Or everything, which is what a debug panel wants.
bus.events.listen((event) => print('${event.type}  ${event.payload()}'));
```

`replayBufferSize` matters in an app: a widget that subscribes after a run
starts still sees what it missed. `bus.droppedCount` tells you when a slow
listener is losing events.

Publish your own:

```dart
final class OrderPlaced extends AgenticEvent {
  const OrderPlaced({
    required super.id,
    required super.timestamp,
    required this.orderId,
    super.runId,
  });

  final String orderId;

  @override
  String get type => 'order.placed';

  @override
  Map<String, Object?> payload() => <String, Object?>{'orderId': orderId};
}

context.publish(OrderPlaced(
  id: context.ids.next(),
  timestamp: context.clock.now(),
  orderId: order.id,
  runId: context.runId,
));
```

`AgenticEvent` is `base`: extend it, do not implement it. `GenericEvent` exists
for one-off events not worth a class.

## Logging

```dart
final logger = StructuredLogger(
  name: 'app',
  level: LogLevel.info,
  sink: MultiLogSink([ConsoleLogSink(asJson: true), myRemoteSink]),
);
final context = AgenticContext.root(logger: logger);

context.logger.info('indexing finished', fields: {'documents': 42});
context.logger.error('indexing failed', error: error, stackTrace: stack);
```

Bind fields once instead of repeating them:
`logger.child('indexer', fields: {'corpus': 'handbook'})`.

**Redaction is on by default.** `redactSensitiveFields` masks anything whose key
looks like a secret — `apiKey`, `authorization`, `password`, `token`. Keep keys
conventional and secrets stay out of logs; invent `myK3y` and they will not.

## Tracing

```dart
final exporter = InMemorySpanExporter();
final tracer = Tracer(exporter: exporter, sampler: (name) => true);
final context = AgenticContext.root(tracer: tracer);

final answer = await context.step('answer_question', (child, span) async {
  span.setAttribute('question.length', question.length);
  final passages = await retriever.retrieve(question, context: child);
  span.addEvent('retrieved', attributes: {'count': passages.length});
  return pipeline.answer(question, context: child);
});

for (final span in exporter.spans) {
  print('${span.name} ${span.duration}');
}
```

`context.step` is the everyday form: it starts a span, makes a child context,
records an error and sets the status if the body throws, and always ends the
span. Use `tracer.trace` or `tracer.startSpan` directly only outside a context.

Spans are OpenTelemetry-shaped — trace id, span id, parent, kind, attributes,
events, status — so an exporter to a real backend is a small class implementing
`SpanExporter`.

## In tests

```dart
final bus = BroadcastEventBus();
final logs = InMemoryLogSink();
final spans = InMemorySpanExporter();
final context = AgenticContext.root(
  events: bus,
  logger: StructuredLogger(sink: logs, level: LogLevel.debug),
  tracer: Tracer(exporter: spans),
  clock: fixedClock,
  ids: SequentialIdGenerator(),
);

await agent.run(AgentInput.text('hello'), context: context);

expect(spans.named('llm.generate'), hasLength(1));
expect(logs.at(LogLevel.error), isEmpty);
```

Asserting on events is usually better than asserting on text: an event is a
contract, a message is prose.

## Common mistakes

- Subscribing to `bus.events` in a widget and never cancelling — a leak with a
  debug panel attached. In Flutter use `EventRecorder`, which is bounded.
- Logging the whole prompt at `info`. It is large, it is often personal, and
  redaction does not know it is a secret.
- Creating a `Tracer` with no exporter and expecting spans anywhere; nothing
  leaves the process until one is set.
- Using `DateTime.now()` in an event instead of `context.clock.now()`, which
  makes ordering untestable.

## See also

- `agentic-core-cancellation-and-context` — what else the context carries
- `agentic-core-errors-and-retry` — the failures worth logging
- `agentic-flutter-trace-panel` — the in-app inspector over this bus
