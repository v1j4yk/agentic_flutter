/// Events published by the vector layer.
///
/// Retrieval is the part of a RAG system that is hardest to debug after the
/// fact: the answer looks wrong, and the question is whether the model
/// reasoned badly or was simply handed the wrong passages. These events record
/// what was asked for and what came back, so that question has an answer.
///
/// No payload here contains a vector or a document body — an event log that
/// carries embeddings is a log nobody can afford to keep.
library;

import 'package:agentic_core/agentic_core.dart';

/// Base for every vector-store event.
abstract base class VectorEvent extends AgenticEvent {
  /// Creates a vector event.
  const VectorEvent({
    required super.id,
    required super.timestamp,
    required this.store,
    this.namespace,
    super.runId,
    super.source,
    super.traceId,
    super.spanId,
  });

  /// The adapter involved, such as `qdrant`.
  final String store;

  /// The partition involved, when one was named.
  final String? namespace;
}

/// Records were written to a store.
final class VectorUpsertCompleted extends VectorEvent {
  /// Creates the event.
  const VectorUpsertCompleted({
    required super.id,
    required super.timestamp,
    required super.store,
    required this.count,
    required this.duration,
    super.namespace,
    super.runId,
    super.source,
    super.traceId,
    super.spanId,
  });

  /// How many records were written.
  final int count;

  /// How long the write took.
  final Duration duration;

  @override
  String get type => 'vector.upsert.completed';

  @override
  JsonMap payload() => pruneNulls(<String, Object?>{
    'store': store,
    'namespace': namespace,
    'count': count,
    'durationMs': duration.inMilliseconds,
  });
}

/// A search finished.
///
/// [returned] against [topK] is the number worth alerting on. A search that
/// consistently returns fewer results than requested means the filter is too
/// narrow, the score floor too high, or the index emptier than anyone thinks.
final class VectorSearchCompleted extends VectorEvent {
  /// Creates the event.
  const VectorSearchCompleted({
    required super.id,
    required super.timestamp,
    required super.store,
    required this.topK,
    required this.returned,
    required this.duration,
    this.topScore,
    this.filtered = false,
    super.namespace,
    super.runId,
    super.source,
    super.traceId,
    super.spanId,
  });

  /// How many matches were requested.
  final int topK;

  /// How many came back.
  final int returned;

  /// The best score, when anything matched.
  final double? topScore;

  /// Whether a metadata filter was applied.
  final bool filtered;

  /// How long the search took.
  final Duration duration;

  @override
  String get type => 'vector.search.completed';

  @override
  JsonMap payload() => pruneNulls(<String, Object?>{
    'store': store,
    'namespace': namespace,
    'topK': topK,
    'returned': returned,
    'topScore': topScore,
    'filtered': filtered ? true : null,
    'durationMs': duration.inMilliseconds,
  });
}

/// Records were removed.
final class VectorDeleteCompleted extends VectorEvent {
  /// Creates the event.
  const VectorDeleteCompleted({
    required super.id,
    required super.timestamp,
    required super.store,
    required this.count,
    super.namespace,
    super.runId,
    super.source,
    super.traceId,
    super.spanId,
  });

  /// How many records were removed.
  final int count;

  @override
  String get type => 'vector.delete.completed';

  @override
  JsonMap payload() => pruneNulls(<String, Object?>{
    'store': store,
    'namespace': namespace,
    'count': count,
  });
}

/// A store operation failed.
///
/// Published *in addition* to the exception being thrown, not instead of it.
/// The caller still has to handle the failure; this is for whoever is watching
/// the system rather than the call.
final class VectorOperationFailed extends VectorEvent {
  /// Creates the event.
  const VectorOperationFailed({
    required super.id,
    required super.timestamp,
    required super.store,
    required this.operation,
    required this.code,
    required this.reason,
    super.namespace,
    super.runId,
    super.source,
    super.traceId,
    super.spanId,
  });

  /// The operation that failed, such as `search`.
  final String operation;

  /// The failure's stable code.
  final String code;

  /// A human-readable explanation.
  final String reason;

  @override
  String get type => 'vector.operation.failed';

  @override
  JsonMap payload() => pruneNulls(<String, Object?>{
    'store': store,
    'namespace': namespace,
    'operation': operation,
    'code': code,
    'reason': reason,
  });
}
