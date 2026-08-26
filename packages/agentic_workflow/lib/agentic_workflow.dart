/// A graph workflow engine for the agentic framework.
///
/// For work whose shape is known in advance, where an agent loop is the wrong
/// tool: a directed graph of typed nodes, validated before it runs and able to
/// pause for a human and resume days later on another device.
///
/// ```dart
/// import 'package:agentic_workflow/agentic_workflow.dart';
///
/// final graph = (WorkflowBuilder('triage')
///       ..chain([StartNode(), classify])
///       ..branch('classify', {'urgent': escalate, 'routine': reply})
///       ..edge('escalate', 'end')
///       ..edge('reply', 'end')
///       ..add(EndNode()))
///     .build();   // throws here if the graph is wrong
///
/// final result = await WorkflowEngine().run(graph, input: {'ticket': ticket});
/// ```
///
/// Two properties drive the design. **Validation before execution**: a node
/// reading a key nothing upstream writes is a build-time error, not a failure
/// three minutes into a run. **Resumability**: a suspended run is a JSON
/// snapshot, so it survives the app being killed.
library;

// --- Engine ------------------------------------------------------------------
export 'src/engine/workflow_engine.dart' show WorkflowBudget, WorkflowEngine;
export 'src/engine/workflow_run.dart'
    show NodeExecution, WorkflowResult, WorkflowSnapshot, WorkflowStatus;
// --- Events ------------------------------------------------------------------
export 'src/events/workflow_events.dart'
    show
        WorkflowCompleted,
        WorkflowEvent,
        WorkflowNodeCompleted,
        WorkflowNodeStarted,
        WorkflowStarted,
        WorkflowSuspended;
// --- Graph -------------------------------------------------------------------
export 'src/graph/workflow_graph.dart'
    show GraphViolation, WorkflowBuilder, WorkflowEdge, WorkflowGraph;
export 'src/graph/workflow_node.dart'
    show NodeContext, NodeOutcome, NodeSuspension, WorkflowNode;
// --- Nodes -------------------------------------------------------------------
export 'src/nodes/builtin_nodes.dart'
    show
        AgentNode,
        ConditionNode,
        CustomNode,
        DelayNode,
        EndNode,
        HumanApprovalNode,
        LlmNode,
        LoopNode,
        MapNode,
        ParallelNode,
        StartNode,
        StructuredLlmNode,
        SwitchNode,
        ToolNode,
        TransformNode,
        WaitForEventNode;
// --- State -------------------------------------------------------------------
export 'src/state/workflow_state.dart' show WorkflowState;
