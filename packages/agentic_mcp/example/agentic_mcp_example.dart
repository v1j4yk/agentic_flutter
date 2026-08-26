// Demonstrates both directions of MCP: publishing your own tools as a server,
// and consuming a server's tools as ordinary framework tools an agent runs.
//
// Run it with:
//
//     dart run example/agentic_mcp_example.dart
//
// It runs offline. Client and server are connected by an in-process transport,
// which is exactly what a plugin architecture inside one app would use; swap in
// `McpHttpTransport` or `StdioTransport` and nothing else changes.
import 'package:agentic_agents/agentic_agents.dart';
import 'package:agentic_core/agentic_core.dart';
import 'package:agentic_llm/agentic_llm.dart';
import 'package:agentic_llm/testing.dart';
import 'package:agentic_mcp/agentic_mcp.dart';
import 'package:agentic_tools/agentic_tools.dart';

Future<void> main() async {
  // ---------------------------------------------------------------------------
  // 1. Publish an application's tools over MCP.
  // ---------------------------------------------------------------------------
  print('--- serving ---');
  final published = ToolRegistry()
    ..register(
      FunctionTool.text(
        name: 'weather',
        description: 'Returns the current weather for a city.',
        parameters: JsonSchema.object(
          properties: <String, JsonSchema>{
            'city': JsonSchema.string(description: 'The city to look up.'),
          },
          required: const <String>{'city'},
        ),
        handler: (invocation) async {
          final city = invocation.require<String>('city');
          return '$city: 18°C, light rain.';
        },
      ),
    )
    ..register(
      FunctionTool.text(
        name: 'shutdown_datacentre',
        description: 'Powers down a datacentre.',
        isReadOnly: false,
        requiresApproval: true,
        handler: (invocation) async => 'lights out',
      ),
    );

  final (clientSide, serverSide) = InMemoryTransport.pair();
  final server = McpServer(
    transport: serverSide,
    registry: published,
    serverInfo: const McpImplementation(name: 'ops-tools', version: '1.0.0'),
    instructions: 'Ask about weather before scheduling anything outdoors.',
  );
  await server.start();

  print('registry   : ${published.all.names.join(', ')}');
  print('published  : ${server.publishedTools.map((s) => s.name).join(', ')}');
  print(
    'withheld   : shutdown_datacentre — it needs a person to approve it, and\n'
    '             there is no person on the far end of a socket.',
  );

  // ---------------------------------------------------------------------------
  // 2. Connect a client and negotiate the session.
  // ---------------------------------------------------------------------------
  print('\n--- connecting ---');
  final bus = BroadcastEventBus();
  final context = AgenticContext.root(events: bus);
  final client = McpClient(transport: clientSide, context: context);

  final session = await client.initialize();
  print('server     : ${session.server} (${session.protocolVersion})');
  print('capabilities: ${session.capabilities}');
  print('instructions: ${session.instructions}');

  // ---------------------------------------------------------------------------
  // 3. Its tools become ordinary tools. Nothing above this line knows about MCP.
  // ---------------------------------------------------------------------------
  print('\n--- adopting the tools ---');
  final registry = ToolRegistry();
  final names = await registerMcpTools(
    client,
    registry,
    prefix: 'ops',
    context: context,
  );
  print('registered : ${names.join(', ')}');

  final spec = registry.specOf('ops_weather')!;
  print('description: ${spec.description}');
  print('read-only  : ${spec.isReadOnly}   approval: ${spec.requiresApproval}');

  // ---------------------------------------------------------------------------
  // 4. An agent uses them without knowing where they came from.
  // ---------------------------------------------------------------------------
  print('\n--- an agent uses them ---');
  final agent = ToolCallingAgent(
    model: FakeChatModel(
      turns: <FakeTurn>[
        FakeTurn.answer(
          ChatResponse(
            message: Message.assistant(
              '',
              toolCalls: <ToolCallPart>[
                ToolCallPart(
                  id: 'call-1',
                  name: 'ops_weather',
                  arguments: const <String, Object?>{'city': 'Lisbon'},
                ),
              ],
            ),
            modelId: 'scripted',
            finishReason: FinishReason.toolCalls,
          ),
        ),
        FakeTurn.answer(
          ChatResponse(
            message: Message.assistant('It is 18°C and raining in Lisbon.'),
            modelId: 'scripted',
          ),
        ),
      ],
    ),
    tools: registry.all,
    info: AgentInfo(name: 'planner', description: 'Plans outdoor work.'),
  );

  final answer = await agent.run(
    AgentInput.text('What is the weather in Lisbon?'),
    context: context,
  );
  print('answer     : ${answer.text}');
  print('iterations : ${answer.iterations}');

  // ---------------------------------------------------------------------------
  // 5. A tool that fails is a failure the model can see, not a dead run.
  // ---------------------------------------------------------------------------
  print('\n--- failure handling ---');
  final failing = await registry
      .resolve('ops_weather')
      .call(
        ToolInvocation(
          callId: 'call-2',
          toolName: 'ops_weather',
          // No city: the executor would normally reject this, but calling the tool
          // directly shows what the server does with it.
          arguments: const <String, Object?>{},
          context: context,
        ),
      );
  print('isError    : ${failing.isError}');
  print('content    : ${failing.content}');

  // ---------------------------------------------------------------------------
  // 6. The server tells the client when its tools change.
  // ---------------------------------------------------------------------------
  print('\n--- live updates ---');
  client.notifications.listen((n) => print('notification: ${n.method}'));

  published.register(
    FunctionTool.text(
      name: 'forecast',
      description: 'Returns a five-day forecast.',
      handler: (invocation) async => 'Rain, then more rain.',
    ),
  );
  await server.notifyToolsChanged();
  await Future<void>.delayed(Duration.zero);

  final refreshed = await client.listTools();
  print('now offers : ${refreshed.map((t) => t.name).join(', ')}');

  // ---------------------------------------------------------------------------
  // 7. Observability.
  // ---------------------------------------------------------------------------
  print('\n--- observability ---');
  for (final event in bus.replayBuffer.whereType<McpEvent>()) {
    print(event);
  }

  await bus.dispose();
  await client.dispose();
  await server.dispose();
}
