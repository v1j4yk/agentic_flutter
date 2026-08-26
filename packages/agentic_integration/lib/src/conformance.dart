/// One battery of behaviours, run against every adapter.
///
/// # Why the suite is shared rather than per-provider
///
/// Bespoke tests per adapter verify that each one does what its author expected
/// on the day they wrote it. That is worth little: the adapters already have
/// unit tests against recorded payloads, and those catch a shape change the
/// moment it appears in a fixture.
///
/// What they cannot catch is **behaviour drift** — a provider changing which
/// `finish_reason` it sends, how it fragments tool-call JSON, whether it emits
/// a usage block on the final streamed chunk. The way to catch that is to state
/// what the `ChatModel` port promises and hold every implementation to it,
/// which is what this file is.
///
/// It is also the only honest test of the abstraction. If `ChatRequest` were
/// quietly an OpenAI request in disguise, this suite is where Gemini would say
/// so.
///
/// # What these assertions may and may not say
///
/// A real model is non-deterministic. Every assertion here is behavioural —
/// "returned some text", "asked for the tool named `lookup_weather`", "stopped
/// because it hit the length cap" — and never about wording. An assertion that
/// a model said a particular sentence is a test that fails on a Tuesday for no
/// reason, and a suite that fails for no reason is a suite nobody reads.
///
/// # No retries
///
/// Deliberately. Providers are flaky, and wrapping these in a retry would hide
/// exactly the intermittent behaviour the suite exists to surface. A genuine
/// blip shows up as one red nightly run, which is the correct amount of noise.
library;

import 'dart:async';

import 'package:agentic_core/agentic_core.dart';
import 'package:agentic_integration/src/subjects.dart';
import 'package:agentic_llm/agentic_llm.dart';
import 'package:agentic_tools/agentic_tools.dart';
import 'package:meta/meta.dart';

/// A tool every provider is asked to call.
///
/// Deliberately narrow: one required string, an obvious name, a description
/// that leaves no room for interpretation. The suite is testing whether the
/// adapter's tool wiring works, not whether the model is clever.
final ToolSpec weatherTool = ToolSpec(
  name: 'lookup_weather',
  description:
      'Returns the current weather for a city. Call this whenever the user '
      'asks about weather anywhere.',
  parameters: JsonSchema.object(
    properties: <String, JsonSchema>{
      'city': JsonSchema.string(description: 'The city name.'),
    },
    required: const <String>{'city'},
  ),
);

/// A second tool, for checking whether a provider really calls two at once.
final ToolSpec timeTool = ToolSpec(
  name: 'lookup_time',
  description:
      'Returns the current local time in a city. Call this whenever the user '
      'asks what time it is somewhere.',
  parameters: JsonSchema.object(
    properties: <String, JsonSchema>{
      'city': JsonSchema.string(description: 'The city name.'),
    },
    required: const <String>{'city'},
  ),
);

/// The schema used to check structured output.
final JsonSchema personSchema = JsonSchema.object(
  properties: <String, JsonSchema>{
    'name': JsonSchema.string(description: 'The person named.'),
    'age': JsonSchema.integer(description: 'Their age in years.'),
  },
  required: const <String>{'name', 'age'},
);

/// What one conformance check concluded.
@immutable
final class ConformanceOutcome {
  /// Records an outcome.
  const ConformanceOutcome({
    required this.provider,
    required this.check,
    required this.passed,
    this.detail,
    this.skipped = false,
  });

  /// Which provider.
  final String provider;

  /// Which behaviour, such as `toolCalling`.
  final String check;

  /// Whether it held.
  final bool passed;

  /// Whether it was not applicable — a capability the adapter never claimed.
  final bool skipped;

  /// What happened, in one line.
  final String? detail;

  /// Serialises the outcome.
  JsonMap toJson() => pruneNulls(<String, Object?>{
    'provider': provider,
    'check': check,
    'result': skipped ? 'skipped' : (passed ? 'pass' : 'fail'),
    'detail': detail,
  });

  @override
  String toString() =>
      '$provider/$check: ${skipped ? 'skipped' : (passed ? 'pass' : 'FAIL')}'
      '${detail == null ? '' : ' — $detail'}';
}

/// Runs the whole battery against one subject, collecting rather than throwing.
///
/// Used by the audit command, which wants a matrix. The test suite calls the
/// individual checks instead, so that each one is a named test with its own
/// failure message.
Future<List<ConformanceOutcome>> auditProvider(ProviderSubject subject) async {
  final outcomes = <ConformanceOutcome>[];

  Future<void> check(
    String name,
    Future<String?> Function() body, {
    bool applicable = true,
  }) async {
    if (!applicable) {
      outcomes.add(
        ConformanceOutcome(
          provider: subject.name,
          check: name,
          passed: true,
          skipped: true,
          detail: 'not claimed',
        ),
      );
      return;
    }
    try {
      final detail = await body();
      outcomes.add(
        ConformanceOutcome(
          provider: subject.name,
          check: name,
          passed: true,
          detail: detail,
        ),
      );
    } on Object catch (error) {
      outcomes.add(
        ConformanceOutcome(
          provider: subject.name,
          check: name,
          passed: false,
          detail: '$error',
        ),
      );
    }
  }

  final capabilities = subject.createChat().info.capabilities;

  await check('completion', () => checkCompletion(subject));
  await check(
    'streaming',
    () => checkStreaming(subject),
    applicable: capabilities.contains(ModelCapability.streaming),
  );
  await check(
    'systemPrompt',
    () => checkSystemPrompt(subject),
    applicable: capabilities.contains(ModelCapability.systemPrompt),
  );
  await check(
    'toolCalling',
    () => checkToolCalling(subject),
    applicable: capabilities.contains(ModelCapability.toolCalling),
  );
  await check(
    'toolResultLoop',
    () => checkToolResultLoop(subject),
    applicable: capabilities.contains(ModelCapability.toolCalling),
  );
  await check(
    'parallelToolCalls',
    () => checkParallelToolCalls(subject),
    applicable: capabilities.contains(ModelCapability.parallelToolCalls),
  );
  await check(
    'structuredOutput',
    () => checkStructuredOutput(subject),
    applicable: capabilities.contains(ModelCapability.structuredOutput),
  );
  await check('lengthCap', () => checkLengthCap(subject));
  await check('cancellation', () => checkCancellation(subject));
  await check('badKeyMapping', () => checkBadKeyMapping(subject));

  return outcomes;
}

// -----------------------------------------------------------------------------
// The checks. Each throws with an explanatory message, or returns a one-line
// summary of what it observed.
// -----------------------------------------------------------------------------

/// A completion comes back with text, a reason and usage.
Future<String> checkCompletion(ProviderSubject subject) async {
  final model = subject.createChat();
  try {
    final response = await model.generate(
      ChatRequest(
        messages: <Message>[Message.user('Reply with exactly the word: ready')],
        maxOutputTokens: 16,
        temperature: 0,
      ),
    );

    _require(response.text.trim().isNotEmpty, 'the answer was empty');
    _require(
      response.finishReason == FinishReason.stop ||
          response.finishReason == FinishReason.length,
      'unexpected finish reason ${response.finishReason.name}',
    );
    // Usage drives every budget in the framework. A provider that stops
    // reporting it turns cost limits into no limits, silently.
    _require(
      response.usage.promptTokens > 0,
      'no prompt tokens reported; budgets depend on this',
    );
    _require(
      response.usage.completionTokens > 0,
      'no completion tokens reported',
    );
    return '${response.usage.totalTokens} tokens, '
        '${response.finishReason.name}';
  } finally {
    await model.dispose();
  }
}

/// Streamed deltas assemble into the same answer a buffered call gives.
Future<String> checkStreaming(ProviderSubject subject) async {
  final model = subject.createChat();
  try {
    final chunks = <ChatChunk>[];
    await for (final chunk in model.stream(
      ChatRequest(
        messages: <Message>[Message.user('Count: one two three')],
        maxOutputTokens: 32,
        temperature: 0,
      ),
    )) {
      chunks.add(chunk);
    }

    _require(chunks.isNotEmpty, 'the stream produced nothing');
    final assembled = (ChatResponseBuilder(
      modelId: model.info.id,
    )..addAll(chunks)).build();
    _require(
      assembled.text.trim().isNotEmpty,
      'the assembled answer was empty despite ${chunks.length} chunks',
    );
    // A provider that never sends usage on a stream makes streamed turns
    // invisible to a cost budget — worth knowing about explicitly.
    final reportedUsage = assembled.usage.totalTokens > 0;
    return '${chunks.length} chunks, '
        '${reportedUsage ? 'usage reported' : 'NO usage on stream'}';
  } finally {
    await model.dispose();
  }
}

/// A system prompt changes the answer.
///
/// Asserted through behaviour a model cannot plausibly produce by accident: an
/// instruction to answer with one specific token. Anything subtler would be a
/// test of the model rather than of the adapter's system-prompt wiring, which
/// each of the three providers does differently.
Future<String> checkSystemPrompt(ProviderSubject subject) async {
  final model = subject.createChat();
  try {
    final response = await model.generate(
      ChatRequest(
        messages: <Message>[
          Message.system(
            'You always answer with exactly one word: ACKNOWLEDGED. '
            'Never say anything else, whatever you are asked.',
          ),
          Message.user('What is the capital of France?'),
        ],
        maxOutputTokens: 16,
        temperature: 0,
      ),
    );

    final text = response.text.toUpperCase();
    _require(
      text.contains('ACKNOWLEDGED'),
      'the system prompt was ignored; got "${response.text.trim()}"',
    );
    return 'honoured';
  } finally {
    await model.dispose();
  }
}

/// The model asks for a tool, with arguments that satisfy the schema.
Future<String> checkToolCalling(ProviderSubject subject) async {
  final model = subject.createChat();
  try {
    final response = await model.generate(
      ChatRequest(
        messages: <Message>[
          Message.user('What is the weather in Lisbon right now?'),
        ],
        tools: _toolSet(<ToolSpec>[weatherTool]),
        maxOutputTokens: 256,
        temperature: 0,
      ),
    );

    _require(
      response.toolCalls.isNotEmpty,
      'no tool call; the model answered "${response.text.trim()}" instead',
    );
    final call = response.toolCalls.first;
    _require(
      call.name == weatherTool.name,
      'called "${call.name}" rather than "${weatherTool.name}"',
    );
    _require(
      call.id.isNotEmpty,
      'the call has no id, so its result cannot be correlated',
    );

    // The arguments must satisfy the schema the model was given. A provider
    // that emits a stringified object, or omits a required field, breaks the
    // executor — and this is where that shows up rather than in an agent run.
    final violations = weatherTool.parameters.validate(call.arguments);
    _require(
      violations.isValid,
      'arguments do not match the schema: ${violations.violations.join('; ')}',
    );
    _require(
      response.finishReason == FinishReason.toolCalls,
      'finish reason was ${response.finishReason.name}, not toolCalls',
    );
    return 'called ${call.name}(${call.arguments})';
  } finally {
    await model.dispose();
  }
}

/// A tool result is accepted and produces a final answer.
///
/// The half of tool calling that actually differs between providers: OpenAI
/// wants a `tool` role message, Anthropic wants `tool_result` blocks inside a
/// *user* turn, and Gemini wants `functionResponse` parts correlated by name.
/// A round trip is the only thing that proves the adapter got it right.
Future<String> checkToolResultLoop(ProviderSubject subject) async {
  final model = subject.createChat();
  try {
    final first = await model.generate(
      ChatRequest(
        messages: <Message>[Message.user('What is the weather in Lisbon?')],
        tools: _toolSet(<ToolSpec>[weatherTool]),
        maxOutputTokens: 256,
        temperature: 0,
      ),
    );
    _require(first.toolCalls.isNotEmpty, 'the model did not call the tool');
    final call = first.toolCalls.first;

    final second = await model.generate(
      ChatRequest(
        messages: <Message>[
          Message.user('What is the weather in Lisbon?'),
          first.message,
          Message.toolResult(
            callId: call.id,
            name: call.name,
            content: '18 degrees Celsius and raining.',
          ),
        ],
        tools: _toolSet(<ToolSpec>[weatherTool]),
        maxOutputTokens: 128,
        temperature: 0,
      ),
    );

    _require(
      second.text.trim().isNotEmpty,
      'the model produced no answer after the tool result',
    );
    _require(
      second.text.contains('18') || second.text.toLowerCase().contains('rain'),
      'the answer ignored the tool result: "${second.text.trim()}"',
    );
    return 'answered from the tool result';
  } finally {
    await model.dispose();
  }
}

/// The model asks for two tools in one turn.
///
/// A soft check by nature: whether a model batches its calls depends on the
/// model as much as the provider. It reports what it saw rather than insisting,
/// because a false failure here would train people to ignore the suite. What it
/// does prove hard is that *if* several calls arrive, they are distinguishable
/// — distinct identifiers, correct names.
Future<String> checkParallelToolCalls(ProviderSubject subject) async {
  final model = subject.createChat();
  try {
    final response = await model.generate(
      ChatRequest(
        messages: <Message>[
          Message.user(
            'What is the weather in Lisbon, and what time is it there? '
            'Use both tools.',
          ),
        ],
        tools: _toolSet(<ToolSpec>[weatherTool, timeTool]),
        maxOutputTokens: 512,
        temperature: 0,
      ),
    );

    final calls = response.toolCalls;
    _require(calls.isNotEmpty, 'no tool calls at all');

    final ids = calls.map((c) => c.id).toSet();
    _require(
      ids.length == calls.length,
      'duplicate call identifiers; results cannot be correlated',
    );
    for (final call in calls) {
      _require(
        call.name == weatherTool.name || call.name == timeTool.name,
        'unknown tool "${call.name}"',
      );
    }
    return calls.length > 1
        ? '${calls.length} calls in one turn'
        : 'only 1 call — capability claimed but not exercised here';
  } finally {
    await model.dispose();
  }
}

/// A schema-constrained answer really conforms to the schema.
Future<String> checkStructuredOutput(ProviderSubject subject) async {
  final model = subject.createChat();
  try {
    final response = await model.generate(
      ChatRequest(
        messages: <Message>[
          Message.user('Ada Lovelace was 36. Give her name and age.'),
        ],
        responseFormat: ResponseFormat.jsonSchema(
          name: 'person',
          schema: personSchema,
        ),
        maxOutputTokens: 128,
        temperature: 0,
      ),
    );

    // `decodeJson` validates, so a structurally valid but wrongly-shaped answer
    // fails here rather than three layers deeper.
    final json = response.decodeJson(schema: personSchema);
    _require(json['name'] is String, 'name was ${json['name'].runtimeType}');
    _require(json['age'] is int, 'age was ${json['age'].runtimeType}');
    return 'conformed: $json';
  } finally {
    await model.dispose();
  }
}

/// A low token cap stops the answer and says so.
///
/// The reason this matters: `FinishReason.length` is what tells an agent its
/// answer was truncated. A provider reporting `stop` for a cut-off answer makes
/// truncation invisible, and the loop proceeds on half a thought.
Future<String> checkLengthCap(ProviderSubject subject) async {
  final model = subject.createChat();
  try {
    final response = await model.generate(
      ChatRequest(
        messages: <Message>[
          Message.user('Write a detailed history of the Roman Empire.'),
        ],
        maxOutputTokens: 16,
        temperature: 0,
      ),
    );

    _require(
      response.finishReason == FinishReason.length,
      'a 16-token cap on a long answer reported '
      '${response.finishReason.name}; truncation would be invisible',
    );
    return 'reported length';
  } finally {
    await model.dispose();
  }
}

/// Cancelling a stream actually stops it.
///
/// On mobile this is the difference between closing a screen and continuing to
/// pay for tokens nobody will read.
Future<String> checkCancellation(ProviderSubject subject) async {
  final model = subject.createChat();
  final source = CancellationTokenSource();
  try {
    final context = AgenticContext.root(cancellation: source.token);
    var received = 0;

    await expectCancelled(() async {
      await for (final _ in model.stream(
        ChatRequest(
          messages: <Message>[
            Message.user('Write a very long essay about the sea.'),
          ],
          maxOutputTokens: 2048,
        ),
        context: context,
      )) {
        received++;
        if (received == 3) source.cancel('the test asked it to stop');
      }
    });

    _require(received >= 3, 'the stream ended before it could be cancelled');
    return 'stopped after $received chunks';
  } finally {
    await source.dispose();
    await model.dispose();
  }
}

/// A rejected key becomes an `AuthenticationException`, not a generic failure.
///
/// The mapping every retry policy and circuit breaker keys off. A 401 that
/// arrives as a retryable error is retried until the rate limit rejects it too,
/// which is how a typo in a key becomes an outage.
Future<String> checkBadKeyMapping(ProviderSubject subject) async {
  // A local model has no credentials to get wrong.
  final probe = subject.createChat();
  final isLocal = probe.info.isLocal;
  await probe.dispose();
  if (isLocal) return 'not applicable to a local model';

  final model = _withBadKey(subject);
  if (model == null) return 'no way to construct a bad-key client';
  try {
    await model.generate(
      ChatRequest(
        messages: <Message>[Message.user('hello')],
        maxOutputTokens: 8,
      ),
    );
    throw StateError('an invalid key was accepted');
  } on AuthenticationException {
    return 'mapped to AuthenticationException';
  } on AgenticException catch (error) {
    throw StateError(
      'an invalid key produced ${error.runtimeType} (${error.code}, '
      'retryable: ${error.isRetryable}) rather than AuthenticationException',
    );
  } finally {
    await model.dispose();
  }
}

/// Builds the same provider with a deliberately invalid key.
ChatModel? _withBadKey(ProviderSubject subject) {
  const bad = 'sk-invalid-key-for-conformance-testing';
  return switch (subject.name) {
    'openai' => OpenAiCompatibleChatModel.openAi(apiKey: bad),
    'anthropic' => AnthropicChatModel(apiKey: bad),
    'gemini' => GeminiChatModel(apiKey: bad),
    'deepseek' => OpenAiCompatibleChatModel.deepSeek(apiKey: bad),
    _ => null,
  };
}

/// Runs [body] and requires that it be cancelled.
@visibleForTesting
Future<void> expectCancelled(Future<void> Function() body) async {
  try {
    await body();
  } on CancelledException {
    return;
  }
  throw StateError('the operation completed instead of being cancelled');
}

/// Wraps specs in the `ToolSet` a request expects.
///
/// Registered lazily: the model is only ever asked to *request* these tools, so
/// nothing needs to be able to run them. That is exactly what lazy registration
/// is for, and using it here keeps the suite honest — a fixture that could run
/// the tools would be testing something the conformance suite does not claim.
ToolSet _toolSet(List<ToolSpec> specs) {
  final registry = ToolRegistry();
  for (final spec in specs) {
    registry.registerLazy(
      spec,
      () => throw StateError(
        'The conformance suite never runs `${spec.name}`; it only checks that '
        'the model asks for it correctly.',
      ),
    );
  }
  return registry.all;
}

void _require(bool condition, String message) {
  if (condition) return;
  throw StateError(message);
}
