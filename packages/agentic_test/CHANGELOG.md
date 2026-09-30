# Changelog

## 0.3.0

### Added

- `EvalCheck.trajectory`, with `ToolStep` and `TrajectoryMatch`: assert the
  *order* tools ran in, not only that they ran. `inOrder` by default, because
  an agent that also called something else is odd rather than wrong; `exact`
  and `anyOrder` for the cases where that is the contract. Arguments are
  contained rather than equal, so an extra optional argument does not fail a
  check.
- `EvalReport.toJUnitXml()`, so eval failures appear in CI beside unit-test
  failures rather than in a log. One entry per trial, so a case that passes
  four times in five reads as flaky instead of as a pass.
- `EvalReport.fromJson`, `EvalReport.compareTo`, `EvalComparison` and
  `EvalRegressionError`: store a report as a baseline, and fail a build when
  the pass rate falls by more than a tolerance. The tolerance exists because a
  gate that fires on ordinary variance is a gate that gets disabled.
  `EvalComparison.missing` names cases the baseline had and this run did not —
  the quiet way a suite stops testing something.
- `EvalCaseReport.summary`, the numbers-without-transcripts form a stored
  baseline restores to.

### Changed

- `EvalReport.passRate` is counted per case rather than by walking trials, so a
  report restored from a baseline reports the rate it was saved with instead of
  zero.

## 0.2.0

- Released with the rest of the framework at 0.2.0, which it now
  depends on. No changes to this package's API or behaviour.

## 0.1.2

Initial release. The version follows the sibling packages it ships with.

- Cassettes. `RecordingChatModel` records a real model's answers,
  `ReplayChatModel` plays them back offline, and `cassetteModel` chooses
  between them: it records when the file is missing or `AGENTIC_RECORD=1` is
  set, and replays otherwise. Replay fails with a `CassetteMismatchError`
  naming the first difference when a prompt or tool changes, and
  `verifyExhausted` catches a run that makes fewer calls. A `Redactor` keeps
  secrets out of the file.
- Evals. `EvalSuite` runs `EvalCase`s repeatedly against an agent and reports
  pass rates. Checks cover success, answer text, tools called and not called,
  step and token limits, custom functions, and a model-graded rubric.
  `EvalReport` renders as a summary, Markdown or JSON, and `requirePassRate`
  turns it into a test assertion.
