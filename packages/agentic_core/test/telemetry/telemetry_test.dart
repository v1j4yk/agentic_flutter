import 'package:agentic_core/agentic_core.dart';
import 'package:agentic_core/testing.dart';
import 'package:test/test.dart';

void main() {
  group('StructuredLogger', () {
    late InMemoryLogSink sink;
    late StructuredLogger logger;

    setUp(() {
      sink = InMemoryLogSink();
      logger = StructuredLogger(
        sink: sink,
        level: LogLevel.debug,
        clock: FakeClock(),
      );
    });

    test('emits records at or above the threshold', () {
      logger
        ..trace('too verbose')
        ..debug('kept')
        ..info('kept too');

      expect(sink.records.map((r) => r.message), <String>['kept', 'kept too']);
    });

    test('isEnabled lets callers skip expensive message construction', () {
      expect(logger.isEnabled(LogLevel.trace), isFalse);
      expect(logger.isEnabled(LogLevel.error), isTrue);
      expect(
        StructuredLogger(
          sink: sink,
          level: LogLevel.off,
        ).isEnabled(LogLevel.fatal),
        isFalse,
      );
    });

    test('child loggers compose names and inherit bound fields', () {
      final child = logger
          .withFields({'runId': 'run-1'})
          .child('agents', fields: {'agent': 'researcher'});

      child.info('started');

      final record = sink.records.single;
      expect(record.loggerName, 'agentic.agents');
      expect(record.fields, containsPair('runId', 'run-1'));
      expect(record.fields, containsPair('agent', 'researcher'));
    });

    test('per-call fields override bound fields', () {
      logger
          .withFields({'step': 'plan'})
          .info('x', fields: {'step': 'execute'});

      expect(sink.records.single.fields['step'], 'execute');
    });

    test('redacts credential-shaped fields by default', () {
      logger.info(
        'configured',
        fields: {
          'apiKey': 'sk-proj-1234567890abcdef',
          'Authorization': 'Bearer abcdefghijklmnop',
          'model': 'gpt-4o',
        },
      );

      final fields = sink.records.single.fields;
      expect(fields['apiKey'], 'sk-p***24');
      expect(fields['Authorization'], startsWith('Bear***'));
      expect(
        fields['model'],
        'gpt-4o',
        reason: 'only credential-shaped keys are masked',
      );
    });

    test('masks a short secret entirely', () {
      logger.info('x', fields: {'token': 'abc'});

      expect(sink.records.single.fields['token'], '***');
    });

    test('redaction can be disabled deliberately', () {
      final plain = StructuredLogger(sink: sink, redactor: null);
      plain.info('x', fields: {'apiKey': 'sk-secret-value'});

      expect(sink.records.single.fields['apiKey'], 'sk-secret-value');
    });

    test('carries an error and stack trace', () {
      final error = ValidationException('bad');
      logger.error('failed', error: error, stackTrace: StackTrace.current);

      expect(sink.records.single.error, same(error));
      expect(sink.records.single.stackTrace, isNotNull);
    });

    test('correlates records with the active span', () {
      final correlated = StructuredLogger(
        sink: sink,
        traceIdProvider: () => 'trace-1',
        spanIdProvider: () => 'span-2',
      );

      correlated.info('inside a span');

      expect(sink.records.single.traceId, 'trace-1');
      expect(sink.records.single.spanId, 'span-2');
      expect(sink.records.single.toJson()['spanId'], 'span-2');
    });

    test('records serialise for a log aggregator', () {
      logger.warn('slow', fields: {'ms': 1200});

      final json = sink.records.single.toJson();
      expect(json['level'], 'WARN');
      expect(json['severity'], LogLevel.warning.severity);
      expect((json['fields']! as Map)['ms'], 1200);
    });

    test('bounds the in-memory buffer', () {
      final bounded = InMemoryLogSink(maxRecords: 2);
      final boundedLogger = StructuredLogger(sink: bounded);

      for (var i = 0; i < 5; i++) {
        boundedLogger.info('m$i');
      }

      expect(bounded.records.map((r) => r.message), <String>['m3', 'm4']);
    });
  });

  group('MultiLogSink', () {
    test('isolates a failing sink', () {
      final healthy = InMemoryLogSink();
      final sink = MultiLogSink([_ExplodingSink(), healthy]);

      StructuredLogger(sink: sink).info('still delivered');

      expect(healthy.records, hasLength(1));
    });
  });

  group('NoopLogger', () {
    test('discards everything and reports every level disabled', () {
      const logger = NoopLogger();

      expect(logger.isEnabled(LogLevel.fatal), isFalse);
      expect(() => logger.info('x'), returnsNormally);
      expect(logger.child('x'), same(logger));
    });
  });

  group('Tracer', () {
    late InMemorySpanExporter exporter;
    late Tracer tracer;

    setUp(() {
      exporter = InMemorySpanExporter();
      tracer = Tracer(
        exporter: exporter,
        ids: SequentialIdGenerator(prefix: 'id-'),
        clock: FakeClock(),
      );
    });

    test('records a span with attributes and status', () async {
      await tracer.trace('llm.generate', (span) async {
        span.setAttribute('llm.model', 'gpt-4o');
        return 'answer';
      });

      final span = exporter.spans.single;
      expect(span.name, 'llm.generate');
      expect(span.status, SpanStatus.ok);
      expect(span.attributes['llm.model'], 'gpt-4o');
    });

    test('builds a parent/child tree within one trace', () async {
      await tracer.trace('agent.run', (parent) async {
        await tracer.trace(
          'llm.generate',
          (child) async => 'x',
          parent: parent.context,
        );
      });

      final child = exporter.named('llm.generate').single;
      final parent = exporter.named('agent.run').single;

      expect(child.context.traceId, parent.context.traceId);
      expect(child.context.parentSpanId, parent.context.spanId);
      expect(exporter.trace(parent.context.traceId), hasLength(2));
    });

    test('records an error and rethrows unchanged', () async {
      await expectLater(
        tracer.trace<void>(
          'tool.run',
          (span) async => throw ToolExecutionException('boom', toolName: 'x'),
        ),
        throwsA(isA<ToolExecutionException>()),
      );

      final span = exporter.spans.single;
      expect(span.status, SpanStatus.error);
      final exception = span.events.single;
      expect(exception.name, 'exception');
      expect(exception.attributes['error.code'], 'tool_execution_error');
      expect(exception.attributes['error.retryable'], isFalse);
    });

    test('ending twice exports once', () {
      tracer.startSpan('x')
        ..end()
        ..end();

      expect(exporter.spans, hasLength(1));
    });

    test('ignores mutation after the span ends', () {
      final span = tracer.startSpan('x')..end();
      span.setAttribute('late', true);

      expect(exporter.spans.single.attributes.containsKey('late'), isFalse);
    });

    test('a sampled-out trace exports nothing', () {
      final sampled = Tracer(
        exporter: exporter,
        sampler: (name) => name.startsWith('keep'),
      );

      sampled.startSpan('keep.this').end();
      sampled.startSpan('drop.this').end();

      expect(exporter.spans.map((s) => s.name), <String>['keep.this']);
    });

    test('children inherit the sampling decision', () {
      final sampled = Tracer(exporter: exporter, sampler: (_) => false);
      final parent = sampled.startSpan('root');

      sampled.startSpan('child', parent: parent.context).end();
      parent.end();

      expect(
        exporter.spans,
        isEmpty,
        reason: 'a half-recorded trace is worse than none',
      );
    });

    test('traceStream marks the first event and counts the rest', () async {
      final events = await tracer
          .traceStream('llm.stream', Stream<int>.fromIterable([1, 2, 3]))
          .toList();

      expect(events, [1, 2, 3]);
      final span = exporter.spans.single;
      expect(span.attributes['stream.events'], 3);
      expect(span.events.single.name, 'first_event');
    });

    test('traceStream records a mid-stream failure', () async {
      await expectLater(
        tracer
            .traceStream('llm.stream', Stream<int>.error(StateError('boom')))
            .toList(),
        throwsStateError,
      );

      expect(exporter.spans.single.status, SpanStatus.error);
    });
  });

  group('TraceContext', () {
    test('round-trips through JSON', () {
      const context = TraceContext(
        traceId: 'abc',
        spanId: 'def',
        parentSpanId: 'ghi',
      );

      expect(TraceContext.fromJson(context.toJson()), context);
    });

    test('renders a W3C traceparent header', () {
      const context = TraceContext(traceId: '4bf92f', spanId: '00f067');

      final header = context.toTraceParent();
      expect(header, startsWith('00-'));
      expect(header.split('-')[1], hasLength(32));
      expect(header.split('-')[2], hasLength(16));
      expect(header, endsWith('-01'));
    });
  });
}

final class _ExplodingSink implements LogSink {
  @override
  void emit(LogRecord record) => throw StateError('sink is broken');

  @override
  Future<void> dispose() async {}
}
