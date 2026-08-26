/// An in-process [MemoryStore] with keyword retrieval.
///
/// # Why keyword search is the default and not an afterthought
///
/// Semantic search is the headline feature of every memory system, and it is
/// genuinely worse than keyword matching at the thing memory is most often used
/// for: recalling a specific name, identifier, version number or piece of
/// jargon. Embeddings are good at "similar in meaning" and bad at "contains the
/// token `PROJ-4417`" — and a user asking about PROJ-4417 wants exactly that
/// row.
///
/// So this store ranks by term overlap, weighted by how rare each term is,
/// blended with importance and recency. It needs no model, no network and no
/// vector index, it runs on a phone, and for a few hundred memories it is
/// frequently the better retriever outright.
///
/// `EmbeddedMemoryStore` adds the semantic half, and `HybridMemoryStore`
/// combines them — which beats either alone.
library;

import 'dart:collection';
import 'dart:math' as math;

import 'package:agentic_core/agentic_core.dart';
import 'package:agentic_memory/src/model/memory_entry.dart';
import 'package:agentic_memory/src/store/memory_store.dart';

/// Weights used when blending the components of a relevance score.
///
/// Exposed because the right blend is domain-dependent: a support assistant
/// wants recency to matter, a codebase assistant does not.
typedef MemoryScoreWeights = ({
  double relevance,
  double importance,
  double recency,
});

/// A store that keeps everything in process.
///
/// Bounded, so it cannot grow without limit inside a long-lived app. When full,
/// the lowest-scoring entry is evicted — least important and least recent
/// first, which is a far better policy than dropping the oldest regardless of
/// value.
final class InMemoryMemoryStore implements MemoryStore {
  /// Creates a store.
  ///
  /// [deduplicate] merges an incoming entry into an existing one with identical
  /// normalised content. On by default, because agents re-remember the same
  /// fact constantly and a store full of near-duplicates retrieves worse: the
  /// same statement occupies every one of the few slots recall is allowed.
  InMemoryMemoryStore({
    this.maxEntries = 1000,
    this.halfLife = const Duration(days: 14),
    this.weights = const (relevance: 0.6, importance: 0.25, recency: 0.15),
    this.deduplicate = true,
    Clock clock = const SystemClock(),
  }) : _clock = clock,
       assert(maxEntries > 0, 'maxEntries must be positive');

  /// Maximum entries retained.
  final int maxEntries;

  /// How long it takes a memory's recency contribution to halve.
  ///
  /// Two weeks suits a general assistant. Shorten it for volatile domains and
  /// lengthen it for stable knowledge, where an old fact is no less true.
  final Duration halfLife;

  /// How the score components are blended.
  final MemoryScoreWeights weights;

  /// Whether identical content merges rather than duplicating.
  final bool deduplicate;

  final Clock _clock;
  final LinkedHashMap<String, MemoryEntry> _entries =
      LinkedHashMap<String, MemoryEntry>();

  /// Every stored entry, most recently written last.
  List<MemoryEntry> get entries =>
      List<MemoryEntry>.unmodifiable(_entries.values);

  @override
  Future<void> write(MemoryEntry entry, {AgenticContext? context}) async {
    if (deduplicate) {
      final existing = _findDuplicate(entry);
      if (existing != null) {
        _entries[existing.id] = _merge(existing, entry);
        return;
      }
    }
    _entries[entry.id] = entry;
    _evictIfNeeded();
  }

  @override
  Future<void> writeAll(
    Iterable<MemoryEntry> entries, {
    AgenticContext? context,
  }) async {
    for (final entry in entries) {
      await write(entry, context: context);
    }
  }

  @override
  Future<List<MemoryHit>> search(
    MemoryQuery query, {
    AgenticContext? context,
  }) async {
    context?.throwIfCancelled();
    final now = _clock.now();
    final candidates = _entries.values
        .where((entry) => query.matches(entry, now: now))
        .toList();
    if (candidates.isEmpty) return const <MemoryHit>[];

    final terms = tokeniseForScoring(query.text ?? '');
    final documentFrequency = terms.isEmpty
        ? const <String, int>{}
        : _documentFrequencies(candidates, terms);

    final hits = <MemoryHit>[];
    for (final entry in candidates) {
      final relevance = terms.isEmpty
          ? 0.0
          : _relevanceOf(entry, terms, documentFrequency, candidates.length);

      // A search with terms that match nothing should return nothing, rather
      // than falling back to "the most important entries", which is how a
      // memory system starts confidently recalling irrelevancies.
      if (terms.isNotEmpty && relevance <= 0) continue;

      final recency = _recencyOf(entry, now);
      final score = terms.isEmpty
          // A query with no text is a filtered listing: rank by what matters
          // rather than by a relevance nobody asked for.
          ? weights.importance * entry.importance + weights.recency * recency
          : weights.relevance * relevance +
                weights.importance * entry.importance +
                weights.recency * recency;

      if (score < query.minScore) continue;
      hits.add(
        MemoryHit(
          entry: entry,
          score: score.clamp(0, 1),
          explanation: terms.isEmpty
              ? 'listed by importance and recency'
              : 'matched ${_matchedTerms(entry, terms).join(', ')}',
        ),
      );
    }

    hits.sort((a, b) => b.score.compareTo(a.score));
    return hits.length <= query.limit ? hits : hits.sublist(0, query.limit);
  }

  @override
  Future<MemoryEntry?> read(String id) async => _entries[id];

  @override
  Future<bool> delete(String id) async => _entries.remove(id) != null;

  @override
  Future<int> prune({DateTime? now}) async {
    final at = now ?? _clock.now();
    final expired = _entries.values
        .where((entry) => entry.isExpired(at))
        .map((entry) => entry.id)
        .toList();
    for (final id in expired) {
      _entries.remove(id);
    }
    return expired.length;
  }

  @override
  Future<void> clear() async => _entries.clear();

  @override
  Future<int> count() async => _entries.length;

  @override
  Future<void> dispose() async => _entries.clear();

  // ---------------------------------------------------------------------------
  // Scoring
  // ---------------------------------------------------------------------------

  /// Relevance from term overlap, weighted by term rarity.
  ///
  /// A simplified inverse-document-frequency weighting: a query term that
  /// appears in almost every memory says nothing about which one to return,
  /// while a rare term is close to decisive. Without it, common words dominate
  /// and every query returns the longest entries.
  double _relevanceOf(
    MemoryEntry entry,
    List<String> terms,
    Map<String, int> documentFrequency,
    int totalDocuments,
  ) {
    final entryTerms = tokeniseForScoring(entry.content).toSet();
    if (entryTerms.isEmpty) return 0;

    var matched = 0.0;
    var possible = 0.0;
    for (final term in terms) {
      final frequency = documentFrequency[term] ?? 0;
      // +1 keeps the weight finite when a term appears in every document.
      final weight = math.log((totalDocuments + 1) / (frequency + 1)) + 1;
      possible += weight;
      if (entryTerms.contains(term)) matched += weight;
    }
    if (possible == 0) return 0;

    final overlap = matched / possible;
    // A tag match is a deliberate curatorial signal and worth more than an
    // incidental word match, so it tops the score up rather than averaging in.
    final tagBonus = entry.tags.any(terms.contains) ? 0.15 : 0.0;
    return (overlap + tagBonus).clamp(0.0, 1.0);
  }

  /// Recency as exponential decay, 1.0 now and 0.5 after [halfLife].
  double _recencyOf(MemoryEntry entry, DateTime now) {
    final age = now.difference(entry.lastTouched);
    if (age.isNegative) return 1;
    final halves = age.inMilliseconds / halfLife.inMilliseconds;
    return math.pow(0.5, halves).toDouble();
  }

  Map<String, int> _documentFrequencies(
    List<MemoryEntry> candidates,
    List<String> terms,
  ) {
    final frequencies = <String, int>{};
    for (final entry in candidates) {
      final entryTerms = tokeniseForScoring(entry.content).toSet();
      for (final term in terms) {
        if (entryTerms.contains(term)) {
          frequencies[term] = (frequencies[term] ?? 0) + 1;
        }
      }
    }
    return frequencies;
  }

  List<String> _matchedTerms(MemoryEntry entry, List<String> terms) {
    final entryTerms = tokeniseForScoring(entry.content).toSet();
    return terms.where(entryTerms.contains).take(4).toList();
  }

  MemoryEntry? _findDuplicate(MemoryEntry candidate) {
    final normalised = _normalise(candidate.content);
    for (final entry in _entries.values) {
      if (entry.id == candidate.id) return entry;
      if (_normalise(entry.content) == normalised) return entry;
    }
    return null;
  }

  /// Merges a re-remembered fact into the one already stored.
  ///
  /// Keeps the higher importance and the newer content, and stamps
  /// [MemoryEntry.updatedAt]. A fact reaffirmed twice is more trustworthy than
  /// one written once, and recency scoring should see that.
  MemoryEntry _merge(MemoryEntry existing, MemoryEntry incoming) =>
      existing.copyWith(
        content: incoming.content,
        importance: math.max(existing.importance, incoming.importance),
        updatedAt: _clock.now(),
        expiresAt: incoming.expiresAt,
        embedding: incoming.embedding ?? existing.embedding,
        tags: <String>{...existing.tags, ...incoming.tags},
        metadata: <String, Object?>{...existing.metadata, ...incoming.metadata},
      );

  void _evictIfNeeded() {
    if (_entries.length <= maxEntries) return;
    final now = _clock.now();

    // Expired entries are dead weight; drop those before evicting anything
    // still valid.
    final expired = _entries.values
        .where((entry) => entry.isExpired(now))
        .map((entry) => entry.id)
        .toList();
    for (final id in expired) {
      _entries.remove(id);
    }
    if (_entries.length <= maxEntries) return;

    final ranked = _entries.values.toList()
      ..sort((a, b) {
        final scoreA =
            weights.importance * a.importance +
            weights.recency * _recencyOf(a, now);
        final scoreB =
            weights.importance * b.importance +
            weights.recency * _recencyOf(b, now);
        return scoreA.compareTo(scoreB);
      });

    for (final entry in ranked) {
      if (_entries.length <= maxEntries) break;
      _entries.remove(entry.id);
    }
  }

  static String _normalise(String content) =>
      content.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), ' ').trim();

  @override
  String toString() => 'InMemoryMemoryStore(${_entries.length}/$maxEntries)';
}

/// Words carrying no retrieval signal.
///
/// A deliberately short list. Aggressive stop-word removal destroys short
/// queries — "who is on call" becomes "call" — and memory queries are short.
const Set<String> memoryStopWords = <String>{
  'a',
  'an',
  'and',
  'are',
  'as',
  'at',
  'be',
  'but',
  'by',
  'for',
  'from',
  'has',
  'have',
  'in',
  'is',
  'it',
  'its',
  'of',
  'on',
  'or',
  'that',
  'the',
  'this',
  'to',
  'was',
  'were',
  'will',
  'with',
};

/// Splits [text] into scoring terms.
///
/// Named for what it is for rather than what it does: a bare `tokenise`
/// exported from a framework lands in every application's namespace, and
/// tokenising is something an application may well do its own way.
///
/// Shared by every store so that a term means the same thing whichever one
/// ranks it. Digits are kept: version numbers and ticket identifiers are
/// exactly what keyword search is best at and semantic search is worst at.
List<String> tokeniseForScoring(String text) {
  if (text.isEmpty) return const <String>[];
  return text
      .toLowerCase()
      .split(RegExp(r'[^a-z0-9]+'))
      .where((term) => term.length >= 2 && !memoryStopWords.contains(term))
      .toList();
}
