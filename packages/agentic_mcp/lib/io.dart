/// The subprocess transport, for platforms that have processes.
///
/// Kept out of the main library because it imports `dart:io`. An application
/// that only speaks HTTP still compiles for the web; one that spawns a server
/// imports this instead.
///
/// ```dart
/// import 'package:agentic_mcp/agentic_mcp.dart';
/// import 'package:agentic_mcp/io.dart';
///
/// final client = McpClient(
///   transport: await StdioTransport.spawn(
///     executable: 'npx',
///     arguments: ['-y', '@modelcontextprotocol/server-filesystem', '/data'],
///   ),
/// );
/// ```
///
/// Not usable on iOS or Android, which do not let an application spawn
/// arbitrary processes; on mobile, MCP means `McpHttpTransport`.
library;

export 'src/transport/stdio_transport.dart' show StdioTransport;
