# Agentic for Dart — ecosystem strategy

A plan to make the `agentic_*` packages the most complete AI agent toolkit for
Flutter and Dart. Written 2026-09-17 against `main` at `182caa1` (0.2.0), with
market research gathered the same day.

## Contents

| Phase | Document |
|---|---|
| 1 | [Ecosystem analysis](01-ecosystem-analysis.md) — trends, pub.dev landscape, Google's Flutter/Dart AI work, developer demand |
| 2 | [Package analysis](02-package-analysis.md) — measured portfolio, cross-cutting findings, scorecard, per-package review |
| 3 | Feature innovation (179 features): [foundation](03a-features-foundation.md) · [orchestration](03b-features-orchestration.md) · [knowledge](03c-features-knowledge.md) · [integration & UI](03d-features-integration.md) · [quality tooling](03e-features-quality.md) |
| 4 | [New packages](04-new-packages.md) — 32 package designs |
| 5 | [Ecosystem architecture](05-ecosystem-architecture.md) — tiers, dependency graph, folder structure, versioning, CI guardrails |
| 6 | [Competitive analysis](06-competitive-analysis.md) — Dart and cross-language matrices, gaps, positioning |
| 7 | [Roadmap](07-roadmap.md) — 6 months, 12 months, 24-month vision, capacity, risks, KPIs |
| 8 | [pub.dev success strategy](08-pubdev-success-strategy.md) — listing, Agent Skills, docs, community, enterprise, 90-day launch |

## Executive summary

**Where things stand.** Fourteen published packages, ~45 k lines of source,
~1,100 tests, 160/160 pub points, strict analysis, governed public API, and safety
features no other Dart framework combines (required budgets, approval gating,
untrusted-content boundaries, lifecycle cancellation, cassettes). Ecosystem score
**74/100**; architecture scores 8–10 everywhere. **Adoption is effectively zero**:
0–2 likes per package, 0 GitHub stars, no verified publisher.

**What changed in the market.** Google now backs Dart for AI (Genkit Dart, GenUI,
Firebase AI Logic, Skills CLI 1.0 on 2026-09-08). MCP moved to a stateless
2026-07-28 specification; `agentic_mcp` is two versions behind. A2A v1.0 and AG-UI
have no Dart implementations. Evals remain the industry's biggest gap, and no Dart
eval library exists apart from `agentic_test`.

**Positioning.** *The production framework for AI agents that run in Flutter
apps — safe by construction, testable offline, and fluent in every open agent
protocol.* Complement Google's packages (GenUI, Firebase, Genkit) rather than
compete with them head-on; lead on durable workflows, evals, safety, on-device
routing and protocols.

## The ten things to do first

| # | Action | Why | Effort | Ref |
|---|---|---|---|---|
| 1 | **Ship Agent Skills in every package** and validate them in CI | Assistants write most Flutter code now; the channel went live nine days ago and is almost empty | 1.2 ew | 8.2 |
| 2 | **Verified publisher**, fix the stale README status, root CHANGELOG and `recall` README | First-five-minutes trust | 1 d | 8.1 |
| 3 | **Replace stale default model IDs** and add a retirement canary | The failure that broke Gemini is queued for OpenAI, Anthropic and Grok | 3 d | X1, LLM-1 |
| 4 | **MCP 2026-07-28 + OAuth + elicitation** (decide first: build on `mcp_dart` or natively) | Remote MCP servers need both; this is the headline for 0.3 | 4 ew | MCP-1..3 |
| 5 | **`agentic_otel`**: OTLP export with GenAI conventions | Production teams need traces outside the app | 2 ew | 4.2 |
| 6 | **Markdown rendering, message actions, streaming performance** in chat | The first thing evaluators see in a demo | 3 ew | FL-1, FL-6, FL-8 |
| 7 | **Evals in CI**: trajectories, YAML datasets, reporters, baselines | Own the category nobody in Dart has | 3 ew | TEST-1..5 |
| 8 | **Durable agent runs + interrupts + guardrails + handoffs** | Table stakes set by LangGraph, OpenAI SDK and MAF; "survives app death" is the unique mobile story | 8.5 ew | AGENTS-1..4 |
| 9 | **PDF RAG** and **Firebase AI Logic adapter** | The most common RAG request; the honest answer to API keys in apps | 3 ew | RAG-1, 4.5 |
| 10 | **Docs site with recipes, error catalogue and `llms.txt`**, plus a 90-day launch plan | Distribution is the constraint, not engineering | 3 ew + ongoing | 8.8, 8.10 |

## Reading guide

- **Maintainer planning a sprint:** Phase 7 (M0, M1), then the referenced
  feature entries in Phase 3.
- **Contributor looking for work:** items marked 🤝 in Phase 7; each links to a
  specified feature in Phase 3.
- **Evaluator comparing frameworks:** Phase 6.
- **Anyone:** the summary above and the scorecard in Phase 2.

## Caveats

- pub.dev figures move daily and some packages were still in the analysis queue.
- Competitor cells marked "?" or *unverified* were not confirmed from primary
  sources; check them before quoting publicly.
- Effort estimates assume one experienced maintainer and include tests and docs;
  they are for sequencing, not commitments.
