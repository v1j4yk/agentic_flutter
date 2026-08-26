/// Events published while an agent runs.
///
/// These are the audit trail. When an agent has spent money on someone's
/// behalf, called a tool that changed something, or given a wrong answer, these
/// events are the record of what happened — available to a cost meter, a
/// compliance log or a debug console without any of them being wired into the
/// agent.
library;

import 'package:agentic_agents/src/agent/agent_budget.dart';
import 'package:agentic_agents/src/agent/agent_result.dart';
import 'package:agentic_core/agentic_core.dart';

/// Base for every agent lifecycle event.
abstract base class AgentEvent extends AgenticEvent {
  /// Creates an agent event.
  const AgentEvent({
    required super.id,
    required super.timestamp,
    required this.agentName,
    this.sessionId,
    super.runId,
    super.source,
    super.traceId,
    super.spanId,
  });

  /// Name of the agent involved.
  final String agentName;

  /// The conversation this run belongs to, when there is one.
  final String? sessionId;
}

/// A run has started.
final class AgentRunStarted extends AgentEvent {
  /// Creates the event.
  const AgentRunStarted({
    required super.id,
    required super.timestamp,
    required super.agentName,
    required this.budget,
    required this.toolCount,
    this.inputPreview,
    super.sessionId,
    super.runId,
    super.source,
    super.traceId,
    super.spanId,
  });

  /// The limits this run is bounded by.
  final AgentBudget budget;

  /// How many tools the agent was given.
  final int toolCount;

  /// A truncated rendering of the request.
  ///
  /// Truncated deliberately: this is user content, and an audit log should
  /// record that a question was asked without becoming a copy of every question
  /// ever asked.
  final String? inputPreview;

  @override
  String get type => 'agent.run.started';

  @override
  JsonMap payload() => pruneNulls(<String, Object?>{
    'agentName': agentName,
    'sessionId': sessionId,
    'budget': budget.toJson(),
    'toolCount': toolCount,
    'inputPreview': inputPreview,
  });
}

/// One iteration finished.
final class AgentStepCompleted extends AgentEvent {
  /// Creates the event.
  const AgentStepCompleted({
    required super.id,
    required super.timestamp,
    required super.agentName,
    required this.stepIndex,
    required this.toolCalls,
    required this.usage,
    required this.duration,
    super.sessionId,
    super.runId,
    super.source,
    super.traceId,
    super.spanId,
  });

  /// Zero-based index of the step.
  final int stepIndex;

  /// Names of the tools this step requested.
  final List<String> toolCalls;

  /// Tokens consumed by this step.
  final TokenUsage usage;

  /// How long the step took.
  final Duration duration;

  @override
  String get type => 'agent.step.completed';

  @override
  JsonMap payload() => <String, Object?>{
    'agentName': agentName,
    'stepIndex': stepIndex,
    'toolCalls': toolCalls,
    'tokens': usage.totalTokens,
    'durationMs': duration.inMilliseconds,
  };
}

/// A run finished, for any reason.
final class AgentRunCompleted extends AgentEvent {
  /// Creates the event.
  const AgentRunCompleted({
    required super.id,
    required super.timestamp,
    required super.agentName,
    required this.stopReason,
    required this.iterations,
    required this.usage,
    required this.duration,
    this.cost,
    this.budgetDimension,
    super.sessionId,
    super.runId,
    super.source,
    super.traceId,
    super.spanId,
  });

  /// Why the run stopped.
  final AgentStopReason stopReason;

  /// How many iterations it took.
  final int iterations;

  /// Total tokens consumed.
  final TokenUsage usage;

  /// Total estimated cost.
  final double? cost;

  /// Which budget limit was hit, when one was.
  final BudgetDimension? budgetDimension;

  /// Total wall-clock duration.
  final Duration duration;

  @override
  String get type => 'agent.run.completed';

  @override
  JsonMap payload() => pruneNulls(<String, Object?>{
    'agentName': agentName,
    'sessionId': sessionId,
    'stopReason': stopReason.name,
    'budgetDimension': budgetDimension?.name,
    'iterations': iterations,
    'tokens': usage.totalTokens,
    'cost': cost,
    'durationMs': duration.inMilliseconds,
  });
}

/// A run stopped because a budget limit was reached.
///
/// Published in addition to [AgentRunCompleted], because this is the signal
/// worth alerting on: a rising count means agents are getting stuck, which is a
/// prompt or tooling problem rather than an infrastructure one.
final class AgentBudgetExhausted extends AgentEvent {
  /// Creates the event.
  const AgentBudgetExhausted({
    required super.id,
    required super.timestamp,
    required super.agentName,
    required this.dimension,
    required this.explanation,
    super.sessionId,
    super.runId,
    super.source,
    super.traceId,
    super.spanId,
  });

  /// Which limit was hit.
  final BudgetDimension dimension;

  /// A human-readable account of what was consumed.
  final String explanation;

  @override
  String get type => 'agent.budget.exhausted';

  @override
  JsonMap payload() => <String, Object?>{
    'agentName': agentName,
    'dimension': dimension.name,
    'explanation': explanation,
  };
}

/// One agent handed work to another.
final class AgentDelegated extends AgentEvent {
  /// Creates the event.
  const AgentDelegated({
    required super.id,
    required super.timestamp,
    required super.agentName,
    required this.delegateName,
    required this.depth,
    super.sessionId,
    super.runId,
    super.source,
    super.traceId,
    super.spanId,
  });

  /// The agent receiving the work.
  final String delegateName;

  /// How deep the delegation chain now is.
  ///
  /// Recorded because unbounded delegation is the multi-agent equivalent of an
  /// unbounded loop, and depth is the number that shows it happening.
  final int depth;

  @override
  String get type => 'agent.delegated';

  @override
  JsonMap payload() => <String, Object?>{
    'agentName': agentName,
    'delegateName': delegateName,
    'depth': depth,
  };
}
