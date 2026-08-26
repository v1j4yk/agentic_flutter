/// Cooperative cancellation.
///
/// Agent runs are long: a research agent can spend a minute in a tool-calling
/// loop, and a workflow can run for hours. Users close screens, navigate away,
/// and hit stop. Without a cancellation primitive, that work keeps burning
/// tokens, battery and rate limit against a result nobody will read.
///
/// Dart futures cannot be cancelled from the outside, so cancellation here is
/// *cooperative*: a [CancellationToken] is threaded through the call graph and
/// every long-running operation checks it. The framework does the threading for
/// you through `AgenticContext`; tool authors only need to honour the token
/// their tool receives.
///
/// # The contract
///
/// * Cancellation is **not** an error condition to be swallowed. It surfaces as
///   a [CancelledException] so that a cancelled result is never mistaken for a
///   completed one.
/// * Cancellation is **not** retryable. Retry policies must let
///   [CancelledException] propagate untouched.
/// * Cancellation is **idempotent and terminal**. A token that has been
///   cancelled stays cancelled; the first reason wins.
///
/// ```dart
/// final source = CancellationTokenSource();
/// final run = agent.run('Research quantum error correction',
///     cancellation: source.token);
///
/// // Elsewhere — the user left the screen.
/// source.cancel('user navigated away');
/// ```
library;

import 'dart:async';

import 'package:agentic_core/src/common/clock.dart';
import 'package:agentic_core/src/common/disposable.dart';
import 'package:agentic_core/src/error/agentic_exception.dart';
import 'package:meta/meta.dart';

/// Removes a previously registered cancellation callback.
///
/// Returned by [CancellationToken.onCancelled]. Always call it when the
/// interest ends: a long-lived token accumulating callbacks from short-lived
/// operations is a memory leak.
typedef CancellationSubscription = void Function();

/// A read-only view of a cancellation signal.
///
/// Handed to operations. Only the owning [CancellationTokenSource] can trigger
/// cancellation, so an operation can observe the signal but never fire it —
/// the same separation as `Future` and `Completer`.
final class CancellationToken {
  CancellationToken._();

  /// A token that is never cancelled.
  ///
  /// The default for APIs that accept a token, so callers who do not care
  /// about cancellation write nothing. Checking it is close to free: it is a
  /// single `false` field read.
  static final CancellationToken none = CancellationToken._();

  final List<void Function()> _callbacks = <void Function()>[];
  Completer<void>? _completer;
  bool _isCancelled = false;
  String? _reason;

  /// Whether cancellation has been requested.
  ///
  /// The cheapest possible check; call it liberally inside loops.
  bool get isCancelled => _isCancelled;

  /// Why cancellation was requested, when a reason was given.
  ///
  /// Propagated into [CancelledException.reason] so that logs distinguish "the
  /// user pressed stop" from "the deadline expired".
  String? get reason => _reason;

  /// Completes when cancellation is requested.
  ///
  /// Use it to race against a long operation:
  ///
  /// ```dart
  /// await Future.any([work, token.whenCancelled]);
  /// ```
  ///
  /// The completer is allocated lazily, so tokens that are only ever polled
  /// through [isCancelled] cost nothing extra.
  Future<void> get whenCancelled {
    if (_isCancelled) return Future<void>.value();
    return (_completer ??= Completer<void>()).future;
  }

  /// Throws a [CancelledException] if cancellation has been requested.
  ///
  /// The standard checkpoint. Call it at the top of every iteration of an
  /// agent loop and between the phases of a tool.
  ///
  /// [operation] names what is being abandoned and appears in the error.
  void throwIfCancelled({String? operation}) {
    if (!_isCancelled) return;
    throw CancelledException(
      operation == null
          ? 'Operation was cancelled.'
          : '`$operation` was cancelled.',
      operation: operation,
      reason: _reason,
    );
  }

  /// Registers [callback], to run when cancellation is requested.
  ///
  /// If the token is already cancelled, [callback] runs immediately and
  /// synchronously — otherwise a caller that registers late would never be
  /// told, which is the classic source of hung requests.
  ///
  /// Returns a [CancellationSubscription] that deregisters the callback.
  /// Deregistering during dispatch is honoured: a callback removed by an
  /// earlier callback in the same cancellation will not run.
  CancellationSubscription onCancelled(void Function() callback) {
    if (_isCancelled) {
      callback();
      return _noopSubscription;
    }
    _callbacks.add(callback);
    return () => _callbacks.remove(callback);
  }

  /// Races [future] against cancellation.
  ///
  /// Completes with [future]'s result, or throws [CancelledException] as soon
  /// as the token fires — whichever happens first. The underlying work is not
  /// stopped; use this for operations that cannot observe a token directly,
  /// such as a third-party SDK call, and pair it with a real abort where one
  /// exists.
  Future<T> race<T>(Future<T> future, {String? operation}) {
    if (_isCancelled) {
      throwIfCancelled(operation: operation);
    }
    final completer = Completer<T>();
    late final CancellationSubscription subscription;

    void settleWith(void Function() action) {
      if (completer.isCompleted) return;
      subscription();
      action();
    }

    subscription = onCancelled(() {
      settleWith(
        () => completer.completeError(
          CancelledException(
            operation == null
                ? 'Operation was cancelled.'
                : '`$operation` was cancelled.',
            operation: operation,
            reason: _reason,
          ),
          StackTrace.current,
        ),
      );
    });

    unawaited(
      future.then<void>(
        (value) => settleWith(() => completer.complete(value)),
        onError: (Object error, StackTrace stackTrace) =>
            settleWith(() => completer.completeError(error, stackTrace)),
      ),
    );

    return completer.future;
  }

  /// Wraps [source] so the subscription is torn down on cancellation.
  ///
  /// The stream ends with a [CancelledException] rather than closing quietly,
  /// so a consumer cannot confuse "cancelled midway" with "finished".
  ///
  /// This is what makes cancelling a streaming LLM response actually close the
  /// underlying HTTP connection: cancelling the subscription propagates all the
  /// way down to the socket.
  Stream<T> bind<T>(Stream<T> source, {String? operation}) {
    // The subscription is created inside `onListen` and torn down inside
    // `detach`, which `onCancel` and both terminal paths call. The analyzer's
    // `cancel_subscriptions` heuristic only recognises a `cancel()` in the same
    // function body as the `listen()`, so it cannot see that teardown here.
    // ignore: cancel_subscriptions
    StreamSubscription<T>? subscription;
    CancellationSubscription? cancelSubscription;
    // Closed by `detach`; the same heuristic limitation applies to `close_sinks`.
    // ignore: close_sinks
    final controller = StreamController<T>();

    CancelledException cancelledError() => CancelledException(
      operation == null
          ? 'Stream was cancelled.'
          : '`$operation` was cancelled.',
      operation: operation,
      reason: _reason,
    );

    Future<void> detach() async {
      cancelSubscription?.call();
      cancelSubscription = null;
      final active = subscription;
      subscription = null;
      await active?.cancel();
    }

    Future<void> failAndClose() async {
      if (!controller.isClosed) {
        controller.addError(cancelledError(), StackTrace.current);
      }
      await detach();
      if (!controller.isClosed) await controller.close();
    }

    controller
      ..onListen = () {
        if (_isCancelled) {
          failAndClose().ignore();
          return;
        }
        cancelSubscription = onCancelled(() => failAndClose().ignore());
        subscription = source.listen(
          controller.add,
          onError: controller.addError,
          onDone: () async {
            await detach();
            if (!controller.isClosed) await controller.close();
          },
        );
      }
      ..onCancel = detach;

    return controller.stream;
  }

  /// Returns a token cancelled when [first] or [second] is cancelled.
  ///
  /// The composition operator for nested scopes: a tool call inherits the
  /// agent's token and adds its own timeout without either being able to
  /// interfere with the other.
  ///
  /// The returned token holds registrations on both parents. Dispose the
  /// returned [CancellationTokenSource] to release them.
  static CancellationTokenSource merge(
    CancellationToken first,
    CancellationToken second, {
    Clock clock = const SystemClock(),
  }) {
    final source = CancellationTokenSource(clock: clock);
    if (first.isCancelled) {
      source.cancel(first.reason);
      return source;
    }
    if (second.isCancelled) {
      source.cancel(second.reason);
      return source;
    }
    final firstSubscription = first.onCancelled(
      () => source.cancel(first.reason),
    );
    final secondSubscription = second.onCancelled(
      () => source.cancel(second.reason),
    );
    source._onDispose = () {
      firstSubscription();
      secondSubscription();
    };
    return source;
  }

  void _cancel(String? reason) {
    if (_isCancelled) return;
    _isCancelled = true;
    _reason = reason;

    // Iterate a snapshot so a callback may safely mutate the registration list,
    // but re-check membership before each invocation so that a deregistration
    // performed *during* dispatch is honoured. That matters: one callback
    // frequently tears down the object a later callback belongs to, and calling
    // the later one anyway would run it against released state.
    final pending = List<void Function()>.of(_callbacks);
    for (final callback in pending) {
      if (!_callbacks.remove(callback)) continue;
      callback();
    }
    _callbacks.clear();

    final completer = _completer;
    if (completer != null && !completer.isCompleted) {
      completer.complete();
    }
  }

  @override
  String toString() => _isCancelled
      ? 'CancellationToken(cancelled${_reason == null ? '' : ': $_reason'})'
      : 'CancellationToken(active)';
}

void _noopSubscription() {}

/// Owns a [CancellationToken] and the right to cancel it.
///
/// Create one where the work is *scoped* — a screen, a request handler, an
/// agent run — and pass [token] downward. Dispose it when the scope ends.
final class CancellationTokenSource implements Disposable {
  /// Creates a source whose token is initially active.
  ///
  /// [clock] is used only by [cancelAfter]; injecting it keeps deadline
  /// behaviour testable without real waiting.
  CancellationTokenSource({Clock clock = const SystemClock()})
    : _clock = clock,
      token = CancellationToken._();

  /// Creates a source already cancelled with [reason].
  ///
  /// Useful for propagating a cancellation across an isolate or process
  /// boundary, where the original source cannot be transferred.
  factory CancellationTokenSource.cancelled([String? reason]) =>
      CancellationTokenSource()..cancel(reason);

  /// Creates a source that cancels itself after [duration].
  factory CancellationTokenSource.timeout(
    Duration duration, {
    Clock clock = const SystemClock(),
    String? reason,
  }) => CancellationTokenSource(clock: clock)..cancelAfter(duration, reason);

  /// The token to hand to operations.
  final CancellationToken token;

  final Clock _clock;
  void Function()? _onDispose;
  bool _disposed = false;

  /// Whether the token has been cancelled.
  bool get isCancelled => token.isCancelled;

  /// Requests cancellation, recording an optional [reason].
  ///
  /// Idempotent: subsequent calls are ignored and the first reason is kept.
  void cancel([String? reason]) => token._cancel(reason);

  /// Requests cancellation after [duration] elapses on this source's clock.
  ///
  /// The deadline is dropped if the source is disposed first, so a completed
  /// operation does not leave a timer alive until it fires.
  void cancelAfter(Duration duration, [String? reason]) {
    unawaited(
      _clock.delay(duration).then((_) {
        if (_disposed || token.isCancelled) return;
        cancel(reason ?? 'deadline of ${duration.inMilliseconds}ms elapsed');
      }),
    );
  }

  /// Releases the source's registrations on any parent tokens.
  ///
  /// Does **not** cancel the token: disposing a scope that finished normally
  /// must not make its result look cancelled. Call [cancel] first if that is
  /// what you mean.
  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _onDispose?.call();
    _onDispose = null;
  }
}

/// Convenience checks on a possibly-absent token.
///
/// Framework APIs accept `CancellationToken?` so callers can omit it entirely.
/// These extensions remove the resulting `?? CancellationToken.none` noise from
/// every implementation.
extension NullableCancellationToken on CancellationToken? {
  /// This token, or [CancellationToken.none] when absent.
  CancellationToken get orNone => this ?? CancellationToken.none;

  /// Whether a token is present and cancelled.
  bool get isCancelled => this?.isCancelled ?? false;

  /// Throws if a token is present and cancelled.
  void throwIfCancelled({String? operation}) =>
      this?.throwIfCancelled(operation: operation);
}

/// Test-only access to construct a bare token.
///
/// Production code always obtains tokens from a [CancellationTokenSource].
@visibleForTesting
CancellationToken debugCreateToken() => CancellationToken._();
