/// A scripted [ChatModel] for tests.
///
/// Testing anything built on a model — an agent loop, a middleware stack, a
/// widget — requires a model that is deterministic, offline and inspectable.
/// Mocking frameworks can produce one, but they cannot answer the questions
/// that actually matter here: *what was in the request*, and *how many times was
/// it sent*. This records both.
///
/// It ships in the published package rather than in this package's own test
/// folder, so that applications and third-party plugins test against the same
/// double the framework does.
library;

import 'dart:async';

import 'package:agentic_core/agentic_core.dart';
import 'package:agentic_llm/src/model/chat_chunk.dart';
import 'package:agentic_llm/src/model/chat_model.dart';
import 'package:agentic_llm/src/model/chat_request.dart';
import 'package:agentic_llm/src/model/chat_response.dart';
import 'package:agentic_llm/src/model/embedding_model.dart';
import 'package:agentic_llm/src/model/model_info.dart';
import 'package:meta/meta.dart';

/// One scripted turn: either an answer or a failure.
@immutable
final class FakeTurn {
  const FakeTurn._({this.response, this.error, this.chunks});

  /// Answers with [response].
  const FakeTurn.answer(ChatResponse response) : this._(response: response);

  /// Fails with [error].
  const FakeTurn.failure(AgenticException error) : this._(error: error);

  /// Answers by emitting [chunks] verbatim when streamed.
  ///
  /// Use this to reproduce a provider's exact fragmentation — the split
  /// tool-call arguments, the empty keep-alive frames — which is the only way
  /// to test an accumulator against reality.
  const FakeTurn.chunks(List<ChatChunk> chunks) : this._(chunks: chunks);

  /// The answer, when this turn succeeds.
  final ChatResponse? response;

  /// The failure, when this turn fails.
  final AgenticException? error;

  /// Explicit chunks, when this turn scripts a stream.
  final List<ChatChunk>? chunks;
}

/// A [ChatModel] that returns scripted answers and records what it was asked.
///
/// ```dart
/// final model = FakeChatModel.text('Paris.');
/// await agent.run('What is the capital of France?');
///
/// expect(model.callCount, 1);
/// expect(model.lastRequest.messages.last.text, contains('France'));
/// ```
final class FakeChatModel implements ChatModel {
  /// Creates a model that plays [turns] in order.
  ///
  /// When the script is exhausted the **last turn repeats**. That is
  /// deliberate: an agent loop under test usually needs one interesting turn
  /// followed by an ordinary one, and requiring an exact count would make every
  /// test brittle against an extra iteration.
  FakeChatModel({
    List<FakeTurn> turns = const <FakeTurn>[],
    ModelInfo? info,
    this.latency = Duration.zero,
  }) : _turns = List<FakeTurn>.of(turns),
       info =
           info ??
           ModelInfo(
             id: 'fake-model',
             provider: 'fake',
             capabilities: ModelCapabilities.frontier,
           );

  /// Creates a model that always answers with [text].
  factory FakeChatModel.text(String text, {ModelInfo? info}) => FakeChatModel(
    info: info,
    turns: <FakeTurn>[
      FakeTurn.answer(
        ChatResponse(
          message: Message.assistant(text),
          modelId: info?.id ?? 'fake-model',
          usage: const TokenUsage(promptTokens: 10, completionTokens: 5),
        ),
      ),
    ],
  );

  /// Creates a model that requests [toolCalls], then answers with [then].
  ///
  /// The two-turn script an agent-loop test almost always needs.
  factory FakeChatModel.toolCall({
    required List<ToolCallPart> toolCalls,
    String then = 'Done.',
    ModelInfo? info,
  }) => FakeChatModel(
    info: info,
    turns: <FakeTurn>[
      FakeTurn.answer(
        ChatResponse(
          message: Message.assistant('', toolCalls: toolCalls),
          modelId: info?.id ?? 'fake-model',
          finishReason: FinishReason.toolCalls,
          usage: const TokenUsage(promptTokens: 20, completionTokens: 10),
        ),
      ),
      FakeTurn.answer(
        ChatResponse(
          message: Message.assistant(then),
          modelId: info?.id ?? 'fake-model',
          usage: const TokenUsage(promptTokens: 30, completionTokens: 5),
        ),
      ),
    ],
  );

  /// Creates a model that always fails with [error].
  factory FakeChatModel.failing(AgenticException error, {ModelInfo? info}) =>
      FakeChatModel(info: info, turns: <FakeTurn>[FakeTurn.failure(error)]);

  /// Creates a model that fails [times] times, then answers with [then].
  ///
  /// The script for exercising a retry policy.
  factory FakeChatModel.failingThenAnswering({
    required AgenticException error,
    int times = 1,
    String then = 'Recovered.',
    ModelInfo? info,
  }) => FakeChatModel(
    info: info,
    turns: <FakeTurn>[
      for (var i = 0; i < times; i++) FakeTurn.failure(error),
      FakeTurn.answer(
        ChatResponse(
          message: Message.assistant(then),
          modelId: info?.id ?? 'fake-model',
        ),
      ),
    ],
  );

  @override
  final ModelInfo info;

  /// Artificial delay before each answer, for exercising timeouts.
  final Duration latency;

  final List<FakeTurn> _turns;
  final List<ChatRequest> _requests = <ChatRequest>[];

  int _index = 0;
  bool _disposed = false;

  /// Every request this model received, in order.
  List<ChatRequest> get requests => List<ChatRequest>.unmodifiable(_requests);

  /// The most recent request.
  ///
  /// Throws a [StateError] if nothing has been sent, because an assertion
  /// against a request that never happened is a broken test rather than a
  /// failing one.
  ChatRequest get lastRequest {
    if (_requests.isEmpty) {
      throw StateError('FakeChatModel has not received any request yet.');
    }
    return _requests.last;
  }

  /// How many calls this model received.
  int get callCount => _requests.length;

  /// Whether [dispose] has been called.
  bool get isDisposed => _disposed;

  /// Appends a turn to the script.
  void enqueue(FakeTurn turn) => _turns.add(turn);

  /// Forgets recorded requests and rewinds the script.
  void reset() {
    _requests.clear();
    _index = 0;
  }

  @override
  Future<ChatResponse> generate(
    ChatRequest request, {
    AgenticContext? context,
  }) async {
    _requests.add(request);
    if (latency > Duration.zero) {
      await (context?.clock ?? const SystemClock()).delay(latency);
    }
    context?.throwIfCancelled();

    final turn = _nextTurn();
    if (turn.error case final error?) throw error;
    if (turn.response case final response?) {
      return response.copyWith(metadata: request.metadata);
    }
    // A chunk-scripted turn asked for by a non-streaming caller: assemble it,
    // so the same script serves both modes.
    final builder = ChatResponseBuilder(modelId: info.id)
      ..addAll(turn.chunks ?? const <ChatChunk>[]);
    return builder.build();
  }

  @override
  Stream<ChatChunk> stream(
    ChatRequest request, {
    AgenticContext? context,
  }) async* {
    _requests.add(request);
    if (latency > Duration.zero) {
      await (context?.clock ?? const SystemClock()).delay(latency);
    }
    context?.throwIfCancelled();

    final turn = _nextTurn();
    if (turn.error case final error?) throw error;

    if (turn.chunks case final chunks?) {
      for (final chunk in chunks) {
        context?.throwIfCancelled();
        yield chunk;
      }
      return;
    }

    final response = turn.response!;
    final message = response.message;
    if (message.reasoning case final reasoning?) {
      yield ChatChunk.reasoning(reasoning);
    }
    // Split into words so a test can observe more than one chunk without the
    // script having to spell them out.
    for (final word in _wordsOf(message.text)) {
      context?.throwIfCancelled();
      yield ChatChunk.text(word);
    }
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
      finishReason: response.finishReason,
      usage: response.usage,
      modelId: response.modelId,
    );
  }

  @override
  Future<void> dispose() async => _disposed = true;

  FakeTurn _nextTurn() {
    if (_turns.isEmpty) {
      throw StateError(
        'FakeChatModel has no scripted turns. Pass `turns:` or use one of the '
        'named constructors.',
      );
    }
    final turn = _turns[_index];
    // The last turn repeats rather than running out; see the constructor.
    if (_index < _turns.length - 1) _index++;
    return turn;
  }

  static Iterable<String> _wordsOf(String text) sync* {
    if (text.isEmpty) return;
    final words = text.split(' ');
    for (var i = 0; i < words.length; i++) {
      yield i == 0 ? words[i] : ' ${words[i]}';
    }
  }

  @override
  String toString() => 'FakeChatModel(${_requests.length} calls)';
}

/// An [EmbeddingModel] returning deterministic vectors.
///
/// Vectors are derived from the text's characters, so identical text embeds
/// identically and different text embeds differently — enough to test a
/// retrieval pipeline end to end without a network or a real model.
final class FakeEmbeddingModel implements EmbeddingModel {
  /// Creates a fake embedder.
  FakeEmbeddingModel({this.dimensions = 8, this.maxBatchSize = 100})
    : info = ModelInfo(id: 'fake-embeddings', provider: 'fake');

  @override
  final ModelInfo info;

  @override
  final int dimensions;

  @override
  final int maxBatchSize;

  /// Every input this model was asked to embed.
  final List<String> embedded = <String>[];

  @override
  Future<List<Embedding>> embed(
    List<String> inputs, {
    required EmbeddingPurpose purpose,
    AgenticContext? context,
  }) async {
    embedded.addAll(inputs);
    return <Embedding>[
      for (var i = 0; i < inputs.length; i++)
        Embedding(values: _vectorFor(inputs[i]), index: i, text: inputs[i]),
    ];
  }

  List<double> _vectorFor(String text) {
    final values = List<double>.filled(dimensions, 0);
    for (var i = 0; i < text.length; i++) {
      values[i % dimensions] += text.codeUnitAt(i) / 1000;
    }
    return values;
  }

  @override
  Future<void> dispose() async {}
}
