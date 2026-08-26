import 'dart:convert';

import 'package:agentic_agents/agentic_agents.dart';
import 'package:agentic_core/agentic_core.dart';
import 'package:agentic_core/testing.dart';
import 'package:agentic_llm/agentic_llm.dart';
import 'package:agentic_llm/testing.dart';
import 'package:agentic_tools/agentic_tools.dart';
import 'package:agentic_workflow/agentic_workflow.dart';
import 'package:test/test.dart';

/// A node that records that it ran and writes a marker.
CustomNode marker(
  String id, {
  List<String>? log,
  Set<String> reads = const <String>{},
  Map<String, JsonSchema> writes = const <String, JsonSchema>{},
  Map<String, Object?> outputs = const <String, Object?>{},
}) => CustomNode(
  id: id,
  reads: reads,
  writes: writes,
  run: (context) async {
    log?.add(id);
    return NodeOutcome.next(writes: outputs);
  },
);

AgenticContext testContext({EventBus? events, SpanExporter? exporter}) =>
    AgenticContext.root(
      runId: 'run-1',
      events: events,
      ids: SequentialIdGenerator(prefix: 'e'),
      tracer: exporter == null ? null : Tracer(exporter: exporter),
    );

void main() {
  group('WorkflowState', () {
    test('writes produce a new instance', () {
      final first = WorkflowState(<String, Object?>{'a': 1});
      final second = first.set('b', 2);

      expect(first.keys, <String>['a']);
      expect(second['b'], 2);
    });

    test('an empty write returns the same instance', () {
      final state = WorkflowState(<String, Object?>{'a': 1});

      expect(identical(state.write(const {}), state), isTrue);
    });

    test('require names the key and both types', () {
      final state = WorkflowState(<String, Object?>{'count': 'not a number'});

      expect(
        () => state.require<int>('count'),
        throwsA(
          isA<ValidationException>()
              .having((e) => e.message, 'message', contains('`count`'))
              .having((e) => e.message, 'message', contains('int')),
        ),
      );
      expect(
        () => state.require<int>('missing'),
        throwsA(
          isA<ValidationException>().having(
            (e) => e.message,
            'message',
            contains('no value for `missing`'),
          ),
        ),
      );
    });

    test('assertSerialisable names the offending key', () {
      // The failure would otherwise appear at suspension time with no clue
      // which node put the value there.
      final state = WorkflowState(<String, Object?>{'ok': 1, 'bad': Object()});

      expect(
        state.assertSerialisable,
        throwsA(
          isA<ValidationException>().having(
            (e) => e.message,
            'message',
            contains('`bad`'),
          ),
        ),
      );
    });

    test('round-trips through JSON', () {
      final state = WorkflowState(<String, Object?>{'a': 1, 'b': 'two'});

      expect(
        WorkflowState.fromJson(
          jsonDecode(jsonEncode(state.toJson())) as Map<String, Object?>,
        ),
        state,
      );
    });
  });

  group('graph validation', () {
    test('accepts a well-formed graph', () {
      expect(
        () => WorkflowGraph(
          id: 'ok',
          nodes: <WorkflowNode>[const StartNode(), const EndNode()],
          edges: const <WorkflowEdge>[WorkflowEdge('start', 'end')],
        ),
        returnsNormally,
      );
    });

    test('rejects duplicate node identifiers', () {
      expect(
        () => WorkflowGraph(
          id: 'dup',
          nodes: <WorkflowNode>[marker('a'), marker('a'), const EndNode()],
          edges: const <WorkflowEdge>[WorkflowEdge('a', 'end')],
        ),
        throwsA(
          isA<ValidationException>().having(
            (e) => e.violations.join(),
            'violations',
            contains('share the identifier'),
          ),
        ),
      );
    });

    test('rejects an edge to a node that does not exist', () {
      expect(
        () => WorkflowGraph(
          id: 'bad-edge',
          nodes: <WorkflowNode>[const StartNode()],
          edges: const <WorkflowEdge>[WorkflowEdge('start', 'nowhere')],
        ),
        throwsA(
          isA<ValidationException>().having(
            (e) => e.violations.join(),
            'violations',
            contains('`nowhere`, which is not a node'),
          ),
        ),
      );
    });

    test('rejects an unreachable node', () {
      expect(
        () => WorkflowGraph(
          id: 'orphan',
          nodes: <WorkflowNode>[
            const StartNode(),
            const EndNode(),
            marker('x'),
          ],
          edges: const <WorkflowEdge>[WorkflowEdge('start', 'end')],
          startNodeId: 'start',
        ),
        throwsA(
          isA<ValidationException>().having(
            (e) => e.violations.join(),
            'violations',
            contains('cannot be reached'),
          ),
        ),
      );
    });

    test('rejects two unlabelled edges from one node', () {
      // The engine would have to pick, and picking arbitrarily is worse than
      // refusing to build.
      expect(
        () => WorkflowGraph(
          id: 'ambiguous',
          nodes: <WorkflowNode>[const StartNode(), marker('a'), marker('b')],
          edges: const <WorkflowEdge>[
            WorkflowEdge('start', 'a'),
            WorkflowEdge('start', 'b'),
          ],
          startNodeId: 'start',
        ),
        throwsA(
          isA<ValidationException>().having(
            (e) => e.violations.join(),
            'violations',
            contains('unlabelled outgoing edges'),
          ),
        ),
      );
    });

    test('rejects an accidental cycle', () {
      expect(
        () => WorkflowGraph(
          id: 'loopy',
          nodes: <WorkflowNode>[const StartNode(), marker('a'), marker('b')],
          edges: const <WorkflowEdge>[
            WorkflowEdge('start', 'a'),
            WorkflowEdge('a', 'b'),
            WorkflowEdge('b', 'a'),
          ],
          startNodeId: 'start',
        ),
        throwsA(
          isA<ValidationException>().having(
            (e) => e.violations.join(),
            'violations',
            contains('loops'),
          ),
        ),
      );
    });

    test('accepts a cycle that was declared intentional', () {
      expect(
        () => WorkflowGraph(
          id: 'loopy',
          nodes: <WorkflowNode>[const StartNode(), marker('a'), marker('b')],
          edges: const <WorkflowEdge>[
            WorkflowEdge('start', 'a'),
            WorkflowEdge('a', 'b'),
            WorkflowEdge('b', 'a'),
          ],
          startNodeId: 'start',
          allowCycles: true,
        ),
        returnsNormally,
      );
    });

    test('rejects a node reading a key nothing upstream writes', () {
      // The promise of the whole package: this fails at build time, not three
      // minutes into a run.
      expect(
        () => WorkflowGraph(
          id: 'missing-input',
          nodes: <WorkflowNode>[
            const StartNode(),
            marker('consume', reads: <String>{'draft'}),
            const EndNode(),
          ],
          edges: const <WorkflowEdge>[
            WorkflowEdge('start', 'consume'),
            WorkflowEdge('consume', 'end'),
          ],
        ),
        throwsA(
          isA<ValidationException>().having(
            (e) => e.violations.join(),
            'violations',
            contains('reads `draft`'),
          ),
        ),
      );
    });

    test('accepts a key written upstream', () {
      expect(
        () => WorkflowGraph(
          id: 'flows',
          nodes: <WorkflowNode>[
            const StartNode(),
            marker(
              'produce',
              writes: <String, JsonSchema>{'draft': JsonSchema.string()},
            ),
            marker('consume', reads: <String>{'draft'}),
            const EndNode(),
          ],
          edges: const <WorkflowEdge>[
            WorkflowEdge('start', 'produce'),
            WorkflowEdge('produce', 'consume'),
            WorkflowEdge('consume', 'end'),
          ],
        ),
        returnsNormally,
      );
    });

    test('rejects a key written on only one branch', () {
      // Availability is the intersection of every path in, not the union: a
      // value that exists on one branch and not another is the bug this looks
      // for.
      expect(
        () => WorkflowGraph(
          id: 'branchy',
          nodes: <WorkflowNode>[
            ConditionNode(id: 'check', predicate: (_) => true),
            marker(
              'yes',
              writes: <String, JsonSchema>{'note': JsonSchema.string()},
            ),
            marker('no'),
            marker('merge', reads: <String>{'note'}),
            const EndNode(),
          ],
          edges: const <WorkflowEdge>[
            WorkflowEdge('check', 'yes', label: 'true'),
            WorkflowEdge('check', 'no', label: 'false'),
            WorkflowEdge('yes', 'merge'),
            WorkflowEdge('no', 'merge'),
            WorkflowEdge('merge', 'end'),
          ],
          startNodeId: 'check',
        ),
        throwsA(
          isA<ValidationException>().having(
            (e) => e.violations.join(),
            'violations',
            contains('only some of the paths'),
          ),
        ),
      );
    });

    test('rejects concurrent branches writing the same key', () {
      expect(
        () => WorkflowGraph(
          id: 'race',
          nodes: <WorkflowNode>[
            const StartNode(),
            ParallelNode(
              id: 'fanout',
              branches: <WorkflowNode>[
                marker(
                  'a',
                  writes: <String, JsonSchema>{'out': JsonSchema.string()},
                ),
                marker(
                  'b',
                  writes: <String, JsonSchema>{'out': JsonSchema.string()},
                ),
              ],
            ),
            const EndNode(),
          ],
          edges: const <WorkflowEdge>[
            WorkflowEdge('start', 'fanout'),
            WorkflowEdge('fanout', 'end'),
          ],
        ),
        throwsA(
          isA<ValidationException>().having(
            (e) => e.violations.join(),
            'violations',
            contains('write `out`'),
          ),
        ),
      );
    });

    test('reports every problem at once', () {
      // A graph with four mistakes should take one fix cycle, not four.
      try {
        WorkflowGraph(
          id: 'messy',
          nodes: <WorkflowNode>[
            const StartNode(),
            marker('orphan'),
            marker('needs', reads: <String>{'missing'}),
          ],
          edges: const <WorkflowEdge>[WorkflowEdge('start', 'needs')],
          startNodeId: 'start',
        );
        fail('expected validation to fail');
      } on ValidationException catch (error) {
        expect(error.violations.length, greaterThanOrEqualTo(2));
      }
    });

    test('infers the start node when exactly one root exists', () {
      final graph = WorkflowGraph(
        id: 'inferred',
        nodes: <WorkflowNode>[marker('first'), const EndNode()],
        edges: const <WorkflowEdge>[WorkflowEdge('first', 'end')],
      );

      expect(graph.startNodeId, 'first');
    });

    test('refuses to guess between several roots', () {
      expect(
        () => WorkflowGraph(
          id: 'ambiguous-start',
          nodes: <WorkflowNode>[marker('a'), marker('b'), const EndNode()],
          edges: const <WorkflowEdge>[
            WorkflowEdge('a', 'end'),
            WorkflowEdge('b', 'end'),
          ],
        ),
        throwsA(
          isA<ValidationException>().having(
            (e) => e.violations.join(),
            'violations',
            contains('ambiguous'),
          ),
        ),
      );
    });

    test('renders a Mermaid diagram from the real graph', () {
      final graph = WorkflowGraph(
        id: 'diagram',
        nodes: <WorkflowNode>[const StartNode(), const EndNode()],
        edges: const <WorkflowEdge>[
          WorkflowEdge('start', 'end', label: 'done'),
        ],
      );

      final mermaid = graph.toMermaid();
      expect(mermaid, startsWith('flowchart TD'));
      expect(mermaid, contains('start -->|done| end'));
    });
  });

  group('declared inputs', () {
    WorkflowGraph graphTaking(Map<String, JsonSchema> inputs) => WorkflowGraph(
      id: 'parameterised',
      inputs: inputs,
      nodes: <WorkflowNode>[
        marker('use', reads: inputs.keys.toSet()),
        const EndNode(),
      ],
      edges: const <WorkflowEdge>[WorkflowEdge('use', 'end')],
      startNodeId: 'use',
    );

    test('a declared input satisfies a node that reads it', () {
      expect(
        () => graphTaking(<String, JsonSchema>{'topic': JsonSchema.string()}),
        returnsNormally,
      );
    });

    test('a missing required input is reported at the boundary', () async {
      // Rather than as a `state has no value for` failure partway in.
      final graph = graphTaking(<String, JsonSchema>{
        'topic': JsonSchema.string(),
      });

      await expectLater(
        const WorkflowEngine().run(graph),
        throwsA(
          isA<ValidationException>().having(
            (e) => e.violations.join(),
            'violations',
            contains('topic: required input is missing'),
          ),
        ),
      );
    });

    test('an input of the wrong shape is rejected', () async {
      final graph = graphTaking(<String, JsonSchema>{
        'count': JsonSchema.integer(),
      });

      await expectLater(
        const WorkflowEngine().run(
          graph,
          input: <String, Object?>{'count': 'not a number'},
        ),
        throwsA(isA<ValidationException>()),
      );
    });
  });

  group('WorkflowBuilder', () {
    test('chains and branches without repeating identifiers', () {
      final log = <String>[];
      final graph =
          (WorkflowBuilder('built')
                ..chain(<WorkflowNode>[
                  const StartNode(),
                  ConditionNode(id: 'check', predicate: (_) => true),
                ])
                ..branch('check', <String, WorkflowNode>{
                  'true': marker('yes', log: log),
                  'false': marker('no', log: log),
                })
                ..add(const EndNode())
                ..edge('yes', 'end')
                ..edge('no', 'end'))
              .build();

      expect(graph.nodes.keys, containsAll(<String>['start', 'check', 'yes']));
      expect(graph.edges.length, 5);
    });
  });

  group('execution', () {
    late WorkflowEngine engine;

    setUp(() => engine = const WorkflowEngine());

    test('runs a linear graph in order', () async {
      final log = <String>[];
      final graph = WorkflowGraph(
        id: 'linear',
        nodes: <WorkflowNode>[
          const StartNode(),
          marker('a', log: log),
          marker('b', log: log),
          const EndNode(),
        ],
        edges: const <WorkflowEdge>[
          WorkflowEdge('start', 'a'),
          WorkflowEdge('a', 'b'),
          WorkflowEdge('b', 'end'),
        ],
      );

      final result = await engine.run(graph);

      expect(result.status, WorkflowStatus.completed);
      expect(log, <String>['a', 'b']);
      expect(result.steps, 4);
    });

    test('carries state between nodes', () async {
      final graph = WorkflowGraph(
        id: 'stateful',
        inputs: <String, JsonSchema>{'n': JsonSchema.integer()},
        nodes: <WorkflowNode>[
          TransformNode(
            id: 'double',
            reads: <String>{'n'},
            writes: <String, JsonSchema>{'doubled': JsonSchema.integer()},
            transform: (context) async => <String, Object?>{
              'doubled': context.require<int>('n') * 2,
            },
          ),
          const EndNode(),
        ],
        edges: const <WorkflowEdge>[WorkflowEdge('double', 'end')],
      );

      final result = await engine.run(graph, input: <String, Object?>{'n': 21});

      expect(result.output<int>('doubled'), 42);
    });

    test('follows the branch a condition chose', () async {
      final log = <String>[];
      final graph = WorkflowGraph(
        id: 'branching',
        inputs: <String, JsonSchema>{'urgent': JsonSchema.boolean()},
        nodes: <WorkflowNode>[
          ConditionNode(
            id: 'check',
            reads: <String>{'urgent'},
            predicate: (context) => context.getOr<bool>('urgent', false),
          ),
          marker('escalate', log: log),
          marker('reply', log: log),
          const EndNode(),
        ],
        edges: const <WorkflowEdge>[
          WorkflowEdge('check', 'escalate', label: 'true'),
          WorkflowEdge('check', 'reply', label: 'false'),
          WorkflowEdge('escalate', 'end'),
          WorkflowEdge('reply', 'end'),
        ],
        startNodeId: 'check',
      );

      await engine.run(graph, input: <String, Object?>{'urgent': true});
      await engine.run(graph, input: <String, Object?>{'urgent': false});

      expect(log, <String>['escalate', 'reply']);
    });

    test('fails when a branch has no matching edge', () async {
      // Falling through would take a path nobody chose.
      final graph = WorkflowGraph(
        id: 'gap',
        nodes: <WorkflowNode>[
          SwitchNode(id: 'route', selector: (_) => 'nowhere'),
          marker('a'),
          const EndNode(),
        ],
        edges: const <WorkflowEdge>[
          WorkflowEdge('route', 'a', label: 'somewhere'),
          WorkflowEdge('a', 'end'),
        ],
        startNodeId: 'route',
      );

      final result = await engine.run(graph);

      expect(result.status, WorkflowStatus.failed);
      expect(result.error!.message, contains('no outgoing edge'));
      expect(result.error!.message, contains('`somewhere`'));
    });

    test('returns a failure with the trail, rather than throwing', () async {
      final graph = WorkflowGraph(
        id: 'failing',
        nodes: <WorkflowNode>[
          marker('ok'),
          CustomNode(
            id: 'boom',
            run: (_) async => throw StorageException('disk full', store: 'db'),
          ),
          const EndNode(),
        ],
        edges: const <WorkflowEdge>[
          WorkflowEdge('ok', 'boom'),
          WorkflowEdge('boom', 'end'),
        ],
        startNodeId: 'ok',
      );

      final result = await engine.run(graph);

      expect(result.status, WorkflowStatus.failed);
      expect(result.error, isA<StorageException>());
      expect(result.executions.map((e) => e.nodeId), <String>['ok', 'boom']);
      expect(result.error!.annotations['workflow.node'], 'boom');
      expect(result.ensureComplete, throwsA(isA<StorageException>()));
    });

    test(
      'catches a node that writes the wrong shape where it happened',
      () async {
        final graph = WorkflowGraph(
          id: 'liar',
          nodes: <WorkflowNode>[
            CustomNode(
              id: 'liar',
              writes: <String, JsonSchema>{
                'items': JsonSchema.array(items: JsonSchema.string()),
              },
              run: (_) async => const NodeOutcome.next(
                writes: <String, Object?>{'items': 'not a list'},
              ),
            ),
            const EndNode(),
          ],
          edges: const <WorkflowEdge>[WorkflowEdge('liar', 'end')],
          startNodeId: 'liar',
        );

        final result = await engine.run(graph);

        expect(result.status, WorkflowStatus.failed);
        expect(result.error!.message, contains('does not match the shape'));
      },
    );

    test('propagates cancellation', () async {
      final source = CancellationTokenSource();
      final graph = WorkflowGraph(
        id: 'cancelled',
        nodes: <WorkflowNode>[
          CustomNode(
            id: 'stop',
            run: (context) async {
              source.cancel('user left');
              context.throwIfCancelled();
              return const NodeOutcome.next();
            },
          ),
          const EndNode(),
        ],
        edges: const <WorkflowEdge>[WorkflowEdge('stop', 'end')],
        startNodeId: 'stop',
      );

      await expectLater(
        engine.run(
          graph,
          context: AgenticContext.root(cancellation: source.token),
        ),
        throwsA(isA<CancelledException>()),
      );
    });
  });

  group('budgets', () {
    test('names the node that is looping', () async {
      // A bare step count tells an author that something looped, not what.
      final graph = WorkflowGraph(
        id: 'spin',
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

      final result = await const WorkflowEngine(
        budget: WorkflowBudget(maxSteps: 100, maxNodeVisits: 3),
      ).run(graph);

      expect(result.status, WorkflowStatus.budgetExhausted);
      expect(result.error!.message, contains('`spin`'));
      expect(result.steps, 3);
    });

    test('stops at the total step budget', () async {
      final graph = WorkflowGraph(
        id: 'chain',
        nodes: <WorkflowNode>[
          CustomNode(
            id: 'a',
            jumpTargets: const <String>{'b'},
            run: (_) async => const NodeOutcome.goTo('b'),
          ),
          CustomNode(
            id: 'b',
            jumpTargets: const <String>{'a'},
            run: (_) async => const NodeOutcome.goTo('a'),
          ),
        ],
        edges: const <WorkflowEdge>[],
        startNodeId: 'a',
        allowCycles: true,
      );

      final result = await const WorkflowEngine(
        budget: WorkflowBudget(maxSteps: 5, maxNodeVisits: 100),
      ).run(graph);

      expect(result.status, WorkflowStatus.budgetExhausted);
      expect(result.steps, 5);
    });

    test('stops at the wall-clock budget on the injected clock', () async {
      final clock = FakeClock();
      final graph = WorkflowGraph(
        id: 'slow',
        nodes: <WorkflowNode>[
          const DelayNode(id: 'wait', duration: Duration(minutes: 5)),
          CustomNode(
            id: 'again',
            jumpTargets: const <String>{'wait'},
            run: (_) async => const NodeOutcome.goTo('wait'),
          ),
        ],
        edges: const <WorkflowEdge>[WorkflowEdge('wait', 'again')],
        startNodeId: 'wait',
        allowCycles: true,
      );

      final pending = const WorkflowEngine(
        budget: WorkflowBudget(maxDuration: Duration(minutes: 10)),
      ).run(graph, context: AgenticContext.root(clock: clock));

      await clock.advance(const Duration(minutes: 30));
      final result = await pending;

      expect(result.status, WorkflowStatus.budgetExhausted);
    });
  });

  group('loops', () {
    test('repeats until the condition stops holding', () async {
      final graph = WorkflowGraph(
        id: 'counter',
        inputs: <String, JsonSchema>{'count': JsonSchema.integer()},
        nodes: <WorkflowNode>[
          TransformNode(
            id: 'increment',
            reads: <String>{'count'},
            writes: <String, JsonSchema>{'count': JsonSchema.integer()},
            transform: (context) async => <String, Object?>{
              'count': context.getOr<int>('count', 0) + 1,
            },
          ),
          LoopNode(
            id: 'again',
            bodyNodeId: 'increment',
            reads: <String>{'count'},
            shouldContinue: (context) => context.getOr<int>('count', 0) < 3,
          ),
          const EndNode(),
        ],
        edges: const <WorkflowEdge>[
          WorkflowEdge('increment', 'again'),
          WorkflowEdge('again', 'end'),
        ],
        startNodeId: 'increment',
        allowCycles: true,
      );

      final result = await const WorkflowEngine().run(
        graph,
        input: <String, Object?>{'count': 0},
      );

      expect(result.status, WorkflowStatus.completed);
      expect(result.output<int>('count'), 3);
    });

    test('a loop bounds itself independently of the engine', () async {
      final graph = WorkflowGraph(
        id: 'runaway',
        nodes: <WorkflowNode>[
          marker('body'),
          LoopNode(
            id: 'again',
            bodyNodeId: 'body',
            maxIterations: 2,
            // Never stops on its own.
            shouldContinue: (_) => true,
          ),
          const EndNode(),
        ],
        edges: const <WorkflowEdge>[
          WorkflowEdge('body', 'again'),
          WorkflowEdge('again', 'end'),
        ],
        startNodeId: 'body',
        allowCycles: true,
      );

      final result = await const WorkflowEngine().run(graph);

      expect(result.status, WorkflowStatus.completed);
    });
  });

  group('parallel and map', () {
    test('runs branches concurrently and merges their writes', () async {
      var active = 0;
      var peak = 0;
      CustomNode branch(String id) => CustomNode(
        id: id,
        writes: <String, JsonSchema>{id: JsonSchema.string()},
        run: (_) async {
          active++;
          peak = active > peak ? active : peak;
          await Future<void>.delayed(const Duration(milliseconds: 5));
          active--;
          return NodeOutcome.next(writes: <String, Object?>{id: 'done'});
        },
      );

      final graph = WorkflowGraph(
        id: 'fanout',
        nodes: <WorkflowNode>[
          ParallelNode(
            id: 'fanout',
            branches: <WorkflowNode>[branch('a'), branch('b'), branch('c')],
          ),
          const EndNode(),
        ],
        edges: const <WorkflowEdge>[WorkflowEdge('fanout', 'end')],
        startNodeId: 'fanout',
      );

      final result = await const WorkflowEngine().run(graph);

      expect(result.output<String>('a'), 'done');
      expect(result.output<String>('c'), 'done');
      expect(peak, greaterThan(1));
    });

    test('a failing branch fails the node by default', () async {
      final graph = WorkflowGraph(
        id: 'fanout-fail',
        nodes: <WorkflowNode>[
          ParallelNode(
            id: 'fanout',
            branches: <WorkflowNode>[
              marker(
                'ok',
                writes: <String, JsonSchema>{'ok': JsonSchema.string()},
                outputs: <String, Object?>{'ok': 'yes'},
              ),
              CustomNode(
                id: 'bad',
                run: (_) async => throw StorageException('x', store: 'db'),
              ),
            ],
          ),
          const EndNode(),
        ],
        edges: const <WorkflowEdge>[WorkflowEdge('fanout', 'end')],
        startNodeId: 'fanout',
      );

      final result = await const WorkflowEngine().run(graph);

      expect(result.status, WorkflowStatus.failed);
    });

    test('refuses to suspend inside a parallel branch', () async {
      // A snapshot of one arm of a fan-out would silently lose the others.
      final graph = WorkflowGraph(
        id: 'bad-suspend',
        nodes: <WorkflowNode>[
          ParallelNode(
            id: 'fanout',
            branches: <WorkflowNode>[
              HumanApprovalNode(id: 'approve', message: 'ok?'),
            ],
          ),
          const EndNode(),
        ],
        edges: const <WorkflowEdge>[WorkflowEdge('fanout', 'end')],
        startNodeId: 'fanout',
      );

      final result = await const WorkflowEngine().run(graph);

      expect(result.status, WorkflowStatus.failed);
      expect(result.error!.message, contains('tried to suspend'));
    });

    test('maps a body over a collection', () async {
      final graph = WorkflowGraph(
        id: 'mapper',
        inputs: <String, JsonSchema>{
          'documents': JsonSchema.array(items: JsonSchema.string()),
        },
        nodes: <WorkflowNode>[
          MapNode(
            id: 'each',
            itemsKey: 'documents',
            resultKey: 'summary',
            outputKey: 'summaries',
            body: TransformNode(
              id: 'summarise',
              reads: <String>{'item'},
              writes: <String, JsonSchema>{'summary': JsonSchema.string()},
              transform: (context) async => <String, Object?>{
                'summary': 'summary of ${context.require<String>('item')}',
              },
            ),
          ),
          const EndNode(),
        ],
        edges: const <WorkflowEdge>[WorkflowEdge('each', 'end')],
        startNodeId: 'each',
      );

      final result = await const WorkflowEngine().run(
        graph,
        input: <String, Object?>{
          'documents': <Object?>['one', 'two', 'three'],
        },
      );

      expect(result.output<List<Object?>>('summaries'), <Object?>[
        'summary of one',
        'summary of two',
        'summary of three',
      ]);
    });

    test('an empty collection produces an empty result', () async {
      final graph = WorkflowGraph(
        id: 'empty-map',
        inputs: <String, JsonSchema>{
          'documents': JsonSchema.array(items: JsonSchema.string()),
        },
        nodes: <WorkflowNode>[
          MapNode(
            id: 'each',
            itemsKey: 'documents',
            resultKey: 'summary',
            body: marker('noop'),
          ),
          const EndNode(),
        ],
        edges: const <WorkflowEdge>[WorkflowEdge('each', 'end')],
        startNodeId: 'each',
      );

      final result = await const WorkflowEngine().run(
        graph,
        input: <String, Object?>{'documents': <Object?>[]},
      );

      expect(result.output<List<Object?>>('results'), isEmpty);
    });
  });

  group('suspension and resume', () {
    WorkflowGraph approvalGraph() => WorkflowGraph(
      id: 'approval',
      nodes: <WorkflowNode>[
        TransformNode(
          id: 'draft',
          writes: <String, JsonSchema>{'draft': JsonSchema.string()},
          transform: (_) async => <String, Object?>{'draft': 'Dear Ada, ...'},
        ),
        HumanApprovalNode(
          id: 'approve',
          message: 'Send this email?',
          reads: <String>{'draft'},
          summarise: (context) => context.require<String>('draft'),
        ),
        marker(
          'send',
          writes: <String, JsonSchema>{'sent': JsonSchema.boolean()},
          outputs: <String, Object?>{'sent': true},
        ),
        marker(
          'discard',
          writes: <String, JsonSchema>{'sent': JsonSchema.boolean()},
          outputs: <String, Object?>{'sent': false},
        ),
        const EndNode(),
      ],
      edges: const <WorkflowEdge>[
        WorkflowEdge('draft', 'approve'),
        WorkflowEdge('approve', 'send', label: 'approved'),
        WorkflowEdge('approve', 'discard', label: 'rejected'),
        WorkflowEdge('send', 'end'),
        WorkflowEdge('discard', 'end'),
      ],
      startNodeId: 'draft',
    );

    test('suspends with a snapshot describing what is being asked', () async {
      final result = await const WorkflowEngine().run(approvalGraph());

      expect(result.status, WorkflowStatus.suspended);
      expect(result.suspension!.kind, 'human_approval');
      expect(result.suspension!.message, 'Send this email?');
      expect(result.suspension!.payload['summary'], 'Dear Ada, ...');
      expect(result.snapshot!.nodeId, 'approve');
    });

    test(
      'resumes through a JSON round trip, as it would after a restart',
      () async {
        const engine = WorkflowEngine();
        final graph = approvalGraph();

        final suspended = await engine.run(graph);

        // Exactly what an app does: persist, die, come back.
        final stored = jsonEncode(suspended.snapshot!.toJson());
        final restored = WorkflowSnapshot.fromJson(
          jsonDecode(stored) as Map<String, Object?>,
        );

        final finished = await engine.resume(
          graph,
          restored,
          resumeValue: <String, Object?>{
            'approved': true,
            'comment': 'looks ok',
          },
        );

        expect(finished.status, WorkflowStatus.completed);
        expect(finished.output<bool>('sent'), isTrue);
        expect(finished.output<String>('approved.comment'), 'looks ok');
        expect(finished.runId, suspended.runId, reason: 'one run, not two');
      },
    );

    test('takes the rejection branch', () async {
      const engine = WorkflowEngine();
      final graph = approvalGraph();
      final suspended = await engine.run(graph);

      final finished = await engine.resume(
        graph,
        suspended.snapshot!,
        resumeValue: <String, Object?>{'approved': false},
      );

      expect(finished.output<bool>('sent'), isFalse);
    });

    test('rejects a malformed decision at the boundary', () async {
      const engine = WorkflowEngine();
      final graph = approvalGraph();
      final suspended = await engine.run(graph);

      await expectLater(
        engine.resume(
          graph,
          suspended.snapshot!,
          resumeValue: <String, Object?>{},
        ),
        throwsA(isA<ValidationException>()),
      );
    });

    test('refuses a snapshot from a different graph', () async {
      const engine = WorkflowEngine();
      final suspended = await engine.run(approvalGraph());
      final other = WorkflowGraph(
        id: 'other',
        nodes: <WorkflowNode>[const StartNode(), const EndNode()],
        edges: const <WorkflowEdge>[WorkflowEdge('start', 'end')],
      );

      await expectLater(
        engine.resume(other, suspended.snapshot!, resumeValue: true),
        throwsA(
          isA<ValidationException>().having(
            (e) => e.message,
            'message',
            contains('belongs to the workflow'),
          ),
        ),
      );
    });

    test('refuses a snapshot whose node no longer exists', () async {
      const engine = WorkflowEngine();
      final suspended = await engine.run(approvalGraph());

      // The graph changed while the run was suspended.
      final changed = WorkflowGraph(
        id: 'approval',
        nodes: <WorkflowNode>[const StartNode(), const EndNode()],
        edges: const <WorkflowEdge>[WorkflowEdge('start', 'end')],
      );

      await expectLater(
        engine.resume(changed, suspended.snapshot!, resumeValue: true),
        throwsA(
          isA<ValidationException>().having(
            (e) => e.message,
            'message',
            contains('no longer exists'),
          ),
        ),
      );
    });

    test('a generic wait node carries its payload through', () async {
      const engine = WorkflowEngine();
      final graph = WorkflowGraph(
        id: 'webhook',
        nodes: <WorkflowNode>[
          WaitForEventNode(
            id: 'wait',
            eventKind: 'payment_confirmed',
            message: 'Waiting for payment.',
            outputKey: 'payment',
          ),
          const EndNode(),
        ],
        edges: const <WorkflowEdge>[WorkflowEdge('wait', 'end')],
        startNodeId: 'wait',
      );

      final suspended = await engine.run(graph);
      expect(suspended.suspension!.kind, 'payment_confirmed');

      final finished = await engine.resume(
        graph,
        suspended.snapshot!,
        resumeValue: <String, Object?>{'reference': 'pay_1'},
      );

      expect(
        finished.output<Map<String, Object?>>('payment')!['reference'],
        'pay_1',
      );
    });

    test('a suspending run must have serialisable state', () async {
      final graph = WorkflowGraph(
        id: 'unserialisable',
        nodes: <WorkflowNode>[
          CustomNode(
            id: 'stash',
            writes: <String, JsonSchema>{'live': JsonSchema.any()},
            run: (_) async =>
                NodeOutcome.next(writes: <String, Object?>{'live': Object()}),
          ),
          HumanApprovalNode(id: 'approve', message: 'ok?'),
          const EndNode(),
        ],
        edges: const <WorkflowEdge>[
          WorkflowEdge('stash', 'approve'),
          WorkflowEdge('approve', 'end'),
        ],
        startNodeId: 'stash',
      );

      await expectLater(
        const WorkflowEngine().run(graph),
        throwsA(
          isA<ValidationException>().having(
            (e) => e.message,
            'message',
            contains('`live`'),
          ),
        ),
      );
    });
  });

  group('framework nodes', () {
    test('an LLM node writes the answer and optional usage', () async {
      final model = FakeChatModel.text('Paris.');
      final graph = WorkflowGraph(
        id: 'ask',
        inputs: <String, JsonSchema>{'question': JsonSchema.string()},
        nodes: <WorkflowNode>[
          LlmNode(
            id: 'ask',
            model: model,
            reads: <String>{'question'},
            usageKey: 'usage',
            buildRequest: (context) =>
                ChatRequest.prompt(context.require<String>('question')),
          ),
          const EndNode(),
        ],
        edges: const <WorkflowEdge>[WorkflowEdge('ask', 'end')],
        startNodeId: 'ask',
      );

      final result = await const WorkflowEngine().run(
        graph,
        input: <String, Object?>{'question': 'capital of France?'},
      );

      expect(result.output<String>('answer'), 'Paris.');
      expect(result.output<Map<String, Object?>>('usage')!['totalTokens'], 15);
    });

    test('a structured node writes a decoded object', () async {
      final graph = WorkflowGraph(
        id: 'extract',
        nodes: <WorkflowNode>[
          StructuredLlmNode(
            id: 'extract',
            model: FakeChatModel.text('{"city":"Paris"}'),
            schema: JsonSchema.object(
              properties: <String, JsonSchema>{'city': JsonSchema.string()},
              required: const <String>{'city'},
            ),
            buildRequest: (_) => ChatRequest.prompt('extract'),
          ),
          const EndNode(),
        ],
        edges: const <WorkflowEdge>[WorkflowEdge('extract', 'end')],
        startNodeId: 'extract',
      );

      final result = await const WorkflowEngine().run(graph);

      expect(result.output<Map<String, Object?>>('result')!['city'], 'Paris');
    });

    test(
      'an agent node runs an agent and fails on an incomplete run',
      () async {
        final agent = ToolCallingAgent(
          info: AgentInfo(name: 'worker', description: 'Answers.'),
          model: FakeChatModel.failing(
            ProviderException('down', provider: 'test', statusCode: 500),
          ),
        );
        final graph = WorkflowGraph(
          id: 'delegating',
          nodes: <WorkflowNode>[
            AgentNode(
              id: 'work',
              agent: agent,
              buildInput: (_) => AgentInput.text('go'),
            ),
            const EndNode(),
          ],
          edges: const <WorkflowEdge>[WorkflowEdge('work', 'end')],
          startNodeId: 'work',
        );

        final result = await const WorkflowEngine().run(graph);

        expect(result.status, WorkflowStatus.failed);
      },
    );

    test('a tool node invokes a tool through the executor', () async {
      final graph = WorkflowGraph(
        id: 'tooling',
        inputs: <String, JsonSchema>{'query': JsonSchema.string()},
        nodes: <WorkflowNode>[
          ToolNode(
            id: 'search',
            reads: <String>{'query'},
            tool: FunctionTool(
              name: 'search_web',
              description: 'Searches.',
              parameters: JsonSchema.object(
                properties: <String, JsonSchema>{'query': JsonSchema.string()},
                required: const <String>{'query'},
              ),
              handler: (invocation) async => ToolResult.success(
                'results for ${invocation.require<String>('query')}',
              ),
            ),
            buildArguments: (context) async => <String, Object?>{
              'query': context.require<String>('query'),
            },
          ),
          const EndNode(),
        ],
        edges: const <WorkflowEdge>[WorkflowEdge('search', 'end')],
        startNodeId: 'search',
      );

      final result = await const WorkflowEngine().run(
        graph,
        input: <String, Object?>{'query': 'dart'},
      );

      expect(result.output<String>('toolResult'), 'results for dart');
    });

    test('a delay waits on the injected clock', () async {
      final clock = FakeClock();
      final graph = WorkflowGraph(
        id: 'waiting',
        nodes: <WorkflowNode>[
          const DelayNode(id: 'wait', duration: Duration(hours: 2)),
          const EndNode(),
        ],
        edges: const <WorkflowEdge>[WorkflowEdge('wait', 'end')],
        startNodeId: 'wait',
      );

      final pending = const WorkflowEngine(
        budget: WorkflowBudget(maxDuration: Duration(days: 1)),
      ).run(graph, context: AgenticContext.root(clock: clock));
      await clock.advance(const Duration(hours: 2));

      expect((await pending).status, WorkflowStatus.completed);
    });
  });

  group('observability', () {
    test('publishes start, per-node and completion events', () async {
      final bus = BroadcastEventBus();
      final graph = WorkflowGraph(
        id: 'observed',
        nodes: <WorkflowNode>[marker('a'), const EndNode()],
        edges: const <WorkflowEdge>[WorkflowEdge('a', 'end')],
        startNodeId: 'a',
      );

      await const WorkflowEngine().run(
        graph,
        context: testContext(events: bus),
      );

      expect(bus.replayBuffer.whereType<WorkflowStarted>(), hasLength(1));
      expect(bus.replayBuffer.whereType<WorkflowNodeStarted>(), hasLength(2));
      expect(bus.replayBuffer.whereType<WorkflowNodeCompleted>(), hasLength(2));

      final completed = bus.replayBuffer.whereType<WorkflowCompleted>().single;
      expect(completed.status, WorkflowStatus.completed);
      expect(completed.steps, 2);
    });

    test('publishes a suspension an approval screen can bind to', () async {
      final bus = BroadcastEventBus();
      final graph = WorkflowGraph(
        id: 'pausing',
        nodes: <WorkflowNode>[
          HumanApprovalNode(id: 'approve', message: 'Proceed?'),
          const EndNode(),
        ],
        edges: const <WorkflowEdge>[
          WorkflowEdge('approve', 'end', label: 'approved'),
        ],
        startNodeId: 'approve',
      );

      await const WorkflowEngine().run(
        graph,
        context: testContext(events: bus),
      );

      final event = bus.replayBuffer.whereType<WorkflowSuspended>().single;
      expect(event.kind, 'human_approval');
      expect(event.message, 'Proceed?');
      await bus.dispose();
    });

    test('opens a span for the run', () async {
      final exporter = InMemorySpanExporter();
      final graph = WorkflowGraph(
        id: 'traced',
        nodes: <WorkflowNode>[marker('a'), const EndNode()],
        edges: const <WorkflowEdge>[WorkflowEdge('a', 'end')],
        startNodeId: 'a',
      );

      await const WorkflowEngine().run(
        graph,
        context: testContext(exporter: exporter),
      );

      final span = exporter.named('workflow.traced').single;
      expect(span.attributes['workflow.steps'], 2);
      expect(span.status, SpanStatus.ok);
    });

    test('the result serialises its trail', () async {
      final graph = WorkflowGraph(
        id: 'trail',
        nodes: <WorkflowNode>[marker('a'), const EndNode()],
        edges: const <WorkflowEdge>[WorkflowEdge('a', 'end')],
        startNodeId: 'a',
      );

      final json = (await const WorkflowEngine().run(graph)).toJson();

      expect(json['status'], 'completed');
      expect(json['steps'], 2);
      expect(json['executions']! as List, hasLength(2));
    });
  });
}
