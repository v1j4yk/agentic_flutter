# Changelog

## 0.1.1

- Shortened the package description to the 60-180 character window pana
  scores against. Search engines truncate anything longer, so the ten points
  it withheld were pointing at a real defect: the useful half of the sentence
  was never being shown.

## 0.1.0

Initial release of the Flutter bindings and the umbrella package.

### Added

- **Umbrella** — one import re-exporting `agentic_core`, `agentic_tools`,
  `agentic_llm`, `agentic_agents`, `agentic_memory`, `agentic_workflow`,
  `agentic_vector`, `agentic_rag` and `agentic_mcp`. Applications take the
  umbrella; extension packages keep depending only on the layer they extend.
- **Runtime** — `AgenticRuntime` owning the event bus, tool registry and logger
  for the app's lifetime, handing each run its own child context and
  cancellation, and disposing only what it created.
- **Lifecycle** — `LifecycleCancellation` and `BackgroundPolicy`, so a run stops
  when the app is paused or detached instead of billing for an answer nobody
  will read; `withLifecycleCancellation` for a screen that owns one run.
- **Logging** — `FlutterLogSink`, routing structured records through
  `debugPrint` (which does not truncate the way the platform log does) and
  staying silent in release unless explicitly enabled.
- **Secrets** — a `SecretStore` port with `InMemorySecretStore`,
  `LayeredSecretStore` and a `DartDefineSecretStore` that refuses unlisted keys
  in release builds, plus a plain account of why an API key in an app binary is
  a published key.
- **Device capabilities** — `locationTool`, `cameraTool`, `askUserTool` and
  `shareTool`, built over callbacks the application supplies so no plugin
  dependency reaches anybody's build. A permission denial becomes a tool failure
  the model can recover from, and a permanent one says not to ask again.
- **Widgets** — `AgenticScope` and `context.agentic`; `AgentChatController` with
  streaming, tool activity, cancellation that keeps partial text, and errors
  that do not discard the transcript; `AgentChatView`, `ChatEntryTile` and
  `ChatComposer`; `ToolApprovalSheet` and `sheetApprovalHandler`, which fail
  closed on dismissal and when there is no navigator to ask through;
  `EventRecorder` and `TraceInspector` for a bounded live trace panel.

### Changed

- `meta` is now floored at `^1.16.0` across every package rather than `^1.19.0`.
  The Flutter SDK pins `meta` to the version it ships, so the tighter floor made
  the framework unresolvable from any Flutter app — the one thing it must not
  be. The framework only uses annotations that have existed for years.
