/// The Google Gemini generative-language API.
///
/// # A third wire shape
///
/// Gemini differs from both of the others, and again structurally:
///
/// * **Turns are `contents`, not messages**, and the assistant role is spelled
///   `model`.
/// * **Everything is a `part`** — text, inline data, function calls and
///   function responses are all entries in a `parts` array.
/// * **The system instruction is its own top-level object**, like Anthropic's.
/// * **Sampling parameters live under `generationConfig`**, not at the root.
/// * **Structured output is `responseSchema`**, which is an OpenAPI subset
///   rather than JSON Schema: it rejects `additionalProperties`, which every
///   schema this framework produces sets.
/// * **The model name is in the URL path**, and streaming is a different path
///   with `?alt=sse`.
/// * **The API key is a query parameter or an `x-goog-api-key` header**, not a
///   bearer token.
///
/// Supporting a third genuinely different shape is what demonstrates the
/// abstraction holds. If `ChatRequest` had quietly been an OpenAI request in
/// disguise, this adapter is where that would have become obvious.
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

/// A chat model speaking Google's `generateContent` API.
///
/// ```dart
/// final gemini = GeminiChatModel(apiKey: key, model: 'gemini-2.0-flash');
/// ```
final class GeminiChatModel implements ChatModel {
  /// Creates an adapter.
  GeminiChatModel({
    required String apiKey,
    String model = 'gemini-2.0-flash',
    Uri? baseUrl,
    Set<ModelCapability> capabilities = _defaultCapabilities,
    int? contextWindow,
    ModelPricing? pricing,
    Map<String, String> headers = const <String, String>{},
    http.Client? client,
    Duration timeout = const Duration(seconds: 120),
  }) : info = ModelInfo(
         id: model,
         provider: 'gemini',
         capabilities: capabilities,
         contextWindow: contextWindow,
         pricing: pricing,
       ),
       _transport = LlmHttpTransport(
         baseUrl:
             baseUrl ??
             Uri.parse('https://generativelanguage.googleapis.com/v1beta'),
         provider: 'gemini',
         timeout: timeout,
         client: client,
         // Sent as a header rather than a query parameter so the key never
         // appears in a URL, where it would end up in logs and proxy traces.
         headers: <String, String>{'x-goog-api-key': apiKey, ...headers},
       );

  static const Set<ModelCapability> _defaultCapabilities = <ModelCapability>{
    ModelCapability.toolCalling,
    ModelCapability.parallelToolCalls,
    ModelCapability.streaming,
    ModelCapability.vision,
    ModelCapability.audioInput,
    ModelCapability.jsonMode,
    ModelCapability.structuredOutput,
    ModelCapability.systemPrompt,
  };

  @override
  final ModelInfo info;

  final LlmHttpTransport _transport;

  @override
  Future<ChatResponse> generate(
    ChatRequest request, {
    AgenticContext? context,
  }) async {
    checkSupports(request);
    final started = context?.clock.now();

    final json = await _transport.postJson(
      '/models/${info.id}:generateContent',
      _buildBody(request),
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

    var toolIndex = 0;
    var sawFinish = false;

    final events = _transport.postSse(
      '/models/${info.id}:streamGenerateContent?alt=sse',
      _buildBody(request),
      context: context,
    );

    await for (final event in events) {
      if (event.isEmpty) continue;
      final json = event.json();

      final usage = _parseUsage(json.optionalObject('usageMetadata'));
      final candidates = json.listOrEmpty('candidates');
      if (candidates.isEmpty) {
        if (!usage.isEmpty) yield ChatChunk(usage: usage);
        continue;
      }

      final candidate = (candidates.first! as Map).cast<String, Object?>();
      final parts =
          candidate.optionalObject('content')?.listOrEmpty('parts') ??
          const <Object?>[];

      for (final entry in parts) {
        if (entry is! Map) continue;
        final part = entry.cast<String, Object?>();

        if (part.optionalString('text') case final text?) {
          // Gemini marks reasoning with a flag on an otherwise ordinary text
          // part rather than with a distinct type.
          if (part.boolOr('thought', orElse: false)) {
            yield ChatChunk.reasoning(text);
          } else {
            yield ChatChunk.text(text);
          }
        }

        if (part.optionalObject('functionCall') case final call?) {
          // Gemini sends each function call complete in one part, so the whole
          // argument object arrives at once — no fragment assembly needed. It
          // is still emitted as a delta so that every provider produces the
          // same chunk shape.
          final args = call.optionalObject('args') ?? const <String, Object?>{};
          yield ChatChunk.tool(
            ToolCallDelta(
              index: toolIndex,
              // Gemini issues no call identifier; results are correlated by
              // name. A synthetic one keeps the framework's contract.
              id: 'call_${toolIndex}_${call.stringOr('name', 'unknown')}',
              name: call.optionalString('name'),
              argumentsDelta: jsonEncode(args),
            ),
          );
          toolIndex++;
        }
      }

      final finish = candidate.optionalString('finishReason');
      if (finish != null) {
        sawFinish = true;
        yield ChatChunk(
          finishReason: _parseFinishReason(finish),
          usage: usage.isEmpty ? null : usage,
          modelId: json.optionalString('modelVersion') ?? info.id,
        );
      } else if (!usage.isEmpty) {
        yield ChatChunk(usage: usage);
      }
    }

    if (!sawFinish) yield const ChatChunk.done();
  }

  @override
  Future<void> dispose() => _transport.dispose();

  // ---------------------------------------------------------------------------
  // Request encoding
  // ---------------------------------------------------------------------------

  JsonMap _buildBody(ChatRequest request) {
    final system = request.messages.systemMessages;
    final body = <String, Object?>{
      'contents': _encodeContents(request.messages.conversation),
      if (system.isNotEmpty)
        'systemInstruction': <String, Object?>{
          'parts': <JsonMap>[
            <String, Object?>{
              'text': system.map((message) => message.text).join('\n\n'),
            },
          ],
        },
      'generationConfig': pruneNulls(<String, Object?>{
        'temperature': request.temperature,
        'topP': request.topP,
        'topK': request.topK,
        'maxOutputTokens': request.maxOutputTokens,
        'seed': request.seed,
        if (request.stopSequences.isNotEmpty)
          'stopSequences': request.stopSequences,
        ..._encodeResponseFormat(request.responseFormat),
      }),
      ..._encodeTools(request),
    };
    return <String, Object?>{...pruneNulls(body), ...request.providerOptions};
  }

  List<JsonMap> _encodeContents(List<Message> messages) {
    final contents = <JsonMap>[];
    var pendingResponses = <JsonMap>[];

    void flushResponses() {
      if (pendingResponses.isEmpty) return;
      // Function responses are a user turn, and consecutive ones merge — the
      // same rule as Anthropic, for the same reason: two user turns in a row
      // are rejected.
      contents.add(<String, Object?>{
        'role': 'user',
        'parts': pendingResponses,
      });
      pendingResponses = <JsonMap>[];
    }

    for (final message in messages) {
      switch (message.role) {
        case MessageRole.tool:
          for (final result in message.toolResults) {
            pendingResponses.add(<String, Object?>{
              'functionResponse': <String, Object?>{
                // Correlation is by name, not by identifier: Gemini has no
                // concept of a call id.
                'name': result.name,
                'response': <String, Object?>{
                  if (result.isError)
                    'error': result.content
                  else
                    'result': result.content,
                },
              },
            });
          }
        case MessageRole.user:
          flushResponses();
          contents.add(<String, Object?>{
            'role': 'user',
            'parts': _encodeParts(message),
          });
        case MessageRole.assistant:
          flushResponses();
          contents.add(<String, Object?>{
            'role': 'model',
            'parts': _encodeParts(message),
          });
        case MessageRole.system:
        case MessageRole.developer:
        // Hoisted into `systemInstruction`.
      }
    }
    flushResponses();
    return contents;
  }

  List<JsonMap> _encodeParts(Message message) {
    final parts = <JsonMap>[];
    for (final part in message.parts) {
      switch (part) {
        case TextPart(:final text):
          if (text.isNotEmpty) parts.add(<String, Object?>{'text': text});
        case ImagePart():
        case AudioPart():
        case FilePart():
          final media = part as MediaPart;
          if (media.isInline) {
            parts.add(<String, Object?>{
              'inlineData': <String, Object?>{
                'mimeType': media.mimeType,
                'data': media.toBase64(),
              },
            });
          } else {
            parts.add(<String, Object?>{
              'fileData': <String, Object?>{
                'mimeType': media.mimeType,
                'fileUri': media.uri.toString(),
              },
            });
          }
        case ToolCallPart(:final name, :final arguments):
          parts.add(<String, Object?>{
            'functionCall': <String, Object?>{'name': name, 'args': arguments},
          });
        case ReasoningPart():
        case ToolResultPart():
        // Reasoning is not echoed back, and results are encoded by the
        // conversation encoder.
      }
    }
    if (parts.isEmpty) parts.add(const <String, Object?>{'text': ''});
    return parts;
  }

  Map<String, Object?> _encodeTools(ChatRequest request) {
    final tools = request.tools;
    if (tools == null || tools.isEmpty) return const <String, Object?>{};
    return <String, Object?>{
      'tools': <JsonMap>[
        <String, Object?>{
          'functionDeclarations': <JsonMap>[
            for (final spec in tools.specs)
              <String, Object?>{
                'name': spec.name,
                'description': spec.toFunctionJson()['description'],
                'parameters': _toOpenApiSchema(spec.parameters.toJson()),
              },
          ],
        },
      ],
      'toolConfig': <String, Object?>{
        'functionCallingConfig': pruneNulls(<String, Object?>{
          'mode': switch (request.toolChoice.mode) {
            ToolChoiceMode.auto => 'AUTO',
            ToolChoiceMode.none => 'NONE',
            ToolChoiceMode.required || ToolChoiceMode.specific => 'ANY',
          },
          if (request.toolChoice.mode == ToolChoiceMode.specific)
            'allowedFunctionNames': <String>[request.toolChoice.toolName!],
        }),
      },
    };
  }

  Map<String, Object?> _encodeResponseFormat(ResponseFormat format) =>
      switch (format.kind) {
        ResponseFormatKind.text => const <String, Object?>{},
        ResponseFormatKind.json => const <String, Object?>{
          'responseMimeType': 'application/json',
        },
        ResponseFormatKind.jsonSchema => <String, Object?>{
          'responseMimeType': 'application/json',
          'responseSchema': _toOpenApiSchema(format.schema!.toJson()),
        },
      };

  /// Strips keywords Gemini's OpenAPI subset rejects.
  ///
  /// `additionalProperties` is the important one: this framework sets it on
  /// every object schema, deliberately, and Gemini returns a 400 for any schema
  /// containing it. Sending our schemas unmodified would make structured output
  /// and tool calling fail on every single request — the kind of incompatibility
  /// that is invisible until the first real call.
  static Object? _toOpenApiSchema(Object? schema) {
    if (schema is List) return schema.map(_toOpenApiSchema).toList();
    if (schema is! Map) return schema;

    const unsupported = <String>{
      'additionalProperties',
      'exclusiveMinimum',
      'exclusiveMaximum',
      'multipleOf',
      'uniqueItems',
      'examples',
      'title',
      'default',
    };

    final result = <String, Object?>{};
    for (final entry in schema.entries) {
      final key = entry.key.toString();
      if (unsupported.contains(key)) continue;
      // A nullable type is expressed as a union in JSON Schema and as a
      // `nullable` flag in OpenAPI.
      if (key == 'type' && entry.value is List) {
        final names = (entry.value! as List).whereType<String>().toList();
        final concrete = names.where((name) => name != 'null').toList();
        result['type'] = concrete.isEmpty ? 'string' : concrete.first;
        if (names.contains('null')) result['nullable'] = true;
        continue;
      }
      result[key] = _toOpenApiSchema(entry.value);
    }
    return result;
  }

  // ---------------------------------------------------------------------------
  // Response decoding
  // ---------------------------------------------------------------------------

  ChatResponse _parseResponse(JsonMap json) {
    final candidates = json.listOrEmpty('candidates');
    if (candidates.isEmpty) {
      final feedback = json.optionalObject('promptFeedback');
      throw ProviderException(
        feedback == null
            ? 'Gemini returned no candidates.'
            : 'Gemini blocked the prompt: '
                  '${feedback.stringOr('blockReason', 'unspecified')}',
        provider: 'gemini',
        retryable: false,
      );
    }

    final candidate = (candidates.first! as Map).cast<String, Object?>();
    final parts = <ContentPart>[];
    var toolIndex = 0;

    for (final entry
        in candidate.optionalObject('content')?.listOrEmpty('parts') ??
            const <Object?>[]) {
      if (entry is! Map) continue;
      final part = entry.cast<String, Object?>();

      if (part.optionalString('text') case final text?) {
        if (text.isNotEmpty) {
          parts.add(
            part.boolOr('thought', orElse: false)
                ? ReasoningPart(text)
                : TextPart(text),
          );
        }
      }
      if (part.optionalObject('functionCall') case final call?) {
        final args = call.optionalObject('args') ?? const <String, Object?>{};
        final name = call.stringOr('name', '');
        parts.add(
          ToolCallPart(
            id: 'call_${toolIndex}_$name',
            name: name,
            arguments: args,
            rawArguments: jsonEncode(args),
          ),
        );
        toolIndex++;
      }
    }

    return ChatResponse(
      message: Message(role: MessageRole.assistant, parts: parts),
      modelId: json.stringOr('modelVersion', info.id),
      requestId: json.optionalString('responseId'),
      finishReason: _parseFinishReason(
        candidate.optionalString('finishReason'),
      ),
      usage: _parseUsage(json.optionalObject('usageMetadata')),
    );
  }

  static TokenUsage _parseUsage(JsonMap? json) {
    if (json == null) return TokenUsage.empty;
    return TokenUsage(
      promptTokens: json.intOr('promptTokenCount', 0),
      completionTokens: json.intOr('candidatesTokenCount', 0),
      totalTokens: json.optionalInt('totalTokenCount'),
      cachedPromptTokens: json.intOr('cachedContentTokenCount', 0),
      reasoningTokens: json.intOr('thoughtsTokenCount', 0),
    );
  }

  static FinishReason _parseFinishReason(String? raw) => switch (raw) {
    'STOP' => FinishReason.stop,
    'MAX_TOKENS' => FinishReason.length,
    'SAFETY' ||
    'RECITATION' ||
    'BLOCKLIST' ||
    'PROHIBITED_CONTENT' => FinishReason.contentFilter,
    'MALFORMED_FUNCTION_CALL' => FinishReason.error,
    null => FinishReason.stop,
    _ => FinishReason.unknown,
  };

  @override
  String toString() => 'GeminiChatModel(${info.qualifiedId})';
}

/// An embedding model speaking Google's `embedContent` API.
final class GeminiEmbeddingModel implements EmbeddingModel {
  /// Creates an adapter.
  GeminiEmbeddingModel({
    required String apiKey,
    String model = 'text-embedding-004',
    this.dimensions = 768,
    this.maxBatchSize = 100,
    Uri? baseUrl,
    http.Client? client,
  }) : info = ModelInfo(
         id: model,
         provider: 'gemini',
         capabilities: const <ModelCapability>{},
       ),
       _transport = LlmHttpTransport(
         baseUrl:
             baseUrl ??
             Uri.parse('https://generativelanguage.googleapis.com/v1beta'),
         provider: 'gemini',
         client: client,
         headers: <String, String>{'x-goog-api-key': apiKey},
       );

  @override
  final ModelInfo info;

  @override
  final int dimensions;

  @override
  final int maxBatchSize;

  final LlmHttpTransport _transport;

  @override
  Future<List<Embedding>> embed(
    List<String> inputs, {
    required EmbeddingPurpose purpose,
    AgenticContext? context,
  }) async {
    if (inputs.isEmpty) return const <Embedding>[];

    final json = await _transport.postJson(
      '/models/${info.id}:batchEmbedContents',
      <String, Object?>{
        'requests': <JsonMap>[
          for (final input in inputs)
            <String, Object?>{
              'model': 'models/${info.id}',
              'content': <String, Object?>{
                'parts': <JsonMap>[
                  <String, Object?>{'text': input},
                ],
              },
              // Gemini's embeddings are asymmetric, and this is where the
              // framework's provider-neutral purpose becomes a task type.
              'taskType': _taskType(purpose),
              'outputDimensionality': dimensions,
            },
        ],
      },
      context: context,
    );

    final embeddings = json.listOrEmpty('embeddings');
    return <Embedding>[
      for (var i = 0; i < embeddings.length; i++)
        Embedding(
          values: (embeddings[i]! as Map)
              .cast<String, Object?>()
              .requireList('values')
              .map((v) => (v! as num).toDouble())
              .toList(),
          index: i,
        ),
    ];
  }

  static String _taskType(EmbeddingPurpose purpose) => switch (purpose) {
    EmbeddingPurpose.document => 'RETRIEVAL_DOCUMENT',
    EmbeddingPurpose.query => 'RETRIEVAL_QUERY',
    EmbeddingPurpose.similarity => 'SEMANTIC_SIMILARITY',
    EmbeddingPurpose.clustering => 'CLUSTERING',
    EmbeddingPurpose.classification => 'CLASSIFICATION',
  };

  @override
  Future<void> dispose() => _transport.dispose();

  @override
  String toString() => 'GeminiEmbeddingModel(${info.qualifiedId})';
}
