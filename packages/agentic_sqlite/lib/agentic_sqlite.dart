/// On-device persistence for the agentic framework.
///
/// ```dart
/// final db = await AgenticDatabase.open('${support.path}/agentic.db');
/// final notes = await db.vectorStore(name: 'notes', dimensions: 768);
/// final memory = await db.memoryStore(name: 'assistant');
/// final chats = db.sessionStore();
/// final pending = db.snapshotStore();
/// ```
///
/// Every store implements a framework port — `VectorStore`, `MemoryStore`,
/// `SessionStore`, `WorkflowSnapshotStore` — so they drop in wherever the in-memory ones were, and
/// everything built on them keeps working across a restart.
library;

export 'src/database.dart' show AgenticDatabase, kSqliteStore;
export 'src/sqlite_memory_store.dart' show SqliteMemoryStore;
export 'src/sqlite_session_store.dart' show SqliteSessionStore;
export 'src/sqlite_snapshot_store.dart' show SqliteWorkflowSnapshotStore;
export 'src/sqlite_vector_store.dart' show SqliteVectorStore;
