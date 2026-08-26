# agentic_benchmark

Micro-benchmarks for the agentic framework, with baseline comparison so a
performance regression shows up as a number in a pull request rather than as a
report from production six weeks later.

Never published. It is a measuring instrument for this repository.

```sh
dart run agentic_benchmark                  # everything, ~2 minutes
dart run agentic_benchmark vector           # one layer, or one benchmark
dart run agentic_benchmark --save-baseline  # record the current numbers
dart run agentic_benchmark --baseline       # compare; exit 1 on a regression
dart run agentic_benchmark --json           # machine-readable
```

## What it measures, and why those things

| Suite | The question it answers |
|---|---|
| `core` | What every other layer pays on every call — schema validation, identifiers, event publication, context derivation |
| `tools` | What the executor adds around a tool that returns instantly |
| `llm` | Stream assembly and SSE decoding, which run on the UI isolate while text arrives |
| `agents` | The framework overhead of a whole turn, with the provider taken out |
| `memory` | Keyword recall on the interactive path |
| `vector` | Whether brute-force search is viable at a given index size |
| `rag` | Chunking throughput and lexical query cost |
| `mcp` | The protocol cost of a tool call, separated from the transport |

The rule of thumb the pipeline suites defend: **framework overhead per agent
step should stay under about a millisecond.** At that scale it is a rounding
error against a 400 ms completion; at ten it is a tax on every turn; at a
hundred it is a bug.

## What it found

The suite justified itself on its first run, which is the point of writing one.

**`vector.search.10k` was 45 ms, not the "few milliseconds" the
`agentic_vector` README claimed.** Two things came out of that:

* an implementation fix — vectors are now stored as `Float64List` rather than
  boxed `List<double>`, and `SimilarityMetric` has a typed fast path. Measured:
  1.4 µs per 768-dimensional cosine instead of 2.4 µs, and `vector.search.10k`
  down from 45 ms to **24 ms**. An unmodifiable *view* over typed data was also
  measured, at 4.4 µs — worse than the boxed list, because the forwarding
  defeats the optimiser. That is why the vector is stored as a writable typed
  list and the trade is documented rather than hidden.
* a documentation fix — 24 ms is still not "a few milliseconds", so the claim
  is now the measurement.

**`rag.bm25.search.5k` was 5.9 ms against a claimed "millisecond per query".**
The index scanned every chunk per query; it is now inverted, so a query walks
only the chunks containing its terms. Down to **3.3 ms**, and the README says
3.3 ms.

## Reading the output

```
benchmark                              median        p90        p99       ops/s
-------------------------------------------------------------------------------
vector.search.10k                     24.16ms    28.75ms    33.49ms        41.4
```

Percentiles, not a mean. A mean hides exactly what matters: a p99 thirty times
the median is a stutter a user sees, and an average that swallowed it says
nothing went wrong. Runs ending with a **tail latency** section are pointing at
something occasional and expensive — a growing buffer, a collection, a cache
that missed.

Benchmarks whose median is under 50 µs are excluded from that heuristic. At that
scale a single tick of scheduler noise reads as "4× slower", and a report that
flags every fast benchmark flags nothing at all.

## Baselines

`baseline.json` holds percentiles, not raw samples — a file with a thousand
samples per benchmark is a file nobody reviews. It records the SDK version and
platform, and a comparison across either warns, because comparing a baseline
taken on another machine measures the machine.

**Record a baseline on a quiet machine.** Numbers on a shared CI runner vary by
tens of per cent between identical runs, which is why `--tolerance` defaults to
0.2 and why the CI job reports the table rather than gating on it. `--baseline`
exits non-zero on a regression, which is what makes it useful locally when you
have changed something you expect to matter.

## Adding a benchmark

```dart
Benchmark<MyFixture>(
  name: 'layer.thing.size',            // stable: it is the baseline's key
  description: 'What this measures, and why it is worth measuring.',
  setup: () async => buildFixture(),   // outside the measurement
  run: (fixture) => thingUnderTest(fixture),
  iterations: 500,
  warmup: 50,
);
```

Two rules earned the hard way:

* **Anything that is not the thing under test goes in `setup`.** A fixture built
  inside `run` means the number measures the fixture.
* **Make the fixture realistic, then stop.** A corpus where every chunk contains
  every query term measures the pathological case and labels it typical; a
  corpus tuned until the number looks good is worse than no benchmark. Where the
  worst case matters, measure it under its own name — `rag.bm25.search.5k` and
  `rag.bm25.search.5k.commonTerms` are both there for that reason.

Renaming a benchmark silently drops its history, so the comparison reports it as
`removed` alongside the `added` replacement rather than quietly ignoring it.
