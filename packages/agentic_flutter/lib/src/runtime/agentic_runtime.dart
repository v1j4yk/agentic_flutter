/// One object that owns a Flutter app's agentic services.
library;

import 'dart:async';

import 'package:agentic_core/agentic_core.dart';
import 'package:agentic_flutter/src/runtime/flutter_log_sink.dart';
import 'package:agentic_flutter/src/runtime/lifecycle.dart';
import 'package:agentic_tools/agentic_tools.dart';
import 'package:flutter/foundation.dart';

/// Everything an app needs to run agents, created once and disposed once.
///
/// # Why an app needs this and a server does not
///
/// On a server, a request handler builds a context, runs, and lets it go. A
/// Flutter app has no request: it has a widget tree that outlives many runs,
/// rebuilds constantly, and can be torn down at any moment. Something has to
/// own the event bus, the tool registry and the logger across all of that, and
/// dispose them exactly once.
///
/// That is what this is. It is deliberately not a service locator — nothing
/// looks it up globally. It is handed down the tree by `AgenticScope`, which
/// means a test can build a different one and a screen can be pointed at a fake
/// without touching global state.
///
/// ```dart
/// final runtime = AgenticRuntime(
///   tools: ToolRegistry()..register(myTool),
///   logLevel: LogLevel.debug,
/// );
///
/// runApp(AgenticScope(runtime: runtime, child: const MyApp()));
/// ```
///
/// # Contexts are per-run, not per-app
///
/// [context] is the root: it carries the services and nothing else. Each run
/// gets a child through [runContext], with its own name, its own cancellation
/// and — if you ask — its own deadline. Sharing one context across runs would
/// mean one cancelled run cancelling the others.
final class AgenticRuntime implements Disposable {
  /// Creates a runtime.
  ///
  /// Everything is optional and every default is inert: no logging above
  /// `info`, an event bus nobody is listening to, an empty registry. A runtime
  /// you never configure costs nothing and still works.
  AgenticRuntime({
    ToolRegistry? tools,
    EventBus? events,
    AgenticLogger? logger,
    Tracer? tracer,
    Clock clock = const SystemClock(),
    IdGenerator? ids,
    LogLevel logLevel = LogLevel.info,
    this.backgroundPolicy = BackgroundPolicy.cancelOnDetach,
    Map<String, Object?> metadata = const <String, Object?>{},
  }) : tools = tools ?? ToolRegistry(),
       events = events ?? BroadcastEventBus(),
       _ownsEvents = events == null,
       _ownsTools = tools == null {
    final resolvedIds = ids ?? Ulid();
    _context = AgenticContext.root(
      name: 'app',
      logger:
          logger ??
          StructuredLogger(
            level: logLevel,
            // Debug-only by default; see `FlutterLogSink`. A framework that
            // logs a user's prompts in release has leaked them.
            sink: const FlutterLogSink(),
            clock: clock,
          ),
      events: this.events,
      tracer: tracer,
      clock: clock,
      ids: resolvedIds,
      metadata: <String, Object?>{
        'platform': defaultTargetPlatform.name,
        'debug': kDebugMode,
        ...metadata,
      },
    );
  }

  /// The tools available to every agent in this app.
  final ToolRegistry tools;

  /// Where framework events are published.
  ///
  /// Listen to it for a live trace view, a cost meter, or an approval queue.
  final EventBus events;

  /// Default policy for runs started through [runContext].
  final BackgroundPolicy backgroundPolicy;

  final bool _ownsEvents;
  final bool _ownsTools;
  final List<LifecycleCancellation> _bindings = <LifecycleCancellation>[];
  late final AgenticContext _context;
  bool _disposed = false;

  /// The root context: services, no cancellation of its own.
  AgenticContext get context => _context;

  /// The logger, for an app that wants to write its own records.
  AgenticLogger get logger => _context.logger;

  /// The clock, injected so tests can control time.
  Clock get clock => _context.clock;

  /// Creates a context for one run, bound to the app's lifecycle.
  ///
  /// The returned record carries the context and the binding that must be
  /// released when the run ends. Prefer [run], which does that for you; use
  /// this when the run's lifetime is managed by something else, such as a
  /// stream a widget listens to.
  ({AgenticContext context, LifecycleCancellation binding}) runContext(
    String name, {
    BackgroundPolicy? policy,
    Duration? timeout,
    Map<String, Object?> metadata = const <String, Object?>{},
  }) {
    _throwIfDisposed();
    final source = CancellationTokenSource(clock: clock);
    final binding = LifecycleCancellation.attach(
      source,
      policy: policy ?? backgroundPolicy,
    );
    _bindings.add(binding);

    return (
      context: _context.child(
        name,
        cancellation: source.token,
        timeout: timeout,
        metadata: metadata,
      ),
      binding: binding,
    );
  }

  /// Runs [body] with a lifecycle-bound context, releasing it afterwards.
  ///
  /// ```dart
  /// final answer = await runtime.run(
  ///   'chat.turn',
  ///   (context) => agent.run(AgentInput.text(question), context: context),
  /// );
  /// ```
  Future<T> run<T>(
    String name,
    Future<T> Function(AgenticContext context) body, {
    BackgroundPolicy? policy,
    Duration? timeout,
    Map<String, Object?> metadata = const <String, Object?>{},
  }) async {
    final scope = runContext(
      name,
      policy: policy,
      timeout: timeout,
      metadata: metadata,
    );
    try {
      return await body(scope.context);
    } finally {
      scope.binding.detach();
      _bindings.remove(scope.binding);
    }
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;

    // Detached first: an observer left in `WidgetsBinding` outlives the runtime
    // and fires against disposed objects on the next lifecycle change.
    for (final binding in _bindings.toList()) {
      binding.detach();
    }
    _bindings.clear();

    // Only what this runtime created is torn down. A caller who passed in a bus
    // or a registry still owns it, and closing somebody else's dependency is
    // how a second runtime in the same test suite starts failing.
    if (_ownsTools) await tools.dispose();
    if (_ownsEvents) await events.dispose();
  }

  void _throwIfDisposed() {
    if (!_disposed) return;
    throw InvalidStateException(
      'This AgenticRuntime has been disposed.',
      currentState: 'disposed',
      expectedState: 'open',
    );
  }

  @override
  String toString() =>
      'AgenticRuntime(${tools.all.length} tool(s), '
      '${backgroundPolicy.name})';
}
