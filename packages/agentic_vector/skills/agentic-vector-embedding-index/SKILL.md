---
name: agentic-vector-embedding-index
description: >-
  Use when turning text into searchable vectors with agentic_vector:
  EmbeddingIndex over a model and a store, addText and addTexts, querying,
  namespaces, document versus query embeddings, batching, and what happens
  when you change embedding model. Read this for "embed and search my text",
  "dimension mismatch", or "search returns nothing sensible".
license: MIT
metadata:
  package: agentic_vector
  min-version: 0.2.0
---

# The embedding index

## Model plus store, as one thing

```dart
final index = EmbeddingIndex(
  model: embeddingModel,
  store: InMemoryVectorStore(dimensions: 768, name: 'notes'),
  namespace: 'user-42',      // optional default for every call
);

await index.addTexts(
  [note.body, other.body],
  ids: [note.id, other.id],               // stable ids: re-adding replaces
  metadatas: [{'tag': 'work'}, {'tag': 'home'}],
  storeText: true,                        // keep the text, so results can show it
);

final matches = await index.query('what did I decide about the migration?', topK: 5);
for (final match in matches) {
  print('${match.score}  ${match.record.metadata['text']}');
}
```

It exists so that "find text that means this" is one call: it embeds, batches to
each side's limits, uses the right encoder for documents versus queries, and
refuses a width mismatch at construction rather than after an ingestion run.

## Document and query embeddings are not the same

Several providers embed a passage and a question differently, and using the
wrong one quietly degrades every result. `EmbeddingIndex` passes
`EmbeddingPurpose.document` when adding and `EmbeddingPurpose.query` when
querying, which is most of the reason to use it rather than calling the model
yourself.

Direct use, when you need it:

```dart
await model.embedDocument(text);
await model.embedQuery(question);
await model.embedAll(texts, purpose: EmbeddingPurpose.document,
    onProgress: (done, total) => report(done / total));
```

## Ids, namespaces and deletion

```dart
await index.delete([noteId]);
await index.deleteWhere(EqualsFilter('tag', 'work'));
await index.count(filter: ExistsFilter('tag'));
```

Use **stable ids** — the note's id, `<documentId>#<chunkIndex>` — so re-adding
replaces rather than duplicating. Duplicates are not merely wasteful: several
near-identical chunks crowd out everything else in `topK`.

Namespaces partition one store: one per user, per corpus or per tenant. A query
without a namespace does not search across them, so pick the level early —
moving later means re-writing every record.

## Cost and batching

Embedding is priced per token and adding a thousand documents is a thousand
documents' worth of tokens. `addTexts` batches to `model.maxBatchSize`, so
prefer it over a loop of `addText`. Cache aggressively: identical text embedded
twice costs twice.

On a phone, each embedding call is also a network round trip. For an app that
searches its own bundled content, embed at build time and ship the snapshot.

## Changing embedding model

This is the operation that breaks indexes, so treat it as a migration:

1. Embedding spaces are **not comparable**. Queries from the new model against
   vectors from the old return plausible nonsense, not an error.
2. Dimensions usually differ too, which at least fails loudly.
3. So: build a second index, re-embed everything, compare a handful of known
   queries, then cut over and delete the old one.

Record which model and dimensions an index was built with — in store metadata,
or next to the snapshot — because in six months nothing else will tell you.

## Common mistakes

- Calling `model.embed` directly and losing the document/query distinction.
- Random ids per run, so a re-index duplicates every record.
- `dimensions` guessed rather than taken from the model. Truncating dimensions
  is fine *if* the model supports it (`gemini-embedding-2` does, at 768, 1536 or
  3072) and the store is created at the same width.
- Embedding whole documents instead of chunks: one vector for 40 pages matches
  everything weakly and nothing precisely.
- Forgetting `storeText: false` on a large corpus you already have text for,
  and doubling the index size.

## See also

- `agentic-vector-choose-store` — where the vectors are kept
- `agentic-rag-index-documents` — chunking before embedding
- `agentic-llm-local-models` — embedding without a network
