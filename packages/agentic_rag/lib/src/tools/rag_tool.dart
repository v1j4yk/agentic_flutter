/// Exposing retrieval to an agent as an ordinary tool.
library;

import 'package:agentic_core/agentic_core.dart';
import 'package:agentic_rag/src/model/document.dart';
import 'package:agentic_rag/src/pipeline/rag_pipeline.dart';
import 'package:agentic_rag/src/retrieval/retriever.dart';
import 'package:agentic_tools/agentic_tools.dart';
import 'package:agentic_vector/agentic_vector.dart';

/// Builds a tool that searches a corpus.
///
/// # Why retrieval as a tool, not as a prompt step
///
/// A pipeline retrieves once, before the model has seen the question. That is
/// right for a question-and-answer box, and wrong for an agent — which
/// frequently needs to search twice, having learned from the first result that
/// it was asking the wrong thing, or to search two corpora, or not to search at
/// all because it already knows.
///
/// Giving retrieval to the model as a tool puts that decision where the
/// information is. The cost is a round trip; the benefit is that the model
/// stops retrieving for "hello" and starts retrieving twice for the questions
/// that need it.
///
/// # It returns passages, not an answer
///
/// The tool returns numbered passages and their sources. The agent writes the
/// answer, using its own system prompt and its own instructions about citation
/// — which is what keeps a search tool composable with the rest of an agent's
/// behaviour instead of quietly becoming a second, competing agent.
///
/// ```dart
/// final tools = ToolRegistry()
///   ..register(searchTool(retriever: retriever, corpus: 'the handbook'));
/// ```
Tool searchTool({
  required Retriever retriever,
  String name = 'search_documents',
  String corpus = 'the indexed documents',
  int topK = 5,
  int maxPassageChars = 800,
  double minScore = 0,
  MetadataFilter? filter,
  String? namespace,
}) => FunctionTool(
  name: name,
  description:
      'Searches $corpus and returns the most relevant passages with their '
      'sources. Use it whenever the answer depends on what those documents '
      'say; search again with different wording if the first results miss.',
  parameters: JsonSchema.object(
    properties: <String, JsonSchema>{
      'query': JsonSchema.string(
        description:
            'What to look for, in natural language. Prefer the words the '
            'documents would use over the words the user used.',
        minLength: 2,
      ),
      'limit': JsonSchema.integer(
        description: 'How many passages to return. Defaults to $topK.',
        minimum: 1,
        maximum: 20,
      ),
    },
    required: const <String>{'query'},
  ),
  handler: (invocation) async {
    final query = invocation.require<String>('query');
    final limit = invocation.arguments['limit'] as int? ?? topK;

    final results = await retriever.retrieve(
      RetrievalRequest(
        query: query,
        topK: limit,
        filter: filter,
        minScore: minScore,
        namespace: namespace,
      ),
      context: invocation.context,
    );

    if (results.isEmpty) {
      // A plain, unambiguous sentence rather than an empty result: a model
      // handed `[]` frequently answers from memory instead, and the whole point
      // of grounding is that it should not.
      return ToolResult.success(
        'No passages in $corpus matched "$query". The documents do not appear '
        'to cover this.',
        data: <String, Object?>{'query': query, 'results': const <Object?>[]},
      );
    }

    return ToolResult.success(
      _render(results, maxPassageChars),
      data: <String, Object?>{
        'query': query,
        'results': <Object?>[
          for (final result in results)
            <String, Object?>{
              'id': result.id,
              'source': result.chunk.label,
              'score': result.score,
            },
        ],
      },
    );
  },
);

/// Builds a tool that answers from a corpus in one step.
///
/// The other shape: the agent asks a question and gets a written, cited answer
/// rather than passages. Use it when the corpus deserves its own specialist —
/// a legal archive, a codebase — and the agent orchestrating it should not be
/// reading raw passages at all.
///
/// It costs a nested model call, which is the trade: fewer tokens in the outer
/// agent's context, one more call per use.
Tool answeringTool({
  required RagPipeline pipeline,
  String name = 'ask_documents',
  String corpus = 'the indexed documents',
  MetadataFilter? filter,
  String? namespace,
}) => FunctionTool(
  name: name,
  description:
      'Asks a question of $corpus and returns a written answer with its '
      'sources. Use it for questions that depend on those documents.',
  parameters: JsonSchema.object(
    properties: <String, JsonSchema>{
      'question': JsonSchema.string(
        description: 'The question, in full, as a sentence.',
        minLength: 3,
      ),
    },
    required: const <String>{'question'},
  ),
  handler: (invocation) async {
    final question = invocation.require<String>('question');
    final answer = await pipeline.answer(
      question,
      filter: filter,
      namespace: namespace,
      context: invocation.context,
    );

    final buffer = StringBuffer(answer.text);
    if (answer.citations.isNotEmpty) {
      buffer.writeln('\n\nSources:');
      for (final citation in answer.citations) {
        buffer.writeln(citation.label);
      }
    }

    return ToolResult.success(
      buffer.toString(),
      data: <String, Object?>{
        'grounded': answer.isGrounded,
        'citations': <Object?>[
          for (final citation in answer.citations) citation.toJson(),
        ],
      },
    );
  },
);

String _render(List<RetrievedChunk> results, int maxPassageChars) {
  final buffer = StringBuffer();
  for (var i = 0; i < results.length; i++) {
    final result = results[i];
    final text = result.text;
    final shown = text.length > maxPassageChars
        ? '${text.substring(0, maxPassageChars)}…'
        : text;
    buffer
      ..writeln('[${i + 1}] ${result.chunk.label}')
      ..writeln(shown)
      ..writeln();
  }
  return buffer.toString().trimRight();
}
