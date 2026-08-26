/// The agentic framework, ready to use in a Flutter app.
///
/// One import gives you every layer — core values, tools, models, agents,
/// memory, workflows, vectors, retrieval and MCP — plus the Flutter-specific
/// pieces that only make sense in an app: a runtime that lives as long as the
/// widget tree, cancellation tied to the app lifecycle, device capabilities as
/// tools, somewhere safe to keep a key, and widgets for chat, approval and
/// traces.
///
/// ```dart
/// import 'package:agentic_flutter/agentic_flutter.dart';
///
/// void main() {
///   final runtime = AgenticRuntime(
///     tools: ToolRegistry()..register(locationTool(read: readPosition)),
///     backgroundPolicy: BackgroundPolicy.cancelOnPause,
///   );
///
///   runApp(AgenticScope(runtime: runtime, child: const MyApp()));
/// }
/// ```
///
/// # Why an umbrella package
///
/// An application should not have to know that `AgentSession` lives in
/// `agentic_agents` and `MetadataFilter` in `agentic_vector`. A *plugin* should:
/// a package that adds one tool depends on `agentic_tools` and nothing else, and
/// stays small. Applications take the umbrella; extensions take the layer they
/// extend.
///
/// # What is deliberately not here
///
/// No plugin dependencies. Location, camera, secure storage and speech each
/// mean a platform dependency, permissions and an upgrade treadmill, and adding
/// them here would put all of that into every app that only calls a hosted
/// model. `platformTools` and `SecretStore` are ports over callbacks you
/// supply — a few lines in your app, and nothing in anybody else's build.
library;

// --- The framework -----------------------------------------------------------
export 'package:agentic_agents/agentic_agents.dart';
export 'package:agentic_core/agentic_core.dart';
export 'package:agentic_llm/agentic_llm.dart';
export 'package:agentic_mcp/agentic_mcp.dart';
export 'package:agentic_memory/agentic_memory.dart';
export 'package:agentic_rag/agentic_rag.dart';
export 'package:agentic_tools/agentic_tools.dart';
export 'package:agentic_vector/agentic_vector.dart';
export 'package:agentic_workflow/agentic_workflow.dart';

// --- Device capabilities -----------------------------------------------------
export 'src/platform/platform_tools.dart'
    show
        CapturedImage,
        DeviceLocation,
        askUserTool,
        cameraTool,
        isPermanentDenial,
        locationTool,
        permissionDenied,
        shareTool;
// --- Runtime -----------------------------------------------------------------
export 'src/runtime/agentic_runtime.dart' show AgenticRuntime;
export 'src/runtime/flutter_log_sink.dart' show FlutterLogSink;
export 'src/runtime/lifecycle.dart'
    show BackgroundPolicy, LifecycleCancellation, withLifecycleCancellation;
// --- Secrets -----------------------------------------------------------------
export 'src/security/secret_store.dart'
    show
        DartDefineSecretStore,
        InMemorySecretStore,
        LayeredSecretStore,
        SecretStore,
        SecretStoreOperations;
// --- Widgets -----------------------------------------------------------------
export 'src/widgets/agent_chat_controller.dart'
    show AgentChatController, ChatEntry;
export 'src/widgets/agent_chat_view.dart'
    show AgentChatView, ChatComposer, ChatEntryTile;
export 'src/widgets/agentic_scope.dart' show AgenticBuildContext, AgenticScope;
export 'src/widgets/tool_approval.dart'
    show
        ScriptedApprovals,
        ToolApprovalSheet,
        sheetApprovalHandler,
        showToolApprovalSheet;
export 'src/widgets/trace_inspector.dart'
    show EventRecorder, EventTile, TraceInspector;
