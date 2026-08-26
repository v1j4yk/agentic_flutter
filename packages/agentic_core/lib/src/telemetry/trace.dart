/// Distributed tracing for agent runs.
///
/// A single agent run is a tree: the run contains planning, planning calls the
/// model, the model requests three tools, one tool performs a retrieval, and
/// the retrieval embeds a query. When the answer is wrong or the run took
/// eleven seconds, a flat log cannot tell you which branch is at fault. A
/// trace can.
///
/// The model here is deliberately OpenTelemetry-shaped — traces, spans,
/// attributes, events, status — without depending on the OpenTelemetry SDK.
/// That keeps `agentic_core` free of a heavy transitive dependency while making
/// an exporter to a real OTel collector a small, mechanical adapter.
///
/// ```dart
/// final result = await tracer.trace(
///   'agent.run',
///   (span) async {
///     span.setAttribute('agent.name', 'researcher');
///     final answer = await agent.run(prompt);
///     span.setAttribute('llm.tokens.total', answer.usage.totalTokens);
///     return answer;
///   },
/// );
/// ```
library;

import 'dart:async';

import 'package:agentic_core/src/common/agentic_id.dart';
import 'package:agentic_core/src/common/clock.dart';
import 'package:agentic_core/src/common/disposable.dart';
import 'package:agentic_core/src/common/json_types.dart';
import 'package:agentic_core/src/error/agentic_exception.dart';
import 'package:meta/meta.dart';

/// Identifies a span and the trace it belongs to.
///
/// Propagated across process boundaries — into an isolate, into an HTTP header,
/// into a job queue — so that work performed elsewhere still joins the same
/// trace.
@immutable
final class TraceContext {
  /// Creates a trace context.
  const TraceContext({
    required this.traceId,
    required this.spanId,
    this.parentSpanId,
    this.sampled = true,
  });

  /// Identifier shared by every span in the run.
  final String traceId;

  /// Identifier of this span.
  final String spanId;

  /// Identifier of the enclosing span, absent for a root span.
  final String? parentSpanId;

  /// Whether this trace is being recorded.
  ///
  /// Sampling is decided once at the root and inherited, so a trace is never
  /// half-recorded — a partial tree is worse than no tree, because it looks
  /// complete.
  final bool sampled;

  /// Serialises the context for propagation.
  JsonMap toJson() => pruneNulls(<String, Object?>{
    'traceId': traceId,
    'spanId': spanId,
    'parentSpanId': parentSpanId,
    'sampled': sampled,
  });

  /// Restores a context produced by [toJson].
  static TraceContext fromJson(JsonMap json) => TraceContext(
    traceId: json['traceId']! as String,
    spanId: json['spanId']! as String,
    parentSpanId: json['parentSpanId'] as String?,
    sampled: json['sampled'] as bool? ?? true,
  );

  /// Renders the context as a W3C `traceparent` header value.
  ///
  /// Lets an agent running on a device join a trace that continues on a
  /// backend, which is the whole point of a standard format.
  String toTraceParent() {
    final flags = sampled ? '01' : '00';
    return '00-${_pad(traceId, 32)}-${_pad(spanId, 16)}-$flags';
  }

  static String _pad(String value, int width) {
    final normalised = value
        .toLowerCase()
        .replaceAll(RegExp('[^0-9a-f]'), '')
        .padRight(width, '0');
    return normalised.length > width
        ? normalised.substring(0, width)
        : normalised;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TraceContext &&
          traceId == other.traceId &&
          spanId == other.spanId &&
          parentSpanId == other.parentSpanId &&
          sampled == other.sampled;

  @override
  int get hashCode => Object.hash(traceId, spanId, parentSpanId, sampled);

  @override
  String toString() =>
      'TraceContext(trace: $traceId, span: $spanId, parent: $parentSpanId)';
}

/// Outcome recorded on a finished span.
enum SpanStatus {
  /// No explicit outcome was set.
  unset,

  /// The operation succeeded.
  ok,

  /// The operation failed.
  error,
}

/// What kind of work a span represents.
///
/// Mirrors the OpenTelemetry span kinds so exported traces render correctly in
/// standard tooling.
enum SpanKind {
  /// Work performed inside the process.
  internal,

  /// An outbound request, such as a call to an LLM provider.
  client,

  /// Handling of an inbound request.
  server,

  /// Publishing to a queue or bus.
  producer,

  /// Consuming from a queue or bus.
  consumer,
}

/// A timestamped point of interest inside a span.
@immutable
final class SpanEvent {
  /// Creates a span event.
  SpanEvent({
    required this.name,
    required this.timestamp,
    Map<String, Object?> attributes = const <String, Object?>{},
  }) : attributes = attributes.isEmpty
           ? const <String, Object?>{}
           : Map<String, Object?>.unmodifiable(attributes);

  /// Short, low-cardinality name, such as `first_token`.
  final String name;

  /// When the event occurred, in UTC.
  final DateTime timestamp;

  /// Structured detail about the event.
  final Map<String, Object?> attributes;

  /// Serialises the event.
  JsonMap toJson() => pruneNulls(<String, Object?>{
    'name': name,
    'timestamp': timestamp.toIso8601String(),
    'attributes': attributes.isEmpty ? null : attributes,
  });
}

/// An immutable snapshot of a finished span.
///
/// [Span] is mutable while it is open — that is unavoidable, since attributes
/// are discovered as the work proceeds. Exporters receive this frozen snapshot
/// instead, so a slow exporter can never observe a torn or later-mutated span.
@immutable
final class SpanData {
  /// Creates a finished-span snapshot.
  SpanData({
    required this.name,
    required this.context,
    required this.kind,
    required this.startTime,
    required this.endTime,
    required this.status,
    this.statusMessage,
    Map<String, Object?> attributes = const <String, Object?>{},
    List<SpanEvent> events = const <SpanEvent>[],
  }) : attributes = Map<String, Object?>.unmodifiable(attributes),
       events = List<SpanEvent>.unmodifiable(events);

  /// Operation name, such as `llm.generate` or `tool.web_search`.
  final String name;

  /// Identity of this span within its trace.
  final TraceContext context;

  /// What kind of work this span represents.
  final SpanKind kind;

  /// When the span started, in UTC.
  final DateTime startTime;

  /// When the span ended, in UTC.
  final DateTime endTime;

  /// Recorded outcome.
  final SpanStatus status;

  /// Human-readable detail about a non-ok [status].
  final String? statusMessage;

  /// Structured attributes describing the operation.
  final Map<String, Object?> attributes;

  /// Points of interest recorded during the span.
  final List<SpanEvent> events;

  /// How long the operation took.
  Duration get duration => endTime.difference(startTime);

  /// Serialises the span.
  JsonMap toJson() => pruneNulls(<String, Object?>{
    'name': name,
    ...context.toJson(),
    'kind': kind.name,
    'startTime': startTime.toIso8601String(),
    'endTime': endTime.toIso8601String(),
    'durationMs': duration.inMilliseconds,
    'status': status.name,
    'statusMessage': statusMessage,
    'attributes': attributes.isEmpty ? null : attributes,
    'events': events.isEmpty
        ? null
        : events.map((event) => event.toJson()).toList(),
  });

  @override
  String toString() =>
      'SpanData($name, ${duration.inMilliseconds}ms, ${status.name})';
}

/// A unit of work being timed.
///
/// Obtain one from [Tracer.startSpan] and always [end] it — preferably by
/// using [Tracer.trace], which ends the span for you even when the body throws.
final class Span {
  Span._({
    required this.name,
    required this.context,
    required this.kind,
    required DateTime startTime,
    required Clock clock,
    required void Function(SpanData data) onEnd,
    Map<String, Object?> attributes = const <String, Object?>{},
  }) : _startTime = startTime,
       _clock = clock,
       _onEnd = onEnd,
       _attributes = Map<String, Object?>.of(attributes);

  /// Operation name.
  final String name;

  /// Identity of this span within its trace.
  final TraceContext context;

  /// What kind of work this span represents.
  final SpanKind kind;

  final DateTime _startTime;
  final Clock _clock;
  final void Function(SpanData data) _onEnd;
  final Map<String, Object?> _attributes;
  final List<SpanEvent> _events = <SpanEvent>[];

  SpanStatus _status = SpanStatus.unset;
  String? _statusMessage;
  bool _ended = false;

  /// Whether [end] has already been called.
  bool get isEnded => _ended;

  /// Attaches [value] to this span under [key].
  ///
  /// Attribute keys should be stable and namespaced — `llm.model`,
  /// `tool.name`, `rag.documents` — so that traces are queryable.
  void setAttribute(String key, Object? value) {
    if (_ended) return;
    _attributes[key] = value;
  }

  /// Attaches every entry of [attributes] to this span.
  void setAttributes(Map<String, Object?> attributes) {
    if (_ended) return;
    _attributes.addAll(attributes);
  }

  /// Records a point of interest.
  ///
  /// The idiomatic way to capture latency landmarks inside a long span, such as
  /// time-to-first-token on a streaming completion.
  void addEvent(String name, {Map<String, Object?> attributes = const {}}) {
    if (_ended) return;
    _events.add(
      SpanEvent(name: name, timestamp: _clock.now(), attributes: attributes),
    );
  }

  /// Sets the outcome of the operation.
  void setStatus(SpanStatus status, [String? message]) {
    if (_ended) return;
    _status = status;
    _statusMessage = message;
  }

  /// Records [error] on this span and sets the status to [SpanStatus.error].
  ///
  /// Framework errors contribute their code and retryability as attributes,
  /// which is what makes "show me every span that failed with `rate_limited`"
  /// a one-line query.
  void recordError(Object error, [StackTrace? stackTrace]) {
    if (_ended) return;
    final attributes = <String, Object?>{
      'error.type': error.runtimeType.toString(),
      'error.message': error.toString(),
      if (stackTrace != null) 'error.stack': stackTrace.toString(),
      if (error is AgenticException) ...<String, Object?>{
        'error.code': error.code,
        'error.retryable': error.isRetryable,
      },
    };
    addEvent('exception', attributes: attributes);
    setStatus(
      SpanStatus.error,
      error is AgenticException ? error.message : error.toString(),
    );
  }

  /// Ends the span and hands a snapshot to the tracer's exporter.
  ///
  /// Idempotent: a second call is ignored, so a `finally` block and an explicit
  /// call cannot double-export.
  void end() {
    if (_ended) return;
    _ended = true;
    _onEnd(
      SpanData(
        name: name,
        context: context,
        kind: kind,
        startTime: _startTime,
        endTime: _clock.now(),
        status: _status,
        statusMessage: _statusMessage,
        attributes: _attributes,
        events: _events,
      ),
    );
  }

  @override
  String toString() => 'Span($name, ${context.spanId})';
}

/// Receives finished spans.
///
/// Implement this to forward traces to an OpenTelemetry collector, a Firebase
/// performance trace, or an in-app inspector.
abstract interface class SpanExporter implements Disposable {
  /// Handles one finished span.
  ///
  /// Called synchronously from [Span.end]; buffer rather than await.
  void export(SpanData span);
}

/// Discards every span.
///
/// The default, so tracing costs nothing until a host application opts in.
final class NoopSpanExporter implements SpanExporter {
  /// Creates the no-op exporter.
  const NoopSpanExporter();

  @override
  void export(SpanData span) {}

  @override
  Future<void> dispose() async {}
}

/// Retains spans in memory.
///
/// Backs assertions in tests and powers an in-app trace inspector.
/// [maxSpans] bounds memory by dropping the oldest spans.
final class InMemorySpanExporter implements SpanExporter {
  /// Creates a bounded in-memory exporter.
  InMemorySpanExporter({this.maxSpans = 1000});

  /// Maximum number of spans retained.
  final int maxSpans;

  final List<SpanData> _spans = <SpanData>[];

  /// The exported spans, oldest first.
  List<SpanData> get spans => List<SpanData>.unmodifiable(_spans);

  /// Every exported span named [name].
  List<SpanData> named(String name) =>
      _spans.where((span) => span.name == name).toList();

  /// Every exported span belonging to [traceId], in start order.
  List<SpanData> trace(String traceId) =>
      _spans.where((span) => span.context.traceId == traceId).toList()
        ..sort((a, b) => a.startTime.compareTo(b.startTime));

  /// Discards every retained span.
  void clear() => _spans.clear();

  @override
  void export(SpanData span) {
    _spans.add(span);
    if (_spans.length > maxSpans) _spans.removeAt(0);
  }

  @override
  Future<void> dispose() async => _spans.clear();
}

/// Decides whether a trace is recorded.
///
/// Returning `false` makes every span in the trace a cheap no-op. Sampling is
/// evaluated once per root span and inherited by descendants.
typedef Sampler = bool Function(String spanName);

/// Creates spans.
///
/// One tracer per application is normal. Child components receive it through
/// `AgenticContext` rather than reaching for a global.
final class Tracer implements Disposable {
  /// Creates a tracer.
  ///
  /// [exporter] defaults to [NoopSpanExporter], so tracing is free until a host
  /// application wires up a destination.
  Tracer({
    SpanExporter? exporter,
    IdGenerator? ids,
    Clock clock = const SystemClock(),
    Sampler? sampler,
  }) : _exporter = exporter ?? const NoopSpanExporter(),
       _ids = ids ?? Ulid(),
       _clock = clock,
       _sampler = sampler;

  final SpanExporter _exporter;
  final IdGenerator _ids;
  final Clock _clock;
  final Sampler? _sampler;

  /// Starts a span named [name].
  ///
  /// When [parent] is supplied the new span joins that trace; otherwise it
  /// starts a new one. Callers must call [Span.end]; prefer [trace], which does
  /// it for you.
  Span startSpan(
    String name, {
    TraceContext? parent,
    SpanKind kind = SpanKind.internal,
    Map<String, Object?> attributes = const <String, Object?>{},
  }) {
    final sampled = parent?.sampled ?? _sampler?.call(name) ?? true;
    final context = TraceContext(
      traceId: parent?.traceId ?? _ids.generate(),
      spanId: _ids.generate(),
      parentSpanId: parent?.spanId,
      sampled: sampled,
    );
    return Span._(
      name: name,
      context: context,
      kind: kind,
      startTime: _clock.now(),
      clock: _clock,
      attributes: attributes,
      onEnd: sampled ? _exporter.export : _discard,
    );
  }

  /// Runs [body] inside a span, ending it in every outcome.
  ///
  /// A thrown error is recorded on the span and rethrown unchanged, so tracing
  /// never alters control flow. Success sets [SpanStatus.ok] unless [body]
  /// already set a status of its own.
  Future<T> trace<T>(
    String name,
    Future<T> Function(Span span) body, {
    TraceContext? parent,
    SpanKind kind = SpanKind.internal,
    Map<String, Object?> attributes = const <String, Object?>{},
  }) async {
    final span = startSpan(
      name,
      parent: parent,
      kind: kind,
      attributes: attributes,
    );
    try {
      final result = await body(span);
      if (span._status == SpanStatus.unset) span.setStatus(SpanStatus.ok);
      return result;
    } on Object catch (error, stackTrace) {
      span.recordError(error, stackTrace);
      rethrow;
    } finally {
      span.end();
    }
  }

  /// Wraps [source] in a span that ends when the stream completes.
  ///
  /// Streaming completions are spans too, and their most interesting number —
  /// time to first token — is only observable from inside the stream.
  Stream<T> traceStream<T>(
    String name,
    Stream<T> source, {
    TraceContext? parent,
    SpanKind kind = SpanKind.client,
    Map<String, Object?> attributes = const <String, Object?>{},
  }) async* {
    final span = startSpan(
      name,
      parent: parent,
      kind: kind,
      attributes: attributes,
    );
    var count = 0;
    try {
      await for (final event in source) {
        if (count == 0) span.addEvent('first_event');
        count++;
        yield event;
      }
      span
        ..setAttribute('stream.events', count)
        ..setStatus(SpanStatus.ok);
    } on Object catch (error, stackTrace) {
      span
        ..setAttribute('stream.events', count)
        ..recordError(error, stackTrace);
      rethrow;
    } finally {
      span.end();
    }
  }

  @override
  Future<void> dispose() => _exporter.dispose();

  static void _discard(SpanData data) {}
}
