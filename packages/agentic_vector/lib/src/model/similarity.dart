/// How closeness between two vectors is measured.
///
/// # Why every metric returns a score, not a distance
///
/// Cosine and dot product are similarities (higher is better); Euclidean is a
/// distance (lower is better). Exposing both conventions through one port would
/// mean `topK` sorts one way for two metrics and the other way for the third,
/// and `minScore` would mean opposite things depending on configuration — a
/// configuration change that silently inverts a filter.
///
/// So [SimilarityMetric.score] always returns *higher is better*, and Euclidean
/// distance is mapped monotonically into that convention. Callers who genuinely
/// want the distance can still call [euclideanDistance].
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:agentic_core/agentic_core.dart';

/// The comparison function a store uses.
enum SimilarityMetric {
  /// Angle between vectors, ignoring magnitude.
  ///
  /// The default for text embeddings, and what nearly every embedding model is
  /// trained against. Magnitude in a text embedding mostly reflects input
  /// length, which is not what relevance means.
  cosine('Cosine'),

  /// Raw dot product.
  ///
  /// Equal to cosine for unit-length vectors, and cheaper because it skips two
  /// square roots. Correct only when vectors are normalised — otherwise long
  /// documents score higher than relevant ones purely by being long.
  dotProduct('Dot product'),

  /// Straight-line distance, mapped to a score.
  ///
  /// Used by models trained with a Euclidean objective. Scores are `1 / (1 + d)`
  /// so that identical vectors score 1 and the ordering matches the other
  /// metrics.
  euclidean('Euclidean');

  const SimilarityMetric(this.label);

  /// Human-readable name, for logs and UIs.
  final String label;

  /// Scores [a] against [b], higher meaning more similar.
  ///
  /// Throws a [ValidationException] when the dimensions disagree. That is
  /// almost always an index built with one embedding model being queried with
  /// another, and it produces plausible-looking nonsense if allowed through.
  double score(List<double> a, List<double> b) {
    _requireSameDimensions(a, b);
    // The typed branch is not a micro-optimisation. A loop over `List<double>`
    // reads boxed doubles through an interface call; the same loop over
    // `Float64List` reads contiguous machine doubles, and at 768 dimensions
    // that is 1.4 µs against 2.4 µs. Multiplied by the size of an index on
    // every query, it decides whether a scan is viable on a device.
    //
    // The check has to be here rather than at the call site because a
    // `Float64List` *is* a `List<double>`: passing one to a parameter of the
    // wider type loses the specialisation the compiler needs.
    if (a is Float64List && b is Float64List) {
      return switch (this) {
        SimilarityMetric.cosine => _cosineTyped(a, b),
        SimilarityMetric.dotProduct => _dotTyped(a, b),
        SimilarityMetric.euclidean => 1 / (1 + _euclideanTyped(a, b)),
      };
    }
    // Deliberately the private helpers: inside this enum the name `dotProduct`
    // resolves to the enum constant, not to the top-level function.
    return switch (this) {
      SimilarityMetric.cosine => _cosine(a, b),
      SimilarityMetric.dotProduct => _dot(a, b),
      SimilarityMetric.euclidean => 1 / (1 + _euclidean(a, b)),
    };
  }

  /// The lowest score this metric can produce, used as a sentinel.
  double get worstScore =>
      this == SimilarityMetric.euclidean ? 0 : double.negativeInfinity;
}

/// Cosine similarity of [a] and [b], from -1 to 1.
///
/// Returns 0 when either vector is all zeros: the angle is undefined, and 0 —
/// "unrelated" — is the only answer that does not distort a ranking.
double cosineSimilarity(List<double> a, List<double> b) {
  _requireSameDimensions(a, b);
  if (a is Float64List && b is Float64List) return _cosineTyped(a, b);
  return _cosine(a, b);
}

/// Dot product of [a] and [b].
double dotProduct(List<double> a, List<double> b) {
  _requireSameDimensions(a, b);
  if (a is Float64List && b is Float64List) return _dotTyped(a, b);
  return _dot(a, b);
}

/// Euclidean distance between [a] and [b].
double euclideanDistance(List<double> a, List<double> b) {
  _requireSameDimensions(a, b);
  if (a is Float64List && b is Float64List) return _euclideanTyped(a, b);
  return _euclidean(a, b);
}

double _cosine(List<double> a, List<double> b) {
  var dot = 0.0;
  var normA = 0.0;
  var normB = 0.0;
  for (var i = 0; i < a.length; i++) {
    final x = a[i];
    final y = b[i];
    dot += x * y;
    normA += x * x;
    normB += y * y;
  }
  if (normA == 0 || normB == 0) return 0;
  return dot / (math.sqrt(normA) * math.sqrt(normB));
}

double _dot(List<double> a, List<double> b) {
  var sum = 0.0;
  for (var i = 0; i < a.length; i++) {
    sum += a[i] * b[i];
  }
  return sum;
}

double _euclidean(List<double> a, List<double> b) {
  var sum = 0.0;
  for (var i = 0; i < a.length; i++) {
    final delta = a[i] - b[i];
    sum += delta * delta;
  }
  return math.sqrt(sum);
}

/// Returns [vector] scaled to unit length.
///
/// Normalise once at ingestion and [SimilarityMetric.dotProduct] becomes exact
/// cosine at a fraction of the cost. An all-zero vector is returned unchanged,
/// because there is no direction to preserve.
Float64List normalise(List<double> vector) {
  var norm = 0.0;
  for (final value in vector) {
    norm += value * value;
  }
  final result = Float64List(vector.length);
  if (norm == 0) {
    result.setAll(0, vector);
    return result;
  }
  final magnitude = math.sqrt(norm);
  for (var i = 0; i < vector.length; i++) {
    result[i] = vector[i] / magnitude;
  }
  return result;
}

// The typed twins. Duplicated rather than made generic on purpose: the whole
// point is that each body is compiled against one concrete list type, and any
// abstraction that unifies them puts the interface call back.

double _cosineTyped(Float64List a, Float64List b) {
  var dot = 0.0;
  var normA = 0.0;
  var normB = 0.0;
  for (var i = 0; i < a.length; i++) {
    final x = a[i];
    final y = b[i];
    dot += x * y;
    normA += x * x;
    normB += y * y;
  }
  if (normA == 0 || normB == 0) return 0;
  return dot / (math.sqrt(normA) * math.sqrt(normB));
}

double _dotTyped(Float64List a, Float64List b) {
  var sum = 0.0;
  for (var i = 0; i < a.length; i++) {
    sum += a[i] * b[i];
  }
  return sum;
}

double _euclideanTyped(Float64List a, Float64List b) {
  var sum = 0.0;
  for (var i = 0; i < a.length; i++) {
    final delta = a[i] - b[i];
    sum += delta * delta;
  }
  return math.sqrt(sum);
}

void _requireSameDimensions(List<double> a, List<double> b) {
  if (a.length == b.length) return;
  throw ValidationException(
    'Cannot compare a ${a.length}-dimensional vector with a '
    '${b.length}-dimensional one. This usually means the index was built with '
    'one embedding model and queried with another.',
    violations: <String>['dimensions: ${a.length} != ${b.length}'],
  );
}
