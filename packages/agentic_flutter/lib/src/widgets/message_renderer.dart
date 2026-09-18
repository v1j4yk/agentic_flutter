/// How a message's text becomes widgets.
///
/// # Why this is a seam
///
/// Models answer in Markdown. Rendering that as plain text shows literal
/// asterisks and fences, which is the first thing anyone notices in a demo —
/// and rendering it *fully* means a CommonMark parser, an HTML subset, syntax
/// highlighting and a table layout, which is a package of its own and a
/// dependency every application would inherit.
///
/// So this is a port with two implementations: the plain one, and a Markdown
/// renderer covering what models actually emit. An application that wants
/// something richer implements [MessageRenderer] over its own package and
/// passes it to `AgentChatView` — in three lines, with nothing here to change.
///
/// # Streaming is the constraint the others do not have
///
/// Text arrives a token at a time, so at any moment the buffer ends
/// mid-word, mid-emphasis or inside an unterminated code fence. A renderer
/// that waits for well-formed input renders nothing until the answer lands;
/// one that treats a half-open fence as an error flickers. [MarkdownMessageRenderer]
/// treats the tail as provisional and renders it as what it is so far.
library;

import 'package:agentic_flutter/src/widgets/markdown_parse.dart';
import 'package:flutter/gestures.dart' show TapGestureRecognizer;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// One message's text, and what the caller knows about it.
@immutable
final class MessageRender {
  /// Describes a message to render.
  const MessageRender({
    required this.text,
    required this.style,
    this.isStreaming = false,
    this.onLinkTap,
  });

  /// The text to show, already resolved from the message's parts.
  final String text;

  /// The base style: colour and size come from the bubble, not the renderer.
  final TextStyle style;

  /// Whether more text is still arriving.
  final bool isStreaming;

  /// Called when a link is tapped, if the renderer supports links.
  ///
  /// Absent by default, and links are then rendered but inert: opening a URL
  /// needs `url_launcher`, which is a plugin, and the framework does not pull
  /// one in on an application's behalf.
  final void Function(Uri uri)? onLinkTap;
}

/// Turns a message's text into a widget.
///
/// ```dart
/// AgentChatView(
///   controller: chat,
///   renderer: const MarkdownMessageRenderer(),
/// );
/// ```
abstract interface class MessageRenderer {
  /// Builds the widget for [render].
  Widget build(BuildContext context, MessageRender render);
}

/// Renders text exactly as the model sent it.
///
/// The default, and the right choice when answers are short and prose-shaped,
/// or when the surrounding design has its own text handling.
final class PlainTextMessageRenderer implements MessageRenderer {
  /// Creates a plain-text renderer.
  const PlainTextMessageRenderer();

  @override
  Widget build(BuildContext context, MessageRender render) =>
      SelectableText(render.text, style: render.style);
}

/// Renders the Markdown subset models actually produce.
///
/// Headings, paragraphs, bullet and numbered lists, block quotes, fenced and
/// inline code, bold, italic and links. Deliberately not the whole of
/// CommonMark: no tables, no images, no HTML, no nested block structures.
/// Those appear rarely in an assistant's answer and each one costs more than
/// it returns here.
///
/// Fenced code blocks get a copy button, because the single most common thing
/// a person does with a code block in a chat is copy it.
final class MarkdownMessageRenderer implements MessageRenderer {
  /// Creates a Markdown renderer.
  const MarkdownMessageRenderer({
    this.codeBackground,
    this.showCopyButton = true,
    this.selectable = true,
  });

  /// Background for code blocks. Defaults to a surface tint from the theme.
  final Color? codeBackground;

  /// Whether a fenced code block shows a copy button.
  final bool showCopyButton;

  /// Whether text can be selected.
  ///
  /// Selection is worth the cost in a chat — people quote answers — but a
  /// transcript of hundreds of messages builds a selection overlay per block,
  /// so it can be turned off.
  final bool selectable;

  @override
  Widget build(BuildContext context, MessageRender render) {
    final blocks = parseMarkdownBlocks(render.text);
    if (blocks.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        for (final (index, block) in blocks.indexed) ...<Widget>[
          if (index > 0) SizedBox(height: block is CodeBlock ? 10 : 8),
          _buildBlock(context, block, render),
        ],
      ],
    );
  }

  Widget _buildBlock(
    BuildContext context,
    MarkdownBlock block,
    MessageRender render,
  ) => switch (block) {
    CodeBlock() => _CodeBlockView(
      block: block,
      style: render.style,
      background: codeBackground,
      showCopyButton: showCopyButton,
    ),
    HeadingBlock(:final level, :final spans) => _text(
      context,
      spans,
      render,
      style: render.style.copyWith(
        fontSize: render.style.fontSize == null
            ? null
            : render.style.fontSize! *
                  switch (level) {
                    1 => 1.4,
                    2 => 1.25,
                    _ => 1.12,
                  },
        fontWeight: FontWeight.w600,
        height: 1.3,
      ),
    ),
    QuoteBlock(:final spans) => Container(
      decoration: BoxDecoration(
        border: Border(
          left: BorderSide(
            color: render.style.color?.withValues(alpha: 0.4) ?? Colors.grey,
            width: 3,
          ),
        ),
      ),
      padding: const EdgeInsets.only(left: 10),
      child: _text(
        context,
        spans,
        render,
        style: render.style.copyWith(fontStyle: FontStyle.italic),
      ),
    ),
    ListBlock(:final items, :final ordered) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        for (final (index, item) in items.indexed)
          Padding(
            padding: EdgeInsets.only(top: index == 0 ? 0 : 4),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                SizedBox(
                  width: 22,
                  child: Text(
                    ordered ? '${index + 1}.' : '•',
                    style: render.style,
                  ),
                ),
                Flexible(child: _text(context, item, render)),
              ],
            ),
          ),
      ],
    ),
    ParagraphBlock(:final spans) => _text(context, spans, render),
    RuleBlock() => Divider(
      height: 12,
      color: render.style.color?.withValues(alpha: 0.3),
    ),
  };

  Widget _text(
    BuildContext context,
    List<InlineSpanNode> spans,
    MessageRender render, {
    TextStyle? style,
  }) {
    final base = style ?? render.style;
    final built = TextSpan(
      children: <InlineSpan>[
        for (final span in spans) _span(span, base, render.onLinkTap),
      ],
    );
    return selectable
        ? SelectableText.rich(built, style: base)
        : Text.rich(built, style: base);
  }

  InlineSpan _span(
    InlineSpanNode node,
    TextStyle base,
    void Function(Uri)? onLinkTap,
  ) => switch (node) {
    TextNode(:final text) => TextSpan(text: text, style: base),
    BoldNode(:final text) => TextSpan(
      text: text,
      style: base.copyWith(fontWeight: FontWeight.w700),
    ),
    ItalicNode(:final text) => TextSpan(
      text: text,
      style: base.copyWith(fontStyle: FontStyle.italic),
    ),
    CodeNode(:final text) => TextSpan(
      text: text,
      style: base.copyWith(
        fontFamily: 'monospace',
        fontFamilyFallback: const <String>['Menlo', 'Consolas', 'Courier New'],
        backgroundColor: base.color?.withValues(alpha: 0.12),
      ),
    ),
    LinkNode(:final text, :final target) => TextSpan(
      text: text,
      style: base.copyWith(
        decoration: TextDecoration.underline,
        decorationColor: base.color?.withValues(alpha: 0.6),
      ),
      recognizer: onLinkTap == null
          ? null
          : (TapGestureRecognizer()
              ..onTap = () {
                final uri = Uri.tryParse(target);
                if (uri != null) onLinkTap(uri);
              }),
    ),
  };
}

/// A fenced code block, rendered with its language and a copy button.
class _CodeBlockView extends StatelessWidget {
  const _CodeBlockView({
    required this.block,
    required this.style,
    required this.showCopyButton,
    this.background,
  });

  final CodeBlock block;
  final TextStyle style;
  final bool showCopyButton;
  final Color? background;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final code = style.copyWith(
      fontFamily: 'monospace',
      fontFamilyFallback: const <String>['Menlo', 'Consolas', 'Courier New'],
      fontSize: (style.fontSize ?? 14) - 1,
      height: 1.45,
    );

    return DecoratedBox(
      decoration: BoxDecoration(
        color:
            background ??
            theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (block.language != null || showCopyButton)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 6, 6, 0),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  if (block.language case final language?)
                    Text(
                      language,
                      style: code.copyWith(
                        fontSize: (code.fontSize ?? 13) - 1,
                        color: code.color?.withValues(alpha: 0.7),
                      ),
                    ),
                  const Spacer(),
                  if (showCopyButton)
                    _CopyButton(text: block.code, style: code),
                ],
              ),
            ),
          Padding(
            padding: EdgeInsets.fromLTRB(
              12,
              block.language == null && !showCopyButton ? 10 : 2,
              12,
              10,
            ),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: SelectableText(block.code, style: code),
            ),
          ),
        ],
      ),
    );
  }
}

/// Copies a code block, and says so for a moment.
class _CopyButton extends StatefulWidget {
  const _CopyButton({required this.text, required this.style});

  final String text;
  final TextStyle style;

  @override
  State<_CopyButton> createState() => _CopyButtonState();
}

class _CopyButtonState extends State<_CopyButton> {
  bool _copied = false;

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: widget.text));
    if (!mounted) return;
    setState(() => _copied = true);
    // Long enough to read, short enough that a second copy is not blocked by
    // the label from the first.
    await Future<void>.delayed(const Duration(seconds: 2));
    if (mounted) setState(() => _copied = false);
  }

  @override
  Widget build(BuildContext context) => TextButton.icon(
    onPressed: _copy,
    icon: Icon(_copied ? Icons.check : Icons.copy, size: 15),
    label: Text(_copied ? 'Copied' : 'Copy'),
    style: TextButton.styleFrom(
      minimumSize: Size.zero,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      textStyle: widget.style.copyWith(
        fontSize: (widget.style.fontSize ?? 13) - 1,
      ),
      foregroundColor: widget.style.color?.withValues(alpha: 0.8),
    ),
  );
}
