---
name: agentic-tools-generator-troubleshoot-build
description: >-
  Use when a build_runner build fails or produces nothing for
  agentic_tools_generator: missing part directives, unsupported parameter and
  return types, stale or conflicting outputs, annotations the builder never
  sees, and generated names that clash. Read this for "no .g.dart file",
  "unsupported type", or "build_runner conflicting outputs".
license: MIT
metadata:
  package: agentic_tools_generator
  min-version: 0.2.0
  sample-types: Customer
---

# When the build fails

## First, the two commands

```sh
dart run build_runner build --delete-conflicting-outputs
dart run build_runner watch --delete-conflicting-outputs
```

For a Flutter package, `flutter pub run build_runner build …`. Most "it is not
generating" reports are a stale output directory, and `--delete-conflicting-outputs`
is the fix.

## Nothing was generated

Check, in this order:

1. **The `part` directive.** Every file with annotations needs
   `part 'my_file.g.dart';` next to its imports. Without it the builder has
   nowhere to write, and says so quietly.
2. **The dev dependency.** `agentic_tools_generator` must be in
   `dev_dependencies`, alongside `build_runner`.
3. **Visibility.** A private function (`_lookup`) is not generated for; make it
   public or wrap it.
4. **Reachability.** The file must be under `lib/` in the package being built.
   A tool defined in `test/` or `bin/` is not part of the library build.
5. **The annotation itself.** `@ToolFunction(isReadOnly: true)` — the argument
   is required, and an annotation missing it will not compile in the first place.

## "Unsupported parameter type"

The model can only send JSON, so parameters are limited to `String`, `int`,
`double`, `num`, `bool`, `DateTime`, enums, lists of those, and
`Map<String, Object?>`. A domain object cannot cross that boundary.

```dart
// Rejected: the model has no way to construct a Customer.
@ToolFunction(isReadOnly: true)
Future<String> summarise(Customer customer) => …

// Accepted: take an id and look it up inside the tool.
@ToolFunction(isReadOnly: true)
Future<String> summarise(@ToolParam('The customer id.') String customerId) async {
  final customer = await repository.find(customerId);
  …
}
```

The same applies to return values: `String`, `ToolResult`, `Map`, a class with
`toJson()`, lists, numbers, booleans and `void`. Anything else needs a
`toJson()` or a manual conversion to `ToolResult`.

Three parameter types are exempt because the framework supplies them rather than
the model: `ToolInvocation`, `AgenticContext` and `CancellationToken`.

## "Conflicting outputs" or a stale schema

A signature changed and the old `.g.dart` is still there. Delete and rebuild:

```sh
dart run build_runner clean
dart run build_runner build --delete-conflicting-outputs
```

Symptoms of a stale build are worse than a hard failure, because the schema the
model sees no longer matches the function: arguments arrive under old names and
the tool fails at run time. If a tool is behaving as though it is from last
week, rebuild before debugging anything else.

## Generated names clash

Two functions named `search` in different files generate two `searchTool`s in
the same library. Set the tool name explicitly, and keep the Dart names
distinct:

```dart
@ToolFunction(isReadOnly: true, name: 'search_orders')
Future<String> searchOrders(…) => …
```

The framework also has a test forbidding one name being exported by two
packages, so a clash inside the framework fails there — but inside *your*
package it is yours to avoid.

## Committing generated files

Either is fine, as long as it is a decision:

- **Commit them** — CI needs no build step, and diffs show when a tool's schema
  changed, which is a prompt change worth reviewing.
- **Ignore them** — cleaner diffs, but every checkout and every CI job must run
  the builder before analysis.

Do not edit them. They are regenerated on the next build, and an edit is lost
without warning.

## Still stuck

Run the builder with more detail — `dart run build_runner build --verbose` names
the file and the offending element. Failing that, reduce: delete annotations
until the build passes, then add them back one at a time. It is usually a
parameter type.

## See also

- `agentic-tools-generator-annotate-functions` — the annotations and what they generate
- `agentic-tools-write-a-tool` — writing the tool by hand instead
