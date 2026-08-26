import 'package:agentic_agents/agentic_agents.dart';
import 'package:agentic_core/agentic_core.dart';
import 'package:agentic_core/testing.dart';
import 'package:agentic_llm/agentic_llm.dart';
import 'package:agentic_llm/testing.dart';
import 'package:agentic_memory/agentic_memory.dart';
import 'package:agentic_tools/agentic_tools.dart';
import 'package:test/test.dart';

MemoryEntry entryOf(
  String content, {
  String? id,
  MemoryKind kind = MemoryKind.fact,
  double importance = 0.5,
  DateTime? createdAt,
  DateTime? expiresAt,
  String? sessionId,
  Set<String> tags = const <String>{},
  List<double>? embedding,
}) => MemoryEntry(
  id: id ?? 'mem-${content.hashCode}',
  content: content,
  createdAt: createdAt ?? DateTime.utc(2026),
  kind: kind,
  importance: importance,
  expiresAt: expiresAt,
  sessionId: sessionId,
  tags: tags,
  embedding: embedding,
);

void main() {
  group('MemoryEntry', () {
    test('round-trips through JSON', () {
      final original = entryOf(
        'The billing service uses Dart 3.11.',
        kind: MemoryKind.fact,
        importance: 0.8,
        tags: {'billing'},
        embedding: <double>[0.1, 0.2],
      );

      final restored = MemoryEntry.fromJson(original.toJson());

      expect(restored.id, original.id);
      expect(restored.content, original.content);
      expect(restored.kind, MemoryKind.fact);
      expect(restored.importance, 0.8);
      expect(restored.tags, {'billing'});
      expect(restored.embedding, <double>[0.1, 0.2]);
    });

    test('reports expiry against a supplied instant', () {
      final entry = entryOf('temp', expiresAt: DateTime.utc(2026, 6));

      expect(entry.isExpired(DateTime.utc(2026, 5)), isFalse);
      expect(entry.isExpired(DateTime.utc(2026, 7)), isTrue);
      expect(entryOf('permanent').isExpired(DateTime.utc(2099)), isFalse);
    });

    test('rejects an importance outside 0..1', () {
      expect(
        () => entryOf('x', importance: 1.5),
        throwsA(isA<AssertionError>()),
      );
    });

    test('lastTouched prefers the revision time', () {
      final entry = entryOf(
        'x',
        createdAt: DateTime.utc(2026),
      ).copyWith(updatedAt: DateTime.utc(2026, 3));

      expect(entry.lastTouched, DateTime.utc(2026, 3));
    });
  });

  group('MemoryQuery filters', () {
    final now = DateTime.utc(2026, 6);

    test('excludes expired entries unless asked', () {
      final expired = entryOf('old', expiresAt: DateTime.utc(2026, 1));

      expect(MemoryQuery().matches(expired, now: now), isFalse);
      expect(
        MemoryQuery(includeExpired: true).matches(expired, now: now),
        isTrue,
      );
    });

    test('filters by kind, session, tags and importance', () {
      final entry = entryOf(
        'x',
        kind: MemoryKind.preference,
        importance: 0.4,
        sessionId: 's1',
        tags: {'ui'},
      );

      expect(
        MemoryQuery(kinds: {MemoryKind.preference}).matches(entry, now: now),
        isTrue,
      );
      expect(
        MemoryQuery(kinds: {MemoryKind.event}).matches(entry, now: now),
        isFalse,
      );
      expect(MemoryQuery(sessionId: 's1').matches(entry, now: now), isTrue);
      expect(MemoryQuery(sessionId: 's2').matches(entry, now: now), isFalse);
      expect(MemoryQuery(tags: {'ui'}).matches(entry, now: now), isTrue);
      expect(MemoryQuery(tags: {'api'}).matches(entry, now: now), isFalse);
      expect(MemoryQuery(minImportance: 0.5).matches(entry, now: now), isFalse);
    });
  });

  group('InMemoryMemoryStore', () {
    late InMemoryMemoryStore store;
    late FakeClock clock;

    setUp(() {
      clock = FakeClock(initialTime: DateTime.utc(2026, 6));
      store = InMemoryMemoryStore(clock: clock);
    });

    test('writes and reads back', () async {
      final entry = await store.remember('Ada prefers British English.');

      expect(await store.count(), 1);
      expect((await store.read(entry.id))!.content, contains('British'));
    });

    test('finds an entry by an exact term', () async {
      await store.writeAll(<MemoryEntry>[
        entryOf('The billing service uses Dart 3.11.', id: 'a'),
        entryOf('The user prefers dark mode.', id: 'b'),
        entryOf('The deploy pipeline runs on Tuesdays.', id: 'c'),
      ]);

      final hits = await store.recall('billing');

      expect(hits.first.entry.id, 'a');
      expect(hits.first.explanation, contains('billing'));
    });

    test('finds an identifier that semantic search would miss', () async {
      // The case keyword retrieval exists for: a rare token that carries all
      // the meaning and no semantic neighbours.
      await store.writeAll(<MemoryEntry>[
        entryOf('Ticket PROJ-4417 tracks the login regression.', id: 'a'),
        entryOf('The team meets on Mondays to plan work.', id: 'b'),
      ]);

      final hits = await store.recall('PROJ-4417');

      expect(hits, hasLength(1));
      expect(hits.single.entry.id, 'a');
    });

    test('returns nothing when no term matches', () async {
      // A store with no floor starts confidently recalling irrelevancies.
      await store.write(entryOf('The user prefers dark mode.'));

      expect(await store.recall('quantum chromodynamics'), isEmpty);
    });

    test('weights rare terms above common ones', () async {
      await store.writeAll(<MemoryEntry>[
        for (var i = 0; i < 8; i++)
          entryOf('The user works on the project daily.', id: 'common-$i'),
        entryOf('The user works on the kubernetes migration.', id: 'rare'),
      ]);

      final hits = await store.recall('user kubernetes');

      expect(hits.first.entry.id, 'rare');
    });

    test('a query without text lists by importance and recency', () async {
      await store.writeAll(<MemoryEntry>[
        entryOf('low', id: 'low', importance: 0.2),
        entryOf('high', id: 'high', importance: 0.9),
      ]);

      final hits = await store.search(MemoryQuery(limit: 5));

      expect(hits.first.entry.id, 'high');
      expect(hits.first.explanation, contains('importance'));
    });

    test('prefers a recent memory over an old one, all else equal', () async {
      await store.writeAll(<MemoryEntry>[
        entryOf(
          'dark mode preferred',
          id: 'old',
          createdAt: DateTime.utc(2025),
        ),
        entryOf(
          'dark mode preferred now',
          id: 'new',
          createdAt: DateTime.utc(2026, 5, 25),
        ),
      ]);

      final hits = await store.recall('dark mode');

      expect(hits.first.entry.id, 'new');
    });

    test('merges a re-remembered fact instead of duplicating it', () async {
      // Agents re-remember constantly; near-duplicates crowd out everything
      // else from the few slots recall is allowed.
      await store.remember('Ada prefers concise answers.', importance: 0.4);
      await store.remember('Ada prefers concise answers!', importance: 0.9);

      expect(await store.count(), 1);
      final hits = await store.recall('concise');
      expect(hits.single.entry.importance, 0.9);
      expect(hits.single.entry.updatedAt, isNotNull);
    });

    test('deduplication can be turned off', () async {
      final duplicating = InMemoryMemoryStore(deduplicate: false, clock: clock);

      await duplicating.remember('same');
      await duplicating.remember('same');

      expect(await duplicating.count(), 2);
    });

    test('prunes expired entries', () async {
      await store.writeAll(<MemoryEntry>[
        entryOf('stale', id: 'a', expiresAt: DateTime.utc(2026, 1)),
        entryOf('fresh', id: 'b'),
      ]);

      expect(await store.prune(), 1);
      expect(await store.count(), 1);
    });

    test('excludes expired entries from search before pruning', () async {
      await store.write(entryOf('stale', expiresAt: DateTime.utc(2026, 1)));

      expect(await store.recall('stale'), isEmpty);
    });

    test('evicts the least valuable entry when full', () async {
      final bounded = InMemoryMemoryStore(maxEntries: 2, clock: clock);

      await bounded.writeAll(<MemoryEntry>[
        entryOf('trivial', id: 'a', importance: 0.1),
        entryOf('important', id: 'b', importance: 0.9),
      ]);
      await bounded.write(entryOf('also important', id: 'c', importance: 0.8));

      expect(await bounded.count(), 2);
      expect(await bounded.read('a'), isNull, reason: 'least valuable goes');
      expect(await bounded.read('b'), isNotNull);
    });

    test('forgetSession removes only that conversation', () async {
      await store.writeAll(<MemoryEntry>[
        entryOf('scoped', id: 'a', sessionId: 's1'),
        entryOf('global', id: 'b'),
      ]);

      expect(await store.forgetSession('s1'), 1);
      expect(await store.read('b'), isNotNull);
    });

    test('recallAsMessage returns null when nothing is relevant', () async {
      // An empty "here is what I remember" block reads to the model as "you
      // remember nothing relevant" and measurably changes its answers.
      expect(
        await store.recallAsMessage(MemoryQuery(text: 'anything')),
        isNull,
      );
    });

    test('recallAsMessage renders hits with a staleness caveat', () async {
      await store.remember('Ada prefers British English.');

      final message = await store.recallAsMessage(
        MemoryQuery(text: 'British English'),
      );

      expect(message!.role, MessageRole.system);
      expect(message.text, contains('Ada prefers British English.'));
      expect(message.text, contains('may be out of date'));
    });
  });

  group('tokenise', () {
    test('keeps digits, which is what identifiers are made of', () {
      expect(tokeniseForScoring('PROJ-4417 and v3.11'), contains('4417'));
      expect(tokeniseForScoring('PROJ-4417 and v3.11'), contains('11'));
    });

    test('drops only a short stop-word list', () {
      // Aggressive removal destroys short queries, and memory queries are short.
      expect(tokeniseForScoring('who is on call'), <String>['who', 'call']);
    });
  });

  group('EmbeddedMemoryStore', () {
    test('embeds on write and ranks by similarity', () async {
      final embeddings = FakeEmbeddingModel();
      final store = EmbeddedMemoryStore(
        InMemoryMemoryStore(),
        embeddings: embeddings,
        minSimilarity: 0,
      );

      await store.write(entryOf('the deployment blocker is the auth service'));
      await store.write(entryOf('lunch is at noon'));

      final hits = await store.recall('deployment blocker');

      expect(hits, isNotEmpty);
      expect(hits.first.explanation, contains('similarity'));
      expect(embeddings.embedded, isNotEmpty);
    });

    test('batches an ingestion run into one embedding call', () async {
      final embeddings = _CountingEmbeddingModel();
      final store = EmbeddedMemoryStore(
        InMemoryMemoryStore(),
        embeddings: embeddings,
      );

      await store.writeAll(<MemoryEntry>[
        for (var i = 0; i < 5; i++) entryOf('fact $i', id: 'e$i'),
      ]);

      expect(
        embeddings.calls,
        1,
        reason: 'one request rather than five is the whole point of a batch',
      );
    });

    test('a similarity floor stops confident irrelevance', () async {
      final store = EmbeddedMemoryStore(
        InMemoryMemoryStore(),
        embeddings: FakeEmbeddingModel(),
        // Nothing can match: vector search always returns its nearest
        // neighbours however far away they are.
        minSimilarity: 1.1,
      );

      await store.write(entryOf('anything at all'));

      expect(await store.recall('unrelated question'), isEmpty);
    });

    test('backfills entries written without vectors', () async {
      final inner = InMemoryMemoryStore();
      await inner.writeAll(<MemoryEntry>[
        entryOf('a', id: 'a'),
        entryOf('b', id: 'b'),
      ]);

      final store = EmbeddedMemoryStore(
        inner,
        embeddings: FakeEmbeddingModel(),
        embedOnWrite: false,
      );

      expect(await store.backfill(), 2);
      expect((await inner.read('a'))!.hasEmbedding, isTrue);
    });
  });

  group('HybridMemoryStore', () {
    test('fuses both rankings and says where a hit came from', () async {
      final inner = InMemoryMemoryStore();
      final semantic = EmbeddedMemoryStore(
        inner,
        embeddings: FakeEmbeddingModel(),
        minSimilarity: 0,
      );
      final hybrid = HybridMemoryStore(keyword: inner, semantic: semantic);

      await hybrid.writeAll(<MemoryEntry>[
        entryOf('Ticket PROJ-4417 tracks the login regression.', id: 'a'),
        entryOf('The release is blocked by an authentication bug.', id: 'b'),
      ]);

      final hits = await hybrid.recall('PROJ-4417');

      expect(hits, isNotEmpty);
      expect(hits.first.entry.id, 'a');
      expect(hits.first.explanation, contains('keyword'));
    });

    test('ranks an entry found by both above one found by one', () async {
      final inner = InMemoryMemoryStore();
      final semantic = EmbeddedMemoryStore(
        inner,
        embeddings: FakeEmbeddingModel(),
        minSimilarity: 0,
      );
      final hybrid = HybridMemoryStore(keyword: inner, semantic: semantic);

      await hybrid.writeAll(<MemoryEntry>[
        entryOf('kubernetes migration status', id: 'both'),
        entryOf('unrelated note about lunch', id: 'one'),
      ]);

      final hits = await hybrid.recall('kubernetes migration');

      expect(hits.first.entry.id, 'both');
    });
  });

  group('SummarisingHistory', () {
    List<Message> longConversation(int turns) => <Message>[
      Message.system('Be brief.'),
      for (var i = 0; i < turns; i++) ...<Message>[
        Message.user('question $i'),
        Message.assistant('answer $i'),
      ],
    ];

    test('sends everything verbatim below the threshold', () async {
      final model = FakeChatModel.text('a summary');
      final strategy = SummarisingHistory(model: model, summariseAfter: 20);

      final selected = await strategy.select(longConversation(4));

      expect(selected, hasLength(9));
      expect(model.callCount, 0, reason: 'summarising 8 turns saves nothing');
    });

    test('summarises the older part and keeps the recent turns', () async {
      final model = FakeChatModel.text('Earlier they discussed deployments.');
      final strategy = SummarisingHistory(
        model: model,
        keepRecent: 4,
        summariseAfter: 10,
      );

      final selected = await strategy.select(longConversation(10));

      expect(model.callCount, 1);
      expect(selected.first.text, 'Be brief.');
      expect(selected[1].text, contains('Earlier they discussed deployments.'));
      expect(selected.last.text, 'answer 9');
      expect(selected, hasLength(6));
    });

    test(
      'caches, so a steady conversation does not summarise every turn',
      () async {
        // The naive implementation adds a model call to every single message,
        // often costing more than the tokens it saves.
        final model = FakeChatModel.text('summary');
        final strategy = SummarisingHistory(
          model: model,
          keepRecent: 4,
          summariseAfter: 10,
        );
        final history = longConversation(10);

        await strategy.select(history);
        await strategy.select(history);
        await strategy.select(history);

        expect(model.callCount, 1);
      },
    );

    test('recomputes when the boundary moves', () async {
      final model = FakeChatModel.text('summary');
      final strategy = SummarisingHistory(
        model: model,
        keepRecent: 4,
        summariseAfter: 10,
      );

      await strategy.select(longConversation(10));
      await strategy.select(longConversation(14));

      expect(model.callCount, 2);
    });

    test('persists each summary when a store is supplied', () async {
      final store = InMemoryMemoryStore();
      final strategy = SummarisingHistory(
        model: FakeChatModel.text('They agreed to ship on Friday.'),
        keepRecent: 4,
        summariseAfter: 10,
        store: store,
        sessionId: 's1',
      );

      await strategy.select(longConversation(10));

      final hits = await store.search(
        MemoryQuery(kinds: {MemoryKind.summary}, limit: 5),
      );
      expect(hits.single.entry.content, contains('ship on Friday'));
      expect(hits.single.entry.sessionId, 's1');
    });
  });

  group('RecallingHistory', () {
    test('injects relevant memories after the system prompt', () async {
      final store = InMemoryMemoryStore();
      await store.remember(
        'Ada prefers answers in British English.',
        kind: MemoryKind.preference,
      );

      final strategy = RecallingHistory(store: store, minScore: 0);
      final selected = await strategy.select(<Message>[
        Message.system('Be brief.'),
        Message.user('Write in British English please, what is a lorry?'),
      ]);

      expect(selected.first.text, 'Be brief.');
      expect(selected[1].text, contains('Ada prefers answers'));
      expect(selected.last.role, MessageRole.user);
    });

    test(
      'recalls against the turn about to be sent, not the previous one',
      () async {
        // The gap this closes: on the first turn the transcript is empty, so a
        // strategy that can only see history recalls nothing at all — exactly
        // when recall matters most.
        final store = InMemoryMemoryStore();
        await store.remember('Ada prefers answers in British English.');

        final strategy = RecallingHistory(store: store, minScore: 0);
        final selected = await strategy.select(
          const <Message>[],
          pending: Message.user('Write in British English, what is a lorry?'),
        );

        expect(selected, hasLength(1));
        expect(selected.single.text, contains('Ada prefers answers'));
      },
    );

    test('injects nothing when nothing is relevant', () async {
      final store = InMemoryMemoryStore();
      await store.remember('Ada prefers British English.');

      final strategy = RecallingHistory(store: store);
      final selected = await strategy.select(<Message>[
        Message.user('What is the airspeed of a swallow?'),
      ]);

      expect(selected, hasLength(1));
    });

    test('publishes what it recalled so an answer is traceable', () async {
      final bus = BroadcastEventBus();
      final store = InMemoryMemoryStore();
      await store.remember('Ada prefers British English.');

      final strategy = RecallingHistory(store: store, minScore: 0);
      await strategy.select(
        <Message>[Message.user('British English please')],
        context: AgenticContext.root(
          events: bus,
          ids: SequentialIdGenerator(prefix: 'e'),
        ),
      );

      final event = bus.replayBuffer.whereType<MemoriesRecalled>().single;
      expect(event.count, 1);
      expect(event.contents.single, contains('British English'));
      await bus.dispose();
    });

    test('composes on top of another strategy', () async {
      final store = InMemoryMemoryStore();
      await store.remember('Ada prefers British English.');

      final strategy = RecallingHistory(
        store: store,
        inner: const SlidingWindowHistory(maxMessages: 2),
        minScore: 0,
      );

      final selected = await strategy.select(<Message>[
        Message.system('Be brief.'),
        for (var i = 0; i < 6; i++) Message.user('turn $i'),
        Message.user('British English please'),
      ]);

      // System prompt, recalled memories, then the windowed tail.
      expect(selected.first.role, MessageRole.system);
      expect(selected[1].text, contains('Ada prefers'));
      expect(selected.length, lessThan(9));
    });
  });

  group('memory tools', () {
    late InMemoryMemoryStore store;
    late ToolExecutor executor;

    setUp(() {
      store = InMemoryMemoryStore();
      executor = ToolExecutor(
        tools: (ToolRegistry()..registerAll(memoryTools(store))).all,
      );
    });

    Future<ToolResult> call(String name, Map<String, Object?> arguments) =>
        executor.execute(
          ToolCallPart(id: 'c1', name: name, arguments: arguments),
          context: AgenticContext.root(),
        );

    test('remember writes an entry the model described', () async {
      final result = await call('remember', <String, Object?>{
        'content': 'Ada prefers concise answers.',
        'kind': 'preference',
        'importance': 0.9,
      });

      expect(result.isError, isFalse);
      expect(await store.count(), 1);
      final stored = (await store.recall('concise')).single.entry;
      expect(stored.kind, MemoryKind.preference);
      expect(stored.importance, 0.9);
    });

    test('remember reports an out-of-range importance for repair', () async {
      // The same treatment every malformed argument gets: the model is told
      // what is wrong and fixes it on the next turn.
      final result = await call('remember', <String, Object?>{
        'content': 'Very important thing.',
        'importance': 1.5,
      });

      expect(result.isError, isTrue);
      expect(result.metadata['failureKind'], 'invalidArguments');
      expect(result.content, contains('importance'));
      expect(await store.count(), 0);
    });

    test('remember is not read-only, so writes cannot interleave', () {
      expect(rememberTool(store).spec.isReadOnly, isFalse);
    });

    test('recall reports an absence as knowledge, not as a failure', () async {
      final result = await call('recall', <String, Object?>{
        'query': 'anything at all',
      });

      expect(
        result.isError,
        isFalse,
        reason:
            'a failure would make the model retry a question with no answer',
      );
      expect(result.content, contains('Nothing relevant'));
    });

    test('recall returns what was stored', () async {
      await store.remember('Ada prefers concise answers.');

      final result = await call('recall', <String, Object?>{
        'query': 'concise answers',
      });

      expect(result.content, contains('Ada prefers concise answers.'));
      expect(result.metadata['hits'], 1);
    });

    test('forget requires approval and is excluded by default', () async {
      expect(
        memoryTools(store).map((t) => t.spec.name),
        isNot(contains('forget')),
      );
      expect(forgetTool(store).spec.requiresApproval, isTrue);
    });

    test('forget reports a missing identifier usefully', () async {
      final gated = ToolExecutor(
        tools: (ToolRegistry()..register(forgetTool(store))).all,
        approvalHandler: (_) async => true,
      );

      final result = await gated.execute(
        ToolCallPart(
          id: 'c1',
          name: 'forget',
          arguments: const <String, Object?>{'memoryId': 'nope'},
        ),
        context: AgenticContext.root(),
      );

      expect(result.isError, isTrue);
      expect(result.content, contains('Use `recall`'));
    });
  });

  group('RememberingAgent', () {
    ChatModel extractorReturning(String json) => FakeChatModel(
      turns: <FakeTurn>[
        FakeTurn.answer(
          ChatResponse(message: Message.assistant(json), modelId: 'extractor'),
        ),
      ],
    );

    test('extracts and stores memories after a run', () async {
      final store = InMemoryMemoryStore();
      final agent = RememberingAgent(
        ToolCallingAgent(
          info: AgentInfo(name: 'assistant', description: 'Answers questions.'),
          model: FakeChatModel.text('British English it is.'),
        ),
        store: store,
        extractionModel: extractorReturning(
          '{"memories":[{"content":"Ada prefers British English.",'
          '"kind":"preference","importance":0.9}]}',
        ),
      );

      final result = await agent.run(
        AgentInput.text('Always answer in British English.'),
      );

      expect(result.text, 'British English it is.');
      expect(await store.count(), 1);
      final stored = (await store.recall('British English')).single.entry;
      expect(stored.kind, MemoryKind.preference);
      expect(stored.tags, contains('extracted'));
      expect(stored.agentName, 'assistant');
    });

    test('discards extractions below the importance floor', () async {
      final store = InMemoryMemoryStore();
      final agent = RememberingAgent(
        ToolCallingAgent(
          info: AgentInfo(name: 'assistant', description: 'Answers.'),
          model: FakeChatModel.text('ok'),
        ),
        store: store,
        extractionModel: extractorReturning(
          '{"memories":[{"content":"They said hello.","importance":0.1}]}',
        ),
        minimumImportance: 0.5,
      );

      await agent.run(AgentInput.text('hello'));

      expect(await store.count(), 0);
    });

    test('keeps the most important when the model over-extracts', () async {
      // A slightly over-eager model should lose the excess, not all of it.
      final store = InMemoryMemoryStore();
      final agent = RememberingAgent(
        ToolCallingAgent(
          info: AgentInfo(name: 'assistant', description: 'Answers.'),
          model: FakeChatModel.text('ok'),
        ),
        store: store,
        extractionModel: extractorReturning(
          '{"memories":['
          '{"content":"minor detail","importance":0.4},'
          '{"content":"the critical fact","importance":0.95},'
          '{"content":"another trifle","importance":0.35},'
          '{"content":"the second fact","importance":0.8}]}',
        ),
        maxMemoriesPerRun: 2,
      );

      await agent.run(AgentInput.text('tell me things'));

      expect(await store.count(), 2);
      final kept = await store.search(MemoryQuery(limit: 5));
      expect(
        kept.map((hit) => hit.entry.content),
        containsAll(<String>['the critical fact', 'the second fact']),
      );
    });

    test('does not extract from a run that failed', () async {
      final store = InMemoryMemoryStore();
      final agent = RememberingAgent(
        ToolCallingAgent(
          info: AgentInfo(name: 'assistant', description: 'Answers.'),
          model: FakeChatModel.failing(
            ProviderException('down', provider: 'test', statusCode: 500),
          ),
        ),
        store: store,
        extractionModel: extractorReturning('{"memories":[]}'),
      );

      await agent.run(AgentInput.text('hi'));

      expect(await store.count(), 0);
    });

    test('a failed extraction never breaks a good answer', () async {
      final bus = BroadcastEventBus();
      final store = InMemoryMemoryStore();
      final agent = RememberingAgent(
        ToolCallingAgent(
          info: AgentInfo(name: 'assistant', description: 'Answers.'),
          model: FakeChatModel.text('A perfectly good answer.'),
        ),
        store: store,
        extractionModel: FakeChatModel.failing(
          ProviderException(
            'extractor down',
            provider: 'test',
            statusCode: 500,
          ),
        ),
      );

      final result = await agent.run(
        AgentInput.text('hi'),
        context: AgenticContext.root(
          events: bus,
          ids: SequentialIdGenerator(prefix: 'e'),
        ),
      );

      expect(result.text, 'A perfectly good answer.');
      expect(result.isSuccess, isTrue);
      expect(
        bus.replayBuffer.whereType<MemoryExtractionFailed>(),
        hasLength(1),
      );
      await bus.dispose();
    });

    test('publishes what it extracted', () async {
      final bus = BroadcastEventBus();
      final agent = RememberingAgent(
        ToolCallingAgent(
          info: AgentInfo(name: 'assistant', description: 'Answers.'),
          model: FakeChatModel.text('ok'),
        ),
        store: InMemoryMemoryStore(),
        extractionModel: extractorReturning(
          '{"memories":[{"content":"A durable fact.","importance":0.8}]}',
        ),
      );

      await agent.run(
        AgentInput.text('hi'),
        context: AgenticContext.root(
          events: bus,
          ids: SequentialIdGenerator(prefix: 'e'),
        ),
      );

      expect(bus.replayBuffer.whereType<MemoriesExtracted>().single.count, 1);
      await bus.dispose();
    });

    test('extracts after streaming too', () async {
      final store = InMemoryMemoryStore();
      final agent = RememberingAgent(
        ToolCallingAgent(
          info: AgentInfo(name: 'assistant', description: 'Answers.'),
          model: FakeChatModel.text('ok'),
        ),
        store: store,
        extractionModel: extractorReturning(
          '{"memories":[{"content":"A durable fact.","importance":0.8}]}',
        ),
      );

      await agent.stream(AgentInput.text('hi')).toList();

      expect(await store.count(), 1);
    });
  });

  group('NoopMemoryStore', () {
    test('accepts writes and remembers nothing', () async {
      const store = NoopMemoryStore();

      await store.remember('anything');

      expect(await store.count(), 0);
      expect(await store.recall('anything'), isEmpty);
    });
  });
}

/// Counts how many embedding requests were made.
final class _CountingEmbeddingModel implements EmbeddingModel {
  int calls = 0;

  final FakeEmbeddingModel _inner = FakeEmbeddingModel();

  @override
  ModelInfo get info => _inner.info;

  @override
  int get dimensions => _inner.dimensions;

  @override
  int get maxBatchSize => _inner.maxBatchSize;

  @override
  Future<List<Embedding>> embed(
    List<String> inputs, {
    required EmbeddingPurpose purpose,
    AgenticContext? context,
  }) {
    calls++;
    return _inner.embed(inputs, purpose: purpose, context: context);
  }

  @override
  Future<void> dispose() => _inner.dispose();
}
