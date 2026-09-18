# Phase 8 — pub.dev success strategy

The engineering is ahead of the distribution: 160/160 pub points on every analysed
package, but 0–2 likes, ~0 independent downloads, 0 GitHub stars and no verified
publisher. Almost every recommendation below is cheap compared with the features
in Phases 3–4 and moves adoption more.

## 8.1 pub.dev score and listing quality

The 160 points (conventions 30, documentation 20, platforms 20, analysis 50,
up-to-date dependencies 40) are table stakes, and they are already earned. What
decides whether someone clicks *Like* or adds the package is the listing.

| Lever | Current | Action | Effort |
|---|---|---|---|
| **Verified publisher** | none (`publisherId: null`) | Register a domain publisher (for example `agentic.dev`) and transfer all packages | 1 h |
| **Keep 160 points** | only `agentic_core` scored in CI, threshold 20 | Run `pana` for every package on Linux in CI and fail below 160; re-check the four packages still pending analysis after 0.2.0 | 2 h |
| **Description** (60–180 chars, shown in search) | good but inward-looking | Lead with the outcome and keywords people search: *"AI agents for Flutter: tool calling, human approval, MCP, RAG and memory, with budgets and offline tests."* | 1 h |
| **Topics** (max 5) | `ai, agents, llm, agentic, workflow` on all | Vary per package so each appears in relevant topic pages: `mcp`, `rag`, `vector-search`, `openai`, `gemini`, `anthropic`, `chatbot`, `sqlite`, `testing`, `codegen`, `on-device` | 1 h |
| **Screenshots** field | `agentic_flutter` only | Add to `agentic_workflow` (graph view), `agentic_rag` (citations), `agentic_test` (HTML report), `create_agentic_app` (generated app) | 3 h |
| **Example tab** | examples exist | Make `example/example.dart` a **15–30 line**, runnable, keyless snippet (uses `FakeChatModel`) — it is the second thing people read | 1 d |
| **README first screen** | root README strong; status says 0.1.1 | 1 sentence of value, 1 GIF, 1 install line, 10-line example, then badges. Move philosophy lower | 1 d |
| **`funding`** | absent | GitHub Sponsors / Open Collective link | 30 min |
| **`documentation`** | points at GitHub README | Point at the docs site once live | — |
| **CHANGELOG hygiene** | per-package good; root stale | Generate root changelog from package changelogs per train | 2 h |
| **Platforms** | pure Dart packages show all platforms | Make sure `agentic_sqlite` (web) and future native bridges declare platforms honestly — wrong badges erode trust | ongoing |

## 8.2 AI agent compatibility — the highest-leverage move of 2026

Most Flutter developers now write code with Claude Code, Antigravity, Copilot,
Cursor or Codex (Flutter Q2 2026 survey). These assistants know
`dartantic_ai`, LangChain.dart and Firebase from training data; they do **not**
know `agentic_*` 0.2. Without help they will write the wrong API and the developer
will blame the package.

### 8.2.1 Ship package skills (Skills CLI 1.0)

Since 2026-09-08, `dart pub publish` bundles a top-level `skills/` directory and
`dart run skills get` installs dependency skills into every major assistant.

**Rules to follow** (dart.dev/tools/pub/package-skills, pub.dev/packages/skills
and agentskills.io; verified by installing two of these skills into a scratch
project on 2026-09-18):

- The directory must start with the package name, either spelling —
  `agentic_workflow-build-graph` or `agentic-workflow-build-graph`. The
  hyphenated form is recommended, and is the only one that also satisfies the
  agentskills.io character rule. **A directory that does not match is silently
  skipped**, with no error anywhere — which is why `check_skills.dart` treats it
  as a build failure.
- `name` must equal the directory name: lowercase letters, digits, hyphens;
  ≤ 64 characters.
- `description`: ≤ 1,024 characters; says **when** to use the skill (this is
  what the assistant matches on).
- Body: keep `SKILL.md` under 500 lines; put long material in `references/`.
- Optional `scripts/`, `references/`, `assets/`.
- No `pubspec.yaml` entry is needed; `dart pub publish` bundles `skills/`
  automatically (confirmed by a dry run listing the directory).
- Consumers install with `dart run skills@ get` (`--all`, `--agent claude`).

**Initial skills catalogue (M0: ~40 skills across 14 packages).**

| Package | Skills |
|---|---|
| `agentic_flutter` | `agentic-flutter-add-chat-agent`, `agentic-flutter-tool-approval-ui`, `agentic-flutter-secrets-and-keys`, `agentic-flutter-trace-panel`, `agentic-flutter-device-tools` |
| `agentic_core` | `agentic-core-errors-and-retry`, `agentic-core-cancellation-and-context`, `agentic-core-tracing-and-events` |
| `agentic_tools` | `agentic-tools-write-a-tool`, `agentic-tools-approval-and-untrusted-content`, `agentic-tools-registry-and-selection` |
| `agentic_tools_generator` | `agentic-tools-generator-annotate-functions`, `agentic-tools-generator-troubleshoot-build` |
| `agentic_llm` | `agentic-llm-choose-provider`, `agentic-llm-structured-output`, `agentic-llm-middleware-retry-fallback-cache`, `agentic-llm-local-models` |
| `agentic_agents` | `agentic-agents-build-tool-calling-agent`, `agentic-agents-budgets`, `agentic-agents-sessions-and-history`, `agentic-agents-multi-agent-delegation` |
| `agentic_workflow` | `agentic-workflow-build-graph`, `agentic-workflow-human-approval-and-resume`, `agentic-workflow-fix-validation-errors` |
| `agentic_memory` | `agentic-memory-add-long-term-memory`, `agentic-memory-choose-recall-strategy` |
| `agentic_vector` | `agentic-vector-choose-store`, `agentic-vector-embedding-index` |
| `agentic_rag` | `agentic-rag-index-documents`, `agentic-rag-answer-with-citations`, `agentic-rag-tune-retrieval` |
| `agentic_sqlite` | `agentic-sqlite-persist-everything` |
| `agentic_mcp` | `agentic-mcp-connect-to-server`, `agentic-mcp-expose-tools-as-server` |
| `agentic_test` | `agentic-test-record-and-replay`, `agentic-test-write-evals` |
| `create_agentic_app` | `create-agentic-app-scaffold`, `create-agentic-app-go-to-production` |
| cross-cutting (in `agentic_flutter`) | `agentic-flutter-migrate-0-1-to-0-2`, `agentic-flutter-debug-agent-behaviour` |

**Template.**

````markdown
---
name: agentic-workflow-human-approval-and-resume
description: >-
  Use when a Dart or Flutter app built with agentic_workflow needs a person to
  approve a step, or must resume a workflow after the app restarts. Covers
  HumanApprovalNode, WorkflowSnapshot, WorkflowSnapshotStore and
  SqliteWorkflowSnapshotStore. Not for single tool approvals in an agent loop —
  use agentic-tools-approval-and-untrusted-content for that.
license: MIT
metadata:
  package: agentic_workflow
  min-version: 0.2.0
---

# Human approval and resumable workflows

## When a workflow suspends
…(10–20 lines of rules, each with the reason)…

## Minimal example
```dart
…(compile-checked, ≤ 40 lines)…
```

## Common mistakes
- Writing non-JSON values into state — snapshots refuse them; convert first.
- Resuming into a changed graph — refused by design; version the graph id.

## See also
references/snapshot-format.md
````

**Quality gates in CI** (`tool/check_skills.dart`):

1. Frontmatter valid per the spec and the pub.dev naming rule.
2. Every Dart code block is extracted and **compiled against the package** — a
   skill with a broken example is worse than none.
3. Every API name mentioned exists in `api/<pkg>.txt`, so a rename breaks the
   build instead of silently rotting a skill.
4. **Evaluate the skills** with this project's own tooling: an `agentic_test`
   eval suite that gives an assistant model a task ("add a resumable approval
   step"), with and without the skill, and checks that the generated code compiles
   and passes a test. Publish the pass-rate lift — nobody else can show that
   number, and it is a strong story.

### 8.2.2 Everything else an assistant reads

| Artifact | What | Effort |
|---|---|---|
| `AGENTS.md` (repo root) | How to build, test and release; layering rules; "check the clash test before naming exports"; never edit `api/*.txt` by hand | 2 h |
| `llms.txt` / `llms-full.txt` on the docs site | Index and full concatenation of guides for tools that fetch docs | 2 h (generated) |
| **Assistant-friendly errors** | Every `AgenticException` message says what to change, and `helpUrl` links to the error page (CORE-9) — assistants act on error text directly | 3 d |
| `create_agentic_app` output | Generated `AGENTS.md` + runs `dart run skills get` (CLI-4) | 2 d |
| MCP server for the docs | Expose docs search and the API index as an MCP server (built with `agentic_mcp`, also a showcase) | 3 d |
| Dart MCP server discoverability | `dart mcp-server` includes pub.dev search — descriptions and topics (8.1) are how assistants find the package | covered by 8.1 |

## 8.3 Downloads

Downloads follow **entry points** and **dependency edges**.

1. **Win search terms.** Package names and descriptions should contain what people
   type: *chatbot*, *AI agent*, *MCP*, *RAG*, *Gemini*, *OpenAI*, *Claude*,
   *offline AI*. Topics per 8.1.
2. **Templates as entry points.** Every template (CLI-1) is a blog post, a video
   and a pub.dev dependency set.
3. **Become a dependency of other packages.** Adapters and bridges
   (`agentic_llm_firebase`, `agentic_ai_toolkit`, `agentic_chat_ui`,
   `agentic_genkit`, `DartanticChatModel`) put `agentic_*` inside other
   ecosystems' dependency graphs.
4. **Small, standalone utilities attract downloads.** Some pieces are useful
   without the framework: the SSE decoder, the JSON Schema coercion, the
   `JsonSchema` builder, the BM25 index, the retry/circuit-breaker policies. Keep
   them reachable from a single small package with no framework baggage
   (`agentic_core` already qualifies — say so in its README).
5. **Examples that people copy.** A gallery of ten runnable apps under `examples/`
   with GIFs.

## 8.4 Likes and GitHub stars

- **Ask, at the moment of success.** The generated app's first-run screen and the
  CLI's success message include one line: "If this saved you time, a ⭐ on GitHub
  or 👍 on pub.dev helps others find it."
- **Launch moments, not a trickle.** Group work into announceable trains (0.3
  "MCP 2026-07-28 with OAuth", 0.4 "agents that survive app death", 1.0).
- **Demo videos under 60 seconds.** Kill the app mid-approval and resume; offline
  Q&A in airplane mode; a Flutter app connecting to Linear through MCP OAuth.
- **Channels, in order of return for Flutter:** r/FlutterDev, Flutter Discord and
  forum, X/Bluesky with @FlutterDev tags, LinkedIn, Medium / dev.to (Flutter
  Community publication), Hacker News only for 1.0 or a genuinely novel piece (A2A
  for Dart, the skills eval result), YouTube (Flutter-focused channels), Flutter
  and Dart newsletters, local GDG and Flutter meetups.
- **"Package of the Week" style exposure.** Pitch the Flutter team's community
  channels once there is a distinctive demo; a GDE article or talk is worth
  hundreds of likes.
- **Comparisons that are fair.** "Genkit, dartantic or agentic?" guides rank well
  in search and in assistant answers, and fairness earns trust.

## 8.5 Community adoption

| Practice | Why | Action |
|---|---|---|
| **Good first issues** | Converts users to contributors | Keep 10+ open, labelled, each with a linked test to copy (the 🤝 items in Phase 7) |
| **Adapter program** | Scales integrations beyond one maintainer | Conformance suites + adapter template + listing in the index + "certified" badge |
| **RFCs** | Contributors can shape the roadmap | `doc/rfcs/` for any breaking change or new package |
| **Public roadmap** | Signals momentum | GitHub Project board mirroring Phase 7 |
| **Discussions + Discord channel** | Questions out of issues | Enable GitHub Discussions; a channel in an existing Flutter community server before running your own |
| **Office hours / livestream** | Human connection | Monthly 45-minute build-along |
| **Recognition** | Retention | Contributors in release notes; `all-contributors` table |
| **Split tests** | Contributors can find where to add tests | One test file per unit (X5) |
| **Governance** | Companies need continuity | `GOVERNANCE.md`, second publisher, security response process |

## 8.6 Enterprise adoption

Enterprises evaluate risk before features.

1. **Trust signals:** verified publisher, `SECURITY.md` with disclosure policy
   and response times, signed release tags, SBOM (CycloneDX) per release,
   OpenSSF Scorecard badge, dependency minimalism (already a strength — publish
   the transitive dependency count per package).
2. **Stability promise:** 1.0 guarantees, deprecation policy, LTS for 1.x
   (Phase 5.6).
3. **Compliance features:** encryption at rest (SQL-3), PII redaction (CORE-7),
   user-controlled memory (MEM-2), audit log (`agentic_auth`), data-residency
   friendly providers (Vertex regions, Bedrock, Azure — LLM-4), on-device mode.
4. **Security documentation:** a threat model for mobile agents (prompt
   injection via tools, MCP tool poisoning, key extraction, data exfiltration via
   URLs) with the framework's mitigations mapped to each — the existing
   untrusted-content work is a strong foundation.
5. **Observability integration:** OTLP presets for Datadog, Grafana, Google
   Cloud and Azure Monitor (4.2).
6. **Case studies and references:** three named production apps by month 12.
7. **Support options:** a paid support or consulting page (individual or partner),
   which also funds maintenance.

## 8.7 Sustainability and funding

- GitHub Sponsors and Open Collective with **specific goals** ("$1,500/month funds
  the MCP interop matrix and a monthly release").
- Apply to programmes that fund open-source infrastructure (for example Google
  and Firebase developer programmes, cloud-credit programmes for CI and
  benchmarks, foundation grants for protocol implementations such as A2A/MCP
  SDKs).
- Seek a **corporate co-maintainer**: an agency or product company building
  Flutter AI apps gains from steering the framework.
- Keep scope honest (R2): build ~12 of the 32 proposed packages in year one; list the
  rest as "community wanted".

## 8.8 Documentation quality

| Layer | Content | Status |
|---|---|---|
| **Tutorials** (learning) | "Your first agent in 10 minutes", "Add RAG to a Flutter app", "Durable approvals" | to do |
| **How-to guides** (tasks) | 40 recipes, each ≤ 1 page, runnable | to do |
| **Concepts** (understanding) | `doc/architecture.md` is excellent — split into concept pages: context, budgets, tools and approvals, untrusted content, workflows, memory, RAG, MCP | to adapt |
| **Reference** | dartdoc (complete) + error catalogue + API snapshot diffs per release | mostly done |
| **For assistants** | skills, `AGENTS.md`, `llms.txt`, docs MCP server | to do |
| **Proof** | benchmark page, conformance/interop matrix, red-team results, eval results | to do |

Style rules already visible in the codebase — every claim true, reasons given —
should be written down as `doc/STYLE.md` so contributors keep the voice.

## 8.9 Developer experience checklist

- [ ] One command from zero to a running app (CLI-6), keyless by default (CLI-8)
- [ ] `agentic doctor` explains configuration problems (stale models, missing keys, version skew)
- [ ] Error messages say what to change and link to a page
- [ ] Every public API has a runnable snippet on the docs site
- [ ] Hot-reload-safe runtime (no duplicated listeners after reload)
- [ ] DevTools extension for runs, traces and prompts (4.20)
- [ ] `dart fix` covers every mechanical breaking change
- [ ] Copy-paste examples compile in CI (docs and skills)
- [ ] Sensible defaults with required safety (budgets) — keep, and explain why in the first example

## 8.10 First 90 days: launch plan

| Week | Deliverable | Channel |
|---|---|---|
| 1 | Verified publisher, README/CHANGELOG fixes, model IDs, `SECURITY.md`, templates | — |
| 2 | Skills in all packages + `check_skills` CI; GIF of `dart run skills get` → assistant builds an agent | X/Bluesky, r/FlutterDev: "Our packages now teach your AI assistant how to use them" |
| 3 | Docs site skeleton with 5 recipes + `llms.txt` | — |
| 4 | Article: "Why AI agents on phones need budgets, approvals and lifecycle cancellation" | Medium Flutter Community, dev.to, LinkedIn |
| 5–6 | OTLP exporter preview; video "Trace your Flutter AI app in Langfuse" | YouTube short, X |
| 7 | Skills eval result: "with vs without skills" pass rates | blog + HN attempt |
| 8–9 | Markdown chat rendering + message actions; refreshed screenshots | pub.dev screenshots, r/FlutterDev |
| 10–12 | **0.3 launch**: MCP 2026-07-28 + OAuth; demo "Flutter app connects to Linear via MCP" | launch post, Flutter Discord, newsletters, GDG talk proposal |
| 12 | Community survey: "What do you need to ship AI in Flutter?" | all channels |

## 8.11 Measure what matters

Track monthly in a public `METRICS.md` (transparency is itself a trust signal):

- pub.dev likes and 30-day downloads per package (API: `/api/packages/<pkg>/score`)
- GitHub stars, forks, contributors, time-to-first-response on issues
- Docs site visitors, top search queries with no results
- `create_agentic_app` runs (opt-in only)
- Skills installs (if the `skills` tooling exposes counts; otherwise GitHub traffic on `skills/`)
- Share of issues that are questions (a docs-quality proxy — should fall)
