import 'package:agentic_core/agentic_core.dart';
import 'package:agentic_integration/agentic_integration.dart';
import 'package:agentic_llm/agentic_llm.dart';
import 'package:test/test.dart';

/// Tests for the harness, not for any provider.
///
/// These run in the ordinary suite and need no credentials, because the
/// mistake that costs most here is a harness that skips everything and reports
/// green — a suite that proves nothing while looking like it proved everything.
void main() {
  group('discovery', () {
    test('reports every provider it knows about, either way', () {
      final subjects = discoverSubjects();
      final named = <String>{
        ...subjects.available.map((s) => s.name),
        ...subjects.missing.map((m) => m.name),
      };

      expect(
        named,
        containsAll(<String>[
          'openai',
          'anthropic',
          'gemini',
          'deepseek',
          'ollama',
        ]),
        reason: 'a provider that appears in neither list is invisible',
      );
    });

    test('a provider is available or missing, never both', () {
      final subjects = discoverSubjects();
      final available = subjects.available.map((s) => s.name).toSet();
      final missing = subjects.missing.map((m) => m.name).toSet();
      expect(available.intersection(missing), isEmpty);
    });

    test('every missing entry says what to set', () {
      for (final missing in discoverSubjects().missing) {
        expect(
          missing.reason,
          contains('set '),
          reason:
              '"${missing.name}" should tell a reader how to enable it, not '
              'just that it is off',
        );
      }
    });

    test('describeMissing names each one', () {
      final subjects = discoverSubjects();
      final described = subjects.describeMissing();
      for (final missing in subjects.missing) {
        expect(described, contains(missing.name));
      }
    });
  });

  group('env', () {
    test('a blank variable counts as absent', () {
      // The failure this guards: an unset CI secret expands to the empty
      // string rather than being absent, so a `containsKey` check would report
      // a key that is not there as present — and the suite would run and fail
      // with a 401 instead of skipping.
      expect(env('AGENTIC_DEFINITELY_UNSET_VARIABLE'), isNull);
    });
  });

  group('the fixtures the suite calls with', () {
    test('the weather tool has a schema a model can satisfy', () {
      expect(weatherTool.name, 'lookup_weather');
      expect(
        weatherTool.parameters.validate(<String, Object?>{}).isValid,
        isFalse,
      );
      expect(
        weatherTool.parameters.validate(<String, Object?>{
          'city': 'Lisbon',
        }).isValid,
        isTrue,
      );
    });

    test('the two tools are distinguishable', () {
      expect(weatherTool.name, isNot(timeTool.name));
      expect(weatherTool.description, isNot(timeTool.description));
    });

    test('the person schema rejects a wrongly-typed answer', () {
      expect(
        personSchema.validate(<String, Object?>{
          'name': 'Ada',
          'age': 36,
        }).isValid,
        isTrue,
      );
      expect(
        personSchema.validate(<String, Object?>{
          'name': 'Ada',
          'age': 'thirty-six',
        }).isValid,
        isFalse,
        reason:
            'a schema that accepts a string age would pass a provider that '
            'does not really constrain its output',
      );
      expect(
        personSchema.validate(<String, Object?>{'name': 'Ada'}).isValid,
        isFalse,
      );
    });
  });

  group('ConformanceOutcome', () {
    test('distinguishes pass, fail and not-applicable', () {
      const passed = ConformanceOutcome(
        provider: 'p',
        check: 'c',
        passed: true,
      );
      const failed = ConformanceOutcome(
        provider: 'p',
        check: 'c',
        passed: false,
        detail: 'because',
      );
      const skipped = ConformanceOutcome(
        provider: 'p',
        check: 'c',
        passed: true,
        skipped: true,
      );

      expect(passed.toJson()['result'], 'pass');
      expect(failed.toJson()['result'], 'fail');
      expect(skipped.toJson()['result'], 'skipped');
      expect('$failed', contains('FAIL'));
      expect('$failed', contains('because'));
    });
  });

  group('the checks refuse a model that misbehaves', () {
    // The conformance suite is only worth having if it actually fails when a
    // provider breaks its contract. These run it against deliberately broken
    // fakes, which needs no network and no key.
    ProviderSubject subjectOf(ChatModel model) =>
        ProviderSubject(name: 'fake', createChat: () => model);

    test('an empty answer fails the completion check', () async {
      await expectLater(
        checkCompletion(subjectOf(_BrokenModel(text: ''))),
        throwsA(isA<StateError>()),
      );
    });

    test('a missing usage report fails it too', () async {
      // Usage drives every budget in the framework. A provider that stops
      // reporting it turns cost limits into no limits, silently.
      await expectLater(
        checkCompletion(
          subjectOf(_BrokenModel(text: 'ready', usage: TokenUsage.empty)),
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('tokens'),
          ),
        ),
      );
    });

    test(
      'a truncated answer reported as stop fails the length check',
      () async {
        await expectLater(
          checkLengthCap(
            subjectOf(
              _BrokenModel(text: 'The Roman Empire', finish: FinishReason.stop),
            ),
          ),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              contains('invisible'),
            ),
          ),
        );
      },
    );

    test('answering instead of calling a tool fails the tool check', () async {
      await expectLater(
        checkToolCalling(subjectOf(_BrokenModel(text: 'It is sunny.'))),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('no tool call'),
          ),
        ),
      );
    });

    test('a tool call with invalid arguments fails it', () async {
      await expectLater(
        checkToolCalling(
          subjectOf(
            _BrokenModel(
              finish: FinishReason.toolCalls,
              toolCalls: <ToolCallPart>[
                ToolCallPart(
                  id: 'c1',
                  name: 'lookup_weather',
                  // No `city`: exactly what a provider that mangles arguments
                  // produces, and what breaks the executor downstream.
                  arguments: const <String, Object?>{},
                ),
              ],
            ),
          ),
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('schema'),
          ),
        ),
      );
    });

    test('a tool call with no id fails it', () async {
      await expectLater(
        checkToolCalling(
          subjectOf(
            _BrokenModel(
              finish: FinishReason.toolCalls,
              toolCalls: <ToolCallPart>[
                ToolCallPart(
                  id: '',
                  name: 'lookup_weather',
                  arguments: const <String, Object?>{'city': 'Lisbon'},
                ),
              ],
            ),
          ),
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('correlated'),
          ),
        ),
      );
    });

    test('ignoring the system prompt fails that check', () async {
      await expectLater(
        checkSystemPrompt(subjectOf(_BrokenModel(text: 'Paris.'))),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('ignored'),
          ),
        ),
      );
    });

    test('duplicate call ids fail the parallel check', () async {
      await expectLater(
        checkParallelToolCalls(
          subjectOf(
            _BrokenModel(
              finish: FinishReason.toolCalls,
              toolCalls: <ToolCallPart>[
                ToolCallPart(
                  id: 'same',
                  name: 'lookup_weather',
                  arguments: const <String, Object?>{'city': 'Lisbon'},
                ),
                ToolCallPart(
                  id: 'same',
                  name: 'lookup_time',
                  arguments: const <String, Object?>{'city': 'Lisbon'},
                ),
              ],
            ),
          ),
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('duplicate'),
          ),
        ),
      );
    });

    test('a well-behaved fake passes the checks it should', () async {
      final good = _BrokenModel(text: 'ready');
      expect(await checkCompletion(subjectOf(good)), contains('tokens'));

      final caps = _BrokenModel(
        text: 'The Roman Empire',
        finish: FinishReason.length,
      );
      expect(await checkLengthCap(subjectOf(caps)), contains('length'));

      final acknowledges = _BrokenModel(text: 'ACKNOWLEDGED');
      expect(await checkSystemPrompt(subjectOf(acknowledges)), 'honoured');
    });

    test(
      'the audit collects failures instead of throwing on the first',
      () async {
        final outcomes = await auditProvider(
          subjectOf(_BrokenModel(text: 'nonsense')),
        );

        expect(outcomes, isNotEmpty);
        expect(
          outcomes.where((o) => !o.passed && !o.skipped),
          isNotEmpty,
          reason: 'a broken model should produce failures, not an exception',
        );
        // Every check is represented, whether it ran or was not applicable.
        expect(outcomes.map((o) => o.check), contains('completion'));
        expect(outcomes.map((o) => o.check), contains('badKeyMapping'));
      },
    );
  });
}

/// A model that answers however the test tells it to.
///
/// Not `FakeChatModel`: this needs to produce *wrong* answers on demand, which
/// is the opposite of what a well-behaved test double is for.
final class _BrokenModel implements ChatModel {
  _BrokenModel({
    this.text = '',
    this.finish = FinishReason.stop,
    this.toolCalls = const <ToolCallPart>[],
    this.usage = const TokenUsage(promptTokens: 10, completionTokens: 5),
  });

  final String text;
  final FinishReason finish;
  final List<ToolCallPart> toolCalls;
  final TokenUsage usage;

  @override
  ModelInfo get info => ModelInfo(
    id: 'broken',
    provider: 'fake',
    capabilities: ModelCapabilities.frontier,
  );

  @override
  Future<ChatResponse> generate(
    ChatRequest request, {
    AgenticContext? context,
  }) async => ChatResponse(
    message: Message.assistant(text, toolCalls: toolCalls),
    modelId: info.id,
    finishReason: finish,
    usage: usage,
  );

  @override
  Stream<ChatChunk> stream(
    ChatRequest request, {
    AgenticContext? context,
  }) async* {
    yield ChatChunk(textDelta: text);
  }

  @override
  Future<void> dispose() async {}
}
