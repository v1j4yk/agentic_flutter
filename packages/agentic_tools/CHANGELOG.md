# Changelog

## Unreleased

- A call denied because no approval handler is configured now tells the model
  that no one could be asked, instead of that the user declined. The model
  repeats what it is told, and a user who never saw a request should not hear
  that they refused one.

- `@ToolFunction` and `@ToolParam` annotations, read by the new
  `agentic_tools_generator` to generate tools from ordinary functions and
  methods. `isReadOnly` is required, so a tool that changes state is never
  read-only by default and exempt from untrusted-content approval.

- **Untrusted content.** `ToolSpec.returnsUntrustedContent` marks a tool whose
  output the application did not write. Once one returns successfully,
  `ToolExecutor` treats every tool that is not read-only according to
  `UntrustedContentPolicy`: `requireApproval` (the default), `refuse` or
  `allow`. `ToolApprovalRequest.untrustedSources` says which content preceded
  the request. Untrusted results reach the model wrapped in
  `<untrusted-content>` markers that text inside cannot close early.

  This does not try to detect prompt injection, which nothing does reliably.
  It guarantees that an injected instruction cannot change state unseen.

  **Behaviour change** (0.2.0): an app with an untrusted tool and a
  state-changing tool without an approval handler will now see those calls
  denied after the untrusted tool runs. Add an approval handler, or pass
  `untrustedContentPolicy: UntrustedContentPolicy.allow` for tools whose worst
  outcome is harmless.

## 0.1.1

- Shortened the package description to the 60-180 character window pana
  scores against. Search engines truncate anything longer, so the ten points
  it withheld were pointing at a real defect: the useful half of the sentence
  was never being shown.

## 0.1.0

Initial release of the tool layer.

### Added

- **Contract** — `Tool`, `ToolSpec`, `ToolInvocation` and `ToolResult`, with
  specifications validated at construction against the naming rules every major
  provider enforces.
- **Authoring** — `FunctionTool` for closure-backed tools, `FunctionTool.text`
  for the simplest case, `DelegatingTool` for cross-cutting behaviour by
  composition, and `RenamedTool` for resolving naming collisions between
  packages.
- **Registry** — `ToolRegistry` with eager and lazy registration, and `ToolSet`
  for handing each agent only the tools it needs. Specs are readable without
  constructing implementations.
- **Execution** — `ToolExecutor` performing argument repair and validation,
  human-approval gating that fails closed, per-tool time budgets enforced even
  against uncooperative tools, cancellation, bounded-concurrency batches with
  serialised writes, and tracing.
- **Events** — `ToolCallStarted`, `ToolCallCompleted` and
  `ToolApprovalRequested`, with a `ToolFailureKind` category on every failure.
