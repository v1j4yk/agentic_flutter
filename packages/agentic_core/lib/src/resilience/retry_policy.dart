/// Retry orchestration.
///
/// A [RetryPolicy] wraps a fallible operation and re-runs it while three
/// conditions hold: the error says it is transient, the caller has not
/// cancelled, and the budget has not run out. Everything about *when* to retry
/// is delegated to a [BackoffStrategy].
///
/// # What this deliberately does not do
///
/// It does not decide idempotency. A tool that charges a credit card must not
/// be retried by a generic policy, and the framework cannot know that from the
/// outside — which is why `ToolExecutionException` defaults to
/// non-retryable and requires the tool author to opt in.
///
/// It does not retry cancellations. `CancelledException` propagates
/// immediately, before any budget or predicate is consulted: the caller asked
/// for the work to stop, and a retry loop that argues with that is a bug.
library;

import 'dart:async';

import 'package:agentic_core/src/cancellation/cancellation.dart';
import 'package:agentic_core/src/common/clock.dart';
import 'package:agentic_core/src/error/agentic_exception.dart';
import 'package:agentic_core/src/resilience/backoff.dart';
import 'package:meta/meta.dart';

/// Decides whether a particular failure should be retried.
///
/// Consulted only after [AgenticException.isRetryable] has already said yes, so
/// a predicate can narrow the default but never widen it. That ordering is
/// deliberate: widening would let a call site retry a validation error forever.
typedef RetryPredicate = bool Function(AgenticException error, int attempt);

/// Notified before each wait, for logging and metrics.
///
/// [attempt] is the attempt that just failed; [delay] is how long the policy is
/// about to wait before attempt `attempt + 1`.
typedef RetryListener =
    void Function(AgenticException error, int attempt, Duration delay);

/// Re-runs a transient failure according to a schedule and a budget.
///
/// ```dart
/// const policy = RetryPolicy(
///   maxAttempts: 4,
///   backoff: ExponentialBackoff(initial: Duration(milliseconds: 200)),
///   maxElapsed: Duration(seconds: 20),
/// );
///
/// final response = await policy.execute(
///   (attempt) => provider.send(request),
///   operation: 'openai.chat.completions',
///   cancellation: token,
/// );
/// ```
@immutable
final class RetryPolicy {
  /// Creates a retry policy.
  ///
  /// [maxAttempts] counts *total* attempts, not retries: `maxAttempts: 1`
  /// disables retrying. Counting total attempts avoids the perennial
  /// off-by-one where `maxRetries: 3` means three or four calls depending on
  /// who wrote the loop.
  const RetryPolicy({
    this.maxAttempts = 3,
    this.backoff = const ExponentialBackoff(),
    this.retryIf,
    this.onRetry,
    this.maxElapsed,
    this.respectRetryAfter = true,
  }) : assert(maxAttempts >= 1, 'maxAttempts must be at least 1');

  /// A policy that never retries.
  ///
  /// Use it as an explicit default so that "no retry" is a visible decision at
  /// the call site rather than an omission.
  static const RetryPolicy none = RetryPolicy(maxAttempts: 1);

  /// A policy tuned for interactive LLM calls.
  ///
  /// Three attempts and a short ceiling: a user staring at a spinner will
  /// abandon the request long before a patient schedule pays off. Prefer
  /// [background] for work nobody is watching.
  static const RetryPolicy interactive = RetryPolicy(
    backoff: ExponentialBackoff(
      initial: Duration(milliseconds: 250),
      maximum: Duration(seconds: 4),
    ),
    maxElapsed: Duration(seconds: 12),
  );

  /// A policy tuned for background and scheduled work.
  ///
  /// Patient and decorrelated: nobody is waiting, so surviving a multi-minute
  /// provider outage is worth more than finishing quickly.
  static const RetryPolicy background = RetryPolicy(
    maxAttempts: 8,
    backoff: ExponentialBackoff(
      maximum: Duration(minutes: 2),
      jitter: Jitter.decorrelated,
    ),
    maxElapsed: Duration(minutes: 10),
  );

  /// Maximum number of attempts, including the first.
  final int maxAttempts;

  /// The schedule that decides how long to wait between attempts.
  final BackoffStrategy backoff;

  /// Optional additional filter applied to retryable errors.
  final RetryPredicate? retryIf;

  /// Optional hook invoked before each wait.
  final RetryListener? onRetry;

  /// Wall-clock ceiling for the whole sequence, measured from the first attempt.
  ///
  /// Checked *before* waiting, so the policy never sleeps into a deadline it
  /// already knows it cannot meet. `null` means only [maxAttempts] bounds the
  /// sequence.
  final Duration? maxElapsed;

  /// Whether a provider's `Retry-After` should override the computed backoff.
  ///
  /// On by default. When a provider states when it will be ready, it knows
  /// better than any client-side schedule, and ignoring it is what turns a
  /// soft rate limit into a hard block.
  final bool respectRetryAfter;

  /// Runs [action], retrying transient failures.
  ///
  /// [action] receives the 1-based attempt number, which is useful for logging
  /// and for varying behaviour on retry — lowering a temperature, dropping to a
  /// cheaper model, or shrinking a batch.
  ///
  /// [operation] names the work in errors and traces.
  ///
  /// Throws the final [AgenticException] once the sequence is exhausted, so a
  /// caller always sees the real cause rather than a generic "retries
  /// exhausted" wrapper. The attempt count is added to
  /// [AgenticException.details] on the way out.
  Future<T> execute<T>(
    FutureOr<T> Function(int attempt) action, {
    required String operation,
    CancellationToken? cancellation,
    Clock clock = const SystemClock(),
  }) async {
    final token = cancellation.orNone;
    final started = clock.now();
    var previousDelay = Duration.zero;

    for (var attempt = 1; ; attempt++) {
      token.throwIfCancelled(operation: operation);

      try {
        return await action(attempt);
      } on CancelledException {
        // The caller asked to stop. Never retried, never wrapped.
        rethrow;
      } on AgenticException catch (error) {
        final isLastAttempt = attempt >= maxAttempts;
        if (isLastAttempt || !_shouldRetry(error, attempt)) {
          throw _annotate(error, attempt, operation);
        }

        final delay = _delayFor(error, attempt, previousDelay);
        final budget = maxElapsed;
        if (budget != null) {
          final elapsed = clock.now().difference(started);
          if (elapsed + delay > budget) {
            throw _annotate(error, attempt, operation, exhaustedBudget: budget);
          }
        }

        onRetry?.call(error, attempt, delay);
        previousDelay = delay;

        // Race the wait against cancellation so a stopped run does not sit out
        // a two-minute backoff before noticing.
        await token.race(clock.delay(delay), operation: '$operation (backoff)');
      }
    }
  }

  /// Runs [action] and reports failure as a value instead of throwing.
  ///
  /// The `Result`-shaped entry point, for fan-out call sites that must collect
  /// failures rather than propagate the first one.
  Future<T?> executeOrNull<T>(
    FutureOr<T> Function(int attempt) action, {
    required String operation,
    CancellationToken? cancellation,
    Clock clock = const SystemClock(),
    void Function(AgenticException error)? onFailure,
  }) async {
    try {
      return await execute(
        action,
        operation: operation,
        cancellation: cancellation,
        clock: clock,
      );
    } on AgenticException catch (error) {
      onFailure?.call(error);
      return null;
    }
  }

  /// Returns a copy with selected fields replaced.
  RetryPolicy copyWith({
    int? maxAttempts,
    BackoffStrategy? backoff,
    RetryPredicate? retryIf,
    RetryListener? onRetry,
    Duration? maxElapsed,
    bool? respectRetryAfter,
  }) => RetryPolicy(
    maxAttempts: maxAttempts ?? this.maxAttempts,
    backoff: backoff ?? this.backoff,
    retryIf: retryIf ?? this.retryIf,
    onRetry: onRetry ?? this.onRetry,
    maxElapsed: maxElapsed ?? this.maxElapsed,
    respectRetryAfter: respectRetryAfter ?? this.respectRetryAfter,
  );

  bool _shouldRetry(AgenticException error, int attempt) {
    if (!error.isRetryable) return false;
    final predicate = retryIf;
    return predicate == null || predicate(error, attempt);
  }

  Duration _delayFor(AgenticException error, int attempt, Duration previous) {
    final computed = backoff.compute(attempt + 1, previous);
    if (!respectRetryAfter) return computed;
    final retryAfter = error is RateLimitException ? error.retryAfter : null;
    if (retryAfter == null) return computed;
    // Honour the server's instruction, but never wait *less* than the local
    // schedule: a provider that says "50ms" while we are clearly overloading it
    // should not be able to talk us into a tight loop.
    return retryAfter > computed ? retryAfter : computed;
  }

  AgenticException _annotate(
    AgenticException error,
    int attempts,
    String operation, {
    Duration? exhaustedBudget,
  }) {
    // The original exception is returned untouched rather than rewrapped: its
    // concrete type is what callers branch on. What the retry loop learned is
    // attached as annotations instead, so the error explains its own history.
    error
      ..annotate('retry.operation', operation)
      ..annotate('retry.attempts', attempts);
    if (exhaustedBudget != null) {
      error.annotate('retry.budgetMs', exhaustedBudget.inMilliseconds);
    }
    return error;
  }

  @override
  String toString() =>
      'RetryPolicy(maxAttempts: $maxAttempts, backoff: $backoff, '
      'maxElapsed: $maxElapsed)';
}
