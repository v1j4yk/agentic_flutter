/// A keyed registry for pluggable implementations.
///
/// The framework's extension points — LLM providers, tools, vector stores,
/// workflow node types, memory backends — all share one shape: a name resolves
/// to an implementation, third parties contribute names the core has never
/// heard of, and a lookup for an unknown name should fail with a message a
/// developer can act on.
///
/// [Registry] is that shape, once, generically. Every extension point uses it
/// rather than reinventing a map with slightly different error handling.
///
/// # Why not a general-purpose service locator
///
/// A locator that resolves by [Type] cannot express "three OpenAI-compatible
/// providers registered under three names", which is the normal case here.
/// Resolution is therefore by string key within a typed registry: one registry
/// per extension point, keys within it.
library;

import 'package:agentic_core/src/common/disposable.dart';
import 'package:agentic_core/src/error/agentic_exception.dart';

/// Lazily constructs a registered value.
typedef RegistryFactory<T> = T Function();

/// A named collection of implementations of [T].
///
/// ```dart
/// final providers = Registry<ChatModel>(kind: 'chat model');
/// providers.registerFactory('openai', () => OpenAiChatModel(apiKey: key));
///
/// final model = providers.resolve('openai');
/// providers.resolve('opeanai'); // NotFoundException: did you mean `openai`?
/// ```
final class Registry<T extends Object> implements Disposable {
  /// Creates an empty registry.
  ///
  /// [kind] names what is being registered and appears in every error message,
  /// so make it a readable noun phrase: `chat model`, `tool`, `vector store`.
  Registry({required this.kind});

  /// Human-readable name for what this registry holds.
  final String kind;

  final Map<String, _Entry<T>> _entries = <String, _Entry<T>>{};
  bool _disposed = false;

  /// Every registered key, in registration order.
  Iterable<String> get keys => _entries.keys;

  /// Number of registered entries.
  int get length => _entries.length;

  /// Whether nothing is registered.
  bool get isEmpty => _entries.isEmpty;

  /// Whether anything is registered.
  bool get isNotEmpty => _entries.isNotEmpty;

  /// Registers an already-constructed [value] under [key].
  ///
  /// Registering a duplicate key throws unless [replace] is set. Silently
  /// overwriting is the wrong default: two packages that both register
  /// `openai` is a dependency conflict, and discovering it at startup is far
  /// better than discovering it when the wrong one answers.
  void register(String key, T value, {bool replace = false}) {
    _throwIfDisposed();
    _guardDuplicate(key, replace: replace);
    _entries[key] = _Entry<T>.instance(value);
  }

  /// Registers a [create] function invoked on first resolution.
  ///
  /// Lazy registration is what keeps startup cheap: an application can register
  /// twelve providers and pay for none of them until one is used. That matters
  /// most on mobile, where constructing an HTTP client or opening a database
  /// per unused provider is measurable at launch.
  ///
  /// When [singleton] is true — the default — the value is created once and
  /// reused. Set it to false for implementations that hold per-use state.
  void registerFactory(
    String key,
    RegistryFactory<T> create, {
    bool replace = false,
    bool singleton = true,
  }) {
    _throwIfDisposed();
    _guardDuplicate(key, replace: replace);
    _entries[key] = _Entry<T>.factory(create, singleton: singleton);
  }

  /// Registers every entry of [values].
  void registerAll(Map<String, T> values, {bool replace = false}) {
    for (final entry in values.entries) {
      register(entry.key, entry.value, replace: replace);
    }
  }

  /// Returns the implementation registered under [key].
  ///
  /// Throws a [NotFoundException] naming the closest registered key when there
  /// is one. A typo in a provider name is the single most common wiring
  /// mistake, and "did you mean `openai`?" turns a ten-minute debugging session
  /// into a five-second fix.
  T resolve(String key) {
    _throwIfDisposed();
    final entry = _entries[key];
    if (entry == null) throw _notFound(key);
    return entry.resolve();
  }

  /// Returns the implementation under [key], or `null` when absent.
  T? maybeResolve(String key) {
    _throwIfDisposed();
    return _entries[key]?.resolve();
  }

  /// Whether [key] is registered.
  bool contains(String key) => _entries.containsKey(key);

  /// Removes [key], returning whether anything was removed.
  ///
  /// Any already-constructed value is *not* disposed: the registry did not
  /// necessarily create it, and disposing something a caller still holds is
  /// worse than leaking it. Dispose it yourself if you own it.
  bool unregister(String key) => _entries.remove(key) != null;

  /// Resolves every registered entry.
  ///
  /// Forces construction of every lazy factory, so use it for diagnostics and
  /// startup validation rather than on a hot path.
  Map<String, T> resolveAll() => <String, T>{
    for (final key in _entries.keys) key: resolve(key),
  };

  /// Disposes every constructed value that is [Disposable], then clears.
  ///
  /// Factories that were never resolved are simply dropped — there is nothing
  /// to release.
  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    final bag = DisposableBag();
    for (final entry in _entries.values) {
      final value = entry.constructedValue;
      if (value is Disposable) bag.add(value);
    }
    _entries.clear();
    await bag.dispose();
  }

  void _guardDuplicate(String key, {required bool replace}) {
    if (replace || !_entries.containsKey(key)) return;
    throw ConfigurationException(
      'A $kind is already registered under `$key`. Pass `replace: true` if '
      'overriding it is intentional.',
      setting: '$kind.$key',
    );
  }

  NotFoundException _notFound(String key) {
    final suggestion = _closestKey(key);
    final available = _entries.isEmpty
        ? 'No $kind is registered.'
        : 'Registered: ${_entries.keys.map((k) => '`$k`').join(', ')}.';
    return NotFoundException(
      'No $kind registered under `$key`. '
      '${suggestion == null ? '' : 'Did you mean `$suggestion`? '}$available',
      resourceType: kind,
      identifier: key,
    );
  }

  /// Returns the registered key closest to [key], if one is close enough.
  ///
  /// The threshold scales with the key's length so that short names do not
  /// match everything: `gpt` should not suggest `gpq`.
  String? _closestKey(String key) {
    if (_entries.isEmpty) return null;
    final threshold = (key.length / 3).ceil().clamp(1, 4);
    String? best;
    var bestDistance = threshold + 1;
    for (final candidate in _entries.keys) {
      final distance = _editDistance(
        key.toLowerCase(),
        candidate.toLowerCase(),
      );
      if (distance < bestDistance) {
        bestDistance = distance;
        best = candidate;
      }
    }
    return bestDistance <= threshold ? best : null;
  }

  void _throwIfDisposed() {
    if (!_disposed) return;
    throw InvalidStateException(
      'This $kind registry has been disposed.',
      currentState: 'disposed',
      expectedState: 'active',
    );
  }

  @override
  String toString() => 'Registry<$T>($kind, ${_entries.length} entries)';
}

/// Levenshtein distance, used only for "did you mean" suggestions.
///
/// Implemented with two rolling rows rather than a full matrix: registries are
/// small, but this runs on a failure path where an allocation spike would be a
/// poor trade for code that is barely shorter.
int _editDistance(String a, String b) {
  if (a == b) return 0;
  if (a.isEmpty) return b.length;
  if (b.isEmpty) return a.length;

  var previous = List<int>.generate(b.length + 1, (i) => i, growable: false);
  var current = List<int>.filled(b.length + 1, 0, growable: false);

  for (var i = 0; i < a.length; i++) {
    current[0] = i + 1;
    for (var j = 0; j < b.length; j++) {
      final substitution = previous[j] + (a[i] == b[j] ? 0 : 1);
      final insertion = current[j] + 1;
      final deletion = previous[j + 1] + 1;
      current[j + 1] = substitution < insertion
          ? (substitution < deletion ? substitution : deletion)
          : (insertion < deletion ? insertion : deletion);
    }
    final swap = previous;
    previous = current;
    current = swap;
  }
  return previous[b.length];
}

final class _Entry<T extends Object> {
  _Entry.instance(T value) : _value = value, _create = null, _singleton = true;

  _Entry.factory(RegistryFactory<T> create, {required bool singleton})
    : _create = create,
      _singleton = singleton,
      _value = null;

  final RegistryFactory<T>? _create;
  final bool _singleton;
  T? _value;

  /// The value if it has been constructed, without constructing it.
  T? get constructedValue => _value;

  T resolve() {
    final existing = _value;
    if (existing != null) return existing;
    final create = _create!;
    final created = create();
    if (_singleton) _value = created;
    return created;
  }
}
