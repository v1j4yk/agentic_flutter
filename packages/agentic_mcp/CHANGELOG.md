# Changelog

## 0.1.1

- Shortened the package description to the 60-180 character window pana
  scores against. Search engines truncate anything longer, so the ten points
  it withheld were pointing at a real defect: the useful half of the sentence
  was never being shown.

## 0.1.0

Initial release of the Model Context Protocol layer.

### Added

- **Wire format** — `JsonRpcRequest`, `JsonRpcNotification`, `JsonRpcResponse`
  and a sealed `JsonRpcMessage` that makes classifying an incoming message an
  exhaustive switch. `JsonRpcError.toException` maps protocol codes onto the
  framework's hierarchy, so retry policies and circuit breakers keep working
  across an MCP boundary.
- **Protocol** — method-name constants, `McpImplementation`, `McpCapabilities`
  (reading `{}` as "supported", keeping unknown capabilities rather than
  discarding them) and version negotiation across three revisions.
- **Client** — `McpClient` with lifecycle, response correlation, per-request
  timeouts, pagination followed to the end, capability checks before a call is
  made, cancellation propagated to the server as `notifications/cancelled`, and
  handlers for server-initiated requests such as `roots/list`.
- **Tools** — `McpTool`, `mcpTools` and `registerMcpTools`, turning a server's
  tools into ordinary `Tool` objects. Server annotations tighten the resulting
  spec and never loosen it; a caller can always demand more approval than the
  server asked for, and never less.
- **Server** — `McpServer` publishing a `ToolRegistry`, including tool listing,
  execution through the framework's own `ToolExecutor`, resources through
  caller-supplied providers, and `notifyToolsChanged`. Tools requiring human
  approval are withheld by default.
- **Transports** — `McpTransport` port; `McpHttpTransport` (Streamable HTTP with
  session identifiers, an optional listening channel, and both JSON and
  event-stream responses); `InMemoryTransport` for tests and in-process servers;
  and `StdioTransport` in `package:agentic_mcp/io.dart`, kept apart so the main
  library stays usable on the web.
- **Content translation** — MCP content blocks to and from `ContentPart`,
  preserving unknown block types as text rather than dropping them.
- **Events** — `McpSessionOpened` (carrying the negotiated revision),
  `McpToolsDiscovered` (carrying the registered names), `McpToolCalled` and
  `McpNotificationReceived`.
