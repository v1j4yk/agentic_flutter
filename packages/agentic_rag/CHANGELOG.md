# Changelog

## 0.2.0

- `searchTool` and `answeringTool` return untrusted content: their passages come
  from documents, and a document can contain instructions.
  **Behaviour change**, so this ships in 0.2.0 only: a tool that is not
  read-only, called after one of these tools returned, now needs approval.

## 0.1.2

- `RagStack`: indexing, retrieval, a search tool and cited answers assembled
  in one call, in keyword-only or hybrid mode. Keyword-only needs no embedding
  model and involves no placeholder vectors.
- `RagPipeline.stream` and `RagStack.stream`: sources first (`RagSourcesReady`),
  then text (`RagAnswerDelta`), then the cited answer (`RagAnswerCompleted`),
  with the same citations, event and cost as `answer`.
- `InMemoryKeywordIndex.containsDocument`. Removing a document now touches its
  own chunks instead of scanning every chunk in the index.
- **Fix:** after a restart with a durable vector store, hybrid retrieval lost
  its keyword half. Unchanged documents are skipped without re-embedding, and
  the skip returned before the in-memory keyword index was refilled. Skipped
  documents now repopulate a keyword index that lacks them.

- `searchTool` and `answeringTool` accept a `description` override, as the
  platform tools in `agentic_flutter` already do. Prefer `corpus` when it is
  enough: the default description carries the advice to search again with
  different wording, which is worth keeping.

## 0.1.1

- Tightened the package description. This one already scored full marks; the
  change keeps the wording consistent with its sibling packages, which did
  not.

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
