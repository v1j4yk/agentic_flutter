/// What a model answered.
library;

import 'dart:convert';

import 'package:agentic_core/agentic_core.dart';
import 'package:meta/meta.dart';

/// Why generation stopped.
///
/// The single most under-checked field in LLM integration. A response that
/// stopped at [length] is *truncated*: its JSON will not parse, its tool call
/// is half-written, and its prose ends mid-sentence. Treating it as a normal
/// answer is how a silent data-corruption bug gets shipped.
enum FinishReason {
  /// The model finished naturally or hit a stop sequence.
  stop,

  /// The token limit was reached. The answer is incomplete.
  length,

  /// The model requested one or more tool calls.
  toolCalls,

  /// Generation was stopped by a safety filter.
  contentFilter,

  /// The provider reported a failure mid-generation.
  error,

  /// The provider sent a reason this version does not recognise.
  ///
  /// Deliberately not an error: a provider adding a finish reason must not
  /// break existing applications.
  unknown;

  /// Whether the answer can be trusted as complete.
  bool get isComplete => this == stop || this == toolCalls;
}

/// A model's complete answer.
@immutable
final class ChatResponse {
  /// Creates a response.
  ChatResponse({
    required this.message,
    required this.modelId,
    this.usage = TokenUsage.empty,
    this.finishReason = FinishReason.stop,
    this.requestId,
    this.latency,
    this.cost,
    this.raw,
    Map<String, Object?> metadata = const <String, Object?>{},
  }) : metadata = Map<String, Object?>.unmodifiable(metadata);

  /// The assistant turn, including any tool calls and reasoning.
  final Message message;

  /// The model that produced it, as reported by the provider.
  ///
  /// May differ from the model that was requested: providers resolve aliases,
  /// and knowing that `gpt-4o` meant `gpt-4o-2024-11-20` matters when an
  /// evaluation changes overnight without a deploy.
  final String modelId;

  /// Tokens consumed.
  final TokenUsage usage;

  /// Why generation stopped.
  final FinishReason finishReason;

  /// The provider's request identifier.
  ///
  /// The single most useful field to quote in a support ticket. Adapters
  /// populate it from the response headers or body.
  final String? requestId;

  /// Wall-clock time the call took, when measured.
  final Duration? latency;

  /// Estimated cost, when the model has prices configured.
  final double? cost;

  /// The provider's raw payload.
  ///
  /// The escape hatch for a field the abstraction does not model yet. Adapters
  /// may omit it — it can be large, and retaining it for a long conversation
  /// costs real memory on a phone.
  final JsonMap? raw;

  /// Metadata carried through from the request.
  final Map<String, Object?> metadata;

  /// The answer text.
  String get text => message.text;

  /// The model's reasoning, when it emitted any.
  String? get reasoning => message.reasoning;

  /// Tool calls the model requested.
  List<ToolCallPart> get toolCalls => message.toolCalls;

  /// Whether the model requested at least one tool call.
  ///
  /// The condition an agent loop turns on.
  bool get hasToolCalls => message.hasToolCalls;

  /// Whether the answer was cut off by the token limit.
  bool get wasTruncated => finishReason == FinishReason.length;

  /// Throws if the answer is incomplete.
  ///
  /// Call this before parsing an answer you will act on. A truncated response
  /// is not a smaller answer; it is a corrupt one.
  void ensureComplete() {
    if (finishReason.isComplete) return;
    throw ProviderException(
      switch (finishReason) {
        FinishReason.length =>
          'The answer was truncated at the output token limit. Raise '
              '`maxOutputTokens`, or ask for less.',
        FinishReason.contentFilter =>
          'The answer was blocked by the provider\'s safety filter.',
        FinishReason.error => 'The provider failed during generation.',
        _ => 'Generation stopped for an unrecognised reason.',
      },
      provider: modelId,
      requestId: requestId,
      retryable: finishReason != FinishReason.contentFilter,
      details: <String, Object?>{'finishReason': finishReason.name},
    );
  }

  /// Parses the answer as a JSON object.
  ///
  /// For use with `ResponseFormat.json` and `ResponseFormat.jsonSchema`.
  /// Validates against [schema] when one is supplied, so a structurally valid
  /// but wrongly-shaped answer fails here rather than three layers deeper.
  ///
  /// Throws a [SerializationException] carrying the offending text when the
  /// answer is not JSON — which, on a model without guaranteed structured
  /// output, happens often enough that the text is the only useful diagnostic.
  JsonMap decodeJson({JsonSchema? schema}) {
    ensureComplete();
    final source = _stripCodeFence(text);
    final Object? decoded;
    try {
      decoded = jsonDecode(source);
    } on FormatException catch (error, stackTrace) {
      throw SerializationException(
        'The model was asked for JSON but produced something else: '
        '${_preview(source)}',
        cause: error,
        causeStackTrace: stackTrace,
        details: <String, Object?>{'modelId': modelId, 'requestId': requestId},
      );
    }
    if (decoded is! Map) {
      throw SerializationException(
        'Expected a JSON object, got ${decoded.runtimeType}: '
        '${_preview(source)}',
      );
    }
    final json = decoded.cast<String, Object?>();
    schema?.validate(json).throwIfInvalid(subject: 'The model\'s JSON answer');
    return json;
  }

  /// Parses the answer as JSON and maps it with [fromJson].
  ///
  /// ```dart
  /// final invoice = response.decodeAs(Invoice.fromJson, schema: invoiceSchema);
  /// ```
  T decodeAs<T>(T Function(JsonMap json) fromJson, {JsonSchema? schema}) =>
      fromJson(decodeJson(schema: schema));

  /// Returns a copy with selected fields replaced.
  ChatResponse copyWith({
    Message? message,
    String? modelId,
    TokenUsage? usage,
    FinishReason? finishReason,
    String? requestId,
    Duration? latency,
    double? cost,
    JsonMap? raw,
    Map<String, Object?>? metadata,
  }) => ChatResponse(
    message: message ?? this.message,
    modelId: modelId ?? this.modelId,
    usage: usage ?? this.usage,
    finishReason: finishReason ?? this.finishReason,
    requestId: requestId ?? this.requestId,
    latency: latency ?? this.latency,
    cost: cost ?? this.cost,
    raw: raw ?? this.raw,
    metadata: metadata ?? this.metadata,
  );

  /// Serialises the response, excluding [raw].
  JsonMap toJson() => pruneNulls(<String, Object?>{
    'message': message.toJson(),
    'modelId': modelId,
    'usage': usage.toJson(),
    'finishReason': finishReason.name,
    'requestId': requestId,
    'latencyMs': latency?.inMilliseconds,
    'cost': cost,
    'metadata': metadata.isEmpty ? null : metadata,
  });

  /// Strips a markdown code fence, which models add even when told not to.
  ///
  /// Cheap and unambiguous: a fence around the whole answer is never part of
  /// the intended JSON, and refusing to handle it wastes a round trip on a
  /// formatting habit rather than a real failure.
  static String _stripCodeFence(String text) {
    final trimmed = text.trim();
    if (!trimmed.startsWith('```')) return trimmed;
    final firstNewline = trimmed.indexOf('\n');
    if (firstNewline < 0) return trimmed;
    final withoutOpen = trimmed.substring(firstNewline + 1);
    final closing = withoutOpen.lastIndexOf('```');
    return closing < 0
        ? withoutOpen.trim()
        : withoutOpen.substring(0, closing).trim();
  }

  static String _preview(String text) =>
      text.length <= 200 ? text : '${text.substring(0, 197)}...';

  @override
  String toString() =>
      'ChatResponse($modelId, ${finishReason.name}, '
      '${usage.totalTokens} tokens'
      '${hasToolCalls ? ', ${toolCalls.length} tool calls' : ''})';
}
