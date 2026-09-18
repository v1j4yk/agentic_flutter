# Working in this repository

For AI coding assistants, and for anyone who wants the short version. The long
version is [CONTRIBUTING.md](CONTRIBUTING.md); the reasoning behind the design
is [doc/architecture.md](doc/architecture.md).

## What this is

A monorepo of Dart and Flutter packages for building AI agents: models, tools,
agents, workflows, memory, retrieval, MCP, persistence, testing and Flutter
widgets. Fourteen published packages plus two internal ones, in one pub
workspace.

`agentic_flutter` is **not** a workspace member — `flutter_test` and
`package:test` pin incompatible versions of `test_api`, so it resolves
separately with `flutter pub get` and reaches its siblings through
`pubspec_overrides.yaml`.

## Commands

```sh
dart pub get                      # the workspace
melos run verify                  # the full gate; run before opening a PR
melos run test                    # pure-Dart packages
melos run test:flutter            # agentic_flutter, needs the Flutter SDK
melos run analyze                 # --fatal-infos --fatal-warnings
melos run format                  # check only; format:fix rewrites
melos run api                     # public API snapshots must match
melos run api:write               # record an intended API change
melos run skills                  # bundled Agent Skills must be valid
melos run fix:check               # `dart fix` data still migrates
melos run models:check            # model identifiers still exist (needs keys)
melos run template:check          # the project template still compiles
```

## Rules that are enforced, not advised

- **Every public member is documented.** `public_member_api_docs: error`.
- **The API surface is committed.** `api/*.txt` and `api/*.signatures.txt` are
  generated; never edit them by hand. A diff there is an API change and belongs
  in a changelog entry.
- **No two packages may export the same name.** There is a test for it. Before
  naming a new export, check: an annotation once named `AgentTool` collided with
  `agentic_agents`' `AgentTool` and reached a user.
- **Dependencies point downward only**, per the layering in
  `doc/architecture.md`. Flutter is a leaf: only `agentic_flutter` may import it.
- **No test in CI touches a network or a real clock.** Inject `Clock`, use
  `FakeChatModel` or a cassette.
- **Skills must pass `melos run skills`**, which checks the packaging rules and
  every framework name a skill teaches against `api/`.

## Conventions worth matching

- Values are immutable; ports are `abstract interface class`; open hierarchies
  are `base` so members can be added in a minor release.
- Expected failures are values (`ToolResult.failure`, `Result`); only
  cancellation escapes. Everything thrown is an `AgenticException` with a stable
  `code` and an `isRetryable` answer.
- `AgenticContext` is passed explicitly — never a `Zone`, never a global.
- Budgets are constructor parameters, not optional guards.
- Comments explain **why**, including what was considered and rejected. Match
  that: a comment restating the code is noise here.
- British spelling in prose (`summarise`, `behaviour`); API names follow Dart
  convention.

## Before you change a public API

1. Is it breaking under `doc/architecture.md §6`? Removing or renaming a member,
   an exception `code`, an event `type` or a registry key; adding a required
   parameter; narrowing a type; tightening validation.
2. If yes: add a `fix_data.yaml` entry where the change is mechanical, a note in
   `doc/migration-*.md`, and a changelog entry under `### Breaking`.
3. Run `melos run api:write` and include the snapshot diff in the same commit.

## Releasing

`tool/release.dart` publishes in dependency order; `--publish` is the only flag
that writes to pub.dev. Compile a package against the *published* versions of
its siblings before release — the workspace resolves siblings locally and hides
a missing API.

## Things that will waste your time if you do not know them

- Deleting `packages/agentic_flutter/example/pubspec_overrides.yaml` breaks CI:
  it is checked in deliberately, against the usual gitignore rule.
- After publishing, `dart pub get` may claim a just-published version does not
  exist; delete the cached `<pkg>-versions.json` under the pub cache.
- A default model identifier is a fact about someone else's product. Two have
  already been retired under us. `melos run models:check` is how that is caught.
