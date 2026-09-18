---
name: agentic-memory-choose-recall-strategy
description: >-
  Use when deciding what an agent sends the model each turn in agentic_memory:
  SummarisingHistory for long conversations, RecallingHistory for memories from
  other conversations, combining them, and their costs. Read this when a chat
  overflows the context window, when an assistant forgets the start of a long
  conversation, or when recall returns irrelevant memories.
license: MIT
metadata:
  package: agentic_memory
  min-version: 0.2.0
---

# Choosing a recall strategy

## The two problems, which are different

| Problem | Symptom | Strategy |
|---|---|---|
| This conversation is too long | context window errors, or the model forgets the start | `SummarisingHistory` |
| The answer lives in a *previous* conversation | "I told you last week" | `RecallingHistory` |

The plain strategies in `agentic_agents` — `KeepAllHistory`,
`SlidingWindowHistory`, `CharacterBudgetHistory` — solve the first problem by
dropping messages. These two solve it by being selective instead.

## Summarising a long conversation

```dart
final session = AgentSession(
  strategy: SummarisingHistory(
    model: cheapModel,        // a small model is enough, and this runs often
    summariseAfter: 20,       // start summarising past this many messages
    keepRecent: 8,            // last N turns stay verbatim
    maxSummaryWords: 200,
    store: memoryStore,       // optional: keep the summary as a memory too
    sessionId: session.id,
  ),
);
```

Older turns collapse into a running summary, recent turns stay exact. Two things
to know:

- **It costs a model call** when it re-summarises. Use a cheap model, and do not
  set `summariseAfter` so low that every turn triggers one.
- **Summaries lose detail**, by definition. Exact identifiers, numbers and
  names are what goes first — keep `keepRecent` generous enough that the
  details in play are still verbatim, and call `invalidate()` if you mutate the
  history behind its back.

## Recalling from other conversations

```dart
AgentSession(
  strategy: RecallingHistory(
    store: memoryStore,
    inner: const SlidingWindowHistory(maxMessages: 20),  // applied first
    limit: 5,
    kinds: {MemoryKind.preference, MemoryKind.fact},
    minScore: 0.3,
    includeSessionScoped: false,   // other sessions' memories only
  ),
);
```

Recalled memories are injected as context for the turn about to be sent, which
is why `select` receives the pending message: a history-only signature recalls
nothing on the first turn, which is exactly when recall matters most.

## Combining them

They compose, because `RecallingHistory` takes an `inner` strategy:

```dart
RecallingHistory(
  store: memoryStore,
  inner: SummarisingHistory(model: cheapModel, keepRecent: 6),
  limit: 4,
);
```

Summarise this conversation, then add what is relevant from previous ones. That
is the setup for a long-lived personal assistant.

## Tuning recall that returns junk

1. **Filter by kind.** A question about preferences should not surface event
   notes.
2. **Raise `minScore`.** Better to recall nothing than to recall noise: an
   irrelevant memory in the prompt makes answers worse, not neutral.
3. **Lower `limit`.** Five good memories beat twenty mediocre ones, and cost
   fewer tokens.
4. **Check what is stored.** Recall cannot be better than extraction; if the
   store is full of "user asked about the weather", fix that first.
5. **Use a hybrid store** if paraphrases miss and exact terms hit, or the
   reverse.

## Cost and latency, honestly

Both strategies run *before* every model call:

- `SummarisingHistory` — occasional extra model call; cheap model, bounded
  output.
- `RecallingHistory` — one store search; with an embedded store, one embedding
  call per turn.

On a phone that embedding call is also a network round trip before the user sees
a token. If time-to-first-token matters more than recall, use a keyword store,
or recall only when the turn looks like a question about the past.

## Common mistakes

- `SummarisingHistory` with an expensive model, doubling the cost of a chat.
- Recall with no `minScore`, filling the prompt with weak matches.
- Both strategies writing to the same store with `sessionScoped` misconfigured,
  so the assistant "remembers" the current conversation twice.
- Expecting recall to work when nothing ever wrote a memory — pair it with
  `RememberingAgent` or the memory tools.

## See also

- `agentic-memory-add-long-term-memory` — writing the memories being recalled
- `agentic-agents-sessions-and-history` — the plain strategies
- `agentic-rag-answer-with-citations` — when the knowledge is documents, not memories
