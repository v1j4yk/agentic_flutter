/// Plan first, then execute.
///
/// # When a loop is the wrong shape
///
/// `ToolCallingAgent` decides one step at a time. That is right for most work
/// and wrong for work with structure the model can see up front: "research
/// these five companies and compare them" is five independent investigations
/// and a synthesis, and a one-step-at-a-time loop rediscovers that fact on
/// every iteration while carrying the whole growing transcript.
///
/// Planning first buys three things:
///
/// * **Visibility.** The plan exists before any work is done, so it can be
///   shown to a user, logged, or rejected.
/// * **Isolation.** Each step runs with a clean context, so step four does not
///   pay for step one's transcript.
/// * **A cheaper planner.** Planning and executing are different jobs; the plan
///   can come from a strong model and the steps from a cheap one.
///
/// It costs an extra model call and, more importantly, commits to a plan made
/// before any evidence was gathered. Use it when the shape of the work is
/// knowable in advance, and a plain loop when it is not.
library;

import 'dart:async';

import 'package:agentic_agents/src/agent/agent.dart';
import 'package:agentic_agents/src/agent/agent_budget.dart';
import 'package:agentic_agents/src/agent/agent_result.dart';
import 'package:agentic_agents/src/agent/agent_session.dart';
import 'package:agentic_agents/src/events/agent_events.dart';
import 'package:agentic_core/agentic_core.dart';
import 'package:agentic_llm/agentic_llm.dart';
import 'package:meta/meta.dart';

/// One step of a plan.
@immutable
final class PlanStep {
  /// Creates a step.
  const PlanStep({required this.description, this.rationale});

  /// Restores a step from the planner's JSON.
  factory PlanStep.fromJson(JsonMap json) => PlanStep(
    description: json.requireString('description'),
    rationale: json.optionalString('rationale'),
  );

  /// A complete, self-contained instruction for the executor.
  final String description;

  /// Why the planner included this step.
  ///
  /// Not sent to the executor — it is for a human reading the plan.
  final String? rationale;

  /// Serialises the step.
  JsonMap toJson() => pruneNulls(<String, Object?>{
    'description': description,
    'rationale': rationale,
  });

  @override
  String toString() => 'PlanStep($description)';
}

/// A plan produced before any work is done.
@immutable
final class Plan {
  /// Creates a plan.
  Plan({required List<PlanStep> steps, this.summary})
    : steps = List<PlanStep>.unmodifiable(steps);

  /// Restores a plan from the planner's JSON.
  factory Plan.fromJson(JsonMap json) => Plan(
    steps: json.decodeList('steps', PlanStep.fromJson),
    summary: json.optionalString('summary'),
  );

  /// The steps, in the order they should run.
  final List<PlanStep> steps;

  /// The planner's one-line description of its approach.
  final String? summary;

  /// Whether the planner decided no steps were needed.
  ///
  /// A legitimate outcome: "what is 2 + 2" needs no plan, and a planner that
  /// invents busywork for it is worse than one that says so.
  bool get isEmpty => steps.isEmpty;

  /// Serialises the plan.
  JsonMap toJson() => pruneNulls(<String, Object?>{
    'summary': summary,
    'steps': steps.map((step) => step.toJson()).toList(),
  });

  /// The schema the planner is constrained to.
  ///
  /// Exposed so a caller can reuse it — for a "show me the plan first" flow
  /// that asks for a plan without executing it.
  static JsonSchema schemaFor({required int maxSteps}) => JsonSchema.object(
    description: 'A short plan for answering the request.',
    properties: <String, JsonSchema>{
      'summary': JsonSchema.string(
        description: 'One sentence describing the overall approach.',
      ),
      'steps': JsonSchema.array(
        description:
            'The steps to carry out, in order. Use as few as possible. '
            'Return an empty list if the request can be answered directly '
            'without any research or tool use.',
        maxItems: maxSteps,
        items: JsonSchema.object(
          properties: <String, JsonSchema>{
            'description': JsonSchema.string(
              description:
                  'A complete, self-contained instruction. The executor '
                  'cannot see the other steps or the original request, so '
                  'repeat anything it needs.',
              minLength: 1,
            ),
            'rationale': JsonSchema.string(
              description: 'Why this step is needed.',
            ),
          },
          required: const <String>{'description'},
        ),
      ),
    },
    required: const <String>{'steps'},
  );

  @override
  String toString() => 'Plan(${steps.length} steps)';
}

/// Emitted while a planning agent works, in addition to the usual chunks.
@immutable
final class AgentPlanReady extends AgentChunk {
  /// Creates the update.
  const AgentPlanReady(this.plan);

  /// The plan about to be executed.
  final Plan plan;

  @override
  String toString() => 'AgentPlanReady(${plan.steps.length} steps)';
}

/// Emitted as each plan step begins.
@immutable
final class AgentPlanStepStarted extends AgentChunk {
  /// Creates the update.
  const AgentPlanStepStarted({
    required this.index,
    required this.total,
    required this.step,
  });

  /// Zero-based position of the step.
  final int index;

  /// How many steps the plan has.
  final int total;

  /// The step being started.
  final PlanStep step;

  @override
  String toString() => 'AgentPlanStepStarted(${index + 1}/$total)';
}

/// Decomposes a request into steps, runs them, then synthesises an answer.
///
/// ```dart
/// final agent = PlannerExecutorAgent(
///   info: AgentInfo(
///     name: 'analyst',
///     description: 'Researches a topic in depth and reports on it.',
///   ),
///   planner: strongModel,
///   executor: ToolCallingAgent(
///     info: AgentInfo(name: 'worker', description: 'Carries out one step.'),
///     model: cheapModel,
///     tools: registry.select(tags: {'research'}),
///   ),
/// );
/// ```
/// **Experimental.** Planner/executor is the agent shape with the least
/// settled interface: how a plan is represented, whether steps are re-planned
/// mid-run, and what a partial plan means on failure are all still being
/// learned from use. `ToolCallingAgent` carries the package's compatibility
/// promise; this does not yet.
@experimental
final class PlannerExecutorAgent implements Agent {
  /// Creates a planning agent.
  ///
  /// [planner] produces the plan and, when [synthesise] is set, the final
  /// answer. [executor] carries out each step; it is normally a
  /// `ToolCallingAgent` with the tools the work needs.
  PlannerExecutorAgent({
    required this.info,
    required this.planner,
    required this.executor,
    this.maxSteps = 5,
    this.instructions,
    this.synthesise = true,
    this.budget = AgentBudget.background,
    this.ownsCollaborators = false,
  }) : assert(maxSteps >= 1, 'maxSteps must be at least 1');

  @override
  final AgentInfo info;

  /// The model that plans and synthesises.
  final ChatModel planner;

  /// The agent that carries out each step.
  final Agent executor;

  /// Maximum steps a plan may contain.
  ///
  /// A hard bound on fan-out, and the reason a planner cannot turn one request
  /// into forty sub-runs.
  final int maxSteps;

  /// Extra guidance given to the planner.
  final String? instructions;

  /// Whether to make a final model call that synthesises the step results.
  ///
  /// On by default. Without it the answer is the last step's output, which is
  /// rarely what the user asked for.
  final bool synthesise;

  /// Limits applied to planning and synthesis.
  ///
  /// Each step's execution is bounded by the executor's own budget; this one
  /// covers the calls this agent makes directly.
  final AgentBudget budget;

  /// Whether [dispose] should also dispose [planner] and [executor].
  final bool ownsCollaborators;

  @override
  Future<AgentResult> run(
    AgentInput input, {
    AgentSession? session,
    AgenticContext? context,
  }) async {
    await for (final chunk in stream(
      input,
      session: session,
      context: context,
    )) {
      if (chunk is AgentFinished) return chunk.result;
    }
    throw InvalidStateException(
      'The planning agent ended without producing a result.',
      currentState: 'exhausted stream',
      expectedState: 'AgentFinished',
    );
  }

  @override
  Stream<AgentChunk> stream(
    AgentInput input, {
    AgentSession? session,
    AgenticContext? context,
  }) async* {
    final root = context ?? AgenticContext.root();
    final scope = root.child('agent.${info.name}');
    final tracker = BudgetTracker(
      budget: input.budget ?? budget,
      clock: scope.clock,
      humanWait: scope.humanWait,
    );
    final startedAt = scope.clock.now();
    final steps = <AgentStep>[];
    final produced = <Message>[input.message];

    scope.publish(
      AgentRunStarted(
        id: scope.ids.prefixed('evt'),
        timestamp: startedAt,
        agentName: info.name,
        sessionId: session?.id,
        budget: input.budget ?? budget,
        toolCount: 0,
        runId: scope.runId,
        source: 'agent:${info.name}',
      ),
    );

    AgentResult finish(
      AgentStopReason reason, {
      required Message message,
      AgenticException? error,
      Map<String, Object?> metadata = const <String, Object?>{},
    }) {
      final result = AgentResult(
        message: message,
        stopReason: reason,
        steps: steps,
        messages: produced,
        usage: tracker.usage,
        cost: tracker.cost == 0 ? null : tracker.cost,
        error: error,
        duration: scope.clock.now().difference(startedAt),
        metadata: <String, Object?>{...input.metadata, ...metadata},
      );
      scope.publish(
        AgentRunCompleted(
          id: scope.ids.prefixed('evt'),
          timestamp: scope.clock.now(),
          agentName: info.name,
          sessionId: session?.id,
          stopReason: reason,
          iterations: steps.length,
          usage: tracker.usage,
          cost: result.cost,
          duration: result.duration,
          runId: scope.runId,
          source: 'agent:${info.name}',
        ),
      );
      session?.recordRun(result);
      return result;
    }

    try {
      scope.throwIfCancelled();

      // ---- Plan ------------------------------------------------------------
      final plan = await _plan(input, scope, tracker);
      yield AgentPlanReady(plan);

      scope.logger.info(
        'Plan ready',
        fields: <String, Object?>{
          'agent': info.name,
          'steps': plan.steps.length,
          'summary': plan.summary,
        },
      );

      // A planner that says no steps are needed is answering directly, which is
      // the correct outcome for a simple request. Fall through to synthesis.
      final findings = <String>[];

      for (var i = 0; i < plan.steps.length; i++) {
        scope.throwIfCancelled();
        final step = plan.steps[i];
        yield AgentPlanStepStarted(
          index: i,
          total: plan.steps.length,
          step: step,
        );

        // Each step runs with a clean context: no session, and no accumulated
        // transcript. That is the isolation that keeps step five as cheap as
        // step one.
        final stepResult = await executor.run(
          AgentInput.text(step.description, metadata: input.metadata),
          context: scope.child('step.$i'),
        );

        findings.add(
          '### Step ${i + 1}: ${step.description}\n'
          '${stepResult.text.isEmpty ? '(no output)' : stepResult.text}',
        );

        steps.addAll(stepResult.steps);
        tracker.recordIteration(usage: stepResult.usage, cost: stepResult.cost);
      }

      // ---- Synthesise ------------------------------------------------------
      scope.throwIfCancelled();
      final answer = synthesise || plan.isEmpty
          ? await _synthesise(input, plan, findings, scope, tracker)
          : Message.assistant(findings.join('\n\n'));

      produced.add(answer);
      yield AgentFinished(
        finish(
          AgentStopReason.completed,
          message: answer,
          metadata: <String, Object?>{'plan': plan.toJson()},
        ),
      );
    } on CancelledException {
      rethrow;
    } on AgenticException catch (error, stackTrace) {
      scope.logger.error(
        'Planning agent failed',
        fields: <String, Object?>{'agent': info.name, 'code': error.code},
        error: error,
        stackTrace: stackTrace,
      );
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

  @override
  Future<void> dispose() async {
    if (!ownsCollaborators) return;
    final bag = DisposableBag()
      ..add(executor)
      ..add(planner);
    await bag.dispose();
  }

  Future<Plan> _plan(
    AgentInput input,
    AgenticContext scope,
    BudgetTracker tracker,
  ) async {
    final schema = Plan.schemaFor(maxSteps: maxSteps);

    final request = ChatRequest(
      messages: <Message>[
        Message.system(
          'You plan work for an execution agent. Break the request into at '
          'most $maxSteps steps, each a complete instruction the executor can '
          'follow without seeing the original request or the other steps. '
          'Prefer fewer steps. Return no steps at all if the request can be '
          'answered directly.'
          '${instructions == null ? '' : '\n\n$instructions'}',
        ),
        input.message,
      ],
      // Planning is a structuring task, not a creative one.
      temperature: 0,
      metadata: input.metadata,
    );

    final plan = await planner.generateStructured<Plan>(
      request,
      name: 'plan',
      schema: schema,
      fromJson: Plan.fromJson,
      context: scope,
    );

    // The planner's own consumption is charged to this agent's budget; the
    // steps are charged as they run.
    tracker.recordIteration();
    return plan;
  }

  Future<Message> _synthesise(
    AgentInput input,
    Plan plan,
    List<String> findings,
    AgenticContext scope,
    BudgetTracker tracker,
  ) async {
    final request = ChatRequest(
      messages: <Message>[
        Message.system(
          'You answer the user using findings gathered by an execution agent. '
          'Use only what the findings support. Say plainly when something '
          'could not be determined rather than filling the gap.'
          '${instructions == null ? '' : '\n\n$instructions'}',
        ),
        Message.user(
          findings.isEmpty
              ? input.text
              : '${input.text}\n\n'
                    'Findings:\n\n${findings.join('\n\n')}',
        ),
      ],
      metadata: input.metadata,
    );

    final response = await planner.generate(request, context: scope);
    tracker.recordIteration(usage: response.usage, cost: response.cost);
    return response.message;
  }

  @override
  String toString() =>
      'PlannerExecutorAgent(${info.name}, maxSteps: $maxSteps)';
}
