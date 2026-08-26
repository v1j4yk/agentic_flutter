/// What to ask a model for.
///
/// One immutable request object, provider-neutral, carrying everything every
/// supported provider can express — and an explicit escape hatch for the things
/// only one of them can.
///
/// # Why an escape hatch is a feature
///
/// A provider-independent abstraction that only exposes the intersection of its
/// providers is useless the first time someone needs a provider-specific
/// feature: they abandon the abstraction and call the HTTP API directly, and
/// now half the application bypasses your retries, tracing and cancellation.
///
/// [ChatRequest.providerOptions] is the pressure valve. Common features are
/// typed and portable; anything else passes through to the adapter, which
/// merges it into the request body. You keep the framework, and you keep the
/// feature.
library;

import 'package:agentic_core/agentic_core.dart';
import 'package:agentic_llm/src/model/model_info.dart';
import 'package:agentic_tools/agentic_tools.dart';
import 'package:meta/meta.dart';

/// How the model may use the tools it was given.
@immutable
final class ToolChoice {
  const ToolChoice._(this.mode, [this.toolName]);

  /// Creates a choice forcing a specific tool.
  ///
  /// Useful for extraction: give the model one tool whose schema is the shape
  /// you want, force it, and the tool call *is* your structured output. This
  /// works on providers with no structured-output mode at all.
  factory ToolChoice.tool(String name) =>
      ToolChoice._(ToolChoiceMode.specific, name);

  /// The model decides whether to call a tool. The default.
  static const ToolChoice auto = ToolChoice._(ToolChoiceMode.auto);

  /// The model must answer in prose and may not call a tool.
  ///
  /// The natural way to end an agent loop that has gathered enough: send the
  /// final turn with tools still described but forbidden, so the model
  /// summarises instead of calling a fourth search.
  static const ToolChoice none = ToolChoice._(ToolChoiceMode.none);

  /// The model must call some tool.
  static const ToolChoice required = ToolChoice._(ToolChoiceMode.required);

  /// Which of the four modes this is.
  final ToolChoiceMode mode;

  /// The tool that must be called, for [ToolChoiceMode.specific].
  final String? toolName;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ToolChoice && mode == other.mode && toolName == other.toolName;

  @override
  int get hashCode => Object.hash(mode, toolName);

  @override
  String toString() => toolName == null
      ? 'ToolChoice.${mode.name}'
      : 'ToolChoice.tool($toolName)';
}

/// The four tool-choice modes.
enum ToolChoiceMode {
  /// The model decides.
  auto,

  /// Tool calling is forbidden.
  none,

  /// Some tool must be called.
  required,

  /// One named tool must be called.
  specific,
}

/// How the model's answer should be shaped.
@immutable
final class ResponseFormat {
  const ResponseFormat._(
    this.kind, {
    this.schema,
    this.schemaName,
    this.strict = true,
  });

  /// Constrains the answer to [schema].
  ///
  /// Requires [ModelCapability.structuredOutput]. The schema is converted to
  /// the strict dialect automatically — closed objects, every property
  /// required, optionality expressed as nullable types — because that is what
  /// providers demand and writing it twice is a needless source of drift.
  ///
  /// [name] identifies the schema to the provider and must be a simple
  /// identifier.
  factory ResponseFormat.jsonSchema({
    required String name,
    required JsonSchema schema,
    bool strict = true,
  }) => ResponseFormat._(
    ResponseFormatKind.jsonSchema,
    schema: schema.toStrict(),
    schemaName: name,
    strict: strict,
  );

  /// Free-form text. The default.
  static const ResponseFormat text = ResponseFormat._(ResponseFormatKind.text);

  /// Syntactically valid JSON, of unspecified shape.
  ///
  /// Weaker than [ResponseFormat.jsonSchema] in the way that matters: valid
  /// JSON of the wrong shape still fails the caller that has to parse it.
  /// Providers also require the word "JSON" to appear in the prompt for this
  /// mode; adapters that know this enforce it.
  static const ResponseFormat json = ResponseFormat._(ResponseFormatKind.json);

  /// Which of the three formats this is.
  final ResponseFormatKind kind;

  /// The required shape, for [ResponseFormatKind.jsonSchema].
  final JsonSchema? schema;

  /// Provider-facing name of the schema.
  final String? schemaName;

  /// Whether conformance is guaranteed rather than merely requested.
  final bool strict;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ResponseFormat &&
          kind == other.kind &&
          schemaName == other.schemaName &&
          schema == other.schema;

  @override
  int get hashCode => Object.hash(kind, schemaName, schema);

  @override
  String toString() => 'ResponseFormat.${kind.name}';
}

/// The three response formats.
enum ResponseFormatKind {
  /// Free-form text.
  text,

  /// Valid JSON of unspecified shape.
  json,

  /// JSON conforming to a supplied schema.
  jsonSchema,
}

/// How much internal reasoning to spend before answering.
///
/// Reasoning tokens are billed and invisible, so this is a cost dial as much as
/// a quality one. Providers spell it differently — an effort level, a token
/// budget, a thinking flag — and adapters translate.
enum ReasoningEffort {
  /// Disable reasoning where the model allows it.
  none,

  /// Minimal reasoning; fastest and cheapest.
  low,

  /// Balanced. The usual default when reasoning is on at all.
  medium,

  /// Maximum reasoning; slowest and most expensive.
  high,
}

/// An immutable request to a chat model.
///
/// ```dart
/// final request = ChatRequest(
///   messages: [
///     Message.system('You are a concise assistant.'),
///     Message.user('What is the capital of France?'),
///   ],
///   temperature: 0.2,
///   maxOutputTokens: 256,
/// );
/// ```
@immutable
final class ChatRequest {
  /// Creates a request.
  ///
  /// [messages] must not be empty; a request with no turns is a programming
  /// error that providers reject with an unhelpful message.
  ChatRequest({
    required List<Message> messages,
    this.tools,
    this.toolChoice = ToolChoice.auto,
    this.temperature,
    this.topP,
    this.topK,
    this.maxOutputTokens,
    List<String> stopSequences = const <String>[],
    this.seed,
    this.responseFormat = ResponseFormat.text,
    this.reasoningEffort,
    this.frequencyPenalty,
    this.presencePenalty,
    this.user,
    Map<String, Object?> providerOptions = const <String, Object?>{},
    Map<String, Object?> metadata = const <String, Object?>{},
  }) : messages = List<Message>.unmodifiable(messages),
       stopSequences = List<String>.unmodifiable(stopSequences),
       providerOptions = Map<String, Object?>.unmodifiable(providerOptions),
       metadata = Map<String, Object?>.unmodifiable(metadata) {
    if (messages.isEmpty) {
      throw ValidationException(
        'A ChatRequest needs at least one message.',
        violations: const <String>['messages: must not be empty'],
      );
    }
    _validateRange('temperature', temperature, 0, 2);
    _validateRange('topP', topP, 0, 1);
    _validateRange('frequencyPenalty', frequencyPenalty, -2, 2);
    _validateRange('presencePenalty', presencePenalty, -2, 2);
    if (maxOutputTokens != null && maxOutputTokens! <= 0) {
      throw ValidationException(
        'maxOutputTokens must be positive, got $maxOutputTokens.',
        violations: <String>['maxOutputTokens: must be > 0'],
      );
    }
  }

  /// Creates a single-turn request from a prompt.
  ///
  /// The shortest path to an answer, for the many cases that are not a
  /// conversation.
  factory ChatRequest.prompt(
    String prompt, {
    String? system,
    double? temperature,
    int? maxOutputTokens,
    ResponseFormat responseFormat = ResponseFormat.text,
  }) => ChatRequest(
    messages: <Message>[
      if (system != null) Message.system(system),
      Message.user(prompt),
    ],
    temperature: temperature,
    maxOutputTokens: maxOutputTokens,
    responseFormat: responseFormat,
  );

  /// The conversation, oldest first.
  final List<Message> messages;

  /// Tools the model may call, or `null` when none are offered.
  ///
  /// `null` and an empty set are different: an empty set still tells an adapter
  /// to omit tool definitions, but records that tool support was considered.
  final ToolSet? tools;

  /// How the model may use [tools].
  final ToolChoice toolChoice;

  /// Sampling temperature, 0 to 2.
  ///
  /// Leave it unset to accept the provider's default rather than pinning a
  /// value that means slightly different things across providers. Set it low
  /// for extraction and tool calling, where determinism beats creativity.
  final double? temperature;

  /// Nucleus sampling threshold, 0 to 1.
  ///
  /// Adjust this *or* [temperature], not both: they interact in ways that are
  /// hard to reason about and harder to tune.
  final double? topP;

  /// Top-k sampling. Supported by Anthropic and Gemini, ignored by OpenAI.
  final int? topK;

  /// Maximum completion tokens.
  ///
  /// A cost ceiling as much as a length one. Anthropic requires it; that
  /// adapter supplies a default rather than failing.
  final int? maxOutputTokens;

  /// Sequences that stop generation when produced.
  final List<String> stopSequences;

  /// Seed for reproducible sampling, where supported.
  ///
  /// Best-effort everywhere. Useful for evaluation runs, never a guarantee.
  final int? seed;

  /// The shape the answer must take.
  final ResponseFormat responseFormat;

  /// How much internal reasoning to spend.
  final ReasoningEffort? reasoningEffort;

  /// Penalty for token frequency, -2 to 2.
  final double? frequencyPenalty;

  /// Penalty for token presence, -2 to 2.
  final double? presencePenalty;

  /// Opaque end-user identifier, forwarded for provider-side abuse detection.
  ///
  /// Never send a raw email address or anything else identifying; send a hash.
  final String? user;

  /// Provider-specific fields merged into the request body.
  ///
  /// The escape hatch described in the library documentation. Keys are used
  /// verbatim, so they are provider-specific by construction — using them ties
  /// that call site to one provider, which is the honest trade.
  final Map<String, Object?> providerOptions;

  /// Application metadata, never sent to a provider.
  ///
  /// Carried through to the response and to events, so a cost meter can
  /// attribute a call to a feature, a tenant or an agent.
  final Map<String, Object?> metadata;

  /// Whether any tools are offered.
  bool get hasTools => tools != null && tools!.isNotEmpty;

  /// Whether a structured answer was requested.
  bool get wantsStructuredOutput =>
      responseFormat.kind != ResponseFormatKind.text;

  /// Capabilities this request requires of a model.
  ///
  /// Used to fail fast with a message naming the missing feature, rather than
  /// sending a request that the provider rejects for reasons the caller has to
  /// decode.
  Set<ModelCapabilityRequirement> get requirements =>
      <ModelCapabilityRequirement>{
        if (hasTools) ModelCapabilityRequirement.toolCalling,
        if (responseFormat.kind == ResponseFormatKind.json)
          ModelCapabilityRequirement.jsonMode,
        if (responseFormat.kind == ResponseFormatKind.jsonSchema)
          ModelCapabilityRequirement.structuredOutput,
        if (messages.any((m) => m.isMultimodal))
          ModelCapabilityRequirement.vision,
      };

  /// Returns a copy with selected fields replaced.
  ///
  /// Note that `null` cannot clear a field here; that is the usual `copyWith`
  /// limitation, and clearing is rare enough to be done by constructing a new
  /// request.
  ChatRequest copyWith({
    List<Message>? messages,
    ToolSet? tools,
    ToolChoice? toolChoice,
    double? temperature,
    double? topP,
    int? topK,
    int? maxOutputTokens,
    List<String>? stopSequences,
    int? seed,
    ResponseFormat? responseFormat,
    ReasoningEffort? reasoningEffort,
    double? frequencyPenalty,
    double? presencePenalty,
    String? user,
    Map<String, Object?>? providerOptions,
    Map<String, Object?>? metadata,
  }) => ChatRequest(
    messages: messages ?? this.messages,
    tools: tools ?? this.tools,
    toolChoice: toolChoice ?? this.toolChoice,
    temperature: temperature ?? this.temperature,
    topP: topP ?? this.topP,
    topK: topK ?? this.topK,
    maxOutputTokens: maxOutputTokens ?? this.maxOutputTokens,
    stopSequences: stopSequences ?? this.stopSequences,
    seed: seed ?? this.seed,
    responseFormat: responseFormat ?? this.responseFormat,
    reasoningEffort: reasoningEffort ?? this.reasoningEffort,
    frequencyPenalty: frequencyPenalty ?? this.frequencyPenalty,
    presencePenalty: presencePenalty ?? this.presencePenalty,
    user: user ?? this.user,
    providerOptions: providerOptions ?? this.providerOptions,
    metadata: metadata ?? this.metadata,
  );

  /// Returns a copy with [additional] messages appended.
  ///
  /// The agent loop's core operation: take the request, append the model's turn
  /// and the tool results, send it again.
  ChatRequest withMessages(Iterable<Message> additional) =>
      copyWith(messages: <Message>[...messages, ...additional]);

  /// A stable fingerprint of everything that affects the answer.
  ///
  /// Backs response caching. Deliberately excludes [metadata], which is
  /// application bookkeeping and must not fragment the cache, and includes
  /// [providerOptions], which certainly does affect the answer.
  String get cacheKey {
    final buffer = StringBuffer()
      ..write(messages.map((m) => m.toJson().toString()).join('|'))
      ..write('#tools=')
      ..write(
        tools?.specs.map((s) => s.toFunctionJson().toString()).join(',') ?? '',
      )
      ..write('#choice=$toolChoice')
      ..write('#t=$temperature#p=$topP#k=$topK#max=$maxOutputTokens')
      ..write('#stop=${stopSequences.join(',')}#seed=$seed')
      ..write('#fmt=${responseFormat.kind.name}:${responseFormat.schemaName}')
      ..write('#reason=${reasoningEffort?.name}')
      ..write('#fp=$frequencyPenalty#pp=$presencePenalty')
      ..write('#opts=$providerOptions');
    return buffer.toString();
  }

  static void _validateRange(
    String name,
    double? value,
    double min,
    double max,
  ) {
    if (value == null) return;
    if (value >= min && value <= max) return;
    throw ValidationException(
      '$name must be between $min and $max, got $value.',
      violations: <String>['$name: must be in [$min, $max]'],
    );
  }

  @override
  String toString() =>
      'ChatRequest(${messages.length} messages'
      '${hasTools ? ', ${tools!.length} tools' : ''}'
      '${wantsStructuredOutput ? ', ${responseFormat.kind.name}' : ''})';
}

/// A capability a request needs from a model.
///
/// A narrower mirror of [ModelCapability], holding only the features a request
/// can imply. Kept separate so that adding a model capability — say, audio
/// output — does not silently become something a request claims to require.
enum ModelCapabilityRequirement {
  /// The request offers tools.
  toolCalling,

  /// The request asks for JSON.
  jsonMode,

  /// The request asks for a specific schema.
  structuredOutput,

  /// The request contains images.
  vision,
}

/// Maps a requirement onto the capability that satisfies it.
extension RequirementCapability on ModelCapabilityRequirement {
  /// The model capability this requirement needs.
  ModelCapability get capability => switch (this) {
    ModelCapabilityRequirement.toolCalling => ModelCapability.toolCalling,
    ModelCapabilityRequirement.jsonMode => ModelCapability.jsonMode,
    ModelCapabilityRequirement.structuredOutput =>
      ModelCapability.structuredOutput,
    ModelCapabilityRequirement.vision => ModelCapability.vision,
  };
}
