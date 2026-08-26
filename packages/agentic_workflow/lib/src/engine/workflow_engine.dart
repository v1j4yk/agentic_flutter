/// Running a workflow.
///
/// The engine walks the graph: run a node, apply its writes, follow an edge,
/// repeat. Everything interesting is in what happens around that.
///
/// * **Bounded.** A graph with cycles is bounded by a step budget, for the same
///   reason an agent loop is: the failure mode is not a crash, it is a workflow
///   that runs correctly and forever.
/// * **Suspendable.** A node can pause the run and hand back a serialisable
///   snapshot. The app can be killed; the run resumes from the snapshot.
/// * **Traced.** Every step is recorded, so a wrong answer is attributable to a
///   node rather than to the workflow as a whole.
library;

import 'dart:async';

import 'package:agentic_core/agentic_core.dart';
import 'package:agentic_workflow/src/engine/workflow_run.dart';
import 'package:agentic_workflow/src/events/workflow_events.dart';
import 'package:agentic_workflow/src/graph/workflow_graph.dart';
import 'package:agentic_workflow/src/graph/workflow_node.dart';
import 'package:agentic_workflow/src/state/workflow_state.dart';
import 'package:meta/meta.dart';

/// Bounds on a single workflow run.
///
/// The same discipline as an agent budget, for the same reason: a cyclic graph
/// with no bound is an outage waiting for the right input.
@immutable
final class WorkflowBudget {
  /// Creates a budget.
  const WorkflowBudget({
    this.maxSteps = 100,
    this.maxNodeVisits = 25,
    this.maxDuration = const Duration(minutes: 10),
  }) : assert(maxSteps >= 1, 'maxSteps must be at least 1'),
       assert(maxNodeVisits >= 1, 'maxNodeVisits must be at least 1');

  /// The default: generous for a linear graph, firm for a runaway loop.
  static const WorkflowBudget standard = WorkflowBudget();

  /// Total node executions allowed.
  final int maxSteps;

  /// How many times any one node may run.
  ///
  /// Catches a tight loop far earlier than [maxSteps], and names the node
  /// responsible — which a total step count cannot.
  final int maxNodeVisits;

  /// Wall-clock ceiling.
  final Duration maxDuration;

  /// Serialises the budget.
  JsonMap toJson() => <String, Object?>{
    'maxSteps': maxSteps,
    'maxNodeVisits': maxNodeVisits,
    'maxDurationMs': maxDuration.inMilliseconds,
  };

  @override
  String toString() =>
      'WorkflowBudget(steps: $maxSteps, visits: $maxNodeVisits, '
      '${maxDuration.inSeconds}s)';
}

/// Executes workflow graphs.
///
/// Stateless and safe to share: everything about a run lives in the run.
///
/// ```dart
/// final engine = WorkflowEngine();
/// final result = await engine.run(graph, input: {'ticket': ticket});
///
/// if (result.status == WorkflowStatus.suspended) {
///   await store.save(result.snapshot!.toJson());   // survives the app closing
/// }
/// ```
final class WorkflowEngine {
  /// Creates an engine.
  ///
  /// [validateWrites] checks each node's output against its declared
  /// `writes` schemas. On by default: a node that promises a `List` and writes
  /// a `String` should fail where it happened, not wherever the value is later
  /// read.
  const WorkflowEngine({
    this.budget = WorkflowBudget.standard,
    this.validateWrites = true,
    this.requireSerialisableState = false,
  });

  /// Default bounds for a run.
  final WorkflowBudget budget;

  /// Whether node writes are checked against their declared schemas.
  final bool validateWrites;

  /// Whether state is checked for JSON-encodability after every node.
  ///
  /// Off by default because it costs an encode per step. Turn it on for a
  /// workflow that can suspend: the alternative is discovering an unencodable
  /// value at suspension time, with no clue which node put it there.
  final bool requireSerialisableState;

  /// Runs [graph] to completion, suspension or failure.
  ///
  /// Never throws for a node failure — the result carries `status: failed` and
  /// the trail of what ran before it. Cancellation propagates.
  Future<WorkflowResult> run(
    WorkflowGraph graph, {
    Map<String, Object?> input = const <String, Object?>{},
    AgenticContext? context,
    WorkflowBudget? budget,
    String? runId,
  }) async {
    // Checked at the boundary, so a caller that omits a required value learns
    // which one now rather than through a missing-key failure partway in.
    graph.validateInput(input);
    return _execute(
      graph: graph,
      state: WorkflowState(input),
      startNodeId: graph.startNodeId,
      context: context,
      budget: budget ?? this.budget,
      runId: runId,
      startedAt: null,
      initialVisits: const <String, int>{},
      initialStep: 0,
      resumeValue: null,
    );
  }

  /// Resumes a suspended run from [snapshot].
  ///
  /// [resumeValue] is what the waiting party decided; it is validated against
  /// the suspension's schema before the node sees it, so a malformed decision
  /// is rejected at the boundary.
  ///
  /// Throws a [ValidationException] when [snapshot] belongs to a different
  /// graph. Resuming into a graph that has changed shape is how a run walks
  /// into a node that no longer exists, and silently doing so would be worse
  /// than refusing.
  Future<WorkflowResult> resume(
    WorkflowGraph graph,
    WorkflowSnapshot snapshot, {
    Object? resumeValue,
    AgenticContext? context,
    WorkflowBudget? budget,
  }) async {
    if (snapshot.graphId != graph.id) {
      throw ValidationException(
        'This snapshot belongs to the workflow `${snapshot.graphId}`, not '
        '`${graph.id}`.',
        violations: <String>[
          'graphId: expected ${graph.id}, got ${snapshot.graphId}',
        ],
      );
    }
    if (!graph.nodes.containsKey(snapshot.nodeId)) {
      throw ValidationException(
        'The snapshot resumes at `${snapshot.nodeId}`, which no longer exists '
        'in `${graph.id}`. The graph changed while the run was suspended.',
        violations: <String>['nodeId: ${snapshot.nodeId} is not in the graph'],
      );
    }

    final schema = snapshot.suspension.resumeSchema;
    if (schema != null) {
      schema
          .validate(schema.coerce(resumeValue))
          .throwIfInvalid(subject: 'The value resuming `${snapshot.nodeId}`');
    }

    return _execute(
      graph: graph,
      state: snapshot.state,
      startNodeId: snapshot.nodeId,
      context: context,
      budget: budget ?? this.budget,
      runId: snapshot.runId,
      startedAt: snapshot.startedAt,
      initialVisits: snapshot.visits,
      initialStep: snapshot.step,
      resumeValue: schema == null ? resumeValue : schema.coerce(resumeValue),
    );
  }

  // ---------------------------------------------------------------------------
  // The walk
  // ---------------------------------------------------------------------------

  Future<WorkflowResult> _execute({
    required WorkflowGraph graph,
    required WorkflowState state,
    required String startNodeId,
    required AgenticContext? context,
    required WorkflowBudget budget,
    required String? runId,
    required DateTime? startedAt,
    required Map<String, int> initialVisits,
    required int initialStep,
    required Object? resumeValue,
  }) async {
    final root = context ?? AgenticContext.root();
    final scope = root.child('workflow.${graph.id}');
    final id = runId ?? scope.ids.prefixed('wf');
    final began = startedAt ?? scope.clock.now();
    final visits = Map<String, int>.of(initialVisits);
    final executions = <NodeExecution>[];

    var current = state;
    var nodeId = startNodeId;
    var step = initialStep;
    var pendingResume = resumeValue;

    final span = scope.tracer.startSpan(
      'workflow.${graph.id}',
      parent: scope.traceContext,
      attributes: <String, Object?>{
        'workflow.id': graph.id,
        'workflow.run_id': id,
        'workflow.nodes': graph.nodes.length,
        if (initialStep > 0) 'workflow.resumed': true,
      },
    );

    scope.publish(
      WorkflowStarted(
        id: scope.ids.prefixed('evt'),
        timestamp: began,
        graphId: graph.id,
        workflowRunId: id,
        nodeCount: graph.nodes.length,
        isResumed: initialStep > 0,
        runId: scope.runId,
        source: 'workflow:${graph.id}',
      ),
    );

    WorkflowResult finish(
      WorkflowStatus status, {
      WorkflowSnapshot? snapshot,
      AgenticException? error,
    }) {
      final result = WorkflowResult(
        graphId: graph.id,
        runId: id,
        status: status,
        state: current,
        executions: executions,
        snapshot: snapshot,
        error: error,
        duration: scope.clock.now().difference(began),
      );
      span
        ..setAttributes(<String, Object?>{
          'workflow.status': status.name,
          'workflow.steps': executions.length,
        })
        ..setStatus(
          status.isComplete ? SpanStatus.ok : SpanStatus.error,
          status.isComplete ? null : status.name,
        )
        ..end();
      scope.publish(
        WorkflowCompleted(
          id: scope.ids.prefixed('evt'),
          timestamp: scope.clock.now(),
          graphId: graph.id,
          workflowRunId: id,
          status: status,
          steps: executions.length,
          duration: result.duration,
          runId: scope.runId,
          source: 'workflow:${graph.id}',
        ),
      );
      return result;
    }

    try {
      while (true) {
        scope.throwIfCancelled();

        if (executions.length + initialStep >= budget.maxSteps) {
          return finish(WorkflowStatus.budgetExhausted);
        }
        if (scope.clock.now().difference(began) >= budget.maxDuration) {
          return finish(WorkflowStatus.budgetExhausted);
        }

        final visit = visits[nodeId] ?? 0;
        if (visit >= budget.maxNodeVisits) {
          // Naming the node is the point: a bare step count tells an author
          // that something looped, not what.
          return finish(
            WorkflowStatus.budgetExhausted,
            error: InvalidStateException(
              '`$nodeId` has run ${budget.maxNodeVisits} times, which is the '
              'per-node limit. The graph is looping without converging.',
              currentState: 'looping',
              expectedState: 'progressing',
              details: <String, Object?>{'nodeId': nodeId},
            ),
          );
        }

        final node = graph.node(nodeId);
        final stepStarted = scope.clock.now();
        visits[nodeId] = visit + 1;

        scope.publish(
          WorkflowNodeStarted(
            id: scope.ids.prefixed('evt'),
            timestamp: stepStarted,
            graphId: graph.id,
            workflowRunId: id,
            nodeId: node.id,
            nodeType: node.type,
            step: step,
            runId: scope.runId,
            source: 'workflow:${graph.id}',
          ),
        );

        final NodeOutcome outcome;
        try {
          outcome = await node.execute(
            NodeContext(
              state: current,
              context: scope.child('node.${node.id}'),
              runId: id,
              visit: visit,
              resumeValue: pendingResume,
            ),
          );
        } on CancelledException {
          rethrow;
        } on AgenticException catch (error, stackTrace) {
          error.annotateAll(<String, Object?>{
            'workflow.graph': graph.id,
            'workflow.node': node.id,
            'workflow.step': step,
          });
          executions.add(
            NodeExecution(
              nodeId: node.id,
              nodeType: node.type,
              step: step,
              duration: scope.clock.now().difference(stepStarted),
              outcome: 'failed',
              error: error,
            ),
          );
          span.recordError(error, stackTrace);
          scope.logger.error(
            'Workflow node failed',
            fields: <String, Object?>{
              'workflow': graph.id,
              'node': node.id,
              'code': error.code,
            },
            error: error,
            stackTrace: stackTrace,
          );
          return finish(WorkflowStatus.failed, error: error);
        }

        // The resume value belongs to exactly one node execution.
        pendingResume = null;

        if (validateWrites) {
          final violation = _checkWrites(node, outcome.writes);
          if (violation != null) {
            executions.add(
              NodeExecution(
                nodeId: node.id,
                nodeType: node.type,
                step: step,
                duration: scope.clock.now().difference(stepStarted),
                outcome: 'invalid-write',
                error: violation,
              ),
            );
            return finish(WorkflowStatus.failed, error: violation);
          }
        }

        current = current.write(outcome.writes);
        if (requireSerialisableState) current.assertSerialisable();

        executions.add(
          NodeExecution(
            nodeId: node.id,
            nodeType: node.type,
            step: step,
            duration: scope.clock.now().difference(stepStarted),
            outcome: outcome.toString(),
            writes: outcome.writes,
          ),
        );
        scope.publish(
          WorkflowNodeCompleted(
            id: scope.ids.prefixed('evt'),
            timestamp: scope.clock.now(),
            graphId: graph.id,
            workflowRunId: id,
            nodeId: node.id,
            nodeType: node.type,
            step: step,
            duration: scope.clock.now().difference(stepStarted),
            writes: outcome.writes.keys.toList(),
            runId: scope.runId,
            source: 'workflow:${graph.id}',
          ),
        );
        step++;

        if (outcome.suspension case final suspension?) {
          // The state is serialised here whether or not the engine was asked to
          // check every step, because this is the moment it must survive.
          current.assertSerialisable();
          final snapshot = WorkflowSnapshot(
            graphId: graph.id,
            runId: id,
            nodeId: node.id,
            state: current,
            suspension: suspension,
            startedAt: began,
            suspendedAt: scope.clock.now(),
            step: step,
            // The suspending node's visit is rolled back by one so that
            // resuming re-enters it at the same iteration it paused on.
            visits: <String, int>{...visits, node.id: visit},
          );
          scope.publish(
            WorkflowSuspended(
              id: scope.ids.prefixed('evt'),
              timestamp: scope.clock.now(),
              graphId: graph.id,
              workflowRunId: id,
              nodeId: node.id,
              kind: suspension.kind,
              message: suspension.message,
              runId: scope.runId,
              source: 'workflow:${graph.id}',
            ),
          );
          return finish(WorkflowStatus.suspended, snapshot: snapshot);
        }

        if (outcome.terminates) return finish(WorkflowStatus.completed);

        final next = _nextNode(graph, node, outcome);
        if (next.error case final failure?) {
          return finish(WorkflowStatus.failed, error: failure);
        }
        if (next.nodeId case final target?) {
          nodeId = target;
        } else {
          // Running out of outgoing edges is how a linear graph ends. A
          // *branch* with no matching edge is a gap, and `_nextNode` reports
          // that as a failure rather than letting it look like an ending.
          return finish(WorkflowStatus.completed);
        }
      }
    } on CancelledException {
      span.end();
      scope.publish(
        WorkflowCompleted(
          id: scope.ids.prefixed('evt'),
          timestamp: scope.clock.now(),
          graphId: graph.id,
          workflowRunId: id,
          status: WorkflowStatus.cancelled,
          steps: executions.length,
          duration: scope.clock.now().difference(began),
          runId: scope.runId,
          source: 'workflow:${graph.id}',
        ),
      );
      rethrow;
    }
  }

  /// Chooses the next node, or reports why there is none.
  static ({String? nodeId, AgenticException? error}) _nextNode(
    WorkflowGraph graph,
    WorkflowNode node,
    NodeOutcome outcome,
  ) {
    if (outcome.goTo case final target?) {
      if (!graph.nodes.containsKey(target)) {
        return (
          nodeId: null,
          error: NotFoundException(
            '`${node.id}` jumped to `$target`, which is not a node in '
            '`${graph.id}`.',
            resourceType: 'workflow node',
            identifier: target,
          ),
        );
      }
      return (nodeId: target, error: null);
    }

    final edge = graph.edgeFor(node.id, label: outcome.label);
    if (edge != null) return (nodeId: edge.to, error: null);

    if (outcome.label != null) {
      // Falling through here would take a path nobody chose.
      final available = graph
          .edgesFrom(node.id)
          .map((edge) => edge.label ?? '(default)')
          .toList();
      return (
        nodeId: null,
        error: InvalidStateException(
          '`${node.id}` branched to `${outcome.label}`, but no outgoing edge '
          'carries that label. '
          '${available.isEmpty ? 'It has no outgoing edges.' : 'It has: '
                    '${available.map((l) => '`$l`').join(', ')}.'}',
          currentState: 'branch ${outcome.label}',
          expectedState: 'a matching edge',
          details: <String, Object?>{'nodeId': node.id},
        ),
      );
    }

    return (nodeId: null, error: null);
  }

  /// Checks a node's writes against what it declared.
  static AgenticException? _checkWrites(
    WorkflowNode node,
    Map<String, Object?> writes,
  ) {
    for (final entry in node.writes.entries) {
      if (!writes.containsKey(entry.key)) continue;
      final result = entry.value.validate(writes[entry.key]);
      if (result.isValid) continue;
      return ValidationException(
        '`${node.id}` wrote a value at `${entry.key}` that does not match the '
        'shape it declared.',
        violations: result.violations.map((v) => v.toString()).toList(),
        details: <String, Object?>{'nodeId': node.id, 'key': entry.key},
      );
    }
    return null;
  }

  @override
  String toString() => 'WorkflowEngine($budget)';
}
