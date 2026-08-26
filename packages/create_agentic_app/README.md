# create_agentic_app

Generates a working Flutter app built on the agentic framework: a chat screen,
an agent with tools, human approval for anything that changes something, a live
trace panel, and an API key kept out of the source.

```sh
dart pub global activate create_agentic_app
create_agentic_app my_app

cd my_app
flutter create . --platforms ios,android,macos,windows,linux
flutter run
```

It starts in **demo mode** against a scripted model, so there is something on
screen before there is an API key. That order is deliberate: a template whose
first run is an error about credentials teaches the wrong thing about the
framework and about shipping keys.

## What you get

```
my_app/
  lib/
    main.dart                    the runtime, the scope, the app's lifetime
    agent.dart                   which model, which tools, which instructions
    tools.dart                   three tools, one of which needs approval
    secrets.dart                 where the key lives — and why not in source
    screens/chat_screen.dart
    screens/settings_screen.dart
  test/app_test.dart             four tests that pass offline
```

| Option | Effect |
|---|---|
| `--provider=openai` | Also `anthropic`, `gemini`, `ollama`. Default `openai` |
| `--directory=path` | Where to write it. Defaults to the project name |
| `--force` | Write into a directory that is not empty |
| `--framework-path=path` | Depend on a local checkout rather than a published version |

## Four decisions the template makes for you

**The agent is bounded.** `AgentBudget.interactive`. The characteristic failure
of an agentic app is not a crash; it is a loop that runs correctly and forever
while the bill grows. A template without a budget teaches that bounds are
optional.

**Runs stop when the app leaves the screen.** `BackgroundPolicy.cancelOnPause`.
On a phone this is the setting that decides whether a forgotten conversation
keeps billing.

**One tool needs a person.** `save_note` sets `requiresApproval: true`, so the
approval sheet actually appears on first run rather than being a paragraph in a
README. The executor *denies* a gated tool when no handler is configured, which
the generated code wires up correctly.

**The key is never in the source.** `lib/secrets.dart` uses a `SecretStore` and
explains, in the file, why a key compiled into an app is a key you have
published — and what the two real alternatives are.

## No platform folders

`flutter create .` generates the `android/`, `ios/` and `macos/` directories.
Those are hundreds of files of Gradle, Xcode and manifest boilerplate that
Flutter itself produces correctly and that would rot in a template within one
release. Generating them here would mean shipping a stale Gradle plugin version
to everyone who ran this.

## How these templates stay honest

They are Dart source held in Dart strings, which means the analyser never sees
them. That is the classic way a scaffolding tool ships something that does not
compile.

So CI generates a project, runs `flutter analyze` over it, and runs its tests.
That job caught two missing imports the first time it ran — which is exactly the
argument for having it.

## Zero dependencies

This package depends on nothing. It writes files; it does not use the framework.
That is what lets it be installed before the framework is published, and what
keeps `pub global activate` from pulling a dozen packages onto a machine that
only wants a scaffold.
