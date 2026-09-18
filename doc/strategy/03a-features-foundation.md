# Phase 3a — Feature innovation: foundation layer

`agentic_core` · `agentic_tools` · `agentic_llm`

## How to read a feature entry

Every entry has the same shape:

- **ID and priority** — `Must Have` (blocks adoption or correctness), `High Value`
  (clear demand, differentiates), `Future` (valuable once the base is wider),
  `Experimental` (bets worth prototyping behind `@experimental`).
- **Complexity** — Low / Medium / High / Very High.
- **Effort** — focused engineering time for one experienced maintainer, including
  tests and docs. "1 wk" ≈ 5 working days.
- **Breaking** — whether the change is breaking under the rules in
  `doc/architecture.md §6`.
- **Deps** — new package dependencies (sibling packages are not listed unless
  a new edge is added).

API sketches follow the existing idioms: ports as `abstract interface class`,
decorators extending `Delegating*`, events extending `*Event`, required budgets,
explicit `AgenticContext`.

---

## `agentic_core` — 12 features

### CORE-1 · OTLP exporter and GenAI semantic conventions — **Must Have**

| Complexity | Effort | Breaking | Deps |
|---|---|---|---|
| Medium | 1.5 wk | No | none in core; `http` in a new `agentic_otel` package |

**Why.** Traces that never leave the process do not help in production. Every
serious observability backend (Langfuse, Arize Phoenix, Honeycomb, Datadog,
Grafana Tempo, Google Cloud Trace) ingests OTLP, and most now read the
OpenTelemetry `gen_ai.*` attributes to render LLM spans properly.

**Use cases.** See a slow agent run as a waterfall in Grafana; cost dashboards
in Datadog; Langfuse prompt/response inspection for a Flutter app in beta.

**API.**

```dart
// agentic_core: vocabulary only — attribute keys, no I/O.
abstract final class GenAiAttributes {
  static const operationName = 'gen_ai.operation.name';
  static const requestModel  = 'gen_ai.request.model';
  static const inputTokens   = 'gen_ai.usage.input_tokens';
  // …
}

// agentic_otel (new package): the exporter.
final tracer = Tracer(
  exporter: BatchSpanExporter(
    OtlpHttpSpanExporter(
      endpoint: Uri.parse('https://otel.example.com/v1/traces'),
      headers: {'authorization': 'Bearer $token'},
    ),
    maxBatch: 256,
    flushEvery: const Duration(seconds: 5),
  ),
  sampler: Sampler.ratio(0.1),
);
```

---

### CORE-2 · Metrics API — **High Value**

| Complexity | Effort | Breaking | Deps |
|---|---|---|---|
| Medium | 1 wk | No | none |

**Why.** Events describe individual runs; dashboards need aggregates — tokens per
minute, p95 time-to-first-token, cost per user, tool failure rate.

**Use cases.** Alert when cost per session doubles; SLOs on latency; per-feature
cost attribution.

**API.**

```dart
abstract interface class Meter {
  Counter counter(String name, {String? unit, String? description});
  Histogram histogram(String name, {String? unit, List<double>? buckets});
}

context.meter
    .histogram('gen_ai.client.operation.duration', unit: 's')
    .record(latency.inMilliseconds / 1000, {'gen_ai.request.model': model.info.id});
```

`MetricsFromEvents` bridges the existing `EventBus` so every adapter gets metrics
without code changes.

---

### CORE-3 · `DocumentPart` and `VideoPart` — **High Value**

| Complexity | Effort | Breaking | Deps |
|---|---|---|---|
| Medium | 1 wk (plus adapter work) | **Yes** — `ContentPart` is sealed, so every exhaustive `switch` must add cases (intended by design) | none |

**Why.** Claude, Gemini and GPT accept PDFs natively, Gemini accepts video.
`FilePart` is too generic for adapters to map correctly.

**Use cases.** "Summarise this contract PDF" without a RAG pipeline; video
Q&A on Gemini.

**API.**

```dart
Message.user([
  TextPart('What are the termination clauses?'),
  DocumentPart.bytes(pdfBytes, mimeType: 'application/pdf', title: 'MSA.pdf'),
]);
```

Ship in 0.3.0 with a `dart fix` note; adapters that cannot send the part throw
`CapabilityNotSupportedException` up front.

---

### CORE-4 · Isolate-portable context — **High Value**

| Complexity | Effort | Breaking | Deps |
|---|---|---|---|
| Medium | 1 wk | No | none |

**Why.** Heavy work (embedding maths, BM25, PDF parsing) must leave the UI
isolate, but `AgenticContext` carries a live event bus and cancellation token.

**API.**

```dart
final result = await context.runInIsolate(
  (ctx) => bm25.score(query, corpus, context: ctx),
  // Events, logs and cancellation are bridged over SendPorts.
);
```

---

### CORE-5 · W3C trace-context propagation helpers — **Must Have**

| Complexity | Effort | Breaking | Deps |
|---|---|---|---|
| Low | 2 d | No | none |

**Why.** A Flutter app calling a Dart backend calling an MCP server should appear as
one trace. `TraceContext` exists; parsing and emitting `traceparent` /
`tracestate` headers consistently across `LlmHttpTransport` and
`McpHttpTransport` does not.

**API.** `TraceContext.fromHeaders(headers)`, `traceContext.toHeaders()`, applied
automatically by both HTTP transports when a span is active.

---

### CORE-6 · Schema-from-type bridge — **High Value**

| Complexity | Effort | Breaking | Deps |
|---|---|---|---|
| Low (core) + Medium (generator) | 3 d + see GEN-2 | No | none |

**Why.** Structured output is the most common LLM task after chat. Hand-writing
`JsonSchema` for a class that already has `fromJson` is duplication.

**API.**

```dart
abstract interface class SchemaType<T> {
  JsonSchema get schema;
  T fromJson(Map<String, Object?> json);
}

final invoice = await model.generateAs(request, InvoiceSchema()); // generated
```

---

### CORE-7 · PII detection and redaction port — **High Value**

| Complexity | Effort | Breaking | Deps |
|---|---|---|---|
| Medium | 1 wk | No | none |

**Why.** Regulated apps (health, finance, EU) must not send certain data to a
third-party model, and must not log it. `FieldRedactor` handles known keys only.

**API.**

```dart
abstract interface class PiiDetector {
  Future<List<PiiSpan>> detect(String text, {AgenticContext? context});
}
final redacting = RedactingChatModel(model,
    detector: RegexPiiDetector.standard(), // emails, phones, cards, IBANs
    mode: RedactionMode.pseudonymise);     // reversible within a run
```

(The decorator lives in `agentic_llm`; the port and the regex detector live here.)

---

### CORE-8 · `Usage` ledger with attribution — **High Value**

| Complexity | Effort | Breaking | Deps |
|---|---|---|---|
| Low | 3 d | No | none |

**Why.** "What did user X cost us yesterday, by feature?" is the first question
after launch. `TokenUsage` aggregates, but nothing attributes.

**API.**

```dart
final ledger = UsageLedger(clock: clock);
context = context.withAttributes({'user.id': uid, 'feature': 'summarise'});
// Every LlmResponseCompleted is recorded against the context's attributes.
ledger.totals(groupBy: ['feature']);
```

---

### CORE-9 · Structured error catalogue and doc links — **Must Have**

| Complexity | Effort | Breaking | Deps |
|---|---|---|---|
| Low | 3 d | No | none |

**Why.** Every `AgenticException.code` should link to a page explaining the
cause and the fix. Messages written for an AI coding assistant to act on are also
a direct DX win.

**API.** `exception.helpUrl` →
`https://agentic.dev/errors/rate_limit_exceeded`; `dart run agentic:explain
rate_limit_exceeded` prints the same page offline.

---

### CORE-10 · Deterministic replay clock and ID scopes — **Future**

| Complexity | Effort | Breaking | Deps |
|---|---|---|---|
| Low | 2 d | No | none |

**Why.** Replaying a recorded production run (see TEST-6) needs the same IDs and
timestamps as the original.

**API.** `ReplayClock.fromEvents(events)`, `IdGenerator.replay(ids)`.

---

### CORE-11 · Content provenance on messages — **Experimental**

| Complexity | Effort | Breaking | Deps |
|---|---|---|---|
| Medium | 1 wk | No | none |

**Why.** The untrusted-content ledger works per run. Carrying provenance on each
part (user typed it, tool returned it, retrieved from URL X) enables
per-source policies and "why did the model say this?" UI.

**API.** `TextPart('…', provenance: Provenance.tool('web_fetch', uri: u))`.

---

### CORE-12 · Config loading (`agentic.yaml`) — **Future**

| Complexity | Effort | Breaking | Deps |
|---|---|---|---|
| Low | 3 d | No | `yaml` (in a separate `agentic_config` library, not core) |

**Why.** Server and CLI users want to change models, budgets and retry policies
without recompiling; declarative workflows (WF-4) need a shared format.

---

## `agentic_tools` — 12 features

### TOOLS-1 · Tool output schemas and structured results — **Must Have**

| Complexity | Effort | Breaking | Deps |
|---|---|---|---|
| Low | 3 d | No | none |

**Why.** MCP (2025-06-18) added `outputSchema` / `structuredContent`; workflows
need typed tool outputs to validate data flow; UIs render structured results
better than text.

**API.**

```dart
ToolSpec(
  name: 'get_weather',
  inputSchema: …,
  outputSchema: JsonSchema.object({'tempC': JsonSchema.number()}),
);
ToolResult.structured({'tempC': 21.5}, text: '21.5 °C'); // validated against outputSchema
```

---

### TOOLS-2 · Progress and partial results — **High Value**

| Complexity | Effort | Breaking | Deps |
|---|---|---|---|
| Medium | 1 wk | No | none |

**Why.** A 40-second report generator with no feedback feels broken on a phone.
MCP carries `notifications/progress`; the tool layer should too.

**API.**

```dart
FunctionTool(spec, (invocation) async {
  for (final (i, page) in pages.indexed) {
    invocation.reportProgress(i / pages.length, message: 'Page ${i + 1}');
    …
  }
});
// Surfaces as ToolCallProgress events and AgentToolCallProgress chunks.
```

---

### TOOLS-3 · Semantic tool search (dynamic toolsets) — **Must Have**

| Complexity | Effort | Breaking | Deps |
|---|---|---|---|
| Medium | 1.5 wk | No | uses `agentic_llm` embeddings via an injected function to avoid a new edge |

**Why.** Connecting three MCP servers yields 80+ tools. Sending all of them
wastes tokens and measurably degrades tool choice. Anthropic and OpenAI now
both offer "tool search" patterns.

**Use cases.** Enterprise assistant with hundreds of internal APIs; IDE agents.

**API.**

```dart
final selector = ToolSelector.semantic(
  registry,
  embed: (texts) => embedder.embedAll(texts, purpose: EmbeddingPurpose.document),
  topK: 12,
  alwaysInclude: {'ask_user'},
);
ToolCallingAgent(tools: DynamicToolSet(selector), …);
// Alternatively expose a `search_tools` meta-tool the model calls itself.
```

---

### TOOLS-4 · Scoped approval policies — **Must Have**

| Complexity | Effort | Breaking | Deps |
|---|---|---|---|
| Medium | 1 wk | No | none |

**Why.** Asking for approval on every `send_email` trains users to tap "Approve"
blindly. Claude Code and Cursor popularised "allow for this session" and
argument-pattern rules.

**API.**

```dart
final policy = ApprovalPolicy([
  ApprovalRule.allow('read_file', when: (args) => args['path'].startsWith('/docs')),
  ApprovalRule.deny('delete_*'),
  ApprovalRule.ask('send_email', remember: ApprovalMemory.session),
]);
ToolExecutor(approval: policy.handlerWith(fallback: sheetApprovalHandler(...)));
```

---

### TOOLS-5 · Rate limits and quotas per tool — **High Value**

| Complexity | Effort | Breaking | Deps |
|---|---|---|---|
| Low | 3 d | No | none |

**Why.** A looping agent can hammer a paid API. Budgets bound the agent, not the
API.

**API.** `RateLimitedTool(tool, limit: RateLimit.perMinute(10), onLimit:
RateLimitBehaviour.returnError)`.

---

### TOOLS-6 · First-party toolkits — **High Value**

| Complexity | Effort | Breaking | Deps |
|---|---|---|---|
| Medium | 2 wk | No | `http` (fetch), none otherwise; ship as `agentic_toolkit` |

**Why.** Every framework's first demo needs "fetch a URL", "what time is it",
"do arithmetic safely". Writing them securely (SSRF allow-lists, size caps,
HTML-to-Markdown) is non-trivial.

**API.**

```dart
registry.registerAll([
  webFetchTool(allowHosts: {'*.wikipedia.org'}, maxBytes: 512 * 1024),
  clockTool(),
  calculatorTool(),               // expression parser, no eval
  fileSystemTools(roots: [docsDir], readOnly: true),
]);
```

---

### TOOLS-7 · Sandboxed code execution tool — **Experimental**

| Complexity | Effort | Breaking | Deps |
|---|---|---|---|
| High | 3 wk | No | remote sandbox adapters (E2B, Daytona, a container you run); a WASM Python (Pyodide) for desktop/web |

**Why.** Code execution is the most capable general tool (data analysis,
charts). Doing it on-device is unsafe; doing it remotely needs a port.

**API.** `codeExecutionTool(sandbox: E2bSandbox(apiKey: …), languages:
{'python'}, timeout: 30.seconds)`.

---

### TOOLS-8 · Tool result caching and idempotency keys — **High Value**

| Complexity | Effort | Breaking | Deps |
|---|---|---|---|
| Low | 3 d | No | none |

**Why.** Resumed workflows and retried agent steps must not charge a card
twice. Read-only tools benefit from caching.

**API.** `ToolSpec(idempotent: true)`, `invocation.idempotencyKey` (stable across
resume), `CachingTool(tool, ttl: 5.minutes)`.

---

### TOOLS-9 · Tool description linting — **High Value**

| Complexity | Effort | Breaking | Deps |
|---|---|---|---|
| Low | 3 d | No | none |

**Why.** Tool descriptions are prompts. Vague names, missing parameter
descriptions and overlapping tools are the top cause of wrong tool choice.

**API.** `ToolLinter().check(registry)` → warnings such as
`tool_description_too_short`, `parameter_undocumented`,
`tools_overlap(search_docs, find_docs)`. Also wired into GEN-6 and the CLI.

---

### TOOLS-10 · Tool call confirmations with diff previews — **Future**

| Complexity | Effort | Breaking | Deps |
|---|---|---|---|
| Medium | 1 wk | No | none |

**Why.** "Approve `update_record`?" is meaningless without seeing what changes.

**API.** `ToolSpec(preview: (args, ctx) async => ToolPreview.diff(before,
after))`; `ToolApprovalSheet` renders it.

---

### TOOLS-11 · OpenAPI → tools importer — **High Value**

| Complexity | Effort | Breaking | Deps |
|---|---|---|---|
| Medium | 2 wk | No | `yaml`; ship in `agentic_toolkit` |

**Why.** Most company APIs have OpenAPI specs. One call should expose selected
operations as tools, with auth injected and never visible to the model.

**API.** `OpenApiToolkit.fromUrl(specUrl, include: {'getOrder',
'listOrders'}, auth: BearerAuth(token))`.

---

### TOOLS-12 · Client-side (UI-executed) tools — **High Value**

| Complexity | Effort | Breaking | Deps |
|---|---|---|---|
| Low | 3 d | No | none |

**Why.** When the agent runs on a server (see new package `agentic_server`),
some tools must execute on the phone (location, camera, confirm). This is the
AG-UI "frontend tool" pattern.

**API.** `ToolSpec(execution: ToolExecution.client)` — the executor emits
`ToolCallDeferred`, and the run resumes when the client posts the result.

---

## `agentic_llm` — 18 features

### LLM-1 · Model catalogue decoupled from adapters — **Must Have**

| Complexity | Effort | Breaking | Deps |
|---|---|---|---|
| Medium | 1 wk | **Soft** — default model IDs move from constructor defaults to catalogue aliases | none (bundled JSON + optional remote refresh) |

**Why.** Finding X1: hard-coded defaults (`gpt-4o`,
`claude-sonnet-4-20250514`, `grok-2-latest`) rot and break users silently,
as Gemini already did. Prices and context windows rot the same way.

**API.**

```dart
final catalogue = ModelCatalogue.bundled();          // shipped JSON, versioned
await catalogue.refresh(from: ModelCatalogue.defaultSource); // optional

GeminiChatModel(apiKey: k, model: ModelAlias.fast);  // resolves to a dated ID
catalogue.lookup('anthropic/claude-sonnet-4-5')?.pricing;
catalogue.deprecations();                            // warns before retirement
```

A nightly job diffs provider model-list endpoints against the catalogue and opens
a PR.

---

### LLM-2 · OpenAI Responses API adapter — **Must Have**

| Complexity | Effort | Breaking | Deps |
|---|---|---|---|
| High | 2.5 wk | No | none |

**Why.** OpenAI's recommended API: reasoning items carried across turns,
built-in tools (web search, file search, code interpreter, remote MCP),
server-side conversation state, background mode.

**API.**

```dart
final gpt = OpenAiResponsesChatModel(
  apiKey: key,
  model: ModelAlias.openAiFlagship,
  builtInTools: {OpenAiBuiltInTool.webSearch()},
  store: false, // stateless by default; reasoning items round-trip in ContentPart
);
```

---

### LLM-3 · Prompt caching controls — **Must Have**

| Complexity | Effort | Breaking | Deps |
|---|---|---|---|
| Medium | 1 wk | No | none |

**Why.** Agent loops resend the same system prompt and tool list every turn.
Caching typically cuts input cost on long runs by well over half. Today
`ModelCapability.promptCaching` is declared but nothing sets cache breakpoints.

**API.**

```dart
ChatRequest(
  messages: history,
  cache: PromptCachePolicy.auto(), // system + tools + stable prefix
);
// Anthropic: cache_control breakpoints; Gemini: cachedContents; OpenAI: automatic.
// TokenUsage gains cacheReadTokens / cacheWriteTokens; ModelPricing already has cachedInputPerMillion.
```

---

### LLM-4 · Cloud-auth providers: Azure OpenAI, AWS Bedrock, Vertex AI — **Must Have** (enterprise)

| Complexity | Effort | Breaking | Deps |
|---|---|---|---|
| High | 3 wk total | No | `crypto` for SigV4 (already in the tree); `googleapis_auth` for Vertex, isolated in `agentic_llm_cloud` |

**Why.** Enterprises buy models through their cloud contract. No Dart framework
covers all three well.

**API.**

```dart
BedrockChatModel(region: 'eu-west-1', credentials: AwsCredentials.fromEnvironment(),
    model: 'anthropic.claude-…');
VertexGeminiChatModel(project: p, location: 'europe-west4', auth: GoogleAuth.adc());
AzureOpenAiChatModel(endpoint: e, deployment: 'gpt-prod', auth: AzureAuth.entraId(token));
```

---

### LLM-5 · Credential providers (short-lived tokens) — **Must Have**

| Complexity | Effort | Breaking | Deps |
|---|---|---|---|
| Low | 3 d | No (new optional parameter) | none |

**Why.** The honest mobile answer is a backend minting short-lived keys or
proxying. Adapters need a `Future<String> Function()` rather than a string.

**API.** `GeminiChatModel(credentials: CredentialProvider.refreshing(() =>
backend.mintKey(), ttl: 10.minutes))`.

---

### LLM-6 · Token counting — **High Value**

| Complexity | Effort | Breaking | Deps |
|---|---|---|---|
| Medium | 1 wk | No | none (provider endpoints) + optional local BPE tables in a separate library |

**Why.** Context-window management by characters (`CharacterBudgetHistory`) is
imprecise; cost previews need tokens.

**API.** `await model.countTokens(request)` with a
`TokenCounter.estimate()` fallback; a `TokenBudgetHistory` strategy in agents.

---

### LLM-7 · On-device model adapters — **Must Have** (strategic)

| Complexity | Effort | Breaking | Deps |
|---|---|---|---|
| Very High | 5 wk | No | platform packages, isolated in `agentic_llm_local` (see Phase 4) |

**Why.** Privacy, offline use and zero marginal cost are a Flutter-native
advantage no Python framework can claim. Targets: Gemini Nano (ML Kit GenAI
Prompt API, alpha), Apple Foundation Models, LiteRT-LM (Google now recommends it
over the maintenance-only MediaPipe LLM Inference) and llama.cpp.

**Build versus bridge.** Do not re-implement native runtimes. `flutter_gemma`
(1.8.x, 434 likes, LiteRT-LM on all six platforms) and `llamadart` (GGUF and
`.litertlm`, including web) already do the hard FFI work. Ship thin
`ChatModel` / `EmbeddingModel` adapters over them, and own what they lack:
capability negotiation, routing, budgets, download management and tool-calling
fallbacks for small models.

**API.**

```dart
final local = await OnDeviceChatModel.best(
  prefer: [OnDeviceBackend.appleFoundation, OnDeviceBackend.geminiNano, OnDeviceBackend.llamaCpp],
  fallbackModelUrl: gemma3nUrl,
);
final model = FallbackChatModel([local, cloud]); // existing decorator
```

---

### LLM-8 · Router: cost-, latency- and capability-aware — **High Value**

| Complexity | Effort | Breaking | Deps |
|---|---|---|---|
| Medium | 1.5 wk | No | none |

**Why.** `FallbackChatModel` handles failure. Teams also want "cheap model for
simple turns, strong model for hard ones" and "on-device when offline".

**API.**

```dart
final model = RoutingChatModel(
  routes: [
    Route(when: RouteWhen.offline, to: local),
    Route(when: RouteWhen.requires({ModelCapability.vision}), to: gemini),
    Route(when: RouteWhen.classifiedAs('simple', by: classifier), to: flashLite),
  ],
  fallback: flagship,
);
```

---

### LLM-9 · Realtime / voice sessions — **High Value**

| Complexity | Effort | Breaking | Deps |
|---|---|---|---|
| Very High | 4 wk | No | `web_socket_channel`; lives in `agentic_voice` (Phase 4) |

**Why.** Voice agents are the fastest-growing agent category, and mobile is where
voice happens. OpenAI Realtime and Gemini Live both use bidirectional
WebSockets with tool calls mid-conversation.

**API.** `RealtimeModel.connect(...)` returning a `RealtimeSession` with
`Sink<AudioFrame> input`, `Stream<RealtimeEvent> events`, and tool execution
through the existing `ToolExecutor`.

---

### LLM-10 · Structured output streaming (partial JSON) — **High Value**

| Complexity | Effort | Breaking | Deps |
|---|---|---|---|
| Medium | 1 wk | No | none |

**Why.** UIs want to render a recipe card as fields arrive, not after 8 seconds.

**API.** `model.streamStructured<Recipe>(request, schema: …)` →
`Stream<Partial<Recipe>>` built on a tolerant incremental JSON parser.

---

### LLM-11 · Provider-native built-in tools — **High Value**

| Complexity | Effort | Breaking | Deps |
|---|---|---|---|
| Medium | 1.5 wk | No | none |

**Why.** Gemini Google Search grounding and code execution, Anthropic web search
and web fetch, OpenAI web and file search run server-side and return citations.
Emulating them locally is worse.

**API.** `ChatRequest(builtInTools: {BuiltInTool.webSearch(maxUses: 3)})`
translated per adapter; unsupported → `CapabilityNotSupportedException`.
Citations surface as a new `CitationPart` (in the same breaking window as CORE-3).

---

### LLM-12 · Batch API support — **Future**

| Complexity | Effort | Breaking | Deps |
|---|---|---|---|
| Medium | 1 wk | No | none |

**Why.** Offline evaluation, bulk enrichment and nightly indexing cost half as
much on batch endpoints.

**API.** `BatchChatModel.submit(requests)` → `BatchJob` with `poll()` and
`results()`.

---

### LLM-13 · Image generation and editing port — **Future**

| Complexity | Effort | Breaking | Deps |
|---|---|---|---|
| Medium | 1.5 wk | No | none |

**API.** `ImageModel.generate(ImageRequest(prompt: …, size: …))` with OpenAI,
Gemini and Imagen adapters; as a tool via `imageGenerationTool(model)`.

---

### LLM-14 · Speech-to-text and text-to-speech ports — **High Value**

| Complexity | Effort | Breaking | Deps |
|---|---|---|---|
| Medium | 1.5 wk | No | none |

**Why.** A non-realtime voice UX (push to talk) only needs STT + chat + TTS, and
works with any chat model.

**API.** `SpeechToTextModel.transcribe(audio)`,
`TextToSpeechModel.synthesise(text, voice: …)` with OpenAI, Gemini, ElevenLabs
and platform (on-device) adapters.

---

### LLM-15 · Rate-limit-aware request scheduler — **High Value**

| Complexity | Effort | Breaking | Deps |
|---|---|---|---|
| Medium | 1 wk | No | none |

**Why.** Parallel workflow branches and RAG indexing hit 429s. Retrying is
reactive; a token bucket that reads `x-ratelimit-*` headers is proactive.

**API.** `ThrottledChatModel(model, limits: RateLimits.fromHeaders())`.

---

### LLM-16 · Mid-stream retry and resumption — **Future**

| Complexity | Effort | Breaking | Deps |
|---|---|---|---|
| High | 1.5 wk | No | none |

**Why.** A dropped connection 90 % of the way through a long answer on mobile
should not restart from zero. Where the provider supports background or resumable
responses, resume; otherwise continue with "continue from: …" prefill.

---

### LLM-17 · Guardrail decorators — **High Value**

| Complexity | Effort | Breaking | Deps |
|---|---|---|---|
| Medium | 1 wk | No | none |

**Why.** Input moderation and output checks are needed at the model boundary
too, not only in agents (see AGENTS-2).

**API.** `GuardedChatModel(model, input: [PromptInjectionCheck(),
PiiCheck()], output: [JsonValidCheck(), ModerationCheck(openAiModeration)])`.

---

### LLM-18 · Provider conformance kit for third parties — **High Value**

| Complexity | Effort | Breaking | Deps |
|---|---|---|---|
| Low | 3 d | No | `test` (in `agentic_test`) |

**Why.** Community adapters (Cohere, Bedrock-community, local servers) must be
able to prove they conform. `agentic_integration` has the suite but is
unpublished.

**API.** `chatModelConformance(() => MyChatModel(), capabilities: {...})` — a
function that registers the shared battery in the caller's own `test` file.
