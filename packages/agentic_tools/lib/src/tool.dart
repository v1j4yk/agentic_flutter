/// The tool contract.
///
/// A tool is a capability an agent can invoke: search the web, read a file,
/// query a database, take a photo. The model chooses one and supplies
/// arguments; the framework validates those arguments, runs the tool, and hands
/// the result back for the next turn.
///
/// # The two halves of a tool
///
/// A tool is a [ToolSpec] — what the model is told — and a [Tool.call] — what
/// actually happens. Keeping them separate matters more than it first appears:
///
/// * the spec is serialised into every request, so it must be stable, cheap and
///   free of runtime state;
/// * the implementation needs a context, a cancellation token and I/O.
///
/// Merging them, as a single "function with a description" does, makes it
/// impossible to list a provider's available tools without constructing every
/// implementation — which on mobile means opening a camera, a database and a
/// Bluetooth adapter to answer a question about a schema.
library;

import 'package:agentic_core/agentic_core.dart';
import 'package:meta/meta.dart';

/// What a tool is called, what it does and what it accepts.
///
/// This is the object that becomes a function definition in a provider request.
/// Everything in it is written for the model, not for a human reading code.
@immutable
final class ToolSpec {
  /// Creates a specification.
  ///
  /// [name] must match `^[a-zA-Z0-9_-]{1,64}$`, the intersection of what
  /// OpenAI, Anthropic and Google accept. Validating at construction turns a
  /// provider-side 400 — which arrives at runtime, in production, with an
  /// unhelpful message — into an error at wiring time.
  ToolSpec({
    required this.name,
    required this.description,
    JsonSchema? parameters,
    this.returns,
    this.isReadOnly = true,
    this.isIdempotent = true,
    this.requiresApproval = false,
    Set<String> tags = const <String>{},
    this.timeout,
    this.version = '1.0.0',
    List<ToolExample> examples = const <ToolExample>[],
  }) : parameters = parameters ?? JsonSchema.object(),
       tags = Set<String>.unmodifiable(tags),
       examples = List<ToolExample>.unmodifiable(examples) {
    _validateName(name);
    if (description.trim().isEmpty) {
      throw ConfigurationException(
        'Tool `$name` has an empty description. The description is the only '
        'thing a model uses to decide whether to call this tool; without one '
        'it will be called at random or not at all.',
        setting: 'ToolSpec.description',
      );
    }
  }

  static final RegExp _namePattern = RegExp(r'^[a-zA-Z0-9_-]{1,64}$');

  /// Identifier the model uses to select this tool.
  ///
  /// Name tools after the action, in `snake_case`: `search_web`,
  /// `read_calendar`, `send_email`. A model picks tools largely by name, and
  /// `doThing` gives it nothing to go on.
  final String name;

  /// What the tool does, when to use it, and when not to.
  ///
  /// The single highest-leverage field for tool-calling accuracy. Say what it
  /// returns, name its limits, and state its cost:
  ///
  /// > Searches the public web and returns the top results with titles, URLs
  /// > and snippets. Use for current events and facts that may have changed.
  /// > Do not use for questions about the user's own documents — use
  /// > `search_documents` for those.
  final String description;

  /// Schema of the arguments the tool accepts.
  ///
  /// Defaults to an empty closed object, meaning the tool takes no arguments.
  final JsonSchema parameters;

  /// Schema of the tool's structured result, when it has one.
  ///
  /// Not sent to providers — none of them accept a return schema — but used to
  /// validate what a tool actually produced, and by workflow graph validation
  /// to check that one node's output can feed the next node's input.
  final JsonSchema? returns;

  /// Whether the tool only reads.
  ///
  /// Read-only tools can be run in parallel, retried freely and executed
  /// speculatively. This is the flag a supervising agent consults before
  /// deciding whether four calls can go at once.
  final bool isReadOnly;

  /// Whether running the tool twice with the same arguments is the same as
  /// running it once.
  ///
  /// Consulted by retry policies. A non-idempotent tool is never retried
  /// automatically, because the framework cannot know whether the first attempt
  /// already charged the card.
  final bool isIdempotent;

  /// Whether a human must approve each invocation.
  ///
  /// The mechanism behind human-in-the-loop. Set it on anything that spends
  /// money, sends a message, or changes state a user would want to see first.
  final bool requiresApproval;

  /// Free-form labels, used to select subsets of a registry.
  ///
  /// Presenting a model with forty tools measurably degrades its choices; tags
  /// are how an agent is given only the eight that matter for its job.
  final Set<String> tags;

  /// Per-invocation time budget, overriding the executor default.
  final Duration? timeout;

  /// Semantic version of this tool's contract.
  ///
  /// Recorded in traces so that a change in behaviour can be correlated with a
  /// change in the tool, rather than blamed on the model.
  final String version;

  /// Worked examples shown to the model.
  ///
  /// A single concrete example is often worth more than another paragraph of
  /// description, especially for tools with structured arguments.
  final List<ToolExample> examples;

  /// Serialises this spec as a provider-neutral function definition.
  ///
  /// Provider adapters reshape this into their own wire format. The shape here
  /// deliberately matches the most widely adopted one — `{name, description,
  /// parameters}` — so most adapters need no reshaping at all.
  JsonMap toFunctionJson() => <String, Object?>{
    'name': name,
    'description': _describedForModel(),
    'parameters': parameters.toJson(),
  };

  /// Serialises the complete spec, including fields providers do not accept.
  JsonMap toJson() => pruneNulls(<String, Object?>{
    'name': name,
    'description': description,
    'parameters': parameters.toJson(),
    'returns': returns?.toJson(),
    'isReadOnly': isReadOnly,
    'isIdempotent': isIdempotent,
    'requiresApproval': requiresApproval,
    'tags': tags.isEmpty ? null : (tags.toList()..sort()),
    'timeoutMs': timeout?.inMilliseconds,
    'version': version,
    'examples': examples.isEmpty
        ? null
        : examples.map((e) => e.toJson()).toList(),
  });

  /// Returns a copy with selected fields replaced.
  ToolSpec copyWith({
    String? name,
    String? description,
    JsonSchema? parameters,
    JsonSchema? returns,
    bool? isReadOnly,
    bool? isIdempotent,
    bool? requiresApproval,
    Set<String>? tags,
    Duration? timeout,
    String? version,
    List<ToolExample>? examples,
  }) => ToolSpec(
    name: name ?? this.name,
    description: description ?? this.description,
    parameters: parameters ?? this.parameters,
    returns: returns ?? this.returns,
    isReadOnly: isReadOnly ?? this.isReadOnly,
    isIdempotent: isIdempotent ?? this.isIdempotent,
    requiresApproval: requiresApproval ?? this.requiresApproval,
    tags: tags ?? this.tags,
    timeout: timeout ?? this.timeout,
    version: version ?? this.version,
    examples: examples ?? this.examples,
  );

  /// Appends rendered examples to the description sent to the model.
  String _describedForModel() {
    if (examples.isEmpty) return description;
    final buffer = StringBuffer(description)..write('\n\nExamples:');
    for (final example in examples) {
      buffer.write('\n- ${example.render()}');
    }
    return buffer.toString();
  }

  static void _validateName(String name) {
    if (_namePattern.hasMatch(name)) return;
    throw ConfigurationException(
      'Tool name `$name` is not usable. Names must be 1-64 characters of '
      'letters, digits, underscores or hyphens — the intersection of what '
      'OpenAI, Anthropic and Google accept. A name outside that set is '
      'rejected by the provider at request time, not here.',
      setting: 'ToolSpec.name',
    );
  }

  @override
  String toString() => 'ToolSpec($name v$version)';
}

/// A worked example of calling a tool.
@immutable
final class ToolExample {
  /// Creates an example.
  ToolExample({
    required this.situation,
    required Map<String, Object?> arguments,
    this.result,
  }) : arguments = Map<String, Object?>.unmodifiable(arguments);

  /// What the user asked, in natural language.
  final String situation;

  /// The arguments that were the right response.
  final Map<String, Object?> arguments;

  /// What the tool returned, when showing it helps.
  final String? result;

  /// Renders the example as a line of prompt text.
  String render() {
    final rendered = arguments.entries
        .map((entry) => '${entry.key}: ${_encode(entry.value)}')
        .join(', ');
    final call = '"$situation" -> {$rendered}';
    return result == null ? call : '$call -> $result';
  }

  /// Serialises the example.
  JsonMap toJson() => pruneNulls(<String, Object?>{
    'situation': situation,
    'arguments': arguments,
    'result': result,
  });

  static String _encode(Object? value) =>
      value is String ? '"$value"' : '$value';
}

/// One request to run a tool.
///
/// Carries validated arguments and the run context, so a tool implementation
/// never has to reach for a global to find its logger or its cancellation
/// token.
@immutable
final class ToolInvocation {
  /// Creates an invocation.
  ToolInvocation({
    required this.callId,
    required this.toolName,
    required this.context,
    Map<String, Object?> arguments = const <String, Object?>{},
    this.rawArguments,
  }) : arguments = Map<String, Object?>.unmodifiable(arguments);

  /// Identifier correlating this call with its result.
  final String callId;

  /// Name the tool was invoked under.
  final String toolName;

  /// Arguments, already coerced and validated against the spec.
  ///
  /// A tool implementation may read these without defensive checks: if it is
  /// running at all, the arguments conformed.
  final Map<String, Object?> arguments;

  /// The argument JSON exactly as the model produced it.
  final String? rawArguments;

  /// Run context: logger, events, tracer, clock and cancellation.
  final AgenticContext context;

  /// Cancellation signal for this invocation.
  ///
  /// Long-running tools must check this. A tool that ignores it keeps a phone's
  /// radio awake after the user has left the screen.
  CancellationToken get cancellation => context.cancellation;

  /// Reads a required argument.
  ///
  /// Safe because arguments were validated, so a failure here means the spec
  /// and the implementation disagree — which is a programming error worth
  /// surfacing loudly.
  T require<T>(String key) {
    final value = arguments[key];
    if (value is T) return value;
    throw ToolExecutionException(
      'Tool `$toolName` read argument `$key` as $T, but it is '
      '${value.runtimeType}. The tool\'s schema and its implementation '
      'disagree.',
      toolName: toolName,
    );
  }

  /// Reads an optional argument, returning [orElse] when absent.
  T optional<T>(String key, T orElse) {
    final value = arguments[key];
    return value is T ? value : orElse;
  }

  @override
  String toString() => 'ToolInvocation($toolName#$callId, $arguments)';
}

/// What a tool produced.
///
/// Both success and failure are *values*, not exceptions. That is the central
/// decision of this layer: a model told "no such file" can try a different
/// path, ask the user, or explain the problem. A thrown exception ends the run
/// and leaves the user with nothing. Only cancellation propagates as an error,
/// because there is nobody left to tell.
@immutable
final class ToolResult {
  const ToolResult._({
    required this.content,
    required this.isError,
    this.data,
    this.parts = const <ContentPart>[],
    this.metadata = const <String, Object?>{},
  });

  /// Creates a successful result.
  ///
  /// [content] is what the model reads, so write it for a reader: a compact
  /// rendering of the answer, not a debug dump. [data] carries the structured
  /// value for application code that wants the real object.
  factory ToolResult.success(
    String content, {
    Object? data,
    List<ContentPart> parts = const <ContentPart>[],
    Map<String, Object?> metadata = const <String, Object?>{},
  }) => ToolResult._(
    content: content,
    isError: false,
    data: data,
    parts: List<ContentPart>.unmodifiable(parts),
    metadata: Map<String, Object?>.unmodifiable(metadata),
  );

  /// Creates a successful result from structured [data].
  ///
  /// The JSON rendering becomes the model-visible content, which is the right
  /// default for tools whose output is a record rather than prose.
  factory ToolResult.json(
    Map<String, Object?> data, {
    Map<String, Object?> metadata = const <String, Object?>{},
  }) => ToolResult.success(_renderJson(data), data: data, metadata: metadata);

  /// Creates a failed result.
  ///
  /// [content] is read by the model, so say what went wrong *and* what it could
  /// do instead. "File not found: /a/b.txt. Use `list_files` to see what is
  /// available." recovers; "Error" does not.
  factory ToolResult.failure(
    String content, {
    Object? cause,
    Map<String, Object?> metadata = const <String, Object?>{},
  }) => ToolResult._(
    content: content,
    isError: true,
    data: cause,
    metadata: Map<String, Object?>.unmodifiable(metadata),
  );

  /// The model-visible rendering of the result.
  final String content;

  /// Whether the tool failed.
  final bool isError;

  /// The structured value, for application code.
  final Object? data;

  /// Rich content, for providers that accept multimodal tool results.
  final List<ContentPart> parts;

  /// Execution metadata such as timings, costs or a cache indicator.
  ///
  /// Never shown to the model; carried for logs, traces and UI.
  final Map<String, Object?> metadata;

  /// Converts this result into the message part sent back to the provider.
  ToolResultPart toPart({required String callId, required String toolName}) =>
      ToolResultPart(
        callId: callId,
        name: toolName,
        content: content,
        isError: isError,
        parts: parts,
      );

  /// Converts this result into a complete tool-role message.
  Message toMessage({required String callId, required String toolName}) =>
      Message(
        role: MessageRole.tool,
        parts: <ContentPart>[toPart(callId: callId, toolName: toolName)],
        metadata: metadata,
      );

  /// Returns a copy with [entries] merged into [metadata].
  ToolResult withMetadata(Map<String, Object?> entries) => ToolResult._(
    content: content,
    isError: isError,
    data: data,
    parts: parts,
    metadata: Map<String, Object?>.unmodifiable(<String, Object?>{
      ...metadata,
      ...entries,
    }),
  );

  /// Serialises the result.
  JsonMap toJson() => pruneNulls(<String, Object?>{
    'content': content,
    'isError': isError,
    'metadata': metadata.isEmpty ? null : metadata,
  });

  static String _renderJson(Map<String, Object?> data) {
    final buffer = StringBuffer('{');
    var first = true;
    for (final entry in data.entries) {
      if (!first) buffer.write(', ');
      first = false;
      buffer.write('"${entry.key}": ${_encodeValue(entry.value)}');
    }
    buffer.write('}');
    return buffer.toString();
  }

  static String _encodeValue(Object? value) => switch (value) {
    null => 'null',
    final String s => '"${s.replaceAll('"', r'\"')}"',
    final Map<String, Object?> m => _renderJson(m),
    final List<Object?> l => '[${l.map(_encodeValue).join(', ')}]',
    _ => value.toString(),
  };

  @override
  String toString() =>
      'ToolResult(${isError ? 'error' : 'ok'}, '
      '${content.length > 40 ? '${content.substring(0, 37)}...' : content})';
}

/// A capability an agent can invoke.
///
/// Implement this directly for stateful tools that own a resource — a database
/// handle, a camera, a socket. For everything else, `FunctionTool` wraps a
/// closure and is considerably less code.
///
/// ```dart
/// final class ReadFileTool implements Tool {
///   @override
///   late final ToolSpec spec = ToolSpec(
///     name: 'read_file',
///     description: 'Reads a UTF-8 text file and returns its contents.',
///     parameters: JsonSchema.object(
///       properties: {'path': JsonSchema.string(description: 'Absolute path')},
///       required: {'path'},
///     ),
///   );
///
///   @override
///   Future<ToolResult> call(ToolInvocation invocation) async {
///     final path = invocation.require<String>('path');
///     invocation.cancellation.throwIfCancelled(operation: 'read_file');
///     // ... read and return ToolResult.success(contents)
///   }
/// }
/// ```
abstract interface class Tool {
  /// What the model is told about this tool.
  ///
  /// Must be stable and cheap to read: it is accessed once per request, and
  /// building it must not touch I/O.
  ToolSpec get spec;

  /// Runs the tool.
  ///
  /// Contract:
  ///
  /// * Return [ToolResult.failure] for expected failures. Do not throw for
  ///   them — a returned failure lets the model recover, a thrown one ends the
  ///   run.
  /// * Let [CancelledException] propagate. Never swallow it.
  /// * Honour [ToolInvocation.cancellation] in anything long-running.
  /// * Do not validate arguments; the executor already did.
  Future<ToolResult> call(ToolInvocation invocation);
}
