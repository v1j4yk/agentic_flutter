/// A small Markdown parser, sized for what a model answers with.
///
/// # Why not a Markdown package
///
/// Two reasons, and neither is "it was easy". The first is the dependency:
/// this is the umbrella package every application depends on, and a parser
/// here is a parser in every app whether or not it renders Markdown. The
/// second is streaming, which general parsers get wrong in a specific way —
/// they are written for a finished document, so a half-arrived
/// ```` ``` ```` fence is a syntax error rather than a code block that has
/// not closed yet. In a chat that flickers, on every answer that contains code.
///
/// So this parses the subset models actually emit, treats the tail as
/// provisional, and stays under a few hundred lines. Anything richer is an
/// application implementing `MessageRenderer` over the package of its choice.
library;

import 'package:meta/meta.dart';

/// A block-level piece of a message.
@immutable
sealed class MarkdownBlock {
  const MarkdownBlock();
}

/// One or more lines of prose.
@immutable
final class ParagraphBlock extends MarkdownBlock {
  /// Creates a paragraph.
  const ParagraphBlock(this.spans);

  /// The inline content.
  final List<InlineSpanNode> spans;
}

/// A `#`-prefixed heading, levels 1 to 3.
@immutable
final class HeadingBlock extends MarkdownBlock {
  /// Creates a heading.
  const HeadingBlock({required this.level, required this.spans});

  /// 1, 2 or 3. Deeper headings are rendered as level 3: a model writing
  /// `#####` inside a chat bubble means "small heading", not a document
  /// outline.
  final int level;

  /// The inline content.
  final List<InlineSpanNode> spans;
}

/// A bullet or numbered list.
@immutable
final class ListBlock extends MarkdownBlock {
  /// Creates a list.
  const ListBlock({required this.items, required this.ordered});

  /// Each item's inline content.
  final List<List<InlineSpanNode>> items;

  /// Whether the list was numbered.
  final bool ordered;
}

/// A `>`-prefixed quote.
@immutable
final class QuoteBlock extends MarkdownBlock {
  /// Creates a quote.
  const QuoteBlock(this.spans);

  /// The inline content.
  final List<InlineSpanNode> spans;
}

/// A fenced code block.
@immutable
final class CodeBlock extends MarkdownBlock {
  /// Creates a code block.
  const CodeBlock({required this.code, this.language, this.isComplete = true});

  /// The code, without the fences.
  final String code;

  /// The language written after the opening fence, when there was one.
  final String? language;

  /// Whether the closing fence had arrived.
  ///
  /// False while a block is still streaming. It renders identically — the
  /// point is that it renders at all, rather than waiting for a fence that
  /// arrives a second later.
  final bool isComplete;
}

/// A horizontal rule.
@immutable
final class RuleBlock extends MarkdownBlock {
  /// Creates a rule.
  const RuleBlock();
}

/// A run of inline content.
@immutable
sealed class InlineSpanNode {
  const InlineSpanNode();

  /// The text this node contributes, without its markers.
  String get text;
}

/// Plain text.
@immutable
final class TextNode extends InlineSpanNode {
  /// Creates a text node.
  const TextNode(this.text);

  @override
  final String text;
}

/// `**bold**`.
@immutable
final class BoldNode extends InlineSpanNode {
  /// Creates a bold node.
  const BoldNode(this.text);

  @override
  final String text;
}

/// `*italic*` or `_italic_`.
@immutable
final class ItalicNode extends InlineSpanNode {
  /// Creates an italic node.
  const ItalicNode(this.text);

  @override
  final String text;
}

/// `` `code` ``.
@immutable
final class CodeNode extends InlineSpanNode {
  /// Creates an inline-code node.
  const CodeNode(this.text);

  @override
  final String text;
}

/// `[text](target)`.
@immutable
final class LinkNode extends InlineSpanNode {
  /// Creates a link node.
  const LinkNode({required this.text, required this.target});

  @override
  final String text;

  /// Where the link points.
  final String target;
}

/// Splits [source] into blocks.
///
/// Never throws and never returns a failure: whatever arrives is rendered as
/// the closest thing it resembles. A chat bubble showing slightly wrong
/// emphasis is a small problem; a chat bubble showing an exception is not.
List<MarkdownBlock> parseMarkdownBlocks(String source) {
  final blocks = <MarkdownBlock>[];
  final lines = source.split('\n');
  final paragraph = <String>[];

  void flushParagraph() {
    if (paragraph.isEmpty) return;
    blocks.add(ParagraphBlock(parseInline(paragraph.join('\n').trim())));
    paragraph.clear();
  }

  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];
    final trimmed = line.trim();

    // A fence opens a code block that runs to the next fence — or, while the
    // answer is still arriving, to the end of what we have.
    if (trimmed.startsWith('```')) {
      flushParagraph();
      final language = trimmed.substring(3).trim();
      final code = <String>[];
      var closed = false;
      for (i++; i < lines.length; i++) {
        if (lines[i].trim().startsWith('```')) {
          closed = true;
          break;
        }
        code.add(lines[i]);
      }
      blocks.add(
        CodeBlock(
          code: code.join('\n'),
          language: language.isEmpty ? null : language,
          isComplete: closed,
        ),
      );
      continue;
    }

    if (trimmed.isEmpty) {
      flushParagraph();
      continue;
    }

    if (_rule.hasMatch(trimmed)) {
      flushParagraph();
      blocks.add(const RuleBlock());
      continue;
    }

    if (_heading.firstMatch(trimmed) case final match?) {
      flushParagraph();
      blocks.add(
        HeadingBlock(
          level: match.group(1)!.length.clamp(1, 3),
          spans: parseInline(match.group(2)!),
        ),
      );
      continue;
    }

    if (trimmed.startsWith('> ') || trimmed == '>') {
      flushParagraph();
      final quoted = <String>[trimmed.replaceFirst(RegExp('^> ?'), '')];
      while (i + 1 < lines.length &&
          (lines[i + 1].trim().startsWith('> ') ||
              lines[i + 1].trim() == '>')) {
        i++;
        quoted.add(lines[i].trim().replaceFirst(RegExp('^> ?'), ''));
      }
      blocks.add(QuoteBlock(parseInline(quoted.join('\n').trim())));
      continue;
    }

    final bullet = _bullet.firstMatch(trimmed);
    final numbered = _numbered.firstMatch(trimmed);
    if (bullet != null || numbered != null) {
      flushParagraph();
      final ordered = numbered != null;
      final items = <List<InlineSpanNode>>[
        parseInline((bullet ?? numbered)!.group(1)!),
      ];
      while (i + 1 < lines.length) {
        final next = lines[i + 1].trim();
        final match = ordered
            ? _numbered.firstMatch(next)
            : _bullet.firstMatch(next);
        if (match == null) break;
        i++;
        items.add(parseInline(match.group(1)!));
      }
      blocks.add(ListBlock(items: items, ordered: ordered));
      continue;
    }

    paragraph.add(line);
  }

  flushParagraph();
  return blocks;
}

/// Splits one block's text into inline nodes.
///
/// Scans once, left to right. An unclosed marker is text, which is what makes
/// this safe mid-stream: `**bold` is two asterisks and a word until the
/// closing pair arrives, not an error and not a swallowed line.
List<InlineSpanNode> parseInline(String source) {
  final nodes = <InlineSpanNode>[];
  final buffer = StringBuffer();

  void flush() {
    if (buffer.isEmpty) return;
    nodes.add(TextNode(buffer.toString()));
    buffer.clear();
  }

  var i = 0;
  while (i < source.length) {
    final rest = source.substring(i);

    // Inline code first: inside backticks, no other marker applies.
    if (rest.startsWith('`')) {
      final end = rest.indexOf('`', 1);
      if (end > 1) {
        flush();
        nodes.add(CodeNode(rest.substring(1, end)));
        i += end + 1;
        continue;
      }
    }

    if (rest.startsWith('**')) {
      final end = rest.indexOf('**', 2);
      if (end > 2) {
        flush();
        nodes.add(BoldNode(rest.substring(2, end)));
        i += end + 2;
        continue;
      }
    }

    if ((rest.startsWith('*') && !rest.startsWith('**')) ||
        rest.startsWith('_')) {
      final marker = rest[0];
      final end = rest.indexOf(marker, 1);
      // A marker with nothing between it and the next one is literal: `a * b`
      // is arithmetic, not emphasis.
      if (end > 1 && !rest.substring(1, end).startsWith(' ')) {
        flush();
        nodes.add(ItalicNode(rest.substring(1, end)));
        i += end + 1;
        continue;
      }
    }

    if (rest.startsWith('[')) {
      final match = _link.matchAsPrefix(rest);
      if (match != null) {
        flush();
        nodes.add(LinkNode(text: match.group(1)!, target: match.group(2)!));
        i += match.end;
        continue;
      }
    }

    buffer.write(source[i]);
    i++;
  }

  flush();
  return nodes;
}

final RegExp _heading = RegExp(r'^(#{1,6})\s+(.*)$');
final RegExp _bullet = RegExp(r'^[-*+]\s+(.*)$');
final RegExp _numbered = RegExp(r'^\d+[.)]\s+(.*)$');
final RegExp _rule = RegExp(r'^(-{3,}|\*{3,}|_{3,})$');
final RegExp _link = RegExp(r'\[([^\]]*)\]\(([^)\s]+)\)');
