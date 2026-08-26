/// Events published while a workflow runs.
///
/// A workflow is the part of an agentic system most likely to be *watched* —
/// by a progress screen, an operations dashboard, or someone waiting to approve
/// a step. These events are what those bind to.
library;

import 'package:agentic_core/agentic_core.dart';
import 'package:agentic_workflow/src/engine/workflow_run.dart';

/// Base for every workflow event.
abstract base class WorkflowEvent extends AgenticEvent {
  /// Creates a workflow event.
  const WorkflowEvent({
    required super.id,
    required super.timestamp,
    required this.graphId,
    required this.workflowRunId,
    super.runId,
    super.source,
    super.traceId,
    super.spanId,
  });

  /// The graph being run.
  final String graphId;

  /// Identifier of this workflow run.
  ///
  /// Distinct from [AgenticEvent.runId], which identifies the enclosing agentic
  /// run — a workflow may be one step inside something larger.
  final String workflowRunId;
}

/// A run began, or resumed.
final class WorkflowStarted extends WorkflowEvent {
  /// Creates the event.
  const WorkflowStarted({
    required super.id,
    required super.timestamp,
    required super.graphId,
    required super.workflowRunId,
    required this.nodeCount,
    this.isResumed = false,
    super.runId,
    super.source,
    super.traceId,
    super.spanId,
  });

  /// How many nodes the graph has.
  final int nodeCount;

  /// Whether this is a resumption rather than a fresh start.
  final bool isResumed;

  @override
  String get type => 'workflow.started';

  @override
  JsonMap payload() => pruneNulls(<String, Object?>{
    'graphId': graphId,
    'workflowRunId': workflowRunId,
    'nodeCount': nodeCount,
    'isResumed': isResumed ? true : null,
  });
}

/// A node is about to run.
final class WorkflowNodeStarted extends WorkflowEvent {
  /// Creates the event.
  const WorkflowNodeStarted({
    required super.id,
    required super.timestamp,
    required super.graphId,
    required super.workflowRunId,
    required this.nodeId,
    required this.nodeType,
    required this.step,
    super.runId,
    super.source,
    super.traceId,
    super.spanId,
  });

  /// The node starting.
  final String nodeId;

  /// Its type.
  final String nodeType;

  /// Position in the run.
  final int step;

  @override
  String get type => 'workflow.node.started';

  @override
  JsonMap payload() => <String, Object?>{
    'graphId': graphId,
    'nodeId': nodeId,
    'nodeType': nodeType,
    'step': step,
  };
}

/// A node finished.
final class WorkflowNodeCompleted extends WorkflowEvent {
  /// Creates the event.
  WorkflowNodeCompleted({
    required super.id,
    required super.timestamp,
    required super.graphId,
    required super.workflowRunId,
    required this.nodeId,
    required this.nodeType,
    required this.step,
    required this.duration,
    List<String> writes = const <String>[],
    super.runId,
    super.source,
    super.traceId,
    super.spanId,
  }) : writes = List<String>.unmodifiable(writes);

  /// The node that finished.
  final String nodeId;

  /// Its type.
  final String nodeType;

  /// Position in the run.
  final int step;

  /// How long it took.
  final Duration duration;

  /// The state keys it wrote.
  ///
  /// Keys only, not values: a workflow's state routinely holds documents and
  /// model output, and copying all of it into every event would dominate the
  /// cost of running one.
  final List<String> writes;

  @override
  String get type => 'workflow.node.completed';

  @override
  JsonMap payload() => pruneNulls(<String, Object?>{
    'graphId': graphId,
    'nodeId': nodeId,
    'nodeType': nodeType,
    'step': step,
    'durationMs': duration.inMilliseconds,
    'writes': writes.isEmpty ? null : writes,
  });
}

/// A run paused, waiting for something outside it.
///
/// The event an approval interface listens for. It carries enough to render the
/// prompt; the snapshot needed to resume is on the result.
final class WorkflowSuspended extends WorkflowEvent {
  /// Creates the event.
  const WorkflowSuspended({
    required super.id,
    required super.timestamp,
    required super.graphId,
    required super.workflowRunId,
    required this.nodeId,
    required this.kind,
    required this.message,
    super.runId,
    super.source,
    super.traceId,
    super.spanId,
  });

  /// The node that suspended.
  final String nodeId;

  /// What is being waited for.
  final String kind;

  /// What is being asked.
  final String message;

  @override
  String get type => 'workflow.suspended';

  @override
  JsonMap payload() => <String, Object?>{
    'graphId': graphId,
    'workflowRunId': workflowRunId,
    'nodeId': nodeId,
    'kind': kind,
    'message': message,
  };
}

/// A run ended, for any reason.
final class WorkflowCompleted extends WorkflowEvent {
  /// Creates the event.
  const WorkflowCompleted({
    required super.id,
    required super.timestamp,
    required super.graphId,
    required super.workflowRunId,
    required this.status,
    required this.steps,
    required this.duration,
    super.runId,
    super.source,
    super.traceId,
    super.spanId,
  });

  /// How it ended.
  final WorkflowStatus status;

  /// How many nodes ran.
  final int steps;

  /// Total wall-clock duration.
  final Duration duration;

  @override
  String get type => 'workflow.completed';

  @override
  JsonMap payload() => <String, Object?>{
    'graphId': graphId,
    'workflowRunId': workflowRunId,
    'status': status.name,
    'steps': steps,
    'durationMs': duration.inMilliseconds,
  };
}
