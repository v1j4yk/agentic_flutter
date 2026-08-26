/// The bridge between a document chunk and a stored vector.
///
/// # Why a codec rather than a shared class
///
/// `agentic_vector` knows about vectors and payloads; it must not learn what a
/// document is. `agentic_rag` knows about documents; it must not reach into a
/// store's schema. This file is the seam: one place that says how a chunk is
/// written into a record's metadata and read back out.
///
/// The reserved keys are prefixed and contain no dots. The prefix keeps them
/// from colliding with a caller's own metadata, and the absence of dots matters
/// because several backends — Qdrant among them — treat a dot in a payload key
/// as a path into a nested object, which would turn `rag.documentId` into a
/// field nobody can filter on.
library;

import 'package:agentic_core/agentic_core.dart';
import 'package:agentic_rag/src/model/document.dart';
import 'package:agentic_vector/agentic_vector.dart';

/// Metadata key holding the source document's identifier.
const String kDocumentIdKey = '_rag_documentId';

/// Metadata key holding the chunk's position within its document.
const String kChunkIndexKey = '_rag_chunkIndex';

/// Metadata key holding the document title.
const String kTitleKey = '_rag_title';

/// Metadata key holding where the document came from.
const String kSourceKey = '_rag_source';

/// Metadata key holding the heading a chunk sits under.
const String kHeadingKey = '_rag_heading';

/// Metadata key holding the chunk's character offset in its document.
const String kStartOffsetKey = '_rag_startOffset';

/// Metadata key holding the source document's content fingerprint.
///
/// What makes "has this document changed?" answerable from the index itself,
/// with no separate bookkeeping table to keep in step.
const String kContentHashKey = '_rag_contentHash';

/// Every key this package reserves.
const Set<String> kReservedMetadataKeys = <String>{
  kDocumentIdKey,
  kChunkIndexKey,
  kTitleKey,
  kSourceKey,
  kHeadingKey,
  kStartOffsetKey,
  kContentHashKey,
};

/// Builds the metadata a chunk is stored with.
///
/// [contentHash] is the source document's fingerprint, when the indexer is
/// tracking one.
JsonMap chunkMetadata(DocumentChunk chunk, {String? contentHash}) =>
    pruneNulls(<String, Object?>{
      ...chunk.metadata,
      kDocumentIdKey: chunk.documentId,
      kChunkIndexKey: chunk.index,
      kTitleKey: chunk.title,
      kSourceKey: chunk.source,
      kHeadingKey: chunk.heading,
      kStartOffsetKey: chunk.startOffset,
      kContentHashKey: contentHash,
    });

/// Reconstructs a chunk from a stored [record].
///
/// Returns `null` when the record was not written by this package — an index
/// shared with something else, or a record predating the current keys. Callers
/// skip those rather than fabricating a document identifier, because a citation
/// pointing at an invented source is worse than no citation.
DocumentChunk? chunkFromRecord(VectorRecord record) {
  final documentId = record.metadata[kDocumentIdKey];
  if (documentId is! String) return null;

  final index = record.metadata[kChunkIndexKey];
  return DocumentChunk(
    id: record.id,
    documentId: documentId,
    text: record.text ?? '',
    index: index is num ? index.toInt() : 0,
    title: record.metadata[kTitleKey] as String?,
    source: record.metadata[kSourceKey] as String?,
    heading: record.metadata[kHeadingKey] as String?,
    startOffset: (record.metadata[kStartOffsetKey] as num?)?.toInt(),
    metadata: userMetadata(record.metadata),
  );
}

/// Strips this package's reserved keys from [metadata].
JsonMap userMetadata(JsonMap metadata) => <String, Object?>{
  for (final entry in metadata.entries)
    if (!kReservedMetadataKeys.contains(entry.key)) entry.key: entry.value,
};

/// A filter matching every chunk of [documentId].
MetadataFilter documentFilter(String documentId) =>
    MetadataFilter.equals(kDocumentIdKey, documentId);

/// A filter matching chunks of [documentId] at or beyond [index].
///
/// Used to clear the tail a shorter re-ingestion leaves behind: upserting six
/// chunks over a document that previously had nine replaces the first six and
/// silently leaves three stale ones behind, still retrievable, still cited.
MetadataFilter staleTailFilter(String documentId, int index) =>
    MetadataFilter.and(<MetadataFilter>[
      documentFilter(documentId),
      MetadataFilter.greaterThan(kChunkIndexKey, index - 1),
    ]);
