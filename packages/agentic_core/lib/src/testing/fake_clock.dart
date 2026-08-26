/// A [Clock] whose time is controlled by the test.
///
/// Anything in the framework that waits does so through a [Clock], so
/// substituting this one makes time a test input. A retry policy with a
/// ten-minute budget can be exercised in under a millisecond, and — more
/// valuable than the speed — the test asserts on the *exact* delays that were
/// requested rather than on the fact that something eventually finished.
library;

import 'dart:async';

import 'package:agentic_core/src/common/clock.dart';
import 'package:meta/meta.dart';

/// A manually or automatically advanced clock.
///
/// Two modes:
///
/// **Manual** — the default. [delay] returns a future that completes only when
/// [advance] moves time past it. Use this to test ordering and concurrency:
/// what happens when a timeout fires while a request is in flight.
///
/// ```dart
/// final clock = FakeClock();
/// final pending = policy.execute(action, operation: 'test', clock: clock);
/// await clock.advance(const Duration(seconds: 5));
/// await pending;
/// ```
///
/// **Auto-advancing** — every [delay] completes on the next microtask and time
/// jumps forward by the requested amount. Use this to test schedules: run the
/// operation, then assert on [requestedDelays].
///
/// ```dart
/// final clock = FakeClock(autoAdvance: true);
/// await policy.execute(failingAction, operation: 'test', clock: clock);
/// expect(clock.requestedDelays, hasLength(2)); // three attempts, two waits
/// ```
@visibleForTesting
final class FakeClock implements Clock {
  /// Creates a fake clock starting at [initialTime].
  ///
  /// The default epoch is a fixed, arbitrary instant so that tests which format
  /// timestamps produce stable output.
  FakeClock({DateTime? initialTime, this.autoAdvance = false})
    : _now = initialTime?.toUtc() ?? DateTime.utc(2026, 1, 1);

  /// Whether delays complete on their own, advancing time as they do.
  final bool autoAdvance;

  final List<_PendingDelay> _pending = <_PendingDelay>[];
  final List<Duration> _requestedDelays = <Duration>[];
  DateTime _now;

  /// Every delay that has been requested, in order.
  ///
  /// The assertion surface for backoff schedules, rate limiters and timeouts.
  List<Duration> get requestedDelays =>
      List<Duration>.unmodifiable(_requestedDelays);

  /// Number of delays still waiting to complete.
  int get pendingCount => _pending.length;

  /// The total of every requested delay.
  Duration get totalRequestedDelay =>
      _requestedDelays.fold(Duration.zero, (sum, delay) => sum + delay);

  @override
  DateTime now() => _now;

  @override
  Future<void> delay(Duration duration) {
    final effective = duration.isNegative ? Duration.zero : duration;
    _requestedDelays.add(effective);

    if (autoAdvance) {
      // Advance on a microtask rather than synchronously, so that code awaiting
      // this delay yields exactly as it would against a real clock. Completing
      // synchronously would hide ordering bugs that only appear in production.
      return Future<void>.microtask(() {
        _now = _now.add(effective);
      });
    }

    if (effective == Duration.zero) return Future<void>.value();

    final pending = _PendingDelay(_now.add(effective), Completer<void>());
    _pending.add(pending);
    return pending.completer.future;
  }

  /// Moves time forward by [duration], completing every delay that comes due.
  ///
  /// Delays complete in due order, and the returned future settles only after
  /// the microtask queue has drained — so `await clock.advance(...)` leaves the
  /// system in the state it would be in after that much real time.
  ///
  /// A delay scheduled *by* a completing delay is also honoured: the loop keeps
  /// going until nothing else is due, which is what makes a multi-step retry
  /// sequence testable with a single call.
  Future<void> advance(Duration duration) async {
    if (duration.isNegative) {
      throw ArgumentError.value(
        duration,
        'duration',
        'Time cannot move backwards on a FakeClock; that would make already '
            'completed delays un-complete.',
      );
    }
    final target = _now.add(duration);

    while (true) {
      _pending.sort((a, b) => a.dueAt.compareTo(b.dueAt));
      final index = _pending.indexWhere(
        (pending) => !pending.dueAt.isAfter(target),
      );
      if (index < 0) break;

      final due = _pending.removeAt(index);
      _now = due.dueAt;
      if (!due.completer.isCompleted) due.completer.complete();

      // Let whatever was waiting run before considering the next timer, so that
      // work scheduled by this delay is visible to the rest of the advance.
      await _drainMicrotasks();
    }

    _now = target;
    await _drainMicrotasks();
  }

  /// Moves time forward to the next pending delay, completing it.
  ///
  /// Returns the amount of time that passed, or `null` when nothing was
  /// pending. Use it to step through a schedule one wait at a time.
  Future<Duration?> advanceToNext() async {
    if (_pending.isEmpty) return null;
    _pending.sort((a, b) => a.dueAt.compareTo(b.dueAt));
    final elapsed = _pending.first.dueAt.difference(_now);
    await advance(elapsed);
    return elapsed;
  }

  /// Completes every pending delay immediately, without advancing time.
  ///
  /// For teardown: a test that finishes with delays outstanding would otherwise
  /// leave futures that never complete, which surfaces later as a confusing
  /// timeout in an unrelated test.
  Future<void> resolvePending() async {
    final outstanding = List<_PendingDelay>.of(_pending);
    _pending.clear();
    for (final pending in outstanding) {
      if (!pending.completer.isCompleted) pending.completer.complete();
    }
    await _drainMicrotasks();
  }

  /// Forgets every recorded delay, keeping the current time.
  void clearRecordedDelays() => _requestedDelays.clear();

  static Future<void> _drainMicrotasks() => Future<void>.delayed(Duration.zero);

  @override
  String toString() =>
      'FakeClock(${_now.toIso8601String()}, '
      'pending: ${_pending.length}, requested: ${_requestedDelays.length})';
}

final class _PendingDelay {
  _PendingDelay(this.dueAt, this.completer);

  final DateTime dueAt;
  final Completer<void> completer;
}
