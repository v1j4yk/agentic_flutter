/// Turning text into vectors.
///
/// Embeddings are the retrieval half of the framework: `agentic_rag` chunks
/// documents, embeds them here, and stores the vectors in `agentic_vector`. The
/// port lives in this package because embedding endpoints are provider
/// endpoints, and an adapter almost always implements both this and `ChatModel`
/// against the same transport and credentials.
library;

import 'dart:math' as math;

import 'package:agentic_core/agentic_core.dart';
import 'package:agentic_llm/src/model/model_info.dart';
import 'package:meta/meta.dart';

/// What an embedding will be used for.
///
/// Several embedding models are *asymmetric*: they produce different vectors
/// for the same text depending on whether it is a stored document or a search
/// query, and using the wrong mode measurably degrades retrieval. Providers
/// spell it differently — a task type, an input type, a prefix string — so the
/// framework asks the question once, in provider-neutral terms, and lets
/// adapters translate.
///
/// Getting this wrong is a silent failure: retrieval still returns results,
/// they are simply worse. Which is why it is a required parameter with no
/// default on the query side.
enum EmbeddingPurpose {
  /// Text being stored for later retrieval.
  document,

  /// Text being used to search.
  query,

  /// Text being compared to other text of the same kind.
  similarity,

  /// Text being grouped.
  clustering,

  /// Text being classified.
  classification,
}

/// A dense vector representation of some text.
@immutable
final class Embedding {
  /// Creates an embedding.
  Embedding({required List<double> values, this.index = 0, this.text})
    : values = List<double>.unmodifiable(values);

  /// The vector components.
  final List<double> values;

  /// Position of the source text in the input batch.
  ///
  /// Providers may return results out of order; this is what puts them back.
  final int index;

  /// The text this vector represents, when the caller asked to keep it.
  ///
  /// Omitted by default: retaining the text alongside every vector doubles the
  /// memory cost of an index on a device.
  final String? text;

  /// Number of components.
  int get dimensions => values.length;

  /// Cosine similarity with [other], from -1 to 1.
  ///
  /// The standard relevance measure for text embeddings. Throws when the
  /// dimensions disagree, because a silent mismatch here produces plausible
  /// nonsense — which is exactly what happens when an index built with one
  /// model is queried with another.
  double cosineSimilarity(Embedding other) {
    if (dimensions != other.dimensions) {
      throw ValidationException(
        'Cannot compare a $dimensions-dimensional embedding with a '
        '${other.dimensions}-dimensional one. This usually means an index was '
        'built with one model and queried with another.',
        violations: <String>['dimensions: $dimensions != ${other.dimensions}'],
      );
    }
    var dot = 0.0;
    var normA = 0.0;
    var normB = 0.0;
    for (var i = 0; i < values.length; i++) {
      final a = values[i];
      final b = other.values[i];
      dot += a * b;
      normA += a * a;
      normB += b * b;
    }
    if (normA == 0 || normB == 0) return 0;
    return dot / (math.sqrt(normA) * math.sqrt(normB));
  }

  /// Euclidean distance to [other].
  double euclideanDistance(Embedding other) {
    if (dimensions != other.dimensions) {
      throw ValidationException(
        'Cannot measure distance between a $dimensions-dimensional embedding '
        'and a ${other.dimensions}-dimensional one.',
        violations: <String>['dimensions: $dimensions != ${other.dimensions}'],
      );
    }
    var sum = 0.0;
    for (var i = 0; i < values.length; i++) {
      final delta = values[i] - other.values[i];
      sum += delta * delta;
    }
    return math.sqrt(sum);
  }

  /// The vector scaled to unit length.
  ///
  /// Once normalised, a dot product *is* cosine similarity, which is what makes
  /// a large index fast. Store normalised vectors and the per-query square root
  /// disappears.
  Embedding normalised() {
    var norm = 0.0;
    for (final value in values) {
      norm += value * value;
    }
    if (norm == 0) return this;
    final magnitude = math.sqrt(norm);
    return Embedding(
      values: <double>[for (final value in values) value / magnitude],
      index: index,
      text: text,
    );
  }

  /// Serialises the embedding.
  JsonMap toJson() => pruneNulls(<String, Object?>{
    'values': values,
    'index': index,
    'text': text,
  });

  /// Restores an embedding from JSON.
  static Embedding fromJson(JsonMap json) => Embedding(
    values: json
        .requireList('values')
        .map((v) => (v! as num).toDouble())
        .toList(),
    index: json.intOr('index', 0),
    text: json.optionalString('text'),
  );

  @override
  String toString() => 'Embedding(${dimensions}d, index: $index)';
}

/// A model that converts text into vectors.
abstract interface class EmbeddingModel implements Disposable {
  /// What this model is.
  ModelInfo get info;

  /// Number of components each vector has.
  ///
  /// Needed before the first call: a vector store must be created with a fixed
  /// dimension, and discovering a mismatch after ingesting fifty thousand
  /// documents is an expensive way to learn it.
  int get dimensions;

  /// Maximum inputs accepted in one call.
  ///
  /// Callers batch to this size. Exceeding it is a provider error, and one
  /// oversized batch can fail an entire ingestion run.
  int get maxBatchSize;

  /// Embeds [inputs], returning one vector per input, in order.
  ///
  /// [purpose] selects the asymmetric mode where the model has one; see
  /// [EmbeddingPurpose].
  Future<List<Embedding>> embed(
    List<String> inputs, {
    required EmbeddingPurpose purpose,
    AgenticContext? context,
  });
}

/// Conveniences available on every [EmbeddingModel].
extension EmbeddingModelOperations on EmbeddingModel {
  /// Embeds a single document.
  Future<Embedding> embedDocument(
    String text, {
    AgenticContext? context,
  }) async {
    final result = await embed(
      <String>[text],
      purpose: EmbeddingPurpose.document,
      context: context,
    );
    return result.single;
  }

  /// Embeds a single search query.
  Future<Embedding> embedQuery(String text, {AgenticContext? context}) async {
    final result = await embed(
      <String>[text],
      purpose: EmbeddingPurpose.query,
      context: context,
    );
    return result.single;
  }

  /// Embeds any number of inputs, splitting into provider-sized batches.
  ///
  /// The call an ingestion pipeline actually wants: hand it ten thousand chunks
  /// and let it deal with the batch limit. Batches run sequentially rather than
  /// in parallel, because embedding endpoints rate-limit aggressively and a
  /// parallel burst is the fastest way to a 429.
  Future<List<Embedding>> embedAll(
    List<String> inputs, {
    required EmbeddingPurpose purpose,
    AgenticContext? context,
    void Function(int done, int total)? onProgress,
  }) async {
    if (inputs.isEmpty) return const <Embedding>[];

    final results = <Embedding>[];
    for (var start = 0; start < inputs.length; start += maxBatchSize) {
      context?.throwIfCancelled();
      final end = math.min(start + maxBatchSize, inputs.length);
      final batch = await embed(
        inputs.sublist(start, end),
        purpose: purpose,
        context: context,
      );
      // Re-index against the full input list; providers index within a batch.
      for (var i = 0; i < batch.length; i++) {
        results.add(
          Embedding(
            values: batch[i].values,
            index: start + i,
            text: batch[i].text,
          ),
        );
      }
      onProgress?.call(results.length, inputs.length);
    }
    return results;
  }
}
