/// Annotations that turn ordinary Dart functions into tools.
///
/// They do nothing at runtime. `agentic_tools_generator` reads them at build
/// time and writes the [FunctionTool] you would otherwise write by hand: the
/// JSON schema derived from the parameter list, the argument reading, and the
/// conversion of the return value into a [ToolResult].
///
/// ```dart
/// part 'order_tools.g.dart';
///
/// /// Looks up where an order is.
/// @ToolFunction(isReadOnly: true)
/// Future<String> orderStatus(
///   @ToolParam('The order number, such as 1042.') String order,
/// ) async => ...;
///
/// // Generated: `final FunctionTool orderStatusTool`.
/// ```
library;

import 'package:agentic_tools/src/function_tool.dart';
import 'package:agentic_tools/src/tool.dart';
import 'package:meta/meta_meta.dart';

/// Marks a function or method as a tool.
///
/// On a top-level function named `orderStatus` the generator writes
/// `final FunctionTool orderStatusTool`. On methods of a class it writes an
/// extension whose `agentTools` getter returns every annotated method as a
/// tool bound to the instance, so tools can use the repositories and clients
/// the instance holds.
@Target(<TargetKind>{TargetKind.function, TargetKind.method})
final class ToolFunction {
  /// Marks a tool.
  ///
  /// [isReadOnly] is required on purpose. It decides whether a person must
  /// approve the call after the agent has read untrusted content, and a
  /// default of "read-only" on a function that deletes something would
  /// silently remove that protection.
  const ToolFunction({
    required this.isReadOnly,
    this.name,
    this.description,
    this.isIdempotent,
    this.requiresApproval = false,
    this.returnsUntrustedContent = false,
    this.tags = const <String>{},
    this.timeout,
  });

  /// The name the model calls, such as `order_status`.
  ///
  /// Defaults to the function name in snake_case.
  final String? name;

  /// What the tool does, written for the model.
  ///
  /// Defaults to the function's documentation comment. One of the two is
  /// required: a model picks tools by their descriptions.
  final String? description;

  /// Whether the tool only reads. See [ToolSpec.isReadOnly].
  final bool isReadOnly;

  /// Whether repeating a call is harmless. Defaults to [isReadOnly].
  final bool? isIdempotent;

  /// Whether a person must approve every call. See
  /// [ToolSpec.requiresApproval].
  final bool requiresApproval;

  /// Whether the output contains text the application did not write. See
  /// [ToolSpec.returnsUntrustedContent].
  final bool returnsUntrustedContent;

  /// Labels for selecting tools. See [ToolSpec.tags].
  final Set<String> tags;

  /// How long a call may run. See [ToolSpec.timeout].
  final Duration? timeout;
}

/// Describes one parameter of a [ToolFunction] to the model.
///
/// Dart has no documentation comments on parameters, so this is where a
/// parameter's meaning, units and format go. A parameter without one is
/// still usable, but the model has only its name to go on.
@Target(<TargetKind>{TargetKind.parameter})
final class ToolParam {
  /// Describes a parameter.
  const ToolParam(this.description);

  /// What the parameter means, written for the model.
  final String description;
}
