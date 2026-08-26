/// The files a new project starts with.
///
/// # Why these are string constants and not asset files
///
/// A globally-activated CLI can read its own package assets, but only through
/// `Isolate.resolvePackageUri`, which behaves differently under `pub global
/// run`, a compiled snapshot and a plain `dart run`. Constants compile in and
/// work identically in all three.
///
/// The cost is real and worth naming: template code is not itself analysed. A
/// template that does not compile is the classic failure of every scaffolding
/// tool, so CI generates a project and runs `flutter analyze` and `flutter test`
/// over the result. That job is the only thing keeping these strings honest.
///
/// # Why raw strings
///
/// Every template is `r'''...'''`, so a `$` in the generated Dart stays a `$`.
/// Substitution is by `__PLACEHOLDER__` instead. Escaping interpolation by hand
/// across a thousand lines of template is how a generator ends up emitting
/// `${name}` into somebody's source file.
library;

import 'package:create_agentic_app/src/project_name.dart';

/// Which provider a generated project is wired for.
enum TemplateProvider {
  /// OpenAI, and everything that speaks its format.
  openai('OPENAI_API_KEY', 'OpenAI'),

  /// Anthropic's Claude.
  anthropic('ANTHROPIC_API_KEY', 'Anthropic'),

  /// Google's Gemini.
  gemini('GEMINI_API_KEY', 'Gemini'),

  /// A model running locally, which needs no key at all.
  ollama('OLLAMA_MODEL', 'Ollama');

  const TemplateProvider(this.keyName, this.label);

  /// The name the key is stored under.
  final String keyName;

  /// How the provider is described to a person.
  final String label;

  /// The indefinite article that belongs in front of [label].
  ///
  /// Written out per provider rather than derived from the first letter: the
  /// rule is about sound, not spelling, and every general-purpose version of it
  /// is wrong somewhere ("an hour", "a user"). With four fixed labels, stating
  /// the answer is both shorter and correct.
  String get article => switch (this) {
    TemplateProvider.openai || TemplateProvider.anthropic => 'an',
    TemplateProvider.gemini || TemplateProvider.ollama => 'a',
  };

  /// Whether this provider needs a secret.
  bool get needsKey => this != TemplateProvider.ollama;

  /// Parses a `--provider` argument.
  static TemplateProvider? parse(String value) {
    for (final provider in TemplateProvider.values) {
      if (provider.name == value) return provider;
    }
    return null;
  }
}

/// Builds every file for a project, keyed by relative path.
///
/// [dependency] is the YAML fragment that pulls in the framework — a version
/// constraint normally, a path during development of the framework itself.
Map<String, String> buildProject({
  required String name,
  required TemplateProvider provider,
  required String dependency,
}) {
  String fill(String template) => template
      .replaceAll('__NAME__', name)
      .replaceAll('__TITLE__', titleFor(name))
      .replaceAll('__DEPENDENCY__', dependency)
      .replaceAll('__KEY_NAME__', provider.keyName)
      .replaceAll('__PROVIDER_ARTICLE__', provider.article)
      .replaceAll('__PROVIDER_LABEL__', provider.label)
      .replaceAll('__MODEL_IMPORT__', _modelImport(provider))
      .replaceAll('__MODEL_CONSTRUCTION__', _modelConstruction(provider));

  return <String, String>{
    'pubspec.yaml': fill(_pubspec),
    'analysis_options.yaml': _analysisOptions,
    '.gitignore': _gitignore,
    'README.md': fill(_readme),
    'lib/main.dart': fill(_main),
    'lib/agent.dart': fill(_agent),
    'lib/tools.dart': fill(_tools),
    'lib/secrets.dart': fill(_secrets),
    'lib/screens/chat_screen.dart': fill(_chatScreen),
    'lib/screens/settings_screen.dart': fill(_settingsScreen),
    // Named 'widget_test.dart' deliberately. The README tells you to run
    // 'flutter create .' to add platform folders, and that command writes its
    // own counter-app 'test/widget_test.dart' referencing a 'MyApp' this
    // template does not have — but only if the file is absent. Occupying the
    // name is what keeps 'flutter test' green on a freshly generated project.
    'test/widget_test.dart': fill(_appTest),
  };
}

String _modelImport(TemplateProvider provider) => switch (provider) {
  // Every adapter comes through the umbrella, so there is nothing extra to
  // import. Kept as a hook so a provider needing its own package can say so.
  _ => '',
};

String _modelConstruction(TemplateProvider provider) => switch (provider) {
  TemplateProvider.openai =>
    "OpenAiCompatibleChatModel.openAi(apiKey: key, model: 'gpt-4o-mini')",
  TemplateProvider.anthropic =>
    "AnthropicChatModel(apiKey: key, model: 'claude-3-5-haiku-latest')",
  TemplateProvider.gemini =>
    "GeminiChatModel(apiKey: key, model: 'gemini-2.5-flash')",
  // A local model is addressed by name, not by key; `key` holds the model name.
  TemplateProvider.ollama => 'OpenAiCompatibleChatModel.ollama(model: key)',
};

const String _pubspec = r'''
name: __NAME__
description: An agentic app built with the agentic framework.
publish_to: none
version: 0.1.0

environment:
  sdk: ^3.11.0
  flutter: ">=3.41.0"

dependencies:
__DEPENDENCY__
  flutter:
    sdk: flutter

dev_dependencies:
  flutter_lints: ^6.0.0
  flutter_test:
    sdk: flutter

flutter:
  uses-material-design: true
''';

const String _analysisOptions = r'''
include: package:flutter_lints/flutter.yaml

analyzer:
  language:
    strict-casts: true
    strict-inference: true
    strict-raw-types: true
  errors:
    # An agent run that nobody awaits is a run whose failure nobody sees.
    unawaited_futures: error
''';

const String _gitignore = r'''
.dart_tool/
.packages
build/
*.iml
.idea/
.vscode/
.DS_Store

# Never commit an API key. See lib/secrets.dart for where one should live.
.env
*.pem
''';

const String _readme = r'''
# __TITLE__

An agentic app: a chat screen backed by an agent with tools, human approval for
anything that changes something, and a live trace panel.

```sh
flutter run
```

It starts in **demo mode** against a scripted model, so it works immediately
with no key and no network. Tap the key icon, paste __PROVIDER_ARTICLE__ __PROVIDER_LABEL__ key,
and it switches to the real thing.

## Where things are

| File | What it owns |
|---|---|
| `lib/main.dart` | The runtime, the scope, and the app's lifetime |
| `lib/agent.dart` | Which model, which tools, which instructions |
| `lib/tools.dart` | What the agent can do |
| `lib/secrets.dart` | Where the API key lives — read this before shipping |
| `lib/screens/` | The chat and settings screens |

## Before you ship

**The key.** `lib/secrets.dart` keeps it in memory, so it is gone when the app
restarts. That is safe and inconvenient. The two real options are in that file:
put the key behind a service the user authenticates to (the only approach that
is actually safe), or store the user's own key with `flutter_secure_storage`.

A key compiled into the app — in source, in an asset, in `--dart-define` — is a
key you have published. An APK is a zip file.

**The Android internet permission.** After `flutter create .`, add this to
`android/app/src/main/AndroidManifest.xml`, above `<application>`:

```xml
<uses-permission android:name="android.permission.INTERNET"/>
```

Flutter puts it in the *debug* and *profile* manifests only. Everything works
while you develop, and the release build cannot reach any provider — reporting
it as `Failed host lookup`, which sends you to debug DNS rather than a
permission. It is the first thing to check when a release build cannot answer.

**Budgets.** `lib/agent.dart` sets `AgentBudget.interactive`. The characteristic
failure of an agentic app is not a crash; it is a loop that runs correctly and
forever while the bill grows. Keep the bound.

**Approval.** `save_note` in `lib/tools.dart` sets `requiresApproval: true`, so
a sheet asks before it runs. Anything that changes something outside the app
should do the same — and note that the executor *denies* a gated tool when no
approval handler is configured, rather than running it.

## Next

- Add a tool in `lib/tools.dart` — the agent picks it up automatically.
- Give it memory: `RecallingHistory` over an `InMemoryMemoryStore`.
- Give it documents: `RagIndexer` and `RagPipeline`, then `searchTool`.
- Connect an MCP server: `McpClient` plus `registerMcpTools`.
''';

const String _main = r'''
import 'package:agentic_flutter/agentic_flutter.dart';
import 'package:flutter/material.dart';

import 'screens/chat_screen.dart';
import 'secrets.dart';
import 'tools.dart';

/// Approval is requested from inside an agent loop, long after the context that
/// started it may have been unmounted. A navigator key is the thing that is
/// still valid at that moment.
final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

/// Where the API key lives. One instance for the app's lifetime.
final SecretStore secrets = createSecretStore();

void main() {
  final runtime = AgenticRuntime(
    tools: buildTools(),
    logLevel: LogLevel.debug,
    // Runs stop when the app leaves the screen. On a phone this is the setting
    // that decides whether a forgotten conversation keeps billing.
    backgroundPolicy: BackgroundPolicy.cancelOnPause,
  );

  runApp(AgenticScope(runtime: runtime, child: const App()));
}

class App extends StatelessWidget {
  const App({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: '__TITLE__',
        navigatorKey: navigatorKey,
        debugShowCheckedModeBanner: false,
        theme: buildTheme(Brightness.light),
        darkTheme: buildTheme(Brightness.dark),
        home: const ChatScreen(),
      );
}

/// The app's look, in one place.
///
/// Both brightnesses are built from the same seed so the app follows the
/// system setting. A chat app is read for long stretches, often at night, and
/// one that is only ever light is one people put down.
ThemeData buildTheme(Brightness brightness) {
  final scheme = ColorScheme.fromSeed(
    seedColor: const Color(0xFF4F46E5),
    brightness: brightness,
  );
  return ThemeData(
    colorScheme: scheme,
    useMaterial3: true,
    scaffoldBackgroundColor: scheme.surface,
    appBarTheme: AppBarTheme(
      backgroundColor: scheme.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: TextStyle(
        color: scheme.onSurface,
        fontSize: 19,
        fontWeight: FontWeight.w600,
        letterSpacing: -0.2,
      ),
    ),
    // Headline weights that hold up at phone sizes. Material's defaults are
    // tuned for larger surfaces and read thin on a 6-inch screen.
    textTheme: const TextTheme(
      titleMedium: TextStyle(fontWeight: FontWeight.w600),
      labelLarge: TextStyle(fontWeight: FontWeight.w600),
    ),
    dividerTheme: DividerThemeData(
      color: scheme.outlineVariant,
      space: 1,
      thickness: 1,
    ),
  );
}
''';

const String _agent = r'''
import 'package:agentic_flutter/agentic_flutter.dart';
__MODEL_IMPORT__
/// The name the __PROVIDER_LABEL__ key is stored under.
const String kApiKeyName = '__KEY_NAME__';

/// Builds the agent, or returns `null` when there is no key yet.
///
/// Returning `null` rather than throwing: "not configured" is an ordinary state
/// on first launch, not a failure, and the chat screen answers it by offering
/// the settings page.
Future<Agent?> buildAgent({
  required SecretStore secrets,
  required ToolRegistry tools,
  required ToolApprovalHandler approvals,
}) async {
  final key = await secrets.read(kApiKeyName);
  if (key == null || key.isEmpty) return null;

  return ToolCallingAgent(
    info: AgentInfo(
      name: 'assistant',
      description: 'Answers questions using the tools it has.',
    ),
    model: __MODEL_CONSTRUCTION__,
    tools: tools.all,
    instructions:
        'You are a helpful assistant. Use the tools when they help. '
        'Say plainly when you do not know something.',
    // Not optional. Every individual call succeeds; only the aggregate is
    // wrong, which is why the bound lives in the loop rather than in a monitor.
    budget: AgentBudget.interactive,
    executor: ToolExecutor(tools: tools.all, approvalHandler: approvals),
  );
}

/// An agent that answers from a script, so the app runs before a key is set.
///
/// Swapping a scripted model for a real one and changing nothing else is the
/// point of the `ChatModel` port. This is that swap, made visible.
Agent buildDemoAgent(ToolRegistry tools) => ToolCallingAgent(
      info: AgentInfo(
        name: 'assistant-demo',
        description: 'A scripted stand-in until an API key is set.',
      ),
      model: DemoChatModel(),
      tools: tools.all,
      budget: AgentBudget.interactive,
    );

/// A model that answers without a network.
///
/// Deliberately obvious about being a stand-in: an app that quietly pretends to
/// have an assistant is worse than one that says it has not been configured.
final class DemoChatModel implements ChatModel {
  @override
  ModelInfo get info => ModelInfo(id: 'demo', provider: 'demo', isLocal: true);

  @override
  Future<ChatResponse> generate(
    ChatRequest request, {
    AgenticContext? context,
  }) async =>
      ChatResponse(
        message: Message.assistant(
          'This is demo mode — no model is connected yet. Tap the key icon '
          'and paste __PROVIDER_ARTICLE__ __PROVIDER_LABEL__ key, and I will answer for real.',
        ),
        modelId: info.id,
      );

  @override
  Stream<ChatChunk> stream(
    ChatRequest request, {
    AgenticContext? context,
  }) async* {
    final answer = (await generate(request, context: context)).text;
    for (final word in answer.split(' ')) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
      context?.throwIfCancelled();
      yield ChatChunk(textDelta: '$word ');
    }
  }

  @override
  Future<void> dispose() async {}
}
''';

const String _tools = r'''
import 'package:agentic_flutter/agentic_flutter.dart';

/// Notes the agent has saved, for the life of the process.
final List<String> savedNotes = <String>[];

/// Everything the agent can do.
///
/// Registering a tool here is all it takes: the agent is built from
/// `registry.all`, so a new tool is offered to the model on the next turn.
ToolRegistry buildTools() => ToolRegistry()
  ..register(
    FunctionTool.text(
      name: 'current_time',
      description:
          'Returns the current date and time. Use it whenever the answer '
          'depends on what time it is now.',
      handler: (invocation) async =>
          invocation.context.clock.now().toLocal().toString(),
    ),
  )
  ..register(
    FunctionTool.text(
      name: 'save_note',
      description: 'Saves a short note for the user to read later.',
      parameters: JsonSchema.object(
        properties: <String, JsonSchema>{
          'text': JsonSchema.string(description: 'The note to save.'),
        },
        required: const <String>{'text'},
      ),
      // This one changes something, so a person confirms it first. The executor
      // *denies* a tool marked this way when no approval handler is configured,
      // rather than running it — failing closed is the only safe default.
      isReadOnly: false,
      requiresApproval: true,
      handler: (invocation) async {
        final text = invocation.require<String>('text');
        savedNotes.add(text);
        return 'Saved: $text';
      },
    ),
  )
  ..register(
    FunctionTool.text(
      name: 'list_notes',
      description: 'Lists the notes saved so far.',
      handler: (invocation) async =>
          savedNotes.isEmpty ? 'No notes yet.' : savedNotes.join('\n'),
    ),
  );
''';

const String _secrets = r'''
import 'package:agentic_flutter/agentic_flutter.dart';

/// Where the API key lives.
///
/// # Read this before shipping
///
/// A key compiled into a Flutter app is readable by anyone who downloads it.
/// Not "hard to find" — an APK is a zip file, and that is equally true of a
/// key in `--dart-define`, in an asset, or in a bundled `.env`. Every one of
/// those is a key you have published.
///
/// There are two honest options:
///
/// 1. **Do not ship the key.** Put a small service between the app and the
///    provider, authenticate the *user* to that service, and let it hold the
///    provider key. The app never sees it. This is the only approach that is
///    actually safe, and it is what a production app should do.
///
/// 2. **Let the user supply their own key**, which is what this app does. Then
///    it needs somewhere safe on the device — see below.
///
/// # What this returns today
///
/// An in-memory store: the key is gone when the app restarts. That is safe and
/// inconvenient, and it is the right default for a template because the
/// alternative would be a plugin dependency you did not ask for.
///
/// To keep it across launches, add `flutter_secure_storage` and replace this
/// with roughly five lines:
///
/// ```dart
/// final class KeychainSecretStore implements SecretStore {
///   KeychainSecretStore(this._storage);
///   final FlutterSecureStorage _storage;
///
///   @override
///   Future<String?> read(String key) => _storage.read(key: key);
///
///   @override
///   Future<void> write(String key, String value) =>
///       _storage.write(key: key, value: value);
///
///   @override
///   Future<void> delete(String key) => _storage.delete(key: key);
///
///   @override
///   Future<void> dispose() async {}
/// }
/// ```
SecretStore createSecretStore() => InMemorySecretStore();
''';

const String _chatScreen = r'''
import 'dart:async';

import 'package:agentic_flutter/agentic_flutter.dart';
import 'package:flutter/material.dart';

import '../agent.dart';
import '../main.dart';
import 'settings_screen.dart';

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key, this.secrets});

  /// Overridden by tests so the screen can be pumped without global state.
  final SecretStore? secrets;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  AgentChatController? _chat;
  EventRecorder? _recorder;
  bool _isDemo = true;
  bool _wired = false;

  SecretStore get _secrets => widget.secrets ?? secrets;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_wired) return;
    _wired = true;
    _recorder = EventRecorder(context.agenticEvents, capacity: 200)..start();
    unawaited(_rebuildAgent());
  }

  @override
  void dispose() {
    _chat?.dispose();
    _recorder?.dispose();
    super.dispose();
  }

  /// Builds the agent from whatever configuration currently exists.
  ///
  /// Called at start-up and again whenever the key changes, so setting a key
  /// takes effect without a restart.
  Future<void> _rebuildAgent() async {
    final runtime = context.agentic;
    final real = await buildAgent(
      secrets: _secrets,
      tools: runtime.tools,
      approvals: sheetApprovalHandler(navigatorKey: navigatorKey),
    );
    if (!mounted) return;

    final previous = _chat;
    setState(() {
      _isDemo = real == null;
      _chat = AgentChatController(
        agent: real ?? buildDemoAgent(runtime.tools),
        runtime: runtime,
      );
    });
    previous?.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final chat = _chat;
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 20,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const Text('__TITLE__'),
            // Which model is answering, in the one place a person looks when
            // an answer seems off. Without it "demo mode" is invisible state.
            Text(
              _isDemo ? 'Demo mode' : '__PROVIDER_LABEL__',
              style: theme.textTheme.labelSmall?.copyWith(
                color: _isDemo
                    ? theme.colorScheme.tertiary
                    : theme.colorScheme.primary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
        actions: <Widget>[
          IconButton(
            icon: const Icon(Icons.key_outlined),
            tooltip: 'API key',
            onPressed: _openSettings,
          ),
          IconButton(
            icon: const Icon(Icons.data_object),
            tooltip: 'Trace',
            onPressed: () => _showTrace(context),
          ),
          const SizedBox(width: 4),
        ],
        bottom: const PreferredSize(
          preferredSize: Size.fromHeight(1),
          child: Divider(),
        ),
      ),
      body: chat == null
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: <Widget>[
                if (_isDemo) _DemoBanner(onAddKey: _openSettings),
                Expanded(
                  child: AgentChatView(
                    controller: chat,
                    hintText: 'Ask something',
                    emptyState: _EmptyState(
                      onPick: (String prompt) => unawaited(chat.send(prompt)),
                    ),
                  ),
                ),
              ],
            ),
    );
  }

  Future<void> _openSettings() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => SettingsScreen(secrets: _secrets),
      ),
    );
    await _rebuildAgent();
  }

  void _showTrace(BuildContext context) {
    final recorder = _recorder;
    if (recorder == null) return;
    unawaited(
      showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        builder: (_) => SizedBox(
          height: MediaQuery.sizeOf(context).height * 0.7,
          child: TraceInspector(recorder: recorder),
        ),
      ),
    );
  }
}

/// Shown before the first message.
///
/// The suggestions are tappable rather than printed, because the two things
/// worth understanding about this app — that it calls tools, and that it asks
/// before the destructive one — are things you have to *see happen*. Making
/// someone retype a sentence to see them is a tax on the only moment where
/// their attention is guaranteed.
class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.onPick});

  final void Function(String prompt) onPick;

  static const List<(IconData, String, String)> _suggestions =
      <(IconData, String, String)>[
    (Icons.schedule, 'What time is it?', 'Calls a tool'),
    (
      Icons.edit_note,
      'Save a note that I owe Ada lunch',
      'Asks before it runs',
    ),
    (Icons.list_alt, 'What notes have I saved?', 'Calls a tool'),
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          Container(
            width: 60,
            height: 60,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: theme.colorScheme.primaryContainer,
            ),
            child: Icon(
              Icons.auto_awesome,
              size: 28,
              color: theme.colorScheme.onPrimaryContainer,
            ),
          ),
          const SizedBox(height: 20),
          Text(
            'Ask me anything',
            style: theme.textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'I can use tools, and I check with you first\nwhen one changes something.',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              height: 1.45,
            ),
          ),
          const SizedBox(height: 28),
          for (final (icon, prompt, note) in _suggestions)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: _SuggestionCard(
                icon: icon,
                prompt: prompt,
                note: note,
                onTap: () => onPick(prompt),
              ),
            ),
        ],
      ),
    );
  }
}

class _SuggestionCard extends StatelessWidget {
  const _SuggestionCard({
    required this.icon,
    required this.prompt,
    required this.note,
    required this.onTap,
  });

  final IconData icon;
  final String prompt;
  final String note;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(14),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
          child: Row(
            children: <Widget>[
              Icon(icon, size: 19, color: theme.colorScheme.primary),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(prompt, style: theme.textTheme.bodyMedium),
                    const SizedBox(height: 2),
                    Text(
                      note,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                Icons.north_east,
                size: 15,
                color: theme.colorScheme.outline,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The strip that says answers are not coming from a real model.
class _DemoBanner extends StatelessWidget {
  const _DemoBanner({required this.onAddKey});

  final VoidCallback onAddKey;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      color: theme.colorScheme.tertiaryContainer,
      padding: const EdgeInsets.fromLTRB(20, 10, 12, 10),
      child: Row(
        children: <Widget>[
          Icon(
            Icons.science_outlined,
            size: 17,
            color: theme.colorScheme.onTertiaryContainer,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Answers are scripted until you add a key.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onTertiaryContainer,
              ),
            ),
          ),
          TextButton(
            onPressed: onAddKey,
            style: TextButton.styleFrom(
              foregroundColor: theme.colorScheme.onTertiaryContainer,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              minimumSize: const Size(0, 34),
            ),
            child: const Text('Add key'),
          ),
        ],
      ),
    );
  }
}
''';

const String _settingsScreen = r'''
import 'dart:async';

import 'package:agentic_flutter/agentic_flutter.dart';
import 'package:flutter/material.dart';

import '../agent.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({required this.secrets, super.key});

  final SecretStore secrets;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final TextEditingController _field = TextEditingController();
  bool _saved = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final existing = await widget.secrets.read(kApiKeyName);
    if (!mounted || existing == null) return;
    setState(() {
      _field.text = existing;
      _saved = true;
    });
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('__PROVIDER_LABEL__ key')),
        body: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              TextField(
                controller: _field,
                // Obscured because a key is a credential and screens get
                // shared, screenshotted and recorded.
                obscureText: true,
                autocorrect: false,
                enableSuggestions: false,
                decoration: const InputDecoration(
                  labelText: '__KEY_NAME__',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 16),
              Text(
                'The key is kept in memory only, so it is cleared when the app '
                'restarts. See lib/secrets.dart for how to store it properly, '
                'and why shipping a key inside the app is not an option.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 24),
              Row(
                children: <Widget>[
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () async {
                        await widget.secrets.delete(kApiKeyName);
                        if (!context.mounted) return;
                        _field.clear();
                        setState(() => _saved = false);
                      },
                      child: const Text('Clear'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton(
                      onPressed: () async {
                        final value = _field.text.trim();
                        if (value.isEmpty) return;
                        await widget.secrets.write(kApiKeyName, value);
                        if (!context.mounted) return;
                        Navigator.of(context).pop();
                      },
                      child: Text(_saved ? 'Update' : 'Save'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      );
}
''';

const String _appTest = r'''
import 'package:agentic_flutter/agentic_flutter.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:__NAME__/screens/chat_screen.dart';
import 'package:__NAME__/tools.dart';

/// These run offline: with no key stored, the app is in demo mode and the
/// scripted model answers. A template whose test needs a credential is a
/// template whose test nobody runs.
void main() {
  late AgenticRuntime runtime;

  setUp(() {
    runtime = AgenticRuntime(tools: buildTools());
  });

  tearDown(() async {
    await runtime.dispose();
  });

  Widget wrap(Widget child) => AgenticScope(
        runtime: runtime,
        child: MaterialApp(home: child),
      );

  testWidgets('says it is in demo mode until a key is set', (tester) async {
    await tester.pumpWidget(wrap(ChatScreen(secrets: InMemorySecretStore())));
    await tester.pumpAndSettle();

    expect(find.textContaining('Demo mode'), findsOneWidget);
  });

  testWidgets('answers a message', (tester) async {
    await tester.pumpWidget(wrap(ChatScreen(secrets: InMemorySecretStore())));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'hello');
    await tester.testTextInput.receiveAction(TextInputAction.send);
    await tester.pumpAndSettle();

    expect(find.text('hello'), findsOneWidget);
    expect(find.textContaining('demo mode'), findsWidgets);
  });

  test('the note tool needs approval before it runs', () {
    // The executor denies a gated tool when no approval handler is configured,
    // rather than running it. Asserting the flag keeps that guarantee from
    // being removed by accident.
    final spec = buildTools().specOf('save_note')!;
    expect(spec.requiresApproval, isTrue);
    expect(spec.isReadOnly, isFalse);
  });

  test('the time tool does not', () {
    final spec = buildTools().specOf('current_time')!;
    expect(spec.requiresApproval, isFalse);
    expect(spec.isReadOnly, isTrue);
  });
}
''';
