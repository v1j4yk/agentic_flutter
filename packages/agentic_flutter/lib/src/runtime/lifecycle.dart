/// Tying agent runs to the app's lifecycle.
///
/// # The problem this exists for
///
/// A server process lives until its work is done. A phone does not. The user
/// switches apps, takes a call, or locks the screen, and the operating system
/// suspends the process — sometimes for seconds, sometimes forever. An agent
/// loop that was mid-run when that happened is in one of two bad states: still
/// billing for a model call nobody will read, or resuming hours later against a
/// screen that no longer exists.
///
/// Neither is a bug in the agent loop. It is a bug in *nothing asking the
/// agent to stop*, which is what this file supplies.
library;

import 'dart:async';

import 'package:agentic_core/agentic_core.dart';
import 'package:flutter/widgets.dart';

/// What should happen to in-flight work when the app leaves the foreground.
enum BackgroundPolicy {
  /// Keep running.
  ///
  /// Correct only when a run is short and its result is wanted regardless —
  /// and even then the platform may suspend the process anyway, so it is a
  /// preference rather than a guarantee.
  keepRunning,

  /// Cancel as soon as the app is no longer visible.
  ///
  /// The safest default for anything expensive. `paused` is reached whenever
  /// the user switches away, which happens constantly and often briefly, so
  /// this trades some wasted restarts for a hard bound on cost.
  cancelOnPause,

  /// Cancel only when the app is being torn down.
  ///
  /// The balanced choice, and the default. A brief switch away does not throw
  /// work away, but a process that is going down does not leave a model call
  /// running behind it.
  cancelOnDetach,
}

/// Cancels a [CancellationTokenSource] in step with the app's lifecycle.
///
/// ```dart
/// final source = CancellationTokenSource();
/// final binding = LifecycleCancellation.attach(
///   source,
///   policy: BackgroundPolicy.cancelOnPause,
/// );
/// // ... run the agent with source.token ...
/// binding.detach();
/// ```
///
/// Prefer `AgenticRuntime`, which owns one of these for you; reach for this
/// directly when a single screen owns a run whose lifetime is its own.
final class LifecycleCancellation with WidgetsBindingObserver {
  LifecycleCancellation._(this._source, this.policy, this._onCancelled);

  /// Attaches an observer that cancels [source] according to [policy].
  ///
  /// [onCancelled] is called when the lifecycle — not the caller — triggered
  /// the cancellation, which is what lets a screen tell the user "stopped
  /// because you left" rather than showing a bare error.
  static LifecycleCancellation attach(
    CancellationTokenSource source, {
    BackgroundPolicy policy = BackgroundPolicy.cancelOnDetach,
    void Function(AppLifecycleState state)? onCancelled,
  }) {
    final binding = LifecycleCancellation._(source, policy, onCancelled);
    WidgetsBinding.instance.addObserver(binding);
    return binding;
  }

  final CancellationTokenSource _source;
  final void Function(AppLifecycleState state)? _onCancelled;

  /// When in-flight work is abandoned.
  final BackgroundPolicy policy;

  bool _detached = false;

  /// The token to hand to a run.
  CancellationToken get token => _source.token;

  /// Whether the lifecycle has already cancelled the run.
  bool get isCancelled => _source.isCancelled;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_detached || _source.isCancelled) return;

    final shouldCancel = switch (policy) {
      BackgroundPolicy.keepRunning => false,
      // `hidden` precedes `paused` on every platform that reports it, so both
      // are treated the same: the user cannot see the result either way.
      BackgroundPolicy.cancelOnPause =>
        state == AppLifecycleState.paused ||
            state == AppLifecycleState.hidden ||
            state == AppLifecycleState.detached,
      BackgroundPolicy.cancelOnDetach => state == AppLifecycleState.detached,
    };
    if (!shouldCancel) return;

    _source.cancel('the app entered ${state.name}');
    _onCancelled?.call(state);
  }

  /// Stops observing.
  ///
  /// Idempotent, and safe from a `dispose`. Not calling it leaks an observer
  /// into `WidgetsBinding` for the life of the app — which on a screen that is
  /// pushed repeatedly means one leaked observer per visit.
  void detach() {
    if (_detached) return;
    _detached = true;
    WidgetsBinding.instance.removeObserver(this);
  }

  @override
  String toString() => 'LifecycleCancellation(${policy.name})';
}

/// Runs [body] with a cancellation token bound to the app's lifecycle.
///
/// The one-call form for a screen that starts a run and awaits it:
///
/// ```dart
/// final answer = await withLifecycleCancellation(
///   policy: BackgroundPolicy.cancelOnPause,
///   (token) => agent.run(input, context: base.child('turn', cancellation: token)),
/// );
/// ```
///
/// The observer is always removed, including when [body] throws.
Future<T> withLifecycleCancellation<T>(
  Future<T> Function(CancellationToken token) body, {
  BackgroundPolicy policy = BackgroundPolicy.cancelOnDetach,
  CancellationToken? parent,
}) async {
  final lifecycle = CancellationTokenSource();
  final binding = LifecycleCancellation.attach(lifecycle, policy: policy);
  // Merged rather than replaced: a caller who already had a token — a screen
  // that cancels on navigation — must not lose it by opting into lifecycle
  // cancellation as well.
  final merged = parent == null
      ? null
      : CancellationToken.merge(parent, lifecycle.token);
  try {
    return await body(merged?.token ?? lifecycle.token);
  } finally {
    binding.detach();
    await merged?.dispose();
    await lifecycle.dispose();
  }
}
