/// Where an app keeps API keys.
///
/// # The problem, stated plainly
///
/// An API key compiled into a Flutter app is readable by anyone who downloads
/// it. Not "hard to find" — an APK is a zip file, and `strings` on the runtime
/// binary finds a hard-coded key in seconds. The same is true of a key in
/// `--dart-define`, in an asset, or in a `.env` bundled at build time. Every
/// one of those is a key you have published.
///
/// This is not a Flutter problem; it is what shipping software to devices you
/// do not control means. There are exactly two honest answers:
///
/// 1. **Do not ship the key.** Put a small service between the app and the
///    provider, authenticate the *user* to that service, and let it hold the
///    provider key. The app never sees it. This is the only approach that is
///    actually safe, and it is what a production application should do.
/// 2. **Let the user supply their own key.** Common for developer tools and
///    power-user apps. The key is the user's, so keeping it out of your build
///    is the whole point — and it needs somewhere safe to live on the device,
///    which is what [SecretStore] is for.
///
/// # Why this package ships a port and not an implementation
///
/// Real secure storage means the iOS Keychain and the Android Keystore, which
/// means a plugin, which means a platform dependency in everybody's build —
/// including for the applications that correctly chose option 1 and have no
/// secrets on the device at all. So the port lives here and the adapter lives
/// in your app, which is a five-line class.
library;

import 'dart:async';

import 'package:agentic_core/agentic_core.dart';
import 'package:flutter/foundation.dart';

/// Stores and retrieves secrets on the device.
///
/// Implement this over `flutter_secure_storage`, `shared_preferences` on a
/// desktop target where the OS keychain is unavailable, or your own storage:
///
/// ```dart
/// final class KeychainSecretStore implements SecretStore {
///   KeychainSecretStore(this._storage);
///   final FlutterSecureStorage _storage;
///
///   @override
///   Future<String?> read(String key) => _storage.read(key: key);
///
///   @override
///   Future<void> write(String key, String value) =>
///       _storage.write(key: key, value: value);
///
///   @override
///   Future<void> delete(String key) => _storage.delete(key: key);
///
///   @override
///   Future<void> dispose() async {}
/// }
/// ```
abstract interface class SecretStore implements Disposable {
  /// Returns the secret stored under [key], or `null`.
  Future<String?> read(String key);

  /// Stores [value] under [key], replacing anything already there.
  Future<void> write(String key, String value);

  /// Removes the secret under [key].
  Future<void> delete(String key);
}

/// Conveniences available on every [SecretStore].
extension SecretStoreOperations on SecretStore {
  /// Returns the secret under [key], or throws naming what is missing.
  ///
  /// The call to use at start-up. A [ConfigurationException] that says which
  /// key is absent is worth far more than a 401 from a provider three screens
  /// later.
  Future<String> require(String key) async {
    final value = await read(key);
    if (value != null && value.isNotEmpty) return value;
    throw ConfigurationException(
      'No secret is stored under `$key`. Ask the user for it, or point the '
      'app at a backend that holds the provider key instead of shipping one.',
      setting: key,
    );
  }

  /// Whether a non-empty secret is stored under [key].
  Future<bool> has(String key) async {
    final value = await read(key);
    return value != null && value.isNotEmpty;
  }
}

/// Keeps secrets in memory for the life of the process.
///
/// Correct for tests, and for a session-only key the user retypes each launch —
/// which is genuinely the safest option for a shared device. It is **not**
/// secure storage and does not pretend to be: nothing survives a restart, and
/// nothing is encrypted.
final class InMemorySecretStore implements SecretStore {
  /// Creates a store, optionally pre-populated.
  InMemorySecretStore([Map<String, String> initial = const <String, String>{}])
    : _secrets = Map<String, String>.of(initial);

  final Map<String, String> _secrets;

  /// How many secrets are held.
  int get length => _secrets.length;

  @override
  Future<String?> read(String key) async => _secrets[key];

  @override
  Future<void> write(String key, String value) async => _secrets[key] = value;

  @override
  Future<void> delete(String key) async => _secrets.remove(key);

  @override
  Future<void> dispose() async => _secrets.clear();

  @override
  String toString() => 'InMemorySecretStore($length secret(s))';
}

/// Reads secrets from compile-time `--dart-define` values.
///
/// # Read this before using it
///
/// A `--dart-define` value is **baked into the binary**. It is convenient for
/// local development and for keys that are not secret — a base URL, a feature
/// flag, a public project identifier — and it is not a way to ship a private
/// API key. Anyone with the build can read it.
///
/// It is here because pretending the option does not exist does not stop people
/// using it; documenting exactly what it is worth does. In release builds it
/// refuses to serve any key not listed in `allowInRelease`, so the mistake is
/// caught at the first call rather than after publication.
///
/// ```dart
/// // flutter run --dart-define=OLLAMA_URL=http://localhost:11434
/// const store = DartDefineSecretStore(
///   values: {'OLLAMA_URL': String.fromEnvironment('OLLAMA_URL')},
///   allowInRelease: {'OLLAMA_URL'},
/// );
/// ```
final class DartDefineSecretStore implements SecretStore {
  /// Creates a store over compile-time [values].
  ///
  /// `String.fromEnvironment` must be called by *you*, at the call site: it is
  /// a const function the compiler resolves, so a library cannot look up a name
  /// on your behalf.
  const DartDefineSecretStore({
    required Map<String, String> values,
    Set<String> allowInRelease = const <String>{},
  }) : _values = values,
       _allowInRelease = allowInRelease;

  final Map<String, String> _values;
  final Set<String> _allowInRelease;

  @override
  Future<String?> read(String key) async {
    if (kReleaseMode && !_allowInRelease.contains(key)) {
      throw ConfigurationException(
        'A compile-time value for `$key` is baked into this build and readable '
        'by anyone who has it, so it is refused in release. Put the key behind '
        'a backend, or ask the user for it and keep it in a `SecretStore`. If '
        '`$key` is genuinely not a secret, list it in `allowInRelease`.',
        setting: key,
      );
    }
    final value = _values[key];
    return value == null || value.isEmpty ? null : value;
  }

  @override
  Future<void> write(String key, String value) async {
    throw CapabilityNotSupportedException(
      'Compile-time values cannot be written at runtime.',
      capability: 'write',
      component: 'DartDefineSecretStore',
    );
  }

  @override
  Future<void> delete(String key) async {
    throw CapabilityNotSupportedException(
      'Compile-time values cannot be deleted at runtime.',
      capability: 'delete',
      component: 'DartDefineSecretStore',
    );
  }

  @override
  Future<void> dispose() async {}

  @override
  String toString() => 'DartDefineSecretStore(${_values.length} value(s))';
}

/// Tries each store in order and returns the first answer.
///
/// The usual arrangement: the user's own key if they have entered one,
/// otherwise a development default.
///
/// ```dart
/// final secrets = LayeredSecretStore([keychain, devDefaults]);
/// ```
///
/// Writes go to the first store only, which is what makes "the user's key wins"
/// hold: a write must not land in the fallback and then be shadowed forever.
final class LayeredSecretStore implements SecretStore {
  /// Creates a layered store over [stores], most important first.
  LayeredSecretStore(Iterable<SecretStore> stores, {this.disposeStores = true})
    : _stores = List<SecretStore>.unmodifiable(stores),
      assert(stores.isNotEmpty, 'a layered store needs at least one layer');

  final List<SecretStore> _stores;

  /// Whether [dispose] closes the wrapped stores.
  final bool disposeStores;

  @override
  Future<String?> read(String key) async {
    for (final store in _stores) {
      // A layer that refuses — `DartDefineSecretStore` in release — must not
      // stop the layers behind it from answering.
      try {
        final value = await store.read(key);
        if (value != null && value.isNotEmpty) return value;
      } on AgenticException {
        continue;
      }
    }
    return null;
  }

  @override
  Future<void> write(String key, String value) =>
      _stores.first.write(key, value);

  @override
  Future<void> delete(String key) async {
    for (final store in _stores) {
      try {
        await store.delete(key);
      } on AgenticException {
        // A read-only layer has nothing to delete; the others still should.
        continue;
      }
    }
  }

  @override
  Future<void> dispose() async {
    if (!disposeStores) return;
    for (final store in _stores) {
      await store.dispose();
    }
  }

  @override
  String toString() => 'LayeredSecretStore(${_stores.length} layer(s))';
}
