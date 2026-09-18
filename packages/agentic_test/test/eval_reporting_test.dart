/// Trajectory checks, CI reports and baselines — the parts that let an eval
/// suite gate a pull request rather than only print a number.
library;

import 'package:agentic_agents/agentic_agents.dart';
import 'package:agentic_core/agentic_core.dart';
import 'package:agentic_llm/agentic_llm.dart';
import 'package:agentic_test/agentic_test.dart';
import 'package:test/test.dart';

ToolCallPart call(String name, [Map<String, Object?> arguments = const {}]) =>
    ToolCallPart(id: 'c_$name', name: name, arguments: arguments);

/// A result whose single step made [calls].
AgentResult ran(List<ToolCallPart> calls) => AgentResult(
  message: Message.assistant('done'),
  stopReason: AgentStopReason.completed,
  duration: Duration.zero,
  steps: <AgentStep>[
    AgentStep(
      index: 0,
      response: ChatResponse(message: Message.assistant('done'), modelId: 'm'),
      duration: Duration.zero,
      toolCalls: calls,
    ),
  ],
);

final AgentInput input = AgentInput.text('Refund order 42.');

Future<CheckResult> verdict(EvalCheck check, AgentResult result) async =>
    check.evaluate(input, result);

EvalReport reportWith(Map<String, double> rates) => EvalReport(
  suite: 'support',
  duration: const Duration(seconds: 1),
  cases: <EvalCaseReport>[
    for (final MapEntry(key: name, value: rate) in rates.entries)
      EvalCaseReport.summary(name: name, passRate: rate, trialCount: 4),
  ],
);

void main() {
  group('trajectory', () {
    test('matches in order, tolerating calls in between', () async {
      final result = ran([
        call('lookup_order', {'orderId': '42'}),
        call('check_stock'),
        call('issue_refund', {'order': '42'}),
      ]);

      final forwards = await verdict(
        const EvalCheck.trajectory([
          ToolStep('lookup_order'),
          ToolStep('issue_refund'),
        ]),
        result,
      );
      expect(
        forwards.passed,
        isTrue,
        reason: 'an agent that also checked stock is odd, not wrong',
      );

      // Order is the point: refunding before looking the order up is exactly
      // the bug this check exists to catch.
      final backwards = await verdict(
        const EvalCheck.trajectory([
          ToolStep('issue_refund'),
          ToolStep('lookup_order'),
        ]),
        result,
      );
      expect(backwards.passed, isFalse);
      expect(backwards.reason, contains('reached step'));
    });

    test('exact rejects an extra call, and any() absorbs one', () async {
      final result = ran([call('a'), call('b'), call('c')]);

      expect(
        (await verdict(
          const EvalCheck.trajectory([
            ToolStep('a'),
            ToolStep('c'),
          ], mode: TrajectoryMatch.exact),
          result,
        )).passed,
        isFalse,
      );
      expect(
        (await verdict(
          const EvalCheck.trajectory([
            ToolStep('a'),
            ToolStep.any(),
            ToolStep('c'),
          ], mode: TrajectoryMatch.exact),
          result,
        )).passed,
        isTrue,
      );
    });

    test('anyOrder ignores order but not count', () async {
      expect(
        (await verdict(
          const EvalCheck.trajectory([
            ToolStep('c'),
            ToolStep('a'),
          ], mode: TrajectoryMatch.anyOrder),
          ran([call('a'), call('b'), call('c')]),
        )).passed,
        isTrue,
      );

      // One call must not satisfy two steps, or "searched twice" would pass on
      // a single search.
      expect(
        (await verdict(
          const EvalCheck.trajectory([
            ToolStep('search'),
            ToolStep('search'),
          ], mode: TrajectoryMatch.anyOrder),
          ran([call('search')]),
        )).passed,
        isFalse,
      );
    });

    test('arguments are contained, not equal', () async {
      final result = ran([
        call('issue_refund', {'order': '42', 'reason': 'damaged'}),
      ]);

      expect(
        (await verdict(
          const EvalCheck.trajectory([
            ToolStep('issue_refund', arguments: {'order': '42'}),
          ]),
          result,
        )).passed,
        isTrue,
        reason: 'a model passing an extra optional argument is not a failure',
      );
      expect(
        (await verdict(
          const EvalCheck.trajectory([
            ToolStep('issue_refund', arguments: {'order': '99'}),
          ]),
          result,
        )).passed,
        isFalse,
      );
    });

    test('a predicate can check what an equality cannot', () async {
      expect(
        (await verdict(
          EvalCheck.trajectory([
            ToolStep(
              'issue_refund',
              where: (arguments) => (arguments['amount']! as num) <= 100,
            ),
          ]),
          ran([
            call('issue_refund', {'amount': 40}),
          ]),
        )).passed,
        isTrue,
      );
    });
  });

  group('JUnit output', () {
    test('names every trial, counts failures, and escapes its own text', () {
      final report = EvalReport(
        suite: 'support & billing',
        duration: const Duration(milliseconds: 1500),
        cases: <EvalCaseReport>[
          EvalCaseReport(
            name: 'refund',
            trials: <EvalTrial>[
              EvalTrial(
                caseName: 'refund',
                attempt: 1,
                checks: const <CheckResult>[
                  CheckResult(
                    description: 'called `issue_refund`',
                    passed: true,
                  ),
                ],
                duration: Duration.zero,
              ),
              EvalTrial(
                caseName: 'refund',
                attempt: 2,
                checks: const <CheckResult>[
                  CheckResult(
                    description: 'answer contains "<order>"',
                    passed: false,
                    reason: 'said 41 & not 42',
                  ),
                ],
                duration: Duration.zero,
              ),
            ],
          ),
        ],
      );

      final xml = report.toJUnitXml();

      expect(xml, startsWith('<?xml version="1.0"'));
      expect(xml, contains('tests="2"'));
      expect(xml, contains('failures="1"'));
      // Per trial, not per case: a case passing four times in five is flaky,
      // and a report that hides that is worse than no report.
      expect(xml, contains('name="refund #1"'));
      expect(xml, contains('name="refund #2"'));
      expect(xml, contains('<failure'));
      // Unescaped, this is not XML at all.
      expect(xml, contains('&amp;'));
      expect(xml, contains('&quot;&lt;order&gt;&quot;'));
      expect(xml, isNot(contains('said 41 & not')));
    });
  });

  group('baselines', () {
    test('a report round-trips through JSON as numbers', () {
      final restored = EvalReport.fromJson(
        reportWith({'refund': 0.75, 'escalate': 1}).toJson(),
      );

      expect(restored.suite, 'support');
      expect(restored.passRate, closeTo(0.875, 0.001));
      expect(restored.cases.map((c) => c.name), <String>['refund', 'escalate']);
      expect(restored.cases.first.passRate, 0.75);
      expect(restored.cases.first.trialCount, 4);
      // Transcripts are deliberately not restored: a baseline is kept for its
      // numbers, and every trial would make the file large and unreadable.
      expect(restored.cases.first.trials, isEmpty);
    });

    test('a comparison names what got worse, and gates on the drop', () {
      final change = reportWith({
        'refund': 0.5,
        'escalate': 1,
      }).compareTo(reportWith({'refund': 1, 'escalate': 1}));

      expect(change.delta, closeTo(-0.25, 0.001));
      expect(change.regressions.single.name, 'refund');
      expect(change.summary, contains('refund'));
      expect(
        () => change.failIfRegressed(maxDrop: 0.05),
        throwsA(isA<EvalRegressionError>()),
      );
      // Ordinary variance must not fail a gate, or the gate gets disabled.
      expect(() => change.failIfRegressed(maxDrop: 0.5), returnsNormally);
    });

    test('an improvement never fails a gate', () {
      final change = reportWith({
        'refund': 1,
      }).compareTo(reportWith({'refund': 0.25}));

      expect(change.delta, greaterThan(0));
      expect(change.regressions, isEmpty);
      expect(change.failIfRegressed, returnsNormally);
    });

    test('a case missing from the run is reported rather than ignored', () {
      final change = reportWith({
        'refund': 1,
      }).compareTo(reportWith({'refund': 1, 'escalate': 1}));

      expect(change.missing, <String>['escalate']);
      expect(change.summary, contains('not in this run'));
    });
  });
}
