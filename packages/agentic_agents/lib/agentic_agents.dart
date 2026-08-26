/// Agent orchestration for the agentic framework.
///
/// An agent is a bounded loop around a model and a set of tools. This package
/// provides the loop, the bounds, the conversation state, planner/executor
/// decomposition, and multi-agent delegation.
///
/// ```dart
/// import 'package:agentic_agents/agentic_agents.dart';
///
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
/// print('${result.text} (${result.iterations} steps, ${result.usage.totalTokens} tokens)');
/// ```
///
/// Delegation needs no separate mechanism: `AgentTool` presents an agent as a
/// tool, so a supervisor is an ordinary agent whose tools happen to be other
/// agents.
library;

// --- The contract ------------------------------------------------------------
export 'src/agent/agent.dart'
    show
        Agent,
        AgentChunk,
        AgentFinished,
        AgentInfo,
        AgentInput,
        AgentOperations,
        AgentReasoningDelta,
        AgentStepFinished,
        AgentTextDelta,
        AgentToolCallFinished,
        AgentToolCallStarted,
        DelegatingAgent;
// --- Bounds ------------------------------------------------------------------
export 'src/agent/agent_budget.dart'
    show AgentBudget, BudgetDimension, BudgetTracker;
export 'src/agent/agent_result.dart'
    show AgentResult, AgentStep, AgentStopReason;
// --- Conversation state ------------------------------------------------------
export 'src/agent/agent_session.dart'
    show
        AgentSession,
        CharacterBudgetHistory,
        HistoryStrategy,
        KeepAllHistory,
        SlidingWindowHistory,
        repairDanglingToolResults;
// --- Events ------------------------------------------------------------------
export 'src/events/agent_events.dart'
    show
        AgentBudgetExhausted,
        AgentDelegated,
        AgentEvent,
        AgentRunCompleted,
        AgentRunStarted,
        AgentStepCompleted;
// --- The loop ----------------------------------------------------------------
export 'src/loop/tool_calling_agent.dart'
    show AgentStopCondition, ToolCallingAgent;
// --- Multi-agent -------------------------------------------------------------
export 'src/multi/agent_tool.dart'
    show AgentTool, kDelegationDepthKey, supervisorOver;
// --- Planner/executor --------------------------------------------------------
export 'src/planner/planner_executor_agent.dart'
    show
        AgentPlanReady,
        AgentPlanStepStarted,
        Plan,
        PlanStep,
        PlannerExecutorAgent;
