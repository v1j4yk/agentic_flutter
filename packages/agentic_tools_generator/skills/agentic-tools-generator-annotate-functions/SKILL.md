---
name: agentic-tools-generator-annotate-functions
description: >-
  Use when generating agent tools from Dart functions with
  agentic_tools_generator: the @ToolFunction and @ToolParam annotations,
  build_runner setup, which parameter and return types are supported, tools
  from class methods, and what to do when the build fails. Read this instead of
  writing FunctionTool and a JsonSchema by hand.
license: MIT
metadata:
  package: agentic_tools_generator
  min-version: 0.2.0
---

# Generating tools from annotated Dart

## Setup

```yaml
dependencies:
  agentic_tools: ^0.3.0

dev_dependencies:
  agentic_tools_generator: ^0.3.0
  build_runner: ^2.4.0
```

```sh
dart run build_runner build --delete-conflicting-outputs
dart run build_runner watch          # while developing
```

## An annotated function

```dart
import 'package:agentic_tools/agentic_tools.dart';

part 'weather.g.dart';

/// Returns the current weather for a city.
///
/// Use for questions about conditions right now. Not for forecasts —
/// use `forecast` for those.
@ToolFunction(isReadOnly: true)
Future<String> cityWeather(
  @ToolParam('The city to look up, in English.') String city, {
  @ToolParam('Units: metric or imperial.') String units = 'metric',
}) async => api.current(city, units: units);
```

The generator writes `cityWeatherTool` — a `FunctionTool` with the JSON schema,
argument decoding and result conversion — and checks all of it at build time.
Register it like any other tool:

```dart
final registry = ToolRegistry()..register(cityWeatherTool);
```

`isReadOnly` is **required** and has no default. That is deliberate: a tool that
changes something must say so, because the flag drives approval and the
untrusted-content rule. Other fields: `name`, `description` (defaults to the doc
comment), `isIdempotent`, `requiresApproval`, `returnsUntrustedContent`, `tags`,
`timeout`.

## Methods on a class

```dart
@ToolFunction(isReadOnly: true)
Future<List<Order>> listOrders(@ToolParam('Customer email.') String customer) => …

@ToolFunction(isReadOnly: false, requiresApproval: true)
Future<String> cancelOrder(@ToolParam('The order id.') String id) => …
```

On a class with annotated methods the generator adds an `agentTools` extension
getter bound to the instance, so tools that need a repository, an API client or
a database get one without globals:

```dart
final registry = ToolRegistry()..registerAll(OrderTools(api).agentTools);
```

## Supported types

| Parameters | Returns |
|---|---|
| `String`, `int`, `double`, `num`, `bool`, `DateTime` | `String`, `ToolResult` |
| enums, and lists of any supported type | `Map`, any class with `toJson()` |
| `Map<String, Object?>` | lists, numbers, booleans, `void` |

Nullable and defaulted parameters become optional, and defaults appear in the
schema so the model sees them. `ToolInvocation`, `AgenticContext` and
`CancellationToken` parameters are supplied by the framework rather than by the
model — which is how a generated tool stays cancellable:

```dart
@ToolFunction(isReadOnly: true)
Future<String> longSearch(String query, CancellationToken cancellation) async {
  for (final page in pages) {
    cancellation.throwIfCancelled(operation: 'long_search');
    …
  }
}
```

An unsupported type is a build error naming the parameter, not a runtime
surprise.

## Descriptions are the prompt

The doc comment becomes the tool description and `@ToolParam` becomes the
parameter description. They are what the model reads to decide whether and how
to call the tool, so write them for a stranger: what it does, when to use it,
and — the clause that does most of the work — when *not* to.

## When the build fails

- **`part 'x.g.dart';` missing** — every file with annotations needs it.
- **Unsupported parameter type** — take a `Map<String, Object?>` or a `String`
  id and look the object up inside the tool. The model can only send JSON.
- **Nothing generated** — the file was not reachable from the build, or the
  annotation is on a private function.
- **Stale output** — `dart run build_runner build --delete-conflicting-outputs`.
- **Name clash** — two tools generating the same name; set `name:` explicitly.

Generated files are build output. Do not edit them, and decide once whether to
commit them (committing makes CI simpler; not committing keeps diffs clean).

## When to write the tool by hand instead

The generator covers the common shape. Write `FunctionTool` yourself when the
schema is dynamic, when the tool is constructed from configuration at run time,
or when you need `DelegatingTool` behaviour around it.

## Common mistakes

- Omitting `@ToolParam`, leaving the model to guess what a parameter means.
- `isReadOnly: true` on something that writes, quietly opting out of the
  untrusted-content approval rule.
- Expecting a domain object as a parameter; the model sends JSON.
- Forgetting to re-run the build after changing a signature, then debugging a
  schema that no longer matches.

## See also

- `agentic-tools-write-a-tool` — the contract being generated, and the rules
- `agentic-tools-generator-troubleshoot-build` — build errors in depth
- `agentic-llm-structured-output` — schemas for model output rather than input
