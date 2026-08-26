/// The Model Context Protocol vocabulary: versions, methods, capabilities.
///
/// # Why the method names are constants
///
/// `tools/call` appears in the client, in the server, in three tests and in a
/// log filter. A typo in any one of them produces a `methodNotFound` at
/// runtime against a server that is working perfectly. Naming them once turns
/// that into a compile error.
library;

import 'package:agentic_core/agentic_core.dart';
import 'package:meta/meta.dart';

/// Protocol revisions this package can speak, newest first.
///
/// Version negotiation is not a formality. A server answers `initialize` with
/// the version *it* chose, which may be older than the one asked for; a client
/// that ignores the answer and carries on sending newer fields gets confusing
/// failures several calls later, in code that looks unrelated.
const List<String> kSupportedProtocolVersions = <String>[
  '2025-06-18',
  '2025-03-26',
  '2024-11-05',
];

/// The revision this package proposes.
const String kLatestProtocolVersion = '2025-06-18';

/// Every method name in the protocol.
abstract final class McpMethod {
  /// Opens the session and negotiates capabilities.
  static const String initialize = 'initialize';

  /// Announces that the client is ready. A notification, not a request.
  static const String initialized = 'notifications/initialized';

  /// Checks that the peer is alive.
  static const String ping = 'ping';

  /// Lists the tools a server offers.
  static const String toolsList = 'tools/list';

  /// Invokes a tool.
  static const String toolsCall = 'tools/call';

  /// Lists readable resources.
  static const String resourcesList = 'resources/list';

  /// Lists parameterised resource templates.
  static const String resourceTemplatesList = 'resources/templates/list';

  /// Reads a resource.
  static const String resourcesRead = 'resources/read';

  /// Asks to be told when a resource changes.
  static const String resourcesSubscribe = 'resources/subscribe';

  /// Cancels such a subscription.
  static const String resourcesUnsubscribe = 'resources/unsubscribe';

  /// Lists prompt templates.
  static const String promptsList = 'prompts/list';

  /// Renders a prompt template.
  static const String promptsGet = 'prompts/get';

  /// Sets the server's log verbosity.
  static const String loggingSetLevel = 'logging/setLevel';

  /// A server asking the client to run a model. Client-implemented.
  static const String samplingCreateMessage = 'sampling/createMessage';

  /// A server asking the client which directories it may work in.
  static const String rootsList = 'roots/list';

  /// Abandons an in-flight request.
  static const String cancelled = 'notifications/cancelled';

  /// Reports progress on a long call.
  static const String progress = 'notifications/progress';

  /// The tool list changed.
  static const String toolListChanged = 'notifications/tools/list_changed';

  /// The resource list changed.
  static const String resourceListChanged =
      'notifications/resources/list_changed';

  /// A subscribed resource changed.
  static const String resourceUpdated = 'notifications/resources/updated';

  /// The prompt list changed.
  static const String promptListChanged = 'notifications/prompts/list_changed';

  /// A log line from the server.
  static const String loggingMessage = 'notifications/message';

  /// The client's roots changed.
  static const String rootsListChanged = 'notifications/roots/list_changed';
}

/// Who is speaking, and what version of it.
@immutable
final class McpImplementation {
  /// Names an implementation.
  const McpImplementation({
    required this.name,
    required this.version,
    this.title,
  });

  /// Restores an implementation from JSON.
  factory McpImplementation.fromJson(JsonMap json) => McpImplementation(
    name: json.stringOr('name', 'unknown'),
    version: json.stringOr('version', '0.0.0'),
    title: json.optionalString('title'),
  );

  /// A machine-readable name, such as `filesystem`.
  final String name;

  /// Its version.
  final String version;

  /// A human-readable name, when the peer supplied one.
  final String? title;

  /// The name to show a person.
  String get displayName => title ?? name;

  /// Serialises the implementation.
  JsonMap toJson() => pruneNulls(<String, Object?>{
    'name': name,
    'version': version,
    'title': title,
  });

  @override
  String toString() => '$name@$version';
}

/// What a peer says it can do.
///
/// # Why this is a value object rather than a map
///
/// Capabilities decide whether a call is worth making at all. Asking a server
/// without a `tools` capability for `tools/list` earns a `methodNotFound` that
/// looks like a bug in your code; checking first turns it into a decision.
///
/// Unknown capabilities are kept in [extra] rather than discarded, so a client
/// built against one revision can still report what a newer server offered.
@immutable
final class McpCapabilities {
  /// Declares capabilities.
  McpCapabilities({
    this.tools = false,
    this.resources = false,
    this.prompts = false,
    this.logging = false,
    this.sampling = false,
    this.roots = false,
    this.completions = false,
    this.toolListChanged = false,
    this.resourceListChanged = false,
    this.resourceSubscribe = false,
    this.promptListChanged = false,
    this.rootsListChanged = false,
    JsonMap extra = const <String, Object?>{},
  }) : extra = Map<String, Object?>.unmodifiable(extra);

  /// Reads a capabilities object.
  factory McpCapabilities.fromJson(JsonMap json) {
    final tools = json.optionalObject('tools');
    final resources = json.optionalObject('resources');
    final prompts = json.optionalObject('prompts');
    final roots = json.optionalObject('roots');
    const known = <String>{
      'tools',
      'resources',
      'prompts',
      'logging',
      'sampling',
      'roots',
      'completions',
      'experimental',
    };

    return McpCapabilities(
      // Presence, not truthiness: the specification uses an empty object to
      // mean "supported, with no sub-features", and `{} == false` in a naive
      // reading would disable every well-behaved server.
      tools: tools != null,
      resources: resources != null,
      prompts: prompts != null,
      logging: json.containsKey('logging'),
      sampling: json.containsKey('sampling'),
      roots: roots != null,
      completions: json.containsKey('completions'),
      toolListChanged: tools?['listChanged'] == true,
      resourceListChanged: resources?['listChanged'] == true,
      resourceSubscribe: resources?['subscribe'] == true,
      promptListChanged: prompts?['listChanged'] == true,
      rootsListChanged: roots?['listChanged'] == true,
      extra: <String, Object?>{
        for (final entry in json.entries)
          if (!known.contains(entry.key)) entry.key: entry.value,
      },
    );
  }

  /// Whether the peer offers tools.
  final bool tools;

  /// Whether it offers readable resources.
  final bool resources;

  /// Whether it offers prompt templates.
  final bool prompts;

  /// Whether it emits log messages.
  final bool logging;

  /// Whether it can ask the client to run a model.
  final bool sampling;

  /// Whether it exposes filesystem roots.
  final bool roots;

  /// Whether it offers argument completion.
  final bool completions;

  /// Whether the tool list can change mid-session.
  final bool toolListChanged;

  /// Whether the resource list can change mid-session.
  final bool resourceListChanged;

  /// Whether individual resources can be subscribed to.
  final bool resourceSubscribe;

  /// Whether the prompt list can change mid-session.
  final bool promptListChanged;

  /// Whether the client's roots can change mid-session.
  final bool rootsListChanged;

  /// Capabilities this package does not know about, kept verbatim.
  final JsonMap extra;

  /// Serialises the capabilities.
  JsonMap toJson() => <String, Object?>{
    if (tools)
      'tools': <String, Object?>{if (toolListChanged) 'listChanged': true},
    if (resources)
      'resources': <String, Object?>{
        if (resourceListChanged) 'listChanged': true,
        if (resourceSubscribe) 'subscribe': true,
      },
    if (prompts)
      'prompts': <String, Object?>{if (promptListChanged) 'listChanged': true},
    if (logging) 'logging': const <String, Object?>{},
    if (sampling) 'sampling': const <String, Object?>{},
    if (roots)
      'roots': <String, Object?>{if (rootsListChanged) 'listChanged': true},
    if (completions) 'completions': const <String, Object?>{},
    ...extra,
  };

  @override
  String toString() {
    final offered = <String>[
      if (tools) 'tools',
      if (resources) 'resources',
      if (prompts) 'prompts',
      if (logging) 'logging',
      if (sampling) 'sampling',
      if (roots) 'roots',
    ];
    return 'McpCapabilities(${offered.isEmpty ? 'none' : offered.join(', ')})';
  }
}

/// Picks the newest revision both sides understand.
///
/// Returns `null` when there is no overlap, which is a session that must not
/// open: continuing against an unknown revision produces failures that look
/// like bugs in whichever call happens to use a changed field first.
String? negotiateProtocolVersion(String serverVersion) =>
    kSupportedProtocolVersions.contains(serverVersion) ? serverVersion : null;
