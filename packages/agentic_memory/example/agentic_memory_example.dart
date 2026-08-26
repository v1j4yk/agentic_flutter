// Demonstrates the memory layer: storing facts, keyword and semantic recall,
// memory-backed history, tools an agent uses on itself, and automatic
// extraction.
//
// Run it with:
//
//     dart run example/agentic_memory_example.dart
//
// It runs offline against scripted models.
import 'package:agentic_agents/agentic_agents.dart';
import 'package:agentic_core/agentic_core.dart';
import 'package:agentic_llm/testing.dart';
import 'package:agentic_memory/agentic_memory.dart';
import 'package:agentic_tools/agentic_tools.dart';

Future<void> main() async {
  // ---------------------------------------------------------------------------
  // 1. Store some things worth remembering.
  // ---------------------------------------------------------------------------
  print('--- storing ---');
  final store = InMemoryMemoryStore();

  await store.remember(
    'Ada wants answers written in British English.',
    kind: MemoryKind.preference,
    importance: 0.9,
  );
  await store.remember(
    'The billing service is written in Dart 3.11.',
    importance: 0.7,
    tags: {'billing'},
  );
  await store.remember(
    'Ticket PROJ-4417 tracks the login regression.',
    importance: 0.6,
    tags: {'billing'},
  );
  await store.remember(
    'The team stood down the Friday deploy freeze.',
    kind: MemoryKind.event,
    importance: 0.4,
    ttl: const Duration(days: 30),
  );

  print('stored     : ${await store.count()} memories');

  // ---------------------------------------------------------------------------
  // 2. Recall. Keyword retrieval is the default because it is the better tool
  //    for identifiers, names and version numbers.
  // ---------------------------------------------------------------------------
  print('\n--- recall ---');
  for (final query in <String>[
    'PROJ-4417',
    'what language is billing written in',
    'the airspeed of a swallow',
  ]) {
    final hits = await store.recall(query, limit: 2);
    print('"$query"');
    if (hits.isEmpty) {
      print('  (nothing relevant — which is the correct answer)');
    }
    for (final hit in hits) {
      print('  ${hit.score.toStringAsFixed(2)}  ${hit.entry.content}');
      print('        ${hit.explanation}');
    }
  }

  // ---------------------------------------------------------------------------
  // 3. Hybrid retrieval: keyword and semantic, rankings fused.
  // ---------------------------------------------------------------------------
  print('\n--- hybrid ---');
  final semantic = EmbeddedMemoryStore(
    store,
    embeddings: FakeEmbeddingModel(),
    minSimilarity: 0,
  );
  final hybrid = HybridMemoryStore(keyword: store, semantic: semantic);

  // Backfill vectors for the entries written before the semantic wrapper.
  print('embedded   : ${await semantic.backfill()} entries');
  for (final hit in await hybrid.recall('login bug ticket', limit: 2)) {
    print('  ${hit.score.toStringAsFixed(2)}  ${hit.entry.content}');
    print('        ${hit.explanation}');
  }

  // ---------------------------------------------------------------------------
  // 4. Memory-backed history: what the model sees is chosen per turn.
  // ---------------------------------------------------------------------------
  print('\n--- recalling history ---');
  final events = BroadcastEventBus();
  events.on<MemoryEvent>().listen((event) {
    final detail = switch (event) {
      MemoriesRecalled(:final count, :final query) =>
        'recalled $count for "$query"',
      MemoriesExtracted(:final count) => 'extracted $count',
      MemoryExtractionFailed(:final reason) => 'extraction failed: $reason',
      _ => null,
    };
    if (detail != null) print('  [${event.type}] $detail');
  });
  final context = AgenticContext.root(events: events, runId: 'example');

  final assistantModel = FakeChatModel.text('A lorry is a truck.');
  final session = AgentSession(
    strategy: RecallingHistory(
      store: store,
      inner: const SlidingWindowHistory(maxMessages: 20),
      minScore: 0.1,
    ),
  );
  final assistant = ToolCallingAgent(
    info: AgentInfo(name: 'assistant', description: 'A personal assistant.'),
    model: assistantModel,
  );

  await assistant.run(
    AgentInput.text('What is a lorry? Answer in British English.'),
    session: session,
    context: context,
  );

  // The recalled preference was injected before the conversation.
  final sent = assistantModel.lastRequest.messages;
  print('sent       : ${sent.length} messages');
  for (final message in sent.where((m) => m.role == MessageRole.system)) {
    print('  system: ${message.text.split('\n').first}');
  }

  // ---------------------------------------------------------------------------
  // 5. Tools the agent uses on itself.
  // ---------------------------------------------------------------------------
  print('\n--- memory tools ---');
  final registry = ToolRegistry()..registerAll(memoryTools(store));
  final toolUser = ToolCallingAgent(
    info: AgentInfo(name: 'librarian', description: 'Manages memory.'),
    model: FakeChatModel.toolCall(
      toolCalls: <ToolCallPart>[
        ToolCallPart(
          id: 'c1',
          name: 'remember',
          arguments: <String, Object?>{
            'content': 'Ada is migrating the billing service to Kubernetes.',
            'kind': 'fact',
            'importance': 0.8,
          },
        ),
      ],
      then: 'Noted.',
    ),
    tools: registry.all,
    instructions:
        'When the user states something durable about their work, call '
        '`remember`.',
  );

  final noted = await toolUser.run(
    AgentInput.text('We are migrating billing to Kubernetes.'),
    context: context,
  );
  print('answer     : ${noted.text}');
  print('stored     : ${await store.count()} memories');
  for (final hit in await store.recall('kubernetes')) {
    print('  ${hit.entry.content}');
  }

  // ---------------------------------------------------------------------------
  // 6. Automatic extraction: memory without the model having to ask.
  // ---------------------------------------------------------------------------
  print('\n--- automatic extraction ---');
  final remembering = RememberingAgent(
    ToolCallingAgent(
      info: AgentInfo(name: 'chat', description: 'A chat assistant.'),
      model: FakeChatModel.text('Understood — I will keep replies short.'),
    ),
    store: store,
    extractionModel: FakeChatModel.text(
      '{"memories":[{"content":"Ada prefers short replies.",'
      '"kind":"preference","importance":0.85}]}',
    ),
  );

  final chatted = await remembering.run(
    AgentInput.text('Please keep your replies short from now on.'),
    context: context,
  );
  print('answer     : ${chatted.text}');
  print('stored     : ${await store.count()} memories');

  // ---------------------------------------------------------------------------
  // 7. Forgetting is a feature, not a failure.
  // ---------------------------------------------------------------------------
  print('\n--- forgetting ---');
  print('pruned     : ${await store.prune()} expired');
  print('final      : ${await store.count()} memories');

  await events.dispose();
  await hybrid.dispose();
  await registry.dispose();
}
