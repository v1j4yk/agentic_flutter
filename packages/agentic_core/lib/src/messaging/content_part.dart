/// The pieces a message is made of.
///
/// A modern LLM message is not a string. It is a sequence of typed parts: text,
/// images, files, audio, the model's private reasoning, requests to call tools,
/// and the results of those calls. Modelling a message as `String` forces every
/// multimodal or tool-using feature to be bolted on later as a parallel field,
/// which is how most wrappers end up with `content`, `imageUrl`, `toolCalls`
/// and `functionCall` all describing the same turn.
///
/// [ContentPart] is `sealed`, unlike most extension points in this framework,
/// and that is a deliberate reversal. Every provider adapter must translate
/// every part into its own wire format. If a third party could add a part type,
/// adapters would silently drop it. Sealing the hierarchy means adding a part
/// type is a compile error in every adapter that has not handled it — which is
/// exactly the conversation that should happen when a new modality appears.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:agentic_core/src/common/json_reader.dart';
import 'package:agentic_core/src/common/json_types.dart';
import 'package:agentic_core/src/error/agentic_exception.dart';
import 'package:collection/collection.dart';
import 'package:meta/meta.dart';

/// One element of a message's content.
@immutable
sealed class ContentPart {
  /// Const-constructible base for every part.
  const ContentPart();

  /// Stable discriminator used in serialisation, such as `text` or `tool_call`.
  String get kind;

  /// Serialises this part, including its [kind].
  JsonMap toJson();

  /// Restores a part produced by [toJson].
  ///
  /// Throws a [SerializationException] for an unknown [kind], because silently
  /// dropping content would corrupt a stored conversation in a way that is
  /// invisible until a user notices a missing image.
  static ContentPart fromJson(JsonMap json) {
    final kind = json.requireString('kind');
    return switch (kind) {
      'text' => TextPart.fromJson(json),
      'reasoning' => ReasoningPart.fromJson(json),
      'image' => ImagePart.fromJson(json),
      'file' => FilePart.fromJson(json),
      'audio' => AudioPart.fromJson(json),
      'tool_call' => ToolCallPart.fromJson(json),
      'tool_result' => ToolResultPart.fromJson(json),
      _ => throw SerializationException(
        'Unknown content part kind `$kind`.',
        path: 'kind',
      ),
    };
  }
}

/// Plain text.
@immutable
final class TextPart extends ContentPart {
  /// Creates a text part.
  const TextPart(this.text);

  /// Restores a text part from JSON.
  factory TextPart.fromJson(JsonMap json) =>
      TextPart(json.requireString('text'));

  /// The text.
  final String text;

  @override
  String get kind => 'text';

  @override
  JsonMap toJson() => <String, Object?>{'kind': kind, 'text': text};

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is TextPart && text == other.text;

  @override
  int get hashCode => Object.hash(TextPart, text);

  @override
  String toString() => 'TextPart(${_preview(text)})';
}

/// The model's intermediate reasoning.
///
/// Reasoning models emit a private chain of thought alongside their answer.
/// It is kept as its own part rather than merged into [TextPart] for three
/// reasons: it must not be shown to the user by default, it must not be fed
/// back verbatim to a different provider, and some providers require their
/// [signature] to be returned unmodified for the reasoning to remain valid
/// across turns.
@immutable
final class ReasoningPart extends ContentPart {
  /// Creates a reasoning part.
  const ReasoningPart(this.text, {this.signature, this.isRedacted = false});

  /// Restores a reasoning part from JSON.
  factory ReasoningPart.fromJson(JsonMap json) => ReasoningPart(
    json.requireString('text'),
    signature: json.optionalString('signature'),
    isRedacted: json.boolOr('isRedacted', orElse: false),
  );

  /// The reasoning text, which may be a summary rather than the raw trace.
  final String text;

  /// Provider-issued integrity signature, to be echoed back verbatim.
  ///
  /// Never modify or synthesise this. A provider that receives an altered
  /// signature rejects the whole turn.
  final String? signature;

  /// Whether the provider redacted the content, leaving only a placeholder.
  final bool isRedacted;

  @override
  String get kind => 'reasoning';

  @override
  JsonMap toJson() => pruneNulls(<String, Object?>{
    'kind': kind,
    'text': text,
    'signature': signature,
    'isRedacted': isRedacted ? true : null,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ReasoningPart &&
          text == other.text &&
          signature == other.signature &&
          isRedacted == other.isRedacted;

  @override
  int get hashCode => Object.hash(ReasoningPart, text, signature, isRedacted);

  @override
  String toString() => 'ReasoningPart(${_preview(text)})';
}

/// Binary or remote content referenced by a message.
///
/// Every media part carries *either* inline [bytes] *or* a [uri], never both.
/// The distinction is load-bearing on mobile: a 4 MB photo inlined as base64
/// becomes a 5.3 MB request body that will fail on a poor connection, while a
/// URI costs a few dozen bytes but requires the provider to be able to reach it.
@immutable
sealed class MediaPart extends ContentPart {
  const MediaPart({this.bytes, this.uri, required this.mimeType})
    : assert(
        (bytes == null) != (uri == null),
        'A media part carries exactly one of `bytes` or `uri`.',
      );

  /// Inline content, when the media travels with the request.
  final Uint8List? bytes;

  /// Location of the content, when the provider fetches it.
  final Uri? uri;

  /// IANA media type, such as `image/png`.
  ///
  /// Required rather than inferred: providers reject unrecognised or
  /// mismatched types, and sniffing from a file extension is wrong often
  /// enough to matter.
  final String mimeType;

  /// Whether the content travels inline.
  bool get isInline => bytes != null;

  /// The content encoded as base64, for providers that take a data payload.
  ///
  /// Throws an [InvalidStateException] when this part references a [uri]
  /// instead of carrying bytes.
  String toBase64() {
    final data = bytes;
    if (data == null) {
      throw InvalidStateException(
        'This $kind part references a URI and has no inline bytes to encode. '
        'Fetch the URI first if the provider requires inline content.',
        currentState: 'uri',
        expectedState: 'bytes',
      );
    }
    return base64Encode(data);
  }

  /// The content as a `data:` URI.
  String toDataUri() => 'data:$mimeType;base64,${toBase64()}';

  /// Common serialisation for every media part.
  @protected
  JsonMap baseJson() => pruneNulls(<String, Object?>{
    'kind': kind,
    'mimeType': mimeType,
    'uri': uri?.toString(),
    'bytes': bytes == null ? null : base64Encode(bytes!),
  });

  /// Decodes the `bytes`/`uri` pair shared by every media part.
  ///
  /// Exactly one of the two is non-null in well-formed JSON; the constructor
  /// assertion enforces that on the way back in.
  @protected
  static (Uint8List? bytes, Uri? uri) decodeSource(JsonMap json) {
    final encoded = json.optionalString('bytes');
    final uri = json.optionalString('uri');
    return (
      encoded == null ? null : base64Decode(encoded),
      uri == null ? null : Uri.parse(uri),
    );
  }
}

/// An image.
@immutable
final class ImagePart extends MediaPart {
  /// Creates an image part.
  const ImagePart({
    super.bytes,
    super.uri,
    required super.mimeType,
    this.detail,
  });

  /// Creates an image from inline [bytes].
  factory ImagePart.bytes(Uint8List bytes, {required String mimeType}) =>
      ImagePart(bytes: bytes, mimeType: mimeType);

  /// Creates an image referenced by [uri].
  factory ImagePart.url(Uri uri, {String mimeType = 'image/*'}) =>
      ImagePart(uri: uri, mimeType: mimeType);

  /// Restores an image part from JSON.
  factory ImagePart.fromJson(JsonMap json) {
    final (bytes, uri) = MediaPart.decodeSource(json);
    return ImagePart(
      bytes: bytes,
      uri: uri,
      mimeType: json.requireString('mimeType'),
      detail: json.optionalString('detail'),
    );
  }

  /// Provider-specific fidelity hint, such as `low`, `high` or `auto`.
  ///
  /// `low` typically costs a fixed, much smaller number of tokens — the
  /// difference between a viable and an unaffordable image-heavy agent.
  final String? detail;

  @override
  String get kind => 'image';

  @override
  JsonMap toJson() =>
      pruneNulls(<String, Object?>{...baseJson(), 'detail': detail});

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ImagePart &&
          mimeType == other.mimeType &&
          uri == other.uri &&
          detail == other.detail &&
          const ListEquality<int>().equals(bytes, other.bytes);

  @override
  int get hashCode => Object.hash(
    ImagePart,
    mimeType,
    uri,
    detail,
    bytes == null ? null : const ListEquality<int>().hash(bytes),
  );

  @override
  String toString() =>
      'ImagePart($mimeType, ${isInline ? '${bytes!.length} bytes' : uri})';
}

/// A document such as a PDF or a spreadsheet.
@immutable
final class FilePart extends MediaPart {
  /// Creates a file part.
  const FilePart({
    super.bytes,
    super.uri,
    required super.mimeType,
    this.name,
    this.providerFileId,
  });

  /// Restores a file part from JSON.
  factory FilePart.fromJson(JsonMap json) {
    final (bytes, uri) = MediaPart.decodeSource(json);
    return FilePart(
      bytes: bytes,
      uri: uri,
      mimeType: json.requireString('mimeType'),
      name: json.optionalString('name'),
      providerFileId: json.optionalString('providerFileId'),
    );
  }

  /// Original file name, shown to the model as context.
  final String? name;

  /// Identifier returned by a provider's file-upload endpoint.
  ///
  /// Uploading once and referencing many times is the only workable pattern for
  /// large documents: re-sending a 20 MB PDF on every turn of a conversation is
  /// both slow and, on metered mobile data, expensive for the user.
  final String? providerFileId;

  @override
  String get kind => 'file';

  @override
  JsonMap toJson() => pruneNulls(<String, Object?>{
    ...baseJson(),
    'name': name,
    'providerFileId': providerFileId,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is FilePart &&
          mimeType == other.mimeType &&
          uri == other.uri &&
          name == other.name &&
          providerFileId == other.providerFileId &&
          const ListEquality<int>().equals(bytes, other.bytes);

  @override
  int get hashCode => Object.hash(
    FilePart,
    mimeType,
    uri,
    name,
    providerFileId,
    bytes == null ? null : const ListEquality<int>().hash(bytes),
  );

  @override
  String toString() => 'FilePart(${name ?? mimeType})';
}

/// Recorded audio, optionally with a transcript.
@immutable
final class AudioPart extends MediaPart {
  /// Creates an audio part.
  const AudioPart({
    super.bytes,
    super.uri,
    required super.mimeType,
    this.transcript,
  });

  /// Restores an audio part from JSON.
  factory AudioPart.fromJson(JsonMap json) {
    final (bytes, uri) = MediaPart.decodeSource(json);
    return AudioPart(
      bytes: bytes,
      uri: uri,
      mimeType: json.requireString('mimeType'),
      transcript: json.optionalString('transcript'),
    );
  }

  /// Text transcript, when one is already available.
  ///
  /// Carrying it alongside the audio lets a text-only provider still receive
  /// the content, which is what makes an audio-input agent degrade gracefully
  /// rather than fail.
  final String? transcript;

  @override
  String get kind => 'audio';

  @override
  JsonMap toJson() =>
      pruneNulls(<String, Object?>{...baseJson(), 'transcript': transcript});

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AudioPart &&
          mimeType == other.mimeType &&
          uri == other.uri &&
          transcript == other.transcript &&
          const ListEquality<int>().equals(bytes, other.bytes);

  @override
  int get hashCode => Object.hash(
    AudioPart,
    mimeType,
    uri,
    transcript,
    bytes == null ? null : const ListEquality<int>().hash(bytes),
  );

  @override
  String toString() => 'AudioPart($mimeType)';
}

/// The model's request to invoke a tool.
@immutable
final class ToolCallPart extends ContentPart {
  /// Creates a tool call.
  ToolCallPart({
    required this.id,
    required this.name,
    Map<String, Object?> arguments = const <String, Object?>{},
    this.rawArguments,
  }) : arguments = Map<String, Object?>.unmodifiable(arguments);

  /// Restores a tool call from JSON.
  factory ToolCallPart.fromJson(JsonMap json) => ToolCallPart(
    id: json.requireString('id'),
    name: json.requireString('name'),
    arguments: json.optionalObject('arguments') ?? const <String, Object?>{},
    rawArguments: json.optionalString('rawArguments'),
  );

  /// Provider-assigned identifier, echoed back on the matching result.
  ///
  /// Correlating results to calls by identifier rather than by order is what
  /// makes parallel tool calling possible: a model can request four tools at
  /// once and receive the answers in whatever order they finish.
  final String id;

  /// Name of the tool to invoke.
  final String name;

  /// Decoded arguments.
  final Map<String, Object?> arguments;

  /// The argument JSON exactly as the provider sent it.
  ///
  /// Preserved because models sometimes emit invalid JSON, and the raw text is
  /// the only thing that can be shown in an error or handed to a repair pass.
  /// It is also what streaming assembles incrementally.
  final String? rawArguments;

  /// The arguments as JSON text, re-encoding them when no raw text was kept.
  ///
  /// Anything that replays a completed tool call as stream fragments — a
  /// non-streaming model presented through a streaming API, a cached answer
  /// served as chunks, a scripted test double — needs the argument *text*.
  /// Reading [rawArguments] directly loses the arguments entirely for a call
  /// that was constructed in code rather than parsed from a provider, which
  /// then fails schema validation for no reason the caller can see.
  ///
  /// Prefers the original text when there is one: re-encoding can reorder keys,
  /// and some providers checksum this field.
  String get argumentsJson => rawArguments ?? jsonEncode(arguments);

  @override
  String get kind => 'tool_call';

  @override
  JsonMap toJson() => pruneNulls(<String, Object?>{
    'kind': kind,
    'id': id,
    'name': name,
    'arguments': arguments,
    'rawArguments': rawArguments,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ToolCallPart &&
          id == other.id &&
          name == other.name &&
          const DeepCollectionEquality().equals(arguments, other.arguments);

  @override
  int get hashCode => Object.hash(
    ToolCallPart,
    id,
    name,
    const DeepCollectionEquality().hash(arguments),
  );

  @override
  String toString() => 'ToolCallPart($name#$id, $arguments)';
}

/// The outcome of a tool invocation, returned to the model.
@immutable
final class ToolResultPart extends ContentPart {
  /// Creates a tool result.
  const ToolResultPart({
    required this.callId,
    required this.name,
    required this.content,
    this.isError = false,
    this.parts = const <ContentPart>[],
  });

  /// Restores a tool result from JSON.
  factory ToolResultPart.fromJson(JsonMap json) => ToolResultPart(
    callId: json.requireString('callId'),
    name: json.requireString('name'),
    content: json.requireString('content'),
    isError: json.boolOr('isError', orElse: false),
    parts: json
        .decodeList('parts', ContentPart.fromJson)
        .toList(growable: false),
  );

  /// Identifier of the [ToolCallPart] this answers.
  final String callId;

  /// Name of the tool that ran.
  final String name;

  /// The result rendered as text for the model.
  ///
  /// Text, not a structured object, because that is what every provider's wire
  /// format accepts. Structured results are serialised by the tool layer, which
  /// is also where the decision about *how* to render them belongs.
  final String content;

  /// Whether the tool failed.
  ///
  /// A failure is still returned to the model rather than thrown, because a
  /// model that is told "the file was not found" can recover — it retries with
  /// a different path or explains the problem to the user. Throwing instead
  /// ends the run and gives the user nothing.
  final bool isError;

  /// Rich result content, for providers that accept multimodal tool results.
  ///
  /// A screenshot tool returns an image here and a description in [content], so
  /// the same result works against a text-only provider and a vision one.
  final List<ContentPart> parts;

  @override
  String get kind => 'tool_result';

  @override
  JsonMap toJson() => pruneNulls(<String, Object?>{
    'kind': kind,
    'callId': callId,
    'name': name,
    'content': content,
    'isError': isError ? true : null,
    'parts': parts.isEmpty ? null : parts.map((p) => p.toJson()).toList(),
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ToolResultPart &&
          callId == other.callId &&
          name == other.name &&
          content == other.content &&
          isError == other.isError &&
          const ListEquality<ContentPart>().equals(parts, other.parts);

  @override
  int get hashCode => Object.hash(
    ToolResultPart,
    callId,
    name,
    content,
    isError,
    const ListEquality<ContentPart>().hash(parts),
  );

  @override
  String toString() =>
      'ToolResultPart($name#$callId, '
      '${isError ? 'error' : 'ok'}, ${_preview(content)})';
}

String _preview(String text) {
  final collapsed = text.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (collapsed.length <= 40) return '"$collapsed"';
  return '"${collapsed.substring(0, 37)}..."';
}
