# Changelog

## 0.2.0

Initial release.

- Generates a `FunctionTool` for each top-level function annotated with
  `@ToolFunction`, and an `agentTools` extension getter for classes with annotated
  methods, bound to the instance.
- Builds the JSON schema from parameters: `String`, `int`, `double`, `num`,
  `bool`, `DateTime`, enums, lists of those, and `Map<String, Object?>`.
  Nullable and defaulted parameters are optional, and defaults appear in the
  schema. `ToolInvocation`, `AgenticContext` and `CancellationToken` parameters
  are supplied by the framework.
- Converts return values: `String`, `ToolResult`, `Map`, classes with
  `toJson()`, lists, numbers, booleans and `void`.
- Fails the build, pointing at the source, for unsupported parameter or return
  types, a missing description, duplicate or invalid tool names, private or
  generic functions, generic classes, and missing imports.
