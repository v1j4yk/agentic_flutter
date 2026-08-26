/// Text in, text out — an embedding model bound to a vector store.
///
/// # Why this pairing deserves a class
///
/// A store holds vectors and a model makes them, and every application that
/// uses both writes the same three pieces of glue: batch the texts to the
/// model's limit, batch the vectors to the store's limit, and remember that a
/// document and a query are embedded in *different modes* on models that have
/// them. Getting the last one wrong costs a measurable amount of retrieval
/// quality and produces no error at all.
///
/// The width check in the constructor is the other reason. An index built with
/// a 1536-dimensional model and queried with a 768-dimensional one fails on
/// the first search — after the ingestion run. Failing at construction turns an
/// hour into a second.
library;

import 'package:agentic_core/agentic_core.dart';
import 'package:agentic_llm/agentic_llm.dart';
import 'package:agentic_vector/src/model/metadata_filter.dart';
import 'package:agentic_vector/src/model/vector_record.dart';
import 'package:agentic_vector/src/store/vector_store.dart';

/// Embeds text and stores it, and answers questions with text.
///
/// ```dart
/// final index = EmbeddingIndex(
///   model: OpenAiCompatibleEmbeddingModel.openAi(apiKey: key),
///   store: InMemoryVectorStore(dimensions: 1536),
/// );
///
/// await index.addTexts(
///   ['Dart 3 added pattern matching.', 'Flutter renders with Impeller.'],
///   metadatas: [{'topic': 'dart'}, {'topic': 'flutter'}],
/// );
///
/// final hits = await index.query('What matches patterns?', topK: 1);
/// ```
final class EmbeddingIndex implements Disposable {
  /// Binds [model] to [store].
  ///
  /// Throws a [ConfigurationException] when their widths disagree — the
  /// mismatch that otherwise surfaces after ingestion rather than before it.
  EmbeddingIndex({
    required this.model,
    required this.store,
    this.namespace,
    this.disposeStore = true,
    this.disposeModel = false,
  }) {
    if (model.dimensions != store.info.dimensions) {
      throw ConfigurationException(
        'The model `${model.info.qualifiedId}` produces '
        '${model.dimensions}-dimensional vectors but the '
        '`${store.info.name}` index expects ${store.info.dimensions}. One of '
        'them has to change, and re-creating the index is usually the answer.',
        setting: 'dimensions',
      );
    }
  }

  /// The model that turns text into vectors.
  final EmbeddingModel model;

  /// The store the vectors live in.
  final VectorStore store;

  /// Partition every operation uses, unless overridden per call.
  final String? namespace;

  /// Whether [dispose] closes [store].
  final bool disposeStore;

  /// Whether [dispose] closes [model].
  ///
  /// Off by default: a model is usually shared with the rest of the
  /// application, and closing its HTTP client from here would break callers
  /// that never asked this index to own it.
  final bool disposeModel;

  /// Embeds [texts] and writes them.
  ///
  /// [ids] makes ingestion idempotent — pass stable identifiers such as
  /// `guide.md#3` and re-running replaces rather than duplicates. Without them
  /// each call inserts new records.
  ///
  /// [metadatas], when given, must be the same length as [texts]; the pairing
  /// is positional because that is how a chunker produces them.
  ///
  /// Returns the records written.
  Future<List<VectorRecord>> addTexts(
    List<String> texts, {
    List<String>? ids,
    List<JsonMap>? metadatas,
    bool storeText = true,
    String? namespace,
    AgenticContext? context,
  }) async {
    if (texts.isEmpty) return const <VectorRecord>[];
    _checkLengths(texts.length, ids?.length, metadatas?.length);

    final records = <VectorRecord>[];
    final batchSize = model.maxBatchSize;
    for (var start = 0; start < texts.length; start += batchSize) {
      context?.throwIfCancelled();
      final end = start + batchSize < texts.length
          ? start + batchSize
          : texts.length;
      final batch = texts.sublist(start, end);
      final vectors = await model.embed(
        batch,
        purpose: EmbeddingPurpose.document,
        context: context,
      );
      if (vectors.length != batch.length) {
        throw ProviderException(
          'The embedding model returned ${vectors.length} vectors for '
          '${batch.length} inputs, so they cannot be paired up.',
          provider: model.info.provider,
        );
      }
      for (var i = 0; i < batch.length; i++) {
        final index = start + i;
        records.add(
          VectorRecord(
            id: ids?[index] ?? (context?.ids ?? Ulid()).prefixed('vec'),
            vector: vectors[i].values,
            metadata: metadatas?[index] ?? const <String, Object?>{},
            text: storeText ? batch[i] : null,
          ),
        );
      }
    }

    await store.upsertAll(
      records,
      namespace: namespace ?? this.namespace,
      context: context,
    );
    return List<VectorRecord>.unmodifiable(records);
  }

  /// Embeds one [text] and writes it, returning the record.
  Future<VectorRecord> addText(
    String text, {
    String? id,
    JsonMap metadata = const <String, Object?>{},
    bool storeText = true,
    String? namespace,
    AgenticContext? context,
  }) async {
    final written = await addTexts(
      <String>[text],
      ids: id == null ? null : <String>[id],
      metadatas: <JsonMap>[metadata],
      storeText: storeText,
      namespace: namespace,
      context: context,
    );
    return written.single;
  }

  /// Embeds [text] as a question and returns the nearest records.
  ///
  /// Uses [EmbeddingPurpose.query], which is what makes asymmetric models —
  /// the ones with separate document and query encoders — retrieve well.
  Future<List<VectorMatch>> query(
    String text, {
    int topK = 8,
    MetadataFilter? filter,
    double minScore = 0,
    bool includeVectors = false,
    String? namespace,
    AgenticContext? context,
  }) async {
    final embedded = await model.embedQuery(text, context: context);
    return store.search(
      VectorQuery.fromEmbedding(
        embedded,
        topK: topK,
        filter: filter,
        minScore: minScore,
        includeVectors: includeVectors,
      ),
      namespace: namespace ?? this.namespace,
      context: context,
    );
  }

  /// Removes records by identifier.
  Future<int> delete(Iterable<String> ids, {String? namespace}) =>
      store.delete(ids, namespace: namespace ?? this.namespace);

  /// Removes every record matching [filter].
  Future<int> deleteWhere(MetadataFilter filter, {String? namespace}) =>
      store.deleteWhere(filter, namespace: namespace ?? this.namespace);

  /// How many records are indexed.
  Future<int> count({String? namespace, MetadataFilter? filter}) =>
      store.count(namespace: namespace ?? this.namespace, filter: filter);

  @override
  Future<void> dispose() async {
    if (disposeStore) await store.dispose();
    if (disposeModel) await model.dispose();
  }

  void _checkLengths(int texts, int? ids, int? metadatas) {
    final violations = <String>[
      if (ids != null && ids != texts) 'ids: $ids, expected $texts',
      if (metadatas != null && metadatas != texts)
        'metadatas: $metadatas, expected $texts',
    ];
    if (violations.isEmpty) return;
    throw ValidationException(
      'Identifiers and metadata are paired with texts by position, so the '
      'lists must be the same length.',
      violations: violations,
    );
  }

  @override
  String toString() =>
      'EmbeddingIndex(${model.info.qualifiedId} -> ${store.info.name})';
}
