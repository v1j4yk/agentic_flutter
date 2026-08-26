# Contributing

Thanks for considering a contribution. This document is short on ceremony and
specific about the things that actually get pull requests rejected.

## Setup

Requires **Dart 3.11+** (Flutter 3.41+ once Flutter packages land).

```bash
git clone https://github.com/v1j4yk/agentic_flutter.git
cd agentic
dart pub get                  # native pub workspace — no bootstrap step
dart run melos run verify     # format + analyze + test
```

`melos run verify` is exactly what CI runs. If it passes locally it passes
there.

## The bar

Every pull request must:

1. **Pass `melos run verify`.** Analysis runs with `--fatal-infos`, so an info
   is a build failure. That is deliberate: a lint set nobody enforces is a lint
   set nobody follows.
2. **Document every public member.** `public_member_api_docs` is an error. See
   [Documentation](#documentation) for what "documented" means here.
3. **Include a test that fails without the change.** For a bug fix, write the
   failing test first and put it in the same commit.
4. **Not add a dependency without saying why.** See
   [Dependencies](#dependencies).

## Documentation

Doc comments are not restated signatures. `/// The name of the tool.` on a field
called `name` adds nothing.

Write what a reader cannot infer:

- **Why** the design is this way, when it is not obvious.
- **What breaks** if it is used wrongly.
- **Trade-offs** that were considered and rejected.
- **A short example** for anything with more than two parameters.

Compare:

```dart
/// Whether the tool is read-only.
final bool isReadOnly;
```

with what is actually in the codebase:

```dart
/// Whether the tool only reads.
///
/// Read-only tools can be run in parallel, retried freely and executed
/// speculatively. This is the flag a supervising agent consults before
/// deciding whether four calls can go at once.
final bool isReadOnly;
```

The second tells a caller how to set it correctly. That is the standard.

## Code style

`dart format` decides layout; do not argue with it. Beyond that:

- **Composition over inheritance.** `DelegatingTool` rather than an abstract
  base with hooks.
- **Immutable value objects.** Fields `final`, collections wrapped
  `unmodifiable` in the constructor, `copyWith` for derivation.
- **Interface-first.** A new capability is an interface plus at least one
  adapter, never a concrete class other layers reach into.
- **No I/O in `agentic_core`.** If it needs a socket or a file, it belongs in an
  adapter package.
- **No Flutter outside `agentic_flutter`.** Not even for `debugPrint`; inject a
  writer instead.
- **Inject the clock.** Never call `DateTime.now()` or `Future.delayed`
  directly. Take a `Clock`.
- **Thread the cancellation token** through anything that can take longer than a
  frame.

## Errors

Every failure is an `AgenticException` subclass with:

- a stable `snake_case` `code` — it is public API, and renaming one is a
  breaking change;
- an honest `isRetryable`, answering "is this transient?", not "should this be
  retried?";
- a `toJson` that includes any fields you added;
- a message written for the developer reading the log at 2am, naming the
  component, the operation and the offending value.

Never introduce a bare `throw Exception('...')`.

## Tests

- Name tests as sentences describing behaviour: `'does not retry a
  non-retryable failure'`, not `'test retry 2'`.
- Assert on **behaviour**, not implementation. `clock.requestedDelays` is a
  behaviour; a private field is not.
- Add a `reason:` when the assertion encodes a decision:
  ```dart
  expect(attempts, 1, reason: 'cancellation is never retried');
  ```
- Use `FakeClock` from `package:agentic_core/testing.dart` for anything timed.
- No test may touch the network or sleep for real.

If a test you wrote catches a genuine design flaw, fix the design rather than the
test, and say so in the pull request. Several of this framework's behaviours —
how cancellation dispatch honours deregistration, how a circuit breaker
classifies failures — are the way they are because a test disagreed with the
first implementation.

## Dependencies

Every dependency added to `agentic_core` is inherited by every application that
ever uses the framework, on every platform.

A new dependency needs a paragraph in the pull request covering: what it does
that we would otherwise write, its transitive weight, its platform support
(including web and WASM), and its maintenance status.

`meta` and `collection` are the whole of the core's dependency list, and the bar
for a third is high.

## Adding a provider

1. Implement `ChatModel` (and `EmbeddingModel` where it applies).
2. Map provider errors onto the core hierarchy — especially the
   429-versus-quota distinction, which retry logic depends on.
3. Declare capabilities honestly in `ModelInfo`. Claiming tool calling a model
   does not have breaks callers that degrade on `supports()`.
4. Pass the shared `ChatModel` contract suite.
5. Add golden tests from **recorded** payloads. Never commit a real API key; the
   test suite must run offline.

## Adding a tool

1. Write the description for the model, not for a reviewer. Say what it returns,
   its limits, and when *not* to use it.
2. Constrain parameters — enums over free strings wherever the set is known.
3. Set `isReadOnly`, `isIdempotent` and `requiresApproval` honestly. They drive
   parallelism, retries and consent.
4. Return `ToolResult.failure` for expected failures; let `CancelledException`
   propagate.
5. Honour the cancellation token in anything long-running.

## Commits and pull requests

Conventional commits, scoped by package:

```
feat(core): add decorrelated jitter to backoff strategies
fix(tools): categorise failures a tool reported itself
docs(core): explain why the error hierarchy is base, not sealed
```

Keep pull requests focused. A refactor and a behaviour change in one diff is two
pull requests.

In the description, say what changed, **why**, and what you considered and
rejected. The last part is the one reviewers value most.

## Reporting bugs

Include the Dart and framework versions, a minimal reproduction, what you
expected, and what happened. If a provider is involved, include its request id —
it is in `ProviderException.requestId` — and please redact your key.

## Licence

Contributions are accepted under the MIT licence covering this repository.
