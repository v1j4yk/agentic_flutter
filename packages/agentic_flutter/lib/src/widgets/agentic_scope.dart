/// Handing the runtime down the widget tree.
library;

import 'dart:async';

import 'package:agentic_core/agentic_core.dart';
import 'package:agentic_flutter/src/runtime/agentic_runtime.dart';
import 'package:agentic_tools/agentic_tools.dart';
import 'package:flutter/widgets.dart';

/// Makes an [AgenticRuntime] available to the widgets below it.
///
/// # Why an inherited widget and not a singleton
///
/// A global runtime is one runtime. That is fine until a widget test wants a
/// fake one, a second screen wants a different tool set, or two tests in the
/// same suite run in sequence and the second inherits the first's disposed
/// event bus. Every one of those is a real problem people hit, and all three
/// disappear when the runtime is inherited rather than looked up.
///
/// ```dart
/// runApp(
///   AgenticScope(
///     runtime: AgenticRuntime(tools: registry),
///     child: const MyApp(),
///   ),
/// );
///
/// // Anywhere below:
/// final runtime = AgenticScope.of(context);
/// ```
class AgenticScope extends StatefulWidget {
  /// Provides [runtime] to [child].
  const AgenticScope({
    required this.runtime,
    required this.child,
    this.disposeRuntime = false,
    super.key,
  });

  /// The runtime to provide.
  final AgenticRuntime runtime;

  /// Whether this widget disposes the runtime when it leaves the tree.
  ///
  /// Off by default, and deliberately so. A runtime handed to `runApp` outlives
  /// the tree; one created for a single screen does not. Disposing something
  /// the caller still holds is the worse mistake, so the default is to leave it
  /// alone and let an explicit `true` say otherwise.
  final bool disposeRuntime;

  /// The subtree.
  final Widget child;

  /// The nearest runtime above [context].
  ///
  /// Throws a [ConfigurationException] naming the missing widget when there is
  /// none — which is more useful than the null dereference three frames later
  /// that the alternative produces.
  static AgenticRuntime of(BuildContext context) {
    final runtime = maybeOf(context);
    if (runtime != null) return runtime;
    throw ConfigurationException(
      'No AgenticScope above this widget. Wrap your app — or at least the '
      'screen that runs agents — in `AgenticScope(runtime: ..., child: ...)`.',
      setting: 'AgenticScope',
    );
  }

  /// The nearest runtime above [context], or `null`.
  static AgenticRuntime? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<_AgenticScopeMarker>()
      ?.runtime;

  @override
  State<AgenticScope> createState() => _AgenticScopeState();
}

class _AgenticScopeState extends State<AgenticScope> {
  @override
  void dispose() {
    if (widget.disposeRuntime) {
      // Not awaited: `dispose` is synchronous, and a runtime's teardown is
      // best-effort by design. Awaiting it here would mean either blocking a
      // frame or a `late` future nobody holds.
      unawaited(widget.runtime.dispose());
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      _AgenticScopeMarker(runtime: widget.runtime, child: widget.child);
}

class _AgenticScopeMarker extends InheritedWidget {
  const _AgenticScopeMarker({required this.runtime, required super.child});

  final AgenticRuntime runtime;

  @override
  bool updateShouldNotify(_AgenticScopeMarker oldWidget) =>
      !identical(runtime, oldWidget.runtime);
}

/// Reaching the framework from a [BuildContext].
extension AgenticBuildContext on BuildContext {
  /// The nearest [AgenticRuntime].
  AgenticRuntime get agentic => AgenticScope.of(this);

  /// The tools available here.
  ToolRegistry get agenticTools => AgenticScope.of(this).tools;

  /// The event bus, for a widget that wants to watch a run.
  EventBus get agenticEvents => AgenticScope.of(this).events;
}
