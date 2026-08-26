/// The OpenAI chat-completions wire format.
///
/// # One adapter, many providers
///
/// OpenAI's `/chat/completions` shape became the de facto standard. DeepSeek,
/// xAI's Grok, Mistral, Together, Groq, Fireworks, OpenRouter, Ollama and
/// llama.cpp's server all speak it, and they differ only in base URL, model
/// identifier and which optional fields they honour.
///
/// Writing nine near-identical adapters would mean nine copies of the same
/// tool-call assembly and the same error mapping, drifting apart with every fix.
/// This is one adapter with named constructors for the common hosts, plus
/// [OpenAiCompatibleChatModel.custom] for anything else — including a local
/// server on `localhost:11434`.
///
/// ```dart
/// final gpt = OpenAiCompatibleChatModel.openAi(apiKey: key, model: 'gpt-4o');
/// final local = OpenAiCompatibleChatModel.ollama(model: 'qwen2.5:7b');
/// ```
///
/// Capabilities differ, so each constructor declares its own. That is not
/// bookkeeping: a caller asking for structured output against a local 7B model
/// should get a clear failure, not a plausible-looking hallucination.
library;

import 'dart:async';
import 'dart:convert';

import 'package:agentic_core/agentic_core.dart';
import 'package:agentic_llm/src/model/chat_chunk.dart';
import 'package:agentic_llm/src/model/chat_model.dart';
import 'package:agentic_llm/src/model/chat_request.dart';
import 'package:agentic_llm/src/model/chat_response.dart';
import 'package:agentic_llm/src/model/embedding_model.dart';
import 'package:agentic_llm/src/model/model_info.dart';
import 'package:agentic_llm/src/transport/http_transport.dart';
import 'package:http/http.dart' as http;

/// A chat model speaking the OpenAI `/chat/completions` format.
final class OpenAiCompatibleChatModel implements ChatModel {
  /// Creates an adapter against an arbitrary OpenAI-compatible endpoint.
  ///
  /// Declare [capabilities] honestly. The default is
  /// [ModelCapabilities.standard], which claims tool calling and JSON mode but
  /// not guaranteed structured output — the right assumption for an unknown
  /// server.
  OpenAiCompatibleChatModel.custom({
    required Uri baseUrl,
    required String model,
    required String provider,
    String? apiKey,
    Set<ModelCapability> capabilities = ModelCapabilities.standard,
    int? contextWindow,
    int? maxOutputTokens,
    ModelPricing? pricing,
    bool isLocal = false,
    Map<String, String> headers = const <String, String>{},
    http.Client? client,
    Duration timeout = const Duration(seconds: 120),
    this.chatPath = '/chat/completions',
  }) : info = ModelInfo(
         id: model,
         provider: provider,
         capabilities: capabilities,
         contextWindow: contextWindow,
         maxOutputTokens: maxOutputTokens,
         pricing: pricing,
         isLocal: isLocal,
       ),
       _transport = LlmHttpTransport(
         baseUrl: baseUrl,
         provider: provider,
         timeout: timeout,
         client: client,
         headers: <String, String>{
           if (apiKey != null) 'authorization': 'Bearer $apiKey',
           ...headers,
         },
       );

  /// Creates an adapter for OpenAI itself.
  factory OpenAiCompatibleChatModel.openAi({
    required String apiKey,
    String model = 'gpt-4o',
    Uri? baseUrl,
    String? organization,
    ModelPricing? pricing,
    http.Client? client,
    Set<ModelCapability> capabilities = ModelCapabilities.frontier,
  }) => OpenAiCompatibleChatModel.custom(
    baseUrl: baseUrl ?? Uri.parse('https://api.openai.com/v1'),
    model: model,
    provider: 'openai',
    apiKey: apiKey,
    capabilities: capabilities,
    pricing: pricing,
    client: client,
    headers: <String, String>{'openai-organization': ?organization},
  );

  /// Creates an adapter for DeepSeek.
  factory OpenAiCompatibleChatModel.deepSeek({
    required String apiKey,
    String model = 'deepseek-chat',
    http.Client? client,
  }) => OpenAiCompatibleChatModel.custom(
    baseUrl: Uri.parse('https://api.deepseek.com/v1'),
    model: model,
    provider: 'deepseek',
    apiKey: apiKey,
    client: client,
  );

  /// Creates an adapter for xAI's Grok.
  factory OpenAiCompatibleChatModel.grok({
    required String apiKey,
    String model = 'grok-2-latest',
    http.Client? client,
  }) => OpenAiCompatibleChatModel.custom(
    baseUrl: Uri.parse('https://api.x.ai/v1'),
    model: model,
    provider: 'grok',
    apiKey: apiKey,
    capabilities: ModelCapabilities.frontier,
    client: client,
  );

  /// Creates an adapter for Mistral.
  factory OpenAiCompatibleChatModel.mistral({
    required String apiKey,
    String model = 'mistral-large-latest',
    http.Client? client,
  }) => OpenAiCompatibleChatModel.custom(
    baseUrl: Uri.parse('https://api.mistral.ai/v1'),
    model: model,
    provider: 'mistral',
    apiKey: apiKey,
    client: client,
  );

  /// Creates an adapter for a local Ollama server.
  ///
  /// No API key, no cost, and conservative capabilities: many local models
  /// advertise tool calling through Ollama and then emit malformed calls.
  /// Pass [capabilities] explicitly once you have verified a specific model.
  factory OpenAiCompatibleChatModel.ollama({
    required String model,
    Uri? baseUrl,
    Set<ModelCapability> capabilities = ModelCapabilities.localMinimal,
    http.Client? client,
  }) => OpenAiCompatibleChatModel.custom(
    baseUrl: baseUrl ?? Uri.parse('http://localhost:11434/v1'),
    model: model,
    provider: 'ollama',
    capabilities: capabilities,
    isLocal: true,
    client: client,
  );

  /// Creates an adapter for a llama.cpp server.
  factory OpenAiCompatibleChatModel.llamaCpp({
    String model = 'local',
    Uri? baseUrl,
    Set<ModelCapability> capabilities = ModelCapabilities.localMinimal,
    http.Client? client,
  }) => OpenAiCompatibleChatModel.custom(
    baseUrl: baseUrl ?? Uri.parse('http://localhost:8080/v1'),
    model: model,
    provider: 'llamacpp',
    capabilities: capabilities,
    isLocal: true,
    client: client,
  );

  @override
  final ModelInfo info;

  /// Path of the chat endpoint, relative to the base URL.
  final String chatPath;

  final LlmHttpTransport _transport;

  @override
  Future<ChatResponse> generate(
    ChatRequest request, {
    AgenticContext? context,
  }) async {
    checkSupports(request);
    final started = context?.clock.now();

    final json = await _transport.postJson(
      chatPath,
      _buildBody(request, stream: false),
      context: context,
    );

    final response = _parseResponse(json);
    final elapsed = started == null
        ? null
        : context!.clock.now().difference(started);
    return response.copyWith(
      latency: elapsed,
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

    final events = _transport.postSse(
      chatPath,
      _buildBody(request, stream: true),
      context: context,
    );

    var sawFinish = false;
    await for (final event in events) {
      // OpenAI terminates with a literal sentinel rather than by closing the
      // stream. Everything after it is noise.
      if (event.data.trim() == '[DONE]') break;
      if (event.isEmpty) continue;

      final chunk = _parseChunk(event.json());
      if (chunk == null) continue;
      if (chunk.isFinal) sawFinish = true;
      yield chunk;
    }

    // Several compatible servers close the connection without ever sending a
    // finish reason. Synthesising one keeps the contract — a stream always ends
    // with a terminal chunk — so no consumer has to special-case them.
    if (!sawFinish) {
      yield const ChatChunk.done();
    }
  }

  @override
  Future<void> dispose() => _transport.dispose();

  // ---------------------------------------------------------------------------
  // Request encoding
  // ---------------------------------------------------------------------------

  JsonMap _buildBody(ChatRequest request, {required bool stream}) {
    final body = <String, Object?>{
      'model': info.id,
      'messages': _encodeMessages(request.messages),
      'stream': stream,
      // Without this, OpenAI omits usage entirely from streamed responses, and
      // every cost meter silently reads zero.
      if (stream) 'stream_options': <String, Object?>{'include_usage': true},
      'temperature': request.temperature,
      'top_p': request.topP,
      'max_completion_tokens': request.maxOutputTokens,
      'seed': request.seed,
      'frequency_penalty': request.frequencyPenalty,
      'presence_penalty': request.presencePenalty,
      'user': request.user,
      if (request.stopSequences.isNotEmpty) 'stop': request.stopSequences,
      if (request.reasoningEffort case final effort?)
        'reasoning_effort': effort.name,
      ..._encodeTools(request),
      ..._encodeResponseFormat(request.responseFormat),
    };
    // Provider options are merged last so they can override anything above,
    // which is what makes the escape hatch actually useful.
    return <String, Object?>{...pruneNulls(body), ...request.providerOptions};
  }

  List<JsonMap> _encodeMessages(List<Message> messages) {
    final encoded = <JsonMap>[];
    for (final message in messages) {
      switch (message.role) {
        case MessageRole.tool:
          // One wire message per tool result: the format correlates by
          // `tool_call_id`, and batching them would lose the correlation.
          for (final result in message.toolResults) {
            encoded.add(<String, Object?>{
              'role': 'tool',
              'tool_call_id': result.callId,
              'content': result.content,
            });
          }
        case MessageRole.assistant:
          encoded.add(_encodeAssistant(message));
        case MessageRole.system:
        case MessageRole.developer:
        case MessageRole.user:
          encoded.add(
            pruneNulls(<String, Object?>{
              'role': message.role.wireName,
              'content': _encodeContent(message),
              'name': message.name,
            }),
          );
      }
    }
    return encoded;
  }

  JsonMap _encodeAssistant(Message message) {
    final calls = message.toolCalls;
    return pruneNulls(<String, Object?>{
      'role': 'assistant',
      // An assistant turn that only requests tools has no text, and the field
      // must be null rather than an empty string for several servers.
      'content': message.text.isEmpty ? null : message.text,
      'name': message.name,
      if (calls.isNotEmpty)
        'tool_calls': <JsonMap>[
          for (final call in calls)
            <String, Object?>{
              'id': call.id,
              'type': 'function',
              'function': <String, Object?>{
                'name': call.name,
                // Echo the original text when there is one: re-encoding can
                // reorder keys, and some providers checksum this field.
                'arguments': call.rawArguments ?? jsonEncode(call.arguments),
              },
            },
        ],
    });
  }

  /// Encodes content as a plain string when possible, an array when not.
  ///
  /// The string form is not merely shorter: several compatible servers reject
  /// the array form outright, so using it unconditionally would break every
  /// local deployment.
  Object _encodeContent(Message message) {
    if (!message.isMultimodal) return message.text;

    final parts = <JsonMap>[];
    for (final part in message.parts) {
      switch (part) {
        case TextPart(:final text):
          parts.add(<String, Object?>{'type': 'text', 'text': text});
        case ImagePart():
          parts.add(<String, Object?>{
            'type': 'image_url',
            'image_url': pruneNulls(<String, Object?>{
              'url': part.isInline ? part.toDataUri() : part.uri.toString(),
              'detail': part.detail,
            }),
          });
        case AudioPart():
          if (part.isInline) {
            parts.add(<String, Object?>{
              'type': 'input_audio',
              'input_audio': <String, Object?>{
                'data': part.toBase64(),
                'format': part.mimeType.split('/').last,
              },
            });
          } else if (part.transcript case final transcript?) {
            // A referenced audio file cannot be inlined, but its transcript
            // still carries the content. Degrading beats dropping the turn.
            parts.add(<String, Object?>{'type': 'text', 'text': transcript});
          }
        case FilePart():
          parts.add(<String, Object?>{
            'type': 'file',
            'file': pruneNulls(<String, Object?>{
              'file_id': part.providerFileId,
              'filename': part.name,
              'file_data': part.isInline ? part.toDataUri() : null,
            }),
          });
        case ReasoningPart():
        case ToolCallPart():
        case ToolResultPart():
        // Handled by the enclosing message encoder, not as content.
      }
    }
    return parts;
  }

  Map<String, Object?> _encodeTools(ChatRequest request) {
    final tools = request.tools;
    if (tools == null || tools.isEmpty) return const <String, Object?>{};
    return <String, Object?>{
      'tools': <JsonMap>[
        for (final spec in tools.specs)
          <String, Object?>{
            'type': 'function',
            'function': spec.toFunctionJson(),
          },
      ],
      'tool_choice': switch (request.toolChoice.mode) {
        ToolChoiceMode.auto => 'auto',
        ToolChoiceMode.none => 'none',
        ToolChoiceMode.required => 'required',
        ToolChoiceMode.specific => <String, Object?>{
          'type': 'function',
          'function': <String, Object?>{'name': request.toolChoice.toolName},
        },
      },
    };
  }

  Map<String, Object?> _encodeResponseFormat(ResponseFormat format) =>
      switch (format.kind) {
        ResponseFormatKind.text => const <String, Object?>{},
        ResponseFormatKind.json => const <String, Object?>{
          'response_format': <String, Object?>{'type': 'json_object'},
        },
        ResponseFormatKind.jsonSchema => <String, Object?>{
          'response_format': <String, Object?>{
            'type': 'json_schema',
            'json_schema': <String, Object?>{
              'name': format.schemaName,
              'strict': format.strict,
              'schema': format.schema!.toJson(),
            },
          },
        },
      };

  // ---------------------------------------------------------------------------
  // Response decoding
  // ---------------------------------------------------------------------------

  ChatResponse _parseResponse(JsonMap json) {
    final choices = json.listOrEmpty('choices');
    if (choices.isEmpty) {
      throw SerializationException(
        '${info.provider} returned no choices. This usually means the request '
        'was filtered or the model produced nothing.',
        path: 'choices',
      );
    }

    final choice = (choices.first! as Map).cast<String, Object?>();
    final message = choice.requireObject('message');

    final parts = <ContentPart>[
      if (message.optionalString('reasoning_content') case final reasoning?)
        if (reasoning.isNotEmpty) ReasoningPart(reasoning),
      if (message.optionalString('content') case final content?)
        if (content.isNotEmpty) TextPart(content),
      ..._parseToolCalls(message.listOrEmpty('tool_calls')),
    ];

    return ChatResponse(
      message: Message(role: MessageRole.assistant, parts: parts),
      modelId: json.stringOr('model', info.id),
      usage: _parseUsage(json.optionalObject('usage')),
      finishReason: _parseFinishReason(choice.optionalString('finish_reason')),
      requestId: json.optionalString('id'),
    );
  }

  List<ToolCallPart> _parseToolCalls(JsonList raw) {
    final calls = <ToolCallPart>[];
    for (var i = 0; i < raw.length; i++) {
      final entry = raw[i];
      if (entry is! Map) continue;
      final call = entry.cast<String, Object?>();
      final function = call.optionalObject('function');
      if (function == null) continue;

      final arguments = function.stringOr('arguments', '');
      calls.add(
        ToolCallPart(
          id: call.stringOr('id', 'call_$i'),
          name: function.stringOr('name', ''),
          arguments: _decodeArguments(arguments),
          rawArguments: arguments.isEmpty ? null : arguments,
        ),
      );
    }
    return calls;
  }

  /// Decodes tool-call arguments, tolerating malformed JSON.
  ///
  /// A model that emitted invalid JSON should be told so and given a chance to
  /// fix it, which is what happens when empty arguments fail schema validation
  /// in the tool executor. Throwing here would end the run instead.
  static Map<String, Object?> _decodeArguments(String raw) {
    if (raw.trim().isEmpty) return const <String, Object?>{};
    try {
      final decoded = jsonDecode(raw);
      return decoded is Map
          ? decoded.cast<String, Object?>()
          : const <String, Object?>{};
    } on FormatException {
      return const <String, Object?>{};
    }
  }

  ChatChunk? _parseChunk(JsonMap json) {
    final choices = json.listOrEmpty('choices');
    final usage = _parseUsage(json.optionalObject('usage'));
    final modelId = json.optionalString('model');

    if (choices.isEmpty) {
      // The final usage-only frame OpenAI sends when `include_usage` is set.
      if (usage.isEmpty) return null;
      return ChatChunk(usage: usage, modelId: modelId);
    }

    final choice = (choices.first! as Map).cast<String, Object?>();
    final delta = choice.optionalObject('delta') ?? const <String, Object?>{};
    final finish = _parseFinishReasonOrNull(
      choice.optionalString('finish_reason'),
    );

    final toolCalls = delta.listOrEmpty('tool_calls');
    if (toolCalls.isNotEmpty) {
      final entry = (toolCalls.first! as Map).cast<String, Object?>();
      final function = entry.optionalObject('function');
      return ChatChunk(
        toolCall: ToolCallDelta(
          index: entry.intOr('index', 0),
          id: entry.optionalString('id'),
          name: function?.optionalString('name'),
          argumentsDelta: function?.optionalString('arguments'),
        ),
        finishReason: finish,
        usage: usage.isEmpty ? null : usage,
        modelId: modelId,
      );
    }

    final content = delta.optionalString('content');
    final reasoning = delta.optionalString('reasoning_content');

    if (content == null && reasoning == null && finish == null) {
      // A role-announcement or keep-alive frame carries nothing to accumulate.
      return usage.isEmpty ? null : ChatChunk(usage: usage, modelId: modelId);
    }

    return ChatChunk(
      textDelta: content,
      reasoningDelta: reasoning,
      finishReason: finish,
      usage: usage.isEmpty ? null : usage,
      modelId: modelId,
    );
  }

  static TokenUsage _parseUsage(JsonMap? json) {
    if (json == null) return TokenUsage.empty;
    final promptDetails = json.optionalObject('prompt_tokens_details');
    final completionDetails = json.optionalObject('completion_tokens_details');
    return TokenUsage(
      promptTokens: json.intOr('prompt_tokens', 0),
      completionTokens: json.intOr('completion_tokens', 0),
      totalTokens: json.optionalInt('total_tokens'),
      cachedPromptTokens: promptDetails?.intOr('cached_tokens', 0) ?? 0,
      reasoningTokens: completionDetails?.intOr('reasoning_tokens', 0) ?? 0,
    );
  }

  static FinishReason _parseFinishReason(String? raw) =>
      _parseFinishReasonOrNull(raw) ?? FinishReason.stop;

  static FinishReason? _parseFinishReasonOrNull(String? raw) => switch (raw) {
    null => null,
    'stop' || 'end_turn' || 'stop_sequence' => FinishReason.stop,
    'length' || 'max_tokens' => FinishReason.length,
    'tool_calls' || 'function_call' => FinishReason.toolCalls,
    'content_filter' => FinishReason.contentFilter,
    // An unrecognised reason must not break the call; it is reported as such.
    _ => FinishReason.unknown,
  };

  @override
  String toString() => 'OpenAiCompatibleChatModel(${info.qualifiedId})';
}

/// An embedding model speaking the OpenAI `/embeddings` format.
///
/// Shares the wire format with every OpenAI-compatible host, so one adapter
/// serves OpenAI, Mistral, Together, Ollama and the rest.
final class OpenAiCompatibleEmbeddingModel implements EmbeddingModel {
  /// Creates an adapter against an arbitrary OpenAI-compatible endpoint.
  OpenAiCompatibleEmbeddingModel.custom({
    required Uri baseUrl,
    required String model,
    required String provider,
    required this.dimensions,
    String? apiKey,
    this.maxBatchSize = 96,
    this.embeddingsPath = '/embeddings',
    ModelPricing? pricing,
    bool isLocal = false,
    http.Client? client,
    Map<String, String> headers = const <String, String>{},
  }) : info = ModelInfo(
         id: model,
         provider: provider,
         capabilities: const <ModelCapability>{},
         pricing: pricing,
         isLocal: isLocal,
       ),
       _transport = LlmHttpTransport(
         baseUrl: baseUrl,
         provider: provider,
         client: client,
         headers: <String, String>{
           if (apiKey != null) 'authorization': 'Bearer $apiKey',
           ...headers,
         },
       );

  /// Creates an adapter for OpenAI's embedding models.
  ///
  /// [dimensions] defaults to the full width of `text-embedding-3-small`.
  /// OpenAI's v3 models support truncation to a smaller width, which trades a
  /// little accuracy for a large saving in index size — often the right call on
  /// a device.
  factory OpenAiCompatibleEmbeddingModel.openAi({
    required String apiKey,
    String model = 'text-embedding-3-small',
    int dimensions = 1536,
    http.Client? client,
  }) => OpenAiCompatibleEmbeddingModel.custom(
    baseUrl: Uri.parse('https://api.openai.com/v1'),
    model: model,
    provider: 'openai',
    apiKey: apiKey,
    dimensions: dimensions,
    client: client,
  );

  /// Creates an adapter for a local Ollama server.
  factory OpenAiCompatibleEmbeddingModel.ollama({
    required String model,
    required int dimensions,
    Uri? baseUrl,
    http.Client? client,
  }) => OpenAiCompatibleEmbeddingModel.custom(
    baseUrl: baseUrl ?? Uri.parse('http://localhost:11434/v1'),
    model: model,
    provider: 'ollama',
    dimensions: dimensions,
    isLocal: true,
    client: client,
  );

  @override
  final ModelInfo info;

  @override
  final int dimensions;

  @override
  final int maxBatchSize;

  /// Path of the embeddings endpoint, relative to the base URL.
  final String embeddingsPath;

  final LlmHttpTransport _transport;

  @override
  Future<List<Embedding>> embed(
    List<String> inputs, {
    required EmbeddingPurpose purpose,
    AgenticContext? context,
  }) async {
    if (inputs.isEmpty) return const <Embedding>[];
    if (inputs.length > maxBatchSize) {
      throw ValidationException(
        'This model accepts at most $maxBatchSize inputs per call, got '
        '${inputs.length}. Use `embedAll` to batch automatically.',
        violations: <String>['inputs: ${inputs.length} > $maxBatchSize'],
      );
    }

    final json = await _transport.postJson(
      embeddingsPath,
      pruneNulls(<String, Object?>{
        'model': info.id,
        'input': inputs,
        // OpenAI's v3 models honour this; hosts that do not simply ignore it.
        'dimensions': dimensions,
      }),
      context: context,
    );

    final data = json.listOrEmpty('data');
    final embeddings = <Embedding>[];
    for (final entry in data) {
      if (entry is! Map) continue;
      final item = entry.cast<String, Object?>();
      embeddings.add(
        Embedding(
          values: item
              .requireList('embedding')
              .map((v) => (v! as num).toDouble())
              .toList(),
          index: item.intOr('index', embeddings.length),
        ),
      );
    }
    // Providers do not guarantee ordering; the caller's contract does.
    embeddings.sort((a, b) => a.index.compareTo(b.index));
    return embeddings;
  }

  @override
  Future<void> dispose() => _transport.dispose();

  @override
  String toString() => 'OpenAiCompatibleEmbeddingModel(${info.qualifiedId})';
}
