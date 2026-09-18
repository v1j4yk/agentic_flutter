---
name: agentic-mcp-expose-tools-as-server
description: >-
  Use when publishing Dart tools to an MCP client such as Claude, Cursor or an
  IDE with agentic_mcp: McpServer over a ToolRegistry, stdio and in-process
  transports, resources and prompts, which tools are withheld and why, and
  testing a server without a socket. Read this for "expose my tools over MCP"
  or "make my Dart code callable from an AI client".
license: MIT
metadata:
  package: agentic_mcp
  min-version: 0.2.0
---

# Publishing tools over MCP

## A server is a registry plus a transport

```dart
import 'package:agentic_mcp/agentic_mcp.dart';
import 'package:agentic_tools/agentic_tools.dart';

final registry = ToolRegistry()
  ..register(searchOrders)
  ..register(orderStatus);

final (clientSide, serverSide) = InMemoryTransport.pair();

final server = McpServer(
  transport: serverSide,
  registry: registry,
  serverInfo: const McpImplementation(name: 'orders', version: '1.0.0'),
  instructions: 'Read-only access to the orders database.',
);
await server.start();

// The other half is an ordinary client, in the same process.
final client = McpClient(transport: clientSide);
await client.initialize();
expect((await client.listTools()).map((t) => t.name), contains('order_status'));
```

`InMemoryTransport.pair()` is not only for tests: it is how an application
embeds an MCP server as a module rather than a subprocess, and it is why
lifecycle, correlation, pagination and cancellation are all testable without a
socket. Develop against it first.

## Serving to an outside client

Be aware of what this package does and does not ship. The transports here are
**client-side**: `McpHttpTransport` calls a remote server, and `StdioTransport`
(in `package:agentic_mcp/io.dart`) spawns one as a subprocess. There is no
ready-made transport that serves this process's own stdin and stdout, and no
HTTP server host.

So publishing to Claude Desktop, Cursor or an IDE means writing a transport —
which is small, because the interface is four members:

```dart
abstract interface class McpTransport implements Disposable {
  String get name;
  Stream<JsonMap> get incoming;   // newline-delimited JSON from the peer
  bool get isOpen;
  Future<void> send(JsonMap message);
}
```

For stdio: read `stdin` as lines, decode each as JSON into a broadcast stream,
and write `jsonEncode(message)` plus a newline to `stdout`. The one rule that
catches everyone is below — stdout belongs to the protocol.

## What gets published, and what does not

```dart
server.publishedTools;    // what a client will actually see
```

A tool whose spec sets `requiresApproval: true` is **withheld**, unless you pass
`publishApprovalRequired: true` and mean it. Approval means a person confirms,
and there is no person on the far end of a socket: publishing such a tool
converts "ask the user" into "just do it". If a destructive tool must be
exposed, make the *client* responsible for approval, and say so in
`instructions`.

Everything else is derived from the `ToolSpec` you already wrote: name,
description, JSON schema, and annotations (`readOnlyHint`, `idempotentHint`)
from `isReadOnly` and `isIdempotent`. Getting those flags right locally is what
makes the server honest remotely.

## Resources and prompts

```dart
McpServer(
  transport: transport,
  registry: registry,
  resourceProvider: (context) async => [
    {'uri': 'orders://schema', 'name': 'Order schema', 'mimeType': 'application/json'},
  ],
  resourceReader: (uri, context) async =>
      uri == 'orders://schema' ? [{'uri': uri, 'text': schemaJson}] : null,
);
```

Resources are how a client reads context without calling a tool — a schema, a
style guide, a changelog. Tell clients when things change with
`notifyToolsChanged()` and `notifyResourcesChanged()`.

## Publishing an agent or a workflow

An agent is already a tool:

```dart
final registry = ToolRegistry()..register(AgentTool(researchAgent));
```

That is a cheap distribution channel: a Dart agent becomes something Claude,
Cursor or an IDE can call, with no protocol work beyond this.

## Before you ship one

- **Name tools for a stranger.** The client's model has none of your context;
  `order_status` beats `status`, and the description decides whether it is
  called at all.
- **Keep results small.** Whatever you return lands in someone's context
  window and is billed to them.
- **Return failures as values.** A `ToolResult.failure` explaining what to do
  next is more useful to a remote model than an exception it cannot see.
- **Do not trust arguments.** They come from a model on someone else's machine:
  validate, scope database queries, and never interpolate them into a query or
  a shell.

## Version reality check

This package implements 2025-06-18 and earlier. The current specification
(2026-07-28) changed the handshake and moved several features, so a client
pinned to the newest version may refuse to connect. Negotiation fails with a
clear error rather than half-working, which is the behaviour you want, but plan
for it before promising compatibility.

## Common mistakes

- Publishing a destructive tool and assuming the client will ask first.
- One giant `do_everything` tool with a `mode` argument: models choose badly
  among modes, and the schema stops describing anything.
- Returning 200 KB of JSON from a list tool.
- Forgetting `server.start()`, so the transport is open and nothing answers.
- Logging to stdout in a stdio server — that stream *is* the protocol, and one
  stray `print` produces an unparsable message. Log to stderr.
- Expecting `StdioTransport` to serve: it connects *to* a subprocess, it does
  not turn this process into one.

## See also

- `agentic-mcp-connect-to-server` — the client side
- `agentic-tools-write-a-tool` — the specs being published
- `agentic-agents-multi-agent-delegation` — publishing an agent as a tool
