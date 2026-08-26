/// Dense retrieval over a vector index.
library;

import 'package:agentic_core/agentic_core.dart';
import 'package:agentic_rag/src/model/document.dart';
import 'package:agentic_rag/src/retrieval/chunk_codec.dart';
import 'package:agentic_rag/src/retrieval/retriever.dart';
import 'package:agentic_vector/agentic_vector.dart';

/// Retrieves passages by embedding similarity.
///
/// # What dense retrieval is good and bad at
///
/// It finds text that means the same thing in different words — "how do I get
/// my money back" against a section titled "Refunds" — which is the whole
/// reason RAG works at all.
///
/// It is unreliable at the exact opposite: rare tokens. Order numbers, error
/// codes, API names and people's surnames are precisely what a user quotes
/// verbatim, and embeddings blur them, because "ERR_4417" and "ERR_4418" are
/// near-identical in vector space. That is what `KeywordRetriever` is for, and
/// why `HybridRetriever` exists rather than one of them being the answer.
///
/// ```dart
/// final retriever = VectorRetriever(index: embeddingIndex);
/// final hits = await retriever.search('how do refunds work?', topK: 4);
/// ```
final class VectorRetriever implements Retriever {
  /// Retrieves from [index].
  const VectorRetriever({
    required this.index,
    this.name = 'vector',
    this.includeVectors = false,
  });

  /// The embedding model and store to search.
  final EmbeddingIndex index;

  @override
  final String name;

  /// Whether matches carry their vectors back.
  ///
  /// Turn it on when a re-ranker needs them — `MmrReranker` does — and leave it
  /// off otherwise, because it is a kilobyte or two per match of pure transfer.
  final bool includeVectors;

  @override
  Future<List<RetrievedChunk>> retrieve(
    RetrievalRequest request, {
    AgenticContext? context,
  }) async {
    final matches = await index.query(
      request.query,
      topK: request.topK,
      filter: request.filter,
      minScore: request.minScore,
      includeVectors: includeVectors,
      namespace: request.namespace,
      context: context,
    );

    final results = <RetrievedChunk>[];
    for (final match in matches) {
      final chunk = chunkFromRecord(match.record);
      // A record this package did not write has no document to cite. Skipping
      // it is the honest answer; inventing an identifier is not.
      if (chunk == null) continue;
      results.add(
        RetrievedChunk(chunk: chunk, score: match.score, retriever: name),
      );
    }
    return finalise(results, request);
  }

  @override
  String toString() => 'VectorRetriever($name)';
}
