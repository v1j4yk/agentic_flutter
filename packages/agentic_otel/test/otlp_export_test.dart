/// What reaches the collector, and what happens when it does not answer.
library;

import 'dart:convert';

import 'package:agentic_core/agentic_core.dart';
import 'package:agentic_otel/agentic_otel.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

final Uri collector = Uri.parse('https://collector.example.com/v1/traces');

/// A span with known values, produced the way the framework produces them.
SpanData spanOf({
  String name = 'llm.generate',
  SpanKind kind = SpanKind.client,
  SpanStatus status = SpanStatus.ok,
  String? statusMessage,
  Map<String, Object?> attributes = const <String, Object?>{},
  List<SpanEvent> events = const <SpanEvent>[],
}) => SpanData(
  name: name,
  context: const TraceContext(
    traceId: '4bf92f3577b34da6a3ce929d0e0e4736',
    spanId: '00f067aa0ba902b7',
    parentSpanId: 'a1b2c3d4e5f60718',
  ),
  kind: kind,
  startTime: DateTime.utc(2026, 9, 18, 12),
  endTime: DateTime.utc(2026, 9, 18, 12, 0, 0, 250),
  status: status,
  statusMessage: statusMessage,
  attributes: attributes,
  events: events,
);

(http.Client, List<http.Request>) accepting({int status = 200}) {
  final requests = <http.Request>[];
  final client = MockClient((request) async {
    requests.add(request);
    return http.Response('{}', status);
  });
  return (client, requests);
}

JsonMap firstSpanIn(http.Request request) {
  final body = jsonDecode(request.body) as Map<String, Object?>;
  final resourceSpans = body['resourceSpans']! as List<Object?>;
  final scopeSpans =
      (resourceSpans.first! as Map<String, Object?>)['scopeSpans']!
          as List<Object?>;
  final spans =
      (scopeSpans.first! as Map<String, Object?>)['spans']! as List<Object?>;
  return spans.first! as Map<String, Object?>;
}

void main() {
  group('encoding', () {
    test('a span carries its identity, timing and status', () {
      final encoded = encodeSpan(
        spanOf(status: SpanStatus.error, statusMessage: 'rate limited'),
      );

      expect(encoded['traceId'], '4bf92f3577b34da6a3ce929d0e0e4736');
      expect(encoded['spanId'], '00f067aa0ba902b7');
      expect(encoded['parentSpanId'], 'a1b2c3d4e5f60718');
      expect(encoded['name'], 'llm.generate');
      expect(encoded['kind'], 3, reason: 'client');
      // Nanoseconds, as a string: the value is past what a double holds
      // exactly, and a collector reading it as a number would round the
      // timestamp.
      expect(encoded['startTimeUnixNano'], isA<String>());
      expect(
        int.parse(encoded['endTimeUnixNano']! as String) -
            int.parse(encoded['startTimeUnixNano']! as String),
        250 * 1000 * 1000,
      );
      expect(encoded['status'], <String, Object?>{
        'code': 2,
        'message': 'rate limited',
      });
    });

    test('a root span omits the parent rather than sending an empty one', () {
      final root = SpanData(
        name: 'agent.run',
        context: const TraceContext(
          traceId: '4bf92f3577b34da6a3ce929d0e0e4736',
          spanId: '00f067aa0ba902b7',
        ),
        kind: SpanKind.internal,
        startTime: DateTime.utc(2026),
        endTime: DateTime.utc(2026),
        status: SpanStatus.unset,
      );

      expect(encodeSpan(root).containsKey('parentSpanId'), isFalse);
    });

    test('attributes are typed, and nulls are dropped', () {
      final attributes = encodeAttributes(<String, Object?>{
        'gen_ai.request.model': 'claude-sonnet-5',
        'gen_ai.usage.input_tokens': 1200,
        'gen_ai.request.temperature': 0.2,
        'agentic.cached': true,
        'gen_ai.response.finish_reasons': <String>['stop'],
        'agentic.absent': null,
      });

      Object? valueFor(String key) =>
          attributes.firstWhere((a) => a['key'] == key)['value'];

      expect(valueFor('gen_ai.request.model'), <String, Object?>{
        'stringValue': 'claude-sonnet-5',
      });
      // Integers go as strings in OTLP's JSON mapping; a number would lose
      // precision for large values.
      expect(valueFor('gen_ai.usage.input_tokens'), <String, Object?>{
        'intValue': '1200',
      });
      expect(valueFor('gen_ai.request.temperature'), <String, Object?>{
        'doubleValue': 0.2,
      });
      expect(valueFor('agentic.cached'), <String, Object?>{'boolValue': true});
      expect(valueFor('gen_ai.response.finish_reasons'), <String, Object?>{
        'arrayValue': <String, Object?>{
          'values': <Object?>[
            <String, Object?>{'stringValue': 'stop'},
          ],
        },
      });
      expect(
        attributes.map((a) => a['key']),
        isNot(contains('agentic.absent')),
      );
    });

    test('an attribute of an unexpected type is rendered, not dropped', () {
      // A span attribute that silently disappears is a debugging session spent
      // looking for it.
      final attributes = encodeAttributes(<String, Object?>{
        'agentic.budget': const Duration(seconds: 30),
      });

      expect(attributes.single['value'], <String, Object?>{
        'stringValue': '0:00:30.000000',
      });
    });

    test('the resource says which service produced the spans', () {
      final body = encodeSpans(
        <SpanData>[spanOf()],
        resource: const OtlpResource(
          serviceName: 'pocket_agent',
          serviceVersion: '1.2.0',
          deploymentEnvironment: 'production',
          attributes: <String, Object?>{'device.model': 'Pixel 9a'},
        ),
      );

      final resource =
          ((body['resourceSpans']! as List<Object?>).first!
                  as Map<String, Object?>)['resource']!
              as Map<String, Object?>;
      final keys = (resource['attributes']! as List<Object?>)
          .map((a) => (a! as Map<String, Object?>)['key'])
          .toList();

      expect(keys, contains('service.name'));
      expect(keys, contains('service.version'));
      expect(keys, contains('deployment.environment.name'));
      expect(keys, contains('device.model'));
    });

    test('events survive with their own timestamps', () {
      final encoded = encodeSpan(
        spanOf(
          events: <SpanEvent>[
            SpanEvent(
              name: 'first_token',
              timestamp: DateTime.utc(2026, 9, 18, 12, 0, 0, 120),
              attributes: const <String, Object?>{'latency_ms': 120},
            ),
          ],
        ),
      );

      final events = encoded['events']! as List<Object?>;
      final event = events.single! as Map<String, Object?>;
      expect(event['name'], 'first_token');
      expect(event['timeUnixNano'], isA<String>());
      expect(event['attributes']! as List<Object?>, hasLength(1));
    });
  });

  group('exporting', () {
    test('posts to the endpoint with the configured headers', () async {
      final (client, requests) = accepting();
      final exporter = OtlpHttpSpanExporter(
        endpoint: collector,
        headers: const <String, String>{'authorization': 'Bearer t'},
        client: client,
      );

      expect(await exporter.exportAll(<SpanData>[spanOf()]), isTrue);

      expect(requests.single.url, collector);
      expect(requests.single.headers['authorization'], 'Bearer t');
      expect(requests.single.headers['content-type'], contains('json'));
      expect(firstSpanIn(requests.single)['name'], 'llm.generate');
      await exporter.dispose();
    });

    test('a rejection is reported, never thrown at the caller', () async {
      final (client, _) = accepting(status: 503);
      final errors = <Object>[];
      final exporter = OtlpHttpSpanExporter(
        endpoint: collector,
        client: client,
        onError: (error, _) => errors.add(error),
      );

      // Telemetry that breaks a run is worse than no telemetry.
      expect(await exporter.exportAll(<SpanData>[spanOf()]), isFalse);
      expect(errors, hasLength(1));
      expect('${errors.single}', contains('503'));
      await exporter.dispose();
    });

    test('a dead collector is reported, never thrown at the caller', () async {
      final exporter = OtlpHttpSpanExporter(
        endpoint: collector,
        client: MockClient((_) async => throw const SocketishFailure()),
        onError: (error, _) {},
      );

      expect(await exporter.exportAll(<SpanData>[spanOf()]), isFalse);
      await exporter.dispose();
    });

    test('exporting nothing makes no request', () async {
      final (client, requests) = accepting();
      final exporter = OtlpHttpSpanExporter(
        endpoint: collector,
        client: client,
      );

      expect(await exporter.exportAll(const <SpanData>[]), isTrue);
      expect(requests, isEmpty);
      await exporter.dispose();
    });
  });

  group('batching', () {
    test('sends one request for many spans', () async {
      final (client, requests) = accepting();
      final exporter = BatchSpanExporter(
        OtlpHttpSpanExporter(endpoint: collector, client: client),
        maxBatch: 10,
        flushEvery: Duration.zero, // no timer: this test drives the flush
      );

      for (var i = 0; i < 5; i++) {
        exporter.export(spanOf(name: 'span.$i'));
      }
      expect(requests, isEmpty, reason: 'nothing is sent until a batch closes');

      await exporter.flush();

      expect(requests, hasLength(1));
      expect(exporter.pending, 0);
      await exporter.dispose();
    });

    test('a full batch flushes itself', () async {
      final (client, requests) = accepting();
      final exporter = BatchSpanExporter(
        OtlpHttpSpanExporter(endpoint: collector, client: client),
        maxBatch: 3,
        flushEvery: Duration.zero,
      );

      for (var i = 0; i < 3; i++) {
        exporter.export(spanOf());
      }
      await exporter.flush();

      expect(requests, hasLength(1));
      await exporter.dispose();
    });

    test('a full queue drops the oldest, and says how many', () async {
      final (client, _) = accepting();
      final exporter = BatchSpanExporter(
        OtlpHttpSpanExporter(endpoint: collector, client: client),
        maxBatch: 1000,
        maxQueue: 5,
        flushEvery: Duration.zero,
      );

      for (var i = 0; i < 8; i++) {
        exporter.export(spanOf(name: 'span.$i'));
      }

      // In a queue of stale telemetry the newest is the one worth keeping.
      expect(exporter.pending, 5);
      expect(exporter.dropped, 3);
      await exporter.dispose();
    });

    test('spans lost while disposing are counted too', () async {
      final (client, _) = accepting(status: 500);
      final exporter = BatchSpanExporter(
        OtlpHttpSpanExporter(endpoint: collector, client: client),
        maxBatch: 100,
        flushEvery: Duration.zero,
      );
      final span = spanOf();
      exporter.export(span);

      await exporter.dispose();

      expect(exporter.dropped, 1);
    });

    test('disposing flushes what is buffered', () async {
      final (client, requests) = accepting();
      final exporter = BatchSpanExporter(
        OtlpHttpSpanExporter(endpoint: collector, client: client),
        maxBatch: 100,
        flushEvery: Duration.zero,
      );

      final span = spanOf();
      exporter.export(span);
      expect(exporter.pending, 1, reason: 'buffered, not yet sent');

      await exporter.dispose();

      // The last spans of a run are the interesting ones; losing them on the
      // way out would make the whole exporter untrustworthy.
      expect(requests, hasLength(1));
    });

    test(
      'a rejected batch counts as dropped rather than retrying forever',
      () async {
        final (client, requests) = accepting(status: 500);
        final exporter = BatchSpanExporter(
          OtlpHttpSpanExporter(endpoint: collector, client: client),
          maxBatch: 10,
          flushEvery: Duration.zero,
        );

        final rejected = spanOf();
        exporter
          ..export(rejected)
          ..export(rejected);
        expect(exporter.pending, 2);

        await exporter.flush();

        expect(requests, hasLength(1));
        expect(exporter.dropped, 2);
        expect(exporter.pending, 0);
        await exporter.dispose();
      },
    );

    test(
      'a tracer wired to it produces spans that reach the collector',
      () async {
        final (client, requests) = accepting();
        final exporter = BatchSpanExporter(
          OtlpHttpSpanExporter(endpoint: collector, client: client),
          maxBatch: 100,
          flushEvery: Duration.zero,
        );
        final tracer = Tracer(exporter: exporter);

        await tracer.trace('agent.run', (span) async {
          span.setAttributes(
            genAiAgentAttributes(agentName: 'support', conversationId: 's1'),
          );
        });
        await exporter.flush();

        final encoded = firstSpanIn(requests.single);
        expect(encoded['name'], 'agent.run');
        final keys = (encoded['attributes']! as List<Object?>)
            .map((a) => (a! as Map<String, Object?>)['key'])
            .toList();
        expect(keys, contains(GenAiAttributes.operationName));
        expect(keys, contains(GenAiAttributes.agentName));
        await exporter.dispose();
      },
    );
  });

  group('GenAI conventions', () {
    test('chat attributes use the names a backend recognises', () {
      final attributes = genAiChatAttributes(
        provider: 'anthropic',
        requestModel: 'claude-sonnet-5',
        responseModel: 'claude-sonnet-5',
        inputTokens: 1200,
        outputTokens: 300,
        finishReason: 'stop',
        temperature: 0.2,
      );

      expect(attributes, containsPair(GenAiAttributes.operationName, 'chat'));
      expect(
        attributes,
        containsPair(GenAiAttributes.providerName, 'anthropic'),
      );
      expect(attributes, containsPair(GenAiAttributes.usageInputTokens, 1200));
      expect(
        attributes,
        containsPair(GenAiAttributes.responseFinishReasons, <String>['stop']),
      );
      // Absent values are left out rather than sent as null.
      expect(attributes.containsKey(GenAiAttributes.responseId), isFalse);
      expect(attributes.containsKey(GenAiAttributes.conversationId), isFalse);
    });

    test('tool attributes name the call as well as the tool', () {
      final attributes = genAiToolAttributes(
        toolName: 'issue_refund',
        callId: 'call_1',
      );

      expect(
        attributes,
        containsPair(GenAiAttributes.operationName, 'execute_tool'),
      );
      expect(
        attributes,
        containsPair(GenAiAttributes.toolName, 'issue_refund'),
      );
      expect(attributes, containsPair(GenAiAttributes.toolCallId, 'call_1'));
      expect(attributes, containsPair(GenAiAttributes.toolType, 'function'));
    });
  });
}

/// Stands in for whatever the platform throws when nothing is listening.
final class SocketishFailure implements Exception {
  const SocketishFailure();

  @override
  String toString() => 'Connection refused';
}
