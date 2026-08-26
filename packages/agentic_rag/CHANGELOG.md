# Changelog

## 0.1.0

Initial release of the retrieval layer.

### Added

- **Values** — `RagDocument`, `DocumentChunk`, `RetrievedChunk` and `Citation`.
  Kept separate so an answer can always say which document, and which part of
  it, a claim came from. Documents carry a stable content fingerprint.
- **Chunking** — `Chunker` port with `BaseChunker` supplying the identifier
  convention and metadata propagation; `RecursiveChunker` splitting at the
  strongest boundary that fits, `MarkdownChunker` splitting at headings and
  putting the heading path into the chunk text so heading terms stay
  searchable, and `FixedSizeChunker` as an honest baseline.
- **Loading** — `DocumentLoader` port with `TextDocumentLoader`,
  `MarkdownDocumentLoader` (YAML front matter to metadata, first heading to
  title), `HtmlDocumentLoader` (dependency-free text extraction and entity
  decoding) and `CompositeDocumentLoader`. Nothing touches `dart:io`, so the
  package runs on the web.
- **Ingestion** — `RagIndexer`, which chunks, embeds and writes; skips
  unchanged documents by fingerprint; deletes the stale tail a shortened
  document leaves behind; keeps a keyword index in step; and records one
  failure without abandoning the run.
- **Retrieval** — `Retriever` port; `VectorRetriever` over an `EmbeddingIndex`;
  `KeywordRetriever` with a real BM25 `InMemoryKeywordIndex`; `HybridRetriever`
  fusing rankings with reciprocal rank fusion, optionally weighted; and
  `NeighbourExpandingRetriever` for adjacent-chunk context.
- **Re-ranking** — `Reranker` port; `ScoreFloorReranker`, `MmrReranker` for
  diversity (refusing to run without vectors rather than degrading silently),
  `LlmReranker` which falls back to the retriever's ordering on failure, and
  `ChainedReranker` for cheap-before-expensive ordering.
- **Pipeline** — `RagPipeline` assembling numbered passages within a character
  budget, generating a cited answer, and resolving markers back to documents;
  `RagContext` reporting what it dropped and `RagAnswer` reporting whether the
  answer was grounded at all.
- **Tools** — `searchTool` so an agent decides when to search, and
  `answeringTool` for a corpus that deserves its own specialist.
- **Events** — `DocumentsIndexed`, `ChunksRetrieved` (carrying the identifiers
  that make an answer reproducible), `ChunksReranked` (carrying how many
  passages the step actually promoted) and `AnswerGenerated` (offered against
  used, the over-fetching signal).
