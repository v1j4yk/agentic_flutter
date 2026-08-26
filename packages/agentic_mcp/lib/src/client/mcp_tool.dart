/// Turning a server's tools into ordinary framework tools.
///
/// # The whole point of this package
///
/// Everything above this line — the agent loop, the executor's validation and
/// approval gating, budgets, retries, tracing — was written against `Tool`. An
/// MCP tool that becomes a `Tool` inherits all of it, and nothing anywhere else
/// in the framework needs to know that MCP exists.
///
/// That is the test of the abstraction, and it is why this file is small.
library;

import 'package:agentic_core/agentic_core.dart';
import 'package:agentic_mcp/src/client/mcp_client.dart';
import 'package:agentic_mcp/src/events/mcp_events.dart';
import 'package:agentic_mcp/src/protocol/mcp_models.dart';
import 'package:agentic_tools/agentic_tools.dart';

/// A tool that runs on an MCP server.
final class McpTool implements Tool {
  /// Wraps [descriptor] as a framework tool.
  McpTool({
    required this.client,
    required this.descriptor,
    String? name,
    this.timeout,
    bool? requiresApproval,
  }) : spec = _specFor(
         descriptor,
         name: name ?? descriptor.name,
         timeout: timeout,
         requiresApproval: requiresApproval,
       );

  /// The session this tool runs on.
  final McpClient client;

  /// What the server said about it.
  final McpToolDescriptor descriptor;

  /// A per-call ceiling, when this tool needs one different from the session's.
  final Duration? timeout;

  @override
  final ToolSpec spec;

  @override
  Future<ToolResult> call(ToolInvocation invocation) async {
    final clock = invocation.context.clock;
    final started = clock.now();

    final McpToolCallResult result;
    try {
      result = await client.callTool(
        descriptor.name,
        arguments: invocation.arguments,
        context: invocation.context,
        timeout: timeout,
      );
    } on CancelledException {
      // The caller abandoned the run. The client has already told the server;
      // this must propagate rather than becoming a tool failure the model sees
      // and "recovers" from.
      rethrow;
    } on AgenticException catch (error) {
      _publish(invocation, clock.now().difference(started), failed: true);
      // A transport or protocol failure is not something the model can fix by
      // trying different arguments, but ending the whole run over one
      // unreachable server is worse. Returned as a failure so the agent can
      // route around it, with the retryability preserved for any policy above.
      return ToolResult.failure(
        'The MCP server could not run `${descriptor.name}`: ${error.message}',
        cause: error,
        metadata: <String, Object?>{
          'mcpServer': client.session?.server.name,
          'retryable': error.isRetryable,
        },
      );
    }

    _publish(
      invocation,
      clock.now().difference(started),
      failed: result.isError,
    );

    final text = result.text;
    final metadata = <String, Object?>{
      'mcpServer': ?client.session?.server.name,
      'mcpTool': descriptor.name,
    };

    if (result.isError) {
      return ToolResult.failure(
        text.isEmpty ? 'The tool reported a failure.' : text,
        metadata: metadata,
      );
    }

    return ToolResult.success(
      // A server that returns only an image, or only a structured result, has
      // an empty text rendering. Saying so beats handing the model an empty
      // string, which reads as "the tool did nothing".
      text.isEmpty && result.structuredContent == null
          ? 'The tool completed and returned no content.'
          : text,
      data: result.structuredContent,
      parts: result.parts,
      metadata: metadata,
    );
  }

  void _publish(
    ToolInvocation invocation,
    Duration duration, {
    required bool failed,
  }) {
    final scope = invocation.context;
    final server = client.session?.server.name ?? client.transport.name;
    scope.publish(
      McpToolCalled(
        id: scope.ids.prefixed('evt'),
        timestamp: scope.clock.now(),
        server: server,
        tool: descriptor.name,
        failed: failed,
        duration: duration,
        runId: scope.runId,
        source: 'mcp:$server',
      ),
    );
  }

  /// Builds the spec a model is shown.
  ///
  /// The annotation mapping is where judgement is needed. MCP's hints are
  /// advisory and come from the server, so they are used to *tighten* defaults
  /// and never to loosen them: an unstated `readOnlyHint` means "assume it
  /// writes", and a `destructiveHint` turns approval on. A server cannot use
  /// them to talk a client out of asking a person first.
  static ToolSpec _specFor(
    McpToolDescriptor descriptor, {
    required String name,
    Duration? timeout,
    bool? requiresApproval,
  }) {
    final annotations = descriptor.annotations;
    final readOnly = annotations.readOnlyHint ?? false;
    final destructive = annotations.destructiveHint ?? !readOnly;

    return ToolSpec(
      name: name,
      description:
          descriptor.description ??
          'The `${descriptor.name}` tool, provided by an MCP server. The '
              'server supplied no description.',
      parameters: descriptor.inputSchema,
      returns: descriptor.outputSchema,
      isReadOnly: readOnly,
      // Absent means unknown, and assuming a remote side effect is safe to
      // repeat is the more dangerous of the two guesses.
      isIdempotent: annotations.idempotentHint ?? readOnly,
      requiresApproval: requiresApproval ?? (destructive && !readOnly),
      timeout: timeout,
      tags: const <String>{'mcp'},
    );
  }

  @override
  String toString() => 'McpTool(${descriptor.name})';
}

/// Discovers a server's tools and wraps each one.
///
/// [prefix] disambiguates when several servers offer a tool of the same name —
/// two filesystem servers both offering `read_file` is the common case, and
/// without a prefix the second registration silently loses to the first.
///
/// [include] filters by MCP name before wrapping. Worth using: a server with
/// forty tools spends a large part of every prompt describing thirty-eight the
/// agent will never call, and the model chooses worse for it.
///
/// ```dart
/// registry.registerAll(
///   await mcpTools(client, prefix: 'fs', include: {'read_file', 'list_dir'}),
/// );
/// ```
Future<List<McpTool>> mcpTools(
  McpClient client, {
  String? prefix,
  Set<String> include = const <String>{},
  Set<String> exclude = const <String>{},
  Set<String> approvalRequired = const <String>{},
  Duration? timeout,
  AgenticContext? context,
}) async {
  final descriptors = await client.listTools(context: context);
  final tools = <McpTool>[
    for (final descriptor in descriptors)
      if (include.isEmpty || include.contains(descriptor.name))
        if (!exclude.contains(descriptor.name))
          McpTool(
            client: client,
            descriptor: descriptor,
            name: prefix == null
                ? descriptor.name
                : '${prefix}_${descriptor.name}',
            timeout: timeout,
            requiresApproval: approvalRequired.contains(descriptor.name)
                ? true
                : null,
          ),
  ];

  final scope = context ?? client.context;
  if (scope != null) {
    final server = client.session?.server.name ?? client.transport.name;
    scope
      ..publish(
        McpToolsDiscovered(
          id: scope.ids.prefixed('evt'),
          timestamp: scope.clock.now(),
          server: server,
          count: tools.length,
          names: <String>[for (final tool in tools) tool.spec.name],
          runId: scope.runId,
          source: 'mcp:$server',
        ),
      )
      ..logger.info(
        'Discovered MCP tools',
        fields: <String, Object?>{
          'server': server,
          'offered': descriptors.length,
          'registered': tools.length,
        },
      );
  }
  return List<McpTool>.unmodifiable(tools);
}

/// Discovers and registers a server's tools in one step.
///
/// Returns the names registered, so start-up code can log or assert on them.
Future<List<String>> registerMcpTools(
  McpClient client,
  ToolRegistry registry, {
  String? prefix,
  Set<String> include = const <String>{},
  Set<String> exclude = const <String>{},
  Set<String> approvalRequired = const <String>{},
  Duration? timeout,
  bool replace = false,
  AgenticContext? context,
}) async {
  final tools = await mcpTools(
    client,
    prefix: prefix,
    include: include,
    exclude: exclude,
    approvalRequired: approvalRequired,
    timeout: timeout,
    context: context,
  );
  registry.registerAll(tools, replace: replace);
  return <String>[for (final tool in tools) tool.spec.name];
}
