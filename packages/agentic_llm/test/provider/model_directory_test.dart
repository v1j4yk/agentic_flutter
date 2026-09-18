/// Discovering which models a provider serves, and changing model at run time.
///
/// These two belong together: a picker is only useful if choosing something
/// from it can take effect without rebuilding the agent holding the model.
library;

import 'dart:convert';

import 'package:agentic_core/agentic_core.dart';
import 'package:agentic_llm/agentic_llm.dart';
import 'package:agentic_llm/testing.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

/// Answers each request with the next scripted body, recording the requests.
(http.Client, List<http.Request>) respondingInOrder(List<Object> bodies) {
  final requests = <http.Request>[];
  var index = 0;
  final client = MockClient((request) async {
    requests.add(request);
    final body = bodies[index < bodies.length ? index : bodies.length - 1];
    index++;
    return http.Response(
      body is String ? body : jsonEncode(body),
      200,
      headers: const <String, String>{'content-type': 'application/json'},
    );
  });
  return (client, requests);
}

void main() {
  group('listing models', () {
    test('an OpenAI-compatible endpoint lists what it serves', () async {
      final (client, requests) = respondingInOrder(<Object>[
        <String, Object?>{
          'object': 'list',
          'data': <Object?>[
            <String, Object?>{'id': 'gpt-5.6', 'owned_by': 'openai'},
            <String, Object?>{'id': 'gpt-6-astra', 'owned_by': 'openai'},
            // Not a model entry. A provider that adds a field must not break
            // the caller.
            'nonsense',
          ],
        },
      ]);
      final model = OpenAiCompatibleChatModel.openAi(
        apiKey: 'sk-test',
        client: client,
      );

      final models = await model.listModels();

      expect(requests.single.method, 'GET');
      expect(requests.single.url.path, endsWith('/models'));
      expect(models.map((m) => m.id), <String>['gpt-5.6', 'gpt-6-astra']);
      expect(models.first.provider, 'openai');
      expect(models.first.raw['owned_by'], 'openai');
      await model.dispose();
    });

    test('a local Ollama server answers the same call', () async {
      // The point of one adapter for the OpenAI format: a picker written
      // against a hosted provider works against a model on the developer's
      // own machine, with no special case.
      final (client, _) = respondingInOrder(<Object>[
        <String, Object?>{
          'data': <Object?>[
            <String, Object?>{'id': 'qwen2.5:7b'},
          ],
        },
      ]);
      final model = OpenAiCompatibleChatModel.ollama(
        model: 'qwen2.5:7b',
        client: client,
      );

      expect((await model.listModels()).single.id, 'qwen2.5:7b');
      await model.dispose();
    });

    test('Anthropic pages through the whole list', () async {
      final (client, requests) = respondingInOrder(<Object>[
        <String, Object?>{
          'data': <Object?>[
            <String, Object?>{
              'id': 'claude-opus-5',
              'display_name': 'Claude Opus 5',
            },
            <String, Object?>{
              'id': 'claude-sonnet-5',
              'display_name': 'Claude Sonnet 5',
            },
          ],
          'has_more': true,
          'last_id': 'claude-sonnet-5',
        },
        <String, Object?>{
          'data': <Object?>[
            <String, Object?>{
              'id': 'claude-haiku-4-5',
              'display_name': 'Claude Haiku 4.5',
            },
          ],
          'has_more': false,
        },
      ]);
      final model = AnthropicChatModel(apiKey: 'sk-ant', client: client);

      final models = await model.listModels();

      // The second page is requested with the cursor, not re-requested from
      // the start — the bug that turns pagination into an infinite loop.
      expect(requests, hasLength(2));
      expect(requests.last.url.queryParameters['after_id'], 'claude-sonnet-5');
      expect(models.map((m) => m.id), <String>[
        AnthropicModels.opus,
        AnthropicModels.sonnet,
        AnthropicModels.haiku,
      ]);
      expect(models.first.label, 'Claude Opus 5');
      await model.dispose();
    });

    test(
      'Gemini strips the models/ prefix and follows the page token',
      () async {
        final (client, requests) = respondingInOrder(<Object>[
          <String, Object?>{
            'models': <Object?>[
              <String, Object?>{
                'name': 'models/gemini-3.8-flash',
                'displayName': 'Gemini 3.8 Flash',
                'supportedGenerationMethods': <String>['generateContent'],
              },
            ],
            'nextPageToken': 'page-2',
          },
          <String, Object?>{
            'models': <Object?>[
              <String, Object?>{
                'name': 'models/gemini-embedding-2',
                'supportedGenerationMethods': <String>['embedContent'],
              },
            ],
          },
        ]);
        final model = GeminiChatModel(apiKey: 'k', client: client);

        final models = await model.listModels();

        expect(requests.last.url.queryParameters['pageToken'], 'page-2');
        // The identifier a caller passes as `model` is the part after the
        // prefix; returning Google's `models/…` name would be unusable.
        expect(models.map((m) => m.id), <String>[
          GeminiModels.flash,
          GeminiModels.embedding,
        ]);
        expect(
          models.last.raw['supportedGenerationMethods'],
          contains('embedContent'),
        );
        await model.dispose();
      },
    );

    test(
      'a rejected key fails as an authentication error, not an empty list',
      () async {
        final client = MockClient(
          (request) async => http.Response(
            '{"error":{"message":"bad key"}}',
            401,
            headers: const <String, String>{'content-type': 'application/json'},
          ),
        );
        final model = OpenAiCompatibleChatModel.openAi(
          apiKey: 'sk-wrong',
          client: client,
        );

        await expectLater(
          model.listModels(),
          throwsA(isA<AuthenticationException>()),
        );
        await model.dispose();
      },
    );
  });

  group('switching model at run time', () {
    test(
      'calls go to the current model, and switching redirects them',
      () async {
        final first = FakeChatModel.text('from the first model');
        final second = FakeChatModel.text(
          'from the second model',
          info: ModelInfo(id: 'second', provider: 'fake'),
        );
        final model = SwitchableChatModel(first, disposePrevious: false);

        expect(await model.prompt('hello'), 'from the first model');

        await model.switchTo(second);

        expect(model.current, same(second));
        expect(model.info.id, 'second');
        expect(await model.prompt('hello'), 'from the second model');
        await model.dispose();
      },
    );

    test(
      'switching disposes the model it replaces, unless told not to',
      () async {
        final replaced = _DisposeCountingModel();
        final owned = SwitchableChatModel(replaced);
        await owned.switchTo(FakeChatModel.text('next'));
        expect(
          replaced.disposals,
          1,
          reason: 'the owner disposes what it drops',
        );

        final borrowed = _DisposeCountingModel();
        final shared = SwitchableChatModel(borrowed, disposePrevious: false);
        await shared.switchTo(FakeChatModel.text('next'));
        expect(borrowed.disposals, 0, reason: 'a borrowed model is not closed');

        await owned.dispose();
        await shared.dispose();
      },
    );

    test('switching to the model already in use does nothing', () async {
      // A settings screen that writes the preference on every rebuild must not
      // close the connection it is about to use.
      final current = _DisposeCountingModel();
      final model = SwitchableChatModel(current);

      await model.switchTo(current);

      expect(current.disposals, 0);
      await model.dispose();
    });

    test('using a disposed switchable model says so', () async {
      final model = SwitchableChatModel(FakeChatModel.text('hi'))..dispose();

      expect(
        () => model.generate(ChatRequest.prompt('hello')),
        throwsA(isA<InvalidStateException>()),
      );
    });
  });
}

/// A model that counts how often it was disposed.
final class _DisposeCountingModel implements ChatModel {
  int disposals = 0;

  @override
  ModelInfo get info => ModelInfo(id: 'counter', provider: 'fake');

  @override
  Future<ChatResponse> generate(
    ChatRequest request, {
    AgenticContext? context,
  }) async =>
      ChatResponse(message: Message.assistant('counted'), modelId: 'counter');

  @override
  Stream<ChatChunk> stream(ChatRequest request, {AgenticContext? context}) =>
      Stream<ChatChunk>.value(const ChatChunk.text('counted'));

  @override
  Future<void> dispose() async => disposals++;
}
