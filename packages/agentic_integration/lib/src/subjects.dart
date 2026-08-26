/// Which providers this machine is configured to test.
///
/// # Absent credentials are a skip, never a failure
///
/// Almost nobody running these tests has a key for every provider, and a suite
/// that goes red because a contributor has no Anthropic account teaches people
/// to ignore it. So a missing key produces a *skip carrying its reason* —
/// `test` prints it, and the difference between "not configured" and "broken"
/// stays visible in the output rather than being buried in a green tick.
///
/// # These tests cost money
///
/// Every subject here makes real calls to a paid API. Defaults are the cheapest
/// capable model each provider offers and responses are capped at a few dozen
/// tokens, which puts a full run in the region of a penny — but it is not zero,
/// and it is why this runs nightly rather than on every push.
library;

import 'dart:io';

import 'package:agentic_llm/agentic_llm.dart';
import 'package:meta/meta.dart';

/// One provider, configured and ready to exercise.
@immutable
final class ProviderSubject {
  /// Describes a subject.
  ProviderSubject({
    required this.name,
    required this.createChat,
    this.createEmbeddings,
    Set<ModelCapability> expectedCapabilities = const <ModelCapability>{},
  }) : expectedCapabilities = Set<ModelCapability>.unmodifiable(
         expectedCapabilities,
       );

  /// How this provider appears in test names, such as `openai`.
  final String name;

  /// Builds a chat model. Called per test, so one test cannot poison another.
  final ChatModel Function() createChat;

  /// Builds an embedding model, when the provider offers one here.
  final EmbeddingModel Function()? createEmbeddings;

  /// What the adapter claims, captured so the audit can compare it with reality.
  final Set<ModelCapability> expectedCapabilities;

  @override
  String toString() => 'ProviderSubject($name)';
}

/// A provider that is not configured, and why.
@immutable
final class MissingSubject {
  /// Describes what is missing.
  const MissingSubject({required this.name, required this.reason});

  /// Which provider.
  final String name;

  /// What to set to enable it.
  final String reason;

  @override
  String toString() => '$name: $reason';
}

/// What this machine can and cannot test.
@immutable
final class SubjectSet {
  /// Creates a set.
  SubjectSet({
    required List<ProviderSubject> available,
    required List<MissingSubject> missing,
  }) : available = List<ProviderSubject>.unmodifiable(available),
       missing = List<MissingSubject>.unmodifiable(missing);

  /// Providers with credentials.
  final List<ProviderSubject> available;

  /// Providers without them.
  final List<MissingSubject> missing;

  /// Whether anything at all can be tested.
  bool get isEmpty => available.isEmpty;

  /// A line explaining what will be skipped.
  String describeMissing() => missing.isEmpty
      ? 'Every provider is configured.'
      : 'Skipping ${missing.length} provider(s):\n'
            '${missing.map((m) => '  $m').join('\n')}';

  @override
  String toString() =>
      'SubjectSet(${available.length} available, ${missing.length} missing)';
}

/// The variable that opts a run in to calling real providers.
const String kOptInVariable = 'AGENTIC_INTEGRATION';

/// Whether this run is allowed to spend money.
///
/// Credentials alone are not enough. A contributor with `OPENAI_API_KEY`
/// exported in their shell — which is most people who use the framework — would
/// otherwise be billed the first time they ran `dart test` out of habit. The
/// opt-in has to be an act, not an accident.
bool get integrationEnabled => env(kOptInVariable) != null;

/// Reads an environment variable, treating blank as absent.
///
/// A CI secret that is not set expands to the empty string rather than being
/// unset, so `containsKey` would report a key that is not there as present —
/// and the tests would run and fail with a 401 instead of skipping.
String? env(String name) {
  final value = Platform.environment[name];
  return value == null || value.trim().isEmpty ? null : value.trim();
}

/// Parses a comma-separated capability list, such as `toolCalling,streaming`.
///
/// Unknown names are ignored rather than fatal: this is configuration typed by
/// a person into a shell, and a typo should cost one capability rather than the
/// whole run.
Set<ModelCapability> _capabilitiesFrom(String? value) {
  if (value == null) return ModelCapabilities.localMinimal;
  final byName = <String, ModelCapability>{
    for (final capability in ModelCapability.values)
      capability.name: capability,
  };
  return <ModelCapability>{
    for (final token in value.split(',')) ?byName[token.trim()],
  };
}

/// Builds the subject set from the environment.
///
/// Adding a provider is one entry in the list below. That is deliberate: the
/// conformance suite is shared, so a new adapter earns the entire battery by
/// declaring how to construct itself.
SubjectSet discoverSubjects() {
  final available = <ProviderSubject>[];
  final missing = <MissingSubject>[];

  void consider({
    required String name,
    required String keyVariable,
    required ProviderSubject Function(String apiKey) build,
  }) {
    final key = env(keyVariable);
    if (key == null) {
      missing.add(MissingSubject(name: name, reason: 'set $keyVariable'));
      return;
    }
    available.add(build(key));
  }

  consider(
    name: 'openai',
    keyVariable: 'OPENAI_API_KEY',
    build: (apiKey) => ProviderSubject(
      name: 'openai',
      createChat: () => OpenAiCompatibleChatModel.openAi(
        apiKey: apiKey,
        model: env('OPENAI_MODEL') ?? 'gpt-4o-mini',
      ),
      createEmbeddings: () =>
          OpenAiCompatibleEmbeddingModel.openAi(apiKey: apiKey),
      expectedCapabilities: ModelCapabilities.frontier,
    ),
  );

  consider(
    name: 'anthropic',
    keyVariable: 'ANTHROPIC_API_KEY',
    build: (apiKey) => ProviderSubject(
      name: 'anthropic',
      createChat: () => AnthropicChatModel(
        apiKey: apiKey,
        model: env('ANTHROPIC_MODEL') ?? 'claude-3-5-haiku-latest',
      ),
    ),
  );

  consider(
    name: 'gemini',
    keyVariable: 'GEMINI_API_KEY',
    build: (apiKey) => ProviderSubject(
      name: 'gemini',
      createChat: () => GeminiChatModel(
        apiKey: apiKey,
        model: env('GEMINI_MODEL') ?? 'gemini-2.0-flash',
      ),
      createEmbeddings: () => GeminiEmbeddingModel(apiKey: apiKey),
    ),
  );

  consider(
    name: 'deepseek',
    keyVariable: 'DEEPSEEK_API_KEY',
    build: (apiKey) => ProviderSubject(
      name: 'deepseek',
      createChat: () => OpenAiCompatibleChatModel.deepSeek(apiKey: apiKey),
    ),
  );

  // Ollama is addressed by URL rather than by key: it is the local case, and
  // testing it proves the same adapter serves a hosted API and a model running
  // on the developer's own machine.
  final ollamaUrl = env('OLLAMA_BASE_URL');
  final ollamaModel = env('OLLAMA_MODEL');
  if (ollamaUrl != null && ollamaModel != null) {
    available.add(
      ProviderSubject(
        name: 'ollama',
        createChat: () => OpenAiCompatibleChatModel.ollama(
          model: ollamaModel,
          baseUrl: Uri.parse(ollamaUrl),
          // Whatever the operator says their model can do. A local model's
          // capabilities depend on which weights are loaded, so the adapter
          // cannot know them and the default is deliberately minimal.
          capabilities: _capabilitiesFrom(env('OLLAMA_CAPABILITIES')),
        ),
        expectedCapabilities: _capabilitiesFrom(env('OLLAMA_CAPABILITIES')),
      ),
    );
  } else {
    missing.add(
      const MissingSubject(
        name: 'ollama',
        reason: 'set OLLAMA_BASE_URL and OLLAMA_MODEL',
      ),
    );
  }

  return SubjectSet(available: available, missing: missing);
}
