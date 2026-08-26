/// The ambient environment of a single run.
///
/// Every long-running operation in the framework needs the same six things: an
/// identity for the run, a way to be cancelled, somewhere to log, somewhere to
/// publish events, a tracer, and a clock. Threading six parameters through
/// every method signature is unusable; reaching for six globals is untestable.
///
/// [AgenticContext] bundles them into one value that is passed explicitly and
/// derived with [AgenticContext.child] as work nests.
///
/// # Why explicit, and not a Zone
///
/// Dart's `Zone` could carry this implicitly, and it is tempting. It is also a
/// trap in Flutter: zone values do not survive an isolate hop, they are
/// invisible in a stack trace, they make a function's dependencies impossible
/// to read from its signature, and a widget rebuild can easily run code in a
/// different zone than the one that started the operation. Explicit context is
/// more typing and far less debugging.
///
/// ```dart
/// final context = AgenticContext.root(
///   logger: StructuredLogger(level: LogLevel.debug),
///   events: BroadcastEventBus(),
/// );
///
/// final scoped = context.child('agent.researcher');
/// scoped.logger.info('Starting research');
/// scoped.throwIfCancelled();
/// ```
library;

import 'dart:async';

import 'package:agentic_core/src/cancellation/cancellation.dart';
import 'package:agentic_core/src/common/agentic_id.dart';
import 'package:agentic_core/src/common/clock.dart';
import 'package:agentic_core/src/common/json_types.dart';
import 'package:agentic_core/src/context/human_wait.dart';
import 'package:agentic_core/src/error/agentic_exception.dart';
import 'package:agentic_core/src/events/agentic_event.dart';
import 'package:agentic_core/src/events/event_bus.dart';
import 'package:agentic_core/src/telemetry/log.dart';
import 'package:agentic_core/src/telemetry/trace.dart';
import 'package:meta/meta.dart';

/// Carries the identity, services and lifetime of one run.
///
/// Immutable. Deriving a scope produces a new context rather than mutating this
/// one, so a nested operation can never disturb its parent's view.
@immutable
final class AgenticContext {
  /// Creates a context from explicit collaborators.
  ///
  /// Prefer [AgenticContext.root] for the top of a run and
  /// [AgenticContext.child] for everything below it.
  AgenticContext({
    required this.runId,
    required this.logger,
    required this.events,
    required this.tracer,
    required this.clock,
    required this.ids,
    required this.cancellation,
    this.name = 'root',
    this.traceContext,
    this.deadline,
    HumanWaitLedger? humanWait,
    Map<String, Object?> metadata = const <String, Object?>{},
  }) : humanWait = humanWait ?? HumanWaitLedger(),
       metadata = metadata.isEmpty
           ? const <String, Object?>{}
           : Map<String, Object?>.unmodifiable(metadata);

  /// Creates a root context, filling in inert defaults for anything omitted.
  ///
  /// The defaults are deliberately silent — a [NoopLogger], a [NoopEventBus]
  /// and a non-exporting [Tracer] — so that a library using the framework
  /// produces no output unless the host application asked for it.
  factory AgenticContext.root({
    String? runId,
    AgenticLogger? logger,
    EventBus? events,
    Tracer? tracer,
    Clock clock = const SystemClock(),
    IdGenerator? ids,
    CancellationToken? cancellation,
    String name = 'root',
    Duration? timeout,
    Map<String, Object?> metadata = const <String, Object?>{},
  }) {
    final generator = ids ?? Ulid();
    final token = timeout == null
        ? cancellation.orNone
        : CancellationTokenSource.timeout(timeout, clock: clock).token;
    return AgenticContext(
      runId: runId ?? generator.prefixed('run'),
      logger: logger ?? const NoopLogger(),
      events: events ?? const NoopEventBus(),
      tracer: tracer ?? Tracer(clock: clock, ids: generator),
      clock: clock,
      ids: generator,
      cancellation: token,
      name: name,
      deadline: timeout == null ? null : clock.now().add(timeout),
      metadata: metadata,
    );
  }

  /// Identifier shared by every operation and event in this run.
  ///
  /// The field every log line, event and span is correlated by. One run, one
  /// identifier, however deeply the work nests.
  final String runId;

  /// Dotted scope name, such as `root.agent.researcher.tool`.
  final String name;

  /// Logger bound to this scope.
  final AgenticLogger logger;

  /// Bus this scope publishes events to.
  final EventBus events;

  /// Tracer this scope creates spans from.
  final Tracer tracer;

  /// Clock for every time-dependent operation in this scope.
  final Clock clock;

  /// Identifier generator for events, messages and spans.
  final IdGenerator ids;

  /// Cancellation signal for this scope.
  final CancellationToken cancellation;

  /// The enclosing span, when this scope is inside one.
  final TraceContext? traceContext;

  /// Absolute deadline for this scope, when one applies.
  final DateTime? deadline;

  /// Time this run has spent blocked on a person.
  ///
  /// Shared by the whole run: [child] passes this same instance down, so a
  /// wait recorded inside a tool call is visible to whatever is enforcing a
  /// budget at the top of the loop. Mutable state on an otherwise immutable
  /// value, and deliberately so — the alternative is a wait that only the
  /// scope which recorded it can see, which is no use to the only code that
  /// needs to know.
  final HumanWaitLedger humanWait;

  /// Application-defined metadata inherited by child scopes.
  ///
  /// The natural home for a user identifier, a tenant, a session — anything
  /// that should appear on every log line and event without being passed
  /// explicitly.
  final Map<String, Object?> metadata;

  /// Time left before [deadline], or `null` when unbounded.
  ///
  /// Negative when the deadline has already passed, which callers should treat
  /// as "do not start new work".
  Duration? get remaining => deadline?.difference(clock.now());

  /// Whether a deadline exists and has passed.
  bool get isExpired {
    final left = remaining;
    return left != null && left.isNegative;
  }

  /// Derives a nested scope named [name].
  ///
  /// The child inherits everything and overrides what is supplied. The logger
  /// is re-scoped so its records carry the nested name, and metadata is merged
  /// rather than replaced.
  ///
  /// A child's [timeout] is clamped to the parent's remaining time: a step can
  /// never outlive the run that owns it.
  AgenticContext child(
    String name, {
    AgenticLogger? logger,
    EventBus? events,
    Tracer? tracer,
    CancellationToken? cancellation,
    TraceContext? traceContext,
    Duration? timeout,
    Map<String, Object?> metadata = const <String, Object?>{},
  }) {
    final childName = '${this.name}.$name';
    final effectiveTimeout = _clampToParentDeadline(timeout);
    final childToken = effectiveTimeout == null
        ? (cancellation ?? this.cancellation)
        : CancellationToken.merge(
            cancellation ?? this.cancellation,
            CancellationTokenSource.timeout(
              effectiveTimeout,
              clock: clock,
            ).token,
            clock: clock,
          ).token;

    final mergedMetadata = metadata.isEmpty
        ? this.metadata
        : <String, Object?>{...this.metadata, ...metadata};

    return AgenticContext(
      runId: runId,
      name: childName,
      logger: (logger ?? this.logger).child(
        name,
        fields: metadata.isEmpty ? const <String, Object?>{} : metadata,
      ),
      events: events ?? this.events,
      tracer: tracer ?? this.tracer,
      clock: clock,
      ids: ids,
      cancellation: childToken,
      traceContext: traceContext ?? this.traceContext,
      humanWait: humanWait,
      deadline: effectiveTimeout == null
          ? deadline
          : clock.now().add(effectiveTimeout),
      metadata: mergedMetadata,
    );
  }

  /// Throws a [CancelledException] if this scope has been cancelled.
  ///
  /// Also throws when a deadline has passed, so a single call covers both ways
  /// a run can be out of time.
  void throwIfCancelled() {
    cancellation.throwIfCancelled(operation: name);
    if (isExpired) {
      throw CancelledException(
        '`$name` exceeded its deadline.',
        operation: name,
        reason: 'deadline exceeded',
      );
    }
  }

  /// Publishes [event] on this scope's bus.
  void publish(AgenticEvent event) => events.publish(event);

  /// Runs [body] inside a span and a matching child scope.
  ///
  /// The idiomatic way to instrument a step: the span is ended in every
  /// outcome, the child context carries the span's trace identifiers, and log
  /// records emitted inside are correlated to it automatically.
  ///
  /// ```dart
  /// final answer = await context.step('llm.generate', (scope, span) async {
  ///   span.setAttribute('llm.model', model.id);
  ///   return model.generate(request, context: scope);
  /// });
  /// ```
  Future<T> step<T>(
    String name,
    Future<T> Function(AgenticContext context, Span span) body, {
    SpanKind kind = SpanKind.internal,
    Map<String, Object?> attributes = const <String, Object?>{},
    Duration? timeout,
  }) {
    throwIfCancelled();
    return tracer.trace(
      name,
      (span) {
        final scope = child(name, traceContext: span.context, timeout: timeout);
        return body(scope, span);
      },
      parent: traceContext,
      kind: kind,
      attributes: <String, Object?>{'run.id': runId, ...attributes},
    );
  }

  /// Returns a copy with [entries] merged into [metadata].
  AgenticContext withMetadata(Map<String, Object?> entries) => AgenticContext(
    runId: runId,
    name: name,
    logger: logger.withFields(entries),
    events: events,
    tracer: tracer,
    clock: clock,
    ids: ids,
    cancellation: cancellation,
    traceContext: traceContext,
    deadline: deadline,
    metadata: <String, Object?>{...metadata, ...entries},
  );

  /// Serialises the identifying parts of this context.
  ///
  /// Collaborators are not included: this describes *where* the run is, not
  /// what it is wired to.
  JsonMap toJson() => pruneNulls(<String, Object?>{
    'runId': runId,
    'name': name,
    'traceId': traceContext?.traceId,
    'spanId': traceContext?.spanId,
    'deadline': deadline?.toIso8601String(),
    'cancelled': cancellation.isCancelled ? true : null,
    'metadata': metadata.isEmpty ? null : metadata,
  });

  Duration? _clampToParentDeadline(Duration? requested) {
    final parentRemaining = remaining;
    if (requested == null) return null;
    if (parentRemaining == null) return requested;
    return requested < parentRemaining ? requested : parentRemaining;
  }

  @override
  String toString() => 'AgenticContext($name, run: $runId)';
}
