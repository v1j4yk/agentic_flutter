# agentic_memory

Memory for the [agentic](https://github.com/v1j4yk/agentic_flutter) framework.

One store port covers conversation, working, long-term, semantic and shared
memory — because those differ in *scope and retention*, not in mechanics. On top
of it sit the two things that make a store useful: history strategies that
summarise and recall, and tools that let an agent manage its own memory.

## Installation

```yaml
dependencies:
  agentic_memory: ^0.1.0
```

## Why memory is not just a longer transcript

Keeping every message and sending them all fails three ways at once: it exceeds
the context window, it costs money on every turn in proportion to the whole
history, and it *degrades quality* — a model given forty turns of scrollback
attends worse to the one sentence that mattered than a model given three
relevant facts.

So a memory is not a message. It is a distilled, addressable, scored piece of
knowledge that outlives the turn it came from, retrieved when relevant rather
than replayed because it is recent.

## Storing

```dart
final store = InMemoryMemoryStore();

await store.remember(
  'Ada wants answers written in British English.',
  kind: MemoryKind.preference,
  importance: 0.9,
);
```

**Write self-contained statements.** "It uses 3.11" is useless recalled six
conversations later; "The billing service uses Dart 3.11" survives. This is the
single most important thing to get right, and no amount of retrieval quality
compensates for getting it wrong.

The five kinds — `fact`, `preference`, `event`, `summary`, `task`, `observation`
— drive retention and retrieval. A preference should outlive the conversation
that produced it; an observation usually should not. Storing everything as one
undifferentiated blob makes both decisions impossible.

## Retrieval is keyword-first, deliberately

Semantic search is the headline feature of every memory system, and it is
genuinely *worse* than keyword matching at what memory is most often asked for:
recalling a specific name, identifier, version number or piece of jargon.
Embeddings are good at "similar in meaning" and bad at "contains `PROJ-4417`" —
and a user asking about PROJ-4417 wants exactly that row.

```dart
await store.recall('PROJ-4417');
// 0.90  Ticket PROJ-4417 tracks the login regression.
//       matched proj, 4417
```

`InMemoryMemoryStore` ranks by term overlap weighted by term rarity, blended
with importance and recency. It needs no model, no network and no vector index,
runs on a phone, and for a few hundred memories is frequently the better
retriever outright.

**Nothing relevant returns nothing.** A store with no floor always returns its
best guesses, which is how a memory system starts confidently recalling
irrelevancies:

```dart
await store.recall('the airspeed of a swallow');  // []
```

### Adding the semantic half

```dart
final semantic = EmbeddedMemoryStore(
  store,
  embeddings: OpenAiCompatibleEmbeddingModel.openAi(apiKey: key),
  minSimilarity: 0.25,
);
```

`minSimilarity` matters more than it looks: vector search returns the nearest
neighbours *however far away they are*. Without a floor, an unrelated question
still recalls three confident irrelevancies — the characteristic failure of
semantic memory.

### Hybrid, which beats either alone

```dart
final hybrid = HybridMemoryStore(keyword: store, semantic: semantic);
```

Rankings are fused with reciprocal rank fusion, not by averaging scores. A
keyword score and a cosine similarity are not on the same scale and are not even
monotonically related — averaging lets whichever store produces larger numbers
silently become the only retriever. Fusion uses each store's *ordering*, so it
needs no calibration.

Wrap the **same** underlying store in `EmbeddedMemoryStore` rather than keeping
two copies of every entry, and leave `writeToBoth` off.

## Memory-backed conversations

`HistoryStrategy` in `agentic_agents` is the seam. Two implementations here are
why it exists:

```dart
final session = AgentSession(
  strategy: RecallingHistory(
    store: store,
    inner: SummarisingHistory(model: cheapModel, keepRecent: 8),
    minScore: 0.2,
  ),
);
```

**`RecallingHistory`** injects what the store knows that is relevant to the turn
about to be sent — so what gets injected changes with the question rather than
being a fixed preamble. Without it a store is a write-only log.

**`SummarisingHistory`** condenses the older part of a conversation and keeps
recent turns verbatim. It **caches**: the summary is recomputed only when the
boundary between summarised and verbatim actually moves. The naive
implementation summarises on every turn, adding a model call to every message
and often costing more than the tokens it saves.

Both compose, and both repair dangling tool results — trimming can slice between
an assistant turn and the tool results answering it, which providers reject.

## Tools an agent uses on itself

```dart
final agent = ToolCallingAgent(
  info: info,
  model: model,
  tools: (ToolRegistry()..registerAll(memoryTools(store))).all,
  instructions:
      'When the user tells you something durable about themselves or their '
      'work, call `remember`. Call `recall` before answering questions about '
      'their preferences or past decisions.',
);
```

The instructions matter as much as the tools: a model given `remember` without
being told when to use it will use it almost never.

`recall` reports an absence as knowledge, not as a failure — "Nothing relevant
is remembered about that" — so the model treats it as something it was never
told rather than a tool to retry.

`forget` is **excluded by default** and requires approval. Deletion is
irreversible, and a model that misreads a correction as a retraction can quietly
erase a user's profile.

## Automatic extraction

```dart
final agent = RememberingAgent(
  ToolCallingAgent(info: info, model: model, tools: tools),
  store: store,
  extractionModel: cheapModel,
  minimumImportance: 0.3,
);
```

After each successful run, a separate pass asks what from the exchange is worth
keeping and writes it. The wrapped agent knows nothing about memory.

**Why a separate call:** asking the agent to remember inline mixes two jobs in
one prompt — answering the user and curating a knowledge base — and models do
the second badly when it competes with the first.

**The cost, plainly:** one extra model call per run. On a chatty assistant that
is a real fraction of the bill. Use a cheap extraction model, raise
`minimumImportance` so trivia is discarded, and consider the explicit
`remember` tool instead when the assistant should acknowledge remembering
anyway.

**A failed extraction never breaks a good answer.** Memory is an enhancement; an
extraction call that times out is logged and published as
`MemoryExtractionFailed`, and the user still gets their answer.

A model that over-extracts loses the *excess*, not everything: the schema allows
headroom and the surplus is dropped by importance.

## Explicit or automatic?

|  | Explicit tools | `RememberingAgent` |
|---|---|---|
| Fires | When the model thinks to | Every run |
| Cost | A tool call | An extra model call |
| Stores | What the model judged important | Sometimes things nobody asked for |
| Suits | An assistant that acknowledges remembering | One that quietly builds a profile |

They are complementary, not alternatives. Using both is reasonable — the store
deduplicates.

## Forgetting is a feature

```dart
await store.remember('...', ttl: Duration(days: 30));
await store.prune();                 // drop expired
await store.forgetSession('s1');     // end a conversation's working memory
```

A store that only accumulates gets slower, more expensive and **less accurate**
over time, as stale facts compete with current ones for the model's attention.
`InMemoryMemoryStore` is bounded and evicts the least valuable entry — least
important and least recent — rather than the oldest regardless of value.

Re-remembering the same fact **merges** rather than duplicating: agents
re-remember constantly, and near-duplicates crowd out everything else from the
few slots recall is allowed.

## Observability

```dart
bus.on<MemoriesRecalled>().listen((e) => debug.log(e.query, e.contents));
bus.on<MemoriesExtracted>().listen((e) => metrics.count(e.count));
```

"How did it know that?" is the most common question a memory system raises.
`MemoriesRecalled` records the statements themselves, not merely a count, which
is what makes a surprising answer traceable to the memory that caused it.

Every hit also carries an `explanation` — `matched proj, 4417`,
`fused from keyword + semantic`. Retrieval that cannot be explained cannot be
debugged.

## Best practices

- **Write self-contained statements.** The one that matters most.
- **Set importance deliberately.** Marking everything 1.0 is the same as having
  no importance at all.
- **Keep recall limits small.** Injecting twenty memories recreates the context
  problem memory was meant to solve.
- **Set `minScore` above zero** on recall, or unrelated questions get confident
  irrelevancies prepended.
- **Give events and observations a TTL.** Facts and preferences rarely need one.
- **Re-embed after changing embedding model.** Old vectors are incomparable with
  new ones; `EmbeddedMemoryStore.backfill()` is a migration, not an optimisation.

## Common mistakes

- **Pronouns in memories.** "She prefers that" is unrecallable.
- **Semantic-only retrieval.** It will fail on the first ticket number.
- **Averaging keyword and semantic scores.** Use `HybridMemoryStore`.
- **Summarising on every turn.** Use the caching strategy, not a hand-rolled one.
- **Storing the current question.** It is not durable knowledge.
- **Never pruning.** Accuracy degrades as the store grows.

## Example

[`example/agentic_memory_example.dart`](example/agentic_memory_example.dart)
runs offline and demonstrates storing, keyword and hybrid recall, memory-backed
history, tools and automatic extraction.

## Licence

MIT
