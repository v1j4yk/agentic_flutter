/// A [VectorStore] backed by Qdrant.
///
/// # What this adapter has to reconcile
///
/// Qdrant is a good fit for the port, with three mismatches that are worth
/// naming because every real adapter has some:
///
/// 1. **Identifiers.** Qdrant point IDs must be unsigned integers or UUIDs,
///    while the port promises caller-chosen string identifiers such as
///    `guide.md#chunk-3`. The adapter derives a deterministic UUID (RFC 4122
///    version 5, SHA-1) from any identifier that is not already one, and keeps
///    the original in the payload. Deterministic is the operative word: a
///    random UUID would make re-indexing insert duplicates instead of
///    replacing.
/// 2. **Score direction.** With Euclidean distance Qdrant reports a distance,
///    where smaller is better; the port promises a score where larger is
///    better. The adapter converts both the returned score and the
///    `minScore` threshold, so a switch of metric does not silently invert a
///    filter.
/// 3. **Filters.** [MetadataFilter] is translated into Qdrant's
///    `must`/`should`/`must_not` structure. Because the filter hierarchy is
///    sealed, adding a filter kind fails to compile here rather than being
///    silently dropped into a query that then returns the wrong rows.
///
/// # Configuration
///
/// ```dart
/// final store = QdrantVectorStore(
///   baseUrl: Uri.parse('http://localhost:6333'),
///   collection: 'documents',
///   dimensions: 1536,
///   apiKey: qdrantKey, // Qdrant Cloud; omit for a local instance
/// );
/// await store.ensureCollection();
/// ```
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:agentic_core/agentic_core.dart';
import 'package:agentic_llm/agentic_llm.dart' show mapHttpFailure;
import 'package:agentic_vector/src/model/metadata_filter.dart';
import 'package:agentic_vector/src/model/similarity.dart';
import 'package:agentic_vector/src/model/vector_record.dart';
import 'package:agentic_vector/src/store/vector_store.dart';
import 'package:crypto/crypto.dart' show sha1;
import 'package:http/http.dart' as http;

/// Payload key holding the caller's identifier.
///
/// Present because the point ID may be a derived UUID; this is what the port's
/// callers actually see as [VectorRecord.id].
const String kQdrantIdKey = '_agentic_id';

/// Payload key holding [VectorRecord.text].
const String kQdrantTextKey = '_agentic_text';

/// Talks to a Qdrant instance over its REST API.
final class QdrantVectorStore implements VectorStore {
  /// Creates an adapter.
  ///
  /// [collection] is the default namespace; a `namespace` argument on any
  /// operation overrides it, mapping one-to-one onto a Qdrant collection.
  ///
  /// Pass a [client] to share a connection pool or to test without a server.
  QdrantVectorStore({
    required Uri baseUrl,
    required this.collection,
    required int dimensions,
    SimilarityMetric metric = SimilarityMetric.cosine,
    String? apiKey,
    http.Client? client,
    this.timeout = const Duration(seconds: 30),
    int maxUpsertBatch = 128,
    this.waitForIndexing = true,
  }) : _baseUrl = baseUrl,
       _apiKey = apiKey,
       _client = client ?? http.Client(),
       _ownsClient = client == null,
       info = VectorStoreInfo(
         name: 'qdrant',
         dimensions: dimensions,
         metric: metric,
         maxUpsertBatch: maxUpsertBatch,
       );

  @override
  final VectorStoreInfo info;

  /// Default collection, used when no namespace is given.
  final String collection;

  /// Ceiling for a single HTTP request.
  final Duration timeout;

  /// Whether writes wait for Qdrant to apply them.
  ///
  /// On by default. Qdrant acknowledges a write before it is searchable
  /// otherwise, which makes "index, then immediately search" — exactly what
  /// every test and every first-run ingestion does — fail intermittently.
  /// Turn it off for bulk loads where nothing reads until the end.
  final bool waitForIndexing;

  final Uri _baseUrl;
  final String? _apiKey;
  final http.Client _client;
  final bool _ownsClient;
  bool _disposed = false;

  /// Creates the collection if it does not already exist.
  ///
  /// Safe to call on every start-up: it checks first and returns without
  /// writing when the collection is there.
  Future<void> ensureCollection({String? namespace}) async {
    final name = namespace ?? collection;
    final existing = await _send(
      'GET',
      '/collections/$name',
      allowStatus: <int>[404],
    );
    if (existing != null) return;
    await _send(
      'PUT',
      '/collections/$name',
      body: <String, Object?>{
        'vectors': <String, Object?>{
          'size': info.dimensions,
          'distance': _distanceName(info.metric),
        },
      },
    );
  }

  /// Deletes an entire collection, including its configuration.
  ///
  /// Distinct from [clear], which empties a collection but leaves it usable.
  Future<void> dropCollection({String? namespace}) async {
    await _send(
      'DELETE',
      '/collections/${namespace ?? collection}',
      allowStatus: <int>[404],
    );
  }

  @override
  Future<void> upsert(
    List<VectorRecord> records, {
    String? namespace,
    AgenticContext? context,
  }) async {
    if (records.isEmpty) return;
    checkDimensions(records);
    if (records.length > info.maxUpsertBatch) {
      throw ValidationException(
        'Qdrant accepts at most ${info.maxUpsertBatch} points per request but '
        '${records.length} were given. Use `upsertAll`, which batches.',
        violations: <String>['records: ${records.length}'],
      );
    }
    await _send(
      'PUT',
      '/collections/${namespace ?? collection}/points'
          '${waitForIndexing ? '?wait=true' : ''}',
      body: <String, Object?>{
        'points': <Object?>[
          for (final record in records)
            <String, Object?>{
              'id': _pointId(record.id),
              'vector': record.vector,
              'payload': <String, Object?>{
                ...record.metadata,
                kQdrantIdKey: record.id,
                if (record.text != null) kQdrantTextKey: record.text,
              },
            },
        ],
      },
      context: context,
    );
  }

  @override
  Future<List<VectorMatch>> search(
    VectorQuery query, {
    String? namespace,
    AgenticContext? context,
  }) async {
    if (query.dimensions != info.dimensions) {
      throw ValidationException(
        'The query is ${query.dimensions}-dimensional but the collection is '
        '${info.dimensions}-dimensional.',
        violations: <String>[
          'dimensions: ${query.dimensions} != ${info.dimensions}',
        ],
      );
    }
    final filter = query.filter;
    final response = await _send(
      'POST',
      '/collections/${namespace ?? collection}/points/search',
      body: pruneNulls(<String, Object?>{
        'vector': query.vector,
        'limit': query.topK,
        'with_payload': true,
        'with_vector': query.includeVectors,
        'filter': filter == null ? null : translateFilter(filter),
        'score_threshold': _backendThreshold(query.minScore),
      }),
      context: context,
    );
    final points = (response?['result'] as List<Object?>?) ?? const <Object?>[];
    return List<VectorMatch>.unmodifiable(<VectorMatch>[
      for (final point in points) _toMatch(point! as JsonMap),
    ]);
  }

  @override
  Future<VectorRecord?> get(String id, {String? namespace}) async {
    final response = await _send(
      'POST',
      '/collections/${namespace ?? collection}/points',
      body: <String, Object?>{
        'ids': <Object?>[_pointId(id)],
        'with_payload': true,
        'with_vector': true,
      },
      allowStatus: <int>[404],
    );
    final points = (response?['result'] as List<Object?>?) ?? const <Object?>[];
    if (points.isEmpty) return null;
    return _toRecord(points.first! as JsonMap);
  }

  @override
  Future<int> delete(Iterable<String> ids, {String? namespace}) async {
    final list = ids.toList(growable: false);
    if (list.isEmpty) return 0;
    await _send(
      'POST',
      '/collections/${namespace ?? collection}/points/delete'
          '${waitForIndexing ? '?wait=true' : ''}',
      body: <String, Object?>{
        'points': <Object?>[for (final id in list) _pointId(id)],
      },
    );
    // Qdrant reports an operation status, not a row count. Returning the
    // request size would be a lie for identifiers that were never there, so the
    // adapter reports what it can honestly claim: the delete was applied to
    // every identifier given.
    return list.length;
  }

  @override
  Future<int> deleteWhere(MetadataFilter filter, {String? namespace}) async {
    final name = namespace ?? collection;
    final before = await count(namespace: name, filter: filter);
    if (before == 0) return 0;
    await _send(
      'POST',
      '/collections/$name/points/delete${waitForIndexing ? '?wait=true' : ''}',
      body: <String, Object?>{'filter': translateFilter(filter)},
    );
    return before;
  }

  @override
  Future<int> count({String? namespace, MetadataFilter? filter}) async {
    final response = await _send(
      'POST',
      '/collections/${namespace ?? collection}/points/count',
      body: pruneNulls(<String, Object?>{
        'exact': true,
        'filter': filter == null ? null : translateFilter(filter),
      }),
      allowStatus: <int>[404],
    );
    final result = response?['result'];
    if (result is! Map) return 0;
    return (result['count'] as num?)?.toInt() ?? 0;
  }

  @override
  Future<void> clear({String? namespace}) async {
    final names = <String>[if (namespace != null) namespace else collection];
    for (final name in names) {
      await _send(
        'POST',
        '/collections/$name/points/delete${waitForIndexing ? '?wait=true' : ''}',
        // An empty `must` matches every point; Qdrant rejects a bare `{}`.
        body: <String, Object?>{
          'filter': <String, Object?>{'must': <Object?>[]},
        },
        allowStatus: <int>[404],
      );
    }
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    if (_ownsClient) _client.close();
  }

  // ---------------------------------------------------------------------------
  // Translation
  // ---------------------------------------------------------------------------

  /// Converts [filter] into Qdrant's filter syntax.
  ///
  /// Public so that adapter behaviour is testable without a server, and so that
  /// callers building a raw Qdrant query can reuse it.
  static JsonMap translateFilter(MetadataFilter filter) => switch (filter) {
    EqualsFilter(:final field, :final value) => <String, Object?>{
      'must': <Object?>[
        <String, Object?>{
          'key': field,
          'match': <String, Object?>{'value': value},
        },
      ],
    },
    NotEqualsFilter(:final field, :final value) => <String, Object?>{
      'must_not': <Object?>[
        <String, Object?>{
          'key': field,
          'match': <String, Object?>{'value': value},
        },
      ],
    },
    InFilter(:final field, :final values) => <String, Object?>{
      'must': <Object?>[
        <String, Object?>{
          'key': field,
          'match': <String, Object?>{'any': values},
        },
      ],
    },
    GreaterThanFilter(:final field, :final value, :final orEqual) =>
      <String, Object?>{
        'must': <Object?>[
          <String, Object?>{
            'key': field,
            'range': <String, Object?>{orEqual ? 'gte' : 'gt': value},
          },
        ],
      },
    LessThanFilter(:final field, :final value, :final orEqual) =>
      <String, Object?>{
        'must': <Object?>[
          <String, Object?>{
            'key': field,
            'range': <String, Object?>{orEqual ? 'lte' : 'lt': value},
          },
        ],
      },
    // Qdrant has no `exists`; it has `is_empty`, which is its negation. A field
    // that is absent and a field explicitly set to null are both empty, which
    // matches this port's definition of existence.
    ExistsFilter(:final field) => <String, Object?>{
      'must_not': <Object?>[
        <String, Object?>{
          'is_empty': <String, Object?>{'key': field},
        },
      ],
    },
    AndFilter(:final filters) => <String, Object?>{
      'must': <Object?>[for (final child in filters) translateFilter(child)],
    },
    OrFilter(:final filters) => <String, Object?>{
      'should': <Object?>[for (final child in filters) translateFilter(child)],
    },
    NotFilter(:final filter) => <String, Object?>{
      'must_not': <Object?>[translateFilter(filter)],
    },
  };

  /// The Qdrant point identifier for a caller's [id].
  ///
  /// An identifier Qdrant already accepts is passed through unchanged, so an
  /// existing collection stays readable; anything else becomes a deterministic
  /// UUID.
  static Object pointIdFor(String id) => _pointId(id);

  static Object _pointId(String id) {
    final asInt = int.tryParse(id);
    if (asInt != null && asInt >= 0) return asInt;
    if (_uuidPattern.hasMatch(id)) return id;
    return _uuidV5(id);
  }

  static final RegExp _uuidPattern = RegExp(
    r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-'
    r'[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
  );

  /// The namespace UUID names are hashed under.
  ///
  /// Fixed forever: changing it would change every derived point identifier and
  /// turn the next re-index into a full duplicate of the collection.
  static const List<int> _namespaceBytes = <int>[
    0xa6, 0x1e, 0x2c, 0x77, //
    0x4b, 0x2f, 0x5e, 0x83,
    0x9c, 0x41, 0x0d, 0x7a,
    0x36, 0xb8, 0x51, 0xe4,
  ];

  static String _uuidV5(String name) {
    final digest = sha1.convert(<int>[
      ..._namespaceBytes,
      ...utf8.encode(name),
    ]);
    final bytes = Uint8List.fromList(digest.bytes.sublist(0, 16))
      ..[6] = (digest.bytes[6] & 0x0f) | 0x50
      ..[8] = (digest.bytes[8] & 0x3f) | 0x80;
    final hex = <String>[
      for (final byte in bytes) byte.toRadixString(16).padLeft(2, '0'),
    ].join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-${hex.substring(16, 20)}-'
        '${hex.substring(20)}';
  }

  static String _distanceName(SimilarityMetric metric) => switch (metric) {
    SimilarityMetric.cosine => 'Cosine',
    SimilarityMetric.dotProduct => 'Dot',
    SimilarityMetric.euclidean => 'Euclid',
  };

  /// Converts a port-level `minScore` into Qdrant's threshold.
  ///
  /// For Euclidean the port's score is `1 / (1 + distance)`, so the equivalent
  /// distance ceiling is `1 / score - 1`. Skipping this conversion is how a
  /// `minScore: 0.5` turns into "within 0.5 units", which on a normalised index
  /// rejects almost everything.
  double? _backendThreshold(double minScore) {
    if (minScore <= 0) return null;
    if (info.metric != SimilarityMetric.euclidean) return minScore;
    return 1 / minScore - 1;
  }

  double _toScore(num raw) => info.metric == SimilarityMetric.euclidean
      ? 1 / (1 + raw)
      : raw.toDouble();

  VectorMatch _toMatch(JsonMap point) => VectorMatch(
    record: _toRecord(point),
    score: _toScore((point['score'] as num?) ?? 0),
  );

  VectorRecord _toRecord(JsonMap point) {
    final payload =
        (point['payload'] as Map?)?.cast<String, Object?>() ??
        const <String, Object?>{};
    final metadata = <String, Object?>{...payload}
      ..remove(kQdrantIdKey)
      ..remove(kQdrantTextKey);
    final vector = point['vector'];
    return VectorRecord(
      // Falls back to the point identifier for records written by something
      // other than this adapter, which is the normal case for an existing
      // collection.
      id: payload[kQdrantIdKey] as String? ?? '${point['id']}',
      vector: vector is List
          ? <double>[for (final value in vector) (value! as num).toDouble()]
          : const <double>[],
      metadata: metadata,
      text: payload[kQdrantTextKey] as String?,
    );
  }

  // ---------------------------------------------------------------------------
  // Transport
  // ---------------------------------------------------------------------------

  /// Sends a request, returning the decoded body or `null` for an allowed
  /// non-success status.
  Future<JsonMap?> _send(
    String method,
    String path, {
    JsonMap? body,
    List<int> allowStatus = const <int>[],
    AgenticContext? context,
  }) async {
    if (_disposed) {
      throw InvalidStateException(
        'This QdrantVectorStore has been disposed.',
        currentState: 'disposed',
        expectedState: 'open',
      );
    }
    context?.throwIfCancelled();
    final request = http.Request(method, _baseUrl.resolve(path.substring(1)))
      ..headers['content-type'] = 'application/json'
      ..headers['accept'] = 'application/json';
    if (_apiKey != null) request.headers['api-key'] = _apiKey;
    if (body != null) request.body = jsonEncode(body);

    final send = _client
        .send(request)
        .then(http.Response.fromStream)
        .timeout(
          timeout,
          onTimeout: () => throw AgenticTimeoutException(
            'Qdrant did not answer `$method $path` within '
            '${timeout.inSeconds}s.',
            operation: 'qdrant.${method.toLowerCase()}',
            timeout: timeout,
          ),
        );

    final token = context?.cancellation ?? CancellationToken.none;
    final response = await token.race(send, operation: 'qdrant.$path');

    if (allowStatus.contains(response.statusCode)) return null;
    if (response.statusCode >= 400) {
      throw mapHttpFailure(
        statusCode: response.statusCode,
        body: utf8.decode(response.bodyBytes, allowMalformed: true),
        provider: 'qdrant',
        headers: response.headers,
      );
    }
    if (response.bodyBytes.isEmpty) return const <String, Object?>{};
    final decoded = jsonDecode(
      utf8.decode(response.bodyBytes, allowMalformed: true),
    );
    if (decoded is Map) return decoded.cast<String, Object?>();
    throw SerializationException(
      'Qdrant returned a ${decoded.runtimeType} for `$path`, expected an '
      'object.',
    );
  }

  @override
  String toString() => 'QdrantVectorStore($collection, ${info.dimensions}d)';
}
