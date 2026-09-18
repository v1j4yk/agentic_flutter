# Phase 3c — Feature innovation: knowledge layer

`agentic_vector` · `agentic_rag` · `agentic_sqlite`

Entry format as in [03a](03a-features-foundation.md).

---

## `agentic_vector` — 10 features

### VEC-1 · Adapter pack: pgvector/Supabase, Pinecone, Chroma, Weaviate, Turbopuffer — **Must Have**

| Complexity | Effort | Breaking | Deps |
|---|---|---|---|
| Medium each | 3–4 d each, ~4 wk total | No | `postgres` for pgvector; others HTTP only |

**Why.** A developer chooses a framework partly by whether it supports the
store they already run. Supabase is the most common Flutter backend after
Firebase, and its vector search is pgvector.

**Use cases.** Supabase-backed Flutter apps; server-side Dart RAG over an
existing Pinecone index.

**API.** Each is a separate package depending only on `agentic_vector`, e.g.
`agentic_vector_pgvector`:

```dart
final store = PgVectorStore(
  connection: await Connection.open(endpoint),
  table: 'documents',
  dimensions: 768,
  metric: SimilarityMetric.cosine,
  index: PgVectorIndex.hnsw(m: 16, efConstruction: 64),
);
```

Every adapter must pass a shared `vectorStoreConformance()` suite comparing
rankings with `InMemoryVectorStore`, which already exists for this purpose.

---

### VEC-2 · ObjectBox adapter (on-device HNSW) — **Must Have**

| Complexity | Effort | Breaking | Deps |
|---|---|---|---|
| Medium | 1 wk | No | `objectbox` (separate package) |

**Why.** ObjectBox 4 added on-device HNSW vector search and is already an
established Flutter database. It removes the ~50 k-vector ceiling on phones
without writing a native index.

**API.** `ObjectBoxVectorStore(store: objectBoxStore, dimensions: 768)` with
metadata filters translated to ObjectBox query conditions where possible and
applied post-query otherwise (reported via `VectorStoreInfo`).

---

### VEC-3 · Float32 storage and quantisation — **High Value**

| Complexity | Effort | Breaking | Deps |
|---|---|---|---|
| Medium | 1 wk | **Soft** — `Embedding.values` stays `List<double>`; storage changes only | none |

**Why.** `Float64List` doubles memory against what every embedding model
produces. Scalar (int8) quantisation cuts it 8× with typically small recall loss;
binary quantisation 32× for first-pass filtering.

**API.** `InMemoryVectorStore(precision: VectorPrecision.float32)`,
`VectorPrecision.int8`, `VectorPrecision.binary(rescoreTopK: 100)`.

---

### VEC-4 · In-process HNSW index — **Future**

| Complexity | Effort | Breaking | Deps |
|---|---|---|---|
| High | 3 wk | No | none (pure Dart) |

**Why.** Pure-Dart ANN for web and desktop where ObjectBox or sqlite-vec is
unavailable, above ~100 k records.

**API.** `HnswVectorStore(m: 16, efSearch: 64)` with snapshot support, benchmarked
in `agentic_benchmark` against exact search for recall@10.

---

### VEC-5 · Isolate-backed search — **High Value**

| Complexity | Effort | Breaking | Deps |
|---|---|---|---|
| Low | 4 d | No | CORE-4 |

**Why.** Brute-force search over 20 k × 768 on a mid-range Android phone takes
tens of milliseconds — enough to drop frames if it runs on the UI isolate.

**API.** `IsolateVectorStore(InMemoryVectorStore(...))` — a
`DelegatingVectorStore` that holds vectors in a long-lived worker isolate using
`TransferableTypedData`.

---

### VEC-6 · Sparse vectors and native hybrid search — **High Value**

| Complexity | Effort | Breaking | Deps |
|---|---|---|---|
| Medium | 1.5 wk | No | none |

**Why.** Qdrant, Pinecone, Weaviate and Milvus support sparse + dense hybrid
in one query, which beats client-side fusion on latency.

**API.** `VectorRecord(vector: dense, sparse: SparseVector(indices, values))`;
`VectorQuery(vector: q, sparse: qs, fusion: Fusion.rrf)`;
`VectorStoreInfo.supportsSparse`.

---

### VEC-7 · Multi-vector (late interaction) records — **Experimental**

| Complexity | Effort | Breaking | Deps |
|---|---|---|---|
| High | 2 wk | No | none |

**Why.** ColBERT/ColPali-style multi-vector retrieval is the strongest approach
for visually rich PDFs (tables, charts) and is supported by Qdrant and Vespa.

**API.** `VectorRecord.multi(vectors: [...])`, `MaxSimScorer`.

---

### VEC-8 · Embedding model migration — **High Value**

| Complexity | Effort | Breaking | Deps |
|---|---|---|---|
| Low | 4 d | No | none |

**Why.** The Gemini embedding retirement already broke Recall. Changing
embedding models means re-embedding everything; doing it safely needs a
shadow index and cut-over.

**API.**

```dart
await EmbeddingMigration(
  from: EmbeddingIndex(store: old, model: oldModel),
  to:   EmbeddingIndex(store: next, model: newModel),
  source: (id) => textStore.read(id),
).run(onProgress: …);       // resumable; verifies recall on sampled queries before cut-over
```

`EmbeddingIndex` also records model ID and dimensions in store metadata, and
refuses to query with a different model.

---

### VEC-9 · Embedding cache — **High Value**

| Complexity | Effort | Breaking | Deps |
|---|---|---|---|
| Low | 3 d | No | none |

**Why.** Re-indexing and repeated queries re-pay for identical embeddings.

**API.** `CachingEmbeddingModel(model, cache: SqliteEmbeddingCache(db))`,
keyed by `(modelId, purpose, sha256(text))`.

---

### VEC-10 · On-device embedding models — **Must Have** (with LLM-7)

| Complexity | Effort | Breaking | Deps |
|---|---|---|---|
| Medium | 1.5 wk | No | bridge over `flutter_gemma` (EmbeddingGemma) or ONNX runtime, in `agentic_llm_local` |

**Why.** Offline RAG and private memory are impossible while every embedding
call leaves the device. EmbeddingGemma-class models run on phones.

**API.** `OnDeviceEmbeddingModel.embeddingGemma(dimensions: 256)` — Matryoshka
truncation exposed as `dimensions`.

---

## `agentic_rag` — 14 features

### RAG-1 · PDF loader (text + layout) — **Must Have**

| Complexity | Effort | Breaking | Deps |
|---|---|---|---|
| High | 2 wk | No | pure-Dart PDF text extraction in `agentic_rag_documents`; optional native (pdfium) backend |

**Why.** Most enterprise and personal knowledge lives in PDFs. Without a PDF
loader the RAG package does not cover the most common first request.

**API.**

```dart
final loader = PdfDocumentLoader(
  mode: PdfMode.layout,            // keeps headings, drops headers/footers
  ocr: VisionOcr(model: gemini),   // optional: scanned pages via a vision model
);
final docs = await loader.load(TextSource.file(path));
```

Page numbers go into chunk metadata so citations can say "p. 14".

---

### RAG-2 · Office, EPUB, CSV and JSON loaders — **High Value**

| Complexity | Effort | Breaking | Deps |
|---|---|---|---|
| Medium | 2 wk | No | `archive`, `xml` |

**API.** `DocxDocumentLoader`, `PptxDocumentLoader`, `XlsxDocumentLoader`
(row-as-record), `EpubDocumentLoader`, `CsvDocumentLoader(rowTemplate: …)`,
all registered in `Registry<DocumentLoader>` by MIME type.

---

### RAG-3 · Multimodal ingestion via vision models — **High Value**

| Complexity | Effort | Breaking | Deps |
|---|---|---|---|
| Medium | 1.5 wk | No | none |

**Why.** Charts, screenshots, receipts and diagrams carry information text
extraction misses. Describing images with a vision model at ingest time makes
them searchable.

**API.** `ImageDescribingEnricher(model: gemini, prompt: …)` as an indexing step;
`RagIndexer(enrichers: [...])`.

---

### RAG-4 · Contextual retrieval — **Must Have**

| Complexity | Effort | Breaking | Deps |
|---|---|---|---|
| Low | 4 d | No | LLM-3 prompt caching (for cost) |

**Why.** Chunks lose their context ("the company's revenue grew 3 %" — which
company?). Prepending a short LLM-generated context to each chunk before
embedding and BM25 indexing substantially reduces retrieval failures, and
prompt caching makes it affordable.

**API.** `RagIndexer(enrichers: [ContextualChunkEnricher(model: flashLite)])`
— the context is stored separately so citations still show original text.

---

### RAG-5 · Query transformation — **High Value**

| Complexity | Effort | Breaking | Deps |
|---|---|---|---|
| Low | 1 wk | No | none |

**Why.** Conversational follow-ups ("and for 2024?") retrieve nothing without
rewriting; complex questions need decomposition.

**API.**

```dart
TransformingRetriever(
  retriever,
  transforms: [
    QueryTransform.condenseWithHistory(model),   // standalone question
    QueryTransform.multiQuery(model, n: 3),       // RRF-fused
    QueryTransform.hyde(model),                   // optional
  ],
);
```

---

### RAG-6 · Hosted rerankers (Cohere, Voyage, Jina) and on-device cross-encoder — **High Value**

| Complexity | Effort | Breaking | Deps |
|---|---|---|---|
| Low | 1 wk | No | none |

**Why.** `LlmReranker` is slow and costly; dedicated rerankers are more
accurate per millisecond.

**API.** `CohereReranker(apiKey: k, model: …)`, `VoyageReranker`, `JinaReranker`
behind the existing `Reranker` port; composable in `ChainedReranker`.

---

### RAG-7 · RAG evaluation metrics — **Must Have**

| Complexity | Effort | Breaking | Deps |
|---|---|---|---|
| Medium | 1.5 wk | No | `agentic_test` |

**Why.** Teams tune chunk size, top-k and rerankers blind. Faithfulness, answer
relevance, context precision and context recall are the standard vocabulary.
`RagAnswer.isGrounded` is a good start.

**API.**

```dart
final report = await RagEval(
  pipeline: rag,
  dataset: RagDataset.fromJsonl('eval/questions.jsonl'),
  metrics: [RagMetric.faithfulness(judge), RagMetric.contextRecall(), RagMetric.citationAccuracy()],
).run();
report.compareTo(baseline).assertNoRegression(tolerance: 0.02);
```

Include a synthetic question generator (`RagDataset.synthesise(corpus, n: 100)`).

---

### RAG-8 · Connectors with incremental sync — **High Value**

| Complexity | Effort | Breaking | Deps |
|---|---|---|---|
| Medium each | 1 wk each | No | per connector (`googleapis`, HTTP) |

**Why.** Ingestion is a pipeline, not a one-off: documents change. The indexer's
fingerprints and tail deletion already make re-ingestion safe — connectors only
need to enumerate changes.

**API.** `SyncSource` port — `Stream<SourceChange> changesSince(Cursor?)` — with
`LocalFolderSource`, `GoogleDriveSource`, `NotionSource`, `GitHubSource`,
`ConfluenceSource`, `WebCrawlerSource(sitemap: …)`; `RagSync(indexer,
sources).runIncremental()`.

---

### RAG-9 · Agentic RAG — **High Value**

| Complexity | Effort | Breaking | Deps |
|---|---|---|---|
| Medium | 1 wk | No | `agentic_agents` (new edge — place in `agentic_rag_agents` or behind a function type to keep layering) |

**Why.** Single-shot retrieval fails on multi-hop questions. An agent that
decides what to search next, judges sufficiency and stops is the current best
practice.

**API.** `ResearchAgent(retrievers: {'handbook': hb, 'tickets': tk}, model: m,
maxSearches: 6)` returning a `RagAnswer` with citations across hops.

---

### RAG-10 · Semantic and late chunking — **Future**

| Complexity | Effort | Breaking | Deps |
|---|---|---|---|
| Medium | 1 wk | No | none |

**API.** `SemanticChunker(embedder, breakpoint: Breakpoint.percentile(95))`
splitting where adjacent-sentence similarity drops.

---

### RAG-11 · Citation UI data and highlight spans — **High Value**

| Complexity | Effort | Breaking | Deps |
|---|---|---|---|
| Low | 4 d | No | none |

**Why.** Trust in RAG apps comes from tapping a citation and seeing the exact
passage highlighted. `Citation` should carry character offsets into the source
document and the supporting quote.

**API.** `Citation.quote`, `Citation.span (start, end)`, `Citation.page`; a
`CitationChip` / `SourceSheet` in `agentic_flutter`.

---

### RAG-12 · GraphRAG — **Experimental**

| Complexity | Effort | Breaking | Deps |
|---|---|---|---|
| Very High | 4 wk | No | `agentic_graph` |

**Why.** "What are the main themes across all 400 interviews?" cannot be
answered by top-k chunks. Entity graphs with community summaries can.

---

### RAG-13 · Answer caching (semantic cache) — **High Value**

| Complexity | Effort | Breaking | Deps |
|---|---|---|---|
| Low | 4 d | No | none |

**Why.** FAQ-style apps receive the same question phrased many ways.

**API.** `SemanticAnswerCache(store: vectorStore, threshold: 0.95, ttl: 1.day)`,
invalidated by `RagIndexer` when cited documents change.

---

### RAG-14 · Permission-aware retrieval — **Must Have** (enterprise)

| Complexity | Effort | Breaking | Deps |
|---|---|---|---|
| Medium | 1 wk | No | none |

**Why.** An enterprise assistant must never cite a document the asking user
cannot open. Filtering after generation is too late.

**API.** `DocumentAcl` stored in chunk metadata at ingest; `RetrievalRequest(principal:
Principal(user: u, groups: g))` compiled into a `MetadataFilter` (sealed filters
make this safe across adapters).

---

## `agentic_sqlite` — 10 features

### SQL-1 · FTS5 keyword index — **Must Have**

| Complexity | Effort | Breaking | Deps |
|---|---|---|---|
| Low | 4 d | No (schema migration 3) | none |

**Why.** BM25 over an in-memory index means loading every chunk at start-up.
FTS5 ships in the bundled SQLite and keeps the index on disk.

**API.** `SqliteKeywordIndex(db)` implementing the same contract as
`InMemoryKeywordIndex`; `RagStack.sqlite(db, embedder: …)` wiring both halves.

---

### SQL-2 · sqlite-vec ANN — **High Value**

| Complexity | Effort | Breaking | Deps |
|---|---|---|---|
| Medium | 1 wk | No | sqlite-vec native asset (`sqlite3_vec`) |

**Why.** Removes the load-and-scan ceiling while keeping one database file.

**API.** `SqliteVectorStore(db, index: SqliteVectorIndex.vec0())`, falling back
to exact scan where the extension is unavailable (reported via
`VectorStoreInfo`).

---

### SQL-3 · Encryption at rest — **Must Have**

| Complexity | Effort | Breaking | Deps |
|---|---|---|---|
| Medium | 1 wk | No | SQLite3 Multiple Ciphers build via `sqlite3` hooks |

**Why.** Memories, chat history and personal documents are among the most
sensitive data an app stores. App review and enterprise MDM policies increasingly
check.

**API.** `AgenticDatabase.open(path, encryption: DatabaseKey.fromSecretStore(secrets,
'db_key'))`, with key rotation (`db.rekey(newKey)`).

---

### SQL-4 · Web support (WASM + OPFS) — **High Value**

| Complexity | Effort | Breaking | Deps |
|---|---|---|---|
| Medium | 1.5 wk | No | `sqlite3` WASM build |

**Why.** Flutter web apps get no persistence today. `package:sqlite3` supports
WASM with OPFS storage.

**API.** `AgenticDatabase.openWeb('agentic.db')` behind a conditional import;
same stores.

---

### SQL-5 · Background isolate connection — **High Value**

| Complexity | Effort | Breaking | Deps |
|---|---|---|---|
| Medium | 1 wk | No | none |

**Why.** Synchronous FFI calls on the UI isolate cause jank during indexing.

**API.** `AgenticDatabase.openInIsolate(path)` returning the same store
interfaces with async message passing.

---

### SQL-6 · Remaining stores: chat cache, usage ledger, eval results, untrusted-content ledger, run store — **High Value**

| Complexity | Effort | Breaking | Deps |
|---|---|---|---|
| Low | 1 wk | No | none |

**Why.** Every in-memory port in the framework should have a persistent twin so
"survives restart" is true everywhere.

**API.** `SqliteChatCache`, `SqliteUsageLedger` (CORE-8), `SqliteRunStore`
(AGENTS-3), `SqliteEmbeddingCache` (VEC-9), `SqliteHumanTaskInbox` (WF-9).

---

### SQL-7 · Drift interop — **High Value**

| Complexity | Effort | Breaking | Deps |
|---|---|---|---|
| Medium | 1 wk | No | `drift` (separate `agentic_drift` package) |

**Why.** Drift is the dominant typed SQL layer in Flutter. Apps already using
it want agentic tables in the same database, migrations and transactions.

**API.** `AgenticDriftTables` mixin for a Drift database; `DriftVectorStore(db)`.

---

### SQL-8 · Backup, export and sync hooks — **Future**

| Complexity | Effort | Breaking | Deps |
|---|---|---|---|
| Medium | 1.5 wk | No | none |

**Why.** Users change phones. Memories and conversations should move with them —
end-to-end encrypted.

**API.** `db.exportEncrypted(sink, key)`, `db.import(...)`; a change-log table
enabling sync adapters (PowerSync, ElectricSQL, Supabase) later.

---

### SQL-9 · Retention and vacuum policies — **High Value**

| Complexity | Effort | Breaking | Deps |
|---|---|---|---|
| Low | 3 d | No | none |

**API.** `AgenticDatabase(retention: Retention(sessions: 90.days, snapshots:
30.days, maxBytes: 200.mb))` with scheduled `VACUUM` and `MemoriesPruned`-style
events.

---

### SQL-10 · Inspector for DevTools — **Future**

| Complexity | Effort | Breaking | Deps |
|---|---|---|---|
| Medium | 1 wk | No | `devtools_extensions` (in `agentic_devtools`) |

**Why.** "What did the assistant remember about me?" and "why was this chunk
retrieved?" should be answerable in DevTools during development.
