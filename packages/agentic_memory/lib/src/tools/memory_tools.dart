/// Tools that let an agent manage its own memory.
///
/// # Two ways to remember, and when each is right
///
/// **Explicitly**, with these tools: the model decides what is worth keeping
/// and calls `remember`. It costs a tool call, it only happens when the model
/// thinks to do it, and what gets stored is exactly what the model judged
/// important — which is usually good and occasionally nothing at all.
///
/// **Automatically**, with `RememberingAgent`: an extraction pass runs after
/// every run. It never forgets to fire, it costs an extra model call each time,
/// and it stores things nobody asked for.
///
/// They are complementary rather than alternatives. Explicit tools suit an
/// assistant that should visibly acknowledge remembering something; automatic
/// extraction suits one that should quietly accumulate a user profile. Using
/// both is reasonable — the store deduplicates.
library;

import 'package:agentic_core/agentic_core.dart';
import 'package:agentic_memory/src/model/memory_entry.dart';
import 'package:agentic_memory/src/store/memory_store.dart';
import 'package:agentic_tools/agentic_tools.dart';

/// Builds the tools an agent uses to read and write its own memory.
///
/// ```dart
/// final agent = ToolCallingAgent(
///   info: AgentInfo(name: 'assistant', description: 'A personal assistant.'),
///   model: model,
///   tools: (ToolRegistry()..registerAll(memoryTools(store))).all,
///   instructions:
///       'When the user tells you something durable about themselves or their '
///       'work, call `remember`. Call `recall` before answering questions '
///       'about their preferences or past decisions.',
/// );
/// ```
///
/// The instructions matter as much as the tools: a model given `remember`
/// without being told when to use it will use it almost never.
List<Tool> memoryTools(
  MemoryStore store, {
  String? sessionId,
  String? agentName,
  bool includeForget = false,
}) => <Tool>[
  rememberTool(store, sessionId: sessionId, agentName: agentName),
  recallTool(store, sessionId: sessionId),
  if (includeForget) forgetTool(store),
];

/// A tool that writes one memory.
Tool rememberTool(
  MemoryStore store, {
  String? sessionId,
  String? agentName,
}) => FunctionTool(
  name: 'remember',
  description:
      'Stores a fact worth recalling in future conversations. Use it when the '
      'user states a durable preference, a decision, or a fact about their '
      'work that will still be true next week. Do not store the current '
      'question, small talk, or anything you were just told to do once.',
  tags: const <String>{'memory'},
  // Writing to memory changes state, which is what stops the executor running
  // several of these concurrently against the same store.
  isReadOnly: false,
  parameters: JsonSchema.object(
    properties: <String, JsonSchema>{
      'content': JsonSchema.string(
        description:
            'The fact, written as a complete standalone sentence. It will be '
            'read months later with no surrounding conversation, so write '
            '"Ada prefers concise answers", never "she prefers that".',
        minLength: 3,
      ),
      'kind': JsonSchema.enumeration(
        const <String>['fact', 'preference', 'event', 'task'],
        description:
            'preference for what the user wants, fact for how things are, '
            'event for something that happened, task for something to do.',
      ),
      'importance': JsonSchema.number(
        description:
            'How much this matters, from 0 to 1. Reserve values above 0.8 for '
            'things that should shape every future answer.',
        minimum: 0,
        maximum: 1,
      ),
    },
    required: const <String>{'content'},
  ),
  examples: <ToolExample>[
    ToolExample(
      situation: 'I always want answers in British English.',
      arguments: const <String, Object?>{
        'content': 'The user wants answers written in British English.',
        'kind': 'preference',
        'importance': 0.9,
      },
    ),
  ],
  handler: (invocation) async {
    final entry = await store.remember(
      invocation.require<String>('content'),
      kind: _kindFrom(invocation.optional<String>('kind', 'fact')),
      importance: _importanceFrom(invocation.arguments['importance']),
      sessionId: sessionId,
      agentName: agentName,
      context: invocation.context,
    );
    return ToolResult.success(
      'Remembered: ${entry.content}',
      data: entry,
      metadata: <String, Object?>{'memoryId': entry.id},
    );
  },
);

/// A tool that searches memory.
Tool recallTool(MemoryStore store, {String? sessionId}) => FunctionTool(
  name: 'recall',
  description:
      'Searches what you remember about this user and their work. Use it '
      'before answering questions about preferences, past decisions or '
      'previous conversations. Returns nothing when there is nothing relevant, '
      'which means you have not been told.',
  tags: const <String>{'memory'},
  parameters: JsonSchema.object(
    properties: <String, JsonSchema>{
      'query': JsonSchema.string(
        description: 'What to look for, in your own words.',
        minLength: 2,
      ),
      'limit': JsonSchema.integer(
        description: 'How many memories to return.',
        minimum: 1,
        maximum: 10,
        defaultValue: 5,
      ),
    },
    required: const <String>{'query'},
  ),
  handler: (invocation) async {
    final hits = await store.recall(
      invocation.require<String>('query'),
      limit: invocation.optional<int>('limit', 5),
      sessionId: sessionId,
      // A floor, so an unrelated query reports nothing rather than returning
      // the nearest three irrelevancies with confidence.
      minScore: 0.15,
      context: invocation.context,
    );

    if (hits.isEmpty) {
      // Phrased so the model treats it as an absence of knowledge rather than
      // a tool failure it should retry.
      return ToolResult.success(
        'Nothing relevant is remembered about that.',
        metadata: const <String, Object?>{'hits': 0},
      );
    }

    final buffer = StringBuffer('Remembered:');
    for (final hit in hits) {
      buffer.write('\n- ${hit.entry.content}');
    }
    return ToolResult.success(
      buffer.toString(),
      data: hits,
      metadata: <String, Object?>{'hits': hits.length},
    );
  },
);

/// A tool that deletes a memory.
///
/// Not included by default. Deletion is irreversible, and a model that
/// misreads a correction as a retraction can quietly erase a user's profile.
/// Pair it with an approval handler when you do enable it.
Tool forgetTool(MemoryStore store) => FunctionTool(
  name: 'forget',
  description:
      'Deletes a remembered fact by its identifier, for when the user says '
      'something you stored is wrong or no longer applies.',
  tags: const <String>{'memory'},
  isReadOnly: false,
  isIdempotent: false,
  requiresApproval: true,
  parameters: JsonSchema.object(
    properties: <String, JsonSchema>{
      'memoryId': JsonSchema.string(
        description: 'The identifier of the memory to delete.',
        minLength: 1,
      ),
    },
    required: const <String>{'memoryId'},
  ),
  handler: (invocation) async {
    final id = invocation.require<String>('memoryId');
    final removed = await store.delete(id);
    return removed
        ? ToolResult.success('Forgotten.')
        : ToolResult.failure(
            'No memory with the identifier `$id`. Use `recall` to find the '
            'right one first.',
          );
  },
);

MemoryKind _kindFrom(String raw) => switch (raw) {
  'preference' => MemoryKind.preference,
  'event' => MemoryKind.event,
  'task' => MemoryKind.task,
  'summary' => MemoryKind.summary,
  'observation' => MemoryKind.observation,
  _ => MemoryKind.fact,
};

/// Reads an importance the model supplied, defaulting when it did not.
///
/// The schema already bounds the range, so an out-of-range value is reported to
/// the model as a validation error it can repair — the same treatment every
/// other malformed argument gets. The clamp here is a guard for callers that
/// invoke the handler directly, not a second repair layer.
double _importanceFrom(Object? raw) {
  if (raw is num) return raw.toDouble().clamp(0.0, 1.0);
  if (raw is String) {
    final parsed = double.tryParse(raw);
    if (parsed != null) return parsed.clamp(0.0, 1.0);
  }
  return 0.5;
}
