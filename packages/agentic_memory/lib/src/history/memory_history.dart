/// History strategies backed by memory.
///
/// `agentic_agents` defines `HistoryStrategy` as the seam where a conversation
/// decides what to send the model next turn. The two strategies here are why
/// that seam exists:
///
/// * [SummarisingHistory] keeps recent turns verbatim and condenses the rest,
///   so a long conversation stays inside the context window without simply
///   forgetting its beginning.
/// * [RecallingHistory] injects what the store knows that is relevant *now*,
///   which is how knowledge survives past the end of a conversation.
///
/// They compose: recall on top of summarise on top of a window.
library;

import 'package:agentic_agents/agentic_agents.dart';
import 'package:agentic_core/agentic_core.dart';
import 'package:agentic_llm/agentic_llm.dart';
import 'package:agentic_memory/src/events/memory_events.dart';
import 'package:agentic_memory/src/model/memory_entry.dart';
import 'package:agentic_memory/src/store/memory_store.dart';

/// Condenses the older part of a conversation into a summary.
///
/// # The cost that makes this worth building carefully
///
/// The naive implementation summarises on every turn, which adds a model call
/// to every single message — often costing more than the tokens it saves.
///
/// This one caches: the summary is recomputed only when the boundary between
/// "summarised" and "verbatim" actually moves. In a steady conversation that is
/// once every [keepRecent] turns rather than every turn.
///
/// ```dart
/// final session = AgentSession(
///   strategy: SummarisingHistory(model: cheapModel, keepRecent: 8),
/// );
/// ```
final class SummarisingHistory implements HistoryStrategy {
  /// Creates a summarising strategy.
  ///
  /// [summariseAfter] is how many conversation messages must accumulate before
  /// summarising begins. Below it, everything is sent verbatim — summarising a
  /// six-turn chat costs a model call to save nothing.
  SummarisingHistory({
    required this.model,
    this.keepRecent = 8,
    this.summariseAfter = 20,
    this.store,
    this.sessionId,
    this.maxSummaryWords = 200,
  }) : assert(keepRecent >= 1, 'keepRecent must be at least 1'),
       assert(
         summariseAfter > keepRecent,
         'summariseAfter must exceed keepRecent, or every turn summarises',
       );

  /// The model that writes summaries.
  ///
  /// Use a cheap one. Condensing a transcript is not a task that rewards a
  /// frontier model, and this call happens on a user-visible path.
  final ChatModel model;

  /// How many recent messages stay verbatim.
  final int keepRecent;

  /// How many messages must accumulate before summarising starts.
  final int summariseAfter;

  /// Optional store to persist each summary into.
  ///
  /// Worth setting: a summary is the most valuable thing a long conversation
  /// produces, and keeping it only in memory means it dies with the process.
  final MemoryStore? store;

  /// Session the persisted summaries belong to.
  final String? sessionId;

  /// Approximate ceiling on summary length.
  final int maxSummaryWords;

  String? _cachedSummary;
  int _cachedUpTo = 0;

  /// The summary currently held, if any.
  String? get summary => _cachedSummary;

  @override
  Future<List<Message>> select(
    List<Message> history, {
    Message? pending,
    AgenticContext? context,
  }) async {
    final system = history.systemMessages;
    final conversation = history.conversation;

    if (conversation.length <= summariseAfter) {
      return repairDanglingToolResults(history);
    }

    final cut = conversation.length - keepRecent;
    final older = conversation.sublist(0, cut);
    final recent = conversation.sublist(cut);

    if (_cachedSummary == null || cut != _cachedUpTo) {
      _cachedSummary = await _summarise(older, context: context);
      _cachedUpTo = cut;
      await _persist(_cachedSummary!, context: context);
    }

    return repairDanglingToolResults(<Message>[
      ...system,
      Message.system(
        'Summary of the earlier part of this conversation:\n\n'
        '${_cachedSummary!}\n\n'
        'The messages that follow are the most recent turns, verbatim.',
      ),
      ...recent,
    ]);
  }

  /// Discards the cached summary, forcing a recompute on the next turn.
  void invalidate() {
    _cachedSummary = null;
    _cachedUpTo = 0;
  }

  Future<String> _summarise(
    List<Message> messages, {
    AgenticContext? context,
  }) async {
    final transcript = messages
        .map((message) => '${message.role.wireName}: ${message.text}')
        .where((line) => line.trim().length > _shortestRolePrefix)
        .join('\n');

    final response = await model.generate(
      ChatRequest(
        messages: <Message>[
          Message.system(
            'Condense the conversation below into at most $maxSummaryWords '
            'words. Preserve decisions, commitments, names, numbers and stated '
            'preferences exactly. Drop pleasantries and restated context. '
            'Write in the third person. Do not invent anything that is not in '
            'the transcript.'
            '${_cachedSummary == null ? '' : '\n\nAn earlier summary of the '
                      'first part is included at the top of the transcript; fold '
                      'it in rather than repeating it.'}',
          ),
          Message.user(
            _cachedSummary == null
                ? transcript
                : 'Earlier summary:\n${_cachedSummary!}\n\n'
                      'Newer messages:\n$transcript',
          ),
        ],
        // Condensing is a faithfulness task, not a creative one.
        temperature: 0,
        maxOutputTokens: maxSummaryWords * 2,
      ),
      context: context,
    );
    return response.text;
  }

  Future<void> _persist(String summary, {AgenticContext? context}) async {
    final target = store;
    if (target == null || summary.isEmpty) return;
    await target.remember(
      summary,
      kind: MemoryKind.summary,
      // Summaries earn a high importance: they are the distilled form of many
      // turns, and losing one loses all of them.
      importance: 0.7,
      sessionId: sessionId,
      tags: const <String>{'conversation-summary'},
      context: context,
    );
  }

  @override
  String toString() =>
      'SummarisingHistory(keepRecent: $keepRecent, after: $summariseAfter)';
}

/// Length of the shortest `role: ` prefix, used to drop content-free turns.
const int _shortestRolePrefix = 6;

/// Prepends what the store remembers that is relevant to the current turn.
///
/// This is the strategy that makes memory *useful*: without it a store is a
/// write-only log. It recalls against the latest user message, so what gets
/// injected changes with the question rather than being a fixed preamble.
///
/// ```dart
/// final session = AgentSession(
///   strategy: RecallingHistory(
///     store: store,
///     inner: SlidingWindowHistory(maxMessages: 20),
///   ),
/// );
/// ```
final class RecallingHistory implements HistoryStrategy {
  /// Creates a recalling strategy.
  ///
  /// [minScore] is worth setting above zero. Recall with no floor always
  /// returns something, so an unrelated question gets three confident
  /// irrelevancies prepended to it — which measurably degrades the answer.
  RecallingHistory({
    required this.store,
    this.inner = const KeepAllHistory(),
    this.limit = 5,
    this.kinds = const <MemoryKind>{},
    this.minScore = 0.2,
    this.sessionId,
    this.includeSessionScoped = true,
  }) : assert(limit > 0, 'limit must be positive');

  /// Where memories are read from.
  final MemoryStore store;

  /// The strategy applied to the conversation itself.
  final HistoryStrategy inner;

  /// How many memories to inject.
  ///
  /// Keep it small. Recall exists to supply a few relevant facts; injecting
  /// twenty recreates the context problem memory was meant to solve.
  final int limit;

  /// Restrict recall to these kinds, or every kind when empty.
  final Set<MemoryKind> kinds;

  /// Minimum relevance for a memory to be injected.
  final double minScore;

  /// Session whose scoped memories are eligible.
  final String? sessionId;

  /// Whether session-scoped memories are recalled alongside global ones.
  final bool includeSessionScoped;

  @override
  Future<List<Message>> select(
    List<Message> history, {
    Message? pending,
    AgenticContext? context,
  }) async {
    final base = await inner.select(
      history,
      pending: pending,
      context: context,
    );
    // The turn about to be sent drives recall; the latest transcript turn is
    // the fallback for callers that select history without one.
    final question = pending?.text ?? _latestUserText(base);
    if (question == null || question.isEmpty) return base;

    final query = MemoryQuery(
      text: question,
      limit: limit,
      kinds: kinds,
      minScore: minScore,
      sessionId: includeSessionScoped ? null : sessionId,
    );
    final hits = await store.search(query, context: context);
    if (hits.isEmpty) return base;

    // Published so that "how did it know that?" is answerable after the fact.
    // Recording the statements themselves, not merely the count, is what makes
    // a surprising answer traceable to the memory that caused it.
    context?.publish(
      MemoriesRecalled(
        id: context.ids.prefixed('evt'),
        timestamp: context.clock.now(),
        query: question,
        count: hits.length,
        contents: hits.map((hit) => hit.entry.content).toList(),
        sessionId: sessionId,
        runId: context.runId,
        source: 'memory:recall',
      ),
    );

    final recalled = _render(hits);

    // Injected after the instructions and before the conversation: it is
    // context, not an instruction, and it must not displace the system prompt.
    final system = base.systemMessages;
    final rest = base.conversation;
    return <Message>[...system, recalled, ...rest];
  }

  /// Renders recalled entries as a system message.
  ///
  /// The closing caveat is not decoration: without it a model treats recalled
  /// memories as more authoritative than what the user just said, and will
  /// argue with a correction.
  static Message _render(List<MemoryHit> hits) {
    final buffer = StringBuffer(
      'Relevant things you remember about this user or project:',
    );
    for (final hit in hits) {
      buffer.write('\n- ${hit.entry.content}');
    }
    buffer.write(
      '\n\nUse these only where they are relevant. They may be out of date; '
      'prefer what the user says now.',
    );
    return Message.system(buffer.toString());
  }

  static String? _latestUserText(List<Message> messages) {
    for (final message in messages.reversed) {
      if (message.role == MessageRole.user && message.text.isNotEmpty) {
        return message.text;
      }
    }
    return null;
  }

  @override
  String toString() => 'RecallingHistory(limit: $limit, minScore: $minScore)';
}
