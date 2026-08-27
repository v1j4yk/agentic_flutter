# Changelog

## 0.1.1

- Shortened the package description to the 60-180 character window pana
  scores against. Search engines truncate anything longer, so the ten points
  it withheld were pointing at a real defect: the useful half of the sentence
  was never being shown.

## 0.1.0

Initial release of the vector layer.

### Added

- **Values** — `VectorRecord`, `VectorQuery` and `VectorMatch`. Identifiers are
  caller-supplied, which is what makes re-indexing a changed document replace
  its chunks instead of duplicating them. Search results omit vectors unless
  asked for; `VectorRecord.hasVector` says which you have.
- **Filtering** — a sealed `MetadataFilter` hierarchy (`equals`, `notEquals`,
  `inValues`, `greaterThan`, `lessThan`, `exists`, `and`, `or`, `not`) that
  every adapter must translate in full, so a new filter kind is a compile error
  rather than a silently ignored predicate.
- **Similarity** — `SimilarityMetric` covering cosine, dot product and
  Euclidean, all scored higher-is-better so that `topK` ordering and `minScore`
  never invert when the metric changes; plus `cosineSimilarity`, `dotProduct`,
  `euclideanDistance` and `normalise` over raw lists.
- **Port** — `VectorStore` with `upsert`, `search`, `get`, `delete`,
  `deleteWhere`, `count` and `clear`, and `VectorStoreOperations` supplying
  `upsertAll` (batched and cancellable), `searchVector`, `exists`, `deleteOne`
  and the `checkDimensions` / `checkNamespace` guards adapters call.
- **In-process store** — `InMemoryVectorStore`, exact by construction, with
  namespaces, oldest-first eviction under `maxRecords`, and `snapshot` /
  `fromJson` so an offline-first app embeds once and restores thereafter.
- **Qdrant adapter** — `QdrantVectorStore`, including deterministic UUID
  derivation for identifiers Qdrant will not accept, score-direction conversion
  for Euclidean collections in both directions, full filter translation, and
  `ensureCollection` / `dropCollection`.
- **Composition** — `EmbeddingIndex` binds an embedding model to a store,
  batching to each side's limit, using the document and query encoders
  correctly, and refusing a width mismatch at construction rather than after
  ingestion.
- **Decorators** — `DelegatingVectorStore`, `ObservableVectorStore` (traces,
  logs and events) and `NamespacedVectorStore` (a handle that cannot reach
  another tenant's partition).
- **Events** — `VectorUpsertCompleted`, `VectorSearchCompleted` (carrying
  requested against returned, the number worth alerting on),
  `VectorDeleteCompleted` and `VectorOperationFailed`.
