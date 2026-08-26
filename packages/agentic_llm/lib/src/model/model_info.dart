/// What a model is and what it can do.
///
/// Capability negotiation is not a nicety in a provider-independent framework;
/// it is the thing that makes one possible. The same application code runs
/// against GPT-4o, Claude, and a 1.5B Qwen on the device — and those three
/// disagree about tool calling, vision, structured output and system prompts.
///
/// Without a declared capability set, every layer above has to discover the
/// difference by sending a request and parsing the failure. With one, an agent
/// can degrade deliberately: fall back to prompt-based tool selection on a
/// small local model, drop an image, or refuse up front with a message that
/// names the problem.
library;

import 'package:agentic_core/agentic_core.dart';
import 'package:meta/meta.dart';

/// A feature a model may or may not support.
///
/// Adapters must declare these honestly. Claiming tool calling on a model that
/// lacks it does not produce a graceful failure — it produces a model that
/// invents a plausible-looking answer instead of calling the tool, which is far
/// harder to diagnose.
enum ModelCapability {
  /// Accepts tool definitions and can request calls.
  toolCalling,

  /// Can request several tool calls in a single turn.
  ///
  /// Distinct from [toolCalling] because it changes agent-loop strategy: a
  /// model without it needs one round trip per tool.
  parallelToolCalls,

  /// Supports incremental token streaming.
  streaming,

  /// Accepts images as input.
  vision,

  /// Accepts audio as input.
  audioInput,

  /// Can be constrained to emit syntactically valid JSON.
  jsonMode,

  /// Can be constrained to a specific JSON Schema, with conformance guaranteed.
  ///
  /// Stronger than [jsonMode]: valid JSON of the wrong shape is still a
  /// failure for a caller that has to parse it.
  structuredOutput,

  /// Produces explicit reasoning before answering.
  reasoning,

  /// Supports server-side caching of a stable prompt prefix.
  promptCaching,

  /// Honours a dedicated system instruction.
  ///
  /// Several small local models have no system role at all; adapters for those
  /// prepend the instruction to the first user turn instead.
  systemPrompt,
}

/// Per-token prices, in units of currency per million tokens.
///
/// Cost is a first-class concern in an agentic system. The characteristic
/// failure of this architecture is not a crash — it is a loop that quietly
/// spends money, and you cannot bound a budget you cannot measure.
///
/// Prices change; these are configuration, not constants baked into an adapter.
@immutable
final class ModelPricing {
  /// Creates a price list.
  const ModelPricing({
    required this.inputPerMillion,
    required this.outputPerMillion,
    this.cachedInputPerMillion,
    this.currency = 'USD',
  });

  /// Price per million prompt tokens.
  final double inputPerMillion;

  /// Price per million completion tokens.
  final double outputPerMillion;

  /// Price per million prompt tokens served from cache.
  ///
  /// Typically a small fraction of [inputPerMillion]. When absent, cached
  /// tokens are billed at the full input rate.
  final double? cachedInputPerMillion;

  /// ISO 4217 currency code.
  final String currency;

  /// Estimates what [usage] cost.
  ///
  /// An estimate, not an invoice: providers round, apply discounts and change
  /// prices. It is accurate enough to enforce a budget and to tell which agent
  /// in a crew is expensive, which is what it is for.
  double estimate(TokenUsage usage) {
    final cachedRate = cachedInputPerMillion ?? inputPerMillion;
    final cached = usage.cachedPromptTokens * cachedRate;
    final uncached = usage.uncachedPromptTokens * inputPerMillion;
    final output = usage.completionTokens * outputPerMillion;
    return (cached + uncached + output) / 1000000;
  }

  /// Serialises the price list.
  JsonMap toJson() => pruneNulls(<String, Object?>{
    'inputPerMillion': inputPerMillion,
    'outputPerMillion': outputPerMillion,
    'cachedInputPerMillion': cachedInputPerMillion,
    'currency': currency,
  });

  @override
  String toString() =>
      'ModelPricing($currency $inputPerMillion in / '
      '$outputPerMillion out per 1M)';
}

/// Identity and capabilities of a model.
@immutable
final class ModelInfo {
  /// Describes a model.
  ///
  /// [id] is the identifier sent on the wire, such as `gpt-4o-2024-11-20`.
  /// Prefer a dated, pinned identifier in production: an alias silently
  /// changes behaviour underneath you.
  ModelInfo({
    required this.id,
    required this.provider,
    Set<ModelCapability> capabilities = const <ModelCapability>{},
    this.contextWindow,
    this.maxOutputTokens,
    this.pricing,
    this.displayName,
    this.isLocal = false,
  }) : capabilities = Set<ModelCapability>.unmodifiable(capabilities);

  /// Wire identifier of the model.
  final String id;

  /// Identifier of the adapter, such as `openai` or `anthropic`.
  final String provider;

  /// Human-readable name for UI.
  final String? displayName;

  /// Features this model supports.
  final Set<ModelCapability> capabilities;

  /// Total token window, prompt plus completion, when known.
  final int? contextWindow;

  /// Maximum completion tokens the model will emit, when known.
  final int? maxOutputTokens;

  /// Prices, when configured.
  final ModelPricing? pricing;

  /// Whether inference runs on the device.
  ///
  /// Local models change the calculus everywhere above: no per-token cost, no
  /// rate limit, no network failure — but a much smaller context window, weaker
  /// tool calling, and a battery budget instead of a billing one.
  final bool isLocal;

  /// A stable key identifying this model, such as `openai:gpt-4o`.
  ///
  /// Used for cache keys, metrics dimensions and registry lookups.
  String get qualifiedId => '$provider:$id';

  /// Whether [capability] is supported.
  bool supports(ModelCapability capability) =>
      capabilities.contains(capability);

  /// Whether every capability in [required] is supported.
  bool supportsAll(Iterable<ModelCapability> required) =>
      required.every(capabilities.contains);

  /// Throws unless [capability] is supported.
  ///
  /// The guard an adapter uses at the top of a request it cannot fulfil, so
  /// the failure names the missing feature instead of surfacing as a provider
  /// 400 fifty lines later.
  void requireCapability(ModelCapability capability) {
    if (supports(capability)) return;
    throw CapabilityNotSupportedException(
      '`$qualifiedId` does not support ${capability.name}.',
      capability: capability.name,
      component: qualifiedId,
    );
  }

  /// Estimates the cost of [usage] against [pricing].
  ///
  /// Returns `null` when no prices are configured, which is always the case for
  /// a local model.
  double? estimateCost(TokenUsage usage) => pricing?.estimate(usage);

  /// Returns a copy with selected fields replaced.
  ModelInfo copyWith({
    String? id,
    String? provider,
    String? displayName,
    Set<ModelCapability>? capabilities,
    int? contextWindow,
    int? maxOutputTokens,
    ModelPricing? pricing,
    bool? isLocal,
  }) => ModelInfo(
    id: id ?? this.id,
    provider: provider ?? this.provider,
    displayName: displayName ?? this.displayName,
    capabilities: capabilities ?? this.capabilities,
    contextWindow: contextWindow ?? this.contextWindow,
    maxOutputTokens: maxOutputTokens ?? this.maxOutputTokens,
    pricing: pricing ?? this.pricing,
    isLocal: isLocal ?? this.isLocal,
  );

  /// Serialises the description.
  JsonMap toJson() => pruneNulls(<String, Object?>{
    'id': id,
    'provider': provider,
    'displayName': displayName,
    'capabilities': capabilities.map((c) => c.name).toList()..sort(),
    'contextWindow': contextWindow,
    'maxOutputTokens': maxOutputTokens,
    'pricing': pricing?.toJson(),
    'isLocal': isLocal ? true : null,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ModelInfo && id == other.id && provider == other.provider;

  @override
  int get hashCode => Object.hash(id, provider);

  @override
  String toString() => 'ModelInfo($qualifiedId)';
}

/// Capability sets shared by whole families of models.
///
/// Adapters compose these rather than re-listing capabilities per model, which
/// is how a typo turns into a runtime surprise.
abstract final class ModelCapabilities {
  /// A current frontier chat model: everything except audio.
  static const Set<ModelCapability> frontier = <ModelCapability>{
    ModelCapability.toolCalling,
    ModelCapability.parallelToolCalls,
    ModelCapability.streaming,
    ModelCapability.vision,
    ModelCapability.jsonMode,
    ModelCapability.structuredOutput,
    ModelCapability.promptCaching,
    ModelCapability.systemPrompt,
  };

  /// A capable model without guaranteed schema conformance.
  static const Set<ModelCapability> standard = <ModelCapability>{
    ModelCapability.toolCalling,
    ModelCapability.parallelToolCalls,
    ModelCapability.streaming,
    ModelCapability.jsonMode,
    ModelCapability.systemPrompt,
  };

  /// A small local model: text in, text out, streamed.
  ///
  /// Deliberately conservative. Many local runtimes advertise tool calling and
  /// then emit malformed calls; declaring it here would push that breakage into
  /// every agent above.
  static const Set<ModelCapability> localMinimal = <ModelCapability>{
    ModelCapability.streaming,
    ModelCapability.systemPrompt,
  };
}
