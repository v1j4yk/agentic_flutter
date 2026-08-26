/// Events published around model calls.
///
/// These are what a cost meter, a latency dashboard and a debug console consume.
/// They are deliberately *small*: a per-token event would be published thousands
/// of times per conversation, and the allocation alone would be visible in a
/// Flutter frame budget. Token-level updates belong in the returned stream,
/// which the consumer already has.
library;

import 'package:agentic_core/agentic_core.dart';
import 'package:agentic_llm/src/model/chat_response.dart';

/// Base for every model lifecycle event.
abstract base class LlmEvent extends AgenticEvent {
  /// Creates a model event.
  const LlmEvent({
    required super.id,
    required super.timestamp,
    required this.modelId,
    required this.provider,
    super.runId,
    super.source,
    super.traceId,
    super.spanId,
  });

  /// Identifier of the model involved.
  final String modelId;

  /// Identifier of the provider adapter.
  final String provider;
}

/// A request is about to be sent.
final class LlmRequestStarted extends LlmEvent {
  /// Creates the event.
  const LlmRequestStarted({
    required super.id,
    required super.timestamp,
    required super.modelId,
    required super.provider,
    required this.messageCount,
    required this.toolCount,
    required this.isStreaming,
    super.runId,
    super.source,
    super.traceId,
    super.spanId,
  });

  /// How many messages were sent.
  final int messageCount;

  /// How many tools were offered.
  final int toolCount;

  /// Whether the answer is being streamed.
  final bool isStreaming;

  @override
  String get type => 'llm.request.started';

  @override
  JsonMap payload() => <String, Object?>{
    'modelId': modelId,
    'provider': provider,
    'messageCount': messageCount,
    'toolCount': toolCount,
    'isStreaming': isStreaming,
  };
}

/// The first token of a streamed answer has arrived.
///
/// Time to first token is the number that decides whether an assistant feels
/// responsive. It is invisible in a non-streaming call and invisible in total
/// latency, so it gets its own event.
final class LlmFirstTokenReceived extends LlmEvent {
  /// Creates the event.
  const LlmFirstTokenReceived({
    required super.id,
    required super.timestamp,
    required super.modelId,
    required super.provider,
    required this.latency,
    super.runId,
    super.source,
    super.traceId,
    super.spanId,
  });

  /// Time between sending the request and the first content.
  final Duration latency;

  @override
  String get type => 'llm.first_token';

  @override
  JsonMap payload() => <String, Object?>{
    'modelId': modelId,
    'provider': provider,
    'latencyMs': latency.inMilliseconds,
  };
}

/// A request finished successfully.
final class LlmResponseCompleted extends LlmEvent {
  /// Creates the event.
  const LlmResponseCompleted({
    required super.id,
    required super.timestamp,
    required super.modelId,
    required super.provider,
    required this.usage,
    required this.finishReason,
    required this.duration,
    this.cost,
    this.toolCallCount = 0,
    this.wasCached = false,
    super.runId,
    super.source,
    super.traceId,
    super.spanId,
  });

  /// Tokens consumed.
  final TokenUsage usage;

  /// Why generation stopped.
  final FinishReason finishReason;

  /// Wall-clock duration of the call.
  final Duration duration;

  /// Estimated cost, when the model has prices configured.
  final double? cost;

  /// How many tool calls the model requested.
  final int toolCallCount;

  /// Whether the answer came from a cache rather than the provider.
  ///
  /// A cost meter must exclude these, or a well-cached application appears to
  /// spend money it never spent.
  final bool wasCached;

  @override
  String get type => 'llm.response.completed';

  @override
  JsonMap payload() => pruneNulls(<String, Object?>{
    'modelId': modelId,
    'provider': provider,
    'usage': usage.toJson(),
    'finishReason': finishReason.name,
    'durationMs': duration.inMilliseconds,
    'cost': cost,
    'toolCallCount': toolCallCount == 0 ? null : toolCallCount,
    'wasCached': wasCached ? true : null,
  });
}

/// A request failed.
final class LlmRequestFailed extends LlmEvent {
  /// Creates the event.
  const LlmRequestFailed({
    required super.id,
    required super.timestamp,
    required super.modelId,
    required super.provider,
    required this.code,
    required this.message,
    required this.isRetryable,
    required this.duration,
    super.runId,
    super.source,
    super.traceId,
    super.spanId,
  });

  /// The failure's stable code.
  final String code;

  /// The failure's message.
  final String message;

  /// Whether the failure was transient.
  final bool isRetryable;

  /// How long the attempt took before failing.
  final Duration duration;

  @override
  String get type => 'llm.request.failed';

  @override
  JsonMap payload() => <String, Object?>{
    'modelId': modelId,
    'provider': provider,
    'code': code,
    'message': message,
    'isRetryable': isRetryable,
    'durationMs': duration.inMilliseconds,
  };
}

/// A call was routed to a fallback model.
///
/// Worth its own event: silent failover hides a degradation that someone needs
/// to know about, and a spike in these is the earliest signal of a provider
/// outage.
final class LlmFailoverOccurred extends LlmEvent {
  /// Creates the event.
  const LlmFailoverOccurred({
    required super.id,
    required super.timestamp,
    required super.modelId,
    required super.provider,
    required this.failedModelId,
    required this.reason,
    super.runId,
    super.source,
    super.traceId,
    super.spanId,
  });

  /// The model that failed, causing this failover.
  final String failedModelId;

  /// Why the previous model was abandoned.
  final String reason;

  @override
  String get type => 'llm.failover';

  @override
  JsonMap payload() => <String, Object?>{
    'modelId': modelId,
    'provider': provider,
    'failedModelId': failedModelId,
    'reason': reason,
  };
}
