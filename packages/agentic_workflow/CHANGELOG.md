# Changelog

## 0.1.0

Initial release of the workflow engine.

### Added

- **Graph** — `WorkflowGraph` validates on construction and refuses to exist in
  an invalid state, reporting every problem at once: missing inputs,
  unreachable nodes, undeclared cycles, ambiguous routes, concurrent writes to
  one key, and unknown edge or jump targets. Key availability is computed as an
  intersection over every path in, so a value written on only one branch is
  caught. `WorkflowBuilder` assembles chains and branches; `toMermaid` renders a
  diagram from the real graph.
- **Nodes** — start, end, custom, transform, condition, switch, LLM, structured
  LLM, agent, tool, parallel, map, loop, delay, human approval and generic wait.
  `WorkflowNode` is `base`, so domain-specific nodes are ordinary subclasses.
- **State** — `WorkflowState`, immutable, with declared access and a
  serialisability check that names the offending key.
- **Engine** — `WorkflowEngine` with per-run budgets on steps, per-node visits
  and wall clock; write-schema checking; failures returned with the trail rather
  than thrown; cancellation propagated.
- **Suspension** — a run pauses into a JSON `WorkflowSnapshot` that survives the
  process, and `resume` restores it, keeping the original run identifier.
  Resume values are validated against the suspension's schema, and resuming into
  a changed graph is refused.
- **Events** — `WorkflowStarted`, `WorkflowNodeStarted`,
  `WorkflowNodeCompleted`, `WorkflowSuspended` and `WorkflowCompleted`.
