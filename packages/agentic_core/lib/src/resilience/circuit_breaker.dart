/// Circuit breaking for failing dependencies.
///
/// Retries help when a dependency is *momentarily* unavailable. They actively
/// hurt when it is *comprehensively* down: every caller keeps hammering a dead
/// provider, each request waits out its full timeout, the user watches a
/// spinner for a minute, and the recovering service is knocked over again by
/// the backlog the moment it comes up.
///
/// A [CircuitBreaker] detects that state and fails fast until the dependency
/// has had time to recover. In an agentic system it is also what makes provider
/// failover tractable: an open circuit on the primary model is the signal to
/// route to the fallback, and it is a cheap boolean rather than another timed
/// out request.
///
/// ```dart
/// final breaker = CircuitBreaker(name: 'openai');
///
/// try {
///   return await breaker.execute(() => primary.generate(request));
/// } on CircuitOpenException {
///   return await fallback.generate(request); // fail over, do not wait.
/// }
/// ```
library;

import 'dart:async';

import 'package:agentic_core/src/common/clock.dart';
import 'package:agentic_core/src/common/disposable.dart';
import 'package:agentic_core/src/common/json_types.dart';
import 'package:agentic_core/src/error/agentic_exception.dart';

/// The three states of a [CircuitBreaker].
enum CircuitState {
  /// Requests flow normally and failures are counted.
  closed,

  /// The dependency is considered down; requests fail immediately.
  open,

  /// A single trial request is allowed through to test for recovery.
  halfOpen,
}

/// Thrown when a request is rejected because the circuit is open.
///
/// Retryable, because the dependency is expected to recover — but the caller
/// should generally *fail over* rather than retry, since retrying will simply
/// be rejected again until [retryAfter] elapses.
final class CircuitOpenException extends AgenticException {
  /// Creates a rejection for the circuit named [circuitName].
  CircuitOpenException(
    super.message, {
    required this.circuitName,
    required this.retryAfter,
    required this.lastFailure,
    super.details,
  });

  /// Name of the circuit that rejected the request.
  final String circuitName;

  /// How long until the circuit will admit a trial request.
  final Duration retryAfter;

  /// The failure that tripped the circuit, preserved for diagnosis.
  ///
  /// Without this, an open circuit reports only that it is open — and the
  /// actual cause, which happened minutes ago, is lost.
  final AgenticException? lastFailure;

  @override
  String get code => 'circuit_open';

  @override
  bool get isRetryable => true;

  @override
  JsonMap toJson() => pruneNulls(<String, Object?>{
    ...super.toJson(),
    'circuit': circuitName,
    'retryAfterMs': retryAfter.inMilliseconds,
    'lastFailure': lastFailure?.toJson(),
  });
}

/// Trips after repeated failures and fails fast until the dependency recovers.
///
/// One breaker guards one dependency. Share the instance across every call site
/// that touches that dependency — a breaker per call site learns nothing,
/// because each one sees only a fraction of the failures.
final class CircuitBreaker implements Disposable {
  /// Creates a breaker guarding the dependency called [name].
  ///
  /// [failureThreshold] consecutive failures trip the circuit.
  /// [successThreshold] consecutive successes in [CircuitState.halfOpen] close
  /// it again — requiring more than one guards against a dependency that
  /// answers a single request before falling over.
  CircuitBreaker({
    required this.name,
    this.failureThreshold = 5,
    this.successThreshold = 2,
    this.resetTimeout = const Duration(seconds: 30),
    this.isFailure,
    Clock clock = const SystemClock(),
  }) : assert(failureThreshold >= 1, 'failureThreshold must be at least 1'),
       assert(successThreshold >= 1, 'successThreshold must be at least 1'),
       _clock = clock;

  /// Identifies the guarded dependency, such as `openai` or `qdrant`.
  final String name;

  /// Consecutive failures required to open the circuit.
  final int failureThreshold;

  /// Consecutive half-open successes required to close the circuit.
  final int successThreshold;

  /// How long the circuit stays open before admitting a trial request.
  final Duration resetTimeout;

  /// Decides which errors count towards tripping.
  ///
  /// Defaults to [countsAsDependencyFailure].
  final bool Function(AgenticException error)? isFailure;

  /// Whether [error] is evidence that the *dependency* is unhealthy.
  ///
  /// This is a different question from [AgenticException.isRetryable], and
  /// conflating the two gets both answers wrong. Retryability asks "could
  /// replaying this identical request succeed?" — the answer is `false` for an
  /// unclassified crash, because replaying an unknown side effect is dangerous.
  /// A circuit breaker asks "is the thing on the other end broken?" — and for
  /// an unclassified crash coming out of a dependency call, the answer is
  /// almost always yes.
  ///
  /// So the rule here is inverted: everything counts *except* failures that are
  /// the caller's own doing, because those say nothing about the dependency's
  /// health and letting them trip the circuit would deny service to every
  /// correct caller sharing it.
  ///
  /// Excluded:
  ///
  /// * [CancelledException] — the user pressed stop. Counting it would let
  ///   someone close a screen five times and take the provider offline for
  ///   everybody.
  /// * [ValidationException], [SerializationException] — malformed input.
  /// * [ConfigurationException], [CapabilityNotSupportedException] — wiring.
  /// * [AuthenticationException], [PermissionDeniedException],
  ///   [QuotaExceededException] — credentials and billing, which no amount of
  ///   waiting repairs.
  ///
  /// Everything else — provider errors, rate limits, timeouts, storage
  /// failures and unclassified crashes — counts.
  static bool countsAsDependencyFailure(AgenticException error) =>
      switch (error) {
        CancelledException() => false,
        ValidationException() => false,
        SerializationException() => false,
        ConfigurationException() => false,
        CapabilityNotSupportedException() => false,
        AuthenticationException() => false,
        PermissionDeniedException() => false,
        QuotaExceededException() => false,
        NotFoundException() => false,
        _ => true,
      };

  final Clock _clock;
  final StreamController<CircuitState> _stateChanges =
      StreamController<CircuitState>.broadcast();

  CircuitState _state = CircuitState.closed;
  int _consecutiveFailures = 0;
  int _consecutiveSuccesses = 0;
  DateTime? _openedAt;
  AgenticException? _lastFailure;
  bool _trialInFlight = false;
  bool _disposed = false;

  /// The current state, after applying any elapsed reset timeout.
  ///
  /// Reading this can move an [CircuitState.open] circuit to
  /// [CircuitState.halfOpen]: the transition is time-based, and evaluating it
  /// lazily on read avoids holding a timer per breaker for the lifetime of the
  /// application.
  CircuitState get state {
    _promoteIfElapsed();
    return _state;
  }

  /// Emits every state transition.
  ///
  /// Useful for dashboards, for logging provider health, and for driving UI
  /// that tells the user an assistant is temporarily degraded.
  Stream<CircuitState> get stateChanges => _stateChanges.stream;

  /// Consecutive failures counted since the last success.
  int get consecutiveFailures => _consecutiveFailures;

  /// The failure that most recently tripped or extended the circuit.
  AgenticException? get lastFailure => _lastFailure;

  /// Runs [action] under the breaker.
  ///
  /// Throws [CircuitOpenException] without invoking [action] when the circuit
  /// is open, or when a half-open trial is already in flight. Any error thrown
  /// by [action] propagates unchanged after being counted.
  Future<T> execute<T>(Future<T> Function() action) async {
    _throwIfDisposed();
    _promoteIfElapsed();

    switch (_state) {
      case CircuitState.open:
        throw _rejection();
      case CircuitState.halfOpen:
        if (_trialInFlight) throw _rejection();
        _trialInFlight = true;
      case CircuitState.closed:
        break;
    }

    try {
      final result = await action();
      _onSuccess();
      return result;
    } on AgenticException catch (error) {
      _onFailure(error);
      rethrow;
    } on Object catch (error, stackTrace) {
      // Errors from outside the framework are counted as failures: an
      // uncategorised crash from a dependency is still that dependency failing.
      _onFailure(
        UnexpectedException(
          'Unclassified failure in circuit `$name`: $error',
          cause: error,
          causeStackTrace: stackTrace,
          component: 'CircuitBreaker($name)',
        ),
      );
      rethrow;
    } finally {
      _trialInFlight = false;
    }
  }

  /// Forces the circuit closed and clears all counters.
  ///
  /// For operator intervention and tests. Production code should let the
  /// breaker recover on its own.
  void reset() {
    _consecutiveFailures = 0;
    _consecutiveSuccesses = 0;
    _openedAt = null;
    _lastFailure = null;
    _transitionTo(CircuitState.closed);
  }

  /// Forces the circuit open immediately.
  ///
  /// Useful when an out-of-band signal — a status page, a push notification,
  /// a 402 from billing — proves the dependency is unusable before enough
  /// requests have failed to trip it naturally.
  void trip([AgenticException? cause]) {
    _lastFailure = cause ?? _lastFailure;
    _openedAt = _clock.now();
    _consecutiveSuccesses = 0;
    _transitionTo(CircuitState.open);
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _stateChanges.close();
  }

  void _onSuccess() {
    _consecutiveFailures = 0;
    if (_state != CircuitState.halfOpen) return;
    _consecutiveSuccesses++;
    if (_consecutiveSuccesses >= successThreshold) {
      _consecutiveSuccesses = 0;
      _openedAt = null;
      _transitionTo(CircuitState.closed);
    }
  }

  void _onFailure(AgenticException error) {
    final counts = (isFailure ?? countsAsDependencyFailure)(error);
    if (!counts) return;

    _lastFailure = error;
    _consecutiveSuccesses = 0;

    // A failure during a trial re-opens immediately: the dependency answered
    // the probe with an error, which is all the evidence needed.
    if (_state == CircuitState.halfOpen) {
      _openedAt = _clock.now();
      _transitionTo(CircuitState.open);
      return;
    }

    _consecutiveFailures++;
    if (_consecutiveFailures >= failureThreshold) {
      _openedAt = _clock.now();
      _transitionTo(CircuitState.open);
    }
  }

  void _promoteIfElapsed() {
    if (_state != CircuitState.open) return;
    final openedAt = _openedAt;
    if (openedAt == null) return;
    if (_clock.now().difference(openedAt) >= resetTimeout) {
      _consecutiveFailures = 0;
      _transitionTo(CircuitState.halfOpen);
    }
  }

  void _transitionTo(CircuitState next) {
    if (_state == next) return;
    _state = next;
    if (!_stateChanges.isClosed) _stateChanges.add(next);
  }

  CircuitOpenException _rejection() {
    final openedAt = _openedAt;
    final remaining = openedAt == null
        ? resetTimeout
        : resetTimeout - _clock.now().difference(openedAt);
    return CircuitOpenException(
      'Circuit `$name` is open after $failureThreshold consecutive failures; '
      'requests are rejected for another '
      '${remaining.isNegative ? 0 : remaining.inMilliseconds}ms.',
      circuitName: name,
      retryAfter: remaining.isNegative ? Duration.zero : remaining,
      lastFailure: _lastFailure,
    );
  }

  void _throwIfDisposed() {
    if (!_disposed) return;
    throw InvalidStateException(
      'CircuitBreaker `$name` has been disposed.',
      currentState: 'disposed',
      expectedState: 'active',
    );
  }

  @override
  String toString() =>
      'CircuitBreaker($name, state: ${_state.name}, '
      'failures: $_consecutiveFailures/$failureThreshold)';
}
