# Examples

Run with `dart run example/agentic_mcp_example.dart`.

The example runs offline: client and server sit in one process, connected by
`InMemoryTransport`. Swap it for `McpHttpTransport` (any platform, including the
web) or `StdioTransport` from `package:agentic_mcp/io.dart` (desktop and server,
where subprocesses exist) and nothing else in the file changes.
