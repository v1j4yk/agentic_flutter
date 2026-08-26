/// Translating between MCP content blocks and the framework's content parts.
///
/// # Why a translation layer and not a shared type
///
/// MCP's content blocks and this framework's [ContentPart] describe the same
/// idea — text, an image, a file, a pointer to a resource — with different
/// field names and a different notion of what a "resource" is. Sharing one type
/// would mean either the core learning MCP's vocabulary or MCP dictating the
/// core's, and both are wrong: an application that never speaks MCP should not
/// carry its concepts, and a future protocol should not require changing the
/// core again.
///
/// So this file is the seam, and it is deliberately lossless in the direction
/// that matters: anything MCP can express that the framework cannot is
/// preserved as text rather than dropped, because a tool result that silently
/// loses half its content is worse than one that reads a little awkwardly.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:agentic_core/agentic_core.dart';

/// Converts one MCP content block into a [ContentPart].
///
/// Returns `null` only for a block with no usable payload at all.
ContentPart? contentPartFromMcp(JsonMap block) {
  final type = block['type'];
  switch (type) {
    case 'text':
      final text = block['text'];
      return text is String ? TextPart(text) : null;

    case 'image':
    case 'audio':
      final data = block['data'];
      final mimeType = block.stringOr(
        'mimeType',
        type == 'image' ? 'image/png' : 'audio/mpeg',
      );
      if (data is! String) return null;
      final bytes = _decodeBase64(data);
      if (bytes == null) return null;
      return type == 'image'
          ? ImagePart(bytes: bytes, mimeType: mimeType)
          : AudioPart(bytes: bytes, mimeType: mimeType);

    case 'resource':
      // An embedded resource: the server inlined the contents rather than
      // making the client fetch them.
      final resource = block.optionalObject('resource');
      return resource == null ? null : _partFromResourceContents(resource);

    case 'resource_link':
      final uri = block.optionalString('uri');
      if (uri == null) return null;
      final name = block.optionalString('name') ?? uri;
      return TextPart('[$name]($uri)');

    default:
      // An unknown block type from a newer revision. Rendering it as JSON keeps
      // the information reachable — by a person reading a log, and by a model
      // reading a tool result — instead of discarding it.
      return TextPart(jsonEncode(block));
  }
}

/// Converts a list of MCP content blocks.
List<ContentPart> contentPartsFromMcp(Object? blocks) {
  if (blocks is! List) return const <ContentPart>[];
  return <ContentPart>[
    for (final block in blocks)
      if (block is Map) ?contentPartFromMcp(block.cast<String, Object?>()),
  ];
}

/// Converts a [ContentPart] into an MCP content block.
///
/// Returns `null` for parts that have no MCP equivalent — a tool call or a tool
/// result, which are envelope concerns in MCP rather than content.
JsonMap? contentPartToMcp(ContentPart part) => switch (part) {
  TextPart(:final text) => <String, Object?>{'type': 'text', 'text': text},
  // Reasoning is deliberately rendered as text rather than dropped: a server
  // that asked for a model's answer wants the answer, and a client that hides
  // the model's own explanation of it is answering a different question.
  ReasoningPart(:final text) => <String, Object?>{'type': 'text', 'text': text},
  ImagePart(:final mimeType) => <String, Object?>{
    'type': 'image',
    'data': _base64Of(part),
    'mimeType': mimeType,
  },
  AudioPart(:final mimeType) => <String, Object?>{
    'type': 'audio',
    'data': _base64Of(part),
    'mimeType': mimeType,
  },
  FilePart(:final mimeType, :final name) => <String, Object?>{
    'type': 'resource',
    'resource': pruneNulls(<String, Object?>{
      'uri': part.uri?.toString() ?? 'file:///${name ?? 'attachment'}',
      'mimeType': mimeType,
      'blob': _base64Of(part),
    }),
  },
  ToolCallPart() || ToolResultPart() => null,
};

/// Converts a list of content parts.
List<Object?> contentPartsToMcp(Iterable<ContentPart> parts) => <Object?>[
  for (final part in parts) ?contentPartToMcp(part),
];

/// Renders MCP content blocks as the plain text a model reads.
///
/// Non-text blocks become a short placeholder rather than nothing, because a
/// tool result that reads "(image/png, 42 KB)" tells the model something true,
/// while an empty string tells it the tool returned nothing.
String renderMcpContent(Object? blocks) {
  if (blocks is! List) return '';
  final buffer = StringBuffer();
  for (final block in blocks) {
    if (block is! Map) continue;
    final map = block.cast<String, Object?>();
    switch (map['type']) {
      case 'text':
        buffer.writeln(map['text']);
      case 'image' || 'audio':
        final data = map['data'];
        final bytes = data is String ? (data.length * 3) ~/ 4 : 0;
        buffer.writeln(
          '(${map['type']}: ${map['mimeType'] ?? 'unknown'}, '
          '${(bytes / 1024).toStringAsFixed(0)} KB)',
        );
      case 'resource':
        final resource = map['resource'];
        if (resource is Map) {
          final text = resource['text'];
          buffer.writeln(
            text is String ? text : '(resource: ${resource['uri']})',
          );
        }
      case 'resource_link':
        buffer.writeln('(resource: ${map['uri']})');
      default:
        buffer.writeln(jsonEncode(map));
    }
  }
  return buffer.toString().trimRight();
}

ContentPart _partFromResourceContents(JsonMap resource) {
  final text = resource['text'];
  if (text is String) return TextPart(text);

  final blob = resource['blob'];
  final mimeType = resource.stringOr('mimeType', 'application/octet-stream');
  final uri = resource.optionalString('uri');
  if (blob is! String) return TextPart('(resource: ${uri ?? 'unknown'})');

  final bytes = _decodeBase64(blob);
  if (bytes == null) return TextPart('(resource: ${uri ?? 'unknown'})');
  if (mimeType.startsWith('image/')) {
    return ImagePart(bytes: bytes, mimeType: mimeType);
  }
  return FilePart(bytes: bytes, mimeType: mimeType, name: uri);
}

String _base64Of(MediaPart part) {
  final bytes = part.bytes;
  // A part carrying only a URI has nothing to inline; the URI travels in the
  // block's own field instead.
  return bytes == null ? '' : base64Encode(bytes);
}

/// Decodes base64 that came off a wire, tolerating what a peer may have sent.
///
/// Returns `null` for anything that is not decodable rather than throwing: one
/// malformed image in a tool result must not fail the whole call, and the
/// caller renders a placeholder instead.
Uint8List? _decodeBase64(String data) {
  try {
    return base64Decode(base64.normalize(data));
  } on FormatException {
    return null;
  }
}
