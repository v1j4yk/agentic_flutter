import 'dart:math';

import 'package:agentic_core/agentic_core.dart';
import 'package:agentic_core/testing.dart';
import 'package:test/test.dart';

class Closeable implements Disposable {
  Closeable(this.name, this.log);

  final String name;
  final List<String> log;

  @override
  Future<void> dispose() async => log.add(name);
}

void main() {
  group('Ulid', () {
    test('produces identifiers of the documented shape', () {
      final id = Ulid().generate();

      expect(id, hasLength(Ulid.length));
      expect(RegExp('^[${Ulid.alphabet}]+\$').hasMatch(id), isTrue);
    });

    test('sorts lexicographically in creation order', () {
      var millis = 1700000000000;
      final ulid = Ulid(now: () => DateTime.fromMillisecondsSinceEpoch(millis));

      final ids = <String>[];
      for (var i = 0; i < 50; i++) {
        ids.add(ulid.generate());
        millis += 1;
      }

      expect(ids, orderedEquals(<String>[...ids]..sort()));
    });

    test('stays strictly increasing inside one millisecond', () {
      // Agent loops emit many events per millisecond; identifiers minted in the
      // same tick must still order.
      final ulid = Ulid(now: () => DateTime.fromMillisecondsSinceEpoch(42));

      final ids = List<String>.generate(1000, (_) => ulid.generate());

      expect(ids.toSet(), hasLength(1000), reason: 'no collisions');
      expect(ids, orderedEquals(<String>[...ids]..sort()));
    });

    test('survives a clock that moves backwards', () {
      var millis = 1700000000000;
      final ulid = Ulid(now: () => DateTime.fromMillisecondsSinceEpoch(millis));

      final first = ulid.generate();
      millis -= 5000; // A network time correction, or the user changing it.
      final second = ulid.generate();

      expect(
        second.compareTo(first),
        greaterThan(0),
        reason: 'ordering is preserved even when wall-clock time is not',
      );
    });

    test('recovers the embedded timestamp', () {
      final when = DateTime.utc(2026, 5, 17, 8, 30);
      final id = Ulid(now: () => when).generate();

      expect(Ulid.timestampOf(id), when);
    });

    test('rejects malformed input when reading a timestamp', () {
      expect(Ulid.timestampOf('too-short'), isNull);
      expect(Ulid.timestampOf('U' * Ulid.length), isNull);
    });

    test('encodes the full 48-bit timestamp range without truncation', () {
      // The web platform truncates bitwise operations to 32 bits, which is why
      // the encoder uses `~/` and `%`. A far-future date proves it.
      final far = DateTime.utc(9999);
      final id = Ulid(now: () => far).generate();

      expect(Ulid.timestampOf(id), far);
    });

    test('honours an injected random source', () {
      final a = Ulid(random: Random(7), now: () => DateTime.utc(2026));
      final b = Ulid(random: Random(7), now: () => DateTime.utc(2026));

      expect(a.generate(), b.generate());
    });

    test('prefixed identifiers stay sortable within their namespace', () {
      final ids = Ulid();

      expect(ids.prefixed('run'), startsWith('run_'));
    });
  });

  group('SequentialIdGenerator', () {
    test('counts predictably', () {
      final ids = SequentialIdGenerator(prefix: 'evt-', start: 5);

      expect(ids.generate(), 'evt-5');
      expect(ids.generate(), 'evt-6');
      expect(ids.nextValue, 7);
    });
  });

  group('JsonMapReader', () {
    final json = <String, Object?>{
      'model': 'gpt-4o',
      'count': 3,
      'countAsDouble': 3.0,
      'ratio': 0.5,
      'flag': true,
      'usage': {'total': 42},
      'choices': [
        {'index': 0},
        {'index': 1},
      ],
      'tags': ['a', 'b'],
      'created': 1700000000,
      'createdIso': '2026-01-01T00:00:00Z',
      'nothing': null,
    };

    test('reads required values', () {
      expect(json.requireString('model'), 'gpt-4o');
      expect(json.requireInt('count'), 3);
      expect(json.requireDouble('ratio'), 0.5);
      expect(json.requireBool('flag'), isTrue);
      expect(json.requireObject('usage').requireInt('total'), 42);
      expect(json.requireList('tags'), <String>['a', 'b']);
    });

    test('accepts an integral double where an int was declared', () {
      // Several providers serialise token counts as 42.0.
      expect(json.requireInt('countAsDouble'), 3);
    });

    test('widens an int where a double was declared', () {
      expect(json.requireDouble('count'), 3.0);
    });

    test('names the offending field on a type mismatch', () {
      expect(
        () => json.requireString('count'),
        throwsA(
          isA<SerializationException>()
              .having((e) => e.path, 'path', 'count')
              .having((e) => e.message, 'message', contains('`count`')),
        ),
      );
    });

    test('distinguishes absent from wrongly typed for optionals', () {
      expect(json.optionalString('missing'), isNull);
      expect(json.optionalString('nothing'), isNull);
      expect(
        () => json.optionalString('count'),
        throwsA(isA<SerializationException>()),
        reason: 'a wrong type is a contract violation even when optional',
      );
    });

    test('treats an absent collection as empty', () {
      expect(json.listOrEmpty('missing'), isEmpty);
      expect(json.stringListOrEmpty('tags'), <String>['a', 'b']);
    });

    test('reports the element index when decoding a list', () {
      final malformed = <String, Object?>{
        'choices': [
          {'ok': 1},
          'not-an-object',
        ],
      };

      expect(
        () => malformed.decodeList('choices', (e) => e),
        throwsA(
          isA<SerializationException>().having(
            (e) => e.path,
            'path',
            'choices[1]',
          ),
        ),
      );
    });

    test('parses both timestamp encodings as UTC', () {
      expect(json.requireDateTime('created').isUtc, isTrue);
      expect(json.requireDateTime('createdIso'), DateTime.utc(2026));
    });

    test('falls back for an unknown enum value', () {
      const mapping = <String, int>{'stop': 1, 'length': 2};
      final finish = <String, Object?>{'reason': 'content_filter'};

      expect(
        finish.requireEnum('reason', mapping, orElse: 0),
        0,
        reason:
            'a provider adding a finish reason must not be a breaking change',
      );
      expect(
        () => finish.requireEnum('reason', mapping),
        throwsA(isA<SerializationException>()),
      );
    });

    test('prune removes null-valued entries', () {
      expect(
        pruneNulls(<String, Object?>{'a': 1, 'b': null}),
        <String, Object?>{'a': 1},
      );
    });
  });

  group('DisposableBag', () {
    test('disposes in reverse registration order', () async {
      final log = <String>[];
      final bag = DisposableBag()
        ..add(Closeable('bus', log))
        ..add(Closeable('store', log))
        ..addSync(() => log.add('subscription'));

      await bag.dispose();

      expect(log, <String>['subscription', 'store', 'bus']);
      expect(bag.isDisposed, isTrue);
    });

    test('continues past a failing teardown and reports it', () async {
      final log = <String>[];
      final bag = DisposableBag()
        ..add(Closeable('first', log))
        ..addCallback(() async => throw StateError('boom'))
        ..add(Closeable('last', log));

      await expectLater(bag.dispose(), throwsA(isA<UnexpectedException>()));

      expect(log, <String>[
        'last',
        'first',
      ], reason: 'one broken adapter must not leak the rest of the graph');
    });

    test('is idempotent', () async {
      final bag = DisposableBag();
      await bag.dispose();

      await expectLater(bag.dispose(), completes);
    });

    test('refuses late registration rather than leaking', () async {
      final bag = DisposableBag();
      await bag.dispose();

      expect(() => bag.addSync(() {}), throwsA(isA<InvalidStateException>()));
    });
  });

  group('using', () {
    test('disposes after the body completes', () async {
      final log = <String>[];

      final result = await withResource(
        Closeable('resource', log),
        (resource) async => resource.name.toUpperCase(),
      );

      expect(result, 'RESOURCE');
      expect(log, <String>['resource']);
    });

    test('disposes even when the body throws', () async {
      final log = <String>[];

      await expectLater(
        withResource(
          Closeable('resource', log),
          (_) async => throw StateError('boom'),
        ),
        throwsStateError,
      );

      expect(log, <String>['resource']);
    });
  });

  group('Clock', () {
    test('SystemClock reports UTC', () {
      expect(const SystemClock().now().isUtc, isTrue);
    });

    test('timeout fails an operation that overruns', () async {
      final clock = FakeClock();
      final pending = clock.timeout(
        () => Future<String>.delayed(const Duration(days: 1), () => 'late'),
        limit: const Duration(seconds: 5),
        name: 'openai.chat',
      );

      // Attach the expectation before advancing: otherwise the future
      // completes with an error nobody is listening to yet, and the test zone
      // reports it as unhandled.
      final expectation = expectLater(
        pending,
        throwsA(
          isA<AgenticTimeoutException>()
              .having((e) => e.operation, 'operation', 'openai.chat')
              .having((e) => e.isRetryable, 'isRetryable', isTrue),
        ),
      );
      await clock.advance(const Duration(seconds: 5));
      await expectation;
    });

    test('timeout passes a result that arrives in time', () async {
      final clock = FakeClock();

      final result = await clock.timeout(
        () async => 'fast',
        limit: const Duration(seconds: 5),
        name: 'test',
      );

      expect(result, 'fast');
      await clock.resolvePending();
    });

    test('measure reports elapsed time on the injected clock', () async {
      final clock = FakeClock();

      final pending = clock.measure(() async {
        await clock.delay(const Duration(seconds: 3));
        return 'done';
      });
      await clock.advance(const Duration(seconds: 3));
      final (value, elapsed) = await pending;

      expect(value, 'done');
      expect(elapsed, const Duration(seconds: 3));
    });
  });

  group('FakeClock', () {
    test('records every requested delay', () async {
      final clock = FakeClock(autoAdvance: true);

      await clock.delay(const Duration(seconds: 1));
      await clock.delay(const Duration(seconds: 2));

      expect(clock.requestedDelays, <Duration>[
        const Duration(seconds: 1),
        const Duration(seconds: 2),
      ]);
      expect(clock.totalRequestedDelay, const Duration(seconds: 3));
    });

    test('advances time as auto-advancing delays complete', () async {
      final clock = FakeClock(autoAdvance: true);
      final start = clock.now();

      await clock.delay(const Duration(minutes: 5));

      expect(clock.now().difference(start), const Duration(minutes: 5));
    });

    test('refuses to move time backwards', () {
      expect(
        () => FakeClock().advance(const Duration(seconds: -1)),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('advanceToNext steps one pending delay at a time', () async {
      final clock = FakeClock();
      unawaitedDelay(clock, const Duration(seconds: 10));
      unawaitedDelay(clock, const Duration(seconds: 30));

      expect(await clock.advanceToNext(), const Duration(seconds: 10));
      expect(await clock.advanceToNext(), const Duration(seconds: 20));
      expect(await clock.advanceToNext(), isNull);
    });
  });
}

void unawaitedDelay(FakeClock clock, Duration duration) {
  clock.delay(duration).ignore();
}
