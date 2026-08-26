/// What an agent remembers.
///
/// # Why memory is not just a longer transcript
///
/// The obvious approach — keep every message and send them all — fails on three
/// counts at once. It exceeds the context window, it costs money on every turn
/// in proportion to the conversation's whole history, and it *degrades quality*:
/// a model given forty turns of scrollback attends worse to the one sentence
/// that mattered than a model given three relevant facts.
///
/// So a memory is not a message. It is a distilled, addressable, scored piece of
/// knowledge that outlives the turn it came from — and can be retrieved when it
/// is relevant rather than replayed because it is recent.
library;

import 'package:agentic_core/agentic_core.dart';
import 'package:meta/meta.dart';

/// What kind of thing is being remembered.
///
/// The kind drives retention and retrieval: a [preference] should outlive the
/// conversation that produced it, while an [observation] usually should not.
/// Storing everything as one undifferentiated blob makes both decisions
/// impossible.
enum MemoryKind {
  /// A durable statement about the world.
  ///
  /// "The project uses Dart 3.11." Long-lived, and wrong once it stops being
  /// true — which is why facts carry [MemoryEntry.updatedAt].
  fact,

  /// Something the user wants.
  ///
  /// "Prefers concise answers." The highest-value kind: preferences are cheap
  /// to store, rarely change, and improve every subsequent turn.
  preference,

  /// Something that happened.
  ///
  /// "Deployed version 2.1 on Tuesday." Time-bound, and worth expiring.
  event,

  /// A condensed account of a longer exchange.
  ///
  /// What a summarising history strategy writes when it drops the middle of a
  /// conversation.
  summary,

  /// Something to be done.
  task,

  /// A transient note held for the current task only.
  ///
  /// Working memory: a scratchpad an agent uses within a run and should not
  /// carry into the next one.
  observation,
}

/// One remembered item.
@immutable
final class MemoryEntry {
  /// Creates an entry.
  ///
  /// [content] should be a **self-contained statement**. "It uses 3.11" is
  /// useless when recalled six conversations later; "The billing service uses
  /// Dart 3.11" survives. This is the single most important thing to get right
  /// about a memory system, and no amount of retrieval quality compensates for
  /// getting it wrong.
  MemoryEntry({
    required this.id,
    required this.content,
    required this.createdAt,
    this.kind = MemoryKind.fact,
    this.importance = 0.5,
    this.updatedAt,
    this.expiresAt,
    this.sessionId,
    this.agentName,
    this.sourceRunId,
    List<double>? embedding,
    Set<String> tags = const <String>{},
    Map<String, Object?> metadata = const <String, Object?>{},
  }) : embedding = embedding == null
           ? null
           : List<double>.unmodifiable(embedding),
       tags = Set<String>.unmodifiable(tags),
       metadata = Map<String, Object?>.unmodifiable(metadata),
       assert(
         importance >= 0 && importance <= 1,
         'importance must be between 0 and 1',
       );

  /// Restores an entry from JSON.
  factory MemoryEntry.fromJson(JsonMap json) => MemoryEntry(
    id: json.requireString('id'),
    content: json.requireString('content'),
    createdAt: json.requireDateTime('createdAt'),
    kind: json.enumOr('kind', <String, MemoryKind>{
      for (final kind in MemoryKind.values) kind.name: kind,
    }, MemoryKind.fact),
    importance: json.optionalDouble('importance') ?? 0.5,
    updatedAt: json.optionalDateTime('updatedAt'),
    expiresAt: json.optionalDateTime('expiresAt'),
    sessionId: json.optionalString('sessionId'),
    agentName: json.optionalString('agentName'),
    sourceRunId: json.optionalString('sourceRunId'),
    embedding: json['embedding'] == null
        ? null
        : json
              .requireList('embedding')
              .map((v) => (v! as num).toDouble())
              .toList(),
    tags: json.stringListOrEmpty('tags').toSet(),
    metadata: json.optionalObject('metadata') ?? const <String, Object?>{},
  );

  /// Stable identifier.
  final String id;

  /// The remembered statement, written to stand alone.
  final String content;

  /// What kind of thing this is.
  final MemoryKind kind;

  /// How much this matters, from 0 to 1.
  ///
  /// Retrieval weights by importance, and pruning drops the least important
  /// first. Set it deliberately: marking everything 1.0 is the same as having
  /// no importance at all.
  final double importance;

  /// When the entry was first written, in UTC.
  final DateTime createdAt;

  /// When the entry was last revised.
  ///
  /// A fact that has been reaffirmed is more trustworthy than one written once
  /// and never touched, and recency scoring uses this when present.
  final DateTime? updatedAt;

  /// When the entry stops being valid.
  ///
  /// Forgetting is a feature, not a failure. A memory system that only ever
  /// accumulates gets slower, more expensive and *less* accurate over time, as
  /// stale facts compete with current ones.
  final DateTime? expiresAt;

  /// The conversation this came from, when it belongs to one.
  ///
  /// Working memory is scoped to a session; long-term memory is not.
  final String? sessionId;

  /// The agent that wrote it.
  final String? agentName;

  /// The run that produced it, for tracing a memory back to its origin.
  final String? sourceRunId;

  /// The vector representation, when one has been computed.
  final List<double>? embedding;

  /// Labels for filtering.
  final Set<String> tags;

  /// Application metadata.
  final Map<String, Object?> metadata;

  /// The instant this entry was last known to be current.
  DateTime get lastTouched => updatedAt ?? createdAt;

  /// Whether this entry has expired as of [now].
  bool isExpired(DateTime now) {
    final expiry = expiresAt;
    return expiry != null && !now.isBefore(expiry);
  }

  /// Whether an embedding has been computed.
  bool get hasEmbedding => embedding != null && embedding!.isNotEmpty;

  /// Returns a copy with selected fields replaced.
  MemoryEntry copyWith({
    String? content,
    MemoryKind? kind,
    double? importance,
    DateTime? updatedAt,
    DateTime? expiresAt,
    String? sessionId,
    String? agentName,
    String? sourceRunId,
    List<double>? embedding,
    Set<String>? tags,
    Map<String, Object?>? metadata,
  }) => MemoryEntry(
    id: id,
    content: content ?? this.content,
    createdAt: createdAt,
    kind: kind ?? this.kind,
    importance: importance ?? this.importance,
    updatedAt: updatedAt ?? this.updatedAt,
    expiresAt: expiresAt ?? this.expiresAt,
    sessionId: sessionId ?? this.sessionId,
    agentName: agentName ?? this.agentName,
    sourceRunId: sourceRunId ?? this.sourceRunId,
    embedding: embedding ?? this.embedding,
    tags: tags ?? this.tags,
    metadata: metadata ?? this.metadata,
  );

  /// Serialises the entry.
  JsonMap toJson() => pruneNulls(<String, Object?>{
    'id': id,
    'content': content,
    'kind': kind.name,
    'importance': importance,
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt?.toIso8601String(),
    'expiresAt': expiresAt?.toIso8601String(),
    'sessionId': sessionId,
    'agentName': agentName,
    'sourceRunId': sourceRunId,
    'embedding': embedding,
    'tags': tags.isEmpty ? null : (tags.toList()..sort()),
    'metadata': metadata.isEmpty ? null : metadata,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is MemoryEntry && id == other.id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() {
    final preview = content.length <= 60
        ? content
        : '${content.substring(0, 57)}...';
    return 'MemoryEntry(${kind.name}, $preview)';
  }
}

/// What to recall.
@immutable
final class MemoryQuery {
  /// Creates a query.
  ///
  /// A query with no [text] is a filtered listing rather than a search, ordered
  /// by importance and recency. That is the right shape for "show me everything
  /// you know about this user".
  MemoryQuery({
    this.text,
    this.limit = 8,
    Set<MemoryKind> kinds = const <MemoryKind>{},
    Set<String> tags = const <String>{},
    this.sessionId,
    this.agentName,
    this.minImportance = 0,
    this.minScore = 0,
    this.includeExpired = false,
    List<double>? embedding,
  }) : kinds = Set<MemoryKind>.unmodifiable(kinds),
       tags = Set<String>.unmodifiable(tags),
       embedding = embedding == null
           ? null
           : List<double>.unmodifiable(embedding),
       assert(limit > 0, 'limit must be positive');

  /// Creates a query from a user turn.
  factory MemoryQuery.forMessage(
    Message message, {
    int limit = 8,
    Set<MemoryKind> kinds = const <MemoryKind>{},
    String? sessionId,
  }) => MemoryQuery(
    text: message.text,
    limit: limit,
    kinds: kinds,
    sessionId: sessionId,
  );

  /// What to search for, or `null` to list rather than search.
  final String? text;

  /// Maximum entries to return.
  ///
  /// Keep it small. Recall exists to give the model a *few* relevant facts;
  /// returning thirty recreates the problem memory was meant to solve.
  final int limit;

  /// Restrict to these kinds, or every kind when empty.
  final Set<MemoryKind> kinds;

  /// Restrict to entries carrying any of these tags.
  final Set<String> tags;

  /// Restrict to one conversation.
  final String? sessionId;

  /// Restrict to one agent's memories.
  final String? agentName;

  /// Minimum importance an entry must carry.
  final double minImportance;

  /// Minimum relevance score a hit must reach.
  ///
  /// The guard against the characteristic failure of semantic search: with no
  /// floor, the nearest vectors are returned however far away they are, so an
  /// unrelated question still recalls three confident irrelevancies.
  final double minScore;

  /// Whether to include entries past their expiry.
  final bool includeExpired;

  /// A precomputed query vector, when the caller already has one.
  final List<double>? embedding;

  /// Returns a copy with selected fields replaced.
  MemoryQuery copyWith({
    String? text,
    int? limit,
    Set<MemoryKind>? kinds,
    Set<String>? tags,
    String? sessionId,
    String? agentName,
    double? minImportance,
    double? minScore,
    bool? includeExpired,
    List<double>? embedding,
  }) => MemoryQuery(
    text: text ?? this.text,
    limit: limit ?? this.limit,
    kinds: kinds ?? this.kinds,
    tags: tags ?? this.tags,
    sessionId: sessionId ?? this.sessionId,
    agentName: agentName ?? this.agentName,
    minImportance: minImportance ?? this.minImportance,
    minScore: minScore ?? this.minScore,
    includeExpired: includeExpired ?? this.includeExpired,
    embedding: embedding ?? this.embedding,
  );

  /// Whether [entry] passes this query's filters, ignoring relevance.
  ///
  /// Shared by every store so that filtering means the same thing regardless of
  /// how a store ranks.
  bool matches(MemoryEntry entry, {required DateTime now}) {
    if (!includeExpired && entry.isExpired(now)) return false;
    if (entry.importance < minImportance) return false;
    if (kinds.isNotEmpty && !kinds.contains(entry.kind)) return false;
    if (sessionId != null && entry.sessionId != sessionId) return false;
    if (agentName != null && entry.agentName != agentName) return false;
    if (tags.isNotEmpty && tags.intersection(entry.tags).isEmpty) return false;
    return true;
  }

  /// Serialises the query.
  JsonMap toJson() => pruneNulls(<String, Object?>{
    'text': text,
    'limit': limit,
    'kinds': kinds.isEmpty ? null : kinds.map((k) => k.name).toList(),
    'tags': tags.isEmpty ? null : (tags.toList()..sort()),
    'sessionId': sessionId,
    'agentName': agentName,
    'minImportance': minImportance == 0 ? null : minImportance,
    'minScore': minScore == 0 ? null : minScore,
  });

  @override
  String toString() =>
      'MemoryQuery(${text == null ? 'list' : '"$text"'}, limit: $limit)';
}

/// A retrieved entry and how well it matched.
@immutable
final class MemoryHit {
  /// Creates a hit.
  const MemoryHit({required this.entry, required this.score, this.explanation});

  /// The retrieved entry.
  final MemoryEntry entry;

  /// Relevance, from 0 to 1.
  ///
  /// Comparable *within* one store's results and not across stores, which is
  /// why hybrid retrieval fuses ranks rather than scores.
  final double score;

  /// Why this entry was returned.
  ///
  /// Populated by stores that can explain themselves. Retrieval that cannot be
  /// explained cannot be debugged, and "why did it recall that?" is the most
  /// common question a memory system raises.
  final String? explanation;

  /// Returns a copy with a different [score].
  MemoryHit withScore(double score, {String? explanation}) => MemoryHit(
    entry: entry,
    score: score,
    explanation: explanation ?? this.explanation,
  );

  /// Serialises the hit.
  JsonMap toJson() => pruneNulls(<String, Object?>{
    'entry': entry.toJson(),
    'score': score,
    'explanation': explanation,
  });

  @override
  String toString() =>
      'MemoryHit(${score.toStringAsFixed(3)}, ${entry.content.length} chars)';
}
