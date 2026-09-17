/// Retrieval over your own documents, assembled in one call.
///
/// # Why this exists when every piece is already public
///
/// A working hybrid setup is an `EmbeddingIndex`, an `InMemoryKeywordIndex`, a
/// `RagIndexer` writing to both, a `VectorRetriever` and a `KeywordRetriever`
/// fused by a `HybridRetriever`, and a `RagPipeline` over that retriever. Seven
/// objects, two of which must share an index and one of which must be built
/// twice with identical weights if the app also wants a search tool. Every app
/// assembled it slightly differently, and the usual mistake — a pipeline
/// retrieving from a different index than the indexer writes to — produces an
/// assistant that answers "nothing found" about documents it has just indexed.
///
/// [RagStack] is that assembly, done once. Every piece stays reachable for the
/// app that outgrows it.
///
/// # Keyword-only is a real mode, not a degraded one
///
/// Without an embedding model — no key yet, offline, or a corpus of part
/// numbers where meaning does not help — [RagStack] indexes lexically only. No
/// placeholder model producing meaningless vectors is involved, and search
/// works the moment a document is added.
library;

import 'package:agentic_core/agentic_core.dart';
import 'package:agentic_llm/agentic_llm.dart';
import 'package:agentic_rag/src/chunking/chunker.dart';
import 'package:agentic_rag/src/chunking/recursive_chunker.dart';
import 'package:agentic_rag/src/events/rag_events.dart';
import 'package:agentic_rag/src/model/document.dart';
import 'package:agentic_rag/src/pipeline/rag_indexer.dart';
import 'package:agentic_rag/src/pipeline/rag_pipeline.dart';
import 'package:agentic_rag/src/rerank/reranker.dart';
import 'package:agentic_rag/src/retrieval/hybrid_retriever.dart';
import 'package:agentic_rag/src/retrieval/keyword_retriever.dart';
import 'package:agentic_rag/src/retrieval/retriever.dart';
import 'package:agentic_rag/src/retrieval/vector_retriever.dart';
// Prefixed: `RagStack.searchTool` would otherwise shadow the function it calls.
import 'package:agentic_rag/src/tools/rag_tool.dart' as rag_tools;
import 'package:agentic_tools/agentic_tools.dart';
import 'package:agentic_vector/agentic_vector.dart';

/// How a [RagStack] finds passages.
enum RagSearchMode {
  /// Lexical only (BM25). No embedding model involved.
  keyword,

  /// Dense and lexical, fused by rank.
  hybrid,
}

/// Indexing, retrieval and cited answering over one corpus.
///
/// ```dart
/// final rag = RagStack(
///   embeddings: GeminiEmbeddingModel(apiKey: key),   // omit for keyword-only
///   store: await db.vectorStore(name: 'notes', dimensions: 768),
///   model: GeminiChatModel(apiKey: key),             // omit for search only
/// );
///
/// await rag.index(documents);
/// final hits = await rag.search('why the rollout is on hold');
/// final answer = await rag.answer('Why is the rollout on hold?');
/// ```
final class RagStack implements Disposable {
  /// Assembles a stack.
  ///
  /// [embeddings] and [store] go together: both for hybrid search, neither for
  /// keyword-only. One without the other is refused rather than guessed at —
  /// a store with no model can hold nothing new, and a model with no store has
  /// nowhere to put what it produces.
  ///
  /// [model] is needed only for [answer] and [stream]; [index] and [search]
  /// work without one.
  ///
  /// The store is not disposed with the stack. It was handed in, so it may be
  /// shared — with an `AgenticDatabase`, say — and closing it here would pull
  /// it out from under its owner.
  factory RagStack({
    EmbeddingModel? embeddings,
    VectorStore? store,
    ChatModel? model,
    Chunker chunker = const RecursiveChunker(),
    Reranker? reranker,
    String? namespace,
    int topK = 8,
    int finalK = 4,
    String? systemPrompt,
    double denseWeight = 1.0,
    double keywordWeight = 0.5,
  }) {
    if ((embeddings == null) != (store == null)) {
      throw ConfigurationException(
        embeddings == null
            ? 'A vector store was given without an embedding model. Pass both '
                  'for hybrid search, or neither for keyword-only search.'
            : 'An embedding model was given without a vector store. Pass both '
                  'for hybrid search, or neither for keyword-only search.',
        setting: embeddings == null ? 'RagStack.embeddings' : 'RagStack.store',
      );
    }

    final keywordIndex = InMemoryKeywordIndex();
    final keyword = KeywordRetriever(index: keywordIndex);

    final EmbeddingIndex? embeddingIndex;
    final Retriever retriever;
    final RagIndexer? indexer;
    if (embeddings != null && store != null) {
      embeddingIndex = EmbeddingIndex(
        model: embeddings,
        store: store,
        namespace: namespace,
        disposeStore: false,
      );
      retriever = HybridRetriever(
        retrievers: <Retriever>[
          VectorRetriever(index: embeddingIndex),
          keyword,
        ],
        weights: <String, double>{
          'vector': denseWeight,
          'keyword': keywordWeight,
        },
      );
      indexer = RagIndexer(
        index: embeddingIndex,
        keywordIndex: keywordIndex,
        chunker: chunker,
        namespace: namespace,
      );
    } else {
      embeddingIndex = null;
      retriever = keyword;
      indexer = null;
    }

    return RagStack._(
      mode: embeddingIndex == null
          ? RagSearchMode.keyword
          : RagSearchMode.hybrid,
      chunker: chunker,
      keywordIndex: keywordIndex,
      embeddingIndex: embeddingIndex,
      retriever: retriever,
      indexer: indexer,
      namespace: namespace,
      topK: topK,
      pipeline: model == null
          ? null
          : RagPipeline(
              retriever: retriever,
              model: model,
              reranker: reranker,
              topK: topK,
              finalK: finalK,
              systemPrompt: systemPrompt,
              includeQuotes: true,
            ),
    );
  }

  RagStack._({
    required this.mode,
    required this.chunker,
    required this.keywordIndex,
    required this.embeddingIndex,
    required this.retriever,
    required this.namespace,
    required this.topK,
    required RagIndexer? indexer,
    required this.pipeline,
  }) : _indexer = indexer;

  /// Whether search is keyword-only or hybrid.
  final RagSearchMode mode;

  /// How documents are split.
  final Chunker chunker;

  /// The lexical index. Always present.
  final InMemoryKeywordIndex keywordIndex;

  /// The dense index, in hybrid mode.
  final EmbeddingIndex? embeddingIndex;

  /// What finds passages: hybrid, or keyword-only.
  final Retriever retriever;

  /// What writes cited answers, when a chat model was given.
  final RagPipeline? pipeline;

  /// The store partition used throughout.
  final String? namespace;

  /// Passages retrieved per question.
  final int topK;

  final RagIndexer? _indexer;

  /// Whether [answer] and [stream] are available.
  bool get canAnswer => pipeline != null;

  /// Indexes [documents], replacing any earlier version of each.
  ///
  /// A document that fails is recorded in the report and indexing continues —
  /// so **check [IndexingReport.failed]**. An embedding call that fails for
  /// every document produces a report with nothing indexed and no exception,
  /// and an app that reads only the success count shows a library of
  /// documents with zero passages instead of an error.
  ///
  /// In hybrid mode an unchanged document is skipped without a model call,
  /// which is what makes re-indexing a library on every launch affordable.
  /// Keyword-only indexing costs no model call at all, so it simply re-indexes.
  Future<IndexingReport> index(
    Iterable<RagDocument> documents, {
    AgenticContext? context,
  }) {
    final indexer = _indexer;
    if (indexer != null) return indexer.indexAll(documents, context: context);
    return _indexKeywordsOnly(documents, context: context);
  }

  /// Removes every chunk of [documentId], returning how many went.
  Future<int> remove(String documentId, {AgenticContext? context}) async {
    final indexer = _indexer;
    if (indexer != null) return indexer.remove(documentId, context: context);
    return keywordIndex.removeDocument(documentId);
  }

  /// The passages most relevant to [query].
  Future<List<RetrievedChunk>> search(
    String query, {
    int? topK,
    MetadataFilter? filter,
    double minScore = 0,
    AgenticContext? context,
  }) => retriever.search(
    query,
    topK: topK ?? this.topK,
    filter: filter,
    minScore: minScore,
    namespace: namespace,
    context: context,
  );

  /// A cited answer to [query].
  ///
  /// Throws a [ConfigurationException] when the stack has no chat model.
  Future<RagAnswer> answer(
    String query, {
    MetadataFilter? filter,
    List<Message> history = const <Message>[],
    AgenticContext? context,
  }) => _requirePipeline().answer(
    query,
    filter: filter,
    namespace: namespace,
    history: history,
    context: context,
  );

  /// A cited answer to [query], as it is written. See [RagPipeline.stream].
  ///
  /// Throws a [ConfigurationException] when the stack has no chat model.
  Stream<RagStreamEvent> stream(
    String query, {
    MetadataFilter? filter,
    List<Message> history = const <Message>[],
    AgenticContext? context,
  }) => _requirePipeline().stream(
    query,
    filter: filter,
    namespace: namespace,
    history: history,
    context: context,
  );

  /// A tool that gives an agent this stack's search.
  Tool searchTool({
    String name = 'search_documents',
    String? description,
    String corpus = 'the indexed documents',
  }) => rag_tools.searchTool(
    retriever: retriever,
    name: name,
    description: description,
    corpus: corpus,
    topK: topK,
    namespace: namespace,
  );

  /// Releases the in-memory keyword index. The store stays with its owner.
  @override
  Future<void> dispose() async {
    keywordIndex.clear();
    await embeddingIndex?.dispose();
  }

  RagPipeline _requirePipeline() {
    final ready = pipeline;
    if (ready != null) return ready;
    throw ConfigurationException(
      'This RagStack has no chat model, so it can search but not answer. '
      'Pass `model:` to answer or stream.',
      setting: 'RagStack.model',
    );
  }

  Future<IndexingReport> _indexKeywordsOnly(
    Iterable<RagDocument> documents, {
    AgenticContext? context,
  }) async {
    final clock = context?.clock ?? const SystemClock();
    final started = clock.now();
    final indexed = <String>[];
    final failed = <String, String>{};
    var written = 0;
    var removed = 0;

    for (final document in documents) {
      context?.throwIfCancelled();
      try {
        final chunks = chunker.chunk(document);
        removed += keywordIndex.removeDocument(document.id);
        keywordIndex.addAll(chunks);
        written += chunks.length;
        indexed.add(document.id);
      } on AgenticException catch (error) {
        failed[document.id] = error.message;
      }
    }

    final report = IndexingReport(
      indexed: indexed,
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
        skipped: 0,
        failed: failed.length,
        chunksWritten: written,
        chunksRemoved: removed,
        duration: report.duration,
        runId: context.runId,
        source: 'rag:stack',
      ),
    );
    return report;
  }
}
