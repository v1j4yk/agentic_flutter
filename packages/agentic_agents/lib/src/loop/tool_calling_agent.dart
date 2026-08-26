/// The tool-calling loop.
///
/// Ask the model. If it requested tools, run them, append the results, ask
/// again. Stop when it answers in prose, when a budget is reached, or when the
/// caller says so.
///
/// That is four lines of description and the reason it stays four lines is that
/// every hard part already belongs to a layer underneath: the model port
/// normalises three providers, the tool executor validates arguments and
/// enforces consent, the run context carries cancellation and tracing. What is
/// left here is the loop itself and the decisions that only the loop can make.
///
/// # The decisions that only the loop can make
///
/// **Running out of budget must still produce an answer.** An agent that hits
/// its iteration limit mid-investigation and returns nothing has wasted every
/// token it spent. On its last permitted iteration this loop forbids tool
/// calling — the tools stay *described*, so the transcript remains valid — which
/// forces the model to answer with what it has. A best-effort answer plus a
/// note beats a spinner and an error.
///
/// **A failing tool is not a failing run.** Tool failures come back as messages
/// the model reads and works around. Only cancellation stops the loop.
///
/// **A failure should still return the trail.** When something does go wrong,
/// the result carries `stopReason: failed` and every step taken up to that
/// point, rather than an exception that discards the evidence.
/// [AgentResult.ensureSuccess] rethrows for callers who want the exception.
library;

import 'dart:async';

import 'package:agentic_agents/src/agent/agent.dart';
import 'package:agentic_agents/src/agent/agent_budget.dart';
import 'package:agentic_agents/src/agent/agent_result.dart';
import 'package:agentic_agents/src/agent/agent_session.dart';
import 'package:agentic_agents/src/events/agent_events.dart';
import 'package:agentic_core/agentic_core.dart';
import 'package:agentic_llm/agentic_llm.dart';
import 'package:agentic_tools/agentic_tools.dart';

/// Decides whether the loop should stop after a step.
///
/// Consulted after each completed iteration. Returning `true` ends the run with
/// [AgentStopReason.stopped].
typedef AgentStopCondition = bool Function(AgentStep step);

/// An agent that answers by calling tools until it can answer in prose.
///
/// ```dart
/// final agent = ToolCallingAgent(
///   info: AgentInfo(
///     name: 'researcher',
///     description: 'Researches topics using web search.',
///   ),
///   model: model,
///   tools: registry.select(tags: {'research'}),
///   instructions: 'Cite your sources. Say so when you are unsure.',
///   budget: AgentBudget.interactive,
/// );
///
/// final result = await agent.run(AgentInput.text('What changed in Dart 3.11?'));
/// ```
final class ToolCallingAgent implements Agent {
  /// Creates an agent.
  ///
  /// [instructions] becomes the system prompt. Keep it **stable**: a system
  /// prompt that varies per request defeats provider prompt caching, which is
  /// usually the single largest cost saving available to an agent that runs
  /// many turns over the same instructions.
  ToolCallingAgent({
    required this.info,
    required this.model,
    this.tools,
    this.instructions,
    this.budget = AgentBudget.standard,
    this.temperature,
    this.maxOutputTokens,
    this.responseFormat = ResponseFormat.text,
    this.stopWhen,
    ToolExecutor? executor,
    this.ownsModel = false,
  }) : _executor =
           executor ?? (tools == null ? null : ToolExecutor(tools: tools));

  @override
  final AgentInfo info;

  /// The model this agent reasons with.
  final ChatModel model;

  /// The tools this agent may call.
  ///
  /// Give it the smallest set that covers its job. Tool-selection accuracy
  /// falls measurably as the set grows, and every spec is serialised into every
  /// request on every iteration — so an unused tool is paid for repeatedly.
  final ToolSet? tools;

  /// The system prompt.
  final String? instructions;

  /// Default limits for a run.
  final AgentBudget budget;

  /// Sampling temperature passed to the model.
  ///
  /// Leave it unset for a general assistant. Set it low for an agent whose job
  /// is extraction or routing, where determinism beats variety.
  final double? temperature;

  /// Maximum completion tokens per model call.
  final int? maxOutputTokens;

  /// Shape the final answer must take.
  final ResponseFormat responseFormat;

  /// Optional early-stop condition, evaluated after each step.
  final AgentStopCondition? stopWhen;

  /// Whether [dispose] should also dispose [model].
  ///
  /// Defaults to `false`, because a model is normally shared between several
  /// agents and disposing it from one of them would break the others.
  final bool ownsModel;

  final ToolExecutor? _executor;

  @override
  Future<AgentResult> run(
    AgentInput input, {
    AgentSession? session,
    AgenticContext? context,
  }) async {
    await for (final chunk in _execute(
      input,
      session: session,
      context: context,
      streaming: false,
    )) {
      if (chunk is AgentFinished) return chunk.result;
    }
    // Unreachable: `_execute` always ends with an `AgentFinished`.
    throw InvalidStateException(
      'The agent loop ended without producing a result.',
      currentState: 'exhausted stream',
      expectedState: 'AgentFinished',
    );
  }

  @override
  Stream<AgentChunk> stream(
    AgentInput input, {
    AgentSession? session,
    AgenticContext? context,
  }) => _execute(
    input,
    session: session,
    context: context,
    // Degrades gracefully: a model without streaming still runs, it simply
    // delivers each step's text in one piece.
    streaming: model.info.supports(ModelCapability.streaming),
  );

  @override
  Future<void> dispose() async {
    if (ownsModel) await model.dispose();
  }

  // ---------------------------------------------------------------------------
  // The loop
  // ---------------------------------------------------------------------------

  Stream<AgentChunk> _execute(
    AgentInput input, {
    required AgentSession? session,
    required AgenticContext? context,
    required bool streaming,
  }) async* {
    final root = context ?? AgenticContext.root();
    final scope = root.child('agent.${info.name}');
    final effectiveBudget = input.budget ?? budget;
    final tracker = BudgetTracker(
      budget: effectiveBudget,
      clock: scope.clock,
      humanWait: scope.humanWait,
    );
    final startedAt = scope.clock.now();

    final span = scope.tracer.startSpan(
      'agent.${info.name}',
      parent: scope.traceContext,
      attributes: <String, Object?>{
        'agent.name': info.name,
        'agent.version': info.version,
        'agent.tools': tools?.length ?? 0,
        'agent.max_iterations': effectiveBudget.maxIterations,
      },
    );

    _publish(
      scope,
      AgentRunStarted(
        id: scope.ids.prefixed('evt'),
        timestamp: startedAt,
        agentName: info.name,
        sessionId: session?.id,
        budget: effectiveBudget,
        toolCount: tools?.length ?? 0,
        inputPreview: _preview(input.text),
        runId: scope.runId,
        source: 'agent:${info.name}',
        traceId: span.context.traceId,
        spanId: span.context.spanId,
      ),
    );

    final steps = <AgentStep>[];
    final produced = <Message>[input.message];
    var forcedFinalTurn = false;

    // Awaited before the loop starts: a strategy may summarise or retrieve, and
    // that work belongs to assembling the request rather than to any iteration.
    // The pending turn is handed to the strategy even though it is not yet part
    // of the transcript: a retrieving strategy must recall against the question
    // just asked, not against the previous one.
    final recalled = session == null
        ? const <Message>[]
        : await session.selectHistory(pending: input.message, context: scope);

    var conversation = <Message>[
      if (instructions case final prompt?) Message.system(prompt),
      ...recalled,
      input.message,
    ];

    AgentResult finish(
      AgentStopReason reason, {
      Message? message,
      BudgetDimension? dimension,
      AgenticException? error,
    }) {
      final answer =
          message ??
          _lastAnswer(produced) ??
          Message.assistant(
            dimension == null
                ? 'The agent stopped without producing an answer.'
                : tracker.explain(dimension),
          );
      final result = AgentResult(
        message: answer,
        stopReason: reason,
        budgetDimension: dimension,
        steps: steps,
        messages: produced,
        usage: tracker.usage,
        cost: tracker.cost == 0 ? null : tracker.cost,
        error: error,
        duration: scope.clock.now().difference(startedAt),
        metadata: <String, Object?>{
          ...input.metadata,
          if (forcedFinalTurn) 'finalTurnForced': true,
        },
      );

      span
        ..setAttributes(<String, Object?>{
          'agent.stop_reason': reason.name,
          'agent.iterations': steps.length,
          'agent.tokens': tracker.usage.totalTokens,
        })
        ..setStatus(
          reason.isSuccess ? SpanStatus.ok : SpanStatus.error,
          reason.isSuccess ? null : reason.name,
        )
        ..end();

      _publish(
        scope,
        AgentRunCompleted(
          id: scope.ids.prefixed('evt'),
          timestamp: scope.clock.now(),
          agentName: info.name,
          sessionId: session?.id,
          stopReason: reason,
          iterations: steps.length,
          usage: tracker.usage,
          cost: result.cost,
          budgetDimension: dimension,
          duration: result.duration,
          runId: scope.runId,
          source: 'agent:${info.name}',
          traceId: span.context.traceId,
          spanId: span.context.spanId,
        ),
      );

      session?.recordRun(result);
      return result;
    }

    try {
      while (true) {
        scope.throwIfCancelled();

        // Checked *before* starting an iteration: a budget bounds what is
        // begun, not what is reported afterwards.
        if (tracker.exhausted case final dimension?) {
          _publish(
            scope,
            AgentBudgetExhausted(
              id: scope.ids.prefixed('evt'),
              timestamp: scope.clock.now(),
              agentName: info.name,
              sessionId: session?.id,
              dimension: dimension,
              explanation: tracker.explain(dimension),
              runId: scope.runId,
              source: 'agent:${info.name}',
            ),
          );
          scope.logger.warn(
            'Agent stopped on its budget',
            fields: <String, Object?>{
              'agent': info.name,
              'dimension': dimension.name,
              ...tracker.toJson(),
            },
          );
          yield AgentFinished(
            finish(AgentStopReason.budgetExhausted, dimension: dimension),
          );
          return;
        }

        // On the last permitted iteration, forbid tool calling so the model has
        // to answer. The tools stay described, which keeps earlier tool calls in
        // the transcript valid.
        final isFinal =
            tracker.isFinalIteration && (tools?.isNotEmpty ?? false);
        if (isFinal) forcedFinalTurn = true;

        final stepIndex = steps.length;
        final stepStartedAt = scope.clock.now();

        final request = ChatRequest(
          messages: conversation,
          tools: tools,
          toolChoice: isFinal ? ToolChoice.none : ToolChoice.auto,
          temperature: temperature,
          maxOutputTokens: maxOutputTokens,
          responseFormat: responseFormat,
          metadata: input.metadata,
        );

        final ChatResponse response;
        if (streaming) {
          final builder = ChatResponseBuilder(modelId: model.info.id);
          await for (final chunk in model.stream(request, context: scope)) {
            builder.add(chunk);
            if (chunk.textDelta case final text?) {
              yield AgentTextDelta(text, stepIndex: stepIndex);
            }
            if (chunk.reasoningDelta case final text?) {
              yield AgentReasoningDelta(text, stepIndex: stepIndex);
            }
          }
          response = builder.build();
        } else {
          response = await model.generate(request, context: scope);
        }

        tracker.recordIteration(usage: response.usage, cost: response.cost);
        produced.add(response.message);
        conversation = <Message>[...conversation, response.message];

        // No tool calls means the model is done talking to itself.
        if (!response.hasToolCalls) {
          final step = AgentStep(
            index: stepIndex,
            response: response,
            duration: scope.clock.now().difference(stepStartedAt),
          );
          steps.add(step);
          _publishStep(scope, session, span, step);
          yield AgentStepFinished(step);
          yield AgentFinished(
            finish(AgentStopReason.completed, message: response.message),
          );
          return;
        }

        for (final call in response.toolCalls) {
          yield AgentToolCallStarted(
            toolName: call.name,
            callId: call.id,
            arguments: call.arguments,
            stepIndex: stepIndex,
          );
        }

        final executor = _executor;
        final resultMessages = executor == null
            ? _refuseToolCalls(response.toolCalls)
            : await executor.executeAllAsMessages(
                response.toolCalls,
                context: scope,
              );

        tracker.recordToolCalls(response.toolCalls.length);
        produced.addAll(resultMessages);
        conversation = <Message>[...conversation, ...resultMessages];

        for (final message in resultMessages) {
          for (final result in message.toolResults) {
            yield AgentToolCallFinished(
              toolName: result.name,
              callId: result.callId,
              summary: _preview(result.content) ?? '',
              isError: result.isError,
              stepIndex: stepIndex,
            );
          }
        }

        final step = AgentStep(
          index: stepIndex,
          response: response,
          toolCalls: response.toolCalls,
          toolResults: resultMessages,
          duration: scope.clock.now().difference(stepStartedAt),
        );
        steps.add(step);
        _publishStep(scope, session, span, step);
        yield AgentStepFinished(step);

        if (stopWhen?.call(step) ?? false) {
          yield AgentFinished(finish(AgentStopReason.stopped));
          return;
        }
      }
    } on CancelledException catch (error) {
      // Cancellation propagates, but the caller still gets the trail: the
      // result is published on the bus and recorded on the session before the
      // exception leaves.
      span
        ..recordError(error)
        ..end();
      _publish(
        scope,
        AgentRunCompleted(
          id: scope.ids.prefixed('evt'),
          timestamp: scope.clock.now(),
          agentName: info.name,
          sessionId: session?.id,
          stopReason: AgentStopReason.cancelled,
          iterations: steps.length,
          usage: tracker.usage,
          duration: scope.clock.now().difference(startedAt),
          runId: scope.runId,
          source: 'agent:${info.name}',
        ),
      );
      rethrow;
    } on AgenticException catch (error, stackTrace) {
      scope.logger.error(
        'Agent run failed',
        fields: <String, Object?>{'agent': info.name, 'code': error.code},
        error: error,
        stackTrace: stackTrace,
      );
      error.annotateAll(<String, Object?>{
        'agent.name': info.name,
        'agent.iteration': steps.length,
      });
      yield AgentFinished(
        finish(
          AgentStopReason.failed,
          message: Message.assistant(
            'The agent could not finish: ${error.message}',
          ),
          error: error,
        ),
      );
    }
  }

  /// Answers tool calls when the agent has no executor.
  ///
  /// Reachable only when a model invents a tool call despite being given no
  /// tools, which small models occasionally do. Telling it so is better than
  /// crashing, and better than an empty turn it cannot interpret.
  List<Message> _refuseToolCalls(List<ToolCallPart> calls) => <Message>[
    for (final call in calls)
      Message.toolResult(
        callId: call.id,
        name: call.name,
        content:
            'No tools are available to this agent. Answer using what you '
            'already know.',
        isError: true,
      ),
  ];

  void _publishStep(
    AgenticContext scope,
    AgentSession? session,
    Span parent,
    AgentStep step,
  ) => _publish(
    scope,
    AgentStepCompleted(
      id: scope.ids.prefixed('evt'),
      timestamp: scope.clock.now(),
      agentName: info.name,
      sessionId: session?.id,
      stepIndex: step.index,
      toolCalls: step.toolCalls.map((call) => call.name).toList(),
      usage: step.usage,
      duration: step.duration,
      runId: scope.runId,
      source: 'agent:${info.name}',
      traceId: parent.context.traceId,
      spanId: parent.context.spanId,
    ),
  );

  void _publish(AgenticContext scope, AgenticEvent event) =>
      scope.publish(event);

  /// The most recent message carrying prose, searching backwards.
  static Message? _lastAnswer(List<Message> messages) {
    for (final message in messages.reversed) {
      if (message.role == MessageRole.assistant && message.text.isNotEmpty) {
        return message;
      }
    }
    return null;
  }

  static String? _preview(String text) {
    final collapsed = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (collapsed.isEmpty) return null;
    return collapsed.length <= 160
        ? collapsed
        : '${collapsed.substring(0, 157)}...';
  }

  @override
  String toString() =>
      'ToolCallingAgent(${info.name}, ${tools?.length ?? 0} tools)';
}
