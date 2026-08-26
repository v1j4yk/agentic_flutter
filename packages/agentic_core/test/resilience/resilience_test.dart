import 'dart:math';

import 'package:agentic_core/agentic_core.dart';
import 'package:agentic_core/testing.dart';
import 'package:test/test.dart';

ProviderException transient() =>
    ProviderException('unavailable', provider: 'test', statusCode: 503);

void main() {
  group('ExponentialBackoff', () {
    test('doubles from the initial delay', () {
      const backoff = ExponentialBackoff(
        initial: Duration(milliseconds: 100),
        jitter: Jitter.none,
      );

      expect(
        backoff.compute(2, Duration.zero),
        const Duration(milliseconds: 100),
      );
      expect(
        backoff.compute(3, Duration.zero),
        const Duration(milliseconds: 200),
      );
      expect(
        backoff.compute(4, Duration.zero),
        const Duration(milliseconds: 400),
      );
    });

    test('caps at the maximum', () {
      const backoff = ExponentialBackoff(
        initial: Duration(seconds: 1),
        maximum: Duration(seconds: 5),
        jitter: Jitter.none,
      );

      expect(backoff.compute(20, Duration.zero), const Duration(seconds: 5));
    });

    test('does not overflow at an absurd attempt number', () {
      const backoff = ExponentialBackoff(
        maximum: Duration(seconds: 30),
        jitter: Jitter.none,
      );

      final delay = backoff.compute(1000, Duration.zero);

      expect(delay, const Duration(seconds: 30));
      expect(delay.isNegative, isFalse);
    });

    test('full jitter stays within the nominal delay', () {
      final backoff = ExponentialBackoff(
        initial: const Duration(milliseconds: 800),
        random: Random(1),
      );

      for (var attempt = 2; attempt < 8; attempt++) {
        final delay = backoff.compute(attempt, Duration.zero);
        expect(delay, greaterThanOrEqualTo(Duration.zero));
        expect(delay, lessThanOrEqualTo(const Duration(seconds: 30)));
      }
    });

    test('equal jitter keeps a latency floor of half the delay', () {
      final backoff = ExponentialBackoff(
        initial: const Duration(milliseconds: 1000),
        jitter: Jitter.equal,
        random: Random(1),
      );

      for (var i = 0; i < 25; i++) {
        final delay = backoff.compute(2, Duration.zero);
        expect(delay, greaterThanOrEqualTo(const Duration(milliseconds: 500)));
        expect(delay, lessThanOrEqualTo(const Duration(milliseconds: 1001)));
      }
    });

    test('rejects a multiplier that would not grow', () {
      expect(
        () => ExponentialBackoff(multiplier: 1),
        throwsA(isA<AssertionError>()),
      );
    });
  });

  group('LinearBackoff', () {
    test('grows by the initial delay each attempt', () {
      const backoff = LinearBackoff(
        initial: Duration(milliseconds: 200),
        jitter: Jitter.none,
      );

      expect(
        backoff.compute(2, Duration.zero),
        const Duration(milliseconds: 200),
      );
      expect(
        backoff.compute(3, Duration.zero),
        const Duration(milliseconds: 400),
      );
    });
  });

  group('FixedScheduleBackoff', () {
    test('walks the schedule then repeats the last entry', () {
      const backoff = FixedScheduleBackoff([
        Duration(seconds: 1),
        Duration(seconds: 4),
      ]);

      expect(backoff.compute(2, Duration.zero), const Duration(seconds: 1));
      expect(backoff.compute(3, Duration.zero), const Duration(seconds: 4));
      expect(backoff.compute(9, Duration.zero), const Duration(seconds: 4));
    });

    test('reports an empty schedule as a configuration error', () {
      const backoff = FixedScheduleBackoff(<Duration>[]);

      expect(
        () => backoff.compute(2, Duration.zero),
        throwsA(isA<ConfigurationException>()),
      );
    });
  });

  group('applyJitter', () {
    test('none is the identity', () {
      const delay = Duration(seconds: 3);

      expect(applyJitter(delay, Jitter.none, Duration.zero, Random(1)), delay);
    });

    test('decorrelated grows against the previous delay', () {
      final delay = applyJitter(
        const Duration(seconds: 1),
        Jitter.decorrelated,
        const Duration(seconds: 2),
        Random(3),
      );

      expect(delay, greaterThanOrEqualTo(const Duration(seconds: 1)));
      expect(delay, lessThanOrEqualTo(const Duration(seconds: 6)));
    });

    test('leaves a zero delay alone', () {
      expect(
        applyJitter(Duration.zero, Jitter.full, Duration.zero, Random(1)),
        Duration.zero,
      );
    });
  });

  group('CircuitBreaker', () {
    late FakeClock clock;
    late CircuitBreaker breaker;

    setUp(() {
      clock = FakeClock();
      breaker = CircuitBreaker(
        name: 'openai',
        failureThreshold: 3,
        successThreshold: 2,
        resetTimeout: const Duration(seconds: 30),
        clock: clock,
      );
    });

    tearDown(() => breaker.dispose());

    test('stays closed while calls succeed', () async {
      expect(await breaker.execute(() async => 'ok'), 'ok');
      expect(breaker.state, CircuitState.closed);
    });

    test('opens after the failure threshold and then fails fast', () async {
      for (var i = 0; i < 3; i++) {
        await expectLater(
          breaker.execute(() async => throw transient()),
          throwsA(isA<ProviderException>()),
        );
      }

      expect(breaker.state, CircuitState.open);

      var invoked = false;
      await expectLater(
        breaker.execute(() async {
          invoked = true;
          return 'never';
        }),
        throwsA(
          isA<CircuitOpenException>()
              .having((e) => e.circuitName, 'circuitName', 'openai')
              .having((e) => e.isRetryable, 'isRetryable', isTrue)
              .having(
                (e) => e.lastFailure,
                'lastFailure',
                isA<ProviderException>(),
              ),
        ),
      );
      expect(
        invoked,
        isFalse,
        reason: 'the point of an open circuit is not calling the dependency',
      );
    });

    test('a success resets the failure count', () async {
      await expectLater(
        breaker.execute(() async => throw transient()),
        throwsA(isA<ProviderException>()),
      );
      await breaker.execute(() async => 'ok');

      expect(breaker.consecutiveFailures, 0);
      expect(breaker.state, CircuitState.closed);
    });

    test('does not count a cancellation towards tripping', () async {
      // Otherwise a user closing a screen five times takes the provider
      // offline for everybody.
      for (var i = 0; i < 5; i++) {
        await expectLater(
          breaker.execute(() async => throw CancelledException('stopped')),
          throwsA(isA<CancelledException>()),
        );
      }

      expect(breaker.state, CircuitState.closed);
    });

    test('does not count a caller-side error towards tripping', () async {
      // Four hundred bad requests from one caller must not deny service to
      // every other caller sharing the breaker.
      for (var i = 0; i < 5; i++) {
        await expectLater(
          breaker.execute(() async => throw ValidationException('bad input')),
          throwsA(isA<ValidationException>()),
        );
      }

      expect(breaker.state, CircuitState.closed);
    });

    test('half-opens after the reset timeout', () async {
      await _trip(breaker);
      expect(breaker.state, CircuitState.open);

      await clock.advance(const Duration(seconds: 30));

      expect(breaker.state, CircuitState.halfOpen);
    });

    test('closes after enough half-open successes', () async {
      await _trip(breaker);
      await clock.advance(const Duration(seconds: 30));

      await breaker.execute(() async => 'probe 1');
      expect(
        breaker.state,
        CircuitState.halfOpen,
        reason: 'one probe is not proof',
      );

      await breaker.execute(() async => 'probe 2');
      expect(breaker.state, CircuitState.closed);
    });

    test('re-opens immediately when a probe fails', () async {
      await _trip(breaker);
      await clock.advance(const Duration(seconds: 30));

      await expectLater(
        breaker.execute(() async => throw transient()),
        throwsA(isA<ProviderException>()),
      );

      expect(breaker.state, CircuitState.open);
    });

    test('emits state transitions', () async {
      final states = <CircuitState>[];
      final subscription = breaker.stateChanges.listen(states.add);

      await _trip(breaker);
      await clock.advance(const Duration(seconds: 30));
      expect(breaker.state, CircuitState.halfOpen);
      await Future<void>.delayed(Duration.zero);

      expect(states, <CircuitState>[CircuitState.open, CircuitState.halfOpen]);
      await subscription.cancel();
    });

    test('can be tripped and reset by an operator', () async {
      breaker.trip();
      expect(breaker.state, CircuitState.open);

      breaker.reset();
      expect(breaker.state, CircuitState.closed);
      expect(await breaker.execute(() async => 'ok'), 'ok');
    });

    test('rejects use after disposal', () async {
      await breaker.dispose();

      await expectLater(
        breaker.execute(() async => 'x'),
        throwsA(isA<InvalidStateException>()),
      );
    });

    test('an unclassified error still counts as a failure', () async {
      for (var i = 0; i < 3; i++) {
        await expectLater(
          breaker.execute(() async => throw StateError('boom')),
          throwsStateError,
        );
      }

      expect(breaker.state, CircuitState.open);
    });
  });
}

Future<void> _trip(CircuitBreaker breaker) async {
  for (var i = 0; i < 3; i++) {
    await expectLater(
      breaker.execute(() async => throw transient()),
      throwsA(isA<ProviderException>()),
    );
  }
}
