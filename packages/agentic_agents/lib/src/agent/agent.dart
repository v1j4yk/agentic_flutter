/// The agent contract.
///
/// An agent is a bounded loop around a model and a set of tools. It takes a
/// request, decides what to do, does it, and answers — repeatedly, until the
/// model stops asking for tools or a budget stops the run.
///
/// # Two ways to observe, and why both exist
///
/// [Agent.run] returns the finished [AgentResult]. [Agent.stream] returns a
/// sequence of [AgentChunk]s as the run proceeds. Separately, every agent
/// publishes events on `AgenticContext.events`.
///
/// That is not redundancy. The stream is for the *caller* — the chat screen
/// that is waiting for this answer and needs tokens as they arrive. The event
/// bus is for *observers* — a cost meter, an audit log, a debug console — that
/// care about every run in the application and must not be coupled to any
/// particular call site.
library;

import 'package:agentic_agents/src/agent/agent_budget.dart';
import 'package:agentic_agents/src/agent/agent_result.dart';
import 'package:agentic_agents/src/agent/agent_session.dart';
import 'package:agentic_core/agentic_core.dart';
import 'package:meta/meta.dart';

/// Identity and configuration of an agent.
@immutable
final class AgentInfo {
  /// Describes an agent.
  ///
  /// [name] appears in traces, events and — when the agent is exposed to
  /// another agent as a tool — in the tool name, so it must be a valid tool
  /// identifier: letters, digits, underscores and hyphens.
  AgentInfo({
    required this.name,
    required this.description,
    this.version = '1.0.0',
    Set<String> tags = const <String>{},
    Map<String, Object?> metadata = const <String, Object?>{},
  }) : tags = Set<String>.unmodifiable(tags),
       metadata = Map<String, Object?>.unmodifiable(metadata) {
    if (!RegExp(r'^[a-zA-Z0-9_-]{1,64}$').hasMatch(name)) {
      throw ConfigurationException(
        'Agent name `$name` is not usable. Names must be 1-64 characters of '
        'letters, digits, underscores or hyphens, because an agent can be '
        'exposed to another agent as a tool and inherits that constraint.',
        setting: 'AgentInfo.name',
      );
    }
  }

  /// Identifier, such as `researcher`.
  final String name;

  /// What this agent is for.
  ///
  /// Written for two audiences: a developer reading a registry, and — when the
  /// agent is delegated to — the supervising *model* deciding whether to hand
  /// it the task. Write it like a tool description.
  final String description;

  /// Semantic version of this agent's behaviour.
  final String version;

  /// Labels for selecting agents from a registry.
  final Set<String> tags;

  /// Application metadata.
  final Map<String, Object?> metadata;

  /// Serialises the description.
  JsonMap toJson() => pruneNulls(<String, Object?>{
    'name': name,
    'description': description,
    'version': version,
    'tags': tags.isEmpty ? null : (tags.toList()..sort()),
    'metadata': metadata.isEmpty ? null : metadata,
  });

  @override
  String toString() => 'AgentInfo($name v$version)';
}

/// What an agent is being asked to do.
@immutable
final class AgentInput {
  /// Creates an input from an existing [message].
  AgentInput({
    required this.message,
    Map<String, Object?> metadata = const <String, Object?>{},
    this.budget,
  }) : metadata = Map<String, Object?>.unmodifiable(metadata);

  /// Creates an input from text, optionally multimodal.
  factory AgentInput.text(
    String text, {
    List<ContentPart> parts = const <ContentPart>[],
    Map<String, Object?> metadata = const <String, Object?>{},
    AgentBudget? budget,
  }) => AgentInput(
    message: Message.user(text, parts: parts),
    metadata: metadata,
    budget: budget,
  );

  /// The user turn that starts the run.
  final Message message;

  /// Application metadata, carried through to the result and to events.
  ///
  /// The natural place for a feature name or a tenant, so a cost meter can
  /// attribute spend to something meaningful.
  final Map<String, Object?> metadata;

  /// Overrides the agent's configured budget for this run only.
  ///
  /// Useful when one request is known to be harder — a "research this
  /// thoroughly" button — without loosening the default for everything.
  final AgentBudget? budget;

  /// The request text.
  String get text => message.text;

  @override
  String toString() => 'AgentInput(${message.text.length} chars)';
}

/// An incremental update from a running agent.
///
/// `base` rather than `sealed`, unlike `ContentPart` in the core. The reasoning
/// is the opposite of that case, and worth stating.
///
/// A content part is sealed because every provider adapter *must* translate
/// every part, so a new modality should break every adapter at compile time.
///
/// A chunk is different: an agent type the framework does not ship — the
/// planner in this package, or one written downstream — legitimately has
/// updates of its own to report, and a UI that does not recognise one should
/// ignore it rather than fail to build. So new kinds are allowed, and a
/// `switch` over chunks needs a default branch.
@immutable
abstract base class AgentChunk {
  /// Const-constructible base for every update.
  const AgentChunk();
}

/// New answer text from the model.
@immutable
final class AgentTextDelta extends AgentChunk {
  /// Creates a text delta.
  const AgentTextDelta(this.text, {this.stepIndex = 0});

  /// The text to append.
  final String text;

  /// Which iteration produced it.
  final int stepIndex;

  @override
  String toString() => 'AgentTextDelta(${text.length} chars)';
}

/// New reasoning text from the model.
///
/// Separate from [AgentTextDelta] because reasoning must not be rendered as the
/// answer. Show it in a collapsible panel, or drop it.
@immutable
final class AgentReasoningDelta extends AgentChunk {
  /// Creates a reasoning delta.
  const AgentReasoningDelta(this.text, {this.stepIndex = 0});

  /// The reasoning text to append.
  final String text;

  /// Which iteration produced it.
  final int stepIndex;

  @override
  String toString() => 'AgentReasoningDelta(${text.length} chars)';
}

/// The agent is about to run a tool.
///
/// The update a user most wants to see: "searching the web", "reading your
/// calendar". Rendering these is the difference between a spinner and an
/// assistant that appears to be working.
@immutable
final class AgentToolCallStarted extends AgentChunk {
  /// Creates the update.
  AgentToolCallStarted({
    required this.toolName,
    required this.callId,
    Map<String, Object?> arguments = const <String, Object?>{},
    this.stepIndex = 0,
  }) : arguments = Map<String, Object?>.unmodifiable(arguments);

  /// The tool being invoked.
  final String toolName;

  /// Identifier correlating this with its result.
  final String callId;

  /// The validated arguments.
  final Map<String, Object?> arguments;

  /// Which iteration requested it.
  final int stepIndex;

  @override
  String toString() => 'AgentToolCallStarted($toolName)';
}

/// A tool finished.
@immutable
final class AgentToolCallFinished extends AgentChunk {
  /// Creates the update.
  const AgentToolCallFinished({
    required this.toolName,
    required this.callId,
    required this.summary,
    required this.isError,
    this.stepIndex = 0,
  });

  /// The tool that ran.
  final String toolName;

  /// Identifier correlating this with its call.
  final String callId;

  /// A short rendering of the result.
  final String summary;

  /// Whether the tool reported a failure.
  final bool isError;

  /// Which iteration requested it.
  final int stepIndex;

  @override
  String toString() =>
      'AgentToolCallFinished($toolName, ${isError ? 'error' : 'ok'})';
}

/// One iteration completed.
@immutable
final class AgentStepFinished extends AgentChunk {
  /// Creates the update.
  const AgentStepFinished(this.step);

  /// The completed step.
  final AgentStep step;

  @override
  String toString() => 'AgentStepFinished(${step.index})';
}

/// The run finished. Always the last chunk.
@immutable
final class AgentFinished extends AgentChunk {
  /// Creates the update.
  const AgentFinished(this.result);

  /// The complete result.
  final AgentResult result;

  @override
  String toString() => 'AgentFinished(${result.stopReason.name})';
}

/// A bounded loop around a model and a set of tools.
///
/// ```dart
/// final agent = ToolCallingAgent(
///   info: AgentInfo(name: 'researcher', description: 'Researches topics.'),
///   model: model,
///   tools: registry.select(tags: {'research'}),
///   instructions: 'Answer with citations. Say when you are unsure.',
/// );
///
/// final result = await agent.run(AgentInput.text('What changed in Dart 3.11?'));
/// print(result.text);
/// ```
///
/// Implementations must:
///
/// * enforce a budget — a loop with no bound is an outage waiting to happen;
/// * honour `AgenticContext.cancellation` between iterations at minimum;
/// * return failures as an [AgentResult] with [AgentStopReason.failed] rather
///   than throwing, except for cancellation, which propagates;
/// * be safe to reuse across runs. Per-run state belongs in [AgentSession].
abstract interface class Agent implements Disposable {
  /// Identity and description of this agent.
  AgentInfo get info;

  /// Runs to completion and returns the result.
  Future<AgentResult> run(
    AgentInput input, {
    AgentSession? session,
    AgenticContext? context,
  });

  /// Runs, emitting updates as they happen.
  ///
  /// The final chunk is always an [AgentFinished]. Cancelling the subscription
  /// stops the run and closes any in-flight model connection.
  Stream<AgentChunk> stream(
    AgentInput input, {
    AgentSession? session,
    AgenticContext? context,
  });
}

/// Conveniences available on every [Agent].
extension AgentOperations on Agent {
  /// Runs with a plain text prompt and returns the answer text.
  ///
  /// Throws if the run did not complete normally, so a caller that ignores
  /// [AgentResult] cannot silently act on a budget-truncated answer.
  Future<String> ask(
    String prompt, {
    AgentSession? session,
    AgenticContext? context,
  }) async {
    final result = await run(
      AgentInput.text(prompt),
      session: session,
      context: context,
    );
    result.ensureSuccess();
    return result.text;
  }

  /// Runs and returns only the answer text as it streams.
  ///
  /// Drops tool updates and reasoning, so a simple chat bubble can bind to it
  /// directly.
  Stream<String> askStream(
    String prompt, {
    AgentSession? session,
    AgenticContext? context,
  }) => stream(AgentInput.text(prompt), session: session, context: context)
      .where((chunk) => chunk is AgentTextDelta)
      .map((chunk) => (chunk as AgentTextDelta).text);
}

/// Wraps another [Agent], delegating everything by default.
///
/// The base for cross-cutting agent behaviour — guardrails, approval gating,
/// transcript recording — added by composition rather than by subclassing a
/// concrete agent.
abstract class DelegatingAgent implements Agent {
  /// Wraps [inner].
  const DelegatingAgent(this.inner);

  /// The wrapped agent.
  final Agent inner;

  @override
  AgentInfo get info => inner.info;

  @override
  Future<AgentResult> run(
    AgentInput input, {
    AgentSession? session,
    AgenticContext? context,
  }) => inner.run(input, session: session, context: context);

  @override
  Stream<AgentChunk> stream(
    AgentInput input, {
    AgentSession? session,
    AgenticContext? context,
  }) => inner.stream(input, session: session, context: context);

  @override
  Future<void> dispose() => inner.dispose();
}
