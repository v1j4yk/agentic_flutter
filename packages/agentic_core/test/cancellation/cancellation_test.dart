import 'dart:async';

import 'package:agentic_core/agentic_core.dart';
import 'package:agentic_core/testing.dart';
import 'package:test/test.dart';

void main() {
  group('CancellationToken', () {
    test('starts active and becomes cancelled once', () {
      final source = CancellationTokenSource();

      expect(source.token.isCancelled, isFalse);
      source
        ..cancel('first')
        ..cancel('second');

      expect(source.token.isCancelled, isTrue);
      expect(
        source.token.reason,
        'first',
        reason: 'cancellation is terminal; the first reason wins',
      );
    });

    test('throwIfCancelled names the operation', () {
      final source = CancellationTokenSource()..cancel('user stopped');

      expect(
        () => source.token.throwIfCancelled(operation: 'agent.run'),
        throwsA(
          isA<CancelledException>()
              .having((e) => e.operation, 'operation', 'agent.run')
              .having((e) => e.reason, 'reason', 'user stopped')
              .having((e) => e.isRetryable, 'isRetryable', isFalse),
        ),
      );
    });

    test('CancellationToken.none is never cancelled', () {
      expect(CancellationToken.none.isCancelled, isFalse);
      expect(CancellationToken.none.throwIfCancelled, returnsNormally);
    });

    test('whenCancelled completes on cancellation', () async {
      final source = CancellationTokenSource();
      var completed = false;

      unawaited(source.token.whenCancelled.then((_) => completed = true));
      await Future<void>.delayed(Duration.zero);
      expect(completed, isFalse);

      source.cancel();
      await Future<void>.delayed(Duration.zero);
      expect(completed, isTrue);
    });

    test(
      'whenCancelled completes immediately for an already-cancelled token',
      () async {
        final source = CancellationTokenSource()..cancel();

        await expectLater(source.token.whenCancelled, completes);
      },
    );

    test('onCancelled fires for late registration', () {
      final source = CancellationTokenSource()..cancel();
      var fired = false;

      source.token.onCancelled(() => fired = true);

      expect(
        fired,
        isTrue,
        reason: 'a late listener must not be silently dropped',
      );
    });

    test('onCancelled subscription can be removed', () {
      final source = CancellationTokenSource();
      var fired = false;

      final unsubscribe = source.token.onCancelled(() => fired = true);
      unsubscribe();
      source.cancel();

      expect(fired, isFalse);
    });

    test('a callback may deregister another during dispatch', () {
      final source = CancellationTokenSource();
      final order = <String>[];
      late CancellationSubscription second;

      source.token
        ..onCancelled(() {
          order.add('first');
          second();
        })
        ..onCancelled(() => order.add('second'));
      second = source.token.onCancelled(() => order.add('third'));

      source.cancel();

      expect(order, contains('first'));
      expect(order, isNot(contains('third')));
    });
  });

  group('race', () {
    test('returns the value when work finishes first', () async {
      final source = CancellationTokenSource();

      final result = await source.token.race(Future<String>.value('done'));

      expect(result, 'done');
    });

    test('throws when cancellation wins', () async {
      final source = CancellationTokenSource();
      final never = Completer<String>();

      final raced = source.token.race(never.future, operation: 'slow');
      source.cancel('gave up');

      await expectLater(raced, throwsA(isA<CancelledException>()));
    });

    test('propagates the underlying error unchanged', () async {
      final source = CancellationTokenSource();

      await expectLater(
        source.token.race(Future<String>.error(StateError('boom'))),
        throwsA(isA<StateError>()),
      );
    });

    test('throws synchronously for an already-cancelled token', () {
      final source = CancellationTokenSource()..cancel();

      expect(
        () => source.token.race(Future<String>.value('x')),
        throwsA(isA<CancelledException>()),
      );
    });
  });

  group('bind', () {
    test('forwards events and completes normally', () async {
      final source = CancellationTokenSource();
      final events = await source.token
          .bind(Stream<int>.fromIterable([1, 2, 3]))
          .toList();

      expect(events, [1, 2, 3]);
    });

    test('ends the stream with an error when cancelled mid-flight', () async {
      final source = CancellationTokenSource();
      final controller = StreamController<int>();
      final received = <int>[];
      Object? error;

      final done = Completer<void>();
      source.token
          .bind(controller.stream, operation: 'llm.stream')
          .listen(
            received.add,
            onError: (Object e) => error = e,
            onDone: done.complete,
          );

      controller.add(1);
      await Future<void>.delayed(Duration.zero);
      source.cancel('user left');
      await done.future;

      expect(received, [1]);
      expect(
        error,
        isA<CancelledException>(),
        reason: 'closing quietly would be indistinguishable from finishing',
      );
      await controller.close();
    });

    test('cancels the upstream subscription so the socket closes', () async {
      final source = CancellationTokenSource();
      var upstreamCancelled = false;
      final controller = StreamController<int>(
        onCancel: () => upstreamCancelled = true,
      );

      final subscription = source.token
          .bind(controller.stream)
          .listen((_) {}, onError: (_) {});

      controller.add(1);
      await Future<void>.delayed(Duration.zero);
      source.cancel();
      await Future<void>.delayed(Duration.zero);

      expect(upstreamCancelled, isTrue);
      await subscription.cancel();
      await controller.close();
    });

    test('an already-cancelled token yields an immediate error', () async {
      final source = CancellationTokenSource()..cancel();

      await expectLater(
        source.token.bind(Stream<int>.fromIterable([1])).toList(),
        throwsA(isA<CancelledException>()),
      );
    });
  });

  group('merge', () {
    test('cancels when either parent cancels', () {
      final first = CancellationTokenSource();
      final second = CancellationTokenSource();
      final merged = CancellationToken.merge(first.token, second.token);

      expect(merged.token.isCancelled, isFalse);
      second.cancel('second won');

      expect(merged.token.isCancelled, isTrue);
      expect(merged.token.reason, 'second won');
    });

    test('is already cancelled when a parent was', () {
      final first = CancellationTokenSource()..cancel('already');
      final merged = CancellationToken.merge(
        first.token,
        CancellationToken.none,
      );

      expect(merged.token.isCancelled, isTrue);
      expect(merged.token.reason, 'already');
    });

    test('disposing the merge releases parent registrations', () async {
      final first = CancellationTokenSource();
      final merged = CancellationToken.merge(
        first.token,
        CancellationToken.none,
      );

      await merged.dispose();
      first.cancel();

      expect(
        merged.token.isCancelled,
        isFalse,
        reason: 'a disposed merge no longer observes its parents',
      );
    });
  });

  group('deadlines', () {
    test('cancelAfter fires on the injected clock', () async {
      final clock = FakeClock();
      final source = CancellationTokenSource(clock: clock)
        ..cancelAfter(const Duration(seconds: 30));

      expect(source.token.isCancelled, isFalse);
      await clock.advance(const Duration(seconds: 30));

      expect(source.token.isCancelled, isTrue);
      expect(source.token.reason, contains('deadline'));
    });

    test('disposing before the deadline drops it', () async {
      final clock = FakeClock();
      final source = CancellationTokenSource(clock: clock)
        ..cancelAfter(const Duration(seconds: 30));

      await source.dispose();
      await clock.advance(const Duration(seconds: 60));

      expect(source.token.isCancelled, isFalse);
    });

    test('disposing a source does not cancel it', () async {
      // A scope that finished normally must not make its result look cancelled.
      final source = CancellationTokenSource();
      await source.dispose();

      expect(source.token.isCancelled, isFalse);
    });
  });

  group('NullableCancellationToken', () {
    test('treats null as never cancelled', () {
      const CancellationToken? absent = null;

      expect(absent.isCancelled, isFalse);
      expect(absent.orNone, same(CancellationToken.none));
      expect(absent.throwIfCancelled, returnsNormally);
    });
  });
}
