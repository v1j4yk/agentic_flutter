import 'package:agentic_core/agentic_core.dart';
import 'package:agentic_core/testing.dart';
import 'package:agentic_llm/agentic_llm.dart';
import 'package:agentic_llm/testing.dart';
import 'package:test/test.dart';

ProviderException transient() =>
    ProviderException('overloaded', provider: 'test', statusCode: 503);

ChatRequest ask([String prompt = 'hello']) =>
    ChatRequest(messages: <Message>[Message.user(prompt)]);

ModelInfo infoFor(String id) =>
    ModelInfo(id: id, provider: id, capabilities: ModelCapabilities.frontier);

void main() {
  group('RetryingChatModel', () {
    test('retries a transient failure and succeeds', () async {
      final inner = FakeChatModel.failingThenAnswering(
        error: transient(),
        times: 2,
        then: 'Recovered.',
      );
      final model = RetryingChatModel(
        inner,
        policy: const RetryPolicy(
          maxAttempts: 4,
          backoff: ConstantBackoff(Duration(milliseconds: 1)),
        ),
      );

      final response = await model.generate(
        ask(),
        context: AgenticContext.root(clock: FakeClock(autoAdvance: true)),
      );

      expect(response.text, 'Recovered.');
      expect(inner.callCount, 3);
    });

    test('does not retry a permanent failure', () async {
      final inner = FakeChatModel.failing(ValidationException('bad request'));
      final model = RetryingChatModel(inner, policy: const RetryPolicy());

      await expectLater(
        model.generate(
          ask(),
          context: AgenticContext.root(clock: FakeClock(autoAdvance: true)),
        ),
        throwsA(isA<ValidationException>()),
      );
      expect(inner.callCount, 1);
    });

    test('retries a stream that fails before delivering anything', () async {
      final inner = FakeChatModel(
        turns: <FakeTurn>[
          FakeTurn.failure(transient()),
          FakeTurn.chunks(const <ChatChunk>[
            ChatChunk.text('ok'),
            ChatChunk.done(),
          ]),
        ],
      );
      final model = RetryingChatModel(
        inner,
        policy: const RetryPolicy(
          maxAttempts: 3,
          backoff: ConstantBackoff(Duration(milliseconds: 1)),
        ),
      );

      final response = await model
          .stream(
            ask(),
            context: AgenticContext.root(clock: FakeClock(autoAdvance: true)),
          )
          .collect();

      expect(response.text, 'ok');
      expect(inner.callCount, 2);
    });

    test('does not restart a stream after a chunk was delivered', () async {
      // Replaying would emit a second beginning, and a UI that already rendered
      // the first sentence would show duplicated text.
      final inner = FakeChatModel(
        turns: <FakeTurn>[
          FakeTurn.chunks(const <ChatChunk>[ChatChunk.text('partial')]),
        ],
      );
      // The scripted turn ends without a terminal chunk, then the next attempt
      // would repeat it; the guard must stop that.
      final received = <String>[];

      final model = RetryingChatModel(
        _FailAfterFirstChunk(inner),
        policy: const RetryPolicy(
          maxAttempts: 3,
          backoff: ConstantBackoff(Duration(milliseconds: 1)),
        ),
      );

      await expectLater(
        model
            .stream(
              ask(),
              context: AgenticContext.root(clock: FakeClock(autoAdvance: true)),
            )
            .forEach((chunk) => received.add(chunk.textDelta ?? '')),
        throwsA(isA<ProviderException>()),
      );

      expect(received, <String>[
        'partial',
      ], reason: 'the partial output is delivered once, not twice');
    });
  });

  group('FallbackChatModel', () {
    test('falls over to the next model on a transient failure', () async {
      final primary = FakeChatModel.failing(transient(), info: infoFor('a'));
      final secondary = FakeChatModel.text(
        'from secondary',
        info: infoFor('b'),
      );
      final model = FallbackChatModel(<ChatModel>[primary, secondary]);

      final response = await model.generate(ask());

      expect(response.text, 'from secondary');
      expect(primary.callCount, 1);
      expect(secondary.callCount, 1);
      await model.dispose();
    });

    test('does not fail over on a caller-side failure', () async {
      // Every provider rejects a malformed request identically; trying three
      // turns one clear error into three confusing ones.
      final primary = FakeChatModel.failing(
        ValidationException('bad'),
        info: infoFor('a'),
      );
      final secondary = FakeChatModel.text('unused', info: infoFor('b'));
      final model = FallbackChatModel(<ChatModel>[primary, secondary]);

      await expectLater(
        model.generate(ask()),
        throwsA(isA<ValidationException>()),
      );
      expect(secondary.callCount, 0);
      await model.dispose();
    });

    test(
      'fails over on an exhausted quota even though it is not retryable',
      () async {
        final primary = FakeChatModel.failing(
          QuotaExceededException('out of credit', provider: 'a'),
          info: infoFor('a'),
        );
        final secondary = FakeChatModel.text('second', info: infoFor('b'));
        final model = FallbackChatModel(<ChatModel>[primary, secondary]);

        expect((await model.generate(ask())).text, 'second');
        await model.dispose();
      },
    );

    test('opens a circuit and stops calling the failed provider', () async {
      final clock = FakeClock();
      final primary = FakeChatModel.failing(transient(), info: infoFor('a'));
      final secondary = FakeChatModel.text('second', info: infoFor('b'));
      final model = FallbackChatModel(
        <ChatModel>[primary, secondary],
        failureThreshold: 2,
        clock: clock,
      );

      for (var i = 0; i < 4; i++) {
        await model.generate(ask());
      }

      expect(
        primary.callCount,
        2,
        reason: 'after the circuit opens, failover is instant',
      );
      expect(secondary.callCount, 4);
      await model.dispose();
    });

    test('publishes a failover event', () async {
      final bus = BroadcastEventBus();
      final model = FallbackChatModel(<ChatModel>[
        FakeChatModel.failing(transient(), info: infoFor('a')),
        FakeChatModel.text('second', info: infoFor('b')),
      ]);

      await model.generate(
        ask(),
        context: AgenticContext.root(
          events: bus,
          ids: SequentialIdGenerator(prefix: 'e'),
        ),
      );

      final event = bus.replayBuffer.whereType<LlmFailoverOccurred>().single;
      expect(event.failedModelId, 'a:a');
      expect(event.modelId, 'b');
      await bus.dispose();
      await model.dispose();
    });

    test('rethrows the last failure when every model fails', () async {
      final model = FallbackChatModel(<ChatModel>[
        FakeChatModel.failing(transient(), info: infoFor('a')),
        FakeChatModel.failing(transient(), info: infoFor('b')),
      ]);

      await expectLater(
        model.generate(ask()),
        throwsA(isA<ProviderException>()),
      );
      await model.dispose();
    });

    test('rejects an empty chain', () {
      expect(
        () => FallbackChatModel(<ChatModel>[]),
        throwsA(isA<ConfigurationException>()),
      );
    });

    test('disposes every model in the chain', () async {
      final primary = FakeChatModel.text('a', info: infoFor('a'));
      final secondary = FakeChatModel.text('b', info: infoFor('b'));

      await FallbackChatModel(<ChatModel>[primary, secondary]).dispose();

      expect(primary.isDisposed, isTrue);
      expect(secondary.isDisposed, isTrue);
    });
  });

  group('CachingChatModel', () {
    test('serves a repeated request from cache', () async {
      final inner = FakeChatModel.text('Paris.');
      final model = CachingChatModel(inner, cache: InMemoryChatCache());

      final first = await model.generate(ask('capital of France'));
      final second = await model.generate(ask('capital of France'));

      expect(first.text, 'Paris.');
      expect(second.text, 'Paris.');
      expect(inner.callCount, 1);
      expect(second.metadata['cached'], isTrue);
    });

    test('zeroes usage on a hit so cost is not double-counted', () async {
      final model = CachingChatModel(
        FakeChatModel.text('Paris.'),
        cache: InMemoryChatCache(),
      );

      await model.generate(ask());
      final cached = await model.generate(ask());

      expect(cached.usage, TokenUsage.empty);
      expect(cached.cost, 0);
    });

    test('does not cache a creative request by default', () async {
      // The caller asked for variety; serving the same sentence reads as a bug.
      final inner = FakeChatModel.text('a poem');
      final model = CachingChatModel(inner, cache: InMemoryChatCache());

      final request = ChatRequest(
        messages: <Message>[Message.user('write a poem')],
        temperature: 0.9,
      );
      await model.generate(request);
      await model.generate(request);

      expect(inner.callCount, 2);
    });

    test('does not cache a truncated answer', () async {
      // Caching corruption would serve it indefinitely.
      final inner = FakeChatModel(
        turns: <FakeTurn>[
          FakeTurn.answer(
            ChatResponse(
              message: Message.assistant('cut off mid-'),
              modelId: 'fake-model',
              finishReason: FinishReason.length,
            ),
          ),
        ],
      );
      final model = CachingChatModel(inner, cache: InMemoryChatCache());

      await model.generate(ask());
      await model.generate(ask());

      expect(inner.callCount, 2);
    });

    test('namespaces entries by model', () async {
      final cache = InMemoryChatCache();
      final first = CachingChatModel(
        FakeChatModel.text('from A', info: infoFor('a')),
        cache: cache,
      );
      final second = CachingChatModel(
        FakeChatModel.text('from B', info: infoFor('b')),
        cache: cache,
      );

      expect((await first.generate(ask())).text, 'from A');
      expect(
        (await second.generate(ask())).text,
        'from B',
        reason: 'switching models must not serve a stale answer',
      );
    });

    test('different requests miss', () async {
      final inner = FakeChatModel.text('answer');
      final model = CachingChatModel(inner, cache: InMemoryChatCache());

      await model.generate(ask('one'));
      await model.generate(ask('two'));

      expect(inner.callCount, 2);
    });

    test('replays a cached answer as a stream', () async {
      final inner = FakeChatModel.text('Paris.');
      final model = CachingChatModel(inner, cache: InMemoryChatCache());

      await model.generate(ask());
      final response = await model.stream(ask()).collect();

      expect(response.text, 'Paris.');
      expect(inner.callCount, 1);
    });

    test('stores an answer produced by streaming', () async {
      final inner = FakeChatModel.text('Paris.');
      final model = CachingChatModel(inner, cache: InMemoryChatCache());

      await model.stream(ask()).collect();
      final second = await model.generate(ask());

      expect(second.text, 'Paris.');
      expect(inner.callCount, 1);
    });
  });

  group('InMemoryChatCache', () {
    ChatResponse answer(String text) =>
        ChatResponse(message: Message.assistant(text), modelId: 'm');

    test('evicts least recently used entries', () async {
      final cache = InMemoryChatCache(maxEntries: 2);

      await cache.put('a', answer('a'));
      await cache.put('b', answer('b'));
      await cache.get('a'); // 'a' becomes most recently used
      await cache.put('c', answer('c'));

      expect(await cache.get('a'), isNotNull);
      expect(await cache.get('b'), isNull, reason: 'b was least recently used');
      expect(await cache.get('c'), isNotNull);
    });

    test('expires entries after the TTL', () async {
      final clock = FakeClock();
      final cache = InMemoryChatCache(
        ttl: const Duration(minutes: 5),
        clock: clock,
      );

      await cache.put('a', answer('a'));
      expect(await cache.get('a'), isNotNull);

      await clock.advance(const Duration(minutes: 6));
      expect(await cache.get('a'), isNull);
    });

    test('clear discards everything', () async {
      final cache = InMemoryChatCache();
      await cache.put('a', answer('a'));
      await cache.clear();

      expect(await cache.get('a'), isNull);
      expect(cache.length, 0);
    });
  });

  group('ObservableChatModel', () {
    test('publishes start and completion events with usage', () async {
      final bus = BroadcastEventBus();
      final model = ObservableChatModel(FakeChatModel.text('Paris.'));

      await model.generate(
        ask(),
        context: AgenticContext.root(
          runId: 'run-1',
          events: bus,
          ids: SequentialIdGenerator(prefix: 'e'),
        ),
      );

      final started = bus.replayBuffer.whereType<LlmRequestStarted>().single;
      final completed = bus.replayBuffer
          .whereType<LlmResponseCompleted>()
          .single;

      expect(started.messageCount, 1);
      expect(started.isStreaming, isFalse);
      expect(completed.usage.totalTokens, 15);
      expect(completed.finishReason, FinishReason.stop);
      expect(completed.runId, 'run-1');
      await bus.dispose();
    });

    test('opens a span with model attributes', () async {
      final exporter = InMemorySpanExporter();
      final model = ObservableChatModel(FakeChatModel.text('Paris.'));

      await model.generate(
        ask(),
        context: AgenticContext.root(tracer: Tracer(exporter: exporter)),
      );

      final span = exporter.named('llm.generate').single;
      expect(span.attributes['llm.model'], 'fake-model');
      expect(span.attributes['llm.tokens.prompt'], 10);
      expect(span.status, SpanStatus.ok);
    });

    test('publishes a failure event and rethrows', () async {
      final bus = BroadcastEventBus();
      final model = ObservableChatModel(FakeChatModel.failing(transient()));

      await expectLater(
        model.generate(
          ask(),
          context: AgenticContext.root(
            events: bus,
            ids: SequentialIdGenerator(prefix: 'e'),
          ),
        ),
        throwsA(isA<ProviderException>()),
      );

      final failed = bus.replayBuffer.whereType<LlmRequestFailed>().single;
      expect(failed.code, 'provider_error');
      expect(failed.isRetryable, isTrue);
      await bus.dispose();
    });

    test('reports time to first token when streaming', () async {
      final bus = BroadcastEventBus();
      final model = ObservableChatModel(FakeChatModel.text('Hello world'));

      await model
          .stream(
            ask(),
            context: AgenticContext.root(
              events: bus,
              ids: SequentialIdGenerator(prefix: 'e'),
            ),
          )
          .collect();

      expect(bus.replayBuffer.whereType<LlmFirstTokenReceived>(), hasLength(1));
      expect(bus.replayBuffer.whereType<LlmResponseCompleted>(), hasLength(1));
      await bus.dispose();
    });

    test('prices a call the adapter did not price', () async {
      final bus = BroadcastEventBus();
      final model = ObservableChatModel(
        FakeChatModel.text(
          'Paris.',
          info: ModelInfo(
            id: 'priced',
            provider: 'fake',
            capabilities: ModelCapabilities.frontier,
            pricing: const ModelPricing(
              inputPerMillion: 1000000,
              outputPerMillion: 1000000,
            ),
          ),
        ),
      );

      await model.generate(
        ask(),
        context: AgenticContext.root(
          events: bus,
          ids: SequentialIdGenerator(prefix: 'e'),
        ),
      );

      final completed = bus.replayBuffer
          .whereType<LlmResponseCompleted>()
          .single;
      expect(
        completed.cost,
        closeTo(15, 1e-9),
        reason: 'the same figure whichever path produced the answer',
      );
      await bus.dispose();
    });

    test('works without a context', () async {
      final model = ObservableChatModel(FakeChatModel.text('Paris.'));

      expect((await model.generate(ask())).text, 'Paris.');
    });
  });

  group('composition', () {
    test('stacks observe, retry, cache and failover together', () async {
      final bus = BroadcastEventBus();
      final flaky = FakeChatModel.failingThenAnswering(
        error: transient(),
        then: 'Paris.',
      );

      final model = ObservableChatModel(
        RetryingChatModel(
          CachingChatModel(
            FallbackChatModel(<ChatModel>[flaky]),
            cache: InMemoryChatCache(),
          ),
          policy: const RetryPolicy(
            maxAttempts: 3,
            backoff: ConstantBackoff(Duration(milliseconds: 1)),
          ),
        ),
      );

      final context = AgenticContext.root(
        events: bus,
        clock: FakeClock(autoAdvance: true),
        ids: SequentialIdGenerator(prefix: 'e'),
      );

      final first = await model.generate(ask(), context: context);
      final second = await model.generate(ask(), context: context);

      expect(first.text, 'Paris.');
      expect(second.text, 'Paris.');
      expect(
        flaky.callCount,
        2,
        reason: 'one failure, one success, then cached',
      );
      // Observation sits outermost, so both calls are visible even though one
      // never reached a provider.
      expect(bus.replayBuffer.whereType<LlmResponseCompleted>(), hasLength(2));
      await bus.dispose();
      await model.dispose();
    });
  });
}

/// Delivers the inner model's first chunk, then fails.
///
/// Reproduces a connection dropped mid-answer, which is the case a retry must
/// refuse to replay.
final class _FailAfterFirstChunk extends DelegatingChatModel {
  const _FailAfterFirstChunk(super.inner);

  @override
  Stream<ChatChunk> stream(
    ChatRequest request, {
    AgenticContext? context,
  }) async* {
    yield* inner.stream(request, context: context);
    throw transient();
  }
}
