// Demonstrates the vector layer: an embedding model bound to a store, metadata
// filtering, namespaces, snapshots and observability.
//
// Run it with:
//
//     dart run example/agentic_vector_example.dart
//
// It runs offline. The embedding model below is a real one — hashed bag of
// words, normalised — not a stub: it needs no network and no download, which is
// exactly what an offline-first mobile index wants for a first pass.
import 'dart:convert';

import 'package:agentic_core/agentic_core.dart';
import 'package:agentic_llm/agentic_llm.dart';
import 'package:agentic_vector/agentic_vector.dart';

Future<void> main() async {
  // ---------------------------------------------------------------------------
  // 1. Index some text.
  // ---------------------------------------------------------------------------
  print('--- indexing ---');
  final model = HashingEmbeddingModel(dimensions: 128);
  final store = InMemoryVectorStore(dimensions: model.dimensions);
  final index = EmbeddingIndex(model: model, store: store);

  const corpus = <String, Map<String, Object?>>{
    'dart-patterns': {
      'text': 'Dart 3 added sealed classes and exhaustive pattern matching.',
      'topic': 'language',
      'year': 2023,
    },
    'dart-workspaces': {
      'text': 'Pub workspaces resolve every package in a monorepo together.',
      'topic': 'tooling',
      'year': 2024,
    },
    'flutter-impeller': {
      'text': 'Flutter renders with the Impeller engine on iOS and Android.',
      'topic': 'rendering',
      'year': 2023,
    },
    'flutter-hooks': {
      'text': 'Flutter widgets rebuild when their inherited state changes.',
      'topic': 'rendering',
      'year': 2025,
    },
  };

  await index.addTexts(
    corpus.values.map((e) => e['text']! as String).toList(),
    ids: corpus.keys.toList(),
    metadatas: corpus.values
        .map((e) => <String, Object?>{'topic': e['topic'], 'year': e['year']})
        .toList(),
  );
  print('indexed    : ${await index.count()} chunks');

  // Re-indexing the same identifiers replaces rather than duplicates.
  await index.addText(
    'Dart 3 added sealed classes, records and exhaustive pattern matching.',
    id: 'dart-patterns',
    metadata: {'topic': 'language', 'year': 2023},
  );
  print('re-indexed : ${await index.count()} chunks (unchanged)');

  // ---------------------------------------------------------------------------
  // 2. Ask a question.
  // ---------------------------------------------------------------------------
  print('\n--- retrieval ---');
  for (final hit in await index.query(
    'how does Flutter draw pixels?',
    topK: 2,
  )) {
    print('${hit.score.toStringAsFixed(3)}  ${hit.id}  ${hit.text}');
  }

  // ---------------------------------------------------------------------------
  // 3. Filter, so "closest" means "closest among what I am allowed to see".
  // ---------------------------------------------------------------------------
  print('\n--- filtered retrieval ---');
  final recent = await index.query(
    'what changed in the language?',
    topK: 3,
    filter: MetadataFilter.and([
      const MetadataFilter.notEquals('topic', 'rendering'),
      const MetadataFilter.greaterThan('year', 2022),
    ]),
  );
  for (final hit in recent) {
    print(
      '${hit.score.toStringAsFixed(3)}  ${hit.id}  '
      '(${hit.record.metadata['topic']}, ${hit.record.metadata['year']})',
    );
  }

  // A floor is what lets retrieval answer "nothing here is relevant".
  final nothing = await index.query('recipes for sourdough', minScore: 0.6);
  print('off-topic  : ${nothing.length} match(es) above the score floor');

  // ---------------------------------------------------------------------------
  // 4. Namespaces: one index, many tenants.
  // ---------------------------------------------------------------------------
  print('\n--- namespaces ---');
  final shared = InMemoryVectorStore(dimensions: model.dimensions);
  for (final tenant in <String>['acme', 'globex']) {
    final scoped = EmbeddingIndex(
      model: model,
      store: NamespacedVectorStore(shared, namespace: tenant),
      disposeStore: false,
    );
    await scoped.addText('$tenant runs its billing on Dart.', id: '$tenant-1');
  }

  final acme = EmbeddingIndex(
    model: model,
    store: NamespacedVectorStore(shared, namespace: 'acme'),
    disposeStore: false,
  );
  final leak = await acme.query('billing', topK: 5);
  print('acme sees  : ${leak.map((h) => h.id).join(', ')}');
  print(
    'index holds: ${shared.length} records across '
    '${shared.namespaces.length} namespaces',
  );

  // ---------------------------------------------------------------------------
  // 5. Snapshot the index so the next launch skips embedding entirely.
  // ---------------------------------------------------------------------------
  print('\n--- persistence ---');
  final encoded = jsonEncode(store.snapshot());
  final restored = InMemoryVectorStore.fromJson(jsonDecode(encoded) as JsonMap);
  print('snapshot   : ${encoded.length} bytes, ${restored.length} records');

  final reopened = EmbeddingIndex(model: model, store: restored);
  final afterRestart = await reopened.query('pattern matching', topK: 1);
  print('after load : ${afterRestart.single.id}');

  // ---------------------------------------------------------------------------
  // 6. Observability: what was asked, and what came back.
  // ---------------------------------------------------------------------------
  print('\n--- observability ---');
  final bus = BroadcastEventBus();
  final observed = EmbeddingIndex(
    model: model,
    store: ObservableVectorStore(
      InMemoryVectorStore(dimensions: model.dimensions),
    ),
  );
  final context = AgenticContext.root(events: bus);

  await observed.addText(
    'Impeller compiles shaders ahead of time.',
    id: 'impeller',
    context: context,
  );
  await observed.query('impeller compiles shaders', context: context);

  for (final event in bus.replayBuffer.whereType<VectorEvent>()) {
    print(event);
  }

  await bus.dispose();
  await index.dispose();
  await shared.dispose();
}

/// An embedding model that runs on the device with nothing to download.
///
/// Words are hashed into a fixed number of buckets and the resulting vector is
/// normalised, so cosine similarity measures shared vocabulary. It has no idea
/// that "draw" and "render" are related — that is what a trained model buys —
/// but it is deterministic, instant, free, and enough to demonstrate the port.
final class HashingEmbeddingModel implements EmbeddingModel {
  HashingEmbeddingModel({this.dimensions = 128})
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
      // FNV-1a over the word, kept inside 32 bits so the result is identical on
      // native and on the web.
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
