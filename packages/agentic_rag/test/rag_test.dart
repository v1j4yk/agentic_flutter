import 'package:agentic_core/agentic_core.dart';
import 'package:agentic_core/testing.dart';
import 'package:agentic_llm/agentic_llm.dart';
import 'package:agentic_llm/testing.dart';
import 'package:agentic_rag/agentic_rag.dart';
import 'package:agentic_tools/agentic_tools.dart';
import 'package:agentic_vector/agentic_vector.dart';
import 'package:test/test.dart';

RagDocument documentOf(
  String id,
  String content, {
  String? title,
  String? source,
  JsonMap metadata = const <String, Object?>{},
}) => RagDocument(
  id: id,
  content: content,
  title: title,
  source: source,
  metadata: metadata,
);

DocumentChunk chunkOf(
  String id, {
  String text = 'text',
  String documentId = 'doc',
  int index = 0,
  String? title,
  String? heading,
  JsonMap metadata = const <String, Object?>{},
}) => DocumentChunk(
  id: id,
  documentId: documentId,
  text: text,
  index: index,
  title: title,
  heading: heading,
  metadata: metadata,
);

/// A deterministic bag-of-words embedder, so retrieval is meaningfully testable.
final class BagOfWordsModel implements EmbeddingModel {
  BagOfWordsModel({this.dimensions = 32, this.maxBatchSize = 64})
    : info = ModelInfo(id: 'bow', provider: 'test');

  @override
  final ModelInfo info;

  @override
  final int dimensions;

  @override
  final int maxBatchSize;

  @override
  Future<List<Embedding>> embed(
    List<String> inputs, {
    required EmbeddingPurpose purpose,
    AgenticContext? context,
  }) async => <Embedding>[
    for (var i = 0; i < inputs.length; i++)
      Embedding(values: _vectorFor(inputs[i]), index: i),
  ];

  List<double> _vectorFor(String text) {
    final values = List<double>.filled(dimensions, 0);
    for (final word in text.toLowerCase().split(RegExp('[^a-z0-9]+'))) {
      if (word.length < 3) continue;
      var hash = 0;
      for (final unit in word.codeUnits) {
        hash = (hash * 31 + unit) & 0xffffff;
      }
      values[hash % dimensions] += 1;
    }
    return normalise(values);
  }

  @override
  Future<void> dispose() async {}
}

/// A retriever that returns whatever it was given.
final class StubRetriever implements Retriever {
  StubRetriever(this.results, {this.name = 'stub'});

  final List<RetrievedChunk> results;

  @override
  final String name;

  final List<RetrievalRequest> requests = <RetrievalRequest>[];

  @override
  Future<List<RetrievedChunk>> retrieve(
    RetrievalRequest request, {
    AgenticContext? context,
  }) async {
    requests.add(request);
    return finalise(results, request);
  }
}

Future<({EmbeddingIndex index, InMemoryVectorStore store})> freshIndex() async {
  final model = BagOfWordsModel();
  final store = InMemoryVectorStore(dimensions: model.dimensions);
  return (index: EmbeddingIndex(model: model, store: store), store: store);
}

void main() {
  group('RagDocument', () {
    test('fingerprints content stably and changes when it changes', () {
      final a = documentOf('d', 'The refund window is 30 days.');
      final b = documentOf('d', 'The refund window is 30 days.');
      final c = documentOf('d', 'The refund window is 14 days.');

      expect(a.contentHash, b.contentHash);
      expect(a.contentHash, isNot(c.contentHash));
      expect(a.contentHash, hasLength(16));
    });

    test('round-trips through JSON', () {
      final document = documentOf(
        'handbook.md',
        '# Refunds\n\nWithin 30 days.',
        title: 'Handbook',
        source: 'https://example.test/handbook',
        metadata: <String, Object?>{'team': 'billing'},
      );
      final restored = RagDocument.fromJson(document.toJson());
      expect(restored.id, document.id);
      expect(restored.content, document.content);
      expect(restored.title, 'Handbook');
      expect(restored.metadata['team'], 'billing');
    });
  });

  group('Citation', () {
    test('renders a label a reader can follow', () {
      final citation = Citation.forChunk(
        chunkOf(
          'handbook.md#3',
          documentId: 'handbook.md',
          title: 'Handbook',
          heading: 'Billing › Refunds',
        ),
        marker: '2',
      );
      expect(citation.label, '[2] Handbook › Billing › Refunds');
      expect(citation.chunkId, 'handbook.md#3');
      expect(citation.quote, isNull);
    });

    test('does not repeat the title a heading path already starts with', () {
      // Markdown heading paths begin with the document's own H1, which is
      // usually the title. Concatenating produced "Handbook > Handbook >
      // Refunds" on every citation a reader saw.
      final citation = Citation.forChunk(
        chunkOf(
          'handbook.md#1',
          documentId: 'handbook.md',
          title: 'Handbook',
          heading: 'Handbook › Refunds',
        ),
        marker: '1',
      );
      expect(citation.label, '[1] Handbook › Refunds');
      expect(formatSourceLabel('Handbook', 'Handbook'), 'Handbook');
      expect(formatSourceLabel('Handbook', null), 'Handbook');
      expect(formatSourceLabel('Handbook', 'Billing'), 'Handbook › Billing');
    });

    test('carries the passage only when asked', () {
      final citation = Citation.forChunk(
        chunkOf('c', text: 'Refunds take five days.'),
        marker: '1',
        includeQuote: true,
      );
      expect(citation.quote, 'Refunds take five days.');
    });
  });

  group('RecursiveChunker', () {
    test('leaves a document that already fits as one chunk', () {
      const chunker = RecursiveChunker(
        options: ChunkOptions(maxChars: 500, overlapChars: 0, minChars: 0),
      );
      final chunks = chunker.chunk(
        documentOf('d', 'One paragraph.\n\nAnd a second paragraph.'),
      );

      expect(
        chunks,
        hasLength(1),
        reason: 'splitting text that fits buys nothing and costs coherence',
      );
    });

    test('keeps paragraphs whole when they fit', () {
      const chunker = RecursiveChunker(
        options: ChunkOptions(maxChars: 40, overlapChars: 0, minChars: 0),
      );
      final chunks = chunker.chunk(
        documentOf(
          'd',
          'First paragraph about billing.\n\n'
              'Second paragraph about refunds.\n\n'
              'Third paragraph about invoices.',
        ),
      );

      expect(chunks, hasLength(3));
      expect(chunks.first.text, 'First paragraph about billing.');
      expect(chunks.map((c) => c.index), <int>[0, 1, 2]);
      expect(chunks.map((c) => c.id), <String>['d#0', 'd#1', 'd#2']);
    });

    test('splits at weaker boundaries only when it must', () {
      const chunker = RecursiveChunker(
        options: ChunkOptions(maxChars: 60, overlapChars: 0, minChars: 0),
      );
      final chunks = chunker.chunk(
        documentOf(
          'd',
          'One sentence here. Another sentence here. A third sentence here.',
        ),
      );

      expect(chunks.length, greaterThan(1));
      for (final chunk in chunks) {
        expect(chunk.text.length, lessThanOrEqualTo(60));
      }
      // Sentence separators survive, so the reassembled text still reads.
      expect(chunks.map((c) => c.text).join(' '), contains('Another sentence'));
    });

    test('overlaps chunks so a boundary sentence stays retrievable', () {
      const chunker = RecursiveChunker(
        options: ChunkOptions(maxChars: 60, overlapChars: 20, minChars: 0),
      );
      final chunks = chunker.chunk(
        documentOf('d', '${'A' * 55}\n\n${'B' * 55}'),
      );

      expect(chunks, hasLength(2));
      expect(
        chunks[1].text,
        startsWith('A'),
        reason: 'the second chunk repeats the tail of the first',
      );
    });

    test('folds a tiny tail into its predecessor', () {
      const chunker = RecursiveChunker(
        options: ChunkOptions(maxChars: 100, overlapChars: 0, minChars: 40),
      );
      final chunks = chunker.chunk(
        documentOf('d', 'A full paragraph of reasonable length.\n\nTiny.'),
      );

      expect(chunks, hasLength(1));
      expect(chunks.single.text, contains('Tiny.'));
    });

    test('cuts text with no boundaries at all rather than giving up', () {
      const chunker = RecursiveChunker(
        options: ChunkOptions(maxChars: 20, overlapChars: 0, minChars: 0),
      );
      final chunks = chunker.chunk(documentOf('d', 'x' * 95));

      expect(chunks.length, 5);
      for (final chunk in chunks) {
        expect(chunk.text.length, lessThanOrEqualTo(20));
      }
    });

    test('carries document metadata onto every chunk', () {
      const chunker = RecursiveChunker(
        options: ChunkOptions(maxChars: 25, overlapChars: 0, minChars: 0),
      );
      final chunks = chunker.chunk(
        documentOf(
          'd',
          'Paragraph one here.\n\nParagraph two here.',
          title: 'Guide',
          source: 'guide.md',
          metadata: <String, Object?>{'team': 'billing'},
        ),
      );

      expect(chunks, hasLength(2));
      for (final chunk in chunks) {
        expect(chunk.title, 'Guide');
        expect(chunk.source, 'guide.md');
        expect(chunk.metadata['team'], 'billing');
      }
    });

    test('never emits an empty chunk', () {
      const chunker = RecursiveChunker(
        options: ChunkOptions(maxChars: 30, overlapChars: 0, minChars: 0),
      );
      final chunks = chunker.chunk(documentOf('d', '\n\n\n   \n\nReal text.'));
      expect(chunks, hasLength(1));
      expect(chunks.single.text, 'Real text.');
    });

    test('rejects an overlap that cannot make progress', () {
      expect(
        () => ChunkOptions(maxChars: 100, overlapChars: 100),
        throwsA(anything),
      );
    });
  });

  group('FixedSizeChunker', () {
    test('cuts at a fixed stride, overlap included', () {
      const chunker = FixedSizeChunker(
        options: ChunkOptions(maxChars: 10, overlapChars: 2, minChars: 0),
      );
      final chunks = chunker.chunk(documentOf('d', '0123456789abcdefghij'));

      expect(chunks.first.text, '0123456789');
      expect(chunks[1].text, startsWith('89'));
    });
  });

  group('MarkdownChunker', () {
    const chunker = MarkdownChunker(
      options: ChunkOptions(maxChars: 400, overlapChars: 0, minChars: 10),
    );

    test('splits at headings and keeps the heading path', () {
      final chunks = chunker.chunk(
        documentOf(
          'handbook.md',
          '# Handbook\n\nWelcome to the handbook, which covers everything.\n\n'
              '## Billing\n\nInvoices are issued monthly on the first.\n\n'
              '### Refunds\n\nRefunds are processed within thirty days.\n',
          title: 'Handbook',
        ),
      );

      expect(chunks.map((c) => c.heading), <String?>[
        'Handbook',
        'Handbook › Billing',
        'Handbook › Billing › Refunds',
      ]);
      expect(chunks.last.text, contains('thirty days'));
      expect(chunks.last.metadata['headingPath'], <String>[
        'Handbook',
        'Billing',
        'Refunds',
      ]);
    });

    test('puts the heading in the text, not only in the metadata', () {
      // Splitting at a heading removes it from the text below it. A section
      // titled `ERR_4418` whose body never repeats the code was unretrievable
      // by that code from either index.
      final chunks = chunker.chunk(
        documentOf(
          'errors.md',
          '# Error reference\n\nCodes the payment gateway returns to us.\n\n'
              '## ERR_4418\n\nThe issuing bank declined the charge, which the '
              'customer has to resolve with their bank.\n',
        ),
      );

      final section = chunks.last;
      expect(section.heading, 'Error reference › ERR_4418');
      expect(section.text, contains('ERR_4418'));
      expect(
        InMemoryKeywordIndex.tokenise(section.text),
        contains('err_4418'),
        reason: 'the code an author put in the heading must be searchable',
      );
    });

    test('can be told to leave the heading out of the text', () {
      const bare = MarkdownChunker(
        options: ChunkOptions(maxChars: 400, overlapChars: 0, minChars: 10),
        prependHeading: false,
      );
      final chunks = bare.chunk(
        documentOf(
          'errors.md',
          '# Error reference\n\nCodes the payment gateway returns to us.\n\n'
              '## ERR_4418\n\nThe issuing bank declined the charge, which the '
              'customer has to resolve with their bank.\n',
        ),
      );

      expect(chunks.last.text, isNot(contains('ERR_4418')));
      expect(chunks.last.heading, 'Error reference › ERR_4418');
    });

    test('does not split at a heading inside a fenced code block', () {
      final chunks = chunker.chunk(
        documentOf(
          'guide.md',
          '# Setup\n\nRun the installer before anything else happens.\n\n'
              '```sh\n# not a heading, just a shell comment\ndart pub get\n```\n\n'
              'Then restart the application to pick up the changes.\n',
        ),
      );

      expect(chunks, hasLength(1));
      expect(chunks.single.text, contains('dart pub get'));
    });

    test(
      'splits an oversized section but keeps its heading on every piece',
      () {
        const narrow = MarkdownChunker(
          options: ChunkOptions(maxChars: 80, overlapChars: 0, minChars: 0),
        );
        final chunks = narrow.chunk(
          documentOf(
            'long.md',
            '## Refunds\n\n${'Refunds are processed promptly. ' * 12}',
          ),
        );

        expect(chunks.length, greaterThan(1));
        expect(chunks.map((c) => c.heading), everyElement('Refunds'));
      },
    );

    test('keeps deeper headings as body text rather than losing them', () {
      final chunks = chunker.chunk(
        documentOf(
          'deep.md',
          '# Top\n\nAn introduction long enough to survive folding.\n\n'
              '#### Deeply nested\n\nSomething worth keeping in the text.\n',
        ),
      );

      expect(chunks, hasLength(1));
      expect(chunks.single.text, contains('#### Deeply nested'));
    });

    test('folds a heading with almost nothing under it', () {
      final chunks = chunker.chunk(
        documentOf(
          'short.md',
          '# Real section\n\nA paragraph with genuine content in it.\n\n'
              '## Stub\n\nTBD\n',
        ),
      );

      expect(chunks, hasLength(1));
      expect(chunks.single.text, contains('TBD'));
      expect(chunks.single.heading, 'Real section');
    });
  });

  group('loaders', () {
    test('markdown lifts front matter and the first heading', () async {
      final loader = MarkdownDocumentLoader(<TextSource>[
        const TextSource(
          id: 'policy.md',
          text:
              '---\n'
              'team: billing\n'
              'year: 2025\n'
              'draft: false\n'
              'tags: [policy, refunds]\n'
              '---\n\n'
              '# Refund policy\n\nWithin thirty days.\n',
        ),
      ]);

      final document = (await loader.load()).single;
      expect(document.title, 'Refund policy');
      expect(document.metadata['team'], 'billing');
      expect(document.metadata['year'], 2025);
      expect(document.metadata['draft'], false);
      expect(document.metadata['tags'], <String>['policy', 'refunds']);
      expect(document.content, startsWith('# Refund policy'));
    });

    test('markdown without front matter is left alone', () async {
      final loader = MarkdownDocumentLoader(<TextSource>[
        const TextSource(id: 'plain.md', text: '# Title\n\nBody.'),
      ]);
      final document = (await loader.load()).single;
      expect(document.metadata, isEmpty);
      expect(document.content, '# Title\n\nBody.');
    });

    test('html becomes readable text with paragraphs intact', () async {
      final loader = HtmlDocumentLoader(<TextSource>[
        const TextSource(
          id: 'page.html',
          text:
              '<html><head><title>Refunds &amp; returns</title>'
              '<style>body{color:red}</style></head>'
              '<body><!-- hidden --><h1>Refunds</h1>'
              '<p>Within <b>30</b> days.</p>'
              '<p>Contact support&nbsp;first.</p>'
              '<script>alert(1)</script></body></html>',
        ),
      ]);

      final document = (await loader.load()).single;
      expect(document.title, 'Refunds & returns');
      expect(document.content, contains('Within 30 days.'));
      expect(document.content, contains('Contact support first.'));
      expect(document.content, isNot(contains('alert')));
      expect(document.content, isNot(contains('color:red')));
      expect(document.content, isNot(contains('hidden')));
      expect(document.content, contains('\n\n'));
    });

    test('html decodes ampersands last, so escaped entities survive', () {
      expect(HtmlDocumentLoader.decodeEntities('&amp;lt;'), '&lt;');
      expect(HtmlDocumentLoader.decodeEntities('&#8212;'), '—');
      expect(HtmlDocumentLoader.decodeEntities('&#x2014;'), '—');
      expect(
        HtmlDocumentLoader.decodeEntities('&#999999999;'),
        '&#999999999;',
        reason: 'an out-of-range reference is left alone, never thrown on',
      );
    });

    test('composite runs its loaders in order', () async {
      const loader = CompositeDocumentLoader(<DocumentLoader>[
        TextDocumentLoader(<TextSource>[TextSource(id: 'a', text: 'first')]),
        TextDocumentLoader(<TextSource>[TextSource(id: 'b', text: 'second')]),
      ]);
      final documents = await loader.load();
      expect(documents.map((d) => d.id), <String>['a', 'b']);
    });
  });

  group('chunk codec', () {
    test('round-trips a chunk through a vector record', () {
      final chunk = chunkOf(
        'guide.md#2',
        text: 'Refunds take five days.',
        documentId: 'guide.md',
        index: 2,
        title: 'Guide',
        heading: 'Refunds',
        metadata: <String, Object?>{'team': 'billing'},
      );
      final record = VectorRecord(
        id: chunk.id,
        vector: const <double>[1, 0],
        metadata: chunkMetadata(chunk, contentHash: 'abc'),
        text: chunk.text,
      );

      final restored = chunkFromRecord(record)!;
      expect(restored.id, 'guide.md#2');
      expect(restored.documentId, 'guide.md');
      expect(restored.index, 2);
      expect(restored.title, 'Guide');
      expect(restored.heading, 'Refunds');
      expect(restored.text, 'Refunds take five days.');
      expect(
        restored.metadata,
        <String, Object?>{'team': 'billing'},
        reason: 'reserved keys must not leak back to the caller',
      );
    });

    test('refuses to invent a document for a foreign record', () {
      final record = VectorRecord(
        id: 'someone-elses',
        vector: const <double>[1, 0],
        metadata: const <String, Object?>{'colour': 'blue'},
      );
      expect(chunkFromRecord(record), isNull);
    });

    test('reserved keys carry no dots, which backends read as paths', () {
      for (final key in kReservedMetadataKeys) {
        expect(key, isNot(contains('.')));
        expect(key, startsWith('_rag_'));
      }
    });

    test('the stale-tail filter matches exactly the chunks past a count', () {
      final filter = staleTailFilter('guide.md', 3);
      bool matches(String documentId, int index) => filter.matches(
        <String, Object?>{kDocumentIdKey: documentId, kChunkIndexKey: index},
      );

      expect(matches('guide.md', 2), isFalse);
      expect(matches('guide.md', 3), isTrue);
      expect(matches('guide.md', 9), isTrue);
      expect(matches('other.md', 9), isFalse);
    });
  });

  group('RagIndexer', () {
    test('indexes, chunks and makes passages retrievable', () async {
      final fresh = await freshIndex();
      final indexer = RagIndexer(
        index: fresh.index,
        chunker: const RecursiveChunker(
          options: ChunkOptions(maxChars: 60, overlapChars: 0, minChars: 0),
        ),
      );

      final report = await indexer.indexAll(<RagDocument>[
        documentOf(
          'guide.md',
          'Refunds are processed within thirty days.\n\n'
              'Invoices are issued on the first of each month.',
          title: 'Guide',
        ),
      ]);

      expect(report.indexed, <String>['guide.md']);
      expect(report.chunksWritten, 2);
      expect(report.isClean, isTrue);

      final retriever = VectorRetriever(index: fresh.index);
      final hits = await retriever.search('refunds processed');
      expect(hits.first.chunk.documentId, 'guide.md');
      expect(hits.first.chunk.title, 'Guide');
      expect(hits.first.text, contains('Refunds'));
    });

    test('skips a document whose content has not changed', () async {
      final fresh = await freshIndex();
      final indexer = RagIndexer(index: fresh.index);
      final document = documentOf('a.md', 'Unchanged content here.');

      final first = await indexer.indexAll(<RagDocument>[document]);
      final second = await indexer.indexAll(<RagDocument>[document]);

      expect(first.indexed, <String>['a.md']);
      expect(second.skipped, <String>['a.md']);
      expect(second.chunksWritten, 0);
    });

    test('re-indexes when the content changes', () async {
      final fresh = await freshIndex();
      final indexer = RagIndexer(index: fresh.index);

      await indexer.indexAll(<RagDocument>[documentOf('a.md', 'Version one.')]);
      final report = await indexer.indexAll(<RagDocument>[
        documentOf('a.md', 'Version two, which is different.'),
      ]);

      expect(report.indexed, <String>['a.md']);
      expect((await fresh.store.get('a.md#0'))!.text, contains('Version two'));
    });

    test('removes the stale tail a shorter document leaves behind', () async {
      // The bug this exists to prevent: nine chunks replaced by six leaves
      // three orphans that still match queries and still get cited.
      final fresh = await freshIndex();
      final indexer = RagIndexer(
        index: fresh.index,
        chunker: const RecursiveChunker(
          options: ChunkOptions(maxChars: 30, overlapChars: 0, minChars: 0),
        ),
      );

      await indexer.indexAll(<RagDocument>[
        documentOf(
          'a.md',
          'Alpha paragraph.\n\nBeta paragraph.\n\n'
              'Gamma paragraph.\n\nDelta paragraph.',
        ),
      ]);
      expect(fresh.store.length, 4);

      final report = await indexer.indexAll(<RagDocument>[
        documentOf('a.md', 'Alpha paragraph.\n\nBeta paragraph.'),
      ]);

      expect(report.chunksWritten, 2);
      expect(report.chunksRemoved, 2);
      expect(fresh.store.length, 2);
      expect(await fresh.store.get('a.md#3'), isNull);
    });

    test('an empty document clears what it used to have', () async {
      final fresh = await freshIndex();
      final indexer = RagIndexer(index: fresh.index);

      await indexer.indexAll(<RagDocument>[
        documentOf('a.md', 'Some content.'),
      ]);
      final report = await indexer.indexAll(<RagDocument>[
        documentOf('a.md', '   \n\n  '),
      ]);

      expect(report.chunksWritten, 0);
      expect(report.chunksRemoved, 1);
      expect(fresh.store.length, 0);
    });

    test('keeps the keyword index in step with the vector index', () async {
      final fresh = await freshIndex();
      final keywords = InMemoryKeywordIndex();
      final indexer = RagIndexer(
        index: fresh.index,
        keywordIndex: keywords,
        chunker: const RecursiveChunker(
          options: ChunkOptions(maxChars: 25, overlapChars: 0, minChars: 0),
        ),
      );

      await indexer.indexAll(<RagDocument>[
        documentOf('a.md', 'Alpha content here.\n\nBeta content here.'),
      ]);
      expect(keywords.length, 2);

      await indexer.indexAll(<RagDocument>[
        documentOf('a.md', 'Only alpha now.'),
      ]);
      expect(keywords.length, 1);
      expect(fresh.store.length, 1);

      await indexer.remove('a.md');
      expect(keywords.length, 0);
      expect(fresh.store.length, 0);
    });

    test('one failed document does not abandon the run', () async {
      final fresh = await freshIndex();
      final indexer = RagIndexer(index: fresh.index, chunker: _AngryChunker());

      final report = await indexer.indexAll(<RagDocument>[
        documentOf('good.md', 'Fine content.'),
        documentOf('bad.md', 'Fine content.'),
        documentOf('also-good.md', 'Fine content.'),
      ]);

      expect(report.indexed, <String>['good.md', 'also-good.md']);
      expect(report.failed.keys, <String>['bad.md']);
      expect(report.isClean, isFalse);
      expect(report.total, 3);
    });

    test('publishes what an ingestion run did', () async {
      final fresh = await freshIndex();
      final bus = BroadcastEventBus();
      final indexer = RagIndexer(index: fresh.index);

      await indexer.indexAll(
        <RagDocument>[documentOf('a.md', 'Some content.')],
        context: AgenticContext.root(
          events: bus,
          ids: SequentialIdGenerator(prefix: 'e'),
          clock: FakeClock(autoAdvance: true),
        ),
      );

      final event = bus.replayBuffer.whereType<DocumentsIndexed>().single;
      expect(event.indexed, 1);
      expect(event.chunksWritten, 1);
      await bus.dispose();
    });
  });

  group('InMemoryKeywordIndex', () {
    test('ranks a rare term above a common one', () {
      final index = InMemoryKeywordIndex()
        ..addAll(<DocumentChunk>[
          for (var i = 0; i < 9; i++)
            chunkOf('common-$i', text: 'the service handles billing requests'),
          chunkOf(
            'rare',
            text: 'the service returns ERR_4417 when billing fails',
          ),
        ]);

      final hits = index.search('ERR_4417 billing');
      expect(hits.first.chunk.id, 'rare');
    });

    test('finds the exact token an embedding would blur', () {
      final index = InMemoryKeywordIndex()
        ..addAll(<DocumentChunk>[
          chunkOf('a', text: 'Error ERR_4417 means the card expired.'),
          chunkOf('b', text: 'Error ERR_4418 means the card was declined.'),
        ]);

      final hits = index.search('ERR_4418');
      expect(hits.first.chunk.id, 'b');
    });

    test('does not let a long passage win on length alone', () {
      final index = InMemoryKeywordIndex()
        ..addAll(<DocumentChunk>[
          chunkOf('short', text: 'Refunds take five days.'),
          chunkOf(
            'long',
            text:
                'Refunds are mentioned here. ${'Unrelated filler text. ' * 40}',
          ),
        ]);

      final hits = index.search('refunds');
      expect(hits.first.chunk.id, 'short');
    });

    test('applies a filter before scoring', () {
      final index = InMemoryKeywordIndex()
        ..addAll(<DocumentChunk>[
          chunkOf(
            'a',
            text: 'refunds policy',
            metadata: <String, Object?>{'team': 'billing'},
          ),
          chunkOf(
            'b',
            text: 'refunds policy',
            metadata: <String, Object?>{'team': 'support'},
          ),
        ]);

      final hits = index.search(
        'refunds',
        filter: const MetadataFilter.equals('team', 'billing'),
      );
      expect(hits.map((h) => h.chunk.id), <String>['a']);
    });

    test('removal keeps the corpus statistics honest', () {
      final index = InMemoryKeywordIndex()
        ..add(chunkOf('a', text: 'alpha beta gamma'))
        ..add(chunkOf('b', text: 'alpha delta'));
      expect(index.length, 2);
      expect(index.averageLength, closeTo(2.5, 1e-9));

      expect(index.remove('b'), isTrue);
      expect(index.remove('b'), isFalse);
      expect(index.length, 1);
      expect(index.averageLength, closeTo(3, 1e-9));
      expect(index.search('delta'), isEmpty);
    });

    test('re-adding the same identifier replaces rather than doubles', () {
      final index = InMemoryKeywordIndex()
        ..add(chunkOf('a', text: 'alpha'))
        ..add(chunkOf('a', text: 'beta'));

      expect(index.length, 1);
      expect(index.search('alpha'), isEmpty);
      expect(index.search('beta'), hasLength(1));
    });

    test('a query with nothing indexable returns nothing', () {
      final index = InMemoryKeywordIndex()..add(chunkOf('a', text: 'alpha'));
      expect(index.search('a I'), isEmpty);
    });
  });

  group('HybridRetriever', () {
    test('promotes what both retrievers agree on', () async {
      final agreed = chunkOf('agreed', text: 'agreed');
      final vectorOnly = chunkOf('vector-only', text: 'vector');
      final keywordOnly = chunkOf('keyword-only', text: 'keyword');

      final retriever = HybridRetriever(
        retrievers: <Retriever>[
          StubRetriever(<RetrievedChunk>[
            RetrievedChunk(chunk: vectorOnly, score: 0.9),
            RetrievedChunk(chunk: agreed, score: 0.8),
          ], name: 'vector'),
          StubRetriever(<RetrievedChunk>[
            RetrievedChunk(chunk: keywordOnly, score: 12),
            RetrievedChunk(chunk: agreed, score: 11),
          ], name: 'keyword'),
        ],
      );

      final hits = await retriever.search('anything', topK: 3);
      expect(hits.first.id, 'agreed');
      expect(hits.first.retriever, contains('vector'));
      expect(hits.first.retriever, contains('keyword'));
    });

    test('fuses incomparable scales without normalising them', () async {
      // BM25 scores in the tens against cosine scores under one: summing them
      // would let the keyword side decide every fusion.
      final retriever = HybridRetriever(
        retrievers: <Retriever>[
          StubRetriever(<RetrievedChunk>[
            RetrievedChunk(chunk: chunkOf('dense-top'), score: 0.4),
          ], name: 'vector'),
          StubRetriever(<RetrievedChunk>[
            RetrievedChunk(chunk: chunkOf('lexical-second'), score: 90),
            RetrievedChunk(chunk: chunkOf('lexical-top'), score: 99),
          ], name: 'keyword'),
        ],
      );

      final hits = await retriever.search('anything', topK: 3);
      // Both first-ranked results tie; the 90-vs-0.4 gap changes nothing.
      expect(
        hits.take(2).map((h) => h.id),
        containsAll(<String>['dense-top', 'lexical-top']),
      );
      expect(hits.first.score, closeTo(hits[1].score, 1e-12));
    });

    test('weights shift the balance when one side is known better', () async {
      final retriever = HybridRetriever(
        retrievers: <Retriever>[
          StubRetriever(<RetrievedChunk>[
            RetrievedChunk(chunk: chunkOf('dense'), score: 0.5),
          ], name: 'vector'),
          StubRetriever(<RetrievedChunk>[
            RetrievedChunk(chunk: chunkOf('lexical'), score: 5),
          ], name: 'keyword'),
        ],
        weights: <String, double>{'keyword': 2},
      );

      final hits = await retriever.search('anything', topK: 2);
      expect(hits.first.id, 'lexical');
    });

    test('asks each retriever for more candidates than it will keep', () async {
      final stub = StubRetriever(const <RetrievedChunk>[]);
      final retriever = HybridRetriever(
        retrievers: <Retriever>[stub],
        candidateMultiplier: 4,
      );

      await retriever.search('anything', topK: 3, minScore: 0.5);
      expect(stub.requests.single.topK, 12);
      expect(
        stub.requests.single.minScore,
        0,
        reason: 'the floor belongs to the fused ranking, not to the inputs',
      );
    });
  });

  group('NeighbourExpandingRetriever', () {
    test('pulls back the chunks either side of a hit', () async {
      final corpus = <String, DocumentChunk>{
        for (var i = 0; i < 5; i++)
          'doc#$i': chunkOf('doc#$i', text: 'part $i', index: i),
      };

      final retriever = NeighbourExpandingRetriever(
        inner: StubRetriever(<RetrievedChunk>[
          RetrievedChunk(chunk: corpus['doc#2']!, score: 0.9),
        ]),
        lookup: (id) => corpus[id],
      );

      final hits = await retriever.search('anything');
      expect(hits.map((h) => h.id), <String>['doc#2', 'doc#1', 'doc#3']);
      expect(hits.first.score, greaterThan(hits[1].score));
    });

    test('ignores neighbours that do not exist', () async {
      final only = chunkOf('doc#0', index: 0);
      final retriever = NeighbourExpandingRetriever(
        inner: StubRetriever(<RetrievedChunk>[
          RetrievedChunk(chunk: only, score: 1),
        ]),
        lookup: (_) => null,
      );

      final hits = await retriever.search('anything');
      expect(hits.map((h) => h.id), <String>['doc#0']);
    });

    test('never returns the same chunk twice', () async {
      final corpus = <String, DocumentChunk>{
        for (var i = 0; i < 3; i++)
          'doc#$i': chunkOf('doc#$i', text: 'part $i', index: i),
      };
      final retriever = NeighbourExpandingRetriever(
        inner: StubRetriever(<RetrievedChunk>[
          RetrievedChunk(chunk: corpus['doc#0']!, score: 0.9),
          RetrievedChunk(chunk: corpus['doc#1']!, score: 0.8),
        ]),
        lookup: (id) => corpus[id],
      );

      final hits = await retriever.search('anything', topK: 2);
      expect(hits.map((h) => h.id).toSet(), hasLength(hits.length));
    });
  });

  group('rerankers', () {
    test('a score floor removes weak matches without reordering', () async {
      const reranker = ScoreFloorReranker(minScore: 0.5);
      final kept = await reranker.rerank('q', <RetrievedChunk>[
        RetrievedChunk(chunk: chunkOf('a'), score: 0.9),
        RetrievedChunk(chunk: chunkOf('b'), score: 0.6),
        RetrievedChunk(chunk: chunkOf('c'), score: 0.2),
      ]);

      expect(kept.map((r) => r.id), <String>['a', 'b']);
      expect(kept.map((r) => r.rank), <int>[0, 1]);
    });

    test('maximal marginal relevance breaks up near-duplicates', () async {
      final vectors = <String, List<double>>{
        'a': <double>[1, 0, 0],
        'a-copy': <double>[0.99, 0.01, 0],
        'different': <double>[0, 1, 0],
      };
      final reranker = MmrReranker(
        vectorOf: (result) => vectors[result.id],
        lambda: 0.5,
      );

      final kept = await reranker.rerank('q', <RetrievedChunk>[
        RetrievedChunk(chunk: chunkOf('a'), score: 0.9),
        RetrievedChunk(chunk: chunkOf('a-copy'), score: 0.89),
        RetrievedChunk(chunk: chunkOf('different'), score: 0.5),
      ], topK: 2);

      expect(kept.map((r) => r.id), <String>['a', 'different']);
    });

    test('with lambda at 1 it is plain relevance ordering', () async {
      final vectors = <String, List<double>>{
        'a': <double>[1, 0],
        'a-copy': <double>[1, 0],
      };
      final reranker = MmrReranker(
        vectorOf: (result) => vectors[result.id],
        lambda: 1,
      );

      final kept = await reranker.rerank('q', <RetrievedChunk>[
        RetrievedChunk(chunk: chunkOf('a'), score: 0.9),
        RetrievedChunk(chunk: chunkOf('a-copy'), score: 0.8),
      ], topK: 2);

      expect(kept.map((r) => r.id), <String>['a', 'a-copy']);
    });

    test('it says so when the vectors it needs are missing', () async {
      final reranker = MmrReranker(vectorOf: (_) => null);
      await expectLater(
        reranker.rerank('q', <RetrievedChunk>[
          RetrievedChunk(chunk: chunkOf('a'), score: 0.9),
          RetrievedChunk(chunk: chunkOf('b'), score: 0.8),
        ]),
        throwsA(
          isA<ConfigurationException>().having(
            (e) => e.message,
            'message',
            contains('includeVectors'),
          ),
        ),
      );
    });

    test('a chain filters cheaply before the expensive stage', () async {
      final expensive = _RecordingReranker();
      final chain = ChainedReranker(<Reranker>[
        const ScoreFloorReranker(minScore: 0.5),
        expensive,
      ]);

      await chain.rerank('q', <RetrievedChunk>[
        RetrievedChunk(chunk: chunkOf('a'), score: 0.9),
        RetrievedChunk(chunk: chunkOf('b'), score: 0.1),
      ], topK: 2);

      expect(expensive.seen.single.map((r) => r.id), <String>['a']);
      expect(expensive.topKs.single, 2, reason: 'the last stage trims');
    });
  });

  group('LlmReranker', () {
    test('reorders by the scores the model returns', () async {
      final model = FakeChatModel.text(
        '{"scores":[{"index":0,"score":2},{"index":1,"score":9}]}',
      );
      final reranker = LlmReranker(model: model);

      final kept = await reranker.rerank('q', <RetrievedChunk>[
        RetrievedChunk(chunk: chunkOf('a', text: 'about billing'), score: 0.9),
        RetrievedChunk(chunk: chunkOf('b', text: 'about refunds'), score: 0.4),
      ], topK: 2);

      expect(kept.map((r) => r.id), <String>['b', 'a']);
      expect(kept.first.score, closeTo(0.9, 1e-12));
      expect(kept.map((r) => r.rank), <int>[0, 1]);
      expect(reranker.lastFailure, isNull);
    });

    test('keeps the retriever ordering when the model fails', () async {
      final model = FakeChatModel.text('not json at all');
      final reranker = LlmReranker(model: model);

      final kept = await reranker.rerank('q', <RetrievedChunk>[
        RetrievedChunk(chunk: chunkOf('a'), score: 0.9),
        RetrievedChunk(chunk: chunkOf('b'), score: 0.4),
      ], topK: 2);

      expect(kept.map((r) => r.id), <String>['a', 'b']);
      expect(reranker.lastFailure, isA<SerializationException>());
    });

    test('a passage the model skipped loses its place, not the run', () async {
      final model = FakeChatModel.text('{"scores":[{"index":1,"score":8}]}');
      final reranker = LlmReranker(model: model);

      final kept = await reranker.rerank('q', <RetrievedChunk>[
        RetrievedChunk(chunk: chunkOf('a'), score: 0.9),
        RetrievedChunk(chunk: chunkOf('b'), score: 0.4),
      ], topK: 2);

      expect(kept.map((r) => r.id), <String>['b', 'a']);
      expect(kept.last.score, 0);
      expect(reranker.lastFailure, isNull);
    });

    test('truncates candidates rather than sending whole documents', () async {
      final model = FakeChatModel.text('{"scores":[{"index":0,"score":5}]}');
      final reranker = LlmReranker(model: model, maxCandidateChars: 20);

      await reranker.rerank('q', <RetrievedChunk>[
        RetrievedChunk(chunk: chunkOf('a', text: 'x' * 500), score: 0.9),
        RetrievedChunk(chunk: chunkOf('b', text: 'y' * 500), score: 0.8),
      ]);

      final sent = model.requests.single.messages.last.text;
      expect(sent, contains('…'));
      expect(sent.length, lessThan(300));
    });
  });

  group('RagPipeline', () {
    List<RetrievedChunk> passages() => <RetrievedChunk>[
      RetrievedChunk(
        chunk: chunkOf(
          'handbook.md#1',
          text: 'Refunds are processed within thirty days.',
          documentId: 'handbook.md',
          index: 1,
          title: 'Handbook',
          heading: 'Refunds',
        ),
        score: 0.9,
      ),
      RetrievedChunk(
        chunk: chunkOf(
          'handbook.md#4',
          text: 'Invoices are issued monthly.',
          documentId: 'handbook.md',
          index: 4,
          title: 'Handbook',
          heading: 'Invoices',
        ),
        score: 0.4,
      ),
    ];

    test('numbers passages and builds citations from them', () async {
      final pipeline = RagPipeline(retriever: StubRetriever(passages()));
      final context = await pipeline.buildContext('how do refunds work?');

      expect(context.chunks, hasLength(2));
      expect(context.text, contains('[1] Handbook › Refunds'));
      expect(context.text, contains('[2] Handbook › Invoices'));
      expect(context.citations.map((c) => c.marker), <String>['1', '2']);
      expect(context.citations.first.chunkId, 'handbook.md#1');
      expect(context.dropped, 0);
    });

    test('drops what does not fit and says how much', () async {
      final pipeline = RagPipeline(
        retriever: StubRetriever(passages()),
        maxContextChars: 60,
      );
      final context = await pipeline.buildContext('anything');

      expect(context.chunks, hasLength(1));
      expect(context.dropped, 1);
      // The best passage is kept even when it alone exceeds the budget:
      // answering "not covered" about a document that covers it is worse.
      expect(context.characters, greaterThan(60));
    });

    test('answers with citations resolved back to documents', () async {
      final pipeline = RagPipeline(
        retriever: StubRetriever(passages()),
        model: FakeChatModel.text('Refunds take thirty days [1].'),
      );

      final answer = await pipeline.answer('how do refunds work?');
      expect(answer.text, contains('[1]'));
      expect(answer.citations, hasLength(1));
      expect(answer.citations.single.chunkId, 'handbook.md#1');
      expect(answer.isGrounded, isTrue);
    });

    test('reads grouped and repeated markers correctly', () async {
      final pipeline = RagPipeline(retriever: StubRetriever(passages()));
      final context = await pipeline.buildContext('anything');

      expect(
        pipeline
            .citationsIn('Both agree [1][2], and [1] again.', context)
            .map((c) => c.marker),
        <String>['1', '2'],
      );
      expect(
        pipeline.citationsIn('Combined [1, 2].', context).map((c) => c.marker),
        <String>['1', '2'],
      );
    });

    test('ignores a marker the model invented', () async {
      final pipeline = RagPipeline(retriever: StubRetriever(passages()));
      final context = await pipeline.buildContext('anything');

      expect(pipeline.citationsIn('As shown [9].', context), isEmpty);
    });

    test('an ungrounded answer is visible as such', () async {
      final pipeline = RagPipeline(
        retriever: StubRetriever(passages()),
        model: FakeChatModel.text('The documents do not cover this.'),
      );

      final answer = await pipeline.answer('what is the capital of Peru?');
      expect(answer.isGrounded, isFalse);
      expect(answer.citations, isEmpty);
    });

    test('tells the model plainly when nothing was retrieved', () async {
      final model = FakeChatModel.text('The documents do not cover this.');
      final pipeline = RagPipeline(
        retriever: StubRetriever(const <RetrievedChunk>[]),
        model: model,
      );

      final answer = await pipeline.answer('anything');
      expect(answer.context.isEmpty, isTrue);
      expect(model.requests.single.messages.last.text, contains('No passages'));
    });

    test('the default prompt insists on grounding and admitting ignorance', () {
      expect(RagPipeline.defaultSystemPrompt, contains('only the passages'));
      expect(RagPipeline.defaultSystemPrompt, contains('cite nothing'));
    });

    test('refuses to answer without a model, and says why', () async {
      final pipeline = RagPipeline(retriever: StubRetriever(passages()));
      await expectLater(
        pipeline.answer('anything'),
        throwsA(
          isA<ConfigurationException>().having(
            (e) => e.setting,
            'setting',
            'model',
          ),
        ),
      );
    });

    test('publishes retrieval, re-ranking and generation', () async {
      final bus = BroadcastEventBus();
      final pipeline = RagPipeline(
        retriever: StubRetriever(passages()),
        reranker: const ScoreFloorReranker(minScore: 0.5),
        model: FakeChatModel.text('Thirty days [1].'),
      );

      await pipeline.answer(
        'how do refunds work?',
        context: AgenticContext.root(
          events: bus,
          ids: SequentialIdGenerator(prefix: 'e'),
          clock: FakeClock(autoAdvance: true),
        ),
      );

      final retrieved = bus.replayBuffer.whereType<ChunksRetrieved>().single;
      expect(retrieved.returned, 2);
      expect(retrieved.chunkIds, <String>['handbook.md#1', 'handbook.md#4']);

      final reranked = bus.replayBuffer.whereType<ChunksReranked>().single;
      expect(reranked.before, 2);
      expect(reranked.after, 1);

      final answered = bus.replayBuffer.whereType<AnswerGenerated>().single;
      expect(answered.citationsOffered, 1);
      expect(answered.citationsUsed, 1);
      await bus.dispose();
    });

    test('passes the filter and namespace through to the retriever', () async {
      final stub = StubRetriever(passages());
      final pipeline = RagPipeline(retriever: stub, topK: 9);

      await pipeline.buildContext(
        'anything',
        filter: const MetadataFilter.equals('team', 'billing'),
        namespace: 'acme',
      );

      expect(stub.requests.single.topK, 9);
      expect(stub.requests.single.namespace, 'acme');
      expect(stub.requests.single.filter, isA<EqualsFilter>());
    });
  });

  group('end to end', () {
    test('ingests, retrieves and answers with a working citation', () async {
      final fresh = await freshIndex();
      final keywords = InMemoryKeywordIndex();
      final indexer = RagIndexer(
        index: fresh.index,
        keywordIndex: keywords,
        chunker: const MarkdownChunker(
          options: ChunkOptions(maxChars: 300, overlapChars: 0, minChars: 10),
        ),
      );

      final loader = MarkdownDocumentLoader(<TextSource>[
        const TextSource(
          id: 'handbook.md',
          text:
              '---\nteam: billing\n---\n\n'
              '# Handbook\n\nThis handbook covers billing and support.\n\n'
              '## Refunds\n\nRefunds are processed within thirty days of the '
              'original purchase date.\n\n'
              '## Invoices\n\nInvoices are issued on the first of each '
              'month and sent by email.\n',
        ),
      ]);

      await indexer.indexAll(await loader.load());

      final pipeline = RagPipeline(
        retriever: HybridRetriever(
          retrievers: <Retriever>[
            VectorRetriever(index: fresh.index),
            KeywordRetriever(index: keywords),
          ],
        ),
        model: FakeChatModel.text('Refunds take thirty days [1].'),
        finalK: 2,
      );

      final answer = await pipeline.answer(
        'how long do refunds take?',
        filter: const MetadataFilter.equals('team', 'billing'),
      );

      expect(answer.isGrounded, isTrue);
      expect(answer.citations.single.documentId, 'handbook.md');
      expect(answer.context.chunks.first.text, contains('thirty days'));
      expect(answer.context.chunks.first.chunk.heading, 'Handbook › Refunds');
    });

    test('an agent can search the corpus as a tool', () async {
      final fresh = await freshIndex();
      final indexer = RagIndexer(index: fresh.index);
      await indexer.indexAll(<RagDocument>[
        documentOf(
          'policy.md',
          'Refunds are processed within thirty days.',
          title: 'Policy',
        ),
      ]);

      final tool = searchTool(
        retriever: VectorRetriever(index: fresh.index),
        corpus: 'the policy documents',
      );

      final result = await tool.call(
        ToolInvocation(
          callId: 'c1',
          toolName: tool.spec.name,
          arguments: const <String, Object?>{'query': 'refunds processed'},
          context: AgenticContext.root(),
        ),
      );

      expect(result.isError, isFalse);
      expect(result.content, contains('[1] Policy'));
      expect(result.content, contains('thirty days'));
    });

    test('the search tool says nothing was found, in words', () async {
      final tool = searchTool(
        retriever: StubRetriever(const <RetrievedChunk>[]),
        corpus: 'the handbook',
      );

      final result = await tool.call(
        ToolInvocation(
          callId: 'c1',
          toolName: tool.spec.name,
          arguments: const <String, Object?>{'query': 'anything'},
          context: AgenticContext.root(),
        ),
      );

      expect(result.isError, isFalse);
      expect(result.content, contains('do not appear to cover this'));
    });

    test('an answering tool returns the answer and its sources', () async {
      final pipeline = RagPipeline(
        retriever: StubRetriever(<RetrievedChunk>[
          RetrievedChunk(
            chunk: chunkOf(
              'handbook.md#1',
              text: 'Refunds take thirty days.',
              documentId: 'handbook.md',
              title: 'Handbook',
            ),
            score: 0.9,
          ),
        ]),
        model: FakeChatModel.text('Thirty days [1].'),
      );

      final tool = answeringTool(pipeline: pipeline);
      final result = await tool.call(
        ToolInvocation(
          callId: 'c1',
          toolName: tool.spec.name,
          arguments: const <String, Object?>{
            'question': 'How long do refunds take?',
          },
          context: AgenticContext.root(),
        ),
      );

      expect(result.content, contains('Thirty days [1].'));
      expect(result.content, contains('Sources:'));
      expect(result.content, contains('[1] Handbook'));
      expect((result.data! as JsonMap)['grounded'], isTrue);
    });
  });
}

/// A chunker that fails for one document, to test partial ingestion.
final class _AngryChunker extends BaseChunker {
  @override
  String get name => 'angry';

  @override
  List<ChunkPiece> split(RagDocument document) {
    if (document.id == 'bad.md') {
      throw StorageException(
        'This document cannot be read.',
        store: 'test',
        operation: 'chunk',
      );
    }
    return <ChunkPiece>[ChunkPiece(text: document.content)];
  }
}

/// A re-ranker that records what it was asked to do.
final class _RecordingReranker implements Reranker {
  @override
  String get name => 'recording';

  final List<List<RetrievedChunk>> seen = <List<RetrievedChunk>>[];
  final List<int> topKs = <int>[];

  @override
  Future<List<RetrievedChunk>> rerank(
    String query,
    List<RetrievedChunk> results, {
    int topK = 4,
    AgenticContext? context,
  }) async {
    seen.add(results);
    topKs.add(topK);
    return results;
  }
}
