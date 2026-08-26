/// Tool and function-calling layer of the agentic framework.
///
/// A tool is a capability an agent can invoke. This package defines what a tool
/// is, how a catalogue of them is kept, how a subset is handed to an agent, and
/// what happens between the model asking for a call and the tool's code
/// running: argument repair, schema validation, human approval, time budgets,
/// cancellation, tracing and events.
///
/// ```dart
/// import 'package:agentic_core/agentic_core.dart';
/// import 'package:agentic_tools/agentic_tools.dart';
///
/// final registry = ToolRegistry()
///   ..register(FunctionTool.text(
///     name: 'now',
///     description: 'Returns the current time in ISO-8601 UTC.',
///     handler: (i) async => i.context.clock.now().toIso8601String(),
///   ));
///
/// final executor = ToolExecutor(tools: registry.all);
/// final messages = await executor.executeAllAsMessages(
///   response.toolCalls,
///   context: context,
/// );
/// ```
///
/// Pure Dart: platform tools that need Flutter — camera, GPS, contacts — live
/// in their own packages and depend on this one, so a server or CLI can use the
/// tool system without pulling in a UI framework.
library;

export 'src/function_tool.dart'
    show DelegatingTool, FunctionTool, RenamedTool, ToolHandler;
export 'src/tool.dart'
    show Tool, ToolExample, ToolInvocation, ToolResult, ToolSpec;
export 'src/tool_events.dart'
    show
        ToolApprovalRequested,
        ToolCallCompleted,
        ToolCallStarted,
        ToolEvent,
        ToolFailureKind;
export 'src/tool_executor.dart'
    show ToolApprovalHandler, ToolApprovalRequest, ToolExecutor;
export 'src/tool_registry.dart' show ToolRegistry, ToolSet;
