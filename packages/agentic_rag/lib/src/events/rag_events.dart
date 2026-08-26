/// Events published by the retrieval layer.
///
/// # What these are for
///
/// When a retrieval-backed answer is wrong, there are only two possibilities:
/// the model reasoned badly, or it was handed the wrong passages. Nothing else
/// in the system can tell you which — the answer looks equally confident either
/// way.
///
/// These events settle it. [ChunksRetrieved] records what was asked, what came
/// back and how well it scored; [ChunksReranked] records what the refinement
/// step changed; [AnswerGenerated] records how many of the citations offered
/// were actually used. Identifiers and scores only: an event log that carries
/// passages is one nobody can afford to keep.
library;

import 'package:agentic_core/agentic_core.dart';

/// Base for every retrieval event.
abstract base class RagEvent extends AgenticEvent {
  /// Creates a retrieval event.
  const RagEvent({
    required super.id,
    required super.timestamp,
    super.runId,
    super.source,
    super.traceId,
    super.spanId,
  });
}

/// An ingestion run finished.
final class DocumentsIndexed extends RagEvent {
  /// Creates the event.
  const DocumentsIndexed({
    required super.id,
    required super.timestamp,
    required this.indexed,
    required this.skipped,
    required this.failed,
    required this.chunksWritten,
    required this.chunksRemoved,
    required this.duration,
    super.runId,
    super.source,
    super.traceId,
    super.spanId,
  });

  /// How many documents were embedded and written.
  final int indexed;

  /// How many were unchanged and skipped.
  final int skipped;

  /// How many failed.
  final int failed;

  /// How many chunks were written.
  final int chunksWritten;

  /// How many stale chunks were removed.
  final int chunksRemoved;

  /// How long the run took.
  final Duration duration;

  @override
  String get type => 'rag.documents.indexed';

  @override
  JsonMap payload() => pruneNulls(<String, Object?>{
    'indexed': indexed,
    'skipped': skipped,
    'failed': failed == 0 ? null : failed,
    'chunksWritten': chunksWritten,
    'chunksRemoved': chunksRemoved == 0 ? null : chunksRemoved,
    'durationMs': duration.inMilliseconds,
  });
}

/// Retrieval ran.
///
/// [returned] against [requested] is the number worth watching. A retrieval
/// step that habitually returns fewer passages than asked for means the filter
/// is too narrow, the score floor too high, or the index emptier than anyone
/// believes.
final class ChunksRetrieved extends RagEvent {
  /// Creates the event.
  const ChunksRetrieved({
    required super.id,
    required super.timestamp,
    required this.retriever,
    required this.requested,
    required this.returned,
    required this.duration,
    this.topScore,
    this.chunkIds = const <String>[],
    this.filtered = false,
    super.runId,
    super.source,
    super.traceId,
    super.spanId,
  });

  /// Which retriever ran.
  final String retriever;

  /// How many passages were asked for.
  final int requested;

  /// How many came back.
  final int returned;

  /// The best score, when anything matched.
  final double? topScore;

  /// The passages returned, in order.
  ///
  /// Identifiers, not text. This is what makes an answer reproducible: the same
  /// question against the same index should return the same list, and when it
  /// does not, this is the record that shows what changed.
  final List<String> chunkIds;

  /// Whether a metadata filter was applied.
  final bool filtered;

  /// How long retrieval took.
  final Duration duration;

  @override
  String get type => 'rag.chunks.retrieved';

  @override
  JsonMap payload() => pruneNulls(<String, Object?>{
    'retriever': retriever,
    'requested': requested,
    'returned': returned,
    'topScore': topScore,
    'chunkIds': chunkIds.isEmpty ? null : chunkIds,
    'filtered': filtered ? true : null,
    'durationMs': duration.inMilliseconds,
  });
}

/// A re-ranking step ran.
final class ChunksReranked extends RagEvent {
  /// Creates the event.
  const ChunksReranked({
    required super.id,
    required super.timestamp,
    required this.reranker,
    required this.before,
    required this.after,
    required this.duration,
    this.promoted = 0,
    this.fellBack = false,
    super.runId,
    super.source,
    super.traceId,
    super.spanId,
  });

  /// Which re-ranker ran.
  final String reranker;

  /// How many candidates it was given.
  final int before;

  /// How many it kept.
  final int after;

  /// How many kept passages were not in the retriever's own top [after].
  ///
  /// The measure of whether re-ranking is earning its cost. A step that never
  /// promotes anything is a model call buying nothing.
  final int promoted;

  /// Whether the re-ranker failed and the retriever's ordering was kept.
  final bool fellBack;

  /// How long re-ranking took.
  final Duration duration;

  @override
  String get type => 'rag.chunks.reranked';

  @override
  JsonMap payload() => pruneNulls(<String, Object?>{
    'reranker': reranker,
    'before': before,
    'after': after,
    'promoted': promoted,
    'fellBack': fellBack ? true : null,
    'durationMs': duration.inMilliseconds,
  });
}

/// An answer was generated from retrieved passages.
final class AnswerGenerated extends RagEvent {
  /// Creates the event.
  const AnswerGenerated({
    required super.id,
    required super.timestamp,
    required this.citationsOffered,
    required this.citationsUsed,
    required this.duration,
    this.answeredFromContext = true,
    super.runId,
    super.source,
    super.traceId,
    super.spanId,
  });

  /// How many passages the model was given.
  final int citationsOffered;

  /// How many it actually cited.
  ///
  /// A large gap is the signal that the retrieval step is over-fetching: every
  /// uncited passage was prompt budget spent on nothing.
  final int citationsUsed;

  /// Whether the model reported it could answer from what it was given.
  final bool answeredFromContext;

  /// How long generation took.
  final Duration duration;

  @override
  String get type => 'rag.answer.generated';

  @override
  JsonMap payload() => pruneNulls(<String, Object?>{
    'citationsOffered': citationsOffered,
    'citationsUsed': citationsUsed,
    'answeredFromContext': answeredFromContext,
    'durationMs': duration.inMilliseconds,
  });
}
