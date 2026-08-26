# agentic_mcp

Model Context Protocol for the agentic framework. Two directions, one
vocabulary: `McpClient` turns a remote server's tools into ordinary `Tool`
objects that every agent already knows how to run, and `McpServer` publishes
your own `ToolRegistry` to any MCP client.

```dart
import 'package:agentic_mcp/agentic_mcp.dart';

final client = McpClient(
  transport: McpHttpTransport(endpoint: Uri.parse('https://mcp.example/mcp')),
  clientInfo: const McpImplementation(name: 'my-app', version: '1.0.0'),
);
await client.initialize();

await registerMcpTools(client, registry, prefix: 'fs');
// The agent now has the server's tools, and knows nothing about MCP.
```

## What is here

| Piece | What it is for |
|---|---|
| `McpClient` | A session: lifecycle, correlation, cancellation, notifications |
| `mcpTools` / `registerMcpTools` | A server's tools as framework `Tool`s |
| `McpServer` | Your `ToolRegistry`, served over the protocol |
| `McpTransport` | The port: `send` and `incoming`, nothing else |
| `McpHttpTransport` | Streamable HTTP — every platform, web included |
| `StdioTransport` | A subprocess (in `package:agentic_mcp/io.dart`) |
| `InMemoryTransport` | Two halves wired together: tests, in-process plugins |
| `JsonRpc*` | The wire format, testable on its own |

## Six decisions worth knowing about

**MCP stops at the tool boundary.** An MCP tool becomes a `Tool`, which means it
inherits the executor's argument validation and repair, approval gating,
timeouts, budgets, retries and tracing — all written before this package
existed. Nothing above the tool layer knows MCP exists, and that is the test of
the abstraction.

**Server hints tighten defaults; they never loosen them.** MCP's tool
annotations are advisory and come from the server. An absent `readOnlyHint`
means "assume it writes"; a `destructiveHint` turns approval on. A server cannot
use them to talk a client out of asking a person first, and a caller's
`approvalRequired` always wins.

**Tools needing approval are not published.** `McpServer` withholds any tool
whose spec sets `requiresApproval`, because approval means a person confirms —
and there is no person on the far end of a socket. Publishing one would convert
a deliberate human gate into a remote call anyone with the endpoint can make.
`publishApprovalRequired: true` opts in when the client is known to enforce
consent itself.

**Cancellation crosses the boundary.** When a caller's context is cancelled the
client sends `notifications/cancelled` before it stops waiting. The server is
often a subprocess or a remote service doing real work; walking away silently
leaves it running and billed.

**Errors map onto the framework's hierarchy.** `methodNotFound` becomes a
`CapabilityNotSupportedException` (permanent), `invalidParams` a
`ValidationException`, a cancellation a `CancelledException` that is never
retryable, and anything else a retryable `ProviderException`. That is what keeps
retry policies and circuit breakers correct across an MCP boundary.

**Capabilities are checked before a call is made.** An empty `{}` means
"supported, no sub-features" — reading it as falsey disables every correct
server — and asking a server without a `prompts` capability for `prompts/list`
earns a `methodNotFound` that looks like your bug. This package checks first and
throws something that names the missing capability.

## Transports

| Transport | Where it works | When to use it |
|---|---|---|
| `McpHttpTransport` | Everywhere, web included | Remote servers; the only option on mobile |
| `StdioTransport` | Desktop, server | A local server run as a subprocess |
| `InMemoryTransport` | Everywhere | Tests, and an MCP-shaped plugin inside one app |

`StdioTransport` lives in `package:agentic_mcp/io.dart` because it imports
`dart:io`. Keeping it out of the main library is what lets an application that
only speaks HTTP still compile for the web. It is also unusable on iOS and
Android, which do not let an app spawn arbitrary processes.

A subprocess server's **stderr is not part of the protocol** — it is where a
well-behaved server logs, precisely because stdout carries JSON-RPC. Route
`StdioTransport.stderrLines` into your logger; a server that logs to stdout
instead is the single most common reason an otherwise-correct stdio session does
not work, and this package reports it as such rather than swallowing it.

## Bidirectional by design

A server can send requests *to* the client — `sampling/createMessage` to have it
run a model, `roots/list` to ask which directories it may touch. Register a
handler and declare the matching capability:

```dart
final client = McpClient(
  transport: transport,
  capabilities: McpCapabilities(roots: true),
)..handle(McpMethod.rootsList, (request, context) async => {
    'roots': [{'uri': 'file:///project', 'name': 'project'}],
  });
```

Declaring a capability without a handler is the mistake worth avoiding: the
server will ask, and every one of those requests will fail.

## Cost and performance notes

* **Filter what you register.** A server with forty tools spends a large part of
  every prompt describing thirty-eight the agent will never call, and the model
  chooses worse for it. `mcpTools(include: {...})` is cheap insurance.
* **Prefix when you connect to more than one server.** Two filesystem servers
  both offering `read_file` is the common case; without a prefix the second
  registration loses to the first.
* **Watch for `notifications/tools/list_changed`.** Tools registered at start-up
  go stale, and nothing else tells you.
* **`instructions` is worth using.** It is the server author's own account of
  how their tools fit together, which no individual tool description conveys.
  Put it in your system prompt.

## Common mistakes

| Mistake | What happens |
|---|---|
| Calling before `initialize()` | An `InvalidStateException` naming the missing step |
| Reading `capabilities: {}` as unsupported | Every correct server looks like it offers nothing |
| Ignoring the negotiated protocol version | Failures appear in whichever call first touches a changed field |
| Not echoing `Mcp-Session-Id` | A 404 several calls later, far from the cause |
| A server logging to stdout | Framing breaks; this package says so explicitly |
| Declaring `sampling` with no handler | Every server-initiated request fails |
| Publishing an approval-gated tool | A human gate becomes a remote call — refused by default |

## Documentation

* [Examples](example/) — `dart run example/agentic_mcp_example.dart`
* [Architecture](../../doc/architecture.md)
