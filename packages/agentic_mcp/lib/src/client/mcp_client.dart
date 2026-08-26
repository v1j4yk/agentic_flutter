/// The MCP client: a session with one server.
library;

import 'dart:async';

import 'package:agentic_core/agentic_core.dart';
import 'package:agentic_mcp/src/events/mcp_events.dart';
import 'package:agentic_mcp/src/protocol/json_rpc.dart';
import 'package:agentic_mcp/src/protocol/mcp_content.dart';
import 'package:agentic_mcp/src/protocol/mcp_models.dart';
import 'package:agentic_mcp/src/protocol/mcp_protocol.dart';
import 'package:agentic_mcp/src/transport/http_transport.dart';
import 'package:agentic_mcp/src/transport/mcp_transport.dart';
import 'package:meta/meta.dart';

/// What the server said when the session opened.
@immutable
final class McpSessionInfo {
  /// Records a negotiated session.
  const McpSessionInfo({
    required this.protocolVersion,
    required this.server,
    required this.capabilities,
    this.instructions,
  });

  /// The revision both sides agreed on.
  final String protocolVersion;

  /// Who the server says it is.
  final McpImplementation server;

  /// What it says it can do.
  final McpCapabilities capabilities;

  /// Guidance the server offers about how to use it.
  ///
  /// Worth putting in a system prompt when present: it is the server author's
  /// own description of how their tools are meant to be used together, which no
  /// individual tool description can convey.
  final String? instructions;

  /// Serialises the session description.
  JsonMap toJson() => pruneNulls(<String, Object?>{
    'protocolVersion': protocolVersion,
    'server': server.toJson(),
    'capabilities': capabilities.toJson(),
    'instructions': instructions,
  });

  @override
  String toString() => 'McpSessionInfo($server, $protocolVersion)';
}

/// Handles a request the *server* sent to the client.
///
/// Returns the result object, or throws to answer with an error. MCP is
/// bidirectional: a server may ask the client to run a model
/// (`sampling/createMessage`) or to say which directories it may touch
/// (`roots/list`).
typedef McpRequestHandler =
    Future<JsonMap> Function(JsonRpcRequest request, AgenticContext context);

/// A session with one MCP server.
///
/// # What this class owns
///
/// Lifecycle (`initialize`, then the `initialized` notification, then teardown),
/// correlating responses to requests, turning protocol errors into framework
/// exceptions, propagating cancellation in both directions, and routing
/// server-initiated requests to handlers.
///
/// What it deliberately does *not* own is how the tools it finds get used —
/// that is `mcpTools`, which turns them into ordinary `Tool` objects that every
/// agent in the framework already knows how to run.
///
/// ```dart
/// final client = McpClient(
///   transport: McpHttpTransport(endpoint: endpoint),
///   clientInfo: const McpImplementation(name: 'my-app', version: '1.0.0'),
/// );
///
/// await client.initialize();
/// registry.registerAll(await mcpTools(client));
/// ```
///
/// # Cancellation crosses the boundary
///
/// When a caller's [AgenticContext] is cancelled, the client sends
/// `notifications/cancelled` and stops waiting. That matters more over MCP than
/// within a process: the server is often a subprocess or a remote service doing
/// real work, and a client that walks away silently leaves it running.
final class McpClient implements Disposable {
  /// Creates a client over [transport].
  ///
  /// The client owns the transport and disposes it; pass
  /// `disposeTransport: false` when the transport is shared.
  McpClient({
    required this.transport,
    this.clientInfo = const McpImplementation(
      name: 'agentic-flutter',
      version: '0.1.0',
    ),
    McpCapabilities? capabilities,
    this.context,
    this.requestTimeout = const Duration(seconds: 60),
    this.disposeTransport = true,
    Map<String, McpRequestHandler> handlers =
        const <String, McpRequestHandler>{},
  }) : capabilities = capabilities ?? McpCapabilities(),
       _handlers = Map<String, McpRequestHandler>.of(handlers);

  /// The channel to the server.
  final McpTransport transport;

  /// Who this client says it is.
  final McpImplementation clientInfo;

  /// What this client offers the server.
  ///
  /// Declaring `sampling` without registering a handler for
  /// `sampling/createMessage` is the mistake worth avoiding: the server will
  /// ask, and every request will fail.
  final McpCapabilities capabilities;

  /// Run context used for logging, events and tracing.
  final AgenticContext? context;

  /// How long any single request may take.
  final Duration requestTimeout;

  /// Whether [dispose] closes [transport].
  final bool disposeTransport;

  final Map<String, McpRequestHandler> _handlers;
  final Map<Object, Completer<JsonRpcResponse>> _pending =
      <Object, Completer<JsonRpcResponse>>{};
  final StreamController<JsonRpcNotification> _notifications =
      StreamController<JsonRpcNotification>.broadcast();

  StreamSubscription<JsonMap>? _subscription;
  McpSessionInfo? _session;
  int _nextId = 1;
  bool _disposed = false;

  /// What the server reported when the session opened, or `null` before then.
  McpSessionInfo? get session => _session;

  /// Whether [initialize] has completed.
  bool get isInitialized => _session != null;

  /// Notifications the server sent.
  ///
  /// A tool list changing mid-session is the one most applications care about:
  /// `notifications/tools/list_changed` means the tools registered at start-up
  /// are stale.
  Stream<JsonRpcNotification> get notifications => _notifications.stream;

  /// Registers a handler for a request the server may send.
  ///
  /// ```dart
  /// client.handle(McpMethod.rootsList, (request, context) async =>
  ///     {'roots': [{'uri': 'file:///project', 'name': 'project'}]});
  /// ```
  void handle(String method, McpRequestHandler handler) {
    _handlers[method] = handler;
  }

  /// Opens the session.
  ///
  /// Sends `initialize`, checks the revision the server chose, and sends the
  /// `initialized` notification. Calling it twice is a no-op, so start-up code
  /// that is not sure whether initialisation already happened can just call it.
  Future<McpSessionInfo> initialize() async {
    _throwIfDisposed();
    final existing = _session;
    if (existing != null) return existing;

    _subscription ??= transport.incoming.listen(
      _onMessage,
      onError: _onTransportError,
      onDone: _onTransportClosed,
    );

    final result = await _request(McpMethod.initialize, <String, Object?>{
      'protocolVersion': kLatestProtocolVersion,
      'capabilities': capabilities.toJson(),
      'clientInfo': clientInfo.toJson(),
    });

    final serverVersion = result.stringOr(
      'protocolVersion',
      kLatestProtocolVersion,
    );
    final agreed = negotiateProtocolVersion(serverVersion);
    if (agreed == null) {
      throw CapabilityNotSupportedException(
        'The MCP server speaks protocol revision `$serverVersion`, and this '
        'client speaks ${kSupportedProtocolVersions.join(', ')}. Continuing '
        'would produce failures in whichever call first uses a changed field.',
        capability: 'protocolVersion:$serverVersion',
        component: transport.name,
      );
    }

    final info = McpSessionInfo(
      protocolVersion: agreed,
      server: McpImplementation.fromJson(
        result.optionalObject('serverInfo') ?? const <String, Object?>{},
      ),
      capabilities: McpCapabilities.fromJson(
        result.optionalObject('capabilities') ?? const <String, Object?>{},
      ),
      instructions: result.optionalString('instructions'),
    );
    _session = info;

    // The revision is echoed on every later HTTP request, which is what lets a
    // server host several revisions behind one endpoint.
    if (transport case final McpHttpTransport http) {
      http.protocolVersion = agreed;
    }

    await notify(McpMethod.initialized);
    if (transport case final McpHttpTransport http) {
      await http.startListening();
    }

    final scope = context;
    if (scope != null) {
      scope
        ..publish(
          McpSessionOpened(
            id: scope.ids.prefixed('evt'),
            timestamp: scope.clock.now(),
            server: info.server.name,
            transport: transport.name,
            protocolVersion: agreed,
            capabilities: info.capabilities.toJson().keys.toList(),
            runId: scope.runId,
            source: 'mcp:${info.server.name}',
          ),
        )
        ..logger.info(
          'MCP session open',
          fields: <String, Object?>{
            'server': info.server.toString(),
            'protocol': agreed,
            'transport': transport.name,
          },
        );
    }
    return info;
  }

  /// Sends a request and waits for its response.
  ///
  /// Throws the framework equivalent of any JSON-RPC error the server returns.
  Future<JsonMap> request(
    String method, {
    JsonMap? params,
    AgenticContext? context,
    Duration? timeout,
  }) async {
    _throwIfDisposed();
    if (!isInitialized && method != McpMethod.initialize) {
      throw InvalidStateException(
        'The MCP session is not open. Call `initialize()` before `$method`.',
        currentState: 'uninitialised',
        expectedState: 'initialised',
      );
    }
    return _request(method, params, context: context, timeout: timeout);
  }

  /// Sends a notification, which expects no answer.
  Future<void> notify(String method, {JsonMap? params}) async {
    _throwIfDisposed();
    await transport.send(
      JsonRpcNotification(method: method, params: params).toJson(),
    );
  }

  /// Checks that the server is alive.
  Future<void> ping({AgenticContext? context}) async {
    await request(McpMethod.ping, context: context);
  }

  /// Lists every tool the server offers, following pagination.
  ///
  /// Paging is followed to the end rather than exposed, because a caller who
  /// stops at the first page silently registers some of a server's tools and
  /// then cannot explain why the model never uses the others.
  Future<List<McpToolDescriptor>> listTools({AgenticContext? context}) async =>
      _listAll(
        method: McpMethod.toolsList,
        key: 'tools',
        capability: 'tools',
        available: (c) => c.tools,
        parse: McpToolDescriptor.fromJson,
        context: context,
      );

  /// Calls a tool.
  ///
  /// A tool that fails returns a result with [McpToolCallResult.isError] set —
  /// the protocol distinguishes "the tool ran and went wrong", which a model
  /// can recover from, from "the call did not happen", which it cannot.
  Future<McpToolCallResult> callTool(
    String name, {
    JsonMap arguments = const <String, Object?>{},
    AgenticContext? context,
    Duration? timeout,
  }) async {
    final result = await request(
      McpMethod.toolsCall,
      params: <String, Object?>{'name': name, 'arguments': arguments},
      context: context,
      timeout: timeout,
    );
    return McpToolCallResult.fromJson(result);
  }

  /// Lists readable resources.
  Future<List<McpResource>> listResources({AgenticContext? context}) async =>
      _listAll(
        method: McpMethod.resourcesList,
        key: 'resources',
        capability: 'resources',
        available: (c) => c.resources,
        parse: McpResource.fromJson,
        context: context,
      );

  /// Lists resource templates.
  Future<List<McpResourceTemplate>> listResourceTemplates({
    AgenticContext? context,
  }) async => _listAll(
    method: McpMethod.resourceTemplatesList,
    key: 'resourceTemplates',
    capability: 'resources',
    available: (c) => c.resources,
    parse: McpResourceTemplate.fromJson,
    context: context,
  );

  /// Reads the resource at [uri].
  Future<List<McpResourceContents>> readResource(
    String uri, {
    AgenticContext? context,
  }) async {
    _requireCapability('resources', (c) => c.resources);
    final result = await request(
      McpMethod.resourcesRead,
      params: <String, Object?>{'uri': uri},
      context: context,
    );
    return <McpResourceContents>[
      for (final entry in result.listOrEmpty('contents'))
        if (entry is Map)
          McpResourceContents.fromJson(entry.cast<String, Object?>()),
    ];
  }

  /// Asks to be notified when [uri] changes.
  Future<void> subscribeToResource(String uri) async {
    _requireCapability('resources.subscribe', (c) => c.resourceSubscribe);
    await request(
      McpMethod.resourcesSubscribe,
      params: <String, Object?>{'uri': uri},
    );
  }

  /// Cancels a resource subscription.
  Future<void> unsubscribeFromResource(String uri) async {
    await request(
      McpMethod.resourcesUnsubscribe,
      params: <String, Object?>{'uri': uri},
    );
  }

  /// Lists prompt templates.
  Future<List<McpPrompt>> listPrompts({AgenticContext? context}) async =>
      _listAll(
        method: McpMethod.promptsList,
        key: 'prompts',
        capability: 'prompts',
        available: (c) => c.prompts,
        parse: McpPrompt.fromJson,
        context: context,
      );

  /// Renders a prompt template into messages.
  Future<McpPromptResult> getPrompt(
    String name, {
    Map<String, String> arguments = const <String, String>{},
    AgenticContext? context,
  }) async {
    _requireCapability('prompts', (c) => c.prompts);
    final result = await request(
      McpMethod.promptsGet,
      params: <String, Object?>{'name': name, 'arguments': arguments},
      context: context,
    );
    return McpPromptResult.fromJson(result);
  }

  /// Sets the server's log verbosity.
  Future<void> setLogLevel(String level) async {
    _requireCapability('logging', (c) => c.logging);
    await request(
      McpMethod.loggingSetLevel,
      params: <String, Object?>{'level': level},
    );
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;

    // Everything still waiting is told the session ended, rather than being
    // left to time out one by one against a transport that is already gone.
    final abandoned = InvalidStateException(
      'The MCP client was disposed while this call was in flight.',
      currentState: 'disposed',
      expectedState: 'open',
    );
    for (final completer in _pending.values.toList()) {
      if (!completer.isCompleted) completer.completeError(abandoned);
    }
    _pending.clear();

    await _subscription?.cancel();
    await _notifications.close();
    if (disposeTransport) await transport.dispose();
  }

  // ---------------------------------------------------------------------------
  // Internals
  // ---------------------------------------------------------------------------

  Future<JsonMap> _request(
    String method,
    JsonMap? params, {
    AgenticContext? context,
    Duration? timeout,
  }) async {
    final scope = context ?? this.context;
    scope?.throwIfCancelled();

    final id = _nextId++;
    final completer = Completer<JsonRpcResponse>();
    _pending[id] = completer;
    // The call is registered before the send completes, so disposal or a dying
    // transport can error it while nothing is awaiting it yet — which Dart
    // would report as an unhandled error. `ignore` attaches a listener that
    // silences that; the `await` below still receives the error.
    completer.future.ignore();

    CancellationSubscription? subscription;
    final token = scope?.cancellation;
    if (token != null) {
      subscription = token.onCancelled(() {
        // Tell the server before giving up. It is frequently a subprocess or a
        // remote service doing real work, and abandoning it silently leaves
        // that work running and billed.
        unawaited(
          notify(
            McpMethod.cancelled,
            params: <String, Object?>{'requestId': id, 'reason': 'cancelled'},
          ).catchError((_) {}),
        );
        final pending = _pending.remove(id);
        if (pending != null && !pending.isCompleted) {
          pending.completeError(
            CancelledException(
              '`mcp.$method` was cancelled.',
              operation: 'mcp.$method',
            ),
          );
        }
      });
    }

    try {
      await transport.send(
        JsonRpcRequest(id: id, method: method, params: params).toJson(),
      );

      final response = await completer.future.timeout(
        timeout ?? requestTimeout,
        onTimeout: () {
          _pending.remove(id);
          throw AgenticTimeoutException(
            'The MCP server did not answer `$method` within '
            '${(timeout ?? requestTimeout).inSeconds}s.',
            operation: 'mcp.$method',
            timeout: timeout ?? requestTimeout,
          );
        },
      );

      final error = response.error;
      if (error != null) {
        throw error.toException(
          server: _session?.server.name ?? transport.name,
          method: method,
        );
      }
      return response.result ?? const <String, Object?>{};
    } finally {
      subscription?.call();
      _pending.remove(id);
    }
  }

  /// Follows `nextCursor` to the end of a paginated list.
  Future<List<T>> _listAll<T>({
    required String method,
    required String key,
    required String capability,
    required bool Function(McpCapabilities) available,
    required T Function(JsonMap) parse,
    AgenticContext? context,
  }) async {
    _requireCapability(capability, available);
    final items = <T>[];
    String? cursor;
    // A bound on paging, because a server that always returns the same cursor
    // would otherwise loop forever inside what looks like one call.
    for (var page = 0; page < 100; page++) {
      final result = await request(
        method,
        params: cursor == null ? null : <String, Object?>{'cursor': cursor},
        context: context,
      );
      for (final entry in result.listOrEmpty(key)) {
        if (entry is Map) items.add(parse(entry.cast<String, Object?>()));
      }
      cursor = result.optionalString('nextCursor');
      if (cursor == null) break;
    }
    return List<T>.unmodifiable(items);
  }

  void _requireCapability(
    String name,
    bool Function(McpCapabilities) available,
  ) {
    final info = _session;
    if (info == null) {
      throw InvalidStateException(
        'The MCP session is not open. Call `initialize()` first.',
        currentState: 'uninitialised',
        expectedState: 'initialised',
      );
    }
    if (available(info.capabilities)) return;
    throw CapabilityNotSupportedException(
      'The MCP server `${info.server.name}` does not offer `$name`. It offers '
      '${info.capabilities}.',
      capability: name,
      component: info.server.name,
    );
  }

  void _onMessage(JsonMap raw) {
    final JsonRpcMessage message;
    try {
      message = JsonRpcMessage.fromJson(raw);
    } on AgenticException catch (error) {
      context?.logger.warn(
        'Discarding an unreadable MCP message',
        fields: <String, Object?>{'transport': transport.name},
        error: error,
      );
      return;
    }

    switch (message) {
      case JsonRpcResponseMessage(:final response):
        final id = response.id;
        final completer = id == null ? null : _pending.remove(id);
        if (completer == null || completer.isCompleted) {
          // A response to a request that timed out, was cancelled, or was never
          // made. Dropping it is correct; logging it is how a duplicate-id bug
          // in a server ever gets noticed.
          context?.logger.debug(
            'Unmatched MCP response',
            fields: <String, Object?>{'id': id},
          );
          return;
        }
        completer.complete(response);

      case JsonRpcNotificationMessage(:final notification):
        if (!_notifications.isClosed) _notifications.add(notification);
        _publishNotification(notification);

      case JsonRpcRequestMessage(:final request):
        unawaited(_handleServerRequest(request));
    }
  }

  Future<void> _handleServerRequest(JsonRpcRequest request) async {
    final handler = _handlers[request.method];
    final scope = context ?? AgenticContext.root(name: 'mcp.server-request');

    if (handler == null) {
      await transport.send(
        JsonRpcResponse.failure(
          request.id,
          JsonRpcError(
            code: JsonRpcErrorCode.methodNotFound,
            message:
                'This client does not handle `${request.method}`. Register a '
                'handler with `client.handle()` if the server needs it.',
          ),
        ).toJson(),
      );
      return;
    }

    try {
      final result = await handler(request, scope);
      await transport.send(JsonRpcResponse.result(request.id, result).toJson());
    } on AgenticException catch (error) {
      await transport.send(
        JsonRpcResponse.failure(
          request.id,
          JsonRpcError(
            code: error is CancelledException
                ? JsonRpcErrorCode.requestCancelled
                : JsonRpcErrorCode.internalError,
            message: error.message,
            data: <String, Object?>{'code': error.code},
          ),
        ).toJson(),
      );
    } on Object catch (error) {
      // A handler is application code and may throw anything. The server is
      // waiting for an answer either way, and leaving it waiting is worse than
      // any error we could send.
      await transport.send(
        JsonRpcResponse.failure(
          request.id,
          JsonRpcError(
            code: JsonRpcErrorCode.internalError,
            message:
                'The client handler for `${request.method}` failed: '
                '$error',
          ),
        ).toJson(),
      );
    }
  }

  void _publishNotification(JsonRpcNotification notification) {
    final scope = context;
    if (scope == null) return;
    scope.publish(
      McpNotificationReceived(
        id: scope.ids.prefixed('evt'),
        timestamp: scope.clock.now(),
        server: _session?.server.name ?? transport.name,
        method: notification.method,
        runId: scope.runId,
        source: 'mcp:${_session?.server.name ?? transport.name}',
      ),
    );
  }

  void _onTransportError(Object error, StackTrace stackTrace) {
    context?.logger.warn(
      'MCP transport error',
      fields: <String, Object?>{'transport': transport.name},
      error: error is AgenticException ? error : null,
    );
    for (final completer in _pending.values.toList()) {
      if (!completer.isCompleted) completer.completeError(error, stackTrace);
    }
    _pending.clear();
  }

  void _onTransportClosed() {
    if (_pending.isEmpty) return;
    final closed = ProviderException(
      'The MCP server closed the connection while ${_pending.length} call(s) '
      'were in flight.',
      provider: _session?.server.name ?? transport.name,
      retryable: true,
    );
    for (final completer in _pending.values.toList()) {
      if (!completer.isCompleted) completer.completeError(closed);
    }
    _pending.clear();
  }

  void _throwIfDisposed() {
    if (!_disposed) return;
    throw InvalidStateException(
      'This McpClient has been disposed.',
      currentState: 'disposed',
      expectedState: 'open',
    );
  }

  @override
  String toString() =>
      'McpClient(${_session?.server.name ?? 'not initialised'}, '
      '${transport.name})';
}

/// A rendered prompt template.
@immutable
final class McpPromptResult {
  /// Creates a rendered prompt.
  McpPromptResult({
    List<Message> messages = const <Message>[],
    this.description,
  }) : messages = List<Message>.unmodifiable(messages);

  /// Reads a rendered prompt.
  factory McpPromptResult.fromJson(JsonMap json) => McpPromptResult(
    description: json.optionalString('description'),
    messages: <Message>[
      for (final entry in json.listOrEmpty('messages'))
        if (entry is Map) _messageFrom(entry.cast<String, Object?>()),
    ],
  );

  /// What the prompt is for.
  final String? description;

  /// The messages, ready to prepend to a conversation.
  final List<Message> messages;

  /// Serialises the result.
  JsonMap toJson() => pruneNulls(<String, Object?>{
    'description': description,
    'messages': messages.map((m) => m.toJson()).toList(),
  });

  static Message _messageFrom(JsonMap json) {
    final role = json.stringOr('role', 'user');
    final content = json['content'];
    // A prompt message carries one content block, not a list — the one place
    // MCP's shape differs from its tool results.
    final parts = content is List
        ? contentPartsFromMcp(content)
        : content is Map
        ? <ContentPart>[?contentPartFromMcp(content.cast<String, Object?>())]
        : const <ContentPart>[];

    return Message(
      role: role == 'assistant' ? MessageRole.assistant : MessageRole.user,
      parts: parts,
    );
  }

  @override
  String toString() => 'McpPromptResult(${messages.length} message(s))';
}
