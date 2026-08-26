/// Cross-cutting behaviour, composed as decorators.
///
/// # Why decorators and not a pipeline
///
/// The usual design for this is a middleware pipeline: a list of handlers, a
/// `next()` callback, an ordering convention. It is more machinery and less
/// clarity. A decorator is an ordinary Dart class that happens to wrap another
/// [ChatModel], so:
///
/// * composition is a constructor call, and the order is visible at the call
///   site rather than implied by a list;
/// * each decorator is unit-testable against a fake model with no framework;
/// * a user's own decorator is indistinguishable from the ones shipped here;
/// * there is no pipeline abstraction to learn, document or version.
///
/// ```dart
/// final model = ObservableChatModel(
///   RetryingChatModel(
///     CachingChatModel(
///       FallbackChatModel([primary, secondary]),
///       cache: InMemoryChatCache(),
///     ),
///     policy: RetryPolicy.interactive,
///   ),
/// );
/// ```
///
/// Read that outside-in: observe everything, retry what fails, serve from cache
/// when possible, and fail over between providers underneath. Ordering matters
/// and is worth thinking about — putting the cache outside the retry would
/// cache nothing when the first attempt fails, and putting observation inside
/// the retry would hide the retries from your dashboard.
library;

import 'dart:async';
import 'dart:collection';

import 'package:agentic_core/agentic_core.dart';
import 'package:agentic_llm/src/events/llm_events.dart';
import 'package:agentic_llm/src/model/chat_chunk.dart';
import 'package:agentic_llm/src/model/chat_model.dart';
import 'package:agentic_llm/src/model/chat_request.dart';
import 'package:agentic_llm/src/model/chat_response.dart';
import 'package:agentic_llm/src/model/model_info.dart';

// -----------------------------------------------------------------------------
// Retrying
// -----------------------------------------------------------------------------

/// Retries transient failures according to a [RetryPolicy].
///
/// # Streaming is retried only before the first chunk
///
/// Once a token has been delivered to the caller, the answer cannot be retried:
/// replaying would emit a second, different beginning, and a UI that has
/// already rendered the first sentence would show garbage. This decorator
/// therefore retries a stream only while nothing has been yielded, and lets a
/// mid-stream failure propagate.
///
/// That is the honest behaviour. A framework that silently restarts a stream
/// produces duplicated text that looks like a model defect.
final class RetryingChatModel extends DelegatingChatModel {
  /// Wraps [inner] with a retry policy.
  const RetryingChatModel(super.inner, {this.policy = RetryPolicy.interactive});

  /// The policy governing attempts.
  final RetryPolicy policy;

  @override
  Future<ChatResponse> generate(
    ChatRequest request, {
    AgenticContext? context,
  }) => policy.execute(
    (attempt) => inner.generate(request, context: context),
    operation: '${info.provider}.generate',
    cancellation: context?.cancellation,
    clock: context?.clock ?? const SystemClock(),
  );

  @override
  Stream<ChatChunk> stream(
    ChatRequest request, {
    AgenticContext? context,
  }) async* {
    var delivered = false;

    // The retry wraps only the act of *starting* the stream and forwarding it.
    // `delivered` is checked inside the predicate so that the policy refuses to
    // make a second attempt once output has escaped.
    final guarded = policy.copyWith(
      retryIf: (error, attempt) =>
          !delivered && (policy.retryIf?.call(error, attempt) ?? true),
    );

    final controller = StreamController<ChatChunk>();

    Future<void> run() async {
      try {
        await guarded.execute<void>(
          (attempt) async {
            await for (final chunk in inner.stream(request, context: context)) {
              delivered = true;
              controller.add(chunk);
            }
          },
          operation: '${info.provider}.stream',
          cancellation: context?.cancellation,
          clock: context?.clock ?? const SystemClock(),
        );
      } on Object catch (error, stackTrace) {
        controller.addError(error, stackTrace);
      } finally {
        await controller.close();
      }
    }

    unawaited(run());
    yield* controller.stream;
  }

  @override
  String toString() => 'RetryingChatModel($inner)';
}

// -----------------------------------------------------------------------------
// Failover
// -----------------------------------------------------------------------------

/// Routes to a secondary model when the primary is unavailable.
///
/// Each model is guarded by its own [CircuitBreaker], which is what makes
/// failover cheap: once the primary has failed enough times, subsequent calls
/// skip it entirely instead of paying a timeout before every fallback.
///
/// ```dart
/// final model = FallbackChatModel([
///   OpenAiCompatibleChatModel.openAi(apiKey: key),
///   AnthropicChatModel(apiKey: anthropicKey),
///   OpenAiCompatibleChatModel.ollama(model: 'qwen2.5:7b'), // offline last
/// ]);
/// ```
///
/// Order matters and should reflect preference, not just availability: a local
/// model last means the application degrades to something rather than nothing
/// when the network is gone.
final class FallbackChatModel implements ChatModel {
  /// Creates a failover chain over [models], in order of preference.
  FallbackChatModel(
    List<ChatModel> models, {
    this.shouldFailover = defaultShouldFailover,
    Duration resetTimeout = const Duration(seconds: 30),
    int failureThreshold = 3,
    Clock clock = const SystemClock(),
  }) : _models = List<ChatModel>.unmodifiable(models),
       _breakers = <CircuitBreaker>[
         for (final model in models)
           CircuitBreaker(
             name: model.info.qualifiedId,
             failureThreshold: failureThreshold,
             resetTimeout: resetTimeout,
             clock: clock,
           ),
       ] {
    if (models.isEmpty) {
      throw ConfigurationException(
        'A FallbackChatModel needs at least one model.',
        setting: 'FallbackChatModel.models',
      );
    }
  }

  /// Whether a failure should move to the next model.
  ///
  /// Defaults to [defaultShouldFailover].
  final bool Function(AgenticException error) shouldFailover;

  final List<ChatModel> _models;
  final List<CircuitBreaker> _breakers;

  /// The models in this chain, in order of preference.
  List<ChatModel> get models => _models;

  /// Whether a failure justifies trying the next provider.
  ///
  /// Transient failures do. A malformed request does not: every provider will
  /// reject it identically, and trying three of them turns one clear error into
  /// three confusing ones and three times the latency.
  ///
  /// An exhausted quota *does* fail over even though it is not retryable — the
  /// account is out of credit, which is exactly when a second provider earns
  /// its keep.
  static bool defaultShouldFailover(AgenticException error) =>
      error.isRetryable ||
      error is QuotaExceededException ||
      error is AuthenticationException;

  @override
  ModelInfo get info => _models.first.info;

  @override
  Future<ChatResponse> generate(
    ChatRequest request, {
    AgenticContext? context,
  }) => _attempt(
    context: context,
    describe: 'generate',
    action: (model) => model.generate(request, context: context),
  );

  @override
  Stream<ChatChunk> stream(
    ChatRequest request, {
    AgenticContext? context,
  }) async* {
    // Failover applies to *establishing* the stream. Once chunks flow, a
    // failure is the caller's to handle, for the same reason a retry cannot
    // restart a partially delivered answer.
    final stream = await _attempt(
      context: context,
      describe: 'stream',
      action: (model) async => model.stream(request, context: context),
    );
    yield* stream;
  }

  Future<T> _attempt<T>({
    required AgenticContext? context,
    required String describe,
    required Future<T> Function(ChatModel model) action,
  }) async {
    AgenticException? lastError;

    for (var i = 0; i < _models.length; i++) {
      final model = _models[i];
      context?.throwIfCancelled();

      try {
        return await _breakers[i].execute(() => action(model));
      } on CancelledException {
        rethrow;
      } on CircuitOpenException catch (error) {
        // The circuit is open, so this provider is skipped without a request.
        // That is the whole point: failover should be instant, not preceded by
        // another timeout.
        lastError = error;
        _publishFailover(context, model, i, 'circuit open');
      } on AgenticException catch (error) {
        lastError = error;
        if (!shouldFailover(error) || i == _models.length - 1) rethrow;
        _publishFailover(context, model, i, error.code);
        context?.logger.warn(
          'Model failed; falling back',
          fields: <String, Object?>{
            'failed': model.info.qualifiedId,
            'next': _models[i + 1].info.qualifiedId,
            'code': error.code,
          },
        );
      }
    }

    throw lastError ??
        ProviderException(
          'Every model in the fallback chain failed.',
          provider: info.provider,
        );
  }

  void _publishFailover(
    AgenticContext? context,
    ChatModel failed,
    int index,
    String reason,
  ) {
    if (context == null || index + 1 >= _models.length) return;
    final next = _models[index + 1];
    context.publish(
      LlmFailoverOccurred(
        id: context.ids.prefixed('evt'),
        timestamp: context.clock.now(),
        modelId: next.info.id,
        provider: next.info.provider,
        failedModelId: failed.info.qualifiedId,
        reason: reason,
        runId: context.runId,
        source: 'llm:fallback',
      ),
    );
  }

  @override
  Future<void> dispose() async {
    final bag = DisposableBag();
    for (final breaker in _breakers) {
      bag.add(breaker);
    }
    for (final model in _models) {
      bag.add(model);
    }
    await bag.dispose();
  }

  @override
  String toString() =>
      'FallbackChatModel(${_models.map((m) => m.info.qualifiedId).join(' -> ')})';
}

// -----------------------------------------------------------------------------
// Caching
// -----------------------------------------------------------------------------

/// Stores answers for reuse.
///
/// Implement this to persist across launches — SQLite, Hive, a file — which is
/// where a cache earns most on a device: the same question asked on Monday and
/// Tuesday costs once.
abstract interface class ChatCache {
  /// Returns the cached answer for [key], or `null`.
  Future<ChatResponse?> get(String key);

  /// Stores [response] under [key].
  Future<void> put(String key, ChatResponse response);

  /// Discards everything.
  Future<void> clear();
}

/// A bounded in-memory [ChatCache] with least-recently-used eviction.
final class InMemoryChatCache implements ChatCache {
  /// Creates a cache holding at most [maxEntries].
  InMemoryChatCache({
    this.maxEntries = 100,
    this.ttl = const Duration(hours: 1),
    Clock clock = const SystemClock(),
  }) : _clock = clock;

  /// Maximum number of retained answers.
  final int maxEntries;

  /// How long an entry stays valid.
  final Duration ttl;

  final Clock _clock;

  // A LinkedHashMap preserves insertion order, which is what makes
  // least-recently-used eviction a re-insert and a `remove(first)`.
  final LinkedHashMap<String, _CacheEntry> _entries =
      LinkedHashMap<String, _CacheEntry>();

  /// Number of entries currently held.
  int get length => _entries.length;

  @override
  Future<ChatResponse?> get(String key) async {
    final entry = _entries.remove(key);
    if (entry == null) return null;
    if (_clock.now().difference(entry.storedAt) > ttl) return null;
    // Re-inserting moves it to the most-recently-used end.
    _entries[key] = entry;
    return entry.response;
  }

  @override
  Future<void> put(String key, ChatResponse response) async {
    _entries
      ..remove(key)
      ..[key] = _CacheEntry(response: response, storedAt: _clock.now());
    while (_entries.length > maxEntries) {
      _entries.remove(_entries.keys.first);
    }
  }

  @override
  Future<void> clear() async => _entries.clear();
}

final class _CacheEntry {
  const _CacheEntry({required this.response, required this.storedAt});

  final ChatResponse response;
  final DateTime storedAt;
}

/// Serves repeated identical requests from a cache.
///
/// # What is cached by default, and why
///
/// Only requests the model would answer deterministically — temperature `0`, or
/// unset with no sampling parameters. Caching a creative request is usually
/// wrong: the caller asked for variety and would get the same sentence every
/// time, which reads as a bug rather than a saving. Override [shouldCache] when
/// you want it anyway.
///
/// Streaming is served from cache as a single chunk. A cached answer has no
/// timing to reproduce, and faking one would misreport latency.
final class CachingChatModel extends DelegatingChatModel {
  /// Wraps [inner] with a cache.
  CachingChatModel(
    super.inner, {
    required this.cache,
    this.shouldCache = defaultShouldCache,
  });

  /// Where answers are stored.
  final ChatCache cache;

  /// Whether a request's answer may be cached.
  final bool Function(ChatRequest request) shouldCache;

  /// Caches only requests whose answer should be deterministic.
  static bool defaultShouldCache(ChatRequest request) =>
      (request.temperature == null || request.temperature == 0) &&
      request.topP == null &&
      request.seed == null;

  @override
  Future<ChatResponse> generate(
    ChatRequest request, {
    AgenticContext? context,
  }) async {
    if (!shouldCache(request)) {
      return inner.generate(request, context: context);
    }

    final key = _keyFor(request);
    final cached = await cache.get(key);
    if (cached != null) {
      context?.logger.debug(
        'Model answer served from cache',
        fields: <String, Object?>{'model': info.qualifiedId},
      );
      // Usage is zeroed: the tokens were paid for once, on the original call,
      // and reporting them again would make a cost meter double-count.
      return cached.copyWith(
        usage: TokenUsage.empty,
        cost: 0,
        latency: Duration.zero,
        metadata: <String, Object?>{...cached.metadata, 'cached': true},
      );
    }

    final response = await inner.generate(request, context: context);
    // Only complete answers are stored. Caching a truncated one would serve
    // corruption indefinitely.
    if (response.finishReason.isComplete) await cache.put(key, response);
    return response;
  }

  @override
  Stream<ChatChunk> stream(
    ChatRequest request, {
    AgenticContext? context,
  }) async* {
    if (!shouldCache(request)) {
      yield* inner.stream(request, context: context);
      return;
    }

    final key = _keyFor(request);
    final cached = await cache.get(key);
    if (cached != null) {
      final message = cached.message;
      if (message.text.isNotEmpty) yield ChatChunk.text(message.text);
      for (var i = 0; i < message.toolCalls.length; i++) {
        final call = message.toolCalls[i];
        yield ChatChunk.tool(
          ToolCallDelta(
            index: i,
            id: call.id,
            name: call.name,
            argumentsDelta: call.argumentsJson,
          ),
        );
      }
      yield ChatChunk(
        finishReason: cached.finishReason,
        usage: TokenUsage.empty,
        modelId: cached.modelId,
      );
      return;
    }

    final builder = ChatResponseBuilder(modelId: info.id);
    await for (final chunk in inner.stream(request, context: context)) {
      builder.add(chunk);
      yield chunk;
    }
    final response = builder.build();
    if (response.finishReason.isComplete) await cache.put(key, response);
  }

  /// Namespaces the key by model, so switching models cannot serve a stale
  /// answer produced by a different one.
  String _keyFor(ChatRequest request) =>
      '${info.qualifiedId}#${request.cacheKey}';

  @override
  String toString() => 'CachingChatModel($inner)';
}

// -----------------------------------------------------------------------------
// Observability
// -----------------------------------------------------------------------------

/// Logs, traces and publishes events around every call.
///
/// Add it outermost so that retries and failovers are visible: a dashboard that
/// cannot see three retries reports one slow call instead of a provider having
/// a bad afternoon.
final class ObservableChatModel extends DelegatingChatModel {
  /// Wraps [inner] with instrumentation.
  const ObservableChatModel(super.inner, {this.logPrompts = false});

  /// Whether to log message content, not just counts.
  ///
  /// Off by default, and it should stay off in production: prompts contain
  /// whatever the user typed. Turning this on ships user data to every log sink
  /// the application has configured.
  final bool logPrompts;

  @override
  Future<ChatResponse> generate(
    ChatRequest request, {
    AgenticContext? context,
  }) async {
    if (context == null) return inner.generate(request);

    return context.step('llm.generate', (scope, span) async {
      final started = scope.clock.now();
      _publishStarted(scope, request, isStreaming: false);
      span.setAttributes(<String, Object?>{
        'llm.model': info.id,
        'llm.provider': info.provider,
        'llm.messages': request.messages.length,
        'llm.tools': request.tools?.length ?? 0,
      });

      try {
        final response = await inner.generate(request, context: scope);
        final duration = scope.clock.now().difference(started);
        // An adapter that priced the call wins; otherwise price it here, so a
        // cost meter reports the same figure whichever path produced the
        // answer.
        final cost = response.cost ?? info.estimateCost(response.usage);

        span.setAttributes(<String, Object?>{
          'llm.finish_reason': response.finishReason.name,
          'llm.tokens.prompt': response.usage.promptTokens,
          'llm.tokens.completion': response.usage.completionTokens,
          'llm.tokens.cached': response.usage.cachedPromptTokens,
          'llm.cost': ?cost,
          'llm.request_id': ?response.requestId,
        });

        scope
          ..publish(
            LlmResponseCompleted(
              id: scope.ids.prefixed('evt'),
              timestamp: scope.clock.now(),
              modelId: response.modelId,
              provider: info.provider,
              usage: response.usage,
              finishReason: response.finishReason,
              duration: duration,
              cost: cost,
              toolCallCount: response.toolCalls.length,
              wasCached: response.metadata['cached'] == true,
              runId: scope.runId,
              source: 'llm:${info.qualifiedId}',
              traceId: span.context.traceId,
              spanId: span.context.spanId,
            ),
          )
          ..logger.info(
            'Model answered',
            fields: <String, Object?>{
              'model': info.qualifiedId,
              'tokens': response.usage.totalTokens,
              'ms': duration.inMilliseconds,
              'finish': response.finishReason.name,
              if (logPrompts) 'answer': response.text,
            },
          );
        return response;
      } on AgenticException catch (error) {
        _publishFailed(scope, error, scope.clock.now().difference(started));
        rethrow;
      }
    }, kind: SpanKind.client);
  }

  @override
  Stream<ChatChunk> stream(
    ChatRequest request, {
    AgenticContext? context,
  }) async* {
    if (context == null) {
      yield* inner.stream(request);
      return;
    }

    final started = context.clock.now();
    _publishStarted(context, request, isStreaming: true);

    final builder = ChatResponseBuilder(modelId: info.id);
    var sawContent = false;

    try {
      await for (final chunk in inner.stream(request, context: context)) {
        if (!sawContent && !chunk.isEmpty) {
          sawContent = true;
          context.publish(
            LlmFirstTokenReceived(
              id: context.ids.prefixed('evt'),
              timestamp: context.clock.now(),
              modelId: info.id,
              provider: info.provider,
              latency: context.clock.now().difference(started),
              runId: context.runId,
              source: 'llm:${info.qualifiedId}',
            ),
          );
        }
        builder.add(chunk);
        yield chunk;
      }
    } on AgenticException catch (error) {
      _publishFailed(context, error, context.clock.now().difference(started));
      rethrow;
    }

    final response = builder.build();
    context.publish(
      LlmResponseCompleted(
        id: context.ids.prefixed('evt'),
        timestamp: context.clock.now(),
        modelId: response.modelId,
        provider: info.provider,
        usage: response.usage,
        finishReason: response.finishReason,
        duration: context.clock.now().difference(started),
        cost: info.estimateCost(response.usage),
        toolCallCount: response.toolCalls.length,
        runId: context.runId,
        source: 'llm:${info.qualifiedId}',
      ),
    );
  }

  void _publishStarted(
    AgenticContext context,
    ChatRequest request, {
    required bool isStreaming,
  }) {
    context.publish(
      LlmRequestStarted(
        id: context.ids.prefixed('evt'),
        timestamp: context.clock.now(),
        modelId: info.id,
        provider: info.provider,
        messageCount: request.messages.length,
        toolCount: request.tools?.length ?? 0,
        isStreaming: isStreaming,
        runId: context.runId,
        source: 'llm:${info.qualifiedId}',
      ),
    );
    if (logPrompts) {
      context.logger.debug(
        'Model request',
        fields: <String, Object?>{
          'model': info.qualifiedId,
          'messages': request.messages.map((m) => m.toJson()).toList(),
        },
      );
    }
  }

  void _publishFailed(
    AgenticContext context,
    AgenticException error,
    Duration duration,
  ) {
    context
      ..publish(
        LlmRequestFailed(
          id: context.ids.prefixed('evt'),
          timestamp: context.clock.now(),
          modelId: info.id,
          provider: info.provider,
          code: error.code,
          message: error.message,
          isRetryable: error.isRetryable,
          duration: duration,
          runId: context.runId,
          source: 'llm:${info.qualifiedId}',
        ),
      )
      ..logger.warn(
        'Model call failed',
        fields: <String, Object?>{
          'model': info.qualifiedId,
          'code': error.code,
          'retryable': error.isRetryable,
        },
        error: error,
      );
  }

  @override
  String toString() => 'ObservableChatModel($inner)';
}
