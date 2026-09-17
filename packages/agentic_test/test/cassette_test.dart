import 'dart:io';

import 'package:agentic_agents/agentic_agents.dart';
import 'package:agentic_core/agentic_core.dart';
import 'package:agentic_llm/agentic_llm.dart';
import 'package:agentic_llm/testing.dart';
import 'package:agentic_test/agentic_test.dart';
import 'package:agentic_tools/agentic_tools.dart';
import 'package:test/test.dart';

/// Stands in for a real provider: a tool call, then an answer that uses it.
FakeChatModel liveModel({String answer = 'Order 1042 shipped on Monday.'}) =>
    FakeChatModel.toolCall(
      toolCalls: [
        ToolCallPart(
          id: 'call_7',
          name: 'order_status',
          arguments: const {'order': '1042'},
        ),
      ],
      then: answer,
      info: ModelInfo(
        id: 'gemini-2.5-flash',
        provider: 'gemini',
        capabilities: const {
          ModelCapability.toolCalling,
          ModelCapability.structuredOutput,
        },
        contextWindow: 1000000,
      ),
    );

({ToolSet tools, List<String> lookups}) orderTools() {
  final lookups = <String>[];
  final tool = FunctionTool.text(
    name: 'order_status',
    description: 'Looks up the status of an order.',
    parameters: JsonSchema.object(
      properties: {'order': JsonSchema.string()},
      required: {'order'},
    ),
    isReadOnly: true,
    handler: (invocation) {
      final order = invocation.require<String>('order');
      lookups.add(order);
      return 'Order $order: shipped Monday.';
    },
  );
  return (tools: (ToolRegistry()..register(tool)).all, lookups: lookups);
}

ToolCallingAgent agentOn(
  ChatModel model, {
  ToolSet? tools,
  String instructions = 'You answer questions about orders.',
}) => ToolCallingAgent(
  info: AgentInfo(name: 'support', description: 'Answers order questions.'),
  model: model,
  tools: tools ?? orderTools().tools,
  instructions: instructions,
);

void main() {
  late Directory temp;

  setUp(() => temp = Directory.systemTemp.createTempSync('agentic_test_'));
  tearDown(() => temp.deleteSync(recursive: true));

  group('record and replay', () {
    test('a replayed run gives the recorded answer and runs the tools '
        'again', () async {
      final live = liveModel();
      final recorder = RecordingChatModel(live);
      final recorded = await agentOn(recorder).ask('Where is order 1042?');
      expect(recorder.cassette.interactions, hasLength(2));

      final replay = ReplayChatModel(
        Cassette.parse(recorder.cassette.encode()),
      );
      final tools = orderTools();
      final replayed = await agentOn(
        replay,
        tools: tools.tools,
      ).ask('Where is order 1042?');

      expect(replayed, recorded);
      expect(replayed, 'Order 1042 shipped on Monday.');
      // The tools are the code under test; only the model is recorded.
      expect(tools.lookups, ['1042']);
      expect(live.callCount, 2, reason: 'replay never reached the live model');
      replay.verifyExhausted();
    });

    test('replay keeps the recorded model information', () async {
      final recorder = RecordingChatModel(liveModel());
      await agentOn(recorder).ask('Where is order 1042?');

      final replay = ReplayChatModel(
        Cassette.parse(recorder.cassette.encode()),
      );
      expect(replay.info.id, 'gemini-2.5-flash');
      expect(replay.info.provider, 'gemini');
      expect(replay.info.contextWindow, 1000000);
      // Capability checks must take the branches they took while recording.
      expect(replay.info.supports(ModelCapability.structuredOutput), isTrue);
      expect(replay.info.supports(ModelCapability.vision), isFalse);
    });

    test('streaming is recorded once finished, and replays the same '
        'response', () async {
      final recorder = RecordingChatModel(liveModel());
      final request = ChatRequest.prompt('Where is order 1042?');
      final streamed = await recorder.stream(request).collect();
      expect(recorder.cassette.interactions, hasLength(1));

      final replay = ReplayChatModel(
        Cassette.parse(recorder.cassette.encode()),
      );
      final replayed = await replay.stream(request).collect();
      expect(replayed.toolCalls.single.name, 'order_status');
      expect(replayed.toolCalls.single.arguments, {'order': '1042'});
      expect(replayed.toolCalls.single.id, streamed.toolCalls.single.id);
      expect(replayed.finishReason, streamed.finishReason);
      expect(replayed.usage, streamed.usage);
    });

    test('a failed live call records nothing', () async {
      final recorder = RecordingChatModel(
        FakeChatModel.failing(
          RateLimitException('slow down', provider: 'gemini'),
        ),
      );
      await expectLater(
        recorder.generate(ChatRequest.prompt('hi')),
        throwsA(isA<RateLimitException>()),
      );
      expect(recorder.cassette.interactions, isEmpty);
    });

    test(
      'identifiers, timestamps and metadata do not affect matching',
      () async {
        final recorder = RecordingChatModel(FakeChatModel.text('Hello.'));
        await recorder.generate(
          ChatRequest(
            messages: [Message.user('hi', id: 'm-1')],
            metadata: const {'feature': 'a'},
          ),
        );
        final replay = ReplayChatModel(recorder.cassette);

        final response = await replay.generate(
          ChatRequest(
            messages: [
              Message(
                role: MessageRole.user,
                parts: const [TextPart('hi')],
                id: 'm-2',
                createdAt: DateTime.utc(2030),
                metadata: const {'draft': true},
              ),
            ],
            metadata: const {'feature': 'b'},
          ),
        );
        expect(response.text, 'Hello.');
        expect(response.metadata, {'feature': 'b'});
      },
    );

    test('the key order of a map does not affect matching', () async {
      final recorder = RecordingChatModel(FakeChatModel.text('Hello.'));
      await recorder.generate(
        ChatRequest(
          messages: [Message.user('hi')],
          providerOptions: const {'safety': 'low', 'cache': true},
        ),
      );
      final replay = ReplayChatModel(
        Cassette.parse(recorder.cassette.encode()),
      );
      final response = await replay.generate(
        ChatRequest(
          messages: [Message.user('hi')],
          providerOptions: const {'cache': true, 'safety': 'low'},
        ),
      );
      expect(response.text, 'Hello.');
    });

    test('requests made in a different order still match', () async {
      final live = FakeChatModel(
        turns: [
          for (final text in ['one', 'two', 'three'])
            FakeTurn.answer(
              ChatResponse(message: Message.assistant(text), modelId: 'm'),
            ),
        ],
      );
      final recorder = RecordingChatModel(live);
      for (final q in ['a', 'b', 'c']) {
        await recorder.generate(ChatRequest.prompt(q));
      }

      final replay = ReplayChatModel(recorder.cassette);
      final answers = await Future.wait([
        for (final q in ['c', 'a', 'b']) replay.generate(ChatRequest.prompt(q)),
      ]);
      expect(answers.map((r) => r.text), ['three', 'one', 'two']);
    });
  });

  group('mismatches', () {
    Future<ReplayChatModel> recordedAgentRun() async {
      final recorder = RecordingChatModel(liveModel());
      await agentOn(recorder).ask('Where is order 1042?');
      return ReplayChatModel(Cassette.parse(recorder.cassette.encode()));
    }

    test('a changed prompt fails and names the difference', () async {
      final replay = await recordedAgentRun();
      final agent = agentOn(
        replay,
        instructions: 'You answer questions about refunds.',
      );

      final result = agent.run(AgentInput.text('Where is order 1042?'));
      await expectLater(
        result,
        throwsA(
          isA<CassetteMismatchError>()
              .having((e) => e.message, 'message', contains('messages[0]'))
              .having((e) => e.message, 'message', contains('about orders.'))
              .having((e) => e.message, 'message', contains('about refunds.')),
        ),
      );
    });

    test('a changed tool description fails', () async {
      final replay = await recordedAgentRun();
      final tool = FunctionTool.text(
        name: 'order_status',
        description: 'Finds an order.',
        parameters: JsonSchema.object(
          properties: {'order': JsonSchema.string()},
          required: {'order'},
        ),
        handler: (_) => 'shipped',
      );
      await expectLater(
        agentOn(
          replay,
          tools: (ToolRegistry()..register(tool)).all,
        ).run(AgentInput.text('Where is order 1042?')),
        throwsA(
          isA<CassetteMismatchError>().having(
            (e) => e.message,
            'message',
            contains('tools[0].description'),
          ),
        ),
      );
    });

    test('asking more often than recorded fails', () async {
      final recorder = RecordingChatModel(FakeChatModel.text('Hello.'));
      await recorder.generate(ChatRequest.prompt('hi'));
      final replay = ReplayChatModel(recorder.cassette);

      await replay.generate(ChatRequest.prompt('hi'));
      await expectLater(
        replay.generate(ChatRequest.prompt('hi')),
        throwsA(
          isA<CassetteMismatchError>().having(
            (e) => e.message,
            'message',
            contains('already been replayed'),
          ),
        ),
      );
    });

    test('verifyExhausted catches a run that now stops early', () async {
      final recorder = RecordingChatModel(FakeChatModel.text('Hello.'));
      await recorder.generate(ChatRequest.prompt('first'));
      await recorder.generate(ChatRequest.prompt('second'));
      final replay = ReplayChatModel(recorder.cassette);

      await replay.generate(ChatRequest.prompt('first'));
      expect(replay.remaining, 1);
      expect(replay.verifyExhausted, throwsA(isA<CassetteMismatchError>()));

      await replay.generate(ChatRequest.prompt('second'));
      replay.verifyExhausted();
    });

    test('an empty cassette says so', () async {
      final replay = ReplayChatModel(
        Cassette(
          model: ModelInfo(id: 'm', provider: 'p'),
        ),
      );
      await expectLater(
        replay.generate(ChatRequest.prompt('hi')),
        throwsA(
          isA<CassetteMismatchError>().having(
            (e) => e.message,
            'message',
            contains('empty'),
          ),
        ),
      );
    });
  });

  group('redaction', () {
    String redact(String text) =>
        text.replaceAll(RegExp(r'sk-[A-Za-z0-9]+'), '<key>');

    test('secrets never reach the file, and redacted requests still '
        'match', () async {
      final recorder = RecordingChatModel(
        FakeChatModel.text('Your key sk-abc123 is valid.'),
        redact: redact,
      );
      await recorder.generate(ChatRequest.prompt('Is sk-abc123 valid?'));

      final file = recorder.cassette.encode();
      expect(file, isNot(contains('sk-abc123')));
      expect(file, contains('<key>'));

      final replay = ReplayChatModel(Cassette.parse(file), redact: redact);
      final response = await replay.generate(
        ChatRequest.prompt('Is sk-zzz999 valid?'),
      );
      expect(response.text, 'Your key <key> is valid.');
    });
  });

  group('cassetteModel', () {
    test('records the first run to disk, then replays without the live '
        'model', () async {
      final path = '${temp.path}/nested/support.json';
      var built = 0;

      final first = cassetteModel(
        path,
        live: () {
          built++;
          return liveModel();
        },
        environment: const {},
      );
      expect(first, isA<RecordingChatModel>());
      await agentOn(first).ask('Where is order 1042?');
      expect(File(path).existsSync(), isTrue);

      final second = cassetteModel(
        path,
        live: () => fail('replay must not construct the live model'),
        environment: const {},
      );
      expect(second, isA<ReplayChatModel>());
      expect(
        await agentOn(second).ask('Where is order 1042?'),
        'Order 1042 shipped on Monday.',
      );
      expect(built, 1);
    });

    test('AGENTIC_RECORD=1 records again from an empty cassette', () async {
      final path = '${temp.path}/support.json';
      await agentOn(
        cassetteModel(path, live: liveModel, environment: const {}),
      ).ask('Where is order 1042?');

      final again = cassetteModel(
        path,
        live: () => liveModel(answer: 'It shipped.'),
        environment: const {'AGENTIC_RECORD': '1'},
      );
      expect(again, isA<RecordingChatModel>());
      await agentOn(again).ask('Where is order 1042?');

      final cassette = Cassette.parse(File(path).readAsStringSync());
      expect(cassette.interactions, hasLength(2), reason: 'not appended');
      expect(cassette.encode(), contains('It shipped.'));
      expect(cassette.encode(), isNot(contains('shipped on Monday')));
    });

    test('replay mode fails on a missing cassette instead of calling the '
        'network', () {
      expect(
        () => cassetteModel(
          '${temp.path}/missing.json',
          live: () => fail('must not be built'),
          mode: CassetteMode.replay,
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('AGENTIC_RECORD=1'),
          ),
        ),
      );
    });

    test('record mode ignores an existing cassette', () {
      final path = '${temp.path}/support.json';
      File(path).writeAsStringSync(
        Cassette(
          model: ModelInfo(id: 'm', provider: 'p'),
        ).encode(),
      );
      expect(
        cassetteModel(path, live: liveModel, mode: CassetteMode.record),
        isA<RecordingChatModel>(),
      );
    });
  });

  group('Cassette format', () {
    test('rejects a file that is not a cassette', () {
      expect(
        () => Cassette.parse('{"format": "vcr", "version": 1}'),
        throwsA(isA<SerializationException>()),
      );
      expect(
        () => Cassette.parse('not json'),
        throwsA(isA<SerializationException>()),
      );
    });

    test('rejects a cassette from a newer format version', () {
      expect(
        () => Cassette.parse(
          '{"format": "agentic_cassette", "version": 99, '
          '"model": {"id": "m", "provider": "p"}, "interactions": []}',
        ),
        throwsA(
          isA<SerializationException>().having(
            (e) => e.message,
            'message',
            contains('Upgrade agentic_test'),
          ),
        ),
      );
    });

    test('skips a capability this version does not know', () {
      final cassette = Cassette.parse(
        '{"format": "agentic_cassette", "version": 1, '
        '"model": {"id": "m", "provider": "p", '
        '"capabilities": ["toolCalling", "telepathy"]}, "interactions": []}',
      );
      expect(cassette.model.capabilities, {ModelCapability.toolCalling});
    });

    test('does not store latency or the raw provider payload', () async {
      final recorder = RecordingChatModel(
        FakeChatModel(
          turns: [
            FakeTurn.answer(
              ChatResponse(
                message: Message.assistant('hi'),
                modelId: 'm',
                latency: const Duration(milliseconds: 812),
                raw: const {'x-secret-header': 'value'},
              ),
            ),
          ],
        ),
      );
      await recorder.generate(ChatRequest.prompt('hi'));
      final file = recorder.cassette.encode();
      expect(file, isNot(contains('812')));
      expect(file, isNot(contains('x-secret-header')));
    });
  });
}
