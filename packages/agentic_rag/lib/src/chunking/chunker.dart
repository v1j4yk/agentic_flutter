/// Splitting documents into retrievable pieces.
///
/// # Why chunking decides how good retrieval is
///
/// Chunking is the highest-leverage and least-glamorous decision in a RAG
/// system. Chunks that are too large dilute the embedding — a 4,000-character
/// page about six subjects is close to nothing in particular — and waste prompt
/// budget on text the question did not ask about. Chunks that are too small win
/// the similarity contest and then answer nothing, because the sentence that
/// matched has lost the paragraph that explained it.
///
/// The defaults here — around a thousand characters with a modest overlap,
/// split along natural boundaries — are a reasonable middle for prose and
/// documentation. They are defaults, not physics: measure on your own corpus.
///
/// # Overlap is not waste
///
/// Overlapping chunks repeat some text, and that repetition is the point. The
/// sentence that answers a question frequently sits across a boundary; without
/// overlap it belongs wholly to neither neighbour and is retrievable by
/// neither.
library;

import 'package:agentic_core/agentic_core.dart';
import 'package:agentic_rag/src/model/document.dart';
import 'package:meta/meta.dart';

/// How a document is split.
@immutable
final class ChunkOptions {
  /// Creates chunking options.
  const ChunkOptions({
    this.maxChars = 1000,
    this.overlapChars = 150,
    this.minChars = 80,
  }) : assert(maxChars > 0, 'maxChars must be positive'),
       assert(
         overlapChars >= 0 && overlapChars < maxChars,
         'overlapChars must be smaller than maxChars, or splitting cannot '
         'make progress',
       ),
       assert(minChars >= 0, 'minChars cannot be negative');

  /// Upper bound on a chunk, in characters.
  ///
  /// Characters rather than tokens on purpose. Counting tokens needs the
  /// model's tokeniser, which differs per provider, may not exist in Dart, and
  /// would make chunking a network-dependent operation. Roughly four characters
  /// per token is close enough to budget with, and being approximate here costs
  /// far less than being unable to chunk offline.
  final int maxChars;

  /// How much of the previous chunk each chunk repeats.
  final int overlapChars;

  /// Below this, a trailing fragment is folded into its predecessor.
  ///
  /// Prevents the "and finally." chunk: a twelve-character tail that embeds to
  /// noise and occasionally outranks real content.
  final int minChars;

  /// Approximate token budget these options correspond to.
  int get approximateTokens => maxChars ~/ 4;

  /// Returns a copy with selected fields replaced.
  ChunkOptions copyWith({int? maxChars, int? overlapChars, int? minChars}) =>
      ChunkOptions(
        maxChars: maxChars ?? this.maxChars,
        overlapChars: overlapChars ?? this.overlapChars,
        minChars: minChars ?? this.minChars,
      );

  /// Serialises the options.
  JsonMap toJson() => <String, Object?>{
    'maxChars': maxChars,
    'overlapChars': overlapChars,
    'minChars': minChars,
  };

  @override
  String toString() => 'ChunkOptions($maxChars/$overlapChars)';
}

/// Splits a document into chunks.
///
/// Implement this for a format the shipped chunkers do not understand — code,
/// subtitles, transcripts with speaker turns. The contract:
///
/// * chunks are returned in document order, with `index` counting from zero;
/// * `id` is `<documentId>#<index>`, so re-ingestion replaces rather than
///   duplicates;
/// * document metadata is carried onto every chunk;
/// * no chunk is empty or whitespace-only.
abstract interface class Chunker {
  /// A short name, used in events and traces.
  String get name;

  /// Splits [document].
  List<DocumentChunk> chunk(RagDocument document);
}

/// Shared machinery for chunkers.
///
/// Extending this rather than implementing [Chunker] directly gets the
/// identifier convention, metadata propagation and the small-tail rule for
/// free — the three things every chunker has to do identically for the rest of
/// the pipeline to work.
abstract base class BaseChunker implements Chunker {
  /// Creates a chunker with [options].
  const BaseChunker({this.options = const ChunkOptions()});

  /// How this chunker splits.
  final ChunkOptions options;

  /// Produces the text pieces, in order.
  ///
  /// Each piece may carry a heading and its offset in the source. Everything
  /// else — identifiers, metadata, ordering — is added by [chunk].
  @protected
  List<ChunkPiece> split(RagDocument document);

  @override
  List<DocumentChunk> chunk(RagDocument document) {
    final pieces = split(document);
    final chunks = <DocumentChunk>[];
    for (final piece in pieces) {
      final text = piece.text.trim();
      if (text.isEmpty) continue;
      chunks.add(
        DocumentChunk(
          id: '${document.id}#${chunks.length}',
          documentId: document.id,
          text: text,
          index: chunks.length,
          title: document.title,
          source: document.source,
          heading: piece.heading,
          startOffset: piece.startOffset,
          metadata: <String, Object?>{...document.metadata, ...piece.metadata},
        ),
      );
    }
    return List<DocumentChunk>.unmodifiable(chunks);
  }
}

/// A piece of text produced by a chunker, before it becomes a chunk.
@immutable
final class ChunkPiece {
  /// Creates a piece.
  const ChunkPiece({
    required this.text,
    this.heading,
    this.startOffset,
    this.metadata = const <String, Object?>{},
  });

  /// The text.
  final String text;

  /// The section this piece sits under, when the format has sections.
  final String? heading;

  /// Where it starts in the source document.
  final int? startOffset;

  /// Anything the chunker learned that is worth filtering on.
  final JsonMap metadata;

  @override
  String toString() => 'ChunkPiece(${text.length} chars)';
}

/// Conveniences available on every [Chunker].
extension ChunkerOperations on Chunker {
  /// Chunks several documents.
  List<DocumentChunk> chunkAll(Iterable<RagDocument> documents) =>
      <DocumentChunk>[for (final document in documents) ...chunk(document)];
}
