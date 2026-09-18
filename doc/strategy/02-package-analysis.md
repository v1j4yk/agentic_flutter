# Phase 2 — Package analysis

Measured on `main` at `182caa1` (0.2.0, released 2026-09-17). Every number below
was read from the repository or from the pub.dev API on 2026-09-17; nothing is
estimated unless marked.

## 2.0 The portfolio at a glance

| Package | Published | Source lines | Test lines | Tests | Exported names | pub points | Likes | Downloads (30 d) |
|---|---|---:|---:|---:|---:|---|---:|---:|
| `agentic_core` | 0.2.0 | 7,893 | 3,269 | 247 | 107 | pending¹ | 2 | 208 |
| `agentic_tools` | 0.2.0 | 1,975 | 951 | 51 | 23 | 160/160 | 2 | 202 |
| `agentic_llm` | 0.2.0 | 5,783 | 2,835 | 143 | 50 | 160/160 | 2 | 205 |
| `agentic_agents` | 0.2.0 | 2,976 | 1,279 | 55 | 43 | 160/160 | 2 | 177 |
| `agentic_workflow` | 0.2.0 | 3,188 | 1,522 | 64 | 39 | 160/160 | 2 | 141 |
| `agentic_memory` | 0.2.0 | 2,439 | 921 | 54 | 25 | 160/160 | 2 | 136 |
| `agentic_vector` | 0.2.0 | 2,626 | 1,245 | 64 | 35 | 160/160 | 2 | 146 |
| `agentic_rag` | 0.2.0 | 4,446 | 1,796 | 92 | 63 | 160/160 | 2 | 137 |
| `agentic_mcp` | 0.2.0 | 3,604 | 1,394 | 62 | 51 | 160/160 | 2 | 139 |
| `agentic_sqlite` | 0.2.0 | 1,309 | 742 | 33 | 6 | pending¹ | 0 | — |
| `agentic_test` | 0.2.0 | 1,472 | 914 | 39 | 16 | 160/160 | 0 | — |
| `agentic_tools_generator` | 0.2.0 | 701 | 870 | 34 | 1 | pending¹ | 0 | — |
| `agentic_flutter` | 0.2.0 | 2,761 | 979 | 51 | 41 + re-exports | 160/160 | 2 | 125 |
| `create_agentic_app` | 0.2.0 | 1,337 | 365 | 25 | CLI | pending¹ | 2 | 122 |
| `agentic_benchmark` | unpublished | 2,069 | 786 | 50 | tool | — | — | — |
| `agentic_integration` | unpublished | 912 | 612 | 32 | suite | — | — | — |
| **Total** | | **45,491** | **20,480** | **~1,096** | | | | |

¹ pub.dev returned `grantedPoints: 0, maxPoints: 0` with only `is:recent` tags,
which is the state of a version still in the analysis queue, not a failed
score. Re-check tomorrow; if it stays at zero, run `pana` from a Linux runner
(it crashes on the maintainer's Windows machine).

**What the download numbers say.** The near-identical 120–210 counts across
every package, with 2 likes each, are the signature of a dependency tree being
resolved (CI, mirrors, the maintainer's own projects), not of independent
adoption. Treat real adoption as effectively zero. That is the single most
important fact in this whole document: the engineering is well ahead of the
distribution.

## 2.1 Cross-cutting findings

These apply to the whole repository and are not repeated per package.

### Strengths that are rare on pub.dev

1. **Architecture is deliberate and documented.** Strict downward layering,
   ports below adapters, Flutter as a leaf, sealed-vs-open decisions recorded
   with reasons (`doc/architecture.md`). Few Dart packages of any kind — AI or
   not — have this.
2. **The API is a governed contract.** `api/<pkg>.txt` and
   `api/<pkg>.signatures.txt` snapshots, a cross-package name-clash test,
   `fix_data.yaml` for `dart fix`, and a migration guide. This is Flutter-team
   discipline.
3. **Static analysis is maximal.** `strict-casts`, `strict-inference`,
   `strict-raw-types`, and `public_member_api_docs: error` — every public member
   is documented by construction.
4. **Safety is built in, not bolted on.** Required budgets, approval gating,
   untrusted-content boundaries (`UntrustedContentLedger`), MCP annotations that
   may only tighten, secrets treated honestly. Most competitors add these later
   or never.
5. **Testability ships to users.** Injected `Clock`, deterministic IDs,
   `FakeChatModel`, cassettes and evals. No test in CI touches the network.
6. **Mobile-first reasoning.** Lifecycle cancellation, the argument that an API
   key in an APK is a published key, exact search sized for a phone.

### Weaknesses that cut across packages

| # | Finding | Evidence | Severity |
|---|---|---|---|
| X1 | **Stale default model IDs** — the same failure that silently broke Gemini in 0.1.1 is queued up for the other providers | `OpenAiCompatibleChatModel.openAi(model: 'gpt-4o')`, `AnthropicChatModel(model: 'claude-sonnet-4-20250514')`, `.grok(model: 'grok-2-latest')` | **High** |
| X2 | **No shipped AI-assistant context** — no `SKILL.md`, `AGENTS.md` or `llms.txt` anywhere, so Claude Code, Gemini CLI, Copilot and Cursor will guess this API from training data that predates it. The Dart team shipped the `skills` CLI 1.0 on 2026-09-08: `dart pub publish` now bundles a top-level `skills/` folder and `dart run skills get` installs it into Claude Code, Cursor, Copilot, Codex, Antigravity and others — the channel exists and is unused | `find -iname SKILL.md` → 0 | **High** |
| X3 | **Front-door documentation is stale** | Root `README.md` says "Status: 0.1.1, early development"; root `CHANGELOG.md` only has an `[Unreleased]` 0.1.0 section; a hard-coded "1083 passing" test badge; `../recall/README.md` is the Flutter template boilerplate | Medium |
| X4 | **No hosted docs site** — pub.dev API docs plus READMEs only; no guides, cookbook, or searchable concept pages | — | Medium |
| X5 | **One test file per package** (e.g. 1,279 lines in one file for `agentic_agents`) — hard to navigate, slow to bisect, discourages contributors | `find test -name '*_test.dart'` → 1 in 10 packages | Medium |
| X6 | **Single maintainer, no governance** — no `CODE_OF_CONDUCT`, `SECURITY.md`, issue templates, discussions, roadmap board, or second publisher | repository root | Medium (adoption-limiting for enterprises) |
| X7 | **0.x churn** — 0.1.1 → 0.1.2 → 0.2.0 with breaking changes in one day. Correct by semver, but it signals instability to evaluators | changelog | Low–Medium |
| X8 | **CI scores only `agentic_core` with pana** at threshold 20 | `.github/workflows/ci.yaml` | Low |
| X9 | **No OpenTelemetry export** — tracing is "OpenTelemetry-shaped" but nothing leaves the process (no OTLP exporter, no `gen_ai.*` semantic conventions, no metrics API) | `grep otlp` / `gen_ai.` / `class Counter` → 0 | Medium |
| X10 | **Everything runs on the UI isolate** — no isolate offload for embedding math, BM25 scoring, chunking or JSON decoding of large payloads | `grep Isolate` → 0 in vector/rag/llm | Medium on low-end phones |

## 2.2 Scoring method

Ten dimensions, each out of 10, summed to 100. "Missing features" is analysed in
prose rather than scored, because it is what Phase 3 answers.

- **Feat** — features present versus what a developer in 2026 expects of this layer
- **Arch** — layering, seams, extensibility
- **DX** — time to first success, ergonomics, error messages
- **Perf** — algorithmic choices, allocation, mobile suitability
- **Docs** — README, dartdoc, examples, guides
- **API** — naming, consistency, type safety, evolvability
- **Sec** — safe defaults, trust boundaries, secret handling
- **Scale** — behaviour at 10× data / traffic / team size
- **Maint** — test quality, code organisation, churn risk
- **Prod** — can a team ship on it today

## 2.3 Scorecard

| Package | Feat | Arch | DX | Perf | Docs | API | Sec | Scale | Maint | Prod | **Score** |
|---|---|---|---|---|---|---|---|---|---|---|---:|
| `agentic_core` | 8 | 10 | 8 | 8 | 9 | 9 | 8 | 8 | 9 | 8 | **85** |
| `agentic_tools` | 7 | 9 | 8 | 8 | 9 | 9 | 9 | 7 | 9 | 8 | **83** |
| `agentic_workflow` | 8 | 9 | 7 | 8 | 8 | 8 | 8 | 7 | 7 | 7 | **77** |
| `agentic_agents` | 7 | 9 | 8 | 8 | 8 | 8 | 8 | 6 | 7 | 7 | **76** |
| `agentic_rag` | 8 | 9 | 7 | 7 | 8 | 8 | 8 | 6 | 8 | 7 | **76** |
| `agentic_tools_generator` | 6 | 8 | 8 | 8 | 7 | 8 | 8 | 8 | 8 | 7 | **76** |
| `agentic_llm` | 6 | 9 | 8 | 7 | 8 | 8 | 7 | 7 | 7 | 6 | **73** |
| `agentic_vector` | 6 | 9 | 8 | 7 | 8 | 9 | 7 | 5 | 8 | 6 | **73** |
| `agentic_test` | 6 | 8 | 8 | 8 | 7 | 8 | 7 | 6 | 8 | 6 | **72** |
| `agentic_benchmark` (internal) | 7 | 8 | 7 | 8 | 6 | 7 | 7 | 7 | 8 | 7 | **72** |
| `agentic_memory` | 7 | 8 | 7 | 6 | 8 | 8 | 7 | 5 | 8 | 6 | **70** |
| `agentic_flutter` | 6 | 9 | 7 | 7 | 7 | 7 | 8 | 6 | 7 | 6 | **70** |
| `agentic_integration` (internal) | 6 | 8 | 6 | 7 | 6 | 7 | 7 | 7 | 8 | 6 | **68** |
| `agentic_mcp` | 5 | 9 | 7 | 7 | 7 | 8 | 6 | 6 | 7 | 5 | **67** |
| `agentic_sqlite` | 6 | 8 | 7 | 6 | 7 | 8 | 6 | 5 | 8 | 6 | **67** |
| `create_agentic_app` | 5 | 7 | 8 | 7 | 6 | 7 | 8 | 5 | 6 | 5 | **64** |
| **Ecosystem (weighted by importance)** | | | | | | | | | | | **74** |

**Reading the scores.** Architecture is 8–10 everywhere; that is not the
constraint. The low columns are **Feat**, **Scale** and **Prod**, and they are
low for the same reason: the framework's foundations are ahead of its
integrations (providers, stores, protocol versions, UI). The fastest route from
74 to 90 is breadth on top of the existing seams, not redesign.

---

## 2.4 Per-package analysis

### `agentic_core` — 85/100

**Current features.** `Message` + sealed `ContentPart` (text, image, audio,
file, reasoning, tool call, tool result); `JsonSchema` with LLM-aware coercion;
a typed `AgenticException` hierarchy with `code` and `isRetryable`;
`CancellationToken`; `RetryPolicy`, four backoff strategies, `CircuitBreaker`;
`EventBus`; `StructuredLogger` with redaction; `Tracer` / `Span` /
`SpanExporter` with `TraceContext`; `Registry<T>`; `AgenticContext`; `Clock`,
`Ulid`, `Result`; `UntrustedContentLedger`.

**Missing.** An OTLP/HTTP span exporter and OpenTelemetry GenAI semantic
conventions; a metrics API (counters, histograms for tokens, latency, cost);
`DocumentPart` / `VideoPart` for native PDF and video input; a portable
`AgenticContext` serialisation for isolate hops; a `Json`-schema-from-type
bridge for `json_serializable` / `freezed`.

**Architecture.** Exemplary. "Vocabulary, not behaviour", no I/O, `base` on open
hierarchies so members can be added in minors.

**DX.** Good, but 107 exported names is a lot to meet first. A "you only need
these eight" section would help.

**Performance.** Immutable values with deep equality are fine at chat scale.
Watch `collection` deep equality on long histories being compared per frame.

**Documentation.** Every public member documented (enforced). Lacks a
narrative guide to context, cancellation and tracing together.

**API design.** Consistent; `Result` as opt-in is the right Dart call.

**Security.** Redaction and untrusted-content primitives present. No PII
classifier hooks yet.

**Scalability / Maintainability.** 247 tests; stable foundation; the risk is
growth — resist adding behaviour here.

**Production readiness.** Ready, once traces can leave the process.

---

### `agentic_tools` — 83/100

**Current features.** `Tool`, `ToolSpec`, `FunctionTool`, `ToolRegistry`
(tags, lazy construction), `ToolSet`, `ToolExecutor` (bounded concurrency,
per-tool timeouts), argument repair and validation, approval gating with
`ToolApprovalHandler`, `UntrustedContentPolicy`, `RenamedTool`,
`DelegatingTool`, `@ToolFunction` / `@ToolParam` annotations.

**Missing.** Output schemas (structured tool results, now in MCP); progress
and partial results from long-running tools; semantic tool search for large
registries (tags are not enough past ~40 tools); per-tool rate limits and
quotas; a permission/scope model richer than approve/deny (for example "approve for
this session", "approve for arguments matching X"); a code-execution sandbox
tool; first-party toolkits (HTTP fetch with allow-list, date/time, math,
file system with roots).

**Architecture.** Correct placement below `agentic_llm`; "expected failures are
values" is right for model-facing code.

**DX / API.** Clean. The annotation plus generator path is a real
differentiator.

**Security.** Strongest package on this axis: approval, untrusted content, and
honest "no handler means denied".

**Scalability.** A flat `ToolSet` sent in full with every request does not
scale to hundreds of MCP tools — needs dynamic selection.

**Production readiness.** High.

---

### `agentic_llm` — 73/100

**Current features.** `ChatModel` / `EmbeddingModel` ports; streaming with
tool-call reassembly; a spec-compliant SSE decoder; structured output with
tool-forcing fallback; `ModelInfo` with capabilities, context window and
pricing; adapters: `OpenAiCompatibleChatModel` (OpenAI, DeepSeek, Grok,
Mistral, Ollama, llama.cpp, custom), `AnthropicChatModel`, `GeminiChatModel`,
two embedding adapters; decorators: `RetryingChatModel`, `FallbackChatModel`
(with circuit breaker), `CachingChatModel`, `ObservableChatModel`; reasoning
deltas and `ReasoningEffort`.

**Missing (in order of developer demand).**
1. OpenAI **Responses API** (stateful, built-in tools, reasoning items) — OpenAI's
   recommended surface for new work, and the only one exposing some reasoning
   and built-in-tool features.
2. **Prompt caching controls** (Anthropic `cache_control`, Gemini cached
   content) — the largest cost lever for agents; `ModelCapability.promptCaching`
   exists but nothing sets breakpoints.
3. **Cloud-auth providers**: Azure OpenAI, AWS Bedrock (SigV4), Google Vertex
   AI (service-account / ADC). Enterprise buyers are on these.
4. **Token counting** before sending (context-window management, cost preview).
5. **On-device models** — Gemini Nano (ML Kit GenAI Prompt API), Apple
   Foundation Models, LiteRT-LM (MediaPipe LLM Inference is now
   maintenance-only), llama.cpp — ideally by bridging the packages that already
   do the native work well (`flutter_gemma`, `llamadart`).
6. **Realtime / audio** sessions (voice agents).
7. Image generation, batch APIs, files APIs, provider-native web search and
   code execution tools.
8. A maintained **model catalogue** (IDs, windows, prices) decoupled from
   adapter releases — the fix for finding X1.

**Architecture.** The best design decision in the repository: one adapter per
*wire format*, not per vendor, with a table proving the abstraction.

**Performance.** Streaming is incremental. JSON decoding of large responses and
base64 image encoding run on the calling isolate.

**Security.** Keys are plain constructor strings; no hook for short-lived token
providers (needed for proxies and ephemeral keys).

**Maintainability.** Provider drift is the maintenance tax. Nightly
conformance now runs correctly, but defaults hard-coded in constructors will
keep rotting.

**Production readiness.** Fine for OpenAI/Anthropic/Gemini direct. Not yet for
enterprise clouds.

---

### `agentic_agents` — 76/100

**Current features.** `ToolCallingAgent` with required `AgentBudget` across
five dimensions; forbids tools on the final iteration; `AgentSession` with
`HistoryStrategy` (keep-all, sliding window, character budget);
`SessionStore`; streaming `AgentChunk` family; `PlannerExecutorAgent`;
`AgentTool` delegation with depth limit; `supervisorOver`; `DelegatingAgent`
for cross-cutting behaviour; `stopWhen`; `repairDanglingToolResults`.

**Missing.** **Handoffs** (transfer of control, not a tool call returning);
**guardrails** as a first-class concept (input, output and tool-call checks
with tripwires); **durable, resumable agent runs** (sessions persist history,
not in-flight state); **interrupts** — pausing mid-run for human input beyond
tool approval; **shared budgets** across a delegation tree (explicitly not
enforced today); **context compaction** that summarises tool results; a
**"deep agent"** harness (to-do list, scratch file system, sub-agents); A2A
remote agents; parallel sub-agent fan-out.

**Architecture.** Delegation-as-tool is elegant and inherits every guarantee.
It is also why handoffs are missing: a handoff is not a tool call that returns.

**Scalability.** Budgets not nesting means a supervisor with five workers can
spend six budgets. Fine for one user; not for a fleet.

**Maintainability.** 55 tests in one 1,279-line file.

**Production readiness.** Good for single-agent assistants today.

---

### `agentic_workflow` — 77/100

**Current features.** `WorkflowGraph` validated on construction with data-flow
analysis; 16 exported node types (start, end, LLM, structured LLM, agent,
tool, condition, switch, loop, map, parallel with `maxConcurrency`, delay,
human approval, wait-for-event, transform, custom); `WorkflowBudget`; resumable runs via
versioned `WorkflowSnapshot` and `WorkflowSnapshotStore`; `toMermaid()`.

**Missing.** Sub-workflows (graph as a node); per-node retry and timeout
policies; typed state (`WorkflowState` is a JSON map); declarative definitions
(JSON/YAML) — the prerequisite for a visual builder and for sharing workflows;
time-travel (fork from any checkpoint, not only suspension points); durable
timers that survive process death; triggers (cron, webhook, event); streaming
of node output tokens to the UI; distributed/remote node execution.

**Architecture.** Validation before execution is a genuine advantage over
LangGraph, whose invalid graphs fail at run time.

**DX.** Builder API is verbose for simple chains; a fluent or functional
"graph DSL" would shorten the common case.

**Production readiness.** Good for in-app multi-step flows with approval.

---

### `agentic_memory` — 70/100

**Current features.** One `MemoryStore` port over working, conversation,
long-term, semantic and shared memory; keyword, embedded and hybrid (RRF)
recall; `RecallingHistory` and `SummarisingHistory`; `RememberingAgent`;
extraction events; remember/recall/forget tools.

**Missing.** Memory **consolidation** (merge, deduplicate, resolve
contradictions); **temporal / episodic** memory with validity windows;
**decay and importance**; **user-controlled memory** (inspect, edit, export,
"forget me" — also a GDPR requirement); **encryption at rest**; **profile
memory** (structured user facts with schemas); knowledge-graph memory;
memory evals (did recall help?).

**Performance / Scale.** In-memory scoring scans every entry; fine below
~10 k entries, not beyond.

**Production readiness.** Good for personal assistants with a
`agentic_sqlite` backing; not for multi-tenant servers.

---

### `agentic_vector` — 73/100

**Current features.** `VectorStore` port; sealed `MetadataFilter`;
`SimilarityMetric` where higher is always better; exact
`InMemoryVectorStore` with JSON snapshots; `QdrantVectorStore`;
`NamespacedVectorStore`; `ObservableVectorStore`; `EmbeddingIndex` with
batching and width checks.

**Missing.** Adapters for **pgvector / Supabase, Pinecone, Chroma, Weaviate,
Milvus, Turbopuffer, ObjectBox** (ObjectBox has on-device HNSW and is already
popular in Flutter); **sqlite-vec**; an in-process **HNSW** index for >100 k
vectors; **Float32** storage and scalar/binary **quantisation** (Float64 doubles
memory on a phone for no ranking benefit); sparse vectors for native hybrid
search; isolate offload for search.

**API.** One of the cleanest ports in the repository.

**Production readiness.** Strong for small on-device corpora; limited for
server-side scale by adapter coverage.

---

### `agentic_rag` — 76/100

**Current features.** Loaders (text, Markdown, HTML, composite); chunkers
(fixed, recursive, Markdown-aware); `RagIndexer` with stable IDs, content
fingerprints and tail deletion; vector, keyword (BM25), hybrid (RRF) and
neighbour-expanding retrievers; rerankers (LLM, MMR, score floor, chained);
cited answers with `isGrounded`; `RagStack`; streaming pipeline events;
search and answering tools.

**Missing.** **PDF, DOCX, EPUB, CSV** loaders and **multimodal** ingestion
(images, scanned pages via vision models); **contextual retrieval** (prepend
LLM-generated chunk context); **query transformation** (rewrite, multi-query,
HyDE, decomposition); hosted **cross-encoder rerankers** (Cohere, Voyage,
Jina); **RAG evaluation** (faithfulness, context precision/recall);
**connectors** with incremental sync (Google Drive, Notion, Confluence,
GitHub, local folders); **agentic RAG** (iterative retrieve-reason loops);
GraphRAG.

**Architecture.** Small ports, each testable. Citations as a first-class
concept with `isGrounded` is better than most Python frameworks.

**Production readiness.** Good for Markdown/HTML corpora — which excludes most
enterprise documents until PDF lands.

---

### `agentic_sqlite` — 67/100

**Current features.** `AgenticDatabase` with schema versioning;
`SqliteVectorStore`, `SqliteMemoryStore`, `SqliteSessionStore`,
`SqliteWorkflowSnapshotStore`; `sqlite3` 3.x build hooks so tests run on the VM.

**Missing.** **FTS5** keyword index (BM25 in the database instead of in Dart
memory); **sqlite-vec** ANN search; **encryption** (SQLCipher / SQLite3MC);
**web** support via the WASM build; a background-isolate connection;
stores for `ChatCache`, `UntrustedContentLedger` and eval results; migration
tooling exposed to apps; a Drift interop layer (Drift is the dominant Flutter
SQL package).

**Scale.** Vector search loads rows and scores in Dart — fine to ~50 k vectors.

**Production readiness.** Good for a single-user app; needs encryption before
anything holding personal data ships.

---

### `agentic_mcp` — 67/100

**Current features.** JSON-RPC layer; `McpClient` with version negotiation
(2024-11-05, 2025-03-26, 2025-06-18); tools, resources, resource templates and
prompts; structured content; roots and sampling handler hooks; stdio,
streamable HTTP (client) and in-process transports; `McpServer` publishing a
`ToolRegistry`; annotation-tightening rule; approval-required tools not
published.

**Missing.** The package is **two spec versions behind**. The current MCP
specification is **2026-07-28** (GA 28 July 2026), which follows 2025-11-25:

- *2025-11-25*: icons, URL-mode elicitation, tool calling inside sampling,
  Client ID Metadata Documents, experimental tasks, JSON Schema 2020-12 default.
- *2026-07-28*: a **stateless core** (no `initialize`, no `Mcp-Session-Id`;
  version and capabilities in `_meta`; required `server/discover`);
  **multi-round-trip requests** (`resultType: "input_required"` replaces
  server-to-client requests); `subscriptions/listen`; tasks as an official
  extension; required `Mcp-Method` / `Mcp-Name` headers; `traceparent` in
  `_meta`; **roots, sampling, logging and HTTP+SSE deprecated**; Dynamic Client
  Registration deprecated in favour of CIMD.

Beyond versions: **OAuth 2.1 authorization** (protected-resource metadata,
PKCE, CIMD, RFC 9207 `iss` validation) — required by nearly every remote MCP
server; **elicitation** (maps directly onto the existing approval sheet); a
**streamable HTTP server** host (today the server runs over stdio or in-process
only); **MCP Apps** (`ui://` resources, stable since January 2026); MCP registry
discovery; progress surfaced as tool progress; interop tests against the
TypeScript and Python reference SDKs.

**Competitive context.** The community `mcp_dart` (2.4.2, ~274 k downloads)
already implements 2026-07-28 with OAuth and elicitation. The official
`dart_mcp` (0.5.2) is experimental and has no streamable HTTP or auth. The
opening is to be the best-*integrated* MCP stack (MCP tools as agent tools,
approvals, tracing) rather than to win on raw spec coverage.

**Security.** The trust-boundary rules are excellent; the lack of OAuth means
users paste bearer tokens instead, which is worse.

**Production readiness.** Good for local stdio servers and unauthenticated HTTP;
not for SaaS MCP servers.

---

### `agentic_test` — 72/100

**Current features.** `RecordingChatModel` / `ReplayChatModel` cassettes with
redaction and mismatch errors; `EvalSuite` of `EvalCase`s with checks
(succeeded, answer contains/matches, called/did-not-call tool, max steps, max
tokens, custom, LLM-judged by rubric); trials and pass rates.

**Missing.** **Trajectory** assertions (tool order, arguments, sub-sequences);
**datasets** from JSONL/YAML; **reporters** (JUnit XML, JSON, Markdown, HTML)
for CI; **model comparison** matrices; statistical confidence (pass^k, Wilson
intervals) instead of raw rates; **regression baselines**; **red-team /
prompt-injection suites**; **RAG metrics**; widget-test helpers for
`AgentChatView`; a fake tool/approval harness; cost reports per suite.

**Production readiness.** Good for unit-level agent tests; not yet an eval
platform.

---

### `agentic_tools_generator` — 76/100

**Current features.** `build_runner` generator for `@ToolFunction` functions
and methods: schema, argument decoding, result conversion, build-time checks.

**Missing.** Class-level **toolkits** (`@Toolkit` on a class → a `ToolSet`);
**structured-output schemas** for classes and records (`@AgenticSchema` →
`JsonSchema` + `fromJson`), the most-requested structured-output ergonomics in
every framework; doc comments → descriptions; enums, sealed classes and
`DateTime` mapping; interop with `json_serializable` and `freezed`; generating
an MCP server entry point; lint rules (`custom_lint` / analyzer plugin) that
catch tool-description problems in the IDE.

**Production readiness.** Ready for what it does.

---

### `agentic_flutter` — 70/100

**Current features.** Umbrella re-exports; `AgenticRuntime` and `AgenticScope`;
`LifecycleCancellation` with `BackgroundPolicy`; `SecretStore` family;
`AgentChatController` / `AgentChatView` / `ChatComposer` / `ChatEntryTile`;
`ToolApprovalSheet`; `EventRecorder` / `TraceInspector`; plugin-free device
tools (location, camera, share, ask-user); `FlutterLogSink`.

**Missing.** **Markdown and code rendering** in messages (entries render as
`SelectableText` today); **attachments** and multimodal composer (images,
files, camera); **voice** in and out; **generative UI** — tools that render
widgets (the space Google's GenUI / A2UI now occupies); conversation list and
session switcher; **theming** tokens and slots; message actions (copy, retry,
edit, feedback thumbs); suggestion chips; state-management adapters
(Riverpod, Bloc, Provider, signals); **background execution** for long runs;
accessibility and localisation audit; DevTools extension instead of an in-app
trace panel.

**Performance.** `notifyListeners()` per streamed delta rebuilds the list;
needs throttling and per-entry listenables for long chats.

**API.** Good seams, but only one visual style; teams building branded apps will
re-implement the view.

**Production readiness.** Excellent for prototypes and internal tools; branded
consumer apps will outgrow the widgets.

---

### `create_agentic_app` — 64/100

**Current features.** Generates a working Flutter agent app with chat, tools,
approval, trace panel and key handling; `--provider`; `--force`; generated
project passes its tests (verified for 0.2.0).

**Missing.** Multiple **templates** (RAG app, voice assistant, workflow app,
Dart server agent, MCP server, CLI agent); **interactive** mode;
**`add` subcommands** (`agentic add rag`, `agentic add mcp`) in the style of
shadcn/ui; generated **`AGENTS.md` / skills** so the user's own coding assistant
understands the project; generated **CI** and a **backend key proxy**
(Firebase Functions / Dart Frog / Cloud Run) — the honest answer to "where
does the key live"; `flutter create` folded in so it is one command.

**Production readiness.** A good demo generator; not yet the on-ramp it could
be.

---

### Internal: `agentic_benchmark` (72) and `agentic_integration` (68)

Both are `publish_to: none`, which is right. `agentic_benchmark` also hosts the
API-snapshot tool — consider moving that into a `tool/` package so the
benchmark package has one job. `agentic_integration` is the provider-drift early
warning system and is currently blind until GitHub secrets are set; that should
be treated as a production incident, not a TODO, because X1 is exactly what it
exists to catch.
