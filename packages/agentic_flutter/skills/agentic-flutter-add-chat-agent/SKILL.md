---
name: agentic-flutter-add-chat-agent
description: >-
  Use when adding an AI chat agent to a Flutter app with agentic_flutter:
  wiring AgenticRuntime and AgenticScope, building a ToolCallingAgent,
  driving it with AgentChatController and AgentChatView, asking the user to
  approve tool calls through a sheet, keeping the API key out of the binary,
  and stopping runs when the app is backgrounded. Covers the first screen of a
  new agentic app and adding chat to an existing one.
license: MIT
metadata:
  package: agentic_flutter
  min-version: 0.2.0
---

# Add a chat agent to a Flutter app

`agentic_flutter` re-exports the whole framework, so one import is enough:

```dart
import 'package:agentic_flutter/agentic_flutter.dart';
```

## 1. One runtime for the app's lifetime

`AgenticRuntime` owns the tool registry, event bus, logger, tracer and clock.
Create it once in `main`, put it above the widgets that use it, and read it with
`context.agentic`.

```dart
void main() {
  final tools = ToolRegistry()..register(weatherTool);

  final runtime = AgenticRuntime(
    tools: tools,
    logLevel: LogLevel.debug,
    // On a phone this is the setting that decides whether a forgotten
    // conversation keeps billing after the user swipes away.
    backgroundPolicy: BackgroundPolicy.cancelOnPause,
  );

  runApp(AgenticScope(runtime: runtime, child: const MyApp()));
}
```

`AgenticScope.of(context)` / `context.agentic` gives any descendant the runtime;
`context.agenticTools` and `context.agenticEvents` are shortcuts.

## 2. The agent

```dart
final agent = ToolCallingAgent(
  info: AgentInfo(
    name: 'assistant',
    description: 'Answers questions using the tools it has.',
  ),
  model: GeminiChatModel(apiKey: key, model: 'gemini-3.8-flash'),
  tools: runtime.tools.all,
  instructions: 'Use the tools when they help. Say plainly when you do not know.',
  // Budgets are required by design: an agent that loops is the characteristic
  // failure of this architecture.
  budget: AgentBudget.interactive,
  // Without a handler, any tool needing approval is denied and the model is
  // told nobody could be asked.
  approvalHandler: sheetApprovalHandler(navigatorKey: navigatorKey),
);
```

`navigatorKey` is a `GlobalKey<NavigatorState>` on your `MaterialApp`. Approval
is requested from inside the agent loop, long after the widget that started the
run may have been unmounted, so a navigator key — not a `BuildContext` — is what
is still valid at that moment.

## 3. The chat screen

`AgentChatController` is a `ChangeNotifier`; `AgentChatView` renders it.

```dart
class _ChatScreenState extends State<ChatScreen> {
  late final AgentChatController _chat;
  var _wired = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_wired) return;
    _wired = true;
    _chat = AgentChatController(runtime: context.agentic, agent: agent);
  }

  @override
  void dispose() {
    _chat.dispose();          // cancels an in-flight run
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Assistant')),
    body: AgentChatView(
      controller: _chat,
      hintText: 'Ask me anything',
      emptyState: const Text('Ask about the weather, or set a reminder.'),
    ),
  );
}
```

`_chat.send(text)` sends a turn, `_chat.entries` is the transcript,
`_chat.isBusy` and `_chat.activity` drive your own UI, `_chat.cancel()` stops the
run, `_chat.clear()` starts a new conversation. Pass `entryBuilder:` to
`AgentChatView` to render entries yourself.

## 4. The API key

A key compiled into an app is a key you have published — anyone can unzip the
binary. `SecretStore` is the seam:

```dart
final secrets = LayeredSecretStore([
  InMemorySecretStore(),                      // writable, gone when the process ends
  const DartDefineSecretStore(                // debug convenience only
    values: {'GEMINI_API_KEY': String.fromEnvironment('GEMINI_API_KEY')},
  ),
]);
final key = await secrets.require('GEMINI_API_KEY');
```

`String.fromEnvironment` must be written at the call site — it is const and
resolved by the compiler, so no library can look it up for you.

For production, either let the user paste their own key (store it with
`flutter_secure_storage` behind your own `SecretStore`), or put a backend you
authenticate to between the app and the provider. Say which one you chose in
code review.

## 5. Watching what happened

```dart
final recorder = EventRecorder(context.agenticEvents)..start();
// … later, in a debug screen:
TraceInspector(recorder: recorder);
```

Stop and dispose the recorder with the screen; an unbounded recorder is a memory
leak with a debug panel attached.

## Running with no key at all

`FakeChatModel` from `package:agentic_llm/testing.dart` scripts answers and tool
calls, so the app runs offline and identically every time. Start there: the only
line that changes later is the model.

## Common mistakes

- Creating the runtime or agent inside `build` — it is rebuilt on every frame.
  Create in `main`, or once in `didChangeDependencies`.
- Forgetting `_chat.dispose()`, which leaves a run streaming into a dead widget.
- Passing a `BuildContext` to the approval handler instead of a navigator key.
- `BackgroundPolicy.keepRunning` on a phone without a reason: runs continue while
  the app is in the background, and so does the billing.
- Shipping `DartDefineSecretStore` values in a release build.

## See also

- `agentic-flutter-tool-approval-ui` — the approval sheet in detail
- `agentic-flutter-secrets-and-keys` — every option for the key, with trade-offs
- `agentic-tools-write-a-tool` — writing the tools the agent calls
- `agentic-agents-budgets` — choosing budgets that fit your screen
