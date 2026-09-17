# Upgrading to 0.2.0

Most apps upgrade in three steps and change no code by hand. This guide lists
every change that could affect an existing app. It was checked against the
committed signature snapshots, so it is complete for signatures. Behaviour
changes, which signatures cannot show, are listed separately.

## The short version

```sh
# 1. Raise the constraints.
#    agentic_flutter: ^0.2.0 (or each agentic_* package you use)
dart pub upgrade --major-versions

# 2. Apply the automatic migration.
dart fix --apply

# 3. Run your tests, then read "Behaviour changes" below.
```

If your app has an approval handler, or none of its tools read outside
content, step 3 finds nothing.

## Breaking signature changes

There is one.

### Memory tool factories take `store` by name

`memoryTools`, `rememberTool`, `recallTool` and `forgetTool` in
`agentic_memory`. Every other tool factory in the framework takes its
arguments by name; these four were the exception.

```dart
memoryTools(store)                    // 0.1.x
memoryTools(store: store)             // 0.2.0
```

`dart fix --apply` makes this change for you.

Every other signature change in 0.2.0 adds an optional named parameter, so it
doesn't affect existing calls:

| Declaration | New parameter |
|---|---|
| `AgenticContext(...)` | `untrustedContent:` |
| `ToolSpec(...)`, `ToolSpec.copyWith`, `FunctionTool(...)`, `FunctionTool.text` | `returnsUntrustedContent:` |
| `ToolExecutor(...)`, `ToolCallingAgent(...)` | `untrustedContentPolicy:` |
| `ToolApprovalRequest(...)` | `untrustedSources:` |

## Behaviour changes

### State-changing tools need approval after untrusted content

**Who is affected:** an app whose agent has both kinds of tool:

- a tool that reads text the app didn't write: `searchTool` or `answeringTool`
  from `agentic_rag`, any MCP tool, `recallTool` from `agentic_memory`, or your
  own tool marked `returnsUntrustedContent: true`
- a tool that isn't read-only (`isReadOnly: false`)

**What changed:** once the first kind of tool has returned in a run, every call
to the second kind is treated as needing approval. A retrieved document or
web page can contain instructions such as "delete all notes", and a model can
follow them. The framework doesn't try to detect that, because nothing does so
reliably. Instead it makes sure an injected instruction can't change anything
without a person seeing it first.

**What you'll see:**

| Your setup | 0.1.x | 0.2.0 |
|---|---|---|
| An approval handler is set | The call ran | The handler is asked, and the request names the content that came before it (`request.untrustedSources`) |
| No approval handler | The call ran | The call is denied. The model is told no one could approve it, and names the content that came before |

**What to do:** choose one per agent.

```dart
// Ask a person. With agentic_flutter, the approval sheet already explains
// which content came before the request.
ToolCallingAgent(
  ...,
  approvalHandler: sheetApprovalHandler(navigatorKey: navigatorKey),
);

// Background work with nobody to ask: deny instead of waiting.
ToolCallingAgent(..., untrustedContentPolicy: UntrustedContentPolicy.refuse);

// The state-changing tools can do no harm (for example, they only write to a
// scratch list the user reviews anyway): keep 0.1.x behaviour.
ToolCallingAgent(..., untrustedContentPolicy: UntrustedContentPolicy.allow);
```

A tool that doesn't change state is never affected. If one of your tools is
marked `isReadOnly: false` but only reads, correcting the flag is the right
fix.

### `null` for an optional tool argument is accepted

**What changed:** when a model sends `"limit": null` for an optional
parameter, `ToolExecutor` treats it as if the argument were left out and
applies the default. In 0.1.x the whole call failed with "Expected integer, got
null".

**Who is affected:** nobody needs to change code. Tool calls that used to fail
now succeed. A tool that checked `arguments.containsKey('limit')` to tell
`null` from "not sent" will now see the key missing, which is how 0.1.x
reported a left-out argument too. A `null` for a *required* parameter is still
rejected.

## New in 0.2.0

Nothing here is required to upgrade.

- **`agentic_test`** (dev dependency): record a real model's answers once and
  replay them offline in tests, and evaluate agent behaviour with pass rates.
  Also published for 0.1.x.
- **`agentic_tools_generator`** (dev dependency): write a function annotated
  with `@ToolFunction`, and `build_runner` generates the tool, its JSON schema
  and argument handling. Mistakes fail the build instead of the tool call.
- **`agentic_sqlite`**: vector, memory, conversation and workflow-snapshot
  stores that survive the app closing. Also published for 0.1.x.
- **`RagStack`** and **`RagPipeline.stream`** in `agentic_rag`: one call to set up
  keyword-only or hybrid retrieval, and answers that stream with their sources.
  Also published for 0.1.x.
- **`SessionStore`** and **`WorkflowSnapshotStore`**: ports for persisting
  conversations and suspended workflows. Also published for 0.1.x.

## Checking your own upgrade

If a test fails after upgrading, this is the order to look in:

1. A tool call denied with "needs a person to approve it because this
   conversation has read content from …", or with "changes state, and this
   conversation has read content from …" under `refuse`: the
   untrusted-content change above.
2. A compile error on `memoryTools(...)`: run `dart fix --apply`.
3. Anything else is not an intended change. Please
   [open an issue](https://github.com/v1j4yk/agentic_flutter/issues) with the
   failing call.
