---
name: agentic-rag-index-documents
description: >-
  Use when getting documents into a searchable index with agentic_rag:
  RagDocument, loaders, chunkers and ChunkOptions, RagIndexer and its
  IndexingReport, re-indexing safely when documents change, and RagStack for
  the whole thing in one object. Read this for "index my notes", "documents
  indexed but nothing is found", or choosing a chunk size.
license: MIT
metadata:
  package: agentic_rag
  min-version: 0.2.0
---

# Indexing documents

## The fast path

`RagStack` wires loader, chunker, index and retriever together:

```dart
final rag = RagStack(
  embeddings: embeddingModel,     // omit for keyword-only search
  store: InMemoryVectorStore(dimensions: 768, name: 'handbook'),
  model: chatModel,               // omit if you only want passages, not answers
  chunker: const MarkdownChunker(),
);

final report = await rag.index([
  RagDocument(id: 'handbook', content: markdown, title: 'Handbook', source: 'handbook.md'),
]);

final hits = await rag.search('holiday policy');
final answer = await rag.answer('How much holiday do I get?');
```

Keyword-only (`RagSearchMode.keyword`) needs no embedding model and no network,
which makes it the right first step: the app works offline, and semantics can be
switched on later.

## Always read the report

```dart
if (!report.isClean) {
  for (final MapEntry(key: id, value: reason) in report.failed.entries) {
    log.error('$id failed to index: $reason');
  }
}
print('${report.chunksWritten} chunks, ${report.skipped.length} unchanged');
```

`RagIndexer` records a failed document rather than throwing, so ignoring
`report.failed` is how "indexed successfully, finds nothing" happens. That is a
real bug this framework has shipped: a retired embedding model failed every
document, and the app reported success.

## Chunking

```dart
const RecursiveChunker(options: ChunkOptions(maxChars: 1000, overlapChars: 150));
const MarkdownChunker(maxHeadingDepth: 3, prependHeading: true);   // keeps headings
const FixedSizeChunker();                                          // last resort
```

Rules of thumb:

- **Too large** and retrieval returns a page when the answer is a sentence,
  diluting the score and wasting context.
- **Too small** and a chunk loses the context that makes it answerable.
- 800–1200 characters with ~15 % overlap suits prose; code and tables want
  structural splitting, not character counts.
- `MarkdownChunker(prependHeading: true)` puts the heading into the chunk, which
  is the cheapest quality win available — a chunk that says what section it is
  from retrieves far better.

## Re-indexing safely

`RagIndexer` makes a second run safe three ways, which matter the moment
documents change:

```dart
final indexer = RagIndexer(
  index: embeddingIndex,
  chunker: const MarkdownChunker(),
  keywordIndex: InMemoryKeywordIndex(),
  skipUnchanged: true,   // content fingerprint: unchanged documents are not re-embedded
  storeText: true,       // keep chunk text in the store, so search can show it
);

await indexer.indexAll(documents);   // stable ids: a re-run replaces, never duplicates
await indexer.remove('handbook');    // and removes every chunk of it
```

Stable `<documentId>#<index>` ids mean a re-run replaces chunks rather than
duplicating them, the fingerprint skips unchanged documents (the expensive part
is embedding), and a shortened document has its tail deleted — otherwise orphan
chunks keep matching and keep being cited.

## Metadata is what filters later

```dart
RagDocument(
  id: 'policy-2026',
  content: text,
  title: 'Travel policy',
  source: 'https://intranet/policy',
  metadata: {'team': 'ops', 'year': 2026, 'public': true},
);
```

Reserved keys (`documentId`, `chunkIndex`, `source`, `title`, `heading`,
`contentHash`, `startOffset`) are set by the indexer; yours travel alongside and
become `MetadataFilter` conditions at query time. Decide the filters you will
need *before* indexing, because adding one later means re-indexing.

## Keeping an index on the device

```dart
final store = InMemoryVectorStore(dimensions: 768, name: 'handbook');
// … index once …
await file.writeAsString(jsonEncode(store.toJson()));   // ship it, or cache it
```

An app that embeds its corpus at build time and restores the snapshot at
startup does no network work to search. For memory that outgrows that,
`agentic_sqlite` keeps vectors on disk.

## Common mistakes

- Ignoring `report.failed`.
- Re-indexing with fresh random ids each run, so the store fills with duplicates
  that all match.
- Indexing whole PDFs-as-text with no structure and a 4000-character chunk size.
- Changing embedding model without re-embedding: the spaces are not comparable,
  and the results are plausible nonsense rather than an error.
- Storing no metadata, then needing per-team filtering.

## See also

- `agentic-rag-answer-with-citations` — asking questions of what you indexed
- `agentic-rag-tune-retrieval` — when the right chunk is not coming back
- `agentic-vector-choose-store` — where the vectors live
