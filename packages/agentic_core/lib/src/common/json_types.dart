/// JSON type aliases with no dependencies.
///
/// Kept in a leaf library so that the error hierarchy and the checked JSON
/// accessors can both depend on these names without forming an import cycle.
library;

/// A decoded JSON object.
///
/// Used pervasively instead of `Map<String, dynamic>`. The `Object?` value type
/// is deliberate: it keeps `strict-casts` and `avoid_dynamic_calls`
/// enforceable, so every field read has to go through a checked accessor
/// instead of an implicit `dynamic` call that fails at runtime.
typedef JsonMap = Map<String, Object?>;

/// A decoded JSON array.
typedef JsonList = List<Object?>;

/// Converts a domain object into its wire representation.
typedef JsonEncode<T> = JsonMap Function(T value);

/// Reconstructs a domain object from its wire representation.
typedef JsonDecode<T> = T Function(JsonMap json);

/// Returns a copy of [json] with every `null`-valued entry removed.
///
/// Named `pruneNulls` rather than `prune` because this reaches every
/// application through the umbrella package, and a bare `prune` in a shared
/// namespace collides with pruning a tree, a cache or a list.
///
/// Provider request bodies are built by naming every optional parameter and
/// then pruning the ones that were never set. Omitting a field is not the same
/// as sending an explicit `null`: several providers reject
/// `{"temperature": null}` outright while happily accepting a body that simply
/// has no `temperature` key.
///
/// ```dart
/// pruneNulls({'model': 'gpt-4o', 'temperature': null}); // {'model': 'gpt-4o'}
/// ```
JsonMap pruneNulls(JsonMap json) {
  final result = <String, Object?>{};
  for (final entry in json.entries) {
    if (entry.value != null) result[entry.key] = entry.value;
  }
  return result;
}
