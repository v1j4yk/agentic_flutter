/// Incremental answers, and how they are reassembled.
///
/// # The problem this solves
///
/// Streaming is not just text arriving in pieces. A tool call arrives in pieces
/// too, and the pieces are *fragments of a JSON string*:
///
/// ```text
/// {"index":0,"id":"call_1","function":{"name":"search_web","arguments":""}}
/// {"index":0,"function":{"arguments":"{\"qu"}}
/// {"index":0,"function":{"arguments":"ery\":\"da"}}
/// {"index":0,"function":{"arguments":"rt 3\"}"}}
/// ```
///
/// No individual fragment is valid JSON. The name arrives once, in the first
/// fragment; the identifier may arrive only once too; and with parallel tool
/// calls, fragments for several calls interleave, distinguished only by
/// `index`. Anthropic streams the same information with entirely different
/// event names and its own block indices.
///
/// [ChatResponseBuilder] absorbs all of that. Adapters emit provider-neutral
/// [ChatChunk]s; the builder assembles them into a [ChatResponse] byte-identical
/// to what the non-streaming call would have produced. That equivalence is the
/// property worth protecting: no code above should have to care which mode was
/// used.
library;

import 'dart:async';
import 'dart:convert';

import 'package:agentic_core/agentic_core.dart';
import 'package:agentic_llm/src/model/chat_response.dart';
import 'package:meta/meta.dart';

/// A fragment of a tool call.
@immutable
final class ToolCallDelta {
  /// Creates a fragment.
  const ToolCallDelta({
    required this.index,
    this.id,
    this.name,
    this.argumentsDelta,
  });

  /// Position of the call within the turn.
  ///
  /// The correlation key. With parallel tool calls, fragments interleave and
  /// this is the only thing that says which call a fragment belongs to — the
  /// identifier is usually sent only once.
  final int index;

  /// The provider's call identifier, usually present only in the first
  /// fragment.
  final String? id;

  /// The tool's name, usually present only in the first fragment.
  final String? name;

  /// A fragment of the argument JSON, to be concatenated in arrival order.
  final String? argumentsDelta;

  @override
  String toString() =>
      'ToolCallDelta(#$index${name == null ? '' : ' $name'}'
      '${argumentsDelta == null ? '' : ' +${argumentsDelta!.length}b'})';
}

/// One incremental update from a streaming response.
///
/// Chunks are sparse: most carry a single text delta and nothing else. The
/// final chunk carries the finish reason and, on most providers, the usage.
@immutable
final class ChatChunk {
  /// Creates a chunk.
  const ChatChunk({
    this.textDelta,
    this.reasoningDelta,
    this.reasoningSignature,
    this.toolCall,
    this.finishReason,
    this.usage,
    this.modelId,
    this.requestId,
    this.raw,
  });

  /// Creates a text-only chunk.
  const ChatChunk.text(String delta) : this(textDelta: delta);

  /// Creates a reasoning-only chunk.
  const ChatChunk.reasoning(String delta) : this(reasoningDelta: delta);

  /// Creates a tool-call fragment chunk.
  const ChatChunk.tool(ToolCallDelta delta) : this(toolCall: delta);

  /// Creates a terminal chunk.
  const ChatChunk.done({
    FinishReason reason = FinishReason.stop,
    TokenUsage? usage,
    String? modelId,
  }) : this(finishReason: reason, usage: usage, modelId: modelId);

  /// New answer text, to be appended.
  final String? textDelta;

  /// New reasoning text, to be appended.
  final String? reasoningDelta;

  /// Integrity signature for the reasoning block, when the provider issues one.
  ///
  /// Must be echoed back verbatim on the next turn or the provider rejects it.
  final String? reasoningSignature;

  /// A fragment of a tool call.
  final ToolCallDelta? toolCall;

  /// Why generation stopped. Present only on the terminal chunk.
  final FinishReason? finishReason;

  /// Token usage. Usually present only on the terminal chunk.
  final TokenUsage? usage;

  /// The model that produced the answer, usually on the first chunk.
  final String? modelId;

  /// The provider's request identifier.
  final String? requestId;

  /// The raw provider event, for debugging.
  final JsonMap? raw;

  /// Whether this chunk ends the stream.
  bool get isFinal => finishReason != null;

  /// Whether this chunk carries nothing but metadata.
  ///
  /// Providers emit these routinely — a role announcement, a keep-alive, an
  /// empty delta — and a UI should not treat one as a token.
  bool get isEmpty =>
      textDelta == null && reasoningDelta == null && toolCall == null;

  @override
  String toString() {
    if (isFinal) return 'ChatChunk(done: ${finishReason!.name})';
    if (textDelta != null) return 'ChatChunk(text: ${textDelta!.length}b)';
    if (toolCall != null) return 'ChatChunk($toolCall)';
    if (reasoningDelta != null) {
      return 'ChatChunk(reasoning: ${reasoningDelta!.length}b)';
    }
    return 'ChatChunk(empty)';
  }
}

/// Assembles a [ChatResponse] from a stream of [ChatChunk]s.
///
/// Also usable as a live view while the stream is still running: [text] and
/// [toolCallCount] are valid at any point, which is what a UI renders.
///
/// ```dart
/// final builder = ChatResponseBuilder();
/// await for (final chunk in model.stream(request)) {
///   builder.add(chunk);
///   setState(() => visibleText = builder.text);
/// }
/// final response = builder.build();
/// ```
final class ChatResponseBuilder {
  /// Creates an empty builder.
  ///
  /// [modelId] seeds the model identifier for providers that never send one.
  ChatResponseBuilder({String? modelId, this.metadata = const {}})
    : _modelId = modelId;

  /// Metadata carried into the built response.
  final Map<String, Object?> metadata;

  final StringBuffer _text = StringBuffer();
  final StringBuffer _reasoning = StringBuffer();
  final Map<int, _PartialToolCall> _toolCalls = <int, _PartialToolCall>{};

  String? _modelId;
  String? _requestId;
  String? _reasoningSignature;
  FinishReason? _finishReason;
  TokenUsage _usage = TokenUsage.empty;
  int _chunkCount = 0;

  /// The answer text accumulated so far.
  String get text => _text.toString();

  /// The reasoning accumulated so far, or `null` if none.
  String? get reasoning => _reasoning.isEmpty ? null : _reasoning.toString();

  /// How many tool calls have been seen so far.
  int get toolCallCount => _toolCalls.length;

  /// How many chunks have been absorbed.
  int get chunkCount => _chunkCount;

  /// Whether a terminal chunk has arrived.
  bool get isComplete => _finishReason != null;

  /// Usage reported so far.
  TokenUsage get usage => _usage;

  /// Absorbs one chunk.
  void add(ChatChunk chunk) {
    _chunkCount++;

    if (chunk.textDelta case final delta?) _text.write(delta);
    if (chunk.reasoningDelta case final delta?) _reasoning.write(delta);
    if (chunk.reasoningSignature case final signature?) {
      _reasoningSignature = signature;
    }
    if (chunk.modelId case final id?) _modelId ??= id;
    if (chunk.requestId case final id?) _requestId ??= id;
    if (chunk.finishReason case final reason?) _finishReason = reason;

    // Usage is replaced rather than summed. Providers differ: some send the
    // running total on every chunk, others only a final figure. Summing would
    // multiply the bill by the chunk count on the first kind.
    if (chunk.usage case final usage?) {
      if (!usage.isEmpty) _usage = usage;
    }

    if (chunk.toolCall case final delta?) _absorbToolCall(delta);
  }

  /// Absorbs every chunk of [chunks].
  void addAll(Iterable<ChatChunk> chunks) => chunks.forEach(add);

  /// Builds the assembled response.
  ///
  /// Safe to call before the stream ends; the result reflects what has arrived,
  /// with an [FinishReason.unknown] finish reason.
  ChatResponse build({Duration? latency, double? cost}) => ChatResponse(
    message: toMessage(),
    modelId: _modelId ?? 'unknown',
    usage: _usage,
    finishReason: _finishReason ?? FinishReason.unknown,
    requestId: _requestId,
    latency: latency,
    cost: cost,
    metadata: metadata,
  );

  /// Builds the assistant message from what has been accumulated.
  ///
  /// Parts are ordered reasoning, then text, then tool calls — matching the
  /// order a non-streaming response produces, so a transcript looks the same
  /// either way.
  Message toMessage() {
    final parts = <ContentPart>[
      if (_reasoning.isNotEmpty)
        ReasoningPart(_reasoning.toString(), signature: _reasoningSignature),
      if (_text.isNotEmpty) TextPart(_text.toString()),
      ..._finishedToolCalls(),
    ];
    return Message(role: MessageRole.assistant, parts: parts);
  }

  /// Discards everything accumulated, for reuse across a retry.
  void reset() {
    _text.clear();
    _reasoning.clear();
    _toolCalls.clear();
    _modelId = null;
    _requestId = null;
    _reasoningSignature = null;
    _finishReason = null;
    _usage = TokenUsage.empty;
    _chunkCount = 0;
  }

  void _absorbToolCall(ToolCallDelta delta) {
    final partial = _toolCalls.putIfAbsent(
      delta.index,
      () => _PartialToolCall(index: delta.index),
    );
    if (delta.id case final id?) partial.id ??= id;
    if (delta.name case final name?) partial.name ??= name;
    if (delta.argumentsDelta case final fragment?) {
      partial.arguments.write(fragment);
    }
  }

  List<ToolCallPart> _finishedToolCalls() {
    // Ordered by the provider's index, not by arrival: fragments interleave,
    // and the model's intended order is the index order.
    final indices = _toolCalls.keys.toList()..sort();
    return <ToolCallPart>[
      for (final index in indices) _toolCalls[index]!.toPart(),
    ];
  }
}

final class _PartialToolCall {
  _PartialToolCall({required this.index});

  final int index;
  final StringBuffer arguments = StringBuffer();
  String? id;
  String? name;

  ToolCallPart toPart() {
    final raw = arguments.toString();
    return ToolCallPart(
      // A provider that never sent an identifier still needs one, because the
      // tool result must correlate back to something.
      id: id ?? 'call_$index',
      name: name ?? '',
      arguments: _parseArguments(raw),
      rawArguments: raw.isEmpty ? null : raw,
    );
  }

  /// Parses accumulated argument JSON, tolerating failure.
  ///
  /// A truncated or malformed argument string must not throw. If it did, a
  /// stream cut short by the token limit would take down the whole call — and
  /// the recoverable outcome is far better: the tool executor validates the
  /// empty arguments against the schema, reports exactly what is missing, and
  /// the model repairs it on the next turn. `rawArguments` keeps the original
  /// text for diagnosis either way.
  static Map<String, Object?> _parseArguments(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return const <String, Object?>{};
    try {
      final decoded = jsonDecode(trimmed);
      return decoded is Map
          ? decoded.cast<String, Object?>()
          : const <String, Object?>{};
    } on FormatException {
      return const <String, Object?>{};
    }
  }
}

/// Stream operations for consuming a streamed answer.
extension ChatChunkStream on Stream<ChatChunk> {
  /// Collects the whole stream into a single response.
  ///
  /// The bridge between the streaming and non-streaming APIs: a caller that
  /// wanted the streaming transport but not the incremental UI can use one
  /// call.
  Future<ChatResponse> collect({String? modelId}) async {
    final builder = ChatResponseBuilder(modelId: modelId);
    await forEach(builder.add);
    return builder.build();
  }

  /// Just the answer text, for rendering.
  ///
  /// Drops reasoning, tool-call fragments and metadata chunks, so a chat bubble
  /// can bind to this directly without filtering.
  Stream<String> get textDeltas => map(
    (chunk) => chunk.textDelta,
  ).where((delta) => delta != null).cast<String>();

  /// The cumulative text after each chunk.
  ///
  /// Convenient for a widget that renders the whole answer each frame rather
  /// than appending.
  Stream<String> get cumulativeText {
    final buffer = StringBuffer();
    return textDeltas.map((delta) {
      buffer.write(delta);
      return buffer.toString();
    });
  }

  /// Emits the assembled response alongside every chunk.
  ///
  /// Lets a UI render progress and still receive a complete, correct
  /// [ChatResponse] without maintaining a builder itself.
  Stream<(ChatChunk chunk, ChatResponseBuilder state)> withState({
    String? modelId,
  }) {
    final builder = ChatResponseBuilder(modelId: modelId);
    return map((chunk) {
      builder.add(chunk);
      return (chunk, builder);
    });
  }
}
