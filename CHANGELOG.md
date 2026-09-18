# Changelog

All notable changes to this repository are documented here. Each package also
keeps its own changelog, which is what pub.dev displays, and is the place to
look for the detail behind a line here.

This project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).
Until 1.0.0, minor versions may contain breaking changes; they will always be
listed here.

## [Unreleased]

The plan for 0.3 and beyond is in [`doc/strategy/`](doc/strategy/README.md); the
README carries the short version.

### Added

- Every package now ships **Agent Skills** under `skills/`, bundled by
  `dart pub publish` and installed with `dart run skills@ get`. An AI assistant
  helping someone use this framework reads those rather than guessing from
  training data that predates it. `tool/check_skills.dart` validates them in CI,
  including that every framework name a skill teaches still exists in
  `api/*.txt`.
- `agentic_llm` — per-provider model constants (`AnthropicModels.opus`,
  `.sonnet`, `.haiku`, and the equivalent for OpenAI, Gemini, Grok, DeepSeek and
  Mistral), `ModelDirectory.listModels()` for asking a provider what it serves,
  and `SwitchableChatModel` for changing model at run time without rebuilding
  the agent that holds it.
- `agentic_integration` — `bin/check_models.dart`, run nightly: every model
  identifier the framework ships, against the list each provider actually
  serves.

### Changed

- Default model identifiers across `agentic_llm`, the conformance suite and the
  project template now name models that exist; two of the old defaults had been
  retired by their providers. See the `agentic_llm` changelog for the table.

### Breaking

- `GeminiEmbeddingModel` defaults to `gemini-embedding-2`, which cannot search
  an index written by `gemini-embedding-001`.
- `OpenAiCompatibleChatModel.deepSeek` and `.mistral` require `model`.

## 0.2.0 — 2026-09-17

All fourteen packages were released together. Migration guide:
[`doc/migration-0.2.md`](doc/migration-0.2.md).

### Added

- `agentic_sqlite` 0.2.0 — on-device persistence: SQLite-backed vector, memory,
  session and workflow-snapshot stores, with a versioned schema.
- `agentic_test` 0.2.0 — record real model answers once and replay them offline,
  plus evals with tool, answer, budget and model-graded checks.
- `agentic_tools_generator` 0.2.0 — generates tools, schemas and argument
  conversion from functions and methods annotated with `@ToolFunction`, checked
  at build time.
- `agentic_tools` — `@ToolFunction` and `@ToolParam` annotations, read by the
  generator above. `isReadOnly` is required, so a tool that changes state is
  never read-only by accident.
- `agentic_agents` — `SessionStore` port; `ToolCallingAgent(approvalHandler:)`
  and `(untrustedContentPolicy:)`.
- `agentic_workflow` — `WorkflowSnapshotStore` port, a versioned snapshot
  format, and `WorkflowSnapshot` is no longer experimental.
- `agentic_rag` — `RagStack` (keyword-only or hybrid), `RagPipeline.stream` with
  a `RagStreamEvent` family.
- `agentic_core` — `UntrustedContentLedger` on `AgenticContext`: which tools
  brought text into a run that the application did not write.
- Repository — public API signature snapshots (`api/*.signatures.txt`) with a
  release diff tool, and a test forbidding one name being exported by two
  packages.

### Changed

- **Untrusted content boundaries** (behaviour change, which is why it is in
  0.2.0 rather than a patch). Retrieval, memory recall and MCP tools mark their
  results as untrusted, and once one returns successfully, a tool that is not
  read-only needs approval before it runs. The Flutter approval sheet says which
  tools the untrusted content came from.
- A call denied because no approval handler is configured now tells the model
  that nobody could be asked, rather than that the user declined.
- `JsonSchema.coerce` treats `null` for an optional, non-nullable property as
  not given, applying the default if there is one. Models send `null` for
  parameters they skip, and those calls used to be rejected.

### Breaking

- `memoryTools`, `rememberTool`, `recallTool` and `forgetTool` take `store` by
  name, like every other tool factory in the framework. `dart fix --apply`
  migrates this.
- Adding untrusted-content approval can make a previously silent run stop for
  approval. `UntrustedContentPolicy` configures it.

## 0.1.2 — 2026-09-17

Patch releases from `release/0.1.x` for packages that needed a fix before 0.2.0.

- `agentic_llm` — retired the `text-embedding-004` and `gemini-2.0-flash`
  defaults, which Google had withdrawn, and mapped a rejected key to an
  authentication failure instead of a generic provider error.
- `agentic_agents`, `agentic_workflow`, `agentic_rag`, `agentic_sqlite`,
  `agentic_test` — released on the same line so a 0.1.x application could take
  the fixes above without moving to 0.2.0.

## 0.1.1 — 2026-08-27

- Shortened every package description into the 60–180 character window pana
  scores against, which was withholding ten points for a real reason: search
  results truncated the useful half of the sentence.
- `create_agentic_app` gained the `example/` it had been missing — the library
  under the command is the half that matters when scaffolding several projects
  or testing what the template emits.

## 0.1.0 — 2026-08-27

First publication of eleven packages.

### Added

- `agentic_core` — foundation layer: immutable message and content model, JSON
  Schema with LLM-aware coercion, structured error hierarchy, cooperative
  cancellation, retry and circuit-breaker policies, typed event bus, structured
  logging, OpenTelemetry-shaped tracing, plugin registry and run context.
- `agentic_tools` — tool layer: tool contract and specification, registry with
  lazy construction, tool selection, argument repair and validation,
  human-approval gating, per-tool time budgets, bounded-concurrency execution
  and lifecycle events.
- `agentic_llm` — model layer: provider-independent `ChatModel` and
  `EmbeddingModel` ports, streaming with fragmented tool-call reassembly, a
  specification-compliant SSE decoder, shared HTTP transport with error mapping,
  adapters for OpenAI-compatible APIs, Anthropic and Gemini, and middleware for
  retries, failover, caching and instrumentation.
- `agentic_agents` — agent layer: a bounded tool-calling loop, budgets across
  four dimensions, sessions with pluggable history trimming, streaming updates,
  multi-agent delegation modelled as tool calls, and planner/executor
  decomposition.
- `agentic_memory` — memory layer: one store port over working, conversation,
  long-term and semantic memory, keyword-first retrieval with optional
  embeddings and hybrid fusion, summarising and recalling history strategies,
  memory tools, and automatic extraction.
- `agentic_workflow` — graph engine: typed nodes, validation before execution,
  branching, parallelism, mapping, loops, budgets, and runs that suspend into
  JSON and resume in another process.
- `agentic_vector` — vector store port with sealed metadata filters, exact
  in-process search with JSON snapshots, a Qdrant adapter and an embedding index.
- `agentic_rag` — loading, chunking, dense and BM25 retrieval, rank fusion,
  re-ranking, cited answers and retrieval tools.
- `agentic_mcp` — Model Context Protocol client and server over stdio, HTTP and
  in-process transports, with remote tools becoming ordinary agent tools.
- `agentic_flutter` — the umbrella: app-lifetime runtime, lifecycle-bound
  cancellation, device capabilities as tools, secret storage, and chat, approval
  and trace widgets.
- `create_agentic_app` — generates a working Flutter agent app with chat, tools,
  approval, a live trace panel and an API key kept out of the source.
- Workspace tooling: native pub workspace, melos task runner, strict shared lint
  contract, GitHub Actions for format, analyze, test, coverage, publish dry-run
  and pub.dev scoring.
