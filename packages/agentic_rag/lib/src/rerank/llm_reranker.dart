/// Re-ranking by asking a model.
library;

import 'package:agentic_core/agentic_core.dart';
import 'package:agentic_llm/agentic_llm.dart';
import 'package:agentic_rag/src/model/document.dart';
import 'package:agentic_rag/src/rerank/reranker.dart';

/// Scores candidates by having a model read them against the question.
///
/// # Why this beats similarity
///
/// An embedding measures whether two texts are *about* the same thing. A model
/// reading both can tell whether one *answers* the other — a distinction
/// similarity cannot make. A passage titled "Refund policy" that explains why
/// refunds are unavailable in your region is highly similar to "how do I get a
/// refund" and does not answer it.
///
/// # What it costs
///
/// One model call per re-ranking, carrying every candidate. That is real money
/// and real latency, which is why it belongs *after* a cheap filter and in
/// front of a small candidate list — `ChainedReranker([ScoreFloorReranker(),
/// LlmReranker(...)])` is the shape that makes sense.
///
/// # Failure is not fatal
///
/// If the model fails, times out or answers in a shape that cannot be read, the
/// retriever's own ordering is returned instead. Re-ranking is an improvement,
/// not a prerequisite: turning a good answer into an error because the
/// *optional* refinement step failed is the wrong trade, and the caller finds
/// out through the log and [lastFailure] rather than through an exception.
///
/// ```dart
/// final reranker = LlmReranker(model: model);
/// final best = await reranker.rerank(question, candidates, topK: 4);
/// ```
final class LlmReranker implements Reranker {
  /// Creates a model-backed re-ranker.
  LlmReranker({
    required this.model,
    this.name = 'llm',
    this.maxCandidateChars = 600,
    this.instructions,
  });

  /// The model that does the judging.
  ///
  /// A small, fast model is usually right here. Judging relevance is a much
  /// easier task than writing the answer, and this call sits on the critical
  /// path of every question.
  final ChatModel model;

  @override
  final String name;

  /// How much of each candidate the model is shown.
  ///
  /// Truncating is deliberate: relevance is nearly always decided by the first
  /// few sentences, and sending twenty full passages to judge four costs more
  /// than the answer will.
  final int maxCandidateChars;

  /// Extra guidance appended to the system prompt.
  final String? instructions;

  /// Why the last re-ranking fell back, or `null` if it did not.
  ///
  /// Exposed because a silent fallback that nobody can observe is how a
  /// pipeline quietly stops re-ranking for a week.
  AgenticException? get lastFailure => _lastFailure;
  AgenticException? _lastFailure;

  @override
  Future<List<RetrievedChunk>> rerank(
    String query,
    List<RetrievedChunk> results, {
    int topK = 4,
    AgenticContext? context,
  }) async {
    _lastFailure = null;
    if (results.length <= 1) return results;

    try {
      final response = await model.generate(
        ChatRequest(
          messages: <Message>[
            Message.system(_systemPrompt()),
            Message.user(_userPrompt(query, results)),
          ],
          responseFormat: ResponseFormat.jsonSchema(
            name: 'relevance_scores',
            schema: _schema,
          ),
          temperature: 0,
        ),
        context: context,
      );

      final scores = _parseScores(response.decodeJson(), results.length);
      if (scores.isEmpty) {
        throw SerializationException(
          'The re-ranking model returned no usable scores.',
        );
      }

      final rescored = <RetrievedChunk>[
        for (var i = 0; i < results.length; i++)
          results[i].copyWith(score: scores[i] ?? 0, retriever: name),
      ]..sort((a, b) => b.score.compareTo(a.score));

      final kept = <RetrievedChunk>[
        for (final result in rescored.take(topK)) result,
      ];
      return List<RetrievedChunk>.unmodifiable(<RetrievedChunk>[
        for (var i = 0; i < kept.length; i++) kept[i].copyWith(rank: i),
      ]);
    } on CancelledException {
      // The caller abandoned the run; it wants to stop, not to fall back.
      rethrow;
    } on AgenticException catch (error) {
      _lastFailure = error;
      context?.logger.warn(
        'Re-ranking failed; keeping the retriever ordering',
        fields: <String, Object?>{'reranker': name, 'code': error.code},
        error: error,
      );
      return <RetrievedChunk>[for (final result in results.take(topK)) result];
    }
  }

  String _systemPrompt() =>
      'You judge whether a passage answers a question.\n'
      'Score every passage from 0 to 10:\n'
      '  10 — directly and completely answers the question\n'
      '   5 — related and partly useful\n'
      '   0 — same subject area but does not answer it, or irrelevant\n'
      'Judge each passage on its own. Being about the right topic is not the '
      'same as answering the question, and a passage that states the opposite '
      'of what was asked scores low.\n'
      'Return one score per passage, in the order given.'
      '${instructions == null ? '' : '\n$instructions'}';

  String _userPrompt(String query, List<RetrievedChunk> results) {
    final buffer = StringBuffer()
      ..writeln('Question: $query')
      ..writeln()
      ..writeln('Passages:');
    for (var i = 0; i < results.length; i++) {
      final text = results[i].text;
      final shown = text.length > maxCandidateChars
          ? '${text.substring(0, maxCandidateChars)}…'
          : text;
      buffer
        ..writeln('[$i] ${results[i].chunk.label}')
        ..writeln(shown)
        ..writeln();
    }
    return buffer.toString();
  }

  /// Reads the model's answer into scores by index.
  ///
  /// Tolerant on purpose: a model that scores five of six passages should cost
  /// the sixth its place, not the whole re-ranking. Missing entries come back
  /// as `null` and are treated as zero.
  static List<double?> _parseScores(JsonMap json, int expected) {
    final raw = json['scores'];
    if (raw is! List) return const <double?>[];

    final scores = List<double?>.filled(expected, null);
    for (final entry in raw) {
      if (entry is! Map) continue;
      final index = (entry['index'] as num?)?.toInt();
      final score = (entry['score'] as num?)?.toDouble();
      if (index == null || score == null) continue;
      if (index < 0 || index >= expected) continue;
      scores[index] = score.clamp(0, 10) / 10;
    }
    return scores;
  }

  static final JsonSchema _schema = JsonSchema.object(
    properties: <String, JsonSchema>{
      'scores': JsonSchema.array(
        description: 'One entry per passage, in the order given.',
        items: JsonSchema.object(
          properties: <String, JsonSchema>{
            'index': JsonSchema.integer(
              description: 'The passage number shown in brackets.',
            ),
            'score': JsonSchema.integer(
              description: 'Relevance from 0 to 10.',
              minimum: 0,
              maximum: 10,
            ),
          },
          required: const <String>{'index', 'score'},
        ),
      ),
    },
    required: const <String>{'scores'},
  );

  @override
  String toString() => 'LlmReranker(${model.info.qualifiedId})';
}
