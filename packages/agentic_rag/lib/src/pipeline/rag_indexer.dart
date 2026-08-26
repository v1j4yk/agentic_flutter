/// Getting documents into an index, and keeping them current.
library;

import 'package:agentic_core/agentic_core.dart';
import 'package:agentic_rag/src/chunking/chunker.dart';
import 'package:agentic_rag/src/chunking/recursive_chunker.dart';
import 'package:agentic_rag/src/events/rag_events.dart';
import 'package:agentic_rag/src/model/document.dart';
import 'package:agentic_rag/src/retrieval/chunk_codec.dart';
import 'package:agentic_rag/src/retrieval/keyword_retriever.dart';
import 'package:agentic_vector/agentic_vector.dart';
import 'package:meta/meta.dart';

/// What one ingestion run did.
@immutable
final class IndexingReport {
  /// Creates a report.
  IndexingReport({
    required this.duration,
    List<String> indexed = const <String>[],
    List<String> skipped = const <String>[],
    Map<String, String> failed = const <String, String>{},
    this.chunksWritten = 0,
    this.chunksRemoved = 0,
  }) : indexed = List<String>.unmodifiable(indexed),
       skipped = List<String>.unmodifiable(skipped),
       failed = Map<String, String>.unmodifiable(failed);

  /// Documents that were embedded and written.
  final List<String> indexed;

  /// Documents skipped because their content had not changed.
  final List<String> skipped;

  /// Documents that failed, and why.
  final Map<String, String> failed;

  /// How many chunks were written.
  final int chunksWritten;

  /// How many stale chunks were removed.
  final int chunksRemoved;

  /// How long the run took.
  final Duration duration;

  /// Whether every document succeeded.
  bool get isClean => failed.isEmpty;

  /// How many documents were seen.
  int get total => indexed.length + skipped.length + failed.length;

  /// Serialises the report.
  JsonMap toJson() => pruneNulls(<String, Object?>{
    'indexed': indexed.length,
    'skipped': skipped.length,
    'failed': failed.isEmpty ? null : failed,
    'chunksWritten': chunksWritten,
    'chunksRemoved': chunksRemoved,
    'durationMs': duration.inMilliseconds,
  });

  @override
  String toString() =>
      'IndexingReport(${indexed.length} indexed, ${skipped.length} skipped, '
      '${failed.length} failed, $chunksWritten chunks, '
      '${duration.inMilliseconds}ms)';
}

/// Chunks documents, embeds them and writes them to an index.
///
/// # Three things that make re-ingestion safe
///
/// **Stable identifiers.** A chunk is `<documentId>#<index>`, so re-indexing a
/// document replaces its chunks rather than adding a second copy. Retrieval
/// returning the same passage twice is not a cosmetic problem — it consumes the
/// prompt budget and makes the model more confident about whatever it says.
///
/// **Content hashing.** An unchanged document is skipped without embedding it
/// again. Re-embedding an unchanged corpus is the largest avoidable cost in a
/// RAG system, and the fingerprint lives in the index itself, so there is no
/// second table to keep in step.
///
/// **Tail deletion.** A document that used to produce nine chunks and now
/// produces six leaves three stale ones behind. They still match queries and
/// still get cited, quoting text that no longer exists. After writing, the
/// indexer deletes everything at or beyond the new chunk count.
///
/// ```dart
/// final indexer = RagIndexer(
///   index: embeddingIndex,
///   chunker: const MarkdownChunker(),
///   keywordIndex: keywordIndex,
/// );
///
/// final report = await indexer.indexAll(documents);
/// print('${report.indexed.length} indexed, ${report.skipped.length} unchanged');
/// ```
final class RagIndexer {
  /// Creates an indexer.
  ///
  /// [keywordIndex], when given, is kept in step with the vector index so that
  /// a hybrid retriever's two halves never disagree about what exists.
  RagIndexer({
    required this.index,
    this.chunker = const RecursiveChunker(),
    this.keywordIndex,
    this.namespace,
    this.skipUnchanged = true,
    this.storeText = true,
  });

  /// The embedding model and vector store to write to.
  final EmbeddingIndex index;

  /// How documents are split.
  final Chunker chunker;

  /// A lexical index kept in step, when hybrid retrieval is in use.
  final InMemoryKeywordIndex? keywordIndex;

  /// The store partition to write to.
  final String? namespace;

  /// Whether documents whose content hash is unchanged are skipped.
  final bool skipUnchanged;

  /// Whether chunk text is stored alongside its vector.
  ///
  /// On by default, and it should stay on unless the text lives somewhere else
  /// you can join to: retrieval that cannot return the passage cannot build a
  /// prompt or a citation from it.
  final bool storeText;

  /// Chunks, embeds and writes [documents].
  ///
  /// Documents are processed one at a time. A failure is recorded against that
  /// document and the run continues — one unreadable file must not abandon an
  /// ingestion of ten thousand.
  Future<IndexingReport> indexAll(
    Iterable<RagDocument> documents, {
    AgenticContext? context,
  }) async {
    final clock = context?.clock ?? const SystemClock();
    final started = clock.now();
    final indexed = <String>[];
    final skipped = <String>[];
    final failed = <String, String>{};
    var written = 0;
    var removed = 0;

    for (final document in documents) {
      context?.throwIfCancelled();
      try {
        final result = await indexOne(document, context: context);
        if (result.skipped) {
          skipped.add(document.id);
        } else {
          indexed.add(document.id);
          written += result.written;
          removed += result.removed;
        }
      } on CancelledException {
        rethrow;
      } on AgenticException catch (error) {
        failed[document.id] = error.message;
        context?.logger.warn(
          'Failed to index a document; continuing',
          fields: <String, Object?>{
            'document': document.id,
            'code': error.code,
          },
          error: error,
        );
      }
    }

    final report = IndexingReport(
      indexed: indexed,
      skipped: skipped,
      failed: failed,
      chunksWritten: written,
      chunksRemoved: removed,
      duration: clock.now().difference(started),
    );

    context?.publish(
      DocumentsIndexed(
        id: context.ids.prefixed('evt'),
        timestamp: clock.now(),
        indexed: indexed.length,
        skipped: skipped.length,
        failed: failed.length,
        chunksWritten: written,
        chunksRemoved: removed,
        duration: report.duration,
        runId: context.runId,
        source: 'rag:indexer',
      ),
    );
    return report;
  }

  /// Indexes one document.
  ///
  /// Returns how many chunks were written and how many stale ones removed, and
  /// whether the document was skipped as unchanged.
  Future<({bool skipped, int written, int removed})> indexOne(
    RagDocument document, {
    AgenticContext? context,
  }) async {
    final hash = document.contentHash;

    if (skipUnchanged && await _isUnchanged(document.id, hash)) {
      return (skipped: true, written: 0, removed: 0);
    }

    final chunks = chunker.chunk(document);
    if (chunks.isEmpty) {
      // An empty document is not an error — a placeholder file, a page that was
      // all markup — but its old chunks must still go.
      final removed = await _removeStaleTail(document.id, 0);
      keywordIndex?.removeDocument(document.id);
      return (skipped: false, written: 0, removed: removed);
    }

    await index.addTexts(
      <String>[for (final chunk in chunks) chunk.text],
      ids: <String>[for (final chunk in chunks) chunk.id],
      metadatas: <JsonMap>[
        for (final chunk in chunks) chunkMetadata(chunk, contentHash: hash),
      ],
      storeText: storeText,
      namespace: namespace,
      context: context,
    );

    final removed = await _removeStaleTail(document.id, chunks.length);

    final keywords = keywordIndex;
    if (keywords != null) {
      keywords
        ..removeDocument(document.id)
        ..addAll(chunks);
    }

    return (skipped: false, written: chunks.length, removed: removed);
  }

  /// Removes every trace of [documentId], returning how many chunks went.
  Future<int> remove(String documentId, {AgenticContext? context}) async {
    keywordIndex?.removeDocument(documentId);
    return index.deleteWhere(documentFilter(documentId), namespace: namespace);
  }

  /// Whether the stored copy of [documentId] already has this [hash].
  ///
  /// Reads the document's first chunk rather than counting or scanning: one
  /// point lookup per document, which is what keeps "re-ingest everything"
  /// cheap enough to run on every launch.
  Future<bool> _isUnchanged(String documentId, String hash) async {
    final first = await index.store.get('$documentId#0', namespace: namespace);
    return first != null && first.metadata[kContentHashKey] == hash;
  }

  Future<int> _removeStaleTail(String documentId, int keptChunks) =>
      index.deleteWhere(
        staleTailFilter(documentId, keptChunks),
        namespace: namespace,
      );

  @override
  String toString() => 'RagIndexer(${chunker.name})';
}
