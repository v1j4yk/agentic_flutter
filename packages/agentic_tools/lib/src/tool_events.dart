/// Events published while tools run.
///
/// A tool call is the part of an agent run a user most wants to see: "searching
/// the web", "reading your calendar", "sending the email". These events are how
/// a UI renders that live, and how an audit log records what an agent actually
/// did on someone's behalf.
library;

import 'package:agentic_core/agentic_core.dart';

/// Base for every tool lifecycle event.
abstract base class ToolEvent extends AgenticEvent {
  /// Creates a tool event.
  const ToolEvent({
    required super.id,
    required super.timestamp,
    required this.toolName,
    required this.callId,
    super.runId,
    super.source,
    super.traceId,
    super.spanId,
  });

  /// Name of the tool involved.
  final String toolName;

  /// Identifier correlating this event with the model's request.
  final String callId;
}

/// A tool is about to run.
///
/// Arguments are included so a UI can show what is being done, and an audit log
/// can record it. They may contain user data: apply the same care here as to
/// any other content leaving the process.
final class ToolCallStarted extends ToolEvent {
  /// Creates the event.
  ToolCallStarted({
    required super.id,
    required super.timestamp,
    required super.toolName,
    required super.callId,
    Map<String, Object?> arguments = const <String, Object?>{},
    super.runId,
    super.source,
    super.traceId,
    super.spanId,
  }) : arguments = Map<String, Object?>.unmodifiable(arguments);

  /// The validated arguments.
  final Map<String, Object?> arguments;

  @override
  String get type => 'tool.call.started';

  @override
  JsonMap payload() => <String, Object?>{
    'toolName': toolName,
    'callId': callId,
    'arguments': arguments,
  };
}

/// A tool finished, successfully or not.
///
/// Success and failure share one event because consumers overwhelmingly care
/// about the same things — which tool, how long, did it work — and splitting
/// them forces every listener to subscribe twice.
final class ToolCallCompleted extends ToolEvent {
  /// Creates the event.
  const ToolCallCompleted({
    required super.id,
    required super.timestamp,
    required super.toolName,
    required super.callId,
    required this.duration,
    required this.isError,
    required this.summary,
    this.failureKind,
    super.runId,
    super.source,
    super.traceId,
    super.spanId,
  });

  /// How long the invocation took, including validation and approval.
  final Duration duration;

  /// Whether the tool reported a failure.
  final bool isError;

  /// A short rendering of the result, truncated for display.
  final String summary;

  /// Why the call failed, when it did.
  final ToolFailureKind? failureKind;

  @override
  String get type => 'tool.call.completed';

  @override
  JsonMap payload() => pruneNulls(<String, Object?>{
    'toolName': toolName,
    'callId': callId,
    'durationMs': duration.inMilliseconds,
    'isError': isError,
    'summary': summary,
    'failureKind': failureKind?.name,
  });
}

/// A tool call is waiting for a human decision.
///
/// Emitted before the approval handler is consulted, so a UI can show the
/// prompt even when the handler itself is a plain callback.
final class ToolApprovalRequested extends ToolEvent {
  /// Creates the event.
  ToolApprovalRequested({
    required super.id,
    required super.timestamp,
    required super.toolName,
    required super.callId,
    Map<String, Object?> arguments = const <String, Object?>{},
    super.runId,
    super.source,
    super.traceId,
    super.spanId,
  }) : arguments = Map<String, Object?>.unmodifiable(arguments);

  /// The arguments the user is being asked to approve.
  final Map<String, Object?> arguments;

  @override
  String get type => 'tool.approval.requested';

  @override
  JsonMap payload() => <String, Object?>{
    'toolName': toolName,
    'callId': callId,
    'arguments': arguments,
  };
}

/// Why a tool call failed.
///
/// Reported as a category rather than a message so that UI, metrics and
/// retry logic can branch without parsing prose. The distinction that matters
/// most is [invalidArguments] — the model's mistake, and one it can fix by
/// trying again — from [executionFailed], which it cannot.
enum ToolFailureKind {
  /// No tool of that name was available to this agent.
  unknownTool,

  /// The arguments did not satisfy the tool's schema.
  invalidArguments,

  /// A human declined the invocation.
  approvalDenied,

  /// The tool exceeded its time budget.
  timeout,

  /// The tool ran and reported a failure.
  executionFailed,

  /// The tool threw something the framework could not classify.
  unexpectedError,
}
