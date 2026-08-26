/// Talking to an MCP server running as a subprocess.
///
/// # Why this is a separate entry point
///
/// It imports `dart:io`, which does not exist on the web. Keeping it out of the
/// package's main library means an application that only ever speaks HTTP still
/// compiles for the web, and a Flutter app that never spawns a subprocess never
/// pays for the possibility.
///
/// It is also not usable on iOS or Android, which do not let an application
/// spawn arbitrary processes. Stdio is for desktop and server; on mobile, MCP
/// means `McpHttpTransport`.
///
/// # Framing
///
/// Messages are newline-delimited JSON on the subprocess's stdin and stdout.
/// The server's **stderr is not part of the protocol** — it is where a
/// well-behaved server puts its own logging — so it is surfaced through
/// `stderrLines` rather than parsed. A server that writes a stray line to
/// stdout, which does happen, produces one unparsable message rather than
/// wedging the session, and the line is reported on `incoming` as an error.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agentic_core/agentic_core.dart';
import 'package:agentic_mcp/src/transport/mcp_transport.dart';

/// Runs an MCP server as a child process and speaks to it over stdio.
///
/// ```dart
/// final transport = await StdioTransport.spawn(
///   executable: 'npx',
///   arguments: ['-y', '@modelcontextprotocol/server-filesystem', '/data'],
/// );
/// ```
final class StdioTransport implements McpTransport {
  StdioTransport._(this._process, this.name);

  /// Connects to an already-running [process].
  ///
  /// For a supervisor that owns process lifetime itself.
  factory StdioTransport.attach(Process process, {String name = 'stdio'}) =>
      StdioTransport._(process, name);

  /// Starts [executable] and connects to it.
  ///
  /// [environment] is merged over the parent's unless
  /// [includeParentEnvironment] is false. Merging is the default because MCP
  /// servers routinely need `PATH`, and a server that cannot find its own
  /// runtime fails in a way that looks like a protocol problem.
  static Future<StdioTransport> spawn({
    required String executable,
    List<String> arguments = const <String>[],
    String? workingDirectory,
    Map<String, String> environment = const <String, String>{},
    bool includeParentEnvironment = true,
    String? name,
  }) async {
    final Process process;
    try {
      process = await Process.start(
        executable,
        arguments,
        workingDirectory: workingDirectory,
        environment: environment.isEmpty ? null : environment,
        includeParentEnvironment: includeParentEnvironment,
      );
    } on ProcessException catch (error, stackTrace) {
      throw ConfigurationException(
        'Could not start the MCP server `$executable`: ${error.message}. '
        'Check that it is installed and on PATH.',
        setting: 'executable',
        cause: error,
        causeStackTrace: stackTrace,
      );
    }
    return StdioTransport._(process, name ?? 'stdio:$executable');
  }

  final Process _process;

  @override
  final String name;

  final StreamController<JsonMap> _incoming =
      StreamController<JsonMap>.broadcast();
  final StreamController<String> _stderr = StreamController<String>.broadcast();

  StreamSubscription<String>? _stdoutSubscription;
  StreamSubscription<String>? _stderrSubscription;
  bool _started = false;
  bool _disposed = false;

  /// The child's process identifier.
  int get pid => _process.pid;

  /// Whatever the server wrote to stderr.
  ///
  /// Not an error channel: MCP servers use it for their own logs, precisely
  /// because stdout is reserved for the protocol. Route it into your logger and
  /// a misbehaving server becomes diagnosable instead of mysterious.
  Stream<String> get stderrLines => _stderr.stream;

  /// Completes with the child's exit code.
  Future<int> get exitCode => _process.exitCode;

  @override
  Stream<JsonMap> get incoming {
    _start();
    return _incoming.stream;
  }

  @override
  bool get isOpen => !_disposed;

  @override
  Future<void> send(JsonMap message) async {
    if (_disposed) {
      throw InvalidStateException(
        'The stdio transport `$name` has been disposed.',
        currentState: 'disposed',
        expectedState: 'open',
      );
    }
    _start();
    _process.stdin.writeln(jsonEncode(message));
    await _process.stdin.flush();
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;

    await _stdoutSubscription?.cancel();
    await _stderrSubscription?.cancel();
    await _incoming.close();
    await _stderr.close();

    // Closing stdin is how a well-behaved MCP server is asked to shut down; the
    // kill is the backstop for one that ignores it. Killing first would lose
    // any work the server was flushing.
    try {
      await _process.stdin.close();
    } on Object {
      // The pipe may already be gone; nothing to do about it during teardown.
    }
    unawaited(
      _process.exitCode
          .timeout(
            const Duration(seconds: 5),
            onTimeout: () {
              _process.kill();
              return -1;
            },
          )
          .catchError((_) => -1),
    );
  }

  void _start() {
    if (_started || _disposed) return;
    _started = true;

    _stdoutSubscription = _process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
          _onLine,
          onError: _incoming.addError,
          onDone: () {
            if (!_incoming.isClosed) unawaited(_incoming.close());
          },
        );

    _stderrSubscription = _process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
          if (!_stderr.isClosed) _stderr.add(line);
        });
  }

  void _onLine(String line) {
    if (line.trim().isEmpty || _incoming.isClosed) return;
    try {
      final decoded = jsonDecode(line);
      if (decoded is Map) {
        _incoming.add(decoded.cast<String, Object?>());
        return;
      }
      // Valid JSON, wrong shape — a bare number or string on stdout.
      _incoming.addError(
        SerializationException(
          'The MCP server `$name` wrote a ${decoded.runtimeType} to stdout, '
          'where only JSON-RPC objects belong.',
        ),
      );
    } on FormatException catch (error, stackTrace) {
      // Almost always a server logging to stdout instead of stderr. Reported
      // rather than swallowed, because it is the single most common reason an
      // otherwise-correct stdio server does not work.
      _incoming.addError(
        SerializationException(
          'The MCP server `$name` wrote a non-JSON line to stdout: '
          '${line.length > 200 ? '${line.substring(0, 200)}…' : line}. '
          'Servers must log to stderr; stdout carries the protocol.',
          cause: error,
          causeStackTrace: stackTrace,
        ),
        stackTrace,
      );
    }
  }

  @override
  String toString() => 'StdioTransport($name, pid: ${_process.pid})';
}
