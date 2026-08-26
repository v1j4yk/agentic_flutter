/// Building a [Tool] from a closure.
///
/// Most tools have no state worth a class: they take arguments, do something,
/// and return a string. [FunctionTool] is the shorthand for those, and it is
/// what nearly every application will use.
library;

import 'dart:async';

import 'package:agentic_core/agentic_core.dart';
import 'package:agentic_tools/src/tool.dart';

/// The body of a [FunctionTool].
typedef ToolHandler = FutureOr<ToolResult> Function(ToolInvocation invocation);

/// A [Tool] backed by a closure.
///
/// ```dart
/// final searchTool = FunctionTool(
///   name: 'search_web',
///   description:
///       'Searches the public web and returns the top results with titles, '
///       'URLs and snippets. Use for current events and facts that may have '
///       'changed since training.',
///   parameters: JsonSchema.object(
///     properties: {
///       'query': JsonSchema.string(
///         description: "The search query, in the user's own words",
///       ),
///       'limit': JsonSchema.integer(minimum: 1, maximum: 10, defaultValue: 5),
///     },
///     required: {'query'},
///   ),
///   handler: (invocation) async {
///     final results = await searchApi.query(
///       invocation.require<String>('query'),
///       limit: invocation.optional<int>('limit', 5),
///     );
///     return ToolResult.success(results.map((r) => r.summary).join('\n'));
///   },
/// );
/// ```
final class FunctionTool implements Tool {
  /// Creates a tool from [handler].
  ///
  /// The parameters mirror [ToolSpec] so that the common case is one
  /// constructor call rather than a spec plus a wrapper.
  FunctionTool({
    required String name,
    required String description,
    required this.handler,
    JsonSchema? parameters,
    JsonSchema? returns,
    bool isReadOnly = true,
    bool isIdempotent = true,
    bool requiresApproval = false,
    Set<String> tags = const <String>{},
    Duration? timeout,
    String version = '1.0.0',
    List<ToolExample> examples = const <ToolExample>[],
  }) : spec = ToolSpec(
         name: name,
         description: description,
         parameters: parameters,
         returns: returns,
         isReadOnly: isReadOnly,
         isIdempotent: isIdempotent,
         requiresApproval: requiresApproval,
         tags: tags,
         timeout: timeout,
         version: version,
         examples: examples,
       );

  /// Creates a tool from an existing [spec].
  ///
  /// Useful when specs are declared in one place — a plugin manifest, a shared
  /// contract — and bound to implementations elsewhere.
  FunctionTool.fromSpec({required this.spec, required this.handler});

  /// Creates a tool whose handler returns plain text.
  ///
  /// The shortest possible form, for tools that answer with a string.
  ///
  /// ```dart
  /// FunctionTool.text(
  ///   name: 'now',
  ///   description: 'Returns the current time in ISO-8601 UTC.',
  ///   handler: (invocation) async =>
  ///       invocation.context.clock.now().toIso8601String(),
  /// );
  /// ```
  factory FunctionTool.text({
    required String name,
    required String description,
    required FutureOr<String> Function(ToolInvocation invocation) handler,
    JsonSchema? parameters,
    bool isReadOnly = true,
    bool isIdempotent = true,
    bool requiresApproval = false,
    Set<String> tags = const <String>{},
    Duration? timeout,
  }) => FunctionTool(
    name: name,
    description: description,
    parameters: parameters,
    isReadOnly: isReadOnly,
    isIdempotent: isIdempotent,
    requiresApproval: requiresApproval,
    tags: tags,
    timeout: timeout,
    handler: (invocation) async =>
        ToolResult.success(await handler(invocation)),
  );

  @override
  final ToolSpec spec;

  /// The closure invoked by [call].
  final ToolHandler handler;

  @override
  Future<ToolResult> call(ToolInvocation invocation) async =>
      handler(invocation);

  @override
  String toString() => 'FunctionTool(${spec.name})';
}

/// Wraps another [Tool], delegating everything by default.
///
/// The base for cross-cutting behaviour — caching, rate limiting, auditing,
/// mocking — added by composition rather than by inheriting from every concrete
/// tool. Override only what you need to change.
///
/// ```dart
/// final class CachingTool extends DelegatingTool {
///   CachingTool(super.inner, this._cache);
///
///   final Map<String, ToolResult> _cache;
///
///   @override
///   Future<ToolResult> call(ToolInvocation invocation) async {
///     final key = '${invocation.toolName}:${invocation.arguments}';
///     return _cache[key] ??= await super.call(invocation);
///   }
/// }
/// ```
abstract class DelegatingTool implements Tool {
  /// Wraps [inner].
  const DelegatingTool(this.inner);

  /// The wrapped tool.
  final Tool inner;

  @override
  ToolSpec get spec => inner.spec;

  @override
  Future<ToolResult> call(ToolInvocation invocation) => inner.call(invocation);
}

/// Presents a tool under a different name.
///
/// Two packages that both register `search` cannot coexist in one registry.
/// Renaming resolves that without forking either package, and is also how a
/// tool is given a name that reads better for a particular agent's job.
final class RenamedTool extends DelegatingTool {
  /// Wraps [inner], exposing it as [name].
  RenamedTool(super.inner, {required String name, String? description})
    : spec = inner.spec.copyWith(name: name, description: description);

  @override
  final ToolSpec spec;

  @override
  Future<ToolResult> call(ToolInvocation invocation) =>
      // The inner tool is given its own name, so an implementation that reports
      // errors against `spec.name` stays self-consistent.
      inner.call(
        ToolInvocation(
          callId: invocation.callId,
          toolName: inner.spec.name,
          arguments: invocation.arguments,
          rawArguments: invocation.rawArguments,
          context: invocation.context,
        ),
      );
}
