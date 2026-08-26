import 'package:agentic_core/agentic_core.dart';
import 'package:test/test.dart';

final searchSchema = JsonSchema.object(
  description: 'Search the web',
  properties: {
    'query': JsonSchema.string(description: 'What to search for', minLength: 1),
    'limit': JsonSchema.integer(minimum: 1, maximum: 50, defaultValue: 10),
    'safe': JsonSchema.boolean(description: 'Filter adult results'),
    'sources': JsonSchema.array(items: JsonSchema.string(), maxItems: 3),
    'mode': JsonSchema.enumeration(['fast', 'thorough']),
  },
  required: {'query'},
);

void main() {
  group('validation', () {
    test('accepts a well-formed object', () {
      expect(searchSchema.validate({'query': 'dart 3'}).isValid, isTrue);
    });

    test('reports a missing required property with its description', () {
      final result = searchSchema.validate({'limit': 5});

      expect(result.isValid, isFalse);
      expect(result.violations, hasLength(1));
      expect(result.violations.single.keyword, 'required');
      expect(result.violations.single.path, '/query');
      expect(result.violations.single.message, contains('What to search for'));
    });

    test('renders numbers the way JSON does, not the way Dart does', () {
      // The message is handed back to a model verbatim; `500.0` for an integer
      // bound invites it to reply with a float.
      final result = searchSchema.validate({'query': 'x', 'limit': 500});

      expect(
        result.violations.single.message,
        'Expected a value <= 50, got 500.',
      );
    });

    test('reports every violation, not just the first', () {
      final result = searchSchema.validate({
        'limit': 500,
        'mode': 'medium',
        'sources': ['a', 'b', 'c', 'd'],
      });

      expect(
        result.violations.map((v) => v.keyword),
        containsAll(<String>['required', 'maximum', 'enum', 'maxItems']),
        reason: 'a model repairing its output should see every problem at once',
      );
    });

    test('rejects an unexpected property and lists the permitted ones', () {
      final result = searchSchema.validate({'query': 'x', 'lmit': 5});

      final violation = result.violations.singleWhere(
        (v) => v.keyword == 'additionalProperties',
      );
      expect(violation.path, '/lmit');
      expect(violation.message, contains('`limit`'));
    });

    test('accepts an integral double for an integer', () {
      // Providers routinely serialise 5 as 5.0; rejecting that would be wrong.
      expect(
        searchSchema.validate({'query': 'x', 'limit': 5.0}).isValid,
        isTrue,
      );
      expect(
        searchSchema.validate({'query': 'x', 'limit': 5.5}).isValid,
        isFalse,
      );
    });

    test('reports nested paths as JSON pointers', () {
      final schema = JsonSchema.object(
        properties: {
          'filters': JsonSchema.array(
            items: JsonSchema.object(
              properties: {'field': JsonSchema.string()},
              required: {'field'},
            ),
          ),
        },
      );

      final result = schema.validate({
        'filters': [
          {'field': 'ok'},
          {'wrong': 1},
        ],
      });

      expect(
        result.violations.map((v) => v.path),
        contains('/filters/1/field'),
      );
    });

    test('rejects null unless the schema is nullable', () {
      expect(JsonSchema.string().validate(null).isValid, isFalse);
      expect(JsonSchema.string().asNullable().validate(null).isValid, isTrue);
    });

    test('validates string constraints', () {
      final schema = JsonSchema.string(
        minLength: 2,
        maxLength: 5,
        pattern: r'^[a-z]+$',
      );

      expect(schema.validate('abc').isValid, isTrue);
      expect(schema.validate('a').violations.single.keyword, 'minLength');
      expect(schema.validate('abcdef').violations.single.keyword, 'maxLength');
      expect(schema.validate('ABC').violations.single.keyword, 'pattern');
    });

    test('validates known formats and ignores unknown ones', () {
      expect(
        JsonSchema.string(format: 'email').validate('a@b.co').isValid,
        isTrue,
      );
      expect(
        JsonSchema.string(format: 'email').validate('nope').isValid,
        isFalse,
      );
      expect(
        JsonSchema.string(format: 'invented').validate('anything').isValid,
        isTrue,
        reason: 'an unrecognised format is advisory, per JSON Schema',
      );
    });

    test('anyOf accepts a value matching any alternative', () {
      final schema = JsonSchema.anyOf([
        JsonSchema.string(),
        JsonSchema.integer(),
      ]);

      expect(schema.validate('text').isValid, isTrue);
      expect(schema.validate(42).isValid, isTrue);
      expect(schema.validate(true).isValid, isFalse);
    });

    test('throwIfInvalid raises a ValidationException listing violations', () {
      expect(
        () => searchSchema
            .validate(<String, Object?>{})
            .throwIfInvalid(subject: 'arguments for tool web_search'),
        throwsA(
          isA<ValidationException>()
              .having((e) => e.violations, 'violations', hasLength(1))
              .having(
                (e) => e.message,
                'message',
                contains('arguments for tool web_search'),
              ),
        ),
      );
    });
  });

  group('construction', () {
    test('rejects a required property that is not declared', () {
      expect(
        () => JsonSchema.object(
          properties: {'a': JsonSchema.string()},
          required: {'b'},
        ),
        throwsA(isA<ConfigurationException>()),
      );
    });

    test('objects are closed by default', () {
      expect(JsonSchema.object().additionalProperties, isFalse);
    });

    test('an empty closed object matches only an empty object', () {
      // The trap `anyObject` exists to avoid: "an object, contents
      // unspecified" is what people mean, and the closed default rejects every
      // real value.
      expect(JsonSchema.object().validate(<String, Object?>{}).isValid, isTrue);
      expect(
        JsonSchema.object().validate(<String, Object?>{'a': 1}).isValid,
        isFalse,
      );
      expect(
        JsonSchema.anyObject().validate(<String, Object?>{'a': 1}).isValid,
        isTrue,
      );
      expect(JsonSchema.anyObject().validate('not an object').isValid, isFalse);
    });
  });

  group('coercion', () {
    test('repairs the numeric string a model sent for an integer', () {
      final coerced = searchSchema.coerce({'query': 'x', 'limit': '5'});

      expect((coerced! as Map)['limit'], 5);
      expect(searchSchema.validate(coerced).isValid, isTrue);
    });

    test('repairs a stringified boolean', () {
      expect(JsonSchema.boolean().coerce('true'), isTrue);
      expect(JsonSchema.boolean().coerce('false'), isFalse);
    });

    test('refuses to guess an ambiguous boolean', () {
      // "yes" is a guess about intent, and a wrongly-flipped boolean silently
      // changes what a tool does.
      expect(JsonSchema.boolean().coerce('yes'), 'yes');
      expect(JsonSchema.boolean().coerce(1), 1);
    });

    test('wraps a bare value where an array was declared', () {
      final schema = JsonSchema.array(items: JsonSchema.string());

      expect(schema.coerce('solo'), <String>['solo']);
      expect(schema.coerce(<String>['a', 'b']), <String>['a', 'b']);
    });

    test('applies declared defaults for absent properties', () {
      final coerced = searchSchema.coerce({'query': 'x'})! as Map;

      expect(coerced['limit'], 10);
    });

    test('preserves unknown keys so validation can report them', () {
      final coerced = searchSchema.coerce({'query': 'x', 'bogus': 1})! as Map;

      expect(coerced['bogus'], 1);
      expect(searchSchema.validate(coerced).isValid, isFalse);
    });

    test('leaves an unknown enum value alone', () {
      final schema = JsonSchema.enumeration(['fast', 'thorough']);

      expect(schema.coerce('medium'), 'medium');
      expect(schema.validate('medium').isValid, isFalse);
    });
  });

  group('serialisation', () {
    test('emits standard JSON Schema', () {
      final json = JsonSchema.object(
        properties: {'q': JsonSchema.string(description: 'query')},
        required: {'q'},
      ).toJson();

      expect(json['type'], 'object');
      expect(json['required'], <String>['q']);
      expect(json['additionalProperties'], isFalse);
      expect(
        (json['properties']! as Map)['q'],
        containsPair('description', 'query'),
      );
    });

    test('renders a nullable schema as a type union', () {
      // `{"type": "x", "nullable": true}` is OpenAPI, not JSON Schema, and
      // several providers reject it.
      expect(JsonSchema.string().asNullable().toJson()['type'], <String>[
        'string',
        'null',
      ]);
    });

    test('sorts required keys so output is byte-stable', () {
      final json = JsonSchema.object(
        properties: {'z': JsonSchema.string(), 'a': JsonSchema.string()},
        required: {'z', 'a'},
      ).toJson();

      expect(json['required'], <String>['a', 'z']);
    });

    test('round-trips through fromJson', () {
      final restored = JsonSchema.fromJson(searchSchema.toJson());

      expect(restored, searchSchema);
      expect(restored.toJson(), searchSchema.toJson());
    });

    test('ignores unsupported keywords rather than failing', () {
      final restored = JsonSchema.fromJson(<String, Object?>{
        'type': 'string',
        r'$comment': 'ignored',
        'contentEncoding': 'base64',
      });

      expect(restored.type, JsonSchemaType.string);
    });
  });

  group('toStrict', () {
    test('closes objects and makes optional properties nullable', () {
      final strict = searchSchema.toStrict();

      expect(strict.additionalProperties, isFalse);
      expect(
        strict.requiredProperties,
        containsAll(<String>['query', 'limit', 'safe', 'sources', 'mode']),
        reason: 'strict dialects require every declared property',
      );
      expect(strict.properties['limit']!.nullable, isTrue);
      expect(strict.properties['query']!.nullable, isFalse);
    });

    test('recurses into arrays and nested objects', () {
      final schema = JsonSchema.object(
        properties: {
          'rows': JsonSchema.array(
            items: JsonSchema.object(properties: {'a': JsonSchema.string()}),
          ),
        },
      );

      final nested = schema.toStrict().properties['rows']!.items!;

      expect(nested.additionalProperties, isFalse);
      expect(nested.requiredProperties, <String>{'a'});
    });
  });
}
