/// What a vector store holds and what a search returns.
library;

import 'dart:typed_data';

import 'package:agentic_core/agentic_core.dart';
import 'package:agentic_llm/agentic_llm.dart';
import 'package:agentic_vector/src/model/metadata_filter.dart';
import 'package:meta/meta.dart';

/// One stored vector and the payload travelling with it.
@immutable
final class VectorRecord {
  /// Creates a record.
  ///
  /// [id] is the caller's key, not the store's. Making it caller-supplied is
  /// what makes ingestion idempotent: re-indexing a document upserts its chunks
  /// rather than duplicating them, which is the difference between a pipeline
  /// you can re-run and one you can run once.
  VectorRecord({
    required this.id,
    required List<double> vector,
    JsonMap metadata = const <String, Object?>{},
    this.text,
  }) : vector = Float64List.fromList(vector),
       metadata = Map<String, Object?>.unmodifiable(metadata);

  /// Restores a record from JSON.
  factory VectorRecord.fromJson(JsonMap json) => VectorRecord(
    id: json.requireString('id'),
    vector: json
        .requireList('vector')
        .map((value) => (value! as num).toDouble())
        .toList(),
    metadata: json.optionalObject('metadata') ?? const <String, Object?>{},
    text: json.optionalString('text'),
  );

  /// Caller-supplied identifier, unique within a namespace.
  final String id;

  /// The embedding.
  ///
  /// Stored as a [Float64List] — unboxed, contiguous doubles. Measured against
  /// the alternatives at 768 dimensions: an unmodifiable `List<double>` costs
  /// 2.4 µs per cosine, this costs 1.4 µs, and an unmodifiable *view* over
  /// typed data costs 4.4 µs because the forwarding defeats the optimiser.
  /// Multiplied by the size of an index on every query, that is the difference
  /// between a search a phone can do and one it cannot.
  ///
  /// The cost is that the returned list is writable. The constructor still
  /// copies, so a record is isolated from the list it was built from — which is
  /// the mutation that happens by accident. Writing into a list the API handed
  /// you is not.
  final Float64List vector;

  /// Payload used for filtering and for rendering a result.
  ///
  /// Keep it small and JSON-encodable. Every remote store transfers this on
  /// every match, so a metadata blob holding a whole document costs bandwidth
  /// on every query rather than once at ingestion.
  final JsonMap metadata;

  /// The text this vector represents, when the store keeps it.
  ///
  /// Optional because storing it doubles the index and some deployments keep
  /// the text in their own database instead, joining on [id].
  final String? text;

  /// Number of components.
  int get dimensions => vector.length;

  /// Whether this record carries its vector.
  ///
  /// A record returned by a search has an empty [vector] unless the query set
  /// [VectorQuery.includeVectors]. That is not a defect — it is the default
  /// because transferring a vector per match is pure cost for a caller that
  /// only wants the text. Code that needs the numbers, such as maximal
  /// marginal relevance, should ask for them and check this.
  bool get hasVector => vector.isNotEmpty;

  /// This record's vector as an [Embedding].
  Embedding get embedding => Embedding(values: vector, text: text);

  /// Returns a copy with selected fields replaced.
  VectorRecord copyWith({
    List<double>? vector,
    JsonMap? metadata,
    String? text,
  }) => VectorRecord(
    id: id,
    vector: vector ?? this.vector,
    metadata: metadata ?? this.metadata,
    text: text ?? this.text,
  );

  /// Serialises the record.
  JsonMap toJson() => pruneNulls(<String, Object?>{
    'id': id,
    'vector': vector,
    'metadata': metadata.isEmpty ? null : metadata,
    'text': text,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is VectorRecord && id == other.id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() => 'VectorRecord($id, ${dimensions}d)';
}

/// A search request.
@immutable
final class VectorQuery {
  /// Creates a query.
  ///
  /// [minScore] is worth setting. Similarity search returns the nearest
  /// neighbours *however far away they are*, so a query with no floor always
  /// returns [topK] results — including for a question the index has nothing
  /// to say about.
  VectorQuery({
    required List<double> vector,
    this.topK = 8,
    this.filter,
    this.minScore = 0,
    this.includeVectors = false,
  }) : vector = Float64List.fromList(vector),
       assert(topK > 0, 'topK must be positive');

  /// Creates a query from an [embedding].
  factory VectorQuery.fromEmbedding(
    Embedding embedding, {
    int topK = 8,
    MetadataFilter? filter,
    double minScore = 0,
    bool includeVectors = false,
  }) => VectorQuery(
    vector: embedding.values,
    topK: topK,
    filter: filter,
    minScore: minScore,
    includeVectors: includeVectors,
  );

  /// The query vector.
  ///
  /// Typed for the same reason as [VectorRecord.vector]: it is one side of
  /// every comparison in a scan.
  final Float64List vector;

  /// How many matches to return.
  final int topK;

  /// Restricts which records are eligible.
  final MetadataFilter? filter;

  /// Minimum similarity for a match to be returned.
  final double minScore;

  /// Whether matches carry their vectors back.
  ///
  /// Off by default: a vector is a kilobyte or two, the caller usually does not
  /// need it, and returning it on every match is pure transfer cost. Turn it on
  /// for re-ranking that needs the vectors, such as maximal marginal relevance.
  final bool includeVectors;

  /// Number of components in the query vector.
  int get dimensions => vector.length;

  /// Returns a copy with selected fields replaced.
  VectorQuery copyWith({
    List<double>? vector,
    int? topK,
    MetadataFilter? filter,
    double? minScore,
    bool? includeVectors,
  }) => VectorQuery(
    vector: vector ?? this.vector,
    topK: topK ?? this.topK,
    filter: filter ?? this.filter,
    minScore: minScore ?? this.minScore,
    includeVectors: includeVectors ?? this.includeVectors,
  );

  /// Serialises the query, excluding the vector.
  JsonMap toJson() => pruneNulls(<String, Object?>{
    'dimensions': dimensions,
    'topK': topK,
    'filter': filter?.toJson(),
    'minScore': minScore == 0 ? null : minScore,
  });

  @override
  String toString() =>
      'VectorQuery(${dimensions}d, topK: $topK'
      '${filter == null ? '' : ', filtered'})';
}

/// One search result.
@immutable
final class VectorMatch {
  /// Creates a match.
  const VectorMatch({required this.record, required this.score});

  /// The matched record.
  final VectorRecord record;

  /// Cosine similarity, from -1 to 1.
  ///
  /// Comparable within one query's results. Comparing scores *across* stores or
  /// across embedding models is meaningless, which is why hybrid retrieval
  /// fuses ranks rather than scores.
  final double score;

  /// The record's identifier.
  String get id => record.id;

  /// The record's text, when it kept any.
  String? get text => record.text;

  /// Serialises the match.
  JsonMap toJson() => <String, Object?>{
    'record': record.toJson(),
    'score': score,
  };

  @override
  String toString() => 'VectorMatch(${record.id}, ${score.toStringAsFixed(3)})';
}
