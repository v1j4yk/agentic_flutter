# Phase 1 — Ecosystem analysis

State of the market on 2026-09-17. Sources were fetched on that date; figures
from pub.dev (likes, downloads) are approximate and move daily. Items that
could not be verified are marked *unverified*.

## 1.1 The five shifts that matter for this project

| # | Shift | Evidence | Implication for `agentic_*` |
|---|---|---|---|
| 1 | **Google has made Dart a first-class AI language** | Genkit Dart (preview Mar 2026, `genkit` 0.16.x), GenUI released at I/O 2026, `firebase_ai` 4.0 GA with hybrid on-device inference, Skills CLI 1.0 (Sep 2026), "agentic hot reload" in Flutter 3.44 | The space is now contested by Google itself. Compete where Google is thin (durable orchestration, evals, MCP depth, safety, offline), interoperate where Google is strong (GenUI, `genai_primitives`, Firebase) |
| 2 | **Protocols have won over frameworks** | MCP 2026-07-28 (stateless core), A2A v1.0 (Apr 2026, 150+ orgs, **no Dart SDK**), AG-UI (CopilotKit, adopted by Google, Microsoft, AWS, Oracle; **no Dart client found**), A2UI v1.0 RC, Agent Skills open standard, AGENTS.md and MCP under the Linux Foundation's Agentic AI Foundation | Being the **best Dart implementation of every open protocol** is a durable moat that a single-vendor framework cannot easily copy |
| 3 | **Durable execution, human-in-the-loop and evals are now table stakes** | LangGraph 1.0, Microsoft Agent Framework 1.0 (Apr 2026), Pydantic AI + Temporal/DBOS, Mastra suspend/resume, Vercel AI SDK 6 `needsApproval`, OpenAI Agents SDK guardrails | `agentic_workflow` snapshots and approval gating are ahead of every Dart competitor; evals and durable *agent* runs are the gaps to close |
| 4 | **AI coding assistants are the new documentation readers** | Flutter Q2 2026 survey: Claude Code 32 %, Antigravity 23 %, Copilot 19 %, Cursor 18 %, Codex 17 %; 79 % of Flutter developers use AI assistants; `dart run skills get` installs package skills into all of them | A package an assistant cannot use correctly will lose to one it can. Ship skills, `llms.txt` and assistant-friendly errors in every package |
| 5 | **On-device AI is practical on phones** | `flutter_gemma` (LiteRT-LM, Gemma 4 E2B/E4B, all six platforms, 434 likes), `llamadart` (GGUF + LiteRT-LM incl. web), ML Kit GenAI Prompt API (Gemini Nano, alpha), Apple Foundation Models, Firebase hybrid inference; MediaPipe LLM Inference now maintenance-only | Hybrid cloud/on-device routing with privacy policies is a Flutter-native advantage no Python framework can claim |

## 1.2 Trend radar

Rated by developer demand (from framework roadmaps, issue trackers and surveys)
and by how well the Dart ecosystem currently serves it.

| Area | Demand | Dart coverage today | Best Dart option today | Opportunity |
|---|---|---|---|---|
| MCP client/server | Very high | Medium | `mcp_dart` (2026-07-28, OAuth); `dart_mcp` (official, experimental, no HTTP/auth) | Best-*integrated* MCP (tools-as-agent-tools, approvals, OAuth sheet, MCP Apps in Flutter) |
| Agent loops + tools | Very high | Good | `dartantic_ai` 3.x, `genkit`, `agentic_agents` | Differentiate on safety and budgets, not on existence |
| Durable workflows / graphs | High | **Poor** | `agentic_workflow`; `adk_dart` (community port) | **Lead.** Only real Dart graph engine with validation and resumable snapshots |
| Human-in-the-loop | High | Poor–Medium | Genkit interrupts, `agentic_tools` approvals | Lead with interrupts, inboxes and ready-made Flutter UI |
| Evals and testing | High (and the biggest industry gap) | **Very poor** | `agentic_test` | **Lead.** No other Dart eval library found |
| Observability (OTel GenAI) | High | Poor | Genkit Dev UI traces | OTLP export with `gen_ai.*` conventions |
| RAG | High | Poor–Medium | LangChain.dart (retrievers), `agentic_rag` | PDF, evals, on-device, citations UI |
| Vector stores | Medium–High | Medium | ObjectBox (HNSW), `sqlite3_vec`, LangChain.dart integrations | Adapters under one port with a conformance suite |
| Memory | Medium–High | Poor | `agentic_memory`, Hive-based ad-hoc | Consolidation, user-controlled memory, encryption |
| Chat UI | High | Good | `flutter_chat_ui` (1.6 k likes), `flutter_ai_toolkit` (246 likes) | Don't fight — adapt; own approvals, traces, generative UI |
| Generative UI | Rising fast | Medium | `genui` (alpha, A2UI 0.9) | Interop plus typed widget tools |
| Voice / realtime | Rising fast | Poor | `openai_dart` (Realtime), `firebase_ai` Live | Provider-neutral realtime sessions with Flutter audio UI |
| On-device LLMs | Rising fast | Medium (engines), Poor (orchestration) | `flutter_gemma`, `llamadart` | Routing, budgets, tool calling for small models |
| A2A | Rising | **None** | — | First Dart A2A SDK |
| AG-UI | Rising | **None found** | — | First Flutter AG-UI client |
| Agent Skills | Rising fast | Tooling exists, content scarce | `skills` CLI, `dart-lang/skills`, `flutter/skills` | Ship skills in every package, and a skills *runtime* for apps |
| Guardrails / safety | Medium–High | Poor | `flutter_agentic` (PII redaction), `agentic_tools` untrusted content | Guardrails + red-team eval suite |
| Cost tracking / routing | Medium | Poor | `genkit_hybrid`, `agentic_llm` Fallback | Router + usage ledger with attribution |
| Computer use / browser | Medium | None | — | Desktop Flutter harness (experimental) |

## 1.3 pub.dev landscape (AI-relevant packages)

| Package | Publisher | Version | Signal | Positioning |
|---|---|---|---|---|
| `firebase_ai` | firebase.google.com | 4.0.0 | 123 likes, ~79 k downloads | Official Gemini access via Firebase, Live API, hybrid on-device |
| `flutter_ai_toolkit` | labs.flutter.dev | 1.0.0 | 246 likes | Chat widgets over `LlmProvider`; Firebase-only provider; open requests for realtime voice, Windows/Linux |
| `genui` / `genai_primitives` | labs.flutter.dev | 0.10.3 / 0.2.4 | 195 likes / ~44 k downloads | Generative UI (A2UI); shared message types Google and dartantic converged on |
| `genkit` (+ plugins) | genkit.dev | 0.16.1 (0.17.0-rc.1) | 71 likes, ~18.5 k downloads | Google's full-stack AI framework: flows, tools, interrupts, Dev UI, middleware, hybrid routing. **Nearest strategic competitor** |
| `dartantic_ai` | sellsbrothers.com | 3.4.2 | established community favourite (likes *unverified*) | Multi-provider agents, tools, typed output, MCP client, server-side tools. No workflows, evals, RAG pipeline |
| `langchain` (LangChain.dart) | langchaindart.dev | 0.9.0 | 303 likes | LCEL chains and integrations; no LangGraph equivalent |
| `mcp_dart` | leehack.com | 2.4.2 | 76 likes, ~274 k downloads | Most complete Dart MCP SDK (2026-07-28, OAuth, elicitation, tasks) |
| `dart_mcp` | labs.dart.dev | 0.5.2 | 83 likes, ~443 k downloads | Official; powers `dart mcp-server`; experimental; stdio only |
| `openai_dart`, `anthropic_sdk_dart`, `ollama_dart` | davidmiguel.com | 9.x / 9.x / 3.x | 17–92 likes | High-quality raw provider clients (Responses, Realtime, batches) |
| `flutter_gemma` | sashadenisov.dev | 1.8.3 | 434 likes | On-device LLMs and embeddings via LiteRT-LM |
| `llamadart` | — | 0.8.23 | active | llama.cpp + LiteRT-LM bindings incl. web |
| `flutter_chat_ui` | flyer.chat | 2.12.0 | 1.63 k likes, ~101 k downloads | Backend-agnostic chat UI marketed for AI agents |
| `objectbox` | objectbox.io | 4.x / 5.x native | established | On-device HNSW vector search |
| `adk_dart` | adk-labs (community) | 2026.9.11 | active | Community port of Google ADK incl. Flutter UI; not a Google product |
| `flutter_agentic` | inlayad.com | 2.0.0 | 2 likes, ~125 downloads | Unrelated package with a name easily confused with `agentic_flutter` |
| `agentic_*` (this project) | uploader account, **no verified publisher** | 0.2.0 | 0–2 likes, ~120–210 downloads | Broadest architecture; lowest distribution |

## 1.4 Flutter and Dart AI initiatives to align with

1. **Package skills (Skills CLI 1.0, 2026-09-08).** A top-level `skills/`
   directory is bundled by `dart pub publish`; each skill lives in
   `skills/<package-name-with-hyphens>-<skill>/SKILL.md` (for example
   `skills/agentic-workflow-build-graph/SKILL.md`). Users run `dart run skills
   get` to install skills for all dependencies into Claude Code
   (`.claude/skills/`), Cursor, Copilot, Codex, Antigravity, Cline, OpenCode or
   `.agents/skills/`. Names must be lowercase letters, digits and hyphens and
   match the directory; descriptions ≤ 1,024 characters; bodies ideally
   < 5 k tokens. **Adopt immediately — see Phase 8.**
2. **Dart and Flutter MCP server** (`dart mcp-server`): analyzer, hot reload,
   widget tree, pub.dev search, tests. Complementary: its pub.dev search is a
   discovery channel, so package descriptions and topics matter more than ever.
3. **GenUI / A2UI**: interoperate (FL-4) rather than build a rival renderer.
4. **`genai_primitives`**: provide lossless conversion to and from `Message`
   (FL-10) so apps can mix Google's widgets and this framework's runtime.
5. **Genkit Dart**: position explicitly (see Phase 6). Consider a
   `genkit_agentic` plugin that exposes `agentic_workflow` graphs and
   `agentic_test` evals to Genkit users — reaching Google's audience instead of
   competing for it head-on.
6. **Firebase AI Logic**: a `FirebaseAiChatModel` adapter (LLM provider) gives
   apps App Check protection without a custom proxy — directly addressing the
   "key in the APK" problem the README raises.
7. **Agentic hot reload / AI-assisted development**: the framework's strict
   analysis and snapshot tests make it unusually friendly to AI-written code;
   say so, and prove it with skills and evals of assistants using the API.

## 1.5 What developers are asking for

From framework issue trackers, the LangChain survey (1,340 respondents),
Flutter's Q2 2026 survey (3,500+) and open `flutter/ai` issues:

1. **Quality** is the top blocker (≈ ⅓ of respondents) → evals, tracing,
   regression gates.
2. **Latency** (≈ 20 %) → streaming everywhere, routing to smaller or on-device
   models, prompt caching.
3. **Security** (25 % at large companies) → guardrails, injection defences,
   MCP OAuth, permission-aware retrieval, encryption at rest.
4. **Multi-model** (> ¾ use several) → provider breadth, router, catalogue.
5. **Trust in AI-written code** (46 % of Flutter developers do not trust it for
   critical tasks) → strict types, clear errors, skills that teach correct usage.
6. **Flutter-specific requests**: realtime voice, Windows/Linux, correct stream
   cancellation on dispose (already solved here by `LifecycleCancellation` — a
   marketing point), customisation of chat UI, alignment with
   `genai_primitives`.
7. **On-device pain**: multi-gigabyte downloads, storage, choosing engines,
   1–3 B models only → download manager, model catalogue, capability-aware
   fallbacks.

Gap noted: no Reddit or Discord data was collected (*unverified*); a short
community survey run by this project would be both research and marketing.
