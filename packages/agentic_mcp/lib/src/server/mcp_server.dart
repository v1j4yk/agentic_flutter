/// Publishing your own tools over MCP.
///
/// # Why a server belongs in this package
///
/// The obvious use of MCP is consuming somebody else's tools. The other
/// direction matters just as much: an application that has built real
/// capabilities — a device's camera, a company's ticket system, a codebase's
/// index — can offer them to any MCP client, editors and other agents included,
/// without exposing an HTTP API and a second authentication story.
///
/// Because the framework's `Tool` already carries a name, a description, a JSON
/// Schema and an execution contract, this is a translation rather than a new
/// abstraction: a `ToolRegistry` is very nearly an MCP server already.
library;

import 'dart:async';

import 'package:agentic_core/agentic_core.dart';
import 'package:agentic_mcp/src/protocol/json_rpc.dart';
import 'package:agentic_mcp/src/protocol/mcp_protocol.dart';
import 'package:agentic_mcp/src/transport/mcp_transport.dart';
import 'package:agentic_tools/agentic_tools.dart';
import 'package:meta/meta.dart';

/// Supplies the resources a server offers.
typedef McpResourceProvider =
    Future<List<JsonMap>> Function(AgenticContext context);

/// Reads one resource by URI, or returns `null` if it does not exist.
typedef McpResourceReader =
    Future<List<JsonMap>?> Function(String uri, AgenticContext context);

/// Serves a [ToolRegistry] over the Model Context Protocol.
///
/// ```dart
/// final server = McpServer(
///   transport: transport,
///   registry: registry,
///   serverInfo: const McpImplementation(name: 'my-app', version: '1.0.0'),
/// );
/// await server.start();
/// ```
///
/// # Approval does not travel
///
/// A tool whose spec sets `requiresApproval` is **not** published. Approval
/// means a person confirms the action, and there is no person on the other end
/// of a socket — publishing such a tool would turn a deliberate human gate into
/// a remote call anybody with the endpoint can make. Pass
/// `publishApprovalRequired: true` only when the client is known to enforce
/// consent itself.
/// **Experimental.** The client half is exercised against real servers nightly;
/// this half has been exercised against one client, which is this package's own.
/// Serving is where a protocol's ambiguities surface, and the shape here will
/// change as it meets implementations that read the specification differently.
@experimental
final class McpServer implements Disposable {
  /// Creates a server over [transport].
  McpServer({
    required this.transport,
    required this.registry,
    this.serverInfo = const McpImplementation(
      name: 'agentic-flutter',
      version: '0.1.0',
    ),
    this.context,
    this.instructions,
    this.resourceProvider,
    this.resourceReader,
    this.publishApprovalRequired = false,
    this.disposeTransport = true,
    ToolApprovalHandler? approvalHandler,
    Duration defaultTimeout = const Duration(seconds: 30),
  }) : _executor = ToolExecutor(
         tools: registry.all,
         approvalHandler: approvalHandler,
         defaultTimeout: defaultTimeout,
       );

  /// The channel to the client.
  final McpTransport transport;

  /// The tools to publish.
  final ToolRegistry registry;

  /// Who this server says it is.
  final McpImplementation serverInfo;

  /// Run context used for logging, events and tracing.
  final AgenticContext? context;

  /// Guidance sent to the client about how to use this server.
  final String? instructions;

  /// Lists the resources this server offers, when it offers any.
  final McpResourceProvider? resourceProvider;

  /// Reads one resource.
  final McpResourceReader? resourceReader;

  /// Whether tools requiring approval are published.
  final bool publishApprovalRequired;

  /// Whether [dispose] closes [transport].
  final bool disposeTransport;

  final ToolExecutor _executor;
  StreamSubscription<JsonMap>? _subscription;
  bool _initialized = false;
  bool _disposed = false;

  /// Whether a client has completed the handshake.
  bool get isInitialized => _initialized;

  /// The tools this server publishes.
  List<ToolSpec> get publishedTools => <ToolSpec>[
    for (final spec in registry.all.specs)
      if (publishApprovalRequired || !spec.requiresApproval) spec,
  ];

  /// Begins serving.
  Future<void> start() async {
    _throwIfDisposed();
    _subscription ??= transport.incoming.listen(
      (message) => unawaited(_onMessage(message)),
      onError: (Object error) => context?.logger.warn(
        'MCP server transport error',
        fields: <String, Object?>{'transport': transport.name},
        error: error is AgenticException ? error : null,
      ),
    );
  }

  /// Tells the client that the tool list changed.
  ///
  /// Send this after registering or removing a tool. A client that registered
  /// tools at start-up has no other way to learn, and will keep describing
  /// tools that no longer exist.
  Future<void> notifyToolsChanged() => _notify(McpMethod.toolListChanged);

  /// Tells the client that the resource list changed.
  Future<void> notifyResourcesChanged() =>
      _notify(McpMethod.resourceListChanged);

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _subscription?.cancel();
    if (disposeTransport) await transport.dispose();
  }

  // ---------------------------------------------------------------------------
  // Dispatch
  // ---------------------------------------------------------------------------

  Future<void> _onMessage(JsonMap raw) async {
    final JsonRpcMessage message;
    try {
      message = JsonRpcMessage.fromJson(raw);
    } on AgenticException {
      // Not a JSON-RPC message at all. There is no id to answer, so the only
      // thing to do is ignore it.
      return;
    }

    switch (message) {
      case JsonRpcRequestMessage(:final request):
        await _respond(request);
      case JsonRpcNotificationMessage(:final notification):
        if (notification.method == McpMethod.initialized) _initialized = true;
      case JsonRpcResponseMessage():
        // This server sends no requests, so any response is unsolicited.
        break;
    }
  }

  Future<void> _respond(JsonRpcRequest request) async {
    try {
      final result = await _dispatch(request);
      await transport.send(JsonRpcResponse.result(request.id, result).toJson());
    } on AgenticException catch (error) {
      await transport.send(
        JsonRpcResponse.failure(
          request.id,
          JsonRpcError(
            code: _codeFor(error),
            message: error.message,
            data: <String, Object?>{'code': error.code},
          ),
        ).toJson(),
      );
    } on Object catch (error) {
      // A tool is application code and may throw anything. The client is
      // waiting; an internal error is a better answer than silence.
      await transport.send(
        JsonRpcResponse.failure(
          request.id,
          JsonRpcError(
            code: JsonRpcErrorCode.internalError,
            message: '`${request.method}` failed: $error',
          ),
        ).toJson(),
      );
    }
  }

  Future<JsonMap> _dispatch(JsonRpcRequest request) async {
    final scope = context ?? AgenticContext.root(name: 'mcp.server');

    return switch (request.method) {
      McpMethod.initialize => _initialize(request),
      McpMethod.ping => const <String, Object?>{},
      McpMethod.toolsList => _listTools(),
      McpMethod.toolsCall => _callTool(request, scope),
      McpMethod.resourcesList => _listResources(scope),
      McpMethod.resourcesRead => _readResource(request, scope),
      _ => throw CapabilityNotSupportedException(
        'This server does not implement `${request.method}`.',
        capability: request.method,
        component: serverInfo.name,
      ),
    };
  }

  JsonMap _initialize(JsonRpcRequest request) {
    final requested =
        request.params?.optionalString('protocolVersion') ??
        kLatestProtocolVersion;
    // Answer with the client's revision when it is one we speak, and with our
    // own when it is not. That is what the specification asks for, and it lets
    // the client decide whether the difference is workable.
    final agreed = kSupportedProtocolVersions.contains(requested)
        ? requested
        : kLatestProtocolVersion;

    return pruneNulls(<String, Object?>{
      'protocolVersion': agreed,
      'capabilities': McpCapabilities(
        tools: true,
        toolListChanged: true,
        resources: resourceProvider != null || resourceReader != null,
        resourceListChanged: resourceProvider != null,
      ).toJson(),
      'serverInfo': serverInfo.toJson(),
      'instructions': instructions,
    });
  }

  JsonMap _listTools() => <String, Object?>{
    'tools': <Object?>[
      for (final spec in publishedTools)
        pruneNulls(<String, Object?>{
          'name': spec.name,
          'description': spec.description,
          'inputSchema': spec.parameters.toJson(),
          'outputSchema': spec.returns?.toJson(),
          'annotations': pruneNulls(<String, Object?>{
            'readOnlyHint': spec.isReadOnly,
            'idempotentHint': spec.isIdempotent,
            // Only claimed when it is safe to claim. A tool this server would
            // not publish without consent is not described as harmless.
            'destructiveHint': spec.isReadOnly ? false : null,
          }),
        }),
    ],
  };

  Future<JsonMap> _callTool(
    JsonRpcRequest request,
    AgenticContext scope,
  ) async {
    final params = request.params ?? const <String, Object?>{};
    final name = params.requireString('name');

    if (!publishApprovalRequired) {
      final spec = registry.specOf(name);
      if (spec != null && spec.requiresApproval) {
        // Not published, so not callable. Reported as "not found" rather than
        // "denied", because telling an untrusted caller which gated tools exist
        // is information they have no use for.
        throw NotFoundException(
          'This server does not offer a tool named `$name`.',
          identifier: name,
          resourceType: 'tool',
        );
      }
    }

    final result = await _executor.execute(
      ToolCallPart(
        id: scope.ids.prefixed('mcp'),
        name: name,
        arguments:
            params.optionalObject('arguments') ?? const <String, Object?>{},
      ),
      context: scope,
    );

    return pruneNulls(<String, Object?>{
      'content': <Object?>[
        <String, Object?>{'type': 'text', 'text': result.content},
      ],
      // A tool failure is reported in the result, not as a JSON-RPC error: the
      // protocol reserves errors for calls that did not happen, and a client's
      // model can only recover from a failure it is allowed to see.
      'isError': result.isError ? true : null,
      'structuredContent': result.data is Map
          ? (result.data! as Map).cast<String, Object?>()
          : null,
    });
  }

  Future<JsonMap> _listResources(AgenticContext scope) async {
    final provider = resourceProvider;
    if (provider == null) return <String, Object?>{'resources': <Object?>[]};
    return <String, Object?>{'resources': await provider(scope)};
  }

  Future<JsonMap> _readResource(
    JsonRpcRequest request,
    AgenticContext scope,
  ) async {
    final reader = resourceReader;
    final uri = (request.params ?? const <String, Object?>{}).requireString(
      'uri',
    );
    if (reader == null) {
      throw CapabilityNotSupportedException(
        'This server does not serve resources.',
        capability: 'resources',
        component: serverInfo.name,
      );
    }
    final contents = await reader(uri, scope);
    if (contents == null) {
      throw NotFoundException(
        'No resource at `$uri`.',
        identifier: uri,
        resourceType: 'resource',
      );
    }
    return <String, Object?>{'contents': contents};
  }

  Future<void> _notify(String method) async {
    if (_disposed || !_initialized) return;
    await transport.send(JsonRpcNotification(method: method).toJson());
  }

  static int _codeFor(AgenticException error) => switch (error) {
    CancelledException() => JsonRpcErrorCode.requestCancelled,
    ValidationException() => JsonRpcErrorCode.invalidParams,
    NotFoundException() ||
    CapabilityNotSupportedException() => JsonRpcErrorCode.methodNotFound,
    SerializationException() => JsonRpcErrorCode.parseError,
    _ => JsonRpcErrorCode.internalError,
  };

  void _throwIfDisposed() {
    if (!_disposed) return;
    throw InvalidStateException(
      'This McpServer has been disposed.',
      currentState: 'disposed',
      expectedState: 'open',
    );
  }

  @override
  String toString() =>
      'McpServer($serverInfo, ${publishedTools.length} tool(s))';
}
