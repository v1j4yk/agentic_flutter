// Records an agent's model calls once, replays them offline, then runs an
// eval suite over the replayed agent.
//
//   dart run example/agentic_test_example.dart
//
// A FakeChatModel stands in for the live provider so the example runs without
// a key. In a real test, `live:` builds a GeminiChatModel, AnthropicChatModel
// or OpenAiCompatibleChatModel instead.
import 'dart:io';

import 'package:agentic_agents/agentic_agents.dart';
import 'package:agentic_llm/agentic_llm.dart';
import 'package:agentic_llm/testing.dart';
import 'package:agentic_test/agentic_test.dart';

Future<void> main() async {
  final dir = Directory.systemTemp.createTempSync('agentic_test_example');
  final path = '${dir.path}${Platform.pathSeparator}support.json';

  ToolCallingAgent agentOn(ChatModel model) => ToolCallingAgent(
    info: AgentInfo(name: 'support', description: 'Answers order questions.'),
    model: model,
    instructions: 'You answer questions about orders. Quote the order number.',
  );

  // First run: no cassette yet, so the live model answers and is recorded.
  var liveCalls = 0;
  final recording = cassetteModel(
    path,
    live: () {
      liveCalls++;
      return FakeChatModel.text('Order 1042 shipped on Monday.');
    },
  );
  print('first run:  ${await agentOn(recording).ask('Where is order 1042?')}');

  // Every run after: the cassette answers. No network, no key, no cost.
  final replaying = cassetteModel(
    path,
    live: () => throw StateError('replay never builds the live model'),
  );
  print('second run: ${await agentOn(replaying).ask('Where is order 1042?')}');
  print('live model built $liveCalls time(s)\n');

  // Evals describe a good run as checks, and report how often they hold.
  final report = await EvalSuite(
    name: 'support',
    cases: [
      EvalCase.text(
        name: 'order status',
        prompt: 'Where is order 1042?',
        checks: [
          const EvalCheck.succeeded(),
          const EvalCheck.answerContains('1042'),
          const EvalCheck.didNotCallTool('cancel_order'),
          const EvalCheck.maxSteps(3),
        ],
      ),
    ],
  ).run(agentOn(cassetteModel(path, live: () => throw StateError('offline'))));

  print(report.toMarkdown());
  report.requirePassRate(1);

  dir.deleteSync(recursive: true);
}
