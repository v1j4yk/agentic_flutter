# Changelog

## 0.2.0

- Released with the rest of the framework at 0.2.0, which it now
  depends on. No changes to this package's API or behaviour.

## 0.1.2

Initial release. The version follows the sibling packages it ships with.

- `sessionStore()` and `snapshotStore()`: durable `SessionStore` and
  `WorkflowSnapshotStore`, added in schema 2. Files from schema 1 upgrade in
  place.
- `SqliteVectorStore.records()`, for rebuilding a keyword index at startup.

Initial release of on-device persistence.

- `AgenticDatabase`: one SQLite file holding many named stores, with schema
  migrations and refusal of files written by a newer schema.
- `SqliteVectorStore`: a durable `VectorStore`. Rows on disk, search over the
  framework's in-memory index, writes committed before they reach memory.
- `SqliteMemoryStore`: a durable `MemoryStore` that persists merges and
  evictions by reconciling, and rolls memory back if a write fails.
