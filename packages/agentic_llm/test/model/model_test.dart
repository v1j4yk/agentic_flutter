import 'package:agentic_core/agentic_core.dart';
import 'package:agentic_llm/agentic_llm.dart';
import 'package:agentic_llm/testing.dart';
import 'package:agentic_tools/agentic_tools.dart';
import 'package:test/test.dart';

void main() {
  group('ChatRequest', () {
    test('rejects an empty conversation', () {
      expect(
        () => ChatRequest(messages: const <Message>[]),
        throwsA(isA<ValidationException>()),
      );
    });

    test('validates sampling parameter ranges', () {
      expect(
        () =>
            ChatRequest(messages: <Message>[Message.user('x')], temperature: 3),
        throwsA(
          isA<ValidationException>().having(
            (e) => e.message,
            'message',
            contains('temperature'),
          ),
        ),
      );
      expect(
        () => ChatRequest(messages: <Message>[Message.user('x')], topP: 1.5),
        throwsA(isA<ValidationException>()),
      );
      expect(
        () => ChatRequest(
          messages: <Message>[Message.user('x')],
          maxOutputTokens: 0,
        ),
        throwsA(isA<ValidationException>()),
      );
    });

    test('prompt builds a single-turn request with a system message', () {
      final request = ChatRequest.prompt('hi', system: 'be brief');

      expect(request.messages, hasLength(2));
      expect(request.messages.first.role, MessageRole.system);
    });

    test('withMessages appends without mutating the original', () {
      final original = ChatRequest.prompt('hi');
      final extended = original.withMessages(<Message>[
        Message.assistant('hello'),
      ]);

      expect(original.messages, hasLength(1));
      expect(extended.messages, hasLength(2));
    });

    test('derives the capabilities it needs', () {
      final registry = ToolRegistry()
        ..register(
          FunctionTool.text(
            name: 'now',
            description: 'The current time.',
            handler: (_) async => 'now',
          ),
        );

      final withTools = ChatRequest(
        messages: <Message>[Message.user('x')],
        tools: registry.all,
      );
      expect(
        withTools.requirements.map((r) => r.capability),
        contains(ModelCapability.toolCalling),
      );

      final withEmptySet = ChatRequest(
        messages: <Message>[Message.user('x')],
        tools: ToolRegistry().all,
      );
      expect(
        withEmptySet.requirements,
        isEmpty,
        reason: 'an empty set asks nothing of the model',
      );

      final structured = ChatRequest(
        messages: <Message>[Message.user('x')],
        responseFormat: ResponseFormat.jsonSchema(
          name: 'x',
          schema: JsonSchema.object(),
        ),
      );
      expect(
        structured.requirements.map((r) => r.capability),
        contains(ModelCapability.structuredOutput),
      );
    });

    test('jsonSchema converts to the strict dialect automatically', () {
      final format = ResponseFormat.jsonSchema(
        name: 'city',
        schema: JsonSchema.object(
          properties: {
            'name': JsonSchema.string(),
            'region': JsonSchema.string(),
          },
          required: {'name'},
        ),
      );

      expect(format.schema!.additionalProperties, isFalse);
      expect(
        format.schema!.requiredProperties,
        containsAll(<String>['name', 'region']),
      );
      expect(format.schema!.properties['region']!.nullable, isTrue);
    });

    group('cacheKey', () {
      test('is stable for identical requests', () {
        expect(
          ChatRequest.prompt('hi').cacheKey,
          ChatRequest.prompt('hi').cacheKey,
        );
      });

      test('changes with anything that affects the answer', () {
        final base = ChatRequest.prompt('hi');

        expect(base.cacheKey, isNot(ChatRequest.prompt('bye').cacheKey));
        expect(base.cacheKey, isNot(base.copyWith(temperature: 0.5).cacheKey));
        expect(
          base.cacheKey,
          isNot(
            base
                .copyWith(
                  providerOptions: const <String, Object?>{'logit_bias': 1},
                )
                .cacheKey,
          ),
        );
      });

      test('ignores metadata, which is application bookkeeping', () {
        final base = ChatRequest.prompt('hi');

        expect(
          base.cacheKey,
          base
              .copyWith(metadata: const <String, Object?>{'tenant': 'a'})
              .cacheKey,
          reason: 'metadata must not fragment the cache',
        );
      });
    });
  });

  group('ChatResponse', () {
    ChatResponse responding(String text, {FinishReason? reason}) =>
        ChatResponse(
          message: Message.assistant(text),
          modelId: 'm',
          finishReason: reason ?? FinishReason.stop,
        );

    test('exposes text, reasoning and tool calls from the message', () {
      final response = ChatResponse(
        message: Message(
          role: MessageRole.assistant,
          parts: [
            ReasoningPart('thinking'),
            TextPart('answer'),
            ToolCallPart(id: 'c', name: 't'),
          ],
        ),
        modelId: 'm',
      );

      expect(response.text, 'answer');
      expect(response.reasoning, 'thinking');
      expect(response.hasToolCalls, isTrue);
    });

    test('ensureComplete rejects a truncated answer', () {
      // A truncated response is not a smaller answer; it is a corrupt one.
      expect(
        responding('cut off', reason: FinishReason.length).ensureComplete,
        throwsA(
          isA<ProviderException>().having(
            (e) => e.message,
            'message',
            contains('maxOutputTokens'),
          ),
        ),
      );
      expect(responding('fine').ensureComplete, returnsNormally);
    });

    test('a content filter block is not retryable', () {
      expect(
        responding('', reason: FinishReason.contentFilter).ensureComplete,
        throwsA(
          isA<ProviderException>().having(
            (e) => e.isRetryable,
            'isRetryable',
            isFalse,
          ),
        ),
      );
    });

    test('decodeJson parses a structured answer', () {
      final json = responding('{"city":"Paris","population":2}').decodeJson();

      expect(json['city'], 'Paris');
    });

    test('decodeJson strips a markdown code fence', () {
      // Models add these even when told not to; a wasted round trip over a
      // formatting habit is a poor trade.
      final json = responding('```json\n{"city":"Paris"}\n```').decodeJson();

      expect(json['city'], 'Paris');
    });

    test('decodeJson reports the offending text when it is not JSON', () {
      expect(
        () => responding('I think the city is Paris.').decodeJson(),
        throwsA(
          isA<SerializationException>().having(
            (e) => e.message,
            'message',
            contains('I think the city is Paris.'),
          ),
        ),
      );
    });

    test('decodeJson validates against a schema when one is given', () {
      final schema = JsonSchema.object(
        properties: {'city': JsonSchema.string()},
        required: {'city'},
      );

      expect(
        () => responding('{"town":"Paris"}').decodeJson(schema: schema),
        throwsA(isA<ValidationException>()),
        reason: 'valid JSON of the wrong shape still fails the caller',
      );
    });

    test('decodeAs maps through a constructor', () {
      final city = responding(
        '{"city":"Paris"}',
      ).decodeAs((json) => json.requireString('city'));

      expect(city, 'Paris');
    });

    test('refuses to decode a truncated answer', () {
      expect(
        () => responding(
          '{"city":"Par',
          reason: FinishReason.length,
        ).decodeJson(),
        throwsA(isA<ProviderException>()),
      );
    });
  });

  group('ModelInfo', () {
    test('reports capabilities and a qualified id', () {
      final info = ModelInfo(
        id: 'gpt-4o',
        provider: 'openai',
        capabilities: ModelCapabilities.frontier,
      );

      expect(info.qualifiedId, 'openai:gpt-4o');
      expect(info.supports(ModelCapability.toolCalling), isTrue);
      expect(info.supports(ModelCapability.audioInput), isFalse);
      expect(
        info.supportsAll(<ModelCapability>[
          ModelCapability.vision,
          ModelCapability.streaming,
        ]),
        isTrue,
      );
    });

    test('requireCapability names the missing feature and the component', () {
      final info = ModelInfo(
        id: 'tinyllama',
        provider: 'ollama',
        capabilities: ModelCapabilities.localMinimal,
      );

      expect(
        () => info.requireCapability(ModelCapability.toolCalling),
        throwsA(
          isA<CapabilityNotSupportedException>()
              .having((e) => e.capability, 'capability', 'toolCalling')
              .having((e) => e.component, 'component', 'ollama:tinyllama'),
        ),
      );
    });

    test('local models declare conservative capabilities', () {
      // Many local models advertise tool calling and then emit malformed calls.
      expect(
        ModelCapabilities.localMinimal.contains(ModelCapability.toolCalling),
        isFalse,
      );
    });
  });

  group('ModelPricing', () {
    test('bills cached tokens at the cached rate', () {
      const pricing = ModelPricing(
        inputPerMillion: 2.5,
        outputPerMillion: 10,
        cachedInputPerMillion: 0.25,
      );
      const usage = TokenUsage(
        promptTokens: 1000000,
        completionTokens: 100000,
        cachedPromptTokens: 900000,
      );

      // 100k uncached at 2.5 + 900k cached at 0.25 + 100k output at 10.
      expect(pricing.estimate(usage), closeTo(0.25 + 0.225 + 1.0, 1e-9));
    });

    test('falls back to the input rate when no cached rate is set', () {
      const pricing = ModelPricing(inputPerMillion: 1, outputPerMillion: 2);
      const usage = TokenUsage(
        promptTokens: 1000000,
        cachedPromptTokens: 500000,
      );

      expect(pricing.estimate(usage), closeTo(1.0, 1e-9));
    });

    test('a model without prices estimates nothing', () {
      final info = ModelInfo(id: 'local', provider: 'ollama', isLocal: true);

      expect(info.estimateCost(const TokenUsage(promptTokens: 100)), isNull);
    });
  });

  group('Embedding', () {
    test('computes cosine similarity', () {
      final a = Embedding(values: const <double>[1, 0, 0]);
      final b = Embedding(values: const <double>[1, 0, 0]);
      final c = Embedding(values: const <double>[0, 1, 0]);

      expect(a.cosineSimilarity(b), closeTo(1.0, 1e-9));
      expect(a.cosineSimilarity(c), closeTo(0.0, 1e-9));
    });

    test('rejects a dimension mismatch instead of returning nonsense', () {
      // The signature of an index built with one model and queried with another.
      final a = Embedding(values: const <double>[1, 0]);
      final b = Embedding(values: const <double>[1, 0, 0]);

      expect(
        () => a.cosineSimilarity(b),
        throwsA(
          isA<ValidationException>().having(
            (e) => e.message,
            'message',
            contains('built with one model'),
          ),
        ),
      );
    });

    test('normalises to unit length', () {
      final normalised = Embedding(values: const <double>[3, 4]).normalised();

      expect(normalised.values[0], closeTo(0.6, 1e-9));
      expect(normalised.values[1], closeTo(0.8, 1e-9));
    });

    test('handles a zero vector without dividing by zero', () {
      final zero = Embedding(values: const <double>[0, 0]);

      expect(zero.normalised().values, <double>[0, 0]);
      expect(zero.cosineSimilarity(zero), 0);
    });

    test('round-trips through JSON', () {
      final original = Embedding(values: const <double>[0.1, 0.2], index: 3);

      expect(Embedding.fromJson(original.toJson()).values, original.values);
      expect(Embedding.fromJson(original.toJson()).index, 3);
    });

    test('embedAll batches and re-indexes against the full input', () async {
      final model = FakeEmbeddingModel(maxBatchSize: 2);
      final inputs = List<String>.generate(5, (i) => 'chunk $i');
      final progress = <int>[];

      final embeddings = await model.embedAll(
        inputs,
        purpose: EmbeddingPurpose.document,
        onProgress: (done, total) => progress.add(done),
      );

      expect(embeddings, hasLength(5));
      expect(
        embeddings.map((e) => e.index),
        <int>[0, 1, 2, 3, 4],
        reason: 'providers index within a batch; the caller needs global order',
      );
      expect(progress, <int>[2, 4, 5]);
      expect(model.embedded, inputs);
    });
  });

  group('FakeChatModel', () {
    test('records requests and repeats the last scripted turn', () async {
      final model = FakeChatModel.text('Paris.');

      await model.generate(ChatRequest.prompt('one'));
      await model.generate(ChatRequest.prompt('two'));

      expect(model.callCount, 2);
      expect(model.lastRequest.messages.single.text, 'two');
      expect(model.requests.first.messages.single.text, 'one');
    });

    test('plays a tool-call script', () async {
      final model = FakeChatModel.toolCall(
        toolCalls: [
          ToolCallPart(id: 'c1', name: 'search_web', arguments: {'q': 'x'}),
        ],
        then: 'Found it.',
      );

      final first = await model.generate(ChatRequest.prompt('x'));
      final second = await model.generate(ChatRequest.prompt('x'));

      expect(first.hasToolCalls, isTrue);
      expect(first.finishReason, FinishReason.toolCalls);
      expect(second.text, 'Found it.');
    });

    test('streams a scripted answer as several chunks', () async {
      final model = FakeChatModel.text('Hello world again');

      final chunks = await model.stream(ChatRequest.prompt('x')).toList();

      expect(chunks.where((c) => c.textDelta != null), hasLength(3));
      expect(
        (await model.stream(ChatRequest.prompt('x')).collect()).text,
        'Hello world again',
      );
    });

    test('replays explicit chunks for both modes', () async {
      final model = FakeChatModel(
        turns: <FakeTurn>[
          FakeTurn.chunks(const <ChatChunk>[
            ChatChunk.text('a'),
            ChatChunk.text('b'),
            ChatChunk.done(),
          ]),
        ],
      );

      expect((await model.generate(ChatRequest.prompt('x'))).text, 'ab');
      expect(
        (await model.stream(ChatRequest.prompt('x')).collect()).text,
        'ab',
      );
    });

    test('reports an empty script clearly', () async {
      final model = FakeChatModel();

      await expectLater(
        model.generate(ChatRequest.prompt('x')),
        throwsA(isA<StateError>()),
      );
    });

    test('lastRequest fails loudly before any call', () {
      expect(() => FakeChatModel.text('x').lastRequest, throwsStateError);
    });
  });

  group('ChatModelOperations', () {
    test('prompt returns the answer text', () async {
      expect(await FakeChatModel.text('Paris.').prompt('capital?'), 'Paris.');
    });

    test(
      'generateStructured falls back to JSON mode without the capability',
      () async {
        final model = FakeChatModel(
          info: ModelInfo(
            id: 'weak',
            provider: 'local',
            capabilities: const <ModelCapability>{ModelCapability.jsonMode},
          ),
          turns: <FakeTurn>[
            FakeTurn.answer(
              ChatResponse(
                message: Message.assistant('{"city":"Paris"}'),
                modelId: 'weak',
              ),
            ),
          ],
        );

        final city = await model.generateStructured<String>(
          ChatRequest.prompt('capital?'),
          name: 'city',
          schema: JsonSchema.object(
            properties: {'city': JsonSchema.string()},
            required: {'city'},
          ),
          fromJson: (json) => json.requireString('city'),
        );

        expect(city, 'Paris');
        expect(
          model.lastRequest.responseFormat.kind,
          ResponseFormatKind.json,
          reason: 'the weaker mode is used, and the answer is still validated',
        );
      },
    );
  });
}
