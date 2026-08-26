/// Reordering what retrieval found.
///
/// # Why retrieval is not the last word
///
/// A retriever optimises for recall: cast a wide net, get the right passage
/// somewhere in the top twenty. A prompt has room for four. Re-ranking is the
/// step in between — it takes a generous candidate list and produces a short,
/// good one.
///
/// The two shipped re-rankers attack different problems. [MmrReranker] fixes
/// redundancy: five passages that all say the same thing use the whole prompt
/// budget to say it once. `LlmReranker` fixes precision: a model reads each
/// candidate against the question and judges relevance directly, which is more
/// accurate than any similarity measure and costs a model call.
library;

import 'package:agentic_core/agentic_core.dart';
import 'package:agentic_rag/src/model/document.dart';
import 'package:agentic_vector/agentic_vector.dart';

/// Reorders and trims retrieval results.
///
/// Implementations must return a subset of what they were given — never
/// fabricate a chunk — ordered best first, with [RetrievedChunk.rank] restamped
/// to the new ordering.
abstract interface class Reranker {
  /// A short name, used in events and traces.
  String get name;

  /// Reorders [results] for [query], keeping at most [topK].
  Future<List<RetrievedChunk>> rerank(
    String query,
    List<RetrievedChunk> results, {
    int topK = 4,
    AgenticContext? context,
  });
}

/// Trades relevance against variety.
///
/// # The redundancy problem
///
/// Retrieval ranks by similarity to the question, and near-duplicate passages
/// are similar to the same questions. A changelog, a FAQ, a document that was
/// re-published under a new title — all of them produce candidate lists whose
/// top five entries are five copies of one fact, filling the prompt without
/// adding anything.
///
/// Maximal marginal relevance picks greedily: at each step it selects the
/// candidate maximising `λ · relevance − (1 − λ) · similarity to what is already
/// chosen`. With [lambda] at 1 it is plain relevance ordering; lower values buy
/// variety at the cost of some relevance. 0.7 is a sensible default.
///
/// # It needs vectors
///
/// Similarity between candidates is measured on their embeddings, so the
/// retriever must have been asked for them — `VectorRetriever(includeVectors:
/// true)`. Given results without vectors this re-ranker cannot do its job, and
/// it says so rather than silently degrading to plain truncation.
final class MmrReranker implements Reranker {
  /// Creates a diversity-aware re-ranker.
  const MmrReranker({
    required this.vectorOf,
    this.lambda = 0.7,
    this.name = 'mmr',
  }) : assert(lambda >= 0 && lambda <= 1, 'lambda must be between 0 and 1');

  /// Supplies the embedding for a result, or `null` when there is none.
  ///
  /// A function rather than a field on [RetrievedChunk] because where the
  /// vector comes from differs: the store returned it, a cache holds it, or the
  /// application embedded it itself.
  final List<double>? Function(RetrievedChunk result) vectorOf;

  /// How strongly relevance is favoured over variety, from 0 to 1.
  final double lambda;

  @override
  final String name;

  @override
  Future<List<RetrievedChunk>> rerank(
    String query,
    List<RetrievedChunk> results, {
    int topK = 4,
    AgenticContext? context,
  }) async {
    if (results.length <= 1) return results;

    final vectors = <String, List<double>>{};
    for (final result in results) {
      final vector = vectorOf(result);
      if (vector != null && vector.isNotEmpty) vectors[result.id] = vector;
    }
    if (vectors.length < results.length) {
      throw ConfigurationException(
        'Maximal marginal relevance needs an embedding for every candidate, '
        'but ${results.length - vectors.length} of ${results.length} had none. '
        'Retrieve with `includeVectors: true`, or use a re-ranker that reads '
        'text instead.',
        setting: 'includeVectors',
      );
    }

    final remaining = List<RetrievedChunk>.of(results)
      ..sort((a, b) => b.score.compareTo(a.score));
    final selected = <RetrievedChunk>[];

    while (selected.length < topK && remaining.isNotEmpty) {
      var bestIndex = 0;
      var bestValue = double.negativeInfinity;
      for (var i = 0; i < remaining.length; i++) {
        final candidate = remaining[i];
        var maxSimilarity = 0.0;
        for (final chosen in selected) {
          final similarity = cosineSimilarity(
            vectors[candidate.id]!,
            vectors[chosen.id]!,
          );
          if (similarity > maxSimilarity) maxSimilarity = similarity;
        }
        final value = lambda * candidate.score - (1 - lambda) * maxSimilarity;
        if (value > bestValue) {
          bestValue = value;
          bestIndex = i;
        }
      }
      final chosen = remaining.removeAt(bestIndex);
      selected.add(chosen.copyWith(rank: selected.length, retriever: name));
    }

    return List<RetrievedChunk>.unmodifiable(selected);
  }

  @override
  String toString() => 'MmrReranker(lambda: $lambda)';
}

/// Keeps only what clears a bar, and at most so many.
///
/// The simplest useful re-ranker, and the one most pipelines should have before
/// they reach for a model: it does not reorder anything, it just enforces that
/// weak matches never reach the prompt. Free, instant, and the difference
/// between "I could not find that" and a confident answer assembled from
/// nothing.
final class ScoreFloorReranker implements Reranker {
  /// Keeps results scoring at least [minScore].
  const ScoreFloorReranker({this.minScore = 0, this.name = 'floor'});

  /// The bar a result must clear.
  final double minScore;

  @override
  final String name;

  @override
  Future<List<RetrievedChunk>> rerank(
    String query,
    List<RetrievedChunk> results, {
    int topK = 4,
    AgenticContext? context,
  }) async {
    final kept = <RetrievedChunk>[];
    for (final result in results) {
      if (result.score < minScore) continue;
      if (kept.length >= topK) break;
      kept.add(result.copyWith(rank: kept.length));
    }
    return List<RetrievedChunk>.unmodifiable(kept);
  }

  @override
  String toString() => 'ScoreFloorReranker($minScore)';
}

/// Runs several re-rankers in order.
///
/// Order is the whole design: put the cheap filters first so the expensive one
/// reads four candidates instead of forty. `[ScoreFloorReranker,
/// LlmReranker]` is usually the right shape.
final class ChainedReranker implements Reranker {
  /// Creates a chain over [rerankers].
  const ChainedReranker(this.rerankers, {this.name = 'chain'});

  /// The re-rankers, in order.
  final List<Reranker> rerankers;

  @override
  final String name;

  @override
  Future<List<RetrievedChunk>> rerank(
    String query,
    List<RetrievedChunk> results, {
    int topK = 4,
    AgenticContext? context,
  }) async {
    var current = results;
    for (var i = 0; i < rerankers.length; i++) {
      // Only the last stage trims to `topK`; the earlier ones keep enough
      // candidates for it to choose from, which is the point of chaining.
      final isLast = i == rerankers.length - 1;
      current = await rerankers[i].rerank(
        query,
        current,
        topK: isLast ? topK : topK * 3,
        context: context,
      );
    }
    return current;
  }

  @override
  String toString() =>
      'ChainedReranker(${rerankers.map((r) => r.name).join(' -> ')})';
}
