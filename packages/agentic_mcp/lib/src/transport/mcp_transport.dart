/// Moving JSON-RPC messages between two peers.
///
/// # Why the port is this small
///
/// A transport does two things: deliver messages that arrive, and send messages
/// that leave. Everything else — correlating responses to requests, timing them
/// out, retrying, negotiating capabilities — is protocol work, and belongs
/// above this line where it can be written once instead of once per transport.
///
/// The three that matter in practice are a subprocess over stdio (desktop and
/// server), Streamable HTTP (everywhere, and the only option on mobile and the
/// web) and an in-process pipe (tests, and a server embedded in the same app).
library;

import 'dart:async';

import 'package:agentic_core/agentic_core.dart';

/// Carries JSON-RPC messages to and from a peer.
///
/// Implementations must:
///
/// * deliver every message on [incoming] as a decoded JSON object;
/// * close [incoming] when the peer goes away, so a client can tell the
///   difference between "quiet" and "gone";
/// * put a framing or connection failure on [incoming] as an error rather than
///   throwing it from [send], which nobody is awaiting;
/// * make [dispose] idempotent and safe to call from a `finally`.
abstract interface class McpTransport implements Disposable {
  /// A short name for logs and errors, such as `stdio` or `http`.
  String get name;

  /// Messages arriving from the peer.
  ///
  /// A broadcast stream: the client subscribes once, but a caller may want to
  /// watch traffic without stealing it.
  Stream<JsonMap> get incoming;

  /// Whether the transport is still usable.
  bool get isOpen;

  /// Sends [message] to the peer.
  ///
  /// Completes when the message has been handed to the underlying channel, not
  /// when the peer has acted on it.
  Future<void> send(JsonMap message);
}

/// A transport whose two halves are wired directly together.
///
/// Used by tests, and by an application that embeds an MCP server in the same
/// process — a plugin architecture where the "server" is a module rather than a
/// subprocess. It has no framing, no serialisation and no I/O, which makes it
/// the right way to test everything above the transport line.
///
/// ```dart
/// final (client, server) = InMemoryTransport.pair();
/// ```
final class InMemoryTransport implements McpTransport {
  InMemoryTransport._(this.name);

  /// Creates two transports connected to each other.
  ///
  /// What one sends, the other receives.
  static (InMemoryTransport client, InMemoryTransport server) pair({
    String clientName = 'in-memory:client',
    String serverName = 'in-memory:server',
  }) {
    final client = InMemoryTransport._(clientName);
    final server = InMemoryTransport._(serverName);
    client._peer = server;
    server._peer = client;
    return (client, server);
  }

  @override
  final String name;

  final StreamController<JsonMap> _controller =
      StreamController<JsonMap>.broadcast();
  InMemoryTransport? _peer;
  bool _disposed = false;

  @override
  Stream<JsonMap> get incoming => _controller.stream;

  @override
  bool get isOpen => !_disposed;

  @override
  Future<void> send(JsonMap message) async {
    _throwIfDisposed();
    final peer = _peer;
    if (peer == null || peer._disposed) {
      throw InvalidStateException(
        'The peer of `$name` has been disposed, so there is nobody to send to.',
        currentState: 'peer-disposed',
        expectedState: 'connected',
      );
    }
    // Delivered asynchronously, so that a handler which sends a reply cannot
    // re-enter its own caller's stack frame. Synchronous delivery here makes
    // an in-process server behave unlike every real one, which is exactly what
    // a test double must not do.
    scheduleMicrotask(() {
      if (!peer._controller.isClosed) peer._controller.add(message);
    });
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _controller.close();

    // The peer's stream is closed too. A real transport breaks at both ends —
    // a socket closes, a subprocess exits — and a client whose peer vanished
    // must learn that its in-flight calls will never be answered rather than
    // waiting out every timeout one by one.
    final peer = _peer;
    _peer = null;
    if (peer != null) await peer.dispose();
  }

  void _throwIfDisposed() {
    if (!_disposed) return;
    throw InvalidStateException(
      'The transport `$name` has been disposed.',
      currentState: 'disposed',
      expectedState: 'open',
    );
  }

  @override
  String toString() => 'InMemoryTransport($name)';
}
