/// Retrieval-augmented generation for the agentic framework.
///
/// Documents in, cited answers out — with every stage of the pipeline
/// replaceable.
///
/// ```dart
/// import 'package:agentic_rag/agentic_rag.dart';
///
/// final indexer = RagIndexer(
///   index: EmbeddingIndex(model: embeddings, store: store),
///   chunker: const MarkdownChunker(),
/// );
/// await indexer.indexAll(documents);
///
/// final pipeline = RagPipeline(
///   retriever: VectorRetriever(index: indexer.index),
///   model: chatModel,
///   reranker: const ScoreFloorReranker(minScore: 0.25),
/// );
///
/// final answer = await pipeline.answer('How do refunds work?');
/// print(answer.text);                 // "... refunds take 5 days [2]."
/// print(answer.citations.first.label); // "[2] Handbook › Refunds"
/// ```
///
/// Each stage is a port: `Chunker`, `Retriever`, `Reranker`,
/// `DocumentLoader`. Replacing one is a class in your own package, and nothing
/// here needs to change.
library;

// --- Chunking ----------------------------------------------------------------
export 'src/chunking/chunker.dart'
    show BaseChunker, ChunkOptions, ChunkPiece, Chunker, ChunkerOperations;
export 'src/chunking/markdown_chunker.dart' show MarkdownChunker;
export 'src/chunking/recursive_chunker.dart'
    show FixedSizeChunker, RecursiveChunker;
// --- Events ------------------------------------------------------------------
export 'src/events/rag_events.dart'
    show
        AnswerGenerated,
        ChunksReranked,
        ChunksRetrieved,
        DocumentsIndexed,
        RagEvent;
// --- Loading -----------------------------------------------------------------
export 'src/loader/builtin_loaders.dart'
    show HtmlDocumentLoader, MarkdownDocumentLoader;
export 'src/loader/document_loader.dart'
    show
        CompositeDocumentLoader,
        DocumentLoader,
        TextDocumentLoader,
        TextSource;
// --- Model -------------------------------------------------------------------
export 'src/model/document.dart'
    show
        Citation,
        DocumentChunk,
        RagDocument,
        RetrievedChunk,
        formatSourceLabel;
// --- Ingestion ---------------------------------------------------------------
export 'src/pipeline/rag_indexer.dart' show IndexingReport, RagIndexer;
// --- Pipeline ----------------------------------------------------------------
export 'src/pipeline/rag_pipeline.dart' show RagAnswer, RagContext, RagPipeline;
// --- Re-ranking --------------------------------------------------------------
export 'src/rerank/llm_reranker.dart' show LlmReranker;
export 'src/rerank/reranker.dart'
    show ChainedReranker, MmrReranker, Reranker, ScoreFloorReranker;
// --- Storage bridge ----------------------------------------------------------
export 'src/retrieval/chunk_codec.dart'
    show
        chunkFromRecord,
        chunkMetadata,
        documentFilter,
        kChunkIndexKey,
        kContentHashKey,
        kDocumentIdKey,
        kHeadingKey,
        kReservedMetadataKeys,
        kSourceKey,
        kStartOffsetKey,
        kTitleKey,
        staleTailFilter,
        userMetadata;
export 'src/retrieval/hybrid_retriever.dart'
    show HybridRetriever, NeighbourExpandingRetriever;
export 'src/retrieval/keyword_retriever.dart'
    show InMemoryKeywordIndex, KeywordRetriever;
// --- Retrieval ---------------------------------------------------------------
export 'src/retrieval/retriever.dart'
    show RetrievalRequest, Retriever, RetrieverOperations;
export 'src/retrieval/vector_retriever.dart' show VectorRetriever;
// --- Tools -------------------------------------------------------------------
export 'src/tools/rag_tool.dart' show answeringTool, searchTool;
