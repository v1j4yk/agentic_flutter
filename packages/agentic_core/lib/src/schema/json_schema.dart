/// An immutable, validating subset of JSON Schema.
///
/// Schemas are the contract language of the whole framework. A tool declares
/// its parameters as a schema, a structured-output request declares its result
/// shape as a schema, a workflow node declares its inputs as a schema. That one
/// object is then used for three different jobs:
///
/// 1. **Describing** the contract to a model, as the `parameters` of a function
///    definition;
/// 2. **Validating** what the model sent back, before a single line of tool
///    code runs;
/// 3. **Repairing** near-misses, because models are probabilistic and will send
///    `"5"` where `5` was asked for.
///
/// # Why not a JSON Schema package
///
/// The published Dart validators target the full specification: `$ref`,
/// `$dynamicAnchor`, remote schema resolution, the vocabulary system. None of
/// that reaches an LLM, because no provider accepts it — OpenAI, Anthropic and
/// Google each support a small, overlapping subset. Depending on a full
/// validator would add weight and a network-fetching code path to every mobile
/// app using the framework, in exchange for features that cannot be used.
///
/// This implementation covers exactly the subset the providers accept, is a
/// pure value object, and adds the one thing a general validator cannot: type
/// coercion tuned for the mistakes language models actually make.
///
/// ```dart
/// final schema = JsonSchema.object(
///   description: 'Search the web',
///   properties: {
///     'query': JsonSchema.string(description: 'What to search for'),
///     'limit': JsonSchema.integer(minimum: 1, maximum: 50, defaultValue: 10),
///   },
///   required: {'query'},
/// );
///
/// schema.validate({'query': 'dart 3'});     // valid
/// schema.validate({'limit': 5});            // missing required `query`
/// schema.coerce({'query': 'x', 'limit': '5'}); // {'query': 'x', 'limit': 5}
/// ```
library;

import 'package:agentic_core/src/common/json_types.dart';
import 'package:agentic_core/src/error/agentic_exception.dart';
import 'package:collection/collection.dart';
import 'package:meta/meta.dart';

/// The JSON Schema primitive types the framework supports.
enum JsonSchemaType {
  /// A JSON object with named properties.
  object('object'),

  /// A JSON array.
  array('array'),

  /// A JSON string.
  string('string'),

  /// A JSON number, integral or fractional.
  number('number'),

  /// A JSON number with no fractional part.
  integer('integer'),

  /// A JSON boolean.
  boolean('boolean'),

  /// JSON `null`.
  nullValue('null');

  const JsonSchemaType(this.wireName);

  /// The value used in the `type` keyword.
  final String wireName;

  /// Parses a `type` keyword value.
  static JsonSchemaType? fromWire(String value) =>
      JsonSchemaType.values.firstWhereOrNull((t) => t.wireName == value);
}

/// One reason a value failed validation.
@immutable
final class SchemaViolation {
  /// Creates a violation.
  const SchemaViolation({
    required this.path,
    required this.message,
    required this.keyword,
  });

  /// JSON pointer to the offending value, such as `/filters/0/field`.
  ///
  /// The root is the empty string, matching RFC 6901.
  final String path;

  /// Human-readable description, phrased so it can be handed straight back to
  /// a model as a repair instruction.
  final String message;

  /// The schema keyword that rejected the value, such as `required` or `type`.
  final String keyword;

  /// Serialises the violation.
  JsonMap toJson() => <String, Object?>{
    'path': path,
    'message': message,
    'keyword': keyword,
  };

  @override
  String toString() => path.isEmpty ? message : '$path: $message';
}

/// The outcome of validating a value against a schema.
@immutable
final class SchemaValidationResult {
  /// Creates a result.
  SchemaValidationResult(List<SchemaViolation> violations)
    : violations = List<SchemaViolation>.unmodifiable(violations);

  /// A result with no violations.
  static final SchemaValidationResult valid = SchemaValidationResult(
    const <SchemaViolation>[],
  );

  /// Everything that was wrong with the value.
  ///
  /// All violations are reported, not just the first. When the "caller" is a
  /// language model repairing its own output, one round trip listing four
  /// problems is worth four round trips listing one each.
  final List<SchemaViolation> violations;

  /// Whether the value satisfied the schema.
  bool get isValid => violations.isEmpty;

  /// Throws a [ValidationException] if the value was invalid.
  ///
  /// [subject] names what was being validated, such as
  /// `arguments for tool web_search`.
  void throwIfInvalid({String subject = 'value'}) {
    if (isValid) return;
    throw ValidationException(
      '$subject failed schema validation with '
      '${violations.length} violation(s).',
      violations: violations.map((v) => v.toString()).toList(),
    );
  }

  @override
  String toString() => isValid
      ? 'SchemaValidationResult(valid)'
      : 'SchemaValidationResult(${violations.length} violation(s): '
            '${violations.join('; ')})';
}

/// An immutable JSON Schema node.
///
/// Build one with the named constructors rather than by parsing JSON: the
/// constructors are type-safe, self-documenting and produce schemas every
/// supported provider accepts.
@immutable
final class JsonSchema {
  const JsonSchema._({
    this.type,
    this.description,
    this.properties = const <String, JsonSchema>{},
    this.requiredProperties = const <String>{},
    this.items,
    this.enumValues,
    this.format,
    this.pattern,
    this.minimum,
    this.maximum,
    this.exclusiveMinimum,
    this.exclusiveMaximum,
    this.multipleOf,
    this.minLength,
    this.maxLength,
    this.minItems,
    this.maxItems,
    this.uniqueItems = false,
    this.additionalProperties = true,
    this.defaultValue,
    this.anyOf = const <JsonSchema>[],
    this.nullable = false,
    this.title,
    this.examples = const <Object?>[],
  });

  /// A schema that accepts anything.
  ///
  /// Use sparingly: an untyped parameter gives the model no guidance and is the
  /// most common cause of malformed tool calls.
  factory JsonSchema.any({String? description}) =>
      JsonSchema._(description: description);

  /// An object with named [properties].
  ///
  /// [additionalProperties] defaults to `false`, the opposite of the JSON
  /// Schema default. That is deliberate: an open object invites a model to
  /// invent parameters, and a rejected extra key is a far better outcome than
  /// a silently ignored one.
  factory JsonSchema.object({
    Map<String, JsonSchema> properties = const <String, JsonSchema>{},
    Set<String> required = const <String>{},
    bool additionalProperties = false,
    String? description,
    String? title,
  }) {
    final unknown = required.difference(properties.keys.toSet());
    if (unknown.isNotEmpty) {
      throw ConfigurationException(
        'Schema marks ${unknown.map((k) => '`$k`').join(', ')} as required, '
        'but no such propert${unknown.length == 1 ? 'y is' : 'ies are'} '
        'declared. Required keys must exist, or the model is being asked for '
        'something it has no way to supply.',
        setting: 'JsonSchema.object.required',
      );
    }
    return JsonSchema._(
      type: JsonSchemaType.object,
      properties: Map<String, JsonSchema>.unmodifiable(properties),
      requiredProperties: Set<String>.unmodifiable(required),
      additionalProperties: additionalProperties,
      description: description,
      title: title,
    );
  }

  /// An object of any shape.
  ///
  /// Distinct from `JsonSchema.object()` with no properties, which is a *closed*
  /// object and therefore matches only `{}` — a trap worth naming, because
  /// "an object, contents unspecified" is a thing people reach for often and
  /// the closed default silently rejects every real value.
  ///
  /// Use this for a payload whose shape genuinely varies. Prefer declaring the
  /// properties wherever you can: an unconstrained object gives a model no
  /// guidance at all.
  factory JsonSchema.anyObject({String? description}) => JsonSchema._(
    type: JsonSchemaType.object,
    additionalProperties: true,
    description: description,
  );

  /// A string, optionally constrained.
  factory JsonSchema.string({
    String? description,
    Iterable<String>? enumValues,
    String? format,
    String? pattern,
    int? minLength,
    int? maxLength,
    String? defaultValue,
    List<Object?> examples = const <Object?>[],
  }) => JsonSchema._(
    type: JsonSchemaType.string,
    description: description,
    enumValues: enumValues == null
        ? null
        : List<Object?>.unmodifiable(enumValues),
    format: format,
    pattern: pattern,
    minLength: minLength,
    maxLength: maxLength,
    defaultValue: defaultValue,
    examples: List<Object?>.unmodifiable(examples),
  );

  /// A string restricted to [values].
  ///
  /// The single highest-leverage schema feature for tool calling: a model given
  /// an enum picks from it almost perfectly, where the same model given a free
  /// string invents a fourth option.
  factory JsonSchema.enumeration(
    Iterable<String> values, {
    String? description,
  }) {
    if (values.isEmpty) {
      throw ConfigurationException(
        'An enumeration schema needs at least one value.',
        setting: 'JsonSchema.enumeration.values',
      );
    }
    return JsonSchema.string(description: description, enumValues: values);
  }

  /// An integer, optionally bounded.
  factory JsonSchema.integer({
    String? description,
    int? minimum,
    int? maximum,
    int? exclusiveMinimum,
    int? exclusiveMaximum,
    int? multipleOf,
    int? defaultValue,
  }) => JsonSchema._(
    type: JsonSchemaType.integer,
    description: description,
    minimum: minimum?.toDouble(),
    maximum: maximum?.toDouble(),
    exclusiveMinimum: exclusiveMinimum?.toDouble(),
    exclusiveMaximum: exclusiveMaximum?.toDouble(),
    multipleOf: multipleOf?.toDouble(),
    defaultValue: defaultValue,
  );

  /// A number, optionally bounded.
  factory JsonSchema.number({
    String? description,
    double? minimum,
    double? maximum,
    double? exclusiveMinimum,
    double? exclusiveMaximum,
    double? multipleOf,
    double? defaultValue,
  }) => JsonSchema._(
    type: JsonSchemaType.number,
    description: description,
    minimum: minimum,
    maximum: maximum,
    exclusiveMinimum: exclusiveMinimum,
    exclusiveMaximum: exclusiveMaximum,
    multipleOf: multipleOf,
    defaultValue: defaultValue,
  );

  /// A boolean.
  factory JsonSchema.boolean({String? description, bool? defaultValue}) =>
      JsonSchema._(
        type: JsonSchemaType.boolean,
        description: description,
        defaultValue: defaultValue,
      );

  /// An array whose elements match [items].
  factory JsonSchema.array({
    required JsonSchema items,
    String? description,
    int? minItems,
    int? maxItems,
    bool uniqueItems = false,
  }) => JsonSchema._(
    type: JsonSchemaType.array,
    items: items,
    description: description,
    minItems: minItems,
    maxItems: maxItems,
    uniqueItems: uniqueItems,
  );

  /// A value matching at least one of [schemas].
  ///
  /// Supported by every provider that supports tool calling, unlike `oneOf`,
  /// which several reject. Prefer this for union-typed parameters.
  factory JsonSchema.anyOf(List<JsonSchema> schemas, {String? description}) {
    if (schemas.length < 2) {
      throw ConfigurationException(
        'anyOf needs at least two alternatives; got ${schemas.length}.',
        setting: 'JsonSchema.anyOf.schemas',
      );
    }
    return JsonSchema._(
      anyOf: List<JsonSchema>.unmodifiable(schemas),
      description: description,
    );
  }

  /// The declared type, or `null` for an unconstrained or `anyOf` schema.
  final JsonSchemaType? type;

  /// Natural-language description shown to the model.
  ///
  /// The most important field in the whole object. A model chooses a tool and
  /// fills its parameters almost entirely from these descriptions; a parameter
  /// documented as "the query" performs measurably worse than one documented as
  /// "the search query, in the user's own words, without quotation marks".
  final String? description;

  /// Human-readable name for the schema.
  final String? title;

  /// Property schemas, for an object.
  final Map<String, JsonSchema> properties;

  /// Names of properties that must be present, for an object.
  final Set<String> requiredProperties;

  /// Element schema, for an array.
  final JsonSchema? items;

  /// Permitted values, for an enumerated schema.
  final List<Object?>? enumValues;

  /// Semantic format hint such as `date-time`, `email` or `uri`.
  final String? format;

  /// Regular expression a string must match.
  final String? pattern;

  /// Inclusive lower bound for a number.
  final double? minimum;

  /// Inclusive upper bound for a number.
  final double? maximum;

  /// Exclusive lower bound for a number.
  final double? exclusiveMinimum;

  /// Exclusive upper bound for a number.
  final double? exclusiveMaximum;

  /// Required divisor for a number.
  final double? multipleOf;

  /// Minimum length of a string.
  final int? minLength;

  /// Maximum length of a string.
  final int? maxLength;

  /// Minimum number of array elements.
  final int? minItems;

  /// Maximum number of array elements.
  final int? maxItems;

  /// Whether array elements must be distinct.
  final bool uniqueItems;

  /// Whether properties not named in [properties] are allowed.
  final bool additionalProperties;

  /// Default applied by [coerce] when the value is absent.
  final Object? defaultValue;

  /// Alternatives, for an `anyOf` schema.
  final List<JsonSchema> anyOf;

  /// Whether JSON `null` is accepted in addition to [type].
  final bool nullable;

  /// Example values shown to the model.
  final List<Object?> examples;

  /// Returns a copy of this schema that also accepts `null`.
  JsonSchema asNullable() => _copyWith(nullable: true);

  /// Returns a copy with a different [description].
  JsonSchema describedAs(String description) =>
      _copyWith(description: description);

  /// Returns a copy in the strict dialect required for guaranteed structured
  /// output.
  ///
  /// Providers that guarantee schema conformance — OpenAI's `strict: true`,
  /// and Google's controlled generation — impose extra rules: every object must
  /// close `additionalProperties`, and every declared property must appear in
  /// `required`. Optional parameters are expressed by making the *type*
  /// nullable instead.
  ///
  /// This transformation applies those rules recursively, so a schema written
  /// naturally can be used in strict mode without being written twice.
  ///
  /// ```dart
  /// final strict = schema.toStrict(); // ready for structured output
  /// ```
  JsonSchema toStrict() {
    if (type != JsonSchemaType.object) {
      if (type == JsonSchemaType.array && items != null) {
        return _copyWith(items: items!.toStrict());
      }
      if (anyOf.isNotEmpty) {
        return _copyWith(
          anyOf: anyOf.map((schema) => schema.toStrict()).toList(),
        );
      }
      return this;
    }

    final strictProperties = <String, JsonSchema>{};
    for (final entry in properties.entries) {
      final wasOptional = !requiredProperties.contains(entry.key);
      final strictChild = entry.value.toStrict();
      strictProperties[entry.key] = wasOptional
          ? strictChild.asNullable()
          : strictChild;
    }

    return _copyWith(
      properties: strictProperties,
      requiredProperties: strictProperties.keys.toSet(),
      additionalProperties: false,
    );
  }

  /// Validates [value] against this schema.
  ///
  /// Never throws for invalid data — invalid data is an expected outcome when
  /// the producer is a language model. Use
  /// [SchemaValidationResult.throwIfInvalid] where an exception is wanted.
  SchemaValidationResult validate(Object? value) {
    final violations = <SchemaViolation>[];
    _validate(value, '', violations);
    return SchemaValidationResult(violations);
  }

  /// Repairs [value] where the mistake is unambiguous, then returns it.
  ///
  /// Language models emit predictable near-misses, and rejecting them costs a
  /// full round trip for something the framework can fix without guessing:
  ///
  /// * `"5"` for an integer, `"3.5"` for a number, `"true"` for a boolean —
  ///   every model does this, especially the small local ones;
  /// * `5` for a string, when the parameter is an identifier;
  /// * a bare value where a single-element array was declared;
  /// * a missing optional property that has a `default`.
  ///
  /// Ambiguous cases are never guessed: `"yes"` is not coerced to `true`,
  /// `"1,2"` is not split into an array, and an unknown enum value is left
  /// alone so validation can reject it. Coercion that guesses is worse than no
  /// coercion, because it silently runs a tool with data the user never asked
  /// for.
  ///
  /// Always [validate] the result; coercion is best-effort and does not
  /// guarantee conformance.
  Object? coerce(Object? value) {
    if (value == null) {
      return defaultValue;
    }

    if (anyOf.isNotEmpty) {
      for (final alternative in anyOf) {
        if (alternative.validate(value).isValid) return value;
      }
      for (final alternative in anyOf) {
        final coerced = alternative.coerce(value);
        if (alternative.validate(coerced).isValid) return coerced;
      }
      return value;
    }

    return switch (type) {
      null => value,
      JsonSchemaType.object => _coerceObject(value),
      JsonSchemaType.array => _coerceArray(value),
      JsonSchemaType.string => value is String ? value : _coerceString(value),
      JsonSchemaType.integer => _coerceInteger(value),
      JsonSchemaType.number => _coerceNumber(value),
      JsonSchemaType.boolean => _coerceBoolean(value),
      JsonSchemaType.nullValue => value,
    };
  }

  /// Serialises this schema to standard JSON Schema.
  ///
  /// The output is what gets sent to a provider as a function's `parameters`.
  JsonMap toJson() {
    final json = <String, Object?>{};

    if (anyOf.isNotEmpty) {
      json['anyOf'] = anyOf.map((schema) => schema.toJson()).toList();
    } else if (type != null) {
      // A nullable schema is expressed as a type union, which is the form every
      // supported provider accepts. `"type": "x", "nullable": true` is OpenAPI,
      // not JSON Schema, and is rejected by several of them.
      json['type'] = nullable
          ? <String>[type!.wireName, JsonSchemaType.nullValue.wireName]
          : type!.wireName;
    }

    if (title != null) json['title'] = title;
    if (description != null) json['description'] = description;
    if (enumValues != null) json['enum'] = enumValues;
    if (format != null) json['format'] = format;
    if (pattern != null) json['pattern'] = pattern;
    if (defaultValue != null) json['default'] = defaultValue;
    if (examples.isNotEmpty) json['examples'] = examples;

    if (type == JsonSchemaType.object) {
      json['properties'] = <String, Object?>{
        for (final entry in properties.entries) entry.key: entry.value.toJson(),
      };
      if (requiredProperties.isNotEmpty) {
        // Sorted so that serialisation is deterministic: identical schemas must
        // produce identical bytes, or prompt caching and golden tests both fail.
        json['required'] = requiredProperties.toList()..sort();
      }
      json['additionalProperties'] = additionalProperties;
    }

    if (type == JsonSchemaType.array && items != null) {
      json['items'] = items!.toJson();
      if (minItems != null) json['minItems'] = minItems;
      if (maxItems != null) json['maxItems'] = maxItems;
      if (uniqueItems) json['uniqueItems'] = true;
    }

    if (minLength != null) json['minLength'] = minLength;
    if (maxLength != null) json['maxLength'] = maxLength;
    if (minimum != null) json['minimum'] = _asJsonNumber(minimum!);
    if (maximum != null) json['maximum'] = _asJsonNumber(maximum!);
    if (exclusiveMinimum != null) {
      json['exclusiveMinimum'] = _asJsonNumber(exclusiveMinimum!);
    }
    if (exclusiveMaximum != null) {
      json['exclusiveMaximum'] = _asJsonNumber(exclusiveMaximum!);
    }
    if (multipleOf != null) json['multipleOf'] = _asJsonNumber(multipleOf!);

    return json;
  }

  /// Reconstructs a schema from JSON Schema.
  ///
  /// Supports the same subset [toJson] produces. Unknown keywords are ignored
  /// rather than rejected, so a schema authored elsewhere degrades to the
  /// closest supported shape instead of failing to load.
  static JsonSchema fromJson(JsonMap json) {
    final anyOfRaw = json['anyOf'];
    if (anyOfRaw is List && anyOfRaw.length >= 2) {
      return JsonSchema.anyOf(
        anyOfRaw
            .whereType<Map<Object?, Object?>>()
            .map((entry) => JsonSchema.fromJson(entry.cast<String, Object?>()))
            .toList(),
        description: json['description'] as String?,
      );
    }

    final rawType = json['type'];
    var nullable = false;
    JsonSchemaType? type;
    if (rawType is String) {
      type = JsonSchemaType.fromWire(rawType);
    } else if (rawType is List) {
      final names = rawType.whereType<String>().toList();
      nullable = names.contains('null');
      final concrete = names.firstWhereOrNull((name) => name != 'null');
      type = concrete == null ? null : JsonSchemaType.fromWire(concrete);
    }

    final properties = <String, JsonSchema>{};
    final rawProperties = json['properties'];
    if (rawProperties is Map) {
      for (final entry in rawProperties.entries) {
        final value = entry.value;
        if (value is Map) {
          properties[entry.key.toString()] = JsonSchema.fromJson(
            value.cast<String, Object?>(),
          );
        }
      }
    }

    final rawItems = json['items'];
    final rawEnum = json['enum'];

    return JsonSchema._(
      type: type,
      nullable: nullable,
      description: json['description'] as String?,
      title: json['title'] as String?,
      properties: Map<String, JsonSchema>.unmodifiable(properties),
      requiredProperties: Set<String>.unmodifiable(
        (json['required'] as List?)?.whereType<String>().toSet() ??
            const <String>{},
      ),
      items: rawItems is Map
          ? JsonSchema.fromJson(rawItems.cast<String, Object?>())
          : null,
      enumValues: rawEnum is List ? List<Object?>.unmodifiable(rawEnum) : null,
      format: json['format'] as String?,
      pattern: json['pattern'] as String?,
      defaultValue: json['default'],
      additionalProperties: json['additionalProperties'] as bool? ?? true,
      minLength: (json['minLength'] as num?)?.toInt(),
      maxLength: (json['maxLength'] as num?)?.toInt(),
      minItems: (json['minItems'] as num?)?.toInt(),
      maxItems: (json['maxItems'] as num?)?.toInt(),
      uniqueItems: json['uniqueItems'] as bool? ?? false,
      minimum: (json['minimum'] as num?)?.toDouble(),
      maximum: (json['maximum'] as num?)?.toDouble(),
      exclusiveMinimum: (json['exclusiveMinimum'] as num?)?.toDouble(),
      exclusiveMaximum: (json['exclusiveMaximum'] as num?)?.toDouble(),
      multipleOf: (json['multipleOf'] as num?)?.toDouble(),
      examples: List<Object?>.unmodifiable(
        (json['examples'] as List?) ?? const <Object?>[],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Validation
  // ---------------------------------------------------------------------------

  void _validate(Object? value, String path, List<SchemaViolation> violations) {
    if (anyOf.isNotEmpty) {
      final matched = anyOf.any(
        (alternative) => alternative.validate(value).isValid,
      );
      if (!matched) {
        violations.add(
          SchemaViolation(
            path: path,
            keyword: 'anyOf',
            message:
                'Value does not match any of the ${anyOf.length} permitted '
                'shapes.',
          ),
        );
      }
      return;
    }

    if (value == null) {
      if (!nullable && type != null && type != JsonSchemaType.nullValue) {
        violations.add(
          SchemaViolation(
            path: path,
            keyword: 'type',
            message: 'Expected ${type!.wireName}, got null.',
          ),
        );
      }
      return;
    }

    final declaredType = type;
    if (declaredType == null) return;

    if (!_matchesType(value, declaredType)) {
      violations.add(
        SchemaViolation(
          path: path,
          keyword: 'type',
          message:
              'Expected ${declaredType.wireName}, got ${_typeNameOf(value)}.',
        ),
      );
      return;
    }

    final permitted = enumValues;
    if (permitted != null && !permitted.contains(value)) {
      violations.add(
        SchemaViolation(
          path: path,
          keyword: 'enum',
          message:
              'Value `$value` is not permitted. '
              'Expected one of: ${permitted.map((v) => '`$v`').join(', ')}.',
        ),
      );
    }

    switch (declaredType) {
      case JsonSchemaType.object:
        _validateObject(value as Map<Object?, Object?>, path, violations);
      case JsonSchemaType.array:
        _validateArray(value as List<Object?>, path, violations);
      case JsonSchemaType.string:
        _validateString(value as String, path, violations);
      case JsonSchemaType.integer:
      case JsonSchemaType.number:
        _validateNumber((value as num).toDouble(), path, violations);
      case JsonSchemaType.boolean:
      case JsonSchemaType.nullValue:
        break;
    }
  }

  void _validateObject(
    Map<Object?, Object?> value,
    String path,
    List<SchemaViolation> violations,
  ) {
    for (final name in requiredProperties) {
      if (!value.containsKey(name) || value[name] == null) {
        final child = properties[name];
        violations.add(
          SchemaViolation(
            path: '$path/$name',
            keyword: 'required',
            message: child?.description == null
                ? 'Required property `$name` is missing.'
                : 'Required property `$name` is missing '
                      '(${child!.description}).',
          ),
        );
      }
    }

    for (final entry in value.entries) {
      final name = entry.key.toString();
      final child = properties[name];
      if (child == null) {
        if (!additionalProperties) {
          violations.add(
            SchemaViolation(
              path: '$path/$name',
              keyword: 'additionalProperties',
              message: properties.isEmpty
                  ? 'Unexpected property `$name`.'
                  : 'Unexpected property `$name`. Permitted properties are: '
                        '${properties.keys.map((k) => '`$k`').join(', ')}.',
            ),
          );
        }
        continue;
      }
      child._validate(entry.value, '$path/$name', violations);
    }
  }

  void _validateArray(
    List<Object?> value,
    String path,
    List<SchemaViolation> violations,
  ) {
    if (minItems != null && value.length < minItems!) {
      violations.add(
        SchemaViolation(
          path: path,
          keyword: 'minItems',
          message: 'Expected at least $minItems item(s), got ${value.length}.',
        ),
      );
    }
    if (maxItems != null && value.length > maxItems!) {
      violations.add(
        SchemaViolation(
          path: path,
          keyword: 'maxItems',
          message: 'Expected at most $maxItems item(s), got ${value.length}.',
        ),
      );
    }
    if (uniqueItems) {
      final seen = <String>{};
      for (var i = 0; i < value.length; i++) {
        if (!seen.add(value[i].toString())) {
          violations.add(
            SchemaViolation(
              path: '$path/$i',
              keyword: 'uniqueItems',
              message: 'Duplicate item `${value[i]}`.',
            ),
          );
        }
      }
    }
    final element = items;
    if (element == null) return;
    for (var i = 0; i < value.length; i++) {
      element._validate(value[i], '$path/$i', violations);
    }
  }

  void _validateString(
    String value,
    String path,
    List<SchemaViolation> violations,
  ) {
    if (minLength != null && value.length < minLength!) {
      violations.add(
        SchemaViolation(
          path: path,
          keyword: 'minLength',
          message:
              'Expected at least $minLength character(s), got ${value.length}.',
        ),
      );
    }
    if (maxLength != null && value.length > maxLength!) {
      violations.add(
        SchemaViolation(
          path: path,
          keyword: 'maxLength',
          message:
              'Expected at most $maxLength character(s), got ${value.length}.',
        ),
      );
    }
    final expression = pattern;
    if (expression != null && !RegExp(expression).hasMatch(value)) {
      violations.add(
        SchemaViolation(
          path: path,
          keyword: 'pattern',
          message: 'Value does not match the required pattern `$expression`.',
        ),
      );
    }
    final semanticFormat = format;
    if (semanticFormat != null && !_matchesFormat(value, semanticFormat)) {
      violations.add(
        SchemaViolation(
          path: path,
          keyword: 'format',
          message: 'Value is not a valid `$semanticFormat`.',
        ),
      );
    }
  }

  void _validateNumber(
    double value,
    String path,
    List<SchemaViolation> violations,
  ) {
    if (minimum != null && value < minimum!) {
      violations.add(
        SchemaViolation(
          path: path,
          keyword: 'minimum',
          message:
              'Expected a value >= ${_asJsonNumber(minimum!)}, '
              'got ${_asJsonNumber(value)}.',
        ),
      );
    }
    if (maximum != null && value > maximum!) {
      violations.add(
        SchemaViolation(
          path: path,
          keyword: 'maximum',
          message:
              'Expected a value <= ${_asJsonNumber(maximum!)}, '
              'got ${_asJsonNumber(value)}.',
        ),
      );
    }
    if (exclusiveMinimum != null && value <= exclusiveMinimum!) {
      violations.add(
        SchemaViolation(
          path: path,
          keyword: 'exclusiveMinimum',
          message:
              'Expected a value > ${_asJsonNumber(exclusiveMinimum!)}, '
              'got ${_asJsonNumber(value)}.',
        ),
      );
    }
    if (exclusiveMaximum != null && value >= exclusiveMaximum!) {
      violations.add(
        SchemaViolation(
          path: path,
          keyword: 'exclusiveMaximum',
          message:
              'Expected a value < ${_asJsonNumber(exclusiveMaximum!)}, '
              'got ${_asJsonNumber(value)}.',
        ),
      );
    }
    final divisor = multipleOf;
    if (divisor != null && divisor != 0) {
      final quotient = value / divisor;
      if ((quotient - quotient.roundToDouble()).abs() > 1e-9) {
        violations.add(
          SchemaViolation(
            path: path,
            keyword: 'multipleOf',
            message:
                'Expected a multiple of ${_asJsonNumber(divisor)}, '
                'got ${_asJsonNumber(value)}.',
          ),
        );
      }
    }
  }

  static bool _matchesType(Object? value, JsonSchemaType type) =>
      switch (type) {
        JsonSchemaType.object => value is Map,
        JsonSchemaType.array => value is List,
        JsonSchemaType.string => value is String,
        JsonSchemaType.boolean => value is bool,
        JsonSchemaType.number => value is num,
        // `5.0` satisfies `integer` in JSON Schema: JSON has one number type,
        // and a provider serialising 5 as 5.0 must not fail validation.
        JsonSchemaType.integer =>
          value is int || (value is double && value == value.roundToDouble()),
        JsonSchemaType.nullValue => value == null,
      };

  static bool _matchesFormat(String value, String format) => switch (format) {
    'date-time' => DateTime.tryParse(value) != null,
    'date' => RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(value),
    'time' => RegExp(r'^\d{2}:\d{2}(:\d{2})?').hasMatch(value),
    'email' => RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(value),
    'uri' || 'url' => Uri.tryParse(value)?.hasScheme ?? false,
    'uuid' => RegExp(
      r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-'
      r'[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
    ).hasMatch(value),
    // An unrecognised format is advisory, not a constraint. JSON Schema says
    // the same, and rejecting one would break schemas authored for another
    // toolchain.
    _ => true,
  };

  static String _typeNameOf(Object? value) => switch (value) {
    null => 'null',
    final bool _ => 'boolean',
    final int _ => 'integer',
    final double _ => 'number',
    final String _ => 'string',
    final List<Object?> _ => 'array',
    final Map<Object?, Object?> _ => 'object',
    _ => value.runtimeType.toString(),
  };

  // ---------------------------------------------------------------------------
  // Coercion
  // ---------------------------------------------------------------------------

  Object? _coerceObject(Object? value) {
    if (value is! Map) return value;
    final source = value.map(
      (key, dynamic entry) => MapEntry(key.toString(), entry as Object?),
    );
    final result = <String, Object?>{};

    for (final entry in properties.entries) {
      final child = entry.value;
      if (source.containsKey(entry.key)) {
        result[entry.key] = child.coerce(source[entry.key]);
      } else if (child.defaultValue != null) {
        result[entry.key] = child.defaultValue;
      }
    }
    // Unknown keys are preserved so that validation can report them. Dropping
    // them here would turn a violation into a silent data loss.
    for (final entry in source.entries) {
      result.putIfAbsent(entry.key, () => entry.value);
    }
    return result;
  }

  Object? _coerceArray(Object? value) {
    final element = items;
    if (value is List) {
      return element == null
          ? value
          : value.map(element.coerce).toList(growable: false);
    }
    // A model asked for a list of one thing routinely sends the thing. Wrapping
    // is unambiguous: the schema says array, the value is a single element.
    final wrapped = <Object?>[element == null ? value : element.coerce(value)];
    return wrapped;
  }

  Object? _coerceString(Object? value) {
    if (value is num || value is bool) return value.toString();
    return value;
  }

  Object? _coerceInteger(Object? value) {
    if (value is int) return value;
    if (value is double) {
      return value == value.roundToDouble() ? value.toInt() : value;
    }
    if (value is String) {
      final parsed = int.tryParse(value.trim());
      if (parsed != null) return parsed;
      final asDouble = double.tryParse(value.trim());
      if (asDouble != null && asDouble == asDouble.roundToDouble()) {
        return asDouble.toInt();
      }
    }
    return value;
  }

  Object? _coerceNumber(Object? value) {
    if (value is num) return value;
    if (value is String) {
      final parsed = double.tryParse(value.trim());
      if (parsed != null) return parsed;
    }
    return value;
  }

  Object? _coerceBoolean(Object? value) {
    if (value is bool) return value;
    if (value is String) {
      final normalised = value.trim().toLowerCase();
      // Only the exact JSON literals are coerced. "yes", "1" and "on" are
      // guesses about intent, and a wrongly-coerced boolean silently flips a
      // tool's behaviour.
      if (normalised == 'true') return true;
      if (normalised == 'false') return false;
    }
    return value;
  }

  static Object _asJsonNumber(double value) =>
      value == value.roundToDouble() && value.abs() < 1e15
      ? value.toInt()
      : value;

  JsonSchema _copyWith({
    JsonSchemaType? type,
    String? description,
    String? title,
    Map<String, JsonSchema>? properties,
    Set<String>? requiredProperties,
    JsonSchema? items,
    bool? additionalProperties,
    bool? nullable,
    List<JsonSchema>? anyOf,
  }) => JsonSchema._(
    type: type ?? this.type,
    description: description ?? this.description,
    title: title ?? this.title,
    properties: properties ?? this.properties,
    requiredProperties: requiredProperties ?? this.requiredProperties,
    items: items ?? this.items,
    enumValues: enumValues,
    format: format,
    pattern: pattern,
    minimum: minimum,
    maximum: maximum,
    exclusiveMinimum: exclusiveMinimum,
    exclusiveMaximum: exclusiveMaximum,
    multipleOf: multipleOf,
    minLength: minLength,
    maxLength: maxLength,
    minItems: minItems,
    maxItems: maxItems,
    uniqueItems: uniqueItems,
    additionalProperties: additionalProperties ?? this.additionalProperties,
    defaultValue: defaultValue,
    anyOf: anyOf ?? this.anyOf,
    nullable: nullable ?? this.nullable,
    examples: examples,
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is JsonSchema &&
          const DeepCollectionEquality().equals(toJson(), other.toJson());

  @override
  int get hashCode => const DeepCollectionEquality().hash(toJson());

  @override
  String toString() =>
      'JsonSchema(${type?.wireName ?? (anyOf.isNotEmpty ? 'anyOf' : 'any')})';
}
