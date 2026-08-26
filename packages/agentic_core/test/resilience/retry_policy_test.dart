import 'package:agentic_core/agentic_core.dart';
import 'package:agentic_core/testing.dart';
import 'package:test/test.dart';

/// A retryable failure, used to drive the policy without touching a network.
ProviderException transient([int status = 503]) => ProviderException(
  'upstream unavailable',
  provider: 'test',
  statusCode: status,
);

ValidationException permanent() => ValidationException('bad request');

void main() {
  group('RetryPolicy', () {
    test('returns the first successful result without waiting', () async {
      final clock = FakeClock(autoAdvance: true);
      var attempts = 0;

      final result = await const RetryPolicy().execute(
        (attempt) async {
          attempts++;
          return 'ok';
        },
        operation: 'test',
        clock: clock,
      );

      expect(result, 'ok');
      expect(attempts, 1);
      expect(
        clock.requestedDelays,
        isEmpty,
        reason: 'a successful first attempt must not sleep',
      );
    });

    test('retries a retryable failure up to maxAttempts', () async {
      final clock = FakeClock(autoAdvance: true);
      var attempts = 0;

      await expectLater(
        const RetryPolicy(
          maxAttempts: 3,
          backoff: FixedScheduleBackoff([Duration(seconds: 1)]),
        ).execute(
          (attempt) async {
            attempts++;
            throw transient();
          },
          operation: 'test',
          clock: clock,
        ),
        throwsA(isA<ProviderException>()),
      );

      expect(attempts, 3, reason: 'maxAttempts counts total attempts');
      expect(
        clock.requestedDelays,
        hasLength(2),
        reason: 'three attempts means two waits',
      );
    });

    test('does not retry a non-retryable failure', () async {
      final clock = FakeClock(autoAdvance: true);
      var attempts = 0;

      await expectLater(
        const RetryPolicy(maxAttempts: 5).execute(
          (attempt) async {
            attempts++;
            throw permanent();
          },
          operation: 'test',
          clock: clock,
        ),
        throwsA(isA<ValidationException>()),
      );

      expect(attempts, 1);
      expect(clock.requestedDelays, isEmpty);
    });

    test(
      'succeeds on a later attempt and reports the attempt number',
      () async {
        final clock = FakeClock(autoAdvance: true);
        final seen = <int>[];

        final result =
            await const RetryPolicy(
              maxAttempts: 4,
              backoff: FixedScheduleBackoff([Duration(milliseconds: 10)]),
            ).execute(
              (attempt) async {
                seen.add(attempt);
                if (attempt < 3) throw transient();
                return attempt;
              },
              operation: 'test',
              clock: clock,
            );

        expect(result, 3);
        expect(seen, [
          1,
          2,
          3,
        ], reason: 'attempt numbers are 1-based and dense');
      },
    );

    test('follows the exponential schedule', () async {
      final clock = FakeClock(autoAdvance: true);

      await expectLater(
        const RetryPolicy(
          maxAttempts: 4,
          backoff: ExponentialBackoff(
            initial: Duration(milliseconds: 100),
            jitter: Jitter.none,
          ),
        ).execute(
          (attempt) async => throw transient(),
          operation: 'test',
          clock: clock,
        ),
        throwsA(isA<ProviderException>()),
      );

      expect(clock.requestedDelays, <Duration>[
        const Duration(milliseconds: 100),
        const Duration(milliseconds: 200),
        const Duration(milliseconds: 400),
      ]);
    });

    test('prefers a provider Retry-After over the computed backoff', () async {
      final clock = FakeClock(autoAdvance: true);

      await expectLater(
        const RetryPolicy(
          maxAttempts: 2,
          backoff: ConstantBackoff(Duration(milliseconds: 100)),
        ).execute(
          (attempt) async => throw RateLimitException(
            'slow down',
            provider: 'test',
            retryAfter: const Duration(seconds: 5),
          ),
          operation: 'test',
          clock: clock,
        ),
        throwsA(isA<RateLimitException>()),
      );

      expect(clock.requestedDelays.single, const Duration(seconds: 5));
    });

    test('never waits less than the local schedule', () async {
      final clock = FakeClock(autoAdvance: true);

      await expectLater(
        const RetryPolicy(
          maxAttempts: 2,
          backoff: ConstantBackoff(Duration(seconds: 2)),
        ).execute(
          (attempt) async => throw RateLimitException(
            'slow down',
            provider: 'test',
            // A provider asking for 1ms must not talk the client into a
            // tight loop.
            retryAfter: const Duration(milliseconds: 1),
          ),
          operation: 'test',
          clock: clock,
        ),
        throwsA(isA<RateLimitException>()),
      );

      expect(clock.requestedDelays.single, const Duration(seconds: 2));
    });

    test('stops before sleeping past maxElapsed', () async {
      final clock = FakeClock(autoAdvance: true);
      var attempts = 0;

      await expectLater(
        const RetryPolicy(
          maxAttempts: 10,
          backoff: ConstantBackoff(Duration(seconds: 4)),
          maxElapsed: Duration(seconds: 5),
        ).execute(
          (attempt) async {
            attempts++;
            throw transient();
          },
          operation: 'test',
          clock: clock,
        ),
        throwsA(isA<ProviderException>()),
      );

      // One 4s wait fits inside the 5s budget; a second would not, so the
      // policy gives up rather than sleeping into a deadline it cannot meet.
      expect(attempts, 2);
      expect(clock.requestedDelays, hasLength(1));
    });

    test('annotates the final error with what the loop did', () async {
      final clock = FakeClock(autoAdvance: true);

      try {
        await const RetryPolicy(
          maxAttempts: 3,
          backoff: ConstantBackoff(Duration(milliseconds: 1)),
        ).execute<String>(
          (attempt) async => throw transient(),
          operation: 'openai.chat',
          clock: clock,
        );
        fail('expected the policy to rethrow');
      } on ProviderException catch (error) {
        expect(error.annotations['retry.attempts'], 3);
        expect(error.annotations['retry.operation'], 'openai.chat');
        expect(
          error.toJson()['annotations'],
          containsPair('retry.attempts', 3),
        );
      }
    });

    test('propagates cancellation without retrying', () async {
      final clock = FakeClock(autoAdvance: true);
      final source = CancellationTokenSource();
      var attempts = 0;

      await expectLater(
        const RetryPolicy(maxAttempts: 5).execute(
          (attempt) async {
            attempts++;
            source.cancel('user stopped');
            throw CancelledException('stopped', reason: 'user stopped');
          },
          operation: 'test',
          cancellation: source.token,
          clock: clock,
        ),
        throwsA(isA<CancelledException>()),
      );

      expect(attempts, 1, reason: 'cancellation is never retried');
    });

    test('abandons a pending backoff when cancelled mid-wait', () async {
      final clock = FakeClock();
      final source = CancellationTokenSource();

      final pending =
          const RetryPolicy(
            maxAttempts: 5,
            backoff: ConstantBackoff(Duration(minutes: 2)),
          ).execute(
            (attempt) async => throw transient(),
            operation: 'test',
            cancellation: source.token,
            clock: clock,
          );

      // Let the first attempt fail and the policy settle into its wait.
      await Future<void>.delayed(Duration.zero);
      source.cancel('user navigated away');

      await expectLater(pending, throwsA(isA<CancelledException>()));
      await clock.resolvePending();
    });

    test('retryIf can narrow but not widen the default', () async {
      final clock = FakeClock(autoAdvance: true);
      var attempts = 0;

      await expectLater(
        RetryPolicy(
          maxAttempts: 4,
          backoff: const ConstantBackoff(Duration(milliseconds: 1)),
          // Would widen to a non-retryable error, which must be ignored.
          retryIf: (error, attempt) => true,
        ).execute(
          (attempt) async {
            attempts++;
            throw permanent();
          },
          operation: 'test',
          clock: clock,
        ),
        throwsA(isA<ValidationException>()),
      );

      expect(attempts, 1);
    });

    test('onRetry observes each wait', () async {
      final clock = FakeClock(autoAdvance: true);
      final observed = <(int, Duration)>[];

      await expectLater(
        RetryPolicy(
          maxAttempts: 3,
          backoff: const ConstantBackoff(Duration(milliseconds: 50)),
          onRetry: (error, attempt, delay) => observed.add((attempt, delay)),
        ).execute(
          (attempt) async => throw transient(),
          operation: 'test',
          clock: clock,
        ),
        throwsA(isA<ProviderException>()),
      );

      expect(observed, [
        (1, const Duration(milliseconds: 50)),
        (2, const Duration(milliseconds: 50)),
      ]);
    });

    test('RetryPolicy.none disables retrying', () async {
      var attempts = 0;

      await expectLater(
        RetryPolicy.none.execute(
          (attempt) async {
            attempts++;
            throw transient();
          },
          operation: 'test',
          clock: FakeClock(autoAdvance: true),
        ),
        throwsA(isA<ProviderException>()),
      );

      expect(attempts, 1);
    });

    test('executeOrNull reports failure as null', () async {
      AgenticException? captured;

      final result = await RetryPolicy.none.executeOrNull<String>(
        (attempt) async => throw transient(),
        operation: 'test',
        clock: FakeClock(autoAdvance: true),
        onFailure: (error) => captured = error,
      );

      expect(result, isNull);
      expect(captured, isA<ProviderException>());
    });
  });
}
