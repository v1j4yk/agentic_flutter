/// Backoff strategies for retry scheduling.
///
/// Backoff is separated from `RetryPolicy` because the two answer different
/// questions. The policy decides *whether* to retry — is this error transient,
/// is there budget left, has the caller cancelled. The strategy decides *when*.
/// Keeping them apart means a new schedule needs no change to the retry loop,
/// and the schedule can be unit-tested as a pure function.
///
/// # Why jitter is not optional in practice
///
/// A mobile app that loses connectivity for ten seconds has every in-flight
/// request fail at once. With deterministic exponential backoff, all of them
/// retry at exactly the same instant, and keep colliding on every subsequent
/// attempt — a self-inflicted thundering herd against the provider that just
/// rate-limited you. Jitter spreads those retries out. [Jitter.full] is the
/// default for that reason, and it is the schedule AWS recommends after
/// measuring the alternatives.
library;

import 'dart:math';

import 'package:agentic_core/src/error/agentic_exception.dart';
import 'package:meta/meta.dart';

/// How randomness is applied to a computed backoff delay.
///
/// Given a computed delay `d` and a uniform random draw:
///
/// | Mode           | Resulting delay        | Character                     |
/// |----------------|------------------------|-------------------------------|
/// | [none]         | `d`                    | Predictable, collides         |
/// | [full]         | `random(0, d)`         | Best spread, lowest contention|
/// | [equal]        | `d/2 + random(0, d/2)` | Spread with a latency floor   |
/// | [decorrelated] | `random(base, prev*3)` | Adapts to observed congestion |
enum Jitter {
  /// No randomisation. Use only when a deterministic schedule is required,
  /// such as in a golden test.
  none,

  /// Uniformly random between zero and the computed delay.
  ///
  /// The default: it minimises collisions between clients, at the cost of
  /// occasionally retrying almost immediately.
  full,

  /// Half the computed delay plus a random half.
  ///
  /// Keeps a guaranteed minimum wait, which matters when the failure mode is a
  /// provider that needs a real pause rather than a de-synchronised herd.
  equal,

  /// Randomised against the *previous* delay rather than the nominal one.
  ///
  /// Grows faster under sustained failure and settles faster once the
  /// dependency recovers. The best choice for a long-lived background agent.
  decorrelated,
}

/// Computes the wait before a given retry attempt.
///
/// Implement this to add a schedule the framework does not ship.
/// Implementations must be pure and must never return a negative [Duration].
abstract interface class BackoffStrategy {
  /// Returns the delay to wait before [attempt].
  ///
  /// [attempt] is 1-based and counts the *upcoming* attempt, so the first
  /// retry is `attempt == 2`. [previousDelay] is what was waited before the
  /// preceding attempt, or [Duration.zero] for the first retry; only
  /// [Jitter.decorrelated] uses it, but it is part of the contract so that
  /// stateful schedules remain expressible without mutable strategy objects.
  Duration compute(int attempt, Duration previousDelay);
}

/// Waits the same [delay] before every attempt.
///
/// Appropriate for polling a resource whose readiness is not load-dependent —
/// a human approval node, a document conversion job — where exponential growth
/// would only add latency for no benefit.
@immutable
final class ConstantBackoff implements BackoffStrategy {
  /// Creates a fixed-delay schedule.
  const ConstantBackoff(this.delay, {this.jitter = Jitter.none, Random? random})
    : _random = random;

  /// The delay before every attempt.
  final Duration delay;

  /// Randomisation applied to [delay].
  final Jitter jitter;

  final Random? _random;

  @override
  Duration compute(int attempt, Duration previousDelay) =>
      applyJitter(delay, jitter, previousDelay, _random ?? _sharedRandom);

  @override
  String toString() => 'ConstantBackoff(${delay.inMilliseconds}ms)';
}

/// Grows the delay linearly: `initial * attempt`.
///
/// A middle ground between constant and exponential. Useful when the
/// dependency's recovery time scales with queue depth rather than with load.
@immutable
final class LinearBackoff implements BackoffStrategy {
  /// Creates a linear schedule.
  const LinearBackoff({
    this.initial = const Duration(milliseconds: 500),
    this.maximum = const Duration(seconds: 30),
    this.jitter = Jitter.full,
    Random? random,
  }) : _random = random;

  /// The delay before the first retry.
  final Duration initial;

  /// Ceiling applied before jitter.
  final Duration maximum;

  /// Randomisation applied to the computed delay.
  final Jitter jitter;

  final Random? _random;

  @override
  Duration compute(int attempt, Duration previousDelay) {
    final retryIndex = (attempt - 1).clamp(1, 1 << 20);
    final scaled = initial * retryIndex;
    final capped = scaled > maximum ? maximum : scaled;
    return applyJitter(capped, jitter, previousDelay, _random ?? _sharedRandom);
  }

  @override
  String toString() =>
      'LinearBackoff(initial: ${initial.inMilliseconds}ms, '
      'max: ${maximum.inMilliseconds}ms, jitter: ${jitter.name})';
}

/// Doubles the delay on every attempt, capped at [maximum].
///
/// The default schedule for network calls, and the right one for LLM providers:
/// their failure modes — overload, rate limiting, cold model load — all recover
/// on timescales that reward backing off quickly.
///
/// ```dart
/// // 500ms, 1s, 2s, 4s, 8s, then capped at 30s — each randomised by jitter.
/// const ExponentialBackoff();
/// ```
@immutable
final class ExponentialBackoff implements BackoffStrategy {
  /// Creates an exponential schedule.
  ///
  /// [multiplier] must be greater than 1; anything else would produce a flat or
  /// shrinking schedule, which is a configuration mistake rather than a valid
  /// choice.
  const ExponentialBackoff({
    this.initial = const Duration(milliseconds: 500),
    this.maximum = const Duration(seconds: 30),
    this.multiplier = 2.0,
    this.jitter = Jitter.full,
    Random? random,
  }) : assert(multiplier > 1, 'multiplier must be greater than 1'),
       _random = random;

  /// The nominal delay before the first retry.
  final Duration initial;

  /// Ceiling applied before jitter, so growth cannot run away.
  final Duration maximum;

  /// Growth factor applied per attempt.
  final double multiplier;

  /// Randomisation applied to the computed delay.
  final Jitter jitter;

  final Random? _random;

  @override
  Duration compute(int attempt, Duration previousDelay) {
    final exponent = (attempt - 2).clamp(0, 62);
    // Computed in microseconds and clamped before conversion so an aggressive
    // multiplier cannot overflow the 64-bit microsecond field on the VM or lose
    // precision in JavaScript's 53-bit integers on the web.
    final growth = pow(multiplier, exponent).toDouble();
    final nominalMicros = initial.inMicroseconds * growth;
    final cappedMicros = nominalMicros > maximum.inMicroseconds
        ? maximum.inMicroseconds
        : nominalMicros.round();
    final capped = Duration(microseconds: cappedMicros.toInt());
    return applyJitter(capped, jitter, previousDelay, _random ?? _sharedRandom);
  }

  @override
  String toString() =>
      'ExponentialBackoff(initial: ${initial.inMilliseconds}ms, '
      'max: ${maximum.inMilliseconds}ms, x$multiplier, '
      'jitter: ${jitter.name})';
}

/// Replays a fixed list of delays, then repeats the last one.
///
/// Exists for tests and for schedules dictated by an external contract — a
/// provider that documents exactly when to retry, for instance.
@immutable
final class FixedScheduleBackoff implements BackoffStrategy {
  /// Creates a schedule that walks [delays] in order.
  ///
  /// [delays] must not be empty. The check happens on first use rather than in
  /// an assertion because `List.length` is not a constant expression, and
  /// keeping this constructor `const` is what allows a whole `RetryPolicy` to
  /// be a compile-time constant.
  const FixedScheduleBackoff(this.delays);

  /// The delays to use, indexed by retry number.
  final List<Duration> delays;

  @override
  Duration compute(int attempt, Duration previousDelay) {
    if (delays.isEmpty) {
      throw ConfigurationException(
        'FixedScheduleBackoff was created with an empty schedule, so it has '
        'no delay to return.',
        setting: 'FixedScheduleBackoff.delays',
      );
    }
    final index = (attempt - 2).clamp(0, delays.length - 1);
    return delays[index];
  }

  @override
  String toString() => 'FixedScheduleBackoff($delays)';
}

/// Applies [jitter] to [delay].
///
/// Exposed so custom [BackoffStrategy] implementations get identical
/// randomisation semantics rather than reinventing them. [previousDelay] is
/// only consulted by [Jitter.decorrelated].
Duration applyJitter(
  Duration delay,
  Jitter jitter,
  Duration previousDelay,
  Random random,
) {
  if (jitter == Jitter.none || delay <= Duration.zero) return delay;
  final micros = delay.inMicroseconds;
  return switch (jitter) {
    Jitter.none => delay,
    Jitter.full => Duration(microseconds: _nextInt(random, micros + 1)),
    Jitter.equal => Duration(
      microseconds: micros ~/ 2 + _nextInt(random, micros ~/ 2 + 1),
    ),
    Jitter.decorrelated => () {
      final previous = previousDelay.inMicroseconds;
      final ceiling = previous <= 0 ? micros : previous * 3;
      final bounded = ceiling > micros * 10 ? micros * 10 : ceiling;
      final span = bounded - micros;
      if (span <= 0) return delay;
      return Duration(microseconds: micros + _nextInt(random, span + 1));
    }(),
  };
}

/// `Random.nextInt` is limited to 2^32; delays in microseconds can exceed it.
int _nextInt(Random random, int max) {
  if (max <= 0) return 0;
  const limit = 1 << 32;
  if (max <= limit) return random.nextInt(max);
  return (random.nextDouble() * max).floor();
}

final Random _sharedRandom = Random();
