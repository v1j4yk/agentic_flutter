/// Where suspended runs wait.
///
/// A workflow that stops for a person's approval is only useful if it is still
/// there when they approve — which on a phone may be tomorrow, after the OS has
/// long since reclaimed the process. `WorkflowSnapshot` makes a run
/// serialisable; this is where it is kept, and how the runs still waiting are
/// found again.
library;

import 'dart:convert';

import 'package:agentic_core/agentic_core.dart';
import 'package:agentic_workflow/src/engine/workflow_run.dart';

/// Keeps [WorkflowSnapshot]s until their runs resume.
///
/// ```dart
/// final result = await engine.run(graph, input: input);
/// if (result.status == WorkflowStatus.suspended) {
///   await snapshots.save(result.snapshot!);
/// }
///
/// // Later — perhaps a different launch of the app:
/// final snapshot = await snapshots.load(runId);
/// final resumed = await engine.resume(graph, snapshot!, resumeValue: true);
/// if (resumed.status != WorkflowStatus.suspended) {
///   await snapshots.delete(runId);
/// }
/// ```
abstract interface class WorkflowSnapshotStore implements Disposable {
  /// Saves [snapshot] under its run id, replacing any earlier one.
  ///
  /// A run that suspends twice — two approvals in sequence — overwrites its
  /// own entry, so the store holds where a run *is*, not where it has been.
  Future<void> save(WorkflowSnapshot snapshot);

  /// The snapshot for [runId], or `null`.
  Future<WorkflowSnapshot?> load(String runId);

  /// Deletes the snapshot for [runId]. Returns whether one existed.
  ///
  /// Call it once a resumed run finishes. A snapshot left behind is a run the
  /// app will offer to resume again.
  Future<bool> delete(String runId);

  /// Every stored snapshot, longest waiting first, optionally for one graph.
  ///
  /// Longest waiting first because that is the order a list of pending
  /// approvals should be worked through.
  Future<List<WorkflowSnapshot>> list({String? graphId});
}

/// A [WorkflowSnapshotStore] that lives as long as the process.
///
/// Snapshots are kept as JSON rather than as objects, so state that does not
/// serialise fails in a test against this store instead of on a user's phone
/// against a durable one.
final class InMemoryWorkflowSnapshotStore implements WorkflowSnapshotStore {
  /// Creates an empty store.
  InMemoryWorkflowSnapshotStore();

  final Map<String, String> _snapshots = <String, String>{};

  @override
  Future<void> save(WorkflowSnapshot snapshot) async {
    _snapshots[snapshot.runId] = jsonEncode(snapshot.toJson());
  }

  @override
  Future<WorkflowSnapshot?> load(String runId) async {
    final json = _snapshots[runId];
    return json == null ? null : _decode(json);
  }

  @override
  Future<bool> delete(String runId) async => _snapshots.remove(runId) != null;

  @override
  Future<List<WorkflowSnapshot>> list({String? graphId}) async {
    final snapshots =
        <WorkflowSnapshot>[
            for (final json in _snapshots.values) _decode(json),
          ].where((s) => graphId == null || s.graphId == graphId).toList()
          ..sort((a, b) => a.suspendedAt.compareTo(b.suspendedAt));
    return List<WorkflowSnapshot>.unmodifiable(snapshots);
  }

  @override
  Future<void> dispose() async => _snapshots.clear();

  static WorkflowSnapshot _decode(String json) => WorkflowSnapshot.fromJson(
    (jsonDecode(json) as Map).cast<String, Object?>(),
  );
}
