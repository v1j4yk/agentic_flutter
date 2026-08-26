// Nodes here derive their declared `writes` from their own constructor
// parameters, so each must invoke `super(...)` explicitly. Dart forbids
// combining that with super parameters, which is what this lint asks for.
// ignore_for_file: use_super_parameters

/// The nodes a workflow is assembled from.
///
/// Each is small on purpose. A node that does two things cannot be reused for
/// either, and cannot be validated for either — the whole value of declaring
/// `reads` and `writes` disappears the moment a node's behaviour depends on a
/// flag in its own configuration.
library;

import 'dart:async';

import 'package:agentic_agents/agentic_agents.dart';
import 'package:agentic_core/agentic_core.dart';
import 'package:agentic_llm/agentic_llm.dart';
import 'package:agentic_tools/agentic_tools.dart';
import 'package:agentic_workflow/src/graph/workflow_node.dart';

/// Where a run begins.
///
/// Does nothing. It exists so a graph has an unambiguous entry point that reads
/// as one in a diagram, and so the start is a node rather than a convention.
final class StartNode extends WorkflowNode {
  /// Creates a start node.
  const StartNode({super.id = 'start', super.description});

  @override
  String get type => 'start';

  @override
  Future<NodeOutcome> execute(NodeContext context) async =>
      const NodeOutcome.next();
}

/// Where a run ends.
///
/// Terminates the run regardless of any outgoing edges, so a graph with several
/// ends behaves the way its diagram reads.
final class EndNode extends WorkflowNode {
  /// Creates an end node.
  const EndNode({super.id = 'end', super.description});

  @override
  String get type => 'end';

  @override
  Future<NodeOutcome> execute(NodeContext context) async =>
      const NodeOutcome.finish();
}

/// Runs a caller-supplied function.
///
/// The escape hatch, and the node most real workflows use most. A workflow that
/// cannot call ordinary code for the ordinary parts forces everything through
/// the model, which is slower, less reliable and far more expensive.
final class CustomNode extends WorkflowNode {
  /// Creates a node backed by [run].
  const CustomNode({
    required super.id,
    required this.run,
    super.reads,
    super.writes,
    super.description,
    this.typeName = 'custom',
    this.jumpTargets = const <String>{},
  });

  /// The function to run.
  final FutureOr<NodeOutcome> Function(NodeContext context) run;

  /// The type reported in traces and diagrams.
  final String typeName;

  @override
  final Set<String> jumpTargets;

  @override
  String get type => typeName;

  @override
  Future<NodeOutcome> execute(NodeContext context) async => run(context);
}

/// Computes new state from old.
///
/// The common case of [CustomNode]: read some keys, write some others, no
/// control flow. Separated because a transform reads far better in a diagram
/// than a general-purpose node does.
final class TransformNode extends WorkflowNode {
  /// Creates a transform.
  const TransformNode({
    required super.id,
    required this.transform,
    super.reads,
    super.writes,
    super.description,
  });

  /// Returns the state updates to apply.
  final FutureOr<Map<String, Object?>> Function(NodeContext context) transform;

  @override
  String get type => 'transform';

  @override
  Future<NodeOutcome> execute(NodeContext context) async =>
      NodeOutcome.next(writes: await transform(context));
}

/// Chooses between two paths.
///
/// Emits `true` or `false` as its branch label, so the graph carries edges with
/// those labels. Making the labels fixed rather than caller-chosen keeps every
/// condition in a codebase reading the same way.
final class ConditionNode extends WorkflowNode {
  /// Creates a condition.
  const ConditionNode({
    required super.id,
    required this.predicate,
    super.reads,
    super.description,
  });

  /// Decides which way to go.
  final FutureOr<bool> Function(NodeContext context) predicate;

  @override
  String get type => 'condition';

  @override
  Future<NodeOutcome> execute(NodeContext context) async =>
      NodeOutcome.branch(await predicate(context) ? 'true' : 'false');
}

/// Chooses between several paths.
///
/// The returned label must match an outgoing edge; the engine fails loudly when
/// it does not, rather than falling through to a default nobody chose.
final class SwitchNode extends WorkflowNode {
  /// Creates a switch.
  const SwitchNode({
    required super.id,
    required this.selector,
    super.reads,
    super.description,
  });

  /// Returns the label of the edge to follow.
  final FutureOr<String> Function(NodeContext context) selector;

  @override
  String get type => 'switch';

  @override
  Future<NodeOutcome> execute(NodeContext context) async =>
      NodeOutcome.branch(await selector(context));
}

/// Asks a model.
final class LlmNode extends WorkflowNode {
  /// Creates a model node.
  ///
  /// [buildRequest] turns state into a request, and [outputKey] is where the
  /// answer lands. Declaring the output key here rather than letting the
  /// caller write arbitrary state is what lets validation see the data flow.
  LlmNode({
    required super.id,
    required this.model,
    required this.buildRequest,
    this.outputKey = 'answer',
    this.usageKey,
    Set<String> reads = const <String>{},
    JsonSchema? outputSchema,
    super.description,
  }) : super(
         reads: reads,
         writes: <String, JsonSchema>{
           outputKey: outputSchema ?? JsonSchema.string(),
           ?usageKey: JsonSchema.anyObject(),
         },
       );

  /// The model to call.
  final ChatModel model;

  /// Builds the request from state.
  final FutureOr<ChatRequest> Function(NodeContext context) buildRequest;

  /// State key the answer is written to.
  final String outputKey;

  /// Optional state key for token usage.
  ///
  /// Worth setting on a long workflow: without it, the tokens a run spent are
  /// visible only in events, and a caller holding the result cannot report the
  /// cost of the thing it just ran.
  final String? usageKey;

  @override
  String get type => 'llm';

  @override
  Future<NodeOutcome> execute(NodeContext context) async {
    final response = await model.generate(
      await buildRequest(context),
      context: context.context,
    );
    // A truncated answer is a corrupt one, and letting it flow downstream turns
    // a clear failure here into a confusing one three nodes later.
    response.ensureComplete();

    return NodeOutcome.next(
      writes: <String, Object?>{
        outputKey: response.text,
        ?usageKey: response.usage.toJson(),
      },
    );
  }
}

/// Asks a model for a structured value.
///
/// Separate from [LlmNode] because the output is a *record*, not prose, and a
/// workflow that has to parse JSON out of a text key by hand has lost the
/// benefit of declaring schemas at all.
final class StructuredLlmNode extends WorkflowNode {
  /// Creates a structured model node.
  StructuredLlmNode({
    required super.id,
    required this.model,
    required this.buildRequest,
    required this.schema,
    this.outputKey = 'result',
    this.schemaName = 'result',
    Set<String> reads = const <String>{},
    super.description,
  }) : super(reads: reads, writes: <String, JsonSchema>{outputKey: schema});

  /// The model to call.
  final ChatModel model;

  /// Builds the request from state.
  final FutureOr<ChatRequest> Function(NodeContext context) buildRequest;

  /// The shape the answer must take.
  final JsonSchema schema;

  /// State key the decoded object is written to.
  final String outputKey;

  /// Name given to the schema in the provider request.
  final String schemaName;

  @override
  String get type => 'llm.structured';

  @override
  Future<NodeOutcome> execute(NodeContext context) async {
    final decoded = await model.generateStructured<JsonMap>(
      await buildRequest(context),
      name: schemaName,
      schema: schema,
      fromJson: (json) => json,
      context: context.context,
    );
    return NodeOutcome.next(writes: <String, Object?>{outputKey: decoded});
  }
}

/// Runs an agent.
///
/// The node that makes a workflow agentic rather than merely scripted: fixed
/// steps where the shape is known, an agent where it is not.
final class AgentNode extends WorkflowNode {
  /// Creates an agent node.
  AgentNode({
    required super.id,
    required this.agent,
    required this.buildInput,
    this.outputKey = 'answer',
    this.failOnIncomplete = true,
    Set<String> reads = const <String>{},
    super.description,
  }) : super(
         reads: reads,
         writes: <String, JsonSchema>{outputKey: JsonSchema.string()},
       );

  /// The agent to run.
  final Agent agent;

  /// Builds the agent's input from state.
  final FutureOr<AgentInput> Function(NodeContext context) buildInput;

  /// State key the agent's answer is written to.
  final String outputKey;

  /// Whether a budget-exhausted or failed agent run fails the workflow.
  ///
  /// On by default. An agent that ran out of budget produced a best effort, and
  /// letting that flow into the next node as though it were a finished answer
  /// is how a workflow produces confident nonsense.
  final bool failOnIncomplete;

  @override
  String get type => 'agent';

  @override
  Future<NodeOutcome> execute(NodeContext context) async {
    final result = await agent.run(
      await buildInput(context),
      context: context.context,
    );
    if (failOnIncomplete) result.ensureSuccess();
    return NodeOutcome.next(writes: <String, Object?>{outputKey: result.text});
  }
}

/// Runs one tool.
final class ToolNode extends WorkflowNode {
  /// Creates a tool node.
  ToolNode({
    required super.id,
    required this.tool,
    required this.buildArguments,
    this.outputKey = 'toolResult',
    this.failOnToolError = true,
    Set<String> reads = const <String>{},
    super.description,
  }) : super(
         reads: reads,
         writes: <String, JsonSchema>{outputKey: JsonSchema.string()},
       );

  /// The tool to invoke.
  final Tool tool;

  /// Builds the arguments from state.
  final FutureOr<Map<String, Object?>> Function(NodeContext context)
  buildArguments;

  /// State key the tool's output is written to.
  final String outputKey;

  /// Whether a failing tool fails the workflow.
  ///
  /// On by default, which is the opposite of the agent case and deliberately
  /// so: an agent *reads* a tool failure and works around it, while a workflow
  /// has no such judgement and would carry the error text forward as data.
  final bool failOnToolError;

  @override
  String get type => 'tool';

  @override
  Future<NodeOutcome> execute(NodeContext context) async {
    final registry = ToolRegistry()..register(tool);
    final executor = ToolExecutor(tools: registry.all);
    final result = await executor.execute(
      ToolCallPart(
        id: '${context.runId}:$id',
        name: tool.spec.name,
        arguments: await buildArguments(context),
      ),
      context: context.context,
    );
    await registry.dispose();

    if (result.isError && failOnToolError) {
      throw ToolExecutionException(
        'The tool `${tool.spec.name}` failed in node `$id`: ${result.content}',
        toolName: tool.spec.name,
      );
    }
    return NodeOutcome.next(
      writes: <String, Object?>{outputKey: result.content},
    );
  }
}

/// Runs several nodes concurrently and merges their writes.
///
/// Children must write **distinct** keys; the graph refuses to build otherwise,
/// because the winner of a concurrent write depends on completion order and
/// that is not something a workflow should leave to chance.
final class ParallelNode extends WorkflowNode {
  /// Creates a parallel node.
  ParallelNode({
    required super.id,
    required List<WorkflowNode> branches,
    this.maxConcurrency = 4,
    this.failFast = true,
    super.description,
  }) : assert(branches.isNotEmpty, 'a parallel node needs branches'),
       _branches = List<WorkflowNode>.unmodifiable(branches),
       super(
         reads: <String>{for (final branch in branches) ...branch.reads},
         writes: <String, JsonSchema>{
           for (final branch in branches) ...branch.writes,
         },
       );

  final List<WorkflowNode> _branches;

  /// How many branches run at once.
  final int maxConcurrency;

  /// Whether the first failing branch fails the node.
  ///
  /// On by default. With it off, the surviving branches' writes are applied and
  /// the failures are dropped — which means a downstream node reads a state
  /// that looks complete but is not.
  final bool failFast;

  @override
  List<WorkflowNode> get children => _branches;

  @override
  String get type => 'parallel';

  @override
  Future<NodeOutcome> execute(NodeContext context) async {
    final writes = <String, Object?>{};
    final failures = <AgenticException>[];

    var next = 0;
    Future<void> worker() async {
      while (true) {
        if (next >= _branches.length) return;
        final branch = _branches[next++];
        context.throwIfCancelled();
        try {
          final outcome = await branch.execute(context);
          if (outcome.isSuspended) {
            // Suspending inside a branch would need per-branch snapshots and a
            // way to resume one arm of a fan-out. Refusing is honest; the
            // alternative is a snapshot that silently loses the other branches.
            throw InvalidStateException(
              'The branch `${branch.id}` tried to suspend inside the parallel '
              'node `$id`. Move the suspending step outside the parallel '
              'block.',
              currentState: 'suspended branch',
              expectedState: 'a branch that runs to completion',
            );
          }
          writes.addAll(outcome.writes);
        } on AgenticException catch (error) {
          failures.add(error);
          if (failFast) return;
        }
      }
    }

    final workerCount = _branches.length < maxConcurrency
        ? _branches.length
        : maxConcurrency;
    await Future.wait(
      List<Future<void>>.generate(workerCount, (_) => worker()),
    );

    if (failures.isNotEmpty && failFast) throw failures.first;
    return NodeOutcome.next(writes: writes);
  }
}

/// Runs one node once per item of a collection.
///
/// The fan-out a workflow actually needs: "summarise each of these documents"
/// is one node and a list, not twenty hand-drawn branches.
final class MapNode extends WorkflowNode {
  /// Creates a map node.
  ///
  /// [itemsKey] holds the collection, [itemKey] is where each element is placed
  /// for [body] to read, and [outputKey] collects what [body] wrote at
  /// [resultKey].
  MapNode({
    required super.id,
    required this.itemsKey,
    required this.body,
    required this.resultKey,
    this.itemKey = 'item',
    this.outputKey = 'results',
    this.maxConcurrency = 4,
    super.description,
  }) : super(
         reads: <String>{itemsKey},
         writes: <String, JsonSchema>{
           outputKey: JsonSchema.array(items: JsonSchema.any()),
         },
       );

  /// State key holding the collection to iterate.
  final String itemsKey;

  /// The node run once per element.
  final WorkflowNode body;

  /// The key [body] writes its per-item output to.
  final String resultKey;

  /// State key each element is exposed at.
  final String itemKey;

  /// State key the collected results are written to.
  final String outputKey;

  /// How many elements are processed at once.
  ///
  /// Bounded because the body usually calls a model, and an unbounded fan-out
  /// over two hundred documents is the fastest route to a rate limit.
  final int maxConcurrency;

  @override
  List<WorkflowNode> get children => <WorkflowNode>[body];

  @override
  String get type => 'map';

  @override
  Future<NodeOutcome> execute(NodeContext context) async {
    final items =
        context.state.get<List<Object?>>(itemsKey) ?? const <Object?>[];
    if (items.isEmpty) {
      return NodeOutcome.next(
        writes: <String, Object?>{outputKey: const <Object?>[]},
      );
    }

    final results = List<Object?>.filled(items.length, null);
    var next = 0;

    Future<void> worker() async {
      while (true) {
        if (next >= items.length) return;
        final index = next++;
        context.throwIfCancelled();
        // Each iteration gets its own state view, so the body sees one item
        // rather than racing with its siblings over a shared key.
        final outcome = await body.execute(
          NodeContext(
            state: context.state.write(<String, Object?>{
              itemKey: items[index],
              '$itemKey.index': index,
            }),
            context: context.context,
            runId: context.runId,
            visit: index,
          ),
        );
        results[index] = outcome.writes[resultKey];
      }
    }

    final workerCount = items.length < maxConcurrency
        ? items.length
        : maxConcurrency;
    await Future.wait(
      List<Future<void>>.generate(workerCount, (_) => worker()),
    );

    return NodeOutcome.next(writes: <String, Object?>{outputKey: results});
  }
}

/// Repeats a target node until a condition holds.
///
/// Implemented as a jump, so the loop is visible in the graph rather than
/// hidden inside a node. The graph must be built with `allowCycles: true`, and
/// the engine's per-node visit budget bounds it whatever the condition does.
final class LoopNode extends WorkflowNode {
  /// Creates a loop.
  ///
  /// While [shouldContinue] holds, execution jumps to [bodyNodeId]; otherwise
  /// it follows the outgoing edge.
  const LoopNode({
    required super.id,
    required this.bodyNodeId,
    required this.shouldContinue,
    this.maxIterations = 10,
    super.reads,
    super.description,
  });

  /// Where to jump while looping.
  final String bodyNodeId;

  /// Whether to go round again.
  final FutureOr<bool> Function(NodeContext context) shouldContinue;

  /// A ceiling on iterations, independent of the engine's budget.
  ///
  /// Local, so one runaway loop reports itself rather than exhausting the whole
  /// run's step budget and blaming whatever node happened to be next.
  final int maxIterations;

  @override
  Set<String> get jumpTargets => <String>{bodyNodeId};

  @override
  String get type => 'loop';

  @override
  Future<NodeOutcome> execute(NodeContext context) async {
    if (context.visit >= maxIterations) {
      return const NodeOutcome.next();
    }
    return await shouldContinue(context)
        ? NodeOutcome.goTo(bodyNodeId)
        : const NodeOutcome.next();
  }
}

/// Waits.
final class DelayNode extends WorkflowNode {
  /// Creates a delay.
  const DelayNode({
    required super.id,
    required this.duration,
    super.description,
  });

  /// How long to wait.
  final Duration duration;

  @override
  String get type => 'delay';

  @override
  Future<NodeOutcome> execute(NodeContext context) async {
    // Through the injected clock, so a workflow with a two-hour delay is
    // testable in microseconds.
    await context.context.clock.delay(duration);
    return const NodeOutcome.next();
  }
}

/// Pauses until a person decides.
///
/// # The node that justifies suspension
///
/// Everything else in this engine could be a function call. This cannot: the
/// wait is unbounded, it outlives the process, and the answer arrives from
/// outside. The run is serialised, the app closes, someone approves it the next
/// morning, and it continues.
///
/// ```dart
/// final approval = HumanApprovalNode(
///   id: 'approve',
///   message: 'Send this email?',
///   summarise: (context) => context.require<String>('draft'),
/// );
/// // -> suspended; persist result.snapshot
/// // later:
/// await engine.resume(graph, snapshot, resumeValue: {'approved': true});
/// ```
final class HumanApprovalNode extends WorkflowNode {
  /// Creates an approval node.
  HumanApprovalNode({
    required super.id,
    required this.message,
    this.summarise,
    this.decisionKey = 'approved',
    Set<String> reads = const <String>{},
    super.description,
  }) : super(
         reads: reads,
         writes: <String, JsonSchema>{decisionKey: JsonSchema.boolean()},
       );

  /// What the person is being asked.
  final String message;

  /// Renders what they are approving.
  final FutureOr<String> Function(NodeContext context)? summarise;

  /// State key the decision is written to.
  final String decisionKey;

  /// The shape a resume value must take.
  ///
  /// Validated by the engine before this node sees it, so a malformed decision
  /// is rejected at the boundary rather than silently read as a refusal.
  static final JsonSchema decisionSchema = JsonSchema.object(
    properties: <String, JsonSchema>{
      'approved': JsonSchema.boolean(description: 'Whether it was approved.'),
      'comment': JsonSchema.string(description: 'Optional note.'),
    },
    required: const <String>{'approved'},
  );

  @override
  String get type => 'human_approval';

  @override
  Future<NodeOutcome> execute(NodeContext context) async {
    if (context.resumeValue case final decision?) {
      final json = decision is Map
          ? decision.cast<String, Object?>()
          : <String, Object?>{'approved': decision == true};
      final approved = json['approved'] == true;
      return NodeOutcome.branch(
        approved ? 'approved' : 'rejected',
        writes: <String, Object?>{
          decisionKey: approved,
          '$decisionKey.comment': ?json['comment'],
        },
      );
    }

    return NodeOutcome.suspend(
      NodeSuspension(
        kind: 'human_approval',
        message: message,
        payload: <String, Object?>{
          'nodeId': id,
          if (summarise case final render?) 'summary': await render(context),
        },
        resumeSchema: decisionSchema,
      ),
    );
  }
}

/// Pauses until an external event arrives.
///
/// The general form of [HumanApprovalNode]: a webhook, a payment confirmation,
/// a file finishing conversion. The workflow does not care what it is waiting
/// for, only that the answer comes from outside.
final class WaitForEventNode extends WorkflowNode {
  /// Creates a waiting node.
  WaitForEventNode({
    required super.id,
    required this.eventKind,
    required this.message,
    this.outputKey = 'event',
    this.payloadSchema,
    Set<String> reads = const <String>{},
    super.description,
  }) : super(
         reads: reads,
         writes: <String, JsonSchema>{
           outputKey: payloadSchema ?? JsonSchema.any(),
         },
       );

  /// What is being waited for, dispatched on by the host application.
  final String eventKind;

  /// A human-readable description of the wait.
  final String message;

  /// State key the event payload is written to.
  final String outputKey;

  /// The shape the payload must take.
  final JsonSchema? payloadSchema;

  @override
  String get type => 'wait';

  @override
  Future<NodeOutcome> execute(NodeContext context) async {
    if (context.resumeValue case final payload?) {
      return NodeOutcome.next(writes: <String, Object?>{outputKey: payload});
    }
    return NodeOutcome.suspend(
      NodeSuspension(
        kind: eventKind,
        message: message,
        payload: <String, Object?>{'nodeId': id},
        resumeSchema: payloadSchema,
      ),
    );
  }
}
