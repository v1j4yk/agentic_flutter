/// The unit of conversation.
///
/// A [Message] is an immutable record of one turn. Immutability is what makes
/// the rest of the framework tractable: conversation history can be shared
/// between agents without defensive copying, a memory store can hold a
/// reference rather than a snapshot, and a workflow can be resumed from a
/// persisted transcript with no risk that a later step mutated an earlier turn.
library;

import 'package:agentic_core/src/common/json_reader.dart';
import 'package:agentic_core/src/common/json_types.dart';
import 'package:agentic_core/src/messaging/content_part.dart';
import 'package:collection/collection.dart';
import 'package:meta/meta.dart';

/// Who produced a message.
enum MessageRole {
  /// Instructions that define the assistant's behaviour.
  system('system'),

  /// Instructions from the application, ranked below `system` on providers that
  /// distinguish them.
  ///
  /// Where a provider has no such role, adapters map this onto `system`.
  developer('developer'),

  /// Input from the end user.
  user('user'),

  /// Output from the model, including its tool calls.
  assistant('assistant'),

  /// The result of a tool invocation, fed back to the model.
  tool('tool');

  const MessageRole(this.wireName);

  /// The value used on the wire by most providers.
  final String wireName;

  /// Parses a role name, returning `null` when unrecognised.
  static MessageRole? fromWire(String value) =>
      MessageRole.values.firstWhereOrNull((role) => role.wireName == value);
}

/// One turn in a conversation.
///
/// Build messages with the named constructors — [Message.system],
/// [Message.user], [Message.assistant], [Message.toolResult] — which enforce
/// the invariants each role carries.
///
/// ```dart
/// final history = <Message>[
///   Message.system('You are a concise assistant.'),
///   Message.user('Summarise this photo.', parts: [ImagePart.bytes(jpeg, mimeType: 'image/jpeg')]),
/// ];
/// ```
@immutable
final class Message {
  /// Creates a message from explicit [parts].
  ///
  /// Prefer the role-specific constructors; this one exists for adapters
  /// reconstructing a message from a provider response.
  Message({
    required this.role,
    required List<ContentPart> parts,
    this.id,
    this.name,
    this.createdAt,
    Map<String, Object?> metadata = const <String, Object?>{},
  }) : parts = List<ContentPart>.unmodifiable(parts),
       metadata = metadata.isEmpty
           ? const <String, Object?>{}
           : Map<String, Object?>.unmodifiable(metadata);

  /// Creates a system message.
  ///
  /// System messages steer everything downstream, so keep them stable: a system
  /// prompt that varies per request defeats provider prompt caching, which is
  /// usually the largest single cost saving available to an agent.
  factory Message.system(String text, {String? id}) =>
      Message(role: MessageRole.system, parts: [TextPart(text)], id: id);

  /// Creates a developer message.
  factory Message.developer(String text, {String? id}) =>
      Message(role: MessageRole.developer, parts: [TextPart(text)], id: id);

  /// Creates a user message, optionally multimodal.
  ///
  /// [text] comes first because it almost always exists; [parts] appends images,
  /// files or audio after it.
  factory Message.user(
    String text, {
    List<ContentPart> parts = const <ContentPart>[],
    String? id,
    String? name,
    Map<String, Object?> metadata = const <String, Object?>{},
  }) => Message(
    role: MessageRole.user,
    parts: <ContentPart>[if (text.isNotEmpty) TextPart(text), ...parts],
    id: id,
    name: name,
    metadata: metadata,
  );

  /// Creates an assistant message.
  ///
  /// [toolCalls] are appended after the text, matching the order providers
  /// return them in.
  factory Message.assistant(
    String text, {
    List<ToolCallPart> toolCalls = const <ToolCallPart>[],
    List<ContentPart> parts = const <ContentPart>[],
    String? id,
    String? name,
    Map<String, Object?> metadata = const <String, Object?>{},
  }) => Message(
    role: MessageRole.assistant,
    parts: <ContentPart>[
      if (text.isNotEmpty) TextPart(text),
      ...parts,
      ...toolCalls,
    ],
    id: id,
    name: name,
    metadata: metadata,
  );

  /// Creates a message carrying the result of one tool call.
  ///
  /// One result per message. Providers correlate results to calls by
  /// [ToolResultPart.callId], and keeping them one-to-one means a partial
  /// failure in a parallel batch does not invalidate the rest.
  factory Message.toolResult({
    required String callId,
    required String name,
    required String content,
    bool isError = false,
    List<ContentPart> parts = const <ContentPart>[],
    String? id,
  }) => Message(
    role: MessageRole.tool,
    parts: <ContentPart>[
      ToolResultPart(
        callId: callId,
        name: name,
        content: content,
        isError: isError,
        parts: parts,
      ),
    ],
    id: id,
  );

  /// Restores a message from JSON.
  factory Message.fromJson(JsonMap json) => Message(
    role: json.requireEnum('role', <String, MessageRole>{
      for (final role in MessageRole.values) role.wireName: role,
    }),
    parts: json.decodeList('parts', ContentPart.fromJson),
    id: json.optionalString('id'),
    name: json.optionalString('name'),
    createdAt: json.optionalDateTime('createdAt'),
    metadata: json.optionalObject('metadata') ?? const <String, Object?>{},
  );

  /// Who produced this message.
  final MessageRole role;

  /// The content, in order.
  final List<ContentPart> parts;

  /// Stable identifier, for deduplication and for UI keys.
  final String? id;

  /// Speaker name, used to distinguish participants in a multi-agent
  /// conversation.
  final String? name;

  /// When the message was created, in UTC.
  final DateTime? createdAt;

  /// Application-defined metadata.
  ///
  /// Never sent to a provider. Use it for agent attribution, citation
  /// identifiers, moderation verdicts and anything else the application needs
  /// to carry alongside a turn.
  final Map<String, Object?> metadata;

  /// Every text part, concatenated with newlines.
  ///
  /// Excludes reasoning, which is not part of the answer, and excludes tool
  /// calls, which are structure rather than prose. This is what a chat bubble
  /// should render.
  String get text =>
      parts.whereType<TextPart>().map((part) => part.text).join('\n');

  /// The model's reasoning, concatenated, or `null` when there was none.
  String? get reasoning {
    final reasoningParts = parts.whereType<ReasoningPart>();
    if (reasoningParts.isEmpty) return null;
    return reasoningParts.map((part) => part.text).join('\n');
  }

  /// Tool calls requested by this message.
  List<ToolCallPart> get toolCalls =>
      parts.whereType<ToolCallPart>().toList(growable: false);

  /// Tool results carried by this message.
  List<ToolResultPart> get toolResults =>
      parts.whereType<ToolResultPart>().toList(growable: false);

  /// Whether this message requests at least one tool call.
  ///
  /// The condition an agent loop turns on: a message with tool calls means
  /// another iteration, one without means the run can finish.
  bool get hasToolCalls => parts.any((part) => part is ToolCallPart);

  /// Whether this message carries non-text content.
  bool get isMultimodal => parts.any((part) => part is MediaPart);

  /// Whether this message has no content at all.
  bool get isEmpty => parts.isEmpty;

  /// Returns a copy with selected fields replaced.
  Message copyWith({
    MessageRole? role,
    List<ContentPart>? parts,
    String? id,
    String? name,
    DateTime? createdAt,
    Map<String, Object?>? metadata,
  }) => Message(
    role: role ?? this.role,
    parts: parts ?? this.parts,
    id: id ?? this.id,
    name: name ?? this.name,
    createdAt: createdAt ?? this.createdAt,
    metadata: metadata ?? this.metadata,
  );

  /// Returns a copy with [additional] parts appended.
  ///
  /// Used by streaming assembly, which accumulates parts as deltas arrive.
  Message withParts(Iterable<ContentPart> additional) =>
      copyWith(parts: <ContentPart>[...parts, ...additional]);

  /// Returns a copy with [entries] merged into [metadata].
  Message withMetadata(Map<String, Object?> entries) =>
      copyWith(metadata: <String, Object?>{...metadata, ...entries});

  /// Serialises the message.
  JsonMap toJson() => pruneNulls(<String, Object?>{
    'role': role.wireName,
    'parts': parts.map((part) => part.toJson()).toList(),
    'id': id,
    'name': name,
    'createdAt': createdAt?.toIso8601String(),
    'metadata': metadata.isEmpty ? null : metadata,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Message &&
          role == other.role &&
          id == other.id &&
          name == other.name &&
          createdAt == other.createdAt &&
          const ListEquality<ContentPart>().equals(parts, other.parts) &&
          const DeepCollectionEquality().equals(metadata, other.metadata);

  @override
  int get hashCode => Object.hash(
    role,
    id,
    name,
    createdAt,
    const ListEquality<ContentPart>().hash(parts),
    const DeepCollectionEquality().hash(metadata),
  );

  @override
  String toString() {
    final summary = parts.length == 1
        ? parts.first.toString()
        : '${parts.length} parts';
    return 'Message(${role.wireName}${name == null ? '' : ':$name'}, $summary)';
  }
}

/// Operations over a conversation history.
///
/// Provided as an extension so that history is a plain `List<Message>` — no
/// wrapper type to learn, and full interoperability with `ListView.builder`,
/// `fold`, and everything else Dart already gives you.
extension ConversationHistory on List<Message> {
  /// The most recent message, or `null` when the list is empty.
  Message? get lastOrNull => isEmpty ? null : last;

  /// Every system and developer message, in order.
  ///
  /// Adapters hoist these into a provider's dedicated system field.
  List<Message> get systemMessages => where(
    (message) =>
        message.role == MessageRole.system ||
        message.role == MessageRole.developer,
  ).toList(growable: false);

  /// Every message that is not a system or developer instruction.
  List<Message> get conversation => where(
    (message) =>
        message.role != MessageRole.system &&
        message.role != MessageRole.developer,
  ).toList(growable: false);

  /// The last [count] messages, keeping any leading system messages.
  ///
  /// The simplest workable context-window strategy: drop the middle of a long
  /// conversation but never drop the instructions, since losing the system
  /// prompt changes the assistant's behaviour mid-conversation.
  List<Message> takeRecent(int count) {
    final system = systemMessages;
    final rest = conversation;
    if (rest.length <= count) return <Message>[...system, ...rest];
    return <Message>[...system, ...rest.sublist(rest.length - count)];
  }

  /// Total usage-relevant text length, as a rough context-size proxy.
  ///
  /// Characters, not tokens: a real count needs the model's tokeniser, which
  /// lives in the provider adapter. Useful for a cheap guard before paying for
  /// an exact count.
  int get characterCount =>
      fold(0, (total, message) => total + message.text.length);

  /// Every tool call awaiting a result.
  ///
  /// A model's turn is incomplete until every call it made has a matching
  /// result; sending an incomplete set is one of the most common causes of a
  /// provider rejecting a request outright.
  List<ToolCallPart> get pendingToolCalls {
    final answered = <String>{
      for (final message in this)
        for (final result in message.toolResults) result.callId,
    };
    return <ToolCallPart>[
      for (final message in this)
        for (final call in message.toolCalls)
          if (!answered.contains(call.id)) call,
    ];
  }
}
