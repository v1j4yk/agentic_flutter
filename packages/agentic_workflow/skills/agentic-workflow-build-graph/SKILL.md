---
name: agentic-workflow-build-graph
description: >-
  Use when building a multi-step flow whose shape is known in advance with
  agentic_workflow: WorkflowBuilder, the node types, edges and branching,
  workflow state and declared reads and writes, validation before execution,
  running a graph and reading WorkflowResult. Read this for "chain these steps",
  "branch on the model's answer", or choosing between a workflow and an agent.
license: MIT
metadata:
  package: agentic_workflow
  min-version: 0.2.0
---

# Building a workflow graph

## Workflow or agent?

| | Agent | Workflow |
|---|---|---|
| Shape of the work | discovered by the model | known when you write it |
| Control | the model chooses each step | you choose; the model fills in content |
| Failure mode | loops, wanders, costs money | a step fails, visibly |
| Validation | at run time | **before it runs** |

If you can draw the flow on paper, it is a workflow. If the steps depend on
what the model finds, it is an agent. Mixed cases nest: an `AgentNode` inside a
graph gives an agent a bounded job with a known place in the flow.

## A graph

```dart
final builder = WorkflowBuilder('triage', description: 'Routes a support ticket.')
  ..add(const StartNode(id: 'start'))
  ..add(StructuredLlmNode(
    id: 'classify',
    model: fastModel,
    buildRequest: (node) => ChatRequest(
      messages: [Message.user(node.state.require<String>('ticket'))],
    ),
    schema: JsonSchema.object(
      properties: {'category': JsonSchema.enumeration(['billing', 'bug', 'other'])},
      required: {'category'},
    ),
    outputKey: 'triage',
    reads: {'ticket'},
  ))
  ..add(SwitchNode(
    id: 'route',
    selector: (node) => node.state.require<Map<String, Object?>>('triage')['category']! as String,
    reads: {'triage'},
  ))
  ..add(const EndNode(id: 'done'));

builder
  ..startAt('start')
  ..edge('start', 'classify')
  ..edge('classify', 'route')
  ..branch('route', {'billing': refundNode, 'bug': fileIssueNode, 'other': replyNode});

final graph = builder.build();   // validates here — or throws
```

## The node types

| Node | Does |
|---|---|
| `StartNode`, `EndNode` | entry and exit |
| `LlmNode`, `StructuredLlmNode` | one model call; structured writes typed JSON into state |
| `ToolNode` | calls a `Tool`, with `buildArguments` from state |
| `AgentNode` | runs a whole agent as a step |
| `ConditionNode`, `SwitchNode` | branch on a predicate or a key |
| `LoopNode` | repeat a body while a predicate holds, bounded by `maxIterations` |
| `ParallelNode`, `MapNode` | fan out, with `maxConcurrency` |
| `TransformNode`, `CustomNode` | your own Dart in the middle of the flow |
| `HumanApprovalNode`, `WaitForEventNode`, `DelayNode` | suspend and resume |

## State, and why `reads` matters

State is a JSON-encodable map. Every node declares what it `reads` and what it
writes, and validation computes availability as an **intersection over every
path into the node** — so a key written on only one branch is reported, rather
than looking safe until the day that branch is not taken.

```dart
node.state.require<String>('ticket');      // throws with the key name if absent
node.state.get<int>('retries');            // null if absent
node.state.getOr('retries', 0);
```

Declare `reads` honestly. It is the input to the check that catches the bug
before the first model call, and skipping it turns a compile-time-ish error
into a run-time one.

## Running it

```dart
const engine = WorkflowEngine(
  budget: WorkflowBudget.standard,
  requireSerialisableState: true,   // fail fast on state that cannot snapshot
);

final result = await engine.run(graph, input: {'ticket': text}, context: context);

result.status;               // completed | suspended | budgetExhausted | cancelled | failed
result.output<String>('reply');
result.executions;           // every node that ran, with durations
result.ensureComplete();     // throws with the reason if it did not finish
```

Graph inputs are declared (`WorkflowGraph(inputs: …)`) and validated before the
run, so a missing input fails immediately with the key named.

## Seeing it

```dart
print(graph.toMermaid());    // paste into any Mermaid renderer
```

Worth doing once for any graph over about six nodes: a picture makes a missing
edge obvious in a way reading builder calls does not.

## Common mistakes

- Not declaring `reads`, then finding the missing-key bug in production.
- Writing a `DateTime`, an enum or a domain object into state; encode it first.
- A jumping node without `jumpTargets`, so the validator thinks the target is
  unreachable.
- Modelling model-driven work as a graph, ending up with fifteen condition nodes
  approximating one agent loop.
- Forgetting `allowCycles` (or a `LoopNode`) and being surprised that a cyclic
  graph is refused.

## See also

- `agentic-workflow-human-approval-and-resume` — suspending and resuming
- `agentic-workflow-fix-validation-errors` — what a GraphViolation means
- `agentic-agents-build-tool-calling-agent` — the other shape of orchestration
