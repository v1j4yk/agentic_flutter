// The benchmark runner.
//
//   dart run agentic_benchmark                  everything
//   dart run agentic_benchmark vector           one layer, or one benchmark
//   dart run agentic_benchmark --save-baseline  record the current numbers
//   dart run agentic_benchmark --baseline       compare against them
//   dart run agentic_benchmark --json           machine-readable output
//
// `--baseline` exits non-zero when something regressed beyond the tolerance,
// so it can gate a pull request. Whether it *should* is a judgement call: on a
// shared CI runner the numbers move by tens of per cent between identical runs,
// which is why the default tolerance is wide and why the CI job reports rather
// than gates. Run it locally, on a quiet machine, when you have changed
// something you expect to matter.
import 'dart:convert';
import 'dart:io';

import 'package:agentic_benchmark/agentic_benchmark.dart';

const String _baselinePath = 'baseline.json';
const double _defaultTolerance = 0.2;

Future<void> main(List<String> arguments) async {
  final options = _Options.parse(arguments);
  if (options.help) {
    stdout.writeln(_usage);
    return;
  }

  final suites = <BenchmarkSuite>[
    coreSuite(),
    toolsSuite(),
    llmSuite(),
    agentsSuite(),
    memorySuite(),
    vectorSuite(),
    retrievalSuite(),
    mcpSuite(),
  ];

  final runner = BenchmarkRunner(
    onProgress: options.json
        ? null
        // To stderr, so `--json` on stdout stays pipeable while a human still
        // sees that a two-minute run is making progress.
        : (name) => stderr.writeln('  running $name'),
  );

  final started = DateTime.now();
  final results = await runner.run(suites, filter: options.filter);
  if (results.isEmpty) {
    stderr.writeln('No benchmark matched "${options.filter}".');
    exitCode = 1;
    return;
  }

  final report = BenchmarkReport(
    results: results,
    dartVersion: Platform.version.split(' ').first,
    platform: '${Platform.operatingSystem}-${_architecture()}',
    recordedAt: started.toUtc(),
  );

  if (options.saveBaseline) {
    File(_baselinePath).writeAsStringSync(report.toPrettyJson());
    stdout.writeln('Wrote $_baselinePath (${results.length} benchmarks).');
    return;
  }

  if (options.json) {
    stdout.writeln(const JsonEncoder.withIndent('  ').convert(report.toJson()));
    return;
  }

  stdout
    ..writeln()
    ..writeln('${report.platform}, Dart ${report.dartVersion}')
    ..writeln()
    ..writeln(renderTable(results));

  if (!options.compareBaseline) return;

  final file = File(_baselinePath);
  if (!file.existsSync()) {
    stderr.writeln(
      'No $_baselinePath to compare against. Record one with '
      '`--save-baseline` on a quiet machine first.',
    );
    exitCode = 1;
    return;
  }

  final baseline = BenchmarkReport.fromJson(
    jsonDecode(file.readAsStringSync()) as Map<String, Object?>,
  );
  if (baseline.platform != report.platform ||
      baseline.dartVersion != report.dartVersion) {
    // A warning rather than a refusal. Comparing across machines is misleading
    // and sometimes it is all you have; what is not acceptable is doing it
    // without knowing.
    stderr.writeln(
      'Warning: the baseline was recorded on ${baseline.platform} with Dart '
      '${baseline.dartVersion}. Comparing across machines or SDKs measures '
      'those as much as the code.',
    );
  }

  final comparisons = report.compareWith(
    baseline,
    tolerance: options.tolerance,
  );
  stdout
    ..writeln()
    ..writeln(renderComparison(comparisons, tolerance: options.tolerance));

  if (comparisons.any((c) => c.verdict.isRegression)) exitCode = 1;
}

String _architecture() {
  // `Platform` exposes no architecture directly; the version string carries it
  // as a trailing "os_arch" token.
  final tokens = Platform.version.split(' ');
  final target = tokens.isEmpty ? '' : tokens.last.replaceAll('"', '');
  final underscore = target.lastIndexOf('_');
  return underscore < 0 ? 'unknown' : target.substring(underscore + 1);
}

final class _Options {
  const _Options({
    this.filter,
    this.saveBaseline = false,
    this.compareBaseline = false,
    this.json = false,
    this.help = false,
    this.tolerance = _defaultTolerance,
  });

  factory _Options.parse(List<String> arguments) {
    String? filter;
    var saveBaseline = false;
    var compareBaseline = false;
    var json = false;
    var help = false;
    var tolerance = _defaultTolerance;

    for (final argument in arguments) {
      switch (argument) {
        case '--save-baseline':
          saveBaseline = true;
        case '--baseline':
          compareBaseline = true;
        case '--json':
          json = true;
        case '-h' || '--help':
          help = true;
        default:
          if (argument.startsWith('--tolerance=')) {
            tolerance =
                double.tryParse(argument.split('=').last) ?? _defaultTolerance;
          } else if (!argument.startsWith('-')) {
            filter = argument;
          }
      }
    }

    return _Options(
      filter: filter,
      saveBaseline: saveBaseline,
      compareBaseline: compareBaseline,
      json: json,
      help: help,
      tolerance: tolerance,
    );
  }

  final String? filter;
  final bool saveBaseline;
  final bool compareBaseline;
  final bool json;
  final bool help;
  final double tolerance;
}

const String _usage = '''
Micro-benchmarks for the agentic framework.

Usage: dart run agentic_benchmark [filter] [options]

  filter                A substring of a benchmark name: `vector`, `agents`,
                        or `vector.search.10k`.

Options:
  --save-baseline       Write the current numbers to baseline.json.
  --baseline            Compare against baseline.json; exit 1 on a regression.
  --tolerance=0.2       Fraction of change treated as noise. Default 0.2.
  --json                Emit the report as JSON on stdout.
  -h, --help            Show this.

Run --save-baseline on a quiet machine. Benchmark numbers on a shared CI runner
vary by tens of per cent between identical runs, which is why the CI job reports
them rather than gating on them.''';
