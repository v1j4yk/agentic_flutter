/// Turning raw source material into documents.
///
/// # Why loaders take text, not paths
///
/// Nothing here touches the filesystem or the network. That is deliberate: a
/// loader that calls `dart:io` cannot run on the web, and a loader that fetches
/// a URL drags a transport, a retry policy and an authentication story into a
/// package about documents.
///
/// Reading a file is one line in your application (`File(path).readAsString()`
/// on native, a picker or a bundle asset on mobile, a fetch on the web) and it
/// is the line that most wants to differ per platform. What is genuinely shared
/// — extracting a title, parsing front matter, stripping markup, deciding what
/// becomes metadata — is what lives here.
library;

import 'package:agentic_core/agentic_core.dart';
import 'package:agentic_rag/src/model/document.dart';

/// Converts source material into documents.
abstract interface class DocumentLoader {
  /// A short name, used in events and traces.
  String get name;

  /// Produces documents from whatever this loader was constructed with.
  Future<List<RagDocument>> load({AgenticContext? context});
}

/// Loads documents that are already in hand as text.
///
/// The loader most applications need: you read the file, this makes it a
/// document.
///
/// ```dart
/// final loader = TextDocumentLoader(<TextSource>[
///   TextSource(id: 'faq.txt', text: await File('faq.txt').readAsString()),
/// ]);
/// ```
final class TextDocumentLoader implements DocumentLoader {
  /// Creates a loader over [sources].
  const TextDocumentLoader(this.sources);

  /// The texts to load.
  final List<TextSource> sources;

  @override
  String get name => 'text';

  @override
  Future<List<RagDocument>> load({AgenticContext? context}) async =>
      <RagDocument>[
        for (final source in sources)
          RagDocument(
            id: source.id,
            content: source.text,
            title: source.title,
            source: source.source ?? source.id,
            metadata: source.metadata,
          ),
      ];
}

/// One text and what is known about it.
final class TextSource {
  /// Describes a text.
  const TextSource({
    required this.id,
    required this.text,
    this.title,
    this.source,
    this.metadata = const <String, Object?>{},
  });

  /// Stable identifier — a path, a URL, a row key.
  final String id;

  /// The content.
  final String text;

  /// A human-readable name.
  final String? title;

  /// Where it came from, defaulting to [id].
  final String? source;

  /// Anything worth filtering or citing on.
  final JsonMap metadata;
}

/// Runs several loaders as one.
///
/// Loaders run sequentially rather than concurrently: they are usually reading
/// from the same disk or the same connection, and running eight at once makes
/// that slower, not faster.
final class CompositeDocumentLoader implements DocumentLoader {
  /// Creates a loader over [loaders].
  const CompositeDocumentLoader(this.loaders);

  /// The loaders to run, in order.
  final List<DocumentLoader> loaders;

  @override
  String get name => 'composite';

  @override
  Future<List<RagDocument>> load({AgenticContext? context}) async {
    final documents = <RagDocument>[];
    for (final loader in loaders) {
      context?.throwIfCancelled();
      documents.addAll(await loader.load(context: context));
    }
    return documents;
  }
}
