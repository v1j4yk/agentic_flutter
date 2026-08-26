// Demonstrates the retrieval layer end to end: loading, chunking, indexing,
// dense and lexical retrieval, fusion, re-ranking, cited answers, and exposing
// the corpus to an agent as a tool.
//
// Run it with:
//
//     dart run example/agentic_rag_example.dart
//
// It runs offline. The embedding model is a real hashing bag-of-words model —
// no download, no key — and the chat model is scripted.
import 'package:agentic_core/agentic_core.dart';
import 'package:agentic_llm/agentic_llm.dart';
import 'package:agentic_llm/testing.dart';
import 'package:agentic_rag/agentic_rag.dart';
import 'package:agentic_tools/agentic_tools.dart';
import 'package:agentic_vector/agentic_vector.dart';

Future<void> main() async {
  // ---------------------------------------------------------------------------
  // 1. Load. Front matter becomes metadata you can filter on.
  // ---------------------------------------------------------------------------
  print('--- loading ---');
  const loader = MarkdownDocumentLoader(<TextSource>[
    TextSource(id: 'handbook.md', text: _handbook),
    TextSource(id: 'errors.md', text: _errors),
  ]);
  final documents = await loader.load();
  for (final document in documents) {
    print(
      '${document.id.padRight(14)} "${document.title}" '
      '${document.content.length} chars, metadata: ${document.metadata}',
    );
  }

  // ---------------------------------------------------------------------------
  // 2. Index. Markdown splits at headings, so every chunk knows its section.
  // ---------------------------------------------------------------------------
  print('\n--- indexing ---');
  final model = HashingEmbeddingModel(dimensions: 256);
  final store = InMemoryVectorStore(dimensions: model.dimensions);
  final keywords = InMemoryKeywordIndex();
  final indexer = RagIndexer(
    index: EmbeddingIndex(model: model, store: store),
    chunker: const MarkdownChunker(options: ChunkOptions(maxChars: 400)),
    keywordIndex: keywords,
  );

  final report = await indexer.indexAll(documents);
  print('report     : $report');
  for (final chunk in keywords.chunks) {
    print('  ${chunk.id.padRight(16)} ${chunk.heading}');
  }

  // Re-ingesting unchanged documents costs nothing.
  final second = await indexer.indexAll(documents);
  print(
    're-run     : ${second.skipped.length} unchanged, '
    '${second.chunksWritten} chunks embedded',
  );

  // ---------------------------------------------------------------------------
  // 3. Retrieve. Dense and lexical retrieval have opposite blind spots.
  // ---------------------------------------------------------------------------
  print('\n--- retrieval ---');
  final dense = VectorRetriever(index: indexer.index);
  final lexical = KeywordRetriever(index: keywords);
  final hybrid = HybridRetriever(retrievers: <Retriever>[dense, lexical]);

  const question = 'how long does a refund take?';
  for (final retriever in <Retriever>[dense, lexical, hybrid]) {
    final hits = await retriever.search(question, topK: 2);
    print('${retriever.name.padRight(8)} ${hits.map((h) => h.id).join(', ')}');
  }

  // Exact tokens — error codes, order numbers, surnames — are what a *trained*
  // embedding model blurs: ERR_4417 and ERR_4418 sit almost on top of each
  // other in vector space. BM25 has the opposite bias and scores a rare token
  // highly, which is the whole argument for fusing the two rankings.
  //
  // The local hashing model below is lexical by construction, so it does not
  // display the weakness; swap in a real embedding model and the two columns
  // come apart.
  print('\n--- exact tokens ---');
  for (final retriever in <Retriever>[dense, lexical]) {
    final hits = await retriever.search('ERR_4418', topK: 1);
    print(
      '${retriever.name.padRight(8)} '
      '${hits.isEmpty ? '(nothing)' : hits.single.chunk.label}',
    );
  }

  // ---------------------------------------------------------------------------
  // 4. Answer, with citations that resolve back to documents.
  // ---------------------------------------------------------------------------
  print('\n--- answering ---');
  final pipeline = RagPipeline(
    retriever: hybrid,
    model: FakeChatModel.text(
      'Refunds are processed within thirty days of purchase [1].',
    ),
    reranker: const ScoreFloorReranker(),
    finalK: 3,
  );

  final answer = await pipeline.answer(question);
  print(answer.text);
  for (final citation in answer.citations) {
    print('  ${citation.label}');
  }
  print('grounded   : ${answer.isGrounded}');
  print(
    'context    : ${answer.context.characters} chars, '
    '${answer.context.chunks.length} passages, '
    '${answer.context.dropped} dropped',
  );

  // A question the corpus does not cover should not produce a confident answer.
  final unanswerable = RagPipeline(
    retriever: hybrid,
    model: FakeChatModel.text('The documents do not cover this.'),
    minScore: 0.15,
  );
  final gap = await unanswerable.answer('what is the capital of Peru?');
  print('\noff-topic  : "${gap.text}" (grounded: ${gap.isGrounded})');

  // ---------------------------------------------------------------------------
  // 5. Filtering: closest *among what this reader may see*.
  // ---------------------------------------------------------------------------
  print('\n--- filtered retrieval ---');
  final billingOnly = await pipeline.buildContext(
    'what goes wrong with cards?',
    filter: const MetadataFilter.equals('team', 'support'),
  );
  print('support    : ${billingOnly.chunks.map((c) => c.id).join(', ')}');

  // ---------------------------------------------------------------------------
  // 6. Give the corpus to an agent as a tool, and let it decide when to search.
  // ---------------------------------------------------------------------------
  print('\n--- as a tool ---');
  final tool = searchTool(retriever: hybrid, corpus: 'the company handbook');
  final result = await tool.call(
    ToolInvocation(
      callId: 'call-1',
      toolName: tool.spec.name,
      arguments: const <String, Object?>{'query': 'invoices', 'limit': 1},
      context: AgenticContext.root(),
    ),
  );
  print(result.content);

  // ---------------------------------------------------------------------------
  // 7. Observability: what was asked, what came back, what was cited.
  // ---------------------------------------------------------------------------
  print('\n--- observability ---');
  final bus = BroadcastEventBus();
  await pipeline.answer(question, context: AgenticContext.root(events: bus));
  for (final event in bus.replayBuffer.whereType<RagEvent>()) {
    print(event);
  }

  await bus.dispose();
  await indexer.index.dispose();
}

/// A device-local embedding model: hashed bag of words, normalised.
///
/// It has no idea that "refund" and "money back" are related — that is what a
/// trained model buys — but it is deterministic, instant and free, which makes
/// the rest of this example runnable with nothing installed.
final class HashingEmbeddingModel implements EmbeddingModel {
  HashingEmbeddingModel({this.dimensions = 256})
    : info = ModelInfo(id: 'hashing-bow', provider: 'local');

  @override
  final ModelInfo info;

  @override
  final int dimensions;

  @override
  int get maxBatchSize => 1024;

  @override
  Future<List<Embedding>> embed(
    List<String> inputs, {
    required EmbeddingPurpose purpose,
    AgenticContext? context,
  }) async => [
    for (var i = 0; i < inputs.length; i++)
      Embedding(values: _vectorFor(inputs[i]), index: i),
  ];

  List<double> _vectorFor(String text) {
    final values = List<double>.filled(dimensions, 0);
    for (final word in text.toLowerCase().split(RegExp(r'[^a-z0-9]+'))) {
      if (word.length < 3) continue;
      var hash = 0x811c9dc5;
      for (final unit in word.codeUnits) {
        hash = ((hash ^ unit) * 0x01000193) & 0xffffffff;
      }
      values[hash % dimensions] += 1;
    }
    return normalise(values);
  }

  @override
  Future<void> dispose() async {}
}

const String _handbook = '''
---
title: Company handbook
team: billing
year: 2025
---

# Company handbook

This handbook covers billing, invoicing and customer refunds. It is the
authoritative source for anything a support agent needs to answer.

## Refunds

Refunds are processed within thirty days of the original purchase date. A
refund is issued to the original payment method and cannot be redirected to
another card or account.

## Invoices

Invoices are issued on the first of each month and sent by email to the billing
contact on the account. A copy is retained in the customer portal for seven
years.
''';

const String _errors = '''
---
title: Error reference
team: support
year: 2025
---

# Error reference

Payment errors returned by the gateway, and what each of them means for the
customer who hit it.

## Card errors

The gateway reports card problems with a four-digit code. Each one below tells
the agent what to say to the customer who hit it.

### ERR_4417

The card has expired. The customer must add a new payment method before the
subscription can renew, and no charge is attempted until they do.

### ERR_4418

The issuing bank declined the charge. This is between the customer and their
bank; there is nothing we can change on our side to make it succeed.
''';
