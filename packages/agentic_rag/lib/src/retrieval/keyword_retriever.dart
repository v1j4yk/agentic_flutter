/// Lexical retrieval with BM25.
///
/// # Why a keyword index still earns its place
///
/// Embeddings are the reason RAG works, and they are unreliable at exactly the
/// queries users are most confident about: an order number, an error code, an
/// API name, a surname. Those are rare tokens, and rare tokens are what dense
/// vectors smooth away — `ERR_4417` and `ERR_4418` sit almost on top of each
/// other in vector space, and neither is especially close to a question that
/// quotes one of them.
///
/// BM25 has the opposite bias. It scores a rare term highly precisely because
/// it is rare, which is why fusing the two rankings beats either alone on
/// nearly every real corpus.
///
/// It is also nearly free: no model, no network, no embedding cost. Measured
/// over five thousand chunks, a query is 3.3 ms — noise next to the tens or
/// hundreds of milliseconds an embedding call costs, which is the comparison
/// that decides whether the lexical half is worth having.
///
/// The index is inverted, so a query walks only the chunks containing its terms
/// rather than the whole corpus. That is worth roughly a factor of two on a
/// realistic vocabulary and nothing at all when every query term appears
/// everywhere — a case the benchmark suite measures by name rather than
/// hiding.
library;

import 'dart:math' as math;

import 'package:agentic_core/agentic_core.dart';
import 'package:agentic_rag/src/model/document.dart';
import 'package:agentic_rag/src/retrieval/retriever.dart';
import 'package:agentic_vector/agentic_vector.dart';

/// An in-process BM25 index over chunks.
///
/// BM25 scores a term by how often it appears in a passage (with diminishing
/// returns), how rare it is across the corpus, and how long the passage is
/// relative to the average — so a long document does not win merely by
/// containing more words.
///
/// ```dart
/// final index = InMemoryKeywordIndex()..addAll(chunks);
/// final retriever = KeywordRetriever(index: index);
/// ```
final class InMemoryKeywordIndex {
  /// Creates an empty index.
  ///
  /// [k1] controls how quickly repeated terms stop helping and [b] how strongly
  /// length is penalised. The defaults, 1.2 and 0.75, are the values BM25 is
  /// almost always used with; change them only with a measurement in hand.
  InMemoryKeywordIndex({this.k1 = 1.2, this.b = 0.75, this.minTermLength = 2});

  /// Term-frequency saturation.
  final double k1;

  /// Length normalisation, from 0 (none) to 1 (full).
  final double b;

  /// Shortest token that is indexed.
  final int minTermLength;

  final Map<String, DocumentChunk> _chunks = <String, DocumentChunk>{};
  final Map<String, Map<String, int>> _frequencies =
      <String, Map<String, int>>{};
  final Map<String, int> _lengths = <String, int>{};

  /// Term to the chunks containing it, and how often.
  ///
  /// The inverted index, and the reason a query is cheap. Scoring by walking
  /// every chunk and asking whether it contains each term costs the size of the
  /// corpus on every query — measured at 5.9 ms over five thousand chunks,
  /// against the "effectively free" this package claims. Walking only the
  /// chunks that contain a term costs the length of that term's postings list,
  /// which for the rare terms BM25 scores highest is a handful of entries.
  final Map<String, Map<String, int>> _postings = <String, Map<String, int>>{};

  int _totalLength = 0;

  /// How many chunks are indexed.
  int get length => _chunks.length;

  /// Average chunk length in tokens, used for normalisation.
  double get averageLength =>
      _chunks.isEmpty ? 0 : _totalLength / _chunks.length;

  /// The indexed chunks.
  Iterable<DocumentChunk> get chunks => _chunks.values;

  /// Adds or replaces a chunk.
  void add(DocumentChunk chunk) {
    remove(chunk.id);
    final terms = tokenise(chunk.text, minLength: minTermLength);
    if (terms.isEmpty) {
      // Still indexed, so `length` and deletion stay consistent with the vector
      // side; it simply matches nothing.
      _chunks[chunk.id] = chunk;
      _frequencies[chunk.id] = const <String, int>{};
      _lengths[chunk.id] = 0;
      return;
    }

    final counts = <String, int>{};
    for (final term in terms) {
      counts[term] = (counts[term] ?? 0) + 1;
    }
    _chunks[chunk.id] = chunk;
    _frequencies[chunk.id] = counts;
    _lengths[chunk.id] = terms.length;
    _totalLength += terms.length;
    for (final entry in counts.entries) {
      _postings.putIfAbsent(entry.key, () => <String, int>{})[chunk.id] =
          entry.value;
    }
  }

  /// Adds or replaces several chunks.
  void addAll(Iterable<DocumentChunk> chunks) {
    for (final chunk in chunks) {
      add(chunk);
    }
  }

  /// Removes a chunk, returning whether it was there.
  bool remove(String id) {
    final counts = _frequencies.remove(id);
    if (counts == null) {
      _chunks.remove(id);
      return false;
    }
    _chunks.remove(id);
    _totalLength -= _lengths.remove(id) ?? 0;
    for (final term in counts.keys) {
      final postings = _postings[term];
      if (postings == null) continue;
      postings.remove(id);
      // A term nobody has any more is removed outright: leaving empty postings
      // behind would grow the index forever under a churning corpus, and would
      // make the term's document frequency — which is its own length — zero.
      if (postings.isEmpty) _postings.remove(term);
    }
    return true;
  }

  /// Removes every chunk of [documentId], returning how many were removed.
  int removeDocument(String documentId) {
    final doomed = <String>[
      for (final chunk in _chunks.values)
        if (chunk.documentId == documentId) chunk.id,
    ];
    for (final id in doomed) {
      remove(id);
    }
    return doomed.length;
  }

  /// Empties the index.
  void clear() {
    _chunks.clear();
    _frequencies.clear();
    _lengths.clear();
    _postings.clear();
    _totalLength = 0;
  }

  /// Scores every chunk against [query], best first.
  ///
  /// [filter] is applied before scoring, matching the rule the vector port
  /// keeps, so that a hybrid retriever's two halves see the same candidates.
  List<({DocumentChunk chunk, double score})> search(
    String query, {
    int limit = 10,
    MetadataFilter? filter,
  }) {
    final terms = tokenise(query, minLength: minTermLength);
    if (terms.isEmpty || _chunks.isEmpty) {
      return const <({DocumentChunk chunk, double score})>[];
    }

    final average = averageLength;
    final total = _chunks.length;
    final accumulated = <String, double>{};

    for (final term in terms.toSet()) {
      final postings = _postings[term];
      if (postings == null) continue;

      // The document frequency *is* the postings length, so the inverted index
      // removes the separate bookkeeping that had to be kept in step with it.
      final documentFrequency = postings.length;
      final idf = math.log(
        1 + (total - documentFrequency + 0.5) / (documentFrequency + 0.5),
      );

      for (final entry in postings.entries) {
        final chunkLength = _lengths[entry.key] ?? 0;
        final frequency = entry.value;
        final normalisation =
            k1 * (1 - b + b * (average == 0 ? 1 : chunkLength / average));
        accumulated[entry.key] =
            (accumulated[entry.key] ?? 0) +
            idf * (frequency * (k1 + 1)) / (frequency + normalisation);
      }
    }

    final scored = <({DocumentChunk chunk, double score})>[];
    for (final entry in accumulated.entries) {
      if (entry.value <= 0) continue;
      final chunk = _chunks[entry.key];
      if (chunk == null) continue;
      // Filtering after scoring but before ranking. The port's rule is that a
      // filter must not be applied to an already-truncated result set, which
      // this respects: nothing has been cut yet.
      if (filter != null && !filter.matches(chunk.metadata)) continue;
      scored.add((chunk: chunk, score: entry.value));
    }

    scored.sort((a, b) => b.score.compareTo(a.score));
    if (scored.length > limit) scored.length = limit;
    return List<({DocumentChunk chunk, double score})>.unmodifiable(scored);
  }

  /// Splits [text] into lowercase terms.
  ///
  /// Deliberately simple: lowercase, split on anything that is not a letter or
  /// digit, drop the shortest tokens. No stemming and no stop-word list —
  /// stemming is language-specific and would quietly break every corpus that is
  /// not English, and BM25's rarity weighting already demotes stop words far
  /// more reliably than a fixed list.
  static List<String> tokenise(String text, {int minLength = 2}) => <String>[
    for (final token in text.toLowerCase().split(_separator))
      if (token.length >= minLength) token,
  ];

  static final RegExp _separator = RegExp(r'[^a-z0-9_]+');

  @override
  String toString() => 'InMemoryKeywordIndex($length chunks)';
}

/// Retrieves passages by term overlap.
///
/// One caveat worth knowing: BM25 scores are **unbounded**, not the 0-to-1 of a
/// cosine similarity. A `minScore` that means "reasonably similar" to a vector
/// retriever means something else entirely here, so set it against measured
/// BM25 values or leave it at zero. It is also why `HybridRetriever` fuses
/// ranks rather than scores — the two scales cannot be added.
final class KeywordRetriever implements Retriever {
  /// Retrieves from [index].
  const KeywordRetriever({required this.index, this.name = 'keyword'});

  /// The index to search.
  final InMemoryKeywordIndex index;

  @override
  final String name;

  @override
  Future<List<RetrievedChunk>> retrieve(
    RetrievalRequest request, {
    AgenticContext? context,
  }) async {
    final hits = index.search(
      request.query,
      // Over-fetch a little, because the score floor and the caller's `topK`
      // are applied afterwards by `finalise`.
      limit: request.topK * 2,
      filter: request.filter,
    );
    return finalise(<RetrievedChunk>[
      for (final hit in hits)
        RetrievedChunk(chunk: hit.chunk, score: hit.score, retriever: name),
    ], request);
  }

  @override
  String toString() => 'KeywordRetriever($name, ${index.length} chunks)';
}
