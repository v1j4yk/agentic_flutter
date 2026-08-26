/// Loaders for the two formats documentation actually arrives in.
library;

import 'package:agentic_core/agentic_core.dart';
import 'package:agentic_rag/src/loader/document_loader.dart';
import 'package:agentic_rag/src/model/document.dart';

/// Loads Markdown, lifting the title and YAML front matter into metadata.
///
/// Front matter is the conventional place authors already put the facts you
/// want to filter on — author, date, tags, tenant — so reading it turns
/// existing files into a filterable corpus with no extra work:
///
/// ```markdown
/// ---
/// title: Refund policy
/// team: billing
/// year: 2025
/// tags: [policy, refunds]
/// ---
///
/// # Refunds
/// ```
///
/// Values are parsed as numbers, booleans, `[bracketed, lists]` or strings.
/// This is not a YAML implementation and does not try to be: nested structures
/// are kept as their raw string rather than guessed at, because a filter over a
/// half-parsed object is worse than a filter over a string.
final class MarkdownDocumentLoader implements DocumentLoader {
  /// Creates a Markdown loader over [sources].
  const MarkdownDocumentLoader(this.sources);

  /// The Markdown texts to load.
  final List<TextSource> sources;

  @override
  String get name => 'markdown';

  @override
  Future<List<RagDocument>> load({AgenticContext? context}) async {
    final documents = <RagDocument>[];
    for (final source in sources) {
      final parsed = parseFrontMatter(source.text);
      final body = parsed.body;
      documents.add(
        RagDocument(
          id: source.id,
          content: body,
          title:
              source.title ??
              parsed.metadata['title'] as String? ??
              firstHeading(body),
          source: source.source ?? source.id,
          metadata: <String, Object?>{...parsed.metadata, ...source.metadata},
        ),
      );
    }
    return documents;
  }

  /// Splits leading `---` front matter from the body.
  ///
  /// Public so that an application reading files itself can reuse it without
  /// constructing a loader.
  static ({JsonMap metadata, String body}) parseFrontMatter(String text) {
    final normalised = text.replaceAll('\r\n', '\n');
    if (!normalised.startsWith('---\n')) {
      return (metadata: const <String, Object?>{}, body: normalised);
    }
    final end = normalised.indexOf('\n---', 3);
    if (end < 0) {
      return (metadata: const <String, Object?>{}, body: normalised);
    }

    final block = normalised.substring(4, end);
    final metadata = <String, Object?>{};
    for (final line in block.split('\n')) {
      final separator = line.indexOf(':');
      if (separator <= 0) continue;
      final key = line.substring(0, separator).trim();
      final value = line.substring(separator + 1).trim();
      if (key.isEmpty || value.isEmpty) continue;
      metadata[key] = _parseScalar(value);
    }

    final bodyStart = normalised.indexOf('\n', end + 1);
    if (bodyStart < 0) return (metadata: metadata, body: '');
    // Leading blank lines are dropped. Front matter is conventionally followed
    // by one, and a body that begins with a newline makes every downstream
    // "does this start with a heading?" check fail for no reason. Indentation
    // on the first line of content is preserved, because that can be a code
    // block.
    final body = normalised
        .substring(bodyStart + 1)
        .replaceFirst(_leadingBlankLines, '');
    return (metadata: metadata, body: body);
  }

  /// The first ATX heading in [markdown], or `null`.
  static String? firstHeading(String markdown) {
    for (final line in markdown.split('\n')) {
      final match = RegExp(r'^#{1,6}\s+(.*)$').firstMatch(line.trimRight());
      if (match != null) return match.group(1)!.trim();
    }
    return null;
  }

  static final RegExp _leadingBlankLines = RegExp(r'^[\n\r]+');

  static Object? _parseScalar(String value) {
    if (value == 'true') return true;
    if (value == 'false') return false;
    final number = num.tryParse(value);
    if (number != null) return number;
    if (value.startsWith('[') && value.endsWith(']')) {
      final inner = value.substring(1, value.length - 1).trim();
      if (inner.isEmpty) return const <Object?>[];
      return <Object?>[
        for (final part in inner.split(','))
          _parseScalar(_unquote(part.trim())),
      ];
    }
    return _unquote(value);
  }

  static String _unquote(String value) {
    if (value.length < 2) return value;
    final first = value[0];
    final last = value[value.length - 1];
    if ((first == '"' && last == '"') || (first == "'" && last == "'")) {
      return value.substring(1, value.length - 1);
    }
    return value;
  }
}

/// Loads HTML by reducing it to readable text.
///
/// Scripts, styles and comments are dropped entirely; block-level tags become
/// line breaks so paragraphs survive; the rest of the markup is removed and the
/// five predefined entities plus numeric references are decoded.
///
/// This is a text extractor, not a parser. It is deliberately dependency-free,
/// which is the right trade for the documentation, help centres and article
/// pages that make up most retrieval corpora. A corpus of application HTML —
/// where the content is assembled by script and the structure carries meaning —
/// wants a real parser upstream, and this loader will happily take its output.
final class HtmlDocumentLoader implements DocumentLoader {
  /// Creates an HTML loader over [sources].
  const HtmlDocumentLoader(this.sources);

  /// The HTML texts to load.
  final List<TextSource> sources;

  @override
  String get name => 'html';

  @override
  Future<List<RagDocument>> load({AgenticContext? context}) async =>
      <RagDocument>[
        for (final source in sources)
          RagDocument(
            id: source.id,
            content: htmlToText(source.text),
            title: source.title ?? extractTitle(source.text),
            source: source.source ?? source.id,
            metadata: source.metadata,
          ),
      ];

  /// Reduces [html] to readable text.
  static String htmlToText(String html) {
    var text = html
        .replaceAll(_commentPattern, ' ')
        .replaceAll(_scriptPattern, ' ')
        .replaceAll(_stylePattern, ' ')
        .replaceAllMapped(_blockPattern, (_) => '\n\n')
        .replaceAll(_breakPattern, '\n')
        .replaceAll(_tagPattern, '');
    text = decodeEntities(text);
    // Collapse the runs of whitespace that markup removal leaves behind, while
    // keeping paragraph breaks, which is what the chunker splits on.
    return text
        .replaceAll(_horizontalSpacePattern, ' ')
        .replaceAll(_blankLinePattern, '\n\n')
        .trim();
  }

  /// The contents of `<title>`, or `null`.
  static String? extractTitle(String html) {
    final match = _titlePattern.firstMatch(html);
    if (match == null) return null;
    final title = decodeEntities(match.group(1)!).trim();
    return title.isEmpty ? null : title;
  }

  /// Decodes the predefined entities and numeric character references.
  static String decodeEntities(String text) => text
      .replaceAllMapped(_numericEntityPattern, (match) {
        final digits = match.group(2)!;
        final code = match.group(1) == null
            ? int.tryParse(digits)
            : int.tryParse(digits, radix: 16);
        // An out-of-range reference is left as written rather than throwing:
        // one malformed entity must not fail a whole ingestion run.
        if (code == null || code < 0 || code > 0x10ffff) return match.group(0)!;
        return String.fromCharCode(code);
      })
      .replaceAll('&nbsp;', ' ')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&apos;', "'")
      // Ampersand last, so `&amp;lt;` decodes to `&lt;` and not to `<`.
      .replaceAll('&amp;', '&');

  static final RegExp _commentPattern = RegExp('<!--.*?-->', dotAll: true);
  static final RegExp _scriptPattern = RegExp(
    '<script[^>]*>.*?</script>',
    caseSensitive: false,
    dotAll: true,
  );
  static final RegExp _stylePattern = RegExp(
    '<style[^>]*>.*?</style>',
    caseSensitive: false,
    dotAll: true,
  );
  static final RegExp _blockPattern = RegExp(
    '</?(p|div|section|article|h[1-6]|li|tr|blockquote|pre)[^>]*>',
    caseSensitive: false,
  );
  static final RegExp _breakPattern = RegExp('<br[^>]*>', caseSensitive: false);
  static final RegExp _tagPattern = RegExp('<[^>]*>');
  static final RegExp _titlePattern = RegExp(
    '<title[^>]*>(.*?)</title>',
    caseSensitive: false,
    dotAll: true,
  );
  static final RegExp _numericEntityPattern = RegExp(
    r'&#(x)?([0-9a-fA-F]+);',
    caseSensitive: false,
  );
  static final RegExp _horizontalSpacePattern = RegExp('[ \t]+');
  static final RegExp _blankLinePattern = RegExp(r'\n\s*\n(\s*\n)+');
}
