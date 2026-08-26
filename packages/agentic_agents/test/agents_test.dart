import 'package:agentic_agents/agentic_agents.dart';
import 'package:agentic_core/agentic_core.dart';
import 'package:agentic_core/testing.dart';
import 'package:agentic_llm/agentic_llm.dart';
import 'package:agentic_llm/testing.dart';
import 'package:agentic_tools/agentic_tools.dart';
import 'package:test/test.dart';

AgentInfo infoFor(String name) =>
    AgentInfo(name: name, description: 'A $name that does $name things.');

ToolCallPart callTo(
  String name, {
  Map<String, Object?> arguments = const {},
  String id = 'call_1',
}) => ToolCallPart(id: id, name: name, arguments: arguments);

/// A registry with one recording tool.
({ToolRegistry registry, List<String> calls}) searchRegistry({
  String result = 'results for dart',
}) {
  final calls = <String>[];
  final registry = ToolRegistry()
    ..register(
      FunctionTool(
        name: 'search_web',
        description: 'Searches the web.',
        parameters: JsonSchema.object(
          properties: {'query': JsonSchema.string()},
          required: {'query'},
        ),
        handler: (invocation) async {
          calls.add(invocation.require<String>('query'));
          return ToolResult.success(result);
        },
      ),
    );
  return (registry: registry, calls: calls);
}

AgenticContext testContext({EventBus? events, SpanExporter? exporter}) =>
    AgenticContext.root(
      runId: 'run-1',
      events: events,
      ids: SequentialIdGenerator(prefix: 'e'),
      tracer: exporter == null ? null : Tracer(exporter: exporter),
    );

void main() {
  group('AgentInfo', () {
    test('rejects a name that could not be used as a tool name', () {
      // An agent can be exposed to another agent as a tool and inherits the
      // provider constraint on tool names.
      expect(
        () => AgentInfo(name: 'my agent!', description: 'x'),
        throwsA(isA<ConfigurationException>()),
      );
    });
  });

  group('ToolCallingAgent', () {
    test('answers directly when the model requests no tools', () async {
      final model = FakeChatModel.text('Paris.');
      final agent = ToolCallingAgent(info: infoFor('assistant'), model: model);

      final result = await agent.run(AgentInput.text('capital of France?'));

      expect(result.text, 'Paris.');
      expect(result.stopReason, AgentStopReason.completed);
      expect(result.iterations, 1);
      expect(model.callCount, 1);
    });

    test('runs a tool, feeds the result back, and answers', () async {
      final tools = searchRegistry();
      final model = FakeChatModel.toolCall(
        toolCalls: [
          callTo('search_web', arguments: {'query': 'dart 3.11'}),
        ],
        then: 'Dart 3.11 added dot shorthands.',
      );
      final agent = ToolCallingAgent(
        info: infoFor('researcher'),
        model: model,
        tools: tools.registry.all,
      );

      final result = await agent.run(AgentInput.text('What is new?'));

      expect(result.text, 'Dart 3.11 added dot shorthands.');
      expect(result.iterations, 2);
      expect(tools.calls, <String>['dart 3.11']);
      expect(result.allToolCalls.single.name, 'search_web');

      // The tool result was actually sent back to the model.
      final secondRequest = model.requests.last;
      expect(
        secondRequest.messages.any((m) => m.role == MessageRole.tool),
        isTrue,
      );
    });

    test('prepends instructions as a system message', () async {
      final model = FakeChatModel.text('ok');
      final agent = ToolCallingAgent(
        info: infoFor('assistant'),
        model: model,
        instructions: 'Be concise.',
      );

      await agent.run(AgentInput.text('hi'));

      expect(model.lastRequest.messages.first.role, MessageRole.system);
      expect(model.lastRequest.messages.first.text, 'Be concise.');
    });

    test(
      'carries a tool failure back to the model rather than failing',
      () async {
        // A failing tool is not a failing run; the model is told and recovers.
        final registry = ToolRegistry()
          ..register(
            FunctionTool(
              name: 'broken',
              description: 'Always fails.',
              handler: (_) async => ToolResult.failure('no such file'),
            ),
          );
        final model = FakeChatModel.toolCall(
          toolCalls: [callTo('broken')],
          then: 'I could not read that file.',
        );
        final agent = ToolCallingAgent(
          info: infoFor('assistant'),
          model: model,
          tools: registry.all,
        );

        final result = await agent.run(AgentInput.text('read it'));

        expect(result.stopReason, AgentStopReason.completed);
        expect(result.text, 'I could not read that file.');
        expect(result.steps.first.hasToolFailure, isTrue);
      },
    );

    test('tells the model when it invents a tool it was never given', () async {
      final model = FakeChatModel(
        turns: <FakeTurn>[
          FakeTurn.answer(
            ChatResponse(
              message: Message.assistant('', toolCalls: [callTo('imaginary')]),
              modelId: 'fake-model',
              finishReason: FinishReason.toolCalls,
            ),
          ),
          FakeTurn.answer(
            ChatResponse(
              message: Message.assistant('Answering from memory then.'),
              modelId: 'fake-model',
            ),
          ),
        ],
      );
      final agent = ToolCallingAgent(info: infoFor('assistant'), model: model);

      final result = await agent.run(AgentInput.text('do something'));

      expect(result.stopReason, AgentStopReason.completed);
      expect(result.text, 'Answering from memory then.');
    });

    test(
      'returns a failure result carrying the trail, not an exception',
      () async {
        final model = FakeChatModel.failing(
          ProviderException('boom', provider: 'test', statusCode: 400),
        );
        final agent = ToolCallingAgent(
          info: infoFor('assistant'),
          model: model,
        );

        final result = await agent.run(AgentInput.text('hi'));

        expect(result.stopReason, AgentStopReason.failed);
        expect(result.error, isA<ProviderException>());
        expect(result.text, contains('could not finish'));
        // The exception is still available to callers who want it.
        expect(result.ensureSuccess, throwsA(isA<ProviderException>()));
      },
    );

    test('propagates cancellation', () async {
      final source = CancellationTokenSource();
      final registry = ToolRegistry()
        ..register(
          FunctionTool(
            name: 'slow',
            description: 'Cancels the run.',
            handler: (invocation) async {
              source.cancel('user left');
              invocation.cancellation.throwIfCancelled(operation: 'slow');
              return ToolResult.success('never');
            },
          ),
        );
      final agent = ToolCallingAgent(
        info: infoFor('assistant'),
        model: FakeChatModel.toolCall(toolCalls: [callTo('slow')]),
        tools: registry.all,
      );

      await expectLater(
        agent.run(
          AgentInput.text('go'),
          context: AgenticContext.root(cancellation: source.token),
        ),
        throwsA(isA<CancelledException>()),
      );
    });

    test('an early stop condition ends the run', () async {
      final tools = searchRegistry();
      final model = FakeChatModel(
        turns: <FakeTurn>[
          FakeTurn.answer(
            ChatResponse(
              message: Message.assistant(
                '',
                toolCalls: [
                  callTo('search_web', arguments: {'query': 'x'}),
                ],
              ),
              modelId: 'fake-model',
              finishReason: FinishReason.toolCalls,
            ),
          ),
        ],
      );
      final agent = ToolCallingAgent(
        info: infoFor('assistant'),
        model: model,
        tools: tools.registry.all,
        stopWhen: (step) => step.toolCalls.isNotEmpty,
      );

      final result = await agent.run(AgentInput.text('go'));

      expect(result.stopReason, AgentStopReason.stopped);
      expect(result.iterations, 1);
    });
  });

  group('budgets', () {
    test('forbids tool calling on the last permitted iteration', () async {
      // The mechanism that guarantees a user gets an answer instead of an
      // unanswered tool call.
      final tools = searchRegistry();
      final model = FakeChatModel(
        turns: <FakeTurn>[
          FakeTurn.answer(
            ChatResponse(
              message: Message.assistant(
                '',
                toolCalls: [
                  callTo('search_web', arguments: {'query': 'a'}),
                ],
              ),
              modelId: 'fake-model',
              finishReason: FinishReason.toolCalls,
            ),
          ),
          FakeTurn.answer(
            ChatResponse(
              message: Message.assistant('Best effort answer.'),
              modelId: 'fake-model',
            ),
          ),
        ],
      );
      final agent = ToolCallingAgent(
        info: infoFor('assistant'),
        model: model,
        tools: tools.registry.all,
        budget: const AgentBudget(maxIterations: 2),
      );

      final result = await agent.run(AgentInput.text('go'));

      expect(result.text, 'Best effort answer.');
      expect(result.metadata['finalTurnForced'], isTrue);
      expect(
        model.requests.last.toolChoice,
        ToolChoice.none,
        reason: 'the final turn must produce prose',
      );
      expect(
        model.requests.last.tools,
        isNotNull,
        reason: 'tools stay described so earlier calls stay valid',
      );
    });

    test(
      'stops on the iteration limit when the model keeps calling tools',
      () async {
        final tools = searchRegistry();
        final model = FakeChatModel(
          turns: <FakeTurn>[
            FakeTurn.answer(
              ChatResponse(
                message: Message.assistant(
                  '',
                  toolCalls: [
                    callTo('search_web', arguments: {'query': 'a'}),
                  ],
                ),
                modelId: 'fake-model',
                finishReason: FinishReason.toolCalls,
              ),
            ),
          ],
        );
        final agent = ToolCallingAgent(
          info: infoFor('assistant'),
          model: model,
          tools: tools.registry.all,
          // One iteration: forcing prose is impossible, so the run ends on the
          // budget and must still explain itself.
          budget: const AgentBudget(maxIterations: 1),
        );

        final result = await agent.run(AgentInput.text('go'));

        expect(result.stopReason, AgentStopReason.budgetExhausted);
        expect(result.budgetDimension, BudgetDimension.iterations);
        expect(result.text, contains('model calls'));
        expect(result.ensureSuccess, throwsA(isA<InvalidStateException>()));
      },
    );

    test('stops on the token allowance', () async {
      final tools = searchRegistry();
      final model = FakeChatModel(
        turns: <FakeTurn>[
          FakeTurn.answer(
            ChatResponse(
              message: Message.assistant(
                '',
                toolCalls: [
                  callTo('search_web', arguments: {'query': 'a'}),
                ],
              ),
              modelId: 'fake-model',
              finishReason: FinishReason.toolCalls,
              usage: const TokenUsage(promptTokens: 400, completionTokens: 200),
            ),
          ),
        ],
      );
      final agent = ToolCallingAgent(
        info: infoFor('assistant'),
        model: model,
        tools: tools.registry.all,
        budget: const AgentBudget(maxIterations: 10, maxTokens: 500),
      );

      final result = await agent.run(AgentInput.text('go'));

      expect(result.budgetDimension, BudgetDimension.tokens);
      expect(result.usage.totalTokens, 600);
    });

    test('an input budget overrides the agent default', () async {
      final model = FakeChatModel.text('ok');
      final agent = ToolCallingAgent(
        info: infoFor('assistant'),
        model: model,
        budget: const AgentBudget(maxIterations: 1),
      );

      final result = await agent.run(
        AgentInput.text('hi', budget: const AgentBudget(maxIterations: 5)),
      );

      expect(result.stopReason, AgentStopReason.completed);
    });

    test('tracker reports the first exhausted dimension', () {
      final clock = FakeClock();
      final tracker = BudgetTracker(
        budget: const AgentBudget(maxIterations: 2, maxTokens: 100),
        clock: clock,
      );

      expect(tracker.exhausted, isNull);
      tracker.recordIteration(
        usage: const TokenUsage(promptTokens: 200, completionTokens: 0),
      );
      expect(tracker.exhausted, BudgetDimension.tokens);
      expect(tracker.explain(BudgetDimension.tokens), contains('200 used'));
    });

    test('time spent waiting on a person does not spend the budget', () async {
      // The defect this guards: a user who reads an approval prompt carefully
      // gets their run killed for it, while one who taps Allow instantly does
      // not. Intermittent, invisible in every test that does not model a
      // human, and exactly backwards — the budget bounds the agent, not the
      // person it is asking.
      final clock = FakeClock();
      final ledger = HumanWaitLedger();
      final tracker = BudgetTracker(
        budget: const AgentBudget(maxDuration: Duration(seconds: 30)),
        clock: clock,
        humanWait: ledger,
      );

      await clock.advance(const Duration(seconds: 10));
      ledger.add(const Duration(seconds: 40));

      expect(tracker.wallClock, const Duration(seconds: 10));
      expect(tracker.humanWait, const Duration(seconds: 40));
      expect(tracker.elapsed, Duration.zero, reason: 'clamped, never negative');
      expect(tracker.exhausted, isNull);
    });

    test('a slow agent still exhausts its duration budget', () async {
      // The other half: excluding human waiting must not disable the bound.
      final clock = FakeClock();
      final ledger = HumanWaitLedger()..add(const Duration(seconds: 5));
      final tracker = BudgetTracker(
        budget: const AgentBudget(maxDuration: Duration(seconds: 30)),
        clock: clock,
        humanWait: ledger,
      );

      await clock.advance(const Duration(seconds: 36));

      expect(tracker.elapsed, const Duration(seconds: 31));
      expect(tracker.exhausted, BudgetDimension.duration);
    });

    test('the human wait is reported so a slow run can be told apart', () {
      final ledger = HumanWaitLedger()..add(const Duration(seconds: 4));
      final tracker = BudgetTracker(
        budget: AgentBudget.interactive,
        clock: FakeClock(),
        humanWait: ledger,
      );
      expect(tracker.toJson()['humanWaitMs'], 4000);
    });

    test('tracker reports a duration limit on the injected clock', () async {
      final clock = FakeClock();
      final tracker = BudgetTracker(
        budget: const AgentBudget(maxDuration: Duration(seconds: 30)),
        clock: clock,
      );

      expect(tracker.exhausted, isNull);
      await clock.advance(const Duration(seconds: 31));
      expect(tracker.exhausted, BudgetDimension.duration);
    });
  });

  group('streaming', () {
    test('emits text deltas, tool updates and a final result', () async {
      final tools = searchRegistry();
      final model = FakeChatModel.toolCall(
        toolCalls: [
          callTo('search_web', arguments: {'query': 'dart'}),
        ],
        then: 'Found it.',
      );
      final agent = ToolCallingAgent(
        info: infoFor('researcher'),
        model: model,
        tools: tools.registry.all,
      );

      final chunks = await agent.stream(AgentInput.text('go')).toList();

      expect(
        chunks.whereType<AgentToolCallStarted>().single.toolName,
        'search_web',
      );
      expect(chunks.whereType<AgentToolCallFinished>().single.isError, isFalse);
      expect(chunks.whereType<AgentStepFinished>(), hasLength(2));
      expect(
        chunks.whereType<AgentTextDelta>().map((c) => c.text).join(),
        'Found it.',
      );
      expect(chunks.last, isA<AgentFinished>());
      expect(
        (chunks.last as AgentFinished).result.stopReason,
        AgentStopReason.completed,
      );
    });

    test('askStream yields only answer text', () async {
      final agent = ToolCallingAgent(
        info: infoFor('assistant'),
        model: FakeChatModel.text('Hello world'),
      );

      expect(await agent.askStream('hi').join(), 'Hello world');
    });

    test(
      'falls back to a single delivery for a model that cannot stream',
      () async {
        final model = FakeChatModel.text(
          'no streaming here',
          info: ModelInfo(
            id: 'basic',
            provider: 'local',
            capabilities: const <ModelCapability>{},
          ),
        );
        final agent = ToolCallingAgent(
          info: infoFor('assistant'),
          model: model,
        );

        final chunks = await agent.stream(AgentInput.text('hi')).toList();

        expect(chunks.whereType<AgentTextDelta>(), isEmpty);
        expect((chunks.last as AgentFinished).result.text, 'no streaming here');
      },
    );
  });

  group('sessions', () {
    test('carries history between runs', () async {
      final model = FakeChatModel.text('ok');
      final agent = ToolCallingAgent(info: infoFor('assistant'), model: model);
      final session = AgentSession();

      await agent.run(AgentInput.text('first'), session: session);
      await agent.run(AgentInput.text('second'), session: session);

      // The second request saw the first exchange.
      expect(
        model.requests.last.messages.map((m) => m.text),
        contains('first'),
      );
      expect(session.runCount, 2);
      expect(session.history.length, 4);
      expect(session.totalUsage.totalTokens, 30);
    });

    test('a sliding window keeps system messages', () async {
      final history = <Message>[
        Message.system('Be brief.'),
        for (var i = 0; i < 10; i++) Message.user('turn $i'),
      ];
      final session = AgentSession(
        history: history,
        strategy: const SlidingWindowHistory(maxMessages: 3),
      );

      final selected = await session.selectHistory();
      expect(selected.first.role, MessageRole.system);
      expect(selected, hasLength(4));
      expect(selected.last.text, 'turn 9');
    });

    test('a window drops tool results whose call was trimmed away', () async {
      // Otherwise a long conversation becomes a hard provider 400 after N turns.
      final session = AgentSession(
        history: <Message>[
          Message.assistant('', toolCalls: [callTo('search_web', id: 'old')]),
          Message.toolResult(callId: 'old', name: 'search_web', content: 'r'),
          Message.user('a'),
          Message.user('b'),
        ],
        strategy: const SlidingWindowHistory(maxMessages: 3),
      );

      final selected = await session.selectHistory();
      expect(
        selected.any((Message m) => m.role == MessageRole.tool),
        isFalse,
        reason: 'a tool result with no matching call is rejected by providers',
      );
    });

    test('a character budget keeps the most recent turns', () async {
      final session = AgentSession(
        history: <Message>[
          Message.system('sys'),
          Message.user('a' * 100),
          Message.user('b' * 100),
          Message.user('c' * 100),
        ],
        strategy: const CharacterBudgetHistory(maxCharacters: 250),
      );

      final selected = await session.selectHistory();
      expect(selected.first.text, 'sys');
      expect(selected.last.text, 'c' * 100);
      expect(selected.length, lessThan(4));
    });

    test('setSystemPrompt replaces instructions in place', () {
      final session = AgentSession(
        history: <Message>[Message.system('old'), Message.user('hi')],
      )..setSystemPrompt('new');

      expect(session.history.first.text, 'new');
      expect(session.history, hasLength(2));
    });

    test('round-trips through JSON', () async {
      final model = FakeChatModel.text('ok');
      final agent = ToolCallingAgent(info: infoFor('assistant'), model: model);
      final session = AgentSession(id: 'session-1');
      await agent.run(AgentInput.text('hi'), session: session);

      final restored = AgentSession.fromJson(session.toJson());

      expect(restored.id, 'session-1');
      expect(restored.history.length, session.history.length);
      expect(restored.runCount, 1);
      expect(restored.totalUsage.totalTokens, 15);
    });
  });

  group('observability', () {
    test('publishes run, step and completion events', () async {
      final bus = BroadcastEventBus();
      final tools = searchRegistry();
      final agent = ToolCallingAgent(
        info: infoFor('researcher'),
        model: FakeChatModel.toolCall(
          toolCalls: [
            callTo('search_web', arguments: {'query': 'x'}),
          ],
        ),
        tools: tools.registry.all,
      );

      await agent.run(AgentInput.text('go'), context: testContext(events: bus));

      expect(bus.replayBuffer.whereType<AgentRunStarted>(), hasLength(1));
      expect(bus.replayBuffer.whereType<AgentStepCompleted>(), hasLength(2));

      final completed = bus.replayBuffer.whereType<AgentRunCompleted>().single;
      expect(completed.stopReason, AgentStopReason.completed);
      expect(completed.iterations, 2);
      expect(completed.runId, 'run-1');
      await bus.dispose();
    });

    test('publishes a budget-exhausted event worth alerting on', () async {
      final bus = BroadcastEventBus();
      final tools = searchRegistry();
      final agent = ToolCallingAgent(
        info: infoFor('assistant'),
        model: FakeChatModel.toolCall(
          toolCalls: [
            callTo('search_web', arguments: {'query': 'x'}),
          ],
        ),
        tools: tools.registry.all,
        budget: const AgentBudget(maxIterations: 1),
      );

      await agent.run(AgentInput.text('go'), context: testContext(events: bus));

      final event = bus.replayBuffer.whereType<AgentBudgetExhausted>().single;
      expect(event.dimension, BudgetDimension.iterations);
      await bus.dispose();
    });

    test('opens a span with agent attributes', () async {
      final exporter = InMemorySpanExporter();
      final agent = ToolCallingAgent(
        info: infoFor('assistant'),
        model: FakeChatModel.text('ok'),
      );

      await agent.run(
        AgentInput.text('hi'),
        context: testContext(exporter: exporter),
      );

      final span = exporter.named('agent.assistant').single;
      expect(span.attributes['agent.name'], 'assistant');
      expect(span.attributes['agent.iterations'], 1);
      expect(span.status, SpanStatus.ok);
    });
  });

  group('delegation', () {
    test('presents an agent as a tool and runs it', () async {
      final researcher = ToolCallingAgent(
        info: AgentInfo(
          name: 'researcher',
          description: 'Researches topics thoroughly.',
        ),
        model: FakeChatModel.text('Dart 3.11 added dot shorthands.'),
      );

      final registry = ToolRegistry()..register(AgentTool(researcher));
      final supervisorModel = FakeChatModel.toolCall(
        toolCalls: [
          callTo('researcher', arguments: {'task': 'What is new in Dart?'}),
        ],
        then: 'The researcher found dot shorthands.',
      );
      final supervisor = ToolCallingAgent(
        info: infoFor('supervisor'),
        model: supervisorModel,
        tools: registry.all,
      );

      final result = await supervisor.run(AgentInput.text('ask the team'));

      expect(result.text, 'The researcher found dot shorthands.');
      expect(result.allToolCalls.single.name, 'researcher');
    });

    test('a delegate tool is never marked read-only', () {
      // A sub-agent can call anything it has, including tools that write.
      final tool = AgentTool(
        ToolCallingAgent(
          info: infoFor('worker'),
          model: FakeChatModel.text('x'),
        ),
      );

      expect(tool.spec.isReadOnly, isFalse);
      expect(tool.spec.isIdempotent, isFalse);
      expect(tool.spec.tags, contains('delegation'));
    });

    test('refuses to delegate past the depth limit', () async {
      final worker = ToolCallingAgent(
        info: infoFor('worker'),
        model: FakeChatModel.text('done'),
      );
      final tool = AgentTool(worker, maxDepth: 1);

      final result = await tool.call(
        ToolInvocation(
          callId: 'c1',
          toolName: 'worker',
          arguments: const <String, Object?>{'task': 'go'},
          // Already one level deep.
          context: AgenticContext.root(
            metadata: const <String, Object?>{kDelegationDepthKey: 1},
          ),
        ),
      );

      expect(result.isError, isTrue);
      expect(result.content, contains('limit'));
    });

    test('publishes a delegation event carrying the depth', () async {
      final bus = BroadcastEventBus();
      final tool = AgentTool(
        ToolCallingAgent(
          info: infoFor('worker'),
          model: FakeChatModel.text('done'),
        ),
      );

      await tool.call(
        ToolInvocation(
          callId: 'c1',
          toolName: 'worker',
          arguments: const <String, Object?>{'task': 'go'},
          context: testContext(events: bus),
        ),
      );

      final event = bus.replayBuffer.whereType<AgentDelegated>().single;
      expect(event.delegateName, 'worker');
      expect(event.depth, 1);
      await bus.dispose();
    });

    test('reports a delegate failure back to the supervisor', () async {
      final failing = ToolCallingAgent(
        info: infoFor('worker'),
        model: FakeChatModel.failing(
          ProviderException('down', provider: 'test', statusCode: 400),
        ),
      );

      final result = await AgentTool(failing).call(
        ToolInvocation(
          callId: 'c1',
          toolName: 'worker',
          arguments: const <String, Object?>{'task': 'go'},
          context: AgenticContext.root(),
        ),
      );

      expect(result.isError, isTrue);
      expect(result.content, contains('did not finish'));
    });

    test('reports the sub-run cost so a parent can account for it', () async {
      final tool = AgentTool(
        ToolCallingAgent(
          info: infoFor('worker'),
          model: FakeChatModel.text('done'),
        ),
      );

      final result = await tool.call(
        ToolInvocation(
          callId: 'c1',
          toolName: 'worker',
          arguments: const <String, Object?>{'task': 'go'},
          context: AgenticContext.root(),
        ),
      );

      expect(result.metadata['delegate'], 'worker');
      expect(result.metadata['tokens'], 15);
    });

    test('supervisorOver builds an ordinary agent over the team', () async {
      final supervisor = supervisorOver(
        model: FakeChatModel.text('Coordinated.'),
        members: <Agent>[
          ToolCallingAgent(
            info: AgentInfo(name: 'researcher', description: 'Researches.'),
            model: FakeChatModel.text('found'),
          ),
          ToolCallingAgent(
            info: AgentInfo(name: 'writer', description: 'Writes.'),
            model: FakeChatModel.text('written'),
          ),
        ],
      );

      final result = await supervisor.run(AgentInput.text('do it'));

      expect(result.text, 'Coordinated.');
      expect(supervisor.info.name, 'supervisor');
    });

    test('supervisorOver rejects an empty team', () {
      expect(
        () => supervisorOver(
          model: FakeChatModel.text('x'),
          members: const <Agent>[],
        ),
        throwsA(isA<ConfigurationException>()),
      );
    });
  });

  group('PlannerExecutorAgent', () {
    ChatResponse planOf(String json) =>
        ChatResponse(message: Message.assistant(json), modelId: 'planner');

    test('plans, executes each step in isolation, then synthesises', () async {
      final planner = FakeChatModel(
        turns: <FakeTurn>[
          FakeTurn.answer(
            planOf(
              '{"summary":"Look both up",'
              '"steps":[{"description":"Research Dart 3.11"},'
              '{"description":"Research Flutter 3.41"}]}',
            ),
          ),
          FakeTurn.answer(
            ChatResponse(
              message: Message.assistant('Both shipped in early 2026.'),
              modelId: 'planner',
            ),
          ),
        ],
      );
      final worker = FakeChatModel.text('a finding');
      final agent = PlannerExecutorAgent(
        info: infoFor('analyst'),
        planner: planner,
        executor: ToolCallingAgent(info: infoFor('worker'), model: worker),
      );

      final result = await agent.run(AgentInput.text('compare the releases'));

      expect(result.text, 'Both shipped in early 2026.');
      expect(result.stopReason, AgentStopReason.completed);
      expect(worker.callCount, 2, reason: 'one run per plan step');

      // Each step ran with a clean context rather than the accumulating one.
      expect(worker.requests.first.messages, hasLength(1));
      expect(worker.requests.last.messages, hasLength(1));

      final plan = result.metadata['plan']! as Map<String, Object?>;
      expect(plan['steps']! as List, hasLength(2));
    });

    test('emits plan chunks while streaming', () async {
      final planner = FakeChatModel(
        turns: <FakeTurn>[
          FakeTurn.answer(planOf('{"steps":[{"description":"One step"}]}')),
          FakeTurn.answer(
            ChatResponse(
              message: Message.assistant('Done.'),
              modelId: 'planner',
            ),
          ),
        ],
      );
      final agent = PlannerExecutorAgent(
        info: infoFor('analyst'),
        planner: planner,
        executor: ToolCallingAgent(
          info: infoFor('worker'),
          model: FakeChatModel.text('finding'),
        ),
      );

      final chunks = await agent.stream(AgentInput.text('go')).toList();

      expect(
        chunks.whereType<AgentPlanReady>().single.plan.steps,
        hasLength(1),
      );
      expect(chunks.whereType<AgentPlanStepStarted>().single.total, 1);
      expect(chunks.last, isA<AgentFinished>());
    });

    test('answers directly when the planner returns no steps', () async {
      // A planner that invents busywork for "what is 2 + 2" is worse than one
      // that says none is needed.
      final planner = FakeChatModel(
        turns: <FakeTurn>[
          FakeTurn.answer(planOf('{"steps":[]}')),
          FakeTurn.answer(
            ChatResponse(message: Message.assistant('4'), modelId: 'planner'),
          ),
        ],
      );
      final worker = FakeChatModel.text('unused');
      final agent = PlannerExecutorAgent(
        info: infoFor('analyst'),
        planner: planner,
        executor: ToolCallingAgent(info: infoFor('worker'), model: worker),
      );

      final result = await agent.run(AgentInput.text('what is 2 + 2'));

      expect(result.text, '4');
      expect(worker.callCount, 0);
    });

    test('bounds the plan size', () {
      final schema = Plan.schemaFor(maxSteps: 3);

      expect(
        schema.validate(<String, Object?>{
          'steps': <Object?>[
            for (var i = 0; i < 4; i++)
              <String, Object?>{'description': 'step $i'},
          ],
        }).isValid,
        isFalse,
        reason: 'a planner must not turn one request into forty sub-runs',
      );
    });

    test('reports a planner failure as a failed result', () async {
      final agent = PlannerExecutorAgent(
        info: infoFor('analyst'),
        planner: FakeChatModel.failing(
          ProviderException('down', provider: 'test', statusCode: 500),
        ),
        executor: ToolCallingAgent(
          info: infoFor('worker'),
          model: FakeChatModel.text('x'),
        ),
      );

      final result = await agent.run(AgentInput.text('go'));

      expect(result.stopReason, AgentStopReason.failed);
      expect(result.error, isA<ProviderException>());
    });
  });

  group('AgentResult', () {
    test('serialises the trail', () async {
      final tools = searchRegistry();
      final agent = ToolCallingAgent(
        info: infoFor('researcher'),
        model: FakeChatModel.toolCall(
          toolCalls: [
            callTo('search_web', arguments: {'query': 'dart'}),
          ],
        ),
        tools: tools.registry.all,
      );

      final json = (await agent.run(AgentInput.text('go'))).toJson();

      expect(json['stopReason'], 'completed');
      expect(json['iterations'], 2);
      expect(json['steps']! as List, hasLength(2));
    });

    test('decodes a structured answer', () async {
      final agent = ToolCallingAgent(
        info: infoFor('extractor'),
        model: FakeChatModel.text('{"city":"Paris"}'),
      );

      final result = await agent.run(AgentInput.text('extract'));

      expect(result.decodeJson()['city'], 'Paris');
    });
  });
}
