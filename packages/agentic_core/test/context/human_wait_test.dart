import 'dart:async';

import 'package:agentic_core/agentic_core.dart';
import 'package:agentic_core/testing.dart';
import 'package:test/test.dart';

/// The ledger exists so a wall-clock budget bounds the agent and not the user.
/// Every test here is a way that could quietly stop being true.
void main() {
  group('HumanWaitLedger', () {
    test('starts empty', () {
      final ledger = HumanWaitLedger();
      expect(ledger.total, Duration.zero);
      expect(ledger.isWaiting, isFalse);
    });

    test('records how long an action took', () async {
      final clock = FakeClock();
      final ledger = HumanWaitLedger();
      final completer = Completer<bool>();

      final pending = ledger.during(() => completer.future, clock: clock);
      expect(ledger.isWaiting, isTrue);
      expect(ledger.total, Duration.zero, reason: 'nothing committed yet');

      await clock.advance(const Duration(seconds: 20));
      completer.complete(true);
      await pending;

      expect(ledger.total, const Duration(seconds: 20));
      expect(ledger.isWaiting, isFalse);
    });

    test('adds separate waits together', () async {
      final clock = FakeClock();
      final ledger = HumanWaitLedger();

      for (var i = 0; i < 2; i++) {
        final completer = Completer<bool>();
        final pending = ledger.during(() => completer.future, clock: clock);
        await clock.advance(const Duration(seconds: 5));
        completer.complete(true);
        await pending;
      }

      expect(ledger.total, const Duration(seconds: 10));
    });

    test('counts overlapping waits once, not twice', () async {
      // Two prompts on screen at the same time blocked the run for the span
      // they overlap in, not for the sum of them. Summing would hand back more
      // budget than was ever lost.
      final clock = FakeClock();
      final ledger = HumanWaitLedger();

      final first = Completer<bool>();
      final second = Completer<bool>();
      final a = ledger.during(() => first.future, clock: clock);
      await clock.advance(const Duration(seconds: 2));
      final b = ledger.during(() => second.future, clock: clock);

      await clock.advance(const Duration(seconds: 8));
      first.complete(true);
      second.complete(true);
      await Future.wait<bool>(<Future<bool>>[a, b]);

      expect(ledger.total, const Duration(seconds: 10));
    });

    test('records the wait even when the action throws', () async {
      // A denied or failed approval blocked the user for just as long as an
      // approved one. Charging the agent for it would make the budget depend
      // on the answer.
      final clock = FakeClock();
      final ledger = HumanWaitLedger();
      final completer = Completer<bool>();

      final pending = ledger.during(() => completer.future, clock: clock);
      await clock.advance(const Duration(seconds: 7));
      completer.completeError(StateError('dismissed'));

      await expectLater(pending, throwsStateError);
      expect(ledger.total, const Duration(seconds: 7));
    });

    test('accepts a wait measured elsewhere', () {
      final ledger = HumanWaitLedger()..add(const Duration(seconds: 3));
      expect(ledger.total, const Duration(seconds: 3));
    });

    test('ignores a negative wait', () {
      final ledger = HumanWaitLedger()..add(const Duration(seconds: -3));
      expect(ledger.total, Duration.zero);
    });
  });

  group('AgenticContext', () {
    test('has a ledger', () {
      expect(AgenticContext.root().humanWait.total, Duration.zero);
    });

    test('shares one ledger with every descendant', () {
      // The property the whole design rests on: a wait recorded deep inside a
      // tool call has to be visible to the budget being tracked at the top of
      // the loop. Separate ledgers per scope would make the subtraction a
      // no-op in exactly the case it was written for.
      final root = AgenticContext.root();
      final nested = root.child('agent').child('tool');

      nested.humanWait.add(const Duration(seconds: 9));

      expect(root.humanWait.total, const Duration(seconds: 9));
      expect(identical(root.humanWait, nested.humanWait), isTrue);
    });
  });
}
