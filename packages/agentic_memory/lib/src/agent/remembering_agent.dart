/// Automatic memory extraction around an agent.
///
/// Wraps any [Agent] and, after each successful run, asks a model what from the
/// exchange is worth keeping — then writes it. The wrapped agent knows nothing
/// about memory.
///
/// # Why extraction is a separate model call
///
/// The alternative is asking the agent itself to remember things inline, which
/// mixes two jobs in one prompt: answering the user, and curating a knowledge
/// base. Models do the second badly when it competes with the first, and the
/// quality of the answer suffers for the sake of the memory.
///
/// A separate pass costs a call and buys a clean separation: the answering
/// prompt stays about answering, and the extraction prompt can be blunt about
/// what does and does not deserve storing.
///
/// # The cost, stated plainly
///
/// One extra model call per run. On a chatty assistant that is a real fraction
/// of the bill. Use a cheap model for extraction, set
/// `minimumImportance` so trivia is discarded rather than stored, and consider
/// the explicit `remember` tool instead when the assistant should acknowledge
/// remembering things anyway.
library;

import 'package:agentic_agents/agentic_agents.dart';
import 'package:agentic_core/agentic_core.dart';
import 'package:agentic_llm/agentic_llm.dart';
import 'package:agentic_memory/src/events/memory_events.dart';
import 'package:agentic_memory/src/model/memory_entry.dart';
import 'package:agentic_memory/src/store/memory_store.dart';

/// An agent that writes to memory after every run.
///
/// ```dart
/// final agent = RememberingAgent(
///   ToolCallingAgent(info: info, model: model, tools: tools),
///   store: store,
///   extractionModel: cheapModel,
/// );
/// ```
final class RememberingAgent extends DelegatingAgent {
  /// Wraps [inner] with automatic extraction.
  RememberingAgent(
    super.inner, {
    required this.store,
    required this.extractionModel,
    this.maxMemoriesPerRun = 5,
    this.minimumImportance = 0.3,
    this.sessionScoped = false,
    this.extractOnFailure = false,
  }) : assert(maxMemoriesPerRun >= 1, 'maxMemoriesPerRun must be at least 1');

  /// Where extracted memories are written.
  final MemoryStore store;

  /// The model used for extraction.
  ///
  /// Use a cheap one. Deciding whether "the user prefers British English" is
  /// worth keeping does not need a frontier model.
  final ChatModel extractionModel;

  /// Maximum memories written per run.
  ///
  /// A hard bound on how fast the store can grow. Without it, one verbose
  /// exchange can add thirty entries and drown everything already there.
  final int maxMemoriesPerRun;

  /// Minimum importance for an extracted memory to be kept.
  ///
  /// The dial that separates a useful profile from a transcript. Raise it if
  /// recall starts returning trivia.
  final double minimumImportance;

  /// Whether extracted memories are scoped to the session.
  ///
  /// Off by default: the point of extraction is knowledge that outlives the
  /// conversation. Turn it on for working memory that must not leak between
  /// conversations.
  final bool sessionScoped;

  /// Whether to extract from a run that did not complete.
  ///
  /// Off by default. A failed or budget-exhausted run often contains a
  /// half-formed conclusion, and storing that as a fact is worse than storing
  /// nothing.
  final bool extractOnFailure;

  @override
  Future<AgentResult> run(
    AgentInput input, {
    AgentSession? session,
    AgenticContext? context,
  }) async {
    final result = await inner.run(input, session: session, context: context);
    await _extract(input, result, session: session, context: context);
    return result;
  }

  @override
  Stream<AgentChunk> stream(
    AgentInput input, {
    AgentSession? session,
    AgenticContext? context,
  }) async* {
    AgentResult? finished;
    await for (final chunk in inner.stream(
      input,
      session: session,
      context: context,
    )) {
      if (chunk is AgentFinished) finished = chunk.result;
      yield chunk;
    }
    // Extraction happens after the caller has the answer, so it never delays a
    // token the user is waiting for.
    if (finished != null) {
      await _extract(input, finished, session: session, context: context);
    }
  }

  /// Extracts and stores memories from a completed exchange.
  ///
  /// Failures here are swallowed deliberately: memory is an enhancement, and an
  /// extraction call that times out must not turn a good answer into an error
  /// the user sees. The failure is logged and published.
  Future<void> _extract(
    AgentInput input,
    AgentResult result, {
    AgentSession? session,
    AgenticContext? context,
  }) async {
    if (!result.isSuccess && !extractOnFailure) return;
    if (result.text.isEmpty) return;

    final scope = context ?? AgenticContext.root();
    try {
      scope.throwIfCancelled();
      final extracted = await extractionModel.generateStructured<List<_Draft>>(
        ChatRequest(
          messages: <Message>[
            Message.system(_extractionPrompt),
            Message.user(
              'User: ${input.text}\n\n'
              'Assistant: ${result.text}',
            ),
          ],
          temperature: 0,
        ),
        name: 'memories',
        schema: _extractionSchema(maxMemoriesPerRun),
        fromJson: _draftsFrom,
        context: scope,
      );

      // Trimmed here rather than by the schema. A model that returns six
      // memories when asked for at most two has been slightly over-eager, and
      // rejecting the whole response for it would lose all six — so the schema
      // allows headroom and the excess is dropped by importance instead.
      final kept =
          extracted
              .where((draft) => draft.importance >= minimumImportance)
              .toList()
            ..sort((a, b) => b.importance.compareTo(a.importance));
      if (kept.isEmpty) return;
      if (kept.length > maxMemoriesPerRun) {
        kept.removeRange(maxMemoriesPerRun, kept.length);
      }

      final now = scope.clock.now();
      final entries = <MemoryEntry>[
        for (final draft in kept)
          MemoryEntry(
            id: scope.ids.prefixed('mem'),
            content: draft.content,
            createdAt: now,
            kind: draft.kind,
            importance: draft.importance,
            sessionId: sessionScoped ? session?.id : null,
            agentName: info.name,
            sourceRunId: scope.runId,
            tags: const <String>{'extracted'},
          ),
      ];

      await store.writeAll(entries, context: scope);

      scope
        ..publish(
          MemoriesExtracted(
            id: scope.ids.prefixed('evt'),
            timestamp: now,
            agentName: info.name,
            sessionId: session?.id,
            count: entries.length,
            runId: scope.runId,
            source: 'memory:${info.name}',
          ),
        )
        ..logger.debug(
          'Extracted memories',
          fields: <String, Object?>{
            'agent': info.name,
            'count': entries.length,
          },
        );
    } on CancelledException {
      // The run was abandoned; there is nothing to record and nobody to tell.
      return;
    } on AgenticException catch (error) {
      scope
        ..logger.warn(
          'Memory extraction failed; the answer is unaffected',
          fields: <String, Object?>{'agent': info.name, 'code': error.code},
          error: error,
        )
        ..publish(
          MemoryExtractionFailed(
            id: scope.ids.prefixed('evt'),
            timestamp: scope.clock.now(),
            agentName: info.name,
            sessionId: session?.id,
            reason: error.message,
            runId: scope.runId,
            source: 'memory:${info.name}',
          ),
        );
    }
  }

  static const String _extractionPrompt =
      'Extract only what is worth remembering for future conversations from '
      'the exchange below.\n\n'
      'Keep: durable preferences, decisions, facts about the user or their '
      'work, and commitments made.\n'
      'Discard: the question itself, anything you inferred rather than were '
      'told, pleasantries, and anything true only right now.\n\n'
      'Write each memory as a complete standalone sentence that will still '
      'make sense read alone in six months. Return an empty list when nothing '
      'qualifies — that is the common case and the correct answer.';

  static JsonSchema _extractionSchema(int limit) => JsonSchema.object(
    properties: <String, JsonSchema>{
      'memories': JsonSchema.array(
        description:
            'The memories worth keeping, at most $limit of them. Often empty, '
            'which is the common case and the correct answer.',
        // Deliberately looser than `limit`: the bound the model is asked to
        // respect is in the description, and this is the backstop against a
        // runaway response rather than a hard gate on a near miss.
        maxItems: limit * 2,
        items: JsonSchema.object(
          properties: <String, JsonSchema>{
            'content': JsonSchema.string(
              description: 'A complete standalone sentence.',
              minLength: 3,
            ),
            'kind': JsonSchema.enumeration(const <String>[
              'fact',
              'preference',
              'event',
              'task',
            ]),
            'importance': JsonSchema.number(
              description: 'From 0 to 1.',
              minimum: 0,
              maximum: 1,
            ),
          },
          required: const <String>{'content'},
        ),
      ),
    },
    required: const <String>{'memories'},
  );

  static List<_Draft> _draftsFrom(JsonMap json) =>
      json.decodeList('memories', _Draft.fromJson);
}

/// One extracted memory, before it becomes an entry.
final class _Draft {
  const _Draft({
    required this.content,
    required this.kind,
    required this.importance,
  });

  factory _Draft.fromJson(JsonMap json) => _Draft(
    content: json.requireString('content'),
    kind: json.enumOr('kind', <String, MemoryKind>{
      'fact': MemoryKind.fact,
      'preference': MemoryKind.preference,
      'event': MemoryKind.event,
      'task': MemoryKind.task,
    }, MemoryKind.fact),
    importance: (json.optionalDouble('importance') ?? 0.5).clamp(0.0, 1.0),
  );

  final String content;
  final MemoryKind kind;
  final double importance;
}
