/// Time a run spent waiting on a person rather than working.
///
/// # Why this exists
///
/// An agent's wall-clock budget is there to bound *the agent*: a loop that will
/// not converge, a provider that has stopped answering, a tool that hangs. It
/// is a safety limit on machine work.
///
/// A human approval prompt is none of those. When a tool asks "may I send this
/// email?" the run is not misbehaving — it is doing exactly what it was built
/// to do, and the clock that follows is measuring how carefully somebody is
/// reading. Counting that against the budget means the more thought a person
/// gives a destructive action, the more likely the run is to be killed for it.
/// That is precisely backwards, and it fails intermittently, which is the worst
/// way for it to fail: fine in every test, fine in every demo, and broken for
/// the user who actually stopped to think.
///
/// So the waiting is recorded here and subtracted. The budget still bounds
/// everything the agent does; it just no longer bounds the user.
///
/// # What still applies while waiting
///
/// Cancellation. A person who backgrounds the app, or a run that is explicitly
/// cancelled, stops immediately — pausing the budget clock is not the same as
/// making a run unkillable, and this deliberately does not touch that path.
library;

import 'package:agentic_core/src/common/clock.dart';

/// Accumulates the time a run spent blocked on a person.
///
/// One ledger is shared by a whole run: a child context passes the same
/// instance down, so a wait recorded deep inside a tool call is visible to the
/// budget being tracked at the top of the loop.
final class HumanWaitLedger {
  /// Creates an empty ledger.
  HumanWaitLedger();

  Duration _total = Duration.zero;
  int _outstanding = 0;

  /// How long this run has spent waiting on a person.
  Duration get total => _total;

  /// Whether somebody is being waited on right now.
  bool get isWaiting => _outstanding > 0;

  /// Runs [action], counting the time it takes as human waiting.
  ///
  /// Nested and concurrent waits are tracked so that two prompts shown at once
  /// do not have their durations added together — the run was blocked for the
  /// span they overlap in, not for the sum of them. Overcounting here would
  /// hand back more budget than was actually lost.
  Future<T> during<T>(Future<T> Function() action, {required Clock clock}) {
    final startedAt = clock.now();
    _outstanding++;
    return Future<T>.sync(action).whenComplete(() {
      _outstanding--;
      // Only the last wait to finish commits, and it commits from the earliest
      // start still open — which is this one when nothing nested, and the outer
      // one when something did.
      if (_outstanding == 0) {
        _total += clock.now().difference(_earliest ?? startedAt);
        _earliest = null;
      } else {
        _earliest ??= startedAt;
      }
    });
  }

  DateTime? _earliest;

  /// Records a wait measured elsewhere.
  ///
  /// For a host that puts up its own confirmation outside a tool call and wants
  /// the budget to know about it.
  void add(Duration duration) {
    if (duration > Duration.zero) _total += duration;
  }

  @override
  String toString() => 'HumanWaitLedger(${_total.inMilliseconds}ms)';
}
