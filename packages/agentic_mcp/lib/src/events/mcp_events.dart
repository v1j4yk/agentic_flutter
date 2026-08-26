/// Events published by the MCP layer.
///
/// # What these answer
///
/// An MCP server is somebody else's code, often somebody else's process, and
/// frequently somebody else's machine. When an agent starts behaving oddly, the
/// first question is whether the server it depends on is healthy, slow, or
/// quietly offering a different set of tools than it did at start-up. These
/// events answer that without attaching a debugger to a subprocess.
///
/// No payload carries tool arguments or results. Those are the caller's data,
/// they are frequently large, and `agentic_tools` already publishes its own
/// events for a tool call's own lifecycle.
library;

import 'package:agentic_core/agentic_core.dart';

/// Base for every MCP event.
abstract base class McpEvent extends AgenticEvent {
  /// Creates an MCP event.
  const McpEvent({
    required super.id,
    required super.timestamp,
    required this.server,
    super.runId,
    super.source,
    super.traceId,
    super.spanId,
  });

  /// The server involved.
  final String server;
}

/// A session was negotiated.
final class McpSessionOpened extends McpEvent {
  /// Creates the event.
  McpSessionOpened({
    required super.id,
    required super.timestamp,
    required super.server,
    required this.transport,
    required this.protocolVersion,
    List<String> capabilities = const <String>[],
    super.runId,
    super.source,
    super.traceId,
    super.spanId,
  }) : capabilities = List<String>.unmodifiable(capabilities);

  /// Which transport carried it.
  final String transport;

  /// The revision both sides agreed on.
  ///
  /// Worth recording: a server that quietly downgrades to an older revision
  /// explains a surprising number of "that field is always missing" reports.
  final String protocolVersion;

  /// What the server said it offers.
  final List<String> capabilities;

  @override
  String get type => 'mcp.session.opened';

  @override
  JsonMap payload() => pruneNulls(<String, Object?>{
    'server': server,
    'transport': transport,
    'protocolVersion': protocolVersion,
    'capabilities': capabilities.isEmpty ? null : capabilities,
  });
}

/// Tools were discovered from a server.
final class McpToolsDiscovered extends McpEvent {
  /// Creates the event.
  McpToolsDiscovered({
    required super.id,
    required super.timestamp,
    required super.server,
    required this.count,
    List<String> names = const <String>[],
    super.runId,
    super.source,
    super.traceId,
    super.spanId,
  }) : names = List<String>.unmodifiable(names);

  /// How many tools were found.
  final int count;

  /// Their names, as registered.
  ///
  /// Kept because "why is the model not using the tool I added?" is nearly
  /// always answered by comparing this list against what was expected —
  /// a prefix, a rename, or a server that never advertised it.
  final List<String> names;

  @override
  String get type => 'mcp.tools.discovered';

  @override
  JsonMap payload() => pruneNulls(<String, Object?>{
    'server': server,
    'count': count,
    'names': names.isEmpty ? null : names,
  });
}

/// A tool call on a server finished.
final class McpToolCalled extends McpEvent {
  /// Creates the event.
  const McpToolCalled({
    required super.id,
    required super.timestamp,
    required super.server,
    required this.tool,
    required this.duration,
    this.failed = false,
    super.runId,
    super.source,
    super.traceId,
    super.spanId,
  });

  /// The tool that ran, by its MCP name.
  final String tool;

  /// Whether the tool reported a failure.
  final bool failed;

  /// How long the round trip took.
  final Duration duration;

  @override
  String get type => 'mcp.tool.called';

  @override
  JsonMap payload() => pruneNulls(<String, Object?>{
    'server': server,
    'tool': tool,
    'failed': failed ? true : null,
    'durationMs': duration.inMilliseconds,
  });
}

/// The server sent a notification.
final class McpNotificationReceived extends McpEvent {
  /// Creates the event.
  const McpNotificationReceived({
    required super.id,
    required super.timestamp,
    required super.server,
    required this.method,
    super.runId,
    super.source,
    super.traceId,
    super.spanId,
  });

  /// Which notification, such as `notifications/tools/list_changed`.
  final String method;

  @override
  String get type => 'mcp.notification.received';

  @override
  JsonMap payload() => <String, Object?>{'server': server, 'method': method};
}
