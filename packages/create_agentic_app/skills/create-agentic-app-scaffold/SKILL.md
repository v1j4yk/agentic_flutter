---
name: create-agentic-app-scaffold
description: >-
  Use when starting a new Flutter AI agent app with create_agentic_app, or
  when explaining what the generated project contains: the command and its
  options, the files it writes and what each owns, demo mode without an API
  key, and the steps between a generated project and something shippable. Read
  this for "start a new agent app" or "scaffold a Flutter AI project".
license: MIT
metadata:
  package: create_agentic_app
  min-version: 0.2.0
---

# Scaffolding an agent app

## The command

```sh
dart pub global activate create_agentic_app
create_agentic_app my_app --provider=gemini
cd my_app
flutter create . --platforms android,ios
flutter run
```

Options: `--provider=openai|anthropic|gemini|ollama`, `--directory=path`,
`--force` to write into a non-empty directory, and `--framework-path=path` to
build against a local checkout of the framework rather than the published
packages.

`flutter create .` is a separate step because the generator writes the Dart
project, not the platform folders — which also means you choose which platforms
exist.

## It runs before you have a key

The generated app starts in **demo mode** against a scripted model: no key, no
network, same answers every time. Tap the key icon to switch to the real
provider. Start there — it keeps the first run from depending on somebody's
billing page, and it is the right way to develop the UI.

## What you get, and what owns what

| File | Owns |
|---|---|
| `lib/main.dart` | the runtime, the scope, the app's lifetime |
| `lib/agent.dart` | which model, which tools, which instructions |
| `lib/tools.dart` | what the agent can do |
| `lib/secrets.dart` | where the API key lives — read this before shipping |
| `lib/screens/` | the chat screen and the settings screen |
| `test/` | widget tests that pass on a fresh checkout |

Three tools are wired up, one of which changes something and therefore asks for
approval; there is a live trace panel; and the key is kept out of the source.
That is roughly the shape of a real app, on purpose — it is easier to delete
what you do not need than to discover what you were missing.

## The parts to change first

1. **`lib/tools.dart`** — replace the sample tools with yours. This is where an
   agent app is actually built; see `agentic-tools-write-a-tool`.
2. **`lib/agent.dart`** — instructions, model choice, budget.
3. **`lib/secrets.dart`** — decide, before shipping, whether users bring their
   own key or you proxy through a backend you authenticate to. A key compiled
   into an app is a key you have published; the file says so and gives both
   options.

## Between generated and shippable

The template is honest about being a starting point. Before a release:

- **Keys** — a backend proxy, or the user's own key in secure storage. Not a
  `--dart-define` in a release build.
- **Budgets** — the defaults are interactive; set a cost ceiling you would be
  comfortable paying per user per day.
- **Approval** — check that everything destructive has `requiresApproval: true`
  and `isReadOnly: false`.
- **Persistence** — add `agentic_sqlite` if conversations or memories should
  survive a restart.
- **Tests** — the generated widget tests run offline against the scripted
  model; keep them that way and add cases as you add tools.

## Using it as a library

The generator is also importable, which matters when scaffolding several
projects or testing what the template emits — that is how this framework's own
CI proves the template still compiles.

## Common mistakes

- Running `flutter run` before `flutter create .`, so there is no platform
  folder.
- A package name that is not `lowercase_with_underscores`; the generator
  refuses rather than producing a project that will not build.
- Shipping with `--dart-define` keys, which land in the binary.
- Deleting the approval handler because the prompt is annoying during
  development, and forgetting to put it back.

## See also

- `agentic-flutter-add-chat-agent` — what the generated screen is doing
- `agentic-tools-write-a-tool` — replacing the sample tools
- `agentic-flutter-secrets-and-keys` — the key decision, in full
