/// Splitting Markdown along its own structure.
library;

import 'package:agentic_rag/src/chunking/chunker.dart';
import 'package:agentic_rag/src/chunking/recursive_chunker.dart';
import 'package:agentic_rag/src/model/document.dart';

/// Splits Markdown at headings, keeping the heading path with each chunk.
///
/// # Why headings are the right boundary
///
/// A heading is the author's own statement of where one subject ends and the
/// next begins — better structural information than any character count. And
/// because the heading path travels with the chunk, a passage retrieved from
/// deep inside a manual still says what it is about: `Handbook › Billing ›
/// Refunds` in front of three paragraphs beats three anonymous paragraphs, both
/// for the model reading it and for the citation shown to the user.
///
/// Sections longer than [ChunkOptions.maxChars] are split further by
/// [RecursiveChunker], and every resulting piece keeps the same heading path.
///
/// Fenced code blocks are never split at a heading inside them — a `#` comment
/// in a shell snippet is not a section — and short sections are folded into
/// their predecessor rather than becoming a chunk that is nothing but a title.
///
/// ```dart
/// const chunker = MarkdownChunker(options: ChunkOptions(maxChars: 1200));
/// for (final chunk in chunker.chunk(document)) {
///   print('${chunk.heading}: ${chunk.text.length} chars');
/// }
/// ```
final class MarkdownChunker extends BaseChunker {
  /// Creates a Markdown chunker.
  const MarkdownChunker({
    super.options,
    this.maxHeadingDepth = 3,
    this.prependHeading = true,
  });

  /// Deepest heading level that starts a new section.
  ///
  /// Three by default. Splitting at every `####` produces sections of one
  /// sentence, which is the small-chunk failure in another costume.
  final int maxHeadingDepth;

  /// Whether each chunk's text begins with its heading path.
  ///
  /// On by default, and it matters more than it looks. Splitting at a heading
  /// removes that heading from the text below it — so a section titled
  /// `ERR_4418` whose body never repeats the code becomes unretrievable *by*
  /// that code, from either an embedding or a keyword index. The words an
  /// author put in a heading are usually the words a reader will search for.
  ///
  /// It costs a handful of tokens per chunk and also gives the model the
  /// section's context when it reads the passage, which is why the technique is
  /// standard practice.
  final bool prependHeading;

  @override
  String get name => 'markdown';

  @override
  List<ChunkPiece> split(RagDocument document) {
    final sections = _sections(document.content);
    final pieces = <ChunkPiece>[];

    for (final section in sections) {
      final body = section.body.trim();
      if (body.isEmpty) continue;

      final metadata = <String, Object?>{
        if (section.path.isNotEmpty) 'headingPath': section.path,
      };

      if (body.length <= options.maxChars) {
        pieces.add(
          ChunkPiece(
            text: _withHeading(body, section.heading),
            heading: section.heading,
            startOffset: section.start,
            metadata: metadata,
          ),
        );
        continue;
      }

      // Too long for one chunk: split it as prose, but keep the heading so
      // every piece still says where it came from.
      final inner = RecursiveChunker(options: options).chunk(
        RagDocument(
          id: document.id,
          content: body,
          title: document.title,
          source: document.source,
        ),
      );
      for (final chunk in inner) {
        pieces.add(
          ChunkPiece(
            // Every piece, not just the first: a reader who retrieves the
            // fourth slice of a long section still needs to know what section
            // it is.
            text: _withHeading(chunk.text, section.heading),
            heading: section.heading,
            startOffset: section.start + (chunk.startOffset ?? 0),
            metadata: metadata,
          ),
        );
      }
    }

    return pieces;
  }

  String _withHeading(String body, String? heading) {
    if (!prependHeading || heading == null || heading.isEmpty) return body;
    if (body.startsWith(heading)) return body;
    return '$heading\n\n$body';
  }

  /// Splits [markdown] into sections at headings.
  List<_Section> _sections(String markdown) {
    final lines = markdown.split('\n');
    final sections = <_Section>[];
    final path = <String>[];
    final buffer = StringBuffer();
    var currentHeading = <String>[];
    var sectionStart = 0;
    var offset = 0;
    var inFence = false;

    void flush(int start) {
      if (buffer.toString().trim().isEmpty) {
        buffer.clear();
        return;
      }
      sections.add(
        _Section(
          heading: currentHeading.isEmpty ? null : currentHeading.join(' › '),
          path: List<String>.unmodifiable(currentHeading),
          body: buffer.toString(),
          start: start,
        ),
      );
      buffer.clear();
    }

    for (final line in lines) {
      final lineLength = line.length + 1;
      if (_fencePattern.hasMatch(line.trimLeft())) inFence = !inFence;

      final match = inFence ? null : _headingPattern.firstMatch(line);
      if (match == null) {
        buffer.writeln(line);
        offset += lineLength;
        continue;
      }

      final level = match.group(1)!.length;
      final title = match.group(2)!.trim();
      if (level > maxHeadingDepth) {
        // Deeper than we split on: keep it as body text so the content is not
        // lost and the heading still reads in the chunk.
        buffer.writeln(line);
        offset += lineLength;
        continue;
      }

      flush(sectionStart);
      sectionStart = offset;
      path
        ..removeRange(
          level - 1 < path.length ? level - 1 : path.length,
          path.length,
        )
        ..add(title);
      currentHeading = List<String>.of(path);
      offset += lineLength;
    }
    flush(sectionStart);

    return _foldShortSections(sections);
  }

  /// Merges sections shorter than [ChunkOptions.minChars] into the previous one.
  ///
  /// A heading with two words under it is not a retrievable idea; attached to
  /// the section above it, it is context.
  List<_Section> _foldShortSections(List<_Section> sections) {
    final folded = <_Section>[];
    for (final section in sections) {
      final tooSmall =
          section.body.trim().length < options.minChars && folded.isNotEmpty;
      if (tooSmall) {
        final previous = folded.removeLast();
        folded.add(
          _Section(
            heading: previous.heading,
            path: previous.path,
            body: '${previous.body}\n${section.body}',
            start: previous.start,
          ),
        );
      } else {
        folded.add(section);
      }
    }
    return folded;
  }

  static final RegExp _headingPattern = RegExp(r'^(#{1,6})\s+(.*)$');
  static final RegExp _fencePattern = RegExp('^(```|~~~)');
}

/// One heading and the text beneath it.
final class _Section {
  const _Section({
    required this.heading,
    required this.path,
    required this.body,
    required this.start,
  });

  final String? heading;
  final List<String> path;
  final String body;
  final int start;
}
