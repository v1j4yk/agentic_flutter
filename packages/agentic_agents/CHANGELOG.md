# Changelog

## 0.1.1

- Shortened the package description to the 60-180 character window pana
  scores against. Search engines truncate anything longer, so the ten points
  it withheld were pointing at a real defect: the useful half of the sentence
  was never being shown.

## 0.1.0

Initial release of the agent layer.

### Added

- **Contract** — `Agent`, `AgentInfo`, `AgentInput`, `AgentResult`, `AgentStep`
  and `AgentStopReason`. Failures return as a result carrying the step trail
  rather than throwing; `ensureSuccess` rethrows for callers who want the
  exception. Cancellation propagates.
- **Budgets** — `AgentBudget` and `BudgetTracker` bound a run by iterations,
  tokens, cost, wall clock and tool calls. On the last permitted iteration the
  loop forbids tool calling so the run still produces an answer, and an
  exhausted budget explains itself in text that can be shown to a user.
- **The loop** — `ToolCallingAgent`, with streaming, early-stop conditions,
  per-run budget overrides, tracing and events.
- **Sessions** — `AgentSession` with `HistoryStrategy`, `KeepAllHistory`,
  `SlidingWindowHistory` and `CharacterBudgetHistory`. Trimming repairs dangling
  tool results, which providers otherwise reject. Sessions serialise for
  persistence.
- **Streaming** — `AgentChunk` and its variants, extensible so that agent types
  the framework does not ship can report updates of their own.
- **Delegation** — `AgentTool` presents an agent as a tool, with depth bounding
  through the run context; `supervisorOver` builds a supervisor over a team.
- **Planning** — `PlannerExecutorAgent`, `Plan` and `PlanStep`, decomposing a
  request into bounded steps that each run with a clean context.
- **Events** — `AgentRunStarted`, `AgentStepCompleted`, `AgentRunCompleted`,
  `AgentBudgetExhausted` and `AgentDelegated`.

### Notes

`HistoryStrategy.select` is asynchronous and receives the turn about to be sent.
Both were needed the moment a real memory backend was built against the seam:
summarising and retrieving are asynchronous, and recall must be driven by the
question just asked rather than by the previous one — a synchronous,
history-only signature recalls nothing at all on the first turn.
