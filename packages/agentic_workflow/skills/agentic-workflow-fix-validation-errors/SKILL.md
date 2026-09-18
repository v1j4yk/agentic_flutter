---
name: agentic-workflow-fix-validation-errors
description: >-
  Use when WorkflowGraph.build() throws in agentic_workflow: reading a
  GraphViolation, and fixing unreachable nodes, missing edges, keys nothing
  writes, jump targets, cycles and duplicate ids. Read this for "my workflow
  will not build", "reads a key nothing writes", or "node is unreachable".
license: MIT
metadata:
  package: agentic_workflow
  min-version: 0.2.0
---

# Fixing graph validation errors

## Why it refuses to exist

`WorkflowGraph` validates on construction and refuses to be built in an invalid
state — not a `validate()` a caller may forget. The failure you get at `build()`
is the failure you would otherwise get three model calls into a production run,
with a partial charge and no answer.

Each problem is a `GraphViolation` with a `rule`, a `message` and usually a
`nodeId`. Read the rule first: it names the class of mistake.

## The violations, and what they mean

**`reads a key nothing writes`** — the node declares `reads: {'x'}` but no path
into it writes `x`.

Availability is computed as an **intersection over every incoming path**, so a
key written on one branch only is reported rather than looking safe until the
day the other branch is taken. Fix by writing the key on every path, declaring
it as a graph input, or reading it defensively with `state.getOr('x', default)`
and dropping it from `reads`.

```dart
WorkflowGraph(
  id: 'triage',
  nodes: nodes,
  edges: edges,
  inputs: {'ticket': JsonSchema.string()},   // now `ticket` is available everywhere
);
```

**`unreachable node`** — nothing leads to it from the start node.

Usually a missing `edge(...)`, or a `branch(...)` whose case label does not
match what the `SwitchNode` selector returns. Labels are compared as strings:
a selector returning `'billing'` needs the key `'billing'`, not `'Billing'`.

**`jump target not declared`** — a node that jumps must declare `jumpTargets`,
because reachability follows edges. Without it the target looks unreachable and
the graph is refused.

**`cycle`** — an edge leads back to an earlier node. Either use a `LoopNode`,
which is bounded by `maxIterations`, or pass `allowCycles: true` and take
responsibility for termination yourself. A workflow that cannot terminate is
the failure this rule exists to prevent.

**`duplicate node id`** / **`edge references unknown node`** — a typo, or a node
added twice. Node ids are the graph's vocabulary; keep them short and literal.

**`no start node`** — call `builder.startAt('start')`, or pass `startNodeId`.

## Working through it

1. Read the `rule` and the `nodeId`.
2. Draw the graph: `print(graph.toMermaid())` for a graph that builds, or the
   builder calls for one that does not. Most violations are obvious in a
   picture.
3. Check the branch labels against the selector's return values.
4. Check `reads` against what earlier nodes actually write — including on the
   *other* branch.
5. Build in a test, not in an app. A graph is pure, so validation is a unit test
   that runs in microseconds:

```dart
test('the triage graph is valid', () {
  expect(buildTriageGraph, returnsNormally);
});
```

That test is worth writing for every graph you ship: it turns a class of
production failure into a red build.

## Related failures at run time

Validation cannot catch everything. These surface when the graph runs:

- **`requireSerialisableState`** — a node wrote something that cannot be JSON
  encoded. Enable it in development to fail at the write rather than at the
  suspension.
- **Missing input** — inputs are validated against their schemas at `run`, so a
  missing or wrong-typed input fails immediately with the key named.
- **Budget exhausted** — `WorkflowBudget` bounds the whole run; a loop that
  never settles stops here.

## Common mistakes

- Declaring `reads` for keys a node does not read, which invents violations.
- *Not* declaring `reads`, which hides real ones — the declaration is the input
  to the check.
- Branch labels that differ in case or whitespace from the selector's output.
- Reaching for `allowCycles: true` to silence a violation, rather than using a
  `LoopNode` with a bound.

## See also

- `agentic-workflow-build-graph` — the builder and the node types
- `agentic-workflow-human-approval-and-resume` — suspending and resuming
