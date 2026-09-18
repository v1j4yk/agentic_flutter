# Phase 3b — Feature innovation: orchestration layer

`agentic_agents` · `agentic_workflow` · `agentic_memory`

Entry format as in [03a](03a-features-foundation.md).

---

## `agentic_agents` — 15 features

### AGENTS-1 · Handoffs — **Must Have**

| Complexity | Effort | Breaking | Deps |
|---|---|---|---|
| Medium | 1.5 wk | No | none |

**Why.** Delegation (`AgentTool`) returns to the caller. Customer-support
and triage flows need *transfer of control*: the billing agent now owns the
conversation. OpenAI Agents SDK, Google ADK and Microsoft Agent Framework all
model this explicitly; users coming from them look for it.

**Use cases.** Triage → billing / technical / sales; a language-routing front
desk; escalation to a human queue.

**API.**

```dart
final triage = ToolCallingAgent(
  info: AgentInfo(name: 'triage', description: 'Routes the customer.'),
  model: model,
  handoffs: [
    Handoff.to(billing, when: 'Questions about invoices or refunds'),
    Handoff.to(tech,    when: 'App errors or crashes',
               inputFilter: HandoffFilter.dropToolCalls),
  ],
  budget: AgentBudget.interactive,
);

final team = AgentTeam(entry: triage, members: [billing, tech]);
final result = await team.run(AgentInput.text('I was charged twice'), session: s);
result.finalAgent.name; // 'billing'
```

Handoffs are still tool calls on the wire (so approval, tracing and budgets
still apply); the difference is that the runner switches the active agent
instead of returning a result.

---

### AGENTS-2 · Guardrails with tripwires — **Must Have**

| Complexity | Effort | Breaking | Deps |
|---|---|---|---|
| Medium | 1.5 wk | No | none |

**Why.** Prompt injection, off-topic use and policy violations must stop a run
before it spends money or takes actions. Guardrails that run *in parallel* with
the first model call keep latency low.

**API.**

```dart
ToolCallingAgent(
  …,
  guardrails: AgentGuardrails(
    input: [
      Guardrail.llm(classifier, rubric: 'Is this about our banking app?', tripOn: 'no'),
      Guardrail.check(PromptInjectionDetector()),
    ],
    output: [Guardrail.schema(answerSchema), Guardrail.check(PiiCheck())],
    toolCalls: [Guardrail.forTool('transfer_funds', maxAmount(500))],
    mode: GuardrailMode.parallelWithFirstCall,
  ),
);
// A trip yields AgentStopReason.guardrailTripped and an AgentGuardrailTripped event.
```

(Adding an enum value to `AgentStopReason` breaks exhaustive switches; ship in 0.3.)

---

### AGENTS-3 · Durable agent runs (checkpoint and resume) — **Must Have**

| Complexity | Effort | Breaking | Deps |
|---|---|---|---|
| High | 2.5 wk | No | reuses `SessionStore` / `agentic_sqlite` |

**Why.** On mobile the OS kills apps mid-run. `AgentSession` persists history
but not an in-flight step (pending tool calls, awaiting approval, budget spent).
Workflows already have snapshots; agents should too.

**API.**

```dart
final runner = DurableAgentRunner(agent, store: SqliteRunStore(db));
final handle = await runner.start(input, sessionId: 's1');   // checkpoints after every step
// … app killed, relaunched …
for (final pending in await runner.pending()) {
  await runner.resume(pending.runId);                        // idempotent tool calls not repeated (TOOLS-8)
}
```

---

### AGENTS-4 · Interrupts (human input mid-run) — **Must Have**

| Complexity | Effort | Breaking | Deps |
|---|---|---|---|
| Medium | 1 wk | No | builds on AGENTS-3 |

**Why.** Approval is yes/no. Real flows need "which account?", "edit this draft
before sending", or an MCP elicitation form. LangGraph's `interrupt()` is
among its most-used features.

**API.**

```dart
final answer = await invocation.interrupt(
  InterruptRequest.form(
    title: 'Confirm the transfer',
    schema: JsonSchema.object({'amount': JsonSchema.number(), 'note': JsonSchema.string()}),
    initial: {'amount': 120},
  ),
);
// Streams AgentInterrupted; the UI renders a form; runner.resume(runId, response: …)
```

---

### AGENTS-5 · Shared budgets across delegation trees — **High Value**

| Complexity | Effort | Breaking | Deps |
|---|---|---|---|
| Low | 4 d | No (opt-in) | none |

**Why.** `doc/architecture.md` records that budgets do not nest. A supervisor
with five workers can spend six budgets; for a product with per-user cost
limits that is a bug.

**API.** `AgentBudget.shared(pool)` / `BudgetPool(maxCost: 0.50)` placed in the
`AgenticContext`; child trackers draw from the pool and exhaustion propagates.

---

### AGENTS-6 · Context compaction — **Must Have**

| Complexity | Effort | Breaking | Deps |
|---|---|---|---|
| Medium | 1 wk | No | none |

**Why.** Long tool-using runs overflow context mostly with stale tool results.
Clearing old tool outputs and summarising early turns is now standard (Claude
Code, OpenAI Agents SDK sessions, LangChain middleware).

**API.**

```dart
AgentSession(strategy: CompactingHistory(
  maxTokens: 60000,                    // uses LLM-6 token counting
  clearToolResultsOlderThan: 3,        // replaces with "[result elided: 4.1 kB]"
  summariseWith: flashLite,
  keep: {MessageRole.system},
));
```

---

### AGENTS-7 · Parallel fan-out to sub-agents — **High Value**

| Complexity | Effort | Breaking | Deps |
|---|---|---|---|
| Low | 4 d | No | none |

**Why.** Research-style tasks (compare five vendors) are embarrassingly parallel.
Parallel tool calls exist; an explicit fan-out and synthesise helper is clearer
and budget-aware.

**API.** `final results = await AgentFanOut(worker, maxConcurrency: 3).run(tasks,
budgetEach: AgentBudget.background)`.

---

### AGENTS-8 · Deep-agent harness — **High Value**

| Complexity | Effort | Breaking | Deps |
|---|---|---|---|
| High | 2.5 wk | No | `agentic_toolkit` (TOOLS-6) |

**Why.** Long-horizon agents (Claude Code, Deep Research, LangChain "deep
agents") share a recipe: a planning to-do tool, a virtual file system for
scratch notes, sub-agents with isolated context, and a detailed system prompt.
Packaging the recipe removes weeks of tuning.

**API.**

```dart
final agent = DeepAgent(
  model: flagship,
  tools: myTools,
  subAgents: [researcher, critic],
  workspace: VirtualWorkspace.inMemory(),   // read_file / write_file / ls / edit_file tools
  todo: true,                               // write_todos tool + UI stream
  budget: AgentBudget.background,
);
```

---

### AGENTS-9 · Agent Skills runtime — **Must Have** (strategic)

| Complexity | Effort | Breaking | Deps |
|---|---|---|---|
| Medium | 1.5 wk | No | `yaml`; lives in `agentic_skills` (Phase 4) with a hook here |

**Why.** Agent Skills (folders containing `SKILL.md` plus resources, loaded
progressively) are now an open format adopted by multiple agent products. A
Dart runtime lets apps ship domain skills as assets and lets agents discover them
by description, keeping the base prompt small.

**API.**

```dart
final skills = await SkillLibrary.fromAssets('assets/skills/');
ToolCallingAgent(
  …,
  skills: skills,  // injects name+description; `load_skill` tool reads the body on demand
);
```

---

### AGENTS-10 · Reflection and self-critique loop — **Future**

| Complexity | Effort | Breaking | Deps |
|---|---|---|---|
| Low | 4 d | No | none |

**API.** `ReflectingAgent(inner, critic: model, rubric: '…', maxRevisions: 2)` —
a `DelegatingAgent` that critiques and revises final answers.

---

### AGENTS-11 · A2A remote agents — **High Value**

| Complexity | Effort | Breaking | Deps |
|---|---|---|---|
| High | see `agentic_a2a` (Phase 4) | No | — |

**Why.** A remote agent published over the Agent2Agent protocol should be usable
as a local `Agent`, and a local agent should be publishable, in the same way
`agentic_mcp` does for tools.

**API.** `final remote = await A2aAgent.connect(Uri.parse('https://…/.well-known/agent-card.json'));`
— then `AgentTool(remote)` or `Handoff.to(remote)`.

---

### AGENTS-12 · Agent state and typed outputs — **High Value**

| Complexity | Effort | Breaking | Deps |
|---|---|---|---|
| Medium | 1 wk | No | CORE-6 |

**Why.** `AgentResult.decodeJson` is untyped. A typed agent is easier to compose
into workflows and UIs.

**API.** `TypedAgent<Itinerary>(agent, schema: ItinerarySchema())` →
`Future<TypedAgentResult<Itinerary>>`, with automatic repair turns on
validation failure.

---

### AGENTS-13 · Agent lifecycle hooks — **High Value**

| Complexity | Effort | Breaking | Deps |
|---|---|---|---|
| Low | 3 d | No | none |

**Why.** `DelegatingAgent` wraps the whole run; developers also want
`beforeModelCall`, `afterToolCall` and `onStep` to mutate requests (inject date,
redact) without subclassing. LangChain v1 middleware and ADK callbacks
established the expectation.

**API.** `ToolCallingAgent(hooks: [AgentHooks(beforeModel: (req, ctx) =>
req.withMessages([...]), afterTool: (call, result, ctx) => result)])`.

---

### AGENTS-14 · Agent registry and cards — **Future**

| Complexity | Effort | Breaking | Deps |
|---|---|---|---|
| Low | 3 d | No | none |

**Why.** Apps with many agents need discovery by capability, and A2A needs an
agent card. `AgentInfo` is most of one.

**API.** `AgentInfo.toCard(skills: …, inputModes: …)`,
`AgentRegistry.find(tags: {'finance'})`.

---

### AGENTS-15 · Computer-use and browser agent — **Experimental**

| Complexity | Effort | Breaking | Deps |
|---|---|---|---|
| Very High | 4 wk | No | desktop only; Playwright via MCP or CDP |

**Why.** Desktop Flutter apps (macOS, Windows, Linux) can host an agent that
operates a browser or the OS with screenshots. The model APIs exist; a safe
harness with per-action approval does not in Dart.

**API.** `ComputerUseAgent(model: …, environment: BrowserEnvironment.cdp(…),
approve: ApprovalPolicy.everyAction)`.

---

## `agentic_workflow` — 14 features

### WF-1 · Sub-workflows — **Must Have**

| Complexity | Effort | Breaking | Deps |
|---|---|---|---|
| Medium | 1 wk | No | none |

**Why.** Graphs past ~15 nodes become unreadable. Composition is the standard
answer (LangGraph subgraphs, n8n sub-workflows).

**API.**

```dart
final enrich = WorkflowBuilder('enrich')…build();
builder.add(SubWorkflowNode(
  id: 'enrich_lead',
  graph: enrich,
  inputs: {'company': 'lead.company'},
  outputs: {'enriched': 'lead.profile'},
));
```

Snapshots nest, so a sub-workflow suspended for approval resumes correctly.

---

### WF-2 · Per-node retry, timeout and error edges — **Must Have**

| Complexity | Effort | Breaking | Deps |
|---|---|---|---|
| Low | 4 d | No | none |

**Why.** An LLM node hitting a 503 should retry; a tool that keeps failing should
route to a fallback branch instead of failing the run.

**API.** `LlmNode(id: 'draft', retry: RetryPolicy.background, timeout:
30.seconds)`; `builder.onError('draft', to: 'fallback_template')`.

---

### WF-3 · Typed state — **High Value**

| Complexity | Effort | Breaking | Deps |
|---|---|---|---|
| High | 2 wk | No (typed layer over the JSON map) | CORE-6 |

**Why.** String keys are where workflow bugs live. Validation already computes
data flow; typed channels would turn those findings into compile errors.

**API.**

```dart
final topic   = StateKey<String>('topic');
final outline = StateKey<Outline>('outline', codec: OutlineSchema());
LlmNode.typed(id: 'plan', reads: [topic], writes: outline, prompt: (s) => 'Outline ${s[topic]}');
```

---

### WF-4 · Declarative workflow definitions (JSON / YAML) — **Must Have** (strategic)

| Complexity | Effort | Breaking | Deps |
|---|---|---|---|
| High | 2.5 wk | No | `yaml` |

**Why.** This is the prerequisite for a visual builder, for server-delivered
workflows (change an app's behaviour without a store release), for sharing
workflows in a marketplace, and for AI assistants generating workflows.

**API.**

```yaml
id: support_triage
version: 3
inputs: [ticket]
nodes:
  - {id: classify, type: structured_llm, model: fast, schema: '#/schemas/triage'}
  - {id: route, type: switch, on: 'triage.category', cases: {billing: refund, bug: file_issue}}
  - {id: refund, type: human_approval, prompt: 'Refund {{ticket.amount}}?'}
```

```dart
final graph = WorkflowDefinition.parseYaml(src).build(
  registry: NodeRegistry.standard()..register('file_issue', fileIssueFactory),
  models: {'fast': flashLite},
);
```

Unknown node types and missing models fail at `build`, keeping validation before
execution. A JSON Schema for the format enables IDE completion.

---

### WF-5 · Time travel: fork from any checkpoint — **High Value**

| Complexity | Effort | Breaking | Deps |
|---|---|---|---|
| Medium | 1.5 wk | No | snapshot store |

**Why.** Debugging "why did step 7 go wrong" means re-running from step 6 with a
changed prompt, not from the beginning.

**API.** `engine.history(runId)` → checkpoints;
`engine.fork(checkpointId, patch: {'draft.tone': 'formal'})`.

---

### WF-6 · Durable timers and scheduled triggers — **High Value**

| Complexity | Effort | Breaking | Deps |
|---|---|---|---|
| Medium | 1.5 wk | No | on Flutter: `workmanager` in an optional bridge |

**Why.** `DelayNode` waits in memory. "Remind me in 3 days", "follow up if no reply
by Friday" and daily digests need timers that survive process death, and
triggers that start runs.

**API.** `DelayNode(until: …, durable: true)`; `WorkflowTrigger.cron('0 8 * *
MON-FRI')`, `WorkflowTrigger.event('email.received')`; a `WorkflowScheduler`
that persists wake-ups in the snapshot store.

---

### WF-7 · Streaming node output — **Must Have**

| Complexity | Effort | Breaking | Deps |
|---|---|---|---|
| Low | 4 d | No | none |

**Why.** An LLM node inside a workflow currently shows nothing until it completes.
Chat-like UIs over workflows need token deltas with the node ID.

**API.** `engine.stream(graph, input)` yields `WorkflowNodeDelta(nodeId,
textDelta)` alongside the existing events.

---

### WF-8 · Visual graph export and live overlay — **High Value**

| Complexity | Effort | Breaking | Deps |
|---|---|---|---|
| Low | 4 d | No | none |

**Why.** `toMermaid()` exists. Add execution overlays (visited, current,
failed, durations) and a Flutter widget that renders the graph live.

**API.** `graph.toMermaid(highlight: result.trace)`; `WorkflowGraphView(graph,
events: engine.events)` in `agentic_flutter`.

---

### WF-9 · Human task inbox — **High Value**

| Complexity | Effort | Breaking | Deps |
|---|---|---|---|
| Medium | 1.5 wk | No | snapshot store |

**Why.** Suspended approvals are spread across runs. Back-office apps need "all
tasks waiting for me", with assignment, SLA and escalation.

**API.** `HumanTaskInbox(store).list(assignee: 'ops')`; `inbox.complete(taskId,
decision: …)` resumes the run; `HumanApprovalNode(assignee: 'ops', sla:
4.hours, onTimeout: 'escalate')`.

---

### WF-10 · Map-reduce over large inputs — **High Value**

| Complexity | Effort | Breaking | Deps |
|---|---|---|---|
| Low | 4 d | No | none |

**Why.** `MapNode` exists; add reduce, batching, partial-failure tolerance and
checkpointing per item so a 2,000-document job resumes at item 1,431.

**API.** `MapReduceNode(id: 'summarise', over: 'docs', mapper: …, reducer: …,
batchSize: 20, tolerateFailures: 0.02)`.

---

### WF-11 · Workflow evaluation hooks — **Future**

| Complexity | Effort | Breaking | Deps |
|---|---|---|---|
| Low | 3 d | No | `agentic_test` |

**API.** `EvalSuite.workflow(graph, cases: …, checks: [EvalCheck.visited('refund'),
EvalCheck.stateEquals('triage.category', 'billing')])`.

---

### WF-12 · Remote node execution — **Future**

| Complexity | Effort | Breaking | Deps |
|---|---|---|---|
| High | 2.5 wk | No | `agentic_server` |

**Why.** Keep secrets and heavy nodes on a server while the graph and approvals
run on the phone (or the reverse).

**API.** `RemoteNode(id: 'crm_lookup', endpoint: server.node('crm_lookup'))`,
with the snapshot and trace carried across.

---

### WF-13 · Graph DSL for linear and branching flows — **High Value** (DX)

| Complexity | Effort | Breaking | Deps |
|---|---|---|---|
| Low | 4 d | No | none |

**Why.** The builder is verbose for the common "A → B → (C | D) → E" case.

**API.**

```dart
final graph = Flow('summarise')
    .then(fetch)
    .then(classify)
    .branch('category', {'news': summariseNews, 'paper': summarisePaper})
    .then(publish)
    .build();
```

---

### WF-14 · Deterministic replay for debugging — **Experimental**

| Complexity | Effort | Breaking | Deps |
|---|---|---|---|
| Medium | 1.5 wk | No | `agentic_test` cassettes, CORE-10 |

**Why.** Reproduce a production failure locally from its snapshot and recorded
model responses — the workflow equivalent of a crash dump.

---

## `agentic_memory` — 10 features

### MEM-1 · Memory consolidation — **Must Have**

| Complexity | Effort | Breaking | Deps |
|---|---|---|---|
| Medium | 1.5 wk | No | none |

**Why.** Extraction without consolidation accumulates duplicates and
contradictions ("lives in Pune" and "moved to Berlin"). Recall quality decays
over months of use — exactly the timescale of a personal assistant.

**API.**

```dart
final consolidator = MemoryConsolidator(
  model: flashLite,
  strategy: ConsolidationStrategy.updateOrAdd, // ADD / UPDATE / DELETE / NOOP per fact
);
await consolidator.run(store, scope: MemoryScope.user(uid), since: lastRun);
```

---

### MEM-2 · User-controlled memory (inspect, edit, export, forget) — **Must Have**

| Complexity | Effort | Breaking | Deps |
|---|---|---|---|
| Low | 1 wk (with widgets) | No | none |

**Why.** App-store privacy review and GDPR both expect users to see and erase
what an assistant remembers. It also builds trust.

**API.** `store.export(scope)` → JSON; `store.forgetAll(scope)`;
`MemoryManagerView(store: store, scope: MemoryScope.user(uid))` in
`agentic_flutter`.

---

### MEM-3 · Temporal memory (validity windows) — **High Value**

| Complexity | Effort | Breaking | Deps |
|---|---|---|---|
| Medium | 1.5 wk | No | none |

**Why.** "Where does Priya work?" has different answers over time. Temporal
knowledge graphs (Zep/Graphiti) showed large recall gains on such questions.

**API.** `MemoryEntry(validFrom: …, validUntil: …, supersedes: oldId)`;
`MemoryQuery(asOf: DateTime(2026, 3))`.

---

### MEM-4 · Profile memory (structured user facts) — **High Value**

| Complexity | Effort | Breaking | Deps |
|---|---|---|---|
| Low | 4 d | No | CORE-6 |

**Why.** Many apps need a small, schema-shaped profile (diet, units, name,
goals) rather than free-text recall.

**API.** `ProfileMemory<UserPrefs>(schema: UserPrefsSchema(), store: …)`,
updated by extraction and injected as a compact system block.

---

### MEM-5 · Importance, decay and pruning policies — **High Value**

| Complexity | Effort | Breaking | Deps |
|---|---|---|---|
| Low | 4 d | No | none |

**API.** `MemoryRetention(decayHalfLife: 30.days, minImportance: 0.2, maxEntries:
5000)`, applied on write and by a scheduled prune (`MemoriesPruned` already
exists).

---

### MEM-6 · Encrypted memory — **Must Have** (for personal data)

| Complexity | Effort | Breaking | Deps |
|---|---|---|---|
| Medium | 1 wk | No | `cryptography` (AES-GCM), key via `SecretStore` |

**API.** `EncryptedMemoryStore(inner, key: await secrets.require('memory_key'))`
— content and metadata values encrypted; keyword search via encrypted token
hashes.

---

### MEM-7 · Knowledge-graph memory — **Future**

| Complexity | Effort | Breaking | Deps |
|---|---|---|---|
| High | 3 wk | No | `agentic_graph` (Phase 4) |

**API.** `GraphMemoryStore(graph)` extracting entities and relations; recall
expands one hop from matched entities.

---

### MEM-8 · Shared team memory with access control — **Future**

| Complexity | Effort | Breaking | Deps |
|---|---|---|---|
| Medium | 1.5 wk | No | none |

**API.** `MemoryScope.team(id)` with `MemoryAcl(read: {...}, write: {...})`
enforced by the store; memory tools receive the caller's principal from context.

---

### MEM-9 · Memory evals — **High Value**

| Complexity | Effort | Breaking | Deps |
|---|---|---|---|
| Low | 4 d | No | `agentic_test` |

**Why.** Memory is easy to add and hard to prove useful. A LongMemEval-style
harness (write sessions, ask later questions) turns tuning into numbers.

**API.** `MemoryEval.longHorizon(sessions: …, probes: …).run(agentFactory)`.

---

### MEM-10 · Scalable indexes — **High Value**

| Complexity | Effort | Breaking | Deps |
|---|---|---|---|
| Medium | 1 wk | No | `agentic_sqlite` FTS5 / sqlite-vec, `agentic_vector` adapters |

**Why.** In-memory scoring scans every entry. Delegating keyword search to FTS5
and semantic search to any `VectorStore` removes the ceiling.

**API.** `IndexedMemoryStore(records: SqliteMemoryStore(db), keyword:
Fts5Index(db), vectors: pgvector)`.
