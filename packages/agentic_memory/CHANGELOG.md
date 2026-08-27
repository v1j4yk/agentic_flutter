# Changelog

## 0.1.1

- Shortened the package description to the 60-180 character window pana
  scores against. Search engines truncate anything longer, so the ten points
  it withheld were pointing at a real defect: the useful half of the sentence
  was never being shown.

## 0.1.0

Initial release of the memory layer.

### Added

- **Values** — `MemoryEntry`, `MemoryKind`, `MemoryQuery` and `MemoryHit`. One
  entry shape covers working, conversation, long-term, semantic and shared
  memory, which differ in scope and retention rather than in mechanics.
- **Stores** — `MemoryStore` port; `InMemoryMemoryStore` with rarity-weighted
  keyword retrieval blended with importance and recency, deduplication,
  expiry and value-based eviction; `EmbeddedMemoryStore` for semantic retrieval
  with a similarity floor and batched backfill; `HybridMemoryStore` fusing both
  rankings with reciprocal rank fusion.
- **History strategies** — `RecallingHistory` injects memories relevant to the
  turn about to be sent; `SummarisingHistory` condenses older turns and caches,
  so a steady conversation summarises once per window rather than once per turn.
- **Tools** — `remember`, `recall` and an approval-gated `forget`, so an agent
  can manage its own memory.
- **Automatic extraction** — `RememberingAgent` runs a separate extraction pass
  after each successful run, bounded by count and importance, and never lets a
  failed extraction break a good answer.
- **Events** — `MemoriesRecalled` (carrying the statements, so an answer is
  traceable), `MemoriesExtracted`, `MemoryExtractionFailed` and `MemoriesPruned`.
