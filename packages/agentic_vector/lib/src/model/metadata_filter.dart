/// Filtering vector search by metadata.
///
/// # Why filtering is not optional
///
/// Similarity alone answers "what is closest", which is almost never the whole
/// question. The real one is "what is closest **among this user's documents**",
/// or "among what was published this year", or "excluding archived records".
/// A store without metadata filtering forces the caller to over-fetch and
/// filter afterwards, which silently returns fewer results than asked for and
/// gets slower as the index grows.
///
/// # Why this hierarchy is sealed
///
/// Every backend adapter must translate every filter into its own language —
/// Qdrant's `must`/`should`, Pinecone's Mongo-ish operators, a SQL `WHERE`.
/// Sealing means adding a filter kind is a compile error in each adapter that
/// has not handled it, rather than a filter silently ignored and a query
/// silently returning the wrong rows.
library;

import 'package:agentic_core/agentic_core.dart';
import 'package:meta/meta.dart';

/// A predicate over a record's metadata.
///
/// ```dart
/// MetadataFilter.and([
///   MetadataFilter.equals('tenant', 'acme'),
///   MetadataFilter.greaterThan('year', 2024),
///   MetadataFilter.not(MetadataFilter.equals('status', 'archived')),
/// ]);
/// ```
@immutable
sealed class MetadataFilter {
  /// Const-constructible base for every filter.
  const MetadataFilter();

  /// Matches records whose [field] equals [value].
  const factory MetadataFilter.equals(String field, Object? value) =
      EqualsFilter;

  /// Matches records whose [field] does not equal [value].
  const factory MetadataFilter.notEquals(String field, Object? value) =
      NotEqualsFilter;

  /// Matches records whose [field] is one of [values].
  factory MetadataFilter.inValues(String field, Iterable<Object?> values) =
      InFilter;

  /// Matches records whose numeric [field] is greater than [value].
  ///
  /// Set [orEqual] for `>=`. A record whose field is absent or non-numeric
  /// never matches: a comparison against nothing is false, not an error, so one
  /// malformed record cannot fail a whole query.
  const factory MetadataFilter.greaterThan(
    String field,
    num value, {
    bool orEqual,
  }) = GreaterThanFilter;

  /// Matches records whose numeric [field] is less than [value].
  const factory MetadataFilter.lessThan(
    String field,
    num value, {
    bool orEqual,
  }) = LessThanFilter;

  /// Matches records that have [field] set to anything but `null`.
  const factory MetadataFilter.exists(String field) = ExistsFilter;

  /// Matches records satisfying every one of [filters].
  factory MetadataFilter.and(List<MetadataFilter> filters) = AndFilter;

  /// Matches records satisfying at least one of [filters].
  factory MetadataFilter.or(List<MetadataFilter> filters) = OrFilter;

  /// Matches records that do not satisfy [filter].
  const factory MetadataFilter.not(MetadataFilter filter) = NotFilter;

  /// Whether [metadata] satisfies this filter.
  ///
  /// Used by in-process stores and by tests. A remote adapter translates the
  /// filter instead of evaluating it, so that the database does the work.
  bool matches(JsonMap metadata);

  /// Serialises the filter.
  JsonMap toJson();
}

/// Matches an exact value.
@immutable
final class EqualsFilter extends MetadataFilter {
  /// Creates an equality filter.
  const EqualsFilter(this.field, this.value);

  /// Metadata key to test.
  final String field;

  /// Value to compare against.
  final Object? value;

  @override
  bool matches(JsonMap metadata) => metadata[field] == value;

  @override
  JsonMap toJson() => <String, Object?>{
    'op': 'eq',
    'field': field,
    'value': value,
  };

  @override
  String toString() => '$field == $value';
}

/// Matches anything but an exact value.
@immutable
final class NotEqualsFilter extends MetadataFilter {
  /// Creates an inequality filter.
  const NotEqualsFilter(this.field, this.value);

  /// Metadata key to test.
  final String field;

  /// Value to compare against.
  final Object? value;

  @override
  bool matches(JsonMap metadata) => metadata[field] != value;

  @override
  JsonMap toJson() => <String, Object?>{
    'op': 'ne',
    'field': field,
    'value': value,
  };

  @override
  String toString() => '$field != $value';
}

/// Matches membership of a set.
@immutable
final class InFilter extends MetadataFilter {
  /// Creates a membership filter.
  InFilter(this.field, Iterable<Object?> values)
    : values = List<Object?>.unmodifiable(values);

  /// Metadata key to test.
  final String field;

  /// Accepted values.
  final List<Object?> values;

  @override
  bool matches(JsonMap metadata) {
    final actual = metadata[field];
    // A list-valued field matches when any of its elements is accepted, which
    // is what makes tag filtering work without a separate operator.
    if (actual is List) return actual.any(values.contains);
    return values.contains(actual);
  }

  @override
  JsonMap toJson() => <String, Object?>{
    'op': 'in',
    'field': field,
    'values': values,
  };

  @override
  String toString() => '$field in $values';
}

/// Matches numbers above a bound.
@immutable
final class GreaterThanFilter extends MetadataFilter {
  /// Creates a lower-bound filter.
  const GreaterThanFilter(this.field, this.value, {this.orEqual = false});

  /// Metadata key to test.
  final String field;

  /// The bound.
  final num value;

  /// Whether the bound is inclusive.
  final bool orEqual;

  @override
  bool matches(JsonMap metadata) {
    final actual = metadata[field];
    if (actual is! num) return false;
    return orEqual ? actual >= value : actual > value;
  }

  @override
  JsonMap toJson() => <String, Object?>{
    'op': orEqual ? 'gte' : 'gt',
    'field': field,
    'value': value,
  };

  @override
  String toString() => '$field ${orEqual ? '>=' : '>'} $value';
}

/// Matches numbers below a bound.
@immutable
final class LessThanFilter extends MetadataFilter {
  /// Creates an upper-bound filter.
  const LessThanFilter(this.field, this.value, {this.orEqual = false});

  /// Metadata key to test.
  final String field;

  /// The bound.
  final num value;

  /// Whether the bound is inclusive.
  final bool orEqual;

  @override
  bool matches(JsonMap metadata) {
    final actual = metadata[field];
    if (actual is! num) return false;
    return orEqual ? actual <= value : actual < value;
  }

  @override
  JsonMap toJson() => <String, Object?>{
    'op': orEqual ? 'lte' : 'lt',
    'field': field,
    'value': value,
  };

  @override
  String toString() => '$field ${orEqual ? '<=' : '<'} $value';
}

/// Matches records where a field is present.
@immutable
final class ExistsFilter extends MetadataFilter {
  /// Creates a presence filter.
  const ExistsFilter(this.field);

  /// Metadata key that must be set.
  final String field;

  @override
  bool matches(JsonMap metadata) => metadata[field] != null;

  @override
  JsonMap toJson() => <String, Object?>{'op': 'exists', 'field': field};

  @override
  String toString() => 'exists($field)';
}

/// Matches records satisfying every child filter.
@immutable
final class AndFilter extends MetadataFilter {
  /// Creates a conjunction.
  AndFilter(List<MetadataFilter> filters)
    : filters = List<MetadataFilter>.unmodifiable(filters);

  /// The child filters.
  final List<MetadataFilter> filters;

  @override
  bool matches(JsonMap metadata) =>
      filters.every((filter) => filter.matches(metadata));

  @override
  JsonMap toJson() => <String, Object?>{
    'op': 'and',
    'filters': filters.map((filter) => filter.toJson()).toList(),
  };

  @override
  String toString() => '(${filters.join(' AND ')})';
}

/// Matches records satisfying at least one child filter.
@immutable
final class OrFilter extends MetadataFilter {
  /// Creates a disjunction.
  OrFilter(List<MetadataFilter> filters)
    : filters = List<MetadataFilter>.unmodifiable(filters);

  /// The child filters.
  final List<MetadataFilter> filters;

  @override
  bool matches(JsonMap metadata) =>
      filters.any((filter) => filter.matches(metadata));

  @override
  JsonMap toJson() => <String, Object?>{
    'op': 'or',
    'filters': filters.map((filter) => filter.toJson()).toList(),
  };

  @override
  String toString() => '(${filters.join(' OR ')})';
}

/// Matches records the child filter rejects.
@immutable
final class NotFilter extends MetadataFilter {
  /// Creates a negation.
  const NotFilter(this.filter);

  /// The negated filter.
  final MetadataFilter filter;

  @override
  bool matches(JsonMap metadata) => !filter.matches(metadata);

  @override
  JsonMap toJson() => <String, Object?>{'op': 'not', 'filter': filter.toJson()};

  @override
  String toString() => 'NOT $filter';
}
