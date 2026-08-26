/// What an agent run produced, and how it got there.
///
/// An agent's answer is rarely the whole story. When it is wrong, the question
/// is always *which step went wrong* — which tool returned what, how many times
/// the model went round, where the tokens went. [AgentResult] carries the
/// answer and the trail, so that question is answerable without re-running
/// anything.
library;

import 'package:agentic_agents/src/agent/agent_budget.dart';
import 'package:agentic_core/agentic_core.dart';
import 'package:agentic_llm/agentic_llm.dart';
import 'package:meta/meta.dart';

/// Why an agent stopped.
enum AgentStopReason {
  /// The model answered without requesting more tools. The normal ending.
  completed,

  /// A budget limit was reached.
  ///
  /// The answer, if there is one, may be a best effort rather than a finished
  /// one — check [AgentResult.budgetDimension] for which limit was hit.
  budgetExhausted,

  /// A caller-supplied stop condition matched.
  stopped,

  /// The run was cancelled.
  cancelled,

  /// The run failed.
  failed;

  /// Whether the answer can be treated as a finished one.
  bool get isSuccess => this == completed || this == stopped;
}

/// One iteration of an agent loop.
///
/// A step is a model call plus whatever tools it requested. Steps are the unit
/// a trace, a debug console and a test all reason about.
@immutable
final class AgentStep {
  /// Creates a step.
  AgentStep({
    required this.index,
    required this.response,
    required this.duration,
    List<ToolCallPart> toolCalls = const <ToolCallPart>[],
    List<Message> toolResults = const <Message>[],
  }) : toolCalls = List<ToolCallPart>.unmodifiable(toolCalls),
       toolResults = List<Message>.unmodifiable(toolResults);

  /// Zero-based position of this step in the run.
  final int index;

  /// What the model answered on this step.
  final ChatResponse response;

  /// Tool calls the model requested.
  final List<ToolCallPart> toolCalls;

  /// The tool-role messages produced in reply, one per call.
  final List<Message> toolResults;

  /// How long the step took, including tool execution.
  final Duration duration;

  /// The model's prose on this step, which is often empty when it called tools.
  String get text => response.text;

  /// Tokens consumed by this step's model call.
  TokenUsage get usage => response.usage;

  /// Whether any tool reported a failure.
  ///
  /// A failing tool is not a failing step: the model is told and usually
  /// recovers. This is here so a UI can show it, not so a caller can abort.
  bool get hasToolFailure =>
      toolResults.any((message) => message.toolResults.any((r) => r.isError));

  /// Serialises the step.
  JsonMap toJson() => pruneNulls(<String, Object?>{
    'index': index,
    'text': text.isEmpty ? null : text,
    'toolCalls': toolCalls.isEmpty
        ? null
        : toolCalls
              .map(
                (c) => <String, Object?>{
                  'name': c.name,
                  'arguments': c.arguments,
                },
              )
              .toList(),
    'toolResults': toolResults.isEmpty
        ? null
        : toolResults
              .expand((m) => m.toolResults)
              .map(
                (r) => <String, Object?>{
                  'name': r.name,
                  'isError': r.isError,
                  'content': r.content,
                },
              )
              .toList(),
    'usage': usage.toJson(),
    'durationMs': duration.inMilliseconds,
  });

  @override
  String toString() =>
      'AgentStep($index, ${toolCalls.length} tool calls, '
      '${duration.inMilliseconds}ms)';
}

/// The outcome of one agent run.
@immutable
final class AgentResult {
  /// Creates a result.
  AgentResult({
    required this.message,
    required this.stopReason,
    required this.duration,
    List<AgentStep> steps = const <AgentStep>[],
    List<Message> messages = const <Message>[],
    this.usage = TokenUsage.empty,
    this.cost,
    this.budgetDimension,
    this.error,
    Map<String, Object?> metadata = const <String, Object?>{},
  }) : steps = List<AgentStep>.unmodifiable(steps),
       messages = List<Message>.unmodifiable(messages),
       metadata = Map<String, Object?>.unmodifiable(metadata);

  /// The final assistant message.
  final Message message;

  /// Why the run stopped.
  final AgentStopReason stopReason;

  /// Which budget limit was hit, when [stopReason] is
  /// [AgentStopReason.budgetExhausted].
  final BudgetDimension? budgetDimension;

  /// Every iteration, in order.
  final List<AgentStep> steps;

  /// Every message this run added to the conversation.
  ///
  /// Append these to a session's history to continue the conversation, or
  /// persist them as an audit trail of what the agent did on someone's behalf.
  final List<Message> messages;

  /// Total tokens across every model call in the run.
  final TokenUsage usage;

  /// Total estimated cost, when the model has pricing configured.
  final double? cost;

  /// The failure, when [stopReason] is [AgentStopReason.failed].
  final AgenticException? error;

  /// Application metadata carried through from the input.
  final Map<String, Object?> metadata;

  /// How long the run took.
  final Duration duration;

  /// The final answer text.
  String get text => message.text;

  /// Number of iterations the run took.
  int get iterations => steps.length;

  /// Every tool call made during the run, in order.
  List<ToolCallPart> get allToolCalls => <ToolCallPart>[
    for (final step in steps) ...step.toolCalls,
  ];

  /// Whether the run produced a usable answer.
  bool get isSuccess => stopReason.isSuccess;

  /// Throws when the run did not complete normally.
  ///
  /// The guard for a caller that will act on the answer. A budget-exhausted
  /// result may still contain a partial answer worth showing a user, but it
  /// should not silently become the input to something else.
  void ensureSuccess() {
    if (isSuccess) return;
    final failure = error;
    if (failure != null) throw failure;
    throw InvalidStateException(
      'The agent stopped for the reason `${stopReason.name}` and its answer '
      'should not be treated as complete.',
      currentState: stopReason.name,
      expectedState: AgentStopReason.completed.name,
      details: pruneNulls(<String, Object?>{
        'budgetDimension': budgetDimension?.name,
        'iterations': iterations,
      }),
    );
  }

  /// Parses the answer as JSON, optionally validating against [schema].
  JsonMap decodeJson({JsonSchema? schema}) {
    ensureSuccess();
    return ChatResponse(
      message: message,
      modelId: 'agent',
    ).decodeJson(schema: schema);
  }

  /// Serialises the result, including the step trail.
  JsonMap toJson() => pruneNulls(<String, Object?>{
    'text': text,
    'stopReason': stopReason.name,
    'budgetDimension': budgetDimension?.name,
    'iterations': iterations,
    'usage': usage.toJson(),
    'cost': cost,
    'durationMs': duration.inMilliseconds,
    'steps': steps.map((step) => step.toJson()).toList(),
    'error': error?.toJson(),
    'metadata': metadata.isEmpty ? null : metadata,
  });

  @override
  String toString() =>
      'AgentResult(${stopReason.name}, $iterations iterations, '
      '${usage.totalTokens} tokens, ${duration.inMilliseconds}ms)';
}
