/// Where conversations are kept between launches.
///
/// # Why a port, when `AgentSession` already serialises
///
/// `toJson` and `fromJson` make a session *storable*; they do not say where it
/// goes, how the list of past conversations is read, or what happens to one the
/// user deletes. Every app that shows a conversation list writes that code, and
/// every one of them writes it slightly differently. This is the one contract,
/// so an app can start on [InMemorySessionStore] and move to a durable adapter
/// — `agentic_sqlite` has one — without touching the screens that use it.
library;

import 'dart:convert';

import 'package:agentic_agents/src/agent/agent_session.dart';
import 'package:agentic_core/agentic_core.dart';
import 'package:meta/meta.dart';

/// A stored conversation, without its messages.
///
/// What a conversation list needs to draw a row. Loading every message of
/// every past conversation to show their titles is the mistake this avoids.
@immutable
final class SessionSummary {
  /// Creates a summary.
  const SessionSummary({
    required this.id,
    required this.updatedAt,
    required this.messageCount,
    this.metadata = const <String, Object?>{},
  });

  /// The session's identifier.
  final String id;

  /// When the session was last saved.
  final DateTime updatedAt;

  /// How many messages it holds.
  final int messageCount;

  /// The session's application-defined metadata, such as a title.
  final JsonMap metadata;

  @override
  String toString() => 'SessionSummary($id, $messageCount messages)';
}

/// Keeps [AgentSession]s between launches.
abstract interface class SessionStore implements Disposable {
  /// Saves [session], replacing any earlier save of the same id.
  Future<void> save(AgentSession session);

  /// The session saved under [id], or `null`.
  ///
  /// [strategy] is supplied here rather than stored, as it is for
  /// `AgentSession.fromJson`: how history is trimmed is the application's
  /// current choice, not a fact about a conversation from last month.
  Future<AgentSession?> load(String id, {HistoryStrategy? strategy});

  /// Deletes the session saved under [id]. Returns whether one existed.
  Future<bool> delete(String id);

  /// Every stored session, most recently updated first.
  Future<List<SessionSummary>> list();
}

/// A [SessionStore] that lives as long as the process.
///
/// Sessions are kept as JSON, not as objects, so it behaves like a durable
/// store: a session holding something that does not serialise fails here, in a
/// test, rather than the first time it is saved to disk on a user's phone.
final class InMemorySessionStore implements SessionStore {
  /// Creates an empty store.
  InMemorySessionStore({Clock clock = const SystemClock()}) : _clock = clock;

  final Clock _clock;
  final Map<String, ({String json, SessionSummary summary})> _sessions =
      <String, ({String json, SessionSummary summary})>{};

  @override
  Future<void> save(AgentSession session) async {
    _sessions[session.id] = (
      json: jsonEncode(session.toJson()),
      summary: SessionSummary(
        id: session.id,
        updatedAt: _clock.now(),
        messageCount: session.history.length,
        metadata: Map<String, Object?>.unmodifiable(session.metadata),
      ),
    );
  }

  @override
  Future<AgentSession?> load(String id, {HistoryStrategy? strategy}) async {
    final stored = _sessions[id];
    if (stored == null) return null;
    return AgentSession.fromJson(
      (jsonDecode(stored.json) as Map).cast<String, Object?>(),
      strategy: strategy,
    );
  }

  @override
  Future<bool> delete(String id) async => _sessions.remove(id) != null;

  @override
  Future<List<SessionSummary>> list() async =>
      List<SessionSummary>.unmodifiable(
        _sessions.values.map((stored) => stored.summary).toList()
          ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt)),
      );

  @override
  Future<void> dispose() async => _sessions.clear();
}
