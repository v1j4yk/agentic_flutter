/// What goes into a retrieval index, and what comes back out.
///
/// # Three types, three jobs
///
/// A [RagDocument] is what a user gave you — a file, a page, an article. A
/// [DocumentChunk] is a retrievable piece of one, because whole documents are
/// the wrong unit: too long to fit a prompt, and too diluted to rank well. A
/// [RetrievedChunk] is a chunk plus why it came back, which is what makes an
/// answer auditable.
///
/// Keeping them separate matters. Code that merges "the source" with "the piece
/// I retrieved" loses the ability to say *where* an answer came from, and
/// citation is the difference between a retrieval system and a plausible one.
library;

import 'dart:convert';

import 'package:agentic_core/agentic_core.dart';
import 'package:meta/meta.dart';

/// Joins a document name and a heading path into one readable label.
///
/// A Markdown chunker builds the heading path from the document's own headings,
/// which for a single-title document starts with the title itself. Naive
/// concatenation then produces "Handbook › Handbook › Refunds" on every
/// citation — visible to end users, and exactly the kind of small wrongness
/// that makes a citation look untrustworthy. This drops the repetition.
String formatSourceLabel(String name, String? heading) {
  if (heading == null || heading.isEmpty) return name;
  if (heading == name) return name;
  if (heading.startsWith('$name › ')) return heading;
  return '$name › $heading';
}

/// A source document, before it is chunked.
@immutable
final class RagDocument {
  /// Creates a document.
  ///
  /// [id] is the caller's stable key — a path, a URL, a database identifier.
  /// Stability is what makes re-ingestion replace a document instead of
  /// duplicating it, so prefer something derived from the source over a random
  /// value.
  RagDocument({
    required this.id,
    required this.content,
    this.title,
    this.source,
    JsonMap metadata = const <String, Object?>{},
  }) : metadata = Map<String, Object?>.unmodifiable(metadata);

  /// Restores a document from JSON.
  factory RagDocument.fromJson(JsonMap json) => RagDocument(
    id: json.requireString('id'),
    content: json.requireString('content'),
    title: json.optionalString('title'),
    source: json.optionalString('source'),
    metadata: json.optionalObject('metadata') ?? const <String, Object?>{},
  );

  /// Stable identifier for the source.
  final String id;

  /// The full text.
  final String content;

  /// A human-readable name, shown in citations.
  final String? title;

  /// Where it came from — a URL, a path, a table row.
  final String? source;

  /// Anything worth filtering or citing on: author, date, tenant, section.
  ///
  /// Copied onto every chunk at ingestion, which is what makes
  /// "search only this tenant's manuals from this year" a single filter rather
  /// than a join.
  final JsonMap metadata;

  /// A content fingerprint, used to skip documents that have not changed.
  ///
  /// Cheap and stable: re-embedding an unchanged corpus is the single largest
  /// avoidable cost in a RAG system, and comparing hashes avoids it without a
  /// separate bookkeeping table.
  String get contentHash => _stableHash(content);

  /// Returns a copy with selected fields replaced.
  RagDocument copyWith({
    String? content,
    String? title,
    String? source,
    JsonMap? metadata,
  }) => RagDocument(
    id: id,
    content: content ?? this.content,
    title: title ?? this.title,
    source: source ?? this.source,
    metadata: metadata ?? this.metadata,
  );

  /// Serialises the document.
  JsonMap toJson() => pruneNulls(<String, Object?>{
    'id': id,
    'content': content,
    'title': title,
    'source': source,
    'metadata': metadata.isEmpty ? null : metadata,
  });

  @override
  String toString() =>
      'RagDocument($id, ${content.length} chars'
      '${title == null ? '' : ', "$title"'})';
}

/// One retrievable piece of a document.
@immutable
final class DocumentChunk {
  /// Creates a chunk.
  DocumentChunk({
    required this.id,
    required this.documentId,
    required this.text,
    required this.index,
    this.title,
    this.source,
    this.heading,
    this.startOffset,
    JsonMap metadata = const <String, Object?>{},
  }) : metadata = Map<String, Object?>.unmodifiable(metadata);

  /// Restores a chunk from JSON.
  factory DocumentChunk.fromJson(JsonMap json) => DocumentChunk(
    id: json.requireString('id'),
    documentId: json.requireString('documentId'),
    text: json.requireString('text'),
    index: json.requireInt('index'),
    title: json.optionalString('title'),
    source: json.optionalString('source'),
    heading: json.optionalString('heading'),
    startOffset: json.optionalInt('startOffset'),
    metadata: json.optionalObject('metadata') ?? const <String, Object?>{},
  );

  /// Identifier, conventionally `<documentId>#<index>`.
  final String id;

  /// The document this came from.
  final String documentId;

  /// The retrievable text.
  final String text;

  /// Position within the document, from zero.
  ///
  /// Kept because adjacent chunks are the cheapest form of context expansion:
  /// having found chunk 7, fetching 6 and 8 often turns a fragment into an
  /// answer.
  final int index;

  /// The document's title, denormalised for citation.
  final String? title;

  /// Where the document came from, denormalised for citation.
  ///
  /// Duplicated onto the chunk on purpose: a citation must be renderable from
  /// what retrieval returned, without a second lookup that may not be possible
  /// on a device that is offline.
  final String? source;

  /// The heading this chunk sits under, when the format had one.
  final String? heading;

  /// Character offset of this chunk in the source document.
  final int? startOffset;

  /// Document metadata plus anything the chunker added.
  final JsonMap metadata;

  /// How long the chunk is, in characters.
  int get length => text.length;

  /// A one-line label for a citation list.
  String get label => formatSourceLabel(title ?? source ?? documentId, heading);

  /// Returns a copy with selected fields replaced.
  DocumentChunk copyWith({String? text, JsonMap? metadata}) => DocumentChunk(
    id: id,
    documentId: documentId,
    text: text ?? this.text,
    index: index,
    title: title,
    source: source,
    heading: heading,
    startOffset: startOffset,
    metadata: metadata ?? this.metadata,
  );

  /// Serialises the chunk.
  JsonMap toJson() => pruneNulls(<String, Object?>{
    'id': id,
    'documentId': documentId,
    'text': text,
    'index': index,
    'title': title,
    'source': source,
    'heading': heading,
    'startOffset': startOffset,
    'metadata': metadata.isEmpty ? null : metadata,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is DocumentChunk && id == other.id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() => 'DocumentChunk($id, ${text.length} chars)';
}

/// A chunk that came back from retrieval, and why.
@immutable
final class RetrievedChunk {
  /// Creates a retrieved chunk.
  const RetrievedChunk({
    required this.chunk,
    required this.score,
    this.retriever,
    this.rank,
  });

  /// What was retrieved.
  final DocumentChunk chunk;

  /// Its relevance, higher being better.
  ///
  /// Comparable within one result list only. Fused and re-ranked results carry
  /// scores on entirely different scales, which is why ordering — not the
  /// number — is what downstream code should rely on.
  final double score;

  /// Which retriever produced it, when more than one was involved.
  final String? retriever;

  /// Its position in the final ordering, from zero.
  final int? rank;

  /// The chunk's identifier.
  String get id => chunk.id;

  /// The chunk's text.
  String get text => chunk.text;

  /// Returns a copy with a new score, rank or attribution.
  RetrievedChunk copyWith({double? score, String? retriever, int? rank}) =>
      RetrievedChunk(
        chunk: chunk,
        score: score ?? this.score,
        retriever: retriever ?? this.retriever,
        rank: rank ?? this.rank,
      );

  /// Serialises the result, excluding the chunk text.
  ///
  /// The text is left out deliberately: these end up in logs and traces, and a
  /// trace that carries whole passages is one nobody can afford to keep.
  JsonMap toJson() => pruneNulls(<String, Object?>{
    'id': chunk.id,
    'documentId': chunk.documentId,
    'index': chunk.index,
    'score': score,
    'retriever': retriever,
    'rank': rank,
  });

  @override
  String toString() =>
      'RetrievedChunk(${chunk.id}, ${score.toStringAsFixed(3)})';
}

/// A reference an answer can point at.
@immutable
final class Citation {
  /// Creates a citation.
  const Citation({
    required this.marker,
    required this.documentId,
    required this.chunkId,
    this.title,
    this.source,
    this.heading,
    this.quote,
  });

  /// Builds a citation for [chunk] under [marker].
  factory Citation.forChunk(
    DocumentChunk chunk, {
    required String marker,
    bool includeQuote = false,
  }) => Citation(
    marker: marker,
    documentId: chunk.documentId,
    chunkId: chunk.id,
    title: chunk.title,
    source: chunk.source,
    heading: chunk.heading,
    quote: includeQuote ? chunk.text : null,
  );

  /// The label used in the prompt and the answer, such as `1`.
  ///
  /// A number rather than an identifier: models reproduce `[1]` reliably and
  /// mangle `[guide.md#7]`, and the mapping back is this object's job.
  final String marker;

  /// The document cited.
  final String documentId;

  /// The chunk cited.
  final String chunkId;

  /// The document's title.
  final String? title;

  /// Where the document came from.
  final String? source;

  /// The section cited.
  final String? heading;

  /// The passage handed to the model, when it is worth keeping.
  final String? quote;

  /// A one-line rendering, such as `[1] Handbook › Billing (handbook.md)`.
  String get label {
    final name = title ?? source ?? documentId;
    final origin = source == null || source == name ? '' : ' ($source)';
    return '[$marker] ${formatSourceLabel(name, heading)}$origin';
  }

  /// Serialises the citation.
  JsonMap toJson() => pruneNulls(<String, Object?>{
    'marker': marker,
    'documentId': documentId,
    'chunkId': chunkId,
    'title': title,
    'source': source,
    'heading': heading,
    'quote': quote,
  });

  @override
  String toString() => label;
}

/// A stable content fingerprint, identical on every platform and every run.
///
/// FNV-1a run twice with different offsets, giving 64 bits as hex. Written out
/// rather than pulled from a hashing dependency for the same reason the rest of
/// the framework avoids one: it is fifteen lines, and every arithmetic step is
/// masked to 32 bits so that native and JavaScript agree. `Object.hashCode`
/// would not do — it is not stable across runs, which is exactly what a
/// fingerprint has to be.
String _stableHash(String text) {
  final bytes = utf8.encode(text);
  var a = 0x811c9dc5;
  var b = 0x01000193;
  for (final byte in bytes) {
    a = ((a ^ byte) * 0x01000193) & 0xffffffff;
    b = ((b ^ byte) * 0x01000193) & 0xffffffff;
    b = (b + (b << 3)) & 0xffffffff;
  }
  return a.toRadixString(16).padLeft(8, '0') +
      b.toRadixString(16).padLeft(8, '0');
}
