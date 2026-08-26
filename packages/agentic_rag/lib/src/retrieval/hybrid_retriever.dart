/// Fusing several retrievers into one ranking.
library;

import 'dart:async';

import 'package:agentic_core/agentic_core.dart';
import 'package:agentic_rag/src/model/document.dart';
import 'package:agentic_rag/src/retrieval/retriever.dart';

/// Runs several retrievers and fuses their rankings.
///
/// # Why ranks, not scores
///
/// A cosine similarity of 0.71 and a BM25 score of 8.4 describe the same
/// passage on scales that have nothing to do with each other. Adding them,
/// averaging them, or normalising them into a shared range all require pinning
/// down what "good" means for each retriever — which changes with the corpus,
/// the model and the query.
///
/// Reciprocal rank fusion sidesteps the problem entirely by throwing the scores
/// away and keeping only the ordering: a passage's contribution from each
/// retriever is `1 / (k + rank)`. A passage ranked first by one retriever and
/// fifteenth by another still places well; a passage both rank highly wins. It
/// needs no tuning, no training and no normalisation, and it reliably beats
/// either input ranking alone.
///
/// # Weights
///
/// [weights] scale each retriever's contribution when one is known to be better
/// for a corpus. The default — equal weight — is the right starting point;
/// reach for weights only with a measurement.
///
/// ```dart
/// final retriever = HybridRetriever(
///   retrievers: [vectorRetriever, keywordRetriever],
///   weights: {'keyword': 0.7}, // dense retrieval leads on this corpus
/// );
/// ```
final class HybridRetriever implements Retriever {
  /// Fuses [retrievers].
  HybridRetriever({
    required this.retrievers,
    this.name = 'hybrid',
    this.k = 60,
    Map<String, double> weights = const <String, double>{},
    this.candidateMultiplier = 3,
  }) : weights = Map<String, double>.unmodifiable(weights),
       assert(retrievers.isNotEmpty, 'a hybrid needs something to fuse'),
       assert(k > 0, 'k must be positive'),
       assert(
         candidateMultiplier >= 1,
         'candidateMultiplier must be at least 1',
       );

  /// The retrievers to run.
  final List<Retriever> retrievers;

  @override
  final String name;

  /// The fusion constant.
  ///
  /// Sixty, from the paper that introduced the technique and the value nearly
  /// every implementation uses. It damps the difference between the top few
  /// ranks, which is what stops one retriever's first result from dominating a
  /// fusion it is only marginally more confident about.
  final int k;

  /// Per-retriever multipliers, keyed by [Retriever.name].
  final Map<String, double> weights;

  /// How many extra candidates each retriever is asked for.
  ///
  /// Fusion needs depth to work with: asking each retriever for exactly `topK`
  /// means a passage ranked seventh by one and first by the other is invisible
  /// to the fusion that would have promoted it.
  final int candidateMultiplier;

  @override
  Future<List<RetrievedChunk>> retrieve(
    RetrievalRequest request, {
    AgenticContext? context,
  }) async {
    // Retrievers hit independent backends — one embeds and queries a store, the
    // other scans an in-process index — so running them concurrently costs the
    // slower of the two rather than the sum.
    final candidateRequest = request.copyWith(
      topK: request.topK * candidateMultiplier,
      // The floor is applied to the fused ranking, not to the inputs: a passage
      // just under one retriever's threshold may be the top hit of the other.
      minScore: 0,
    );
    final rankings = await Future.wait(<Future<List<RetrievedChunk>>>[
      for (final retriever in retrievers)
        retriever.retrieve(candidateRequest, context: context),
    ]);

    final fused = <String, double>{};
    final byId = <String, RetrievedChunk>{};
    final contributors = <String, Set<String>>{};

    for (var i = 0; i < rankings.length; i++) {
      final retriever = retrievers[i];
      final weight = weights[retriever.name] ?? 1.0;
      final ranking = rankings[i];
      for (var rank = 0; rank < ranking.length; rank++) {
        final result = ranking[rank];
        fused[result.id] = (fused[result.id] ?? 0) + weight / (k + rank + 1);
        byId.putIfAbsent(result.id, () => result);
        contributors
            .putIfAbsent(result.id, () => <String>{})
            .add(retriever.name);
      }
    }

    final results = <RetrievedChunk>[
      for (final entry in fused.entries)
        byId[entry.key]!.copyWith(
          score: entry.value,
          // Attribution names every retriever that found it, which is what
          // makes "why did this come back?" answerable from a trace.
          retriever: contributors[entry.key]!.join('+'),
        ),
    ];
    return finalise(results, request);
  }

  @override
  String toString() =>
      'HybridRetriever(${retrievers.map((r) => r.name).join(' + ')})';
}

/// Adds context around whatever another retriever found.
///
/// # The neighbour problem
///
/// Chunking cuts a document into pieces that rank well on their own. That is
/// the goal, and it has a cost: the piece that matched frequently ends
/// mid-explanation, and the sentence that completes it is the first line of the
/// next chunk.
///
/// This decorator pulls the neighbours of each hit back in — chunk 6 and 8 when
/// 7 matched — and returns them in document order. It is the cheapest quality
/// improvement available to a RAG pipeline: no extra model call, no extra
/// embedding, just a lookup by identifier.
///
/// Neighbours are appended after the ranked hits and never displace them, so a
/// [RetrievalRequest.topK] of six means six *retrieved* passages plus their
/// context rather than six passages in total.
final class NeighbourExpandingRetriever implements Retriever {
  /// Expands what [inner] finds using [lookup].
  ///
  /// [lookup] resolves a chunk identifier to a chunk; an in-process index, a
  /// database, or the vector store's own `get`.
  const NeighbourExpandingRetriever({
    required this.inner,
    required this.lookup,
    this.before = 1,
    this.after = 1,
    this.name = 'neighbours',
  });

  /// The retriever whose results are expanded.
  final Retriever inner;

  /// Resolves `<documentId>#<index>` to a chunk, or `null`.
  final FutureOr<DocumentChunk?> Function(String chunkId) lookup;

  /// How many preceding chunks to add.
  final int before;

  /// How many following chunks to add.
  final int after;

  @override
  final String name;

  @override
  Future<List<RetrievedChunk>> retrieve(
    RetrievalRequest request, {
    AgenticContext? context,
  }) async {
    final hits = await inner.retrieve(request, context: context);
    if (hits.isEmpty || (before == 0 && after == 0)) return hits;

    final seen = <String>{for (final hit in hits) hit.id};
    final expanded = List<RetrievedChunk>.of(hits);

    for (final hit in hits) {
      for (var offset = -before; offset <= after; offset++) {
        if (offset == 0) continue;
        final index = hit.chunk.index + offset;
        if (index < 0) continue;
        final id = '${hit.chunk.documentId}#$index';
        if (!seen.add(id)) continue;
        final neighbour = await lookup(id);
        if (neighbour == null) continue;
        expanded.add(
          RetrievedChunk(
            chunk: neighbour,
            // Just below its anchor, so ordering by score keeps a neighbour
            // beside the hit it belongs to rather than at the end.
            score: hit.score - 1e-6 * offset.abs(),
            retriever: '$name:${hit.chunk.index}',
            rank: hit.rank,
          ),
        );
      }
    }
    return List<RetrievedChunk>.unmodifiable(expanded);
  }

  @override
  String toString() => 'NeighbourExpandingRetriever($inner, -$before/+$after)';
}
