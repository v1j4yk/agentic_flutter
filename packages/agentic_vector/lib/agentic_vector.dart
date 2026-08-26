/// Vector storage and similarity search for the agentic framework.
///
/// One `VectorStore` port, an exact in-process implementation, a Qdrant
/// adapter, and the glue that turns an embedding model plus a store into
/// something you hand text to.
///
/// ```dart
/// import 'package:agentic_vector/agentic_vector.dart';
///
/// final index = EmbeddingIndex(
///   model: OpenAiCompatibleEmbeddingModel.openAi(apiKey: key),
///   store: InMemoryVectorStore(dimensions: 1536),
/// );
///
/// await index.addText(
///   'Dart 3 added exhaustive pattern matching.',
///   id: 'dart-3-patterns',
///   metadata: {'topic': 'language'},
/// );
///
/// final hits = await index.query(
///   'How do I match on a sealed type?',
///   filter: MetadataFilter.equals('topic', 'language'),
///   topK: 3,
/// );
/// ```
///
/// Writing another backend is a class implementing `VectorStore` in your own
/// package; nothing here needs to change. The `MetadataFilter` hierarchy is
/// sealed on purpose, so the compiler tells you what your adapter has not
/// translated yet.
library;

// --- Events ------------------------------------------------------------------
export 'src/events/vector_events.dart'
    show
        VectorDeleteCompleted,
        VectorEvent,
        VectorOperationFailed,
        VectorSearchCompleted,
        VectorUpsertCompleted;
// --- Filtering ---------------------------------------------------------------
export 'src/model/metadata_filter.dart'
    show
        AndFilter,
        EqualsFilter,
        ExistsFilter,
        GreaterThanFilter,
        InFilter,
        LessThanFilter,
        MetadataFilter,
        NotEqualsFilter,
        NotFilter,
        OrFilter;
// --- Similarity --------------------------------------------------------------
export 'src/model/similarity.dart'
    show
        SimilarityMetric,
        cosineSimilarity,
        dotProduct,
        euclideanDistance,
        normalise;
// --- Model -------------------------------------------------------------------
export 'src/model/vector_record.dart'
    show VectorMatch, VectorQuery, VectorRecord;
// --- Composition -------------------------------------------------------------
export 'src/store/embedding_index.dart' show EmbeddingIndex;
// --- Implementations ---------------------------------------------------------
export 'src/store/in_memory_vector_store.dart'
    show InMemoryVectorStore, kDefaultNamespace;
export 'src/store/qdrant_vector_store.dart'
    show QdrantVectorStore, kQdrantIdKey, kQdrantTextKey;
// --- Port --------------------------------------------------------------------
export 'src/store/vector_store.dart'
    show VectorStore, VectorStoreInfo, VectorStoreOperations;
export 'src/store/vector_store_decorators.dart'
    show DelegatingVectorStore, NamespacedVectorStore, ObservableVectorStore;
