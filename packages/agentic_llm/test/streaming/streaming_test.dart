import 'dart:convert';

import 'package:agentic_core/agentic_core.dart';
import 'package:agentic_llm/agentic_llm.dart';
import 'package:test/test.dart';

/// Splits [text] into byte chunks of exactly [size], to reproduce the way a
/// network delivers a response.
Stream<List<int>> chunked(String text, int size) async* {
  final bytes = utf8.encode(text);
  for (var i = 0; i < bytes.length; i += size) {
    yield bytes.sublist(i, i + size > bytes.length ? bytes.length : i + size);
  }
}

void main() {
  group('SSE parsing', () {
    test('parses a simple event stream', () async {
      const raw = 'data: one\n\ndata: two\n\n';

      final events = await decodeServerSentEvents(chunked(raw, 1024)).toList();

      expect(events.map((e) => e.data), <String>['one', 'two']);
    });

    test('reassembles a line split across chunk boundaries', () async {
      // The failure this prevents: splitting per HTTP chunk yields two
      // fragments of invalid JSON and silently drops a token.
      const raw = 'data: {"choices":[{"delta":{"content":"Hello"}}]}\n\n';

      for (final size in <int>[1, 3, 7, 16, 1024]) {
        final events = await decodeServerSentEvents(
          chunked(raw, size),
        ).toList();

        expect(events, hasLength(1), reason: 'chunk size $size');
        expect(
          events.single.json().requireList('choices'),
          hasLength(1),
          reason: 'chunk size $size',
        );
      }
    });

    test('survives a multi-byte character split mid-codepoint', () async {
      // A naive per-chunk utf8.decode corrupts this. It is invisible in English
      // tests and obvious to the first user typing Japanese.
      const raw = 'data: {"text":"こんにちは世界"}\n\n';

      for (final size in <int>[1, 2, 3, 5, 8]) {
        final events = await decodeServerSentEvents(
          chunked(raw, size),
        ).toList();

        expect(
          events.single.json().requireString('text'),
          'こんにちは世界',
          reason: 'chunk size $size',
        );
      }
    });

    test('joins multiple data lines with newlines', () async {
      const raw = 'data: first\ndata: second\n\n';

      final events = await decodeServerSentEvents(chunked(raw, 4)).toList();

      expect(events.single.data, 'first\nsecond');
    });

    test('reads the event name', () async {
      const raw = 'event: content_block_delta\ndata: {}\n\n';

      final events = await decodeServerSentEvents(chunked(raw, 5)).toList();

      expect(events.single.event, 'content_block_delta');
    });

    test('discards comment keep-alives', () async {
      const raw = ': ping\n\ndata: real\n\n';

      final events = await decodeServerSentEvents(chunked(raw, 3)).toList();

      expect(events.map((e) => e.data), <String>['real']);
    });

    test('strips exactly one leading space from a value', () async {
      // A streamed token frequently begins with a space; stripping all
      // whitespace would silently delete it and run words together.
      final events = await decodeServerSentEventLines(
        Stream<String>.fromIterable(<String>['data:  leading', '']),
      ).toList();

      expect(events.single.data, ' leading');
    });

    test('handles CRLF line endings', () async {
      const raw = 'data: one\r\n\r\ndata: two\r\n\r\n';

      final events = await decodeServerSentEvents(chunked(raw, 6)).toList();

      expect(events.map((e) => e.data), <String>['one', 'two']);
    });

    test('emits a trailing event with no closing blank line', () async {
      // Several providers close the connection this way.
      const raw = 'data: last';

      final events = await decodeServerSentEvents(chunked(raw, 2)).toList();

      expect(events.single.data, 'last');
    });

    test('ignores unknown fields rather than failing', () async {
      const raw = 'unknown: x\ndata: kept\n\n';

      final events = await decodeServerSentEvents(chunked(raw, 4)).toList();

      expect(events.single.data, 'kept');
    });

    test('reports non-JSON payloads with the offending text', () async {
      final events = await decodeServerSentEventLines(
        Stream<String>.fromIterable(<String>['data: <!DOCTYPE html>', '']),
      ).toList();

      expect(
        events.single.json,
        throwsA(
          isA<SerializationException>().having(
            (e) => e.message,
            'message',
            contains('<!DOCTYPE html>'),
          ),
        ),
      );
    });
  });

  group('ChatResponseBuilder', () {
    test('concatenates text deltas', () {
      final builder = ChatResponseBuilder(modelId: 'm')
        ..addAll(const <ChatChunk>[
          ChatChunk.text('Hello'),
          ChatChunk.text(', '),
          ChatChunk.text('world'),
          ChatChunk.done(reason: FinishReason.stop),
        ]);

      expect(builder.build().text, 'Hello, world');
    });

    test('assembles a tool call from JSON fragments', () {
      // No individual fragment is valid JSON. This is the shape OpenAI
      // actually streams.
      final builder = ChatResponseBuilder(modelId: 'm')
        ..addAll(const <ChatChunk>[
          ChatChunk.tool(
            ToolCallDelta(index: 0, id: 'call_1', name: 'search_web'),
          ),
          ChatChunk.tool(ToolCallDelta(index: 0, argumentsDelta: '{"qu')),
          ChatChunk.tool(ToolCallDelta(index: 0, argumentsDelta: 'ery":"da')),
          ChatChunk.tool(ToolCallDelta(index: 0, argumentsDelta: 'rt 3"}')),
          ChatChunk.done(reason: FinishReason.toolCalls),
        ]);

      final call = builder.build().toolCalls.single;
      expect(call.id, 'call_1');
      expect(call.name, 'search_web');
      expect(call.arguments, <String, Object?>{'query': 'dart 3'});
      expect(call.rawArguments, '{"query":"dart 3"}');
    });

    test('keeps interleaved parallel tool calls apart', () {
      // Fragments for several calls arrive interleaved, distinguished only by
      // index. Losing that correlation splices two calls together.
      final builder = ChatResponseBuilder(modelId: 'm')
        ..addAll(const <ChatChunk>[
          ChatChunk.tool(ToolCallDelta(index: 0, id: 'a', name: 'search')),
          ChatChunk.tool(ToolCallDelta(index: 1, id: 'b', name: 'read')),
          ChatChunk.tool(ToolCallDelta(index: 0, argumentsDelta: '{"q":')),
          ChatChunk.tool(ToolCallDelta(index: 1, argumentsDelta: '{"p":')),
          ChatChunk.tool(ToolCallDelta(index: 0, argumentsDelta: '"x"}')),
          ChatChunk.tool(ToolCallDelta(index: 1, argumentsDelta: '"y"}')),
          ChatChunk.done(reason: FinishReason.toolCalls),
        ]);

      final calls = builder.build().toolCalls;
      expect(calls.map((c) => c.name), <String>['search', 'read']);
      expect(calls[0].arguments, <String, Object?>{'q': 'x'});
      expect(calls[1].arguments, <String, Object?>{'p': 'y'});
    });

    test('orders tool calls by provider index, not arrival', () {
      final builder = ChatResponseBuilder(modelId: 'm')
        ..addAll(const <ChatChunk>[
          ChatChunk.tool(ToolCallDelta(index: 1, id: 'b', name: 'second')),
          ChatChunk.tool(ToolCallDelta(index: 0, id: 'a', name: 'first')),
          ChatChunk.done(reason: FinishReason.toolCalls),
        ]);

      expect(builder.build().toolCalls.map((c) => c.name), <String>[
        'first',
        'second',
      ]);
    });

    test('tolerates truncated tool-call JSON instead of throwing', () {
      // A stream cut off by the token limit must not take down the call. The
      // executor validates the empty arguments and the model repairs them.
      final builder = ChatResponseBuilder(modelId: 'm')
        ..addAll(const <ChatChunk>[
          ChatChunk.tool(ToolCallDelta(index: 0, id: 'c', name: 'search')),
          ChatChunk.tool(
            ToolCallDelta(index: 0, argumentsDelta: '{"query":"da'),
          ),
          ChatChunk.done(reason: FinishReason.length),
        ]);

      final call = builder.build().toolCalls.single;
      expect(call.arguments, isEmpty);
      expect(
        call.rawArguments,
        '{"query":"da',
        reason: 'the raw text is the only diagnostic left',
      );
    });

    test('synthesises an id when the provider sent none', () {
      final builder = ChatResponseBuilder(modelId: 'm')
        ..add(const ChatChunk.tool(ToolCallDelta(index: 2, name: 'search')));

      expect(builder.build().toolCalls.single.id, 'call_2');
    });

    test('replaces usage rather than summing it', () {
      // Some providers send a running total on every chunk. Summing would
      // multiply the reported bill by the chunk count.
      final builder = ChatResponseBuilder(modelId: 'm')
        ..addAll(const <ChatChunk>[
          ChatChunk(usage: TokenUsage(promptTokens: 10, completionTokens: 1)),
          ChatChunk(usage: TokenUsage(promptTokens: 10, completionTokens: 2)),
          ChatChunk(usage: TokenUsage(promptTokens: 10, completionTokens: 3)),
          ChatChunk.done(),
        ]);

      expect(builder.build().usage.completionTokens, 3);
      expect(builder.build().usage.promptTokens, 10);
    });

    test('ignores an empty usage frame', () {
      final builder = ChatResponseBuilder(modelId: 'm')
        ..addAll(const <ChatChunk>[
          ChatChunk(usage: TokenUsage(promptTokens: 7, completionTokens: 2)),
          ChatChunk(usage: TokenUsage.empty),
          ChatChunk.done(),
        ]);

      expect(builder.build().usage.promptTokens, 7);
    });

    test('orders parts as reasoning, text, then tool calls', () {
      // The same order a non-streaming response produces, so a transcript looks
      // identical either way.
      final builder = ChatResponseBuilder(modelId: 'm')
        ..addAll(const <ChatChunk>[
          ChatChunk.text('answer'),
          ChatChunk.reasoning('thinking'),
          ChatChunk.tool(ToolCallDelta(index: 0, id: 'a', name: 't')),
          ChatChunk.done(reason: FinishReason.toolCalls),
        ]);

      final parts = builder.build().message.parts;
      expect(parts[0], isA<ReasoningPart>());
      expect(parts[1], isA<TextPart>());
      expect(parts[2], isA<ToolCallPart>());
    });

    test('captures a reasoning signature for the next turn', () {
      final builder = ChatResponseBuilder(modelId: 'm')
        ..addAll(const <ChatChunk>[
          ChatChunk.reasoning('thinking'),
          ChatChunk(reasoningSignature: 'sig-abc'),
          ChatChunk.done(),
        ]);

      final part = builder
          .build()
          .message
          .parts
          .whereType<ReasoningPart>()
          .single;
      expect(part.signature, 'sig-abc');
    });

    test('exposes partial state while the stream is running', () {
      final builder = ChatResponseBuilder(modelId: 'm')
        ..add(const ChatChunk.text('par'));

      expect(builder.text, 'par');
      expect(builder.isComplete, isFalse);

      builder.add(const ChatChunk.done());
      expect(builder.isComplete, isTrue);
    });

    test('reports an unknown finish reason when built early', () {
      final builder = ChatResponseBuilder(modelId: 'm')
        ..add(const ChatChunk.text('partial'));

      expect(builder.build().finishReason, FinishReason.unknown);
    });

    test('reset clears everything', () {
      final builder = ChatResponseBuilder(modelId: 'm')
        ..add(const ChatChunk.text('x'))
        ..reset();

      expect(builder.text, isEmpty);
      expect(builder.chunkCount, 0);
    });
  });

  group('stream extensions', () {
    final chunks = Stream<ChatChunk>.fromIterable(const <ChatChunk>[
      ChatChunk.text('Hello'),
      ChatChunk(),
      ChatChunk.text(' world'),
      ChatChunk.done(
        reason: FinishReason.stop,
        usage: TokenUsage(promptTokens: 5, completionTokens: 2),
      ),
    ]);

    test('collect assembles a complete response', () async {
      final response = await chunks.collect(modelId: 'm');

      expect(response.text, 'Hello world');
      expect(response.finishReason, FinishReason.stop);
      expect(response.usage.totalTokens, 7);
    });

    test('textDeltas drops metadata chunks', () async {
      expect(await chunks.textDeltas.toList(), <String>['Hello', ' world']);
    });

    test('cumulativeText emits the whole answer each time', () async {
      expect(await chunks.cumulativeText.toList(), <String>[
        'Hello',
        'Hello world',
      ]);
    });
  });
}
