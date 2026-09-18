// Exporting a run's spans to a collector.
//
//   dart run example/agentic_otel_example.dart
//
// It posts to localhost:4318, the OTLP HTTP port every collector uses. With
// nothing listening the export fails, is reported through `onError`, and the
// run finishes anyway — which is the behaviour worth demonstrating.
import 'package:agentic_core/agentic_core.dart';
import 'package:agentic_otel/agentic_otel.dart';

Future<void> main() async {
  final exporter = BatchSpanExporter(
    OtlpHttpSpanExporter(
      endpoint: Uri.parse('http://localhost:4318/v1/traces'),
      resource: const OtlpResource(
        serviceName: 'agentic_otel_example',
        deploymentEnvironment: 'local',
      ),
      onError: (error, _) => print('export failed (expected here): $error'),
    ),
    // Small, so the example sends something without waiting five seconds.
    maxBatch: 4,
    flushEvery: Duration.zero,
  );

  final context = AgenticContext.root(
    tracer: Tracer(exporter: exporter),
    logger: StructuredLogger(sink: const ConsoleLogSink()),
  );

  // A run, shaped the way the framework shapes one: an agent span with a model
  // call and a tool call beneath it.
  await context.step('agent.run', (runContext, span) async {
    span.setAttributes(
      genAiAgentAttributes(agentName: 'support', conversationId: 'session-1'),
    );

    await runContext.step('chat', (_, chat) async {
      chat
        ..setAttributes(
          genAiChatAttributes(
            provider: 'anthropic',
            requestModel: 'claude-sonnet-5',
            inputTokens: 1200,
            outputTokens: 180,
            finishReason: 'tool_calls',
          ),
        )
        ..addEvent('first_token', attributes: {'latency_ms': 320});
    });

    await runContext.step('execute_tool', (_, tool) async {
      tool.setAttributes(
        genAiToolAttributes(toolName: 'lookup_order', callId: 'call_1'),
      );
    });
  });

  print('pending before flush: ${exporter.pending}');
  await exporter.dispose(); // flushes
  print('dropped: ${exporter.dropped}');
}
