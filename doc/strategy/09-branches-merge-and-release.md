# Phase 9 — The 0.3 branches: what they are, how to merge, how to publish

Written 2026-09-18. Everything below is committed locally and **nothing is
pushed**. `main` is still at `182caa1` (0.2.0, released 2026-09-17).

## 9.1 The commits

Eight commits, in the order they were made. Each is self-contained: the
repository analyses, formats and tests green at every one of them.

| # | Commit | Branch tip | What it does | Files |
|---|---|---|---|---|
| 1 | `60734a4` | | Strategy documents (`doc/strategy/`), README status and roadmap corrected | 11 |
| 2 | `68c4f6b` | | First 3 Agent Skills + `tool/check_skills.dart`, wired into CI and melos | 8 |
| 3 | `29d9b35` | | Model identifiers that exist; `ModelDirectory.listModels`; `SwitchableChatModel`; model-name constants; nightly `check_models.dart` | 25 |
| 4 | `3dc1b13` | `feature/0.3-skills-and-models` | 32 more skills, one per package; checker learns declared types, `sample-types`, secondary libraries | 33 |
| 5 | `47c57a5` | `chore/0.3-governance` | `AGENTS.md`, `SECURITY.md`, `CODE_OF_CONDUCT.md`, issue templates, generated `llms.txt` | 12 |
| 6 | `7dfd7a7` | `feat/eval-trajectory-and-reporters` | `EvalCheck.trajectory`, `toJUnitXml`, baselines and regression gates | 8 |
| 7 | `4db0c3c` | `feat/core-trace-propagation` | W3C trace context in and out; `traceparent` on provider and MCP requests | 12 |
| 8 | `d23f337` | `feat/agentic-otel` | New package `agentic_otel`: OTLP export, batching, GenAI conventions | 20 |

### What each one changes, in one line

1. **Strategy** — analysis, roadmap and competitive comparison; no code.
2. **Skills, first cut** — the mechanism plus three exemplars, so the checker
   exists before the content does.
3. **Models** — every default had rotted and two were retired outright; adds
   discovery and run-time switching so the default matters less.
4. **Skills, complete** — 35 skills across all 14 published packages.
5. **Governance** — the files an evaluator and a contributor look for.
6. **Evals** — trajectory assertions, CI reports, baselines.
7. **Trace context** — a run is one trace across app, backend and MCP server.
8. **`agentic_otel`** — that trace reaches a collector.

## 9.2 Breaking changes in this set

Three, all in commit 3, all listed in `packages/agentic_llm/CHANGELOG.md`:

| Change | Who breaks | Migration |
|---|---|---|
| `OpenAiCompatibleChatModel.deepSeek` requires `model` | anyone calling it | pass `DeepSeekModels.flash` or a name you chose |
| `OpenAiCompatibleChatModel.mistral` requires `model` | anyone calling it | pass `MistralModels.medium` or a name you chose |
| `GeminiEmbeddingModel` defaults to `gemini-embedding-2` | anyone with an index built on `gemini-embedding-001` | pass `model: GeminiModels.embeddingLegacy`, **or** re-embed every document |

The third is the dangerous one: embedding spaces are not comparable, so an
index searched with the wrong model returns plausible nonsense rather than an
error. It needs a line in the migration guide before release — see 9.5.

The other default changes (`gpt-4o` → `gpt-5.6`, `claude-sonnet-4-…` →
`claude-sonnet-5`, `grok-2-latest` → `grok-4.6`, `gemini-2.5-flash` →
`gemini-3.8-flash`) are not breaking in the semver sense, but they change which
model — and which price — a caller gets by default. They belong in the release
notes at the top, not in a bullet list halfway down.

## 9.3 How to merge

**The branches are stacked, not parallel.** Each was cut from the previous
tip, so `feat/agentic-otel` contains all eight commits and the others contain a
prefix of them:

```
main (182caa1)
  └── 60734a4 → 68c4f6b → 29d9b35 → 3dc1b13   feature/0.3-skills-and-models
                                       └── 47c57a5   chore/0.3-governance
                                             └── 7dfd7a7   feat/eval-trajectory-and-reporters
                                                   └── 4db0c3c   feat/core-trace-propagation
                                                         └── d23f337   feat/agentic-otel
```

### Option A — merge the tip, once (simplest)

If the whole set is going in, only the last branch needs merging; it already
contains the rest.

```sh
git checkout main
git merge --no-ff feat/agentic-otel -m "0.3 development: skills, models, evals, tracing"
git branch -d feature/0.3-skills-and-models chore/0.3-governance \
              feat/eval-trajectory-and-reporters feat/core-trace-propagation
```

Verify before merging, not after:

```sh
melos run verify        # format, analyze, test, api, skills, llms, fix, flutter
```

### Option B — merge in order, one pull request each

For review, or to keep the history legible on GitHub. Merge **in this order**;
any other order conflicts, because each branch's base is the one above it.

```sh
git checkout main && git merge --ff-only feature/0.3-skills-and-models
git merge --ff-only chore/0.3-governance
git merge --ff-only feat/eval-trajectory-and-reporters
git merge --ff-only feat/core-trace-propagation
git merge --ff-only feat/agentic-otel
```

`--ff-only` is deliberate: these are already linear, and a merge commit per
branch would imply a parallelism that does not exist.

To open them as separate pull requests, push them in the same order and set each
one's base to the previous branch rather than to `main`. GitHub will then show
only that branch's own diff, and re-target each to `main` automatically as the
one before it merges.

### Option C — take some and not others

Every commit is independent in content, even though the branches are stacked, so
cherry-picking works — with one exception worth knowing:

| Want | Cherry-pick | Note |
|---|---|---|
| Just the model fixes | `29d9b35` | needs `68c4f6b` only if you keep the skill it edits; otherwise resolve one hunk |
| Just governance | `47c57a5` | independent |
| Just evals | `7dfd7a7` | independent |
| Just tracing | `4db0c3c` | independent |
| Just `agentic_otel` | `d23f337` | **depends on `4db0c3c`** in spirit: it exports spans, and the README documents propagation added there |

### Before any merge

- [ ] `melos run verify` is green on the branch being merged.
- [ ] `packages/agentic_flutter/example/pubspec.lock` is still uncommitted —
      it is an unowned working-tree change and has stayed out of all eight
      commits.
- [ ] No `.claude/`, `.config/` or `.template_probe/` directories crept in;
      they are ignored, but `git add -A` has caught the lockfile twice.

## 9.4 Publishing order

`tool/release.dart` computes this from the dependency graph — do not maintain it
by hand, and do not publish by hand. Run:

```sh
dart run tool/release.dart --version=0.3.0              # check only
dart run tool/release.dart --version=0.3.0 --publish    # irreversible
```

The order it produces today, with `agentic_otel` in it (verified 2026-09-18):

| # | Package | Depends on |
|---|---|---|
| 1 | `agentic_core` | — |
| 2 | `agentic_tools` | core |
| 3 | `agentic_llm` | core, tools |
| 4 | `agentic_agents` | core, llm, tools |
| 5 | `agentic_mcp` | core, llm, tools |
| 6 | `agentic_memory` | agents, core, llm, tools |
| 7 | `agentic_vector` | core, llm |
| 8 | `agentic_rag` | core, llm, tools, vector |
| 9 | `agentic_workflow` | agents, core, llm, tools |
| 10 | `agentic_flutter` | everything below it |
| 11 | **`agentic_otel`** | core |
| 12 | `agentic_sqlite` | agents, core, memory, vector, workflow |
| 13 | `agentic_test` | agents, core, llm |
| 14 | `agentic_tools_generator` | analyzer, build, source_gen |
| 15 | `create_agentic_app` | — (template only) |

`agentic_otel` only needs `agentic_core`, so it could publish as early as
position 2; the tool places it where the topological sort happens to put it,
which is fine — the constraint is that nothing publishes before what it depends
on.

`agentic_benchmark` and `agentic_integration` are `publish_to: none` and are
not in the list.

### Rules that have already cost time once

1. **Compile against the published siblings before releasing.** The workspace
   resolves siblings by path, which hides a missing API. `release.dart` does a
   dry run per package; that is not the same thing, so for a release with a new
   cross-package API, generate a project with `create_agentic_app` against
   pub.dev and build it.
2. **pub.dev is append-only.** Retraction hides a version for seven days and
   never removes it; anyone whose lockfile already names it keeps resolving it.
3. **After publishing, the pub cache lies.** `dart pub get` may say a
   just-published version "doesn't match any versions". Delete
   `~/AppData/Local/Pub/Cache/hosted/pub.dev/.cache/<pkg>-versions.json`.
4. **`agentic_sqlite`'s dry run is flaky** when 15 packages are checked in a
   row — its build hook compiles SQLite mid-run. It failed once and passed on
   an immediate re-run with no change. Re-run before investigating.
5. **`--allow-warnings`** exists for the warnings that are not defects (a new
   package has no pub.dev history, for instance). Read each one before using it.

## 9.5 What must happen before 0.3.0 is published

Not blockers for merging; blockers for publishing.

| # | Task | Why |
|---|---|---|
| 1 | Bump all 15 versions to `0.3.0` and the sibling constraints to `^0.3.0` | The tool checks this; a package at 0.3.0 depending on `^0.2.0` resolves users onto a combination nobody tested |
| 2 | Write `doc/migration-0.3.md` | Three breaking changes, one of which (the embedding model) fails silently |
| 3 | Roll each package's `## Unreleased` section into `## 0.3.0` | pub.dev shows the changelog; "Unreleased" on a published version is wrong |
| 4 | Root `CHANGELOG.md`: same | — |
| 5 | Set the GitHub secrets the nightly workflows need | `check_models.dart` and the conformance suite are the canaries for exactly the failure this release fixes, and they are blind without keys |
| 6 | Verified publisher on pub.dev | `publisherId` is null for all 14 published packages today |
| 7 | Re-run `melos run models:check` with keys | The model identifiers in commit 3 were verified against documentation, not against a live API |
| 8 | Tag `v0.3.0` after publishing, not before | The tag should name what was published |

## 9.6 Suggested release notes headline

> **0.3.0 — the release that stops lying to you.** Every default model
> identifier now names a model that exists; two had been retired by their
> providers. Traces leave the process over OTLP. Evals can fail a build. And
> every package ships Agent Skills, so the assistant writing your code knows
> this API instead of guessing at it.
