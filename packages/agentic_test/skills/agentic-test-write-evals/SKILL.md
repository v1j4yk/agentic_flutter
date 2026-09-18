---
name: agentic-test-write-evals
description: >-
  Use when checking whether an agent behaves well rather than whether code
  compiles, with agentic_test: EvalSuite, EvalCase, the EvalCheck family
  including LLM-as-judge, repeats and pass rates, and gating CI on a threshold.
  Read this for "test agent quality", "did my prompt change make things worse",
  or "assert the agent used the right tool".
license: MIT
metadata:
  package: agentic_test
  min-version: 0.2.0
---

# Evals

## Why a unit test is not enough

An agent's output is not deterministic, so asserting an exact string either
fails constantly or tests nothing. An eval asks a weaker, more useful question:
across a set of realistic inputs, how often does the agent do the right thing?
That number is what tells you whether a prompt change helped.

```dart
final suite = EvalSuite(
  name: 'support agent',
  cases: [
    EvalCase.text(
      name: 'refund needs the order first',
      prompt: 'I was charged twice for order 42',
      checks: [
        const EvalCheck.succeeded(),
        const EvalCheck.calledTool('lookup_order'),
        EvalCheck.calledTool('issue_refund', where: (args) => args['orderId'] == '42'),
        const EvalCheck.answerContains('refund'),
        const EvalCheck.maxSteps(6),
      ],
    ),
    EvalCase.text(
      name: 'does not refund without an order',
      prompt: 'Just give me my money back',
      checks: [const EvalCheck.didNotCallTool('issue_refund')],
    ),
  ],
);

final report = await suite.run(agent, repeat: 3, concurrency: 2);
print(report.summary);
report.requirePassRate(0.9);     // throws below the threshold — this is the gate
```

## The checks

| Check | Asserts |
|---|---|
| `EvalCheck.succeeded()` | the run finished rather than failing or exhausting a budget |
| `EvalCheck.answerContains('…')` | a substring, optionally case-sensitive |
| `EvalCheck.answerMatches(RegExp(…))` | a pattern |
| `EvalCheck.calledTool('name', where: …)` | a tool ran, optionally with matching arguments |
| `EvalCheck.didNotCallTool('name')` | it stayed away from something dangerous |
| `EvalCheck.maxSteps(6)` / `maxTokens(20000)` | it did not wander |
| `EvalCheck.judgedBy(model, rubric: '…')` | a model scores the answer |
| `EvalCheck.custom('…', (result) async => …)` | anything else; return null to pass, a reason to fail |

The negative checks matter most. "Did not issue a refund without an order" is a
safety property, and safety properties are what an eval suite is really for.

## LLM as judge, used carefully

```dart
EvalCheck.judgedBy(
  cheapModel,
  rubric: 'Does the answer state the refund timeline and apologise, '
      'without promising a specific date?',
);
```

Rules that make judging useful rather than decorative:

- **One question per rubric.** A rubric asking three things returns one blurry
  verdict.
- **Ask for a property, not a preference.** "Cites at least one source" is
  checkable; "is helpful" is not.
- **Use a cheap model**, and remember every case now costs two calls.
- **Spot-check the judge.** Read ten verdicts by hand before trusting the
  number.

Prefer a deterministic check whenever one exists: `calledTool` costs nothing and
never has an opinion.

## Repeats, and what a pass rate means

```dart
await suite.run(agent, repeat: 5);
report.passRate;              // across every trial
report.cases;                 // per case, with its own pass rate
report.failures;              // the trials that failed, with their checks
report.toMarkdown();          // paste into a PR
```

One run of a non-deterministic system is an anecdote. `repeat: 3` or `5` turns
it into a measurement, and a case that passes three times out of five is
*flaky* — which is information about the agent, not noise to be rounded away.

Set the threshold where it is honest. A suite gated at 100 % on a probabilistic
system will be disabled within a month.

## Making it cheap enough to run often

Combine evals with cassettes: record once, then the suite replays offline for
free and deterministically. That is what makes it viable in CI.

```dart
final agent = ToolCallingAgent(
  info: info,
  model: cassetteModel('test/cassettes/support.json', live: () => liveModel),
  tools: registry.all,
  budget: AgentBudget.interactive,
);
```

Then run the live version on a schedule, not on every pull request.

## Growing the suite

The best cases are real failures. When someone reports the agent doing
something wrong, add the case *before* fixing it: the eval proves the fix, and
then stops it coming back. Ten cases from real complaints beat a hundred
invented ones.

## Common mistakes

- Asserting exact answer text, which fails on wording the model is free to
  choose.
- `repeat: 1` and then reasoning about the pass rate.
- Only positive checks, so nothing tests the dangerous paths.
- A judge rubric that asks for "a good answer".
- Running an expensive suite live on every commit, so it gets turned off.

## See also

- `agentic-test-record-and-replay` — making a suite free to re-run
- `agentic-agents-build-tool-calling-agent` — the agent under evaluation
- `agentic-tools-write-a-tool` — the tools the checks assert on
