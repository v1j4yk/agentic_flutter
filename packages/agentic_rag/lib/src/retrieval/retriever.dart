/// The retrieval port.
///
/// # One interface over three very different ideas
///
/// Dense retrieval finds text that *means* the same thing. Lexical retrieval
/// finds text that *says* the same thing. A hybrid does both and fuses the
/// rankings. They have almost nothing in common internally, and exactly one
/// thing in common externally: given a question, they return ranked passages.
///
/// That is what this port is. It is what lets a pipeline be assembled from
/// whichever combination a corpus actually needs, and swapped when measurement
/// says something else works better.
library;

import 'package:agentic_core/agentic_core.dart';
import 'package:agentic_rag/src/model/document.dart';
import 'package:agentic_vector/agentic_vector.dart';
import 'package:meta/meta.dart';

/// A retrieval request.
@immutable
final class RetrievalRequest {
  /// Creates a request.
  const RetrievalRequest({
    required this.query,
    this.topK = 6,
    this.filter,
    this.minScore = 0,
    this.namespace,
  }) : assert(topK > 0, 'topK must be positive');

  /// The question, in the user's own words.
  final String query;

  /// How many passages to return.
  ///
  /// Six by default. The number that matters is how much of the prompt they
  /// consume: twenty chunks of a thousand characters is twenty thousand
  /// characters of context, most of it irrelevant, and models measurably lose
  /// track of the middle of a long context.
  final int topK;

  /// Restricts which chunks are eligible.
  final MetadataFilter? filter;

  /// Minimum relevance for a passage to be returned.
  ///
  /// The setting that lets a pipeline answer "I do not know". Without it,
  /// retrieval always returns its `topK` nearest passages, however irrelevant,
  /// and the model dutifully writes an answer from them.
  final double minScore;

  /// The store partition to search, when the backend has them.
  final String? namespace;

  /// Returns a copy with selected fields replaced.
  RetrievalRequest copyWith({
    String? query,
    int? topK,
    MetadataFilter? filter,
    double? minScore,
    String? namespace,
  }) => RetrievalRequest(
    query: query ?? this.query,
    topK: topK ?? this.topK,
    filter: filter ?? this.filter,
    minScore: minScore ?? this.minScore,
    namespace: namespace ?? this.namespace,
  );

  /// Serialises the request.
  JsonMap toJson() => pruneNulls(<String, Object?>{
    'query': query,
    'topK': topK,
    'filter': filter?.toJson(),
    'minScore': minScore == 0 ? null : minScore,
    'namespace': namespace,
  });

  @override
  String toString() => 'RetrievalRequest("$query", topK: $topK)';
}

/// Finds the passages most relevant to a question.
///
/// Implementations must return results ordered by descending
/// [RetrievedChunk.score], at most [RetrievalRequest.topK] of them, and none
/// below [RetrievalRequest.minScore].
abstract interface class Retriever {
  /// A short name, carried on results and into events.
  String get name;

  /// Retrieves passages for [request].
  Future<List<RetrievedChunk>> retrieve(
    RetrievalRequest request, {
    AgenticContext? context,
  });
}

/// Conveniences available on every [Retriever].
extension RetrieverOperations on Retriever {
  /// Retrieves with a plain query string.
  Future<List<RetrievedChunk>> search(
    String query, {
    int topK = 6,
    MetadataFilter? filter,
    double minScore = 0,
    String? namespace,
    AgenticContext? context,
  }) => retrieve(
    RetrievalRequest(
      query: query,
      topK: topK,
      filter: filter,
      minScore: minScore,
      namespace: namespace,
    ),
    context: context,
  );

  /// Applies this port's ordering contract to [results].
  ///
  /// Sorts, applies the floor, truncates and stamps ranks. Implementations call
  /// it last so that every retriever keeps the same promises without each one
  /// re-deriving them.
  @protected
  List<RetrievedChunk> finalise(
    List<RetrievedChunk> results,
    RetrievalRequest request,
  ) {
    final ordered = List<RetrievedChunk>.of(results)
      ..sort((a, b) => b.score.compareTo(a.score));
    final kept = <RetrievedChunk>[];
    for (final result in ordered) {
      if (result.score < request.minScore) continue;
      if (kept.length >= request.topK) break;
      kept.add(
        result.copyWith(rank: kept.length, retriever: result.retriever ?? name),
      );
    }
    return List<RetrievedChunk>.unmodifiable(kept);
  }
}
