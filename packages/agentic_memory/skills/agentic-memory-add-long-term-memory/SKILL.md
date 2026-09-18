---
name: agentic-memory-add-long-term-memory
description: >-
  Use when an assistant should remember things across conversations with
  agentic_memory: MemoryStore, MemoryEntry and its kinds, writing and searching
  memories, the memory tools an agent can call, RememberingAgent for automatic
  extraction, and pruning. Read this for "remember the user's preferences",
  "recall what we discussed last week", or choosing between memory and a
  session.
license: MIT
metadata:
  package: agentic_memory
  min-version: 0.2.0
---

# Long-term memory

## Memory is not a session

A **session** is one conversation, sent to the model each turn. **Memory** is
what survives conversations and is recalled only when relevant. Reach for
memory when the assistant should know something next week; reach for a session
when it should know what was said two turns ago.

## Writing and reading

```dart
final store = InMemoryMemoryStore(maxEntries: 1000, halfLife: const Duration(days: 14));

await store.write(MemoryEntry(
  id: context.ids.next(),
  content: 'Prefers metric units and terse answers.',
  createdAt: context.clock.now(),
  kind: MemoryKind.preference,
  importance: 0.8,                       // 0..1, weighs the ranking
  tags: {'style'},
  expiresAt: null,                       // set for things that go stale
));

final hits = await store.search(MemoryQuery(
  text: 'what units should I use?',
  limit: 5,
  kinds: {MemoryKind.preference},
  minImportance: 0.3,
));
for (final hit in hits) {
  print('${hit.score}  ${hit.entry.content}');
}
```

`MemoryKind` is `fact`, `preference`, `event`, `summary`, `task` or
`observation`. Filtering by kind is what keeps "what does this user like" from
returning last Tuesday's meeting note.

Ranking weighs relevance, importance and recency; `halfLife` sets how fast
recency decays, and `prune()` drops expired and surplus entries.

## Keyword first, then semantics

`InMemoryMemoryStore` matches terms, and that is the default on purpose:
embeddings underperform term matching on identifiers, names, versions and error
codes, which is a large share of what people ask an assistant to remember.

Add meaning when paraphrase matters:

```dart
final semantic = EmbeddedMemoryStore(
  InMemoryMemoryStore(),
  embeddings: embeddingModel,
  minSimilarity: 0.25,
);

final hybrid = HybridMemoryStore(
  keyword: InMemoryMemoryStore(),
  semantic: semantic,
  writeToBoth: true,
);
```

`HybridMemoryStore` fuses the two rankings by rank (reciprocal rank fusion), not
by score — a cosine similarity and a keyword score are not on the same scale,
and averaging them means nothing. `EmbeddedMemoryStore.backfill()` embeds
entries written before embeddings were switched on.

## Letting the agent manage its own memory

```dart
final agent = ToolCallingAgent(
  info: info,
  model: model,
  tools: ToolRegistry(tools: memoryTools(store: store)).all,
  instructions: 'Remember durable preferences and facts about the user. '
      'Do not remember one-off requests.',
  budget: AgentBudget.interactive,
);
```

`memoryTools(store: store)` gives `remember`, `recall` and `forget`; the
individual factories `rememberTool`, `recallTool` and `forgetTool` take `store`
by name too. **`recall` returns untrusted content**: a memory was extracted from
an earlier conversation that may have contained injected text, so after a recall
a tool that is not read-only needs approval.

## Extracting memories automatically

```dart
final remembering = RememberingAgent(
  agent,
  store: store,
  extractionModel: cheapModel,     // a small model is enough
  maxMemoriesPerRun: 5,
  minimumImportance: 0.3,
  sessionScoped: false,
);
```

It wraps any agent, extracts durable facts after each run, and publishes
`MemoriesExtracted` (or `MemoryExtractionFailed`) so extraction never breaks the
run it followed.

## Recalling without asking

Make memory part of history selection, so the agent never needs to call a tool:

```dart
AgentSession(
  strategy: RecallingHistory(store: store, limit: 5, inner: const SlidingWindowHistory()),
);
```

`select` receives the turn about to be sent, which is why recall works on the
first turn — the moment it matters most.

## Privacy, briefly

Memory is the most personal data an assistant holds. Decide early: what is
stored, for how long (`expiresAt`), where (`agentic_sqlite` for on-device), and
how a user deletes it (`store.delete`, `store.clear`). "We remembered everything
forever" is a decision too, just not a defensible one.

## Common mistakes

- Using memory for conversation state, then wondering why the agent repeats
  itself within one chat — that is a session.
- Writing every turn into memory: recall quality falls as the store fills with
  noise. Extract, do not log.
- Embeddings only, no keyword half, then failing to recall an error code or a
  version number.
- Never pruning, so a phone-sized store scans thousands of stale entries.
- Forgetting that recall is untrusted content, and being surprised by an
  approval prompt after it.

## See also

- `agentic-memory-choose-recall-strategy` — summarising versus recalling history
- `agentic-agents-sessions-and-history` — the other kind of remembering
- `agentic-sqlite-persist-everything` — memory that survives a restart
