/// Memory for the agentic framework.
///
/// One store port covers conversation, working, long-term, semantic and shared
/// memory, because those differ in scope and retention rather than in
/// mechanics. On top of it sit the two things that make a store useful:
/// history strategies that summarise and recall, and tools that let an agent
/// manage its own memory.
///
/// ```dart
/// import 'package:agentic_memory/agentic_memory.dart';
///
/// final store = InMemoryMemoryStore();
/// await store.remember(
///   'The user wants answers written in British English.',
///   kind: MemoryKind.preference,
///   importance: 0.9,
/// );
///
/// final session = AgentSession(
///   strategy: RecallingHistory(
///     store: store,
///     inner: SlidingWindowHistory(maxMessages: 20),
///   ),
/// );
/// ```
///
/// Retrieval is keyword-first by design. Embeddings are worse than term
/// matching at recalling a specific name, identifier or version number, which
/// is a large share of what memory is asked for — so `InMemoryMemoryStore`
/// needs no model at all, `EmbeddedMemoryStore` adds the semantic half, and
/// `HybridMemoryStore` fuses the two.
library;

// --- Automatic extraction ----------------------------------------------------
export 'src/agent/remembering_agent.dart' show RememberingAgent;
// --- Events ------------------------------------------------------------------
export 'src/events/memory_events.dart'
    show
        MemoriesExtracted,
        MemoriesPruned,
        MemoriesRecalled,
        MemoryEvent,
        MemoryExtractionFailed;
// --- History strategies ------------------------------------------------------
export 'src/history/memory_history.dart'
    show RecallingHistory, SummarisingHistory;
// --- Values ------------------------------------------------------------------
export 'src/model/memory_entry.dart'
    show MemoryEntry, MemoryHit, MemoryKind, MemoryQuery;
// --- Stores ------------------------------------------------------------------
export 'src/store/embedded_store.dart'
    show EmbeddedMemoryStore, HybridMemoryStore;
export 'src/store/in_memory_store.dart'
    show
        InMemoryMemoryStore,
        MemoryScoreWeights,
        memoryStopWords,
        tokeniseForScoring;
export 'src/store/memory_store.dart'
    show MemoryStore, MemoryStoreOperations, NoopMemoryStore;
// --- Tools -------------------------------------------------------------------
export 'src/tools/memory_tools.dart'
    show forgetTool, memoryTools, recallTool, rememberTool;
