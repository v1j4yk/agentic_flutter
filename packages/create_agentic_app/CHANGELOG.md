# Changelog

## 0.1.0

Initial release.

### Added

- **`create_agentic_app <name>`** — generates a Flutter project built on the
  framework: a chat screen, an agent with three tools, human approval for the
  one that changes something, a live trace panel, and four tests that pass
  offline.
- **Demo mode** — the generated app runs against a scripted model before any
  key exists, so the first run shows an app rather than an error about
  credentials.
- **Providers** — `--provider=openai|anthropic|gemini|ollama` wires the right
  adapter, key name and settings copy.
- **Name validation** — hyphens, capitals, reserved words and a collision with
  the framework's own package names are refused *before* anything is written,
  with the closest legal name suggested. Each of those otherwise fails later,
  from pub, with a message about a pubspec the user did not write.
- **`--framework-path`** — depends on a local checkout rather than a published
  version, which is how CI generates a project and compiles it.
- **Nothing is written unless everything can be** — a half-generated project is
  worse than none, because `flutter run` then fails for a reason unrelated to
  the real problem.

### Notes

The package has **no dependencies**. It writes files; it does not use the
framework — which is what lets it be installed before the framework is
published.

Platform folders are not generated. `flutter create .` produces them correctly,
and a template carrying its own Gradle and Xcode boilerplate ships a stale
toolchain to everyone who runs it.
