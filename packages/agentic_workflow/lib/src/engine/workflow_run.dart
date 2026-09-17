/// What a run produced, and what it takes to resume one.
library;

import 'package:agentic_core/agentic_core.dart';
import 'package:agentic_workflow/src/graph/workflow_node.dart';
import 'package:agentic_workflow/src/state/workflow_state.dart';
import 'package:meta/meta.dart';

/// How a run ended.
enum WorkflowStatus {
  /// Reached an end node or a terminating outcome.
  completed,

  /// Paused, waiting for something outside the workflow.
  ///
  /// Not a failure. The run holds a [WorkflowResult.snapshot] that restores it,
  /// possibly on a different device, days later.
  suspended,

  /// A step budget was reached.
  budgetExhausted,

  /// The run was cancelled.
  cancelled,

  /// A node failed and the run stopped.
  failed;

  /// Whether the run finished successfully.
  bool get isComplete => this == completed;

  /// Whether the run can be resumed.
  bool get isResumable => this == suspended;
}

/// One node execution.
@immutable
final class NodeExecution {
  /// Creates a record of one step.
  NodeExecution({
    required this.nodeId,
    required this.nodeType,
    required this.step,
    required this.duration,
    required this.outcome,
    Map<String, Object?> writes = const <String, Object?>{},
    this.error,
  }) : writes = Map<String, Object?>.unmodifiable(writes);

  /// The node that ran.
  final String nodeId;

  /// Its type, so a trace reads without the graph beside it.
  final String nodeType;

  /// Position of this step in the run, from zero.
  final int step;

  /// How long the node took.
  final Duration duration;

  /// A short description of what it decided.
  final String outcome;

  /// What it wrote to state.
  final Map<String, Object?> writes;

  /// The failure, when the node failed.
  final AgenticException? error;

  /// Serialises the record.
  JsonMap toJson() => pruneNulls(<String, Object?>{
    'step': step,
    'nodeId': nodeId,
    'nodeType': nodeType,
    'outcome': outcome,
    'durationMs': duration.inMilliseconds,
    'writes': writes.isEmpty ? null : writes.keys.toList(),
    'error': error?.toJson(),
  });

  @override
  String toString() =>
      'NodeExecution($step: $nodeId -> $outcome, '
      '${duration.inMilliseconds}ms)';
}

/// Everything needed to resume a suspended run.
///
/// # Why this is JSON and nothing else
///
/// A run paused for approval outlives the process that started it. Someone
/// approves it the next morning, possibly on another device. So a snapshot is
/// data: the graph is looked up by identifier, and everything else round-trips
/// through JSON.
///
/// That is also why workflow state must be JSON-encodable — the constraint is
/// not arbitrary, it is what makes suspension real rather than a pause that
/// dies with the app.
///
/// # The serialised shape is versioned
///
/// A snapshot saved by one release of an app can be resumed by the next, so
/// [toJson] writes [formatVersion] and [WorkflowSnapshot.fromJson] checks it. A
/// snapshot from a *newer* format is refused rather than guessed at: resuming a
/// run whose state was only half understood is how an approval gets applied to
/// the wrong document. When the shape changes, the version goes up and reading
/// the old one stays supported.
@immutable
final class WorkflowSnapshot {
  /// Creates a snapshot.
  WorkflowSnapshot({
    required this.graphId,
    required this.runId,
    required this.nodeId,
    required this.state,
    required this.suspension,
    required this.startedAt,
    required this.suspendedAt,
    required this.step,
    Map<String, int> visits = const <String, int>{},
  }) : visits = Map<String, int>.unmodifiable(visits);

  /// Restores a snapshot from JSON.
  ///
  /// Throws a [SerializationException] for a snapshot written by a newer
  /// format than this build understands.
  factory WorkflowSnapshot.fromJson(JsonMap json) {
    final version = json.intOr('formatVersion', 1);
    if (version > formatVersion) {
      throw SerializationException(
        'This workflow snapshot uses format $version, and this build of '
        'agentic_workflow reads up to $formatVersion. Upgrade the package to '
        'resume it; resuming a run whose state is only partly understood could '
        'apply a decision to the wrong data.',
        path: 'formatVersion',
      );
    }
    return WorkflowSnapshot._fromCurrentJson(json);
  }

  factory WorkflowSnapshot._fromCurrentJson(JsonMap json) => WorkflowSnapshot(
    graphId: json.requireString('graphId'),
    runId: json.requireString('runId'),
    nodeId: json.requireString('nodeId'),
    state: WorkflowState.fromJson(json.requireObject('state')),
    suspension: NodeSuspension.fromJson(json.requireObject('suspension')),
    startedAt: json.requireDateTime('startedAt'),
    suspendedAt: json.requireDateTime('suspendedAt'),
    step: json.intOr('step', 0),
    visits: <String, int>{
      for (final entry in (json.optionalObject('visits') ?? const {}).entries)
        entry.key: (entry.value! as num).toInt(),
    },
  );

  /// The version of the serialised shape this build writes.
  ///
  /// Snapshots written before the field existed (0.1) have exactly the version
  /// 1 shape, and are read as version 1.
  static const int formatVersion = 1;

  /// Which graph this run belongs to.
  ///
  /// Checked on resume. Restoring a snapshot into a graph that has since
  /// changed shape is how a resumed run walks into a node that no longer
  /// exists.
  final String graphId;

  /// The run's identifier, preserved across the pause.
  final String runId;

  /// The node that suspended, and where execution restarts.
  final String nodeId;

  /// The state as it stood when the run paused.
  final WorkflowState state;

  /// What is being waited for.
  final NodeSuspension suspension;

  /// When the run originally started.
  final DateTime startedAt;

  /// When it paused.
  final DateTime suspendedAt;

  /// How many steps had run before the pause.
  final int step;

  /// Visit counts per node, so a loop resumes where it left off.
  final Map<String, int> visits;

  /// Serialises the snapshot.
  JsonMap toJson() => <String, Object?>{
    'formatVersion': formatVersion,
    'graphId': graphId,
    'runId': runId,
    'nodeId': nodeId,
    'state': state.toJson(),
    'suspension': suspension.toJson(),
    'startedAt': startedAt.toIso8601String(),
    'suspendedAt': suspendedAt.toIso8601String(),
    'step': step,
    'visits': visits,
  };

  @override
  String toString() =>
      'WorkflowSnapshot($graphId/$runId at $nodeId, '
      '${suspension.kind})';
}

/// The outcome of running a workflow.
@immutable
final class WorkflowResult {
  /// Creates a result.
  WorkflowResult({
    required this.graphId,
    required this.runId,
    required this.status,
    required this.state,
    required this.duration,
    List<NodeExecution> executions = const <NodeExecution>[],
    this.snapshot,
    this.error,
  }) : executions = List<NodeExecution>.unmodifiable(executions);

  /// The graph that ran.
  final String graphId;

  /// This run's identifier.
  final String runId;

  /// How it ended.
  final WorkflowStatus status;

  /// The state as it stands.
  final WorkflowState state;

  /// Every node execution, in order.
  final List<NodeExecution> executions;

  /// How to resume, when [status] is [WorkflowStatus.suspended].
  final WorkflowSnapshot? snapshot;

  /// The failure, when the run failed.
  final AgenticException? error;

  /// How long the run took.
  final Duration duration;

  /// How many nodes ran.
  int get steps => executions.length;

  /// Whether the run finished successfully.
  bool get isComplete => status.isComplete;

  /// What the run is waiting for, when suspended.
  NodeSuspension? get suspension => snapshot?.suspension;

  /// Reads a value from the final state.
  T? output<T>(String key) => state.get<T>(key);

  /// Throws unless the run completed.
  ///
  /// A suspended run is not a failure, but it is also not an answer — treating
  /// its partial state as final is the mistake this guards.
  void ensureComplete() {
    if (isComplete) return;
    final failure = error;
    if (failure != null) throw failure;
    throw InvalidStateException(
      'The workflow `$graphId` ended as `${status.name}` after $steps step(s), '
      '${status.isResumable ? 'and is waiting to be resumed.' : 'without '
                'completing.'}',
      currentState: status.name,
      expectedState: WorkflowStatus.completed.name,
    );
  }

  /// Serialises the result, excluding state values.
  JsonMap toJson() => pruneNulls(<String, Object?>{
    'graphId': graphId,
    'runId': runId,
    'status': status.name,
    'steps': steps,
    'durationMs': duration.inMilliseconds,
    'executions': executions.map((e) => e.toJson()).toList(),
    'suspension': snapshot?.suspension.toJson(),
    'error': error?.toJson(),
  });

  @override
  String toString() =>
      'WorkflowResult($graphId, ${status.name}, $steps steps, '
      '${duration.inMilliseconds}ms)';
}
