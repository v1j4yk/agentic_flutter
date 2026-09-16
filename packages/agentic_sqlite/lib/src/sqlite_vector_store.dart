/// A vector store that survives a restart.
///
/// # SQLite holds the truth; memory holds the index
///
/// Rows live in SQLite. Search runs over an `InMemoryVectorStore` loaded from
/// those rows when the store opens, so ranking is the same tested code path as
/// the in-memory adapter rather than a second implementation that could
/// disagree with it.
///
/// Every mutation is written to SQLite first, inside a transaction, and applied
/// to memory only once that commits. If the write fails, memory is untouched
/// and the two still agree — the failure mode is "the call threw", never "the
/// app searched data it will lose on restart".
///
/// # What it does not do
///
/// It never evicts. `InMemoryVectorStore(maxRecords:)` drops the oldest records
/// silently, which is the right trade for a cache and the wrong one for a
/// durable store — a note a user saved should not vanish because they saved
/// others. Bounding size is the application's decision, made with
/// `deleteWhere` or `clear`.
///
/// # Precision
///
/// Vectors are stored as 32-bit floats, half the disk of 64-bit. Every
/// embedding provider produces float32-precision values in the first place, so
/// nothing real is lost; a vector read back can differ from the one written in
/// the eighth significant digit.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:agentic_core/agentic_core.dart';
import 'package:agentic_sqlite/src/database.dart';
import 'package:agentic_vector/agentic_vector.dart';
import 'package:meta/meta.dart';
import 'package:sqlite3/sqlite3.dart';

/// A durable [VectorStore] in an [AgenticDatabase].
final class SqliteVectorStore implements VectorStore {
  SqliteVectorStore._({
    required AgenticDatabase database,
    required this.name,
    required InMemoryVectorStore index,
  }) : _database = database,
       _index = index;

  /// Opens collection [name], creating or validating it, and loads its rows.
  @internal
  static Future<SqliteVectorStore> load({
    required AgenticDatabase database,
    required String name,
    required int dimensions,
    required SimilarityMetric metric,
  }) async {
    final db = database.connection;
    try {
      final existing = db.select(
        'SELECT dimensions, metric FROM vector_collections WHERE name = ?',
        <Object?>[name],
      );
      if (existing.isEmpty) {
        db.execute(
          'INSERT INTO vector_collections (name, dimensions, metric) '
          'VALUES (?, ?, ?)',
          <Object?>[name, dimensions, metric.name],
        );
      } else {
        final row = existing.first;
        final storedDimensions = row['dimensions'] as int;
        final storedMetric = row['metric'] as String;
        if (storedDimensions != dimensions || storedMetric != metric.name) {
          throw ConfigurationException(
            'The vector collection "$name" was created with '
            '$storedDimensions dimensions and the $storedMetric metric, but '
            'was opened with $dimensions and ${metric.name}. Vectors of one '
            'shape scored as another give wrong results, not slow ones. '
            'Open it with the original settings, or clear it and re-index '
            'with the new embedding model.',
            setting: 'vectorStore.$name',
          );
        }
      }
    } on SqliteException catch (error, stackTrace) {
      throw wrapSqliteError(error, stackTrace, operation: 'open');
    }

    final index = InMemoryVectorStore(
      dimensions: dimensions,
      metric: metric,
      name: '$kSqliteStore:$name',
    );
    final store = SqliteVectorStore._(
      database: database,
      name: name,
      index: index,
    );
    await store._hydrate();
    return store;
  }

  final AgenticDatabase _database;
  final InMemoryVectorStore _index;
  bool _disposed = false;

  /// The collection's name within the database.
  final String name;

  @override
  VectorStoreInfo get info => VectorStoreInfo(
    name: kSqliteStore,
    dimensions: _index.info.dimensions,
    metric: _index.info.metric,
    maxUpsertBatch: 1000,
  );

  Future<void> _hydrate() async {
    final ResultSet rows;
    try {
      rows = _database.connection.select(
        'SELECT namespace, id, vector, metadata, text FROM vectors '
        'WHERE collection = ?',
        <Object?>[name],
      );
    } on SqliteException catch (error, stackTrace) {
      throw wrapSqliteError(error, stackTrace, operation: 'load');
    }

    final dimensions = _index.info.dimensions;
    final byNamespace = <String, List<VectorRecord>>{};
    for (final row in rows) {
      final id = row['id'] as String;
      final bytes = row['vector'] as Uint8List;
      // A row that does not decode is reported, not skipped. Opening a store
      // that silently lacks some of what was saved is worse than refusing to
      // open: the user would search, find nothing, and conclude it was never
      // there.
      if (bytes.length != dimensions * 4) {
        throw StorageException(
          'The vector "$id" in collection "$name" is ${bytes.length} bytes; '
          '$dimensions float32 components need ${dimensions * 4}. The file is '
          'damaged, or was written with a different dimension outside this '
          'package.',
          store: kSqliteStore,
          operation: 'load',
          details: <String, Object?>{'collection': name, 'id': id},
        );
      }
      final JsonMap metadata;
      try {
        metadata = (jsonDecode(row['metadata'] as String) as Map)
            .cast<String, Object?>();
      } on FormatException catch (error, stackTrace) {
        throw StorageException(
          'The metadata of vector "$id" in collection "$name" is not valid '
          'JSON. The file is damaged.',
          store: kSqliteStore,
          operation: 'load',
          cause: error,
          causeStackTrace: stackTrace,
          details: <String, Object?>{'collection': name, 'id': id},
        );
      }
      byNamespace
          .putIfAbsent(row['namespace'] as String, () => <VectorRecord>[])
          .add(
            VectorRecord(
              id: id,
              vector: _decode(bytes),
              metadata: metadata,
              text: row['text'] as String?,
            ),
          );
    }
    for (final entry in byNamespace.entries) {
      await _index.upsert(entry.value, namespace: entry.key);
    }
  }

  @override
  Future<void> upsert(
    List<VectorRecord> records, {
    String? namespace,
    AgenticContext? context,
  }) async {
    _checkOpen();
    if (records.isEmpty) return;
    // Validated here, before the transaction, so a bad batch fails with the
    // framework's message and without writing any of it.
    final expected = info.dimensions;
    final violations = <String>[
      for (final record in records)
        if (record.dimensions != expected)
          '${record.id}: ${record.dimensions} dimensions, expected $expected',
    ];
    if (violations.isNotEmpty) {
      throw ValidationException(
        '${violations.length} record(s) do not match the collection\'s '
        '$expected dimensions.',
        violations: violations,
      );
    }

    final key = namespace ?? kDefaultNamespace;
    _database.transaction((db) {
      final statement = db.prepare(
        'INSERT OR REPLACE INTO vectors '
        '(collection, namespace, id, vector, metadata, text) '
        'VALUES (?, ?, ?, ?, ?, ?)',
      );
      try {
        for (final record in records) {
          statement.execute(<Object?>[
            name,
            key,
            record.id,
            _encode(record.vector),
            jsonEncode(record.metadata),
            record.text,
          ]);
        }
      } finally {
        statement.close();
      }
    }, operation: 'upsert');
    await _index.upsert(records, namespace: key, context: context);
  }

  @override
  Future<List<VectorMatch>> search(
    VectorQuery query, {
    String? namespace,
    AgenticContext? context,
  }) {
    _checkOpen();
    return _index.search(query, namespace: namespace, context: context);
  }

  @override
  Future<VectorRecord?> get(String id, {String? namespace}) {
    _checkOpen();
    return _index.get(id, namespace: namespace);
  }

  @override
  Future<int> delete(Iterable<String> ids, {String? namespace}) async {
    _checkOpen();
    final targets = ids.toList();
    if (targets.isEmpty) return 0;
    final key = namespace ?? kDefaultNamespace;
    _database.transaction((db) {
      final statement = db.prepare(
        'DELETE FROM vectors WHERE collection = ? AND namespace = ? AND id = ?',
      );
      try {
        for (final id in targets) {
          statement.execute(<Object?>[name, key, id]);
        }
      } finally {
        statement.close();
      }
    }, operation: 'delete');
    return _index.delete(targets, namespace: key);
  }

  /// Deletes every record whose metadata matches [filter].
  ///
  /// A null [namespace] means *every* namespace, as it does for
  /// `InMemoryVectorStore.deleteWhere` — unlike [upsert], [get] and [delete],
  /// where null means the default one. The asymmetry is inherited on purpose:
  /// a persistent store that answered differently from the in-memory one
  /// would be a trap for anybody switching between them.
  ///
  /// The filter is evaluated in Dart with `MetadataFilter.matches`, not
  /// translated to SQL, so it cannot disagree with how search filters.
  @override
  Future<int> deleteWhere(MetadataFilter filter, {String? namespace}) async {
    _checkOpen();
    final rows = namespace == null
        ? _database.connection.select(
            'SELECT namespace, id, metadata FROM vectors WHERE collection = ?',
            <Object?>[name],
          )
        : _database.connection.select(
            'SELECT namespace, id, metadata FROM vectors '
            'WHERE collection = ? AND namespace = ?',
            <Object?>[name, namespace],
          );
    final doomed = <(String, String)>[
      for (final row in rows)
        if (filter.matches(
          (jsonDecode(row['metadata'] as String) as Map)
              .cast<String, Object?>(),
        ))
          (row['namespace'] as String, row['id'] as String),
    ];
    if (doomed.isEmpty) return 0;

    _database.transaction((db) {
      final statement = db.prepare(
        'DELETE FROM vectors WHERE collection = ? AND namespace = ? AND id = ?',
      );
      try {
        for (final (ns, id) in doomed) {
          statement.execute(<Object?>[name, ns, id]);
        }
      } finally {
        statement.close();
      }
    }, operation: 'deleteWhere');
    return _index.deleteWhere(filter, namespace: namespace);
  }

  @override
  Future<int> count({String? namespace, MetadataFilter? filter}) {
    _checkOpen();
    return _index.count(namespace: namespace, filter: filter);
  }

  /// Removes every record in [namespace], or in all namespaces when null.
  @override
  Future<void> clear({String? namespace}) async {
    _checkOpen();
    _database.transaction((db) {
      if (namespace == null) {
        db.execute('DELETE FROM vectors WHERE collection = ?', <Object?>[name]);
      } else {
        db.execute(
          'DELETE FROM vectors WHERE collection = ? AND namespace = ?',
          <Object?>[name, namespace],
        );
      }
    }, operation: 'clear');
    await _index.clear(namespace: namespace);
  }

  /// Releases the in-memory copy. The rows stay on disk.
  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _database.release('vector:$name');
    await _index.dispose();
  }

  void _checkOpen() {
    if (_disposed) {
      throw InvalidStateException(
        'The vector store "$name" has been disposed.',
        currentState: 'disposed',
        expectedState: 'open',
      );
    }
  }

  static Uint8List _encode(Float64List vector) =>
      Float32List.fromList(vector).buffer.asUint8List();

  static List<double> _decode(Uint8List bytes) {
    // Copied rather than viewed: the blob's backing buffer belongs to SQLite's
    // result set and is not guaranteed to be aligned for a Float32 view.
    final aligned = Uint8List.fromList(bytes);
    return aligned.buffer.asFloat32List();
  }
}
