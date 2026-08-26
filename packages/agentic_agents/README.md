# agentic_agents

Agent orchestration for the
[agentic](https://github.com/v1j4yk/agentic_flutter) framework.

An agent is a bounded loop around a model and a set of tools. This package
provides the loop, the bounds, the conversation state, planner/executor
decomposition, and multi-agent delegation.

## Installation

```yaml
dependencies:
  agentic_agents: ^0.1.0
```

## The basics

```dart
final agent = ToolCallingAgent(
  info: AgentInfo(
    name: 'researcher',
    description: 'Researches technical topics using web search.',
  ),
  model: model,
  tools: registry.select(tags: {'research'}),
  instructions: 'Cite your sources. Say so when you are unsure.',
  budget: AgentBudget.interactive,
);

final result = await agent.run(AgentInput.text('What shipped in Dart 3.11?'));

print(result.text);
print('${result.iterations} steps, ${result.usage.totalTokens} tokens');
```

Or the one-liner, which throws if the run did not complete normally:

```dart
final answer = await agent.ask('What shipped in Dart 3.11?');
```

## Budgets are not optional

The characteristic failure of an agentic system is not a crash. It is a loop
that runs *correctly* and forever: the model calls a tool, gets something
ambiguous back, calls it again with a slightly different argument, and forty
iterations later the user has closed the app and the bill is still growing.

Every individual call succeeded. Only the aggregate is wrong — which is why
bounds belong in the loop, not in a monitor.

```dart
const AgentBudget(
  maxIterations: 10,               // the shape of the loop
  maxTokens: 100000,               // the context
  maxCost: 0.50,                   // the money
  maxDuration: Duration(minutes: 2), // the user's patience
  maxToolCalls: 30,
);
```

Four dimensions because one is never enough: iterations say nothing about a run
that accumulates a 200k-token transcript, and tokens say nothing about a
two-tool ping-pong that costs almost nothing per turn.

`AgentBudget.standard` applies if you do not think about it. `interactive` and
`background` are tuned presets.

### Running out of budget still produces an answer

An agent that hits its iteration limit mid-investigation and returns nothing has
wasted every token it spent. On its **last permitted iteration** the loop
forbids tool calling — the tools stay *described*, so earlier tool calls in the
transcript remain valid — which forces the model to answer with what it has.

When even that is impossible, the result carries an explanation you can show:

```text
stopReason : budgetExhausted
dimension  : iterations
text       : Reached the limit of 1 model calls. The agent was still working;
             raise `maxIterations` or narrow the task.
```

## Results carry the trail

```dart
result.text;           // the answer
result.stopReason;     // completed | budgetExhausted | stopped | cancelled | failed
result.steps;          // every iteration: response, tool calls, results, timing
result.allToolCalls;   // flattened, in order
result.usage;          // tokens across the whole run
result.cost;           // when the model has pricing configured
result.messages;       // what to append to a transcript
```

When an agent gives a wrong answer, the question is always *which step went
wrong*. `steps` answers it without re-running anything.

**Failures return, they do not throw.** A failed run comes back as
`stopReason: failed` with the steps taken up to that point, rather than an
exception that discards the evidence. `result.ensureSuccess()` rethrows for
callers who want the exception.

The one exception is cancellation, which propagates — though the run is still
published to the event bus and recorded on the session on its way out.

## Streaming

```dart
await for (final chunk in agent.stream(input, context: context)) {
  switch (chunk) {
    case AgentToolCallStarted(:final toolName):
      setState(() => status = 'Using $toolName…');
    case AgentTextDelta(:final text):
      setState(() => answer += text);
    case AgentFinished(:final result):
      setState(() => usage = result.usage);
    default:
      // `AgentChunk` is extensible; a default branch is required.
  }
}
```

`AgentChunk` is `base`, not `sealed` — the opposite of `ContentPart` in the
core, deliberately. A content part is sealed because every provider adapter
*must* translate every part. A chunk is different: an agent type the framework
does not ship has updates of its own to report, and a UI that does not recognise
one should ignore it rather than fail to build.

For the simplest case:

```dart
await for (final text in agent.askStream('What is Dart?')) {
  buffer.write(text);
}
```

## Sessions

```dart
final session = AgentSession(strategy: SlidingWindowHistory(maxMessages: 20));

await agent.run(AgentInput.text('What is Dart?'), session: session);
await agent.run(AgentInput.text('And its type system?'), session: session);
// The second run sees the first.

session.totalUsage;   // across every run
session.toJson();     // persist and restore
```

`HistoryStrategy` is the seam where memory plugs in. `agentic_memory` will
supply a summarising strategy and `agentic_rag` a retrieving one; neither
requires a change here.

Trimming strategies also **repair dangling tool results** — a window can slice
between an assistant turn and the tool results answering it, and providers
reject a `tool` message with no matching call. That failure appears only after N
turns and is one of the most confusing in this area.

## Delegation

Handing work to a sub-agent is a tool call. `AgentTool` presents an `Agent` as a
`Tool`, so a supervisor is an ordinary agent whose tools happen to be agents:

```dart
final supervisor = supervisorOver(
  model: model,
  members: [researcher, writer, reviewer],
  instructions: 'Research first, then draft, then review.',
);

final result = await supervisor.run(AgentInput.text('Write a release summary'));
```

Everything already built applies unchanged: argument validation, approval
gating, time budgets, tracing, events, cancellation. A bespoke "crew"
abstraction would duplicate all of it.

Two things delegation genuinely adds:

- **Recursion is bounded.** `maxDepth` (default 3) is tracked through the run
  context, so it survives across agents that know nothing about each other.
  Exceeding it returns a failure telling the model to do the work itself.
- **Budgets do not nest.** A sub-agent has its own budget; a supervisor with a
  100k allowance can spawn five sub-agents that spend 100k each. That is a
  deliberate trade — threading one mutable tracker through independent agents
  would couple them — and the mitigation is that every sub-run publishes its own
  `AgentRunCompleted`, so a cost meter on the bus sees the true total even
  though no single agent does.

A delegate gets a **clean conversation**, not the supervisor's transcript.
Sharing it would leak the supervisor's reasoning into the delegate's context and
multiply everyone's token cost.

## Plan, then execute

```dart
final analyst = PlannerExecutorAgent(
  info: AgentInfo(name: 'analyst', description: 'Researches and reports.'),
  planner: strongModel,          // plans and synthesises
  executor: ToolCallingAgent(    // carries out each step
    info: AgentInfo(name: 'worker', description: 'Carries out one step.'),
    model: cheapModel,
    tools: registry.select(tags: {'research'}),
  ),
  maxSteps: 5,
);
```

A plain loop decides one step at a time, which is right for most work and wrong
for work whose structure the model can see up front. Planning first buys
**visibility** (the plan exists before any work is done, so it can be shown or
rejected), **isolation** (each step runs with a clean context, so step four does
not pay for step one's transcript), and **a cheaper executor**.

It costs an extra model call and commits to a plan made before any evidence was
gathered. Use it when the shape of the work is knowable; use a loop when it is
not.

A planner returning *no* steps is a legitimate outcome — "what is 2 + 2" needs
no plan, and one that invents busywork for it is worse.

## Observability

```dart
bus.on<AgentRunCompleted>().listen((e) => metrics.record(e.usage, e.cost));
bus.on<AgentBudgetExhausted>().listen((e) => alerts.warn(e.explanation));
bus.on<AgentDelegated>().listen((e) => trace.add(e.delegateName, e.depth));
```

`AgentBudgetExhausted` is the one worth alerting on: a rising count means agents
are getting stuck, which is a prompt or tooling problem rather than an
infrastructure one.

Each run also opens a span with `agent.name`, `agent.iterations`,
`agent.tokens` and `agent.stop_reason`.

**Streams are for the caller; events are for observers.** That is not
redundancy — the stream belongs to the screen waiting for this answer, the bus
to a cost meter that cares about every run in the application.

## Testing

```dart
import 'package:agentic_llm/testing.dart';

final model = FakeChatModel.toolCall(
  toolCalls: [ToolCallPart(id: 'c1', name: 'search_web', arguments: {'query': 'dart'})],
  then: 'Dart 3.11 added dot shorthands.',
);

final result = await agent.run(AgentInput.text('What is new?'));

expect(result.iterations, 2);
expect(model.lastRequest.messages.any((m) => m.role == MessageRole.tool), isTrue);
```

No network, no real clock. `FakeClock` drives duration budgets in microseconds.

## Best practices

- **Give each agent the smallest tool set that covers its job.** Selection
  accuracy falls as the set grows, and every spec is re-sent on every iteration.
- **Keep `instructions` stable.** A system prompt that varies per request
  defeats provider prompt caching, usually the largest saving available.
- **Write `AgentInfo.description` for the supervising model**, not for a code
  reviewer — it is the basis on which work gets routed to this agent.
- **Set a tighter budget for interactive work** than for background work.
- **Prefer one capable agent to three coordinating ones.** Delegation costs a
  round trip and a context copy per hop; reach for it when the specialists
  genuinely differ.

## Common mistakes

- **No budget.** See above. This is the one that costs money.
- **Ignoring `stopReason`.** A `budgetExhausted` answer is a best effort, not a
  finished one.
- **Sharing a session between concurrent runs.** Sessions are mutable and owned
  by one conversation.
- **Delegating in a cycle.** `maxDepth` catches it, but a plan is usually the
  better structure.
- **Expecting nested budgets.** They do not nest; watch the bus.

## Example

[`example/agentic_agents_example.dart`](example/agentic_agents_example.dart)
runs offline and demonstrates the loop, streaming, budgets, sessions, delegation
and planning.

## Licence

MIT
