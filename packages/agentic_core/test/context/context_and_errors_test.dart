import 'package:agentic_core/agentic_core.dart';
import 'package:agentic_core/testing.dart';
import 'package:test/test.dart';

void main() {
  group('AgenticException', () {
    test('infers retryability from an HTTP status', () {
      bool retryable(int status) => ProviderException(
        'x',
        provider: 'test',
        statusCode: status,
      ).isRetryable;

      expect(retryable(500), isTrue);
      expect(retryable(503), isTrue);
      expect(retryable(429), isTrue);
      expect(retryable(408), isTrue);
      expect(retryable(400), isFalse);
      expect(retryable(404), isFalse);
    });

    test('treats a missing status as a transport failure', () {
      // No response at all means the request never landed — the most retryable
      // failure there is.
      expect(
        ProviderException('socket closed', provider: 'test').isRetryable,
        isTrue,
      );
    });

    test('an explicit retryable flag overrides the inference', () {
      expect(
        ProviderException(
          'x',
          provider: 'test',
          statusCode: 400,
          retryable: true,
        ).isRetryable,
        isTrue,
      );
    });

    test('separates throttling from an exhausted quota', () {
      // Waiting fixes a rate limit; it never restores a spent credit balance.
      expect(RateLimitException('x', provider: 't').isRetryable, isTrue);
      expect(QuotaExceededException('x', provider: 't').isRetryable, isFalse);
    });

    test('cancellation is never retryable', () {
      expect(CancelledException('stopped').isRetryable, isFalse);
    });

    test('tool failures default to non-retryable', () {
      // Replaying an unknown side effect is the more dangerous mistake.
      expect(ToolExecutionException('x', toolName: 't').isRetryable, isFalse);
      expect(
        ToolExecutionException('x', toolName: 't', retryable: true).isRetryable,
        isTrue,
      );
    });

    test('details are unmodifiable', () {
      final error = ConfigurationException('x', details: {'a': 1});

      expect(() => error.details['b'] = 2, throwsUnsupportedError);
    });

    test('annotations accumulate with first-writer-wins', () {
      final error = ProviderException('x', provider: 'test')
        ..annotate('step', 'inner')
        ..annotate('step', 'outer')
        ..annotateAll({'node': 'n1', 'agent': 'researcher'});

      expect(error.annotations['step'], 'inner');
      expect(error.annotations['node'], 'n1');
      expect(error.toString(), contains('agent=researcher'));
    });

    test('serialises for a log aggregator', () {
      final error = ProviderException(
        'upstream failed',
        provider: 'openai',
        statusCode: 503,
        requestId: 'req-1',
        cause: StateError('socket'),
      );

      final json = error.toJson();
      expect(json['code'], 'provider_error');
      expect(json['retryable'], isTrue);
      expect(json['provider'], 'openai');
      expect(json['requestId'], 'req-1');
      expect(json['cause'], contains('socket'));
    });

    test('ValidationException lists every violation', () {
      final error = ValidationException('bad', violations: ['/a: x', '/b: y']);

      expect(error.violations, hasLength(2));
      expect(error.toString(), contains('/a: x'));
      expect(() => error.violations.add('z'), throwsUnsupportedError);
    });
  });

  group('Result', () {
    test('guard captures a framework error', () {
      final result = Result.guard<int>(() => throw ValidationException('bad'));

      expect(result.isErr, isTrue);
      expect(result.errorOrNull, isA<ValidationException>());
    });

    test('guard wraps a foreign error so Err is always well typed', () {
      final result = Result.guard<int>(() => throw StateError('boom'));

      expect(result.errorOrNull, isA<UnexpectedException>());
      expect(result.errorOrNull!.cause, isA<StateError>());
    });

    test('guardAsync never completes with an error', () async {
      final result = await Result.guardAsync<int>(
        () async => throw ValidationException('bad'),
      );

      expect(result.isErr, isTrue);
    });

    test('is exhaustively switchable', () {
      const Result<int> ok = Ok(1);

      final label = switch (ok) {
        Ok(:final value) => 'ok:$value',
        Err(:final error) => 'err:${error.code}',
      };

      expect(label, 'ok:1');
    });

    test('map leaves errors untouched', () {
      final Result<int> failed = Err(ValidationException('bad'));

      expect(failed.map((v) => v * 2).isErr, isTrue);
      expect(const Ok(2).map((v) => v * 2).valueOrNull, 4);
    });

    test('flatMap chains fallible computations', () {
      final result = const Ok(2).flatMap<int>((v) => Ok(v + 1));

      expect(result.valueOrNull, 3);
    });

    test('mapError re-describes a failure for the layer above', () {
      final Result<int> failed = Err(ValidationException('bad'));

      final mapped = failed.mapError(
        (e) => ConfigurationException('wrapped: ${e.message}'),
      );

      expect(mapped.errorOrNull, isA<ConfigurationException>());
    });

    test('unwrap throws the captured error', () {
      final Result<int> failed = Err(ValidationException('bad'));

      expect(failed.unwrap, throwsA(isA<ValidationException>()));
      expect(failed.unwrapOr(7), 7);
      expect(failed.unwrapOrElse((e) => e.code.length), 16);
    });

    test('partition splits a fan-out in order', () {
      final results = <Result<int>>[
        const Ok(1),
        Err(ValidationException('bad')),
        const Ok(3),
      ];

      final (values, errors) = Result.partition(results);

      expect(values, <int>[1, 3]);
      expect(errors, hasLength(1));
    });

    test('toResult bridges a throwing future', () async {
      final result = await Future<int>.error(
        ValidationException('bad'),
      ).toResult();

      expect(result.isErr, isTrue);
    });
  });

  group('AgenticContext', () {
    test('root fills silent defaults', () {
      final context = AgenticContext.root();

      expect(context.runId, startsWith('run_'));
      expect(context.logger, isA<NoopLogger>());
      expect(context.events, isA<NoopEventBus>());
      expect(context.cancellation.isCancelled, isFalse);
      expect(context.deadline, isNull);
    });

    test('child composes the scope name and shares the run id', () {
      final root = AgenticContext.root(runId: 'run-1');
      final scope = root.child('agent').child('tool');

      expect(scope.name, 'root.agent.tool');
      expect(scope.runId, 'run-1');
    });

    test('child re-scopes the logger and merges metadata', () {
      final sink = InMemoryLogSink();
      final root = AgenticContext.root(
        logger: StructuredLogger(sink: sink),
        metadata: {'tenant': 'acme'},
      );

      root.child('agents', metadata: {'agent': 'researcher'}).logger.info('hi');

      final record = sink.records.single;
      expect(record.loggerName, 'agentic.agents');
      expect(record.fields, containsPair('agent', 'researcher'));
    });

    test('metadata is inherited and unmodifiable', () {
      final root = AgenticContext.root(metadata: {'tenant': 'acme'});
      final scope = root.child('agent', metadata: {'agent': 'r'});

      expect(scope.metadata, containsPair('tenant', 'acme'));
      expect(() => scope.metadata['x'] = 1, throwsUnsupportedError);
    });

    test('a deadline expires and throwIfCancelled reports it', () async {
      final clock = FakeClock();
      final context = AgenticContext.root(
        clock: clock,
        timeout: const Duration(seconds: 10),
      );

      expect(context.isExpired, isFalse);
      expect(context.remaining, const Duration(seconds: 10));

      await clock.advance(const Duration(seconds: 11));

      expect(context.isExpired, isTrue);
      expect(context.throwIfCancelled, throwsA(isA<CancelledException>()));
    });

    test('a child deadline is clamped to the parent', () {
      final clock = FakeClock();
      final root = AgenticContext.root(
        clock: clock,
        timeout: const Duration(seconds: 5),
      );

      final scope = root.child('step', timeout: const Duration(minutes: 10));

      expect(
        scope.remaining,
        lessThanOrEqualTo(const Duration(seconds: 5)),
        reason: 'a step must never outlive the run that owns it',
      );
    });

    test('cancelling the parent cancels the child', () {
      final source = CancellationTokenSource();
      final root = AgenticContext.root(cancellation: source.token);
      final scope = root.child('step');

      source.cancel('user stopped');

      expect(scope.cancellation.isCancelled, isTrue);
      expect(
        scope.throwIfCancelled,
        throwsA(
          isA<CancelledException>().having(
            (e) => e.operation,
            'operation',
            'root.step',
          ),
        ),
      );
    });

    test('step opens a span and passes a matching scope', () async {
      final exporter = InMemorySpanExporter();
      final context = AgenticContext.root(
        runId: 'run-1',
        tracer: Tracer(exporter: exporter),
      );

      final result = await context.step('llm.generate', (scope, span) async {
        span.setAttribute('llm.model', 'gpt-4o');
        expect(scope.traceContext, span.context);
        expect(scope.name, 'root.llm.generate');
        return 'answer';
      });

      expect(result, 'answer');
      final span = exporter.spans.single;
      expect(span.attributes['run.id'], 'run-1');
      expect(span.attributes['llm.model'], 'gpt-4o');
      expect(span.status, SpanStatus.ok);
    });

    test('step records a failure and rethrows', () async {
      final exporter = InMemorySpanExporter();
      final context = AgenticContext.root(tracer: Tracer(exporter: exporter));

      await expectLater(
        context.step<void>(
          'tool.run',
          (scope, span) async =>
              throw ToolExecutionException('x', toolName: 't'),
        ),
        throwsA(isA<ToolExecutionException>()),
      );

      expect(exporter.spans.single.status, SpanStatus.error);
    });

    test('publishes events on its bus', () async {
      final bus = BroadcastEventBus();
      final context = AgenticContext.root(runId: 'run-1', events: bus);

      context.publish(
        GenericEvent(
          id: 'e1',
          timestamp: DateTime.utc(2026),
          type: 'app.ping',
          runId: 'run-1',
        ),
      );

      expect(bus.publishedCount, 1);
      await bus.dispose();
    });

    test('serialises where the run is', () {
      final json = AgenticContext.root(runId: 'run-1').child('agent').toJson();

      expect(json['runId'], 'run-1');
      expect(json['name'], 'root.agent');
    });
  });
}
