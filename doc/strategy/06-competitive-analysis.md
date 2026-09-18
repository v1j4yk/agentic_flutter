# Phase 6 — Competitive analysis

Compared on 2026-09-17. "✅" = shipped and documented; "◐" = partial,
preview or via a separate product; "—" = absent or not found. Where a
competitor's status could not be verified it is marked "?".

## 6.1 Who the real competitors are

The prompt lists LangChain, LangGraph, CrewAI, AutoGen, Microsoft Agents,
Dartantic AI, flutter_agentic and MCP Dart packages. Research changes the
ranking of threat:

| Threat to adoption | Competitor | Why |
|---|---|---|
| **1 — direct, strong** | **Genkit Dart** (Google) | Dart-native, Google-backed, promoted at I/O 2026, full-stack (Flutter + Cloud Functions), Dev UI, middleware, interrupts, hybrid routing |
| **2 — direct, established** | **dartantic_ai** | The community default for "LLM + tools in Dart", broad providers, MCP client, active releases |
| **3 — adjacent, Google** | `firebase_ai` + `flutter_ai_toolkit` + `genui` | Owns "add Gemini to my Flutter app" and generative UI |
| 4 — adjacent | `mcp_dart`, `dart_mcp` | Own the MCP layer on their own |
| 5 — indirect | LangGraph, Microsoft Agent Framework, OpenAI Agents SDK, Google ADK, CrewAI, Mastra | Set developer *expectations*; many Flutter teams call a Python/TS backend running these |
| 6 — noise | `flutter_agentic`, `agenix`, `adk_dart` | Low adoption; `flutter_agentic` is a **naming-confusion** risk |

## 6.2 Feature matrix — Dart ecosystem

| Capability | **agentic_\*** 0.2 | Genkit Dart 0.16 | dartantic_ai 3.4 | LangChain.dart 0.9 | flutter_ai_toolkit 1.0 + firebase_ai 4 | flutter_agentic 2.0 | mcp_dart 2.4 |
|---|---|---|---|---|---|---|---|
| Providers (cloud) | OpenAI-compatible, Anthropic, Gemini | Google GenAI, Anthropic, OpenAI | OpenAI, Google, Anthropic, Mistral, Cohere, Ollama, OpenRouter, xAI | many | Gemini (Firebase) | 7 incl. local | — |
| OpenAI Responses API | — | ? | ? | ? | — | ? | — |
| On-device models | — (Ollama/llama.cpp server only) | ◐ Gemini Nano in Chrome | — | — | ◐ hybrid inference | ✅ Gemma/GGUF | — |
| Streaming + tool calling | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | — |
| Structured output | ✅ (tool-forcing fallback) | ✅ (`schemantic`) | ✅ | ✅ | ✅ | ? | — |
| Required budgets (tokens, cost, time) | ✅ **unique** | — | — | — | — | ◐ rate limits | — |
| Retry, fallback, circuit breaker | ✅ | ◐ middleware | ◐ | ◐ | — | ◐ | — |
| Agent loop | ✅ | ✅ | ✅ | ✅ AgentExecutor | ◐ auto function calling | ✅ ReAct | — |
| Multi-agent (delegation / supervisor) | ✅ | ? | ? | ◐ | — | ◐ | — |
| Handoffs | — | ? | — | — | — | — | — |
| Human approval of tools | ✅ | ✅ (middleware) | ? | — | — | ? | — |
| Interrupts / resume | ◐ workflows only | ✅ | — | — | — | — | — |
| Graph workflows with validation | ✅ **unique** | ◐ flows (code, not graphs) | — | ◐ LCEL chains | — | ◐ AgenticFlow | — |
| Durable resumable runs | ✅ workflows | ? | — | — | — | — | — |
| Memory (long-term, semantic, hybrid) | ✅ | ? | — | ◐ | ◐ history | ◐ Hive | — |
| RAG pipeline with citations | ✅ | ◐ retrievers | — | ✅ | — | — | — |
| Vector stores | in-memory, Qdrant, SQLite | ◐ plugins | — | ✅ several | — | — | — |
| MCP client | ✅ (2025-06-18) | ? | ✅ | — | — | — | ✅ (2026-07-28) |
| MCP server | ✅ stdio/in-process | ? | ? | — | — | — | ✅ HTTP + OAuth |
| MCP OAuth / elicitation | — | ? | ? | — | — | — | ✅ |
| A2A / AG-UI | — | — | — | — | — | — | — |
| Untrusted-content / injection boundaries | ✅ **unique** | — | — | — | ◐ App Check (abuse, not injection) | ◐ PII redaction | — |
| Tracing | ◐ in-process, OTel-shaped | ✅ Dev UI | — | ◐ callbacks | — | ? | — |
| OTLP export | — | ? | — | — | ◐ Firebase console | — | — |
| Record/replay cassettes | ✅ **unique** | — | — | — | — | — | — |
| Evals | ✅ basic | ? *unverified* | — | — | — | — | — |
| Code generation for tools | ✅ | ✅ (`schemantic`) | ◐ schema builder | — | — | — | — |
| Chat widgets | ✅ basic | — | — | — | ✅ polished | ? | — |
| Approval / trace widgets | ✅ **unique** | — | — | — | — | — | — |
| Generative UI | — | — | — | — | ✅ `genui` | — | — |
| App lifecycle cancellation | ✅ **unique** | — | — | — | ◐ (open dispose bug #186) | — | — |
| Project generator | ✅ | ✅ CLI | — | — | — | — | — |
| Agent Skills shipped | — | ? | ? | ? | ◐ `flutter/skills` repo | — | ? |
| Verified publisher | — | ✅ genkit.dev | ✅ | ✅ | ✅ Google | ✅ | ✅ |
| Likes (approx.) | 2 | 71 | ? | 303 | 246 / 123 | 2 | 76 |

## 6.3 Feature matrix — cross-language reference frameworks

Cells come from each project's public documentation and announcements, not
hands-on testing; treat "◐" and "?" as prompts to check before quoting publicly.

| Capability | LangChain 1.x | LangGraph 1.x | CrewAI | MS Agent Framework 1.0 | OpenAI Agents SDK | Google ADK | **agentic_\*** |
|---|---|---|---|---|---|---|---|
| Languages | Py, TS | Py, TS | Py | .NET, Py | Py, TS | Py, TS, Go, Java, Kotlin | **Dart** |
| Runs in a mobile app | — | — | — | — | — | — | **✅** |
| Agent loop + middleware/hooks | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ callbacks | ◐ decorators, no step hooks |
| Handoffs | ◐ | ✅ | ◐ | ✅ | ✅ | ✅ | — |
| Guardrails | ◐ middleware | ◐ | ◐ | ✅ middleware | ✅ | ✅ callbacks | ◐ approval + untrusted content |
| Graph workflows | via LangGraph | ✅ | ✅ Flows | ✅ | — | ✅ workflow agents | ✅ |
| Checkpoints / durable | via LangGraph | ✅ | ◐ | ✅ | ◐ sessions | ◐ | ◐ workflows only |
| Human-in-the-loop | ✅ | ✅ `interrupt()` | ✅ (Jan 2026) | ✅ | ✅ approvals | ✅ | ✅ approvals, ◐ interrupts |
| Time travel | — | ✅ | — | ◐ | — | — | — |
| Declarative (YAML) definitions | — | ◐ | ✅ | ✅ | — | ✅ Agent Config | — |
| Deep-agent harness | ✅ `deepagents` | ✅ | — | ◐ preview | ✅ (Apr 2026) | — | — |
| Sandboxed code execution | ◐ | ◐ | ✅ | ✅ | ✅ native | ✅ | — |
| MCP | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ◐ older spec |
| A2A | ? | ◐ via LangSmith Deployment | ? | ✅ | — | ✅ built-in | — |
| AG-UI | ◐ via LangGraph | ✅ | ◐ | ◐ preview | — | ✅ | — |
| Tracing (OTel) | ✅ LangSmith | ✅ | ✅ AMP | ✅ | ✅ built-in | ✅ | ◐ |
| Evals | ✅ LangSmith | ✅ | ◐ | ◐ | ◐ platform | ✅ `adk eval` | ◐ |
| Visual dev UI | ✅ Studio | ✅ Studio | ✅ AMP | ◐ DevUI preview | ◐ traces UI | ✅ `adk web` | ◐ in-app trace panel |
| Hosted deployment | ✅ LangSmith Deployment | ✅ | ✅ AMP | ✅ Azure AI Foundry | ◐ | ✅ Agent Engine | — |
| Budgets enforced by construction | — | — (recursion limit) | ◐ max iter | ◐ | ◐ max turns | ◐ | **✅** |
| Offline / on-device first | — | — | — | — | — | — | **◐ → planned ✅** |

## 6.4 Where `agentic_*` already wins

1. **The only Dart framework that covers the whole stack** — models, tools,
   agents, validated workflows, memory, RAG, vectors, MCP, persistence, tests
   and Flutter UI — under one consistent architecture.
2. **Safety by construction.** Required budgets, approval gating, untrusted
   content boundaries and MCP annotation tightening. No Dart competitor has
   more than one of these; the Python frameworks mostly add them as optional
   middleware.
3. **Validated graph workflows with resumable JSON snapshots.** LangGraph-class
   capability, with validation before execution that LangGraph lacks.
4. **Testing story.** Cassettes plus evals, with injected clocks and IDs — ahead
   of every Dart package and many Python ones.
5. **Mobile realism.** Lifecycle cancellation, honest secret handling,
   phone-sized exact search. The official toolkit still has an open issue about
   cancelling a stream on dispose.
6. **API governance.** Signature snapshots, clash tests, `dart fix` data,
   migration guides. Enterprise evaluators notice this.

## 6.5 Gaps, ranked by adoption impact

| Rank | Gap | Who has it | Fix (Phase 3/4 ref) |
|---|---|---|---|
| 1 | **Distribution and trust signals**: 2 likes, no verified publisher, stale README, no docs site | everyone above | Phase 8 |
| 2 | **Assistant-readiness**: no skills, no `llms.txt` | (few do yet — open window) | Phase 8, CLI-4 |
| 3 | **MCP two spec versions behind, no OAuth** | `mcp_dart`, all reference frameworks | MCP-1, MCP-2, MCP-3 |
| 4 | **Provider breadth**: no Responses API, Bedrock/Vertex/Azure, Firebase, on-device | dartantic, Genkit, flutter_agentic | LLM-2, LLM-4, 4.3, 4.5 |
| 5 | **No OTLP export / dev UI** | Genkit Dev UI, LangSmith, ADK web | 4.2, 4.20 |
| 6 | **Chat UI polish** (Markdown, attachments, theming) | flutter_ai_toolkit, flutter_chat_ui | FL-1..3, FL-10 |
| 7 | **Handoffs, guardrails, interrupts, durable agent runs** | OpenAI SDK, MAF, LangGraph, Genkit | AGENTS-1..4 |
| 8 | **Document ingestion (PDF)** | LangChain.dart | RAG-1 |
| 9 | **Generative UI** | genui | FL-4, 4.23 |
| 10 | **Deployment story** | Genkit (Cloud Functions), LangSmith | 4.14, CLI-5 |

## 6.6 Differentiation strategy

**Positioning statement.**

> *Agentic for Dart is the production framework for AI agents that run in
> Flutter apps — safe by construction, testable offline, and fluent in every open
> agent protocol.*

Three pillars, each backed by features no Dart competitor combines:

1. **Production-safe on devices people carry.** Required budgets, approvals,
   interrupts, guardrails, injection boundaries, lifecycle-aware cancellation,
   encrypted local memory, hybrid on-device routing.
   *Proof points:* red-team suite results published per release; a "kill the app
   mid-run and resume" demo video.
2. **Tested like software, not vibes.** Cassettes, evals with statistical gates,
   trajectory checks, RAG metrics, simulated users, CI reporters.
   *Proof points:* the framework's own agents evaluated in public CI; a benchmark
   page.
3. **Protocol-native.** The most complete Dart implementations of MCP
   (2026-07-28 + OAuth + Apps), the first of A2A and AG-UI, plus interop with
   GenUI, `genai_primitives`, Genkit and Firebase.
   *Proof points:* a green interop matrix in the README.

**How to treat each competitor.**

| Competitor | Stance | Concrete move |
|---|---|---|
| Genkit Dart | **Complement, then compete on depth** | `agentic_genkit` bridge (models in, workflows/evals out); comparison page that is fair and specific ("use Genkit for flows on Firebase; use agentic for durable graphs, budgets, on-device, evals — or both") |
| dartantic_ai | **Interoperate** | `DartanticChatModel` adapter so dartantic's providers work under agentic agents/workflows; talk to the maintainer about sharing `genai_primitives` conversions |
| flutter_ai_toolkit / genui / firebase_ai | **Build on Google's layer** | `agentic_ai_toolkit` `LlmProvider`, `agentic_flutter_genui`, `agentic_llm_firebase` — ride Google's documentation traffic |
| mcp_dart / dart_mcp | **Integrate or catch up — decide once** | Option A: build `agentic_mcp` on `mcp_dart`'s protocol layer and keep the integration value (tools, approvals, OAuth sheet, Apps in Flutter). Option B: implement 2026-07-28 natively. A is faster and lower-risk; B keeps zero dependencies. Recommendation: **A for the client transport and auth, keep own server integration**, revisit at 1.0 |
| LangGraph / MAF / OpenAI SDK / ADK | **Borrow vocabulary, serve their front-ends** | Name concepts the way users already know them (handoff, interrupt, guardrail, checkpoint); ship `agentic_ag_ui` so Flutter apps can front those backends |
| flutter_agentic | **Avoid confusion** | Consistent "Agentic for Dart" branding, verified publisher, README note linking to the right package names |

## 6.7 Opportunities no one in Dart has claimed

1. First **A2A** SDK for Dart.
2. First **AG-UI** client and server for Dart/Flutter.
3. First **eval platform** for Dart (datasets, gates, red team, RAG metrics).
4. First **OTel GenAI** exporter for Dart agents.
5. First **Agent Skills runtime** for apps (not just skills for assistants).
6. First **visual workflow builder** written in Flutter that runs the same graphs.
7. First **hybrid on-device/cloud router** with privacy policies and budgets.
8. First **durable mobile agent runs** — survive app kill, resume on relaunch.
