/// The graph, and the checks that run before it does.
///
/// # Validation before execution is the whole point
///
/// A workflow that fails three minutes in because node seven reads a key nobody
/// writes has wasted three minutes, some money, and — if it had side effects —
/// left the world half-changed. Every one of those failures is knowable from
/// the graph alone.
///
/// So [WorkflowGraph] validates on construction and refuses to exist in an
/// invalid state. Not a `validate()` a caller may forget to call: a graph you
/// are holding is a graph that has passed.
library;

import 'package:agentic_core/agentic_core.dart';
import 'package:agentic_workflow/src/graph/workflow_node.dart';
import 'package:meta/meta.dart';

/// A directed connection between two nodes.
@immutable
final class WorkflowEdge {
  /// Creates an edge.
  const WorkflowEdge(this.from, this.to, {this.label});

  /// Source node identifier.
  final String from;

  /// Target node identifier.
  final String to;

  /// The branch this edge represents.
  ///
  /// A node returning `NodeOutcome.branch('yes')` follows the edge labelled
  /// `yes`. An unlabelled edge is the default path.
  final String? label;

  /// Serialises the edge.
  JsonMap toJson() =>
      pruneNulls(<String, Object?>{'from': from, 'to': to, 'label': label});

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is WorkflowEdge &&
          from == other.from &&
          to == other.to &&
          label == other.label;

  @override
  int get hashCode => Object.hash(from, to, label);

  @override
  String toString() =>
      'WorkflowEdge($from -> $to${label == null ? '' : ' [$label]'})';
}

/// One problem found in a graph.
@immutable
final class GraphViolation {
  /// Creates a violation.
  const GraphViolation({
    required this.rule,
    required this.message,
    this.nodeId,
  });

  /// Which check failed, such as `unreachable` or `missing-input`.
  final String rule;

  /// What is wrong and how to fix it.
  final String message;

  /// The node involved, when one is.
  final String? nodeId;

  @override
  String toString() => nodeId == null ? message : '[$nodeId] $message';
}

/// A validated workflow.
///
/// ```dart
/// final graph = WorkflowGraph(
///   id: 'triage',
///   nodes: [startNode, classifyNode, escalateNode, replyNode, endNode],
///   edges: [
///     WorkflowEdge('start', 'classify'),
///     WorkflowEdge('classify', 'escalate', label: 'urgent'),
///     WorkflowEdge('classify', 'reply', label: 'routine'),
///     WorkflowEdge('escalate', 'end'),
///     WorkflowEdge('reply', 'end'),
///   ],
/// );
/// ```
@immutable
final class WorkflowGraph {
  /// Creates and validates a graph.
  ///
  /// Throws a [ValidationException] listing every problem found, not just the
  /// first — a graph with four mistakes should take one fix cycle, not four.
  ///
  /// Set [allowCycles] for a graph that loops back on purpose. Leaving it off
  /// turns an accidental cycle into a build-time error, which is the far more
  /// common case.
  factory WorkflowGraph({
    required String id,
    required List<WorkflowNode> nodes,
    required List<WorkflowEdge> edges,
    Map<String, JsonSchema> inputs = const <String, JsonSchema>{},
    String? startNodeId,
    bool allowCycles = false,
    String? description,
  }) {
    final byId = <String, WorkflowNode>{};
    final duplicates = <String>[];
    for (final node in nodes) {
      if (byId.containsKey(node.id)) duplicates.add(node.id);
      byId[node.id] = node;
    }

    final start = startNodeId ?? _inferStart(nodes, edges);
    final violations = _validate(
      nodes: byId,
      edges: edges,
      duplicates: duplicates,
      startNodeId: start,
      allowCycles: allowCycles,
      inputs: inputs.keys.toSet(),
    );

    if (violations.isNotEmpty) {
      throw ValidationException(
        'The workflow `$id` has ${violations.length} problem(s) and cannot '
        'run.',
        violations: violations.map((v) => v.toString()).toList(),
        details: <String, Object?>{'graph': id},
      );
    }

    return WorkflowGraph._(
      id: id,
      nodes: byId,
      edges: edges,
      inputs: inputs,
      startNodeId: start!,
      allowCycles: allowCycles,
      description: description,
    );
  }

  WorkflowGraph._({
    required this.id,
    required Map<String, WorkflowNode> nodes,
    required List<WorkflowEdge> edges,
    required Map<String, JsonSchema> inputs,
    required this.startNodeId,
    required this.allowCycles,
    this.description,
  }) : _nodes = Map<String, WorkflowNode>.unmodifiable(nodes),
       edges = List<WorkflowEdge>.unmodifiable(edges),
       inputs = Map<String, JsonSchema>.unmodifiable(inputs);

  /// Identifier for this workflow.
  final String id;

  /// What the workflow does.
  final String? description;

  /// Where execution begins.
  final String startNodeId;

  /// Whether cycles are intentional.
  final bool allowCycles;

  /// Every edge, in declaration order.
  final List<WorkflowEdge> edges;

  /// State keys the caller supplies when starting a run, with their shapes.
  ///
  /// A graph's parameters. Declaring them is what lets a node read a value the
  /// caller provided without validation reporting it as missing — and it means
  /// the run's input is checked at the boundary rather than by whichever node
  /// happens to read it first.
  final Map<String, JsonSchema> inputs;

  final Map<String, WorkflowNode> _nodes;

  /// Every node, keyed by identifier.
  Map<String, WorkflowNode> get nodes => _nodes;

  /// The node with [nodeId].
  ///
  /// Throws a [NotFoundException] naming the closest match, because a mistyped
  /// jump target is the easiest mistake to make and the hardest to spot.
  WorkflowNode node(String nodeId) {
    final found = _nodes[nodeId];
    if (found != null) return found;
    throw NotFoundException(
      'The workflow `$id` has no node `$nodeId`. '
      'Nodes: ${_nodes.keys.map((k) => '`$k`').join(', ')}.',
      resourceType: 'workflow node',
      identifier: nodeId,
    );
  }

  /// Edges leaving [nodeId].
  List<WorkflowEdge> edgesFrom(String nodeId) =>
      edges.where((edge) => edge.from == nodeId).toList(growable: false);

  /// The edge to follow from [nodeId] for [label].
  ///
  /// Returns `null` when nothing matches, which the engine reports as a failure
  /// rather than treating as "stop here" — a branch with no matching edge is a
  /// gap in the graph, and falling through silently takes a path nobody chose.
  WorkflowEdge? edgeFor(String nodeId, {String? label}) {
    final candidates = edgesFrom(nodeId);
    if (label != null) {
      for (final edge in candidates) {
        if (edge.label == label) return edge;
      }
      return null;
    }
    for (final edge in candidates) {
      if (edge.label == null) return edge;
    }
    // A single labelled edge is unambiguous, so following it is safe and saves
    // authors from labelling a chain that never branches.
    return candidates.length == 1 ? candidates.first : null;
  }

  /// Validates a run's input against [inputs].
  ///
  /// Called by the engine before the first node runs, so a caller that omits a
  /// required value learns which one immediately rather than through a
  /// `state has no value for` failure partway in.
  void validateInput(Map<String, Object?> input) {
    if (inputs.isEmpty) return;
    final violations = <String>[];
    for (final entry in inputs.entries) {
      if (!input.containsKey(entry.key)) {
        violations.add('${entry.key}: required input is missing');
        continue;
      }
      final result = entry.value.validate(input[entry.key]);
      for (final violation in result.violations) {
        violations.add('${entry.key}${violation.path}: ${violation.message}');
      }
    }
    if (violations.isEmpty) return;
    throw ValidationException(
      'The input to the workflow `$id` is not valid.',
      violations: violations,
      details: <String, Object?>{'graph': id},
    );
  }

  /// Serialises the graph, for diagrams and storage.
  JsonMap toJson() => pruneNulls(<String, Object?>{
    'id': id,
    'description': description,
    'startNodeId': startNodeId,
    'inputs': inputs.isEmpty
        ? null
        : <String, Object?>{
            for (final entry in inputs.entries) entry.key: entry.value.toJson(),
          },
    'allowCycles': allowCycles ? true : null,
    'nodes': _nodes.values.map((node) => node.toJson()).toList(),
    'edges': edges.map((edge) => edge.toJson()).toList(),
  });

  /// Renders the graph as a Mermaid flowchart.
  ///
  /// Included because a workflow nobody can see is a workflow nobody trusts,
  /// and a diagram generated from the real graph cannot drift from it the way a
  /// hand-drawn one does.
  String toMermaid() {
    final buffer = StringBuffer('flowchart TD');
    for (final node in _nodes.values) {
      final label = '${node.id}<br/><i>${node.type}</i>';
      buffer.write('\n  ${_safe(node.id)}["$label"]');
    }
    for (final edge in edges) {
      buffer.write(
        edge.label == null
            ? '\n  ${_safe(edge.from)} --> ${_safe(edge.to)}'
            : '\n  ${_safe(edge.from)} -->|${edge.label}| ${_safe(edge.to)}',
      );
    }
    return buffer.toString();
  }

  static String _safe(String id) =>
      id.replaceAll(RegExp(r'[^A-Za-z0-9_]'), '_');

  /// Picks the start node when one was not named.
  ///
  /// The node with no incoming edges. Ambiguity is left to validation rather
  /// than guessed at, because guessing wrong silently runs the wrong workflow.
  static String? _inferStart(
    List<WorkflowNode> nodes,
    List<WorkflowEdge> edges,
  ) {
    final targets = edges.map((edge) => edge.to).toSet();
    final roots = nodes
        .where((node) => !targets.contains(node.id))
        .map((node) => node.id)
        .toList();
    return roots.length == 1 ? roots.first : null;
  }

  // ---------------------------------------------------------------------------
  // Validation
  // ---------------------------------------------------------------------------

  static List<GraphViolation> _validate({
    required Map<String, WorkflowNode> nodes,
    required List<WorkflowEdge> edges,
    required List<String> duplicates,
    required String? startNodeId,
    required bool allowCycles,
    required Set<String> inputs,
  }) {
    final violations = <GraphViolation>[];

    for (final id in duplicates.toSet()) {
      violations.add(
        GraphViolation(
          rule: 'duplicate-id',
          nodeId: id,
          message:
              'Two nodes share the identifier `$id`. Identifiers address nodes '
              'in edges and jumps, so they must be unique.',
        ),
      );
    }

    if (nodes.isEmpty) {
      violations.add(
        const GraphViolation(
          rule: 'empty',
          message: 'A workflow needs at least one node.',
        ),
      );
      return violations;
    }

    if (startNodeId == null) {
      final targets = edges.map((edge) => edge.to).toSet();
      final roots = nodes.keys.where((id) => !targets.contains(id)).toList();
      violations.add(
        GraphViolation(
          rule: 'no-start',
          message: roots.isEmpty
              ? 'Every node has an incoming edge, so there is nowhere to '
                    'start. Name one with `startNodeId`.'
              : 'Several nodes have no incoming edge '
                    '(${roots.map((r) => '`$r`').join(', ')}), so the start is '
                    'ambiguous. Name one with `startNodeId`.',
        ),
      );
    } else if (!nodes.containsKey(startNodeId)) {
      violations.add(
        GraphViolation(
          rule: 'unknown-start',
          nodeId: startNodeId,
          message: 'The start node `$startNodeId` is not in the graph.',
        ),
      );
    }

    for (final edge in edges) {
      if (!nodes.containsKey(edge.from)) {
        violations.add(
          GraphViolation(
            rule: 'unknown-edge-source',
            nodeId: edge.from,
            message: 'An edge starts at `${edge.from}`, which is not a node.',
          ),
        );
      }
      if (!nodes.containsKey(edge.to)) {
        violations.add(
          GraphViolation(
            rule: 'unknown-edge-target',
            nodeId: edge.to,
            message: 'An edge ends at `${edge.to}`, which is not a node.',
          ),
        );
      }
    }

    for (final node in nodes.values) {
      for (final target in node.jumpTargets) {
        if (nodes.containsKey(target)) continue;
        violations.add(
          GraphViolation(
            rule: 'unknown-jump-target',
            nodeId: node.id,
            message:
                '`${node.id}` declares a jump to `$target`, which is not a '
                'node.',
          ),
        );
      }
    }

    // Ambiguous routing: two unlabelled edges leaving one node means the engine
    // would have to pick, and picking arbitrarily is worse than refusing.
    for (final id in nodes.keys) {
      final unlabelled = edges
          .where((edge) => edge.from == id && edge.label == null)
          .length;
      if (unlabelled > 1) {
        violations.add(
          GraphViolation(
            rule: 'ambiguous-route',
            nodeId: id,
            message:
                '`$id` has $unlabelled unlabelled outgoing edges. Label them, '
                'or use a parallel node if both should run.',
          ),
        );
      }
      final labels = edges
          .where((edge) => edge.from == id && edge.label != null)
          .map((edge) => edge.label!)
          .toList();
      final duplicateLabels = labels
          .where((label) => labels.where((l) => l == label).length > 1)
          .toSet();
      for (final label in duplicateLabels) {
        violations.add(
          GraphViolation(
            rule: 'duplicate-label',
            nodeId: id,
            message: '`$id` has two outgoing edges labelled `$label`.',
          ),
        );
      }
    }

    if (startNodeId == null || !nodes.containsKey(startNodeId)) {
      return violations;
    }

    final reachable = _reachableFrom(startNodeId, edges, nodes);
    for (final id in nodes.keys) {
      if (!reachable.contains(id)) {
        violations.add(
          GraphViolation(
            rule: 'unreachable',
            nodeId: id,
            message:
                '`$id` cannot be reached from `$startNodeId`. Connect it, or '
                'remove it.',
          ),
        );
      }
    }

    if (!allowCycles) {
      final cycle = _findCycle(startNodeId, edges, nodes);
      if (cycle != null) {
        violations.add(
          GraphViolation(
            rule: 'cycle',
            message:
                'The graph loops: ${cycle.join(' -> ')}. Pass '
                '`allowCycles: true` if that is intended, and bound it with the '
                "engine's step budget.",
          ),
        );
      }
    }

    violations.addAll(_validateDataFlow(nodes, edges, startNodeId, inputs));
    return violations;
  }

  /// Checks that every key a node reads is written somewhere upstream.
  ///
  /// Walks forward from the start accumulating the keys guaranteed to exist.
  /// A key counts as available at a node only when **every** path into it
  /// writes the key — an intersection rather than a union — because a value
  /// that exists on one branch and not another is exactly the bug this is
  /// looking for.
  static List<GraphViolation> _validateDataFlow(
    Map<String, WorkflowNode> nodes,
    List<WorkflowEdge> edges,
    String startNodeId,
    Set<String> inputs,
  ) {
    final violations = <GraphViolation>[];
    // The caller's declared inputs exist before any node runs, so they seed the
    // set the same way the start node's own writes do.
    final availableAt = <String, Set<String>>{
      startNodeId: <String>{...inputs, ...nodes[startNodeId]!.writes.keys},
    };

    // Breadth-first with a visit cap: a cyclic graph would otherwise loop, and
    // in a cycle the analysis converges after one pass round anyway.
    final queue = <String>[startNodeId];
    final visits = <String, int>{};

    while (queue.isNotEmpty) {
      final currentId = queue.removeAt(0);
      final visitCount = (visits[currentId] ?? 0) + 1;
      visits[currentId] = visitCount;
      if (visitCount > nodes.length) continue;

      final available = availableAt[currentId] ?? <String>{};
      for (final edge in edges.where((edge) => edge.from == currentId)) {
        final target = nodes[edge.to];
        if (target == null) continue;

        final produced = <String>{
          ...available,
          ...target.writes.keys,
          for (final child in target.children) ...child.writes.keys,
        };
        final existing = availableAt[edge.to];
        availableAt[edge.to] =
            existing == null
                  ? produced
                  // Intersection: only keys present on *every* path in are
                  // guaranteed. Union would let a branch-only key look safe.
                  : existing.intersection(produced)
              ..addAll(target.writes.keys);
        queue.add(edge.to);
      }
    }

    for (final node in nodes.values) {
      final available = availableAt[node.id] ?? <String>{};
      // The node's own writes are available to itself; a node that reads what
      // it writes is doing an update, which is legitimate.
      final visible = <String>{...available, ...node.writes.keys};
      for (final key in node.reads) {
        if (visible.contains(key)) continue;
        violations.add(
          GraphViolation(
            rule: 'missing-input',
            nodeId: node.id,
            message:
                '`${node.id}` reads `$key`, but no node guaranteed to run '
                'before it writes that key. Either it is never written, or it '
                'is written on only some of the paths that reach here.',
          ),
        );
      }
    }

    // A parallel node whose children write the same key is a race: the winner
    // depends on completion order, which is not something a workflow should
    // leave to chance.
    for (final node in nodes.values) {
      if (node.children.length < 2) continue;
      final seen = <String, String>{};
      for (final child in node.children) {
        for (final key in child.writes.keys) {
          final earlier = seen[key];
          if (earlier != null) {
            violations.add(
              GraphViolation(
                rule: 'concurrent-write',
                nodeId: node.id,
                message:
                    'Inside `${node.id}`, both `$earlier` and `${child.id}` '
                    'write `$key`. Concurrent branches must write distinct '
                    'keys, or the result depends on which finishes first.',
              ),
            );
          }
          seen[key] = child.id;
        }
      }
    }

    return violations;
  }

  static Set<String> _reachableFrom(
    String startNodeId,
    List<WorkflowEdge> edges,
    Map<String, WorkflowNode> nodes,
  ) {
    final reached = <String>{startNodeId};
    final queue = <String>[startNodeId];
    while (queue.isNotEmpty) {
      final current = queue.removeLast();
      for (final edge in edges.where((edge) => edge.from == current)) {
        if (reached.add(edge.to)) queue.add(edge.to);
      }
      // A jump is not an edge, so a declared target has to be followed
      // explicitly or a loop's body would look unreachable.
      for (final target in nodes[current]?.jumpTargets ?? const <String>{}) {
        if (nodes.containsKey(target) && reached.add(target)) {
          queue.add(target);
        }
      }
    }
    // Children are reached through their parent, not by an edge.
    for (final id in reached.toList()) {
      for (final child in nodes[id]?.children ?? const <WorkflowNode>[]) {
        reached.add(child.id);
      }
    }
    return reached;
  }

  /// Returns one cycle as a path, or `null` when the graph is acyclic.
  static List<String>? _findCycle(
    String startNodeId,
    List<WorkflowEdge> edges,
    Map<String, WorkflowNode> nodes,
  ) {
    final visiting = <String>{};
    final done = <String>{};
    final path = <String>[];

    List<String>? walk(String id) {
      if (visiting.contains(id)) {
        final start = path.indexOf(id);
        return <String>[...path.sublist(start < 0 ? 0 : start), id];
      }
      if (done.contains(id)) return null;

      visiting.add(id);
      path.add(id);
      for (final edge in edges.where((edge) => edge.from == id)) {
        if (!nodes.containsKey(edge.to)) continue;
        final found = walk(edge.to);
        if (found != null) return found;
      }
      visiting.remove(id);
      done.add(id);
      path.removeLast();
      return null;
    }

    return walk(startNodeId);
  }

  @override
  String toString() =>
      'WorkflowGraph($id, ${_nodes.length} nodes, ${edges.length} edges)';
}

/// Assembles a graph without repeating node identifiers.
///
/// The literal form is fine for a diagram-shaped workflow and tedious for a
/// chain, where every edge restates two identifiers that are obvious from the
/// order.
///
/// ```dart
/// final graph = (WorkflowBuilder('triage')
///       ..chain([startNode, classifyNode])
///       ..branch('classify', {'urgent': escalateNode, 'routine': replyNode})
///       ..chain([escalateNode, endNode])
///       ..edge('reply', 'end'))
///     .build();
/// ```
final class WorkflowBuilder {
  /// Creates a builder for a graph called [id].
  WorkflowBuilder(this.id, {this.description, this.allowCycles = false});

  /// Identifier of the graph being built.
  final String id;

  /// What the workflow does.
  final String? description;

  /// Whether cycles are intentional.
  final bool allowCycles;

  final Map<String, WorkflowNode> _nodes = <String, WorkflowNode>{};
  final List<WorkflowEdge> _edges = <WorkflowEdge>[];
  String? _startNodeId;

  /// Adds [node].
  ///
  /// Adding the same node twice is a no-op, so a node can appear in several
  /// `chain` calls without the caller tracking what has been registered.
  void add(WorkflowNode node) => _nodes[node.id] = node;

  /// Adds every node in [nodes].
  void addAll(Iterable<WorkflowNode> nodes) => nodes.forEach(add);

  /// Names the start node explicitly.
  ///
  /// Only needed when several nodes have no incoming edge; otherwise the single
  /// root is inferred.
  // ignore: use_setters_to_change_properties
  void startAt(String nodeId) => _startNodeId = nodeId;

  /// Adds an edge.
  void edge(String from, String to, {String? label}) =>
      _edges.add(WorkflowEdge(from, to, label: label));

  /// Adds [nodes] and connects them in order.
  void chain(List<WorkflowNode> nodes) {
    addAll(nodes);
    for (var i = 0; i < nodes.length - 1; i++) {
      edge(nodes[i].id, nodes[i + 1].id);
    }
  }

  /// Adds labelled edges from [from] to each entry of [targets].
  void branch(String from, Map<String, WorkflowNode> targets) {
    addAll(targets.values);
    for (final entry in targets.entries) {
      edge(from, entry.value.id, label: entry.key);
    }
  }

  /// Builds and validates the graph.
  WorkflowGraph build() => WorkflowGraph(
    id: id,
    description: description,
    nodes: _nodes.values.toList(),
    edges: _edges,
    startNodeId: _startNodeId,
    allowCycles: allowCycles,
  );
}
