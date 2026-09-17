/// One SQLite file, and the stores that live in it.
///
/// # Why one database object and not one file per store
///
/// A phone app wants a single file: one thing to back up, one thing to delete
/// on sign-out, one set of file handles. Collections inside it are namespaced
/// by name, so a notes index and an assistant's memory share the file without
/// sharing rows.
///
/// # Why synchronous SQLite behind an asynchronous API
///
/// `package:sqlite3` is synchronous and runs on the calling isolate. Every
/// method here still returns a `Future`, so that moving the work onto a
/// background isolate later is an implementation change rather than a breaking
/// one. Until then the honest cost is stated: a bulk write blocks the isolate
/// for as long as SQLite takes, which for a few hundred records is well inside
/// a frame and for tens of thousands is not.
library;

import 'dart:io';

import 'package:agentic_agents/agentic_agents.dart';
import 'package:agentic_core/agentic_core.dart';
import 'package:agentic_memory/agentic_memory.dart';
import 'package:agentic_sqlite/src/sqlite_memory_store.dart';
import 'package:agentic_sqlite/src/sqlite_session_store.dart';
import 'package:agentic_sqlite/src/sqlite_snapshot_store.dart';
import 'package:agentic_sqlite/src/sqlite_vector_store.dart';
import 'package:agentic_vector/agentic_vector.dart';
import 'package:agentic_workflow/agentic_workflow.dart';
import 'package:meta/meta.dart';
import 'package:sqlite3/sqlite3.dart';

/// The adapter identifier carried on errors and store info.
const String kSqliteStore = 'sqlite';

/// A SQLite database holding framework stores.
final class AgenticDatabase {
  AgenticDatabase._(this._db, {required this.path});

  /// Opens, or creates, the database file at [path].
  ///
  /// In a Flutter app the path should come from `path_provider`'s
  /// `getApplicationSupportDirectory()` — not the documents directory, which
  /// iOS exposes to the user and syncs to iCloud.
  static Future<AgenticDatabase> open(String path) async {
    final file = File(path);
    if (!file.parent.existsSync()) {
      file.parent.createSync(recursive: true);
    }
    return _prepare(() => sqlite3.open(path), path: path, operation: 'open');
  }

  /// An in-memory database, gone when disposed.
  ///
  /// For tests, and for the moment before a user has consented to anything
  /// being written to disk.
  static Future<AgenticDatabase> inMemory() async =>
      _prepare(sqlite3.openInMemory, path: ':memory:', operation: 'open');

  static AgenticDatabase _prepare(
    Database Function() opener, {
    required String path,
    required String operation,
  }) {
    final Database db;
    try {
      db = opener();
    } on SqliteException catch (error, stackTrace) {
      throw wrapSqliteError(error, stackTrace, operation: operation);
    }
    final database = AgenticDatabase._(db, path: path);
    try {
      database
        .._configure()
        .._migrate();
    } on Object {
      db.close();
      rethrow;
    }
    return database;
  }

  final Database _db;

  /// Where the file is, or `:memory:`.
  final String path;

  final Set<String> _openCollections = <String>{};
  bool _disposed = false;

  /// The schema version this build of the package writes.
  ///
  /// Stored in SQLite's `user_version`. A file written by a *newer* version is
  /// refused rather than read, because reading a schema you do not understand
  /// is how an upgrade followed by a downgrade silently corrupts somebody's
  /// notes.
  static const int schemaVersion = 2;

  /// Opens the vector collection [name], creating it if needed.
  ///
  /// Every record in the collection is loaded into memory, so search costs
  /// what `InMemoryVectorStore` costs: exact and fast to a few tens of
  /// thousands of vectors. Loading 10,000 768-dimensional vectors reads about
  /// 30 MB, once.
  ///
  /// [dimensions] and [metric] are recorded on first open. Opening an existing
  /// collection with different values throws, because vectors of one size
  /// scored with another metric are not a slower search — they are a wrong one.
  Future<SqliteVectorStore> vectorStore({
    required String name,
    required int dimensions,
    SimilarityMetric metric = SimilarityMetric.cosine,
  }) async {
    _claim('vector:$name');
    try {
      return await SqliteVectorStore.load(
        database: this,
        name: name,
        dimensions: dimensions,
        metric: metric,
      );
    } on Object {
      _release('vector:$name');
      rethrow;
    }
  }

  /// Opens the memory store [name], creating it if needed.
  ///
  /// The options are those of `InMemoryMemoryStore`, which does the ranking;
  /// this store makes its contents durable, including its evictions.
  Future<SqliteMemoryStore> memoryStore({
    required String name,
    int maxEntries = 1000,
    Duration halfLife = const Duration(days: 14),
    MemoryScoreWeights weights = const (
      relevance: 0.6,
      importance: 0.25,
      recency: 0.15,
    ),
    bool deduplicate = true,
    Clock clock = const SystemClock(),
  }) async {
    _claim('memory:$name');
    try {
      return await SqliteMemoryStore.load(
        database: this,
        name: name,
        inner: InMemoryMemoryStore(
          maxEntries: maxEntries,
          halfLife: halfLife,
          weights: weights,
          deduplicate: deduplicate,
          clock: clock,
        ),
      );
    } on Object {
      _release('memory:$name');
      rethrow;
    }
  }

  /// Opens the conversation store [name].
  ///
  /// Unlike the vector and memory stores this holds nothing in memory, so it
  /// may be opened more than once: every instance reads the same rows.
  /// [clock] stamps each save, and is what orders the conversation list.
  SessionStore sessionStore({
    String name = 'default',
    Clock clock = const SystemClock(),
  }) {
    connection; // Fails now if disposed, rather than on the first save.
    return SqliteSessionStore(database: this, name: name, clock: clock);
  }

  /// Opens the store for suspended workflow runs named [name].
  ///
  /// Holds nothing in memory, so it may be opened more than once.
  WorkflowSnapshotStore snapshotStore({String name = 'default'}) {
    connection;
    return SqliteWorkflowSnapshotStore(database: this, name: name);
  }

  /// Closes the file. Stores opened from it must not be used afterwards.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _openCollections.clear();
    _db.close();
  }

  /// The raw connection, for the stores in this package.
  @internal
  Database get connection {
    if (_disposed) {
      throw InvalidStateException(
        'The database at $path has been disposed.',
        currentState: 'disposed',
        expectedState: 'open',
      );
    }
    return _db;
  }

  /// Runs [body] in a transaction, rolling back if it throws.
  @internal
  T transaction<T>(T Function(Database db) body, {required String operation}) {
    final db = connection..execute('BEGIN IMMEDIATE');
    try {
      final result = body(db);
      db.execute('COMMIT');
      return result;
    } on SqliteException catch (error, stackTrace) {
      db.execute('ROLLBACK');
      throw wrapSqliteError(error, stackTrace, operation: operation);
    } on Object {
      db.execute('ROLLBACK');
      rethrow;
    }
  }

  /// Releases a collection name when its store is disposed.
  @internal
  void release(String key) => _release(key);

  /// A collection may be open once at a time.
  ///
  /// Two stores over the same rows would each hold their own in-memory copy,
  /// and the second write would quietly make the first store's searches stale.
  void _claim(String key) {
    connection; // Fails first if disposed, which is the more useful error.
    if (!_openCollections.add(key)) {
      throw InvalidStateException(
        'The collection "$key" is already open on this database. Share the '
        'store you already have: two stores over the same rows would each '
        'keep their own copy in memory and drift apart on the first write.',
        currentState: 'open',
        expectedState: 'closed',
      );
    }
  }

  void _release(String key) => _openCollections.remove(key);

  void _configure() {
    // WAL lets reads continue during a write and survives a crash mid-write
    // far better than the default rollback journal. Foreign keys are off by
    // default in SQLite for historical reasons, and nothing here relies on
    // them, but a future schema would silently lose them without this.
    _db
      ..execute('PRAGMA journal_mode = WAL')
      ..execute('PRAGMA foreign_keys = ON')
      ..execute('PRAGMA synchronous = NORMAL');
  }

  void _migrate() {
    final current = _db.userVersion;
    if (current > schemaVersion) {
      throw StorageException(
        'The database at $path was written by a newer version of '
        'agentic_sqlite (schema $current; this build understands up to '
        '$schemaVersion). Upgrade the package rather than reading it: a '
        'schema this build does not know could be corrupted by writing to it.',
        store: kSqliteStore,
        operation: 'migrate',
      );
    }
    if (current == schemaVersion) return;

    transaction((db) {
      if (current < 1) {
        db
          ..execute('''
            CREATE TABLE vector_collections (
              name TEXT PRIMARY KEY,
              dimensions INTEGER NOT NULL,
              metric TEXT NOT NULL
            )''')
          ..execute('''
            CREATE TABLE vectors (
              collection TEXT NOT NULL,
              namespace TEXT NOT NULL,
              id TEXT NOT NULL,
              vector BLOB NOT NULL,
              metadata TEXT NOT NULL,
              text TEXT,
              PRIMARY KEY (collection, namespace, id)
            ) WITHOUT ROWID''')
          ..execute('''
            CREATE TABLE memories (
              store TEXT NOT NULL,
              id TEXT NOT NULL,
              entry TEXT NOT NULL,
              seq INTEGER NOT NULL,
              PRIMARY KEY (store, id)
            ) WITHOUT ROWID''');
      }
      if (current < 2) {
        // Neither table holds an in-memory copy: both are read from disk on
        // every call, which is why their stores need no open-once claim.
        db
          ..execute('''
            CREATE TABLE sessions (
              store TEXT NOT NULL,
              id TEXT NOT NULL,
              session TEXT NOT NULL,
              updated_at INTEGER NOT NULL,
              message_count INTEGER NOT NULL,
              metadata TEXT NOT NULL,
              PRIMARY KEY (store, id)
            ) WITHOUT ROWID''')
          ..execute(
            'CREATE INDEX sessions_by_update ON sessions (store, updated_at)',
          )
          ..execute('''
            CREATE TABLE workflow_snapshots (
              store TEXT NOT NULL,
              run_id TEXT NOT NULL,
              graph_id TEXT NOT NULL,
              suspended_at INTEGER NOT NULL,
              snapshot TEXT NOT NULL,
              PRIMARY KEY (store, run_id)
            ) WITHOUT ROWID''')
          ..execute(
            'CREATE INDEX workflow_snapshots_by_wait '
            'ON workflow_snapshots (store, graph_id, suspended_at)',
          );
      }
      // Later schema versions append a block here, each guarded by
      // `current < n`, so a file several versions old migrates step by step.
      db.userVersion = schemaVersion;
    }, operation: 'migrate');
  }
}

/// Turns a SQLite failure into a framework error.
///
/// `SQLITE_BUSY` and `SQLITE_LOCKED` are retryable — another connection holds
/// the file and will let go. Everything else is not: a constraint violation or
/// a corrupt file does not improve by being tried again.
@internal
StorageException wrapSqliteError(
  SqliteException error,
  StackTrace stackTrace, {
  required String operation,
}) {
  final primary = error.extendedResultCode & 0xff;
  return StorageException(
    'SQLite $operation failed: ${error.message}',
    store: kSqliteStore,
    operation: operation,
    retryable: primary == 5 || primary == 6,
    cause: error,
    causeStackTrace: stackTrace,
    details: <String, Object?>{'sqliteCode': error.extendedResultCode},
  );
}
