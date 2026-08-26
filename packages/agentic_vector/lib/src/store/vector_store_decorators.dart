/// Decorators that add behaviour to any [VectorStore].
///
/// # Why decorators rather than options on the port
///
/// Observability, namespace pinning and read-only guards are all things some
/// deployments want and others do not. Putting them on the interface would
/// force every adapter — including third-party ones — to implement all of
/// them, correctly, forever. Wrapping composes instead: each concern is one
/// small class, and a store that knows nothing about tracing still traces.
///
/// Order matters. Put [ObservableVectorStore] outermost so that what it
/// reports is what the caller actually experienced, retries and all.
library;

import 'package:agentic_core/agentic_core.dart';
import 'package:agentic_vector/src/events/vector_events.dart';
import 'package:agentic_vector/src/model/metadata_filter.dart';
import 'package:agentic_vector/src/model/vector_record.dart';
import 'package:agentic_vector/src/store/vector_store.dart';

/// Forwards every call to another store.
///
/// Extend this to write a decorator and override only what you change; new
/// methods on [VectorStore] then reach your decorator without you touching it.
abstract base class DelegatingVectorStore implements VectorStore {
  /// Wraps [inner].
  const DelegatingVectorStore(this.inner);

  /// The wrapped store.
  final VectorStore inner;

  @override
  VectorStoreInfo get info => inner.info;

  @override
  Future<void> upsert(
    List<VectorRecord> records, {
    String? namespace,
    AgenticContext? context,
  }) => inner.upsert(records, namespace: namespace, context: context);

  @override
  Future<List<VectorMatch>> search(
    VectorQuery query, {
    String? namespace,
    AgenticContext? context,
  }) => inner.search(query, namespace: namespace, context: context);

  @override
  Future<VectorRecord?> get(String id, {String? namespace}) =>
      inner.get(id, namespace: namespace);

  @override
  Future<int> delete(Iterable<String> ids, {String? namespace}) =>
      inner.delete(ids, namespace: namespace);

  @override
  Future<int> deleteWhere(MetadataFilter filter, {String? namespace}) =>
      inner.deleteWhere(filter, namespace: namespace);

  @override
  Future<int> count({String? namespace, MetadataFilter? filter}) =>
      inner.count(namespace: namespace, filter: filter);

  @override
  Future<void> clear({String? namespace}) => inner.clear(namespace: namespace);

  @override
  Future<void> dispose() => inner.dispose();
}

/// Traces, logs and publishes events around every operation.
///
/// ```dart
/// final store = ObservableVectorStore(QdrantVectorStore(...));
/// ```
final class ObservableVectorStore extends DelegatingVectorStore {
  /// Wraps [inner] with instrumentation.
  const ObservableVectorStore(super.inner);

  @override
  Future<void> upsert(
    List<VectorRecord> records, {
    String? namespace,
    AgenticContext? context,
  }) async {
    if (context == null) return inner.upsert(records, namespace: namespace);

    await context.step('vector.upsert', (scope, span) async {
      final started = scope.clock.now();
      span.setAttributes(<String, Object?>{
        'vector.store': info.name,
        'vector.namespace': ?namespace,
        'vector.records': records.length,
      });
      try {
        await inner.upsert(records, namespace: namespace, context: scope);
      } on AgenticException catch (error) {
        _publishFailure(scope, span, 'upsert', namespace, error);
        rethrow;
      }
      final duration = scope.clock.now().difference(started);
      scope
        ..publish(
          VectorUpsertCompleted(
            id: scope.ids.prefixed('evt'),
            timestamp: scope.clock.now(),
            store: info.name,
            namespace: namespace,
            count: records.length,
            duration: duration,
            runId: scope.runId,
            source: 'vector:${info.name}',
            traceId: span.context.traceId,
            spanId: span.context.spanId,
          ),
        )
        ..logger.debug(
          'Vectors written',
          fields: <String, Object?>{
            'store': info.name,
            'count': records.length,
            'ms': duration.inMilliseconds,
          },
        );
    }, kind: SpanKind.client);
  }

  @override
  Future<List<VectorMatch>> search(
    VectorQuery query, {
    String? namespace,
    AgenticContext? context,
  }) async {
    if (context == null) return inner.search(query, namespace: namespace);

    return context.step('vector.search', (scope, span) async {
      final started = scope.clock.now();
      span.setAttributes(<String, Object?>{
        'vector.store': info.name,
        'vector.namespace': ?namespace,
        'vector.top_k': query.topK,
        'vector.filtered': query.filter != null,
      });
      final List<VectorMatch> matches;
      try {
        matches = await inner.search(
          query,
          namespace: namespace,
          context: scope,
        );
      } on AgenticException catch (error) {
        _publishFailure(scope, span, 'search', namespace, error);
        rethrow;
      }
      final duration = scope.clock.now().difference(started);
      final topScore = matches.isEmpty ? null : matches.first.score;
      span.setAttributes(<String, Object?>{
        'vector.returned': matches.length,
        'vector.top_score': ?topScore,
      });
      scope
        ..publish(
          VectorSearchCompleted(
            id: scope.ids.prefixed('evt'),
            timestamp: scope.clock.now(),
            store: info.name,
            namespace: namespace,
            topK: query.topK,
            returned: matches.length,
            topScore: topScore,
            filtered: query.filter != null,
            duration: duration,
            runId: scope.runId,
            source: 'vector:${info.name}',
            traceId: span.context.traceId,
            spanId: span.context.spanId,
          ),
        )
        // Logged at debug: a busy agent searches on every turn, and this line
        // at info would drown everything else in the log.
        ..logger.debug(
          'Vector search',
          fields: <String, Object?>{
            'store': info.name,
            'requested': query.topK,
            'returned': matches.length,
            'ms': duration.inMilliseconds,
          },
        );
      return matches;
    }, kind: SpanKind.client);
  }

  void _publishFailure(
    AgenticContext scope,
    Span span,
    String operation,
    String? namespace,
    AgenticException error,
  ) {
    scope
      ..publish(
        VectorOperationFailed(
          id: scope.ids.prefixed('evt'),
          timestamp: scope.clock.now(),
          store: info.name,
          namespace: namespace,
          operation: operation,
          code: error.code,
          reason: error.message,
          runId: scope.runId,
          source: 'vector:${info.name}',
          traceId: span.context.traceId,
          spanId: span.context.spanId,
        ),
      )
      ..logger.warn(
        'Vector store operation failed',
        fields: <String, Object?>{
          'store': info.name,
          'operation': operation,
          'code': error.code,
        },
        error: error,
      );
  }

  @override
  String toString() => 'ObservableVectorStore($inner)';
}

/// Pins every operation to one namespace.
///
/// The handle a multi-tenant application hands to request-scoped code: it
/// cannot read another tenant's data because it has no way to name one. One
/// underlying store, and therefore one connection pool, is shared by all of
/// them.
///
/// ```dart
/// final tenantStore = NamespacedVectorStore(shared, namespace: tenantId);
/// await tenantStore.searchVector(query); // always scoped to `tenantId`
/// ```
final class NamespacedVectorStore extends DelegatingVectorStore {
  /// Binds [inner] to [namespace].
  const NamespacedVectorStore(super.inner, {required this.namespace});

  /// The partition every call is confined to.
  final String namespace;

  @override
  Future<void> upsert(
    List<VectorRecord> records, {
    String? namespace,
    AgenticContext? context,
  }) => inner.upsert(records, namespace: this.namespace, context: context);

  @override
  Future<List<VectorMatch>> search(
    VectorQuery query, {
    String? namespace,
    AgenticContext? context,
  }) => inner.search(query, namespace: this.namespace, context: context);

  @override
  Future<VectorRecord?> get(String id, {String? namespace}) =>
      inner.get(id, namespace: this.namespace);

  @override
  Future<int> delete(Iterable<String> ids, {String? namespace}) =>
      inner.delete(ids, namespace: this.namespace);

  @override
  Future<int> deleteWhere(MetadataFilter filter, {String? namespace}) =>
      inner.deleteWhere(filter, namespace: this.namespace);

  @override
  Future<int> count({String? namespace, MetadataFilter? filter}) =>
      inner.count(namespace: this.namespace, filter: filter);

  /// Clears this namespace only.
  ///
  /// Deliberately ignores a `null` namespace rather than clearing everything:
  /// the whole point of this wrapper is that code holding it cannot reach past
  /// its own partition, and "clear the entire index" is the operation where
  /// that matters most.
  @override
  Future<void> clear({String? namespace}) =>
      inner.clear(namespace: this.namespace);

  /// Disposal is a no-op: the wrapped store is shared and outlives this handle.
  @override
  Future<void> dispose() async {}

  @override
  String toString() => 'NamespacedVectorStore($namespace, $inner)';
}
