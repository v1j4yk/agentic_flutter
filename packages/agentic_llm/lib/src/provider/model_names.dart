/// The model names each provider publishes, as constants.
///
/// # Why these exist
///
/// Every adapter takes `model` as a plain `String`, and always will: a
/// framework that only accepts the identifiers it knew about when it was
/// written is a framework that stops working the week a provider ships
/// something. These constants are a convenience, not a whitelist — pass any
/// string a provider serves, including one released after this file was
/// written.
///
/// ```dart
/// AnthropicChatModel(apiKey: key, model: AnthropicModels.opus);
/// AnthropicChatModel(apiKey: key, model: 'claude-something-6');  // equally valid
/// ```
///
/// # These names rot, and that is handled
///
/// A model identifier is a fact about someone else's product. Two of this
/// framework's defaults have already been outlived — `text-embedding-004` and
/// `gemini-2.0-flash` were both retired, and the second failure showed up as
/// documents indexed into zero passages rather than as an error.
///
/// So: the names here were verified against each provider's published model
/// list on **2026-09-18**, `tool/check_models.dart` re-checks them against the
/// live list, and `ModelDirectory.listModels` asks the provider directly at
/// run time — which is also what a model picker in an app should use, because
/// only the provider knows what a given key may call today.
library;

/// Model identifiers published by Anthropic.
///
/// The three families differ in the trade they make between speed, cost and
/// capability; all of them take the same requests through
/// `AnthropicChatModel`. Anthropic's dateless identifiers are pinned
/// snapshots, so an id here keeps meaning one specific model.
abstract final class AnthropicModels {
  /// Claude Opus — for complex agentic and enterprise work.
  static const String opus = 'claude-opus-5';

  /// Claude Sonnet — the balance of speed and intelligence, and the default.
  static const String sonnet = 'claude-sonnet-5';

  /// Claude Haiku — the fastest and cheapest of the three.
  static const String haiku = 'claude-haiku-4-5';

  /// Every family name above, for a picker or a test matrix.
  static const List<String> all = <String>[opus, sonnet, haiku];
}

/// Model identifiers published by OpenAI.
abstract final class OpenAiModels {
  /// The most capable model, for the hardest end-to-end work.
  static const String flagship = 'gpt-6-astra';

  /// The balanced model, and the default: capable without flagship pricing.
  static const String balanced = 'gpt-5.6';

  /// The cost-optimised model, for high-volume work.
  static const String economy = 'gpt-5.6-luna';

  /// The small embedding model: cheaper, and enough for most retrieval.
  static const String embeddingSmall = 'text-embedding-3-small';

  /// The large embedding model, when retrieval quality is worth the size.
  static const String embeddingLarge = 'text-embedding-3-large';

  /// Every chat model above, for a picker or a test matrix.
  static const List<String> all = <String>[flagship, balanced, economy];
}

/// Model identifiers published by Google for the Gemini API.
abstract final class GeminiModels {
  /// The current Flash model, and the default.
  static const String flash = 'gemini-3.8-flash';

  /// The budget Flash variant.
  static const String flashLite = 'gemini-3.5-flash-lite';

  /// The current embedding model, and the default for `GeminiEmbeddingModel`.
  ///
  /// Changing embedding model invalidates an index: embedding spaces are not
  /// comparable, so queries embedded with one model cannot search vectors
  /// written by another. Re-embed, or keep naming the old one.
  static const String embedding = 'gemini-embedding-2';

  /// The previous, text-only embedding model. Deprecated by Google, and kept
  /// named here because an index built with it can only be searched with it.
  static const String embeddingLegacy = 'gemini-embedding-001';

  /// Every chat model above, for a picker or a test matrix.
  static const List<String> all = <String>[flash, flashLite];
}

/// Model identifiers published by xAI for Grok.
abstract final class GrokModels {
  /// The current flagship, and the default.
  static const String flagship = 'grok-4.6';

  /// The previous flagship family, behind an alias xAI moves forward.
  static const String previous = 'grok-4.5-latest';

  /// Every model above, for a picker or a test matrix.
  static const List<String> all = <String>[flagship, previous];
}

/// Model identifiers published by DeepSeek.
///
/// `OpenAiCompatibleChatModel.deepSeek` requires `model` rather than defaulting
/// to one of these: DeepSeek serves retired names through their replacements,
/// so a default would quietly change which model you pay for.
abstract final class DeepSeekModels {
  /// The lightweight model.
  static const String flash = 'deepseek-flash';

  /// The larger model.
  static const String pro = 'deepseek-v4-pro';

  /// Every model above, for a picker or a test matrix.
  static const List<String> all = <String>[flash, pro];
}

/// Model identifiers published by Mistral.
///
/// Mistral publishes dated identifiers, which is why
/// `OpenAiCompatibleChatModel.mistral` requires `model`: the date is the part
/// that tells you which generation you are running.
abstract final class MistralModels {
  /// The medium generalist model.
  static const String medium = 'mistral-medium-2508';

  /// The small generalist model.
  static const String small = 'mistral-small-2506';

  /// The large generalist model.
  static const String large = 'mistral-large-2411';

  /// Every model above, for a picker or a test matrix.
  static const List<String> all = <String>[medium, small, large];
}
