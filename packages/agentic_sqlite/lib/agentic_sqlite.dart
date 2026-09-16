/// On-device persistence for the agentic framework.
///
/// ```dart
/// final db = await AgenticDatabase.open('${support.path}/agentic.db');
/// final notes = await db.vectorStore(name: 'notes', dimensions: 768);
/// final memory = await db.memoryStore(name: 'assistant');
/// ```
///
/// Both stores implement the framework's ports — `VectorStore` and
/// `MemoryStore` — so they drop in wherever the in-memory ones were, and
/// everything built on them keeps working across a restart.
library;

export 'src/database.dart' show AgenticDatabase, kSqliteStore;
export 'src/sqlite_memory_store.dart' show SqliteMemoryStore;
export 'src/sqlite_vector_store.dart' show SqliteVectorStore;
