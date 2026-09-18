# Phase 4 — New packages

Every package below obeys the existing rules: it depends only on the layer it
extends, it defines ports before adapters, heavy platform dependencies live in
separate bridge packages, and anything touching Flutter is a leaf.

**Naming convention.** `agentic_<capability>` for framework packages,
`agentic_<layer>_<vendor>` for adapters (e.g. `agentic_vector_pgvector`),
`agentic_flutter_<thing>` for Flutter-only leaves. This keeps skills names
predictable (`agentic-vector-pgvector-…`) and pub.dev search coherent.

## 4.0 Summary

| # | Package | Layer | Priority | Effort | Absorbs features |
|---|---|---|---|---|---|
| 1 | `agentic_skills` | agents | **Must Have** | 2 wk | AGENTS-9 |
| 2 | `agentic_otel` | observability | **Must Have** | 2 wk | CORE-1, CORE-2 |
| 3 | `agentic_llm_local` | model adapters | **Must Have** | 5 wk | LLM-7, VEC-10 |
| 4 | `agentic_llm_cloud` | model adapters | **Must Have** (enterprise) | 3 wk | LLM-4 |
| 5 | `agentic_llm_firebase` | model adapters | **Must Have** | 1 wk | Firebase AI Logic / App Check |
| 6 | `agentic_guardrails` | safety | **Must Have** | 3 wk | AGENTS-2, LLM-17, CORE-7, TEST-8 |
| 7 | `agentic_router` | models | High Value | 2 wk | LLM-8, cost tracking |
| 8 | `agentic_rag_documents` | knowledge | **Must Have** | 4 wk | RAG-1, RAG-2, RAG-3 |
| 9 | `agentic_vector_*` adapter family | knowledge | **Must Have** | 5 wk | VEC-1, VEC-2 |
| 10 | `agentic_toolkit` | tools | High Value | 3 wk | TOOLS-6, TOOLS-7, TOOLS-11 |
| 11 | `agentic_mcp_server` | protocol | **Must Have** | 2 wk | MCP-4, MCP-12, MCP-13 |
| 12 | `agentic_a2a` | protocol | High Value | 4 wk | AGENTS-11 |
| 13 | `agentic_ag_ui` | protocol | High Value | 3 wk | FL-18, TOOLS-12 |
| 14 | `agentic_server` | runtime | High Value | 4 wk | durable server runtime, WF-12 |
| 15 | `agentic_voice` | multimodal | High Value | 5 wk | LLM-9, LLM-14, FL-5 |
| 16 | `agentic_vision` | multimodal | Future | 3 wk | camera/OCR/detection tools |
| 17 | `agentic_graph` | knowledge | Future | 5 wk | MEM-7, RAG-12 |
| 18 | `agentic_prompts` | DX | High Value | 2 wk | prompt templates, versioning |
| 19 | `agentic_eval` (split from `agentic_test`) | quality | High Value | 1 wk (split) + features | TEST-2..8 |
| 20 | `agentic_devtools` | DX | High Value | 4 wk | FL-12, SQL-10, MCP-14 |
| 21 | `agentic_cli` | DX | **Must Have** | 3 wk | CLI-3, CLI-4, CLI-9 |
| 22 | `agentic_workflow_studio` | visual builder | Future | 8 wk | WF-4, WF-8 |
| 23 | `agentic_flutter_genui` | UI bridge | High Value | 2 wk | FL-4 |
| 24 | `agentic_flutter_adapters` family | UI bridges | High Value | 2 wk | FL-9, FL-10 |
| 25 | `agentic_auth` | enterprise | Future | 4 wk | OAuth, identity propagation, RBAC |
| 26 | `agentic_usage` | analytics | High Value | 2 wk | CORE-8, cost dashboards |
| 27 | `agentic_sim` | testing | Experimental | 4 wk | TEST-10, environments |
| 28 | `agentic_computer_use` | agents | Experimental | 4 wk | AGENTS-15 |
| 29 | `agentic_sync` | knowledge | Future | 4 wk | RAG-8, SQL-8 |
| 30 | `agentic_marketplace` (registry + CLI) | ecosystem | Experimental | 6 wk | plugin/skill/workflow discovery |
| 31 | `agentic_genkit` | interop | High Value | 2 wk | bridge to Genkit Dart |
| 32 | `agentic_learn` (docs site + cookbook repo, not a package) | docs | **Must Have** | 4 wk | X4 |

Effort is for a first useful release by one experienced maintainer.

---

## 4.1 `agentic_skills` — Agent Skills runtime — **Must Have**

**Purpose.** Load, validate and use Agent Skills (`SKILL.md` + `scripts/`,
`references/`, `assets/`) *inside apps and agents* built with this framework.
Distinct from shipping skills *about* this framework (Phase 8), though it
reuses the same validator.

**Why now.** Agent Skills is an open standard supported by 40+ clients; the Dart
team just made skills a pub.dev distribution primitive. A Dart runtime lets a
Flutter app ship domain expertise ("how our refund policy works") as versioned
assets, and lets server agents load skills from Git.

**API.**

```dart
final library = await SkillLibrary.load([
  SkillSource.assets('assets/skills'),
  SkillSource.directory(Directory('.agents/skills')),
  SkillSource.git('https://github.com/acme/support-skills', ref: 'v3'),
]);

library.validate();                         // name/description rules from agentskills.io

final agent = ToolCallingAgent(
  info: AgentInfo(name: 'support', description: '…'),
  model: model,
  tools: registry.all,
  instructions: base + library.catalogPrompt(), // ~100 tokens per skill
  budget: AgentBudget.interactive,
).withSkills(library);                      // adds load_skill / read_skill_file tools
```

**Security.** Skills are untrusted content by default; `scripts/` never execute
unless a `SkillScriptRunner` is supplied and approved (maps to TOOLS-4).
`allowed-tools` is enforced as an allow-list over the registry.

**Deps.** `agentic_agents`, `agentic_tools`, `yaml`.

---

## 4.2 `agentic_otel` — OpenTelemetry export — **Must Have**

**Purpose.** Export `Tracer` spans and metrics over OTLP/HTTP (JSON and
protobuf), with OpenTelemetry GenAI semantic conventions (`invoke_agent`,
`chat`, `execute_tool`, `gen_ai.*` attributes; content capture opt-in, as the
conventions recommend).

**API.**

```dart
final otel = AgenticOtel.configure(
  endpoint: Uri.parse('https://cloud.langfuse.com/api/public/otel'),
  headers: {'authorization': basicAuth},
  serviceName: 'pocket_agent',
  captureContent: ContentCapture.none,     // or .redacted(detector)
  sampler: Sampler.parentBased(Sampler.ratio(0.2)),
);
final runtime = AgenticRuntime(tracer: otel.tracer, meter: otel.meter);
```

Presets: `OtelPreset.langfuse`, `.phoenix`, `.honeycomb`, `.datadog`,
`.grafanaCloud`, `.googleCloudTrace`. Mobile specifics: batched export, disk
buffer while offline, flush on `AppLifecycleState.paused`.

**Deps.** `agentic_core`, `http`.

---

## 4.3 `agentic_llm_local` — On-device models — **Must Have**

**Purpose.** `ChatModel` and `EmbeddingModel` adapters for on-device inference
plus the orchestration those engines lack.

**Design.** Bridges, not engines:

| Adapter | Over | Platforms |
|---|---|---|
| `GemmaChatModel`, `GemmaEmbeddingModel` | `flutter_gemma` (LiteRT-LM) | all six |
| `LlamaDartChatModel` | `llamadart` (GGUF, LiteRT-LM) | native + web |
| `GeminiNanoChatModel` | ML Kit GenAI Prompt API via platform channel | Android (supported devices) |
| `AppleFoundationChatModel` | Apple Foundation Models via platform channel | iOS / macOS (supported devices) |

Each bridge is its own package (`agentic_llm_local_gemma`, …) so an app pulls in
one native dependency, not four. The core `agentic_llm_local` package owns:

- `ModelDownloadManager` — resumable downloads, checksum, storage quota,
  Wi-Fi-only policy, progress stream, eviction.
- `DeviceCapabilityProbe` — RAM, accelerator, supported backends → a
  recommended model.
- `PromptedToolCalling` — tool-calling via constrained prompting for models
  without native function calling (uses `ModelCapabilities.localMinimal`).
- `OnDeviceChatModel.best(prefer: …)` — picks the best available backend.

**Deps.** `agentic_llm`; bridges add their engine package.

---

## 4.4 `agentic_llm_cloud` — Azure OpenAI, Bedrock, Vertex AI — **Must Have** (enterprise)

**Purpose.** Adapters requiring cloud credentials and signing, kept out of
`agentic_llm` so mobile apps never pull in cloud auth code.

**API.** `AzureOpenAiChatModel`, `BedrockChatModel` (Converse API, SigV4),
`VertexGeminiChatModel`, `VertexAnthropicChatModel`; credential providers
`AwsCredentials.fromEnvironment()`, `GoogleAuth.adc()`,
`AzureAuth.managedIdentity()`.

**Deps.** `agentic_llm`, `crypto`, `googleapis_auth`.

---

## 4.5 `agentic_llm_firebase` — Firebase AI Logic adapter — **Must Have**

**Purpose.** A `ChatModel` over `firebase_ai`, inheriting App Check, server
prompt templates and hybrid on-device inference.

**Why.** It is the cleanest honest answer to "where does my key go" for a
Flutter app, and it puts the framework in front of the largest Flutter AI
audience.

**API.** `FirebaseAiChatModel(model: FirebaseAI.googleAI().generativeModel(…))`,
`FirebaseAiLiveSession` for `agentic_voice`.

**Deps.** `agentic_llm`, `firebase_ai` (Flutter leaf).

---

## 4.6 `agentic_guardrails` — Safety layer — **Must Have**

**Purpose.** One vocabulary for input, output and tool-call checks usable by
models (decorator), agents (tripwires), workflows (nodes) and evals (red team).

**API.**

```dart
abstract interface class Guardrail {
  String get name;
  Future<GuardrailVerdict> check(GuardrailInput input, {AgenticContext? context});
}

final guards = GuardrailSet([
  PromptInjectionDetector.heuristic(),               // fast, on-device
  PromptInjectionDetector.classifier(model: flashLite),
  PiiGuardrail(detector: RegexPiiDetector.standard(), action: PiiAction.redact),
  TopicGuardrail(allowed: ['banking', 'account help'], judge: flashLite),
  ModerationGuardrail.openAi(apiKey: k),
  SchemaGuardrail(answerSchema),
  ToolArgumentGuardrail('transfer_funds', (args) => args['amount'] <= 500),
]);
```

Ships the `RedTeamSuite` datasets used by TEST-8 so defences and attacks evolve
together.

**Deps.** `agentic_llm`, `agentic_tools`.

---

## 4.7 `agentic_router` — Model router and cost control — **High Value**

**Purpose.** `RoutingChatModel` (LLM-8) plus policies: privacy (sensitive →
on-device), offline, cost ceilings per user/day, latency SLOs, A/B splits for
prompt or model experiments, shadow traffic for evaluating a new model.

**API.** `RoutingChatModel(routes: …, experiments: [Experiment('flash-vs-haiku',
split: 0.1, arms: {...})])`, emitting `LlmRouteSelected` events consumed by
`agentic_usage` and `agentic_eval`.

---

## 4.8 `agentic_rag_documents` — Document loaders — **Must Have**

**Purpose.** PDF (text + layout + optional vision OCR), DOCX, PPTX, XLSX,
EPUB, CSV, JSON loaders, and enrichers (image description, contextual chunk
headers, table extraction).

**Design.** Pure Dart by default; `agentic_rag_documents_pdfium` as an optional
native backend for higher fidelity. Page, sheet and slide numbers become chunk
metadata for citations.

---

## 4.9 `agentic_vector_*` — Vector store adapters — **Must Have**

`agentic_vector_pgvector` (also Supabase), `agentic_vector_objectbox`,
`agentic_vector_pinecone`, `agentic_vector_chroma`, `agentic_vector_weaviate`,
`agentic_vector_turbopuffer`, `agentic_vector_sqlite_vec` (or folded into
`agentic_sqlite`). Each passes the shared `vectorStoreConformance()` suite
published from `agentic_vector/testing.dart`.

**Community model.** Publish the conformance suite and an adapter template first;
invite the community to own adapters for stores the maintainer does not use. This
is how LangChain scaled integrations.

---

## 4.10 `agentic_toolkit` — Batteries-included tools — **High Value**

Web fetch (SSRF-safe, HTML → Markdown), web search (Brave, Tavily, Exa, Google
Programmable Search), clock/time zones, calculator, unit conversion, file system
with roots, OpenAPI importer (TOOLS-11), HTTP request with allow-list, code
execution via remote sandbox (E2B, Daytona) (TOOLS-7), Git read-only, SQL query
(read-only, parameterised). All `@ToolFunction`-generated, all with approval
defaults and untrusted-content flags set correctly.

---

## 4.11 `agentic_mcp_server` — Host MCP servers in Dart — **Must Have**

Shelf handler for streamable HTTP (MCP-4), OAuth resource-server validation,
Origin checks, `McpServer.forWorkflow` / `forAgent` (MCP-12), deployment recipes
(Cloud Run, Dart Frog, Serverpod, Docker), and the `mcp-server` template.
Keeps `shelf` out of the client package.

---

## 4.12 `agentic_a2a` — Agent2Agent protocol — **High Value**

**Why.** A2A v1.0 (April 2026) has SDKs in Python, JS, Java, Go and .NET — **none
in Dart**. First mover wins the "official-feeling" position.

**API.**

```dart
// Consume
final travel = await A2aAgent.fromCard(Uri.parse('https://agents.acme.com/.well-known/agent-card.json'),
    auth: A2aAuth.oauth(…));
final result = await travel.run(AgentInput.text('Book Lisbon, 3 nights'));   // it's an Agent

// Publish
final handler = A2aShelfHandler(
  agent: myAgent,
  card: myAgent.info.toCard(url: publicUrl, skills: [...]),
  taskStore: SqliteA2aTaskStore(db),     // durable tasks
  signing: AgentCardSigner.jws(key),     // signed agent cards
);
```

Bindings: JSON-RPC first, REST second, gRPC later.

---

## 4.13 `agentic_ag_ui` — AG-UI protocol — **High Value**

Client (`AgUiAgent` implementing `Agent`, FL-18) *and* server
(`AgUiShelfHandler(agent)` streaming AG-UI events from any `agentic_agents`
agent). This lets Flutter apps front Python backends, and lets CopilotKit /
React front-ends use Dart agents.

---

## 4.14 `agentic_server` — Durable server runtime — **High Value**

**Purpose.** Run agents and workflows as a service: HTTP/SSE API, durable run
store (Postgres/SQLite), job queue with retries, cron triggers (WF-6),
webhooks, multi-tenant budgets, human task inbox API (WF-9), and client SDK
generation for Flutter.

**Why.** Genkit Dart and LangSmith Deployment both answer "where does my agent
run in production". A Flutter team wants the answer in Dart, deployable to
Cloud Run or Serverpod.

**API.**

```dart
final server = AgenticServer(
  store: PostgresRunStore(pool),
  agents: {'support': supportAgent},
  workflows: {'onboarding': onboardingGraph},
  auth: JwtAuth(issuer: …),
  budgets: TenantBudgets.perDay(cost: 5.0),
);
await server.serve(port: 8080);
// Flutter: final client = AgenticClient(baseUrl); client.agent('support').stream(...)
```

---

## 4.15 `agentic_voice` — Voice agents — **High Value**

Realtime sessions (OpenAI Realtime, Gemini Live via `firebase_ai`, others) with
tool calling through `ToolExecutor`; push-to-talk pipeline (STT → agent → TTS)
for any `Agent`; voice activity detection; barge-in; echo cancellation guidance;
Flutter widgets (`RealtimeVoiceView`, `VoiceChatButton`) in
`agentic_flutter_voice`. Audio I/O via callbacks (no plugin lock-in).

---

## 4.16 `agentic_vision` — Computer vision tools — **Future**

Tools and pipelines for camera-first agents: document scanning with
perspective correction (via callback), receipt/invoice extraction to typed
schemas (GEN-2), barcode/QR, label reading, image comparison, on-device ML Kit
bridges. Positioned as "structured extraction from the camera", which is where
mobile vision agents deliver value.

---

## 4.17 `agentic_graph` — Knowledge graph — **Future**

Entity/relation extraction, a `GraphStore` port (in-memory, SQLite, Neo4j,
FalkorDB), temporal edges (MEM-3), community summaries for GraphRAG (RAG-12),
and graph-expansion retrievers.

---

## 4.18 `agentic_prompts` — Prompt engineering toolkit — **High Value**

**Purpose.** Prompts as versioned, testable, typed assets.

```dart
@PromptTemplate(version: 3)
const summarise = Prompt<SummariseInput>('''
You are summarising for {{audience}}.
{{#if bullets}}Use at most {{maxBullets}} bullets.{{/if}}
''');
```

Features: typed variables (generated), partials, provider-specific variants,
prompt registry with remote override (for example Firebase Remote Config or
Firebase server prompt templates), A/B assignment (with `agentic_router`),
optimisation loop (propose → eval → keep), and prompt snapshots in PR diffs.

---

## 4.19 `agentic_eval` — Evaluation platform (split) — **High Value**

Split evals out of `agentic_test` once TEST-2..8 land: `agentic_test` keeps
fakes, cassettes and test helpers (a `dev_dependency`); `agentic_eval` becomes
the dataset/metrics/reporting platform that can also run in production
(online evals on sampled traffic, feeding `agentic_otel`).

---

## 4.20 `agentic_devtools` — DevTools extension — **High Value**

Tabs: **Runs** (timeline of agent steps, tool calls, approvals), **Traces**
(span waterfall with token and cost per span), **Prompts** (exact requests and
responses, redacted), **Memory** (browse, edit, delete), **Vectors** (query a
store, see scores), **Workflows** (live graph with state inspector, fork from
checkpoint), **MCP** (servers, tools, JSON-RPC log), **Evals** (latest report).
Uses the VM service to read an in-app `EventRecorder`.

---

## 4.21 `agentic_cli` — The `agentic` command — **Must Have**

`init`, `add`, `doctor`, `upgrade`, `eval`, `cassettes`, `skills`, `mcp
inspect`, `workflow validate|render`, `models list|check`. `create_agentic_app`
stays as the zero-install entry point and delegates to the same library.

---

## 4.22 `agentic_workflow_studio` — Visual workflow builder — **Future**

A Flutter desktop/web app (and embeddable widget) editing WF-4 declarative
definitions: node palette from `NodeRegistry`, schema-driven node forms, live
validation errors from `WorkflowGraph`, test-run with cassettes, time-travel
debugger, export to YAML/Dart. Also installable as an MCP App so Claude or VS
Code can render it. The strongest *visual* differentiator for Flutter: a
workflow builder built with the same UI toolkit that runs the workflows.

---

## 4.23 `agentic_flutter_genui` — GenUI / A2UI bridge — **High Value**

Feed `agentic_agents` runs into `genui` surfaces; map A2UI actions back to
agent input; share a component catalogue with typed widget tools (FL-4).

---

## 4.24 `agentic_flutter_adapters` family — **High Value**

`agentic_riverpod`, `agentic_bloc`, `agentic_signals`, `agentic_chat_ui`
(`flutter_chat_ui`), `agentic_ai_toolkit` (`LlmProvider` for
`flutter_ai_toolkit`), `agentic_genai_primitives`.

---

## 4.25 `agentic_auth` — Enterprise authentication — **Future**

Identity propagation from app user → agent → tools → MCP servers
(on-behalf-of token exchange, RFC 8693), per-tool scopes, RBAC for agents and
workflows, audit log (append-only, exportable), and SSO helpers (OIDC, SAML via
broker). Required for regulated deployments.

---

## 4.26 `agentic_usage` — Analytics, telemetry and cost tracking — **High Value**

Usage ledger with attribution (CORE-8), budgets per user/tenant/feature, cost
anomaly alerts, token forecast, Flutter dashboard widgets, export to BigQuery,
Postgres or CSV. Pricing comes from the model catalogue (LLM-1).

---

## 4.27 `agentic_sim` — Simulation environment — **Experimental**

Simulated users (TEST-10), simulated tool environments with state (a fake
CRM, calendar, bank ledger — τ-bench style), fault injection (latency, 429s,
malformed tool results, OS suspension mid-run), and scenario scripts. Lets teams
test agents against realistic failure before production.

---

## 4.28 `agentic_computer_use` — **Experimental**

Desktop-only computer/browser use harness (AGENTS-15): screenshot and action
loop, CDP/Playwright-MCP environments, per-action approval, recording and replay.

---

## 4.29 `agentic_sync` — Connectors and sync — **Future**

`SyncSource` implementations (Drive, Notion, GitHub, Confluence, Slack, local
folders, web crawler) with incremental cursors, plus encrypted device-to-device
or cloud backup for memory and sessions (SQL-8).

---

## 4.30 `agentic_marketplace` — Discovery registry — **Experimental**

Not a store: an index. A GitHub-backed registry (JSON) listing community tools,
adapters, skills, workflows (WF-4 YAML) and MCP servers with verification badges
(passes conformance suite, has skills, verified publisher). `agentic add
<name>` installs from it; the docs site renders it. Low infrastructure cost;
high community signal.

---

## 4.31 `agentic_genkit` — Genkit Dart bridge — **High Value**

Wrap Genkit models as `ChatModel`s and expose `agentic_workflow` graphs,
`agentic_rag` pipelines and `agentic_eval` suites as Genkit flows/evaluators.
Turns the nearest competitor's audience into an adoption channel: "already on
Genkit? Add durable workflows and evals."

---

## 4.32 `agentic_learn` — Documentation site and cookbook — **Must Have**

Not a package but a product: a docs site (for example Docusaurus or a Jaspr site
written in Dart, which is itself a story), concept guides, 40+ recipes, an
error catalogue (CORE-9), benchmarks, the adapter conformance matrix, `llms.txt`
and `llms-full.txt`, and a runnable DartPad or Zapp example per concept. See
Phase 8.
