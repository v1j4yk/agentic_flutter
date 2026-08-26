/// Streamable HTTP, the transport that works everywhere.
///
/// # How the transport works
///
/// One endpoint, and the client POSTs every JSON-RPC message to it. The server
/// answers in one of two shapes and the client must handle both:
///
/// * `application/json` — one response, and the exchange is over;
/// * `text/event-stream` — a stream of messages, which is how a server sends
///   progress notifications and its own requests while a call is in flight.
///
/// A session identifier arrives in the `Mcp-Session-Id` header of the
/// `initialize` response and must be echoed on every later request. Servers use
/// it to route to the right session; omitting it typically earns a 404 several
/// calls later, which is a confusing way to learn about a header.
///
/// # The listening channel
///
/// A server can also send messages when nothing is in flight — a tool list
/// changed, a resource was updated. That needs a channel the client opened and
/// left open, which is the `GET` with `Accept: text/event-stream`. Servers that
/// do not support it answer 405, and that is not an error: it means this server
/// only ever speaks when spoken to.
library;

import 'dart:async';
import 'dart:convert';

import 'package:agentic_core/agentic_core.dart';
import 'package:agentic_llm/agentic_llm.dart' show decodeServerSentEvents;
import 'package:agentic_llm/agentic_llm.dart' as llm show mapHttpFailure;
import 'package:agentic_mcp/src/protocol/mcp_protocol.dart';
import 'package:agentic_mcp/src/transport/mcp_transport.dart';
import 'package:http/http.dart' as http;

/// Header carrying the session identifier.
const String kSessionIdHeader = 'mcp-session-id';

/// Header carrying the negotiated protocol revision.
const String kProtocolVersionHeader = 'mcp-protocol-version';

/// Talks to an MCP server over Streamable HTTP.
///
/// ```dart
/// final transport = McpHttpTransport(
///   endpoint: Uri.parse('https://mcp.example.test/mcp'),
///   headers: {'authorization': 'Bearer $token'},
/// );
/// ```
final class McpHttpTransport implements McpTransport {
  /// Creates a transport pointed at [endpoint].
  ///
  /// [headers] are sent on every request and typically carry authentication;
  /// they are never logged. Pass a [client] to share a connection pool or to
  /// test without a server.
  McpHttpTransport({
    required this.endpoint,
    Map<String, String> headers = const <String, String>{},
    http.Client? client,
    this.name = 'http',
    this.timeout = const Duration(seconds: 60),
    this.listenForServerMessages = true,
  }) : _headers = Map<String, String>.unmodifiable(headers),
       _client = client ?? http.Client(),
       _ownsClient = client == null;

  /// The server's single endpoint.
  final Uri endpoint;

  @override
  final String name;

  /// Ceiling for one request.
  ///
  /// Applies to the whole exchange, streamed responses included, so it has to
  /// accommodate the slowest tool the server offers.
  final Duration timeout;

  /// Whether to open a listening channel for server-initiated messages.
  final bool listenForServerMessages;

  final Map<String, String> _headers;
  final http.Client _client;
  final bool _ownsClient;
  final StreamController<JsonMap> _incoming =
      StreamController<JsonMap>.broadcast();

  String? _sessionId;
  StreamSubscription<String>? _listener;
  bool _disposed = false;

  /// The session identifier the server assigned, once it has.
  String? get sessionId => _sessionId;

  /// The protocol revision echoed on every request.
  ///
  /// Set by the client once negotiation is done; from then on every request
  /// carries the header, which is what lets one endpoint serve several
  /// revisions at once.
  String? protocolVersion;

  @override
  Stream<JsonMap> get incoming => _incoming.stream;

  @override
  bool get isOpen => !_disposed;

  @override
  Future<void> send(JsonMap message) async {
    _throwIfDisposed();

    final request = http.Request('POST', endpoint)
      ..headers.addAll(_requestHeaders())
      ..headers['content-type'] = 'application/json'
      ..headers['accept'] = 'application/json, text/event-stream'
      ..body = jsonEncode(message);

    final response = await _client
        .send(request)
        .timeout(
          timeout,
          onTimeout: () => throw AgenticTimeoutException(
            'The MCP server at $endpoint did not answer within '
            '${timeout.inSeconds}s.',
            operation: 'mcp.post',
            timeout: timeout,
          ),
        );

    _captureSessionId(response.headers);

    if (response.statusCode >= 400) {
      final body = await response.stream.bytesToString();
      throw llm.mapHttpFailure(
        statusCode: response.statusCode,
        body: body,
        provider: 'mcp:$name',
        headers: response.headers,
      );
    }

    // 202 Accepted is the correct answer to a notification: nothing to read.
    if (response.statusCode == 202) {
      await response.stream.drain<void>();
      return;
    }

    final contentType = response.headers['content-type'] ?? '';
    if (contentType.contains('text/event-stream')) {
      // Deliberately not awaited: the stream carries the response *and* any
      // notifications the server sends while working, and the caller of `send`
      // is waiting on the correlated response, not on the stream ending.
      unawaited(_pumpEventStream(response.stream));
      return;
    }

    final body = await response.stream.bytesToString();
    if (body.trim().isEmpty) return;
    _emitDecoded(body);
  }

  /// Opens the listening channel, if the server supports one.
  ///
  /// Called by the client after initialisation. A 405 means the server does not
  /// offer one, which is a valid configuration and not a failure.
  Future<void> startListening() async {
    if (!listenForServerMessages || _disposed || _listener != null) return;

    final request = http.Request('GET', endpoint)
      ..headers.addAll(_requestHeaders())
      ..headers['accept'] = 'text/event-stream';

    final http.StreamedResponse response;
    try {
      response = await _client.send(request);
    } on Object {
      // A listening channel is an optimisation. Failing to open one must not
      // stop a session that works perfectly well request-by-request.
      return;
    }

    _captureSessionId(response.headers);
    if (response.statusCode == 405 || response.statusCode >= 400) {
      await response.stream.drain<void>();
      return;
    }

    _listener = decodeServerSentEvents(response.stream)
        .map((event) => event.data)
        .where((data) => data.isNotEmpty)
        .listen(
          _emitDecoded,
          onError: _incoming.addError,
          // The server closed the channel. The session is still usable over
          // POST, so this is not an error — just the end of unsolicited
          // messages.
          onDone: () => _listener = null,
        );
  }

  /// Ends the session on the server.
  ///
  /// Best-effort: a server that does not implement `DELETE` answers 405, and a
  /// session that has already expired answers 404. Neither is worth failing a
  /// teardown over.
  Future<void> terminateSession() async {
    final id = _sessionId;
    if (id == null || _disposed) return;
    try {
      await _client.delete(endpoint, headers: _requestHeaders());
    } on Object {
      // Teardown must not throw; the session is being abandoned either way.
    }
    _sessionId = null;
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    await _listener?.cancel();
    // Terminated before the disposal flag is set, so the DELETE actually goes
    // out: a session left open on the server holds resources until it expires.
    await terminateSession();
    _disposed = true;
    await _incoming.close();
    if (_ownsClient) _client.close();
  }

  Map<String, String> _requestHeaders() => <String, String>{
    ..._headers,
    kSessionIdHeader: ?_sessionId,
    kProtocolVersionHeader: ?protocolVersion,
  };

  void _captureSessionId(Map<String, String> headers) {
    final id = headers[kSessionIdHeader];
    if (id != null && id.isNotEmpty) _sessionId = id;
  }

  Future<void> _pumpEventStream(Stream<List<int>> bytes) async {
    try {
      await for (final event in decodeServerSentEvents(bytes)) {
        if (_disposed) return;
        if (event.data.isEmpty) continue;
        _emitDecoded(event.data);
      }
    } on Object catch (error, stackTrace) {
      if (!_incoming.isClosed) _incoming.addError(error, stackTrace);
    }
  }

  /// Decodes one payload and publishes it, tolerating a batch.
  ///
  /// JSON-RPC allows an array of messages in one payload. Handling it here
  /// rather than in the client keeps every layer above dealing in single
  /// messages.
  void _emitDecoded(String payload) {
    if (_incoming.isClosed) return;
    final Object? decoded;
    try {
      decoded = jsonDecode(payload);
    } on FormatException catch (error, stackTrace) {
      _incoming.addError(
        SerializationException(
          'The MCP server at $endpoint sent something that is not JSON: '
          '${payload.length > 200 ? '${payload.substring(0, 200)}…' : payload}',
          cause: error,
          causeStackTrace: stackTrace,
        ),
        stackTrace,
      );
      return;
    }

    if (decoded is Map) {
      _incoming.add(decoded.cast<String, Object?>());
      return;
    }
    if (decoded is List) {
      for (final item in decoded) {
        if (item is Map) _incoming.add(item.cast<String, Object?>());
      }
    }
  }

  void _throwIfDisposed() {
    if (!_disposed) return;
    throw InvalidStateException(
      'The MCP transport `$name` has been disposed.',
      currentState: 'disposed',
      expectedState: 'open',
    );
  }

  @override
  String toString() => 'McpHttpTransport($endpoint)';
}

/// The default `initialize` headers a client sends.
///
/// Exposed because an application that authenticates out-of-band still needs to
/// know which headers this package sets, so it does not overwrite them.
const Set<String> kReservedHeaders = <String>{
  'content-type',
  'accept',
  kSessionIdHeader,
  kProtocolVersionHeader,
};

/// Whether [version] is one this package can speak.
bool isSupportedProtocolVersion(String version) =>
    kSupportedProtocolVersions.contains(version);
