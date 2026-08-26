/// What a server offers: tools, resources and prompts.
library;

import 'package:agentic_core/agentic_core.dart';
import 'package:agentic_mcp/src/protocol/mcp_content.dart';
import 'package:meta/meta.dart';

/// A tool as the server describes it.
@immutable
final class McpToolDescriptor {
  /// Describes a tool.
  const McpToolDescriptor({
    required this.name,
    required this.inputSchema,
    this.title,
    this.description,
    this.outputSchema,
    this.annotations = const McpToolAnnotations(),
  });

  /// Reads a tool descriptor.
  factory McpToolDescriptor.fromJson(JsonMap json) {
    final input = json.optionalObject('inputSchema');
    return McpToolDescriptor(
      name: json.requireString('name'),
      title: json.optionalString('title'),
      description: json.optionalString('description'),
      // A tool with no schema takes no arguments. `anyObject` rather than
      // `object()`, because a closed empty object matches only `{}` and would
      // reject a server that sends a field this client has not modelled.
      inputSchema: input == null
          ? JsonSchema.anyObject()
          : JsonSchema.fromJson(input),
      outputSchema: json.optionalObject('outputSchema') == null
          ? null
          : JsonSchema.fromJson(json.requireObject('outputSchema')),
      annotations: McpToolAnnotations.fromJson(
        json.optionalObject('annotations') ?? const <String, Object?>{},
      ),
    );
  }

  /// The name used to call it.
  final String name;

  /// A human-readable name, when the server supplied one.
  final String? title;

  /// What the tool does, as the model will be told.
  final String? description;

  /// The argument schema.
  final JsonSchema inputSchema;

  /// The result schema, when the server declares one.
  final JsonSchema? outputSchema;

  /// Behavioural hints.
  final McpToolAnnotations annotations;

  /// Serialises the descriptor.
  JsonMap toJson() => pruneNulls(<String, Object?>{
    'name': name,
    'title': title,
    'description': description,
    'inputSchema': inputSchema.toJson(),
    'outputSchema': outputSchema?.toJson(),
    'annotations': annotations.isEmpty ? null : annotations.toJson(),
  });

  @override
  String toString() => 'McpToolDescriptor($name)';
}

/// Hints a server gives about how a tool behaves.
///
/// # Why these are hints and not guarantees
///
/// The specification is explicit that annotations are advisory: they come from
/// the server, and a client must not make a security decision on them alone.
/// This package treats them accordingly — they inform defaults (a destructive
/// tool gets approval turned on) but never relax anything the caller asked for.
@immutable
final class McpToolAnnotations {
  /// Creates annotations.
  const McpToolAnnotations({
    this.title,
    this.readOnlyHint,
    this.destructiveHint,
    this.idempotentHint,
    this.openWorldHint,
  });

  /// Reads annotations.
  factory McpToolAnnotations.fromJson(JsonMap json) => McpToolAnnotations(
    title: json.optionalString('title'),
    readOnlyHint: json.optionalBool('readOnlyHint'),
    destructiveHint: json.optionalBool('destructiveHint'),
    idempotentHint: json.optionalBool('idempotentHint'),
    openWorldHint: json.optionalBool('openWorldHint'),
  );

  /// A display name for the tool.
  final String? title;

  /// Whether the tool only reads.
  final bool? readOnlyHint;

  /// Whether it may destroy something.
  final bool? destructiveHint;

  /// Whether calling it twice is the same as calling it once.
  final bool? idempotentHint;

  /// Whether it touches the world outside the server.
  final bool? openWorldHint;

  /// Whether the server said anything at all.
  bool get isEmpty =>
      title == null &&
      readOnlyHint == null &&
      destructiveHint == null &&
      idempotentHint == null &&
      openWorldHint == null;

  /// Serialises the annotations.
  JsonMap toJson() => pruneNulls(<String, Object?>{
    'title': title,
    'readOnlyHint': readOnlyHint,
    'destructiveHint': destructiveHint,
    'idempotentHint': idempotentHint,
    'openWorldHint': openWorldHint,
  });

  @override
  String toString() => 'McpToolAnnotations(${toJson()})';
}

/// What a tool call returned.
@immutable
final class McpToolCallResult {
  /// Creates a result.
  McpToolCallResult({
    List<Object?> content = const <Object?>[],
    this.isError = false,
    this.structuredContent,
  }) : content = List<Object?>.unmodifiable(content);

  /// Reads a tool result.
  factory McpToolCallResult.fromJson(JsonMap json) => McpToolCallResult(
    content: json['content'] is List
        ? json['content']! as List<Object?>
        : const <Object?>[],
    isError: json.boolOr('isError', orElse: false),
    structuredContent: json.optionalObject('structuredContent'),
  );

  /// The raw MCP content blocks.
  final List<Object?> content;

  /// Whether the tool reported a failure.
  ///
  /// A protocol-level success carrying `isError: true` — the tool ran and went
  /// wrong. That distinction matters: a failed tool is something the model can
  /// see and recover from, while a transport failure is not.
  final bool isError;

  /// A structured result, when the server declared an output schema.
  final JsonMap? structuredContent;

  /// The content rendered as the text a model reads.
  String get text => renderMcpContent(content);

  /// The content as framework content parts.
  List<ContentPart> get parts => contentPartsFromMcp(content);

  /// Serialises the result.
  JsonMap toJson() => pruneNulls(<String, Object?>{
    'content': content,
    'isError': isError ? true : null,
    'structuredContent': structuredContent,
  });

  @override
  String toString() =>
      'McpToolCallResult(${content.length} block(s)'
      '${isError ? ', error' : ''})';
}

/// Something a server can be asked to read.
@immutable
final class McpResource {
  /// Describes a resource.
  const McpResource({
    required this.uri,
    required this.name,
    this.title,
    this.description,
    this.mimeType,
    this.size,
  });

  /// Reads a resource descriptor.
  factory McpResource.fromJson(JsonMap json) => McpResource(
    uri: json.requireString('uri'),
    name: json.stringOr('name', json.stringOr('uri', 'resource')),
    title: json.optionalString('title'),
    description: json.optionalString('description'),
    mimeType: json.optionalString('mimeType'),
    size: json.optionalInt('size'),
  );

  /// Its address.
  final String uri;

  /// A machine-readable name.
  final String name;

  /// A human-readable name.
  final String? title;

  /// What it contains.
  final String? description;

  /// Its media type.
  final String? mimeType;

  /// Its size in bytes, when the server knows.
  final int? size;

  /// The name to show a person.
  String get displayName => title ?? name;

  /// Serialises the descriptor.
  JsonMap toJson() => pruneNulls(<String, Object?>{
    'uri': uri,
    'name': name,
    'title': title,
    'description': description,
    'mimeType': mimeType,
    'size': size,
  });

  @override
  String toString() => 'McpResource($uri)';
}

/// A family of resources addressed by a URI template.
@immutable
final class McpResourceTemplate {
  /// Describes a template.
  const McpResourceTemplate({
    required this.uriTemplate,
    required this.name,
    this.title,
    this.description,
    this.mimeType,
  });

  /// Reads a template descriptor.
  factory McpResourceTemplate.fromJson(JsonMap json) => McpResourceTemplate(
    uriTemplate: json.requireString('uriTemplate'),
    name: json.stringOr('name', 'template'),
    title: json.optionalString('title'),
    description: json.optionalString('description'),
    mimeType: json.optionalString('mimeType'),
  );

  /// An RFC 6570 template, such as `file:///{path}`.
  final String uriTemplate;

  /// A machine-readable name.
  final String name;

  /// A human-readable name.
  final String? title;

  /// What the family contains.
  final String? description;

  /// The media type its members share.
  final String? mimeType;

  /// Fills the template's `{placeholders}` from [values].
  ///
  /// Deliberately a simple substitution rather than a full RFC 6570
  /// implementation: MCP servers overwhelmingly use plain `{name}` expansion,
  /// and values are percent-encoded so a path containing a space produces a
  /// valid URI rather than a confusing 404.
  String expand(Map<String, String> values) {
    var uri = uriTemplate;
    for (final entry in values.entries) {
      uri = uri.replaceAll('{${entry.key}}', Uri.encodeComponent(entry.value));
    }
    return uri;
  }

  /// Serialises the descriptor.
  JsonMap toJson() => pruneNulls(<String, Object?>{
    'uriTemplate': uriTemplate,
    'name': name,
    'title': title,
    'description': description,
    'mimeType': mimeType,
  });

  @override
  String toString() => 'McpResourceTemplate($uriTemplate)';
}

/// The contents of one resource.
@immutable
final class McpResourceContents {
  /// Creates resource contents.
  const McpResourceContents({
    required this.uri,
    this.mimeType,
    this.text,
    this.blob,
  });

  /// Reads resource contents.
  factory McpResourceContents.fromJson(JsonMap json) => McpResourceContents(
    uri: json.stringOr('uri', ''),
    mimeType: json.optionalString('mimeType'),
    text: json.optionalString('text'),
    blob: json.optionalString('blob'),
  );

  /// Where it came from.
  final String uri;

  /// Its media type.
  final String? mimeType;

  /// Text contents, for a textual resource.
  final String? text;

  /// Base64 contents, for a binary one.
  final String? blob;

  /// Whether this is text rather than binary.
  bool get isText => text != null;

  /// Serialises the contents.
  JsonMap toJson() => pruneNulls(<String, Object?>{
    'uri': uri,
    'mimeType': mimeType,
    'text': text,
    'blob': blob,
  });

  @override
  String toString() =>
      'McpResourceContents($uri, ${isText ? 'text' : 'binary'})';
}

/// A prompt template a server offers.
@immutable
final class McpPrompt {
  /// Describes a prompt.
  McpPrompt({
    required this.name,
    this.title,
    this.description,
    List<McpPromptArgument> arguments = const <McpPromptArgument>[],
  }) : arguments = List<McpPromptArgument>.unmodifiable(arguments);

  /// Reads a prompt descriptor.
  factory McpPrompt.fromJson(JsonMap json) => McpPrompt(
    name: json.requireString('name'),
    title: json.optionalString('title'),
    description: json.optionalString('description'),
    arguments: <McpPromptArgument>[
      for (final argument in json.listOrEmpty('arguments'))
        if (argument is Map)
          McpPromptArgument.fromJson(argument.cast<String, Object?>()),
    ],
  );

  /// The name used to render it.
  final String name;

  /// A human-readable name.
  final String? title;

  /// What the prompt is for.
  final String? description;

  /// What it needs to be rendered.
  final List<McpPromptArgument> arguments;

  /// The names that must be supplied.
  List<String> get requiredArguments => <String>[
    for (final argument in arguments)
      if (argument.required) argument.name,
  ];

  /// Serialises the descriptor.
  JsonMap toJson() => pruneNulls(<String, Object?>{
    'name': name,
    'title': title,
    'description': description,
    'arguments': arguments.isEmpty
        ? null
        : arguments.map((a) => a.toJson()).toList(),
  });

  @override
  String toString() => 'McpPrompt($name)';
}

/// One argument of a prompt template.
@immutable
final class McpPromptArgument {
  /// Describes an argument.
  const McpPromptArgument({
    required this.name,
    this.title,
    this.description,
    this.required = false,
  });

  /// Reads an argument descriptor.
  factory McpPromptArgument.fromJson(JsonMap json) => McpPromptArgument(
    name: json.requireString('name'),
    title: json.optionalString('title'),
    description: json.optionalString('description'),
    required: json.boolOr('required', orElse: false),
  );

  /// Its name.
  final String name;

  /// A human-readable name.
  final String? title;

  /// What it means.
  final String? description;

  /// Whether it must be supplied.
  // ignore: avoid_positional_boolean_parameters
  final bool required;

  /// Serialises the descriptor.
  JsonMap toJson() => pruneNulls(<String, Object?>{
    'name': name,
    'title': title,
    'description': description,
    'required': required ? true : null,
  });

  @override
  String toString() => 'McpPromptArgument($name${required ? '*' : ''})';
}
