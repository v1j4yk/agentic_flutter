/// Events published by the memory layer.
///
/// Memory is the part of an agentic system users are most likely to be
/// surprised by — "how did it know that?" and "why did it forget?" are both
/// support questions. These events are the record that answers them.
library;

import 'package:agentic_core/agentic_core.dart';

/// Base for every memory event.
abstract base class MemoryEvent extends AgenticEvent {
  /// Creates a memory event.
  const MemoryEvent({
    required super.id,
    required super.timestamp,
    this.agentName,
    this.sessionId,
    super.runId,
    super.source,
    super.traceId,
    super.spanId,
  });

  /// The agent involved, when there was one.
  final String? agentName;

  /// The conversation involved, when there was one.
  final String? sessionId;
}

/// Memories were extracted from an exchange and stored.
final class MemoriesExtracted extends MemoryEvent {
  /// Creates the event.
  const MemoriesExtracted({
    required super.id,
    required super.timestamp,
    required this.count,
    super.agentName,
    super.sessionId,
    super.runId,
    super.source,
    super.traceId,
    super.spanId,
  });

  /// How many entries were written.
  final int count;

  @override
  String get type => 'memory.extracted';

  @override
  JsonMap payload() =>
      pruneNulls(<String, Object?>{'agentName': agentName, 'count': count});
}

/// An extraction pass failed.
///
/// Published rather than thrown: memory is an enhancement, and a failed
/// extraction must not turn a good answer into an error the user sees. A rising
/// count here means the extraction model or its budget needs attention.
final class MemoryExtractionFailed extends MemoryEvent {
  /// Creates the event.
  const MemoryExtractionFailed({
    required super.id,
    required super.timestamp,
    required this.reason,
    super.agentName,
    super.sessionId,
    super.runId,
    super.source,
    super.traceId,
    super.spanId,
  });

  /// Why extraction failed.
  final String reason;

  @override
  String get type => 'memory.extraction_failed';

  @override
  JsonMap payload() =>
      pruneNulls(<String, Object?>{'agentName': agentName, 'reason': reason});
}

/// Memories were recalled and injected into a conversation.
///
/// The event that answers "how did it know that?". Recording what was recalled
/// — not merely how many — is what makes an unexpected answer traceable to the
/// memory that caused it.
final class MemoriesRecalled extends MemoryEvent {
  /// Creates the event.
  MemoriesRecalled({
    required super.id,
    required super.timestamp,
    required this.query,
    required this.count,
    List<String> contents = const <String>[],
    super.agentName,
    super.sessionId,
    super.runId,
    super.source,
    super.traceId,
    super.spanId,
  }) : contents = List<String>.unmodifiable(contents);

  /// What was searched for.
  final String query;

  /// How many entries were injected.
  final int count;

  /// The recalled statements.
  final List<String> contents;

  @override
  String get type => 'memory.recalled';

  @override
  JsonMap payload() => pruneNulls(<String, Object?>{
    'query': query,
    'count': count,
    'contents': contents.isEmpty ? null : contents,
  });
}

/// Expired entries were dropped.
final class MemoriesPruned extends MemoryEvent {
  /// Creates the event.
  const MemoriesPruned({
    required super.id,
    required super.timestamp,
    required this.count,
    super.agentName,
    super.sessionId,
    super.runId,
    super.source,
  });

  /// How many entries were removed.
  final int count;

  @override
  String get type => 'memory.pruned';

  @override
  JsonMap payload() => <String, Object?>{'count': count};
}
