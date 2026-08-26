# agentic_vector

Vector storage and similarity search for the agentic framework: one `VectorStore`
port, an exact in-process implementation, a Qdrant adapter, and the glue that
turns an embedding model plus a store into something you hand text to.

```dart
import 'package:agentic_vector/agentic_vector.dart';

final index = EmbeddingIndex(
  model: OpenAiCompatibleEmbeddingModel.openAi(apiKey: key),
  store: InMemoryVectorStore(dimensions: 1536),
);

await index.addText(
  'Dart 3 added exhaustive pattern matching.',
  id: 'dart-3-patterns',
  metadata: {'topic': 'language', 'year': 2023},
);

final hits = await index.query(
  'How do I match on a sealed type?',
  topK: 3,
  filter: MetadataFilter.equals('topic', 'language'),
  minScore: 0.2,
);
```

## What is here

| Piece | What it is for |
|---|---|
| `VectorStore` | The port. Upsert, search, get, delete, count, clear. |
| `VectorRecord` / `VectorQuery` / `VectorMatch` | What is stored, what is asked, what comes back. |
| `MetadataFilter` | A sealed predicate over metadata, translated by each adapter. |
| `SimilarityMetric` | Cosine, dot product, Euclidean — all scored higher-is-better. |
| `InMemoryVectorStore` | Exact brute-force search, with snapshots for offline-first apps. |
| `QdrantVectorStore` | A REST adapter, including the identifier and score-direction work. |
| `EmbeddingIndex` | An embedding model bound to a store: text in, text out. |
| `ObservableVectorStore` | Traces, logs and events around every operation. |
| `NamespacedVectorStore` | A handle that cannot reach another tenant's partition. |

## Five decisions worth knowing about

**Filtering happens before ranking.** The port requires it, and the in-process
store and the Qdrant adapter both do it. The alternative — fetch `topK` by
similarity, then discard what does not match — is easy and wrong: it returns
fewer results than asked for, and none at all when the nearest records happen to
belong to somebody else.

**Scores always mean higher-is-better.** Euclidean distance is mapped to
`1 / (1 + d)`. Without that, `topK` would sort one way for two metrics and the
other way for the third, and `minScore` would silently invert when the metric
changed.

**`minScore` defaults to 0, and that is a trap worth knowing.** Similarity search
returns the nearest neighbours *however far away they are*, so a query with no
floor always returns `topK` results — including for a question the index has
nothing to say about. Set one.

**Identifiers belong to the caller.** `VectorRecord.id` is yours, which is what
makes ingestion idempotent: re-indexing a changed document replaces its chunks
instead of duplicating them. The Qdrant adapter derives a deterministic UUID
where Qdrant will not accept a string, and keeps your identifier in the payload.

**`MetadataFilter` is sealed.** Every adapter translates every filter kind into
its backend's language. Sealing means adding a kind is a compile error in each
adapter that has not handled it, rather than a filter silently ignored and a
query silently returning the wrong rows.

## Vectors are omitted from results by default

A search returns records whose `vector` is empty unless the query sets
`includeVectors: true`; check `VectorRecord.hasVector`. Transferring a
1536-component vector per match is pure cost for a caller that only wants the
text. Re-ranking that needs the numbers — maximal marginal relevance, for
instance — should ask for them.

## Writing another backend

Implement `VectorStore`. Nothing in this package needs to change, and the
conveniences in `VectorStoreOperations` — `upsertAll`, `searchVector`,
`exists`, `checkDimensions`, `checkNamespace` — come for free.

The contract implementations must keep:

* `upsert` is insert-or-replace on `VectorRecord.id`;
* reject records whose width differs from `VectorStoreInfo.dimensions`;
* apply `VectorQuery.filter` **before** ranking;
* order matches by descending score, at most `topK`, none below `minScore`;
* throw `CapabilityNotSupportedException` for a namespace you cannot honour —
  never ignore one, because silently merging two tenants' data is the worst
  failure this port has.

`InMemoryVectorStore` is exact by construction, so it doubles as the reference a
new adapter's ranking can be compared against.

## Offline-first

`InMemoryVectorStore.snapshot()` and `InMemoryVectorStore.fromJson` round-trip a
whole index, vectors included. Embed once, write the result to a file, and start
from it on every later launch instead of re-embedding. `maxRecords` bounds how
much a device holds, evicting oldest-first.

The example ships a working `HashingEmbeddingModel` — hashed bag of words, no
download, no key — so the whole pipeline runs with nothing installed.

## Cost and performance notes

* **Brute force is fine up to a few thousand vectors.** Measured on a desktop
  at 768 dimensions: **1.9 ms for a thousand records, 24 ms for ten thousand**
  (`dart run agentic_benchmark vector`). A phone is slower still. So a few
  thousand records is comfortably interactive, ten thousand is a visible pause,
  and past that you want either a metadata filter that cuts the candidate set —
  which roughly halves the time here — or a real index on a server.
  <br>An earlier version of this note claimed "a few milliseconds" for ten
  thousand. It was wrong by an order of magnitude, and the benchmark suite is
  why that is now a measurement instead of a belief.
* **Normalise once, at ingestion.** `normalise()` plus
  `SimilarityMetric.dotProduct` is exact cosine without the per-query square
  roots.
* **Batch ingestion with `upsertAll`.** It chunks to
  `VectorStoreInfo.maxUpsertBatch` and runs the batches sequentially, which is
  what keeps a remote store from rate-limiting an import.
* **Keep metadata small.** Every remote store transfers it on every match, so a
  payload holding a whole document costs bandwidth per query rather than once at
  ingestion.

## Common mistakes

| Mistake | What happens |
|---|---|
| Querying with a different model than you indexed with | A `ValidationException` naming the width mismatch — `EmbeddingIndex` catches it at construction |
| Leaving `minScore` at 0 | Irrelevant passages are handed to the model with full confidence |
| Filtering the results of a search | Fewer results than `topK`, sometimes none |
| Random identifiers on re-index | The index doubles in size and retrieval returns duplicates |
| Passing a namespace to a store that does not support them | `CapabilityNotSupportedException`, by design |
| Using `VectorMatch.record.vector` without `includeVectors` | An empty list; check `hasVector` |

## Documentation

* [Examples](example/) — `dart run example/agentic_vector_example.dart`
* [Architecture](../../doc/architecture.md)
