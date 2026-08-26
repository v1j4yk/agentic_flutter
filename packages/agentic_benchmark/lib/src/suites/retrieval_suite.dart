/// Whether the retrieval claims in the documentation are true.
///
/// `agentic_vector`'s README says brute-force search over ten thousand
/// 768-dimensional vectors is "a few milliseconds" and that approximate indexes
/// only start paying above roughly a hundred thousand records. That is a claim
/// a reader will act on, so it should be a measurement rather than a belief —
/// which is what `vector.search.10k` is here to be.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:agentic_benchmark/src/harness.dart';
import 'package:agentic_memory/agentic_memory.dart';
import 'package:agentic_rag/agentic_rag.dart';
import 'package:agentic_vector/agentic_vector.dart';

BenchmarkSuite vectorSuite() => BenchmarkSuite(
  name: 'vector',
  benchmarks: <Benchmark<Object?>>[
    _search(count: 1000, dimensions: 768),
    _search(count: 10000, dimensions: 768),
    _search(count: 10000, dimensions: 768, filtered: true),
    Benchmark<InMemoryVectorStore>(
      name: 'vector.upsert.1k',
      description:
          'Writing a thousand 768-dimensional records. The ingestion side, '
          'which happens once where search happens constantly.',
      setup: () => InMemoryVectorStore(dimensions: 768),
      run: (store) => store.upsertAll(_records(1000, 768)),
      iterations: 20,
      warmup: 3,
      unit: '1k records',
    ),
    Benchmark<Float64List>(
      name: 'vector.cosine.768d',
      description:
          'One cosine similarity. Multiplied by the index size on every '
          'unfiltered query, so it is the constant the whole scan is made of.',
      setup: () => _vector(768, 7),
      run: (vector) => cosineSimilarity(vector, _queryVector),
      iterations: 20000,
      warmup: 2000,
    ),
  ],
);

BenchmarkSuite retrievalSuite() => BenchmarkSuite(
  name: 'rag',
  benchmarks: <Benchmark<Object?>>[
    Benchmark<RagDocument>(
      name: 'rag.chunk.recursive.100kb',
      description:
          'Splitting a hundred kilobytes of prose at natural boundaries. Paid '
          'once per document at ingestion, and the reason ingestion is slow '
          'when it is slow.',
      setup: () => RagDocument(id: 'doc', content: _prose(100 * 1024)),
      run: (document) => const RecursiveChunker().chunk(document),
      iterations: 30,
      warmup: 5,
      unit: '100 KB',
    ),
    Benchmark<RagDocument>(
      name: 'rag.chunk.markdown.100kb',
      description:
          'The same document split at headings, which also builds the heading '
          'path every chunk carries.',
      setup: () => RagDocument(id: 'doc', content: _markdown(100 * 1024)),
      run: (document) => const MarkdownChunker().chunk(document),
      iterations: 30,
      warmup: 5,
      unit: '100 KB',
    ),
    Benchmark<InMemoryKeywordIndex>(
      name: 'rag.bm25.build.5k',
      description:
          'Building a BM25 index over five thousand chunks. The cost of the '
          'lexical half of hybrid retrieval, paid at start-up.',
      setup: InMemoryKeywordIndex.new,
      run: (index) => index
        ..clear()
        ..addAll(_chunks(5000)),
      iterations: 10,
      warmup: 2,
      unit: '5k chunks',
    ),
    Benchmark<InMemoryKeywordIndex>(
      name: 'rag.bm25.search.5k',
      description:
          'One BM25 query over five thousand chunks of varied prose. The claim '
          'this checks is that a keyword index is effectively free next to an '
          'embedding call.',
      setup: () => InMemoryKeywordIndex()..addAll(_chunks(5000)),
      run: (index) => index.search('quarterly reconciliation ledger variance'),
      iterations: 500,
      warmup: 50,
    ),
    Benchmark<InMemoryKeywordIndex>(
      name: 'rag.bm25.search.5k.commonTerms',
      description:
          'The worst case, stated as one: every query term appears in every '
          'chunk, so the inverted index has no selectivity to offer and the '
          'query degrades to a full scan. Kept because a benchmark suite that '
          'only measures the happy path is a suite that flatters itself.',
      setup: () => InMemoryKeywordIndex()..addAll(_chunks(5000)),
      run: (index) => index.search('refunds processed within thirty days'),
      iterations: 200,
      warmup: 20,
    ),
  ],
);

BenchmarkSuite memorySuite() => BenchmarkSuite(
  name: 'memory',
  benchmarks: <Benchmark<Object?>>[
    Benchmark<InMemoryMemoryStore>(
      name: 'memory.recall.5k',
      description:
          'Rarity-weighted keyword recall over five thousand memories, blended '
          'with importance and recency. Runs on every turn of a remembering '
          'agent, so it is on the interactive path rather than the batch one.',
      setup: () async {
        final store = InMemoryMemoryStore();
        for (var i = 0; i < 5000; i++) {
          await store.remember(
            'Fact number $i about ${_topics[i % _topics.length]} '
            'and its consequences for the team.',
            importance: (i % 10) / 10,
          );
        }
        return store;
      },
      teardown: (store) => store.dispose(),
      run: (store) => store.recall('what did we decide about billing?'),
      iterations: 200,
      warmup: 20,
    ),
  ],
);

Benchmark<InMemoryVectorStore> _search({
  required int count,
  required int dimensions,
  bool filtered = false,
}) {
  final size = count >= 1000 ? '${count ~/ 1000}k' : '$count';
  return Benchmark<InMemoryVectorStore>(
    name: 'vector.search.$size${filtered ? '.filtered' : ''}',
    description: filtered
        ? 'Exhaustive search over $size vectors with a metadata filter applied '
              'before ranking — the rule the port exists to enforce.'
        : 'Exhaustive search over $size $dimensions-dimensional vectors. The '
              'measurement behind the claim that brute force is fine on a '
              'device at this scale.',
    setup: () async {
      final store = InMemoryVectorStore(dimensions: dimensions);
      // Filled through the store's own API so the benchmark measures the same
      // code path an application uses, and awaited so the fixture is complete
      // before the first sample is taken.
      await store.upsertAll(_records(count, dimensions));
      return store;
    },
    teardown: (store) => store.dispose(),
    run: (store) => store.searchVector(
      _queryVector,
      topK: 8,
      filter: filtered ? const MetadataFilter.equals('tenant', 'acme') : null,
    ),
    iterations: count >= 10000 ? 50 : 200,
    warmup: count >= 10000 ? 5 : 20,
    unit: '$size vectors',
  );
}

List<VectorRecord> _records(int count, int dimensions) => <VectorRecord>[
  for (var i = 0; i < count; i++)
    VectorRecord(
      id: 'record-$i',
      vector: _vector(dimensions, i),
      metadata: <String, Object?>{
        'tenant': i.isEven ? 'acme' : 'globex',
        'year': 2020 + (i % 6),
      },
    ),
];

/// A deterministic pseudo-random vector.
///
/// Seeded per record so every run measures the same data. Real embeddings are
/// not uniform, but a scan's cost does not depend on the values — only on the
/// count and the width.
Float64List _vector(int dimensions, int seed) {
  final random = math.Random(seed);
  final values = Float64List(dimensions);
  for (var i = 0; i < dimensions; i++) {
    values[i] = random.nextDouble() - 0.5;
  }
  return values;
}

final Float64List _queryVector = _vector(768, 999);

const List<String> _topics = <String>[
  'billing',
  'refunds',
  'invoices',
  'onboarding',
  'deployment',
];

/// A corpus with the vocabulary distribution a real one has.
///
/// This matters more than it looks. A fixture where every chunk contains every
/// query term measures the pathological case — an inverted index has no
/// selectivity to offer, and the number that comes out is a full scan wearing a
/// benchmark's name. Real prose has a long tail of rare words, which is exactly
/// the distribution BM25 is built to exploit, so the fixture has one too.
List<DocumentChunk> _chunks(int count) {
  final random = math.Random(42);
  return <DocumentChunk>[
    for (var i = 0; i < count; i++)
      DocumentChunk(
        id: 'chunk-$i',
        documentId: 'doc-${i ~/ 20}',
        index: i % 20,
        text:
            'Section $i covers ${_topics[i % _topics.length]}. '
            'Refunds are processed within thirty days. '
            '${List<String>.generate(24, (_) => _vocabulary[random.nextInt(_vocabulary.length)]).join(' ')}.',
      ),
  ];
}

/// Enough distinct words that a query term is not in every chunk.
const List<String> _vocabulary = <String>[
  'quarterly',
  'reconciliation',
  'ledger',
  'variance',
  'accrual',
  'depreciation',
  'amortisation',
  'settlement',
  'remittance',
  'chargeback',
  'dispute',
  'escalation',
  'provisioning',
  'entitlement',
  'subscription',
  'proration',
  'dunning',
  'collection',
  'writeoff',
  'adjustment',
  'credit',
  'debit',
  'reversal',
  'authorisation',
  'capture',
  'refund',
  'invoice',
  'statement',
  'threshold',
  'allocation',
  'forecast',
  'attribution',
  'segmentation',
  'retention',
  'cohort',
  'churn',
  'expansion',
  'contraction',
  'renewal',
  'migration',
  'onboarding',
  'deprovisioning',
  'compliance',
  'audit',
  'retention',
  'archival',
  'redaction',
  'anonymisation',
  'residency',
  'encryption',
];

/// Prose with paragraph structure, so the recursive chunker has real
/// boundaries to find rather than one unbroken line.
String _prose(int bytes) {
  final buffer = StringBuffer();
  var paragraph = 0;
  while (buffer.length < bytes) {
    buffer
      ..writeln(
        'Paragraph $paragraph discusses ${_topics[paragraph % _topics.length]} '
        'in some detail. It runs to several sentences so that the splitter has '
        'sentence boundaries to fall back on. It also repeats vocabulary, '
        'which is what a real corpus does.',
      )
      ..writeln();
    paragraph++;
  }
  return buffer.toString();
}

String _markdown(int bytes) {
  final buffer = StringBuffer('# Handbook\n\n');
  var section = 0;
  while (buffer.length < bytes) {
    buffer
      ..writeln('## Section $section')
      ..writeln()
      ..writeln(
        'This section covers ${_topics[section % _topics.length]}. Refunds are '
        'processed within thirty days. Invoices are issued monthly and sent by '
        'email to the billing contact on the account.',
      )
      ..writeln();
    section++;
  }
  return buffer.toString();
}
