import 'dart:typed_data';

import 'package:agentic_core/agentic_core.dart';
import 'package:test/test.dart';

final jpeg = Uint8List.fromList(<int>[0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3]);

void main() {
  group('Message construction', () {
    test('user message places text before attached parts', () {
      final message = Message.user(
        'What is in this photo?',
        parts: [ImagePart.bytes(jpeg, mimeType: 'image/jpeg')],
      );

      expect(message.role, MessageRole.user);
      expect(message.parts.first, isA<TextPart>());
      expect(message.parts.last, isA<ImagePart>());
      expect(message.isMultimodal, isTrue);
    });

    test('omits an empty text part', () {
      final message = Message.user(
        '',
        parts: [ImagePart.bytes(jpeg, mimeType: 'image/jpeg')],
      );

      expect(message.parts, hasLength(1));
      expect(message.text, isEmpty);
    });

    test('assistant message appends tool calls after text', () {
      final message = Message.assistant(
        'Let me look that up.',
        toolCalls: [
          ToolCallPart(id: 'call_1', name: 'search', arguments: {'q': 'dart'}),
        ],
      );

      expect(message.hasToolCalls, isTrue);
      expect(message.toolCalls.single.name, 'search');
      expect(message.text, 'Let me look that up.');
    });

    test('text excludes reasoning and tool calls', () {
      final message = Message(
        role: MessageRole.assistant,
        parts: [
          ReasoningPart('The user wants the capital of France.'),
          TextPart('Paris.'),
          ToolCallPart(id: 'c1', name: 'noop'),
        ],
      );

      expect(message.text, 'Paris.');
      expect(message.reasoning, 'The user wants the capital of France.');
    });

    test('joins multiple text parts with newlines', () {
      final message = Message(
        role: MessageRole.assistant,
        parts: [TextPart('one'), TextPart('two')],
      );

      expect(message.text, 'one\ntwo');
    });

    test('argumentsJson re-encodes a call built in code', () {
      // Anything replaying a completed call as stream fragments needs the
      // argument text. Reading `rawArguments` directly loses the arguments for
      // a call that was constructed rather than parsed, which then fails schema
      // validation for no visible reason.
      final constructed = ToolCallPart(
        id: 'c1',
        name: 'search_web',
        arguments: {'query': 'dart'},
      );
      final parsed = ToolCallPart(
        id: 'c1',
        name: 'search_web',
        arguments: {'query': 'dart'},
        rawArguments: '{"query" : "dart"}',
      );

      expect(constructed.rawArguments, isNull);
      expect(constructed.argumentsJson, '{"query":"dart"}');
      expect(
        parsed.argumentsJson,
        '{"query" : "dart"}',
        reason: 'the original text wins; re-encoding can reorder keys',
      );
    });

    test('parts are unmodifiable', () {
      final message = Message.user('hi');

      expect(
        () => message.parts.add(TextPart('injected')),
        throwsUnsupportedError,
      );
    });

    test('copyWith replaces only what is named', () {
      final original = Message.user('hi', id: 'm1');
      final renamed = original.copyWith(name: 'alice');

      expect(renamed.id, 'm1');
      expect(renamed.name, 'alice');
      expect(renamed.text, 'hi');
      expect(original.name, isNull, reason: 'the original is untouched');
    });
  });

  group('media parts', () {
    test('require exactly one of bytes or uri', () {
      expect(
        () => ImagePart(mimeType: 'image/png'),
        throwsA(isA<AssertionError>()),
      );
      expect(
        () => ImagePart(
          bytes: jpeg,
          uri: Uri.parse('https://example.com/a.png'),
          mimeType: 'image/png',
        ),
        throwsA(isA<AssertionError>()),
      );
    });

    test('encode inline bytes as a data URI', () {
      final part = ImagePart.bytes(jpeg, mimeType: 'image/jpeg');

      expect(part.isInline, isTrue);
      expect(part.toDataUri(), startsWith('data:image/jpeg;base64,'));
    });

    test('refuse to encode a URI-referenced part', () {
      final part = ImagePart.url(Uri.parse('https://example.com/a.png'));

      expect(part.isInline, isFalse);
      expect(part.toBase64, throwsA(isA<InvalidStateException>()));
    });
  });

  group('serialisation', () {
    test('round-trips a multimodal tool-calling exchange', () {
      final original = Message(
        role: MessageRole.assistant,
        id: 'm-1',
        name: 'researcher',
        createdAt: DateTime.utc(2026, 3, 1, 12, 30),
        metadata: {'agent': 'researcher'},
        parts: [
          ReasoningPart('thinking', signature: 'sig-abc'),
          TextPart('Here is what I found.'),
          ImagePart.bytes(jpeg, mimeType: 'image/jpeg'),
          ToolCallPart(
            id: 'call_1',
            name: 'search',
            arguments: {'q': 'dart', 'limit': 3},
          ),
        ],
      );

      final restored = Message.fromJson(original.toJson());

      expect(restored, original);
      expect(restored.parts.whereType<ImagePart>().single.bytes, jpeg);
      expect(
        restored.parts.whereType<ReasoningPart>().single.signature,
        'sig-abc',
      );
    });

    test('round-trips a tool result', () {
      final original = Message.toolResult(
        callId: 'call_1',
        name: 'search',
        content: 'no results',
        isError: true,
      );

      final restored = Message.fromJson(original.toJson());

      expect(restored, original);
      expect(restored.toolResults.single.isError, isTrue);
    });

    test('rejects an unknown content part kind', () {
      expect(
        () => ContentPart.fromJson(<String, Object?>{'kind': 'hologram'}),
        throwsA(isA<SerializationException>()),
      );
    });
  });

  group('ConversationHistory', () {
    final history = <Message>[
      Message.system('Be concise.'),
      Message.user('one'),
      Message.assistant(
        'two',
        toolCalls: [
          ToolCallPart(id: 'a', name: 't'),
          ToolCallPart(id: 'b', name: 't'),
        ],
      ),
      Message.toolResult(callId: 'a', name: 't', content: 'done'),
    ];

    test('separates instructions from conversation', () {
      expect(history.systemMessages, hasLength(1));
      expect(history.conversation, hasLength(3));
    });

    test('takeRecent keeps system messages', () {
      final trimmed = history.takeRecent(1);

      expect(trimmed.first.role, MessageRole.system);
      expect(trimmed, hasLength(2));
    });

    test('takeRecent is a no-op when history already fits', () {
      expect(history.takeRecent(10), hasLength(4));
    });

    test('finds tool calls that have no result yet', () {
      // Sending a turn with an unanswered tool call is one of the most common
      // causes of a provider rejecting a request outright.
      expect(history.pendingToolCalls.map((c) => c.id), <String>['b']);
    });
  });

  group('TokenUsage', () {
    test('derives a total when the provider did not send one', () {
      const usage = TokenUsage(promptTokens: 10, completionTokens: 5);

      expect(usage.totalTokens, 15);
    });

    test('keeps a provider total that disagrees with the sum', () {
      // Cached and reasoning tokens are counted differently across vendors,
      // and the provider's number is the one that gets billed.
      const usage = TokenUsage(
        promptTokens: 10,
        completionTokens: 5,
        totalTokens: 12,
      );

      expect(usage.totalTokens, 12);
    });

    test('adds field by field', () {
      const a = TokenUsage(
        promptTokens: 10,
        completionTokens: 5,
        cachedPromptTokens: 8,
      );
      const b = TokenUsage(promptTokens: 3, completionTokens: 1);

      final sum = a + b;

      expect(sum.promptTokens, 13);
      expect(sum.completionTokens, 6);
      expect(sum.cachedPromptTokens, 8);
      expect(sum.totalTokens, 19);
    });

    test('sums an iterable from the empty identity', () {
      expect(<TokenUsage>[].sum(), TokenUsage.empty);
      expect(
        <TokenUsage>[
          const TokenUsage(promptTokens: 1),
          const TokenUsage(promptTokens: 2),
        ].sum().promptTokens,
        3,
      );
    });

    test('reports the cache hit rate without dividing by zero', () {
      expect(TokenUsage.empty.cacheHitRate, 0);
      expect(
        const TokenUsage(
          promptTokens: 100,
          cachedPromptTokens: 75,
        ).cacheHitRate,
        0.75,
      );
      expect(
        const TokenUsage(
          promptTokens: 100,
          cachedPromptTokens: 75,
        ).uncachedPromptTokens,
        25,
      );
    });
  });
}
