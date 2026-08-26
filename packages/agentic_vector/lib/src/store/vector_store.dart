/// The vector store port.
///
/// # One interface, many databases
///
/// Qdrant, Pinecone, Chroma, pgvector, sqlite-vec and an in-process list all do
/// the same three things: hold vectors with a payload, find the nearest ones to
/// a query, and remove them again. They differ in transport, in filter syntax
/// and in what they call a collection — none of which application code should
/// have to know.
///
/// The port is deliberately small. Every method here is one a real backend
/// implements natively; anything that can be composed from them lives in
/// [VectorStoreOperations] instead, so that adding a convenience never breaks
/// a third-party store.
///
/// # Namespaces
///
/// A `namespace` is a per-call partition — Qdrant's collection, Pinecone's
/// namespace, a tenant column in SQL. It is a parameter rather than a
/// constructor argument because the alternative, one store instance per tenant,
/// means one HTTP client and one connection pool per tenant.
library;

import 'package:agentic_core/agentic_core.dart';
import 'package:agentic_vector/src/model/metadata_filter.dart';
import 'package:agentic_vector/src/model/similarity.dart';
import 'package:agentic_vector/src/model/vector_record.dart';
import 'package:meta/meta.dart';

/// What a store is and what it can do.
@immutable
final class VectorStoreInfo {
  /// Describes a store.
  const VectorStoreInfo({
    required this.name,
    required this.dimensions,
    this.metric = SimilarityMetric.cosine,
    this.maxUpsertBatch = 128,
    this.supportsNamespaces = true,
    this.supportsTextStorage = true,
  }) : assert(dimensions > 0, 'dimensions must be positive'),
       assert(maxUpsertBatch > 0, 'maxUpsertBatch must be positive');

  /// Adapter identifier, such as `qdrant` or `in-memory`.
  final String name;

  /// Vector width this store accepts.
  ///
  /// Fixed for the life of an index. A store that accepted mixed widths would
  /// be a store whose queries fail at read time instead of write time.
  final int dimensions;

  /// How closeness is measured.
  final SimilarityMetric metric;

  /// Largest batch [VectorStore.upsert] accepts in one call.
  ///
  /// Callers chunk to this. It exists because ingestion is the operation most
  /// likely to be handed ten thousand records at once.
  final int maxUpsertBatch;

  /// Whether [VectorStore.upsert] and friends honour a namespace.
  ///
  /// A store that reports `false` throws when given one, rather than ignoring
  /// it — silently merging two tenants' data is the worst possible failure for
  /// this port.
  final bool supportsNamespaces;

  /// Whether [VectorRecord.text] survives a round trip.
  ///
  /// Some deployments keep text in their own database and join on the record
  /// identifier. Retrieval code checks this before assuming a match can render
  /// itself.
  final bool supportsTextStorage;

  /// Serialises the description.
  JsonMap toJson() => <String, Object?>{
    'name': name,
    'dimensions': dimensions,
    'metric': metric.name,
    'maxUpsertBatch': maxUpsertBatch,
    'supportsNamespaces': supportsNamespaces,
    'supportsTextStorage': supportsTextStorage,
  };

  @override
  String toString() => 'VectorStoreInfo($name, ${dimensions}d, ${metric.name})';
}

/// Stores vectors and finds the nearest ones.
///
/// Implementations must:
///
/// * treat [upsert] as insert-or-replace on [VectorRecord.id];
/// * reject records whose width differs from [VectorStoreInfo.dimensions];
/// * apply [VectorQuery.filter] **before** ranking, not after;
/// * return matches ordered by descending [VectorMatch.score];
/// * return at most [VectorQuery.topK] matches, none below
///   [VectorQuery.minScore];
/// * throw [CapabilityNotSupportedException] for a namespace they cannot
///   honour.
///
/// The pre-filter rule is the one that gets broken. Fetching `topK` by
/// similarity and filtering afterwards is easy and wrong: it returns fewer
/// results than asked for, and returns none at all whenever the top matches
/// happen to belong to another tenant.
abstract interface class VectorStore implements Disposable {
  /// What this store is.
  VectorStoreInfo get info;

  /// Inserts or replaces [records].
  ///
  /// Idempotent by [VectorRecord.id], which is what makes re-indexing a
  /// changed document safe.
  Future<void> upsert(
    List<VectorRecord> records, {
    String? namespace,
    AgenticContext? context,
  });

  /// Returns the records nearest to [query].
  Future<List<VectorMatch>> search(
    VectorQuery query, {
    String? namespace,
    AgenticContext? context,
  });

  /// Returns the record with [id], or `null`.
  Future<VectorRecord?> get(String id, {String? namespace});

  /// Removes the records with [ids], returning how many existed.
  Future<int> delete(Iterable<String> ids, {String? namespace});

  /// Removes every record matching [filter], returning how many were removed.
  ///
  /// Separate from [delete] because "forget everything from this document" and
  /// "forget this tenant" are the two deletions that actually happen, and doing
  /// them by identifier means reading the whole index first.
  Future<int> deleteWhere(MetadataFilter filter, {String? namespace});

  /// How many records are stored, optionally restricted by [filter].
  Future<int> count({String? namespace, MetadataFilter? filter});

  /// Removes everything in [namespace], or everywhere when it is `null`.
  Future<void> clear({String? namespace});
}

/// Conveniences available on every [VectorStore].
///
/// Extensions rather than interface members: a new helper here costs
/// third-party adapters nothing, whereas a new interface method breaks them.
extension VectorStoreOperations on VectorStore {
  /// Upserts a single record.
  Future<void> upsertOne(
    VectorRecord record, {
    String? namespace,
    AgenticContext? context,
  }) => upsert(<VectorRecord>[record], namespace: namespace, context: context);

  /// Upserts [records] in batches of [VectorStoreInfo.maxUpsertBatch].
  ///
  /// The call ingestion code should use. Batches run sequentially rather than
  /// concurrently: a store being written to is usually the bottleneck, and
  /// firing eighty parallel writes at it is how ingestion gets rate-limited.
  ///
  /// Returns how many records were written. Checks cancellation between
  /// batches, so a cancelled ingestion stops at a batch boundary rather than
  /// leaving one half-applied.
  Future<int> upsertAll(
    Iterable<VectorRecord> records, {
    String? namespace,
    AgenticContext? context,
  }) async {
    final all = records.toList(growable: false);
    final batchSize = info.maxUpsertBatch;
    var written = 0;
    for (var start = 0; start < all.length; start += batchSize) {
      context?.throwIfCancelled();
      final end = start + batchSize < all.length
          ? start + batchSize
          : all.length;
      final batch = all.sublist(start, end);
      await upsert(batch, namespace: namespace, context: context);
      written += batch.length;
    }
    return written;
  }

  /// Searches with a raw [vector].
  Future<List<VectorMatch>> searchVector(
    List<double> vector, {
    int topK = 8,
    MetadataFilter? filter,
    double minScore = 0,
    bool includeVectors = false,
    String? namespace,
    AgenticContext? context,
  }) => search(
    VectorQuery(
      vector: vector,
      topK: topK,
      filter: filter,
      minScore: minScore,
      includeVectors: includeVectors,
    ),
    namespace: namespace,
    context: context,
  );

  /// Whether a record with [id] exists.
  Future<bool> exists(String id, {String? namespace}) async =>
      await get(id, namespace: namespace) != null;

  /// Removes one record, returning whether it existed.
  Future<bool> deleteOne(String id, {String? namespace}) async =>
      await delete(<String>[id], namespace: namespace) > 0;

  /// Validates [records] against this store's dimensions.
  ///
  /// Adapters call this at the top of [VectorStore.upsert]. Reporting every
  /// offending record at once matters during ingestion: fixing them one
  /// exception per run is how a ten-minute import becomes an afternoon.
  @protected
  void checkDimensions(List<VectorRecord> records) {
    final expected = info.dimensions;
    final violations = <String>[
      for (final record in records)
        if (record.dimensions != expected)
          '${record.id}: ${record.dimensions} dimensions, expected $expected',
    ];
    if (violations.isEmpty) return;
    throw ValidationException(
      '${violations.length} of ${records.length} record(s) do not match the '
      'index width of $expected. This usually means they were embedded with a '
      'different model.',
      violations: violations,
    );
  }

  /// Validates [namespace] against this store's capabilities.
  @protected
  void checkNamespace(String? namespace) {
    if (namespace == null || info.supportsNamespaces) return;
    throw CapabilityNotSupportedException(
      'The `${info.name}` store does not support namespaces, and silently '
      'ignoring `$namespace` would merge data that was meant to stay apart.',
      capability: 'namespaces',
      component: info.name,
    );
  }
}
