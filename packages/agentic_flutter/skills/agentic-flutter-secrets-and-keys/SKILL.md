---
name: agentic-flutter-secrets-and-keys
description: >-
  Use when deciding where an API key lives in a Flutter app built on
  agentic_flutter: SecretStore, InMemorySecretStore, DartDefineSecretStore,
  LayeredSecretStore, wiring flutter_secure_storage, and the backend-proxy
  option. Read this before shipping anything that calls a model provider
  directly, or for "how do I store the API key".
license: MIT
metadata:
  package: agentic_flutter
  min-version: 0.2.0
---

# Where the API key lives

## The uncomfortable fact

**A key compiled into an app is a key you have published.** An APK or IPA is a
zip file; strings inside it are readable in minutes, obfuscation included. This
is not a Flutter weakness — it is true of every client app — and no
`SecretStore` implementation changes it.

So there are exactly two honest designs:

| Design | Who pays | When to use |
|---|---|---|
| **The user brings their own key** | the user | developer tools, power-user apps, prototypes |
| **A backend you authenticate to** | you | anything consumer-facing, anything monetised |

Everything else — dart-defines, obfuscated constants, keys fetched at first
launch and cached — is the first design with extra steps and a worse story when
the key leaks.

## The port

```dart
abstract interface class SecretStore implements Disposable {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}
```

Shipped implementations:

```dart
InMemorySecretStore();                 // writable, gone when the process ends
const DartDefineSecretStore(           // compile-time, debug convenience
  values: {'GEMINI_API_KEY': String.fromEnvironment('GEMINI_API_KEY')},
);
LayeredSecretStore([writable, readOnlyFallback]);   // reads in order, writes to the front
```

`String.fromEnvironment` must be written at the call site: it is a const
function the compiler resolves, so no library can look a name up on your behalf.

`secrets.require('KEY')` throws a `ConfigurationException` naming the key when it
is missing, rather than letting an empty string reach the provider and come back
as a confusing 401. An empty value counts as missing.

## The user's own key

Keep it in the platform keychain — one small class over
`flutter_secure_storage`, which stays your dependency rather than the
framework's:

```dart
final class SecureSecretStore implements SecretStore {
  SecureSecretStore(this._storage);
  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) => _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);

  @override
  Future<void> dispose() async {}
}
```

Then a settings screen writes it and the app reads it. Say in the UI that the
key is theirs, stays on the device, and is billed to their account.

## The backend proxy

The app authenticates as its user (Firebase Auth, your own tokens); the backend
holds the provider key and forwards the call. Benefits beyond secrecy: you can
rate-limit per user, cap spend, swap models without an app release, and revoke a
single user rather than rotating one key for everyone.

With `agentic_llm` this is a `baseUrl` change — point an OpenAI-compatible model
at your proxy and send your own auth header:

```dart
OpenAiCompatibleChatModel.custom(
  baseUrl: Uri.parse('https://api.myapp.com/llm/v1'),
  model: 'gpt-5.6',
  provider: 'myapp',
  apiKey: await session.idToken(),   // your token, not the provider's key
);
```

`agentic_llm_firebase`-style adapters (Firebase AI Logic) are the same idea with
the backend already built, including App Check.

## In development

```dart
final secrets = LayeredSecretStore([
  InMemorySecretStore(),                       // what the settings screen writes
  const DartDefineSecretStore(                 // convenience, debug only
    values: {'GEMINI_API_KEY': String.fromEnvironment('GEMINI_API_KEY')},
  ),
]);
```

```sh
flutter run --dart-define=GEMINI_API_KEY=...
```

`DartDefineSecretStore` refuses to expose values in a release build unless you
name them in `allowInRelease` — which exists so that opting in is a deliberate,
greppable act.

## Checklist before shipping

- [ ] No provider key in the repository, in `--dart-define` for release, or in a
      committed `.env`.
- [ ] The key path is either "the user's own key in secure storage" or "a
      backend proxy".
- [ ] Spend is capped somewhere — `AgentBudget.maxCost` in the app, rate limits
      in the proxy, or both.
- [ ] A revocation story: what you do when a key leaks anyway.
- [ ] Logs do not contain the key. Redaction covers conventional names
      (`apiKey`, `token`, `authorization`); an unconventional one is on you.

## Common mistakes

- Treating obfuscation as protection.
- Committing a `.env` with a live key, then rotating nothing because the repo is
  private "for now".
- Reading the key once at start-up and caching it in a global, so the settings
  screen cannot change it.
- Storing a key in the SQLite database next to the conversations rather than in
  the keychain.

## See also

- `agentic-flutter-add-chat-agent` — where the key is used
- `agentic-llm-choose-provider` — pointing a model at a proxy
- `create-agentic-app-scaffold` — the generated `lib/secrets.dart`
