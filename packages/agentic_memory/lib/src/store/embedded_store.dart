/// Semantic and hybrid retrieval.
///
/// # What each half is good at
///
/// Keyword retrieval finds the row containing `PROJ-4417`. Semantic retrieval
/// finds the memory about "the deployment blocker" when the user asked about
/// "what is holding up the release". Each is close to useless at the other's
/// job, and a memory system that ships only one of them fails visibly and
/// often.
///
/// [HybridMemoryStore] runs both and fuses the rankings. That is not a
/// compromise between the two; on standard retrieval benchmarks it beats either
/// alone, because the two make uncorrelated mistakes.
library;

import 'dart:math' as math;

import 'package:agentic_core/agentic_core.dart';
import 'package:agentic_llm/agentic_llm.dart';
import 'package:agentic_memory/src/model/memory_entry.dart';
import 'package:agentic_memory/src/store/memory_store.dart';

/// Adds embedding-based retrieval to another store.
///
/// Wraps a store that holds the entries and computes a vector for each on
/// write, then ranks by cosine similarity on search. The inner store still owns
/// storage, so persistence is its problem rather than this decorator's.
///
/// ```dart
/// final store = EmbeddedMemoryStore(
///   InMemoryMemoryStore(),
///   embeddings: OpenAiCompatibleEmbeddingModel.openAi(apiKey: key),
/// );
/// ```
final class EmbeddedMemoryStore implements MemoryStore {
  /// Wraps [inner], embedding entries with [embeddings].
  ///
  /// [minSimilarity] is a floor on cosine similarity, and it matters more than
  /// it looks. Vector search always returns the nearest neighbours however far
  /// away they are, so without a floor an unrelated question still recalls
  /// three confident irrelevancies — the characteristic failure of semantic
  /// memory. 0.25 is a conservative starting point; tune it against your own
  /// data rather than trusting the default.
  EmbeddedMemoryStore(
    this.inner, {
    required this.embeddings,
    this.minSimilarity = 0.25,
    this.embedOnWrite = true,
  });

  /// The store that holds the entries.
  final MemoryStore inner;

  /// The model that turns text into vectors.
  final EmbeddingModel embeddings;

  /// Minimum cosine similarity for a hit to be returned.
  final double minSimilarity;

  /// Whether to compute a vector when an entry is written.
  ///
  /// Turning this off is for backfilling an existing store: entries are stored
  /// unembedded and vectors are computed later in batches, which is far cheaper
  /// than one embedding call per write.
  final bool embedOnWrite;

  @override
  Future<void> write(MemoryEntry entry, {AgenticContext? context}) async {
    if (!embedOnWrite || entry.hasEmbedding) {
      return inner.write(entry, context: context);
    }
    final vector = await embeddings.embedDocument(
      entry.content,
      context: context,
    );
    await inner.write(
      entry.copyWith(embedding: vector.normalised().values),
      context: context,
    );
  }

  @override
  Future<void> writeAll(
    Iterable<MemoryEntry> entries, {
    AgenticContext? context,
  }) async {
    final list = entries.toList();
    if (list.isEmpty) return;
    if (!embedOnWrite) return inner.writeAll(list, context: context);

    // One batched call rather than N. An ingestion run that embeds per entry is
    // the difference between one request and ten thousand.
    final needsEmbedding = <int>[
      for (var i = 0; i < list.length; i++)
        if (!list[i].hasEmbedding) i,
    ];
    if (needsEmbedding.isEmpty) return inner.writeAll(list, context: context);

    final vectors = await embeddings.embedAll(
      <String>[for (final index in needsEmbedding) list[index].content],
      purpose: EmbeddingPurpose.document,
      context: context,
    );
    for (var i = 0; i < needsEmbedding.length; i++) {
      final index = needsEmbedding[i];
      list[index] = list[index].copyWith(
        embedding: vectors[i].normalised().values,
      );
    }
    await inner.writeAll(list, context: context);
  }

  @override
  Future<List<MemoryHit>> search(
    MemoryQuery query, {
    AgenticContext? context,
  }) async {
    final text = query.text;
    if (text == null || text.isEmpty) {
      // Nothing to compare against; a filtered listing is the inner store's job.
      return inner.search(query, context: context);
    }

    context?.throwIfCancelled();
    final queryVector = query.embedding != null
        ? Embedding(values: query.embedding!).normalised()
        // The *query* purpose, not the document one: several embedding models
        // are asymmetric, and using the wrong mode degrades retrieval silently.
        : (await embeddings.embedQuery(text, context: context)).normalised();

    // Pull a wide candidate set from the inner store with filters applied but
    // no text ranking, then rank those by similarity. Letting the inner store
    // rank first would hide exactly the entries semantic search exists to find.
    final candidates = await inner.search(
      query.copyWith(text: '', limit: math.max(query.limit * 20, 100)),
      context: context,
    );

    final hits = <MemoryHit>[];
    for (final candidate in candidates) {
      final entry = candidate.entry;
      if (!entry.hasEmbedding) continue;
      final similarity = queryVector.cosineSimilarity(
        Embedding(values: entry.embedding!),
      );
      if (similarity < minSimilarity || similarity < query.minScore) continue;
      hits.add(
        MemoryHit(
          entry: entry,
          score: similarity.clamp(0, 1),
          explanation: 'semantic similarity ${similarity.toStringAsFixed(3)}',
        ),
      );
    }

    hits.sort((a, b) => b.score.compareTo(a.score));
    return hits.length <= query.limit ? hits : hits.sublist(0, query.limit);
  }

  /// Computes and stores vectors for entries that have none.
  ///
  /// For backfilling a store written with [embedOnWrite] disabled, or after
  /// changing embedding model. Returns how many entries were embedded.
  ///
  /// Changing the model means every existing vector is incomparable with every
  /// new one — the dimensions may even differ — so a re-embedding pass is not
  /// optional after a model switch, it is a migration.
  Future<int> backfill({int batchSize = 64, AgenticContext? context}) async {
    final all = await inner.search(
      MemoryQuery(limit: 100000, includeExpired: true),
      context: context,
    );
    final pending = all
        .map((hit) => hit.entry)
        .where((entry) => !entry.hasEmbedding)
        .toList();
    if (pending.isEmpty) return 0;

    for (var start = 0; start < pending.length; start += batchSize) {
      context?.throwIfCancelled();
      final end = math.min(start + batchSize, pending.length);
      final batch = pending.sublist(start, end);
      final vectors = await embeddings.embedAll(
        batch.map((entry) => entry.content).toList(),
        purpose: EmbeddingPurpose.document,
        context: context,
      );
      await inner.writeAll(<MemoryEntry>[
        for (var i = 0; i < batch.length; i++)
          batch[i].copyWith(embedding: vectors[i].normalised().values),
      ], context: context);
    }
    return pending.length;
  }

  @override
  Future<MemoryEntry?> read(String id) => inner.read(id);

  @override
  Future<bool> delete(String id) => inner.delete(id);

  @override
  Future<int> prune({DateTime? now}) => inner.prune(now: now);

  @override
  Future<void> clear() => inner.clear();

  @override
  Future<int> count() => inner.count();

  @override
  Future<void> dispose() => inner.dispose();

  @override
  String toString() => 'EmbeddedMemoryStore($inner)';
}

/// Fuses the rankings of two stores.
///
/// # Why ranks and not scores
///
/// A keyword score and a cosine similarity are not on the same scale and are
/// not even monotonically related. Averaging them — the obvious approach — lets
/// whichever store happens to produce larger numbers dominate, and the blend
/// silently becomes a single retriever.
///
/// Reciprocal rank fusion sidesteps the problem entirely: it uses only each
/// store's *ordering*, scoring an entry `1 / (k + rank)` in each list and
/// summing. It needs no calibration, no tuning per store, and no assumption
/// that two scores mean the same thing.
final class HybridMemoryStore implements MemoryStore {
  /// Fuses [keyword] and [semantic].
  ///
  /// Writes go to both; a store that only reads from one of them would drift.
  /// Wrap the *same* underlying store in [EmbeddedMemoryStore] to avoid holding
  /// two copies of every entry — see the package README.
  HybridMemoryStore({
    required this.keyword,
    required this.semantic,
    this.rankConstant = 60,
    this.writeToBoth = false,
  }) : assert(rankConstant > 0, 'rankConstant must be positive');

  /// The lexical retriever.
  final MemoryStore keyword;

  /// The semantic retriever.
  final MemoryStore semantic;

  /// The `k` in `1 / (k + rank)`.
  ///
  /// 60 is the value from the original reciprocal-rank-fusion work and is a
  /// sound default. Lower it to let the top of each list dominate more sharply.
  final int rankConstant;

  /// Whether a write goes to both stores.
  ///
  /// Leave this off when both wrap the same underlying store — the usual
  /// arrangement — or every entry is stored twice.
  final bool writeToBoth;

  @override
  Future<void> write(MemoryEntry entry, {AgenticContext? context}) async {
    // The semantic store is written through, because it is the one that
    // computes vectors; the keyword store is normally the same object beneath.
    await semantic.write(entry, context: context);
    if (writeToBoth) await keyword.write(entry, context: context);
  }

  @override
  Future<void> writeAll(
    Iterable<MemoryEntry> entries, {
    AgenticContext? context,
  }) async {
    final list = entries.toList();
    await semantic.writeAll(list, context: context);
    if (writeToBoth) await keyword.writeAll(list, context: context);
  }

  @override
  Future<List<MemoryHit>> search(
    MemoryQuery query, {
    AgenticContext? context,
  }) async {
    context?.throwIfCancelled();
    // Ask each for more than needed: an entry ranked fourth in both lists
    // should beat one ranked first in a single list, and that only shows up
    // with enough depth to fuse.
    final wide = query.copyWith(limit: query.limit * 3, minScore: 0);
    final results = await Future.wait(<Future<List<MemoryHit>>>[
      keyword.search(wide, context: context),
      semantic.search(wide, context: context),
    ]);

    final fused = <String, double>{};
    final byId = <String, MemoryEntry>{};
    final sources = <String, Set<String>>{};

    void absorb(List<MemoryHit> hits, String label) {
      for (var rank = 0; rank < hits.length; rank++) {
        final entry = hits[rank].entry;
        byId[entry.id] = entry;
        fused[entry.id] =
            (fused[entry.id] ?? 0) + 1 / (rankConstant + rank + 1);
        (sources[entry.id] ??= <String>{}).add(label);
      }
    }

    absorb(results[0], 'keyword');
    absorb(results[1], 'semantic');
    if (fused.isEmpty) return const <MemoryHit>[];

    // Normalise so scores stay comparable with the single-store case: the
    // theoretical maximum is being first in both lists.
    final best = 2 / (rankConstant + 1);
    final ranked = fused.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    final hits = <MemoryHit>[];
    for (final entry in ranked) {
      final score = (entry.value / best).clamp(0.0, 1.0);
      if (score < query.minScore) continue;
      hits.add(
        MemoryHit(
          entry: byId[entry.key]!,
          score: score,
          explanation: 'fused from ${sources[entry.key]!.join(' + ')}',
        ),
      );
      if (hits.length >= query.limit) break;
    }
    return hits;
  }

  @override
  Future<MemoryEntry?> read(String id) => semantic.read(id);

  @override
  Future<bool> delete(String id) async {
    final removed = await semantic.delete(id);
    if (writeToBoth) await keyword.delete(id);
    return removed;
  }

  @override
  Future<int> prune({DateTime? now}) async {
    final removed = await semantic.prune(now: now);
    if (writeToBoth) await keyword.prune(now: now);
    return removed;
  }

  @override
  Future<void> clear() async {
    await semantic.clear();
    if (writeToBoth) await keyword.clear();
  }

  @override
  Future<int> count() => semantic.count();

  @override
  Future<void> dispose() async {
    await semantic.dispose();
    if (writeToBoth) await keyword.dispose();
  }

  @override
  String toString() => 'HybridMemoryStore(keyword + semantic)';
}
