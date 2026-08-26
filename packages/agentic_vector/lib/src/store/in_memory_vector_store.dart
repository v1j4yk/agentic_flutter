/// An exhaustive-search vector store that lives in the process.
///
/// # Why exhaustive search is the right default here
///
/// Real vector databases use approximate nearest neighbour indexes — HNSW,
/// IVF — because they hold millions of vectors. This one compares the query
/// against every record: no index to build, no recall parameter to tune, and
/// exact results.
///
/// What that costs, measured at 768 dimensions on a desktop: **1.9 ms for a
/// thousand records, 24 ms for ten thousand**. So brute force is comfortably
/// interactive for a few thousand vectors, a visible pause at ten thousand, and
/// past that you want a metadata filter to cut the candidate set — which
/// roughly halves it — or a server. A phone is slower again.
///
/// Run `dart run agentic_benchmark vector` to get the number for your machine
/// rather than trusting this one.
///
/// Exactness also makes this the reference implementation: adapter tests can
/// compare a remote store's ranking against a store that is definitionally
/// correct.
library;

import 'dart:collection';

import 'package:agentic_core/agentic_core.dart';
import 'package:agentic_vector/src/model/metadata_filter.dart';
import 'package:agentic_vector/src/model/similarity.dart';
import 'package:agentic_vector/src/model/vector_record.dart';
import 'package:agentic_vector/src/store/vector_store.dart';

/// The key used for records stored without an explicit namespace.
const String kDefaultNamespace = 'default';

/// Holds vectors in memory and scans them exhaustively.
///
/// ```dart
/// final store = InMemoryVectorStore(dimensions: 3);
/// await store.upsertOne(VectorRecord(
///   id: 'doc-1',
///   vector: [0.1, 0.9, 0.0],
///   text: 'Dart supports pattern matching.',
///   metadata: {'lang': 'dart'},
/// ));
///
/// final hits = await store.searchVector(
///   [0.1, 0.8, 0.1],
///   filter: MetadataFilter.equals('lang', 'dart'),
/// );
/// ```
final class InMemoryVectorStore implements VectorStore {
  /// Creates an empty index of fixed width.
  ///
  /// [maxRecords] bounds memory on a device. When it is exceeded the oldest
  /// records by insertion are dropped — the only ordering an index has without
  /// access-frequency data, and the one that matches how documents are usually
  /// superseded.
  InMemoryVectorStore({
    required int dimensions,
    SimilarityMetric metric = SimilarityMetric.cosine,
    this.maxRecords,
    String name = 'in-memory',
  }) : info = VectorStoreInfo(
         name: name,
         dimensions: dimensions,
         metric: metric,
       ),
       assert(
         maxRecords == null || maxRecords > 0,
         'maxRecords must be positive',
       );

  /// Restores a store from [snapshot].
  ///
  /// The other half of [snapshot]: an offline-first app embeds its content
  /// once, writes the index to a file, and starts from it thereafter instead of
  /// re-embedding on every launch.
  factory InMemoryVectorStore.fromJson(JsonMap json) {
    final store = InMemoryVectorStore(
      dimensions: json.requireInt('dimensions'),
      metric: SimilarityMetric.values.byName(
        json.stringOr('metric', SimilarityMetric.cosine.name),
      ),
      maxRecords: json.optionalInt('maxRecords'),
      name: json.stringOr('name', 'in-memory'),
    );
    final namespaces = json.optionalObject('namespaces') ?? const {};
    for (final entry in namespaces.entries) {
      final records = store._bucket(entry.key);
      for (final raw in entry.value! as List<Object?>) {
        final record = VectorRecord.fromJson(raw! as JsonMap);
        records[record.id] = record;
      }
    }
    return store;
  }

  @override
  final VectorStoreInfo info;

  /// Upper bound on records held across all namespaces, or `null` for none.
  final int? maxRecords;

  /// Namespace to identifier to record, in insertion order.
  final Map<String, LinkedHashMap<String, VectorRecord>> _namespaces =
      <String, LinkedHashMap<String, VectorRecord>>{};

  /// How many records are held across every namespace.
  int get length =>
      _namespaces.values.fold(0, (sum, records) => sum + records.length);

  /// The namespaces that currently hold anything.
  Iterable<String> get namespaces => _namespaces.keys;

  @override
  Future<void> upsert(
    List<VectorRecord> records, {
    String? namespace,
    AgenticContext? context,
  }) async {
    checkDimensions(records);
    final target = _bucket(namespace);
    for (final record in records) {
      target[record.id] = record;
    }
    _evict();
  }

  @override
  Future<List<VectorMatch>> search(
    VectorQuery query, {
    String? namespace,
    AgenticContext? context,
  }) async {
    if (query.dimensions != info.dimensions) {
      throw ValidationException(
        'The query is ${query.dimensions}-dimensional but the index is '
        '${info.dimensions}-dimensional.',
        violations: <String>[
          'dimensions: ${query.dimensions} != ${info.dimensions}',
        ],
      );
    }
    final filter = query.filter;
    final matches = <VectorMatch>[];
    for (final record in _bucket(namespace).values) {
      // Filter before scoring, not after: post-filtering is what makes a
      // top-8 query return two results.
      if (filter != null && !filter.matches(record.metadata)) continue;
      final score = info.metric.score(query.vector, record.vector);
      if (score < query.minScore) continue;
      matches.add(
        VectorMatch(
          record: query.includeVectors ? record : _withoutVector(record),
          score: score,
        ),
      );
    }
    matches.sort((a, b) => b.score.compareTo(a.score));
    if (matches.length > query.topK) matches.length = query.topK;
    return List<VectorMatch>.unmodifiable(matches);
  }

  @override
  Future<VectorRecord?> get(String id, {String? namespace}) async =>
      _bucket(namespace)[id];

  @override
  Future<int> delete(Iterable<String> ids, {String? namespace}) async {
    final target = _bucket(namespace);
    var removed = 0;
    for (final id in ids) {
      if (target.remove(id) != null) removed++;
    }
    return removed;
  }

  @override
  Future<int> deleteWhere(MetadataFilter filter, {String? namespace}) async {
    var removed = 0;
    for (final bucket in _buckets(namespace)) {
      final doomed = <String>[
        for (final record in bucket.values)
          if (filter.matches(record.metadata)) record.id,
      ];
      for (final id in doomed) {
        bucket.remove(id);
      }
      removed += doomed.length;
    }
    return removed;
  }

  @override
  Future<int> count({String? namespace, MetadataFilter? filter}) async {
    var total = 0;
    for (final bucket in _buckets(namespace)) {
      if (filter == null) {
        total += bucket.length;
      } else {
        total += bucket.values
            .where((record) => filter.matches(record.metadata))
            .length;
      }
    }
    return total;
  }

  @override
  Future<void> clear({String? namespace}) async {
    if (namespace == null) {
      _namespaces.clear();
    } else {
      _namespaces.remove(namespace);
    }
  }

  /// Serialises the whole index, vectors included.
  ///
  /// Expensive by nature — this is every vector the store holds — so treat it
  /// as a checkpoint operation, not something to call per write.
  JsonMap snapshot() => pruneNulls(<String, Object?>{
    'name': info.name,
    'dimensions': info.dimensions,
    'metric': info.metric.name,
    'maxRecords': maxRecords,
    'namespaces': <String, Object?>{
      for (final entry in _namespaces.entries)
        if (entry.value.isNotEmpty)
          entry.key: entry.value.values
              .map((record) => record.toJson())
              .toList(),
    },
  });

  @override
  Future<void> dispose() async => _namespaces.clear();

  LinkedHashMap<String, VectorRecord> _bucket(String? namespace) =>
      _namespaces.putIfAbsent(
        namespace ?? kDefaultNamespace,
        LinkedHashMap<String, VectorRecord>.new,
      );

  /// The buckets an operation touches: one namespace, or all of them.
  Iterable<LinkedHashMap<String, VectorRecord>> _buckets(String? namespace) =>
      namespace == null
      ? _namespaces.values
      : <LinkedHashMap<String, VectorRecord>>[_bucket(namespace)];

  void _evict() {
    final limit = maxRecords;
    if (limit == null) return;
    var excess = length - limit;
    if (excess <= 0) return;
    // Oldest first, across namespaces in the order they were created.
    for (final bucket in _namespaces.values) {
      while (excess > 0 && bucket.isNotEmpty) {
        bucket.remove(bucket.keys.first);
        excess--;
      }
      if (excess <= 0) return;
    }
  }

  /// A copy without the vector, for callers who did not ask for it.
  ///
  /// Matters more than it looks: handing back the stored record would let a
  /// caller mutate nothing (records are immutable) but would retain every
  /// vector it ever saw in whatever it holds the matches in.
  static VectorRecord _withoutVector(VectorRecord record) => VectorRecord(
    id: record.id,
    vector: const <double>[],
    metadata: record.metadata,
    text: record.text,
  );

  @override
  String toString() =>
      'InMemoryVectorStore($length record(s), ${info.dimensions}d)';
}
