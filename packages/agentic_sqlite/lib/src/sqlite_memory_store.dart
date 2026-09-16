/// A memory store that survives a restart.
///
/// # Why this reconciles instead of mirroring each call
///
/// `InMemoryMemoryStore` is not a passive map. A write can *merge* into an
/// existing entry when the content matches, and can *evict* others when the
/// store is full. Mirroring the call — "write this entry to disk" — would leave
/// both the merged-away duplicate and every evicted entry on disk, and the next
/// restart would bring back memories the assistant had deliberately let go.
///
/// So every mutation is applied to the in-memory store first, and then the
/// difference between its contents before and after is what gets written:
/// entries that are new or changed are stored, entries that disappeared are
/// deleted. The disk always holds exactly what search can see.
///
/// # When the write fails
///
/// Memory is rolled back to its state before the call, and the error is
/// rethrown. Memory and disk never disagree, even across a failure.
library;

import 'dart:convert';

import 'package:agentic_core/agentic_core.dart';
import 'package:agentic_memory/agentic_memory.dart';
import 'package:agentic_sqlite/src/database.dart';
import 'package:meta/meta.dart';
import 'package:sqlite3/sqlite3.dart';

/// A durable [MemoryStore] in an [AgenticDatabase].
final class SqliteMemoryStore implements MemoryStore {
  SqliteMemoryStore._({
    required AgenticDatabase database,
    required this.name,
    required InMemoryMemoryStore inner,
  }) : _database = database,
       _inner = inner;

  /// Opens memory store [name] and loads its entries into [inner].
  @internal
  static Future<SqliteMemoryStore> load({
    required AgenticDatabase database,
    required String name,
    required InMemoryMemoryStore inner,
  }) async {
    final store = SqliteMemoryStore._(
      database: database,
      name: name,
      inner: inner,
    );
    await store._hydrate();
    return store;
  }

  final AgenticDatabase _database;
  final InMemoryMemoryStore _inner;
  int _nextSeq = 0;
  bool _disposed = false;

  /// The store's name within the database.
  final String name;

  /// Every stored entry, most recently written last.
  List<MemoryEntry> get entries {
    _checkOpen();
    return _inner.entries;
  }

  Future<void> _hydrate() async {
    final ResultSet rows;
    try {
      rows = _database.connection.select(
        'SELECT id, entry, seq FROM memories WHERE store = ? ORDER BY seq',
        <Object?>[name],
      );
    } on SqliteException catch (error, stackTrace) {
      throw wrapSqliteError(error, stackTrace, operation: 'load');
    }

    final loaded = <MemoryEntry>[];
    for (final row in rows) {
      final id = row['id'] as String;
      try {
        loaded.add(
          MemoryEntry.fromJson(
            (jsonDecode(row['entry'] as String) as Map).cast<String, Object?>(),
          ),
        );
      } on Object catch (error, stackTrace) {
        // Reported rather than skipped, for the same reason the vector store
        // does: a memory that silently fails to load is one the assistant
        // behaves as if it never had.
        throw StorageException(
          'The memory "$id" in store "$name" could not be read. The file is '
          'damaged, or was written by an incompatible version.',
          store: kSqliteStore,
          operation: 'load',
          cause: error,
          causeStackTrace: stackTrace,
          details: <String, Object?>{'store': name, 'id': id},
        );
      }
      _nextSeq = (row['seq'] as int) + 1;
    }

    // Loaded through the same reconciliation as any other write. Entries that
    // were distinct when saved stay distinct, but if the store was opened with
    // a smaller `maxEntries` or different deduplication than before, the
    // effect of that change is applied now *and persisted*, instead of
    // resurfacing on every launch.
    await _mutate(
      'load',
      () => _inner.writeAll(loaded),
      // The rows are already on disk. Diffing against them rather than against
      // an empty store means an unchanged file is not rewritten on every
      // launch — only what the options changed is.
      baseline: <String, MemoryEntry>{
        for (final entry in loaded) entry.id: entry,
      },
    );
  }

  @override
  Future<void> write(MemoryEntry entry, {AgenticContext? context}) =>
      _mutate('write', () => _inner.write(entry, context: context));

  @override
  Future<void> writeAll(
    Iterable<MemoryEntry> entries, {
    AgenticContext? context,
  }) => _mutate('writeAll', () => _inner.writeAll(entries, context: context));

  @override
  Future<List<MemoryHit>> search(MemoryQuery query, {AgenticContext? context}) {
    _checkOpen();
    return _inner.search(query, context: context);
  }

  @override
  Future<MemoryEntry?> read(String id) {
    _checkOpen();
    return _inner.read(id);
  }

  @override
  Future<bool> delete(String id) => _mutate('delete', () => _inner.delete(id));

  @override
  Future<int> prune({DateTime? now}) =>
      _mutate('prune', () => _inner.prune(now: now));

  @override
  Future<void> clear() => _mutate('clear', _inner.clear);

  @override
  Future<int> count() {
    _checkOpen();
    return _inner.count();
  }

  /// Releases the in-memory copy. The entries stay on disk.
  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _database.release('memory:$name');
    await _inner.dispose();
  }

  /// Applies [change] in memory, then persists exactly what it changed.
  Future<T> _mutate<T>(
    String operation,
    Future<T> Function() change, {
    Map<String, MemoryEntry>? baseline,
  }) async {
    _checkOpen();
    final before =
        baseline ??
        <String, MemoryEntry>{
          for (final entry in _inner.entries) entry.id: entry,
        };
    final restoreTo = _inner.entries;

    final result = await change();

    final present = <String>{};
    final changed = <MemoryEntry>[];
    for (final entry in _inner.entries) {
      present.add(entry.id);
      // Entries are immutable, so "changed" is "a different instance". A merge
      // produces a new instance through `copyWith`; an untouched entry is the
      // very same object, and costs nothing to skip.
      if (!identical(before[entry.id], entry)) changed.add(entry);
    }
    final removed = <String>[
      for (final id in before.keys)
        if (!present.contains(id)) id,
    ];
    if (changed.isEmpty && removed.isEmpty) return result;

    try {
      _database.transaction((db) {
        final upsert = db.prepare(
          // An existing row keeps its `seq`: a merged entry stays where it was
          // in write order, as it does in the in-memory store's map.
          'INSERT INTO memories (store, id, entry, seq) VALUES (?, ?, ?, ?) '
          'ON CONFLICT (store, id) DO UPDATE SET entry = excluded.entry',
        );
        final remove = db.prepare(
          'DELETE FROM memories WHERE store = ? AND id = ?',
        );
        try {
          var seq = _nextSeq;
          for (final entry in changed) {
            upsert.execute(<Object?>[
              name,
              entry.id,
              jsonEncode(entry.toJson()),
              seq++,
            ]);
          }
          for (final id in removed) {
            remove.execute(<Object?>[name, id]);
          }
          _nextSeq = seq;
        } finally {
          upsert.close();
          remove.close();
        }
      }, operation: operation);
    } on Object {
      await _restore(restoreTo);
      rethrow;
    }
    return result;
  }

  /// Puts the in-memory store back to [entries], in their original order.
  ///
  /// Safe to replay through `write`: these entries coexisted a moment ago, so
  /// none is a duplicate of another and there are no more of them than the
  /// store allows — neither merging nor eviction can alter them on the way in.
  Future<void> _restore(Iterable<MemoryEntry> entries) async {
    await _inner.clear();
    for (final entry in entries) {
      await _inner.write(entry);
    }
  }

  void _checkOpen() {
    if (_disposed) {
      throw InvalidStateException(
        'The memory store "$name" has been disposed.',
        currentState: 'disposed',
        expectedState: 'open',
      );
    }
  }
}
