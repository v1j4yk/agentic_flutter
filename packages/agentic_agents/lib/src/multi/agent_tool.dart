/// Delegation, modelled as a tool call.
///
/// # Why multi-agent needs no new mechanism
///
/// A supervisor deciding to hand research to a researcher is doing exactly what
/// it does when it decides to call a search tool: choosing a capability by
/// name, supplying arguments, and reading back a result. The only difference is
/// what happens on the other side.
///
/// So delegation here is an adapter, not an architecture. [AgentTool] presents
/// an [Agent] as a [Tool], and a supervisor is an ordinary [ToolCallingAgent]
/// whose tools happen to be other agents. Everything already
/// built applies unchanged: argument validation, approval gating, time budgets,
/// tracing, events, cancellation.
///
/// The alternative — a bespoke "crew" abstraction with its own routing,
/// messaging and lifecycle — would duplicate all of that and would still have
/// to solve the two problems below.
///
/// # The two problems delegation does add
///
/// **Unbounded recursion.** A supervisor that can delegate to a researcher that
/// can delegate to a supervisor will do so, forever. [AgentTool.maxDepth]
/// bounds the chain, tracked through the run context so it survives across
/// agents that know nothing about each other.
///
/// **Budgets do not nest.** A sub-agent has its own [AgentBudget]; the parent's
/// does not constrain it, so a supervisor with a 100k token budget can spawn
/// five sub-agents that spend 100k each. That is a deliberate trade — threading
/// one mutable tracker through independent agents would couple them — and the
/// mitigation is that every sub-run publishes its own `AgentRunCompleted` on
/// the shared event bus, so a cost meter listening there sees the true total
/// even though no single agent does.
library;

import 'package:agentic_agents/src/agent/agent.dart';
import 'package:agentic_agents/src/agent/agent_budget.dart';
import 'package:agentic_agents/src/agent/agent_result.dart';
import 'package:agentic_agents/src/events/agent_events.dart';
import 'package:agentic_agents/src/loop/tool_calling_agent.dart';
import 'package:agentic_core/agentic_core.dart';
import 'package:agentic_llm/agentic_llm.dart';
import 'package:agentic_tools/agentic_tools.dart';

/// Key under which delegation depth is carried in the run context.
const String kDelegationDepthKey = 'agent.delegationDepth';

/// Presents an [Agent] as a [Tool], so another agent can delegate to it.
///
/// ```dart
/// final supervisor = ToolCallingAgent(
///   info: AgentInfo(
///     name: 'supervisor',
///     description: 'Coordinates specialists.',
///   ),
///   model: model,
///   tools: (ToolRegistry()
///         ..register(AgentTool(researcher))
///         ..register(AgentTool(writer)))
///       .all,
///   instructions:
///       'Delegate research to `researcher` and drafting to `writer`. '
///       'Do not do their work yourself.',
/// );
/// ```
final class AgentTool implements Tool {
  /// Wraps [agent] as a tool.
  ///
  /// The tool's name and description come from [Agent.info], which is why
  /// [AgentInfo.name] is constrained to the same character set as a tool name.
  /// Write [AgentInfo.description] for the *supervising model*: it is the only
  /// basis on which work gets routed here rather than somewhere else.
  AgentTool(
    this.agent, {
    this.maxDepth = 3,
    ToolSpec? spec,
    Duration? timeout,
    AgentBudget? budget,
  }) : _budget = budget,
       spec =
           spec ??
           ToolSpec(
             name: agent.info.name,
             description: agent.info.description,
             parameters: JsonSchema.object(
               properties: <String, JsonSchema>{
                 'task': JsonSchema.string(
                   description:
                       'The task to delegate, written as a complete, '
                       'self-contained instruction. The delegate cannot see '
                       'this conversation.',
                   minLength: 1,
                 ),
                 'context': JsonSchema.string(
                   description:
                       'Any background the delegate needs but could not know, '
                       'such as decisions already made or constraints agreed '
                       'with the user.',
                 ),
               },
               required: const <String>{'task'},
             ),
             // Delegation is never read-only: a sub-agent may call any tool it
             // has, including ones that write. Marking it read-only would let
             // the executor run several in parallel, which is exactly the case
             // that needs care.
             isReadOnly: false,
             isIdempotent: false,
             tags: <String>{'delegation', ...agent.info.tags},
             timeout: timeout,
             version: agent.info.version,
           );

  /// The agent work is handed to.
  final Agent agent;

  /// Maximum depth of a delegation chain.
  ///
  /// Depth 1 is a supervisor calling a specialist. Beyond three, a plan is
  /// almost always a better structure than a deeper chain.
  final int maxDepth;

  @override
  final ToolSpec spec;

  final AgentBudget? _budget;

  @override
  Future<ToolResult> call(ToolInvocation invocation) async {
    final context = invocation.context;
    final depth = _depthOf(context);

    if (depth >= maxDepth) {
      // Returned rather than thrown, so the supervising model is told and can
      // do the work itself instead of the run collapsing.
      return ToolResult.failure(
        'Delegation is already $depth levels deep, which is the limit. '
        'Complete this task yourself rather than delegating again.',
        metadata: <String, Object?>{'delegationDepth': depth},
      );
    }

    final task = invocation.require<String>('task');
    final background = invocation.optional<String>('context', '');

    final scope = context.withMetadata(<String, Object?>{
      kDelegationDepthKey: depth + 1,
    });

    scope.publish(
      AgentDelegated(
        id: scope.ids.prefixed('evt'),
        timestamp: scope.clock.now(),
        agentName: invocation.toolName,
        delegateName: agent.info.name,
        depth: depth + 1,
        runId: scope.runId,
        source: 'agent:${agent.info.name}',
      ),
    );

    final result = await agent.run(
      AgentInput.text(
        background.isEmpty ? task : '$task\n\nBackground:\n$background',
        metadata: <String, Object?>{kDelegationDepthKey: depth + 1},
        budget: _budget,
      ),
      // No session: a delegate gets a clean conversation. Sharing the parent's
      // transcript would leak the supervisor's reasoning into the delegate's
      // context and multiply everyone's token cost.
      context: scope,
    );

    if (!result.isSuccess) {
      return ToolResult.failure(
        '`${agent.info.name}` did not finish: '
        '${result.error?.message ?? result.stopReason.name}. '
        '${result.text.isEmpty ? '' : 'Partial answer: ${result.text}'}',
        metadata: _resultMetadata(result, depth + 1),
      );
    }

    return ToolResult.success(
      result.text,
      data: result,
      metadata: _resultMetadata(result, depth + 1),
    );
  }

  /// Reports what the sub-run consumed, so a parent can see it.
  ///
  /// Metadata is never shown to the model — it is for the application's own
  /// accounting.
  Map<String, Object?> _resultMetadata(AgentResult result, int depth) =>
      pruneNulls(<String, Object?>{
        'delegate': agent.info.name,
        'delegationDepth': depth,
        'iterations': result.iterations,
        'tokens': result.usage.totalTokens,
        'cost': result.cost,
        'stopReason': result.stopReason.name,
      });

  static int _depthOf(AgenticContext context) {
    final value = context.metadata[kDelegationDepthKey];
    return value is int ? value : 0;
  }

  @override
  String toString() => 'AgentTool(${agent.info.name}, maxDepth: $maxDepth)';
}

/// Builds a supervisor over a team of agents.
///
/// A convenience, not a new abstraction: it wraps each member in an
/// [AgentTool], puts them in a registry, and returns an ordinary
/// [ToolCallingAgent]. Everything the returned agent does — streaming, budgets,
/// events, cancellation — is what any agent does.
///
/// ```dart
/// final crew = supervisorOver(
///   model: model,
///   members: [researcher, writer, reviewer],
///   instructions:
///       'Research first, then draft, then review. Do not skip the review.',
/// );
/// ```
Agent supervisorOver({
  required ChatModel model,
  required List<Agent> members,
  String name = 'supervisor',
  String description = 'Coordinates a team of specialist agents.',
  String? instructions,
  AgentBudget budget = AgentBudget.standard,
  int maxDepth = 3,
  ToolSet? extraTools,
}) {
  if (members.isEmpty) {
    throw ConfigurationException(
      'A supervisor needs at least one team member.',
      setting: 'supervisorOver.members',
    );
  }

  final registry = ToolRegistry();
  for (final member in members) {
    registry.register(AgentTool(member, maxDepth: maxDepth));
  }

  final roster = members
      .map((m) => '- `${m.info.name}`: ${m.info.description}')
      .join('\n');

  return ToolCallingAgent(
    info: AgentInfo(
      name: name,
      description: description,
      tags: const <String>{'supervisor'},
    ),
    model: model,
    tools: registry.all,
    budget: budget,
    instructions:
        '${instructions ?? 'Coordinate the team to answer the request.'}\n\n'
        'Your team:\n$roster\n\n'
        'Delegate to a specialist rather than doing their work yourself. '
        'Give each delegate a complete, self-contained instruction: they '
        'cannot see this conversation.',
  );
}
