// Demonstrates the agent layer: a bounded tool-calling loop, streaming,
// sessions, budgets, delegation and planning.
//
// Run it with:
//
//     dart run example/agentic_agents_example.dart
//
// It runs offline against scripted models. Swap `_scripted(...)` for a real
// `ChatModel` and nothing else changes.
import 'dart:io';

import 'package:agentic_agents/agentic_agents.dart';
import 'package:agentic_core/agentic_core.dart';
import 'package:agentic_llm/agentic_llm.dart';
import 'package:agentic_llm/testing.dart';
import 'package:agentic_tools/agentic_tools.dart';

Future<void> main() async {
  // ---------------------------------------------------------------------------
  // 1. Tools the agent may use.
  // ---------------------------------------------------------------------------
  final registry = ToolRegistry()
    ..register(
      FunctionTool(
        name: 'search_web',
        description:
            'Searches the public web and returns the top results. Use for '
            'current events and facts that may have changed.',
        tags: {'research'},
        parameters: JsonSchema.object(
          properties: {
            'query': JsonSchema.string(description: 'The search query'),
          },
          required: {'query'},
        ),
        handler: (invocation) async => ToolResult.success(
          'Dart 3.11 shipped dot shorthands and a faster analyzer.',
        ),
      ),
    );

  // ---------------------------------------------------------------------------
  // 2. Observe every run. A cost meter or audit log binds here.
  // ---------------------------------------------------------------------------
  final events = BroadcastEventBus();
  events.on<AgenticEvent>().listen((event) {
    final detail = switch (event) {
      AgentRunStarted(:final agentName, :final toolCount) =>
        '$agentName started with $toolCount tools',
      AgentStepCompleted(:final stepIndex, :final toolCalls) =>
        'step $stepIndex${toolCalls.isEmpty ? '' : ' -> ${toolCalls.join(', ')}'}',
      AgentBudgetExhausted(:final explanation) => explanation,
      AgentDelegated(:final delegateName, :final depth) =>
        'delegated to $delegateName (depth $depth)',
      AgentRunCompleted(:final stopReason, :final iterations, :final usage) =>
        '${stopReason.name} after $iterations steps, ${usage.totalTokens} tokens',
      _ => null,
    };
    if (detail != null) print('  [${event.type}] $detail');
  });

  final context = AgenticContext.root(events: events, runId: 'example');

  // ---------------------------------------------------------------------------
  // 3. A tool-calling agent.
  // ---------------------------------------------------------------------------
  print('--- tool-calling agent ---');
  final researcher = ToolCallingAgent(
    info: AgentInfo(
      name: 'researcher',
      description: 'Researches technical topics using web search.',
    ),
    model: _scripted(<FakeTurn>[
      _toolCall('search_web', <String, Object?>{'query': 'Dart 3.11 release'}),
      _says('Dart 3.11 shipped dot shorthands and a faster analyzer.'),
    ]),
    tools: registry.select(tags: {'research'}),
    instructions: 'Cite what you found. Say so when you are unsure.',
    budget: AgentBudget.interactive,
  );

  final result = await researcher.run(
    AgentInput.text('What shipped in Dart 3.11?'),
    context: context,
  );
  print('answer     : ${result.text}');
  print('steps      : ${result.iterations}');
  print('tool calls : ${result.allToolCalls.map((c) => c.name).join(', ')}');
  print('tokens     : ${result.usage.totalTokens}');

  // ---------------------------------------------------------------------------
  // 4. The same agent, streamed. This is what a chat screen binds to.
  // ---------------------------------------------------------------------------
  print('\n--- streaming ---');
  final streamer = ToolCallingAgent(
    info: AgentInfo(name: 'streamer', description: 'Answers, streamed.'),
    model: _scripted(<FakeTurn>[
      _toolCall('search_web', <String, Object?>{'query': 'Flutter 3.41'}),
      _says('Flutter 3.41 shipped alongside Dart 3.11.'),
    ]),
    tools: registry.select(tags: {'research'}),
  );

  await for (final chunk in streamer.stream(
    AgentInput.text('And Flutter?'),
    context: context,
  )) {
    switch (chunk) {
      case AgentToolCallStarted(:final toolName, :final arguments):
        print('  using $toolName $arguments');
      case AgentToolCallFinished(:final toolName, :final summary):
        print('  $toolName -> $summary');
      case AgentTextDelta(:final text):
        stdout.write(text);
      case AgentFinished():
        stdout.writeln();
      default:
      // Other update kinds are ignored: `AgentChunk` is extensible, so a
      // default branch is required and correct.
    }
  }

  // ---------------------------------------------------------------------------
  // 5. Budgets. A loop that never stops is the failure mode this prevents.
  // ---------------------------------------------------------------------------
  print('\n--- budget ---');
  final stubborn = ToolCallingAgent(
    info: AgentInfo(name: 'stubborn', description: 'Never stops searching.'),
    // Always asks for another search, forever.
    model: _scripted(<FakeTurn>[
      _toolCall('search_web', <String, Object?>{'query': 'again'}),
    ]),
    tools: registry.select(tags: {'research'}),
    budget: const AgentBudget(maxIterations: 1),
  );

  final bounded = await stubborn.run(
    AgentInput.text('search forever'),
    context: context,
  );
  print('stop reason: ${bounded.stopReason.name}');
  print('dimension  : ${bounded.budgetDimension?.name}');
  print('answer     : ${bounded.text}');

  // ---------------------------------------------------------------------------
  // 6. Sessions carry the conversation between runs.
  // ---------------------------------------------------------------------------
  print('\n--- session ---');
  final chat = ToolCallingAgent(
    info: AgentInfo(name: 'assistant', description: 'A chat assistant.'),
    model: _scripted(<FakeTurn>[
      _says('Dart is a language for building apps.'),
      _says('It has sound null safety and records.'),
    ]),
  );
  final session = AgentSession(strategy: const SlidingWindowHistory());

  print('turn 1     : ${await chat.ask('What is Dart?', session: session)}');
  print('turn 2     : ${await chat.ask('Its type system?', session: session)}');
  print(
    'history    : ${session.history.length} messages, '
    '${session.totalUsage.totalTokens} tokens across ${session.runCount} runs',
  );

  // ---------------------------------------------------------------------------
  // 7. Delegation. A supervisor's tools are other agents.
  // ---------------------------------------------------------------------------
  print('\n--- delegation ---');
  final writer = ToolCallingAgent(
    info: AgentInfo(name: 'writer', description: 'Turns notes into prose.'),
    model: _scripted(<FakeTurn>[_says('Dart 3.11 is a solid release.')]),
  );
  final supervisor = supervisorOver(
    model: _scripted(<FakeTurn>[
      _toolCall('writer', <String, Object?>{
        'task': 'Write one sentence about Dart 3.11.',
      }),
      _says('Here is the summary: Dart 3.11 is a solid release.'),
    ]),
    members: <Agent>[researcher, writer],
  );

  final delegated = await supervisor.run(
    AgentInput.text('Summarise the release'),
    context: context,
  );
  print('answer     : ${delegated.text}');

  // ---------------------------------------------------------------------------
  // 8. Plan first, then execute. For work whose shape is knowable up front.
  // ---------------------------------------------------------------------------
  print('\n--- planner/executor ---');
  final analyst = PlannerExecutorAgent(
    info: AgentInfo(name: 'analyst', description: 'Researches and reports.'),
    planner: _scripted(<FakeTurn>[
      _says(
        '{"summary":"Check both releases",'
        '"steps":[{"description":"Look up Dart 3.11"},'
        '{"description":"Look up Flutter 3.41"}]}',
      ),
      _says('Both shipped together in early 2026.'),
    ]),
    executor: ToolCallingAgent(
      info: AgentInfo(name: 'worker', description: 'Carries out one step.'),
      model: _scripted(<FakeTurn>[_says('a finding')]),
      tools: registry.select(tags: {'research'}),
    ),
  );

  await for (final chunk in analyst.stream(
    AgentInput.text('Compare the latest Dart and Flutter releases'),
    context: context,
  )) {
    switch (chunk) {
      case AgentPlanReady(:final plan):
        print('  plan: ${plan.summary}');
        for (final step in plan.steps) {
          print('    - ${step.description}');
        }
      case AgentPlanStepStarted(:final index, :final total):
        print('  running step ${index + 1}/$total');
      case AgentFinished(:final result):
        print('answer     : ${result.text}');
      default:
    }
  }

  await events.dispose();
  await registry.dispose();
}

// -----------------------------------------------------------------------------
// Scripted models, so the example runs offline and deterministically.
// -----------------------------------------------------------------------------

ChatModel _scripted(List<FakeTurn> turns) => FakeChatModel(
  turns: turns,
  info: ModelInfo(
    id: 'scripted',
    provider: 'example',
    capabilities: ModelCapabilities.frontier,
  ),
);

FakeTurn _says(String text) => FakeTurn.answer(
  ChatResponse(
    message: Message.assistant(text),
    modelId: 'scripted',
    usage: const TokenUsage(promptTokens: 40, completionTokens: 12),
  ),
);

FakeTurn _toolCall(String name, Map<String, Object?> arguments) =>
    FakeTurn.answer(
      ChatResponse(
        message: Message.assistant(
          '',
          toolCalls: <ToolCallPart>[
            ToolCallPart(id: 'call_$name', name: name, arguments: arguments),
          ],
        ),
        modelId: 'scripted',
        finishReason: FinishReason.toolCalls,
        usage: const TokenUsage(promptTokens: 60, completionTokens: 18),
      ),
    );
