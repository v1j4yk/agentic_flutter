/// Bounds on what a single agent run may consume.
///
/// # The failure this exists to prevent
///
/// The characteristic failure of an agentic system is not a crash. It is a loop
/// that runs correctly and forever: the model calls a tool, the tool returns
/// something ambiguous, the model calls it again with a slightly different
/// argument, and forty iterations later the user has closed the app and the
/// bill is still growing.
///
/// Nothing about that looks like an error. Every individual call succeeds. Only
/// the *aggregate* is wrong, which is why bounds have to be enforced by the
/// loop rather than discovered by a monitor.
///
/// So a budget is a required part of an agent's construction, not an optional
/// guard. [AgentBudget.standard] is what you get if you do not think about it,
/// and it is deliberately conservative.
///
/// # Four dimensions, because one is never enough
///
/// * **Iterations** bound the shape of the loop. Cheap to check, and the only
///   bound that stops a two-tool ping-pong that costs almost nothing per turn.
/// * **Tokens** bound the context. Necessary because iterations say nothing
///   about a run that accumulates a 200k-token transcript.
/// * **Cost** bounds the money, which is what a product owner actually cares
///   about and what iterations and tokens only approximate.
/// * **Wall clock** bounds the user's patience, which is unrelated to all three.
library;

import 'package:agentic_core/agentic_core.dart';
import 'package:meta/meta.dart';

/// Limits applied to one agent run.
@immutable
final class AgentBudget {
  /// Creates a budget.
  ///
  /// Every limit is optional except [maxIterations], which always applies:
  /// a loop with no iteration bound is not an agent, it is an outage.
  const AgentBudget({
    this.maxIterations = 10,
    this.maxTokens,
    this.maxCost,
    this.maxDuration,
    this.maxToolCalls,
  }) : assert(maxIterations >= 1, 'maxIterations must be at least 1');

  /// The default: enough to finish real work, cheap enough to be survivable.
  ///
  /// Ten iterations covers the overwhelming majority of genuine tool-using
  /// answers. A run that needs more is usually stuck, not thorough.
  static const AgentBudget standard = AgentBudget(
    maxTokens: 100000,
    maxDuration: Duration(minutes: 2),
    maxToolCalls: 30,
  );

  /// For an interactive assistant, where a user is watching a spinner.
  static const AgentBudget interactive = AgentBudget(
    maxIterations: 5,
    maxTokens: 30000,
    maxDuration: Duration(seconds: 30),
    maxToolCalls: 10,
  );

  /// For background or scheduled work that nobody is waiting on.
  static const AgentBudget background = AgentBudget(
    maxIterations: 30,
    maxTokens: 500000,
    maxDuration: Duration(minutes: 15),
    maxToolCalls: 100,
  );

  /// Maximum model calls in the loop.
  final int maxIterations;

  /// Maximum total tokens across every model call in the run.
  final int? maxTokens;

  /// Maximum estimated cost, in the currency of the model's pricing.
  ///
  /// Only enforceable when the model has prices configured; a local model
  /// reports no cost, and this bound is then inert by design.
  final double? maxCost;

  /// Maximum wall-clock duration.
  final Duration? maxDuration;

  /// Maximum individual tool invocations.
  ///
  /// Distinct from [maxIterations] because one iteration can request eight
  /// parallel calls.
  final int? maxToolCalls;

  /// Returns a copy with selected limits replaced.
  AgentBudget copyWith({
    int? maxIterations,
    int? maxTokens,
    double? maxCost,
    Duration? maxDuration,
    int? maxToolCalls,
  }) => AgentBudget(
    maxIterations: maxIterations ?? this.maxIterations,
    maxTokens: maxTokens ?? this.maxTokens,
    maxCost: maxCost ?? this.maxCost,
    maxDuration: maxDuration ?? this.maxDuration,
    maxToolCalls: maxToolCalls ?? this.maxToolCalls,
  );

  /// Serialises the budget.
  JsonMap toJson() => pruneNulls(<String, Object?>{
    'maxIterations': maxIterations,
    'maxTokens': maxTokens,
    'maxCost': maxCost,
    'maxDurationMs': maxDuration?.inMilliseconds,
    'maxToolCalls': maxToolCalls,
  });

  @override
  String toString() =>
      'AgentBudget(iterations: $maxIterations'
      '${maxTokens == null ? '' : ', tokens: $maxTokens'}'
      '${maxCost == null ? '' : ', cost: $maxCost'}'
      '${maxDuration == null ? '' : ', ${maxDuration!.inSeconds}s'})';
}

/// Which limit a run hit.
enum BudgetDimension {
  /// The iteration count was reached.
  iterations,

  /// The token allowance was consumed.
  tokens,

  /// The cost ceiling was reached.
  cost,

  /// The time allowance elapsed.
  duration,

  /// The tool-call allowance was consumed.
  toolCalls,
}

/// Tracks consumption against an [AgentBudget] during a run.
///
/// Mutable by nature — it is a running total — and owned by exactly one run.
/// The loop consults [exhausted] before each iteration rather than after, so a
/// budget is a bound on what is *started*, not a report on what was spent.
final class BudgetTracker {
  /// Creates a tracker for [budget], starting the clock now.
  ///
  /// [humanWait], when supplied, is subtracted from [elapsed]. Pass the ledger
  /// from the run's context so that time spent at an approval prompt does not
  /// count against a limit that exists to bound the agent's own work.
  BudgetTracker({
    required this.budget,
    Clock clock = const SystemClock(),
    HumanWaitLedger? humanWait,
  }) : _clock = clock,
       _humanWait = humanWait,
       _startedAt = clock.now();

  /// The limits being tracked.
  final AgentBudget budget;

  final Clock _clock;
  final DateTime _startedAt;
  final HumanWaitLedger? _humanWait;

  TokenUsage _usage = TokenUsage.empty;
  double _cost = 0;
  int _iterations = 0;
  int _toolCalls = 0;

  /// Model calls made so far.
  int get iterations => _iterations;

  /// Tool invocations made so far.
  int get toolCalls => _toolCalls;

  /// Tokens consumed so far.
  TokenUsage get usage => _usage;

  /// Estimated cost so far.
  double get cost => _cost;

  /// Time the agent has spent working.
  ///
  /// Wall-clock since the run started, less any time it spent blocked on a
  /// person — see [HumanWaitLedger] for why that subtraction is the whole
  /// point rather than a refinement.
  Duration get elapsed {
    final wall = _clock.now().difference(_startedAt);
    final waited = _humanWait?.total ?? Duration.zero;
    final worked = wall - waited;
    // A clamp rather than a bare subtraction: a ledger written by another
    // clock could in principle report more waiting than has elapsed, and a
    // negative duration here would read as an unlimited budget.
    return worked.isNegative ? Duration.zero : worked;
  }

  /// Wall-clock since the run started, including time spent waiting on a
  /// person.
  ///
  /// What a stopwatch would have shown. Reported alongside [elapsed] so a slow
  /// run can be told from a run that was simply waiting for an answer.
  Duration get wallClock => _clock.now().difference(_startedAt);

  /// How long this run spent blocked on a person.
  Duration get humanWait => _humanWait?.total ?? Duration.zero;

  /// Records one completed model call.
  void recordIteration({TokenUsage usage = TokenUsage.empty, double? cost}) {
    _iterations++;
    _usage = _usage + usage;
    _cost += cost ?? 0;
  }

  /// Records [count] tool invocations.
  void recordToolCalls(int count) => _toolCalls += count;

  /// Which limit is exhausted, or `null` when there is room to continue.
  ///
  /// Checked before starting work. Iterations are checked first because that
  /// bound is the one a stuck loop hits, and reporting it is more actionable
  /// than reporting the token total it happened to accumulate on the way.
  BudgetDimension? get exhausted {
    if (_iterations >= budget.maxIterations) return BudgetDimension.iterations;
    if (budget.maxToolCalls case final limit?) {
      if (_toolCalls >= limit) return BudgetDimension.toolCalls;
    }
    if (budget.maxTokens case final limit?) {
      if (_usage.totalTokens >= limit) return BudgetDimension.tokens;
    }
    if (budget.maxCost case final limit?) {
      if (_cost >= limit) return BudgetDimension.cost;
    }
    if (budget.maxDuration case final limit?) {
      if (elapsed >= limit) return BudgetDimension.duration;
    }
    return null;
  }

  /// Whether any limit has been reached.
  bool get isExhausted => exhausted != null;

  /// Iterations still available.
  int get remainingIterations =>
      (budget.maxIterations - _iterations).clamp(0, budget.maxIterations);

  /// Whether exactly one iteration remains.
  ///
  /// The loop uses this to make its final call a prose-only one, so a run that
  /// runs out of budget still answers the user instead of ending on an
  /// unanswered tool call.
  bool get isFinalIteration => remainingIterations <= 1;

  /// Describes what was consumed, for logs and results.
  JsonMap toJson() => pruneNulls(<String, Object?>{
    'iterations': _iterations,
    'toolCalls': _toolCalls,
    'tokens': _usage.totalTokens,
    'cost': _cost == 0 ? null : _cost,
    'elapsedMs': elapsed.inMilliseconds,
    'humanWaitMs': humanWait == Duration.zero ? null : humanWait.inMilliseconds,
  });

  /// A human-readable explanation of why [dimension] stopped the run.
  ///
  /// Written to be shown to a developer *and* summarised to a user: it says
  /// what was hit and what to change.
  String explain(BudgetDimension dimension) => switch (dimension) {
    BudgetDimension.iterations =>
      'Reached the limit of ${budget.maxIterations} model calls. The agent was '
          'still working; raise `maxIterations` or narrow the task.',
    BudgetDimension.toolCalls =>
      'Reached the limit of ${budget.maxToolCalls} tool calls.',
    BudgetDimension.tokens =>
      'Consumed the token allowance of ${budget.maxTokens} '
          '(${_usage.totalTokens} used).',
    BudgetDimension.cost =>
      'Reached the cost ceiling of ${budget.maxCost} '
          '(${_cost.toStringAsFixed(4)} spent).',
    BudgetDimension.duration =>
      'Ran for ${elapsed.inSeconds}s, past the limit of '
          '${budget.maxDuration!.inSeconds}s.',
  };

  @override
  String toString() =>
      'BudgetTracker($_iterations/${budget.maxIterations} iterations, '
      '${_usage.totalTokens} tokens, ${elapsed.inMilliseconds}ms)';
}
