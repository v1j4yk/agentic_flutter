/// The memory port.
///
/// One interface covers every memory type the framework talks about, because
/// they differ in *scope and retention*, not in mechanics:
///
/// | Type | How it is expressed |
/// |---|---|
/// | Working | `sessionId` set, short `expiresAt` |
/// | Conversation | `MemoryKind.summary`, scoped to a session |
/// | Long-term | no session, no expiry, high importance |
/// | Semantic | any of the above, retrieved by embedding |
/// | Shared | no session, tagged by team |
///
/// Modelling them as five separate interfaces would mean five implementations
/// per backend and five migrations per schema change, to express what is really
/// a filter.
library;

import 'package:agentic_core/agentic_core.dart';
import 'package:agentic_memory/src/model/memory_entry.dart';

/// Stores and retrieves what an agent remembers.
///
/// Implement this to persist memory in SQLite, Hive, Isar or a remote service.
/// Implementations must:
///
/// * treat [write] as an upsert on [MemoryEntry.id];
/// * apply every filter in [MemoryQuery.matches] before ranking;
/// * return hits ordered by descending [MemoryHit.score];
/// * never return more than [MemoryQuery.limit] hits.
abstract interface class MemoryStore implements Disposable {
  /// Writes or replaces an entry.
  Future<void> write(MemoryEntry entry, {AgenticContext? context});

  /// Writes several entries.
  ///
  /// Separate from [write] because a batch is meaningfully cheaper for a
  /// backend that embeds or hits a network: one round trip rather than N.
  Future<void> writeAll(
    Iterable<MemoryEntry> entries, {
    AgenticContext? context,
  });

  /// Retrieves the entries most relevant to [query].
  Future<List<MemoryHit>> search(MemoryQuery query, {AgenticContext? context});

  /// Returns the entry with [id], or `null`.
  Future<MemoryEntry?> read(String id);

  /// Removes the entry with [id], returning whether anything was removed.
  Future<bool> delete(String id);

  /// Drops expired entries, returning how many were removed.
  ///
  /// Forgetting is a feature. A store that only accumulates gets slower, more
  /// expensive and *less* accurate, because stale facts compete with current
  /// ones for the model's attention.
  Future<int> prune({DateTime? now});

  /// Removes everything.
  Future<void> clear();

  /// How many entries are stored.
  Future<int> count();
}

/// Conveniences available on every [MemoryStore].
///
/// Extensions rather than interface members, so adding one never breaks a
/// third-party store.
extension MemoryStoreOperations on MemoryStore {
  /// Writes [content] as a new entry, generating the identifier and timestamp.
  ///
  /// The call most application code wants. Write [content] as a **self-contained
  /// statement**: "The billing service uses Dart 3.11", not "it uses 3.11".
  Future<MemoryEntry> remember(
    String content, {
    MemoryKind kind = MemoryKind.fact,
    double importance = 0.5,
    String? sessionId,
    String? agentName,
    Duration? ttl,
    Set<String> tags = const <String>{},
    Map<String, Object?> metadata = const <String, Object?>{},
    AgenticContext? context,
  }) async {
    final clock = context?.clock ?? const SystemClock();
    final now = clock.now();
    final entry = MemoryEntry(
      id: (context?.ids ?? Ulid()).prefixed('mem'),
      content: content,
      createdAt: now,
      kind: kind,
      importance: importance,
      expiresAt: ttl == null ? null : now.add(ttl),
      sessionId: sessionId,
      agentName: agentName,
      sourceRunId: context?.runId,
      tags: tags,
      metadata: metadata,
    );
    await write(entry, context: context);
    return entry;
  }

  /// Searches with a plain query string.
  Future<List<MemoryHit>> recall(
    String text, {
    int limit = 8,
    Set<MemoryKind> kinds = const <MemoryKind>{},
    String? sessionId,
    double minScore = 0,
    AgenticContext? context,
  }) => search(
    MemoryQuery(
      text: text,
      limit: limit,
      kinds: kinds,
      sessionId: sessionId,
      minScore: minScore,
    ),
    context: context,
  );

  /// Removes every entry belonging to [sessionId].
  ///
  /// What to call when a conversation ends and its working memory should not
  /// leak into the next one.
  Future<int> forgetSession(String sessionId) async {
    final hits = await search(
      MemoryQuery(sessionId: sessionId, limit: 1000, includeExpired: true),
    );
    var removed = 0;
    for (final hit in hits) {
      if (await delete(hit.entry.id)) removed++;
    }
    return removed;
  }

  /// Renders recalled entries as a message to prepend to a conversation.
  ///
  /// Returns `null` when nothing was recalled, so a caller can omit the message
  /// entirely rather than sending an empty "here is what I remember" block —
  /// which reads to the model as "you remember nothing relevant" and measurably
  /// changes its answers.
  Future<Message?> recallAsMessage(
    MemoryQuery query, {
    String heading = 'Relevant things you remember about this user or project:',
    AgenticContext? context,
  }) async {
    final hits = await search(query, context: context);
    if (hits.isEmpty) return null;
    final buffer = StringBuffer(heading);
    for (final hit in hits) {
      buffer.write('\n- ${hit.entry.content}');
    }
    buffer.write(
      '\n\nUse these only where they are relevant. They may be out of date; '
      'prefer what the user says now.',
    );
    return Message.system(buffer.toString());
  }
}

/// A [MemoryStore] that remembers nothing.
///
/// The default where memory is optional, so a component can be wired with a
/// store unconditionally and cost nothing when the host has not configured one.
final class NoopMemoryStore implements MemoryStore {
  /// Creates the no-op store.
  const NoopMemoryStore();

  @override
  Future<void> write(MemoryEntry entry, {AgenticContext? context}) async {}

  @override
  Future<void> writeAll(
    Iterable<MemoryEntry> entries, {
    AgenticContext? context,
  }) async {}

  @override
  Future<List<MemoryHit>> search(
    MemoryQuery query, {
    AgenticContext? context,
  }) async => const <MemoryHit>[];

  @override
  Future<MemoryEntry?> read(String id) async => null;

  @override
  Future<bool> delete(String id) async => false;

  @override
  Future<int> prune({DateTime? now}) async => 0;

  @override
  Future<void> clear() async {}

  @override
  Future<int> count() async => 0;

  @override
  Future<void> dispose() async {}
}
