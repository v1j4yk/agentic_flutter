---
name: agentic-vector-choose-store
description: >-
  Use when picking or configuring a vector store with agentic_vector:
  InMemoryVectorStore and its JSON snapshots, QdrantVectorStore,
  NamespacedVectorStore, SimilarityMetric, metadata filters, and when an
  in-process store stops being enough. Read this for "where do the embeddings
  go", "search on a phone", or writing a store adapter of your own.
license: MIT
metadata:
  package: agentic_vector
  min-version: 0.2.0
---

# Choosing a vector store

## One port, several backings

```dart
final store = InMemoryVectorStore(
  dimensions: 768,
  metric: SimilarityMetric.cosine,
  name: 'handbook',
  maxRecords: 50000,          // optional ceiling
);

final remote = QdrantVectorStore(
  baseUrl: Uri.parse('http://localhost:6333'),
  collection: 'handbook',
  dimensions: 768,
);

final scoped = NamespacedVectorStore(store, namespace: 'user-42');
```

Everything above takes `VectorStore`, so the choice is one line and the rest of
the app does not change.

## In-process is exact, and that is a feature

`InMemoryVectorStore` does brute-force search: every vector, every query. That
sounds naive and is the right default:

- Exact means **no recall loss** — an approximate index trades accuracy for
  speed, and below roughly a hundred thousand vectors there is no speed to win.
- A few thousand vectors on a phone is milliseconds.
- It is the reference a new adapter's ranking can be compared against.

Snapshot it rather than re-embedding on every launch:

```dart
final json = store.snapshot();                       // JSON-encodable
final restored = InMemoryVectorStore.fromJson(json);
```

An offline-first app embeds its corpus once, ships or caches the snapshot, and
searches with no network at all.

## When to move off it

| Signal | Move to |
|---|---|
| Vectors outgrow memory on a low-end device | `agentic_sqlite` (on-disk, same port) |
| More than ~100 k vectors, or multi-tenant server | Qdrant, or another hosted store |
| The index must be shared between processes or devices | a hosted store |

Memory cost is roughly `records × dimensions × 8 bytes`: 50 k × 768 is about
300 MB, which is far too much for a phone. Cut dimensions before cutting
records — most embedding models are trained to be truncated, and 768 or even
256 usually costs little accuracy.

## Metrics: higher is always better

```dart
SimilarityMetric.cosine;      // the default, and right for most embeddings
SimilarityMetric.dotProduct;  // for normalised vectors, where it equals cosine
SimilarityMetric.euclidean;   // reported as a score, not a distance
```

Every metric reports a score where higher is better — Euclidean included — so
`topK` ordering and `minScore` never invert when the metric changes. Match the
metric to the model: use what the embedding model was trained for, and do not
mix metrics across an index.

## Filters are sealed on purpose

```dart
final results = await store.search(
  VectorQuery(
    vector: queryVector,
    topK: 8,
    minScore: 0.2,
    filter: AndFilter([
      EqualsFilter('team', 'ops'),
      NotFilter(EqualsFilter('archived', true)),
      InFilter('year', [2025, 2026]),
      ExistsFilter('source'),
    ]),
  ),
);
```

`MetadataFilter` is sealed, so adding a filter kind is a compile error in every
adapter that has not translated it — rather than a predicate silently dropped
from a query, which is the failure mode that returns confidently wrong results.

## Writing an adapter

Implement `VectorStore`: `upsert`, `search`, `get`, `delete`, `deleteWhere`,
`count`, `clear`, `info`, `dispose`. Two rules make it trustworthy:

1. **Translate every filter kind**, or throw. Never drop one.
2. **Report the metric honestly** in `VectorStoreInfo`, and return scores where
   higher is better.

Compare its ranking against `InMemoryVectorStore` on the same data — that is
what exact search is for.

`DelegatingVectorStore` wraps a store for cross-cutting behaviour, and
`ObservableVectorStore` already does logging, tracing and events.

## Common mistakes

- `dimensions` that does not match the embedding model. `EmbeddingIndex`
  refuses a mismatch at construction; a raw store will happily store garbage.
- Mixing vectors from two embedding models in one store: the spaces are not
  comparable, and the results are plausible nonsense rather than an error.
- Keeping 100 k vectors in memory on a phone.
- Re-embedding a static corpus on every launch instead of snapshotting.
- Filtering after search instead of passing a `MetadataFilter`, which breaks
  `topK` — the filter removes results the store already counted.

## See also

- `agentic-vector-embedding-index` — binding a model to a store
- `agentic-sqlite-persist-everything` — the on-disk store
- `agentic-rag-index-documents` — what fills the store
