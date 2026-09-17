/// Conversations that survive a restart.
library;

import 'dart:convert';

import 'package:agentic_agents/agentic_agents.dart';
import 'package:agentic_core/agentic_core.dart';
import 'package:agentic_sqlite/src/database.dart';
import 'package:meta/meta.dart';
import 'package:sqlite3/sqlite3.dart';

/// A durable [SessionStore] in an [AgenticDatabase].
///
/// Reads go to disk every time; nothing is held in memory. A conversation list
/// is read once per screen, and a conversation once per open, so a cache would
/// add a second copy to keep consistent for no measurable gain.
final class SqliteSessionStore implements SessionStore {
  /// Creates a store over the `sessions` table.
  @internal
  SqliteSessionStore({
    required AgenticDatabase database,
    required this.name,
    Clock clock = const SystemClock(),
  }) : _database = database,
       _clock = clock;

  final AgenticDatabase _database;
  final Clock _clock;

  /// The store's name within the database.
  final String name;

  @override
  Future<void> save(AgentSession session) async {
    _database.transaction((db) {
      db.execute(
        'INSERT INTO sessions '
        '(store, id, session, updated_at, message_count, metadata) '
        'VALUES (?, ?, ?, ?, ?, ?) '
        'ON CONFLICT (store, id) DO UPDATE SET '
        'session = excluded.session, updated_at = excluded.updated_at, '
        'message_count = excluded.message_count, metadata = excluded.metadata',
        <Object?>[
          name,
          session.id,
          jsonEncode(session.toJson()),
          _clock.now().toUtc().microsecondsSinceEpoch,
          session.history.length,
          jsonEncode(session.metadata),
        ],
      );
    }, operation: 'saveSession');
  }

  @override
  Future<AgentSession?> load(String id, {HistoryStrategy? strategy}) async {
    final rows = _select(
      'SELECT session FROM sessions WHERE store = ? AND id = ?',
      <Object?>[name, id],
      operation: 'loadSession',
    );
    if (rows.isEmpty) return null;
    try {
      return AgentSession.fromJson(
        (jsonDecode(rows.first['session'] as String) as Map)
            .cast<String, Object?>(),
        strategy: strategy,
      );
    } on Object catch (error, stackTrace) {
      throw StorageException(
        'The session "$id" in store "$name" could not be read. The file is '
        'damaged, or was written by an incompatible version.',
        store: kSqliteStore,
        operation: 'loadSession',
        cause: error,
        causeStackTrace: stackTrace,
        details: <String, Object?>{'store': name, 'id': id},
      );
    }
  }

  @override
  Future<bool> delete(String id) async {
    var removed = false;
    _database.transaction((db) {
      db.execute('DELETE FROM sessions WHERE store = ? AND id = ?', <Object?>[
        name,
        id,
      ]);
      removed = db.updatedRows > 0;
    }, operation: 'deleteSession');
    return removed;
  }

  @override
  Future<List<SessionSummary>> list() async {
    final rows = _select(
      'SELECT id, updated_at, message_count, metadata FROM sessions '
      'WHERE store = ? ORDER BY updated_at DESC',
      <Object?>[name],
      operation: 'listSessions',
    );
    return List<SessionSummary>.unmodifiable(<SessionSummary>[
      for (final row in rows)
        SessionSummary(
          id: row['id'] as String,
          updatedAt: DateTime.fromMicrosecondsSinceEpoch(
            row['updated_at'] as int,
            isUtc: true,
          ),
          messageCount: row['message_count'] as int,
          metadata: Map<String, Object?>.unmodifiable(
            (jsonDecode(row['metadata'] as String) as Map)
                .cast<String, Object?>(),
          ),
        ),
    ]);
  }

  /// Nothing to release: the rows stay on disk and nothing is cached.
  @override
  Future<void> dispose() async {}

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
