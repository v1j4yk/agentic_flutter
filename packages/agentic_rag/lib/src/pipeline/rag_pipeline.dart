/// Retrieve, re-rank, assemble, answer.
library;

import 'package:agentic_core/agentic_core.dart';
import 'package:agentic_llm/agentic_llm.dart';
import 'package:agentic_rag/src/events/rag_events.dart';
import 'package:agentic_rag/src/model/document.dart';
import 'package:agentic_rag/src/rerank/reranker.dart';
import 'package:agentic_rag/src/retrieval/retriever.dart';
import 'package:agentic_vector/agentic_vector.dart';
import 'package:meta/meta.dart';

/// What [RagPipeline.stream] reports, in the order it happens.
///
/// A sealed family so a screen can `switch` over it and the compiler says when
/// a case is missing.
sealed class RagStreamEvent {
  const RagStreamEvent();
}

/// Retrieval finished; the passages the answer will draw on are known.
///
/// Arrives before the model has written a word. On a phone that is the
/// difference between a spinner for the whole answer and sources on screen
/// within a few hundred milliseconds — and the sources are what tell somebody
/// whether the answer that follows is worth reading.
final class RagSourcesReady extends RagStreamEvent {
  /// Creates the event.
  const RagSourcesReady(this.context);

  /// The passages, numbered as the answer will cite them.
  final RagContext context;
}

/// More of the answer's text.
final class RagAnswerDelta extends RagStreamEvent {
  /// Creates the event.
  const RagAnswerDelta(this.text);

  /// The text added since the previous delta.
  final String text;
}

/// The answer is complete, with the citations it actually used.
///
/// Always the last event of a stream that did not fail. Citations are
/// resolved here, from the finished text, because a `[1]` can arrive split
/// across two deltas.
final class RagAnswerCompleted extends RagStreamEvent {
  /// Creates the event.
  const RagAnswerCompleted(this.answer);

  /// The finished answer, identical to what [RagPipeline.answer] returns.
  final RagAnswer answer;
}

/// The passages selected for a question, ready to put in a prompt.
@immutable
final class RagContext {
  /// Creates a context.
  RagContext({
    required this.query,
    required this.text,
    List<RetrievedChunk> chunks = const <RetrievedChunk>[],
    List<Citation> citations = const <Citation>[],
    this.dropped = 0,
  }) : chunks = List<RetrievedChunk>.unmodifiable(chunks),
       citations = List<Citation>.unmodifiable(citations);

  /// The question this context was assembled for.
  final String query;

  /// The formatted passages, as they appear in the prompt.
  final String text;

  /// The passages, in the order they appear.
  final List<RetrievedChunk> chunks;

  /// One citation per passage, numbered from 1.
  final List<Citation> citations;

  /// How many retrieved passages did not fit the character budget.
  ///
  /// Reported rather than silently discarded: a context that habitually drops
  /// half of what retrieval found is over-fetching, and nothing else would tell
  /// you.
  final int dropped;

  /// Whether anything was found.
  bool get isEmpty => chunks.isEmpty;

  /// How large the assembled context is.
  int get characters => text.length;

  /// The citation for [marker], or `null`.
  Citation? citationFor(String marker) {
    for (final citation in citations) {
      if (citation.marker == marker) return citation;
    }
    return null;
  }

  /// Serialises the context, excluding the passage text.
  JsonMap toJson() => <String, Object?>{
    'query': query,
    'chunks': chunks.map((c) => c.toJson()).toList(),
    'characters': characters,
    'dropped': dropped,
  };

  @override
  String toString() =>
      'RagContext(${chunks.length} passages, $characters chars)';
}

/// An answer and what it was built from.
@immutable
final class RagAnswer {
  /// Creates an answer.
  RagAnswer({
    required this.text,
    required this.context,
    List<Citation> citations = const <Citation>[],
    this.usage = TokenUsage.empty,
    this.cost,
  }) : citations = List<Citation>.unmodifiable(citations);

  /// What the model wrote.
  final String text;

  /// What it was given.
  final RagContext context;

  /// The citations the answer actually used, in order of first appearance.
  final List<Citation> citations;

  /// What the generation call consumed.
  final TokenUsage usage;

  /// What it cost, when the model reports pricing.
  final double? cost;

  /// Whether the answer cited anything at all.
  ///
  /// A heuristic, and an honest one: the prompt tells the model to cite the
  /// passage behind every claim and to cite nothing when the passages do not
  /// answer the question. An answer with no citations is therefore either an
  /// admission that the corpus does not cover this, or a claim made without
  /// support — and both are worth surfacing rather than presenting as fact.
  bool get isGrounded => citations.isNotEmpty;

  /// Serialises the answer, excluding the passage text.
  JsonMap toJson() => pruneNulls(<String, Object?>{
    'text': text,
    'citations': citations.map((c) => c.toJson()).toList(),
    'grounded': isGrounded,
    'usage': usage.toJson(),
    'cost': cost,
  });

  @override
  String toString() =>
      'RagAnswer(${text.length} chars, ${citations.length} citations)';
}

/// Runs the retrieval half of a question end to end.
///
/// # The shape of the pipeline
///
/// ```
/// question ──► retrieve ──► re-rank ──► fit to budget ──► prompt ──► answer
///                (recall)   (precision)   (honesty)
/// ```
///
/// Each stage has one job. Retrieval casts a wide net. Re-ranking trims it to
/// what actually answers the question. The budget stage decides what fits, and
/// reports what it dropped. Generation is given numbered passages and told to
/// cite them.
///
/// # Citations are the product
///
/// A retrieval system that cannot say where an answer came from is a
/// text generator with extra steps. The prompt numbers every passage and asks
/// the model to mark each claim; [RagAnswer.citations] resolves the markers the
/// answer used back to documents.
///
/// Markers are numbers because that is what models reproduce reliably. Asked to
/// write `[guide.md#7]` they mangle it; asked to write `[3]` they do not.
///
/// ```dart
/// final pipeline = RagPipeline(
///   retriever: hybridRetriever,
///   model: chatModel,
///   reranker: const ScoreFloorReranker(minScore: 0.2),
/// );
///
/// final answer = await pipeline.answer('How do refunds work?');
/// print(answer.text);
/// for (final citation in answer.citations) {
///   print(citation.label);
/// }
/// ```
final class RagPipeline {
  /// Creates a pipeline.
  ///
  /// [model] is needed only by [answer]; [buildContext] works without one,
  /// which is what makes this usable as a search backend as well as a question
  /// answerer.
  RagPipeline({
    required this.retriever,
    this.model,
    this.reranker,
    this.topK = 6,
    this.finalK = 4,
    this.maxContextChars = 6000,
    this.minScore = 0,
    this.systemPrompt,
    this.includeQuotes = false,
  }) : assert(topK > 0, 'topK must be positive'),
       assert(finalK > 0, 'finalK must be positive'),
       assert(maxContextChars > 0, 'maxContextChars must be positive');

  /// Where passages come from.
  final Retriever retriever;

  /// The model that writes the answer.
  final ChatModel? model;

  /// The refinement step, when there is one.
  final Reranker? reranker;

  /// How many passages retrieval is asked for.
  final int topK;

  /// How many survive re-ranking and reach the prompt.
  ///
  /// Smaller than [topK] on purpose. Retrieval optimises for recall; this is
  /// the number that fits a prompt without burying the answer in the middle of
  /// a long context, where models measurably lose track of it.
  final int finalK;

  /// Upper bound on the assembled context, in characters.
  ///
  /// The best-ranked passage is always included, even when it alone exceeds
  /// this — so the budget can be overshot by at most one passage. Dropping it
  /// would mean answering "the documents do not cover this" about a document
  /// that does, which is the worse failure. If that overshoot matters, it is a
  /// sign that `ChunkOptions.maxChars` is too close to this number: chunks
  /// should be a fraction of the context, not the whole of it.
  final int maxContextChars;

  /// Minimum relevance for a passage to be used at all.
  final double minScore;

  /// Replaces the built-in answering instructions.
  ///
  /// The default insists on grounding, citation, and admitting ignorance. If
  /// you replace it, keep those three: they are what separates a retrieval
  /// answer from a confident guess.
  final String? systemPrompt;

  /// Whether citations carry the passage they came from.
  ///
  /// Off by default because it duplicates the context, which is already in the
  /// prompt. Turn it on when the citations are rendered somewhere the context
  /// is not — a sources panel in a UI.
  final bool includeQuotes;

  /// Retrieves, re-ranks and assembles the context for [query].
  Future<RagContext> buildContext(
    String query, {
    MetadataFilter? filter,
    String? namespace,
    int? topK,
    int? finalK,
    AgenticContext? context,
  }) async {
    final clock = context?.clock ?? const SystemClock();
    final requested = topK ?? this.topK;
    final kept = finalK ?? this.finalK;

    final retrievalStarted = clock.now();
    var results = await retriever.retrieve(
      RetrievalRequest(
        query: query,
        topK: requested,
        filter: filter,
        minScore: minScore,
        namespace: namespace,
      ),
      context: context,
    );
    _publishRetrieved(
      context,
      results,
      requested: requested,
      filtered: filter != null,
      duration: clock.now().difference(retrievalStarted),
    );

    final refiner = reranker;
    if (refiner != null && results.isNotEmpty) {
      final rerankStarted = clock.now();
      final before = results;
      results = await refiner.rerank(
        query,
        results,
        topK: kept,
        context: context,
      );
      _publishReranked(
        context,
        reranker: refiner.name,
        before: before,
        after: results,
        duration: clock.now().difference(rerankStarted),
      );
    } else if (results.length > kept) {
      results = List<RetrievedChunk>.unmodifiable(results.take(kept));
    }

    return assemble(query, results);
  }

  /// Formats [results] into a prompt-ready context, honouring the budget.
  ///
  /// Separate from [buildContext] so that an application which retrieved its
  /// own passages — from a cache, from a previous turn — can still use the
  /// formatting and citation numbering.
  RagContext assemble(String query, List<RetrievedChunk> results) {
    final buffer = StringBuffer();
    final used = <RetrievedChunk>[];
    final citations = <Citation>[];
    var dropped = 0;

    for (final result in results) {
      final marker = '${used.length + 1}';
      final block = _formatPassage(marker, result);
      // Budget is checked before appending, and a passage that does not fit is
      // skipped rather than truncated: half a passage reads as a complete one
      // and is quoted as if it were.
      if (buffer.length + block.length > maxContextChars && used.isNotEmpty) {
        dropped++;
        continue;
      }
      buffer.write(block);
      used.add(result);
      citations.add(
        Citation.forChunk(
          result.chunk,
          marker: marker,
          includeQuote: includeQuotes,
        ),
      );
    }

    return RagContext(
      query: query,
      text: buffer.toString().trimRight(),
      chunks: used,
      citations: citations,
      dropped: dropped,
    );
  }

  /// Answers [query] from retrieved passages.
  ///
  /// Throws a [ConfigurationException] when the pipeline has no model.
  Future<RagAnswer> answer(
    String query, {
    MetadataFilter? filter,
    String? namespace,
    List<Message> history = const <Message>[],
    AgenticContext? context,
  }) async {
    final chat = _requireModel();
    final clock = context?.clock ?? const SystemClock();

    final retrieved = await buildContext(
      query,
      filter: filter,
      namespace: namespace,
      context: context,
    );

    final started = clock.now();
    final response = await chat.generate(
      promptFor(query, retrieved, history: history),
      context: context,
    );
    return _complete(
      response,
      retrieved,
      model: chat,
      duration: clock.now().difference(started),
      context: context,
    );
  }

  /// Answers [query] as a stream: sources first, then text, then the answer.
  ///
  /// Emits exactly one [RagSourcesReady], any number of [RagAnswerDelta]s, and
  /// one [RagAnswerCompleted] whose answer is the same as [answer] would have
  /// returned — including the `AnswerGenerated` event and the cost estimate.
  ///
  /// Cancelling the subscription cancels the model's stream, which closes the
  /// connection and stops the provider generating an answer nobody will read.
  ///
  /// ```dart
  /// await for (final event in pipeline.stream(question)) {
  ///   switch (event) {
  ///     case RagSourcesReady(:final context): showSources(context.citations);
  ///     case RagAnswerDelta(:final text):     appendText(text);
  ///     case RagAnswerCompleted(:final answer): linkCitations(answer.citations);
  ///   }
  /// }
  /// ```
  Stream<RagStreamEvent> stream(
    String query, {
    MetadataFilter? filter,
    String? namespace,
    List<Message> history = const <Message>[],
    AgenticContext? context,
  }) async* {
    final chat = _requireModel();
    final clock = context?.clock ?? const SystemClock();

    final retrieved = await buildContext(
      query,
      filter: filter,
      namespace: namespace,
      context: context,
    );
    yield RagSourcesReady(retrieved);

    final started = clock.now();
    final builder = ChatResponseBuilder(modelId: chat.info.id);
    await for (final chunk in chat.stream(
      promptFor(query, retrieved, history: history),
      context: context,
    )) {
      builder.add(chunk);
      final delta = chunk.textDelta;
      if (delta != null && delta.isNotEmpty) yield RagAnswerDelta(delta);
    }

    yield RagAnswerCompleted(
      _complete(
        builder.build(),
        retrieved,
        model: chat,
        duration: clock.now().difference(started),
        context: context,
      ),
    );
  }

  /// Resolves citations, reports the answer, and prices it.
  ///
  /// Shared by [answer] and [stream] so the two cannot drift: a streamed answer
  /// that cited, costed or reported differently from a generated one would be
  /// a bug nobody noticed until the numbers disagreed.
  RagAnswer _complete(
    ChatResponse response,
    RagContext retrieved, {
    required ChatModel model,
    required Duration duration,
    AgenticContext? context,
  }) {
    final text = response.text;
    final citations = citationsIn(text, retrieved);

    context?.publish(
      AnswerGenerated(
        id: context.ids.prefixed('evt'),
        timestamp: context.clock.now(),
        citationsOffered: retrieved.citations.length,
        citationsUsed: citations.length,
        answeredFromContext: citations.isNotEmpty,
        duration: duration,
        runId: context.runId,
        source: 'rag:pipeline',
      ),
    );

    return RagAnswer(
      text: text,
      context: retrieved,
      citations: citations,
      usage: response.usage,
      cost: response.cost ?? model.info.estimateCost(response.usage),
    );
  }

  /// Builds the request that [answer] and [stream] send.
  ///
  /// Exposed for a caller who needs control of generation that neither offers
  /// — a different model per request, say.
  ///
  /// This used to be the recommended way to stream, on the argument that a
  /// streaming API here would mean buffering someone else's stream. It turned
  /// out every caller buffered it anyway: citations can only be resolved from
  /// finished text, because a `[1]` arrives split across deltas. So each app
  /// rewrote the same five steps and lost the `AnswerGenerated` event and the
  /// cost estimate along the way. [stream] does those steps once.
  ChatRequest promptFor(
    String query,
    RagContext context, {
    List<Message> history = const <Message>[],
  }) => ChatRequest(
    messages: <Message>[
      Message.system(systemPrompt ?? defaultSystemPrompt),
      ...history,
      Message.user(_userPrompt(query, context)),
    ],
    temperature: 0.2,
  );

  /// Resolves the `[n]` markers used in [text] back to citations.
  ///
  /// Returns them in order of first appearance, without duplicates. Markers
  /// that do not correspond to a passage are ignored — a model that invents
  /// `[9]` for a context with four passages should lose the citation, not
  /// produce a broken link.
  List<Citation> citationsIn(String text, RagContext context) {
    final seen = <String>{};
    final used = <Citation>[];
    for (final match in _markerPattern.allMatches(text)) {
      for (final marker in match.group(1)!.split(',')) {
        final trimmed = marker.trim();
        if (!seen.add(trimmed)) continue;
        final citation = context.citationFor(trimmed);
        if (citation != null) used.add(citation);
      }
    }
    return List<Citation>.unmodifiable(used);
  }

  /// The instructions used when [systemPrompt] is not set.
  static const String defaultSystemPrompt =
      'Answer the question using only the passages provided.\n\n'
      'Rules:\n'
      '* Cite the passage behind every claim, as [1], [2]. Cite more than one '
      'with [1][3].\n'
      '* If the passages do not answer the question, say so plainly and cite '
      'nothing. Do not fill the gap from your own knowledge, and do not soften '
      'it — "the documents do not cover this" is a complete and useful '
      'answer.\n'
      '* Do not contradict a passage. If two passages disagree, say so and '
      'cite both.\n'
      '* Answer in the question\'s own language and keep it short.';

  ChatModel _requireModel() {
    final chat = model;
    if (chat != null) return chat;
    throw ConfigurationException(
      'This RagPipeline has no model, so it can retrieve but not answer. Pass '
      'one to the constructor, or use `buildContext` and generate yourself.',
      setting: 'model',
    );
  }

  String _formatPassage(String marker, RetrievedChunk result) {
    final label = result.chunk.label;
    return '[$marker] $label\n${result.text}\n\n';
  }

  String _userPrompt(String query, RagContext context) {
    if (context.isEmpty) {
      return 'Question: $query\n\n'
          'No passages were found for this question. Say that the documents '
          'do not cover it.';
    }
    return 'Passages:\n${context.text}\n\nQuestion: $query';
  }

  void _publishRetrieved(
    AgenticContext? context,
    List<RetrievedChunk> results, {
    required int requested,
    required bool filtered,
    required Duration duration,
  }) {
    if (context == null) return;
    context.publish(
      ChunksRetrieved(
        id: context.ids.prefixed('evt'),
        timestamp: context.clock.now(),
        retriever: retriever.name,
        requested: requested,
        returned: results.length,
        topScore: results.isEmpty ? null : results.first.score,
        chunkIds: <String>[for (final result in results) result.id],
        filtered: filtered,
        duration: duration,
        runId: context.runId,
        source: 'rag:pipeline',
      ),
    );
  }

  void _publishReranked(
    AgenticContext? context, {
    required String reranker,
    required List<RetrievedChunk> before,
    required List<RetrievedChunk> after,
    required Duration duration,
  }) {
    if (context == null) return;
    // A passage counts as promoted when re-ranking kept it but the retriever
    // would not have — which is exactly what the step is being paid for.
    final wouldHaveKept = <String>{
      for (final result in before.take(after.length)) result.id,
    };
    final promoted = after.where((r) => !wouldHaveKept.contains(r.id)).length;

    context.publish(
      ChunksReranked(
        id: context.ids.prefixed('evt'),
        timestamp: context.clock.now(),
        reranker: reranker,
        before: before.length,
        after: after.length,
        promoted: promoted,
        duration: duration,
        runId: context.runId,
        source: 'rag:pipeline',
      ),
    );
  }

  static final RegExp _markerPattern = RegExp(r'\[(\d+(?:\s*,\s*\d+)*)\]');

  @override
  String toString() =>
      'RagPipeline(${retriever.name}'
      '${reranker == null ? '' : ' -> ${reranker!.name}'})';
}
