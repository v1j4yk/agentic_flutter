// Demonstrates the model layer: a provider-neutral request, a middleware stack,
// streaming, tool calling and cost accounting.
//
// Run it with:
//
//     dart run example/agentic_llm_example.dart
//
// It runs offline against `FakeChatModel`. To point it at a real provider,
// export a key first — nothing else changes, which is the point:
//
//     export OPENAI_API_KEY=sk-...
//     dart run example/agentic_llm_example.dart
import 'dart:io';

import 'package:agentic_core/agentic_core.dart';
import 'package:agentic_llm/agentic_llm.dart';
import 'package:agentic_llm/testing.dart';
import 'package:agentic_tools/agentic_tools.dart';

Future<void> main() async {
  // ---------------------------------------------------------------------------
  // 1. Pick a provider. Every branch produces a `ChatModel`, and nothing below
  //    this point knows or cares which one it got.
  // ---------------------------------------------------------------------------
  final apiKey = Platform.environment['OPENAI_API_KEY'];
  final anthropicKey = Platform.environment['ANTHROPIC_API_KEY'];

  final ChatModel provider;
  if (apiKey != null) {
    provider = OpenAiCompatibleChatModel.openAi(
      apiKey: apiKey,
      model: 'gpt-4o-mini',
      pricing: const ModelPricing(inputPerMillion: 0.15, outputPerMillion: 0.6),
    );
  } else if (anthropicKey != null) {
    provider = AnthropicChatModel(apiKey: anthropicKey);
  } else {
    print('No API key found — running against a scripted fake model.\n');
    provider = _scriptedModel();
  }

  // ---------------------------------------------------------------------------
  // 2. Wrap it. Each decorator is an ordinary class; the order is visible here
  //    rather than hidden in a pipeline configuration.
  // ---------------------------------------------------------------------------
  final model = ObservableChatModel(
    RetryingChatModel(
      CachingChatModel(
        FallbackChatModel(<ChatModel>[provider]),
        cache: InMemoryChatCache(),
      ),
      policy: RetryPolicy.interactive,
    ),
  );

  print('model        : ${model.info.qualifiedId}');
  print(
    'capabilities : ${model.info.capabilities.map((c) => c.name).join(', ')}',
  );

  // ---------------------------------------------------------------------------
  // 3. Observe the run. A UI would bind to these; here they just print.
  // ---------------------------------------------------------------------------
  final events = BroadcastEventBus();
  events.on<LlmEvent>().listen((event) {
    final detail = switch (event) {
      LlmRequestStarted(:final messageCount, :final toolCount) =>
        '$messageCount messages, $toolCount tools',
      LlmFirstTokenReceived(:final latency) =>
        'first token after ${latency.inMilliseconds}ms',
      LlmResponseCompleted(:final usage, :final cost, :final wasCached) =>
        '${usage.totalTokens} tokens'
            '${cost == null ? '' : ', \$${cost.toStringAsFixed(6)}'}'
            '${wasCached ? ' (cached)' : ''}',
      LlmRequestFailed(:final code) => 'failed: $code',
      _ => '',
    };
    print('  [${event.type}] $detail');
  });

  final context = AgenticContext.root(events: events, runId: 'example');

  // ---------------------------------------------------------------------------
  // 4. A plain question.
  // ---------------------------------------------------------------------------
  print('\n--- generate ---');
  final answer = await model.generate(
    ChatRequest.prompt(
      'What is the capital of France? Answer in one word.',
      system: 'You are concise.',
      temperature: 0,
    ),
    context: context,
  );
  print('answer       : ${answer.text}');
  print('finish       : ${answer.finishReason.name}');

  // The identical request is served from cache — note the zeroed usage.
  print('\n--- generate again (cache hit) ---');
  await model.generate(
    ChatRequest.prompt(
      'What is the capital of France? Answer in one word.',
      system: 'You are concise.',
      temperature: 0,
    ),
    context: context,
  );

  // ---------------------------------------------------------------------------
  // 5. Streaming. The same request, delivered incrementally.
  // ---------------------------------------------------------------------------
  print('\n--- stream ---');
  stdout.write('streamed     : ');
  final builder = ChatResponseBuilder(modelId: model.info.id);
  await for (final chunk in model.stream(
    ChatRequest.prompt('Name three Dart 3 features.', temperature: 0.7),
    context: context,
  )) {
    builder.add(chunk);
    if (chunk.textDelta case final delta?) stdout.write(delta);
  }
  stdout.writeln();
  print('chunks       : ${builder.chunkCount}');

  // ---------------------------------------------------------------------------
  // 6. Tool calling. The model asks; `agentic_tools` runs it; the loop closes.
  // ---------------------------------------------------------------------------
  print('\n--- tool calling ---');
  final registry = ToolRegistry()
    ..register(
      FunctionTool(
        name: 'get_weather',
        description: 'Returns the current weather for a city.',
        parameters: JsonSchema.object(
          properties: {
            'city': JsonSchema.string(description: 'City name'),
            'unit': JsonSchema.enumeration(['celsius', 'fahrenheit']),
          },
          required: {'city'},
        ),
        handler: (invocation) async => ToolResult.json(<String, Object?>{
          'city': invocation.require<String>('city'),
          'temperature': 18,
          'conditions': 'light rain',
        }),
      ),
    );

  final executor = ToolExecutor(tools: registry.all);
  var conversation = ChatRequest(
    messages: <Message>[Message.user('What is the weather in Paris?')],
    tools: registry.all,
    temperature: 0,
  );

  // A minimal agent loop. `agentic_agents` will own this; it is four lines
  // because the layers underneath already did the hard parts.
  for (var turn = 0; turn < 3; turn++) {
    final response = await model.generate(conversation, context: context);
    if (!response.hasToolCalls) {
      print('answer       : ${response.text}');
      break;
    }
    print('tool calls   : ${response.toolCalls.map((c) => c.name).join(', ')}');
    final results = await executor.executeAllAsMessages(
      response.toolCalls,
      context: context,
    );
    for (final result in results) {
      print('tool result  : ${result.toolResults.single.content}');
    }
    conversation = conversation.withMessages(<Message>[
      response.message,
      ...results,
    ]);
  }

  await events.dispose();
  await model.dispose();
  await registry.dispose();
}

/// A scripted model so the example runs with no network and no key.
ChatModel _scriptedModel() => FakeChatModel(
  info: ModelInfo(
    id: 'scripted',
    provider: 'example',
    capabilities: ModelCapabilities.frontier,
    pricing: const ModelPricing(inputPerMillion: 0.15, outputPerMillion: 0.6),
  ),
  turns: <FakeTurn>[
    FakeTurn.answer(
      ChatResponse(
        message: Message.assistant('Paris'),
        modelId: 'scripted',
        usage: const TokenUsage(promptTokens: 24, completionTokens: 1),
      ),
    ),
    FakeTurn.answer(
      ChatResponse(
        message: Message.assistant('Records, patterns, and sealed classes.'),
        modelId: 'scripted',
        usage: const TokenUsage(promptTokens: 18, completionTokens: 9),
      ),
    ),
    FakeTurn.answer(
      ChatResponse(
        message: Message.assistant(
          '',
          toolCalls: <ToolCallPart>[
            ToolCallPart(
              id: 'call_1',
              name: 'get_weather',
              arguments: <String, Object?>{'city': 'Paris'},
            ),
          ],
        ),
        modelId: 'scripted',
        finishReason: FinishReason.toolCalls,
        usage: const TokenUsage(promptTokens: 60, completionTokens: 12),
      ),
    ),
    FakeTurn.answer(
      ChatResponse(
        message: Message.assistant('It is 18 °C with light rain in Paris.'),
        modelId: 'scripted',
        usage: const TokenUsage(promptTokens: 90, completionTokens: 11),
      ),
    ),
  ],
);
