/// Rendering what a model actually writes, including half of it.
library;

import 'package:agentic_flutter/agentic_flutter.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// The text of every node in a block, joined — what a reader would see.
String textOf(List<InlineSpanNode> spans) => spans.map((s) => s.text).join();

Widget wrap(Widget child) => MaterialApp(
  home: Scaffold(body: SingleChildScrollView(child: child)),
);

void main() {
  group('blocks', () {
    test('prose is one paragraph per blank-line-separated run', () {
      final blocks = parseMarkdownBlocks(
        'First line.\nSame paragraph.\n\nSecond.',
      );

      expect(blocks, hasLength(2));
      expect(
        textOf((blocks.first as ParagraphBlock).spans),
        'First line.\nSame paragraph.',
      );
    });

    test('headings deeper than three render as three', () {
      // A model writing ##### inside a chat bubble means "small heading", not
      // a document outline.
      final blocks = parseMarkdownBlocks('# One\n## Two\n##### Five');

      expect(blocks.map((b) => (b as HeadingBlock).level), <int>[1, 2, 3]);
      expect(textOf((blocks.first as HeadingBlock).spans), 'One');
    });

    test('bullets and numbers become lists, and mixing them ends one', () {
      final blocks = parseMarkdownBlocks('- one\n- two\n\n1. first\n2. second');

      final bullets = blocks.first as ListBlock;
      expect(bullets.ordered, isFalse);
      expect(bullets.items.map(textOf), <String>['one', 'two']);

      final numbers = blocks.last as ListBlock;
      expect(numbers.ordered, isTrue);
      expect(numbers.items.map(textOf), <String>['first', 'second']);
    });

    test('a fenced block keeps its language and its indentation', () {
      final blocks = parseMarkdownBlocks(
        'Try this:\n```dart\nvoid main() {\n  print(1);\n}\n```\nDone.',
      );

      final code = blocks[1] as CodeBlock;
      expect(code.language, 'dart');
      expect(code.code, 'void main() {\n  print(1);\n}');
      expect(code.isComplete, isTrue);
      expect(blocks, hasLength(3));
    });

    test('an unclosed fence is a code block that has not finished', () {
      // The streaming case. A parser that waits for the closing fence renders
      // nothing until the answer lands; one that errors flickers.
      final blocks = parseMarkdownBlocks('Here:\n```python\nprint("half a');

      final code = blocks.last as CodeBlock;
      expect(code.isComplete, isFalse);
      expect(code.language, 'python');
      expect(code.code, 'print("half a');
    });

    test('quotes and rules are their own blocks', () {
      final blocks = parseMarkdownBlocks('> quoted\n> lines\n\n---\n\nafter');

      expect(textOf((blocks.first as QuoteBlock).spans), 'quoted\nlines');
      expect(blocks[1], isA<RuleBlock>());
      expect(blocks.last, isA<ParagraphBlock>());
    });

    test('empty input renders nothing rather than an empty paragraph', () {
      expect(parseMarkdownBlocks(''), isEmpty);
      expect(parseMarkdownBlocks('   \n\n  '), isEmpty);
    });
  });

  group('inline', () {
    test('emphasis, code and links are recognised', () {
      final spans = parseInline(
        'A **bold** and *italic* with `code` and [a link](https://x.dev).',
      );

      expect(spans.whereType<BoldNode>().single.text, 'bold');
      expect(spans.whereType<ItalicNode>().single.text, 'italic');
      expect(spans.whereType<CodeNode>().single.text, 'code');
      final link = spans.whereType<LinkNode>().single;
      expect(link.text, 'a link');
      expect(link.target, 'https://x.dev');
    });

    test('an unclosed marker stays text', () {
      // Mid-stream, every emphasis is briefly unclosed. It must read as the
      // characters that arrived, not vanish and reappear.
      expect(textOf(parseInline('A **bold half')), 'A **bold half');
      expect(parseInline('A **bold half').whereType<BoldNode>(), isEmpty);
      expect(textOf(parseInline('an `open code')), 'an `open code');
    });

    test('arithmetic is not emphasis', () {
      // `2 * 3 * 4` is multiplication, and a renderer that italicises part of
      // it is worse than one that renders nothing.
      final spans = parseInline('2 * 3 * 4');
      expect(spans.whereType<ItalicNode>(), isEmpty);
      expect(textOf(spans), '2 * 3 * 4');
    });

    test('underscores inside identifiers are left alone', () {
      final spans = parseInline('call agentic_core.dart now');
      expect(textOf(spans), 'call agentic_core.dart now');
    });

    test('code spans win over emphasis inside them', () {
      final spans = parseInline('use `a **b** c` here');
      expect(spans.whereType<CodeNode>().single.text, 'a **b** c');
      expect(spans.whereType<BoldNode>(), isEmpty);
    });
  });

  group('widgets', () {
    testWidgets('plain is the default, and shows the text as sent', (
      tester,
    ) async {
      await tester.pumpWidget(
        wrap(ChatEntryTile(entry: _entry('**not bold** here'))),
      );

      expect(find.text('**not bold** here'), findsOneWidget);
    });

    testWidgets('the Markdown renderer strips the markers', (tester) async {
      await tester.pumpWidget(
        wrap(
          ChatEntryTile(
            entry: _entry('# Title\n\nSome **bold** text.'),
            renderer: const MarkdownMessageRenderer(),
          ),
        ),
      );

      expect(find.text('Title'), findsOneWidget);
      expect(find.textContaining('**'), findsNothing);
    });

    testWidgets('a code block copies its code, and says it did', (
      tester,
    ) async {
      // Mock the platform channel rather than trusting the default: the
      // assertion worth making is that the *code* reached the clipboard, not
      // that a label changed.
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied =
                (call.arguments as Map<Object?, Object?>)['text'] as String?;
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );

      await tester.pumpWidget(
        wrap(
          ChatEntryTile(
            entry: _entry('```dart\nvoid main() {}\n```'),
            renderer: const MarkdownMessageRenderer(),
          ),
        ),
      );

      expect(find.text('dart'), findsOneWidget);

      await tester.tap(find.text('Copy'));
      await tester.pump();

      expect(copied, 'void main() {}');
      expect(find.text('Copied'), findsOneWidget);

      // The label reverts on a timer; letting it fire keeps the test from
      // ending with a pending one.
      await tester.pump(const Duration(seconds: 2));
      expect(find.text('Copy'), findsOneWidget);
    });

    testWidgets('copying can be turned off', (tester) async {
      await tester.pumpWidget(
        wrap(
          ChatEntryTile(
            entry: _entry('```\nplain\n```'),
            renderer: const MarkdownMessageRenderer(showCopyButton: false),
          ),
        ),
      );

      expect(find.text('Copy'), findsNothing);
      expect(find.text('plain'), findsOneWidget);
    });

    testWidgets('a half-arrived code block still renders', (tester) async {
      await tester.pumpWidget(
        wrap(
          ChatEntryTile(
            entry: _entry('```dart\nvoid main() {', isStreaming: true),
            renderer: const MarkdownMessageRenderer(),
          ),
        ),
      );

      expect(find.text('void main() {'), findsOneWidget);
    });

    testWidgets('an error is shown as our sentence, not as Markdown', (
      tester,
    ) async {
      await tester.pumpWidget(
        wrap(
          ChatEntryTile(
            entry: ChatEntry(
              id: 'e',
              message: Message.assistant(''),
              error: RateLimitException('slow down', provider: 'openai'),
            ),
            renderer: const MarkdownMessageRenderer(),
          ),
        ),
      );

      // Whatever the wording, it is the framework's, and it rendered.
      expect(find.byType(SelectableText), findsWidgets);
    });

    testWidgets('a tapped link reports its target', (tester) async {
      final tapped = <Uri>[];
      await tester.pumpWidget(
        wrap(
          ChatEntryTile(
            entry: _entry('See [the docs](https://agentic.dev/guide).'),
            renderer: const MarkdownMessageRenderer(),
            onLinkTap: tapped.add,
          ),
        ),
      );

      await tester.tap(find.textContaining('the docs'));
      await tester.pump();

      expect(tapped.single, Uri.parse('https://agentic.dev/guide'));
    });
  });
}

/// A finished assistant entry carrying [text].
ChatEntry _entry(String text, {bool isStreaming = false}) => ChatEntry(
  id: 'entry',
  message: Message.assistant(text),
  isStreaming: isStreaming,
);
