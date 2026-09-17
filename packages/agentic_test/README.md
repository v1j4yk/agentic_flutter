# agentic_test

Testing for agents built on the [agentic framework](https://github.com/v1j4yk/agentic_flutter).
Record real model answers once and replay them offline, and score agent
behaviour with evals.

```yaml
dev_dependencies:
  agentic_test: ^0.2.0
```

An agent test usually has two bad options. Call a real provider, and the test
is slow, costs money, needs a key in CI and fails when the model has an off day.
Script a fake, and the test only proves the agent handles the answers you
imagined. This package adds two better options.

## Cassettes: real answers, recorded once

```dart
import 'dart:io';

import 'package:agentic_test/agentic_test.dart';
import 'package:test/test.dart';

test('answers order questions', () async {
  final model = cassetteModel(
    'test/cassettes/order_status.json',
    live: () => GeminiChatModel(apiKey: Platform.environment['GEMINI_API_KEY']!),
  );
  final agent = ToolCallingAgent(info: info, model: model, tools: tools);

  expect(await agent.ask('Where is order 1042?'), contains('1042'));
});
```

The first run has no cassette. It calls Gemini and writes every request and
answer to the file. Commit the file. Every run after that replays it: no
network, no key, no cost, and the same answer every time.

Only the model is recorded. Your tools, prompts, and message handling still
run for real on every replay.

| Situation | What happens |
|---|---|
| Cassette missing | Records (`CassetteMode.auto`, the default) |
| `AGENTIC_RECORD=1` set | Records again from an empty cassette |
| `mode: CassetteMode.replay` | Never touches the network, and fails if the cassette is missing. Use this in CI. |
| A prompt or tool description changed | `CassetteMismatchError` names the first difference |
| The agent now makes more calls | `CassetteMismatchError` |
| The agent now makes fewer calls | `replay.verifyExhausted()` throws |

A mismatch shows exactly what changed:

```text
No recorded exchange matches this request. Compared with recording #0:
First difference at $.messages[0].parts[0].text:
  recorded: "You answer questions about orders."
  actual:   "You answer questions about refunds."
If the change is intended, record the cassette again.
```

Requests are matched on everything that shapes the answer: messages, tools,
sampling settings and response format. Message IDs, timestamps and metadata
are ignored, because they change on every run. Matching doesn't depend on
order, so agents that call the model concurrently replay reliably.

### Keep secrets out of the file

Provider keys travel in HTTP headers, and cassettes never record headers. Text
inside the conversation is recorded, so pass a `redact` function for anything
that shouldn't be committed:

```dart
cassetteModel(
  path,
  live: buildModel,
  redact: (text) => text.replaceAll(RegExp(r'\b[\w.]+@[\w.]+\b'), '<email>'),
);
```

The same function runs on live requests before matching, so redacted text
still matches.

## Evals: how often does the agent get it right?

A unit test asserts one exact behaviour. An agent never writes the same
sentence twice, so an eval checks properties instead, and a suite measures how
often they hold.

```dart
final suite = EvalSuite(name: 'support', cases: [
  EvalCase.text(
    name: 'refund',
    prompt: 'Refund order 1042, it arrived broken.',
    checks: [
      const EvalCheck.succeeded(),
      EvalCheck.calledTool('issue_refund', where: (args) => args['order'] == '1042'),
      const EvalCheck.didNotCallTool('delete_account'),
      const EvalCheck.answerContains('1042'),
      const EvalCheck.maxSteps(4),
      EvalCheck.judgedBy(grader, rubric: 'Does the answer avoid promising a delivery date?'),
    ],
  ),
]);

final report = await suite.run(agent, repeat: 5);
print(report.toMarkdown());
report.requirePassRate(0.8);
```

| Check | Passes when |
|---|---|
| `succeeded()` | The run completed without failing, being cancelled or running out of budget |
| `answerContains(text)` / `answerMatches(pattern)` | The final answer contains the text or matches the pattern |
| `calledTool(name, where:)` | The tool was called, with matching arguments if `where` is given |
| `didNotCallTool(name)` | The tool was never called |
| `maxSteps(n)` / `maxTokens(n)` | The run stayed within the limit |
| `custom(description, fn)` | `fn` returns `null`; otherwise its return value is the failure reason |
| `judgedBy(model, rubric:)` | A grader model says the answer meets the rubric |

A model grader can be wrong. Ask it one yes-or-no question per rubric and rely
on the pass rate over repeated runs. A grader that errors fails the check
instead of aborting the suite. Each trial runs in a fresh context, so nothing
carries over between trials, including untrusted-content taint.

Run evals against a live model to measure a prompt change. Run them against a
cassette to catch regressions in CI for free. Repeating a run only tells you
something against a live model, because a cassette gives the same answer every
time.

## Related

- `FakeChatModel` in `package:agentic_llm/testing.dart` scripts exact answers
  and failures, like rate limits, that a cassette doesn't record.
- `FakeClock` in `package:agentic_core/testing.dart` controls time for budget
  and timeout tests.
