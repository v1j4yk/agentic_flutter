# agentic_otel

OpenTelemetry export for the [agentic framework](https://github.com/v1j4yk/agentic_flutter).
Agent, model and tool spans, sent over OTLP to any backend that speaks it.

```yaml
dependencies:
  agentic_otel: ^0.2.0
```

## Why

The framework's tracing is OpenTelemetry-shaped, and until something exports it,
it stays inside the process. That is fine while you are looking at a debug panel
on your own device, and useless the moment a user reports that "it was slow
yesterday".

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

final context = AgenticContext.root(
  tracer: Tracer(exporter: exporter, sampler: (name) => true),
);
```

Every agent run, model call and tool execution beneath that context now arrives
at your collector. Anything that reads OTLP works: Langfuse, Arize Phoenix,
Grafana Tempo, Honeycomb, Datadog, Google Cloud Trace, or a local
`otel-collector` in Docker.

## Batching, because this runs on a phone

`BatchSpanExporter` buffers spans and sends one request instead of one per span.
On a device that is the difference between one TLS handshake and thirty, on the
same radio the model call is using.

```dart
BatchSpanExporter(
  inner,
  maxBatch: 128,                              // send when this many are waiting
  maxQueue: 2048,                             // then drop the oldest
  flushEvery: const Duration(seconds: 5),     // and send a partial batch anyway
);
```

Two behaviours worth knowing:

- **The oldest spans are dropped when the queue is full**, not the newest. In a
  backlog of stale telemetry the recent spans are the ones worth keeping.
  `exporter.dropped` says how many went, so the gap is visible.
- **A rejected batch is dropped rather than retried forever.** Retrying into a
  collector that is down turns one problem into an unbounded queue; the failure
  has already been reported through `onError`.

On Flutter, flush when the app is backgrounded — that is when the last spans of
a run would otherwise be lost:

```dart
// In a WidgetsBindingObserver:
if (state == AppLifecycleState.paused) unawaited(exporter.flush());
```

`dispose()` flushes what is left.

## Failures never reach your application

Telemetry that breaks a run is worse than no telemetry. A rejected export, a
timeout, a collector that is not running — all are reported through `onError`
and dropped. Nothing is thrown into the code that produced the span.

## Naming spans so a backend understands them

A tracing backend renders an LLM span specially — model, tokens, cost — only
when it recognises the attribute names. `GenAiAttributes` holds the
OpenTelemetry GenAI convention keys, and three helpers build the usual sets:

```dart
await context.step('chat', (child, span) async {
  span.setAttributes(genAiChatAttributes(
    provider: 'anthropic',
    requestModel: AnthropicModels.sonnet,
    inputTokens: response.usage.promptTokens,
    outputTokens: response.usage.completionTokens,
    finishReason: response.finishReason.name,
  ));
  return response;
});

genAiToolAttributes(toolName: 'issue_refund', callId: call.id);
genAiAgentAttributes(agentName: 'support', conversationId: session.id);
```

The conventions are still marked Development upstream, so they move. They live
in one file here for that reason.

## What this package does not do

**It does not send prompts or completions.** Message content is the most
sensitive thing the framework touches, and a backend that shows it to everyone
with a dashboard login is a decision an application makes deliberately. The
attribute keys are there; attaching content is a line you write, after deciding
what redaction applies.

**It does not export metrics or logs.** Spans carry the timings, the token
counts and the failures, which is what a trace view needs.

**It does not start a trace for you.** `Tracer` does that. This package is the
exporter, so an application that already has its own transport can use
`encodeSpans` and post the JSON itself.

## Joining a trace that started elsewhere

`agentic_core` reads and writes W3C trace-context headers, and the HTTP
transports send them, so a Flutter app calling your backend calling an MCP
server is one trace rather than three:

```dart
final incoming = TraceContext.fromHeaders(request.headers);
final context = AgenticContext.root(traceContext: incoming, tracer: tracer);
```

## Licence

MIT.
