/// A collection of tools, and the subsets an agent is given.
///
/// # Why subsets matter
///
/// A registry is the application's full catalogue: every tool the app can do.
/// An agent must never be handed all of it. Tool-selection accuracy falls
/// measurably as the catalogue grows — a model choosing between forty tools
/// picks wrong far more often than one choosing between eight — and every spec
/// is serialised into every request, so an unused tool costs tokens on every
/// single turn of every conversation.
///
/// [ToolRegistry] therefore has a large surface for *selecting*: by name, by
/// tag, by read-only. A `ToolSet` is what an agent actually receives.
library;

import 'package:agentic_core/agentic_core.dart';
import 'package:agentic_tools/src/tool.dart';
import 'package:meta/meta.dart';

/// The application's catalogue of tools.
///
/// ```dart
/// final registry = ToolRegistry()
///   ..register(searchTool)
///   ..register(readFileTool)
///   ..registerLazy(cameraSpec, () => CameraTool(controller));
///
/// final researchTools = registry.select(tags: {'research'});
/// ```
final class ToolRegistry implements Disposable {
  /// Creates an empty registry.
  ToolRegistry({Iterable<Tool> tools = const <Tool>[]}) {
    for (final tool in tools) {
      register(tool);
    }
  }

  final Registry<Tool> _registry = Registry<Tool>(kind: 'tool');
  final Map<String, ToolSpec> _specs = <String, ToolSpec>{};

  /// Every registered tool name, in registration order.
  Iterable<String> get names => _registry.keys;

  /// Number of registered tools.
  int get length => _registry.length;

  /// Whether nothing is registered.
  bool get isEmpty => _registry.isEmpty;

  /// Specifications of every registered tool.
  ///
  /// Available without constructing any lazily-registered implementation, which
  /// is the whole point of registering a spec alongside a factory.
  List<ToolSpec> get specs => List<ToolSpec>.unmodifiable(_specs.values);

  /// Registers [tool] under its own name.
  ///
  /// Throws a [ConfigurationException] on a duplicate name unless [replace] is
  /// set. Two packages registering `search` is a conflict the application must
  /// resolve — with `RenamedTool` — not something to paper over.
  void register(Tool tool, {bool replace = false}) {
    final spec = tool.spec;
    _registry.register(spec.name, tool, replace: replace);
    _specs[spec.name] = spec;
  }

  /// Registers every tool in [tools].
  void registerAll(Iterable<Tool> tools, {bool replace = false}) {
    for (final tool in tools) {
      register(tool, replace: replace);
    }
  }

  /// Registers a tool built on first use, with its [spec] known up front.
  ///
  /// The right registration for anything expensive to construct: a camera
  /// controller, a database connection, an HTTP client. The spec is available
  /// immediately for prompt assembly; the implementation is built only if the
  /// model actually calls it.
  void registerLazy(
    ToolSpec spec,
    Tool Function() create, {
    bool replace = false,
  }) {
    _registry.registerFactory(spec.name, create, replace: replace);
    _specs[spec.name] = spec;
  }

  /// Returns the tool registered as [name].
  ///
  /// Throws a [NotFoundException] naming the closest registered tool when the
  /// name is a near miss — which is exactly what a model's occasional
  /// misspelling produces.
  Tool resolve(String name) => _registry.resolve(name);

  /// Returns the tool registered as [name], or `null`.
  Tool? maybeResolve(String name) => _registry.maybeResolve(name);

  /// Returns the spec registered as [name], without constructing the tool.
  ToolSpec? specOf(String name) => _specs[name];

  /// Whether [name] is registered.
  bool contains(String name) => _registry.contains(name);

  /// Removes [name], returning whether anything was removed.
  bool unregister(String name) {
    _specs.remove(name);
    return _registry.unregister(name);
  }

  /// Selects a subset of this registry.
  ///
  /// Filters combine with AND. Omitting all of them selects everything, which
  /// is convenient for tests and rarely right in production.
  ///
  /// * [names] — an explicit allow-list.
  /// * [tags] — tools carrying **any** of these tags.
  /// * [excludeTags] — tools carrying **none** of these tags.
  /// * [readOnly] — when `true`, only tools that do not mutate state.
  /// * [where] — arbitrary predicate for anything the above cannot express.
  ToolSet select({
    Set<String>? names,
    Set<String>? tags,
    Set<String>? excludeTags,
    bool? readOnly,
    bool Function(ToolSpec spec)? where,
  }) {
    final selected = <String>[];
    for (final entry in _specs.entries) {
      final spec = entry.value;
      if (names != null && !names.contains(entry.key)) continue;
      if (tags != null && tags.intersection(spec.tags).isEmpty) continue;
      if (excludeTags != null &&
          excludeTags.intersection(spec.tags).isNotEmpty) {
        continue;
      }
      if (readOnly != null && spec.isReadOnly != readOnly) continue;
      if (where != null && !where(spec)) continue;
      selected.add(entry.key);
    }
    return ToolSet._(this, selected);
  }

  /// Every registered tool, as a set.
  ToolSet get all => ToolSet._(this, _specs.keys.toList());

  @override
  Future<void> dispose() async {
    _specs.clear();
    await _registry.dispose();
  }

  @override
  String toString() => 'ToolRegistry(${_specs.length} tools)';
}

/// An immutable selection of tools from a [ToolRegistry].
///
/// This is what an agent is configured with. It resolves lazily against its
/// registry, so a set can be built during prompt assembly without constructing
/// implementations that may never be called.
@immutable
final class ToolSet {
  ToolSet._(this._registry, List<String> names)
    : names = List<String>.unmodifiable(names);

  final ToolRegistry _registry;

  /// Names in this selection.
  final List<String> names;

  /// Number of tools in this selection.
  int get length => names.length;

  /// Whether the selection is empty.
  ///
  /// An empty set is meaningful: it tells a provider adapter to omit tool
  /// definitions entirely rather than send an empty array, which some providers
  /// reject.
  bool get isEmpty => names.isEmpty;

  /// Whether the selection contains anything.
  bool get isNotEmpty => names.isNotEmpty;

  /// Specifications of the selected tools.
  List<ToolSpec> get specs => <ToolSpec>[
    for (final name in names) ?_registry.specOf(name),
  ];

  /// The selected tools, constructing any lazy implementations.
  List<Tool> get tools => <Tool>[
    for (final name in names) _registry.resolve(name),
  ];

  /// Whether [name] is in this selection.
  bool contains(String name) => names.contains(name);

  /// The spec for [name], without constructing the implementation.
  ///
  /// Prompt assembly and executor dispatch both go through this rather than
  /// through [resolve], so a lazily-registered tool is built only if the model
  /// actually calls it — not merely because it was described to the model.
  ToolSpec? specOf(String name) =>
      contains(name) ? _registry.specOf(name) : null;

  /// Resolves [name] within this selection.
  ///
  /// Throws a [NotFoundException] if the tool exists in the registry but was
  /// not selected — a distinct failure from "no such tool", and one worth
  /// distinguishing, because it usually means an agent was given the wrong set
  /// rather than that the model hallucinated a name.
  Tool resolve(String name) {
    if (!contains(name)) {
      throw NotFoundException(
        _registry.contains(name)
            ? 'Tool `$name` exists but was not made available to this agent. '
                  'Available here: ${names.map((n) => '`$n`').join(', ')}.'
            : 'No tool named `$name`. '
                  'Available here: ${names.map((n) => '`$n`').join(', ')}.',
        resourceType: 'tool',
        identifier: name,
      );
    }
    return _registry.resolve(name);
  }

  /// Function definitions for a provider request.
  List<JsonMap> toFunctionJson() =>
      specs.map((spec) => spec.toFunctionJson()).toList();

  /// Returns a set with [other]'s tools added.
  ///
  /// Both sets must come from the same registry.
  ToolSet operator +(ToolSet other) {
    if (!identical(_registry, other._registry)) {
      throw ConfigurationException(
        'Cannot combine tool sets from different registries.',
        setting: 'ToolSet.+',
      );
    }
    return ToolSet._(_registry, <String>{...names, ...other.names}.toList());
  }

  /// Returns a set without the named tools.
  ToolSet without(Set<String> excluded) => ToolSet._(
    _registry,
    names.where((name) => !excluded.contains(name)).toList(),
  );

  @override
  String toString() => 'ToolSet(${names.join(', ')})';
}
