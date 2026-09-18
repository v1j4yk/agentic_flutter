---
name: agentic-workflow-human-approval-and-resume
description: >-
  Use when a Dart or Flutter workflow built with agentic_workflow must pause for
  a person to approve a step, or must survive the process ending and resume
  later. Covers HumanApprovalNode, WorkflowStatus.suspended, WorkflowSnapshot,
  WorkflowSnapshotStore, SqliteWorkflowSnapshotStore, WorkflowEngine.resume and
  the JSON-serialisable state rule. For approving a single tool call inside an
  agent loop, use agentic-tools-approval-and-untrusted-content instead.
license: MIT
metadata:
  package: agentic_workflow
  min-version: 0.2.0
---

# Human approval and resumable workflows

## The model

A workflow run either finishes or **suspends**. A suspended run is a JSON
snapshot: save it, let the process die, load it, and resume — possibly on
another device, keeping the same `runId`.

```dart
final result = await engine.run(graph, input: {'ticket': ticket});

switch (result.status) {
  case WorkflowStatus.suspended:
    await store.save(result.snapshot!);          // snapshot is non-null here
    await notifyApprover(result.suspension!);    // kind, message, payload, resumeSchema
  case WorkflowStatus.completed:
    print(result.output<String>('reply'));
  case WorkflowStatus.failed:
  case WorkflowStatus.budgetExhausted:
  case WorkflowStatus.cancelled:
    result.ensureComplete();                     // throws with the reason
}
```

## Asking a person

```dart
final builder = WorkflowBuilder('refunds')
  ..add(StartNode(id: 'start'))
  ..add(ToolNode(id: 'lookup', toolName: 'lookup_order', /* … */))
  ..add(HumanApprovalNode(
    id: 'approve',
    message: 'Approve this refund?',
    summarise: (ctx) => 'Refund ${ctx.state.require<num>('amount')} '
        'to ${ctx.state.require<String>('customer')}?',
    decisionKey: 'approved',        // where the boolean answer is written
    reads: {'amount', 'customer'},  // declared so validation can check the flow
  ))
  ..add(ToolNode(id: 'refund', toolName: 'issue_refund', /* … */))
  ..add(EndNode(id: 'done'));

builder
  ..startAt('start')
  ..chain([/* start */])
  ..edge('start', 'lookup')
  ..edge('lookup', 'approve')
  ..branch('approve', {'true': refundNode, 'false': declineNode});

final graph = builder.build();   // validates here, or throws
```

## Resuming

```dart
final snapshot = await store.load(runId);
if (snapshot == null) return;                 // already finished, or pruned

final result = await engine.resume(
  graph,                                      // the same graph, same shape
  snapshot,
  resumeValue: true,                          // the person's answer
);
```

`resumeValue` is validated against `suspension.resumeSchema` when the node
declares one.

## Persisting snapshots on a device

```dart
final db = await AgenticDatabase.open('${dir.path}/agentic.db');
final store = db.snapshotStore(name: 'refunds');   // survives app restarts

await store.save(result.snapshot!);
for (final pending in await store.list(graphId: 'refunds')) { /* inbox UI */ }
```

`InMemoryWorkflowSnapshotStore` is the same interface for tests.

## Rules that matter

1. **State must be JSON-encodable.** That constraint is what makes snapshots
   portable. Convert domain objects to maps before writing them into state; use
   `WorkflowEngine(requireSerialisableState: true)` (or
   `state.assertSerialisable()`) to fail fast in development rather than at
   suspension time.
2. **Resuming into a changed graph is refused**, not silently continued. If you
   ship a new graph shape, change the graph `id` (or version it,
   `refunds_v3`) and let in-flight runs finish on the old one.
3. **The `runId` is preserved** across suspend and resume, so traces and logs
   join up.
4. **Validation happens at `build()`.** A node reading a key nothing writes on
   *every* path into it is an error before the first model call — key
   availability is computed as an intersection over all incoming paths.
5. **A node that jumps must declare `jumpTargets`**, or its target looks
   unreachable to the validator.
6. **Budgets still apply** across resume: pass a fresh `WorkflowBudget` to
   `resume` if the original is exhausted by design.

## Testing it

```dart
test('refund waits for a person and then pays', () async {
  final first = await engine.run(graph, input: {'orderId': '42'});
  expect(first.status, WorkflowStatus.suspended);
  expect(first.suspension!.kind, 'human_approval');

  final resumed = await engine.resume(graph, first.snapshot!, resumeValue: true);
  expect(resumed.status, WorkflowStatus.completed);
  expect(resumed.output<bool>('refunded'), isTrue);
});
```

Round-trip the snapshot through `jsonEncode` / `WorkflowSnapshot.fromJson` in at
least one test: that is what catches a non-serialisable value before a user does.

## Common mistakes

- Reading `result.snapshot` without checking `status == suspended`.
- Writing a `DateTime`, an enum or a domain object into state — encode it first.
- Editing the graph and resuming old snapshots into it.
- Keeping snapshots only in memory, which defeats the point on mobile: the OS
  kills the app while the approver is elsewhere.
- Forgetting to prune completed runs — `store.delete(runId)` after a successful
  resume.

## See also

- `agentic-workflow-build-graph` — nodes, edges, branching and validation
- `agentic-workflow-fix-validation-errors` — what `GraphViolation` messages mean
- `agentic-sqlite-persist-everything` — the database behind the snapshot store
