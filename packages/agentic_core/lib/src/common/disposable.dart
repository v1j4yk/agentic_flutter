/// Deterministic teardown for objects that own resources.
///
/// Dart has no destructors and no `using` block, so a framework that opens
/// sockets, database handles, isolates and stream controllers has to make
/// ownership explicit. Everything in the framework that holds a resource
/// implements [Disposable], and everything that *creates* one is responsible
/// for disposing it.
library;

import 'dart:async';

import 'package:agentic_core/src/error/agentic_exception.dart';

/// An object that owns resources which must be released explicitly.
///
/// Implementations must make [dispose] idempotent. Double disposal happens
/// routinely in Flutter — a `State` disposing in `dispose()` while a provider
/// scope tears down the same object — and throwing on the second call turns a
/// harmless race into a crash.
abstract interface class Disposable {
  /// Releases every resource held by this object.
  ///
  /// Must be idempotent, must not throw for an already-disposed object, and
  /// should complete even if an underlying resource fails to close: a partial
  /// teardown that gives up halfway leaks the remainder.
  Future<void> dispose();
}

/// Disposes a group of objects as a unit, in reverse registration order.
///
/// Reverse order matters. If a store is registered before the event bus that
/// publishes its change notifications, tearing down in registration order
/// would close the store while the bus can still deliver to it. Last in, first
/// out mirrors construction and is the same discipline a stack frame uses.
///
/// ```dart
/// final bag = DisposableBag()
///   ..add(eventBus)
///   ..add(vectorStore)
///   ..addCallback(subscription.cancel);
///
/// await bag.dispose(); // subscription, then store, then bus.
/// ```
final class DisposableBag implements Disposable {
  final List<Future<void> Function()> _teardowns = <Future<void> Function()>[];
  bool _disposed = false;

  /// Whether [dispose] has already run.
  bool get isDisposed => _disposed;

  /// Number of registered teardowns still pending.
  int get length => _teardowns.length;

  /// Registers [disposable] for teardown.
  ///
  /// Throws an [InvalidStateException] if the bag is already disposed, because
  /// silently dropping the registration would leak the resource — the one
  /// failure mode this type exists to prevent.
  void add(Disposable disposable) => addCallback(disposable.dispose);

  /// Registers an arbitrary [teardown] callback.
  ///
  /// Accepts `Future<void> Function()` so that `subscription.cancel` and
  /// `controller.close` can be registered directly.
  void addCallback(Future<void> Function() teardown) {
    if (_disposed) {
      throw InvalidStateException(
        'Cannot register a teardown on a disposed DisposableBag; the resource '
        'would never be released.',
        currentState: 'disposed',
        expectedState: 'active',
      );
    }
    _teardowns.add(teardown);
  }

  /// Registers a synchronous [teardown] callback.
  void addSync(void Function() teardown) => addCallback(() async => teardown());

  /// Disposes every registered object, most recently added first.
  ///
  /// Every teardown runs even if an earlier one throws. Failures are collected
  /// and rethrown together as a single [UnexpectedException], so one broken
  /// adapter cannot leak the rest of the graph.
  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;

    final total = _teardowns.length;
    final failures = <Object>[];
    for (final teardown in _teardowns.reversed) {
      try {
        await teardown();
      } on Object catch (error) {
        failures.add(error);
      }
    }
    _teardowns.clear();

    if (failures.isEmpty) return;
    throw UnexpectedException(
      'Disposal failed for ${failures.length} of $total resource(s): '
      '${failures.map((e) => e.toString()).join('; ')}',
      cause: failures.first,
      component: 'DisposableBag',
      details: <String, Object?>{'failureCount': failures.length},
    );
  }
}

/// Runs [body] with [resource] and disposes it afterwards, even on failure.
///
/// The closest thing Dart offers to a `using` block, and named `withResource`
/// rather than `using` because it reaches every application through the
/// umbrella package — and `using` is a word an application is entitled to
/// have its own meaning for. Prefer it over a manual `try` / `finally` at call
/// sites that create a short-lived resource.
///
/// ```dart
/// final answer = await withResource(
///   HttpChatModel(...),
///   (model) => model.generate(request),
/// );
/// ```
Future<R> withResource<T extends Disposable, R>(
  T resource,
  FutureOr<R> Function(T resource) body,
) async {
  try {
    return await body(resource);
  } finally {
    await resource.dispose();
  }
}
