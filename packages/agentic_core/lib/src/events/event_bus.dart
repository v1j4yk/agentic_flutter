/// Publish/subscribe delivery of [AgenticEvent]s.
///
/// The bus is how the framework stays decoupled: an agent publishes what
/// happened and never learns who cared. A chat UI, a cost meter, an audit
/// writer and a test can all observe the same run without the agent holding a
/// reference to any of them.
///
/// # Why replay exists
///
/// A Flutter screen almost never subscribes before the work starts. The user
/// taps send, a run begins, and the widget that renders it builds one frame
/// later — by which time the first events are gone, because broadcast streams
/// do not remember. That produces the classic "the first token is always
/// missing" bug.
///
/// [BroadcastEventBus] therefore keeps a bounded replay buffer and delivers it
/// to every new subscriber before live events. Set `replayBufferSize: 0` to opt
/// out where the memory matters more than the completeness.
library;

import 'dart:async';

import 'package:agentic_core/src/common/disposable.dart';
import 'package:agentic_core/src/events/agentic_event.dart';

/// Delivers events to interested subscribers.
///
/// Implement this to bridge the framework onto another transport — an isolate
/// port, a WebSocket, a platform channel — but prefer composing with
/// [BroadcastEventBus] over reimplementing delivery semantics.
abstract interface class EventBus implements Disposable {
  /// Every event, in publication order.
  Stream<AgenticEvent> get events;

  /// Whether [dispose] has been called.
  bool get isClosed;

  /// Publishes [event] to all current subscribers.
  ///
  /// Never throws. Delivery to subscribers is asynchronous, so publishing does
  /// not run listener code inline and a slow listener cannot stall the
  /// publisher.
  void publish(AgenticEvent event);

  /// Events of type [T] only.
  ///
  /// The type-safe way to observe a subset of a run:
  ///
  /// ```dart
  /// bus.on<TokenReceivedEvent>().listen((e) => buffer.write(e.text));
  /// ```
  Stream<T> on<T extends AgenticEvent>();
}

/// The default [EventBus]: a broadcast stream with bounded replay.
///
/// Safe to share across a whole application. Create a child bus per run only if
/// runs must not observe one another.
final class BroadcastEventBus implements EventBus {
  /// Creates a bus.
  ///
  /// [replayBufferSize] is how many recent events a new subscriber receives
  /// before live delivery begins. The default of 64 is enough to cover the
  /// frame or two between starting a run and a widget subscribing, without
  /// retaining a long conversation's worth of events.
  ///
  /// [onDropped] is invoked when an event is published after the bus is closed.
  /// Publishing during teardown is a normal race — a run finishing while a
  /// screen disposes — so it is not an error, but a host application may want
  /// to know it happened.
  BroadcastEventBus({
    this.replayBufferSize = 64,
    void Function(AgenticEvent event)? onDropped,
  }) : assert(replayBufferSize >= 0, 'replayBufferSize must not be negative'),
       _onDropped = onDropped;

  /// Number of recent events replayed to a new subscriber.
  final int replayBufferSize;

  final void Function(AgenticEvent event)? _onDropped;
  final StreamController<AgenticEvent> _controller =
      StreamController<AgenticEvent>.broadcast(sync: false);
  final List<AgenticEvent> _replay = <AgenticEvent>[];

  int _publishedCount = 0;
  int _droppedCount = 0;
  bool _closed = false;

  /// Total events accepted for delivery.
  int get publishedCount => _publishedCount;

  /// Total events discarded because the bus was closed.
  int get droppedCount => _droppedCount;

  /// The events currently held for replay, oldest first.
  List<AgenticEvent> get replayBuffer =>
      List<AgenticEvent>.unmodifiable(_replay);

  @override
  bool get isClosed => _closed;

  @override
  Stream<AgenticEvent> get events => on<AgenticEvent>();

  @override
  void publish(AgenticEvent event) {
    if (_closed) {
      _droppedCount++;
      _onDropped?.call(event);
      return;
    }
    _publishedCount++;
    if (replayBufferSize > 0) {
      _replay.add(event);
      if (_replay.length > replayBufferSize) _replay.removeAt(0);
    }
    _controller.add(event);
  }

  @override
  Stream<T> on<T extends AgenticEvent>() => Stream<T>.multi((controller) {
    if (_closed) {
      unawaited(controller.close());
      return;
    }

    // Subscribe before replaying. Dart delivers on a single thread, so nothing
    // can be published between these two statements — but subscribing first
    // also makes the ordering guarantee obvious rather than incidental.
    final subscription = _controller.stream.listen(
      (event) {
        if (event is T) controller.add(event);
      },
      onError: controller.addError,
      onDone: controller.close,
    );

    for (final event in _replay) {
      if (event is T) controller.add(event);
    }

    controller.onCancel = subscription.cancel;
  }, isBroadcast: true);

  /// Discards the replay buffer without closing the bus.
  ///
  /// Call this at the end of a run so that the next subscriber is not replayed
  /// a previous conversation's events.
  void clearReplay() => _replay.clear();

  @override
  Future<void> dispose() async {
    if (_closed) return;
    _closed = true;
    _replay.clear();
    await _controller.close();
  }
}

/// An [EventBus] that accepts events and delivers nothing.
///
/// The default for components that publish but whose host has not opted into
/// observing. Publishing costs one field increment.
final class NoopEventBus implements EventBus {
  /// Creates the no-op bus.
  const NoopEventBus();

  @override
  Stream<AgenticEvent> get events => const Stream<AgenticEvent>.empty();

  @override
  bool get isClosed => false;

  @override
  void publish(AgenticEvent event) {}

  @override
  Stream<T> on<T extends AgenticEvent>() => const Stream<Never>.empty();

  @override
  Future<void> dispose() async {}
}

/// Convenience subscriptions available on every [EventBus].
extension EventBusOperations on EventBus {
  /// Events of type [T] that also satisfy [predicate].
  Stream<T> where<T extends AgenticEvent>(bool Function(T event) predicate) =>
      on<T>().where(predicate);

  /// Events belonging to the run identified by [runId].
  ///
  /// The single most common filter: one screen renders one run, and must not
  /// react to a background run happening at the same time.
  Stream<T> forRun<T extends AgenticEvent>(String runId) =>
      on<T>().where((event) => event.runId == runId);

  /// Completes with the first event of type [T] satisfying [predicate].
  ///
  /// Used to await a milestone — a human approval, a workflow reaching a node —
  /// without hand-rolling a subscription and a completer.
  Future<T> next<T extends AgenticEvent>({bool Function(T event)? predicate}) =>
      predicate == null ? on<T>().first : on<T>().firstWhere(predicate);

  /// Collects every event of type [T] until [signal] completes.
  ///
  /// Convenient in tests: run the operation, then assert on the whole sequence
  /// rather than on individual callbacks.
  Future<List<T>> collect<T extends AgenticEvent>(Future<void> signal) async {
    final collected = <T>[];
    final subscription = on<T>().listen(collected.add);
    try {
      await signal;
    } finally {
      await subscription.cancel();
    }
    return collected;
  }
}
