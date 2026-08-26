/// The data a workflow run carries between nodes.
///
/// # Why a state bag rather than wired ports
///
/// The obvious design connects each node's outputs to the next node's inputs
/// with typed edges. It validates beautifully and it is miserable to author:
/// adding one field to a node means rewiring every edge downstream of it, and a
/// visual editor for it needs a port-matching UI before it can draw a line.
///
/// This uses a shared, immutable map instead — but with declared access.
/// Every node states which keys it reads and which it writes, so the graph can
/// still be checked before it runs: a
/// node reading a key nothing upstream produces is caught at build time, not
/// three minutes into a run.
///
/// That recovers most of the validation for a fraction of the authoring cost.
///
/// # State must be JSON-encodable
///
/// A run has to survive the process that started it — a workflow paused on
/// human approval outlives the app being killed — and that means the state gets
/// serialised. Putting a `Uint8List`, a `Stream` or a live object in state
/// produces a snapshot that cannot be restored, and the failure appears only on
/// resume. `WorkflowState.assertSerialisable` exists to find it earlier.
library;

import 'dart:convert';

import 'package:agentic_core/agentic_core.dart';
import 'package:collection/collection.dart';
import 'package:meta/meta.dart';

/// An immutable snapshot of a run's data.
///
/// Every write produces a new instance, so a completed node's view of the state
/// is preserved for the trace rather than overwritten.
@immutable
final class WorkflowState {
  /// Creates a state from [values].
  WorkflowState([Map<String, Object?> values = const <String, Object?>{}])
    : _values = Map<String, Object?>.unmodifiable(values);

  /// Restores a state from JSON.
  factory WorkflowState.fromJson(JsonMap json) => WorkflowState(json);

  /// An empty state.
  static final WorkflowState empty = WorkflowState();

  final Map<String, Object?> _values;

  /// The values, unmodifiable.
  Map<String, Object?> get values => _values;

  /// Every key currently set.
  Iterable<String> get keys => _values.keys;

  /// Whether nothing is set.
  bool get isEmpty => _values.isEmpty;

  /// Whether [key] is set.
  bool contains(String key) => _values.containsKey(key);

  /// The value at [key], or `null`.
  Object? operator [](String key) => _values[key];

  /// The value at [key] as [T], or `null` when absent or of another type.
  T? get<T>(String key) {
    final value = _values[key];
    return value is T ? value : null;
  }

  /// The value at [key] as [T].
  ///
  /// Throws a [ValidationException] naming the key and both types. A node that
  /// reaches this has a bug in its declared reads, or an upstream
  /// node wrote the wrong shape — either way, the message needs to say which
  /// key, because a workflow with thirty nodes gives no other clue.
  T require<T>(String key) {
    if (!_values.containsKey(key)) {
      throw ValidationException(
        'The workflow state has no value for `$key`. Either no node writes it, '
        'or the node that does has not run yet.',
        violations: <String>['state.$key: missing'],
      );
    }
    final value = _values[key];
    if (value is T) return value;
    throw ValidationException(
      'The workflow state holds a ${value.runtimeType} at `$key`, but $T was '
      'expected.',
      violations: <String>['state.$key: expected $T, got ${value.runtimeType}'],
    );
  }

  /// The value at [key] as [T], or [orElse] when absent or of another type.
  T getOr<T>(String key, T orElse) => get<T>(key) ?? orElse;

  /// Returns a new state with [updates] applied.
  ///
  /// Existing keys are replaced. An empty [updates] returns this instance
  /// unchanged, which keeps a no-op node from churning allocations in a loop.
  WorkflowState write(Map<String, Object?> updates) {
    if (updates.isEmpty) return this;
    return WorkflowState(<String, Object?>{..._values, ...updates});
  }

  /// Returns a new state with [key] set to [value].
  WorkflowState set(String key, Object? value) =>
      write(<String, Object?>{key: value});

  /// Returns a new state without [keys].
  ///
  /// Used to drop large intermediate values once nothing downstream reads them,
  /// which matters because everything in state is serialised into every
  /// snapshot.
  WorkflowState remove(Set<String> keys) {
    if (keys.isEmpty) return this;
    final next = Map<String, Object?>.of(_values)
      ..removeWhere((key, _) => keys.contains(key));
    return WorkflowState(next);
  }

  /// Throws when the state cannot be serialised.
  ///
  /// Call it after a node writes if the workflow will ever be suspended. The
  /// alternative is discovering the problem on resume, hours later, with no
  /// indication of which node put the offending value there.
  void assertSerialisable() {
    try {
      jsonEncode(_values);
    } on Object catch (error) {
      final offender = _values.entries.firstWhereOrNull((entry) {
        try {
          jsonEncode(<String, Object?>{entry.key: entry.value});
          return false;
        } on Object {
          return true;
        }
      });
      throw ValidationException(
        offender == null
            ? 'The workflow state is not JSON-encodable, so this run could not '
                  'be suspended and resumed.'
            : 'The workflow state holds a ${offender.value.runtimeType} at '
                  '`${offender.key}`, which is not JSON-encodable. A suspended '
                  'run is serialised, so state must survive a round trip.',
        cause: error,
        violations: <String>[
          if (offender != null) 'state.${offender.key}: not JSON-encodable',
        ],
      );
    }
  }

  /// Serialises the state.
  JsonMap toJson() => Map<String, Object?>.of(_values);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is WorkflowState &&
          const DeepCollectionEquality().equals(_values, other._values);

  @override
  int get hashCode => const DeepCollectionEquality().hash(_values);

  @override
  String toString() => 'WorkflowState(${_values.keys.join(', ')})';
}
