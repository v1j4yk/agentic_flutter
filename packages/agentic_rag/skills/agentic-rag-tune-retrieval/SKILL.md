---
name: agentic-rag-tune-retrieval
description: >-
  Use when the right passage is not coming back in agentic_rag: choosing
  between dense, keyword and hybrid retrieval, reciprocal rank fusion, the
  rerankers (LlmReranker, MmrReranker, ScoreFloorReranker, ChainedReranker),
  NeighbourExpandingRetriever, and how to diagnose retrieval separately from
  generation. Read this for "it cannot find the error code", "results are all
  the same paragraph", or "top-k is full of near-misses".
license: MIT
metadata:
  package: agentic_rag
  min-version: 0.2.0
---

# Tuning retrieval

## Diagnose retrieval before touching the prompt

```dart
final results = await retriever.retrieve(RetrievalRequest(query: question, topK: 10));
for (final result in results) {
  print('${result.score.toStringAsFixed(3)}  ${result.chunk.metadata[kHeadingKey]}');
}
```

If the right chunk is not in that list, no prompt change will fix the answer.
Fix retrieval first. Only when the chunk is present and the answer is still
wrong is it a generation problem.

## Dense, keyword, or both

| Retriever | Finds | Blind to |
|---|---|---|
| `VectorRetriever` | text that *means* the same thing | rare exact tokens: error codes, part numbers, names, versions |
| `KeywordRetriever` (BM25) | exact and rare terms, scored highly *because* they are rare | paraphrase, synonyms, "how do I…" phrasing |
| `HybridRetriever` | both | — |

Their blind spots are opposites, which is why hybrid is usually right for real
corpora:

```dart
final retriever = HybridRetriever(
  retrievers: [
    VectorRetriever(index: embeddingIndex),
    KeywordRetriever(index: keywordIndex),
  ],
  k: 60,                                       // RRF rank constant
  weights: {'keyword': 1.2, 'vector': 1.0},    // by retriever name
  candidateMultiplier: 3,                      // fetch more from each, then fuse
);
```

Fusion is by **rank**, not score: a cosine similarity and a BM25 score share no
scale, so averaging them is meaningless. A lower `k` sharpens the top of each
list; a higher one blends more evenly.

## Rerankers

Retrieval is cheap and approximate; reranking is expensive and precise. Retrieve
widely, then rerank down:

```dart
RagPipeline(
  retriever: retriever,
  topK: 20,        // retrieve widely
  finalK: 4,       // keep few
  reranker: ChainedReranker([
    ScoreFloorReranker(minScore: 0.15),                    // drop the obvious noise first
    MmrReranker(vectorOf: (r) => r.chunk.embedding, lambda: 0.7),  // then diversify
    LlmReranker(model: cheapModel),                        // then judge what is left
  ]),
);
```

- `ScoreFloorReranker` — cheapest, first: nothing else should pay to look at
  noise.
- `MmrReranker` — the fix for "all four results are the same paragraph". Lower
  `lambda` means more diversity, less pure relevance.
- `LlmReranker` — most accurate, slowest, and it costs money per query. Use a
  cheap model, cap `maxCandidateChars`, and check `lastFailure` — it degrades to
  the input order rather than failing the query.

## Neighbours: when the answer straddles a boundary

```dart
NeighbourExpandingRetriever(inner: retriever, before: 1, after: 1);
```

Chunk 7 matches, but the sentence completing the thought is in chunk 8. This
pulls adjacent chunks in by `chunkIndex`, which is what makes narrow chunks safe
to use.

## The usual causes, in order

1. **Chunks with no heading.** `MarkdownChunker(prependHeading: true)` fixes
   more retrieval problems than any reranker.
2. **Keyword half missing.** Any corpus with identifiers needs one.
3. **`topK` too small.** Retrieve 20 and rerank to 4, rather than retrieving 4
   and hoping.
4. **Query and documents phrased differently.** Users ask "can I expense a
   taxi"; the document says "ground transportation reimbursement". Hybrid helps;
   indexing a question-shaped summary alongside each chunk helps more.
5. **`minScore` set too high**, quietly filtering the answer out. Check by
   setting it to zero.
6. **One embedding model at index time, another at query time.** Vectors from
   different models are not comparable — this produces confident nonsense, not
   an error.

## Measuring instead of guessing

Keep twenty real questions with the document that should answer each one, and
assert that it is retrieved:

```dart
test('retrieves the holiday policy', () async {
  final results = await retriever.retrieve(
    const RetrievalRequest(query: 'how much holiday do I get', topK: 5),
  );
  expect(results.map((r) => r.chunk.metadata[kDocumentIdKey]), contains('policy-2026'));
});
```

Recall@5 on those twenty questions turns "it feels worse" into a number, which
is the only way to tell whether a chunk-size change helped.

## Common mistakes

- Reranking with an expensive model on every keystroke of a search box.
- `MmrReranker` with no `vectorOf` source, so it cannot diversify.
- Tuning the system prompt when the chunk was never retrieved.
- Raising `finalK` to compensate for poor ranking, which fills the context with
  near-misses and makes answers worse.

## See also

- `agentic-rag-index-documents` — chunking, which decides what can be retrieved
- `agentic-rag-answer-with-citations` — what happens after retrieval
- `agentic-vector-embedding-index` — the dense half
