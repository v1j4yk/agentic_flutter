---
name: agentic-agents-multi-agent-delegation
description: >-
  Use when one agent should hand work to another in agentic_agents: AgentTool
  for delegation, supervisorOver for a team behind one entry point,
  PlannerExecutorAgent for decomposing a task, delegation depth limits, and
  what delegation does and does not inherit (approval and tracing yes, budgets
  no). Read this before building a multi-agent system, including to decide
  whether you need one.
license: MIT
metadata:
  package: agentic_agents
  min-version: 0.2.0
---

# Multi-agent delegation

## First: do you need a second agent?

Usually not. A second agent is worth it when a task needs a **different system
prompt, a different tool set, or its own context** — not merely because a task
has steps. One agent with five tools beats five agents with one tool each: it
is cheaper, easier to debug, and has no hand-off to get wrong.

Good reasons to split:

- Tool sets that must not mix (a support agent must not hold `issue_refund`).
- A long sub-task whose intermediate reasoning should not pollute the main
  conversation's context.
- A specialist prompt that would dilute a general one.

## Delegation is a tool call

Handing work to a sub-agent is modelled as a tool. That is the whole mechanism:
no new concept, and delegation inherits argument validation, approval gating,
tracing, events and cancellation unchanged.

```dart
final researcher = ToolCallingAgent(
  info: AgentInfo(name: 'researcher', description: 'Finds and cites sources.'),
  model: model,
  tools: registry.select(tags: {'research'}),
  budget: AgentBudget.background,
);

final writer = ToolCallingAgent(
  info: AgentInfo(name: 'writer', description: 'Writes the final answer.'),
  model: model,
  tools: ToolRegistry(tools: [
    // The researcher, as a tool the writer may call.
    AgentTool(researcher, maxDepth: 2, budget: AgentBudget.background),
  ]).all,
  budget: AgentBudget.standard,
);
```

`AgentTool` derives its `ToolSpec` from the delegate's `AgentInfo`, so **the
delegate's `description` is the prompt that decides whether it gets used**.
Write it as a job posting: what it does, and when to call it.

`maxDepth` stops the obvious disaster — A delegating to B delegating to A. The
current depth travels in the context under `kDelegationDepthKey`.

## A team behind one entry point

```dart
final support = supervisorOver(
  model: model,
  members: [billingAgent, technicalAgent, accountAgent],
  name: 'support',
  description: 'Answers customer questions by routing to a specialist.',
  instructions: 'Route to exactly one specialist. Do not answer yourself.',
);

final result = await support.run(AgentInput.text('I was charged twice'));
```

`supervisorOver` builds a `ToolCallingAgent` whose tools are its members. It is
routing, not hand-off: the supervisor keeps control and the specialist's answer
comes back as a tool result.

## Decomposing a task

```dart
final agent = PlannerExecutorAgent(
  info: AgentInfo(name: 'analyst', description: 'Answers multi-part questions.'),
  planner: model,            // writes the plan
  executor: workerAgent,     // runs each step, with its own tools
  maxSteps: 5,
  synthesise: true,          // one final pass that writes the answer
);
```

Each step runs in isolation, so a long research task does not carry every
intermediate result into the next prompt. Streaming yields `AgentPlanReady` and
`AgentPlanStepStarted`, which is what a progress UI should render.

Use it when the shape of the work is unknown until the model looks at it. When
the shape is known in advance, a workflow graph is the better tool: it validates
before it runs and can suspend for approval.

## What delegation does not do

- **Budgets do not nest.** Each delegate runs on its own budget; nothing sums
  them. A supervisor with five members can spend six budgets. Watch
  `AgentDelegated` and `LlmResponseCompleted` events for the real total.
- **No control transfer.** The caller always gets control back; the delegate
  cannot take over the conversation.
- **No shared session.** A delegate sees the task it is given, not the parent's
  transcript — which is the point, and also why the task text must be complete.

## Debugging a team

```dart
bus.on<AgentDelegated>().listen((e) => print('${e.agentName} → ${e.delegateName} (depth ${e.depth})'));
```

When a delegate is never called, it is almost always its `description`. When it
is called for the wrong thing, say in the supervisor's `instructions` what each
member is *not* for.

## Common mistakes

- Splitting into agents to model steps, where one agent with more tools is
  simpler and cheaper.
- A vague `AgentInfo.description` on a delegate, then blaming tool choice.
- No `maxDepth`, then a delegation cycle that burns budget until it trips.
- Assuming the parent's budget bounds the team's spend.
- Passing a whole conversation as the delegated task instead of a self-contained
  instruction.

## See also

- `agentic-agents-build-tool-calling-agent` — the agent being delegated to
- `agentic-agents-budgets` — why the totals surprise people
- `agentic-workflow-build-graph` — when the shape is known in advance
