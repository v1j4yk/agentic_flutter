---
name: agentic-agents-budgets
description: >-
  Use when choosing or debugging the limits on an agent run in agentic_agents:
  AgentBudget across iterations, tokens, cost, wall clock and tool calls, the
  interactive/standard/background presets, BudgetTracker, what happens when a
  budget is exhausted, and why budgets do not nest across delegation. Read this
  when an agent loops, costs more than expected, or stops early.
license: MIT
metadata:
  package: agentic_agents
  min-version: 0.2.0
---

# Budgets

## Why they are required rather than optional

The characteristic failure of an agent is not a crash. It is a loop that
quietly spends money: the model calls a tool, dislikes the result, calls it
again, and keeps going while a phone is in someone's pocket. So `AgentBudget`
is a constructor parameter with a default, not a guard you remember to add.

## The presets

```dart
AgentBudget.interactive;  // someone is watching — few iterations, short clock
AgentBudget.standard;     // the default
AgentBudget.background;   // nobody is watching — more iterations, longer clock
```

Start with a preset. Reach for a custom budget when you know a number that
matters:

```dart
const AgentBudget(
  maxIterations: 8,                            // reason/act cycles
  maxTokens: 60000,                            // prompt + completion, whole run
  maxCost: 0.25,                               // needs ModelInfo.pricing to be set
  maxDuration: Duration(seconds: 90),          // wall clock
  maxToolCalls: 20,
);
```

Only `maxIterations` has a default; the rest are opt-in, and
`budget.copyWith(...)` adjusts a preset without restating it.

A per-run override beats the agent's own budget:

```dart
await agent.run(AgentInput(
  message: Message.user('Summarise this thread'),
  budget: AgentBudget.interactive.copyWith(maxCost: 0.05),
));
```

## What exhaustion does

The run **finishes** rather than throwing:

```dart
final result = await agent.run(input);
if (result.stopReason == AgentStopReason.budgetExhausted) {
  // Which dimension ran out, so the message can be honest.
  switch (result.budgetDimension) {
    case BudgetDimension.cost:       tellUser('That question got expensive.');
    case BudgetDimension.duration:   tellUser('That took too long.');
    case BudgetDimension.iterations: tellUser('I could not get there in time.');
    case BudgetDimension.tokens:
    case BudgetDimension.toolCalls:
    case null:                       tellUser('I had to stop early.');
  }
}
```

Two behaviours worth knowing:

- **The last iteration forbids tool calls.** Exhausting a budget yields a
  best-effort answer rather than an unanswered tool call left dangling.
- **An `AgentBudgetExhausted` event is published**, so a dashboard or debug
  panel sees it even when the caller only reads the text.

## Watching spend as it happens

```dart
final tracker = BudgetTracker(budget: AgentBudget.standard, clock: context.clock);
tracker.recordIteration(usage: response.usage, cost: response.cost);
tracker.recordToolCalls(2);

tracker.isExhausted;          // any dimension
tracker.exhausted;            // which one, or null
tracker.explain(BudgetDimension.cost);   // a sentence for a log or a user
tracker.remainingIterations;
tracker.isFinalIteration;     // the loop uses this to withhold tools
```

Time spent waiting for a human does not count against the wall clock —
`HumanWaitLedger` on the context tracks it — so an approval sheet left open
does not eat the budget.

## Budgets do not nest across delegation

A supervisor with five sub-agents can spend six budgets: each `AgentTool` runs
its delegate under that delegate's own budget, and nothing sums them. This is
deliberate — a sub-agent starved by its parent's remaining allowance fails in a
way that is hard to explain — but it means **a delegating agent does not bound
total spend**.

Until shared pools exist, bound it yourself: give delegates small budgets, cap
`AgentTool(maxDepth:)`, and watch `LlmResponseCompleted` on the event bus for
the real total.

## Costs need pricing

`maxCost` can only work if the model knows its prices:

```dart
OpenAiCompatibleChatModel.openAi(
  apiKey: key,
  model: OpenAiModels.balanced,
  pricing: const ModelPricing(inputPerMillion: 0.25, outputPerMillion: 2.0),
);
```

Without `pricing`, `ModelInfo.estimateCost` returns null, `result.cost` is null
and a `maxCost` budget never trips. Local models are genuinely free, so this is
only a gap for hosted ones.

## Common mistakes

- Treating `budgetExhausted` as success because `result.text` is non-empty.
- Setting `maxIterations: 1` for a tool-using agent: one iteration leaves no
  turn in which to use the tool result.
- Expecting `maxCost` to work without `pricing`.
- Assuming a supervisor's budget bounds its whole team.
- Using a `background` budget on a screen someone is watching.

## See also

- `agentic-agents-build-tool-calling-agent` — the loop these bound
- `agentic-agents-multi-agent-delegation` — where budgets stop nesting
- `agentic-core-cancellation-and-context` — the other way a run stops
