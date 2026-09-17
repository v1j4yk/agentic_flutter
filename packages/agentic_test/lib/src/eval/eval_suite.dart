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
    : trials = List<EvalTrial>.unmodifiable(trials);

  /// The case.
  final String name;

  /// Every trial, in attempt order.
  final List<EvalTrial> trials;

  /// How many trials passed.
  int get passed => trials.where((t) => t.passed).length;

  /// The fraction of trials that passed, from 0 to 1.
  double get passRate => trials.isEmpty ? 0 : passed / trials.length;

  /// Serialises the report.
  JsonMap toJson() => <String, Object?>{
    'name': name,
    'passed': passed,
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
  double get passRate {
    final all = trials.toList();
    return all.isEmpty ? 0 : all.where((t) => t.passed).length / all.length;
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

  static String _percent(double rate) => '${(rate * 100).toStringAsFixed(0)}%';
}

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
