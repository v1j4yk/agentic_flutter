---
name: agentic-test-record-and-replay
description: >-
  Use when testing code that calls a model, with agentic_test: cassettes that
  record a real answer once and replay it offline, cassetteModel, CassetteMode,
  redacting keys before anything is written to disk, and FakeChatModel for
  answers you script yourself. Read this for "test my agent without paying",
  "deterministic tests for LLM code", or a cassette mismatch error.
license: MIT
metadata:
  package: agentic_test
  min-version: 0.2.0
---

# Recording and replaying model answers

## Two ways to avoid calling a provider in a test

| | Use | When |
|---|---|---|
| **Fake** | `FakeChatModel` (`package:agentic_llm/testing.dart`) | you decide what the model says: tool call, then an answer |
| **Cassette** | `agentic_test` | you want what the *real* model actually said, replayed offline |

Fakes test your logic. Cassettes test your logic against real model behaviour —
the awkward phrasing, the surprising tool choice, the malformed arguments — and
keep it stable in CI.

## A cassette in one line

```dart
import 'package:agentic_test/agentic_test.dart';

final model = cassetteModel(
  'test/cassettes/refund_flow.json',
  live: () => GeminiChatModel(apiKey: Platform.environment['GEMINI_API_KEY']!),
  mode: CassetteMode.auto,
);
```

`CassetteMode.auto` is the mode to use: replay if the file exists, otherwise
call the live model and record it. So the first run costs money and every run
after it is free and deterministic. `record` forces a re-record, `replay`
forbids live calls — which is what CI should set, so a missing cassette fails
instead of quietly spending.

Commit cassettes. They are the fixture.

## Redaction happens before anything is written

```dart
cassetteModel(
  path,
  live: () => model,
  redact: (text) => text.replaceAll(RegExp(r'sk-[A-Za-z0-9]{20,}'), 'sk-REDACTED'),
);
```

Cassettes contain prompts and answers, which means they can contain keys, names
and personal data. `redact` runs on the way in, so the secret never reaches the
file. Review the first recording by eye before committing it — that is the
cheapest privacy review you will ever do.

## Using the halves directly

```dart
final recorder = RecordingChatModel(liveModel, onRecorded: (c) => file.writeAsStringSync(c.encode()));
final player = ReplayChatModel(Cassette.parse(file.readAsStringSync()));

player.remaining;          // interactions not yet replayed
player.verifyExhausted();  // fails the test if the code made fewer calls than recorded
```

`verifyExhausted()` is the assertion people forget. A refactor that skips a
model call still passes every other check; this is what catches it.

## When a cassette stops matching

`CassetteMismatchError` means the request no longer matches what was recorded —
you changed the prompt, the tools, or the history. That is information, not an
obstacle: the prompt changed, so the recorded answer may no longer be
representative. Re-record with `CassetteMode.record`, read the diff, and commit
it as a deliberate change.

## Scripting a fake instead

```dart
import 'package:agentic_llm/testing.dart';

final model = FakeChatModel(turns: [
  // Turn one: ask for a tool.
  FakeTurn.answer(ChatResponse(
    message: Message.assistant('', toolCalls: [
      ToolCallPart(id: 'call_1', name: 'get_weather', arguments: {'city': 'Lisbon'}),
    ]),
    modelId: 'fake-model',
    finishReason: FinishReason.toolCalls,
  )),
  // Turn two: answer with what the tool returned.
  FakeTurn.answer(ChatResponse(
    message: Message.assistant('It is 21 °C in Lisbon.'),
    modelId: 'fake-model',
  )),
]);
```

The last turn repeats once the script is exhausted, so a test does not break
when the loop runs one extra iteration. `FakeChatModel.text('…')` is the
one-liner.

## What to test at which level

- **Unit** — tools, schemas, policies: no model at all.
- **Component** — the agent loop against `FakeChatModel`: does it stop, respect
  budgets, ask for approval?
- **Cassette** — the same loop against a real recorded model: does the prompt
  actually produce the tool call you expect?
- **Live** — opt-in, never in CI: `agentic_integration` runs these nightly.

## Common mistakes

- Recording with a real key and committing without reading the file.
- `CassetteMode.auto` in CI, so a missing cassette silently makes live calls —
  set `replay` there.
- Never calling `verifyExhausted()`, so a skipped model call passes.
- Treating a mismatch as a tooling problem rather than a signal that the prompt
  changed.
- Testing only with fakes, so the prompts are never exercised against a model
  until production.

## See also

- `agentic-test-write-evals` — scoring behaviour rather than asserting exact text
- `agentic-agents-build-tool-calling-agent` — the loop under test
- `agentic-llm-choose-provider` — the live model being recorded
