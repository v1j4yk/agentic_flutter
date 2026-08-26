/// A device's capabilities, offered to an agent as ordinary tools.
///
/// # Why these take callbacks instead of using plugins
///
/// Location, camera, contacts and speech each mean a plugin. Depending on them
/// here would put four plugins, four sets of platform permissions and four
/// upgrade treadmills into every application that uses this framework —
/// including the ones that only ever call a hosted model and touch no hardware
/// at all.
///
/// So what lives here is the part that is genuinely shared and genuinely easy
/// to get wrong: the tool name and description the model reads, the argument
/// schema, the read-only and approval flags, the permission-denied path, and
/// the conversion of a result into something a model can act on. What you
/// supply is the one line that calls your plugin.
///
/// ```dart
/// registry.register(locationTool(
///   read: () async {
///     final position = await Geolocator.getCurrentPosition();
///     return DeviceLocation(
///       latitude: position.latitude,
///       longitude: position.longitude,
///       accuracyMetres: position.accuracy,
///     );
///   },
/// ));
/// ```
///
/// # Permission denial is a tool failure, not an exception
///
/// A user saying no is an ordinary outcome, not a bug. Every tool here turns a
/// [PermissionDeniedException] into a `ToolResult.failure` carrying a sentence
/// the model can act on — it will ask the user, or answer without the
/// information — rather than an exception that ends the run. Throw one from
/// your callback with [permissionDenied].
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:agentic_core/agentic_core.dart';
import 'package:agentic_tools/agentic_tools.dart';
import 'package:meta/meta.dart';

/// Thrown by a capability callback when the user declined a permission.
///
/// A thin naming of `agentic_core`'s [PermissionDeniedException] for the one
/// distinction the core has no reason to model: whether the refusal can be
/// asked about again. A temporary "not now" can be retried after explaining
/// why; a "never ask again" can only be undone in system settings, and telling
/// the model which it was stops it asking again pointlessly.
PermissionDeniedException permissionDenied(
  String capability, {
  bool permanent = false,
  String? message,
  Object? cause,
  StackTrace? causeStackTrace,
}) => PermissionDeniedException(
  message ??
      (permanent
          ? 'The user has permanently denied $capability access.'
          : 'The user declined $capability access.'),
  operation: 'platform:$capability',
  cause: cause,
  causeStackTrace: causeStackTrace,
  details: <String, Object?>{'capability': capability, 'permanent': permanent},
);

/// Whether [error] was a permanent refusal.
bool isPermanentDenial(PermissionDeniedException error) =>
    error.details['permanent'] == true;

/// Where the device is.
@immutable
final class DeviceLocation {
  /// Creates a location.
  const DeviceLocation({
    required this.latitude,
    required this.longitude,
    this.accuracyMetres,
    this.altitudeMetres,
    this.placeName,
    this.timestamp,
  });

  /// Degrees north.
  final double latitude;

  /// Degrees east.
  final double longitude;

  /// How far off the reading may be.
  ///
  /// Included in what the model sees. A coordinate accurate to three kilometres
  /// is a different fact from one accurate to five metres, and a model told
  /// only the numbers will treat them identically.
  final double? accuracyMetres;

  /// Height above sea level.
  final double? altitudeMetres;

  /// A human-readable place, when the app has reverse-geocoded it.
  final String? placeName;

  /// When the reading was taken.
  final DateTime? timestamp;

  /// Serialises the location.
  JsonMap toJson() => pruneNulls(<String, Object?>{
    'latitude': latitude,
    'longitude': longitude,
    'accuracyMetres': accuracyMetres,
    'altitudeMetres': altitudeMetres,
    'placeName': placeName,
    'timestamp': timestamp?.toIso8601String(),
  });

  /// A sentence a model can read.
  String describe() {
    final buffer = StringBuffer();
    if (placeName != null) buffer.write('$placeName — ');
    buffer.write(
      '${latitude.toStringAsFixed(5)}, ${longitude.toStringAsFixed(5)}',
    );
    if (accuracyMetres != null) {
      buffer.write(' (accurate to about ${accuracyMetres!.round()} m)');
    }
    return buffer.toString();
  }

  @override
  String toString() => 'DeviceLocation(${describe()})';
}

/// A tool that reports where the device is.
///
/// Marked read-only and idempotent, and it does **not** require approval by
/// default — the platform already asks, and a second confirmation for something
/// the OS has just confirmed trains users to tap through both. Pass
/// `requiresApproval: true` if your product wants its own gate as well.
Tool locationTool({
  required FutureOr<DeviceLocation> Function() read,
  String name = 'device_location',
  String? description,
  bool requiresApproval = false,
  Duration timeout = const Duration(seconds: 15),
}) => FunctionTool(
  name: name,
  description:
      description ??
      "Returns the device's current location. Use it when the answer depends "
          'on where the user is — nearby places, local time zone, regional '
          'availability. Do not call it for general knowledge questions.',
  parameters: JsonSchema.object(properties: const <String, JsonSchema>{}),
  requiresApproval: requiresApproval,
  timeout: timeout,
  tags: const <String>{'platform', 'location'},
  handler: (invocation) => _guard('location', () async {
    final location = await read();
    return ToolResult.success(location.describe(), data: location.toJson());
  }),
);

/// A photograph or image the device produced.
@immutable
final class CapturedImage {
  /// Creates a captured image.
  const CapturedImage({
    required this.bytes,
    required this.mimeType,
    this.width,
    this.height,
    this.description,
  });

  /// The encoded image.
  final Uint8List bytes;

  /// Its media type, such as `image/jpeg`.
  final String mimeType;

  /// Pixel width, when known.
  final int? width;

  /// Pixel height, when known.
  final int? height;

  /// What it is, when the app knows.
  final String? description;

  /// How large the encoded image is.
  int get byteLength => bytes.length;

  /// This image as a content part a model can read.
  ImagePart toPart() => ImagePart(bytes: bytes, mimeType: mimeType);

  @override
  String toString() => 'CapturedImage($mimeType, $byteLength bytes)';
}

/// A tool that captures an image and hands it to the model.
///
/// # Size is the thing to get right
///
/// A modern phone camera produces a 4 MB JPEG, which becomes roughly 5.3 MB of
/// base64 in the request body and a four-figure token count in the bill. Resize
/// before returning: 1024 pixels on the long edge is enough for almost every
/// question a model is asked about a photograph. [maxBytes] is a backstop that
/// fails loudly rather than silently sending it.
///
/// Requires approval by default. Taking a picture is an action with a
/// side effect in the physical world, and a model deciding to do it
/// unprompted is exactly the case approval exists for.
Tool cameraTool({
  required FutureOr<CapturedImage?> Function(String purpose) capture,
  String name = 'take_photo',
  String? description,
  bool requiresApproval = true,
  int maxBytes = 4 * 1024 * 1024,
  Duration timeout = const Duration(minutes: 2),
}) => FunctionTool(
  name: name,
  description:
      description ??
      'Takes a photograph with the device camera and returns it. Use it only '
          'when seeing something is necessary to answer, and say what you need '
          'to see in `purpose` so the user knows what to point the camera at.',
  parameters: JsonSchema.object(
    properties: <String, JsonSchema>{
      'purpose': JsonSchema.string(
        description: 'What you need to see, in one short phrase.',
        minLength: 3,
      ),
    },
    required: const <String>{'purpose'},
  ),
  isReadOnly: false,
  isIdempotent: false,
  requiresApproval: requiresApproval,
  timeout: timeout,
  tags: const <String>{'platform', 'camera'},
  handler: (invocation) => _guard('camera', () async {
    final purpose = invocation.require<String>('purpose');
    final image = await capture(purpose);
    if (image == null) {
      return ToolResult.failure(
        'The user closed the camera without taking a photo. Ask what they '
        'would like to do instead, or answer without the image.',
      );
    }
    if (image.byteLength > maxBytes) {
      return ToolResult.failure(
        'The photo is ${(image.byteLength / 1024 / 1024).toStringAsFixed(1)} MB, '
        'over the ${(maxBytes / 1024 / 1024).toStringAsFixed(1)} MB limit. '
        'Resize it before sending — 1024 pixels on the long edge is enough for '
        'almost any question about a photograph.',
      );
    }
    return ToolResult.success(
      image.description ??
          'A photo of: ${invocation.require<String>('purpose')}.',
      parts: <ContentPart>[image.toPart()],
      metadata: <String, Object?>{
        'bytes': image.byteLength,
        'mimeType': image.mimeType,
      },
    );
  }),
);

/// A tool that asks the user a question mid-run.
///
/// # Why an agent needs this
///
/// The alternative to asking is guessing. An agent that cannot reach the user
/// invents a plausible answer to "which account did you mean?" and proceeds
/// confidently on it — which is far worse than a two-second interruption.
///
/// On a phone this is a dialog or a bottom sheet; supply whichever, and return
/// `null` if the user dismisses it.
Tool askUserTool({
  required FutureOr<String?> Function(String question, List<String> options)
  ask,
  String name = 'ask_user',
  String? description,
  Duration timeout = const Duration(minutes: 5),
}) => FunctionTool(
  name: name,
  description:
      description ??
      'Asks the user a question and returns their answer. Use it when you '
          'genuinely cannot proceed without knowing something only they can '
          'tell you. Do not use it for anything you can look up or infer.',
  parameters: JsonSchema.object(
    properties: <String, JsonSchema>{
      'question': JsonSchema.string(
        description: 'The question, in one sentence.',
        minLength: 3,
      ),
      'options': JsonSchema.array(
        description:
            'Choices to offer, when the answer is one of a few. Omit for an '
            'open question.',
        items: JsonSchema.string(),
        maxItems: 6,
      ),
    },
    required: const <String>{'question'},
  ),
  isReadOnly: false,
  isIdempotent: false,
  timeout: timeout,
  tags: const <String>{'platform', 'interaction'},
  handler: (invocation) async {
    final question = invocation.require<String>('question');
    final options = <String>[
      for (final option
          in invocation.arguments['options'] as List<Object?>? ??
              const <Object?>[])
        if (option is String) option,
    ];

    final answer = await ask(question, options);
    if (answer == null) {
      return ToolResult.failure(
        'The user dismissed the question without answering. Continue with what '
        'you already know, or explain what you need and why.',
      );
    }
    return ToolResult.success(
      answer,
      data: <String, Object?>{'question': question, 'answer': answer},
    );
  },
);

/// A tool that shares text through the platform's share sheet.
///
/// Requires approval by default: it puts content in front of somebody outside
/// the conversation, and the model should not decide that on its own.
Tool shareTool({
  required FutureOr<bool> Function(String text, String? subject) share,
  String name = 'share',
  String? description,
  bool requiresApproval = true,
}) => FunctionTool(
  name: name,
  description:
      description ??
      'Opens the system share sheet with the given text. Use it when the user '
          'asked to send, share or export something.',
  parameters: JsonSchema.object(
    properties: <String, JsonSchema>{
      'text': JsonSchema.string(
        description: 'The text to share.',
        minLength: 1,
      ),
      'subject': JsonSchema.string(
        description: 'A subject line, for targets that use one such as email.',
      ),
    },
    required: const <String>{'text'},
  ),
  isReadOnly: false,
  isIdempotent: false,
  requiresApproval: requiresApproval,
  tags: const <String>{'platform', 'share'},
  handler: (invocation) => _guard('share', () async {
    final shared = await share(
      invocation.require<String>('text'),
      invocation.arguments['subject'] as String?,
    );
    return shared
        ? ToolResult.success('Shared.')
        : ToolResult.failure(
            'The user closed the share sheet without sharing.',
          );
  }),
);

/// Runs [body], turning a permission denial into a recoverable failure.
Future<ToolResult> _guard(
  String capability,
  Future<ToolResult> Function() body,
) async {
  try {
    return await body();
  } on PermissionDeniedException catch (error) {
    return ToolResult.failure(
      isPermanentDenial(error)
          ? 'The user has permanently denied $capability access. It can only '
                'be re-enabled in system settings, so do not ask again — '
                'answer without it, or say what is missing.'
          : 'The user declined $capability access. Explain why you need it if '
                'it matters, or answer without it.',
      cause: error,
    );
  } on CancelledException {
    // The run was abandoned. This must reach the loop, not the model.
    rethrow;
  } on AgenticException catch (error) {
    return ToolResult.failure(
      'The $capability capability failed: ${error.message}',
      cause: error,
    );
  } on Object catch (error, stackTrace) {
    // Plugin code throws platform exceptions of every shape. A tool must not
    // let one end the run when the model could simply proceed without it.
    return ToolResult.failure(
      'The $capability capability failed: $error',
      cause: UnexpectedException(
        'A platform capability threw.',
        cause: error,
        causeStackTrace: stackTrace,
      ),
    );
  }
}
