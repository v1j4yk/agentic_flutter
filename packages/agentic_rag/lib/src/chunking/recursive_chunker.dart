/// Splitting prose along the strongest boundary that fits.
library;

import 'package:agentic_rag/src/chunking/chunker.dart';
import 'package:agentic_rag/src/model/document.dart';

/// Splits text by trying progressively weaker separators.
///
/// # How it works
///
/// The text is split on the strongest separator available — blank lines, then
/// single newlines, then sentence ends, then spaces, then bare characters.
/// Pieces are accumulated until adding the next one would exceed
/// [ChunkOptions.maxChars]; anything still too large is split again with the
/// next separator down.
///
/// The effect is that a paragraph stays whole whenever it fits, and only text
/// that genuinely cannot fit gets cut mid-sentence. A fixed-width splitter, by
/// contrast, cuts every chunk mid-sentence regardless — and every one of those
/// cuts is a passage that no longer reads as an answer.
///
/// This is the default for prose and the right starting point for almost any
/// corpus.
///
/// ```dart
/// const chunker = RecursiveChunker(
///   options: ChunkOptions(maxChars: 800, overlapChars: 100),
/// );
/// final chunks = chunker.chunk(document);
/// ```
final class RecursiveChunker extends BaseChunker {
  /// Creates a recursive chunker.
  ///
  /// [separators] are tried in order, strongest first. The default list works
  /// for prose and Markdown; a corpus of code or CSV wants its own.
  const RecursiveChunker({
    super.options,
    this.separators = const <String>['\n\n', '\n', '. ', ' ', ''],
  });

  /// Boundaries to try, strongest first.
  ///
  /// An empty string as the last entry means "cut anywhere", and it must stay
  /// last: without it a single unbroken 50,000-character line has no boundary
  /// at all and would come back as one oversized chunk.
  final List<String> separators;

  @override
  String get name => 'recursive';

  @override
  List<ChunkPiece> split(RagDocument document) {
    final pieces = _splitText(document.content, 0);
    return _withOverlap(pieces);
  }

  /// Splits [text] using the separator at [depth] or weaker.
  List<_Span> _splitText(String text, int depth) {
    if (text.trim().isEmpty) return const <_Span>[];
    if (text.length <= options.maxChars) {
      return <_Span>[_Span(text, 0)];
    }
    if (depth >= separators.length) {
      // Out of separators: hard-cut what is left, which only happens for text
      // with no whitespace at all.
      return <_Span>[
        for (var start = 0; start < text.length; start += options.maxChars)
          _Span(
            text.substring(
              start,
              start + options.maxChars < text.length
                  ? start + options.maxChars
                  : text.length,
            ),
            start,
          ),
      ];
    }

    final separator = separators[depth];
    if (separator.isEmpty) return _splitText(text, separators.length);

    final parts = _splitKeepingSeparator(text, separator);
    final spans = <_Span>[];
    final buffer = StringBuffer();
    var bufferStart = 0;
    var cursor = 0;

    void flush() {
      if (buffer.isEmpty) return;
      spans.add(_Span(buffer.toString(), bufferStart));
      buffer.clear();
    }

    for (final part in parts) {
      final partStart = cursor;
      cursor += part.length;
      if (part.trim().isEmpty && buffer.isEmpty) continue;

      if (part.length > options.maxChars) {
        // This single part is oversized; flush what we have and recurse into it
        // with a weaker separator.
        flush();
        for (final inner in _splitText(part, depth + 1)) {
          spans.add(_Span(inner.text, partStart + inner.start));
        }
        continue;
      }
      if (buffer.length + part.length > options.maxChars) flush();
      if (buffer.isEmpty) bufferStart = partStart;
      buffer.write(part);
    }
    flush();
    return spans;
  }

  /// Splits on [separator] while keeping it attached to the preceding part.
  ///
  /// Keeping it matters: dropping `. ` would concatenate sentences into
  /// `oneTwo`, and dropping `\n\n` would run paragraphs together in the text
  /// the model eventually reads.
  static List<String> _splitKeepingSeparator(String text, String separator) {
    final parts = <String>[];
    var start = 0;
    while (true) {
      final at = text.indexOf(separator, start);
      if (at < 0) break;
      parts.add(text.substring(start, at + separator.length));
      start = at + separator.length;
    }
    if (start < text.length) parts.add(text.substring(start));
    return parts;
  }

  /// Prepends the tail of each chunk to its successor, and folds small tails.
  List<ChunkPiece> _withOverlap(List<_Span> spans) {
    if (spans.isEmpty) return const <ChunkPiece>[];

    final merged = <_Span>[];
    for (final span in spans) {
      final tooSmall =
          span.text.trim().length < options.minChars && merged.isNotEmpty;
      if (tooSmall) {
        final previous = merged.removeLast();
        merged.add(_Span(previous.text + span.text, previous.start));
      } else {
        merged.add(span);
      }
    }

    if (options.overlapChars == 0) {
      return <ChunkPiece>[
        for (final span in merged)
          ChunkPiece(text: span.text, startOffset: span.start),
      ];
    }

    final pieces = <ChunkPiece>[];
    for (var i = 0; i < merged.length; i++) {
      final span = merged[i];
      if (i == 0) {
        pieces.add(ChunkPiece(text: span.text, startOffset: span.start));
        continue;
      }
      final previous = merged[i - 1].text;
      final take = options.overlapChars < previous.length
          ? options.overlapChars
          : previous.length;
      final overlap = previous.substring(previous.length - take);
      pieces.add(
        ChunkPiece(
          text: overlap + span.text,
          startOffset: span.start - take >= 0 ? span.start - take : span.start,
        ),
      );
    }
    return pieces;
  }
}

/// A piece of text and where it started.
final class _Span {
  const _Span(this.text, this.start);

  final String text;
  final int start;
}

/// Splits at a fixed width, ignoring structure.
///
/// Rarely the right choice for prose — it cuts mid-sentence by construction —
/// but exactly right for text with no structure to respect: base64 payloads,
/// log lines, OCR output with no paragraphing. It is also the honest baseline
/// to measure [RecursiveChunker] against on your own corpus.
final class FixedSizeChunker extends BaseChunker {
  /// Creates a fixed-width chunker.
  const FixedSizeChunker({super.options});

  @override
  String get name => 'fixed-size';

  @override
  List<ChunkPiece> split(RagDocument document) {
    final text = document.content;
    final stride = options.maxChars - options.overlapChars;
    final pieces = <ChunkPiece>[];
    for (var start = 0; start < text.length; start += stride) {
      final end = start + options.maxChars < text.length
          ? start + options.maxChars
          : text.length;
      pieces.add(
        ChunkPiece(text: text.substring(start, end), startOffset: start),
      );
      if (end == text.length) break;
    }
    return pieces;
  }
}
