/// Conversation state that outlives a single run.
///
/// A session is what turns a sequence of one-shot answers into a conversation:
/// it holds the transcript, accumulates usage, and decides what is sent back to
/// the model on the next turn.
///
/// # Why the trimming strategy is a seam, not a setting
///
/// Every conversation eventually exceeds the context window, and what to do
/// about it is a genuine product decision: drop the middle, summarise it, or
/// retrieve the relevant parts from a vector store. Those are three different
/// packages' worth of behaviour.
///
/// [HistoryStrategy] is the seam where they plug in. `agentic_memory` will
/// supply a summarising strategy and `agentic_rag` a retrieving one, and
/// neither will require a change here.
library;

import 'package:agentic_agents/src/agent/agent_result.dart';
import 'package:agentic_core/agentic_core.dart';

/// Decides which messages are sent to the model on the next turn.
///
/// Implementations must never drop system messages: losing the instructions
/// mid-conversation changes the assistant's behaviour in a way that looks like
/// the model degrading rather than the framework misbehaving.
///
/// # Why this is asynchronous
///
/// The trivial strategies here are pure functions and would be happier
/// synchronous. The interesting ones are not: summarising the dropped middle of
/// a conversation is a model call, and retrieving the relevant parts of it from
/// a vector store is a search. Both are the reason this seam exists, so the
/// signature has to admit them — a synchronous interface would force every
/// real memory backend to be bolted on somewhere else.
abstract interface class HistoryStrategy {
  /// Returns the messages to send, given the full [history].
  ///
  /// [pending] is the turn about to be sent, which is *not* yet part of
  /// [history]. A retrieving strategy needs it: recall should be driven by the
  /// question just asked, and a strategy that can only see previous turns
  /// retrieves for the wrong thing on every turn — including recalling nothing
  /// at all on the first.
  ///
  /// [context] carries cancellation, logging and the clock for strategies that
  /// do real work. Strategies that need neither may ignore both.
  Future<List<Message>> select(
    List<Message> history, {
    Message? pending,
    AgenticContext? context,
  });
}

/// Sends the entire history.
///
/// The right default for short conversations and the wrong one for long ones.
/// It fails loudly — a context-length error from the provider — rather than
/// silently degrading, which is the better failure of the two.
final class KeepAllHistory implements HistoryStrategy {
  /// Creates the strategy.
  const KeepAllHistory();

  @override
  Future<List<Message>> select(
    List<Message> history, {
    Message? pending,
    AgenticContext? context,
  }) async => history;
}

/// Keeps the most recent [maxMessages] turns, plus every system message.
///
/// The simplest strategy that works. Its weakness is honest and worth knowing:
/// it forgets, and the user will notice when the assistant loses something they
/// said ten turns ago.
final class SlidingWindowHistory implements HistoryStrategy {
  /// Creates a window over the last [maxMessages] non-system messages.
  const SlidingWindowHistory({this.maxMessages = 20})
    : assert(maxMessages >= 1, 'maxMessages must be at least 1');

  /// How many recent messages to keep.
  final int maxMessages;

  @override
  Future<List<Message>> select(
    List<Message> history, {
    Message? pending,
    AgenticContext? context,
  }) async => repairDanglingToolResults(history.takeRecent(maxMessages));
}

/// Keeps recent history under an approximate character budget.
///
/// Characters, not tokens: an exact count needs the model's tokeniser, which
/// lives in the provider adapter. Four characters per token is a serviceable
/// rule for English and a poor one for code or CJK, so leave real headroom.
final class CharacterBudgetHistory implements HistoryStrategy {
  /// Creates a strategy bounded at [maxCharacters].
  const CharacterBudgetHistory({this.maxCharacters = 24000})
    : assert(maxCharacters > 0, 'maxCharacters must be positive');

  /// Approximate ceiling on the transcript's size.
  final int maxCharacters;

  @override
  Future<List<Message>> select(
    List<Message> history, {
    Message? pending,
    AgenticContext? context,
  }) async {
    final system = history.systemMessages;
    final rest = history.conversation;

    var used = system.fold<int>(0, (sum, m) => sum + m.text.length);
    final kept = <Message>[];
    // Walk backwards: recent turns matter most, and stopping at the first turn
    // that does not fit keeps the transcript contiguous.
    for (final message in rest.reversed) {
      final size = message.text.length;
      if (kept.isNotEmpty && used + size > maxCharacters) break;
      used += size;
      kept.insert(0, message);
    }
    return repairDanglingToolResults(<Message>[...system, ...kept]);
  }
}

/// Drops tool results whose originating call was trimmed away.
///
/// Trimming can slice between an assistant turn and the tool results answering
/// it. Providers reject a `tool` message with no matching call, so a naive
/// window turns a long conversation into a hard 400 — one of the most confusing
/// failures in this whole area, because it appears only after N turns.
///
/// Exported so that a strategy in another package — a summarising or retrieving
/// one — gets the same repair without reimplementing it.
List<Message> repairDanglingToolResults(List<Message> messages) {
  final knownCallIds = <String>{
    for (final message in messages)
      for (final call in message.toolCalls) call.id,
  };

  final repaired = <Message>[];
  for (final message in messages) {
    if (message.role != MessageRole.tool) {
      repaired.add(message);
      continue;
    }
    final orphaned = message.toolResults.any(
      (result) => !knownCallIds.contains(result.callId),
    );
    if (!orphaned) repaired.add(message);
  }
  return repaired;
}

/// A conversation with an agent.
///
/// Mutable and owned by one conversation. Sessions are cheap; create one per
/// chat thread rather than sharing a global.
///
/// ```dart
/// final session = AgentSession(strategy: SlidingWindowHistory(maxMessages: 20));
///
/// await agent.run(AgentInput.text('What is Dart?'), session: session);
/// await agent.run(AgentInput.text('And its type system?'), session: session);
/// // The second run sees the first.
/// ```
final class AgentSession {
  /// Creates a session.
  AgentSession({
    String? id,
    List<Message> history = const <Message>[],
    this.strategy = const KeepAllHistory(),
    IdGenerator? ids,
    Map<String, Object?> metadata = const <String, Object?>{},
  }) : id = id ?? (ids ?? Ulid()).prefixed('session'),
       _history = List<Message>.of(history),
       metadata = Map<String, Object?>.of(metadata);

  /// Restores a session from [json].
  ///
  /// [strategy] is supplied by the caller rather than read from the payload:
  /// trimming is behaviour the application chooses, not state belonging to the
  /// conversation.
  factory AgentSession.fromJson(JsonMap json, {HistoryStrategy? strategy}) {
    final session = AgentSession(
      id: json.requireString('id'),
      history: json.decodeList('history', Message.fromJson),
      strategy: strategy ?? const KeepAllHistory(),
      metadata: json.optionalObject('metadata') ?? const <String, Object?>{},
    );
    final usage = json.optionalObject('totalUsage');
    if (usage != null) session._totalUsage = TokenUsage.fromJson(usage);
    session
      .._totalCost = json.optionalDouble('totalCost') ?? 0
      .._runCount = json.intOr('runCount', 0);
    return session;
  }

  /// Stable identifier for this conversation.
  final String id;

  /// How history is trimmed before each turn.
  final HistoryStrategy strategy;

  /// Application metadata, such as the user or thread this belongs to.
  final Map<String, Object?> metadata;

  final List<Message> _history;

  TokenUsage _totalUsage = TokenUsage.empty;
  double _totalCost = 0;
  int _runCount = 0;

  /// The complete transcript, oldest first.
  List<Message> get history => List<Message>.unmodifiable(_history);

  /// The transcript as it will be sent to the model, after trimming.
  ///
  /// Asynchronous because a strategy may summarise or retrieve; see
  /// [HistoryStrategy].
  Future<List<Message>> selectHistory({
    Message? pending,
    AgenticContext? context,
  }) => strategy.select(history, pending: pending, context: context);

  /// Tokens consumed across every run in this session.
  TokenUsage get totalUsage => _totalUsage;

  /// Estimated cost across every run in this session.
  double get totalCost => _totalCost;

  /// How many runs this session has seen.
  int get runCount => _runCount;

  /// Whether anything has been said yet.
  bool get isEmpty => _history.isEmpty;

  /// Appends messages to the transcript.
  void append(Iterable<Message> messages) => _history.addAll(messages);

  /// Appends a single message.
  void add(Message message) => _history.add(message);

  /// Records a completed run: its messages and its consumption.
  void recordRun(AgentResult result) {
    _history.addAll(result.messages);
    _totalUsage = _totalUsage + result.usage;
    _totalCost += result.cost ?? 0;
    _runCount++;
  }

  /// Replaces the system instructions, keeping the rest of the transcript.
  ///
  /// The one edit a long conversation legitimately needs: swapping the
  /// assistant's instructions without discarding what has been said.
  void setSystemPrompt(String prompt) {
    _history
      ..removeWhere((message) => message.role == MessageRole.system)
      ..insert(0, Message.system(prompt));
  }

  /// Discards the transcript and the totals.
  void clear() {
    _history.clear();
    _totalUsage = TokenUsage.empty;
    _totalCost = 0;
    _runCount = 0;
  }

  /// Serialises the session for persistence.
  ///
  /// The strategy is not serialised: it is behaviour chosen by the application,
  /// not state belonging to the conversation.
  JsonMap toJson() => pruneNulls(<String, Object?>{
    'id': id,
    'history': _history.map((message) => message.toJson()).toList(),
    'totalUsage': _totalUsage.toJson(),
    'totalCost': _totalCost == 0 ? null : _totalCost,
    'runCount': _runCount,
    'metadata': metadata.isEmpty ? null : metadata,
  });

  @override
  String toString() =>
      'AgentSession($id, ${_history.length} messages, $_runCount runs)';
}
