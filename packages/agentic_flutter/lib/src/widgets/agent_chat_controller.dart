/// The state behind a chat screen.
library;

import 'dart:async';

import 'package:agentic_agents/agentic_agents.dart';
import 'package:agentic_core/agentic_core.dart';
import 'package:agentic_flutter/src/runtime/agentic_runtime.dart';
import 'package:flutter/foundation.dart';

/// One line in a chat transcript.
///
/// Distinct from [Message] on purpose. A transcript needs things a message does
/// not have — whether this turn is still streaming, whether it failed, what the
/// agent is currently doing — and a message needs to stay the immutable value
/// the rest of the framework passes around.
@immutable
final class ChatEntry {
  /// Creates an entry.
  ChatEntry({
    required this.id,
    required this.message,
    this.isStreaming = false,
    this.error,
    this.activity,
    List<String> toolCalls = const <String>[],
  }) : toolCalls = List<String>.unmodifiable(toolCalls);

  /// Stable identifier, so a list can key its rows.
  final String id;

  /// The message itself.
  final Message message;

  /// Whether more text is still arriving for this entry.
  final bool isStreaming;

  /// The failure, when the turn failed.
  final AgenticException? error;

  /// What the agent is doing right now, such as `searching the handbook`.
  ///
  /// The difference between a spinner and a screen that tells the user why it
  /// is taking eleven seconds.
  final String? activity;

  /// Tools called during this turn, in order.
  final List<String> toolCalls;

  /// Who wrote it.
  MessageRole get role => message.role;

  /// The text so far.
  String get text => message.text;

  /// Whether this entry is a failure.
  bool get isError => error != null;

  /// Returns a copy with selected fields replaced.
  ChatEntry copyWith({
    Message? message,
    bool? isStreaming,
    AgenticException? error,
    String? activity,
    List<String>? toolCalls,
    bool clearActivity = false,
  }) => ChatEntry(
    id: id,
    message: message ?? this.message,
    isStreaming: isStreaming ?? this.isStreaming,
    error: error ?? this.error,
    activity: clearActivity ? null : (activity ?? this.activity),
    toolCalls: toolCalls ?? this.toolCalls,
  );

  @override
  String toString() =>
      'ChatEntry($id, ${role.name}, ${text.length} chars'
      '${isStreaming ? ', streaming' : ''})';
}

/// Drives a chat screen against an [Agent].
///
/// # Why a controller and not a `StreamBuilder`
///
/// A chat screen is not one stream. It is a transcript that grows, a turn that
/// may be cancelled, a session whose history must survive rebuilds, and an
/// error that has to be shown without discarding what came before. A
/// `StreamBuilder` models exactly one of those.
///
/// This is a plain [ChangeNotifier], so it works with `ListenableBuilder`,
/// `provider`, `riverpod` or nothing at all.
///
/// ```dart
/// final controller = AgentChatController(agent: agent, runtime: runtime);
///
/// // In the widget:
/// ListenableBuilder(
///   listenable: controller,
///   builder: (context, _) => ChatList(entries: controller.entries),
/// );
///
/// await controller.send('What shipped in Dart 3.11?');
/// ```
///
/// # Cancellation is a first-class button
///
/// [cancel] stops the current turn, and the entry it was writing keeps whatever
/// text had already arrived. A chat that can only be waited out is a chat whose
/// users force-quit the app, which cancels nothing and bills for everything.
final class AgentChatController extends ChangeNotifier {
  /// Creates a controller.
  ///
  /// [session] carries history between turns. Without one every turn starts
  /// from nothing, which is occasionally what you want and usually a bug.
  AgentChatController({
    required this.agent,
    this.runtime,
    AgentSession? session,
    this.context,
    this.streaming = true,
  }) : session = session ?? AgentSession();

  /// The agent that answers.
  final Agent agent;

  /// Where the run context comes from, when there is a runtime.
  final AgenticRuntime? runtime;

  /// Conversation history.
  final AgentSession session;

  /// A context to use when there is no [runtime].
  final AgenticContext? context;

  /// Whether answers stream token by token.
  final bool streaming;

  final List<ChatEntry> _entries = <ChatEntry>[];
  CancellationTokenSource? _turn;
  int _sequence = 0;
  bool _disposed = false;

  /// The transcript.
  List<ChatEntry> get entries => List<ChatEntry>.unmodifiable(_entries);

  /// Whether a turn is in progress.
  bool get isBusy => _turn != null;

  /// What the agent is doing, when it is doing something.
  String? get activity => _entries.isEmpty ? null : _entries.last.activity;

  /// Sends [text] and awaits the answer.
  ///
  /// Returns the assistant's entry, whether it succeeded or failed. Concurrent
  /// calls are rejected rather than queued: two turns racing on one session
  /// interleave their history, and the resulting transcript is wrong in a way
  /// that is very hard to see.
  Future<ChatEntry> send(String text) async {
    if (_disposed) {
      throw InvalidStateException(
        'This AgentChatController has been disposed.',
        currentState: 'disposed',
        expectedState: 'open',
      );
    }
    if (isBusy) {
      throw InvalidStateException(
        'A turn is already running. Await it, or call `cancel()` first.',
        currentState: 'busy',
        expectedState: 'idle',
      );
    }

    _append(ChatEntry(id: 'u${_sequence++}', message: Message.user(text)));
    final answer = ChatEntry(
      id: 'a${_sequence++}',
      message: Message.assistant(''),
      isStreaming: streaming,
      activity: 'thinking',
    );
    _append(answer);

    final source = CancellationTokenSource();
    _turn = source;
    notifyListeners();

    try {
      final scope = _contextFor(source.token);
      final result = streaming
          ? await _runStreaming(answer.id, text, scope)
          : await _runBuffered(answer.id, text, scope);
      return result;
    } finally {
      _turn = null;
      await source.dispose();
      if (!_disposed) notifyListeners();
    }
  }

  /// Stops the turn in progress, keeping whatever text had arrived.
  void cancel([String reason = 'the user stopped it']) {
    _turn?.cancel(reason);
  }

  /// Empties the transcript and the session.
  void clear() {
    cancel('the conversation was cleared');
    _entries.clear();
    session.clear();
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    cancel('the screen was closed');
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // Internals
  // ---------------------------------------------------------------------------

  AgenticContext _contextFor(CancellationToken token) {
    final base = context ?? runtime?.context ?? AgenticContext.root();
    return base.child('chat.turn', cancellation: token);
  }

  Future<ChatEntry> _runStreaming(
    String id,
    String text,
    AgenticContext scope,
  ) async {
    final buffer = StringBuffer();
    final tools = <String>[];

    try {
      await for (final chunk in agent.stream(
        AgentInput.text(text),
        session: session,
        context: scope,
      )) {
        switch (chunk) {
          case AgentTextDelta(:final text):
            buffer.write(text);
            _update(
              id,
              (entry) => entry.copyWith(
                message: Message.assistant(buffer.toString()),
                clearActivity: true,
              ),
            );
          case AgentToolCallStarted(:final toolName):
            tools.add(toolName);
            _update(
              id,
              (entry) => entry.copyWith(
                activity: 'using $toolName',
                toolCalls: List<String>.of(tools),
              ),
            );
          case AgentToolCallFinished(:final toolName, :final isError):
            _update(
              id,
              (entry) => entry.copyWith(
                activity: isError ? '$toolName failed' : 'thinking',
              ),
            );
          case AgentFinished(:final result):
            // `result.error` and not just `result.message`. An agent reports a
            // failure it handled by *finishing* with an error attached, not by
            // throwing — throwing is reserved for what it could not handle. So
            // the common failures, an rejected API key above all, arrive here
            // rather than in the catch below. Reading only the message renders
            // them as ordinary answers and leaves every error affordance —
            // the styling, the actionable text in `ChatEntryTile` — dead in
            // exactly the case they were written for.
            _update(
              id,
              (entry) => entry.copyWith(
                message: result.message,
                error: result.error,
                isStreaming: false,
                clearActivity: true,
              ),
            );
          default:
            // A chunk type added by a newer agent, or one this screen has no
            // opinion about. Ignoring it is correct; failing on it would make
            // every new chunk kind a breaking change for every chat screen.
            break;
        }
      }
      return _finish(id);
    } on CancelledException {
      _update(
        id,
        (entry) => entry.copyWith(isStreaming: false, activity: 'stopped'),
      );
      return _finish(id);
    } on AgenticException catch (error) {
      _update(
        id,
        (entry) => entry.copyWith(
          isStreaming: false,
          error: error,
          clearActivity: true,
        ),
      );
      return _finish(id);
    }
  }

  Future<ChatEntry> _runBuffered(
    String id,
    String text,
    AgenticContext scope,
  ) async {
    try {
      final result = await agent.run(
        AgentInput.text(text),
        session: session,
        context: scope,
      );
      _update(
        id,
        (entry) => entry.copyWith(
          message: result.message,
          isStreaming: false,
          clearActivity: true,
          toolCalls: <String>[
            for (final step in result.steps)
              for (final call in step.toolCalls) call.name,
          ],
        ),
      );
    } on CancelledException {
      _update(id, (entry) => entry.copyWith(activity: 'stopped'));
    } on AgenticException catch (error) {
      _update(id, (entry) => entry.copyWith(error: error, clearActivity: true));
    }
    return _finish(id);
  }

  void _append(ChatEntry entry) {
    _entries.add(entry);
    if (!_disposed) notifyListeners();
  }

  void _update(String id, ChatEntry Function(ChatEntry entry) change) {
    final index = _entries.indexWhere((entry) => entry.id == id);
    if (index < 0) return;
    _entries[index] = change(_entries[index]);
    if (!_disposed) notifyListeners();
  }

  ChatEntry _finish(String id) =>
      _entries.firstWhere((entry) => entry.id == id);

  @override
  String toString() =>
      'AgentChatController(${_entries.length} entries'
      '${isBusy ? ', busy' : ''})';
}
