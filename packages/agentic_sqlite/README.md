# agentic_sqlite

On-device persistence for the [agentic framework](https://github.com/v1j4yk/agentic_flutter).
SQLite-backed vector and memory stores that survive the app being closed.

Every other store in the framework is in memory. That is right for tests and
wrong for an app: a user indexes their notes, the OS reclaims the process, and
the next launch starts empty. This package is the fix.

```yaml
dependencies:
  agentic_sqlite: ^0.1.1
```

```dart
import 'package:agentic_sqlite/agentic_sqlite.dart';
import 'package:path_provider/path_provider.dart';

final support = await getApplicationSupportDirectory();
final db = await AgenticDatabase.open('${support.path}/agentic.db');

final notes = await db.vectorStore(name: 'notes', dimensions: 768);
final memory = await db.memoryStore(name: 'assistant');
```

Both implement the framework's ports — `VectorStore` and `MemoryStore` — so
they replace the in-memory stores with no other change. An `EmbeddingIndex`, a
`RagIndexer`, a `RememberingAgent`: everything built on them now keeps its data.

Use `getApplicationSupportDirectory()`, not the documents directory, which iOS
shows to the user and backs up to iCloud.

## How it works

**SQLite holds the data; memory holds the index.** Rows are stored in one file.
When a store opens, they are loaded into the framework's in-memory store, and
search runs there — the same tested ranking code, not a second implementation
that could disagree with it.

**Writes go to disk first.** Every change is committed in a transaction before
it reaches memory. If the write fails, the call throws and memory is untouched,
so the app never searches data it will lose on restart.

**Memory is reconciled, not mirrored.** The memory store merges duplicates and
evicts entries when full. Copying each call to disk would keep the evicted and
merged-away entries, and they would come back on the next launch. Instead, the
difference between the store's contents before and after each change is what
gets written. If that write fails, memory is rolled back.

## Trade-offs, stated

| | |
|---|---|
| **Memory** | Every record in an open collection is held in memory. 10,000 × 768-dimensional vectors is about 30 MB |
| **Scale** | Search is exact. Comfortable to a few tens of thousands of chunks |
| **Blocking** | SQLite runs on the calling isolate. A write of a few hundred records is well inside a frame; tens of thousands is not. The API is already `async`, so moving it to a background isolate will not be a breaking change |
| **Precision** | Vectors are stored as 32-bit floats — what embedding models produce — at half the disk of 64-bit |
| **Eviction** | The vector store never evicts. A note a user saved should not disappear because they saved others; bound it yourself with `deleteWhere` or `clear` |
| **Web** | Not supported. SQLite on the web needs a WASM build and an async VFS — a different adapter |

## Safety

- A collection can be open **once** per database. Two stores over the same rows
  would each keep their own copy in memory and drift apart on the first write.
- Opening a vector collection with a different **dimension or metric** than it
  was created with throws. Vectors scored with the wrong shape give wrong
  results, not slow ones.
- A **damaged row** is reported as a `StorageException` when the store opens,
  rather than skipped. A store that silently lacks some of what was saved is
  worse than one that refuses to open.
- A file written by a **newer schema** is refused, so an app downgrade cannot
  write into a format this version does not understand.

## Native code

SQLite is bundled by `package:sqlite3` 3.x through a build hook, on the Dart VM
and in Flutter alike. There is no `sqlite3_flutter_libs` to add.
