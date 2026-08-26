/// Watching what the framework is doing, from inside the app.
library;

import 'dart:async';

import 'package:agentic_core/agentic_core.dart';
import 'package:flutter/material.dart';

/// Collects framework events for display.
///
/// # Why this is bounded
///
/// A busy agent publishes hundreds of events a minute. An unbounded list of
/// them is a memory leak with a debug panel attached — and on a phone, the
/// thing that gets killed is the app the developer is trying to debug. So this
/// keeps the most recent [capacity] and drops the rest, which is what a
/// developer actually reads anyway.
///
/// ```dart
/// final recorder = EventRecorder(runtime.events)..start();
/// // ...
/// TraceInspector(recorder: recorder);
/// ```
final class EventRecorder extends ChangeNotifier {
  /// Records events from [bus].
  EventRecorder(
    this.bus, {
    this.capacity = 500,
    this.include = const <String>{},
  }) : assert(capacity > 0, 'capacity must be positive');

  /// Where events come from.
  final EventBus bus;

  /// How many events are kept.
  final int capacity;

  /// Type prefixes to keep, or empty for everything.
  ///
  /// `{'llm.', 'tool.'}` is the useful setting when a run is drowning in
  /// workflow node events.
  final Set<String> include;

  final List<AgenticEvent> _events = <AgenticEvent>[];
  StreamSubscription<AgenticEvent>? _subscription;
  int _dropped = 0;

  /// The events kept, oldest first.
  List<AgenticEvent> get events => List<AgenticEvent>.unmodifiable(_events);

  /// How many were discarded to stay within [capacity].
  ///
  /// Shown rather than hidden: a developer reading a trace needs to know they
  /// are looking at the tail of one, not the whole thing.
  int get dropped => _dropped;

  /// Whether recording is active.
  bool get isRecording => _subscription != null;

  /// Begins recording.
  void start() {
    if (_subscription != null) return;
    _subscription = bus.events.listen(_record);
    notifyListeners();
  }

  /// Stops recording, keeping what was collected.
  Future<void> stop() async {
    await _subscription?.cancel();
    _subscription = null;
    notifyListeners();
  }

  /// Discards everything collected.
  void clear() {
    _events.clear();
    _dropped = 0;
    notifyListeners();
  }

  /// Events whose type starts with [prefix].
  List<AgenticEvent> ofType(String prefix) => <AgenticEvent>[
    for (final event in _events)
      if (event.type.startsWith(prefix)) event,
  ];

  @override
  void dispose() {
    // The subscription is cancelled directly rather than through `stop()`,
    // which notifies. Notifying during disposal is an assertion failure in
    // debug and a listener callback into a dead widget in release.
    unawaited(_subscription?.cancel());
    _subscription = null;
    _events.clear();
    super.dispose();
  }

  void _record(AgenticEvent event) {
    if (include.isNotEmpty &&
        !include.any((prefix) => event.type.startsWith(prefix))) {
      return;
    }
    _events.add(event);
    if (_events.length > capacity) {
      _events.removeAt(0);
      _dropped++;
    }
    notifyListeners();
  }

  @override
  String toString() =>
      'EventRecorder(${_events.length}/$capacity'
      '${_dropped > 0 ? ', $_dropped dropped' : ''})';
}

/// A developer panel showing recorded events.
///
/// Meant for a debug drawer, not for users. It is the answer to "the agent gave
/// a strange answer and I need to know what it actually did" without attaching
/// a debugger or reading a log file off a device.
class TraceInspector extends StatelessWidget {
  /// Creates an inspector.
  const TraceInspector({required this.recorder, this.onEventTap, super.key});

  /// Where events come from.
  final EventRecorder recorder;

  /// Called when an event row is tapped.
  final void Function(AgenticEvent event)? onEventTap;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: recorder,
    builder: (context, _) {
      final theme = Theme.of(context);
      final events = recorder.events.reversed.toList(growable: false);

      return Column(
        children: <Widget>[
          ListTile(
            dense: true,
            title: Text(
              '${events.length} event(s)'
              '${recorder.dropped > 0 ? ', ${recorder.dropped} dropped' : ''}',
              style: theme.textTheme.labelLarge,
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                IconButton(
                  icon: Icon(
                    recorder.isRecording
                        ? Icons.pause
                        : Icons.fiber_manual_record,
                  ),
                  tooltip: recorder.isRecording ? 'Pause' : 'Record',
                  onPressed: () => recorder.isRecording
                      ? unawaited(recorder.stop())
                      : recorder.start(),
                ),
                IconButton(
                  icon: const Icon(Icons.delete_outline),
                  tooltip: 'Clear',
                  onPressed: recorder.clear,
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: events.isEmpty
                ? Center(
                    child: Text(
                      recorder.isRecording
                          ? 'Waiting for events…'
                          : 'Recording is paused.',
                      style: theme.textTheme.bodySmall,
                    ),
                  )
                // Newest first: a developer opening this panel is looking at
                // what just happened, not at what happened first.
                : ListView.separated(
                    itemCount: events.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (context, index) =>
                        EventTile(event: events[index], onTap: onEventTap),
                  ),
          ),
        ],
      );
    },
  );
}

/// One event row.
class EventTile extends StatelessWidget {
  /// Creates a row.
  const EventTile({required this.event, this.onTap, super.key});

  /// The event to render.
  final AgenticEvent event;

  /// Called when the row is tapped.
  final void Function(AgenticEvent event)? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final payload = event.toJson()
      ..remove('id')
      ..remove('type')
      ..remove('timestamp');

    return ListTile(
      dense: true,
      leading: Icon(
        iconFor(event.type),
        size: 18,
        color: colourFor(event.type, theme),
      ),
      title: Text(event.type, style: theme.textTheme.labelMedium),
      subtitle: Text(
        payload.entries.map((e) => '${e.key}=${e.value}').join('  '),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodySmall,
      ),
      trailing: Text(
        '${event.timestamp.hour.toString().padLeft(2, '0')}:'
        '${event.timestamp.minute.toString().padLeft(2, '0')}:'
        '${event.timestamp.second.toString().padLeft(2, '0')}',
        style: theme.textTheme.labelSmall,
      ),
      onTap: onTap == null ? null : () => onTap!(event),
    );
  }

  /// An icon for an event type.
  ///
  /// Matched by prefix so a package this widget has never heard of still gets
  /// a sensible icon rather than a blank.
  static IconData iconFor(String type) {
    if (type.startsWith('llm.')) return Icons.psychology_outlined;
    if (type.startsWith('tool.')) return Icons.build_outlined;
    if (type.startsWith('agent.')) return Icons.smart_toy_outlined;
    if (type.startsWith('memory.')) return Icons.bookmark_outline;
    if (type.startsWith('workflow.')) return Icons.account_tree_outlined;
    if (type.startsWith('vector.')) return Icons.scatter_plot_outlined;
    if (type.startsWith('rag.')) return Icons.menu_book_outlined;
    if (type.startsWith('mcp.')) return Icons.cable_outlined;
    return Icons.circle_outlined;
  }

  /// A colour for an event type, with failures standing out.
  static Color colourFor(String type, ThemeData theme) =>
      type.contains('failed') || type.contains('error')
      ? theme.colorScheme.error
      : theme.colorScheme.primary;
}
