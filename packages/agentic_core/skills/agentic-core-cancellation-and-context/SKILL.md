---
name: agentic-core-cancellation-and-context
description: >-
  Use when stopping work in progress or passing run-scoped services in a Dart
  or Flutter project on the agentic framework: CancellationToken,
  CancellationTokenSource, deadlines, AgenticContext and its child scopes, and
  making a long operation or a custom tool cancellable. Covers why the context
  is passed rather than looked up, and how a screen being closed stops a run
  that is costing money.
license: MIT
metadata:
  package: agentic_core
  min-version: 0.2.0
---

# Cancellation and the run context

## Why cancellation is cooperative

A Dart `Future` cannot be cancelled from outside. So a token is threaded
through, and long operations check it. Where that is not enough — a third-party
SDK that ignores its token — the framework also stops *waiting*, so a badly
behaved component degrades one step instead of hanging a run.

On a phone this is not a nicety. A user who closes a screen expects the bill to
stop.

## Starting and stopping work

```dart
final source = CancellationTokenSource();
final context = AgenticContext.root(cancellation: source.token);

final run = agent.run(AgentInput.text(question), context: context);

// Elsewhere: a close button, a navigation pop, a timeout.
source.cancel('the user left the screen');
```

Ready-made sources:

```dart
CancellationTokenSource.timeout(const Duration(seconds: 30));
CancellationTokenSource.cancelled('already too late');
CancellationToken.merge(userToken, deadlineToken);   // either one stops it
CancellationToken.none;                              // explicit "never cancels"
```

`source.cancelAfter(duration)` adds a deadline to a source you already have.
Dispose a source you own, which releases its listeners.

In Flutter, do not wire this by hand: `AgenticRuntime.run` and
`LifecycleCancellation` already bind a run to the widget and app lifecycle.

## Making your own code cancellable

Three tools, in order of preference:

```dart
// 1. Check between units of work.
for (final page in pages) {
  invocation.cancellation.throwIfCancelled(operation: 'index_page');
  await index(page);
}

// 2. Stop waiting on something that cannot be cancelled.
final reply = await token.race(thirdPartySdk.call(), operation: 'sdk.call');

// 3. End a stream when the token trips.
await for (final chunk in token.bind(source, operation: 'download')) { … }
```

Also available: `token.isCancelled`, `token.reason`, `token.whenCancelled` (a
future), and `token.onCancelled(callback)`, which returns the function that
removes the listener — call it, or you have a leak.

**Let `CancelledException` propagate.** It is not a failure to report; it is the
caller getting what they asked for. A tool that catches it and returns a
`ToolResult.failure` tells the model the tool broke, and the model tries again.

## The context

`AgenticContext` carries everything a run needs and nothing it does not:
`runId`, `logger`, `events`, `tracer`, `clock`, `ids`, `cancellation`,
`deadline`, `metadata`, `untrustedContent`.

```dart
final context = AgenticContext.root(runId: 'run-42');

await context.step('retrieve', (childContext, span) async {
  span.setAttribute('query.length', query.length);
  return retriever.retrieve(query, context: childContext);
});
```

`step` opens a span, creates a child context and closes the span even if the
body throws. `context.child('name')` is the same nesting without the span.

Deadlines live here too: `context.deadline`, `context.remaining`,
`context.isExpired`, and `context.throwIfCancelled()` — which checks the
deadline as well as the token, and is why framework code calls it rather than
checking `token.isCancelled` alone.

Attach run-scoped facts once and get them on every log and event:

```dart
final scoped = context.withMetadata({'user.id': userId, 'feature': 'summarise'});
```

## Why it is passed, never reached for

No `Zone`, no ambient singleton. Zone values do not survive an isolate hop, are
invisible in stack traces, hide a function's dependencies from its signature,
and a widget rebuild can run in a different zone than the one that started the
operation. A parameter costs one line and is always right.

Every framework entry point takes `{AgenticContext? context}`. Pass it, or the
call gets a fresh root context with no cancellation, no trace and no deadline —
which works, and is invisible until you need to stop a run and cannot.

## Common mistakes

- Creating a `CancellationTokenSource` per call and never cancelling or
  disposing it.
- Swallowing `CancelledException` in a tool or a loop.
- Passing a context to the agent but not down into your own tool's HTTP call,
  so the run stops and the request keeps going.
- Using `DateTime.now()` instead of `context.clock.now()`, which makes the
  behaviour untestable.

## See also

- `agentic-core-errors-and-retry` — what to do with the failures that do escape
- `agentic-core-tracing-and-events` — the other things the context carries
- `agentic-flutter-add-chat-agent` — lifecycle-bound cancellation in an app
