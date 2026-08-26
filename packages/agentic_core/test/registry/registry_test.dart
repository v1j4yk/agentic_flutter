import 'package:agentic_core/agentic_core.dart';
import 'package:test/test.dart';

class FakeProvider implements Disposable {
  FakeProvider(this.name);

  final String name;
  bool disposed = false;

  @override
  Future<void> dispose() async => disposed = true;
}

void main() {
  late Registry<FakeProvider> registry;

  setUp(() => registry = Registry<FakeProvider>(kind: 'chat model'));

  test('registers and resolves by key', () {
    final provider = FakeProvider('openai');
    registry.register('openai', provider);

    expect(registry.resolve('openai'), same(provider));
    expect(registry.contains('openai'), isTrue);
    expect(registry.keys, <String>['openai']);
  });

  test('rejects a duplicate key unless replacement is explicit', () {
    registry.register('openai', FakeProvider('a'));

    expect(
      () => registry.register('openai', FakeProvider('b')),
      throwsA(
        isA<ConfigurationException>().having(
          (e) => e.message,
          'message',
          contains('replace: true'),
        ),
      ),
    );

    registry.register('openai', FakeProvider('b'), replace: true);
    expect(registry.resolve('openai').name, 'b');
  });

  test('suggests the closest key on a typo', () {
    registry
      ..register('openai', FakeProvider('a'))
      ..register('anthropic', FakeProvider('b'));

    expect(
      () => registry.resolve('opeanai'),
      throwsA(
        isA<NotFoundException>()
            .having(
              (e) => e.message,
              'message',
              contains('Did you mean `openai`?'),
            )
            .having((e) => e.identifier, 'identifier', 'opeanai')
            .having((e) => e.resourceType, 'resourceType', 'chat model'),
      ),
    );
  });

  test('does not suggest a key that is not actually close', () {
    registry.register('anthropic', FakeProvider('a'));

    expect(
      () => registry.resolve('qdrant'),
      throwsA(
        isA<NotFoundException>().having(
          (e) => e.message,
          'message',
          isNot(contains('Did you mean')),
        ),
      ),
    );
  });

  test('reports an empty registry clearly', () {
    expect(
      () => registry.resolve('anything'),
      throwsA(
        isA<NotFoundException>().having(
          (e) => e.message,
          'message',
          contains('No chat model is registered.'),
        ),
      ),
    );
  });

  test('maybeResolve returns null instead of throwing', () {
    expect(registry.maybeResolve('missing'), isNull);
  });

  group('lazy factories', () {
    test('do not construct until first resolution', () {
      var constructed = 0;
      registry.registerFactory('openai', () {
        constructed++;
        return FakeProvider('openai');
      });

      expect(constructed, 0, reason: 'registration must be free');

      registry
        ..resolve('openai')
        ..resolve('openai');

      expect(constructed, 1, reason: 'singleton by default');
    });

    test('can construct per resolution', () {
      var constructed = 0;
      registry
        ..registerFactory('openai', () {
          constructed++;
          return FakeProvider('openai');
        }, singleton: false)
        ..resolve('openai')
        ..resolve('openai');

      expect(constructed, 2);
    });
  });

  group('lifecycle', () {
    test('dispose releases every constructed value', () async {
      final eager = FakeProvider('eager');
      var lazyConstructed = false;

      registry
        ..register('eager', eager)
        ..registerFactory('lazy', () {
          lazyConstructed = true;
          return FakeProvider('lazy');
        });

      await registry.dispose();

      expect(eager.disposed, isTrue);
      expect(
        lazyConstructed,
        isFalse,
        reason: 'an unresolved factory has nothing to release',
      );
    });

    test('rejects use after disposal', () async {
      await registry.dispose();

      expect(
        () => registry.register('x', FakeProvider('x')),
        throwsA(isA<InvalidStateException>()),
      );
      expect(
        () => registry.resolve('x'),
        throwsA(isA<InvalidStateException>()),
      );
    });

    test('unregister removes without disposing', () {
      final provider = FakeProvider('a');
      registry.register('a', provider);

      expect(registry.unregister('a'), isTrue);
      expect(registry.unregister('a'), isFalse);
      expect(
        provider.disposed,
        isFalse,
        reason: 'the registry may not own a value it was handed',
      );
    });
  });

  test('resolveAll forces every factory', () {
    registry
      ..registerFactory('a', () => FakeProvider('a'))
      ..registerFactory('b', () => FakeProvider('b'));

    expect(registry.resolveAll().keys, <String>['a', 'b']);
    expect(registry.length, 2);
  });
}
