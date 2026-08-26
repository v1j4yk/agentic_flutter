// Demonstrates the workflow engine: validation before execution, branching,
// fan-out, a human approval that survives the app closing, and the diagram the
// graph draws of itself.
//
// Run it with:
//
//     dart run example/agentic_workflow_example.dart
//
// It runs offline against scripted models.
import 'dart:convert';

import 'package:agentic_core/agentic_core.dart';
import 'package:agentic_llm/agentic_llm.dart';
import 'package:agentic_llm/testing.dart';
import 'package:agentic_workflow/agentic_workflow.dart';

Future<void> main() async {
  // ---------------------------------------------------------------------------
  // 1. A graph is checked when it is built, not when it runs.
  // ---------------------------------------------------------------------------
  print('--- validation ---');
  try {
    WorkflowGraph(
      id: 'broken',
      nodes: <WorkflowNode>[
        const StartNode(),
        CustomNode(
          id: 'summarise',
          // Nothing upstream writes `document`.
          reads: const <String>{'document'},
          run: (_) async => const NodeOutcome.next(),
        ),
        const EndNode(),
      ],
      edges: const <WorkflowEdge>[
        WorkflowEdge('start', 'summarise'),
        WorkflowEdge('summarise', 'end'),
      ],
    );
  } on ValidationException catch (error) {
    for (final violation in error.violations) {
      print('  rejected: $violation');
    }
  }

  // ---------------------------------------------------------------------------
  // 2. A real graph: triage a ticket, fan out over its attachments, draft a
  //    reply, and ask a human before sending.
  // ---------------------------------------------------------------------------
  final classifier = FakeChatModel.text('urgent');
  final drafter = FakeChatModel.text(
    'Dear Ada, we are treating this as urgent and will respond within the hour.',
  );

  final graph = WorkflowGraph(
    id: 'ticket-triage',
    description: 'Classifies a support ticket, drafts a reply, asks to send.',
    inputs: <String, JsonSchema>{
      'ticket': JsonSchema.string(description: 'The ticket text'),
      'attachments': JsonSchema.array(items: JsonSchema.string()),
    },
    nodes: <WorkflowNode>[
      const StartNode(),

      LlmNode(
        id: 'classify',
        model: classifier,
        reads: const <String>{'ticket'},
        outputKey: 'severity',
        usageKey: 'classifyUsage',
        buildRequest: (context) => ChatRequest.prompt(
          'Classify this ticket as `urgent` or `routine`, one word only:\n'
          '${context.require<String>('ticket')}',
          temperature: 0,
        ),
      ),

      // Fan out over attachments. One node, however many there are.
      MapNode(
        id: 'scan',
        itemsKey: 'attachments',
        resultKey: 'note',
        outputKey: 'attachmentNotes',
        body: TransformNode(
          id: 'scanOne',
          reads: const <String>{'item'},
          writes: <String, JsonSchema>{'note': JsonSchema.string()},
          transform: (context) async => <String, Object?>{
            'note': 'scanned ${context.require<String>('item')}',
          },
        ),
      ),

      SwitchNode(
        id: 'route',
        reads: const <String>{'severity'},
        selector: (context) =>
            context.require<String>('severity').trim().toLowerCase(),
      ),

      LlmNode(
        id: 'draft',
        model: drafter,
        reads: const <String>{'ticket', 'severity'},
        outputKey: 'draft',
        buildRequest: (context) => ChatRequest.prompt(
          'Draft a reply to this ${context.require<String>('severity')} '
          'ticket:\n${context.require<String>('ticket')}',
        ),
      ),

      TransformNode(
        id: 'queue',
        writes: <String, JsonSchema>{'draft': JsonSchema.string()},
        transform: (_) async => <String, Object?>{
          'draft': 'Thanks — we have added this to the queue.',
        },
      ),

      HumanApprovalNode(
        id: 'approve',
        message: 'Send this reply?',
        reads: const <String>{'draft'},
        summarise: (context) => context.require<String>('draft'),
      ),

      TransformNode(
        id: 'send',
        reads: const <String>{'draft'},
        writes: <String, JsonSchema>{'outcome': JsonSchema.string()},
        transform: (_) async => <String, Object?>{'outcome': 'sent'},
      ),
      TransformNode(
        id: 'discard',
        writes: <String, JsonSchema>{'outcome': JsonSchema.string()},
        transform: (_) async => <String, Object?>{'outcome': 'discarded'},
      ),

      const EndNode(),
    ],
    edges: const <WorkflowEdge>[
      WorkflowEdge('start', 'classify'),
      WorkflowEdge('classify', 'scan'),
      WorkflowEdge('scan', 'route'),
      WorkflowEdge('route', 'draft', label: 'urgent'),
      WorkflowEdge('route', 'queue', label: 'routine'),
      WorkflowEdge('draft', 'approve'),
      WorkflowEdge('queue', 'approve'),
      WorkflowEdge('approve', 'send', label: 'approved'),
      WorkflowEdge('approve', 'discard', label: 'rejected'),
      WorkflowEdge('send', 'end'),
      WorkflowEdge('discard', 'end'),
    ],
  );

  // ---------------------------------------------------------------------------
  // 3. The graph draws itself, from the real thing rather than by hand.
  // ---------------------------------------------------------------------------
  print('\n--- diagram ---');
  print(graph.toMermaid().split('\n').take(6).join('\n'));
  print('  ... (${graph.nodes.length} nodes, ${graph.edges.length} edges)');

  // ---------------------------------------------------------------------------
  // 4. Run it. It suspends at the approval.
  // ---------------------------------------------------------------------------
  print('\n--- run ---');
  final events = BroadcastEventBus();
  events.on<WorkflowEvent>().listen((event) {
    final detail = switch (event) {
      WorkflowNodeCompleted(:final nodeId, :final nodeType, :final writes) =>
        '$nodeId ($nodeType)${writes.isEmpty ? '' : ' -> ${writes.join(', ')}'}',
      WorkflowSuspended(:final message) => 'paused: $message',
      WorkflowCompleted(:final status, :final steps) =>
        '${status.name} after $steps steps',
      _ => null,
    };
    if (detail != null) print('  $detail');
  });

  const engine = WorkflowEngine();
  final context = AgenticContext.root(events: events, runId: 'example');

  final suspended = await engine.run(
    graph,
    input: <String, Object?>{
      'ticket': 'The checkout page is down and customers cannot pay.',
      'attachments': <Object?>['screenshot.png', 'console.log'],
    },
    context: context,
  );

  print('status     : ${suspended.status.name}');
  print('severity   : ${suspended.output<String>('severity')}');
  print('attachments: ${suspended.output<List<Object?>>('attachmentNotes')}');
  print('waiting on : ${suspended.suspension!.message}');
  print('to approve : ${suspended.suspension!.payload['summary']}');

  // ---------------------------------------------------------------------------
  // 5. The pause outlives the process. Persist the snapshot, close the app,
  //    come back tomorrow, resume.
  // ---------------------------------------------------------------------------
  print('\n--- persist and resume ---');
  final stored = jsonEncode(suspended.snapshot!.toJson());
  print('snapshot   : ${stored.length} bytes of JSON');

  final restored = WorkflowSnapshot.fromJson(
    jsonDecode(stored) as Map<String, Object?>,
  );
  final finished = await engine.resume(
    graph,
    restored,
    resumeValue: <String, Object?>{'approved': true, 'comment': 'looks right'},
    context: context,
  );

  print('status     : ${finished.status.name}');
  print('outcome    : ${finished.output<String>('outcome')}');
  print('run id     : ${finished.runId} (same run, resumed)');
  print('steps      : ${finished.steps} after resuming');

  // ---------------------------------------------------------------------------
  // 6. A budget bounds a graph that loops.
  // ---------------------------------------------------------------------------
  print('\n--- budget ---');
  final looping = WorkflowGraph(
    id: 'never-converges',
    nodes: <WorkflowNode>[
      CustomNode(
        id: 'spin',
        jumpTargets: const <String>{'spin'},
        run: (_) async => const NodeOutcome.goTo('spin'),
      ),
    ],
    edges: const <WorkflowEdge>[],
    startNodeId: 'spin',
    allowCycles: true,
  );

  final bounded = await const WorkflowEngine(
    budget: WorkflowBudget(maxNodeVisits: 4),
  ).run(looping, context: context);

  print('status     : ${bounded.status.name}');
  print('reason     : ${bounded.error?.message}');

  await events.dispose();
}
