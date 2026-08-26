/// An injectable source of time.
///
/// Everything in the framework that waits — retry backoff, rate limiting,
/// circuit-breaker recovery, workflow delay nodes, scheduled agents, cache
/// expiry — waits through a [Clock] rather than by calling
/// `Future.delayed` directly.
///
/// The reason is testability. A retry policy that sleeps for real turns a unit
/// test into a multi-second integration test, and a test that asserts on
/// exponential backoff by actually sleeping for 8 seconds will be deleted by
/// the first engineer who has to run the suite. With an injected clock the same
/// test runs in microseconds and asserts on the *exact* delays requested, which
/// is a stronger assertion than "it eventually finished".
///
/// `FakeClock`, in `package:agentic_core/testing.dart`, is the counterpart.
library;

import 'dart:async';

import 'package:agentic_core/src/error/agentic_exception.dart';

/// A source of the current time and of delays.
///
/// Prefer `extends Clock` over `implements Clock` in downstream code: this
/// class is a pure interface today, but extending it means a future default
/// method arrives without breaking your implementation.
abstract interface class Clock {
  /// The current instant, always in UTC.
  ///
  /// UTC is not a preference, it is a correctness requirement: agent runs are
  /// suspended on one device and resumed on another, memories are written on a
  /// phone and read on a desktop, and traces are merged across time zones. A
  /// local `DateTime` in any of those paths is a bug waiting for a user to
  /// travel.
  DateTime now();

  /// Completes after [duration] has elapsed on this clock.
  ///
  /// A zero or negative [duration] must complete without delay, but still
  /// asynchronously, so that callers cannot accidentally depend on synchronous
  /// completion.
  Future<void> delay(Duration duration);
}

/// The production [Clock], backed by the platform clock and `dart:async`.
final class SystemClock implements Clock {
  /// Creates a system clock.
  ///
  /// The default constructor is `const` and every instance is
  /// interchangeable, so `const SystemClock()` is the idiomatic default value
  /// for a `Clock` parameter.
  const SystemClock();

  @override
  DateTime now() => DateTime.timestamp();

  @override
  Future<void> delay(Duration duration) =>
      Future<void>.delayed(duration.isNegative ? Duration.zero : duration);
}

/// Time-derived helpers that every [Clock] gets for free.
///
/// Defined as an extension rather than as interface members so that adding a
/// helper never breaks an existing implementation.
extension ClockOperations on Clock {
  /// Emits an event every [interval] until the subscription is cancelled.
  ///
  /// Unlike `Stream.periodic`, this drifts: each interval is measured from the
  /// end of the previous emission rather than from a fixed schedule. That is
  /// the correct behaviour for polling a queue or an agent's inbox, where
  /// overlapping ticks would be worse than a slow schedule.
  Stream<DateTime> periodic(Duration interval) async* {
    while (true) {
      await delay(interval);
      yield now();
    }
  }

  /// Runs [operation], failing with [AgenticTimeoutException] after [limit].
  ///
  /// Implemented against [Clock.delay] rather than `Future.timeout` so that a
  /// fake clock can drive it. [name] appears in the error and should identify
  /// the operation, for example `openai.chat.completions`.
  ///
  /// The underlying future is *not* cancelled — Dart futures cannot be — so
  /// operations that hold resources should also observe a
  /// `CancellationToken`. What this guarantees is that the caller stops
  /// waiting, not that the work stops running.
  Future<T> timeout<T>(
    Future<T> Function() operation, {
    required Duration limit,
    required String name,
  }) {
    final completer = Completer<T>();
    // Both completion paths below are wired into `completer`, so the future
    // is deliberately not awaited here.
    // ignore: discarded_futures
    final work = operation();
    unawaited(
      work.then<void>(
        (value) {
          if (!completer.isCompleted) completer.complete(value);
        },
        onError: (Object error, StackTrace stackTrace) {
          if (!completer.isCompleted) {
            completer.completeError(error, stackTrace);
          }
        },
      ),
    );
    unawaited(
      delay(limit).then((_) {
        if (completer.isCompleted) return;
        completer.completeError(
          AgenticTimeoutException(
            '`$name` did not complete within '
            '${limit.inMilliseconds}ms.',
            operation: name,
            timeout: limit,
          ),
          StackTrace.current,
        );
      }),
    );
    return completer.future;
  }

  /// Measures how long [operation] takes on this clock.
  ///
  /// Returns the value alongside the elapsed duration, so instrumentation does
  /// not need a second call to [Clock.now] at every call site.
  Future<(T value, Duration elapsed)> measure<T>(
    Future<T> Function() operation,
  ) async {
    final started = now();
    final value = await operation();
    return (value, now().difference(started));
  }
}
