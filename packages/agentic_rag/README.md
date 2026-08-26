# agentic_rag

Retrieval-augmented generation for the agentic framework: document ingestion,
chunking, indexing, dense and lexical retrieval, re-ranking, and answers that
carry citations back to the passages they came from.

```dart
import 'package:agentic_rag/agentic_rag.dart';

final indexer = RagIndexer(
  index: EmbeddingIndex(model: embeddings, store: store),
  chunker: const MarkdownChunker(),
);
await indexer.indexAll(documents);

final pipeline = RagPipeline(
  retriever: VectorRetriever(index: indexer.index),
  model: chatModel,
  reranker: const ScoreFloorReranker(minScore: 0.25),
);

final answer = await pipeline.answer('How do refunds work?');
print(answer.text);                  // "Refunds take thirty days [1]."
print(answer.citations.first.label); // "[1] Handbook › Refunds (handbook.md)"
print(answer.isGrounded);            // true
```

## The pipeline

```
question ──► retrieve ──► re-rank ──► fit to budget ──► prompt ──► answer
               (recall)   (precision)    (honesty)
```

| Stage | Ports | Shipped |
|---|---|---|
| Load | `DocumentLoader` | `TextDocumentLoader`, `MarkdownDocumentLoader`, `HtmlDocumentLoader`, `CompositeDocumentLoader` |
| Chunk | `Chunker` | `RecursiveChunker`, `MarkdownChunker`, `FixedSizeChunker` |
| Index | — | `RagIndexer` |
| Retrieve | `Retriever` | `VectorRetriever`, `KeywordRetriever` (BM25), `HybridRetriever`, `NeighbourExpandingRetriever` |
| Re-rank | `Reranker` | `ScoreFloorReranker`, `MmrReranker`, `LlmReranker`, `ChainedReranker` |
| Answer | — | `RagPipeline` |
| Expose | — | `searchTool`, `answeringTool` |

Every stage is replaceable: implement the port in your own package and nothing
here changes.

## Six decisions worth knowing about

**Citations are the product.** A retrieval system that cannot say where an
answer came from is a text generator with extra steps. Passages are numbered in
the prompt, the model is told to mark each claim, and `RagAnswer.citations`
resolves the markers it used back to documents. Markers are numbers because
that is what models reproduce reliably — asked to write `[guide.md#7]` they
mangle it, asked to write `[3]` they do not.

**Re-ingestion is safe by construction.** Chunk identifiers are
`<documentId>#<index>`, so re-indexing replaces rather than duplicates. A
content fingerprint skips documents that have not changed. And after writing,
the indexer deletes chunks at or beyond the new count — the stale tail a
shortened document otherwise leaves behind, still matching queries and still
being cited, quoting text that no longer exists.

**Headings go into the chunk text, not just its metadata.** Splitting at a
heading removes it from the text below, so a section titled `ERR_4418` whose
body never repeats the code becomes unretrievable *by that code*. The words an
author puts in a heading are usually the words a reader searches for.
`MarkdownChunker(prependHeading: false)` opts out.

**Hybrid retrieval fuses ranks, not scores.** Cosine similarity of 0.71 and a
BM25 score of 8.4 are not comparable, and normalising them into a shared range
means deciding what "good" means for each — which changes with the corpus.
Reciprocal rank fusion keeps only the ordering, needs no tuning, and reliably
beats either input.

**Both halves of a hybrid earn their place.** Dense retrieval finds text that
*means* the same thing; it is unreliable on rare tokens — order numbers, error
codes, surnames — because `ERR_4417` and `ERR_4418` are nearly identical in
vector space. BM25 has the opposite bias and scores a rare term highly *because*
it is rare.

**Re-ranking may fail; the answer must not.** `LlmReranker` falls back to the
retriever's own ordering when the model errors or answers unreadably, logging it
and recording `lastFailure`. Turning a good answer into an error because the
optional refinement step failed is the wrong trade.

## Chunking is where retrieval quality is decided

Chunks that are too large dilute the embedding — a page about six subjects is
close to nothing in particular — and spend prompt budget on text the question
did not ask about. Chunks that are too small win the similarity contest and then
answer nothing, because the sentence that matched has lost the paragraph that
explained it.

The defaults (≈1,000 characters, 150 of overlap, split at natural boundaries)
are a reasonable middle for prose. They are defaults, not physics: measure on
your own corpus. `FixedSizeChunker` is the honest baseline to measure against.

Overlap is not waste. The sentence that answers a question frequently sits
across a boundary; without overlap it belongs wholly to neither neighbour and is
retrievable by neither.

Sizes are in **characters, not tokens**. Counting tokens needs the provider's
own tokeniser, which differs per provider and may not exist in Dart — and would
make chunking a network-dependent operation. Roughly four characters per token
is close enough to budget with.

## Loaders take text, not paths

Nothing here touches `dart:io` or the network. Reading a file is one line in
your app — and it is the line that most wants to differ per platform (a path on
desktop, a bundle asset or picker on mobile, a fetch on the web). What is
genuinely shared — extracting a title, parsing front matter, stripping markup —
is what lives here. The package therefore runs everywhere Dart does, web
included.

## Saying "I don't know"

The single most valuable thing a RAG pipeline can do is decline. Three settings
make that possible:

* `RagPipeline.minScore` — a relevance floor. Without one, retrieval always
  returns its `topK` nearest passages, however irrelevant, and the model
  dutifully writes an answer from them.
* the default system prompt — which tells the model to say plainly that the
  documents do not cover the question, and to cite nothing when they do not.
* `RagAnswer.isGrounded` — false when the answer cited nothing, which is your
  signal to render it differently, or not at all.

## Retrieval as a tool

`searchTool` gives the corpus to an agent, which then decides when and how often
to search. A pipeline retrieves once, before the model has seen the question —
right for a search box, wrong for an agent that needs to search twice after
learning it asked the wrong thing, or not at all because it already knows.

`answeringTool` is the other shape: the agent asks a question and gets a
written, cited answer, at the cost of a nested model call.

## Cost and performance notes

* **Content hashing is the biggest saving available.** Re-embedding an unchanged
  corpus is the largest avoidable cost in a RAG system; `skipUnchanged` removes
  it, with the fingerprint living in the index rather than a second table.
* **Order a re-ranker chain cheap-first.** `ChainedReranker([ScoreFloorReranker(),
  LlmReranker(...)])` lets the model read four candidates instead of forty.
* **`finalK` smaller than `topK`.** Retrieval optimises for recall; the prompt
  needs precision, and models measurably lose track of the middle of a long
  context.
* **Watch `citationsOffered` against `citationsUsed`.** A large gap means
  over-fetching: every uncited passage was budget spent on nothing.
* **A keyword index is nearly free.** No model, no network, no embedding cost.
  Measured over five thousand chunks: **3.3 ms per query**, rising to 4.9 ms
  when every query term is common enough to appear in most chunks. Next to an
  embedding call — tens to hundreds of milliseconds of network — that is noise,
  which is the claim that matters. Building the index costs ~150 ms for five
  thousand chunks, once, at start-up.

## Common mistakes

| Mistake | What happens |
|---|---|
| No `minScore` | Irrelevant passages are handed to the model, which answers confidently from them |
| Random chunk identifiers | The index doubles on every re-run and retrieval returns duplicates |
| Re-indexing a shortened document without tail deletion | Stale chunks stay retrievable and get cited, quoting text that no longer exists |
| Summing dense and lexical scores | The larger scale decides every result; fuse ranks instead |
| `MmrReranker` without `includeVectors: true` | A `ConfigurationException` naming the setting — by design, rather than degrading silently |
| Chunks nearly as large as `maxContextChars` | One passage fills the whole context; the budget can overshoot by at most one passage |
| Treating an ungrounded answer as an answer | Check `RagAnswer.isGrounded` |

## Documentation

* [Examples](example/) — `dart run example/agentic_rag_example.dart`
* [`agentic_vector`](../agentic_vector/) — the store and embedding layer beneath
* [Architecture](../../doc/architecture.md)
