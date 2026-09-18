/// W3C trace-context propagation: joining a trace that started elsewhere, and
/// continuing it into the next process.
library;

import 'package:agentic_core/agentic_core.dart';
import 'package:test/test.dart';

const String _traceId = '4bf92f3577b34da6a3ce929d0e0e4736';
const String _spanId = '00f067aa0ba902b7';

void main() {
  group('reading a traceparent', () {
    test('parses a well-formed header and treats the caller as the parent', () {
      final context = TraceContext.fromTraceParent('00-$_traceId-$_spanId-01');

      expect(context, isNotNull);
      expect(context!.traceId, _traceId);
      expect(context.sampled, isTrue);
      // The incoming span is this request's *parent*. Getting that backwards
      // produces a trace where every hop is a sibling of the last.
      expect(context.parentSpanId, _spanId);
    });

    test('an unsampled flag survives, because sampling is decided once', () {
      expect(
        TraceContext.fromTraceParent('00-$_traceId-$_spanId-00')!.sampled,
        isFalse,
      );
    });

    test('a future version is accepted if the first four fields parse', () {
      // The format is designed to be forward-compatible; refusing an unknown
      // version would break this the first time the spec moves.
      final context = TraceContext.fromTraceParent(
        '01-$_traceId-$_spanId-01-something-new',
      );
      expect(context?.traceId, _traceId);
    });

    test('malformed input is null, not an exception', () {
      // This parses a header an outside caller controls. A bad one means
      // "start a new trace", not "fail the request".
      for (final bad in <String>[
        '',
        'garbage',
        '00-$_traceId',
        '00-tooshort-$_spanId-01',
        '00-$_traceId-tooshort-01',
        'zz-$_traceId-$_spanId-01',
        '00-${'z' * 32}-$_spanId-01',
        'ff-$_traceId-$_spanId-01', // forbidden version
        '00-${'0' * 32}-$_spanId-01', // all-zero trace id is invalid
        '00-$_traceId-${'0' * 16}-01', // all-zero span id is invalid
      ]) {
        expect(
          TraceContext.fromTraceParent(bad),
          isNull,
          reason: 'should reject "$bad"',
        );
      }
    });

    test('headers are matched case-insensitively', () {
      // Clients disagree about casing, and a lookup that misses starts a new
      // trace for every request — silently.
      final context = TraceContext.fromHeaders(<String, String>{
        'Traceparent': '00-$_traceId-$_spanId-01',
        'TraceState': 'vendor=abc',
      });

      expect(context?.traceId, _traceId);
      expect(context?.traceState, 'vendor=abc');
    });

    test('no traceparent means no context', () {
      expect(TraceContext.fromHeaders(const <String, String>{}), isNull);
      expect(
        TraceContext.fromHeaders(const <String, String>{'tracestate': 'a=b'}),
        isNull,
      );
    });
  });

  group('writing headers', () {
    test('round-trips through the header form', () {
      const original = TraceContext(
        traceId: _traceId,
        spanId: _spanId,
        traceState: 'vendor=abc',
      );

      final headers = original.toHeaders();
      expect(headers['traceparent'], '00-$_traceId-$_spanId-01');
      expect(headers['tracestate'], 'vendor=abc');

      final parsed = TraceContext.fromHeaders(headers);
      expect(parsed!.traceId, original.traceId);
      expect(parsed.sampled, original.sampled);
      expect(parsed.traceState, original.traceState);
    });

    test('tracestate is carried through untouched, or omitted', () {
      // Vendor data belongs to whoever started the trace. This framework never
      // reads it and never invents it; it only refuses to drop it.
      expect(
        const TraceContext(
          traceId: _traceId,
          spanId: _spanId,
        ).toHeaders().containsKey('tracestate'),
        isFalse,
      );
      expect(
        const TraceContext(
          traceId: _traceId,
          spanId: _spanId,
          traceState: '',
        ).toHeaders().containsKey('tracestate'),
        isFalse,
      );
    });

    test('survives a JSON round trip, for an isolate or a snapshot', () {
      const original = TraceContext(
        traceId: _traceId,
        spanId: _spanId,
        parentSpanId: 'a1b2c3d4e5f60718',
        sampled: false,
        traceState: 'vendor=abc',
      );

      final restored = TraceContext.fromJson(original.toJson());

      expect(restored.traceId, original.traceId);
      expect(restored.spanId, original.spanId);
      expect(restored.parentSpanId, original.parentSpanId);
      expect(restored.sampled, isFalse);
      expect(restored.traceState, 'vendor=abc');
    });

    test('an id from a real span renders as a valid header', () {
      final tracer = Tracer(ids: SequentialIdGenerator());
      final span = tracer.startSpan('llm.generate');

      final header = span.context.toTraceParent();

      expect(
        TraceContext.fromTraceParent(header),
        isNotNull,
        reason:
            'a span this framework produced must be propagatable: "$header"',
      );
      span.end();
    });
  });
}
