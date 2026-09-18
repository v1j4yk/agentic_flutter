/// Running evals, and what they report.
library;

import 'dart:async';

import 'package:agentic_agents/agentic_agents.dart';
import 'package:agentic_core/agentic_core.dart';
import 'package:agentic_test/src/eval/eval_check.dart';
import 'package:meta/meta.dart';

/// One task for an agent, and what a good run looks like.
@immutable
final class EvalCase {
  /// Creates a case from an [AgentInput].
  EvalCase({
    required this.name,
    required this.input,
    required List<EvalCheck> checks,
  }) : checks = List<EvalCheck>.unmodifiable(checks) {
    if (checks.isEmpty) {
      throw ConfigurationException(
        'Eval case `$name` has no checks, so every run would pass.',
        setting: 'EvalCase.checks',
      );
    }
  }

  /// Creates a case from a prompt.
  factory EvalCase.text({
    required String name,
    required String prompt,
    required List<EvalCheck> checks,
  }) => EvalCase(name: name, input: AgentInput.text(prompt), checks: checks);

  /// Identifies the case in reports.
  final String name;

  /// What the agent is asked.
  final AgentInput input;

  /// What must hold for a run to pass. Every check must pass.
  final List<EvalCheck> checks;
}

/// One run of one case.
@immutable
final class EvalTrial {
  /// Creates a trial.
  EvalTrial({
    required this.caseName,
    required this.attempt,
    required List<CheckResult> checks,
    required this.duration,
    this.result,
    this.error,
  }) : checks = List<CheckResult>.unmodifiable(checks);

  /// The case this trial ran.
  final String caseName;

  /// Which repetition this was, from zero.
  final int attempt;

  /// Each check's verdict. Empty when the run threw.
  final List<CheckResult> checks;

  /// What the agent returned, unless it threw.
  final AgentResult? result;

  /// What the agent threw, if it did.
  ///
  /// An agent is meant to report failure in its result. One that throws
  /// instead fails the trial, and the suite carries on.
  final Object? error;

  /// How long the run and its checks took.
  final Duration duration;

  /// Whether the run completed and every check passed.
  bool get passed => error == null && checks.every((c) => c.passed);

  /// The checks that failed.
  List<CheckResult> get failedChecks =>
      checks.where((c) => !c.passed).toList(growable: false);

  /// Serialises the trial.
  JsonMap toJson() => pruneNulls(<String, Object?>{
    'case': caseName,
    'attempt': attempt,
    'passed': passed,
    'checks': checks.map((c) => c.toJson()).toList(),
    'error': error?.toString(),
    'answer': result?.text,
    'steps': result?.iterations,
    'tokens': result?.usage.totalTokens,
    'durationMs': duration.inMilliseconds,
  });
}

/// The outcome of every trial of one case.
@immutable
final class EvalCaseReport {
  /// Creates a case report.
  EvalCaseReport({required this.name, required List<EvalTrial> trials})
    : trials = List<EvalTrial>.unmodifiable(trials),
      _passRate = null,
      _trialCount = null;

  /// Creates a case report with numbers but no transcripts.
  ///
  /// What a stored baseline restores to: keeping every trial would make a
  /// baseline file large and unreadable, and a comparison only needs the rate.
  const EvalCaseReport.summary({
    required this.name,
    required double passRate,
    required int trialCount,
  }) : trials = const <EvalTrial>[],
       _passRate = passRate,
       _trialCount = trialCount;

  /// The case.
  final String name;

  /// Every trial, in attempt order. Empty for a restored baseline.
  final List<EvalTrial> trials;

  final double? _passRate;
  final int? _trialCount;

  /// How many trials ran.
  int get trialCount => _trialCount ?? trials.length;

  /// How many trials passed.
  int get passed => _passRate == null
      ? trials.where((t) => t.passed).length
      : (_passRate * trialCount).round();

  /// The fraction of trials that passed, from 0 to 1.
  double get passRate =>
      _passRate ?? (trials.isEmpty ? 0 : passed / trials.length);

  /// Serialises the report.
  JsonMap toJson() => <String, Object?>{
    'name': name,
    'passed': passed,
    'passRate': passRate,
    'trialCount': trialCount,
    'trials': trials.map((t) => t.toJson()).toList(),
  };
}

/// What an [EvalSuite] run found.
@immutable
final class EvalReport {
  /// Creates a report.
  EvalReport({
    required this.suite,
    required List<EvalCaseReport> cases,
    required this.duration,
  }) : cases = List<EvalCaseReport>.unmodifiable(cases);

  /// Reads a report written by [toJson].
  ///
  /// Trials are not restored — a baseline is kept for its numbers, and storing
  /// every transcript would make the file unreadable and large.
  factory EvalReport.fromJson(JsonMap json) => EvalReport(
    suite: json.requireString('suite'),
    duration: Duration(milliseconds: json.intOr('durationMs', 0)),
    cases: <EvalCaseReport>[
      for (final entry in json.listOrEmpty('cases'))
        if (entry is Map<String, Object?>)
          EvalCaseReport.summary(
            name: entry.requireString('name'),
            passRate: entry.optionalDouble('passRate') ?? 0,
            trialCount: entry.intOr('trialCount', 0),
          ),
    ],
  );

  /// The suite's name.
  final String suite;

  /// Each case's outcome, in suite order.
  final List<EvalCaseReport> cases;

  /// How long the whole suite took.
  final Duration duration;

  /// Every trial of every case.
  Iterable<EvalTrial> get trials => cases.expand((c) => c.trials);

  /// The trials that failed.
  List<EvalTrial> get failures =>
      trials.where((t) => !t.passed).toList(growable: false);

  /// The fraction of all trials that passed, from 0 to 1.
  ///
  /// Counted per case rather than by walking the trials, so that a report
  /// restored from a stored baseline — which keeps the numbers and drops the
  /// transcripts — reports the rate it was saved with rather than zero.
  double get passRate {
    final total = cases.fold(0, (sum, c) => sum + c.trialCount);
    if (total == 0) return 0;
    return cases.fold(0, (sum, c) => sum + c.passed) / total;
  }

  /// Tokens spent across all trials, including failures.
  int get totalTokens =>
      trials.fold(0, (sum, t) => sum + (t.result?.usage.totalTokens ?? 0));

  /// Throws an [EvalFailedError] if [passRate] is below [threshold].
  ///
  /// The single line a CI test needs:
  ///
  /// ```dart
  /// test('support agent', () async {
  ///   final report = await suite.run(agent, repeat: 5);
  ///   report.requirePassRate(0.9);
  /// });
  /// ```
  void requirePassRate(double threshold) {
    if (threshold < 0 || threshold > 1) {
      throw ArgumentError.value(threshold, 'threshold', 'must be in [0, 1]');
    }
    if (passRate >= threshold) return;
    throw EvalFailedError(this, threshold);
  }

  /// A readable summary: the pass rate, then each failure and why.
  String get summary {
    final buffer = StringBuffer()
      ..writeln(
        '$suite: ${_percent(passRate)} passed '
        '(${trials.length - failures.length}/${trials.length} trials)',
      );
    for (final trial in failures) {
      buffer.writeln('  ${trial.caseName} #${trial.attempt}:');
      if (trial.error case final error?) {
        buffer.writeln('    threw: $error');
      }
      for (final check in trial.failedChecks) {
        buffer.writeln('    $check');
      }
    }
    return buffer.toString().trimRight();
  }

  /// The report as a Markdown table, for a pull request comment or a CI
  /// summary.
  String toMarkdown() {
    final buffer = StringBuffer()
      ..writeln('### $suite — ${_percent(passRate)}')
      ..writeln()
      ..writeln('| Case | Passed | Rate |')
      ..writeln('|---|---|---|');
    for (final c in cases) {
      buffer.writeln(
        '| ${c.name} | ${c.passed}/${c.trials.length} | '
        '${_percent(c.passRate)} |',
      );
    }
    final failed = failures;
    if (failed.isNotEmpty) {
      buffer
        ..writeln()
        ..writeln('**Failures**')
        ..writeln();
      for (final trial in failed) {
        final why = trial.error != null
            ? 'threw: ${trial.error}'
            : trial.failedChecks.map((c) => '$c').join('; ');
        buffer.writeln('- ${trial.caseName} #${trial.attempt}: $why');
      }
    }
    return buffer.toString();
  }

  /// Serialises the report, for tracking pass rates over time.
  JsonMap toJson() => <String, Object?>{
    'suite': suite,
    'passRate': passRate,
    'totalTokens': totalTokens,
    'durationMs': duration.inMilliseconds,
    'cases': cases.map((c) => c.toJson()).toList(),
  };

  /// The report as JUnit XML, which is what CI systems render natively.
  ///
  /// GitHub Actions, GitLab and Jenkins all read this format, so a suite's
  /// failures appear beside unit-test failures rather than buried in a log.
  /// One `<testcase>` per trial, named `case #attempt`, so a case that passes
  /// four times out of five shows as one flaky entry rather than as a pass.
  ///
  /// ```dart
  /// File('build/evals.xml').writeAsStringSync(report.toJUnitXml());
  /// ```
  String toJUnitXml() {
    final trialList = trials.toList();
    final failed = trialList.where((t) => !t.passed).length;
    final errored = trialList.where((t) => t.error != null).length;
    final buffer = StringBuffer()
      ..writeln('<?xml version="1.0" encoding="UTF-8"?>')
      ..writeln(
        '<testsuite name="${_xml(suite)}" tests="${trialList.length}" '
        'failures="${failed - errored}" errors="$errored" '
        'time="${duration.inMilliseconds / 1000}">',
      );

    for (final trial in trialList) {
      final name = _xml('${trial.caseName} #${trial.attempt}');
      final time = trial.duration.inMilliseconds / 1000;
      if (trial.passed) {
        buffer.writeln('  <testcase name="$name" time="$time"/>');
        continue;
      }
      buffer.writeln('  <testcase name="$name" time="$time">');
      if (trial.error case final error?) {
        buffer.writeln(
          '    <error message="${_xml('$error')}">${_xml('$error')}</error>',
        );
      } else {
        final why = trial.failedChecks.map((c) => '$c').join('\n');
        buffer.writeln(
          '    <failure message="${_xml(trial.failedChecks.map((c) => c.description).join('; '))}">'
          '${_xml(why)}</failure>',
        );
      }
      buffer.writeln('  </testcase>');
    }

    return (buffer..writeln('</testsuite>')).toString();
  }

  /// Compares this report with an earlier one.
  ///
  /// The question an eval suite exists to answer is not "is it good" but "did
  /// that change make it worse", and that needs yesterday's numbers. Store
  /// [toJson] somewhere and read it back with [EvalReport.fromJson].
  ///
  /// ```dart
  /// final change = report.compareTo(baseline);
  /// change.failIfRegressed(maxDrop: 0.05);
  /// ```
  EvalComparison compareTo(EvalReport baseline) =>
      EvalComparison(baseline: baseline, current: this);

  static String _percent(double rate) => '${(rate * 100).toStringAsFixed(0)}%';
}

/// Two runs of the same suite, and what changed between them.
final class EvalComparison {
  /// Creates a comparison.
  const EvalComparison({required this.baseline, required this.current});

  /// The earlier report.
  final EvalReport baseline;

  /// The report just produced.
  final EvalReport current;

  /// How much the overall pass rate moved. Negative is a regression.
  double get delta => current.passRate - baseline.passRate;

  /// Cases whose pass rate fell, worst first.
  List<({String name, double before, double after})> get regressions {
    final before = <String, double>{
      for (final c in baseline.cases) c.name: c.passRate,
    };
    final moved = <({String name, double before, double after})>[
      for (final c in current.cases)
        if (before[c.name] case final was? when c.passRate < was)
          (name: c.name, before: was, after: c.passRate),
    ]..sort((a, b) => (a.after - a.before).compareTo(b.after - b.before));
    return moved;
  }

  /// Cases in the baseline that this run did not cover.
  List<String> get missing {
    final names = current.cases.map((c) => c.name).toSet();
    return <String>[
      for (final c in baseline.cases)
        if (!names.contains(c.name)) c.name,
    ];
  }

  /// Throws when the suite got worse by more than [maxDrop].
  ///
  /// A small tolerance is deliberate: these runs are not deterministic, and a
  /// gate that fires on ordinary variance is a gate that gets disabled. Zero
  /// tolerance is for a suite that replays cassettes, where it is honest.
  void failIfRegressed({double maxDrop = 0.05}) {
    if (delta >= -maxDrop) return;
    throw EvalRegressionError(this, maxDrop);
  }

  /// A readable summary of the change.
  String get summary {
    final direction = delta >= 0 ? 'up' : 'down';
    final buffer = StringBuffer()
      ..writeln(
        '${current.suite}: ${_asPercent(baseline.passRate)} → '
        '${_asPercent(current.passRate)} '
        '($direction ${_asPercent(delta.abs())})',
      );
    for (final regression in regressions) {
      buffer.writeln(
        '  ${regression.name}: ${_asPercent(regression.before)} → '
        '${_asPercent(regression.after)}',
      );
    }
    for (final name in missing) {
      buffer.writeln('  $name: in the baseline, not in this run');
    }
    return buffer.toString();
  }
}

/// Thrown by [EvalComparison.failIfRegressed].
final class EvalRegressionError extends Error {
  /// Creates the error.
  EvalRegressionError(this.comparison, this.maxDrop);

  /// What was compared.
  final EvalComparison comparison;

  /// The tolerance that was exceeded.
  final double maxDrop;

  @override
  String toString() =>
      'EvalRegressionError: pass rate fell by more than '
      '${_asPercent(maxDrop)}\n${comparison.summary}';
}

String _asPercent(double rate) => '${(rate * 100).toStringAsFixed(0)}%';

/// Escapes text for an XML attribute or element body.
String _xml(String text) => text
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;');

/// Thrown by [EvalReport.requirePassRate] when a suite falls short.
final class EvalFailedError extends Error {
  /// Creates the error.
  EvalFailedError(this.report, this.threshold);

  /// The report that fell short.
  final EvalReport report;

  /// The pass rate that was required.
  final double threshold;

  @override
  String toString() =>
      'EvalFailedError: required ${(threshold * 100).toStringAsFixed(0)}%\n'
      '${report.summary}';
}

/// A named set of [EvalCase]s run against an agent.
///
/// ```dart
/// final suite = EvalSuite(name: 'support', cases: [refund, orderStatus]);
/// final report = await suite.run(agent, repeat: 5);
/// print(report.summary);
/// ```
///
/// Run it against a live model to measure a prompt change, or against a
/// cassette to keep behaviour from regressing in CI at no cost. [run] with
/// `repeat` above one is only meaningful live: a cassette answers identically
/// every time.
final class EvalSuite {
  /// Creates a suite.
  EvalSuite({required this.name, required List<EvalCase> cases})
    : cases = List<EvalCase>.unmodifiable(cases) {
    final seen = <String>{};
    for (final c in cases) {
      if (!seen.add(c.name)) {
        throw ConfigurationException(
          'Eval suite `$name` has two cases named `${c.name}`; reports could '
          'not tell them apart.',
          setting: 'EvalSuite.cases',
        );
      }
    }
  }

  /// Identifies the suite in reports.
  final String name;

  /// The cases, run in this order.
  final List<EvalCase> cases;

  /// Runs every case [repeat] times against [agent].
  ///
  /// Trials run one at a time unless [concurrency] is raised: a live provider
  /// rate-limits a burst, and a rate limit would fail trials for reasons that
  /// say nothing about the agent. Each trial runs in its own root context, so
  /// no state — untrusted-content taint, budgets — carries between them.
  Future<EvalReport> run(
    Agent agent, {
    int repeat = 1,
    int concurrency = 1,
    Clock clock = const SystemClock(),
  }) async {
    if (repeat < 1) {
      throw ArgumentError.value(repeat, 'repeat', 'must be at least 1');
    }
    if (concurrency < 1) {
      throw ArgumentError.value(
        concurrency,
        'concurrency',
        'must be at least 1',
      );
    }
    final started = clock.now();
    final jobs = <(EvalCase, int)>[
      for (final c in cases)
        for (var attempt = 0; attempt < repeat; attempt++) (c, attempt),
    ];
    final trials = List<EvalTrial?>.filled(jobs.length, null);

    var next = 0;
    Future<void> worker() async {
      while (next < jobs.length) {
        final index = next++;
        final (evalCase, attempt) = jobs[index];
        trials[index] = await _trial(agent, evalCase, attempt, clock);
      }
    }

    await Future.wait(<Future<void>>[
      for (var i = 0; i < concurrency && i < jobs.length; i++) worker(),
    ]);

    return EvalReport(
      suite: name,
      duration: clock.now().difference(started),
      cases: <EvalCaseReport>[
        for (final c in cases)
          EvalCaseReport(
            name: c.name,
            trials: <EvalTrial>[
              for (var i = 0; i < jobs.length; i++)
                if (identical(jobs[i].$1, c)) trials[i]!,
            ],
          ),
      ],
    );
  }

  static Future<EvalTrial> _trial(
    Agent agent,
    EvalCase evalCase,
    int attempt,
    Clock clock,
  ) async {
    final started = clock.now();
    final context = AgenticContext.root();
    final AgentResult result;
    try {
      result = await agent.run(evalCase.input, context: context);
    } on Object catch (error) {
      return EvalTrial(
        caseName: evalCase.name,
        attempt: attempt,
        checks: const <CheckResult>[],
        error: error,
        duration: clock.now().difference(started),
      );
    }
    final verdicts = <CheckResult>[];
    for (final check in evalCase.checks) {
      verdicts.add(
        await check.evaluate(evalCase.input, result, context: context),
      );
    }
    return EvalTrial(
      caseName: evalCase.name,
      attempt: attempt,
      checks: verdicts,
      result: result,
      duration: clock.now().difference(started),
    );
  }
}
