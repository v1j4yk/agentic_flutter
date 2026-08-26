/// The node contract.
///
/// A node does one thing and says what it touches. Declaring [WorkflowNode.reads]
/// and [WorkflowNode.writes] is what lets a graph be checked before it runs, and
/// it is the only obligation the contract imposes beyond executing.
library;

import 'package:agentic_core/agentic_core.dart';
import 'package:agentic_workflow/src/state/workflow_state.dart';
import 'package:meta/meta.dart';

/// What a node was given when it ran.
@immutable
final class NodeContext {
  /// Creates a node context.
  const NodeContext({
    required this.state,
    required this.context,
    required this.runId,
    required this.visit,
    this.resumeValue,
  });

  /// The workflow state as it stands.
  final WorkflowState state;

  /// Run context: logger, events, tracer, clock, cancellation.
  final AgenticContext context;

  /// Identifier of this workflow run.
  final String runId;

  /// How many times this node has already run in this run.
  ///
  /// Zero on the first visit. A node inside a loop uses it to know which
  /// iteration it is on without keeping state of its own — which it must not,
  /// because a node instance is shared across concurrent runs.
  final int visit;

  /// The value supplied when resuming a suspended run.
  ///
  /// Only ever non-null on the visit immediately after a suspension, and only
  /// for the node that suspended.
  final Object? resumeValue;

  /// Reads a required value from state.
  T require<T>(String key) => state.require<T>(key);

  /// Reads a value from state, or [orElse].
  T getOr<T>(String key, T orElse) => state.getOr<T>(key, orElse);

  /// Whether the run has been cancelled or has passed its deadline.
  void throwIfCancelled() => context.throwIfCancelled();
}

/// A pause, waiting for something outside the workflow.
///
/// The whole point of suspension is that the waiting can outlive the process:
/// a run paused for approval is serialised, the app closes, and someone
/// approves it the next morning. So a suspension carries only data.
@immutable
final class NodeSuspension {
  /// Creates a suspension.
  NodeSuspension({
    required this.kind,
    required this.message,
    JsonMap payload = const <String, Object?>{},
    this.resumeSchema,
  }) : payload = Map<String, Object?>.unmodifiable(payload);

  /// What is being waited for, such as `human_approval`.
  ///
  /// The application dispatches on this to decide what interface to show.
  final String kind;

  /// A human-readable description of what is being asked.
  final String message;

  /// Data the waiting party needs — the draft being approved, the options.
  final JsonMap payload;

  /// The shape the resume value must take.
  ///
  /// Validated on resume, so a malformed decision is rejected at the boundary
  /// rather than reaching node code that assumed it was well formed.
  final JsonSchema? resumeSchema;

  /// Serialises the suspension.
  JsonMap toJson() => pruneNulls(<String, Object?>{
    'kind': kind,
    'message': message,
    'payload': payload.isEmpty ? null : payload,
    'resumeSchema': resumeSchema?.toJson(),
  });

  /// Restores a suspension from JSON.
  static NodeSuspension fromJson(JsonMap json) => NodeSuspension(
    kind: json.requireString('kind'),
    message: json.requireString('message'),
    payload: json.optionalObject('payload') ?? const <String, Object?>{},
    resumeSchema: json.optionalObject('resumeSchema') == null
        ? null
        : JsonSchema.fromJson(json.requireObject('resumeSchema')),
  );

  @override
  String toString() => 'NodeSuspension($kind: $message)';
}

/// What a node decided.
@immutable
final class NodeOutcome {
  const NodeOutcome._({
    this.writes = const <String, Object?>{},
    this.label,
    this.goTo,
    this.suspension,
    this.terminates = false,
  });

  /// Continues along the node's unlabelled outgoing edge.
  const NodeOutcome.next({Map<String, Object?> writes = const {}})
    : this._(writes: writes);

  /// Continues along the outgoing edge labelled [label].
  ///
  /// How a condition or a switch chooses. The engine fails loudly when no edge
  /// carries the label, because silently falling through is how a workflow
  /// takes a branch nobody intended.
  const NodeOutcome.branch(
    String label, {
    Map<String, Object?> writes = const {},
  }) : this._(writes: writes, label: label);

  /// Jumps to [nodeId], ignoring outgoing edges.
  ///
  /// The mechanism behind loops. Use it sparingly: a graph whose flow is mostly
  /// jumps cannot be read as a diagram, which was the point of a graph.
  const NodeOutcome.goTo(
    String nodeId, {
    Map<String, Object?> writes = const {},
  }) : this._(writes: writes, goTo: nodeId);

  /// Pauses the run until it is resumed.
  const NodeOutcome.suspend(
    NodeSuspension suspension, {
    Map<String, Object?> writes = const {},
  }) : this._(writes: writes, suspension: suspension);

  /// Ends the run successfully, whatever edges remain.
  const NodeOutcome.finish({Map<String, Object?> writes = const {}})
    : this._(writes: writes, terminates: true);

  /// State updates this node produced.
  final Map<String, Object?> writes;

  /// The outgoing edge label to follow, when branching.
  final String? label;

  /// An explicit jump target.
  final String? goTo;

  /// The pause requested, when suspending.
  final NodeSuspension? suspension;

  /// Whether this ends the run.
  final bool terminates;

  /// Whether the run should pause here.
  bool get isSuspended => suspension != null;

  @override
  String toString() {
    if (suspension != null) return 'NodeOutcome(suspend: ${suspension!.kind})';
    if (terminates) return 'NodeOutcome(finish)';
    if (goTo != null) return 'NodeOutcome(goTo: $goTo)';
    if (label != null) return 'NodeOutcome(branch: $label)';
    return 'NodeOutcome(next, ${writes.length} writes)';
  }
}

/// One step of a workflow.
///
/// `base` rather than `sealed`: the built-in nodes cover the common shapes, and
/// a workflow that cannot add a node for its own domain is a workflow engine
/// nobody can use. Extend this, or use `CustomNode` for a closure.
///
/// Implementations must:
///
/// * be **stateless**. A node instance is shared across concurrent runs and
///   across iterations of a loop; per-run data belongs in [WorkflowState] and
///   per-iteration data in [NodeContext.visit];
/// * declare [reads] and [writes] honestly, because validation believes them;
/// * honour cancellation in anything long-running;
/// * write only JSON-encodable values, so a run can be suspended.
@immutable
abstract base class WorkflowNode {
  /// Creates a node.
  const WorkflowNode({
    required this.id,
    this.reads = const <String>{},
    this.writes = const <String, JsonSchema>{},
    this.description,
  });

  /// Unique identifier within a graph.
  final String id;

  /// State keys this node needs before it can run.
  ///
  /// Validation checks that some node on every path into this one writes each
  /// of them. Under-declaring hides a real error until the run; over-declaring
  /// produces a false failure at build time, which is the cheaper mistake.
  final Set<String> reads;

  /// State keys this node produces, with the shape of each.
  ///
  /// The schema is used to validate what the node actually wrote, catching a
  /// node that promises a `List` and writes a `String` at the moment it does it
  /// rather than wherever the value is later read.
  final Map<String, JsonSchema> writes;

  /// What this node does, for diagrams and traces.
  final String? description;

  /// Stable type name, such as `llm` or `condition`.
  ///
  /// A getter rather than a field so subclasses supply it without threading it
  /// through every constructor. It appears in traces and serialised graphs, so
  /// treat it as public API.
  String get type;

  /// Nodes this one contains, for validation and tracing.
  ///
  /// Parallel and map nodes hold children; everything else holds none.
  List<WorkflowNode> get children => const <WorkflowNode>[];

  /// Nodes this one may jump to with `NodeOutcome.goTo`.
  ///
  /// Declared because reachability analysis follows *edges*, and a jump is not
  /// an edge. Without this, a loop that jumps backwards makes its target look
  /// unreachable and the graph refuses to build — so a node that jumps must say
  /// where, exactly as it must say what it reads.
  Set<String> get jumpTargets => const <String>{};

  /// Runs the node.
  Future<NodeOutcome> execute(NodeContext context);

  /// Describes the node for serialisation and diagrams.
  @mustCallSuper
  JsonMap toJson() => pruneNulls(<String, Object?>{
    'id': id,
    'type': type,
    'description': description,
    'reads': reads.isEmpty ? null : (reads.toList()..sort()),
    'writes': writes.isEmpty ? null : (writes.keys.toList()..sort()),
    'children': children.isEmpty
        ? null
        : children.map((child) => child.toJson()).toList(),
  });

  @override
  String toString() => '$runtimeType($id)';
}
