---
name: agentic-otel-export-traces
description: >-
  Use when agent traces must leave the process with agentic_otel: wiring
  OtlpHttpSpanExporter and BatchSpanExporter to a Tracer, pointing them at
  Langfuse, Phoenix, Grafana, Honeycomb or a local collector, the GenAI
  semantic-convention attributes a backend needs to render an LLM span, and why
  prompts are not exported. Read this for "send traces to my observability
  backend" or "why is my trace view empty".
license: MIT
metadata:
  package: agentic_otel
  min-version: 0.2.0
---

# Exporting traces

## Wiring it

```dart
import 'package:agentic_core/agentic_core.dart';
import 'package:agentic_otel/agentic_otel.dart';

final exporter = BatchSpanExporter(
  OtlpHttpSpanExporter(
    endpoint: Uri.parse('https://collector.example.com/v1/traces'),
    headers: {'authorization': 'Bearer $token'},
    resource: const OtlpResource(
      serviceName: 'pocket_agent',
      serviceVersion: '1.2.0',
      deploymentEnvironment: 'production',
    ),
    onError: (error, stack) => log.warning('trace export failed: $error'),
  ),
);

final tracer = Tracer(exporter: exporter, sampler: (name) => true);
final context = AgenticContext.root(tracer: tracer);
```

In Flutter: `AgenticRuntime(tracer: tracer)`, once, at app start.

`endpoint` is the **full traces URL**, not the collector root — every collector
exposes `/v1/traces`, and pointing at the root is a 404 that reads like a
network problem.

## Set the service name

`OtlpResource(serviceName: …)` is the one field worth deciding. Every span from
every deployment arriving as `unknown_service` is the usual reason a trace view
is unusable. Add `deploymentEnvironment` so your laptop's traces are not mixed
with production's.

## Batch, especially on a phone

One request per span means one TLS handshake per span, on the same radio the
model call is using.

```dart
BatchSpanExporter(inner, maxBatch: 128, maxQueue: 2048,
    flushEvery: const Duration(seconds: 5));
```

- When the queue is full the **oldest** spans are dropped — in a backlog of
  stale telemetry the recent ones are worth keeping — and `exporter.dropped`
  says how many, so the gap is visible.
- A rejected batch is dropped rather than retried forever; retrying into a
  collector that is down turns one problem into an unbounded queue.
- **Flush when the app is backgrounded**, or the last spans of a run — the
  interesting ones — are lost:

```dart
if (state == AppLifecycleState.paused) unawaited(exporter.flush());
```

`dispose()` flushes what is left, and counts anything the collector refuses.

## Make a backend recognise an LLM span

A backend renders model calls specially only when it sees the OpenTelemetry
GenAI attribute names. The same numbers under `llm.tokens` are a generic span.

```dart
await context.step('chat', (child, span) async {
  final response = await model.generate(request, context: child);
  span.setAttributes(genAiChatAttributes(
    provider: model.info.provider,
    requestModel: model.info.id,
    responseModel: response.modelId,
    responseId: response.requestId,
    inputTokens: response.usage.promptTokens,
    outputTokens: response.usage.completionTokens,
    finishReason: response.finishReason.name,
  ));
  return response;
});
```

`genAiToolAttributes(toolName:, callId:)` and
`genAiAgentAttributes(agentName:, conversationId:)` do the same for tool and
agent spans. `GenAiAttributes` holds the raw keys when you need one directly.

## Prompts and completions are not exported

Deliberately. Message content is the most sensitive thing this framework
touches, and a backend that shows it to everyone with a dashboard login is a
decision an application makes, not a default that ships.

If you do want it, attach it yourself, after deciding what redaction applies —
and remember that `redactSensitiveFields` in `agentic_core` only knows
conventional key names, not the contents of a user's message.

## Failures never reach the application

A rejected export, a timeout, a collector that is not running: all are reported
through `onError` and dropped. Nothing is thrown into the code that produced the
span, because telemetry that breaks a run is worse than no telemetry. If traces
are missing, `onError` is the first place to look — not the agent.

## Joining a trace that started elsewhere

```dart
final incoming = TraceContext.fromHeaders(request.headers);
final context = AgenticContext.root(traceContext: incoming, tracer: tracer);
```

The HTTP transports in `agentic_llm` and `agentic_mcp` send `traceparent`
onward, so app → backend → MCP server is one trace rather than three.

## Common mistakes

- Pointing at the collector root instead of `/v1/traces`.
- No `sampler`, then wondering why nothing arrives: `Tracer` records nothing by
  default.
- Using the unbatched exporter on a device, and paying a round trip per span.
- Never flushing on background, so the end of every run is missing.
- Leaving `serviceName` at its default and getting one undifferentiated pile.
- Attaching whole prompts "temporarily" to debug something, and shipping it.

## See also

- `agentic-core-tracing-and-events` — spans, events and logs inside the process
- `agentic-flutter-trace-panel` — the in-app view, for development
