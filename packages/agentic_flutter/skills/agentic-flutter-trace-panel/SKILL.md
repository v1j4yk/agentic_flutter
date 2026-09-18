---
name: agentic-flutter-trace-panel
description: >-
  Use when building a debug view of what an agent did inside a Flutter app with
  agentic_flutter: EventRecorder, TraceInspector, EventTile, filtering event
  types, and keeping the recorder bounded so it is not a leak. Read this for
  "show me what the agent did", "debug panel for tool calls", or investigating a
  wrong answer in a running app.
license: MIT
metadata:
  package: agentic_flutter
  min-version: 0.2.0
  sample-types: DebugScreen
---

# The in-app trace panel

## Recording

```dart
class _DebugScreenState extends State<DebugScreen> {
  late final EventRecorder _recorder;

  @override
  void initState() {
    super.initState();
    _recorder = EventRecorder(
      context.agenticEvents,
      capacity: 500,                 // bounded: the oldest are dropped
      include: const {'llm.', 'tool.', 'agent.'},   // type prefixes, empty = everything
    )..start();
  }

  @override
  void dispose() {
    _recorder.stop();
    _recorder.dispose();             // an unbounded, undisposed recorder is a leak
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => TraceInspector(
    recorder: _recorder,
    onEventTap: (event) => showDialog(context: context, builder: (_) => _EventDetail(event)),
  );
}
```

`TraceInspector` shows events newest first. `EventTile` renders one, with
`EventTile.iconFor` and `EventTile.colourFor` so a custom list can match.

`recorder.dropped` tells you how many events fell off the end — if that number
is large, the capacity is too small for what you are debugging, or the panel is
subscribed to everything.

## What you can see

Every layer publishes: `LlmRequestStarted`, `LlmFirstTokenReceived`,
`LlmResponseCompleted` (with usage and cost), `LlmRequestFailed`,
`LlmFailoverOccurred`, `ToolCallStarted`, `ToolApprovalRequested`,
`ToolCallCompleted`, `AgentRunStarted`, `AgentStepCompleted`,
`AgentBudgetExhausted`, `AgentDelegated`, `MemoriesRecalled`,
`ChunksRetrieved`, `McpToolCalled`, and your own.

Which answers the questions that matter when an answer is wrong:

| Question | Look at |
|---|---|
| Did it search at all? | `ChunksRetrieved`, `ToolCallStarted` |
| Why did it stop early? | `AgentBudgetExhausted`, and the dimension |
| What did that cost? | `LlmResponseCompleted.cost` and `usage` |
| Why was it slow? | `LlmFirstTokenReceived.latency` |
| Did a provider fail over? | `LlmFailoverOccurred` |
| Was approval asked, and answered? | `ToolApprovalRequested`, `ToolCallCompleted` |

## Filtering and querying

```dart
_recorder.ofType('tool.');     // everything under a prefix
_recorder.events;              // the buffer, newest first
_recorder.clear();
```

Prefer `include:` at construction over filtering in `build`: an unfiltered
recorder in a busy run wakes the widget on every event, and on a phone that
shows up as jank in the chat itself.

## Ship it behind a switch

A trace panel is a development tool that is also useful in a beta:

- gate it on `kDebugMode`, a hidden gesture, or an internal-user flag;
- never show prompts or answers in a build real users have, since they contain
  whatever they typed;
- for production, export spans instead — the event bus is in-process, and a real
  backend wants OpenTelemetry.

## Instrumenting your own code

```dart
context.publish(GenericEvent(
  id: context.ids.next(),
  timestamp: context.clock.now(),
  type: 'app.note_saved',
  data: {'noteId': note.id},
  runId: context.runId,
));
```

Anything you publish appears in the same panel, which is the cheapest way to
correlate "the app did X" with "the agent then did Y".

## Common mistakes

- Subscribing to `bus.events` directly in a widget and never cancelling; use
  `EventRecorder`, which is bounded and disposable.
- A capacity of 10000 "just in case", on a device with a busy run.
- Leaving the panel reachable in a release build, with prompts visible.
- Reading the panel bottom-up: it is newest first.

## See also

- `agentic-core-tracing-and-events` — the bus, logs and spans underneath
- `agentic-flutter-add-chat-agent` — the runtime that owns the bus
- `agentic-agents-budgets` — the events that explain an early stop
