# Phase 3e — Feature innovation: quality and developer tooling

`agentic_test` · `agentic_tools_generator` · (internal) `agentic_benchmark`, `agentic_integration`

Entry format as in [03a](03a-features-foundation.md).

The strategic point for this group: across the industry, 89 % of teams with
agents in production have observability but only about half run offline evals
(LangChain *State of Agent Engineering*, Dec 2025). No Dart eval library was
found on pub.dev. **Evals are the most defensible differentiator available to
this project.**

---

## `agentic_test` — 12 features

### TEST-1 · Trajectory assertions — **Must Have**

| Complexity | Effort | Breaking | Deps |
|---|---|---|---|
| Low | 4 d | No | none |

**Why.** For agents, *how* matters as much as *what*: did it look up the order
before refunding? `calledTool` checks presence, not order or arguments.

**API.**

```dart
EvalCheck.trajectory([
  ToolStep('lookup_order', args: {'orderId': '42'}),
  ToolStep.any(),                                   // wildcard
  ToolStep('issue_refund', args: ArgsMatch.subset({'amount': lessThan(100)})),
], mode: TrajectoryMatch.inOrder);                   // exact | inOrder | anyOrder | superset
```

---

### TEST-2 · Datasets from files — **Must Have**

| Complexity | Effort | Breaking | Deps |
|---|---|---|---|
| Low | 3 d | No | `yaml` |

**Why.** Eval cases belong in data files that product people can edit, not in
Dart code.

**API.**

```yaml
# eval/support.yaml
- id: refund-duplicate
  input: "I was charged twice for order 42"
  checks:
    - called_tool: {name: lookup_order, args: {orderId: "42"}}
    - answer_contains: refund
    - judged_by: {rubric: "Apologises and states the refund timeline"}
  tags: [billing, regression]
```

```dart
final suite = EvalSuite.fromYaml('eval/support.yaml', judge: judgeModel);
```

---

### TEST-3 · CI reporters (JUnit XML, JSON, Markdown, HTML) — **Must Have**

| Complexity | Effort | Breaking | Deps |
|---|---|---|---|
| Low | 4 d | No | none |

**Why.** Results must appear in GitHub checks, PR comments and dashboards.

**API.** `report.writeJUnit('build/evals.xml')`, `report.toMarkdown()` (PR
comment), `report.toHtml()` (self-contained, with transcripts); a
`dart run agentic_test:eval` entry point with `--tags`, `--trials`, `--model`.

---

### TEST-4 · Statistical rigour: pass^k, confidence intervals, flakiness — **High Value**

| Complexity | Effort | Breaking | Deps |
|---|---|---|---|
| Low | 3 d | No | none |

**Why.** A 7/10 pass rate on one run is noise. Reliability metrics such as pass^k
(all k trials pass), Wilson intervals and a per-case flakiness flag make
decisions defensible.

**API.** `EvalReport.passAtK(k)`, `.passHatK(k)`,
`.confidenceInterval(level: 0.95)`, `EvalCaseReport.isFlaky`.

---

### TEST-5 · Baselines and regression gates — **Must Have**

| Complexity | Effort | Breaking | Deps |
|---|---|---|---|
| Low | 4 d | No | none |

**Why.** "Did this prompt change make things worse?" is the question evals exist
to answer.

**API.** `report.saveBaseline('eval/baseline.json')`;
`report.compareTo(Baseline.load(...)).failIfRegressed(maxDrop: 0.05,
significance: 0.05)`; cost and latency regressions reported alongside quality.

---

### TEST-6 · Production trace → eval case — **High Value**

| Complexity | Effort | Breaking | Deps |
|---|---|---|---|
| Medium | 1 wk | No | CORE-10, FL-6 |

**Why.** The best eval cases are real failures. A thumbs-down in the app should
become a replayable case in one step.

**API.** `EvalCase.fromRecordedRun(events, cassette, expected: …)`; `agentic
eval capture --run <id>`.

---

### TEST-7 · Model comparison matrix — **High Value**

| Complexity | Effort | Breaking | Deps |
|---|---|---|---|
| Low | 4 d | No | none |

**Why.** Choosing between Flash, Haiku, a local Gemma and GPT-mini needs quality ×
cost × latency on *your* cases.

**API.** `EvalMatrix(suite, models: {'flash': f, 'haiku': h, 'gemma-local':
g}).run()` → a table and a Pareto chart in the HTML report.

---

### TEST-8 · Red-team and prompt-injection suites — **Must Have**

| Complexity | Effort | Breaking | Deps |
|---|---|---|---|
| Medium | 1.5 wk | No | none |

**Why.** The framework's untrusted-content boundaries are a security claim;
a bundled attack suite lets users prove it holds for their tools and prompts.

**API.** `RedTeamSuite.standard(categories: {InjectionVia.toolResult,
InjectionVia.retrievedDocument, InjectionVia.mcpDescription, DataExfiltration.url,
Jailbreak.roleplay})` run against an agent factory, asserting that dangerous tools
were not called and secrets did not leak.

---

### TEST-9 · Widget-test harness for chat UIs — **High Value**

| Complexity | Effort | Breaking | Deps |
|---|---|---|---|
| Low | 4 d | No | `flutter_test` (in `agentic_flutter_test`, because of the `test_api` pin) |

**API.** `await tester.pumpAgentChat(agent: scriptedAgent)`,
`await tester.sendMessage('hi')`, `await tester.approveNextTool()`,
`expect(find.toolCall('get_weather'), findsOneWidget)`.

---

### TEST-10 · Scripted and simulated users — **High Value**

| Complexity | Effort | Breaking | Deps |
|---|---|---|---|
| Medium | 1 wk | No | none |

**Why.** Multi-turn agents need multi-turn tests. An LLM playing a persona
("impatient customer who never gives the order number up front") finds failures
that single-turn cases miss.

**API.** `SimulatedUser(model: m, persona: '…', goal: '…', maxTurns: 8)`;
`EvalCase.conversation(user: simulated, checks: [...])`.

---

### TEST-11 · Cassette maintenance tools — **High Value**

| Complexity | Effort | Breaking | Deps |
|---|---|---|---|
| Low | 3 d | No | none |

**Why.** Cassettes go stale when prompts change. Developers need to see what
changed and re-record selectively.

**API.** `CassetteMode.recordMissing`, `dart run agentic_test:cassettes --stale`
(lists interactions whose request hash no longer matches), `--prune`, and a
human-readable diff of mismatched requests in `CassetteMismatchError`.

---

### TEST-12 · Tool and MCP contract fakes — **High Value**

| Complexity | Effort | Breaking | Deps |
|---|---|---|---|
| Low | 3 d | No | none |

**API.** `FakeTool.returning(...)`, `FakeTool.failing(ToolFailureKind.timeout)`,
`FakeMcpServer(tools: …)` over `InMemoryTransport`, `ScriptedApprovals` moved here
from `agentic_flutter` (keeping a re-export) so pure-Dart tests can use it.

---

## `agentic_tools_generator` — 10 features

### GEN-1 · `@Toolkit` classes — **Must Have**

| Complexity | Effort | Breaking | Deps |
|---|---|---|---|
| Low | 4 d | No | none |

**Why.** Real tools share dependencies (an API client, a repository).
Annotating each method and assembling a `ToolSet` by hand is boilerplate.

**API.**

```dart
@Toolkit(prefix: 'calendar')
class CalendarTools {
  CalendarTools(this.api);
  final CalendarApi api;

  /// Lists events between two dates.
  @ToolFunction(readOnly: true)
  Future<List<Event>> listEvents(DateTime from, DateTime to) => api.list(from, to);

  /// Creates an event. Requires confirmation.
  @ToolFunction(requiresApproval: true)
  Future<Event> createEvent(String title, DateTime start, {Duration length = const Duration(hours: 1)}) => …;
}

registry.registerAll(CalendarTools(api).tools);   // generated extension
```

---

### GEN-2 · `@AgenticSchema` for structured output — **Must Have**

| Complexity | Effort | Breaking | Deps |
|---|---|---|---|
| Medium | 1.5 wk | No | CORE-6 |

**Why.** The most common structured-output complaint in every language is
writing the schema twice. Generating `JsonSchema` + `fromJson` from a class,
record or sealed hierarchy — with doc comments as descriptions — removes it.

**API.**

```dart
@AgenticSchema()
class Recipe {
  /// Dish name, title case.
  final String name;
  @Range(min: 1, max: 12) final int servings;
  final List<Ingredient> ingredients;
  final Difficulty difficulty;          // enum → string enum
}

final recipe = await model.generateAs(request, Recipe.schema);  // generated
```

Sealed classes map to `anyOf` with a discriminator; nullable fields map to
optional properties consistently with `JsonSchema.coerce`.

---

### GEN-3 · Doc comments as descriptions — **Must Have**

| Complexity | Effort | Breaking | Deps |
|---|---|---|---|
| Low | 2 d | No | none |

**Why.** `public_member_api_docs` already forces documentation; reusing it as
tool and parameter descriptions keeps one source of truth. `@ToolParam(description:)`
remains as an override.

---

### GEN-4 · `json_serializable` and `freezed` interop — **High Value**

| Complexity | Effort | Breaking | Deps |
|---|---|---|---|
| Medium | 1 wk | No | none (reads their annotations) |

**Why.** Most Flutter apps already model data with them. Honour `@JsonKey(name:)`,
`@JsonValue`, `includeIfNull`, and freezed unions, and call their existing
`fromJson` instead of generating a second decoder.

---

### GEN-5 · Generate MCP server entry points — **High Value**

| Complexity | Effort | Breaking | Deps |
|---|---|---|---|
| Low | 3 d | No | `agentic_mcp` |

**API.** `@McpServerEntry(name: 'calendar')` on a toolkit generates
`bin/calendar_mcp.dart` serving stdio and, optionally, HTTP (MCP-4).

---

### GEN-6 · Analyzer plugin with lints and quick fixes — **High Value**

| Complexity | Effort | Breaking | Deps |
|---|---|---|---|
| Medium | 1.5 wk | No | the new analyzer plugin API (`analysis_server_plugin`) |

**Why.** Feedback in the editor beats a failed build: missing descriptions,
unsupported parameter types, a destructive-sounding name (`delete_*`) without
`requiresApproval`, overlapping tool names (TOOLS-9), and an exported name
clashing with another agentic package (the `AgentTool` clash found in Phase 5b).

---

### GEN-7 · Typed tool results and output schemas — **High Value**

| Complexity | Effort | Breaking | Deps |
|---|---|---|---|
| Low | 3 d | No | TOOLS-1 |

**Why.** Return types already exist in the Dart signature; generate `outputSchema`
and structured results from them.

---

### GEN-8 · Streaming and progress-reporting tools — **Future**

| Complexity | Effort | Breaking | Deps |
|---|---|---|---|
| Low | 3 d | No | TOOLS-2 |

**API.** A `ToolProgress progress` parameter is recognised and injected, and
`Stream<T>` returns become progress plus final result.

---

### GEN-9 · Workflow node generation — **Future**

| Complexity | Effort | Breaking | Deps |
|---|---|---|---|
| Medium | 1 wk | No | WF-3 |

**API.** `@WorkflowNodeFunction(reads: ['topic'], writes: 'outline')` generating
a typed `CustomNode` with data-flow declarations the validator can check.

---

### GEN-10 · Schema snapshot tests — **High Value**

| Complexity | Effort | Breaking | Deps |
|---|---|---|---|
| Low | 2 d | No | none |

**Why.** A renamed parameter silently changes what the model sees. Generating a
`tools.schema.json` snapshot per library — the same idea as `api/*.txt` — makes
prompt-surface changes reviewable in PRs.

---

## Internal packages — recommendations, not features

| Package | Recommendation | Priority |
|---|---|---|
| `agentic_integration` | Publish the reusable half as `chatModelConformance()` in `agentic_test` (LLM-18); set nightly secrets so model retirement is caught before users see it (finding X1) | Must Have |
| `agentic_integration` | Add a **model-retirement canary**: call each provider's model-list endpoint nightly and fail if a default or catalogue alias disappears | Must Have |
| `agentic_benchmark` | Move `api_snapshot` into `tool/` so the package does one job; add benchmarks for streaming UI rebuilds (FL-8), vector search on isolates (VEC-5), BM25 at 100 k chunks, and cold-start cost of `agentic_flutter` | High Value |
| `agentic_benchmark` | Publish results to a `benchmarks/` page on the docs site — performance numbers are marketing for a mobile-first framework | High Value |
