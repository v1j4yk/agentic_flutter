import 'dart:convert';
import 'dart:typed_data';

import 'package:agentic_core/agentic_core.dart';
import 'package:agentic_llm/agentic_llm.dart';
import 'package:agentic_tools/agentic_tools.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

/// Captures the requests an adapter builds, so encoding can be asserted on.
final class Recorder {
  final List<http.Request> requests = <http.Request>[];

  JsonMap get lastBody =>
      (jsonDecode(requests.last.body) as Map).cast<String, Object?>();

  Map<String, String> get lastHeaders => requests.last.headers;
}

/// A client that records the request and replies with [body].
(http.Client, Recorder) respondingWith(
  Object body, {
  int status = 200,
  Map<String, String> headers = const <String, String>{},
}) {
  final recorder = Recorder();
  final client = MockClient((request) async {
    recorder.requests.add(request);
    return http.Response(
      body is String ? body : jsonEncode(body),
      status,
      headers: <String, String>{'content-type': 'application/json', ...headers},
    );
  });
  return (client, recorder);
}

final searchTools = ToolRegistry()
  ..register(
    FunctionTool(
      name: 'search_web',
      description: 'Searches the public web.',
      parameters: JsonSchema.object(
        properties: {'query': JsonSchema.string(description: 'The query')},
        required: {'query'},
      ),
      handler: (_) async => ToolResult.success('ok'),
    ),
  );

final history = <Message>[
  Message.system('You are concise.'),
  Message.user('What is the capital of France?'),
];

void main() {
  group('OpenAI-compatible: request encoding', () {
    test('encodes model, messages and sampling parameters', () async {
      final (client, recorder) = respondingWith(_openAiTextResponse);
      final model = OpenAiCompatibleChatModel.openAi(
        apiKey: 'sk-test',
        client: client,
      );

      await model.generate(
        ChatRequest(
          messages: history,
          temperature: 0.2,
          maxOutputTokens: 256,
          stopSequences: const <String>['END'],
        ),
      );

      final body = recorder.lastBody;
      expect(body['model'], 'gpt-4o');
      expect(body['temperature'], 0.2);
      expect(body['max_completion_tokens'], 256);
      expect(body['stop'], <String>['END']);
      expect(body['stream'], isFalse);

      final messages = body.requireList('messages');
      expect(messages, hasLength(2));
      expect((messages.first! as Map)['role'], 'system');
      await model.dispose();
    });

    test('sends the API key as a bearer token', () async {
      final (client, recorder) = respondingWith(_openAiTextResponse);
      final model = OpenAiCompatibleChatModel.openAi(
        apiKey: 'sk-test',
        client: client,
      );

      await model.generate(ChatRequest(messages: history));

      expect(recorder.lastHeaders['authorization'], 'Bearer sk-test');
      await model.dispose();
    });

    test('omits parameters that were never set', () async {
      // Sending an explicit null is not the same as omitting a field; several
      // servers reject `{"temperature": null}`.
      final (client, recorder) = respondingWith(_openAiTextResponse);
      final model = OpenAiCompatibleChatModel.openAi(
        apiKey: 'k',
        client: client,
      );

      await model.generate(ChatRequest(messages: history));

      expect(recorder.lastBody.containsKey('temperature'), isFalse);
      expect(recorder.lastBody.containsKey('seed'), isFalse);
      await model.dispose();
    });

    test('encodes tools and tool choice', () async {
      final (client, recorder) = respondingWith(_openAiTextResponse);
      final model = OpenAiCompatibleChatModel.openAi(
        apiKey: 'k',
        client: client,
      );

      await model.generate(
        ChatRequest(
          messages: history,
          tools: searchTools.all,
          toolChoice: ToolChoice.tool('search_web'),
        ),
      );

      final body = recorder.lastBody;
      final tools = body.requireList('tools');
      final function = (tools.single! as Map)
          .cast<String, Object?>()
          .requireObject('function');
      expect(function['name'], 'search_web');
      expect(
        (body['tool_choice']! as Map)['function'],
        containsPair('name', 'search_web'),
      );
      await model.dispose();
    });

    test('encodes a tool result as its own message with the call id', () async {
      final (client, recorder) = respondingWith(_openAiTextResponse);
      final model = OpenAiCompatibleChatModel.openAi(
        apiKey: 'k',
        client: client,
      );

      await model.generate(
        ChatRequest(
          messages: <Message>[
            Message.user('search please'),
            Message.assistant(
              '',
              toolCalls: [
                ToolCallPart(
                  id: 'call_1',
                  name: 'search_web',
                  arguments: {'query': 'dart'},
                ),
              ],
            ),
            Message.toolResult(
              callId: 'call_1',
              name: 'search_web',
              content: 'results',
            ),
          ],
        ),
      );

      final messages = recorder.lastBody.requireList('messages');
      final assistant = (messages[1]! as Map).cast<String, Object?>();
      final tool = (messages[2]! as Map).cast<String, Object?>();

      expect(assistant['content'], isNull, reason: 'an empty turn sends null');
      expect(assistant.requireList('tool_calls'), hasLength(1));
      expect(tool['role'], 'tool');
      expect(tool['tool_call_id'], 'call_1');
      await model.dispose();
    });

    test('sends plain text content when the turn is not multimodal', () async {
      // Several compatible servers reject the array form outright.
      final (client, recorder) = respondingWith(_openAiTextResponse);
      final model = OpenAiCompatibleChatModel.openAi(
        apiKey: 'k',
        client: client,
      );

      await model.generate(ChatRequest(messages: history));

      final messages = recorder.lastBody.requireList('messages');
      expect((messages.last! as Map)['content'], isA<String>());
      await model.dispose();
    });

    test('sends a content array for a multimodal turn', () async {
      final (client, recorder) = respondingWith(_openAiTextResponse);
      final model = OpenAiCompatibleChatModel.openAi(
        apiKey: 'k',
        client: client,
      );

      await model.generate(
        ChatRequest(
          messages: <Message>[
            Message.user(
              'What is this?',
              parts: [
                ImagePart.bytes(
                  Uint8List.fromList(<int>[1, 2, 3]),
                  mimeType: 'image/png',
                ),
              ],
            ),
          ],
        ),
      );

      final content = (recorder.lastBody.requireList('messages').single! as Map)
          .cast<String, Object?>()
          .requireList('content');
      expect(content, hasLength(2));
      expect((content[1]! as Map)['type'], 'image_url');
      await model.dispose();
    });

    test('encodes a strict JSON schema response format', () async {
      final (client, recorder) = respondingWith(_openAiTextResponse);
      final model = OpenAiCompatibleChatModel.openAi(
        apiKey: 'k',
        client: client,
      );

      await model.generate(
        ChatRequest(
          messages: history,
          responseFormat: ResponseFormat.jsonSchema(
            name: 'city',
            schema: JsonSchema.object(
              properties: {'name': JsonSchema.string()},
              required: {'name'},
            ),
          ),
        ),
      );

      final format = recorder.lastBody.requireObject('response_format');
      expect(format['type'], 'json_schema');
      expect(format.requireObject('json_schema')['strict'], isTrue);
      await model.dispose();
    });

    test('provider options override generated fields', () async {
      final (client, recorder) = respondingWith(_openAiTextResponse);
      final model = OpenAiCompatibleChatModel.openAi(
        apiKey: 'k',
        client: client,
      );

      await model.generate(
        ChatRequest(
          messages: history,
          temperature: 0.5,
          providerOptions: const <String, Object?>{
            'temperature': 0.9,
            'logit_bias': <String, Object?>{'123': -100},
          },
        ),
      );

      expect(recorder.lastBody['temperature'], 0.9);
      expect(recorder.lastBody['logit_bias'], isNotNull);
      await model.dispose();
    });
  });

  group('OpenAI-compatible: response decoding', () {
    test('decodes text, usage and finish reason', () async {
      final (client, _) = respondingWith(_openAiTextResponse);
      final model = OpenAiCompatibleChatModel.openAi(
        apiKey: 'k',
        client: client,
        pricing: const ModelPricing(
          inputPerMillion: 2.5,
          outputPerMillion: 10,
          cachedInputPerMillion: 1.25,
        ),
      );

      final response = await model.generate(ChatRequest(messages: history));

      expect(response.text, 'Paris.');
      expect(response.modelId, 'gpt-4o-2024-11-20');
      expect(response.requestId, 'chatcmpl-1');
      expect(response.finishReason, FinishReason.stop);
      expect(response.usage.promptTokens, 20);
      expect(response.usage.cachedPromptTokens, 16);
      expect(response.usage.reasoningTokens, 3);
      expect(
        response.cost,
        closeTo((4 * 2.5 + 16 * 1.25 + 8 * 10) / 1e6, 1e-12),
      );
      await model.dispose();
    });

    test('decodes tool calls', () async {
      final (client, _) = respondingWith(_openAiToolCallResponse);
      final model = OpenAiCompatibleChatModel.openAi(
        apiKey: 'k',
        client: client,
      );

      final response = await model.generate(ChatRequest(messages: history));

      expect(response.finishReason, FinishReason.toolCalls);
      expect(response.hasToolCalls, isTrue);
      final call = response.toolCalls.single;
      expect(call.name, 'search_web');
      expect(call.arguments, <String, Object?>{'query': 'capital of France'});
      await model.dispose();
    });

    test('tolerates malformed tool-call arguments', () async {
      // Returned, not thrown: the executor validates and the model repairs.
      final (client, _) = respondingWith(<String, Object?>{
        'id': 'x',
        'model': 'gpt-4o',
        'choices': <Object?>[
          <String, Object?>{
            'finish_reason': 'tool_calls',
            'message': <String, Object?>{
              'role': 'assistant',
              'tool_calls': <Object?>[
                <String, Object?>{
                  'id': 'c1',
                  'function': <String, Object?>{
                    'name': 'search_web',
                    'arguments': '{"query": "unterminated',
                  },
                },
              ],
            },
          },
        ],
      });
      final model = OpenAiCompatibleChatModel.openAi(
        apiKey: 'k',
        client: client,
      );

      final call = (await model.generate(
        ChatRequest(messages: history),
      )).toolCalls.single;

      expect(call.arguments, isEmpty);
      expect(call.rawArguments, contains('unterminated'));
      await model.dispose();
    });

    test('maps an unknown finish reason without failing', () async {
      final (client, _) = respondingWith(<String, Object?>{
        'model': 'gpt-4o',
        'choices': <Object?>[
          <String, Object?>{
            'finish_reason': 'something_new',
            'message': <String, Object?>{'role': 'assistant', 'content': 'hi'},
          },
        ],
      });
      final model = OpenAiCompatibleChatModel.openAi(
        apiKey: 'k',
        client: client,
      );

      final response = await model.generate(ChatRequest(messages: history));

      expect(response.finishReason, FinishReason.unknown);
      await model.dispose();
    });

    test('reports an empty choices array clearly', () async {
      final (client, _) = respondingWith(<String, Object?>{
        'choices': <Object?>[],
      });
      final model = OpenAiCompatibleChatModel.openAi(
        apiKey: 'k',
        client: client,
      );

      await expectLater(
        model.generate(ChatRequest(messages: history)),
        throwsA(isA<SerializationException>()),
      );
      await model.dispose();
    });
  });

  group('OpenAI-compatible: streaming', () {
    test('assembles a streamed answer and requests usage', () async {
      final (client, recorder) = respondingWith(
        'data: {"model":"gpt-4o","choices":[{"delta":{"content":"Pa"}}]}\n\n'
        'data: {"choices":[{"delta":{"content":"ris."}}]}\n\n'
        'data: {"choices":[{"delta":{},"finish_reason":"stop"}]}\n\n'
        'data: {"choices":[],"usage":{"prompt_tokens":20,"completion_tokens":2}}\n\n'
        'data: [DONE]\n\n',
        headers: const <String, String>{'content-type': 'text/event-stream'},
      );
      final model = OpenAiCompatibleChatModel.openAi(
        apiKey: 'k',
        client: client,
      );

      final response = await model
          .stream(ChatRequest(messages: history))
          .collect(modelId: 'gpt-4o');

      expect(response.text, 'Paris.');
      expect(response.finishReason, FinishReason.stop);
      expect(response.usage.promptTokens, 20);
      // Without stream_options, OpenAI omits usage entirely and every cost
      // meter silently reads zero.
      expect(
        recorder.lastBody.requireObject('stream_options')['include_usage'],
        isTrue,
      );
      await model.dispose();
    });

    test('assembles fragmented tool-call arguments end to end', () async {
      final (client, _) = respondingWith(
        'data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"c1",'
        '"function":{"name":"search_web","arguments":""}}]}}]}\n\n'
        'data: {"choices":[{"delta":{"tool_calls":[{"index":0,'
        '"function":{"arguments":"{\\"qu"}}]}}]}\n\n'
        'data: {"choices":[{"delta":{"tool_calls":[{"index":0,'
        '"function":{"arguments":"ery\\":\\"dart\\"}"}}]}}]}\n\n'
        'data: {"choices":[{"delta":{},"finish_reason":"tool_calls"}]}\n\n'
        'data: [DONE]\n\n',
      );
      final model = OpenAiCompatibleChatModel.openAi(
        apiKey: 'k',
        client: client,
      );

      final response = await model
          .stream(ChatRequest(messages: history, tools: searchTools.all))
          .collect();

      final call = response.toolCalls.single;
      expect(call.id, 'c1');
      expect(call.name, 'search_web');
      expect(call.arguments, <String, Object?>{'query': 'dart'});
      await model.dispose();
    });

    test('synthesises a finish for servers that just close', () async {
      final (client, _) = respondingWith(
        'data: {"choices":[{"delta":{"content":"hi"}}]}\n\n',
      );
      final model = OpenAiCompatibleChatModel.ollama(
        model: 'qwen2.5',
        client: client,
      );

      final chunks = await model
          .stream(ChatRequest(messages: history))
          .toList();

      expect(chunks.last.isFinal, isTrue);
      await model.dispose();
    });
  });

  group('capability negotiation', () {
    test('refuses structured output on a model without it', () async {
      final (client, _) = respondingWith(_openAiTextResponse);
      final model = OpenAiCompatibleChatModel.ollama(
        model: 'qwen2.5',
        client: client,
      );

      await expectLater(
        model.generate(
          ChatRequest(
            messages: history,
            responseFormat: ResponseFormat.jsonSchema(
              name: 'x',
              schema: JsonSchema.object(),
            ),
          ),
        ),
        throwsA(
          isA<CapabilityNotSupportedException>()
              .having((e) => e.capability, 'capability', 'structuredOutput')
              .having((e) => e.component, 'component', 'ollama:qwen2.5'),
        ),
      );
      await model.dispose();
    });

    test('refuses tools on a model without tool calling', () async {
      final (client, _) = respondingWith(_openAiTextResponse);
      final model = OpenAiCompatibleChatModel.ollama(
        model: 'tinyllama',
        client: client,
      );

      await expectLater(
        model.generate(ChatRequest(messages: history, tools: searchTools.all)),
        throwsA(isA<CapabilityNotSupportedException>()),
      );
      await model.dispose();
    });
  });

  group('error mapping', () {
    Future<void> expectMapped(
      int status,
      Object body,
      Matcher matcher, {
      Map<String, String> headers = const <String, String>{},
    }) async {
      final (client, _) = respondingWith(
        body,
        status: status,
        headers: headers,
      );
      final model = OpenAiCompatibleChatModel.openAi(
        apiKey: 'k',
        client: client,
      );
      await expectLater(
        model.generate(ChatRequest(messages: history)),
        matcher,
      );
      await model.dispose();
    }

    test('401 becomes a non-retryable authentication failure', () async {
      await expectMapped(
        401,
        <String, Object?>{
          'error': <String, Object?>{'message': 'Invalid API key'},
        },
        throwsA(
          isA<AuthenticationException>()
              .having((e) => e.isRetryable, 'isRetryable', isFalse)
              .having((e) => e.message, 'message', contains('Invalid API key')),
        ),
      );
    });

    test('429 becomes a retryable rate limit honouring Retry-After', () async {
      await expectMapped(
        429,
        <String, Object?>{
          'error': <String, Object?>{'message': 'Slow down'},
        },
        throwsA(
          isA<RateLimitException>()
              .having((e) => e.isRetryable, 'isRetryable', isTrue)
              .having(
                (e) => e.retryAfter,
                'retryAfter',
                const Duration(seconds: 30),
              ),
        ),
        headers: const <String, String>{'retry-after': '30'},
      );
    });

    test('429 with an exhausted quota is not retryable', () async {
      // The difference that matters: waiting fixes a throttle, but never
      // restores a spent credit balance.
      await expectMapped(
        429,
        <String, Object?>{
          'error': <String, Object?>{
            'message': 'You exceeded your current quota',
            'code': 'insufficient_quota',
          },
        },
        throwsA(
          isA<QuotaExceededException>().having(
            (e) => e.isRetryable,
            'isRetryable',
            isFalse,
          ),
        ),
      );
    });

    test('5xx is retryable', () async {
      await expectMapped(
        503,
        <String, Object?>{
          'error': <String, Object?>{'message': 'Overloaded'},
        },
        throwsA(
          isA<ProviderException>()
              .having((e) => e.isRetryable, 'isRetryable', isTrue)
              .having((e) => e.statusCode, 'statusCode', 503),
        ),
      );
    });

    test('400 is not retryable', () async {
      await expectMapped(
        400,
        <String, Object?>{
          'error': <String, Object?>{'message': 'Bad request'},
        },
        throwsA(
          isA<ProviderException>().having(
            (e) => e.isRetryable,
            'isRetryable',
            isFalse,
          ),
        ),
      );
    });

    test('an HTML error page is reported with its text', () async {
      await expectMapped(
        502,
        '<!DOCTYPE html><title>Bad gateway</title>',
        throwsA(
          isA<ProviderException>().having(
            (e) => e.message,
            'message',
            contains('DOCTYPE'),
          ),
        ),
      );
    });

    test('a transport failure is retryable', () async {
      final client = MockClient(
        (request) async => throw const SocketExceptionStub(),
      );
      final model = OpenAiCompatibleChatModel.openAi(
        apiKey: 'k',
        client: client,
      );

      await expectLater(
        model.generate(ChatRequest(messages: history)),
        throwsA(
          isA<ProviderException>()
              .having((e) => e.isRetryable, 'isRetryable', isTrue)
              .having((e) => e.statusCode, 'statusCode', isNull),
        ),
      );
      await model.dispose();
    });

    test('parses an HTTP-date Retry-After', () {
      final future = DateTime.now().toUtc().add(const Duration(seconds: 120));
      const weekdays = <String>[
        'Mon',
        'Tue',
        'Wed',
        'Thu',
        'Fri',
        'Sat',
        'Sun',
      ];
      const months = <String>[
        'Jan',
        'Feb',
        'Mar',
        'Apr',
        'May',
        'Jun',
        'Jul',
        'Aug',
        'Sep',
        'Oct',
        'Nov',
        'Dec',
      ];
      String two(int v) => v.toString().padLeft(2, '0');
      final header =
          '${weekdays[future.weekday - 1]}, ${two(future.day)} '
          '${months[future.month - 1]} ${future.year} '
          '${two(future.hour)}:${two(future.minute)}:${two(future.second)} GMT';

      final error = mapHttpFailure(
        statusCode: 429,
        body: '{}',
        provider: 'test',
        headers: <String, String>{'retry-after': header},
      );

      expect(error, isA<RateLimitException>());
      expect(
        (error as RateLimitException).retryAfter!.inSeconds,
        closeTo(120, 2),
      );
    });

    test('parseHttpDate rejects a malformed value', () {
      expect(parseHttpDate('not a date'), isNull);
    });
  });

  group('Anthropic', () {
    test('hoists the system prompt and supplies max_tokens', () async {
      final (client, recorder) = respondingWith(_anthropicTextResponse);
      final model = AnthropicChatModel(apiKey: 'sk-ant', client: client);

      await model.generate(ChatRequest(messages: history));

      final body = recorder.lastBody;
      expect(body['system'], 'You are concise.');
      expect(
        body.requireList('messages'),
        hasLength(1),
        reason: 'a system message left in the array is a 400',
      );
      expect(body['max_tokens'], 4096, reason: 'the API requires the field');
      expect(recorder.lastHeaders['x-api-key'], 'sk-ant');
      expect(recorder.lastHeaders['anthropic-version'], isNotNull);
      await model.dispose();
    });

    test('batches tool results into a single user turn', () async {
      // Two user turns in a row are rejected, so consecutive results must merge.
      final (client, recorder) = respondingWith(_anthropicTextResponse);
      final model = AnthropicChatModel(apiKey: 'k', client: client);

      await model.generate(
        ChatRequest(
          messages: <Message>[
            Message.user('do both'),
            Message.assistant(
              '',
              toolCalls: [
                ToolCallPart(
                  id: 'a',
                  name: 'search_web',
                  arguments: {'q': '1'},
                ),
                ToolCallPart(
                  id: 'b',
                  name: 'search_web',
                  arguments: {'q': '2'},
                ),
              ],
            ),
            Message.toolResult(callId: 'a', name: 'search_web', content: 'r1'),
            Message.toolResult(callId: 'b', name: 'search_web', content: 'r2'),
          ],
        ),
      );

      final messages = recorder.lastBody.requireList('messages');
      expect(messages, hasLength(3));
      final results = (messages[2]! as Map).cast<String, Object?>();
      expect(results['role'], 'user');
      expect(results.requireList('content'), hasLength(2));
      expect(
        (results.requireList('content').first! as Map)['type'],
        'tool_result',
      );
      await model.dispose();
    });

    test('encodes tools with input_schema', () async {
      final (client, recorder) = respondingWith(_anthropicTextResponse);
      final model = AnthropicChatModel(apiKey: 'k', client: client);

      await model.generate(
        ChatRequest(messages: history, tools: searchTools.all),
      );

      final tool = (recorder.lastBody.requireList('tools').single! as Map)
          .cast<String, Object?>();
      expect(tool['name'], 'search_web');
      expect(tool.requireObject('input_schema')['type'], 'object');
      expect(recorder.lastBody.requireObject('tool_choice')['type'], 'auto');
      await model.dispose();
    });

    test('decodes text, tool use and usage', () async {
      final (client, _) = respondingWith(_anthropicToolUseResponse);
      final model = AnthropicChatModel(apiKey: 'k', client: client);

      final response = await model.generate(ChatRequest(messages: history));

      expect(response.text, 'Let me search.');
      expect(response.finishReason, FinishReason.toolCalls);
      expect(response.toolCalls.single.name, 'search_web');
      expect(response.toolCalls.single.arguments, <String, Object?>{
        'query': 'France',
      });
      expect(response.usage.promptTokens, 30);
      expect(response.usage.cachedPromptTokens, 25);
      await model.dispose();
    });

    test('round-trips a thinking signature', () async {
      final (client, recorder) = respondingWith(_anthropicTextResponse);
      final model = AnthropicChatModel(apiKey: 'k', client: client);

      await model.generate(
        ChatRequest(
          messages: <Message>[
            Message.user('hi'),
            Message(
              role: MessageRole.assistant,
              parts: [
                ReasoningPart('deliberating', signature: 'sig-xyz'),
                TextPart('answer'),
              ],
            ),
            Message.user('again'),
          ],
        ),
      );

      final blocks = (recorder.lastBody.requireList('messages')[1]! as Map)
          .cast<String, Object?>()
          .requireList('content');
      final thinking = (blocks.first! as Map).cast<String, Object?>();
      expect(thinking['type'], 'thinking');
      expect(
        thinking['signature'],
        'sig-xyz',
        reason: 'an altered signature makes the provider reject the turn',
      );
      await model.dispose();
    });

    test('drops an unsigned thinking block rather than sending it', () async {
      final (client, recorder) = respondingWith(_anthropicTextResponse);
      final model = AnthropicChatModel(apiKey: 'k', client: client);

      await model.generate(
        ChatRequest(
          messages: <Message>[
            Message.user('hi'),
            Message(
              role: MessageRole.assistant,
              parts: [ReasoningPart('unsigned'), TextPart('answer')],
            ),
            Message.user('again'),
          ],
        ),
      );

      final blocks = (recorder.lastBody.requireList('messages')[1]! as Map)
          .cast<String, Object?>()
          .requireList('content');
      expect(blocks, hasLength(1));
      expect((blocks.single! as Map)['type'], 'text');
      await model.dispose();
    });

    test('maps block indices onto tool-call indices when streaming', () async {
      // Anthropic indexes content blocks, and block 1 is tool call 0 whenever
      // the model writes prose first — which is most of the time.
      final (client, _) = respondingWith(
        'event: message_start\n'
        'data: {"type":"message_start","message":{"id":"msg_1","model":"claude",'
        '"usage":{"input_tokens":10,"output_tokens":0}}}\n\n'
        'event: content_block_start\n'
        'data: {"type":"content_block_start","index":0,'
        '"content_block":{"type":"text","text":""}}\n\n'
        'event: content_block_delta\n'
        'data: {"type":"content_block_delta","index":0,'
        '"delta":{"type":"text_delta","text":"Searching."}}\n\n'
        'event: content_block_start\n'
        'data: {"type":"content_block_start","index":1,'
        '"content_block":{"type":"tool_use","id":"tu_1","name":"search_web"}}\n\n'
        'event: content_block_delta\n'
        'data: {"type":"content_block_delta","index":1,'
        '"delta":{"type":"input_json_delta","partial_json":"{\\"query\\":"}}\n\n'
        'event: content_block_delta\n'
        'data: {"type":"content_block_delta","index":1,'
        '"delta":{"type":"input_json_delta","partial_json":"\\"dart\\"}"}}\n\n'
        'event: message_delta\n'
        'data: {"type":"message_delta","delta":{"stop_reason":"tool_use"},'
        '"usage":{"output_tokens":12}}\n\n'
        'event: message_stop\ndata: {"type":"message_stop"}\n\n',
      );
      final model = AnthropicChatModel(apiKey: 'k', client: client);

      final response = await model
          .stream(ChatRequest(messages: history, tools: searchTools.all))
          .collect();

      expect(response.text, 'Searching.');
      expect(response.finishReason, FinishReason.toolCalls);
      final call = response.toolCalls.single;
      expect(call.id, 'tu_1');
      expect(call.name, 'search_web');
      expect(call.arguments, <String, Object?>{'query': 'dart'});
      expect(response.usage.promptTokens, 10);
      expect(response.usage.completionTokens, 12);
      await model.dispose();
    });

    test('surfaces a mid-stream error event', () async {
      final (client, _) = respondingWith(
        'event: error\n'
        'data: {"type":"error","error":{"type":"overloaded_error",'
        '"message":"Overloaded"}}\n\n',
      );
      final model = AnthropicChatModel(apiKey: 'k', client: client);

      await expectLater(
        model.stream(ChatRequest(messages: history)).toList(),
        throwsA(
          isA<ProviderException>().having(
            (e) => e.isRetryable,
            'isRetryable',
            isTrue,
          ),
        ),
      );
      await model.dispose();
    });

    test('does not claim structured output it cannot guarantee', () {
      final model = AnthropicChatModel(apiKey: 'k');

      expect(model.info.supports(ModelCapability.structuredOutput), isFalse);
      expect(model.info.supports(ModelCapability.toolCalling), isTrue);
    });
  });

  group('Gemini', () {
    test('encodes contents, roles and system instruction', () async {
      final (client, recorder) = respondingWith(_geminiTextResponse);
      final model = GeminiChatModel(apiKey: 'k', client: client);

      await model.generate(
        ChatRequest(
          messages: <Message>[
            Message.system('You are concise.'),
            Message.user('hi'),
            Message.assistant('hello'),
            Message.user('again'),
          ],
          temperature: 0.3,
        ),
      );

      final body = recorder.lastBody;
      final contents = body.requireList('contents');
      expect(contents, hasLength(3));
      expect((contents[1]! as Map)['role'], 'model');
      expect(
        body.requireObject('systemInstruction').requireList('parts'),
        hasLength(1),
      );
      expect(body.requireObject('generationConfig')['temperature'], 0.3);
      expect(recorder.lastHeaders['x-goog-api-key'], 'k');
      await model.dispose();
    });

    test('strips schema keywords Gemini rejects', () async {
      // Every object schema this framework builds sets additionalProperties,
      // and Gemini 400s on any schema containing it — so unmodified schemas
      // would fail every single tool-calling request.
      final (client, recorder) = respondingWith(_geminiTextResponse);
      final model = GeminiChatModel(apiKey: 'k', client: client);

      await model.generate(
        ChatRequest(messages: history, tools: searchTools.all),
      );

      final declaration =
          ((recorder.lastBody.requireList('tools').single! as Map)
                      .cast<String, Object?>()
                      .requireList('functionDeclarations')
                      .single!
                  as Map)
              .cast<String, Object?>();
      final parameters = declaration.requireObject('parameters');

      expect(parameters.containsKey('additionalProperties'), isFalse);
      expect(parameters['type'], 'object');
      expect(parameters.requireObject('properties'), contains('query'));
      await model.dispose();
    });

    test('converts a nullable type union to the OpenAPI flag', () async {
      final (client, recorder) = respondingWith(_geminiTextResponse);
      final model = GeminiChatModel(apiKey: 'k', client: client);

      await model.generate(
        ChatRequest(
          messages: history,
          responseFormat: ResponseFormat.jsonSchema(
            name: 'city',
            schema: JsonSchema.object(
              properties: {
                'name': JsonSchema.string(),
                'region': JsonSchema.string(),
              },
              required: {'name'},
            ),
          ),
        ),
      );

      final schema = recorder.lastBody
          .requireObject('generationConfig')
          .requireObject('responseSchema')
          .requireObject('properties')
          .requireObject('region');

      expect(schema['type'], 'string');
      expect(schema['nullable'], isTrue);
      await model.dispose();
    });

    test('encodes tool results as functionResponse in a user turn', () async {
      final (client, recorder) = respondingWith(_geminiTextResponse);
      final model = GeminiChatModel(apiKey: 'k', client: client);

      await model.generate(
        ChatRequest(
          messages: <Message>[
            Message.user('search'),
            Message.assistant(
              '',
              toolCalls: [
                ToolCallPart(
                  id: 'x',
                  name: 'search_web',
                  arguments: {'q': '1'},
                ),
              ],
            ),
            Message.toolResult(
              callId: 'x',
              name: 'search_web',
              content: 'found',
            ),
          ],
        ),
      );

      final last = (recorder.lastBody.requireList('contents').last! as Map)
          .cast<String, Object?>();
      expect(last['role'], 'user');
      final response = (last.requireList('parts').single! as Map)
          .cast<String, Object?>()
          .requireObject('functionResponse');
      expect(response['name'], 'search_web');
      await model.dispose();
    });

    test('decodes text, function calls and usage', () async {
      final (client, _) = respondingWith(_geminiToolCallResponse);
      final model = GeminiChatModel(apiKey: 'k', client: client);

      final response = await model.generate(ChatRequest(messages: history));

      expect(response.text, 'Looking it up.');
      expect(response.toolCalls.single.name, 'search_web');
      expect(response.toolCalls.single.arguments, <String, Object?>{
        'query': 'France',
      });
      expect(response.usage.promptTokens, 15);
      expect(response.usage.reasoningTokens, 4);
      await model.dispose();
    });

    test('maps a safety block to contentFilter', () async {
      final (client, _) = respondingWith(<String, Object?>{
        'candidates': <Object?>[
          <String, Object?>{
            'finishReason': 'SAFETY',
            'content': <String, Object?>{
              'parts': <Object?>[
                <String, Object?>{'text': ''},
              ],
            },
          },
        ],
      });
      final model = GeminiChatModel(apiKey: 'k', client: client);

      final response = await model.generate(ChatRequest(messages: history));

      expect(response.finishReason, FinishReason.contentFilter);
      expect(response.ensureComplete, throwsA(isA<ProviderException>()));
      await model.dispose();
    });

    test('reports a blocked prompt clearly', () async {
      final (client, _) = respondingWith(<String, Object?>{
        'candidates': <Object?>[],
        'promptFeedback': <String, Object?>{'blockReason': 'SAFETY'},
      });
      final model = GeminiChatModel(apiKey: 'k', client: client);

      await expectLater(
        model.generate(ChatRequest(messages: history)),
        throwsA(
          isA<ProviderException>()
              .having((e) => e.message, 'message', contains('SAFETY'))
              .having((e) => e.isRetryable, 'isRetryable', isFalse),
        ),
      );
      await model.dispose();
    });
  });

  group('cross-provider equivalence', () {
    test('every adapter produces the same shape from its own format', () async {
      // The point of the abstraction: three wire formats, one result type.
      final adapters = <String, ChatModel>{
        'openai': OpenAiCompatibleChatModel.openAi(
          apiKey: 'k',
          client: respondingWith(_openAiToolCallResponse).$1,
        ),
        'anthropic': AnthropicChatModel(
          apiKey: 'k',
          client: respondingWith(_anthropicToolUseResponse).$1,
        ),
        'gemini': GeminiChatModel(
          apiKey: 'k',
          client: respondingWith(_geminiToolCallResponse).$1,
        ),
      };

      for (final entry in adapters.entries) {
        final response = await entry.value.generate(
          ChatRequest(messages: history, tools: searchTools.all),
        );

        expect(response.hasToolCalls, isTrue, reason: entry.key);
        expect(response.toolCalls.single.name, 'search_web', reason: entry.key);
        expect(
          response.toolCalls.single.arguments.values.single,
          anyOf('capital of France', 'France'),
          reason: entry.key,
        );
        expect(response.usage.promptTokens, greaterThan(0), reason: entry.key);
        await entry.value.dispose();
      }
    });
  });
}

/// Stands in for a `dart:io` socket failure, which cannot be constructed on all
/// platforms the tests run on.
final class SocketExceptionStub implements Exception {
  const SocketExceptionStub();

  @override
  String toString() => 'SocketException: connection failed';
}

// -----------------------------------------------------------------------------
// Recorded provider payloads
// -----------------------------------------------------------------------------

const Map<String, Object?> _openAiTextResponse = <String, Object?>{
  'id': 'chatcmpl-1',
  'model': 'gpt-4o-2024-11-20',
  'choices': <Object?>[
    <String, Object?>{
      'index': 0,
      'finish_reason': 'stop',
      'message': <String, Object?>{'role': 'assistant', 'content': 'Paris.'},
    },
  ],
  'usage': <String, Object?>{
    'prompt_tokens': 20,
    'completion_tokens': 8,
    'total_tokens': 28,
    'prompt_tokens_details': <String, Object?>{'cached_tokens': 16},
    'completion_tokens_details': <String, Object?>{'reasoning_tokens': 3},
  },
};

const Map<String, Object?> _openAiToolCallResponse = <String, Object?>{
  'id': 'chatcmpl-2',
  'model': 'gpt-4o',
  'choices': <Object?>[
    <String, Object?>{
      'finish_reason': 'tool_calls',
      'message': <String, Object?>{
        'role': 'assistant',
        'content': null,
        'tool_calls': <Object?>[
          <String, Object?>{
            'id': 'call_1',
            'type': 'function',
            'function': <String, Object?>{
              'name': 'search_web',
              'arguments': '{"query": "capital of France"}',
            },
          },
        ],
      },
    },
  ],
  'usage': <String, Object?>{'prompt_tokens': 42, 'completion_tokens': 12},
};

const Map<String, Object?> _anthropicTextResponse = <String, Object?>{
  'id': 'msg_1',
  'model': 'claude-sonnet-4-20250514',
  'stop_reason': 'end_turn',
  'content': <Object?>[
    <String, Object?>{'type': 'text', 'text': 'Paris.'},
  ],
  'usage': <String, Object?>{'input_tokens': 20, 'output_tokens': 5},
};

const Map<String, Object?> _anthropicToolUseResponse = <String, Object?>{
  'id': 'msg_2',
  'model': 'claude-sonnet-4-20250514',
  'stop_reason': 'tool_use',
  'content': <Object?>[
    <String, Object?>{'type': 'text', 'text': 'Let me search.'},
    <String, Object?>{
      'type': 'tool_use',
      'id': 'tu_1',
      'name': 'search_web',
      'input': <String, Object?>{'query': 'France'},
    },
  ],
  'usage': <String, Object?>{
    'input_tokens': 30,
    'output_tokens': 18,
    'cache_read_input_tokens': 25,
  },
};

const Map<String, Object?> _geminiTextResponse = <String, Object?>{
  'modelVersion': 'gemini-2.0-flash',
  'candidates': <Object?>[
    <String, Object?>{
      'finishReason': 'STOP',
      'content': <String, Object?>{
        'role': 'model',
        'parts': <Object?>[
          <String, Object?>{'text': 'Paris.'},
        ],
      },
    },
  ],
  'usageMetadata': <String, Object?>{
    'promptTokenCount': 12,
    'candidatesTokenCount': 3,
  },
};

const Map<String, Object?> _geminiToolCallResponse = <String, Object?>{
  'modelVersion': 'gemini-2.0-flash',
  'candidates': <Object?>[
    <String, Object?>{
      'finishReason': 'STOP',
      'content': <String, Object?>{
        'role': 'model',
        'parts': <Object?>[
          <String, Object?>{'text': 'Looking it up.'},
          <String, Object?>{
            'functionCall': <String, Object?>{
              'name': 'search_web',
              'args': <String, Object?>{'query': 'France'},
            },
          },
        ],
      },
    },
  ],
  'usageMetadata': <String, Object?>{
    'promptTokenCount': 15,
    'candidatesTokenCount': 9,
    'thoughtsTokenCount': 4,
  },
};
