# Changelog

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
