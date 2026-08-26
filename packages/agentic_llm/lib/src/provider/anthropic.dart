/// The Anthropic Messages API.
///
/// # Why this needs its own adapter
///
/// Anthropic is not OpenAI-compatible, and the differences are structural
/// rather than cosmetic. Each one is a place where a naive translation produces
/// a request the API rejects, or worse, silently mishandles:
///
/// * **System prompts are hoisted.** There is no `system` role in the message
///   list; the instruction is a top-level field. A system message left in the
///   array is a 400.
/// * **Tool results are *user* turns.** OpenAI has a dedicated `tool` role;
///   Anthropic sends `tool_result` content blocks inside a user message, and
///   several results are batched into one turn — the exact opposite of the
///   OpenAI rule of one message per result.
/// * **Content is always blocks.** Text, images, tool uses and tool results are
///   all typed blocks in an array.
/// * **`max_tokens` is required.** Omitting it is a 400, so this adapter
///   supplies a default rather than failing on a request that every other
///   provider accepts.
/// * **Streaming is event-typed.** Instead of one repeated chunk shape, there
///   are seven named event types, and tool arguments arrive as
///   `input_json_delta` fragments against a block index.
/// * **Thinking blocks carry signatures** that must be echoed back verbatim on
///   the next turn or the conversation is rejected.
///
/// Everything above is absorbed here. Nothing above this file knows Anthropic
/// exists.
library;

import 'dart:async';
import 'dart:convert';

import 'package:agentic_core/agentic_core.dart';
import 'package:agentic_llm/src/model/chat_chunk.dart';
import 'package:agentic_llm/src/model/chat_model.dart';
import 'package:agentic_llm/src/model/chat_request.dart';
import 'package:agentic_llm/src/model/chat_response.dart';
import 'package:agentic_llm/src/model/model_info.dart';
import 'package:agentic_llm/src/transport/http_transport.dart';
import 'package:http/http.dart' as http;

/// A chat model speaking Anthropic's Messages API.
///
/// ```dart
/// final claude = AnthropicChatModel(
///   apiKey: key,
///   model: 'claude-sonnet-4-20250514',
/// );
/// ```
final class AnthropicChatModel implements ChatModel {
  /// Creates an adapter.
  ///
  /// [defaultMaxTokens] is used when a request does not set
  /// `maxOutputTokens`, because the API requires the field. The default is
  /// deliberately generous: silently truncating an answer is a far worse
  /// failure than a slightly larger bill.
  AnthropicChatModel({
    required String apiKey,
    String model = 'claude-sonnet-4-20250514',
    Uri? baseUrl,
    this.apiVersion = '2023-06-01',
    this.defaultMaxTokens = 4096,
    Set<ModelCapability> capabilities = _defaultCapabilities,
    int? contextWindow,
    ModelPricing? pricing,
    Map<String, String> headers = const <String, String>{},
    http.Client? client,
    Duration timeout = const Duration(seconds: 120),
  }) : info = ModelInfo(
         id: model,
         provider: 'anthropic',
         capabilities: capabilities,
         contextWindow: contextWindow,
         pricing: pricing,
       ),
       _transport = LlmHttpTransport(
         baseUrl: baseUrl ?? Uri.parse('https://api.anthropic.com/v1'),
         provider: 'anthropic',
         timeout: timeout,
         client: client,
         requestIdHeaders: const <String>['request-id', 'x-request-id'],
         headers: <String, String>{
           'x-api-key': apiKey,
           'anthropic-version': apiVersion,
           ...headers,
         },
       );

  static const Set<ModelCapability> _defaultCapabilities = <ModelCapability>{
    ModelCapability.toolCalling,
    ModelCapability.parallelToolCalls,
    ModelCapability.streaming,
    ModelCapability.vision,
    ModelCapability.reasoning,
    ModelCapability.promptCaching,
    ModelCapability.systemPrompt,
    // Deliberately absent: Anthropic has no `response_format`. Schema-shaped
    // output is achieved by forcing a tool call instead, which
    // `generateStructured` does automatically — so claiming the capability here
    // would be a lie that produces worse results.
  };

  @override
  final ModelInfo info;

  /// The `anthropic-version` header sent on every request.
  final String apiVersion;

  /// Value used when a request omits `maxOutputTokens`.
  final int defaultMaxTokens;

  final LlmHttpTransport _transport;

  @override
  Future<ChatResponse> generate(
    ChatRequest request, {
    AgenticContext? context,
  }) async {
    checkSupports(request);
    final started = context?.clock.now();

    final json = await _transport.postJson(
      '/messages',
      _buildBody(request, stream: false),
      context: context,
    );

    final response = _parseResponse(json);
    return response.copyWith(
      latency: started == null
          ? null
          : context!.clock.now().difference(started),
      cost: info.estimateCost(response.usage),
      metadata: request.metadata,
    );
  }

  @override
  Stream<ChatChunk> stream(
    ChatRequest request, {
    AgenticContext? context,
  }) async* {
    checkSupports(request);
    info.requireCapability(ModelCapability.streaming);

    // Anthropic reports input and output tokens in different events, so usage
    // has to be accumulated across the stream and emitted as a running total.
    var promptTokens = 0;
    var cachedTokens = 0;
    var completionTokens = 0;
    String? modelId;

    // Block index to tool-call index. Anthropic indexes *content blocks*, and a
    // turn's blocks include text as well as tool uses — so block 1 may be tool
    // call 0. Emitting the block index directly would misattribute fragments
    // whenever a model writes prose before calling a tool, which is most times.
    final toolIndexOfBlock = <int, int>{};
    var nextToolIndex = 0;

    final events = _transport.postSse(
      '/messages',
      _buildBody(request, stream: true),
      context: context,
    );

    await for (final event in events) {
      if (event.isEmpty) continue;
      final json = event.json();
      final type = event.event ?? json.stringOr('type', '');

      switch (type) {
        case 'message_start':
          final message = json.optionalObject('message');
          modelId = message?.optionalString('model');
          final usage = message?.optionalObject('usage');
          if (usage != null) {
            promptTokens = usage.intOr('input_tokens', 0);
            cachedTokens = usage.intOr('cache_read_input_tokens', 0);
            completionTokens = usage.intOr('output_tokens', 0);
          }
          yield ChatChunk(
            modelId: modelId,
            requestId: message?.optionalString('id'),
          );

        case 'content_block_start':
          final index = json.intOr('index', 0);
          final block = json.optionalObject('content_block');
          if (block == null) continue;
          if (block.stringOr('type', '') == 'tool_use') {
            final toolIndex = nextToolIndex++;
            toolIndexOfBlock[index] = toolIndex;
            yield ChatChunk.tool(
              ToolCallDelta(
                index: toolIndex,
                id: block.optionalString('id'),
                name: block.optionalString('name'),
              ),
            );
          }

        case 'content_block_delta':
          final index = json.intOr('index', 0);
          final delta = json.optionalObject('delta');
          if (delta == null) continue;
          switch (delta.stringOr('type', '')) {
            case 'text_delta':
              yield ChatChunk.text(delta.stringOr('text', ''));
            case 'thinking_delta':
              yield ChatChunk.reasoning(delta.stringOr('thinking', ''));
            case 'signature_delta':
              yield ChatChunk(
                reasoningSignature: delta.optionalString('signature'),
              );
            case 'input_json_delta':
              yield ChatChunk.tool(
                ToolCallDelta(
                  index: toolIndexOfBlock[index] ?? index,
                  argumentsDelta: delta.stringOr('partial_json', ''),
                ),
              );
          }

        case 'message_delta':
          final usage = json.optionalObject('usage');
          if (usage != null) {
            completionTokens = usage.intOr('output_tokens', completionTokens);
          }
          final reason = json
              .optionalObject('delta')
              ?.optionalString('stop_reason');
          if (reason != null) {
            yield ChatChunk(
              finishReason: _parseStopReason(reason),
              usage: TokenUsage(
                promptTokens: promptTokens,
                completionTokens: completionTokens,
                cachedPromptTokens: cachedTokens,
              ),
              modelId: modelId,
            );
          }

        case 'error':
          final error = json.optionalObject('error');
          throw ProviderException(
            'Anthropic failed mid-stream: '
            '${error?.optionalString('message') ?? 'unknown error'}',
            provider: 'anthropic',
            providerCode: error?.optionalString('type'),
            // An overloaded_error mid-stream is transient; anything else is
            // not, and retrying a rejected request wastes the budget.
            retryable: error?.optionalString('type') == 'overloaded_error',
          );

        case 'message_stop':
        case 'content_block_stop':
        case 'ping':
        // Nothing to accumulate.
      }
    }
  }

  @override
  Future<void> dispose() => _transport.dispose();

  // ---------------------------------------------------------------------------
  // Request encoding
  // ---------------------------------------------------------------------------

  JsonMap _buildBody(ChatRequest request, {required bool stream}) {
    final system = request.messages.systemMessages;
    final conversation = _encodeConversation(request.messages.conversation);

    final body = <String, Object?>{
      'model': info.id,
      'messages': conversation,
      // Required by the API. Every other provider treats it as optional, so
      // supplying a default here keeps a portable request portable.
      'max_tokens': request.maxOutputTokens ?? defaultMaxTokens,
      'stream': stream,
      'temperature': request.temperature,
      'top_p': request.topP,
      'top_k': request.topK,
      if (system.isNotEmpty)
        'system': system.map((message) => message.text).join('\n\n'),
      if (request.stopSequences.isNotEmpty)
        'stop_sequences': request.stopSequences,
      if (request.reasoningEffort case final effort?)
        if (effort != ReasoningEffort.none)
          'thinking': <String, Object?>{
            'type': 'enabled',
            'budget_tokens': _thinkingBudget(effort, request),
          },
      ..._encodeTools(request),
    };
    return <String, Object?>{...pruneNulls(body), ...request.providerOptions};
  }

  /// Converts an effort level into a token budget.
  ///
  /// The budget must be smaller than `max_tokens`, or the API rejects the
  /// request — so it is clamped against whatever the caller asked for rather
  /// than taken as an absolute.
  int _thinkingBudget(ReasoningEffort effort, ChatRequest request) {
    final ceiling = request.maxOutputTokens ?? defaultMaxTokens;
    final requested = switch (effort) {
      ReasoningEffort.none => 0,
      ReasoningEffort.low => 1024,
      ReasoningEffort.medium => 4096,
      ReasoningEffort.high => 16384,
    };
    final limit = (ceiling * 0.8).floor();
    return requested < limit ? requested : limit;
  }

  /// Encodes the conversation into Anthropic's user/assistant alternation.
  ///
  /// Tool results are the interesting part: they are `tool_result` blocks in a
  /// *user* turn, and consecutive results must be merged into one turn. Sending
  /// them as separate turns produces two user messages in a row, which the API
  /// rejects.
  List<JsonMap> _encodeConversation(List<Message> messages) {
    final encoded = <JsonMap>[];
    var pendingToolResults = <JsonMap>[];

    void flushToolResults() {
      if (pendingToolResults.isEmpty) return;
      encoded.add(<String, Object?>{
        'role': 'user',
        'content': pendingToolResults,
      });
      pendingToolResults = <JsonMap>[];
    }

    for (final message in messages) {
      switch (message.role) {
        case MessageRole.tool:
          for (final result in message.toolResults) {
            pendingToolResults.add(<String, Object?>{
              'type': 'tool_result',
              'tool_use_id': result.callId,
              'content': result.content,
              if (result.isError) 'is_error': true,
            });
          }
        case MessageRole.user:
          flushToolResults();
          encoded.add(<String, Object?>{
            'role': 'user',
            'content': _encodeBlocks(message),
          });
        case MessageRole.assistant:
          flushToolResults();
          encoded.add(<String, Object?>{
            'role': 'assistant',
            'content': _encodeBlocks(message),
          });
        case MessageRole.system:
        case MessageRole.developer:
        // Hoisted into the top-level `system` field by the caller.
      }
    }
    flushToolResults();
    return encoded;
  }

  List<JsonMap> _encodeBlocks(Message message) {
    final blocks = <JsonMap>[];
    for (final part in message.parts) {
      switch (part) {
        case TextPart(:final text):
          if (text.isNotEmpty) {
            blocks.add(<String, Object?>{'type': 'text', 'text': text});
          }
        case ReasoningPart(:final text, :final signature):
          // The signature must survive the round trip untouched, or the next
          // turn is rejected. A reasoning block without one is dropped rather
          // than sent unsigned.
          if (signature != null) {
            blocks.add(<String, Object?>{
              'type': 'thinking',
              'thinking': text,
              'signature': signature,
            });
          }
        case ImagePart():
          blocks.add(<String, Object?>{
            'type': 'image',
            'source': part.isInline
                ? <String, Object?>{
                    'type': 'base64',
                    'media_type': part.mimeType,
                    'data': part.toBase64(),
                  }
                : <String, Object?>{'type': 'url', 'url': part.uri.toString()},
          });
        case FilePart():
          blocks.add(<String, Object?>{
            'type': 'document',
            'source': part.isInline
                ? <String, Object?>{
                    'type': 'base64',
                    'media_type': part.mimeType,
                    'data': part.toBase64(),
                  }
                : <String, Object?>{'type': 'url', 'url': part.uri.toString()},
          });
        case ToolCallPart(:final id, :final name, :final arguments):
          blocks.add(<String, Object?>{
            'type': 'tool_use',
            'id': id,
            'name': name,
            'input': arguments,
          });
        case AudioPart():
          // Anthropic accepts no audio. The transcript preserves the content
          // instead of dropping the turn entirely.
          if (part.transcript case final transcript?) {
            blocks.add(<String, Object?>{'type': 'text', 'text': transcript});
          }
        case ToolResultPart():
        // Handled by the conversation encoder, which must merge them.
      }
    }
    // A turn with no blocks is rejected, and an assistant turn can legitimately
    // be empty when a model answered with tool calls alone.
    if (blocks.isEmpty) {
      blocks.add(const <String, Object?>{'type': 'text', 'text': ''});
    }
    return blocks;
  }

  Map<String, Object?> _encodeTools(ChatRequest request) {
    final tools = request.tools;
    if (tools == null || tools.isEmpty) return const <String, Object?>{};
    return <String, Object?>{
      'tools': <JsonMap>[
        for (final spec in tools.specs)
          <String, Object?>{
            'name': spec.name,
            'description': spec.toFunctionJson()['description'],
            'input_schema': spec.parameters.toJson(),
          },
      ],
      'tool_choice': switch (request.toolChoice.mode) {
        ToolChoiceMode.auto => <String, Object?>{'type': 'auto'},
        ToolChoiceMode.none => <String, Object?>{'type': 'none'},
        ToolChoiceMode.required => <String, Object?>{'type': 'any'},
        ToolChoiceMode.specific => <String, Object?>{
          'type': 'tool',
          'name': request.toolChoice.toolName,
        },
      },
    };
  }

  // ---------------------------------------------------------------------------
  // Response decoding
  // ---------------------------------------------------------------------------

  ChatResponse _parseResponse(JsonMap json) {
    final parts = <ContentPart>[];

    for (final entry in json.listOrEmpty('content')) {
      if (entry is! Map) continue;
      final block = entry.cast<String, Object?>();
      switch (block.stringOr('type', '')) {
        case 'text':
          parts.add(TextPart(block.stringOr('text', '')));
        case 'thinking':
          parts.add(
            ReasoningPart(
              block.stringOr('thinking', ''),
              signature: block.optionalString('signature'),
            ),
          );
        case 'redacted_thinking':
          parts.add(
            ReasoningPart(block.stringOr('data', ''), isRedacted: true),
          );
        case 'tool_use':
          final input =
              block.optionalObject('input') ?? const <String, Object?>{};
          parts.add(
            ToolCallPart(
              id: block.stringOr('id', ''),
              name: block.stringOr('name', ''),
              arguments: input,
              rawArguments: jsonEncode(input),
            ),
          );
      }
    }

    final usage = json.optionalObject('usage');
    return ChatResponse(
      message: Message(role: MessageRole.assistant, parts: parts),
      modelId: json.stringOr('model', info.id),
      requestId: json.optionalString('id'),
      finishReason: _parseStopReason(json.optionalString('stop_reason')),
      usage: TokenUsage(
        promptTokens: usage?.intOr('input_tokens', 0) ?? 0,
        completionTokens: usage?.intOr('output_tokens', 0) ?? 0,
        cachedPromptTokens: usage?.intOr('cache_read_input_tokens', 0) ?? 0,
      ),
    );
  }

  static FinishReason _parseStopReason(String? raw) => switch (raw) {
    'end_turn' || 'stop_sequence' => FinishReason.stop,
    'max_tokens' => FinishReason.length,
    'tool_use' => FinishReason.toolCalls,
    'refusal' => FinishReason.contentFilter,
    null => FinishReason.stop,
    _ => FinishReason.unknown,
  };

  @override
  String toString() => 'AnthropicChatModel(${info.qualifiedId})';
}
