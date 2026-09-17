/// Recorded model conversations, and how a request is matched against them.
///
/// # Why record at the model boundary
///
/// An agent test that calls a real provider is slow, costs money, needs a key
/// in CI, and fails when the model has a different day. A test against a
/// hand-written fake is fast and free, but proves only that the agent handles
/// the answers its author imagined.
///
/// A cassette is the middle: real answers, captured once from a real model,
/// replayed offline forever after. The agent's prompts, tool schemas and
/// message handling are exercised against what a provider actually returned.
///
/// # What makes a request "the same"
///
/// Everything that reaches the provider and shapes the answer: the messages,
/// the tools, the sampling settings, the response format. Not the things that
/// change on every run without changing the question — message identifiers,
/// timestamps, application metadata. When a prompt or a tool description
/// changes, replay fails and says where, which is exactly when a recording
/// should be refreshed.
library;

import 'dart:convert';

import 'package:agentic_core/agentic_core.dart';
import 'package:agentic_llm/agentic_llm.dart';
import 'package:meta/meta.dart';

/// Rewrites a string before it is written to a cassette.
///
/// Applied to every string value in both the request and the response — not
/// to JSON keys — so a secret, an email address or a customer name never
/// reaches a file that is committed to version control. Replay applies the same
/// function to the live request before matching, so redacted text still
/// matches.
typedef Redactor = String Function(String text);

/// The file format identifier, checked on load.
const String _format = 'agentic_cassette';

/// The newest cassette format version this package reads and writes.
const int _version = 1;

/// One recorded exchange: what was asked, and what came back.
@immutable
final class CassetteInteraction {
  /// Creates an interaction from its already-canonical JSON.
  const CassetteInteraction({required this.request, required this.response});

  /// Restores an interaction from a cassette file.
  factory CassetteInteraction.fromJson(JsonMap json) => CassetteInteraction(
    request: json.requireObject('request'),
    response: json.requireObject('response'),
  );

  /// The request, in the canonical form produced by [canonicalRequest].
  final JsonMap request;

  /// The response, in the form produced by [encodeResponse].
  final JsonMap response;

  /// The recorded answer.
  ChatResponse get chatResponse => decodeResponse(response);

  /// Serialises the interaction.
  JsonMap toJson() => <String, Object?>{
    'request': request,
    'response': response,
  };
}

/// A sequence of recorded model exchanges, and the model that produced them.
final class Cassette {
  /// Creates a cassette.
  Cassette({
    required this.model,
    List<CassetteInteraction> interactions = const <CassetteInteraction>[],
  }) : _interactions = List<CassetteInteraction>.of(interactions);

  /// Restores a cassette from its JSON form.
  ///
  /// Throws a [SerializationException] for a file that is not a cassette, or
  /// that was written by a newer version of this package — replaying a format
  /// this version does not understand would produce confusing mismatches
  /// rather than an honest error.
  factory Cassette.fromJson(JsonMap json) {
    if (json['format'] != _format) {
      throw SerializationException(
        'Not an agentic cassette: the `format` field is '
        '`${json['format']}`, expected `$_format`.',
      );
    }
    final version = json.requireInt('version');
    if (version > _version) {
      throw SerializationException(
        'This cassette was written in format version $version, and this '
        'version of agentic_test reads up to $_version. Upgrade agentic_test, '
        'or record the cassette again.',
      );
    }
    return Cassette(
      model: decodeModelInfo(json.requireObject('model')),
      interactions: json
          .decodeList('interactions', CassetteInteraction.fromJson)
          .toList(),
    );
  }

  /// Parses a cassette from the text of a file.
  factory Cassette.parse(String source) {
    final Object? decoded;
    try {
      decoded = jsonDecode(source);
    } on FormatException catch (error, stackTrace) {
      throw SerializationException(
        'The cassette is not valid JSON.',
        cause: error,
        causeStackTrace: stackTrace,
      );
    }
    if (decoded is! Map) {
      throw SerializationException('A cassette must be a JSON object.');
    }
    return Cassette.fromJson(decoded.cast<String, Object?>());
  }

  /// The model the interactions were recorded from.
  ///
  /// Replayed as the replaying model's `info`, so capability checks — does it
  /// support structured output, tool calling, vision — take the same branches
  /// they took while recording.
  final ModelInfo model;

  final List<CassetteInteraction> _interactions;

  /// The recorded exchanges, in the order they completed.
  List<CassetteInteraction> get interactions =>
      List<CassetteInteraction>.unmodifiable(_interactions);

  /// Appends an exchange.
  void add(CassetteInteraction interaction) => _interactions.add(interaction);

  /// Serialises the cassette.
  JsonMap toJson() => <String, Object?>{
    'format': _format,
    'version': _version,
    'model': encodeModelInfo(model),
    'interactions': _interactions.map((i) => i.toJson()).toList(),
  };

  /// The cassette as file text: indented, so a diff in review is readable.
  String encode() =>
      '${const JsonEncoder.withIndent('  ').convert(toJson())}\n';
}

/// Thrown when a replayed request matches nothing in the cassette.
///
/// An [Error], not an exception: it means the code under test now asks the
/// model something it did not ask when the cassette was recorded. The fix is to
/// record again or to find the unintended change — never to catch this.
final class CassetteMismatchError extends Error {
  /// Creates the error.
  CassetteMismatchError(this.message);

  /// What was asked, and how it differs from the nearest recording.
  final String message;

  @override
  String toString() => 'CassetteMismatchError: $message';
}

/// The canonical form of [request] used for recording and matching.
///
/// Keeps what reaches the provider and shapes the answer; drops message
/// identifiers, timestamps and metadata, which differ between runs of the same
/// test. [redact] is applied to every string value.
JsonMap canonicalRequest(ChatRequest request, {Redactor? redact}) {
  final format = request.responseFormat;
  final json = pruneNulls(<String, Object?>{
    'messages': <Object?>[
      for (final message in request.messages)
        pruneNulls(<String, Object?>{
          'role': message.role.wireName,
          'name': message.name,
          'parts': message.parts.map((part) => part.toJson()).toList(),
        }),
    ],
    'tools': request.tools?.specs.map((s) => s.toFunctionJson()).toList(),
    'toolChoice': request.toolChoice == ToolChoice.auto
        ? null
        : request.toolChoice.toString(),
    'temperature': request.temperature,
    'topP': request.topP,
    'topK': request.topK,
    'maxOutputTokens': request.maxOutputTokens,
    'stopSequences': request.stopSequences.isEmpty
        ? null
        : request.stopSequences,
    'seed': request.seed,
    'responseFormat': format.kind == ResponseFormatKind.text
        ? null
        : pruneNulls(<String, Object?>{
            'kind': format.kind.name,
            'name': format.schemaName,
            'schema': format.schema?.toJson(),
          }),
    'reasoningEffort': request.reasoningEffort?.name,
    'frequencyPenalty': request.frequencyPenalty,
    'presencePenalty': request.presencePenalty,
    'providerOptions': request.providerOptions.isEmpty
        ? null
        : request.providerOptions,
  });
  return redact == null ? json : redactJson(json, redact);
}

/// The recorded form of [response].
///
/// Drops the raw provider payload, which can be large and can echo request
/// headers; latency, which differs on every run and would make every
/// re-recording a noisy diff; and metadata, which belongs to the request.
JsonMap encodeResponse(ChatResponse response, {Redactor? redact}) {
  final json = pruneNulls(<String, Object?>{
    'message': response.message.toJson(),
    'modelId': response.modelId,
    'usage': response.usage.isEmpty ? null : response.usage.toJson(),
    'finishReason': response.finishReason.name,
    'requestId': response.requestId,
    'cost': response.cost,
  });
  return redact == null ? json : redactJson(json, redact);
}

/// Restores a response recorded by [encodeResponse].
ChatResponse decodeResponse(JsonMap json) => ChatResponse(
  message: Message.fromJson(json.requireObject('message')),
  modelId: json.requireString('modelId'),
  usage: switch (json.optionalObject('usage')) {
    final usage? => TokenUsage.fromJson(usage),
    null => TokenUsage.empty,
  },
  finishReason: json.requireEnum('finishReason', <String, FinishReason>{
    for (final reason in FinishReason.values) reason.name: reason,
  }, orElse: FinishReason.unknown),
  requestId: json.optionalString('requestId'),
  cost: json.optionalDouble('cost'),
);

/// Serialises the parts of [info] that change how a model is used.
JsonMap encodeModelInfo(ModelInfo info) => pruneNulls(<String, Object?>{
  'id': info.id,
  'provider': info.provider,
  'capabilities': (info.capabilities.map((c) => c.name).toList()..sort()),
  'contextWindow': info.contextWindow,
  'maxOutputTokens': info.maxOutputTokens,
  'isLocal': info.isLocal ? true : null,
});

/// Restores model information written by [encodeModelInfo].
///
/// A capability this version does not know is skipped rather than failing the
/// load: a cassette recorded with a newer agentic_llm should still replay.
ModelInfo decodeModelInfo(JsonMap json) {
  final known = <String, ModelCapability>{
    for (final capability in ModelCapability.values)
      capability.name: capability,
  };
  return ModelInfo(
    id: json.requireString('id'),
    provider: json.requireString('provider'),
    capabilities: <ModelCapability>{
      for (final name in json.stringListOrEmpty('capabilities')) ?known[name],
    },
    contextWindow: json.optionalInt('contextWindow'),
    maxOutputTokens: json.optionalInt('maxOutputTokens'),
    isLocal: json.boolOr('isLocal', orElse: false),
  );
}

/// Applies [redact] to every string value in [json], recursively.
JsonMap redactJson(JsonMap json, Redactor redact) =>
    (_redact(json, redact)! as Map).cast<String, Object?>();

Object? _redact(Object? value, Redactor redact) => switch (value) {
  final String text => redact(text),
  final Map<Object?, Object?> map => <String, Object?>{
    for (final entry in map.entries)
      entry.key! as String: _redact(entry.value, redact),
  },
  final List<Object?> list => <Object?>[
    for (final item in list) _redact(item, redact),
  ],
  _ => value,
};

/// Describes how [actual] differs from [recorded], in one short paragraph.
///
/// Walks both structures and reports the first path where they diverge, which
/// is almost always the answer to "what did I change" — a reworded system
/// prompt, a tool description, one more message in the history.
String describeRequestDifference(JsonMap recorded, JsonMap actual) {
  final path = _firstDifference(recorded, actual, r'$');
  if (path == null) return 'The requests are identical.';
  return 'First difference at ${path.$1}:\n'
      '  recorded: ${_preview(path.$2)}\n'
      '  actual:   ${_preview(path.$3)}';
}

(String, Object?, Object?)? _firstDifference(
  Object? a,
  Object? b,
  String path,
) {
  if (a is Map && b is Map) {
    final keys = <Object?>{...a.keys, ...b.keys};
    for (final key in keys) {
      if (!a.containsKey(key) || !b.containsKey(key)) {
        return ('$path.$key', a[key], b[key]);
      }
      final found = _firstDifference(a[key], b[key], '$path.$key');
      if (found != null) return found;
    }
    return null;
  }
  if (a is List && b is List) {
    final shared = a.length < b.length ? a.length : b.length;
    for (var i = 0; i < shared; i++) {
      final found = _firstDifference(a[i], b[i], '$path[$i]');
      if (found != null) return found;
    }
    if (a.length != b.length) {
      return ('$path.length', a.length, b.length);
    }
    return null;
  }
  return a == b ? null : (path, a, b);
}

String _preview(Object? value) {
  if (value == null) return '(absent)';
  final text = value is String ? jsonEncode(value) : jsonEncode(value);
  return text.length <= 160 ? text : '${text.substring(0, 157)}...';
}

/// Encodes [json] with object keys sorted, for comparing requests.
///
/// Key order carries no meaning in JSON, but `jsonEncode` preserves it, so two
/// equal maps built in a different order would otherwise compare unequal.
String canonicalJsonKey(Object? json) => jsonEncode(_sorted(json));

Object? _sorted(Object? value) => switch (value) {
  final Map<Object?, Object?> map => <String, Object?>{
    for (final key in (map.keys.map((k) => k! as String).toList()..sort()))
      key: _sorted(map[key]),
  },
  final List<Object?> list => <Object?>[for (final item in list) _sorted(item)],
  _ => value,
};
