# Changelog

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
