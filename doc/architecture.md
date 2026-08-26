# Architecture

How the framework is layered, what each package owns, where the extension points
are, and the shapes the not-yet-built packages are designed against.

Every package described here is built. The document is kept honest — a section
claims only what the code does — and it records the decisions that are not
visible from an API listing.

---

## 1. Layering

Dependencies point strictly downward. A package may depend on the layers below
it and never on a sibling or a layer above.

```
                    ┌───────────────────────────────┐
      Presentation  │        agentic_flutter        │  widgets, platform tools
                    └───────────────┬───────────────┘
                                    │
        ┌──────────────┬────────────┼──────────────┬───────────────┐
        │              │            │              │               │
 ┌──────┴──────┐ ┌─────┴──────┐ ┌───┴────────┐ ┌───┴─────────┐ ┌───┴────────┐
 │  agentic_   │ │  agentic_  │ │  agentic_  │ │  agentic_   │ │  agentic_  │
 │   memory    │ │  workflow  │ │    rag     │ │    mcp      │ │   agents   │
 └──────┬──────┘ └─────┬──────┘ └───┬────────┘ └───┬─────────┘ └───┬────────┘
        │              │            │              │               │
        │              │      ┌─────┴────────┐     │               │
        │              │      │agentic_vector│     │               │
        │              │      └─────┬────────┘     │               │
        │              │            │              │               │
        └──────────────┴────────────┴──────────────┴───────────────┘
                                    │
                           ┌────────┴────────┐
                           │   agentic_llm   │
                           └────────┬────────┘
                                    │
                           ┌────────┴────────┐
                           │  agentic_tools  │
                           └────────┬────────┘
                                    │
                           ┌────────┴────────┐
                           │  agentic_core   │
                           └─────────────────┘
                            no dependencies
                            beyond meta + collection
```

`agentic_memory` and `agentic_workflow` also depend on `agentic_agents`, which
is why it is drawn on the same row rather than below them: both extend an agent
rather than being extended by one.

The nine packages below `agentic_flutter` share one pub workspace.
`agentic_flutter` does not, for a reason that is a property of the tooling
rather than of the design; see its section below.

`agentic_llm` sits *above* `agentic_tools` rather than beside it. A modern model
abstraction cannot avoid the tool vocabulary — a `ChatRequest` has to carry the
tools the model may call — while `agentic_tools` knows nothing about models. The
dependency is one-directional and the layering stays acyclic; the alternative,
hoisting `ToolSpec` into the core, would split the tool contract across two
packages for no benefit.

`agentic_vector` sits directly above `agentic_llm` — it needs the embedding port
and nothing else — and `agentic_rag` composes it with `agentic_tools` to expose
retrieval as a tool. Neither knows about agents, workflows or memory, which is
what lets an application use retrieval without an agent and an agent without
retrieval.

### Why this shape

**The core owns vocabulary, not behaviour.** A `Message` means the same thing to
a provider adapter, a memory store and a widget. If any of them owned it, the
others would depend on that one.

**Ports live below their adapters.** `ChatModel` will be defined in
`agentic_llm`; the OpenAI adapter implements it. Nothing in the core knows what
OpenAI is, so a new provider is a new package rather than a core change.

**Flutter is a leaf.** Only `agentic_flutter` may import Flutter. Everything
below it runs on a server, in a CLI, or in a test with no widget binding — which
is also what keeps the test suite at one second.

**Plugins depend on a layer, not the framework.** A tool package depends on
`agentic_tools` alone. A vector store depends on `agentic_vector` alone. Nobody
pulls in a whole framework to add one capability.

---

## 2. What each package owns

### `agentic_core` — ✅ built

The vocabulary. Immutable value objects and pure ports.

| Concern | Answer |
|---|---|
| What is a conversation turn? | `Message` + sealed `ContentPart` |
| What is a contract? | `JsonSchema` |
| What went wrong? | `AgenticException` with `code` and `isRetryable` |
| How do I stop? | `CancellationToken` |
| When do I try again? | `RetryPolicy`, `BackoffStrategy`, `CircuitBreaker` |
| What happened? | `EventBus`, `AgenticLogger`, `Tracer` |
| Where am I? | `AgenticContext` |
| How is a plugin found? | `Registry<T>` |

**Rule:** nothing here performs I/O. If it needs a socket or a file, it belongs
in an adapter.

### `agentic_tools` — ✅ built

What an agent can *do*. `Tool`, `ToolSpec`, `ToolRegistry`, `ToolSet`,
`ToolExecutor`. Owns argument repair and validation, approval gating, time
budgets, bounded-concurrency batching and lifecycle events.

**Rule:** expected failures are returned as values. Only a caller's cancellation
escapes.

### `agentic_llm` — ✅ built

Provider-independent model access. The port:

```dart
abstract interface class ChatModel {
  ModelInfo get info;                       // id, context window, capabilities
  Future<ChatResponse> generate(ChatRequest request, {AgenticContext? context});
  Stream<ChatChunk> stream(ChatRequest request, {AgenticContext? context});
}

abstract interface class EmbeddingModel {
  Future<List<Embedding>> embed(List<String> inputs, {AgenticContext? context});
}
```

`ChatRequest` carries messages, a `ToolSet`, sampling parameters, an optional
response schema and provider passthrough. `ChatResponse` carries a `Message`,
`TokenUsage`, a `FinishReason` and the provider's request id.

**Adapters shipped.** One `OpenAiCompatibleChatModel` covers OpenAI, DeepSeek,
Grok, Mistral, Together, Groq, Ollama and llama.cpp by base URL alone — they all
speak the same wire format, and pretending otherwise would mean eight
near-identical adapters drifting apart with every fix. Anthropic and Gemini get
native adapters because their formats genuinely differ, and each difference is a
place a naive translation produces a rejected request:

| | OpenAI | Anthropic | Gemini |
|---|---|---|---|
| System prompt | a message | top-level `system` | `systemInstruction` |
| Tool results | `tool` role, one per message | `tool_result` blocks in a *user* turn, batched | `functionResponse` parts in a user turn |
| Assistant role | `assistant` | `assistant` | `model` |
| `max_tokens` | optional | **required** | optional |
| Tool correlation | by call id | by call id | **by name** |
| Streaming | one repeated chunk shape | seven named event types | candidate deltas |
| Structured output | `response_format` | none — force a tool call | `responseSchema`, OpenAPI subset |

The last row is why `AnthropicChatModel` does *not* declare
`ModelCapability.structuredOutput`: claiming it would be a lie that produces
worse results than the tool-forcing fallback `generateStructured` uses instead.

Supporting a third genuinely different shape is the test of the abstraction. If
`ChatRequest` had quietly been an OpenAI request in disguise, the Gemini adapter
is where that would have become obvious.

**Middleware as decorators**, not as a pipeline framework:

```dart
final model = RetryingModel(
  CachingModel(
    LoggingModel(OpenAiCompatibleChatModel(...)),
    cache: store,
  ),
  policy: RetryPolicy.interactive,
);
```

Each decorator is a `ChatModel` wrapping a `ChatModel`. Composition is ordinary
Dart, order is visible at the call site, and a user's own decorator is
indistinguishable from a built-in one.

**Capability negotiation.** `ModelInfo.supports(Capability.toolCalling)` lets
layers above degrade deliberately — falling back to prompt-based tool selection
on a small local model — rather than parsing an error.

### `agentic_agents` — ✅ built

The loop. `Agent.run(input)` → reason → call tools → observe → repeat until the
model stops requesting tools or a budget is reached.

```dart
abstract interface class Agent {
  AgentInfo get info;
  Future<AgentResult> run(AgentInput input, {AgentSession? session});
  Stream<AgentEvent> runStreaming(AgentInput input, {AgentSession? session});
}
```

Budgets are first-class: max iterations, max tokens, max wall clock, max cost,
max tool calls. An agent that loops forever is the characteristic failure of
this architecture, and it must be bounded by construction rather than by hope.

Shipped: `ToolCallingAgent` (the workhorse), `PlannerExecutorAgent` (decompose,
run each step in isolation, synthesise), and `AgentTool` for delegation, where
handing work to a sub-agent is modelled as *a tool call* — so delegation needs
no new mechanism and inherits validation, consent, tracing and cancellation
unchanged.

Two consequences worth recording. The loop forbids tool calling on its last
permitted iteration, so exhausting a budget yields a best-effort answer rather
than an unanswered tool call. And budgets do **not** nest across delegation:
sub-agents carry their own, and aggregate spend is observed on the event bus
rather than enforced by any single agent.

### `agentic_workflow` — ✅ built

For work whose shape is known in advance, where an agent loop is the wrong tool.
A directed graph of typed nodes — start, end, LLM, tool, condition, switch, loop,
parallel, delay, human approval, RAG, API, custom — validated before it runs.

Two properties drove the design, and both survived contact with the
implementation.

**Validation before execution.** `WorkflowGraph` validates on construction and
refuses to exist in an invalid state — not a `validate()` a caller may forget.
Data-flow analysis computes key availability as an *intersection* over every
path into a node, so a value written on only one branch is reported rather than
looking safe.

**Resumability.** A suspended run is a JSON snapshot: the app can be killed and
the run resumed elsewhere, keeping its original identifier. That constraint is
what forces workflow state to be JSON-encodable, and why resuming into a graph
whose shape has changed is refused rather than silently continued.

Building it found two gaps worth recording. A graph needed a way to declare its
**inputs** — without one, every workflow taking run input failed validation for
reading keys "nothing writes". And reachability follows edges, so a node that
jumps must declare `jumpTargets` or its target looks unreachable.

### `agentic_memory` — ✅ built

One `MemoryStore` port covers working, conversation, long-term, semantic and
shared memory, because those differ in *scope and retention* rather than in
mechanics — they are filters over one entry shape, not five interfaces.

`agentic_memory` sits above `agentic_agents` because it implements
`HistoryStrategy`, the seam the agent loop already exposed. Building against
that seam found two gaps in it, both now fixed: `select` had to become
asynchronous (summarising is a model call, retrieving is a search), and it had
to receive the turn *about to be sent* — a history-only signature recalls
nothing at all on the first turn, which is when recall matters most.

Retrieval is keyword-first by design: embeddings underperform term matching on
identifiers, names and version numbers, which is a large share of real recall.
`EmbeddedMemoryStore` adds semantics and `HybridMemoryStore` fuses the rankings
with reciprocal rank fusion rather than averaging scores that are not on the
same scale.

### `agentic_vector` — ✅ built

One `VectorStore` port over Qdrant, Pinecone, pgvector or an in-process list.
Two decisions carry most of the weight. `MetadataFilter` is **sealed**, so
adding a filter kind is a compile error in every adapter that has not translated
it rather than a predicate silently dropped from a query. And every
`SimilarityMetric` reports a score where higher is better, Euclidean distance
included, so `topK` ordering and `minScore` never invert when the metric
changes.

`InMemoryVectorStore` is exact by construction — brute force over a few thousand
vectors is milliseconds on a phone, and approximate indexes only start paying
above roughly a hundred thousand records — which also makes it the reference a
new adapter's ranking can be compared against. It snapshots to JSON, so an
offline-first app embeds once and restores thereafter.

`EmbeddingIndex` binds a model to a store, batches to each side's limit, uses
the document and query encoders correctly, and refuses a width mismatch at
construction rather than after an ingestion run.

### `agentic_rag` — ✅ built

A pipeline of small ports: `DocumentLoader` → `Chunker` → `EmbeddingIndex` →
`Retriever` → `Reranker` → `RagPipeline`. Each is independently replaceable and
independently testable.

Citations are first-class rather than metadata. Passages are numbered in the
prompt, the model marks each claim, and the markers resolve back to documents —
numbers because models reproduce `[3]` reliably and mangle `[guide.md#7]`.
`RagAnswer.isGrounded` is false when an answer cited nothing, which is the
signal that the corpus did not cover the question.

`RagIndexer` makes re-ingestion safe three ways: stable `<documentId>#<index>`
identifiers so a re-run replaces rather than duplicates, a content fingerprint
so unchanged documents are never re-embedded, and tail deletion so a shortened
document does not leave orphan chunks that still match and still get cited.

`HybridRetriever` fuses rankings with reciprocal rank fusion rather than
combining scores that share no scale — the same argument, and the same
technique, as `HybridMemoryStore`. Its two halves have opposite blind spots:
dense retrieval finds text that *means* the same thing and blurs rare tokens
like error codes, while BM25 scores a rare term highly precisely because it is
rare.

### `agentic_mcp` — ✅ built

Model Context Protocol in both directions. `McpClient` turns a remote server's
tools into ordinary `Tool` objects; `McpServer` publishes a `ToolRegistry` to
any MCP client. Nothing above the tool layer learns that MCP exists, which is
the test this package was written to pass.

The layering shows in how little there is. JSON-RPC framing and error mapping
sit below the MCP vocabulary, which sits below a transport-agnostic client; the
transport port has two methods. Adding a transport is one class, and the
in-process one exists so that lifecycle, correlation, pagination and
cancellation are all testable without a socket.

Two rules are enforced rather than advised. Server-supplied tool annotations may
only *tighten* the resulting `ToolSpec` — an absent `readOnlyHint` means "assume
it writes" — because they are hints from the other side of a trust boundary. And
a tool whose spec requires human approval is not published at all, because
approval means a person confirms, and there is no person on the far end of a
socket.

### `agentic_flutter` — ✅ built

The umbrella, and the only package that may import Flutter.

It is also the only package that is **not a workspace member**. `flutter_test`
pins `test_api` to the version the Flutter SDK ships and `package:test` needs a
newer one; they cannot share one pub resolution. Including it would have dragged
the other nine onto Flutter's pinned test stack and undone the property this
layering exists to protect — that everything below `agentic_flutter` is testable
on the Dart VM alone. It resolves separately and reaches its siblings by path
until they are published.

Building it surfaced a real defect in the packages beneath: `meta: ^1.19.0` was
a floor no Flutter app could satisfy, because the SDK pins the version it ships.
The framework uses annotations that have existed for years, so the floor was
claiming a requirement that did not exist — and making the whole framework
unusable from a Flutter app in the process. It is now `^1.16.0`.

What is here is what genuinely differs in an app rather than a process:
`AgenticRuntime` owns services across a widget tree that outlives many runs;
`LifecycleCancellation` stops a run when the OS suspends the app, which is the
mobile failure mode a server framework has no reason to model; `SecretStore` is
a port with an honest account of why an API key in a binary is a published key.

What is deliberately absent is plugins. Location, camera and secure storage each
mean a platform dependency in every app that uses the framework, including the
ones that touch no hardware. So the device capabilities are tool factories over
callbacks the application supplies — the tool contract, the schema, the approval
defaults and the permission-denied path live here; the one line that calls a
plugin lives in your app.

---

## 3. Extension points

Every extension point is an interface plus a registry. To add a capability you
implement the interface and register it; no framework code changes.

| To add… | Implement | Register in |
|---|---|---|
| An LLM provider | `ChatModel` | `Registry<ChatModel>` |
| An embedding provider | `EmbeddingModel` | `Registry<EmbeddingModel>` |
| A tool | `Tool` | `ToolRegistry` |
| A vector store | `VectorStore` | `Registry<VectorStore>` |
| A memory backend | `Memory` | `Registry<Memory>` |
| A workflow node type | `WorkflowNode` | `Registry<NodeFactory>` |
| A document loader | `DocumentLoader` | `Registry<DocumentLoader>` |
| A log destination | `LogSink` | passed to `StructuredLogger` |
| A trace destination | `SpanExporter` | passed to `Tracer` |
| A retry schedule | `BackoffStrategy` | passed to `RetryPolicy` |
| A failure type | `extend AgenticException` | — |
| An event | `extend AgenticEvent` | — |

### Sealed versus open, deliberately

| Type | Sealed? | Why |
|---|---|---|
| `ContentPart` | **Sealed** | Every provider adapter must translate every part. Adding a modality *should* break every adapter at compile time. |
| `Result` | **Sealed** | There are exactly two outcomes. Exhaustive `switch` is the point. |
| `AgenticException` | Open (`base`) | A plugin must be able to add its own failure type. |
| `AgenticEvent` | Open (`base`) | A plugin must be able to publish its own events. |
| `Tool`, `ChatModel`, … | Open (interface) | These *are* the extension points. |

`base` on the open hierarchies means anyone may `extend` but nobody may
`implement`, which preserves the ability to add members in a minor release.

---

## 4. Cross-cutting decisions

### Exceptions for control flow, `Result` as an opt-in

Dart's asynchronous idiom is exceptions. Returning `Result` everywhere would
force `switch (await x)` ladders at every call site and composes badly with
`Stream`. So the framework throws, but every failure is typed, coded and
classified — and `Result.guard` is there for fan-out, batch and isolate
boundaries where a value genuinely reads better.

### Explicit context, never a `Zone`

`AgenticContext` is passed. Zone values do not survive an isolate hop, are
invisible in stack traces, hide a function's dependencies from its signature,
and a widget rebuild can easily run in a different zone than the one that
started the operation.

### Injected time

Everything that waits waits through a `Clock`. This is what makes a ten-minute
retry budget testable in microseconds, and — more valuable — assertable against
the exact schedule rather than "it eventually finished".

### Cooperative cancellation

Dart futures cannot be cancelled from outside, so tokens are threaded through and
long operations check them. Where that is not enough — a third-party SDK, a tool
that ignores its token — the framework also stops *waiting*, so a badly-behaved
component degrades one step instead of hanging a run.

### Budgets everywhere

Iterations, tokens, wall clock, cost. An agentic system's characteristic failure
is not a crash; it is a loop that quietly spends money. Bounds are constructor
parameters, not optional guards.

---

## 5. Testing strategy

| Level | What it covers | Speed |
|---|---|---|
| Unit | Value objects, schemas, policies, pure logic | microseconds |
| Component | A layer against fakes: executor + fake tools, agent + fake model | milliseconds |
| Contract | Every adapter of a port against one shared suite | milliseconds |
| Golden | Recorded provider payloads, replayed offline | milliseconds |
| Live | Real providers, opt-in via env var, never in CI | seconds |

The contract-suite level is the important one for an adapter framework: a
`ChatModel` conformance suite that every provider adapter must pass is what keeps
"provider-independent" true rather than aspirational.

No test in CI touches a network or a real clock.

---

## 6. Versioning

Semantic versioning per package, with independent version numbers — a fix in a
provider adapter should not bump the whole framework.

Within a layer, packages depend on carets (`agentic_core: ^0.1.0`). Before 1.0,
minor versions may break; every break is listed in the changelog with a
migration note.

**Considered breaking:** removing or renaming a public member, an
`AgenticException.code`, an `AgenticEvent.type`, or a registry key; adding a
required parameter; narrowing a type; tightening validation.

**Not breaking:** adding an optional parameter, adding a member to a `base`
class, adding an event type, adding a registry entry, changing a `message`
string.
