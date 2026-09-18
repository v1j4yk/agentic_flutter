---
name: agentic-agents-sessions-and-history
description: >-
  Use when an agent needs to remember a conversation across turns, or when a
  long chat overflows the context window, in agentic_agents: AgentSession,
  SessionStore, saving and restoring a conversation, and the HistoryStrategy
  choices (KeepAllHistory, SlidingWindowHistory, CharacterBudgetHistory, and
  the summarising and recalling strategies from agentic_memory). Read this for
  "the agent forgets what I said" or "context length exceeded".
license: MIT
metadata:
  package: agentic_agents
  min-version: 0.2.0
---

# Sessions and history

## Without a session, every turn is a first turn

`agent.run(input)` with no session starts a fresh conversation. Multi-turn chat
means one session, reused:

```dart
final session = AgentSession(strategy: const SlidingWindowHistory(maxMessages: 20));

await agent.run(AgentInput.text('My name is Priya.'), session: session);
await agent.run(AgentInput.text('What is my name?'), session: session);   // knows
```

A session owns the transcript and the running totals:

```dart
session.history;      // every message so far
session.runCount;
session.totalUsage;   // TokenUsage across the conversation
session.totalCost;
session.add(message); session.append(messages); session.clear();
session.setSystemPrompt('You are terse.');   // replaces any existing system turn
```

## Choosing a history strategy

A strategy decides what is *sent* on the next turn. The transcript is never
edited — trimming for the model does not delete anything.

| Strategy | Sends | Use when |
|---|---|---|
| `KeepAllHistory()` (default) | everything | short conversations, tests |
| `SlidingWindowHistory(maxMessages: 20)` | the last N messages | chat that runs long |
| `CharacterBudgetHistory(maxCharacters: 24000)` | as much as fits | mixed message sizes |
| `SummarisingHistory(...)` (`agentic_memory`) | a summary plus recent turns | very long chats |
| `RecallingHistory(...)` (`agentic_memory`) | what is relevant now | assistants that remember across sessions |

`select` is asynchronous and receives the turn about to be sent, because
summarising is a model call and recall needs to know what is being asked. Your
own strategy is one class:

```dart
final class KeepSystemAndLastTurn implements HistoryStrategy {
  const KeepSystemAndLastTurn();

  @override
  Future<List<Message>> select(
    List<Message> history, {
    Message? pending,
    AgenticContext? context,
  }) async => <Message>[
    ...history.where((m) => m.role == MessageRole.system),
    if (history.isNotEmpty) history.last,
  ];
}
```

## Persisting a conversation

```dart
final store = InMemorySessionStore();                 // or SqliteSessionStore
await store.save(session);

final restored = await store.load(sessionId, strategy: const SlidingWindowHistory());
for (final summary in await store.list()) {
  print('${summary.id}  ${summary.messageCount}  ${summary.updatedAt}');
}
await store.delete(sessionId);
```

`AgentSession.toJson` / `fromJson` is the same thing without a store — useful for
a snapshot inside a larger document. A strategy is not serialised, so pass it
when loading, otherwise the session comes back keeping everything.

In Flutter, `agentic_sqlite`'s `db.sessionStore()` survives restarts, which is
what "continue where we left off" needs.

## Trimming versus context-window errors

A provider rejecting a request for length is a `ProviderException`, not
something the framework can retry away. Fix it upstream:

1. Use a trimming strategy rather than `KeepAllHistory`.
2. Trim the *tool results*, not the user's words — they are usually the bulk.
3. Summarise with a cheap model (`SummarisingHistory`) rather than dropping
   turns, when early context matters.
4. Check `model.info.contextWindow` when choosing a window size.

## Repairing a broken transcript

A conversation cut off mid-tool-call leaves a tool call with no result, which
some providers reject outright:

```dart
final safe = repairDanglingToolResults(session.history);
```

Use it after restoring a session that was interrupted, or when building history
from your own storage.

## Common mistakes

- Creating a new `AgentSession` per turn, then concluding the model has no
  memory.
- Serialising a session and expecting its strategy to come back with it.
- `KeepAllHistory` in production chat, which works right up until the window
  overflows on someone else's device.
- Mutating `session.history` directly instead of `add`/`append`.
- Sharing one session across two agents with different system prompts.

## See also

- `agentic-agents-build-tool-calling-agent` — the loop that consumes the session
- `agentic-memory-choose-recall-strategy` — summarising and recalling history
- `agentic-sqlite-persist-everything` — sessions that survive a restart
