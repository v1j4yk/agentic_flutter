---
name: agentic-sqlite-persist-everything
description: >-
  Use when agent state must survive an app restart with agentic_sqlite:
  opening an AgenticDatabase, the SQLite-backed vector, memory, session and
  workflow-snapshot stores, schema versions, and testing against an in-memory
  database. Read this for "remember across launches", "resume a workflow after
  the app was killed", or "the index is rebuilt on every start".
license: MIT
metadata:
  package: agentic_sqlite
  min-version: 0.2.0
---

# Persistence on the device

## One database, four stores

```dart
import 'package:agentic_sqlite/agentic_sqlite.dart';

final directory = await getApplicationSupportDirectory();   // path_provider, in your app
final db = await AgenticDatabase.open('${directory.path}/agentic.db');

final vectors   = await db.vectorStore(name: 'handbook', dimensions: 768);
final memories  = await db.memoryStore(name: 'user');
final sessions  = db.sessionStore(name: 'chats');
final snapshots = db.snapshotStore(name: 'workflows');
```

Each implements the same port its in-memory twin does — `VectorStore`,
`MemoryStore`, `SessionStore`, `WorkflowSnapshotStore` — so persistence is a
constructor change and nothing above it moves. `AgenticDatabase.inMemory()` is
the same thing for tests.

Open the database once, at app start, and dispose it when the app is done:
`db.release(key)` drops one store, `db.dispose()` closes the connection.

## What each one buys you

| Store | Without it | With it |
|---|---|---|
| `vectorStore` | the corpus is re-embedded on every launch | index once, search forever |
| `memoryStore` | the assistant forgets the user between launches | it remembers |
| `sessionStore` | conversations vanish when the app is killed | a chat list that resumes |
| `snapshotStore` | a workflow awaiting approval dies with the process | it resumes on relaunch |

The last one is the mobile case a server framework never has to think about:
the OS kills your app while the approver is elsewhere, and the run has to be
there when they come back.

## It runs on the Dart VM too

`sqlite3` 3.x bundles SQLite through a build hook on the VM and in Flutter
alike, so these stores are testable without a device:

```dart
test('memories survive a reopen', () async {
  final db = await AgenticDatabase.inMemory();
  final store = await db.memoryStore(name: 'user');
  await store.write(entry);
  expect(await store.count(), 1);
  await db.dispose();
});
```

`sqlite3_flutter_libs` is not needed, and is end-of-life for exactly this
reason.

## Schema versions

`AgenticDatabase.schemaVersion` is the version this package writes, and opening
an older file migrates it forward. Two consequences:

- **Downgrades are not supported.** A database written by a newer version of
  the package will not open on an older one, so ship carefully.
- **Your own tables are yours.** Use `db.connection` or
  `db.transaction(...)` for them; keep them out of the framework's namespace so
  a future migration does not collide.

## Size, and keeping it honest

Vectors dominate: roughly `records × dimensions × 8 bytes`, plus stored text.
On a phone that is the number to watch.

- Prefer 768 or 256 dimensions over 3072 where the model supports truncation.
- `storeText: false` on the index if you already have the text elsewhere.
- Prune memories (`store.prune()`), delete finished workflow snapshots, and
  drop sessions the user deleted — nothing does it for you.

## What is not here yet

Worth knowing before you design around it: there is no encryption at rest, no
full-text index (keyword search is scored in Dart, not by FTS5), no approximate
vector index, and no web (WASM) support. For anything holding personal data,
that first gap is the one to think about — either keep the sensitive part out of
the database, or wrap the values yourself.

## Common mistakes

- Opening a database per screen instead of once per app.
- Using a path from `getTemporaryDirectory()`, which the OS may clear.
- Forgetting `await db.dispose()` in tests, which leaks connections and makes
  later tests fail confusingly.
- Assuming a vector store created at 768 dimensions can hold a 1536-dimension
  embedding; it refuses, and that refusal is doing you a favour.
- Storing an API key in it. Keys belong in a `SecretStore`.

## See also

- `agentic-vector-choose-store` — the port this implements
- `agentic-agents-sessions-and-history` — what a session store holds
- `agentic-workflow-human-approval-and-resume` — snapshots and resuming
