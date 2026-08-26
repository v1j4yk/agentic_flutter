/// Turning measurements into something a person can act on.
///
/// # A number on its own says nothing
///
/// "`vector.search.10k` took 4.1 ms" is not information. "It took 4.1 ms and it
/// used to take 1.3 ms" is. So the useful output of a benchmark suite is a
/// *comparison*, and everything here exists to make that comparison honest:
/// a tolerance wide enough that ordinary machine noise does not cry wolf, and
/// narrow enough that a real regression does not hide inside it.
library;

import 'dart:convert';

import 'package:agentic_benchmark/src/harness.dart';
import 'package:agentic_core/agentic_core.dart';
import 'package:meta/meta.dart';

/// How a result compares with a baseline.
enum BenchmarkVerdict {
  /// Within tolerance.
  unchanged,

  /// Faster by more than the tolerance.
  ///
  /// Worth noticing rather than celebrating: an improvement nobody intended is
  /// usually a benchmark that stopped measuring what it used to.
  faster,

  /// Slower by more than the tolerance.
  slower,

  /// Present now, absent from the baseline.
  added,

  /// In the baseline, missing now.
  ///
  /// Usually a rename, which silently discards the history the old name had.
  removed;

  /// Whether this verdict should fail a gated run.
  bool get isRegression => this == slower;
}

/// One benchmark, then and now.
@immutable
final class BenchmarkComparison {
  /// Creates a comparison.
  const BenchmarkComparison({
    required this.name,
    required this.verdict,
    this.current,
    this.baseline,
  });

  /// Which benchmark.
  final String name;

  /// How it compares.
  final BenchmarkVerdict verdict;

  /// What was measured now, or `null` when the benchmark has been removed.
  final BenchmarkResult? current;

  /// What the baseline recorded, or `null` when the benchmark is new.
  final BenchmarkResult? baseline;

  /// The change in median, as a ratio. `1.2` means twenty per cent slower.
  double? get ratio {
    final now = current?.medianUs;
    final before = baseline?.medianUs;
    if (now == null || before == null || before == 0) return null;
    return now / before;
  }

  /// The change as a signed percentage, or `null` when there is nothing to
  /// compare with.
  double? get changePercent {
    final value = ratio;
    return value == null ? null : (value - 1) * 100;
  }

  /// Serialises the comparison.
  JsonMap toJson() => pruneNulls(<String, Object?>{
    'name': name,
    'verdict': verdict.name,
    'currentUs': current?.medianUs,
    'baselineUs': baseline?.medianUs,
    'changePercent': changePercent,
  });

  @override
  String toString() => 'BenchmarkComparison($name, ${verdict.name})';
}

/// A set of results, with the context needed to read them.
@immutable
final class BenchmarkReport {
  /// Creates a report.
  BenchmarkReport({
    required List<BenchmarkResult> results,
    required this.dartVersion,
    required this.platform,
    required this.recordedAt,
  }) : results = List<BenchmarkResult>.unmodifiable(results);

  /// Restores a report from a baseline file.
  factory BenchmarkReport.fromJson(JsonMap json) => BenchmarkReport(
    dartVersion: json.stringOr('dartVersion', 'unknown'),
    platform: json.stringOr('platform', 'unknown'),
    recordedAt: json.optionalDateTime('recordedAt') ?? DateTime.utc(1970),
    results: <BenchmarkResult>[
      for (final entry in json.listOrEmpty('results'))
        if (entry is Map)
          BenchmarkResult.fromJson(entry.cast<String, Object?>()),
    ],
  );

  /// What was measured.
  final List<BenchmarkResult> results;

  /// Which Dart built it.
  ///
  /// Recorded because a baseline compared across SDK versions is comparing two
  /// compilers as much as two revisions of this code.
  final String dartVersion;

  /// Which operating system and architecture.
  final String platform;

  /// When the run happened.
  final DateTime recordedAt;

  /// The result named [name], or `null`.
  BenchmarkResult? operator [](String name) {
    for (final result in results) {
      if (result.name == name) return result;
    }
    return null;
  }

  /// Compares this report against [baseline].
  ///
  /// [tolerance] is the fraction of change treated as noise — 0.2 means a
  /// twenty per cent swing either way is ignored. The default is deliberately
  /// generous: a shared CI runner routinely varies by that much between
  /// identical runs, and a gate that fires on noise is a gate people disable.
  List<BenchmarkComparison> compareWith(
    BenchmarkReport baseline, {
    double tolerance = 0.2,
  }) {
    final comparisons = <BenchmarkComparison>[];
    final seen = <String>{};

    for (final result in results) {
      seen.add(result.name);
      final before = baseline[result.name];
      if (before == null) {
        comparisons.add(
          BenchmarkComparison(
            name: result.name,
            verdict: BenchmarkVerdict.added,
            current: result,
          ),
        );
        continue;
      }
      final change = before.medianUs == 0
          ? 0.0
          : (result.medianUs - before.medianUs) / before.medianUs;
      comparisons.add(
        BenchmarkComparison(
          name: result.name,
          verdict: change > tolerance
              ? BenchmarkVerdict.slower
              : change < -tolerance
              ? BenchmarkVerdict.faster
              : BenchmarkVerdict.unchanged,
          current: result,
          baseline: before,
        ),
      );
    }

    for (final before in baseline.results) {
      if (seen.contains(before.name)) continue;
      comparisons.add(
        BenchmarkComparison(
          name: before.name,
          verdict: BenchmarkVerdict.removed,
          baseline: before,
        ),
      );
    }
    return comparisons;
  }

  /// Serialises the report.
  JsonMap toJson() => <String, Object?>{
    'dartVersion': dartVersion,
    'platform': platform,
    'recordedAt': recordedAt.toIso8601String(),
    'results': results.map((r) => r.toJson()).toList(),
  };

  /// Serialises the report as indented JSON, for a file a person reviews.
  String toPrettyJson() =>
      '${const JsonEncoder.withIndent('  ').convert(toJson())}\n';

  @override
  String toString() =>
      'BenchmarkReport(${results.length} results, $platform, $dartVersion)';
}

/// Below this median, a tail ratio is timer noise rather than a signal.
///
/// Fifty microseconds is roughly where a scheduling hiccup stops dominating the
/// measurement on the machines this runs on.
const int tailFloorUs = 50;

/// Renders results as a fixed-width table.
///
/// Deliberately plain text with no colour. Benchmark output is read in a
/// terminal, pasted into a pull request, and diffed against a previous run;
/// escape codes ruin all three.
String renderTable(List<BenchmarkResult> results) {
  if (results.isEmpty) return 'No benchmarks matched.';

  const nameWidth = 34;
  final buffer = StringBuffer()
    ..writeln(
      '${'benchmark'.padRight(nameWidth)}'
      '${'median'.padLeft(11)}'
      '${'p90'.padLeft(11)}'
      '${'p99'.padLeft(11)}'
      '${'ops/s'.padLeft(12)}',
    )
    ..writeln('-' * (nameWidth + 45));

  for (final result in results) {
    buffer.writeln(
      '${_truncate(result.name, nameWidth).padRight(nameWidth)}'
      '${_duration(result.medianUs).padLeft(11)}'
      '${_duration(result.p90Us).padLeft(11)}'
      '${_duration(result.p99Us).padLeft(11)}'
      '${_rate(result.opsPerSecond).padLeft(12)}',
    );
  }

  // Flagged rather than buried: a tail this much worse than the middle is the
  // most actionable thing a benchmark run can tell you.
  //
  // The floor matters as much as the ratio. A benchmark with a 1 µs median is
  // measured with microsecond granularity, so a single tick of scheduler noise
  // reads as "4x slower" — and a report that flags every fast benchmark flags
  // nothing at all.
  final spiky = results
      .where((r) => r.medianUs >= tailFloorUs && r.tailRatio >= 3)
      .toList();
  if (spiky.isNotEmpty) {
    buffer
      ..writeln()
      ..writeln('Tail latency worth investigating (p99 >= 3x median):');
    for (final result in spiky) {
      buffer.writeln(
        '  ${result.name}  ${result.tailRatio.toStringAsFixed(1)}x',
      );
    }
  }
  return buffer.toString();
}

/// Renders a comparison against a baseline.
String renderComparison(
  List<BenchmarkComparison> comparisons, {
  double tolerance = 0.2,
}) {
  if (comparisons.isEmpty) return 'Nothing to compare.';

  const nameWidth = 34;
  final buffer = StringBuffer()
    ..writeln(
      '${'benchmark'.padRight(nameWidth)}'
      '${'baseline'.padLeft(11)}'
      '${'current'.padLeft(11)}'
      '${'change'.padLeft(10)}'
      '   verdict',
    )
    ..writeln('-' * (nameWidth + 50));

  for (final comparison in comparisons) {
    final change = comparison.changePercent;
    buffer.writeln(
      '${_truncate(comparison.name, nameWidth).padRight(nameWidth)}'
      '${_optionalDuration(comparison.baseline?.medianUs).padLeft(11)}'
      '${_optionalDuration(comparison.current?.medianUs).padLeft(11)}'
      '${(change == null ? '—' : '${change >= 0 ? '+' : ''}'
                '${change.toStringAsFixed(1)}%').padLeft(10)}'
      '   ${comparison.verdict.name}',
    );
  }

  final regressions = comparisons.where((c) => c.verdict.isRegression).toList();
  buffer
    ..writeln()
    ..writeln(
      regressions.isEmpty
          ? 'No regression beyond ${(tolerance * 100).round()}%.'
          : '${regressions.length} regression(s) beyond '
                '${(tolerance * 100).round()}%: '
                '${regressions.map((c) => c.name).join(', ')}',
    );
  return buffer.toString();
}

String _truncate(String value, int width) =>
    value.length <= width ? value : '${value.substring(0, width - 1)}…';

String _optionalDuration(int? microseconds) =>
    microseconds == null ? '—' : _duration(microseconds);

/// Formats microseconds at a scale a reader can hold in their head.
String _duration(int microseconds) {
  if (microseconds < 1000) return '${microseconds}us';
  if (microseconds < 1000000) {
    return '${(microseconds / 1000).toStringAsFixed(2)}ms';
  }
  return '${(microseconds / 1000000).toStringAsFixed(2)}s';
}

String _rate(double opsPerSecond) {
  if (!opsPerSecond.isFinite) return '—';
  if (opsPerSecond >= 1000000) {
    return '${(opsPerSecond / 1000000).toStringAsFixed(1)}M';
  }
  if (opsPerSecond >= 1000) {
    return '${(opsPerSecond / 1000).toStringAsFixed(1)}k';
  }
  return opsPerSecond.toStringAsFixed(1);
}
