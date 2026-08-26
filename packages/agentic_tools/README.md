# agentic_tools

Tool and function-calling layer of the
[agentic](https://github.com/v1j4yk/agentic_flutter) framework.

A tool is a capability an agent can invoke: search the web, read a file, query a
database, take a photo. This package defines what a tool is, how a catalogue is
kept, how a subset is handed to an agent, and everything that happens between the
model asking for a call and the tool's code running.

Pure Dart. Platform tools that need Flutter — camera, GPS, contacts — live in
their own packages and depend on this one, so a server or CLI can use the tool
system without a UI framework.

## Installation

```yaml
dependencies:
  agentic_tools: ^0.1.0
```

## Declaring a tool

```dart
final searchTool = FunctionTool(
  name: 'search_web',
  description:
      'Searches the public web and returns the top results with titles, URLs '
      'and snippets. Use for current events and facts that may have changed. '
      'Do not use for the user\'s own documents — use `search_documents`.',
  tags: {'research'},
  parameters: JsonSchema.object(
    properties: {
      'query': JsonSchema.string(description: "The query, in the user's words"),
      'limit': JsonSchema.integer(minimum: 1, maximum: 10, defaultValue: 5),
    },
    required: {'query'},
  ),
  handler: (invocation) async {
    final results = await api.search(invocation.require<String>('query'));
    return ToolResult.success(results.join('\n'));
  },
);
```

The `description` is the entire basis on which a model decides whether to call
this tool and with what. Say what it returns, name its limits, and say when
*not* to use it. A parameter documented as "the query" performs measurably worse
than one documented as "the search query, in the user's own words".

`FunctionTool.text` is shorter still when the answer is a string. Implement
`Tool` directly for stateful tools that own a resource — a database handle, a
camera, a socket.

### Specs are validated at construction

```dart
ToolSpec(name: 'search web!', description: '...');
// ConfigurationException: names must be 1-64 characters of letters, digits,
// underscores or hyphens — the intersection of what OpenAI, Anthropic and
// Google accept.
```

That turns a provider-side 400, which arrives at runtime in production with an
unhelpful message, into an error at wiring time.

## Catalogue and selection

A registry is everything your app can do. An agent must never receive all of it:
tool-selection accuracy falls measurably as the catalogue grows, and every spec
is serialised into **every request on every turn**.

```dart
final registry = ToolRegistry()
  ..register(searchTool)
  ..register(readFileTool)
  ..registerLazy(cameraSpec, () => CameraTool(controller));

final researchTools = registry.select(tags: {'research'});
final safeTools     = registry.select(readOnly: true);
final combined      = researchTools + registry.select(names: {'read_file'});
```

`registerLazy` keeps the spec available for prompt assembly while deferring
construction until the model actually calls the tool — which on mobile is the
difference between opening a camera, a database and an HTTP client at launch
and opening none of them.

A `ToolSet` distinguishes the two ways a lookup can fail, because they mean very
different things:

```dart
set.resolve('write_file');
// NotFoundException: Tool `write_file` exists but was not made available to
// this agent.  ← you gave the agent the wrong set

set.resolve('serch_web');
// NotFoundException: No tool named `serch_web`. Did you mean `search_web`?
```

## Execution

```dart
final executor = ToolExecutor(
  tools: registry.select(tags: {'research'}),
  approvalHandler: (request) => showConfirmDialog(request),
);

final messages = await executor.executeAllAsMessages(
  response.toolCalls,
  context: context,
);
```

Between the model's request and your handler, the executor:

1. resolves the name against this agent's set;
2. repairs near-miss arguments (`"5"` → `5`) and validates the rest;
3. asks a human when the spec requires approval;
4. enforces a time budget and honours cancellation;
5. opens a span, publishes events, writes structured logs;
6. turns every outcome into a message the model can read.

### Failure is a value

Almost nothing thrown inside a tool escapes. A failure comes back as a
`ToolResult` with `isError`, which becomes a tool message the model reads and
acts on — retry with a different path, ask the user, explain the problem.

```dart
handler: (invocation) async => ToolResult.failure(
  'No such file: ${invocation.require<String>('path')}. '
  'Use `list_files` to see what is available.',
),
```

Write failures for the reader. "File not found, here is what to try instead"
recovers; "Error" does not.

The one exception is a cancellation that came from the **caller** — the user
pressed stop — which propagates, because there is nobody left to recover. A tool
that stops because its own budget expired is different, and comes back as a
timeout failure the agent can work around.

### Invalid arguments are a conversation, not a crash

```dart
// The model omitted a required argument.
result.content;
// The arguments for `search_web` were not valid:
// - /query: Required property `query` is missing (The search query).
// - /limit: Expected a value <= 10, got 99.
// Correct them and call `search_web` again.
```

Every violation is reported at once. When the caller is a language model
repairing its own output, one round trip listing four problems beats four round
trips listing one each.

### Human in the loop

```dart
FunctionTool(
  name: 'send_email',
  requiresApproval: true,
  isReadOnly: false,
  isIdempotent: false,
  // ...
);
```

If a tool requires approval and no handler is configured, the call is **denied**.
Failing closed is the only safe default: the alternative is a tool marked as
needing consent running without any.

### Batches: parallel reads, serialised writes

```dart
await executor.executeAll(response.toolCalls, context: context);
```

Read-only calls run concurrently up to `maxConcurrency`; mutating calls run one
at a time. A model happily requests four parallel calls without knowing that two
of them write to the same file. Results always come back in the order the model
asked for them, whatever order they finished in.

### Time budgets are actually enforced

Cancellation in Dart is cooperative, so a tool that never checks its token would
block an agent loop for ever. The executor therefore does both: it cancels the
token, *and* stops waiting when the budget expires. The abandoned work may keep
running — nothing can prevent that — but the run continues.

## Observability

```dart
bus.on<ToolCallStarted>().listen((e) => setState(() => status = e.toolName));
bus.on<ToolCallCompleted>().listen((e) => metrics.record(e.toolName, e.duration));
```

Every failure carries a `ToolFailureKind` — `unknownTool`, `invalidArguments`,
`approvalDenied`, `timeout`, `executionFailed`, `unexpectedError` — so UI and
metrics branch on a category rather than parsing prose. The distinction that
matters most is `invalidArguments`, which the model can fix by trying again,
from `executionFailed`, which it cannot.

Each call also opens a span with `tool.name`, `tool.version`, `tool.read_only`
and `tool.is_error`.

## Composition over inheritance

`DelegatingTool` adds cross-cutting behaviour without touching any concrete
tool:

```dart
final class CachingTool extends DelegatingTool {
  CachingTool(super.inner, this._cache);

  final Map<String, ToolResult> _cache;

  @override
  Future<ToolResult> call(ToolInvocation invocation) async =>
      _cache['${invocation.toolName}:${invocation.arguments}'] ??=
          await super.call(invocation);
}
```

`RenamedTool` resolves the collision when two packages both register `search`,
without forking either.

## Best practices

- **Name after the action**, in `snake_case`: `search_web`, `read_calendar`.
- **Use enums for constrained parameters.** A model given an enum picks from it
  almost perfectly; the same model given a free string invents a fourth option.
- **Mark `isReadOnly: false` honestly.** It is what decides parallelism.
- **Mark `isIdempotent: false` on anything with a side effect.** The framework
  cannot know whether the first attempt already charged the card.
- **Give slow tools their own `timeout`** rather than raising the default.
- **Tag tools** so each agent gets eight, not forty.

## Common mistakes

- **Throwing for an expected failure.** It ends the run; return
  `ToolResult.failure` instead.
- **Swallowing `CancelledException`.** It must propagate.
- **Ignoring the cancellation token in a long tool.** It keeps a phone's radio
  awake after the user has gone.
- **Validating arguments inside the handler.** The executor already did; if it
  is running, they conformed.
- **Registering every tool for every agent.** The single biggest lever on
  tool-calling accuracy and per-turn token cost.

## Example

See [`example/agentic_tools_example.dart`](example/agentic_tools_example.dart)
for a runnable end-to-end walkthrough, including the arguments a model got
wrong, a tool that fails, and one that needs a human to say yes.

## Licence

MIT
