// Demonstrates the pieces of `agentic_core` an application actually touches:
// a run context, structured logging and tracing, the event bus, schema
// validation, and a retry that survives a flaky dependency.
//
// Run it with:
//
//     dart run example/agentic_core_example.dart
//
// Nothing here reaches the network. The "provider" is a function that fails
// twice and then succeeds, which is enough to show the machinery working.
import 'dart:async';

import 'package:agentic_core/agentic_core.dart';

/// Published when a step of the run finishes.
final class StepCompleted extends AgenticEvent {
  const StepCompleted({
    required super.id,
    required super.timestamp,
    required this.step,
    required this.detail,
    super.runId,
  });

  final String step;
  final String detail;

  @override
  String get type => 'example.step.completed';

  @override
  JsonMap payload() => <String, Object?>{'step': step, 'detail': detail};
}

Future<void> main() async {
  // ---------------------------------------------------------------------------
  // 1. A run context carries identity, logging, events, tracing, time and
  //    cancellation. Everything below receives it rather than reaching for a
  //    global, which is what makes all of it testable.
  // ---------------------------------------------------------------------------
  final events = BroadcastEventBus();
  final spans = InMemorySpanExporter();

  final context = AgenticContext.root(
    logger: StructuredLogger(level: LogLevel.debug),
    events: events,
    tracer: Tracer(exporter: spans),
    timeout: const Duration(seconds: 30),
    metadata: <String, Object?>{'example': 'agentic_core'},
  );

  context.logger.info(
    'Run started',
    fields: <String, Object?>{
      'runId': context.runId,
      // Credential-shaped fields are redacted before they reach any sink.
      'apiKey': 'sk-proj-not-a-real-key-1234',
    },
  );

  // A UI would subscribe here. Note that the bus replays recent events, so a
  // subscriber that arrives a frame late still sees everything.
  final subscription = events.on<StepCompleted>().listen(
    (event) => print('  event: ${event.step} -> ${event.detail}'),
  );

  // ---------------------------------------------------------------------------
  // 2. Schemas are the contract for tool arguments and structured output. They
  //    validate, and they repair the near-misses language models really emit.
  // ---------------------------------------------------------------------------
  final schema = JsonSchema.object(
    description: 'Search the web',
    properties: <String, JsonSchema>{
      'query': JsonSchema.string(
        description: 'What to search for',
        minLength: 1,
      ),
      'limit': JsonSchema.integer(minimum: 1, maximum: 50, defaultValue: 10),
    },
    required: <String>{'query'},
  );

  // A model sent the limit as a string and omitted nothing else. Coercion fixes
  // the unambiguous mistake instead of spending a round trip on it.
  final repaired = schema.coerce(<String, Object?>{
    'query': 'dart 3 records',
    'limit': '5',
  });
  print('coerced arguments : $repaired');
  print('valid             : ${schema.validate(repaired).isValid}');

  // A genuinely wrong argument reports every problem at once, phrased so the
  // text can be handed straight back to a model as a repair instruction.
  final invalid = schema.validate(<String, Object?>{'limit': 500});
  for (final violation in invalid.violations) {
    print('violation         : $violation');
  }

  context.publish(
    StepCompleted(
      id: context.ids.prefixed('evt'),
      timestamp: context.clock.now(),
      step: 'validate',
      detail: '${invalid.violations.length} violation(s)',
      runId: context.runId,
    ),
  );

  // ---------------------------------------------------------------------------
  // 3. A step opens a span and derives a scoped context. The retry policy is
  //    driven by the error's own `isRetryable`, never by parsing messages.
  // ---------------------------------------------------------------------------
  var attempts = 0;

  final answer = await context.step('provider.generate', (scope, span) async {
    span.setAttribute('provider', 'flaky-example');

    return const RetryPolicy(
      maxAttempts: 4,
      backoff: ExponentialBackoff(initial: Duration(milliseconds: 50)),
    ).execute(
      (attempt) async {
        attempts = attempt;
        scope.logger.debug('Calling provider', fields: {'attempt': attempt});

        if (attempt < 3) {
          // A 503 is transient, so the policy will back off and try again.
          throw ProviderException(
            'upstream temporarily unavailable',
            provider: 'flaky-example',
            statusCode: 503,
          );
        }
        return 'Records are a Dart 3 feature for grouping values.';
      },
      operation: 'provider.generate',
      cancellation: scope.cancellation,
      clock: scope.clock,
    );
  });

  print('answer            : $answer');
  print('attempts          : $attempts');

  // ---------------------------------------------------------------------------
  // 4. Messages are immutable and multimodal, and history knows things worth
  //    knowing — such as which tool calls have not been answered yet.
  // ---------------------------------------------------------------------------
  final history = <Message>[
    Message.system('You are a concise assistant.'),
    Message.user('What are Dart records?'),
    Message.assistant(
      answer,
      toolCalls: <ToolCallPart>[
        ToolCallPart(
          id: 'call_1',
          name: 'search_web',
          arguments: repaired! as JsonMap,
        ),
      ],
    ),
  ];

  print('history text      : ${history.last.text}');
  print('pending tool calls: ${history.pendingToolCalls.map((c) => c.name)}');

  // Usage is additive across every call in a run, whatever the provider.
  final usage = <TokenUsage>[
    const TokenUsage(
      promptTokens: 820,
      completionTokens: 90,
      cachedPromptTokens: 640,
    ),
    const TokenUsage(promptTokens: 120, completionTokens: 40),
  ].sum();
  print('tokens            : $usage');
  print(
    'cache hit rate    : ${(usage.cacheHitRate * 100).toStringAsFixed(1)}%',
  );

  // ---------------------------------------------------------------------------
  // 5. The trace is the record of what happened, and it survives the run.
  // ---------------------------------------------------------------------------
  for (final span in spans.spans) {
    print(
      'span              : ${span.name} '
      '(${span.duration.inMilliseconds}ms, ${span.status.name})',
    );
  }

  await subscription.cancel();
  await events.dispose();
  await spans.dispose();
}
