/// Turns `@ToolFunction` functions and methods into `FunctionTool`s.
///
/// # What is generated
///
/// For a top-level function:
///
/// ```dart
/// final FunctionTool orderStatusTool = FunctionTool(
///   name: 'order_status',
///   description: 'Looks up where an order is.',
///   parameters: JsonSchema.object(...),
///   isReadOnly: true,
///   handler: (invocation) async => ToolResult.success(
///     await orderStatus(invocation.require<String>('order')),
///   ),
/// );
/// ```
///
/// For methods of a class, an extension whose `agentTools` getter returns them
/// bound to the instance.
///
/// # What is checked
///
/// Everything a hand-written tool gets wrong at runtime is a build error here:
/// a parameter type with no JSON representation, a return value that cannot
/// become text, a tool with no description, two tools with one name, and a
/// library that does not import what the generated code needs.
library;

import 'package:analyzer/dart/constant/value.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/nullability_suffix.dart';
import 'package:analyzer/dart/element/type.dart';
import 'package:build/build.dart';
import 'package:source_gen/source_gen.dart';

const TypeChecker _agentTool = TypeChecker.typeNamedLiterally(
  'ToolFunction',
  inPackage: 'agentic_tools',
);
const TypeChecker _toolParam = TypeChecker.typeNamedLiterally(
  'ToolParam',
  inPackage: 'agentic_tools',
);
const TypeChecker _toolInvocation = TypeChecker.typeNamedLiterally(
  'ToolInvocation',
  inPackage: 'agentic_tools',
);
const TypeChecker _toolResult = TypeChecker.typeNamedLiterally(
  'ToolResult',
  inPackage: 'agentic_tools',
);
const TypeChecker _agenticContext = TypeChecker.typeNamedLiterally(
  'AgenticContext',
  inPackage: 'agentic_core',
);
const TypeChecker _cancellationToken = TypeChecker.typeNamedLiterally(
  'CancellationToken',
  inPackage: 'agentic_core',
);
const TypeChecker _dateTime = TypeChecker.typeNamedLiterally(
  'DateTime',
  inSdk: true,
);

/// The names the generated code uses, and the package each comes from.
const Map<String, String> _requiredNames = <String, String>{
  'FunctionTool': 'package:agentic_tools/agentic_tools.dart',
  'ToolResult': 'package:agentic_tools/agentic_tools.dart',
  'JsonSchema': 'package:agentic_core/agentic_core.dart',
};

/// Generates tools for every `@ToolFunction` in a library.
final class AgentToolGenerator extends Generator {
  /// Creates the generator.
  const AgentToolGenerator();

  @override
  String? generate(LibraryReader library, BuildStep buildStep) {
    final functions = <TopLevelFunctionElement>[
      for (final function in library.element.topLevelFunctions)
        if (_agentTool.hasAnnotationOf(function)) function,
    ];
    final classes = <(ClassElement, List<MethodElement>)>[
      for (final type in library.element.classes)
        if (type.methods.where(_agentTool.hasAnnotationOf).toList()
            case final methods when methods.isNotEmpty)
          (type, methods),
    ];
    if (functions.isEmpty && classes.isEmpty) return null;

    _requireImports(
      library.element,
      functions.firstOrNull ?? classes.first.$2.first,
    );

    // Generated code follows the generator's style, not the package's lint
    // set, and nobody edits it by hand.
    final output = StringBuffer()
      ..writeln('// ignore_for_file: type=lint')
      ..writeln();
    final names = <String, Element>{};

    for (final function in functions) {
      final tool = _ToolModel.of(function);
      _claimName(names, tool, function);
      final variable = '${function.name}Tool';
      output
        ..writeln(
          '/// The `${tool.name}` tool, generated from [${function.name}].',
        )
        ..writeln(
          'final FunctionTool $variable = ${tool.render(function.name!)};',
        )
        ..writeln();
    }

    for (final (type, methods) in classes) {
      final className = type.name!;
      if (type.typeParameters.isNotEmpty) {
        throw InvalidGenerationSourceError(
          '`$className` is generic, so the generated extension could not say '
          'which instantiation its tools belong to. Move the tools to a '
          'non-generic class.',
          element: type,
        );
      }
      final tools = <String>[];
      for (final method in methods) {
        final tool = _ToolModel.of(method);
        _claimName(names, tool, method);
        final target = method.isStatic
            ? '$className.${method.name}'
            // `this.` is required: inside an extension, a bare name finds a
            // top-level function of the same name before the instance method.
            : 'this.${method.name}';
        tools.add(tool.render(target));
      }
      final extensionName = '${className.replaceFirst('_', r'$')}AgentTools';
      output
        ..writeln('/// The `@ToolFunction` methods of [$className], as tools.')
        ..writeln('extension $extensionName on $className {')
        ..writeln('  /// Every `@ToolFunction` method, bound to this instance.')
        ..writeln('  ///')
        ..writeln(
          '  /// Builds new tools on each read; read it once and register',
        )
        ..writeln('  /// the result.')
        ..writeln('  List<FunctionTool> get agentTools => <FunctionTool>[')
        ..writeln(tools.map((t) => '    $t,').join('\n'))
        ..writeln('  ];')
        ..writeln('}')
        ..writeln();
    }
    return output.toString();
  }

  static void _claimName(
    Map<String, Element> names,
    _ToolModel tool,
    Element element,
  ) {
    final existing = names[tool.name];
    if (existing != null) {
      throw InvalidGenerationSourceError(
        'Two tools in this library are named `${tool.name}`: '
        '`${existing.displayName}` and `${element.displayName}`. A model '
        'could not tell them apart. Pass `name:` to one of them.',
        element: element,
      );
    }
    names[tool.name] = element;
  }

  /// Fails the build when the generated code would not compile for want of an
  /// import, with a message naming the import — rather than leaving the user to
  /// decode "Undefined name 'JsonSchema'" in a generated file.
  static void _requireImports(LibraryElement library, Element anchor) {
    final visible = <String>{};
    for (final import in library.firstFragment.libraryImports) {
      if (import.prefix != null) continue;
      for (final name in _requiredNames.keys) {
        if (import.namespace.get2(name) != null) visible.add(name);
      }
    }
    final missing = _requiredNames.keys.where((n) => !visible.contains(n));
    if (missing.isEmpty) return;
    final imports = missing.map((n) => _requiredNames[n]!).toSet();
    throw InvalidGenerationSourceError(
      'The generated tools use ${missing.map((n) => '`$n`').join(', ')}, '
      'which this library does not import without a prefix. Add '
      '${imports.map((i) => "`import '$i';`").join(' and ')} '
      '(or `package:agentic_flutter/agentic_flutter.dart`, which exports '
      'both).',
      element: anchor,
    );
  }
}

/// One tool, read from an annotated function or method.
final class _ToolModel {
  _ToolModel({
    required this.name,
    required this.description,
    required this.annotation,
    required this.parameters,
    required this.returns,
    required this.isAsync,
  });

  factory _ToolModel.of(ExecutableElement element) {
    final functionName = element.name!;
    if (element.isPrivate) {
      throw InvalidGenerationSourceError(
        '`$functionName` is private, and the generated tool lives in a part '
        'that is visible outside this library. Make it public, or leave it '
        'unannotated.',
        element: element,
      );
    }
    if (element.typeParameters.isNotEmpty) {
      throw InvalidGenerationSourceError(
        '`$functionName` is generic. A tool is called with JSON, which cannot '
        'say what the type arguments are.',
        element: element,
      );
    }
    final annotation = ConstantReader(_agentTool.firstAnnotationOf(element));
    final name =
        _optionalString(annotation, 'name') ?? _snakeCase(functionName);
    if (!RegExp(r'^[a-zA-Z0-9_-]{1,64}$').hasMatch(name)) {
      throw InvalidGenerationSourceError(
        'The tool name `$name` is not usable. Providers accept 1-64 letters, '
        'digits, underscores and hyphens.',
        element: element,
      );
    }
    final description =
        _optionalString(annotation, 'description') ??
        _docComment(element.documentationComment);
    if (description == null || description.trim().isEmpty) {
      throw InvalidGenerationSourceError(
        '`$functionName` has no description. A model chooses tools by what '
        'they say they do: add a `///` comment or `description:`.',
        element: element,
      );
    }

    final (returned, isAsync) = _unwrapFuture(element.returnType);
    return _ToolModel(
      name: name,
      description: description.trim(),
      annotation: annotation,
      parameters: [
        for (final parameter in element.formalParameters)
          _ParameterModel.of(parameter, element),
      ],
      returns: _ReturnKind.of(returned, element),
      isAsync: isAsync,
    );
  }

  final String name;
  final String description;
  final ConstantReader annotation;
  final List<_ParameterModel> parameters;
  final _ReturnKind returns;
  final bool isAsync;

  /// The `FunctionTool(...)` expression calling [target].
  String render(String target) {
    final schemaParameters = parameters.where((p) => !p.isInjected).toList();
    final isReadOnly = annotation.read('isReadOnly').boolValue;
    final idempotent = annotation.read('isIdempotent');
    final isIdempotent = idempotent.isNull ? isReadOnly : idempotent.boolValue;
    final tags = <String>[
      for (final tag in annotation.read('tags').setValue) tag.toStringValue()!,
    ]..sort();
    final timeout = annotation.read('timeout');

    final positional = [
      for (final p in parameters)
        if (!p.element.isNamed) p.readExpression,
    ];
    final named = [
      for (final p in parameters)
        if (p.element.isNamed) '${p.element.name}: ${p.readExpression}',
    ];
    final call = '$target(${[...positional, ...named].join(', ')})';
    final value = isAsync ? '(await $call)' : call;

    return [
      'FunctionTool(',
      '  name: ${_literal(name)},',
      '  description: ${_literal(description)},',
      '  parameters: JsonSchema.object(',
      '    properties: <String, JsonSchema>{',
      for (final p in schemaParameters)
        '      ${_literal(p.element.name!)}: ${p.schema},',
      '    },',
      '    required: <String>{',
      for (final p in schemaParameters)
        if (p.isRequired) '      ${_literal(p.element.name!)},',
      '    },',
      '  ),',
      '  isReadOnly: $isReadOnly,',
      '  isIdempotent: $isIdempotent,',
      if (annotation.read('requiresApproval').boolValue)
        '  requiresApproval: true,',
      if (annotation.read('returnsUntrustedContent').boolValue)
        '  returnsUntrustedContent: true,',
      if (tags.isNotEmpty)
        '  tags: <String>{${tags.map(_literal).join(', ')}},',
      if (!timeout.isNull) _timeoutArgument(timeout),
      '  handler: (invocation) async {',
      ...returns.render(value),
      '  },',
      ')',
    ].join('\n');
  }
}

/// How one parameter is described to the model and read back from JSON.
final class _ParameterModel {
  _ParameterModel({
    required this.element,
    required this.schema,
    required this.readExpression,
    required this.isRequired,
    required this.isInjected,
  });

  factory _ParameterModel.of(
    FormalParameterElement element,
    ExecutableElement function,
  ) {
    final type = element.type;
    final key = _literal(element.name!);

    // Parameters the framework supplies, never the model.
    for (final (checker, expression) in <(TypeChecker, String)>[
      (_toolInvocation, 'invocation'),
      (_agenticContext, 'invocation.context'),
      (_cancellationToken, 'invocation.cancellation'),
    ]) {
      if (checker.isExactlyType(type)) {
        return _ParameterModel(
          element: element,
          schema: '',
          readExpression: expression,
          isRequired: false,
          isInjected: true,
        );
      }
    }

    final nullable = type.nullabilitySuffix == NullabilitySuffix.question;
    final hasDefault = element.hasDefaultValue;
    final isRequired = !nullable && !hasDefault;
    final description = _toolParam.firstAnnotationOf(element) == null
        ? null
        : ConstantReader(
            _toolParam.firstAnnotationOf(element),
          ).read('description').stringValue;

    final mapping = _JsonMapping.of(type, element, function);
    final defaultValue = hasDefault
        ? _defaultLiteral(element.computeConstantValue(), mapping)
        : null;
    final schemaArguments = [
      ...mapping.schemaArguments,
      if (description != null) 'description: ${_literal(description)}',
      if (defaultValue != null && mapping.acceptsDefault)
        'defaultValue: $defaultValue',
    ];
    final schema = '${mapping.schemaFactory}(${schemaArguments.join(', ')})';

    // A missing optional argument must fall back to the Dart default, which
    // cannot be expressed by omitting a named argument conditionally — so the
    // default's source is repeated here.
    final String read;
    if (isRequired) {
      read = mapping.convert('invocation.arguments[$key]');
    } else {
      // A constant default is repeated as a literal where possible: its source
      // may name a private or static member that is not in scope in the
      // generated code.
      final fallback = hasDefault
          ? _constantLiteral(element.computeConstantValue()) ??
                element.defaultValueCode!
          : 'null';
      read =
          '(invocation.arguments[$key] == null ? $fallback : '
          '${mapping.convert('invocation.arguments[$key]')})';
    }
    return _ParameterModel(
      element: element,
      schema: schema,
      readExpression: read,
      isRequired: isRequired,
      isInjected: false,
    );
  }

  final FormalParameterElement element;
  final String schema;
  final String readExpression;
  final bool isRequired;
  final bool isInjected;
}

/// A Dart type's JSON schema, and how to convert a decoded JSON value to it.
final class _JsonMapping {
  _JsonMapping({
    required this.schemaFactory,
    required this.convert,
    this.schemaArguments = const <String>[],
    this.acceptsDefault = false,
  });

  factory _JsonMapping.of(
    DartType type,
    FormalParameterElement parameter,
    ExecutableElement function,
  ) {
    final display = type.getDisplayString();
    if (type.isDartCoreString) {
      return _JsonMapping(
        schemaFactory: 'JsonSchema.string',
        convert: (v) => '($v as String)',
        acceptsDefault: true,
      );
    }
    if (type.isDartCoreInt) {
      return _JsonMapping(
        schemaFactory: 'JsonSchema.integer',
        convert: (v) => '($v as num).toInt()',
        acceptsDefault: true,
      );
    }
    if (type.isDartCoreDouble) {
      // JSON does not distinguish 3 from 3.0; a decoded 3 is an int, and
      // `as double` would reject it.
      return _JsonMapping(
        schemaFactory: 'JsonSchema.number',
        convert: (v) => '($v as num).toDouble()',
        acceptsDefault: true,
      );
    }
    if (type.isDartCoreNum) {
      return _JsonMapping(
        schemaFactory: 'JsonSchema.number',
        convert: (v) => '($v as num)',
        acceptsDefault: true,
      );
    }
    if (type.isDartCoreBool) {
      return _JsonMapping(
        schemaFactory: 'JsonSchema.boolean',
        convert: (v) => '($v as bool)',
        acceptsDefault: true,
      );
    }
    if (_dateTime.isExactlyType(type)) {
      return _JsonMapping(
        schemaFactory: 'JsonSchema.string',
        schemaArguments: const <String>["format: 'date-time'"],
        convert: (v) => 'DateTime.parse($v as String)',
      );
    }
    if (type is InterfaceType && type.element is EnumElement) {
      final enumElement = type.element as EnumElement;
      final values = enumElement.constants.map((c) => _literal(c.name!));
      final enumName = enumElement.name!;
      return _JsonMapping(
        schemaFactory: 'JsonSchema.enumeration',
        schemaArguments: <String>['<String>[${values.join(', ')}]'],
        convert: (v) => '$enumName.values.byName($v as String)',
      );
    }
    if (type is InterfaceType && type.isDartCoreList) {
      final item = _JsonMapping.of(
        type.typeArguments.single,
        parameter,
        function,
      );
      if (type.typeArguments.single.nullabilitySuffix ==
          NullabilitySuffix.question) {
        throw _unsupported(
          display,
          parameter,
          'list items must not be nullable',
        );
      }
      final itemType = type.typeArguments.single.getDisplayString();
      return _JsonMapping(
        schemaFactory: 'JsonSchema.array',
        schemaArguments: <String>[
          'items: ${item.schemaFactory}(${item.schemaArguments.join(', ')})',
        ],
        convert: (v) =>
            '<$itemType>[for (final item in $v as List<Object?>) '
            '${item.convert('item')}]',
      );
    }
    if (type is InterfaceType &&
        type.isDartCoreMap &&
        type.typeArguments.first.isDartCoreString &&
        (type.typeArguments.last is DynamicType ||
            type.typeArguments.last.isDartCoreObject)) {
      return _JsonMapping(
        schemaFactory: 'JsonSchema.anyObject',
        convert: (v) => '($v as Map<String, Object?>)',
      );
    }
    throw _unsupported(
      display,
      parameter,
      'supported types are String, int, double, num, bool, DateTime, enums, '
      'List of those, Map<String, Object?>, and the injected ToolInvocation, '
      'AgenticContext and CancellationToken',
    );
  }

  final String schemaFactory;
  final List<String> schemaArguments;
  final String Function(String value) convert;

  /// Whether the schema factory takes a `defaultValue:` of this type.
  final bool acceptsDefault;

  static InvalidGenerationSourceError _unsupported(
    String type,
    FormalParameterElement parameter,
    String detail,
  ) => InvalidGenerationSourceError(
    'Parameter `${parameter.name}` has type `$type`, which a model cannot '
    'send as JSON: $detail.',
    element: parameter,
  );
}

/// How a function's return value becomes a `ToolResult`.
enum _ReturnKind {
  text,
  toolResult,
  none,
  jsonMap,
  toJson,
  scalar,
  list;

  static _ReturnKind of(DartType type, ExecutableElement function) {
    if (type is VoidType || type.isDartCoreNull) return none;
    if (type.nullabilitySuffix == NullabilitySuffix.question) {
      throw InvalidGenerationSourceError(
        '`${function.name}` may return null. Say what the model should read '
        'when there is nothing: return a String such as "No order found." '
        'instead.',
        element: function,
      );
    }
    if (type.isDartCoreString) return text;
    if (_toolResult.isExactlyType(type)) return toolResult;
    if (type.isDartCoreInt ||
        type.isDartCoreDouble ||
        type.isDartCoreNum ||
        type.isDartCoreBool) {
      return scalar;
    }
    if (type is InterfaceType &&
        type.isDartCoreMap &&
        type.typeArguments.first.isDartCoreString) {
      return jsonMap;
    }
    if (type is InterfaceType && type.isDartCoreList) return list;
    if (type is InterfaceType) {
      final toJson = type.lookUpMethod('toJson', function.library);
      if (toJson != null &&
          toJson.formalParameters.every((p) => !p.isRequiredPositional) &&
          toJson.returnType is InterfaceType &&
          (toJson.returnType as InterfaceType).isDartCoreMap) {
        return _ReturnKind.toJson;
      }
    }
    throw InvalidGenerationSourceError(
      '`${function.name}` returns `${type.getDisplayString()}`, which cannot '
      'be shown to a model. Return a String, a ToolResult, a '
      'Map<String, Object?>, a List, a number or bool, a class with a '
      '`Map<String, Object?> toJson()`, or nothing.',
      element: function,
    );
  }

  List<String> render(String value) => switch (this) {
    text => ['    return ToolResult.success($value);'],
    toolResult => ['    return $value;'],
    none => ['    $value;', "    return ToolResult.success('Done.');"],
    scalar => ["    return ToolResult.success('\${$value}');"],
    jsonMap => ['    return ToolResult.json($value);'],
    toJson => ['    return ToolResult.json($value.toJson());'],
    list => ["    return ToolResult.json(<String, Object?>{'items': $value});"],
  };
}

(DartType, bool) _unwrapFuture(DartType type) {
  if (type is InterfaceType &&
      (type.isDartAsyncFuture || type.isDartAsyncFutureOr)) {
    return (type.typeArguments.single, true);
  }
  return (type, false);
}

String? _optionalString(ConstantReader reader, String field) {
  final value = reader.read(field);
  return value.isNull ? null : value.stringValue;
}

/// A doc comment's text without its `///` markers.
String? _docComment(String? raw) {
  if (raw == null) return null;
  return raw
      .split('\n')
      .map((line) => line.trim())
      .map((line) => line.startsWith('///') ? line.substring(3) : line)
      .map((line) => line.startsWith(' ') ? line.substring(1) : line)
      .join('\n')
      .trim();
}

/// `orderStatus` → `order_status`; `getURL` → `get_url`.
String _snakeCase(String name) => name
    .replaceAllMapped(RegExp('([a-z0-9])([A-Z])'), (m) => '${m[1]}_${m[2]}')
    .replaceAllMapped(RegExp('([A-Z]+)([A-Z][a-z])'), (m) => '${m[1]}_${m[2]}')
    .toLowerCase();

/// A Dart string literal for [value].
String _literal(String value) {
  final escaped = value
      .replaceAll(r'\', r'\\')
      .replaceAll("'", r"\'")
      .replaceAll(r'$', r'\$')
      .replaceAll('\n', r'\n')
      .replaceAll('\r', r'\r');
  return "'$escaped'";
}

/// A literal for a parameter's default, when the schema can carry it.
String? _defaultLiteral(DartObject? value, _JsonMapping mapping) {
  if (value == null || !mapping.acceptsDefault) return null;
  if (value.toStringValue() case final s?) return _literal(s);
  if (value.toBoolValue() case final b?) return '$b';
  if (value.toIntValue() case final i?) {
    return mapping.schemaFactory == 'JsonSchema.number'
        ? '${i.toDouble()}'
        : '$i';
  }
  if (value.toDoubleValue() case final d?) return '$d';
  return null;
}

String _timeoutArgument(ConstantReader timeout) {
  // A public field since Dart 3.x; older SDKs kept it private as `_duration`.
  final microseconds =
      (timeout.peek('inMicroseconds') ?? timeout.read('_duration')).intValue;
  return '  timeout: const Duration(microseconds: $microseconds),';
}

/// A Dart literal for a primitive constant, or `null` for anything else.
String? _constantLiteral(DartObject? value) {
  if (value == null) return null;
  if (value.isNull) return 'null';
  if (value.toStringValue() case final s?) return _literal(s);
  if (value.toBoolValue() case final b?) return '$b';
  if (value.toIntValue() case final i?) return '$i';
  if (value.toDoubleValue() case final d?) return '$d';
  return null;
}
