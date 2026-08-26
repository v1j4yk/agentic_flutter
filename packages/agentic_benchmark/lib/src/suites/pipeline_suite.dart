/// What the framework costs on top of the model.
///
/// # The only number that matters here
///
/// A real turn is dominated by the provider: hundreds of milliseconds of
/// network and inference. Everything measured in this file happens around that
/// call, and the question worth asking is not "is it fast" but "is it small
/// enough to disappear next to the model".
///
/// The rule of thumb this suite exists to defend: framework overhead per agent
/// step should stay under about a millisecond. At that scale it is a rounding
/// error against a 400 ms completion. At ten it is a tax on every turn, and at
/// a hundred it is a bug.
library;

import 'package:agentic_agents/agentic_agents.dart';
import 'package:agentic_benchmark/src/harness.dart';
import 'package:agentic_core/agentic_core.dart';
import 'package:agentic_llm/agentic_llm.dart';
import 'package:agentic_llm/testing.dart';
import 'package:agentic_mcp/agentic_mcp.dart';
import 'package:agentic_tools/agentic_tools.dart';

BenchmarkSuite toolsSuite() => BenchmarkSuite(
  name: 'tools',
  benchmarks: <Benchmark<Object?>>[
    Benchmark<ToolExecutor>(
      name: 'tools.execute.trivial',
      description:
          'Running a tool that returns immediately. Everything measured is '
          'framework overhead: lookup, coercion, validation, tracing, events.',
      setup: () => ToolExecutor(tools: _registry().all),
      run: (executor) => executor.execute(
        ToolCallPart(
          id: 'c1',
          name: 'echo',
          arguments: const <String, Object?>{'text': 'hello'},
        ),
        context: _context,
      ),
      iterations: 1000,
      warmup: 100,
    ),
    Benchmark<ToolExecutor>(
      name: 'tools.execute.rejected',
      description:
          'A call whose arguments do not validate. The failure path is the one '
          'a model exercises repeatedly while it learns a schema, so it must '
          'not be the slow one.',
      setup: () => ToolExecutor(tools: _registry().all),
      run: (executor) => executor.execute(
        ToolCallPart(
          id: 'c1',
          name: 'echo',
          arguments: const <String, Object?>{},
        ),
        context: _context,
      ),
      iterations: 1000,
      warmup: 100,
    ),
    Benchmark<ToolExecutor>(
      name: 'tools.executeAll.8parallel',
      description:
          'Eight read-only calls in one batch. Read-only calls run '
          'concurrently, so this measures the scheduling rather than the work.',
      setup: () => ToolExecutor(tools: _registry().all),
      run: (executor) => executor.executeAll(<ToolCallPart>[
        for (var i = 0; i < 8; i++)
          ToolCallPart(
            id: 'c$i',
            name: 'echo',
            arguments: <String, Object?>{'text': 'call $i'},
          ),
      ], context: _context),
      iterations: 300,
      warmup: 30,
      unit: '8 calls',
    ),
  ],
);

BenchmarkSuite llmSuite() => BenchmarkSuite(
  name: 'llm',
  benchmarks: <Benchmark<Object?>>[
    Benchmark<List<ChatChunk>>(
      name: 'llm.stream.assemble.500chunks',
      description:
          'Assembling five hundred streamed deltas into one response, '
          'including reassembling fragmented tool-call JSON. Runs on the UI '
          'isolate while text is arriving, so it competes with frame budget.',
      setup: () => <ChatChunk>[
        for (var i = 0; i < 500; i++) ChatChunk(textDelta: 'token $i '),
      ],
      run: (chunks) => ChatResponseBuilder(modelId: 'bench')
        ..addAll(chunks)
        ..build(),
      iterations: 300,
      warmup: 30,
      unit: '500 chunks',
    ),
    Benchmark<String>(
      name: 'llm.sse.decode.500events',
      description:
          'Decoding five hundred server-sent events from a byte stream, '
          'including the chunk-boundary handling that makes it correct.',
      setup: () => <String>[
        for (var i = 0; i < 500; i++) 'data: {"delta":"token $i"}\n\n',
      ].join(),
      run: (payload) => decodeServerSentEvents(
        Stream<List<int>>.value(payload.codeUnits),
      ).toList(),
      iterations: 200,
      warmup: 20,
      unit: '500 events',
    ),
  ],
);

BenchmarkSuite agentsSuite() => BenchmarkSuite(
  name: 'agents',
  benchmarks: <Benchmark<Object?>>[
    Benchmark<Agent>(
      name: 'agents.turn.noTools',
      description:
          'A whole agent turn against a model that answers instantly. The '
          'framework overhead of one step, with the provider taken out.',
      setup: () => ToolCallingAgent(
        info: AgentInfo(name: 'bench', description: 'Benchmark agent.'),
        model: FakeChatModel.text('An answer.'),
      ),
      run: (agent) => agent.run(AgentInput.text('question'), context: _context),
      iterations: 500,
      warmup: 50,
    ),
    Benchmark<Agent>(
      name: 'agents.turn.oneToolCall',
      description:
          'A turn that calls one tool and then answers: two model calls, one '
          'tool execution, and the history bookkeeping between them.',
      setup: () {
        final registry = _registry();
        return ToolCallingAgent(
          info: AgentInfo(name: 'bench', description: 'Benchmark agent.'),
          model: FakeChatModel(
            turns: <FakeTurn>[
              FakeTurn.answer(
                ChatResponse(
                  message: Message.assistant(
                    '',
                    toolCalls: <ToolCallPart>[
                      ToolCallPart(
                        id: 'c1',
                        name: 'echo',
                        arguments: const <String, Object?>{'text': 'hi'},
                      ),
                    ],
                  ),
                  modelId: 'bench',
                  finishReason: FinishReason.toolCalls,
                ),
              ),
              FakeTurn.answer(
                ChatResponse(
                  message: Message.assistant('An answer.'),
                  modelId: 'bench',
                ),
              ),
            ],
          ),
          tools: registry.all,
        );
      },
      run: (agent) => agent.run(AgentInput.text('question'), context: _context),
      iterations: 300,
      warmup: 30,
    ),
    Benchmark<AgentSession>(
      name: 'agents.session.select.100messages',
      description:
          'Choosing what history to send with a hundred messages already in '
          'the session. Runs before every model call, and grows with the '
          'conversation — which is exactly when a user is least patient.',
      setup: () {
        final session = AgentSession();
        for (var i = 0; i < 50; i++) {
          session
            ..add(Message.user('Question number $i about the project.'))
            ..add(Message.assistant('Answer number $i, at some length.'));
        }
        return session;
      },
      run: (session) => session.strategy.select(
        session.history,
        pending: Message.user('the next question'),
        context: _context,
      ),
      iterations: 500,
      warmup: 50,
    ),
  ],
);

BenchmarkSuite mcpSuite() => BenchmarkSuite(
  name: 'mcp',
  benchmarks: <Benchmark<Object?>>[
    // `McpServer` is marked experimental; benchmarking it is deliberate. A
    // number attached to an API that is still moving is part of what makes the
    // shape it settles into affordable.
    // ignore: experimental_member_use
    Benchmark<({McpClient client, McpServer server})>(
      name: 'mcp.tool.call.roundtrip',
      description:
          'One tool call across an MCP boundary, in process. Isolates the '
          'protocol cost — framing, correlation, translation — from the '
          'transport, which in a real deployment dominates it.',
      setup: () async {
        final (clientSide, serverSide) = InMemoryTransport.pair();
        // ignore: experimental_member_use
        final server = McpServer(
          transport: serverSide,
          registry: _registry(),
          serverInfo: const McpImplementation(name: 'bench', version: '1.0.0'),
        );
        await server.start();
        final client = McpClient(transport: clientSide);
        await client.initialize();
        return (client: client, server: server);
      },
      teardown: (pair) async {
        await pair.client.dispose();
        await pair.server.dispose();
      },
      run: (pair) => pair.client.callTool(
        'echo',
        arguments: const <String, Object?>{'text': 'hello'},
      ),
      iterations: 500,
      warmup: 50,
    ),
  ],
);

/// A context with observability on, because that is how the framework ships.
///
/// Benchmarking with a silent logger and a no-op bus would measure a
/// configuration nobody runs.
final AgenticContext _context = AgenticContext.root(
  events: BroadcastEventBus(),
);

ToolRegistry _registry() => ToolRegistry()
  ..register(
    FunctionTool.text(
      name: 'echo',
      description: 'Returns what it is given.',
      parameters: JsonSchema.object(
        properties: <String, JsonSchema>{'text': JsonSchema.string()},
        required: const <String>{'text'},
      ),
      handler: (invocation) async => invocation.require<String>('text'),
    ),
  );
