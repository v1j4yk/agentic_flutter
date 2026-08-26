/// Measuring how long things take, honestly.
///
/// # Why not `package:benchmark_harness`
///
/// It reports a single mean over a fixed two-second window, and its base class
/// is synchronous. Almost everything in this framework is asynchronous, and a
/// mean hides exactly what matters: a p99 that is thirty times the median is a
/// stutter a user sees, and a mean that swallowed it says nothing went wrong.
///
/// So this harness reports percentiles, and it reports how many samples they
/// came from, because a p99 over twenty samples is not a p99.
///
/// # Real time is the point here
///
/// Every other part of the framework injects a `Clock` so that tests never wait.
/// Benchmarks are the one place that would be wrong: the number being measured
/// *is* elapsed wall time. This file is the only one in the repository that
/// reaches for a real `Stopwatch` deliberately.
library;

import 'dart:async';

import 'package:agentic_core/agentic_core.dart';
import 'package:meta/meta.dart';

/// One thing worth timing.
///
/// ```dart
/// Benchmark(
///   name: 'core.schema.validate',
///   description: 'Validating a nested object against a closed schema.',
///   setup: () async => buildFixture(),
///   run: (fixture) async => schema.validate(fixture),
/// );
/// ```
final class Benchmark<T> {
  /// Creates a benchmark.
  ///
  /// [setup] runs once, outside the measurement, and its result is handed to
  /// every iteration. Anything expensive that is not the thing under test —
  /// building a corpus, filling an index — belongs there, or the number
  /// measures the fixture instead of the code.
  Benchmark({
    required this.name,
    required this.description,
    required this.run,
    this.setup,
    this.teardown,
    this.iterations = 200,
    this.warmup = 20,
    this.unit = 'op',
  }) : assert(iterations > 0, 'iterations must be positive'),
       assert(warmup >= 0, 'warmup cannot be negative');

  /// A dotted identifier, such as `vector.search.10k`.
  ///
  /// Stable across runs: it is the key a baseline is matched on, so renaming
  /// one silently drops its history.
  final String name;

  /// What is being measured, and why it is worth measuring.
  final String description;

  /// Builds the fixture, once.
  final FutureOr<T> Function()? setup;

  /// The code under test.
  final FutureOr<void> Function(T fixture) run;

  /// Releases the fixture.
  final FutureOr<void> Function(T fixture)? teardown;

  /// How many measured iterations to take.
  final int iterations;

  /// How many unmeasured iterations to run first.
  ///
  /// Not optional in practice. The first calls into fresh code pay for JIT
  /// compilation and cold caches, and including them makes a fast operation
  /// look ten times slower than it is.
  final int warmup;

  /// What one iteration processes, for a per-unit figure.
  final String unit;

  /// Runs the benchmark and returns its measurements.
  Future<BenchmarkResult> measure() async {
    final fixture = await _makeFixture();
    try {
      for (var i = 0; i < warmup; i++) {
        await run(fixture);
      }

      final samples = List<int>.filled(iterations, 0);
      final stopwatch = Stopwatch();
      for (var i = 0; i < iterations; i++) {
        stopwatch
          ..reset()
          ..start();
        await run(fixture);
        stopwatch.stop();
        samples[i] = stopwatch.elapsedMicroseconds;
      }
      return BenchmarkResult.fromSamples(
        name: name,
        description: description,
        samples: samples,
      );
    } finally {
      final release = teardown;
      if (release != null) await release(fixture);
    }
  }

  Future<T> _makeFixture() async {
    final build = setup;
    if (build != null) return build();
    // A benchmark with no fixture is typed `Benchmark<void>`; `null as T` is
    // the only value that inhabits it.
    return null as T;
  }

  @override
  String toString() => 'Benchmark($name)';
}

/// What a benchmark measured.
///
/// Percentiles only. Keeping every sample would make a baseline file nobody
/// reviews, and a result restored from one would then be a different shape from
/// a result just measured — which is exactly the kind of asymmetry that makes
/// comparison code subtly wrong.
@immutable
final class BenchmarkResult {
  const BenchmarkResult({
    required this.name,
    required this.description,
    required this.count,
    required this.minUs,
    required this.medianUs,
    required this.p90Us,
    required this.p99Us,
    required this.maxUs,
  });

  /// Summarises [samples], in microseconds.
  factory BenchmarkResult.fromSamples({
    required String name,
    required String description,
    required List<int> samples,
  }) {
    if (samples.isEmpty) {
      throw ValidationException(
        'A benchmark result needs at least one sample.',
        violations: const <String>['samples: empty'],
      );
    }
    final sorted = List<int>.of(samples)..sort();
    return BenchmarkResult(
      name: name,
      description: description,
      count: sorted.length,
      minUs: sorted.first,
      medianUs: percentileOf(sorted, 50),
      p90Us: percentileOf(sorted, 90),
      p99Us: percentileOf(sorted, 99),
      maxUs: sorted.last,
    );
  }

  /// Restores a result from a baseline file.
  factory BenchmarkResult.fromJson(JsonMap json) => BenchmarkResult(
    name: json.requireString('name'),
    description: json.stringOr('description', ''),
    count: json.requireInt('count'),
    minUs: json.requireInt('minUs'),
    medianUs: json.requireInt('medianUs'),
    p90Us: json.requireInt('p90Us'),
    p99Us: json.requireInt('p99Us'),
    maxUs: json.requireInt('maxUs'),
  );

  /// Which benchmark this is.
  final String name;

  /// What it measures.
  final String description;

  /// How many samples the percentiles came from.
  ///
  /// Reported rather than assumed: a p99 over twenty samples is not a p99, and
  /// a reader comparing two runs needs to know which one to trust.
  final int count;

  /// The fastest iteration.
  ///
  /// The closest thing to "how long this takes with nothing in the way", and
  /// the most stable figure on a noisy machine — which also makes it the least
  /// representative of what a user experiences.
  final int minUs;

  /// The middle iteration. The headline number.
  final int medianUs;

  /// The 90th percentile.
  final int p90Us;

  /// The 99th percentile.
  ///
  /// What a user notices. A p99 far above the median means something
  /// occasional and expensive — a growing buffer, a collection, a cache that
  /// missed — and an average hides it completely.
  final int p99Us;

  /// The slowest iteration.
  final int maxUs;

  /// Iterations per second, from the median.
  double get opsPerSecond =>
      medianUs == 0 ? double.infinity : 1000000 / medianUs;

  /// The median in milliseconds.
  double get medianMs => medianUs / 1000;

  /// How much slower the tail is than the middle.
  ///
  /// Above about three, something occasional is costing real time and is worth
  /// finding.
  double get tailRatio => medianUs == 0 ? 1 : p99Us / medianUs;

  /// Serialises the result.
  JsonMap toJson() => <String, Object?>{
    'name': name,
    'description': description,
    'count': count,
    'minUs': minUs,
    'medianUs': medianUs,
    'p90Us': p90Us,
    'p99Us': p99Us,
    'maxUs': maxUs,
  };

  /// The [percentile]th value of [sorted], by nearest rank.
  ///
  /// Nearest rank rather than interpolation: it can only ever report a duration
  /// that was actually measured, which matters when a reader takes the number
  /// to a profiler looking for it.
  static int percentileOf(List<int> sorted, int percentile) {
    if (sorted.isEmpty) return 0;
    final rank = ((percentile / 100) * sorted.length).ceil().clamp(
      1,
      sorted.length,
    );
    return sorted[rank - 1];
  }

  @override
  String toString() =>
      'BenchmarkResult($name, median ${medianUs}us, p99 ${p99Us}us)';
}

/// A named group of benchmarks.
@immutable
final class BenchmarkSuite {
  /// Creates a suite.
  BenchmarkSuite({
    required this.name,
    required List<Benchmark<Object?>> benchmarks,
  }) : benchmarks = List<Benchmark<Object?>>.unmodifiable(benchmarks);

  /// The layer being measured, such as `vector`.
  final String name;

  /// What it contains.
  final List<Benchmark<Object?>> benchmarks;

  @override
  String toString() => 'BenchmarkSuite($name, ${benchmarks.length})';
}

/// Runs suites and reports progress as it goes.
final class BenchmarkRunner {
  /// Creates a runner.
  const BenchmarkRunner({this.onProgress});

  /// Called before each benchmark, so a long run is not silent.
  final void Function(String name)? onProgress;

  /// Runs every benchmark in [suites] whose name matches [filter].
  ///
  /// [filter] is a substring match against the full name, which is enough to
  /// select a layer (`vector`) or one benchmark (`vector.search.10k`) without
  /// inventing a query language.
  Future<List<BenchmarkResult>> run(
    List<BenchmarkSuite> suites, {
    String? filter,
  }) async {
    final results = <BenchmarkResult>[];
    for (final suite in suites) {
      for (final benchmark in suite.benchmarks) {
        if (filter != null && !benchmark.name.contains(filter)) continue;
        onProgress?.call(benchmark.name);
        results.add(await benchmark.measure());
      }
    }
    return results;
  }
}
