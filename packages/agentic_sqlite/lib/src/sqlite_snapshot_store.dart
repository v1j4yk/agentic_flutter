/// Suspended workflow runs that survive a restart.
library;

import 'dart:convert';

import 'package:agentic_core/agentic_core.dart';
import 'package:agentic_sqlite/src/database.dart';
import 'package:agentic_workflow/agentic_workflow.dart';
import 'package:meta/meta.dart';
import 'package:sqlite3/sqlite3.dart';

/// A durable [WorkflowSnapshotStore] in an [AgenticDatabase].
///
/// The snapshot's own `formatVersion` travels inside the stored JSON, so a
/// snapshot saved by a newer app version is refused on load with the workflow
/// package's explanation rather than resumed on a guess.
final class SqliteWorkflowSnapshotStore implements WorkflowSnapshotStore {
  /// Creates a store over the `workflow_snapshots` table.
  @internal
  SqliteWorkflowSnapshotStore({
    required AgenticDatabase database,
    required this.name,
  }) : _database = database;

  final AgenticDatabase _database;

  /// The store's name within the database.
  final String name;

  @override
  Future<void> save(WorkflowSnapshot snapshot) async {
    _database.transaction((db) {
      db.execute(
        'INSERT INTO workflow_snapshots '
        '(store, run_id, graph_id, suspended_at, snapshot) '
        'VALUES (?, ?, ?, ?, ?) '
        'ON CONFLICT (store, run_id) DO UPDATE SET '
        'graph_id = excluded.graph_id, suspended_at = excluded.suspended_at, '
        'snapshot = excluded.snapshot',
        <Object?>[
          name,
          snapshot.runId,
          snapshot.graphId,
          snapshot.suspendedAt.toUtc().microsecondsSinceEpoch,
          jsonEncode(snapshot.toJson()),
        ],
      );
    }, operation: 'saveSnapshot');
  }

  @override
  Future<WorkflowSnapshot?> load(String runId) async {
    final rows = _select(
      'SELECT snapshot FROM workflow_snapshots WHERE store = ? AND run_id = ?',
      <Object?>[name, runId],
      operation: 'loadSnapshot',
    );
    if (rows.isEmpty) return null;
    return _decode(rows.first['snapshot'] as String, runId: runId);
  }

  @override
  Future<bool> delete(String runId) async {
    var removed = false;
    _database.transaction((db) {
      db.execute(
        'DELETE FROM workflow_snapshots WHERE store = ? AND run_id = ?',
        <Object?>[name, runId],
      );
      removed = db.updatedRows > 0;
    }, operation: 'deleteSnapshot');
    return removed;
  }

  @override
  Future<List<WorkflowSnapshot>> list({String? graphId}) async {
    final rows = graphId == null
        ? _select(
            'SELECT run_id, snapshot FROM workflow_snapshots '
            'WHERE store = ? ORDER BY suspended_at',
            <Object?>[name],
            operation: 'listSnapshots',
          )
        : _select(
            'SELECT run_id, snapshot FROM workflow_snapshots '
            'WHERE store = ? AND graph_id = ? ORDER BY suspended_at',
            <Object?>[name, graphId],
            operation: 'listSnapshots',
          );
    return List<WorkflowSnapshot>.unmodifiable(<WorkflowSnapshot>[
      for (final row in rows)
        _decode(row['snapshot'] as String, runId: row['run_id'] as String),
    ]);
  }

  /// Nothing to release: the rows stay on disk and nothing is cached.
  @override
  Future<void> dispose() async {}

  WorkflowSnapshot _decode(String json, {required String runId}) {
    final JsonMap map;
    try {
      map = (jsonDecode(json) as Map).cast<String, Object?>();
    } on FormatException catch (error, stackTrace) {
      throw StorageException(
        'The snapshot for run "$runId" in store "$name" is not valid JSON. '
        'The file is damaged.',
        store: kSqliteStore,
        operation: 'loadSnapshot',
        cause: error,
        causeStackTrace: stackTrace,
        details: <String, Object?>{'store': name, 'runId': runId},
      );
    }
    // Not wrapped: a SerializationException for a newer format already says
    // exactly what to do, and hiding it inside a storage error would not.
    return WorkflowSnapshot.fromJson(map);
  }

  ResultSet _select(
    String sql,
    List<Object?> parameters, {
    required String operation,
  }) {
    try {
      return _database.connection.select(sql, parameters);
    } on SqliteException catch (error, stackTrace) {
      throw wrapSqliteError(error, stackTrace, operation: operation);
    }
  }
}
