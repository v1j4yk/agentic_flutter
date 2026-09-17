import 'package:agentic_agents/agentic_agents.dart';
import 'package:agentic_core/agentic_core.dart';
import 'package:agentic_llm/agentic_llm.dart';
import 'package:agentic_llm/testing.dart';
import 'package:agentic_test/agentic_test.dart';
import 'package:test/test.dart';

/// An agent that returns scripted results in turn, and can throw.
final class ScriptedAgent implements Agent {
  ScriptedAgent(this.script);

  final List<Object> script;
  final List<AgenticContext?> contexts = [];
  int _next = 0;

  @override
  AgentInfo get info => AgentInfo(name: 'scripted', description: 'Scripted.');

  @override
  Future<AgentResult> run(
    AgentInput input, {
    AgentSession? session,
    AgenticContext? context,
  }) async {
    contexts.add(context);
    final entry = script[_next++ % script.length];
    if (entry is AgentResult) return entry;
    throw entry;
  }

  @override
  Stream<AgentChunk> stream(
    AgentInput input, {
    AgentSession? session,
    AgenticContext? context,
  }) => throw UnimplementedError();

  @override
  Future<void> dispose() async {}
}

AgentResult resultWith(
  String text, {
  List<ToolCallPart> toolCalls = const [],
  int steps = 1,
  int tokens = 100,
  AgentStopReason stopReason = AgentStopReason.completed,
}) => AgentResult(
  message: Message.assistant(text),
  stopReason: stopReason,
  duration: Duration.zero,
  usage: TokenUsage(promptTokens: tokens, completionTokens: 0),
  steps: [
    for (var i = 0; i < steps; i++)
      AgentStep(
        index: i,
        response: ChatResponse(
          message: Message.assistant(i == steps - 1 ? text : ''),
          modelId: 'm',
        ),
        duration: Duration.zero,
        toolCalls: i == 0 ? toolCalls : const [],
      ),
  ],
);

ToolCallPart refund(String order) =>
    ToolCallPart(id: 'c1', name: 'issue_refund', arguments: {'order': order});

final AgentInput input = AgentInput.text('Refund order 1042.');

Future<CheckResult> check(EvalCheck check, AgentResult result) async =>
    check.evaluate(input, result);

void main() {
  group('checks', () {
    test('succeeded', () async {
      expect(
        (await check(EvalCheck.succeeded(), resultWith('ok'))).passed,
        isTrue,
      );
      final failed = await check(
        EvalCheck.succeeded(),
        resultWith('', stopReason: AgentStopReason.budgetExhausted),
      );
      expect(failed.passed, isFalse);
      expect(failed.reason, contains('budgetExhausted'));
    });

    test('answerContains ignores case by default', () async {
      final result = resultWith('Refund issued for ORDER 1042.');
      expect(
        (await check(EvalCheck.answerContains('order 1042'), result)).passed,
        isTrue,
      );
      final strict = await check(
        EvalCheck.answerContains('order 1042', caseSensitive: true),
        result,
      );
      expect(strict.passed, isFalse);
      expect(strict.reason, contains('ORDER 1042'));
    });

    test('answerMatches', () async {
      final pattern = EvalCheck.answerMatches(RegExp(r'\b\d{4}\b'));
      expect((await check(pattern, resultWith('order 1042'))).passed, isTrue);
      expect((await check(pattern, resultWith('no order'))).passed, isFalse);
    });

    test('calledTool, with and without an argument filter', () async {
      final result = resultWith('Done.', toolCalls: [refund('1042')]);
      expect(
        (await check(EvalCheck.calledTool('issue_refund'), result)).passed,
        isTrue,
      );
      expect(
        (await check(
          EvalCheck.calledTool(
            'issue_refund',
            where: (args) => args['order'] == '1042',
          ),
          result,
        )).passed,
        isTrue,
      );

      final wrongOrder = await check(
        EvalCheck.calledTool(
          'issue_refund',
          where: (args) => args['order'] == '9999',
        ),
        result,
      );
      expect(wrongOrder.passed, isFalse);
      expect(wrongOrder.reason, contains('"order":"1042"'));

      final notCalled = await check(
        EvalCheck.calledTool('cancel_order'),
        result,
      );
      expect(notCalled.passed, isFalse);
      expect(notCalled.reason, contains('`issue_refund`'));
    });

    test('didNotCallTool', () async {
      final result = resultWith('Done.', toolCalls: [refund('1042')]);
      expect(
        (await check(
          EvalCheck.didNotCallTool('delete_account'),
          result,
        )).passed,
        isTrue,
      );
      final called = await check(
        EvalCheck.didNotCallTool('issue_refund'),
        result,
      );
      expect(called.passed, isFalse);
      expect(called.reason, contains('1 time'));
    });

    test('maxSteps and maxTokens are inclusive limits', () async {
      final result = resultWith('ok', steps: 3, tokens: 500);
      expect((await check(EvalCheck.maxSteps(3), result)).passed, isTrue);
      expect((await check(EvalCheck.maxSteps(2), result)).passed, isFalse);
      expect((await check(EvalCheck.maxTokens(500), result)).passed, isTrue);
      expect((await check(EvalCheck.maxTokens(499), result)).passed, isFalse);
    });

    test('custom returns the reason it gives', () async {
      final noApology = EvalCheck.custom(
        'does not apologise',
        (result) => result.text.contains('sorry') ? 'it apologised' : null,
      );
      expect((await check(noApology, resultWith('Done.'))).passed, isTrue);
      final failed = await check(noApology, resultWith('sorry, done.'));
      expect(failed.passed, isFalse);
      expect(failed.reason, 'it apologised');
      expect(failed.description, 'does not apologise');
    });
  });

  group('judgedBy', () {
    test('passes on the grader\'s verdict and keeps its reason', () async {
      final grader = FakeChatModel.text(
        '{"reason": "It confirms the refund politely.", "pass": true}',
      );
      final verdict = await check(
        EvalCheck.judgedBy(grader, rubric: 'Is the answer polite?'),
        resultWith('Your refund is on its way.', toolCalls: [refund('1042')]),
      );

      expect(verdict.passed, isTrue);
      expect(verdict.reason, 'It confirms the refund politely.');

      // The grader sees the rubric, the request, the tool calls and the answer.
      final prompt = grader.lastRequest.messages.last.text;
      expect(prompt, contains('Is the answer polite?'));
      expect(prompt, contains('Refund order 1042.'));
      expect(prompt, contains('issue_refund {"order":"1042"}'));
      expect(prompt, contains('Your refund is on its way.'));
      expect(grader.lastRequest.temperature, 0);
      expect(
        grader.lastRequest.responseFormat.kind,
        ResponseFormatKind.jsonSchema,
      );
    });

    test('fails on a negative verdict', () async {
      final verdict = await check(
        EvalCheck.judgedBy(
          FakeChatModel.text('{"reason": "It is curt.", "pass": false}'),
          rubric: 'Is the answer polite?',
        ),
        resultWith('Done.'),
      );
      expect(verdict.passed, isFalse);
      expect(verdict.reason, 'It is curt.');
    });

    test(
      'a grader that cannot answer fails the check, not the suite',
      () async {
        final unparseable = await check(
          EvalCheck.judgedBy(
            FakeChatModel.text('I think it was fine.'),
            rubric: 'Is the answer polite?',
          ),
          resultWith('Done.'),
        );
        expect(unparseable.passed, isFalse);
        expect(unparseable.reason, startsWith('the grader failed'));

        final offline = await check(
          EvalCheck.judgedBy(
            FakeChatModel.failing(
              ProviderException('overloaded', provider: 'fake'),
            ),
            rubric: 'Is the answer polite?',
          ),
          resultWith('Done.'),
        );
        expect(offline.passed, isFalse);
        expect(offline.reason, contains('overloaded'));
      },
    );
  });

  group('EvalSuite', () {
    EvalCase refundCase() => EvalCase.text(
      name: 'refund',
      prompt: 'Refund order 1042.',
      checks: [
        EvalCheck.calledTool('issue_refund'),
        EvalCheck.answerContains('1042'),
      ],
    );

    test('a run where every check holds passes', () async {
      final agent = ScriptedAgent([
        resultWith('Refunded 1042.', toolCalls: [refund('1042')]),
      ]);
      final report = await EvalSuite(
        name: 'support',
        cases: [refundCase()],
      ).run(agent);

      expect(report.passRate, 1);
      expect(report.failures, isEmpty);
      report.requirePassRate(1);
      expect(report.summary, startsWith('support: 100% passed (1/1 trials)'));
    });

    test('repeat measures how often a case passes', () async {
      final agent = ScriptedAgent([
        resultWith('Refunded 1042.', toolCalls: [refund('1042')]),
        resultWith('I cannot help with that.'),
        resultWith('Refunded 1042.', toolCalls: [refund('1042')]),
        resultWith('Refunded 1042.', toolCalls: [refund('1042')]),
      ]);
      final report = await EvalSuite(
        name: 'support',
        cases: [refundCase()],
      ).run(agent, repeat: 4);

      expect(report.cases.single.trials, hasLength(4));
      expect(report.cases.single.passed, 3);
      expect(report.passRate, 0.75);
      expect(report.failures.single.attempt, 1);
      expect(report.failures.single.failedChecks.map((c) => c.description), [
        'called `issue_refund`',
        'the answer contains "1042"',
      ]);

      report.requirePassRate(0.75);
      expect(
        () => report.requirePassRate(0.8),
        throwsA(
          isA<EvalFailedError>().having(
            (e) => e.toString(),
            'message',
            allOf(contains('required 80%'), contains('refund #1')),
          ),
        ),
      );
    });

    test(
      'an agent that throws fails its trial and the suite carries on',
      () async {
        final agent = ScriptedAgent([
          StateError('boom'),
          resultWith('Refunded 1042.', toolCalls: [refund('1042')]),
        ]);
        final report = await EvalSuite(
          name: 'support',
          cases: [refundCase()],
        ).run(agent, repeat: 2);

        expect(report.passRate, 0.5);
        final failed = report.failures.single;
        expect(failed.error, isA<StateError>());
        expect(failed.checks, isEmpty);
        expect(report.summary, contains('threw: Bad state: boom'));
      },
    );

    test('each trial runs in its own root context', () async {
      final agent = ScriptedAgent([resultWith('Refunded 1042.')]);
      await EvalSuite(
        name: 'support',
        cases: [
          EvalCase.text(
            name: 'a',
            prompt: 'x',
            checks: [EvalCheck.succeeded()],
          ),
        ],
      ).run(agent, repeat: 2);

      // A shared context would carry state such as budgets and
      // untrusted-content taint from one trial into the next.
      expect(agent.contexts, hasLength(2));
      expect(agent.contexts[0], isNotNull);
      expect(agent.contexts[0], isNot(same(agent.contexts[1])));
      expect(agent.contexts[0]!.runId, isNot(agent.contexts[1]!.runId));
    });

    test('concurrent trials are reported in case and attempt order', () async {
      final agent = ScriptedAgent([resultWith('ok')]);
      final report = await EvalSuite(
        name: 'support',
        cases: [
          for (final name in ['a', 'b', 'c'])
            EvalCase.text(
              name: name,
              prompt: name,
              checks: [EvalCheck.succeeded()],
            ),
        ],
      ).run(agent, repeat: 3, concurrency: 4);

      expect(report.cases.map((c) => c.name), ['a', 'b', 'c']);
      for (final c in report.cases) {
        expect(c.trials.map((t) => t.attempt), [0, 1, 2]);
        expect(c.trials.every((t) => t.caseName == c.name), isTrue);
      }
      expect(report.trials, hasLength(9));
    });

    test('reports render as Markdown and JSON', () async {
      final agent = ScriptedAgent([
        resultWith('Refunded 1042.', toolCalls: [refund('1042')], tokens: 40),
        resultWith('No.', tokens: 60),
      ]);
      final report = await EvalSuite(
        name: 'support',
        cases: [refundCase()],
      ).run(agent, repeat: 2);

      final markdown = report.toMarkdown();
      expect(markdown, contains('### support — 50%'));
      expect(markdown, contains('| refund | 1/2 | 50% |'));
      expect(markdown, contains('- refund #1: FAIL called `issue_refund`'));

      final json = report.toJson();
      expect(json['passRate'], 0.5);
      expect(json['totalTokens'], 100);
      final trials =
          ((json['cases']! as List).single as Map)['trials']! as List;
      expect((trials[1] as Map)['answer'], 'No.');
    });

    test('rejects a case with no checks and duplicate case names', () {
      expect(
        () => EvalCase.text(name: 'empty', prompt: 'x', checks: []),
        throwsA(isA<ConfigurationException>()),
      );
      expect(
        () => EvalSuite(name: 's', cases: [refundCase(), refundCase()]),
        throwsA(isA<ConfigurationException>()),
      );
    });

    test('works end to end on a real agent loop', () async {
      final model = FakeChatModel.toolCall(
        toolCalls: [refund('1042')],
        then: 'Refund for order 1042 is on its way.',
      );
      final agent = ToolCallingAgent(
        info: AgentInfo(name: 'support', description: 'Handles refunds.'),
        model: model,
      );
      // No tools registered: the call fails, and the model still answers.
      final report = await EvalSuite(
        name: 'support',
        cases: [
          EvalCase.text(
            name: 'refund',
            prompt: 'Refund order 1042.',
            checks: [
              EvalCheck.succeeded(),
              EvalCheck.calledTool('issue_refund'),
              EvalCheck.maxSteps(2),
            ],
          ),
        ],
      ).run(agent);

      expect(report.summary, contains('100%'));
    });
  });
}
