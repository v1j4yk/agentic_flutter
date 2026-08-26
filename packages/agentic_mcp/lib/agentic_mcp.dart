/// Model Context Protocol for the agentic framework.
///
/// Two directions, one vocabulary. `McpClient` turns a remote server's tools
/// into ordinary `Tool` objects that every agent in the framework already knows
/// how to run; `McpServer` publishes your own `ToolRegistry` to any MCP client.
///
/// ```dart
/// import 'package:agentic_mcp/agentic_mcp.dart';
///
/// final client = McpClient(
///   transport: McpHttpTransport(endpoint: Uri.parse('https://…/mcp')),
/// );
/// await client.initialize();
///
/// await registerMcpTools(client, registry, prefix: 'fs');
/// // The agent now has the server's tools, and knows nothing about MCP.
/// ```
///
/// The subprocess transport lives in `package:agentic_mcp/io.dart`, because it
/// imports `dart:io` and this library must stay usable on the web.
library;

// --- Client ------------------------------------------------------------------
export 'src/client/mcp_client.dart'
    show McpClient, McpPromptResult, McpRequestHandler, McpSessionInfo;
export 'src/client/mcp_tool.dart' show McpTool, mcpTools, registerMcpTools;
// --- Events ------------------------------------------------------------------
export 'src/events/mcp_events.dart'
    show
        McpEvent,
        McpNotificationReceived,
        McpSessionOpened,
        McpToolCalled,
        McpToolsDiscovered;
// --- Wire format -------------------------------------------------------------
export 'src/protocol/json_rpc.dart'
    show
        JsonRpcError,
        JsonRpcErrorCode,
        JsonRpcMessage,
        JsonRpcNotification,
        JsonRpcNotificationMessage,
        JsonRpcRequest,
        JsonRpcRequestMessage,
        JsonRpcResponse,
        JsonRpcResponseMessage,
        kJsonRpcVersion;
// --- Content translation -----------------------------------------------------
export 'src/protocol/mcp_content.dart'
    show
        contentPartFromMcp,
        contentPartToMcp,
        contentPartsFromMcp,
        contentPartsToMcp,
        renderMcpContent;
// --- Domain ------------------------------------------------------------------
export 'src/protocol/mcp_models.dart'
    show
        McpPrompt,
        McpPromptArgument,
        McpResource,
        McpResourceContents,
        McpResourceTemplate,
        McpToolAnnotations,
        McpToolCallResult,
        McpToolDescriptor;
// --- Protocol ----------------------------------------------------------------
export 'src/protocol/mcp_protocol.dart'
    show
        McpCapabilities,
        McpImplementation,
        McpMethod,
        kLatestProtocolVersion,
        kSupportedProtocolVersions,
        negotiateProtocolVersion;
// --- Server ------------------------------------------------------------------
export 'src/server/mcp_server.dart'
    show McpResourceProvider, McpResourceReader, McpServer;
// --- Transport ---------------------------------------------------------------
export 'src/transport/http_transport.dart'
    show
        McpHttpTransport,
        isSupportedProtocolVersion,
        kProtocolVersionHeader,
        kReservedHeaders,
        kSessionIdHeader;
export 'src/transport/mcp_transport.dart' show InMemoryTransport, McpTransport;
