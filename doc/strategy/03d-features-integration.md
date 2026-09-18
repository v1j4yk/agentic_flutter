# Phase 3d — Feature innovation: integration and presentation

`agentic_mcp` · `agentic_flutter` · `create_agentic_app`

Entry format as in [03a](03a-features-foundation.md).

---

## `agentic_mcp` — 14 features

### MCP-1 · MCP 2026-07-28 support (stateless core, MRTR) — **Must Have**

| Complexity | Effort | Breaking | Deps |
|---|---|---|---|
| High | 3 wk | **Yes** for users of `McpClient.handle(McpMethod.rootsList / samplingCreateMessage, …)` — those become deprecated paths | none |

**Why.** 2026-07-28 is the current specification. It removes the `initialize`
handshake and sessions, replaces server-to-client requests with multi-round-trip
requests (`resultType: "input_required"`), adds `server/discover` and
`subscriptions/listen`, requires `Mcp-Method` / `Mcp-Name` headers, and
deprecates roots, sampling, logging and HTTP+SSE. Servers built on the Tier 1
SDKs will expect it.

**API.**

```dart
final client = McpClient(
  transport: McpHttpTransport(Uri.parse('https://mcp.example.com')),
  protocol: McpProtocol.negotiate(prefer: '2026-07-28', fallback: {'2025-11-25', '2025-06-18'}),
  onInputRequired: (request, ctx) => switch (request) {
    ElicitationInput(:final schema, :final message) => approvalUi.form(message, schema),
    SamplingInput() => sampler.handle(request),   // kept for older servers
  },
);
```

The existing `negotiateProtocolVersion` becomes a per-request `_meta` concern;
keep 2025-06-18 and 2025-11-25 handshakes for older servers for the 12-month
deprecation window the spec defines.

---

### MCP-2 · OAuth 2.1 authorization (PKCE, CIMD, protected-resource metadata) — **Must Have**

| Complexity | Effort | Breaking | Deps |
|---|---|---|---|
| High | 2.5 wk | No | `crypto`; on Flutter, `flutter_web_auth_2` or `app_links` in an optional bridge |

**Why.** Almost every hosted MCP server (GitHub, Linear, Notion, Atlassian,
Stripe, …) requires OAuth. Without it, users paste long-lived tokens, which is
worse for security and blocks consumer apps entirely.

**Use cases.** A Flutter productivity app that lets users connect their Notion
and Linear through MCP with a normal sign-in sheet.

**API.**

```dart
final auth = McpOAuth(
  clientMetadataUrl: Uri.parse('https://myapp.example/.well-known/oauth-client.json'), // CIMD
  redirectUri: Uri.parse('myapp://oauth'),
  launcher: FlutterAuthLauncher(),           // opens the system browser sheet
  tokens: SecureTokenStore(secretStore),     // refresh tokens never in memory longer than needed
);
final client = McpClient(transport: McpHttpTransport(url, auth: auth));
```

Discovery follows the spec order (protected-resource metadata → authorization
server metadata / OIDC discovery); `iss` is validated per RFC 9207.

---

### MCP-3 · Elicitation mapped to Flutter forms — **Must Have**

| Complexity | Effort | Breaking | Deps |
|---|---|---|---|
| Medium | 1 wk | No | none (widgets in `agentic_flutter`) |

**Why.** Elicitation lets a server ask the user for structured input mid-call.
The framework already has the right UI concept (the approval sheet) and the
right schema type. Also covers URL-mode elicitation (open a browser for
sensitive input such as payment details).

**API.** `McpElicitationHandler.flutter(navigatorKey)` renders a form from the
restricted JSON Schema subset; returns `accept` / `decline` / `cancel`.

---

### MCP-4 · Streamable HTTP server host — **Must Have**

| Complexity | Effort | Breaking | Deps |
|---|---|---|---|
| Medium | 1.5 wk | No | `shelf` (in `agentic_mcp_server` to keep the client light) |

**Why.** `McpServer` can publish a `ToolRegistry`, but only over stdio or
in-process. A Dart backend (Dart Frog, Serverpod, Cloud Run, Firebase Functions
for Dart) should expose tools to Claude, ChatGPT, Gemini and IDEs over HTTP.

**API.**

```dart
final handler = McpShelfHandler(
  server: McpServer(tools: registry, resources: docs),
  auth: McpResourceServerAuth(issuer: Uri.parse('https://auth.example.com'), audience: 'mcp'),
  allowedOrigins: {'https://claude.ai'},    // DNS-rebinding protection
);
await serve(Router()..mount('/mcp', handler.call), InternetAddress.anyIPv4, 8080);
```

---

### MCP-5 · MCP Apps (interactive UI resources) — **High Value**

| Complexity | Effort | Breaking | Deps |
|---|---|---|---|
| High | 2 wk | No | `webview_flutter` in an optional bridge |

**Why.** MCP Apps (stable since January 2026) let tools return interactive UI
(`ui://` HTML resources) that hosts such as Claude and VS Code render in a
sandbox. Supporting it in Flutter makes a Flutter app a first-class MCP host;
supporting it in the server lets Dart servers ship UIs.

**API.** Client: `McpAppView(resource: result.uiResource, bridge: …)` —
sandboxed web view with the postMessage bridge. Server: `McpServer.app(uri:
'ui://chart', html: …)` linked from a tool.

---

### MCP-6 · Tasks extension (long-running calls) — **High Value**

| Complexity | Effort | Breaking | Deps |
|---|---|---|---|
| Medium | 1 wk | No | none |

**Why.** Report generation, video processing and deployments exceed request
time-outs. Tasks give a durable handle with `tasks/get` and `tasks/update`.

**API.** On the client, a task-returning tool surfaces as a `ToolResult.pending(taskId)`
that the agent runner polls or resumes (fits AGENTS-3). On the server,
`ToolSpec(execution: ToolExecution.task)`.

---

### MCP-7 · Registry discovery and connection manager — **High Value**

| Complexity | Effort | Breaking | Deps |
|---|---|---|---|
| Medium | 1 wk | No | none |

**Why.** Apps connecting to several servers need lifecycle, reconnection,
health, per-server tool prefixes and caching of list results (`ttlMs` /
`cacheScope` are now required in 2026-07-28).

**API.**

```dart
final hub = McpHub(
  servers: [
    McpServerConfig.stdio('git', command: 'uvx', args: ['mcp-server-git']),
    McpServerConfig.http('linear', Uri.parse('https://mcp.linear.app/mcp'), auth: oauth),
  ],
  toolPrefix: McpToolPrefix.serverName,
);
await registerMcpTools(registry, hub);   // extends the existing helper
final found = await McpRegistryClient().search('calendar');
```

Also reads the de facto `mcp.json` / `.mcp.json` config format.

---

### MCP-8 · Trace propagation through `_meta` — **High Value**

| Complexity | Effort | Breaking | Deps |
|---|---|---|---|
| Low | 2 d | No | CORE-5 |

**Why.** 2026-07-28 standardised `traceparent` in `_meta`. With it, a Flutter
app → Dart MCP server → downstream API call is one trace.

---

### MCP-9 · Server-side prompts and resources from Dart annotations — **Future**

| Complexity | Effort | Breaking | Deps |
|---|---|---|---|
| Medium | 1 wk | No | `agentic_tools_generator` |

**API.** `@McpPrompt()` and `@McpResource('docs://{slug}')` generating the
provider registrations, alongside `@ToolFunction`.

---

### MCP-10 · Conformance and interop test matrix — **Must Have**

| Complexity | Effort | Breaking | Deps |
|---|---|---|---|
| Medium | 1 wk | No | CI only (Node/Python reference servers) |

**Why.** "Supports MCP" is only credible with a matrix against the reference
TypeScript and Python SDKs, the official conformance suite where available,
and `mcp_dart` / `dart_mcp`. Publishing the matrix in the README is also
marketing.

---

### MCP-11 · MCP tool safety policies — **High Value**

| Complexity | Effort | Breaking | Deps |
|---|---|---|---|
| Low | 4 d | No | TOOLS-4 |

**Why.** Remote tool descriptions are an injection surface ("tool poisoning"),
and a server can change its tool list after approval ("rug pull").

**API.** `McpTrustPolicy(pinToolDefinitions: true, onDefinitionChange:
TrustAction.requireReapproval, scanDescriptions: InjectionScanner.standard())`,
with `McpToolDefinitionChanged` events.

---

### MCP-12 · Expose agents and workflows as MCP servers — **High Value**

| Complexity | Effort | Breaking | Deps |
|---|---|---|---|
| Low | 4 d | No | none |

**Why.** A Dart agent or workflow published as a single MCP tool can be used from
Claude Desktop, Cursor or Gemini CLI immediately, which is also a cheap
distribution channel.

**API.** `McpServer(tools: ToolRegistry()..register(AgentTool(agent)))` already
works in principle; add `McpServer.forWorkflow(graph, engine)` with task support
for long runs.

---

### MCP-13 · Dart MCP server template and CLI — **High Value**

| Complexity | Effort | Breaking | Deps |
|---|---|---|---|
| Low | 4 d | No | `create_agentic_app` |

**API.** `create_agentic_app my_server --template=mcp-server` producing a stdio
and HTTP server with `@ToolFunction` tools, tests via `InMemoryTransport`, a
Dockerfile, and a `.mcp.json` snippet for Claude Code and Cursor.

---

### MCP-14 · MCP Inspector widget — **Future**

| Complexity | Effort | Breaking | Deps |
|---|---|---|---|
| Medium | 1 wk | No | `agentic_flutter` / `agentic_devtools` |

**Why.** Browsing tools, calling one with a generated form and watching the
JSON-RPC traffic is the fastest MCP debugging loop.

---

## `agentic_flutter` — 18 features

### FL-1 · Rich message rendering (Markdown, code, tables, LaTeX) — **Must Have**

| Complexity | Effort | Breaking | Deps |
|---|---|---|---|
| Medium | 1.5 wk | No | a Markdown renderer (for example `gpt_markdown` or `flutter_markdown_plus`) behind a `MessageRenderer` port |

**Why.** Every model answers in Markdown. Rendering it as `SelectableText`
shows literal asterisks and code fences, which is the first thing an evaluator
notices in a demo.

**Use cases.** Code answers with copy buttons, tables in finance apps, formulas
in education apps.

**API.**

```dart
AgentChatView(
  controller: chat,
  renderer: MarkdownMessageRenderer(
    codeTheme: CodeTheme.github(),
    onLinkTap: (uri) => launchUrl(uri),
    streamingSafe: true,   // tolerates half-open code fences while tokens arrive
  ),
);
```

---

### FL-2 · Theming and slot-based customisation — **Must Have**

| Complexity | Effort | Breaking | Deps |
|---|---|---|---|
| Medium | 1.5 wk | No | none |

**Why.** Branded apps cannot use a chat view they cannot restyle.
`entryBuilder` replaces everything or nothing.

**API.**

```dart
AgenticChatTheme(
  data: AgenticChatThemeData.fromColorScheme(scheme).copyWith(
    userBubble: BubbleStyle(radius: 20, color: scheme.primary),
    avatarBuilder: (ctx, role) => …,
    toolCallBuilder: (ctx, call) => ToolCallChip(call),
    composerDecoration: …,
  ),
  child: AgentChatView(controller: chat),
);
```

---

### FL-3 · Attachments and multimodal composer — **Must Have**

| Complexity | Effort | Breaking | Deps |
|---|---|---|---|
| Medium | 1.5 wk | No | callbacks only (no plugins, following the platform-tools rule) |

**Why.** "Photo of my fridge → recipe", "explain this PDF" and "what is this
error screenshot" are core mobile use cases and the models support them.

**API.** `ChatComposer(attachments: AttachmentOptions(pickImage: () =>
picker.pickImage(...), pickFile: …, maxBytes: 8.mb, downscale: 1568))` producing
`ImagePart` / `DocumentPart`; thumbnails in the transcript.

---

### FL-4 · Generative UI: tools that render widgets (with GenUI/A2UI interop) — **Must Have** (strategic)

| Complexity | Effort | Breaking | Deps |
|---|---|---|---|
| High | 3 wk | No | optional `genui` bridge package |

**Why.** Google's `genui` (A2UI v0.9, v1.0 targeted for Q4 2026) established
that agents should answer with UI, not only text. `agentic_flutter` should
support both a lightweight typed approach and full A2UI interop, rather than
compete with Google's renderer.

**API.**

```dart
// Lightweight: a tool whose result renders a registered widget.
registry.register(uiTool<WeatherCard>(
  name: 'show_weather',
  schema: WeatherCardSchema(),                      // generated (GEN-2)
  builder: (ctx, data) => WeatherCard(data: data),
));

// Interop: feed agent output into GenUI surfaces.
final surfaces = A2uiBridge(controller: chat, catalog: myCatalog); // in agentic_flutter_genui
```

---

### FL-5 · Voice mode (push-to-talk and realtime) — **High Value**

| Complexity | Effort | Breaking | Deps |
|---|---|---|---|
| High | 3 wk | No | `agentic_voice`; audio capture via callbacks |

**Why.** An open request against the official Flutter AI Toolkit (realtime
voice, flutter/ai #189). Voice is where mobile agents are most useful (driving,
cooking, accessibility).

**API.** `VoiceChatButton(controller: chat, stt: …, tts: …)` for push-to-talk;
`RealtimeVoiceView(session: realtime)` with barge-in, a level meter and
live captions.

---

### FL-6 · Message actions: copy, regenerate, edit-and-resend, feedback — **Must Have**

| Complexity | Effort | Breaking | Deps |
|---|---|---|---|
| Low | 4 d | No | none |

**Why.** Users expect them from ChatGPT, Gemini and Claude; feedback thumbs are
also the cheapest source of eval data.

**API.** `AgentChatController.regenerate(entryId)`, `.editAndResend(entryId,
text)`; `ChatEntryActions(onFeedback: (entry, rating) => feedbackSink.add(...))`
emitting `UserFeedbackRecorded` events that `agentic_test` can turn into eval cases.

---

### FL-7 · Conversation list and session management — **High Value**

| Complexity | Effort | Breaking | Deps |
|---|---|---|---|
| Low | 1 wk | No | `SessionStore` |

**API.** `ConversationListView(store: SqliteSessionStore(db), onOpen: …)` with
auto-generated titles (`SessionTitler(model: flashLite)`), search, rename,
delete and pinning.

---

### FL-8 · Streaming performance — **Must Have**

| Complexity | Effort | Breaking | Deps |
|---|---|---|---|
| Low | 4 d | No | none |

**Why.** `notifyListeners()` per token rebuilds the whole list; on long chats
at 50–100 tokens per second that means dropped frames on low-end Android.

**API.** Internal: per-entry `ValueListenable`s, frame-coalesced updates
(`SchedulerBinding.scheduleFrameCallback`), `SliverList` with stable keys.
Public: `AgentChatController(updateThrottle: 32.ms)`. Add a benchmark in
`agentic_benchmark` measuring rebuilds per second.

---

### FL-9 · State-management adapters (Riverpod, Bloc, signals) — **High Value**

| Complexity | Effort | Breaking | Deps |
|---|---|---|---|
| Low | 3 d each | No | each in its own package |

**Why.** Flutter teams adopt libraries that fit their existing architecture.
A `ChangeNotifier` controller is fine, but a `Notifier` / `Cubit` wrapper removes
an adoption objection.

**API.** `agentic_riverpod`: `agentChatProvider(agentFactory)` →
`AsyncNotifier<ChatState>`; `agentic_bloc`: `AgentChatCubit`.

---

### FL-10 · `flutter_chat_ui` and `genai_primitives` adapters — **High Value**

| Complexity | Effort | Breaking | Deps |
|---|---|---|---|
| Low | 1 wk | No | `flutter_chat_core`, `genai_primitives` (separate bridge packages) |

**Why.** `flutter_chat_ui` (1.6 k likes) is the most popular Flutter chat UI and
now markets itself for AI agents. Google's packages (`genui`,
`flutter_ai_toolkit`) and `dartantic_ai` have converged on `genai_primitives`
message types. Adapters turn potential competitors into distribution.

**API.** `AgenticChatAdapter(controller).toChatController()` for
`flutter_chat_ui`; `Message.fromGenAi(ChatMessage)` / `toGenAi()` and
`AgenticLlmProvider(agent)` implementing the AI Toolkit's `LlmProvider`.

---

### FL-11 · Background execution — **High Value**

| Complexity | Effort | Breaking | Deps |
|---|---|---|---|
| High | 2 wk | No | `workmanager` / iOS `BGTaskScheduler` via callbacks |

**Why.** `BackgroundPolicy.keepRunning` only works while the OS allows it.
Long research runs or indexing need proper background tasks, with a notification
on completion and a durable run to resume (AGENTS-3).

**API.** `BackgroundAgentRunner(runner: durableRunner, schedule: (job) =>
Workmanager().registerOneOffTask(...), notify: (result) => …)`.

---

### FL-12 · DevTools extension — **High Value**

| Complexity | Effort | Breaking | Deps |
|---|---|---|---|
| Medium | 2 wk | No | `devtools_extensions` (in `agentic_devtools`) |

**Why.** The in-app `TraceInspector` competes with the app for screen space.
A DevTools tab shows runs, spans, prompts, token costs, tool calls, memory and
workflow graphs without changing the app.

---

### FL-13 · Approval and interrupt UI kit — **Must Have**

| Complexity | Effort | Breaking | Deps |
|---|---|---|---|
| Low | 1 wk | No | AGENTS-4, TOOLS-4, TOOLS-10 |

**API.** `ToolApprovalSheet` gains "allow for session", diff previews and risk
labels; new `InterruptFormSheet(schema)`, `HumanTaskInboxView(inbox)` and an
inline approval card mode (`ApprovalPresentation.inline`) for chat transcripts.

---

### FL-14 · Agent status and plan widgets — **High Value**

| Complexity | Effort | Breaking | Deps |
|---|---|---|---|
| Low | 1 wk | No | none |

**Why.** Long runs need visible progress: current step, to-do list (AGENTS-8),
sources being read, tool progress (TOOLS-2).

**API.** `AgentActivityIndicator(controller)`, `PlanChecklist(stream:
agent.stream(...))`, `SourcesStrip(citations)`, `WorkflowGraphView(graph, events)`.

---

### FL-15 · Accessibility and localisation — **Must Have**

| Complexity | Effort | Breaking | Deps |
|---|---|---|---|
| Low | 1 wk | No | `flutter_localizations` |

**Why.** Screen readers must announce streamed answers once, not per token;
approval sheets must be operable by keyboard; strings must be translatable. Many
enterprise and public-sector buyers require it.

**API.** `AgenticLocalizations` delegates; `SemanticsService.announce` on answer
completion; an accessibility test suite using `meetsGuideline`.

---

### FL-16 · Desktop and web parity — **High Value**

| Complexity | Effort | Breaking | Deps |
|---|---|---|---|
| Medium | 1.5 wk | No | none |

**Why.** Windows and Linux support is an open request against the official AI
Toolkit (flutter/ai #132). Desktop agent apps (local files, MCP stdio servers)
are a natural fit, and the framework is already pure Dart below this package.

**API.** Keyboard shortcuts (Enter / Shift+Enter, Esc to stop), drag-and-drop
attachments, resizable split view with trace panel, a golden-test matrix on all
six platforms.

---

### FL-17 · Offline queue and connectivity-aware runs — **High Value**

| Complexity | Effort | Breaking | Deps |
|---|---|---|---|
| Medium | 1 wk | No | connectivity via callbacks |

**Why.** The README's own argument: tunnels, lifts, captive portals. Messages
sent offline should queue, route to an on-device model (LLM-8), or fail with an
honest, retryable state.

**API.** `AgentChatController(connectivity: () => …, offlinePolicy:
OfflinePolicy.queue | OfflinePolicy.onDevice(localModel) | OfflinePolicy.fail)`.

---

### FL-18 · AG-UI client — **Experimental** (strategic)

| Complexity | Effort | Breaking | Deps |
|---|---|---|---|
| Medium | 2 wk | No | SSE (already in `agentic_llm`) |

**Why.** Many teams run agents on Python/TypeScript backends (LangGraph, Mastra,
Pydantic AI, Microsoft Agent Framework) and want a Flutter front end. AG-UI is
the event protocol those backends speak; no Dart client was found. This makes
`agentic_flutter` useful to teams that never adopt the Dart agent runtime.

**API.** `AgUiAgent(endpoint: Uri.parse('https://api.example.com/agent'))`
implementing `Agent`, so `AgentChatController` works unchanged; frontend tools
via TOOLS-12; shared state via `AgUiStateController`.

---

## `create_agentic_app` — 10 features

### CLI-1 · Template gallery — **Must Have**

| Complexity | Effort | Breaking | Deps |
|---|---|---|---|
| Medium | 2 wk | No | none |

**Why.** One template shows one use case. Developers search for their use case.

**API.** `create_agentic_app my_app --template=<name>`:

| Template | What it generates |
|---|---|
| `chat` (default) | today's app |
| `rag` | document Q&A with PDF import, citations, SQLite persistence |
| `voice` | push-to-talk assistant |
| `workflow` | multi-step approval flow with an inbox |
| `on-device` | offline assistant on a local model |
| `mcp-client` | app that connects to MCP servers with OAuth |
| `mcp-server` | Dart MCP server (stdio + HTTP) |
| `server-agent` | Dart backend agent with an AG-UI/SSE endpoint + Flutter client |
| `cli-agent` | terminal agent in pure Dart |

---

### CLI-2 · Interactive mode — **High Value**

| Complexity | Effort | Breaking | Deps |
|---|---|---|---|
| Low | 4 d | No | `mason_logger` or `interact` |

**API.** Running with no arguments asks for template, provider, platforms and
features (memory, RAG, MCP) and prints the equivalent non-interactive command.

---

### CLI-3 · `agentic` CLI with `add` subcommands — **Must Have**

| Complexity | Effort | Breaking | Deps |
|---|---|---|---|
| Medium | 2 wk | No | `analyzer` for safe code edits |

**Why.** shadcn/ui showed that "add a capability to my existing project" beats
"generate a new project". Most adopters already have an app.

**API.**

```sh
dart pub global activate agentic_cli
agentic init                 # detects Flutter/Dart, adds deps, AgenticScope, secrets
agentic add rag --store=sqlite
agentic add mcp --server=https://mcp.linear.app/mcp
agentic add tool weather     # scaffolds an @ToolFunction + test
agentic add skills           # installs Agent Skills for the user's coding assistant
agentic doctor               # checks versions, keys, stale model IDs, lints tool descriptions
```

---

### CLI-4 · Generated `AGENTS.md` and installed skills — **Must Have**

| Complexity | Effort | Breaking | Deps |
|---|---|---|---|
| Low | 2 d | No | `skills` CLI |

**Why.** Most people generating a project will then work on it with Claude Code,
Antigravity, Copilot, Cursor or Codex. An `AGENTS.md` describing the
architecture and running `dart run skills get` for the agentic packages makes
those assistants productive immediately.

---

### CLI-5 · Backend key proxy templates — **Must Have**

| Complexity | Effort | Breaking | Deps |
|---|---|---|---|
| Medium | 1.5 wk | No | per target |

**Why.** The generated app correctly says a key in an APK is a published key.
It should then offer the fix: `--backend=firebase-functions | cloud-run |
dart-frog | serverpod`, generating an authenticated proxy (or short-lived key
minting, LLM-5) with per-user rate limits and cost caps.

---

### CLI-6 · Fold in `flutter create` — **High Value**

| Complexity | Effort | Breaking | Deps |
|---|---|---|---|
| Low | 2 d | No | none |

**Why.** The quick start is currently two commands plus a `cd`. One command to a
running app is measurably better for conversion.

**API.** `create_agentic_app my_app --platforms=android,ios` runs `flutter
create` itself when Flutter is on the `PATH`.

---

### CLI-7 · Generated CI, evals and cassettes — **High Value**

| Complexity | Effort | Breaking | Deps |
|---|---|---|---|
| Low | 3 d | No | none |

**Why.** Teaching good habits by default: a GitHub Actions workflow running
analysis, widget tests, cassette-replayed agent tests and a small eval suite.

---

### CLI-8 · Demo mode with scripted model — **High Value**

| Complexity | Effort | Breaking | Deps |
|---|---|---|---|
| Low | 2 d | No | none |

**Why.** `pocket_agent` already starts in demo mode with no key. Making every
template run keyless removes the most common drop-off point (getting a key).

---

### CLI-9 · Upgrade command with codemods — **Future**

| Complexity | Effort | Breaking | Deps |
|---|---|---|---|
| Medium | 1.5 wk | No | `dart fix` data |

**API.** `agentic upgrade` bumps all `agentic_*` constraints together, runs
`dart fix --apply`, and links the migration guide for anything not automatable.

---

### CLI-10 · Telemetry-free usage analytics opt-in — **Future**

| Complexity | Effort | Breaking | Deps |
|---|---|---|---|
| Low | 2 d | No | none |

**Why.** Knowing which templates are used guides the roadmap. It must be opt-in,
documented and anonymous, or it will cost trust — so default to off and ask once.
