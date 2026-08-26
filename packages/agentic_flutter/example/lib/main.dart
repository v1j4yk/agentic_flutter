// A working chat app built on agentic_flutter.
//
//   cd example && flutter run
//
// It runs offline against a scripted model, so it behaves the same every time
// and needs no API key. Replace `FakeChatModel` with a real adapter and nothing
// else in this file changes.
import 'package:agentic_flutter/agentic_flutter.dart';
import 'package:agentic_llm/testing.dart';
import 'package:flutter/material.dart';

final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

void main() {
  // ---------------------------------------------------------------------------
  // 1. Tools. One is read-only; one changes something and needs a person.
  // ---------------------------------------------------------------------------
  final tools = ToolRegistry()
    ..register(
      FunctionTool.text(
        name: 'city_weather',
        description: 'Returns the current weather for a city.',
        parameters: JsonSchema.object(
          properties: <String, JsonSchema>{
            'city': JsonSchema.string(description: 'The city to look up.'),
          },
          required: const <String>{'city'},
        ),
        handler: (invocation) async =>
            '${invocation.require<String>('city')}: 18°C, light rain.',
      ),
    )
    ..register(
      FunctionTool.text(
        name: 'set_reminder',
        description: 'Creates a reminder on the device.',
        parameters: JsonSchema.object(
          properties: <String, JsonSchema>{
            'text': JsonSchema.string(description: 'What to be reminded of.'),
          },
          required: const <String>{'text'},
        ),
        // Not read-only, and gated: the approval sheet will ask before it runs.
        isReadOnly: false,
        requiresApproval: true,
        handler: (invocation) async =>
            'Reminder set: ${invocation.require<String>('text')}',
      ),
    )
    // A device capability over a callback. In a real app the callback calls a
    // plugin; here it returns a fixed answer so the example runs anywhere.
    ..register(
      locationTool(
        read: () async => const DeviceLocation(
          latitude: 51.5072,
          longitude: -0.1276,
          accuracyMetres: 15,
          placeName: 'London',
        ),
      ),
    );

  // ---------------------------------------------------------------------------
  // 2. One runtime for the app's lifetime.
  // ---------------------------------------------------------------------------
  final runtime = AgenticRuntime(
    tools: tools,
    logLevel: LogLevel.debug,
    // Runs stop when the app leaves the screen. On a phone this is the setting
    // that decides whether a forgotten conversation keeps billing.
    backgroundPolicy: BackgroundPolicy.cancelOnPause,
  );

  runApp(AgenticScope(runtime: runtime, child: const ExampleApp()));
}

class ExampleApp extends StatelessWidget {
  const ExampleApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'agentic_flutter',
    navigatorKey: navigatorKey,
    theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true),
    home: const ChatScreen(),
  );
}

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  late final AgentChatController _chat;
  late final EventRecorder _recorder;
  bool _wired = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_wired) return;
    _wired = true;

    final runtime = context.agentic;

    _chat = AgentChatController(
      runtime: runtime,
      agent: ToolCallingAgent(
        info: AgentInfo(
          name: 'assistant',
          description: 'Answers questions using the tools it has.',
        ),
        model: _scriptedModel(),
        tools: runtime.tools.all,
        instructions:
            'Use the tools when they help. Say plainly when you do not know.',
        // Approval is asked through a sheet. Without a handler the executor
        // denies gated tools outright, which is the safe default rather than a
        // bug to work around.
        executor: ToolExecutor(
          tools: runtime.tools.all,
          approvalHandler: sheetApprovalHandler(navigatorKey: navigatorKey),
        ),
      ),
    );

    _recorder = EventRecorder(runtime.events, capacity: 200)..start();
  }

  @override
  void dispose() {
    _chat.dispose();
    _recorder.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('agentic_flutter'),
      actions: <Widget>[
        IconButton(
          icon: const Icon(Icons.bug_report_outlined),
          tooltip: 'Trace',
          onPressed: () => showModalBottomSheet<void>(
            context: context,
            isScrollControlled: true,
            builder: (_) => SizedBox(
              height: MediaQuery.sizeOf(context).height * 0.7,
              child: TraceInspector(recorder: _recorder),
            ),
          ),
        ),
        IconButton(
          icon: const Icon(Icons.delete_outline),
          tooltip: 'Clear',
          onPressed: _chat.clear,
        ),
      ],
    ),
    body: AgentChatView(
      controller: _chat,
      hintText: 'Ask about the weather, or set a reminder',
      emptyState: const Padding(
        padding: EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.chat_bubble_outline, size: 40),
            SizedBox(height: 12),
            Text(
              'Try "what is the weather in Lisbon?" — it will call a tool.\n'
              'Then try "remind me to call Ada" — that one asks first.',
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    ),
  );
}

/// A model that answers from a script, so the example runs with no key.
///
/// Every turn is scripted in order: a tool call, then an answer, and so on.
/// Swap this for `OpenAiCompatibleChatModel.openAi(apiKey: key)` and the rest
/// of the app is unchanged — which is the point of the `ChatModel` port.
ChatModel _scriptedModel() => FakeChatModel(
  turns: <FakeTurn>[
    // Turn one: the model decides to call a tool.
    FakeTurn.answer(
      ChatResponse(
        message: Message.assistant(
          '',
          toolCalls: <ToolCallPart>[
            ToolCallPart(
              id: 'c1',
              name: 'city_weather',
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
        message: Message.assistant(
          'It is 18°C with light rain in Lisbon right now.',
        ),
        modelId: 'scripted',
      ),
    ),
    // Turn two: a gated tool, so the approval sheet appears.
    FakeTurn.answer(
      ChatResponse(
        message: Message.assistant(
          '',
          toolCalls: <ToolCallPart>[
            ToolCallPart(
              id: 'c2',
              name: 'set_reminder',
              arguments: const <String, Object?>{'text': 'Call Ada'},
            ),
          ],
        ),
        modelId: 'scripted',
        finishReason: FinishReason.toolCalls,
      ),
    ),
    // The last turn repeats once the script runs out, so the app stays usable
    // rather than throwing at the end of the demo.
    FakeTurn.answer(
      ChatResponse(
        message: Message.assistant(
          'Done. That is the end of the script — swap in a real model to keep '
          'going.',
        ),
        modelId: 'scripted',
      ),
    ),
  ],
);
