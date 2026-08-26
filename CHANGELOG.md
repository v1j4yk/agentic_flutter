# Changelog

All notable changes to this repository are documented here. Each package also
keeps its own changelog, which is what pub.dev displays.

This project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).
Until 1.0.0, minor versions may contain breaking changes; they will always be
listed here.

## [Unreleased]

### Added

- `agentic_core` 0.1.0 — foundation layer: immutable message and content model,
  JSON Schema with LLM-aware coercion, structured error hierarchy, cooperative
  cancellation, retry and circuit-breaker policies, typed event bus, structured
  logging, OpenTelemetry-shaped tracing, plugin registry and run context.
- `agentic_tools` 0.1.0 — tool layer: tool contract and specification, registry
  with lazy construction, tool selection, argument repair and validation,
  human-approval gating, per-tool time budgets, bounded-concurrency execution
  and lifecycle events.
- `agentic_llm` 0.1.0 — model layer: provider-independent `ChatModel` and
  `EmbeddingModel` ports, streaming with fragmented tool-call reassembly, a
  specification-compliant SSE decoder, shared HTTP transport with error mapping,
  adapters for OpenAI-compatible APIs, Anthropic and Gemini, and middleware for
  retries, failover, caching and instrumentation.
- `agentic_agents` 0.1.0 — agent layer: a bounded tool-calling loop, budgets
  across four dimensions, sessions with pluggable history trimming, streaming
  updates, multi-agent delegation modelled as tool calls, and planner/executor
  decomposition.
- `agentic_memory` 0.1.0 — memory layer: one store port over working,
  conversation, long-term and semantic memory, keyword-first retrieval with
  optional embeddings and hybrid fusion, summarising and recalling history
  strategies, memory tools, and automatic extraction.
- `agentic_workflow` 0.1.0 — graph engine: typed nodes, validation before
  execution, branching, parallelism, mapping, loops, budgets, and runs that
  suspend into JSON and resume in another process.
- Workspace tooling: native pub workspace, melos task runner, strict shared lint
  contract, GitHub Actions for format/analyze/test/coverage/publish-dry-run and
  pub.dev scoring.
