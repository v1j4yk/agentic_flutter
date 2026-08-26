import 'dart:convert';

import 'package:agentic_core/agentic_core.dart';
import 'package:agentic_core/testing.dart';
import 'package:agentic_llm/agentic_llm.dart';
import 'package:agentic_vector/agentic_vector.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

/// A vector pointing along one axis, so relevance is obvious by construction.
List<double> axis(int index, {int dimensions = 4, double magnitude = 1}) {
  final values = List<double>.filled(dimensions, 0);
  values[index] = magnitude;
  return values;
}

VectorRecord recordOf(
  String id, {
  required int onAxis,
  JsonMap metadata = const <String, Object?>{},
  String? text,
  int dimensions = 4,
}) => VectorRecord(
  id: id,
  vector: axis(onAxis, dimensions: dimensions),
  metadata: metadata,
  text: text ?? 'text for $id',
);

/// An embedding model that records how it was called.
///
/// The shipped `FakeEmbeddingModel` is deterministic but does not remember
/// batch boundaries or purposes, and both are contracts `EmbeddingIndex` has
/// to keep.
final class RecordingEmbeddingModel implements EmbeddingModel {
  RecordingEmbeddingModel({this.dimensions = 4, this.maxBatchSize = 2})
    : info = ModelInfo(id: 'recording', provider: 'test');

  @override
  final ModelInfo info;

  @override
  final int dimensions;

  @override
  final int maxBatchSize;

  final List<List<String>> batches = <List<String>>[];
  final List<EmbeddingPurpose> purposes = <EmbeddingPurpose>[];

  /// When set, the model returns this many vectors regardless of input count.
  int? returnCount;

  @override
  Future<List<Embedding>> embed(
    List<String> inputs, {
    required EmbeddingPurpose purpose,
    AgenticContext? context,
  }) async {
    batches.add(List<String>.unmodifiable(inputs));
    purposes.add(purpose);
    final count = returnCount ?? inputs.length;
    return <Embedding>[
      for (var i = 0; i < count; i++)
        Embedding(
          values: <double>[
            for (var d = 0; d < dimensions; d++)
              (i < inputs.length ? inputs[i].length : 0) + d.toDouble(),
          ],
          index: i,
        ),
    ];
  }

  @override
  Future<void> dispose() async {}
}

void main() {
  group('MetadataFilter', () {
    test('equality matches the stored value and nothing else', () {
      const filter = MetadataFilter.equals('tenant', 'acme');
      expect(filter.matches(<String, Object?>{'tenant': 'acme'}), isTrue);
      expect(filter.matches(<String, Object?>{'tenant': 'other'}), isFalse);
      expect(filter.matches(const <String, Object?>{}), isFalse);
    });

    test('inequality matches records missing the field', () {
      const filter = MetadataFilter.notEquals('status', 'archived');
      expect(filter.matches(const <String, Object?>{}), isTrue);
      expect(filter.matches(<String, Object?>{'status': 'archived'}), isFalse);
    });

    test('membership matches any element of a list-valued field', () {
      final filter = MetadataFilter.inValues('tags', <String>['dart', 'ai']);
      expect(
        filter.matches(<String, Object?>{
          'tags': <String>['flutter', 'dart'],
        }),
        isTrue,
      );
      expect(filter.matches(<String, Object?>{'tags': 'dart'}), isTrue);
      expect(
        filter.matches(<String, Object?>{
          'tags': <String>['rust'],
        }),
        isFalse,
      );
    });

    test('comparisons never match a non-numeric or absent field', () {
      const gt = MetadataFilter.greaterThan('year', 2024);
      expect(gt.matches(<String, Object?>{'year': 2025}), isTrue);
      expect(gt.matches(<String, Object?>{'year': 2024}), isFalse);
      expect(gt.matches(<String, Object?>{'year': 'recent'}), isFalse);
      expect(gt.matches(const <String, Object?>{}), isFalse);

      const gte = MetadataFilter.greaterThan('year', 2024, orEqual: true);
      expect(gte.matches(<String, Object?>{'year': 2024}), isTrue);

      const lte = MetadataFilter.lessThan('year', 2024, orEqual: true);
      expect(lte.matches(<String, Object?>{'year': 2024}), isTrue);
      expect(lte.matches(<String, Object?>{'year': 2025}), isFalse);
    });

    test('existence treats an explicit null as absent', () {
      const filter = MetadataFilter.exists('author');
      expect(filter.matches(<String, Object?>{'author': 'Ada'}), isTrue);
      expect(filter.matches(<String, Object?>{'author': null}), isFalse);
    });

    test('composes with and, or and not', () {
      final filter = MetadataFilter.and(<MetadataFilter>[
        const MetadataFilter.equals('tenant', 'acme'),
        MetadataFilter.or(<MetadataFilter>[
          const MetadataFilter.greaterThan('year', 2024),
          const MetadataFilter.equals('pinned', true),
        ]),
        const MetadataFilter.not(MetadataFilter.equals('status', 'archived')),
      ]);

      expect(
        filter.matches(<String, Object?>{'tenant': 'acme', 'year': 2025}),
        isTrue,
      );
      expect(
        filter.matches(<String, Object?>{'tenant': 'acme', 'pinned': true}),
        isTrue,
      );
      expect(
        filter.matches(<String, Object?>{
          'tenant': 'acme',
          'year': 2025,
          'status': 'archived',
        }),
        isFalse,
      );
      expect(
        filter.matches(<String, Object?>{'tenant': 'other', 'year': 2025}),
        isFalse,
      );
    });

    test('serialises to a shape a backend can read', () {
      final filter = MetadataFilter.and(<MetadataFilter>[
        const MetadataFilter.equals('tenant', 'acme'),
        const MetadataFilter.lessThan('year', 2030),
      ]);
      expect(filter.toJson(), <String, Object?>{
        'op': 'and',
        'filters': <Object?>[
          <String, Object?>{'op': 'eq', 'field': 'tenant', 'value': 'acme'},
          <String, Object?>{'op': 'lt', 'field': 'year', 'value': 2030},
        ],
      });
    });
  });

  group('similarity', () {
    test('cosine is 1 for identical and 0 for orthogonal vectors', () {
      expect(cosineSimilarity(axis(0), axis(0)), closeTo(1, 1e-12));
      expect(cosineSimilarity(axis(0), axis(1)), closeTo(0, 1e-12));
      expect(
        cosineSimilarity(axis(0), axis(0, magnitude: 42)),
        closeTo(1, 1e-12),
        reason: 'cosine ignores magnitude',
      );
    });

    test('cosine of a zero vector is 0 rather than a NaN', () {
      expect(cosineSimilarity(axis(0), List<double>.filled(4, 0)), 0);
    });

    test('comparing different widths names the likely cause', () {
      expect(
        () => cosineSimilarity(axis(0), axis(0, dimensions: 8)),
        throwsA(
          isA<ValidationException>().having(
            (e) => e.message,
            'message',
            contains('embedding model'),
          ),
        ),
      );
    });

    test('every metric scores higher for closer vectors', () {
      final near = axis(0, magnitude: 0.9);
      final far = axis(1);
      for (final metric in SimilarityMetric.values) {
        expect(
          metric.score(axis(0), near),
          greaterThan(metric.score(axis(0), far)),
          reason: '${metric.name} must rank the nearer vector higher',
        );
      }
    });

    test('euclidean scores are bounded and peak at 1', () {
      expect(SimilarityMetric.euclidean.score(axis(0), axis(0)), 1);
      expect(SimilarityMetric.euclidean.score(axis(0), axis(1)), lessThan(1));
      expect(
        SimilarityMetric.euclidean.score(axis(0), axis(1)),
        greaterThan(0),
      );
    });

    test('normalising makes dot product equal cosine', () {
      final a = normalise(<double>[3, 4, 0, 0]);
      final b = normalise(<double>[0, 4, 3, 0]);
      expect(dotProduct(a, b), closeTo(cosineSimilarity(a, b), 1e-12));
      expect(normalise(List<double>.filled(4, 0)), everyElement(0));
    });
  });

  group('VectorRecord', () {
    test('round-trips through JSON', () {
      final record = VectorRecord(
        id: 'doc-1#0',
        vector: <double>[0.1, 0.2],
        metadata: <String, Object?>{'topic': 'dart'},
        text: 'Dart 3 added patterns.',
      );
      final restored = VectorRecord.fromJson(
        jsonDecode(jsonEncode(record.toJson())) as JsonMap,
      );
      expect(restored.id, record.id);
      expect(restored.vector, record.vector);
      expect(restored.metadata, record.metadata);
      expect(restored.text, record.text);
    });

    test('is immutable in both collections it holds', () {
      final metadata = <String, Object?>{'a': 1};
      final vector = <double>[1, 2];
      final record = VectorRecord(id: 'r', vector: vector, metadata: metadata);
      vector.add(3);
      metadata['b'] = 2;
      expect(record.vector, <double>[1, 2]);
      expect(record.metadata, <String, Object?>{'a': 1});
      expect(() => record.metadata['c'] = 3, throwsUnsupportedError);
    });

    test('reports whether it carries a vector', () {
      expect(recordOf('r', onAxis: 0).hasVector, isTrue);
      expect(
        VectorRecord(id: 'r', vector: const <double>[]).hasVector,
        isFalse,
      );
    });

    test('identity is the identifier, so upserts deduplicate', () {
      final a = recordOf('same', onAxis: 0);
      final b = recordOf('same', onAxis: 1);
      expect(a, b);
      expect(<VectorRecord>{a, b}, hasLength(1));
    });

    test('a query keeps its vector out of its own serialisation', () {
      final query = VectorQuery(
        vector: axis(0),
        topK: 3,
        filter: const MetadataFilter.equals('t', 'a'),
        minScore: 0.5,
      );
      final json = query.toJson();
      expect(json.containsKey('vector'), isFalse);
      expect(json['dimensions'], 4);
      expect(json['topK'], 3);
      expect(json['minScore'], 0.5);
    });

    test('rejects a non-positive topK', () {
      expect(() => VectorQuery(vector: axis(0), topK: 0), throwsA(anything));
    });
  });

  group('InMemoryVectorStore', () {
    test('upsert replaces by identifier rather than duplicating', () async {
      final store = InMemoryVectorStore(dimensions: 4);
      await store.upsertOne(recordOf('doc-1', onAxis: 0, text: 'first'));
      await store.upsertOne(recordOf('doc-1', onAxis: 1, text: 'second'));

      expect(store.length, 1);
      expect((await store.get('doc-1'))!.text, 'second');
    });

    test('ranks by similarity and honours topK', () async {
      final store = InMemoryVectorStore(dimensions: 4);
      await store.upsertAll(<VectorRecord>[
        recordOf('near', onAxis: 0),
        recordOf('mid', onAxis: 1),
        recordOf('far', onAxis: 2),
      ]);

      final hits = await store.searchVector(<double>[1, 0.5, 0, 0], topK: 2);
      expect(hits.map((h) => h.id), <String>['near', 'mid']);
      expect(hits.first.score, greaterThan(hits.last.score));
    });

    test('filters before ranking, so topK still comes back full', () async {
      // The regression this port exists to prevent: with post-filtering, the
      // three `other` records would consume the top-3 window and this query
      // would return one result instead of two.
      final store = InMemoryVectorStore(dimensions: 4);
      await store.upsertAll(<VectorRecord>[
        for (var i = 0; i < 3; i++)
          VectorRecord(
            id: 'other-$i',
            vector: <double>[1, 0, 0, 0],
            metadata: const <String, Object?>{'tenant': 'other'},
          ),
        VectorRecord(
          id: 'mine-0',
          vector: <double>[0.9, 0.1, 0, 0],
          metadata: const <String, Object?>{'tenant': 'acme'},
        ),
        VectorRecord(
          id: 'mine-1',
          vector: <double>[0.8, 0.2, 0, 0],
          metadata: const <String, Object?>{'tenant': 'acme'},
        ),
      ]);

      final hits = await store.searchVector(
        <double>[1, 0, 0, 0],
        topK: 2,
        filter: const MetadataFilter.equals('tenant', 'acme'),
      );
      expect(hits.map((h) => h.id), <String>['mine-0', 'mine-1']);
    });

    test('drops matches below the score floor', () async {
      final store = InMemoryVectorStore(dimensions: 4);
      await store.upsertAll(<VectorRecord>[
        recordOf('same', onAxis: 0),
        recordOf('orthogonal', onAxis: 1),
      ]);

      final hits = await store.searchVector(axis(0), minScore: 0.5);
      expect(hits.map((h) => h.id), <String>['same']);
    });

    test('omits vectors unless the query asks for them', () async {
      final store = InMemoryVectorStore(dimensions: 4);
      await store.upsertOne(recordOf('doc', onAxis: 0));

      final lean = await store.searchVector(axis(0));
      expect(lean.single.record.hasVector, isFalse);
      expect(lean.single.text, isNotNull);

      final full = await store.searchVector(axis(0), includeVectors: true);
      expect(full.single.record.vector, axis(0));
    });

    test('keeps namespaces apart', () async {
      final store = InMemoryVectorStore(dimensions: 4);
      await store.upsertOne(recordOf('a', onAxis: 0), namespace: 'tenant-a');
      await store.upsertOne(recordOf('b', onAxis: 0), namespace: 'tenant-b');

      final hits = await store.searchVector(axis(0), namespace: 'tenant-a');
      expect(hits.map((h) => h.id), <String>['a']);
      expect(await store.get('b', namespace: 'tenant-a'), isNull);
      expect(await store.count(namespace: 'tenant-b'), 1);
      expect(await store.count(), 2, reason: 'no namespace means all of them');
    });

    test('clears one namespace without touching the others', () async {
      final store = InMemoryVectorStore(dimensions: 4);
      await store.upsertOne(recordOf('a', onAxis: 0), namespace: 'a');
      await store.upsertOne(recordOf('b', onAxis: 0), namespace: 'b');

      await store.clear(namespace: 'a');
      expect(await store.count(namespace: 'a'), 0);
      expect(await store.count(namespace: 'b'), 1);

      await store.clear();
      expect(store.length, 0);
    });

    test('deletes by filter across every namespace', () async {
      final store = InMemoryVectorStore(dimensions: 4);
      await store.upsertOne(
        recordOf(
          'a',
          onAxis: 0,
          metadata: <String, Object?>{'doc': 'guide.md'},
        ),
        namespace: 'one',
      );
      await store.upsertOne(
        recordOf(
          'b',
          onAxis: 0,
          metadata: <String, Object?>{'doc': 'guide.md'},
        ),
        namespace: 'two',
      );
      await store.upsertOne(
        recordOf('c', onAxis: 0, metadata: <String, Object?>{'doc': 'other'}),
        namespace: 'two',
      );

      final removed = await store.deleteWhere(
        const MetadataFilter.equals('doc', 'guide.md'),
      );
      expect(removed, 2);
      expect(store.length, 1);
    });

    test('deleting reports only what was actually there', () async {
      final store = InMemoryVectorStore(dimensions: 4);
      await store.upsertOne(recordOf('a', onAxis: 0));

      expect(await store.delete(<String>['a', 'missing']), 1);
      expect(await store.deleteOne('a'), isFalse);
    });

    test('names every record whose width is wrong, not just the first', () {
      final store = InMemoryVectorStore(dimensions: 4);
      expect(
        () => store.upsert(<VectorRecord>[
          recordOf('good', onAxis: 0),
          recordOf('bad-1', onAxis: 0, dimensions: 8),
          recordOf('bad-2', onAxis: 0, dimensions: 2),
        ]),
        throwsA(
          isA<ValidationException>().having(
            (e) => e.violations,
            'violations',
            hasLength(2),
          ),
        ),
      );
    });

    test('rejects a query of the wrong width', () {
      final store = InMemoryVectorStore(dimensions: 4);
      expect(
        () => store.searchVector(axis(0, dimensions: 8)),
        throwsA(isA<ValidationException>()),
      );
    });

    test('evicts oldest first once the record cap is reached', () async {
      final store = InMemoryVectorStore(dimensions: 4, maxRecords: 2);
      await store.upsertOne(recordOf('first', onAxis: 0));
      await store.upsertOne(recordOf('second', onAxis: 0));
      await store.upsertOne(recordOf('third', onAxis: 0));

      expect(store.length, 2);
      expect(await store.get('first'), isNull);
      expect(await store.get('third'), isNotNull);
    });

    test('re-upserting keeps a record in its original position', () async {
      final store = InMemoryVectorStore(dimensions: 4, maxRecords: 2);
      await store.upsertOne(recordOf('first', onAxis: 0));
      await store.upsertOne(recordOf('second', onAxis: 0));
      await store.upsertOne(recordOf('first', onAxis: 1, text: 'updated'));
      await store.upsertOne(recordOf('third', onAxis: 0));

      expect(
        await store.get('first'),
        isNull,
        reason: 'an update is not an access; insertion order is unchanged',
      );
    });

    test('snapshots and restores an index, vectors included', () async {
      final store = InMemoryVectorStore(dimensions: 4, maxRecords: 10);
      await store.upsertOne(
        recordOf('a', onAxis: 0, metadata: <String, Object?>{'topic': 'dart'}),
      );
      await store.upsertOne(recordOf('b', onAxis: 1), namespace: 'other');

      final restored = InMemoryVectorStore.fromJson(
        jsonDecode(jsonEncode(store.snapshot())) as JsonMap,
      );

      expect(restored.length, 2);
      expect(restored.maxRecords, 10);
      expect(restored.info.dimensions, 4);
      expect((await restored.get('a'))!.metadata['topic'], 'dart');
      final hits = await restored.searchVector(
        axis(1),
        namespace: 'other',
        includeVectors: true,
      );
      expect(hits.single.record.vector, axis(1));
    });

    test('disposal empties the index', () async {
      final store = InMemoryVectorStore(dimensions: 4);
      await store.upsertOne(recordOf('a', onAxis: 0));
      await store.dispose();
      expect(store.length, 0);
    });
  });

  group('VectorStoreOperations', () {
    test('upsertAll splits into batches the store accepts', () async {
      final store = _CountingStore(
        const VectorStoreInfo(
          name: 'counting',
          dimensions: 4,
          maxUpsertBatch: 2,
        ),
      );

      final written = await store.upsertAll(<VectorRecord>[
        for (var i = 0; i < 5; i++) recordOf('r$i', onAxis: 0),
      ]);

      expect(written, 5);
      expect(store.batchSizes, <int>[2, 2, 1]);
    });

    test('a cancelled ingestion stops at a batch boundary', () async {
      final source = CancellationTokenSource();
      final context = AgenticContext.root(cancellation: source.token);
      final store = _CountingStore(
        const VectorStoreInfo(
          name: 'counting',
          dimensions: 4,
          maxUpsertBatch: 2,
        ),
        onUpsert: (batch) {
          if (batch.first.id == 'r2') source.cancel('enough');
        },
      );

      await expectLater(
        store.upsertAll(<VectorRecord>[
          for (var i = 0; i < 6; i++) recordOf('r$i', onAxis: 0),
        ], context: context),
        throwsA(isA<CancelledException>()),
      );
      expect(store.batchSizes, <int>[2, 2], reason: 'no half-applied batch');
    });

    test('a store without namespaces refuses one rather than merging', () {
      final store = _CountingStore(
        const VectorStoreInfo(
          name: 'flat',
          dimensions: 4,
          supportsNamespaces: false,
        ),
      );
      expect(
        () => store.checkNamespace('tenant-a'),
        throwsA(
          isA<CapabilityNotSupportedException>().having(
            (e) => e.capability,
            'capability',
            'namespaces',
          ),
        ),
      );
      expect(() => store.checkNamespace(null), returnsNormally);
    });
  });

  group('decorators', () {
    test('observability publishes what was asked and what came back', () async {
      final bus = BroadcastEventBus();
      final inner = InMemoryVectorStore(dimensions: 4);
      final store = ObservableVectorStore(inner);
      final context = AgenticContext.root(
        events: bus,
        ids: SequentialIdGenerator(prefix: 'e'),
        clock: FakeClock(autoAdvance: true),
      );

      await store.upsert(<VectorRecord>[
        recordOf('a', onAxis: 0),
      ], context: context);
      await store.search(
        VectorQuery(
          vector: axis(0),
          topK: 5,
          filter: const MetadataFilter.exists('missing'),
        ),
        context: context,
      );

      final upserted = bus.replayBuffer
          .whereType<VectorUpsertCompleted>()
          .single;
      expect(upserted.count, 1);
      expect(upserted.store, 'in-memory');

      final searched = bus.replayBuffer
          .whereType<VectorSearchCompleted>()
          .single;
      expect(searched.topK, 5);
      expect(searched.returned, 0, reason: 'the filter excluded everything');
      expect(searched.filtered, isTrue);
      expect(searched.payload().containsKey('topScore'), isFalse);
      await bus.dispose();
    });

    test('observability reports a failure and still rethrows it', () async {
      final bus = BroadcastEventBus();
      final store = ObservableVectorStore(InMemoryVectorStore(dimensions: 4));
      final context = AgenticContext.root(
        events: bus,
        ids: SequentialIdGenerator(prefix: 'e'),
      );

      await expectLater(
        store.search(
          VectorQuery(vector: axis(0, dimensions: 8)),
          context: context,
        ),
        throwsA(isA<ValidationException>()),
      );

      final failure = bus.replayBuffer
          .whereType<VectorOperationFailed>()
          .single;
      expect(failure.operation, 'search');
      expect(failure.code, 'validation_error');
      await bus.dispose();
    });

    test('observability is transparent without a context', () async {
      final store = ObservableVectorStore(InMemoryVectorStore(dimensions: 4));
      await store.upsertOne(recordOf('a', onAxis: 0));
      expect((await store.searchVector(axis(0))).single.id, 'a');
    });

    test('a namespaced handle cannot reach another partition', () async {
      final shared = InMemoryVectorStore(dimensions: 4);
      final acme = NamespacedVectorStore(shared, namespace: 'acme');
      final other = NamespacedVectorStore(shared, namespace: 'other');

      await acme.upsertOne(recordOf('a', onAxis: 0));
      await other.upsertOne(recordOf('b', onAxis: 0));

      // Even asking for the other namespace explicitly is ignored.
      final hits = await acme.searchVector(axis(0), namespace: 'other');
      expect(hits.map((h) => h.id), <String>['a']);
      expect(await acme.get('b', namespace: 'other'), isNull);
      expect(await acme.count(), 1);
    });

    test('clearing a namespaced handle leaves the rest of the index', () async {
      final shared = InMemoryVectorStore(dimensions: 4);
      final acme = NamespacedVectorStore(shared, namespace: 'acme');
      await acme.upsertOne(recordOf('a', onAxis: 0));
      await shared.upsertOne(recordOf('b', onAxis: 0), namespace: 'other');

      await acme.clear();
      expect(shared.length, 1);
    });

    test(
      'disposing a namespaced handle leaves the shared store open',
      () async {
        final shared = InMemoryVectorStore(dimensions: 4);
        final acme = NamespacedVectorStore(shared, namespace: 'acme');
        await acme.upsertOne(recordOf('a', onAxis: 0));

        await acme.dispose();
        expect(shared.length, 1);
      },
    );
  });

  group('EmbeddingIndex', () {
    test('refuses a model whose width does not match the index', () {
      expect(
        () => EmbeddingIndex(
          model: RecordingEmbeddingModel(dimensions: 8),
          store: InMemoryVectorStore(dimensions: 4),
        ),
        throwsA(
          isA<ConfigurationException>().having(
            (e) => e.setting,
            'setting',
            'dimensions',
          ),
        ),
      );
    });

    test('embeds in batches the model accepts', () async {
      final model = RecordingEmbeddingModel(maxBatchSize: 2);
      final index = EmbeddingIndex(
        model: model,
        store: InMemoryVectorStore(dimensions: 4),
      );

      await index.addTexts(<String>['a', 'bb', 'ccc', 'dddd', 'eeeee']);

      expect(model.batches.map((b) => b.length), <int>[2, 2, 1]);
      expect(
        model.purposes,
        everyElement(EmbeddingPurpose.document),
        reason: 'stored text is a document, not a query',
      );
      expect(await index.count(), 5);
    });

    test('uses the query encoder when searching', () async {
      final model = RecordingEmbeddingModel();
      final index = EmbeddingIndex(
        model: model,
        store: InMemoryVectorStore(dimensions: 4),
      );
      await index.addText('a document');
      await index.query('a question');

      expect(model.purposes.last, EmbeddingPurpose.query);
    });

    test('stable identifiers make re-indexing idempotent', () async {
      final store = InMemoryVectorStore(dimensions: 4);
      final index = EmbeddingIndex(
        model: RecordingEmbeddingModel(),
        store: store,
      );

      await index.addText('first version', id: 'guide.md#0');
      await index.addText('second version', id: 'guide.md#0');

      expect(store.length, 1);
      expect((await store.get('guide.md#0'))!.text, 'second version');
    });

    test('pairs metadata with texts by position, or refuses', () async {
      final index = EmbeddingIndex(
        model: RecordingEmbeddingModel(),
        store: InMemoryVectorStore(dimensions: 4),
      );

      await expectLater(
        index.addTexts(
          <String>['a', 'b'],
          metadatas: <JsonMap>[<String, Object?>{}],
        ),
        throwsA(
          isA<ValidationException>().having(
            (e) => e.violations.single,
            'violation',
            contains('metadatas'),
          ),
        ),
      );
    });

    test('detects a model that returns the wrong number of vectors', () async {
      final model = RecordingEmbeddingModel(maxBatchSize: 10)..returnCount = 1;
      final index = EmbeddingIndex(
        model: model,
        store: InMemoryVectorStore(dimensions: 4),
      );

      await expectLater(
        index.addTexts(<String>['a', 'b']),
        throwsA(isA<ProviderException>()),
      );
    });

    test('can index without keeping the text', () async {
      final store = InMemoryVectorStore(dimensions: 4);
      final index = EmbeddingIndex(
        model: RecordingEmbeddingModel(),
        store: store,
      );

      await index.addText('secret', id: 'r', storeText: false);
      expect((await store.get('r'))!.text, isNull);
    });

    test('disposes the store it owns and leaves the model alone', () async {
      final store = InMemoryVectorStore(dimensions: 4);
      final index = EmbeddingIndex(
        model: RecordingEmbeddingModel(),
        store: store,
      );
      await index.addText('a');
      await index.dispose();
      expect(store.length, 0);
    });
  });

  group('QdrantVectorStore', () {
    /// Captures every request and answers with canned bodies.
    ({List<http.Request> requests, MockClient client}) recorder(
      Map<String, Object?> Function(http.Request request) respond, {
      int status = 200,
    }) {
      final requests = <http.Request>[];
      final client = MockClient((request) async {
        requests.add(request);
        return http.Response(
          jsonEncode(respond(request)),
          status,
          headers: <String, String>{'content-type': 'application/json'},
        );
      });
      return (requests: requests, client: client);
    }

    QdrantVectorStore storeWith(
      http.Client client, {
      SimilarityMetric metric = SimilarityMetric.cosine,
      int dimensions = 4,
    }) => QdrantVectorStore(
      baseUrl: Uri.parse('http://localhost:6333'),
      collection: 'docs',
      dimensions: dimensions,
      metric: metric,
      client: client,
      apiKey: 'secret-key',
    );

    test('derives a stable point identifier for a non-UUID id', () {
      final first = QdrantVectorStore.pointIdFor('guide.md#3');
      final second = QdrantVectorStore.pointIdFor('guide.md#3');
      expect(first, second, reason: 're-indexing must replace, not duplicate');
      expect(first, isA<String>());
      expect(
        first,
        matches(
          RegExp(
            r'^[0-9a-f]{8}-[0-9a-f]{4}-5[0-9a-f]{3}-[89ab][0-9a-f]{3}-'
            r'[0-9a-f]{12}$',
          ),
        ),
        reason: 'a version 5, RFC 4122 variant UUID',
      );
      expect(QdrantVectorStore.pointIdFor('guide.md#4'), isNot(first));
    });

    test('passes through identifiers Qdrant already accepts', () {
      expect(QdrantVectorStore.pointIdFor('42'), 42);
      expect(
        QdrantVectorStore.pointIdFor('6ba7b810-9dad-11d1-80b4-00c04fd430c8'),
        '6ba7b810-9dad-11d1-80b4-00c04fd430c8',
      );
      expect(QdrantVectorStore.pointIdFor('-1'), isA<String>());
    });

    test('writes points with the payload and waits for indexing', () async {
      final rec = recorder(
        (_) => <String, Object?>{'result': <String, Object?>{}},
      );
      final store = storeWith(rec.client);

      await store.upsertOne(
        recordOf(
          'guide.md#0',
          onAxis: 0,
          metadata: <String, Object?>{'topic': 'dart'},
          text: 'Dart 3 added patterns.',
        ),
      );

      final request = rec.requests.single;
      expect(request.method, 'PUT');
      expect(request.url.path, '/collections/docs/points');
      expect(request.url.query, 'wait=true');
      expect(request.headers['api-key'], 'secret-key');

      final point =
          ((jsonDecode(request.body) as JsonMap)['points']! as List<Object?>)
                  .single!
              as JsonMap;
      expect(point['id'], QdrantVectorStore.pointIdFor('guide.md#0'));
      expect(point['vector'], axis(0));
      final payload = point['payload']! as JsonMap;
      expect(payload['topic'], 'dart');
      expect(payload[kQdrantIdKey], 'guide.md#0');
      expect(payload[kQdrantTextKey], 'Dart 3 added patterns.');
    });

    test('refuses a batch larger than the server accepts', () async {
      final store = QdrantVectorStore(
        baseUrl: Uri.parse('http://localhost:6333'),
        collection: 'docs',
        dimensions: 4,
        maxUpsertBatch: 2,
        client: MockClient((_) async => http.Response('{}', 200)),
      );

      await expectLater(
        store.upsert(<VectorRecord>[
          for (var i = 0; i < 3; i++) recordOf('r$i', onAxis: 0),
        ]),
        throwsA(
          isA<ValidationException>().having(
            (e) => e.message,
            'message',
            contains('upsertAll'),
          ),
        ),
      );
    });

    test('reads matches back, restoring the caller identifier', () async {
      final rec = recorder(
        (_) => <String, Object?>{
          'result': <Object?>[
            <String, Object?>{
              'id': 12,
              'score': 0.83,
              'payload': <String, Object?>{
                kQdrantIdKey: 'guide.md#0',
                kQdrantTextKey: 'Dart 3 added patterns.',
                'topic': 'dart',
              },
            },
            <String, Object?>{
              'id': 'e2e1f5b0-0000-4000-8000-000000000000',
              'score': 0.42,
              'payload': <String, Object?>{'topic': 'flutter'},
            },
          ],
        },
      );
      final store = storeWith(rec.client);

      final hits = await store.searchVector(
        axis(0),
        topK: 2,
        filter: const MetadataFilter.equals('topic', 'dart'),
      );

      expect(hits.map((h) => h.id), <String>[
        'guide.md#0',
        'e2e1f5b0-0000-4000-8000-000000000000',
      ]);
      expect(hits.first.score, 0.83);
      expect(hits.first.text, 'Dart 3 added patterns.');
      expect(hits.first.record.metadata, <String, Object?>{'topic': 'dart'});
      expect(
        hits.first.record.metadata.containsKey(kQdrantIdKey),
        isFalse,
        reason: 'adapter bookkeeping must not leak into caller metadata',
      );

      final body = jsonDecode(rec.requests.single.body) as JsonMap;
      expect(body['limit'], 2);
      expect(body['with_payload'], true);
      expect(body['with_vector'], false);
      expect(body.containsKey('score_threshold'), isFalse);
      expect(body['filter'], <String, Object?>{
        'must': <Object?>[
          <String, Object?>{
            'key': 'topic',
            'match': <String, Object?>{'value': 'dart'},
          },
        ],
      });
    });

    test(
      'converts euclidean scores and thresholds in both directions',
      () async {
        final rec = recorder(
          (_) => <String, Object?>{
            'result': <Object?>[
              <String, Object?>{'id': 1, 'score': 1.0, 'payload': null},
            ],
          },
        );
        final store = storeWith(rec.client, metric: SimilarityMetric.euclidean);

        final hits = await store.searchVector(axis(0), minScore: 0.5);

        // A distance of 1 is a score of 1 / (1 + 1).
        expect(hits.single.score, closeTo(0.5, 1e-12));
        // A score floor of 0.5 is a distance ceiling of 1 / 0.5 - 1.
        final body = jsonDecode(rec.requests.single.body) as JsonMap;
        expect(body['score_threshold'], closeTo(1, 1e-12));
      },
    );

    test('translates every filter kind into Qdrant syntax', () {
      expect(
        QdrantVectorStore.translateFilter(
          MetadataFilter.inValues('tags', <String>['a', 'b']),
        ),
        <String, Object?>{
          'must': <Object?>[
            <String, Object?>{
              'key': 'tags',
              'match': <String, Object?>{
                'any': <String>['a', 'b'],
              },
            },
          ],
        },
      );
      expect(
        QdrantVectorStore.translateFilter(
          const MetadataFilter.greaterThan('year', 2024, orEqual: true),
        ),
        <String, Object?>{
          'must': <Object?>[
            <String, Object?>{
              'key': 'year',
              'range': <String, Object?>{'gte': 2024},
            },
          ],
        },
      );
      expect(
        QdrantVectorStore.translateFilter(
          const MetadataFilter.exists('author'),
        ),
        <String, Object?>{
          'must_not': <Object?>[
            <String, Object?>{
              'is_empty': <String, Object?>{'key': 'author'},
            },
          ],
        },
      );
      expect(
        QdrantVectorStore.translateFilter(
          MetadataFilter.or(<MetadataFilter>[
            const MetadataFilter.equals('a', 1),
            const MetadataFilter.not(MetadataFilter.equals('b', 2)),
          ]),
        ),
        <String, Object?>{
          'should': <Object?>[
            <String, Object?>{
              'must': <Object?>[
                <String, Object?>{
                  'key': 'a',
                  'match': <String, Object?>{'value': 1},
                },
              ],
            },
            <String, Object?>{
              'must_not': <Object?>[
                <String, Object?>{
                  'must': <Object?>[
                    <String, Object?>{
                      'key': 'b',
                      'match': <String, Object?>{'value': 2},
                    },
                  ],
                },
              ],
            },
          ],
        },
      );
    });

    test(
      'counts before deleting by filter, so the count is truthful',
      () async {
        final rec = recorder(
          (request) => request.url.path.endsWith('/count')
              ? <String, Object?>{
                  'result': <String, Object?>{'count': 7},
                }
              : <String, Object?>{'result': <String, Object?>{}},
        );
        final store = storeWith(rec.client);

        final removed = await store.deleteWhere(
          const MetadataFilter.equals('doc', 'guide.md'),
        );

        expect(removed, 7);
        expect(rec.requests.map((r) => r.url.path), <String>[
          '/collections/docs/points/count',
          '/collections/docs/points/delete',
        ]);
      },
    );

    test('skips the delete entirely when nothing matches', () async {
      final rec = recorder(
        (_) => <String, Object?>{
          'result': <String, Object?>{'count': 0},
        },
      );
      final store = storeWith(rec.client);

      expect(await store.deleteWhere(const MetadataFilter.exists('gone')), 0);
      expect(rec.requests, hasLength(1));
    });

    test('creates a collection only when it is missing', () async {
      final requests = <http.Request>[];
      var exists = false;
      final client = MockClient((request) async {
        requests.add(request);
        if (request.method == 'GET') {
          return http.Response(
            exists ? '{"result":{}}' : '{"status":{"error":"Not found"}}',
            exists ? 200 : 404,
          );
        }
        exists = true;
        return http.Response('{"result":true}', 200);
      });
      final store = storeWith(client);

      await store.ensureCollection();
      await store.ensureCollection();

      expect(requests.map((r) => r.method), <String>['GET', 'PUT', 'GET']);
      final created = jsonDecode(requests[1].body) as JsonMap;
      expect(created['vectors'], <String, Object?>{
        'size': 4,
        'distance': 'Cosine',
      });
    });

    test('maps a server failure onto the framework hierarchy', () async {
      final store = storeWith(
        MockClient(
          (_) async => http.Response(
            jsonEncode(<String, Object?>{
              'status': <String, Object?>{'error': 'Wrong input'},
            }),
            400,
          ),
        ),
      );

      await expectLater(
        store.searchVector(axis(0)),
        throwsA(
          isA<AgenticException>().having(
            (e) => e.isRetryable,
            'retryable',
            isFalse,
          ),
        ),
      );
    });

    test('a disposed store refuses to talk to the server', () async {
      final store = storeWith(
        MockClient((_) async => http.Response('{}', 200)),
      );
      await store.dispose();

      await expectLater(
        store.searchVector(axis(0)),
        throwsA(isA<InvalidStateException>()),
      );
    });

    test('a cancelled context stops the request before it is sent', () async {
      var sent = 0;
      final store = storeWith(
        MockClient((_) async {
          sent++;
          return http.Response('{}', 200);
        }),
      );
      final source = CancellationTokenSource()..cancel('user left');

      await expectLater(
        store.searchVector(
          axis(0),
          context: AgenticContext.root(cancellation: source.token),
        ),
        throwsA(isA<CancelledException>()),
      );
      expect(sent, 0);
    });
  });
}

/// A store that records the batches it is handed.
final class _CountingStore implements VectorStore {
  _CountingStore(this.info, {this.onUpsert});

  @override
  final VectorStoreInfo info;

  final void Function(List<VectorRecord> batch)? onUpsert;

  final List<int> batchSizes = <int>[];

  @override
  Future<void> upsert(
    List<VectorRecord> records, {
    String? namespace,
    AgenticContext? context,
  }) async {
    batchSizes.add(records.length);
    onUpsert?.call(records);
  }

  @override
  Future<List<VectorMatch>> search(
    VectorQuery query, {
    String? namespace,
    AgenticContext? context,
  }) async => const <VectorMatch>[];

  @override
  Future<VectorRecord?> get(String id, {String? namespace}) async => null;

  @override
  Future<int> delete(Iterable<String> ids, {String? namespace}) async => 0;

  @override
  Future<int> deleteWhere(MetadataFilter filter, {String? namespace}) async =>
      0;

  @override
  Future<int> count({String? namespace, MetadataFilter? filter}) async => 0;

  @override
  Future<void> clear({String? namespace}) async {}

  @override
  Future<void> dispose() async {}
}
