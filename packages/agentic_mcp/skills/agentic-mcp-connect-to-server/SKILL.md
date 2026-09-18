---
name: agentic-mcp-connect-to-server
description: >-
  Use when connecting to a Model Context Protocol server from Dart or Flutter
  with agentic_mcp: McpClient, the HTTP and stdio transports, turning remote
  tools into ordinary agent tools with registerMcpTools, resources and prompts,
  and the trust rules that apply to anything a server returns. Read this for
  "use an MCP server in my app", "MCP tools in my agent", or a failing MCP
  handshake.
license: MIT
metadata:
  package: agentic_mcp
  min-version: 0.2.0
---

# Connecting to an MCP server

## Two transports, one client

```dart
import 'package:agentic_mcp/agentic_mcp.dart';

final client = McpClient(
  transport: McpHttpTransport(endpoint: Uri.parse('https://example.com/mcp')),
  clientInfo: const McpImplementation(name: 'my-app', version: '1.0.0'),
);
final session = await client.initialize();
print('connected to ${session.server.name} on ${session.protocolVersion}');
```

A local server is a subprocess, which needs `dart:io` and so lives in its own
library — keeping the main one usable on the web:

```dart
import 'package:agentic_mcp/io.dart';

final client = McpClient(
  transport: await StdioTransport.spawn(
    executable: 'npx',
    arguments: ['-y', '@modelcontextprotocol/server-filesystem', '/data'],
  ),
);
```

**Not on mobile.** iOS and Android do not let an app spawn arbitrary processes,
so on a phone MCP means `McpHttpTransport`. `InMemoryTransport.pair()` connects
a client and server in one process, which is how to test all of this without a
socket.

## Remote tools become ordinary tools

```dart
final registry = ToolRegistry();
final names = await registerMcpTools(
  client,
  registry,
  prefix: 'fs',                       // avoids collisions between servers
  include: {'read_file', 'list_directory'},
  approvalRequired: {'write_file'},   // insist, whatever the server claims
);
```

Nothing above the tool layer learns that MCP exists: the agent, the approval
sheet and the trace all see a `Tool`. `mcpTools(client)` returns them without
registering, when you want to inspect first.

## The trust rules, which are not optional

A server is on the other side of a trust boundary, so:

1. **Annotations may only tighten.** A server saying `readOnlyHint: true` does
   not make a tool read-only here; an absent hint means "assume it writes".
2. **MCP results are untrusted content.** Whatever comes back was written
   outside your application, so after an MCP tool returns, a tool that is not
   read-only needs approval. That is the defence against a server — or a
   document it read — telling your model to do something else.
3. **Approval-required tools are never re-published.** If your own server
   exposes a registry, a tool needing human approval is withheld, because there
   is no person at the far end of a socket.

Use `prefix:` whenever you connect to more than one server: two servers with a
`search` tool otherwise collide, and the model cannot tell them apart.

## Resources and prompts

```dart
for (final resource in await client.listResources()) print(resource.uri);
final contents = await client.readResource('file:///data/report.md');
final prompt = await client.getPrompt('summarise', arguments: {'style': 'terse'});
```

Resources are data the server offers; prompts are templates it suggests. Both
are content, not instructions — the same trust rule applies.

## Lifecycle

```dart
await client.ping();                    // is it still there
client.notifications.listen(handle);    // tools changed, resources changed, progress
await client.dispose();                 // closes the transport, kills a spawned process
```

`initialize()` negotiates a protocol version both sides support and fails with a
clear error when they cannot agree — better than the first mismatched field
failing three calls later. Dispose matters especially for stdio: an undisposed
client leaves a process running.

## Version reality check

This package speaks 2025-06-18, 2025-03-26 and 2024-11-05. The current MCP
specification has moved on (2025-11-25, then 2026-07-28, which changed the
handshake substantially and deprecated roots and sampling), and there is no
OAuth support here yet. So: servers pinned to older versions work; a hosted
server requiring OAuth or the newest spec does not yet. Check
`kSupportedProtocolVersions` before promising a user it will connect.

## Common mistakes

- Trying `StdioTransport` on Android or iOS.
- Connecting two servers with no `prefix`, then debugging why the wrong
  `search` ran.
- Trusting `readOnlyHint` from a server you do not control.
- Forgetting `dispose`, leaving a subprocess alive after the screen closes.
- Being surprised by an approval prompt after an MCP call — that is the
  untrusted-content rule working.

## See also

- `agentic-mcp-expose-tools-as-server` — the other direction
- `agentic-tools-approval-and-untrusted-content` — the trust rules in full
- `agentic-tools-write-a-tool` — what a remote tool becomes locally
