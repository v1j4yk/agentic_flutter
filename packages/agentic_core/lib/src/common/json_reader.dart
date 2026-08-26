/// Checked read access to decoded JSON.
///
/// Every adapter in the framework — LLM providers, vector stores, tool
/// transports, persistence layers — speaks JSON at its boundary. Decoding that
/// JSON with `as` casts is the single largest source of runtime crashes in
/// provider integrations, because a provider is free to send `null`, to send a
/// number where a string was documented, or to omit a field entirely.
///
/// These accessors replace casts with total functions that either return a
/// well-typed value or throw a [SerializationException] naming the offending
/// field. `type 'Null' is not a subtype of type 'String'` becomes
/// ``Expected `model` to be String, got null``.
library;

import 'package:agentic_core/src/common/json_types.dart';
import 'package:agentic_core/src/error/agentic_exception.dart';

/// Checked field access for a [JsonMap].
///
/// ```dart
/// final json = {'model': 'gpt-4o', 'usage': {'total_tokens': 42}};
/// json.requireString('model');                             // 'gpt-4o'
/// json.optionalString('system_fingerprint');               // null
/// json.requireObject('usage').requireInt('total_tokens');  // 42
/// json.requireString('missing');   // throws SerializationException
/// ```
extension JsonMapReader on JsonMap {
  /// Reads a required [String] at [key].
  ///
  /// Throws a [SerializationException] if the key is absent, holds `null`, or
  /// holds a non-string.
  String requireString(String key) => _require<String>(key);

  /// Reads a [String] at [key], or `null` when the key is absent or `null`.
  ///
  /// A present-but-wrongly-typed value still throws: an absent optional field
  /// is normal, a field of the wrong type is a contract violation.
  String? optionalString(String key) => _optional<String>(key);

  /// Reads a [String] at [key], falling back to [orElse].
  String stringOr(String key, String orElse) =>
      _optional<String>(key) ?? orElse;

  /// Reads a required [int] at [key].
  ///
  /// A JSON number that decodes as [double] but has no fractional part is
  /// accepted, because several providers serialise token counts as `42.0`.
  int requireInt(String key) {
    final value = this[key];
    if (value is int) return value;
    if (value is double && value == value.roundToDouble()) return value.toInt();
    throw _typeError(key, 'int', value);
  }

  /// Reads an [int] at [key], or `null` when the key is absent or `null`.
  int? optionalInt(String key) => _isAbsentOrNull(key) ? null : requireInt(key);

  /// Reads an [int] at [key], falling back to [orElse].
  int intOr(String key, int orElse) => optionalInt(key) ?? orElse;

  /// Reads a required [double] at [key], widening integers.
  double requireDouble(String key) {
    final value = this[key];
    if (value is double) return value;
    if (value is int) return value.toDouble();
    throw _typeError(key, 'double', value);
  }

  /// Reads a [double] at [key], or `null` when the key is absent or `null`.
  double? optionalDouble(String key) =>
      _isAbsentOrNull(key) ? null : requireDouble(key);

  /// Reads a required [bool] at [key].
  bool requireBool(String key) => _require<bool>(key);

  /// Reads a [bool] at [key], or `null` when the key is absent or `null`.
  bool? optionalBool(String key) => _optional<bool>(key);

  /// Reads a [bool] at [key], falling back to [orElse].
  bool boolOr(String key, {required bool orElse}) =>
      _optional<bool>(key) ?? orElse;

  /// Reads a required nested object at [key].
  ///
  /// A `Map` with a looser static type is accepted and re-cast, because
  /// `jsonDecode` produces `Map<String, dynamic>` and some transports produce
  /// `Map<dynamic, dynamic>`.
  JsonMap requireObject(String key) {
    final value = this[key];
    if (value is JsonMap) return value;
    if (value is Map) return value.cast<String, Object?>();
    throw _typeError(key, 'object', value);
  }

  /// Reads a nested object at [key], or `null` when absent or `null`.
  JsonMap? optionalObject(String key) =>
      _isAbsentOrNull(key) ? null : requireObject(key);

  /// Reads a required array at [key].
  JsonList requireList(String key) {
    final value = this[key];
    if (value is JsonList) return value;
    if (value is List) return value.cast<Object?>();
    throw _typeError(key, 'array', value);
  }

  /// Reads an array at [key], returning an empty list when absent or `null`.
  ///
  /// Absent-means-empty is the right default for collections: it removes a null
  /// check from every call site, and no provider distinguishes "no tool calls"
  /// from "the `tool_calls` field was omitted".
  JsonList listOrEmpty(String key) =>
      _isAbsentOrNull(key) ? const <Object?>[] : requireList(key);

  /// Reads an array of strings at [key], empty when absent.
  List<String> stringListOrEmpty(String key) {
    final raw = listOrEmpty(key);
    if (raw.isEmpty) return const <String>[];
    final result = <String>[];
    for (var i = 0; i < raw.length; i++) {
      final element = raw[i];
      if (element is! String) {
        throw SerializationException(
          'Expected a string at `$key[$i]`, got ${_describe(element)}.',
          path: '$key[$i]',
        );
      }
      result.add(element);
    }
    return result;
  }

  /// Reads an array of objects at [key] and maps each element with [decode].
  ///
  /// Element indices appear in the error path, so a malformed third element
  /// reports `choices[2]` rather than a bare `choices`.
  List<T> decodeList<T>(String key, JsonDecode<T> decode) {
    final raw = listOrEmpty(key);
    if (raw.isEmpty) return <T>[];
    final result = <T>[];
    for (var i = 0; i < raw.length; i++) {
      final element = raw[i];
      if (element is! Map) {
        throw SerializationException(
          'Expected an object at `$key[$i]`, got ${_describe(element)}.',
          path: '$key[$i]',
        );
      }
      result.add(decode(element.cast<String, Object?>()));
    }
    return result;
  }

  /// Reads a required [DateTime] at [key], normalised to UTC.
  ///
  /// Accepts ISO-8601 strings and Unix epoch seconds, the two encodings used
  /// across the providers the framework ships with. Normalising to UTC keeps
  /// comparisons across adapters total.
  DateTime requireDateTime(String key) {
    final value = this[key];
    if (value is String) {
      final parsed = DateTime.tryParse(value);
      if (parsed != null) return parsed.toUtc();
    }
    if (value is int) {
      return DateTime.fromMillisecondsSinceEpoch(value * 1000, isUtc: true);
    }
    throw _typeError(key, 'an ISO-8601 string or epoch seconds', value);
  }

  /// Reads a [DateTime] at [key], or `null` when absent or `null`.
  DateTime? optionalDateTime(String key) =>
      _isAbsentOrNull(key) ? null : requireDateTime(key);

  /// Reads a required enum-like [String] at [key] and maps it through [values].
  ///
  /// [values] maps the wire representation to the domain value. Unknown wire
  /// values fall back to [orElse] when one is supplied, which is what allows
  /// the framework to tolerate a provider adding a new `finish_reason` without
  /// a breaking change on our side.
  T requireEnum<T>(String key, Map<String, T> values, {T? orElse}) {
    final raw = requireString(key);
    final mapped = values[raw];
    if (mapped != null) return mapped;
    if (orElse != null) return orElse;
    throw SerializationException(
      'Unknown value `$raw` for `$key`. '
      'Expected one of: ${values.keys.join(', ')}.',
      path: key,
    );
  }

  /// Reads an enum-like [String] at [key], or [orElse] when absent or unknown.
  T enumOr<T>(String key, Map<String, T> values, T orElse) =>
      _isAbsentOrNull(key) ? orElse : requireEnum(key, values, orElse: orElse);

  bool _isAbsentOrNull(String key) => !containsKey(key) || this[key] == null;

  T _require<T>(String key) {
    final value = this[key];
    if (value is T) return value;
    throw _typeError(key, _friendlyType(T), value);
  }

  T? _optional<T>(String key) {
    if (_isAbsentOrNull(key)) return null;
    final value = this[key];
    if (value is T) return value;
    throw _typeError(key, _friendlyType(T), value);
  }

  SerializationException _typeError(String key, String expected, Object? got) =>
      SerializationException(
        'Expected `$key` to be $expected, got ${_describe(got)}.',
        path: key,
      );
}

String _friendlyType(Type type) => type.toString();

String _describe(Object? value) {
  if (value == null) return 'null';
  final text = value.toString();
  final truncated = text.length > 60 ? '${text.substring(0, 57)}...' : text;
  return '${value.runtimeType} ($truncated)';
}
