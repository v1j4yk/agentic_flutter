/// The base type for everything published on an event bus.
///
/// The framework is event-driven on purpose. An agent run emits a stream of
/// facts — a step started, a token arrived, a tool was called, a memory was
/// written — and several very different consumers want them: a chat UI
/// rendering tokens, a cost meter summing usage, a persistence layer writing an
/// audit trail, a test asserting on the sequence.
///
/// If the agent called each of those directly it would depend on all of them.
/// Publishing instead inverts that: the agent depends on nothing, and consumers
/// come and go without the agent knowing.
///
/// Like `AgenticException`, this type is `base` rather than `sealed`: a
/// third-party tool or provider package must be able to define its own events.
library;

import 'package:agentic_core/src/common/json_types.dart';
import 'package:meta/meta.dart';

/// A fact that has already happened.
///
/// Events are immutable and named in the past tense. That is not a style
/// preference: an event is a record, and anything that can be rejected or
/// modified by a listener is a command, which belongs in a different mechanism.
///
/// Subclasses must:
///
/// * be immutable;
/// * return a stable, dotted [type] such as `agent.step.completed`, since that
///   string ends up in stored audit logs and is part of the public contract;
/// * serialise their whole state through [toJson], so that a run can be
///   replayed or inspected long after the objects are gone.
@immutable
abstract base class AgenticEvent {
  /// Creates an event.
  ///
  /// [id] should be sortable so that a stored event log replays in order;
  /// `Ulid` is what the framework uses. [runId] correlates every event of one
  /// agent or workflow run and is the field consumers filter on most.
  const AgenticEvent({
    required this.id,
    required this.timestamp,
    this.runId,
    this.source,
    this.traceId,
    this.spanId,
  });

  /// Unique, sortable identifier for this event.
  final String id;

  /// When the event occurred, in UTC.
  final DateTime timestamp;

  /// Identifier of the run this event belongs to.
  final String? runId;

  /// Component that published the event, such as `agent:researcher`.
  final String? source;

  /// Trace this event was emitted within, when tracing is active.
  final String? traceId;

  /// Span this event was emitted within, when tracing is active.
  final String? spanId;

  /// Stable, dotted type name, such as `llm.response.completed`.
  ///
  /// Used for routing, filtering and persistence. Treat it as public API:
  /// renaming one breaks stored logs and any consumer filtering on it.
  String get type;

  /// Event-specific payload, excluding the envelope fields.
  ///
  /// Implementations return only their own data; [toJson] merges it with the
  /// envelope so that every serialised event has the same shape.
  @protected
  JsonMap payload();

  /// Serialises the complete event, envelope included.
  JsonMap toJson() => pruneNulls(<String, Object?>{
    'id': id,
    'type': type,
    'timestamp': timestamp.toIso8601String(),
    'runId': runId,
    'source': source,
    'traceId': traceId,
    'spanId': spanId,
    ...payload(),
  });

  @override
  String toString() {
    final data = payload();
    final rendered = data.isEmpty
        ? ''
        : ' ${data.entries.map((e) => '${e.key}=${e.value}').join(' ')}';
    return '$type[$id]$rendered';
  }
}

/// An event carrying an arbitrary payload under a caller-chosen [type].
///
/// The escape hatch for application-level signals that do not deserve their own
/// class — a UI notification, a custom checkpoint. Prefer a purpose-built
/// subclass for anything the framework itself reacts to: a typed event can be
/// selected with `bus.on<MyEvent>()`, while these can only be filtered by
/// string.
@immutable
final class GenericEvent extends AgenticEvent {
  /// Creates a generic event of the given [type].
  GenericEvent({
    required super.id,
    required super.timestamp,
    required this.type,
    Map<String, Object?> data = const <String, Object?>{},
    super.runId,
    super.source,
    super.traceId,
    super.spanId,
  }) : data = Map<String, Object?>.unmodifiable(data);

  @override
  final String type;

  /// The event's payload.
  final Map<String, Object?> data;

  @override
  JsonMap payload() => data;
}
