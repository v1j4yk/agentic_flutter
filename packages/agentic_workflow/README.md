# agentic_workflow

A graph workflow engine for the
[agentic](https://github.com/v1j4yk/agentic_flutter) framework.

For work whose shape is known in advance, where an agent loop is the wrong tool:
a directed graph of typed nodes, checked before it runs, able to pause for a
human and resume days later on another device.

## Installation

```yaml
dependencies:
  agentic_workflow: ^0.1.0
```

## When a graph, and when an agent

An agent decides one step at a time. That is right when the path is unknown and
wrong when it is not — a five-step process with two branches does not need a
model to rediscover its own shape on every run, and cannot be reviewed, drawn or
tested when it does.

Use a workflow when the steps are known and an agent for the steps that are not.
`AgentNode` puts one inside the other.

## Validation before execution

A workflow that fails three minutes in because node seven reads a key nobody
writes has wasted three minutes, some money, and — if it had side effects — left
the world half-changed. Every one of those failures is knowable from the graph
alone.

So `WorkflowGraph` validates on construction and **refuses to exist** in an
invalid state:

```dart
WorkflowGraph(
  id: 'broken',
  inputs: {'ticket': JsonSchema.string()},
  nodes: [start, summarise, end],
  edges: [...],
);
// ValidationException: [summarise] `summarise` reads `document`, but no node
// guaranteed to run before it writes that key.
```

What it catches:

| Rule | Caught |
|---|---|
| `missing-input` | A node reads a key nothing upstream writes |
| `unreachable` | A node no path reaches |
| `cycle` | A loop that was not declared with `allowCycles` |
| `ambiguous-route` | Two unlabelled edges leaving one node |
| `concurrent-write` | Two parallel branches writing the same key |
| `unknown-edge-target`, `unknown-jump-target` | An edge or jump to nothing |
| `duplicate-id`, `duplicate-label`, `no-start` | Structural mistakes |

Every problem is reported at once, not just the first: a graph with four
mistakes should take one fix cycle, not four.

Key availability is computed as an **intersection** over every path into a node,
not a union. A value written on one branch and not another is precisely the bug
this is looking for.

## State

Nodes share an immutable map and declare what they touch:

```dart
TransformNode(
  id: 'double',
  reads: {'n'},
  writes: {'doubled': JsonSchema.integer()},
  transform: (context) async => {'doubled': context.require<int>('n') * 2},
);
```

Wired ports would validate slightly better and are miserable to author — adding
one field means rewiring every edge downstream. Declared access over a shared
bag recovers most of the checking for a fraction of the cost.

A graph declares its **inputs**, which are its parameters:

```dart
WorkflowGraph(
  id: 'triage',
  inputs: {'ticket': JsonSchema.string()},
  // ...
);

await engine.run(graph, input: {'ticket': text});
// A missing or wrongly-shaped input is rejected at the boundary, naming it.
```

**State must be JSON-encodable.** That is not arbitrary: it is what makes
suspension real rather than a pause that dies with the app. `WorkflowState`
finds an offending value and names the key.

## Nodes

| Node | Does |
|---|---|
| `StartNode`, `EndNode` | Entry and exit |
| `CustomNode` | Runs a closure — the escape hatch, and the most-used node |
| `TransformNode` | Reads keys, writes keys, no control flow |
| `ConditionNode` | Branches `true`/`false` |
| `SwitchNode` | Branches on a returned label |
| `LlmNode`, `StructuredLlmNode` | Asks a model, for prose or a schema-shaped record |
| `AgentNode` | Runs an agent |
| `ToolNode` | Invokes one tool through the executor |
| `ParallelNode` | Runs branches concurrently, merges writes |
| `MapNode` | Runs one body per item of a collection |
| `LoopNode` | Jumps back while a condition holds |
| `DelayNode` | Waits, on the injected clock |
| `HumanApprovalNode`, `WaitForEventNode` | Suspends |

`WorkflowNode` is `base`, so a workflow that needs a node for its own domain
just writes one.

A workflow that cannot call ordinary code for the ordinary parts forces
everything through the model, which is slower, less reliable and far more
expensive — hence `CustomNode` and `TransformNode` being first-class rather than
grudging.

## Suspension is the feature

Everything else here could be a function call. This cannot: the wait is
unbounded, it outlives the process, and the answer arrives from outside.

```dart
final result = await engine.run(graph, input: input);

if (result.status == WorkflowStatus.suspended) {
  await db.save(jsonEncode(result.snapshot!.toJson()));
  showApproval(result.suspension!.message, result.suspension!.payload);
}

// The next morning, possibly on another device:
final snapshot = WorkflowSnapshot.fromJson(jsonDecode(await db.load()));
final finished = await engine.resume(
  graph,
  snapshot,
  resumeValue: {'approved': true, 'comment': 'looks right'},
);
```

The resumed run keeps its original `runId`: one run, paused, not two.

The resume value is validated against the suspension's schema **before** the
node sees it, so a malformed decision is rejected at the boundary rather than
silently read as a refusal.

Resuming into a graph whose shape has changed is **refused**, naming the node
that no longer exists. Silently continuing is how a run walks into a node that
was deleted.

Suspending inside a `ParallelNode` is also refused: a snapshot of one arm of a
fan-out would quietly lose the others.

## Budgets

```dart
const WorkflowEngine(
  budget: WorkflowBudget(
    maxSteps: 100,
    maxNodeVisits: 25,
    maxDuration: Duration(minutes: 10),
  ),
);
```

The same discipline as an agent budget, for the same reason. `maxNodeVisits`
earns its place by **naming the culprit**:

```text
`spin` has run 4 times, which is the per-node limit.
The graph is looping without converging.
```

A bare step count tells an author that something looped, not what.

## Failures return the trail

```dart
result.status;      // completed | suspended | budgetExhausted | cancelled | failed
result.executions;  // every node: which, how long, what it wrote
result.error;       // annotated with the graph, node and step
result.output<T>('key');
result.ensureComplete();   // rethrows, for callers that want the exception
```

A node failure comes back as a result, not an exception, so the steps taken
before it survive. Cancellation propagates.

A node that writes a value contradicting its declared schema fails **where it
happened**, not wherever the value is later read.

## Diagrams

```dart
print(graph.toMermaid());
// flowchart TD
//   classify["classify<br/><i>llm</i>"]
//   route -->|urgent| draft
```

Generated from the real graph, so it cannot drift the way a hand-drawn one does.
A workflow nobody can see is a workflow nobody trusts.

## Building

```dart
final graph = (WorkflowBuilder('triage')
      ..chain([const StartNode(), classify])
      ..branch('classify', {'urgent': escalate, 'routine': reply})
      ..add(const EndNode())
      ..edge('escalate', 'end')
      ..edge('reply', 'end'))
    .build();
```

The literal form suits a diagram-shaped workflow; the builder suits a chain,
where every edge otherwise restates two identifiers the order already implies.

## Testing

No network, no real clock:

```dart
final clock = FakeClock();
final pending = engine.run(graph, context: AgenticContext.root(clock: clock));
await clock.advance(const Duration(hours: 2));   // a two-hour delay, instantly
```

Because nodes are plain objects, most workflow logic is testable by calling
`node.execute(...)` directly with a `NodeContext`.

## Best practices

- **Declare `reads` and `writes` honestly.** Validation believes them.
  Over-declaring gives a false failure at build time; under-declaring hides a
  real one until the run. The first is much the cheaper mistake.
- **Keep nodes small.** A node that does two things cannot be reused or
  validated for either.
- **Prefer edges to jumps.** A graph whose flow is mostly `goTo` cannot be read
  as a diagram, which was the point of a graph.
- **Drop large intermediates** with `WorkflowState.remove` once nothing reads
  them: everything in state is serialised into every snapshot.
- **Turn on `requireSerialisableState`** while developing a workflow that
  suspends.

## Common mistakes

- **`JsonSchema.object()` for "any object".** That is a *closed* object and
  matches only `{}`. Use `JsonSchema.anyObject()`.
- **Forgetting to declare `inputs`.** The graph will refuse to build, which is
  the system working — declare them.
- **Jumping without declaring `jumpTargets`.** Reachability follows edges; a
  jump is not an edge, so the target looks unreachable.
- **Putting a live object in state.** It cannot be snapshotted, and the failure
  otherwise appears at suspension time.
- **Suspending inside a parallel branch.** Move it outside the fan-out.
- **No budget on a cyclic graph.** See above.

## Example

[`example/agentic_workflow_example.dart`](example/agentic_workflow_example.dart)
runs offline and demonstrates validation, branching, fan-out, a human approval
persisted as JSON and resumed, and a budget bounding a runaway loop.

## Licence

MIT
