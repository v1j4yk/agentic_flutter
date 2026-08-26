/// Running the tools a model asked for.
///
/// [ToolExecutor] sits between the model's request and the tool's code and owns
/// everything neither of them should:
///
/// * resolving the name against the set this agent was given;
/// * repairing and validating arguments against the schema;
/// * asking a human when the tool requires approval;
/// * enforcing a time budget and honouring cancellation;
/// * tracing, logging and publishing lifecycle events;
/// * turning every outcome into a message the model can read.
///
/// # Failure is a value here
///
/// Almost nothing thrown inside a tool escapes this class. A failure comes back
/// as a `ToolResult` with `isError`, which becomes a tool message the model
/// reads and can act on — retry with a different path, ask the user, explain
/// the problem. Throwing instead ends the run and leaves the user with a
/// spinner and no answer.
///
/// The single exception is a cancellation that came from the *caller* — the
/// user pressed stop, the screen closed — which propagates untouched, because
/// once nobody is listening there is nobody to recover. A tool that stops
/// because its own time budget expired is a different thing entirely, and comes
/// back as a timeout failure the agent can work around.
library;

import 'dart:async';

import 'package:agentic_core/agentic_core.dart';
import 'package:agentic_tools/src/tool.dart';
import 'package:agentic_tools/src/tool_events.dart';
import 'package:agentic_tools/src/tool_registry.dart';

/// Asks a human whether a tool may run.
///
/// Return `true` to allow. Implementations may take as long as they need — the
/// executor is already inside the run's cancellation scope, so a user who
/// abandons the screen while a dialog is open cancels cleanly.
typedef ToolApprovalHandler =
    Future<bool> Function(ToolApprovalRequest request);

/// A pending human-in-the-loop decision.
final class ToolApprovalRequest {
  /// Creates a request.
  ToolApprovalRequest({
    required this.spec,
    required this.callId,
    required Map<String, Object?> arguments,
    required this.context,
  }) : arguments = Map<String, Object?>.unmodifiable(arguments);

  /// The tool awaiting approval.
  final ToolSpec spec;

  /// Identifier of the model's request.
  final String callId;

  /// The validated arguments the user is being asked to approve.
  ///
  /// Already coerced and validated, so a confirmation dialog can render real
  /// values rather than whatever the model happened to emit.
  final Map<String, Object?> arguments;

  /// The run this invocation belongs to.
  final AgenticContext context;

  @override
  String toString() => 'ToolApprovalRequest(${spec.name}#$callId)';
}

/// Executes tool calls on behalf of an agent.
///
/// ```dart
/// final executor = ToolExecutor(
///   tools: registry.select(tags: {'research'}),
///   approvalHandler: (request) => showConfirmDialog(request),
/// );
///
/// final messages = await executor.executeAll(
///   response.message.toolCalls,
///   context: context,
/// );
/// ```
final class ToolExecutor {
  /// Creates an executor over [tools].
  ///
  /// [defaultTimeout] applies to any tool whose spec does not set its own.
  /// Every tool gets a budget: an agent loop blocked forever on a tool that
  /// forgot to set a socket timeout is indistinguishable from a hung app.
  ToolExecutor({
    required this.tools,
    this.defaultTimeout = const Duration(seconds: 30),
    this.coerceArguments = true,
    this.approvalHandler,
    this.maxConcurrency = 4,
    this.serialiseMutatingCalls = true,
  }) : assert(maxConcurrency >= 1, 'maxConcurrency must be at least 1');

  /// The tools this executor may run.
  final ToolSet tools;

  /// Time budget applied when a spec does not set [ToolSpec.timeout].
  final Duration defaultTimeout;

  /// Whether to repair near-miss arguments before validating.
  ///
  /// On by default. Models emit `"5"` for an integer often enough that
  /// rejecting it costs a wasted round trip for a mistake the framework can fix
  /// without guessing. See `JsonSchema.coerce` for exactly what is repaired and
  /// what is deliberately left alone.
  final bool coerceArguments;

  /// Consulted before running any tool whose spec requires approval.
  ///
  /// When a tool requires approval and no handler is configured, the call is
  /// *denied*. Failing closed is the only safe default: the alternative is a
  /// tool marked as needing consent running without any.
  final ToolApprovalHandler? approvalHandler;

  /// Maximum number of tool calls run concurrently in [executeAll].
  final int maxConcurrency;

  /// Whether calls to tools that mutate state run one at a time.
  ///
  /// On by default. A model happily requests four parallel calls without
  /// knowing that two of them write to the same file. Read-only tools still run
  /// concurrently, which is where nearly all the latency saving is anyway.
  final bool serialiseMutatingCalls;

  /// Runs one tool call and returns its outcome.
  ///
  /// Never throws for a tool-level failure; see the library documentation.
  /// Propagates [CancelledException] only.
  Future<ToolResult> execute(
    ToolCallPart call, {
    required AgenticContext context,
  }) async {
    context.throwIfCancelled();

    final spec = _specFor(call.name);
    if (spec == null) {
      return _fail(
        call,
        context,
        ToolFailureKind.unknownTool,
        _unknownToolMessage(call.name),
        started: context.clock.now(),
      );
    }

    return context.step('tool.${spec.name}', (scope, span) async {
      span.setAttributes(<String, Object?>{
        'tool.name': spec.name,
        'tool.version': spec.version,
        'tool.call_id': call.id,
        'tool.read_only': spec.isReadOnly,
      });
      return _runValidated(call, spec, scope, span, context.cancellation);
    }, timeout: spec.timeout ?? defaultTimeout);
  }

  /// Runs several tool calls and returns their outcomes in request order.
  ///
  /// Read-only calls run concurrently, bounded by [maxConcurrency]. Mutating
  /// calls run sequentially when [serialiseMutatingCalls] is set. Results are
  /// always returned in the order the model asked for them, whatever order they
  /// finished in.
  Future<List<ToolResult>> executeAll(
    List<ToolCallPart> calls, {
    required AgenticContext context,
  }) async {
    if (calls.isEmpty) return const <ToolResult>[];
    if (calls.length == 1) {
      return <ToolResult>[await execute(calls.single, context: context)];
    }

    final results = List<ToolResult?>.filled(calls.length, null);
    final concurrent = <int>[];
    final sequential = <int>[];

    for (var i = 0; i < calls.length; i++) {
      final spec = _specFor(calls[i].name);
      final mutates = spec != null && !spec.isReadOnly;
      if (serialiseMutatingCalls && mutates) {
        sequential.add(i);
      } else {
        concurrent.add(i);
      }
    }

    await _runBounded(concurrent, (index) async {
      results[index] = await execute(calls[index], context: context);
    });

    for (final index in sequential) {
      results[index] = await execute(calls[index], context: context);
    }

    return List<ToolResult>.unmodifiable(results.cast<ToolResult>());
  }

  /// Runs several tool calls and returns the messages to append to history.
  ///
  /// The form an agent loop wants: the result of this can be concatenated onto
  /// the conversation and sent straight back to the model.
  Future<List<Message>> executeAllAsMessages(
    List<ToolCallPart> calls, {
    required AgenticContext context,
  }) async {
    final results = await executeAll(calls, context: context);
    return <Message>[
      for (var i = 0; i < calls.length; i++)
        results[i].toMessage(callId: calls[i].id, toolName: calls[i].name),
    ];
  }

  // ---------------------------------------------------------------------------
  // Internals
  // ---------------------------------------------------------------------------

  Future<ToolResult> _runValidated(
    ToolCallPart call,
    ToolSpec spec,
    AgenticContext context,
    Span span,
    CancellationToken callerCancellation,
  ) async {
    final started = context.clock.now();

    final prepared = _prepareArguments(spec, call.arguments);
    if (prepared.violations.isNotEmpty) {
      span.setAttribute('tool.invalid_arguments', prepared.violations.length);
      return _fail(
        call,
        context,
        ToolFailureKind.invalidArguments,
        _invalidArgumentsMessage(spec, prepared.violations),
        started: started,
      );
    }

    if (spec.requiresApproval) {
      final approved = await _requestApproval(
        spec,
        call,
        prepared.arguments,
        context,
      );
      if (!approved) {
        span.setAttribute('tool.approval', 'denied');
        return _fail(
          call,
          context,
          ToolFailureKind.approvalDenied,
          'The user declined to run `${spec.name}`. Do not retry it; continue '
          'without it or ask the user what they would prefer.',
          started: started,
        );
      }
      span.setAttribute('tool.approval', 'granted');
    }

    context
      ..publish(
        ToolCallStarted(
          id: context.ids.prefixed('evt'),
          timestamp: started,
          toolName: spec.name,
          callId: call.id,
          arguments: prepared.arguments,
          runId: context.runId,
          source: 'tool:${spec.name}',
          traceId: span.context.traceId,
          spanId: span.context.spanId,
        ),
      )
      ..logger.debug(
        'Tool invoked',
        fields: <String, Object?>{'tool': spec.name, 'callId': call.id},
      );

    final invocation = ToolInvocation(
      callId: call.id,
      toolName: spec.name,
      arguments: prepared.arguments,
      rawArguments: call.rawArguments,
      context: context,
    );

    try {
      final tool = tools.resolve(spec.name);
      // Two mechanisms, because one is not enough. The child context's deadline
      // cancels the token, which lets a well-behaved tool stop and release its
      // resources. But cancellation in Dart is cooperative: a tool that never
      // checks the token would block the agent loop for ever. So the executor
      // also stops *waiting* when the budget expires. The abandoned work may
      // keep running — nothing can prevent that — but the run continues.
      final result = await context.clock.timeout(
        () async => tool.call(invocation),
        limit: spec.timeout ?? defaultTimeout,
        name: 'tool.${spec.name}',
      );
      // A tool that returns its own failure is still a failure, and consumers
      // filtering on `failureKind` must see it. Without this, a UI counting
      // failures by category silently misses every failure a tool reported
      // itself — which is the most common kind there is.
      _publishCompletion(
        call,
        spec,
        context,
        span,
        result,
        started,
        result.isError ? ToolFailureKind.executionFailed : null,
      );
      return result;
    } on CancelledException catch (error) {
      // Two very different things arrive here, and conflating them would make
      // the executor's behaviour depend on whether a tool happens to check its
      // token.
      //
      // If the *caller's* token fired, the run is over: there is nobody left to
      // hand a failure to, so it propagates.
      //
      // If only this invocation's own deadline fired, the tool was well behaved
      // enough to notice and stop — which should not be punished by ending the
      // whole run. It becomes the same timeout failure a tool that ignored its
      // token would have produced.
      if (callerCancellation.isCancelled) rethrow;
      return _fail(
        call,
        context,
        ToolFailureKind.timeout,
        _timedOutMessage(spec),
        started: started,
        span: span,
        spec: spec,
        cause: error,
      );
    } on AgenticTimeoutException catch (error) {
      return _fail(
        call,
        context,
        ToolFailureKind.timeout,
        _timedOutMessage(spec),
        started: started,
        span: span,
        spec: spec,
        cause: error,
      );
    } on AgenticException catch (error, stackTrace) {
      span.recordError(error, stackTrace);
      return _fail(
        call,
        context,
        ToolFailureKind.executionFailed,
        '`${spec.name}` failed: ${error.message}',
        started: started,
        span: span,
        spec: spec,
        cause: error,
      );
    } on Object catch (error, stackTrace) {
      // A tool that throws something unclassified is a bug in the tool, but the
      // agent run should degrade rather than crash the host application.
      span.recordError(error, stackTrace);
      context.logger.error(
        'Tool threw an unclassified error',
        fields: <String, Object?>{'tool': spec.name},
        error: error,
        stackTrace: stackTrace,
      );
      return _fail(
        call,
        context,
        ToolFailureKind.unexpectedError,
        '`${spec.name}` failed unexpectedly: $error',
        started: started,
        span: span,
        spec: spec,
        cause: error,
      );
    }
  }

  ({Map<String, Object?> arguments, List<String> violations}) _prepareArguments(
    ToolSpec spec,
    Map<String, Object?> raw,
  ) {
    final candidate = coerceArguments
        ? spec.parameters.coerce(Map<String, Object?>.of(raw))
        : raw;

    final result = spec.parameters.validate(candidate);
    if (!result.isValid) {
      return (
        arguments: raw,
        violations: result.violations.map((v) => v.toString()).toList(),
      );
    }
    return (
      arguments: candidate is Map<String, Object?>
          ? candidate
          : Map<String, Object?>.of(raw),
      violations: const <String>[],
    );
  }

  Future<bool> _requestApproval(
    ToolSpec spec,
    ToolCallPart call,
    Map<String, Object?> arguments,
    AgenticContext context,
  ) async {
    context.publish(
      ToolApprovalRequested(
        id: context.ids.prefixed('evt'),
        timestamp: context.clock.now(),
        toolName: spec.name,
        callId: call.id,
        arguments: arguments,
        runId: context.runId,
        source: 'tool:${spec.name}',
      ),
    );

    final handler = approvalHandler;
    if (handler == null) {
      context.logger.warn(
        'Tool requires approval but no approval handler is configured; '
        'denying.',
        fields: <String, Object?>{'tool': spec.name},
      );
      return false;
    }

    // Recorded as human waiting, not as work. Whoever is enforcing a wall-clock
    // budget subtracts this: a person reading a destructive tool's arguments
    // carefully is the system behaving correctly, and killing the run for it
    // would punish exactly the caution the prompt exists to invite.
    return context.humanWait.during(
      () => handler(
        ToolApprovalRequest(
          spec: spec,
          callId: call.id,
          arguments: arguments,
          context: context,
        ),
      ),
      clock: context.clock,
    );
  }

  ToolResult _fail(
    ToolCallPart call,
    AgenticContext context,
    ToolFailureKind kind,
    String message, {
    required DateTime started,
    Span? span,
    ToolSpec? spec,
    Object? cause,
  }) {
    final result = ToolResult.failure(
      message,
      cause: cause,
      metadata: <String, Object?>{'failureKind': kind.name},
    );
    _publishCompletion(call, spec, context, span, result, started, kind);
    return result;
  }

  void _publishCompletion(
    ToolCallPart call,
    ToolSpec? spec,
    AgenticContext context,
    Span? span,
    ToolResult result,
    DateTime started,
    ToolFailureKind? kind,
  ) {
    final finished = context.clock.now();
    context.publish(
      ToolCallCompleted(
        id: context.ids.prefixed('evt'),
        timestamp: finished,
        toolName: spec?.name ?? call.name,
        callId: call.id,
        duration: finished.difference(started),
        isError: result.isError,
        summary: _summarise(result.content),
        failureKind: kind,
        runId: context.runId,
        source: 'tool:${spec?.name ?? call.name}',
        traceId: span?.context.traceId,
        spanId: span?.context.spanId,
      ),
    );
    span?.setAttributes(<String, Object?>{
      'tool.is_error': result.isError,
      if (kind != null) 'tool.failure_kind': kind.name,
    });
  }

  /// Looks up a spec without constructing the tool.
  ///
  /// Deliberately not `tools.resolve(name).spec`: that would build every
  /// lazily-registered tool during dispatch, which is exactly the cost lazy
  /// registration exists to avoid.
  ToolSpec? _specFor(String name) => tools.specOf(name);

  String _timedOutMessage(ToolSpec spec) {
    final budget = spec.timeout ?? defaultTimeout;
    return '`${spec.name}` did not finish within ${budget.inSeconds}s and was '
        'abandoned. Try again with narrower arguments, or continue without it.';
  }

  String _unknownToolMessage(String name) {
    final available = tools.names.map((n) => '`$n`').join(', ');
    return tools.isEmpty
        ? 'No tools are available. Answer without calling one.'
        : 'There is no tool named `$name`. Available tools: $available.';
  }

  String _invalidArgumentsMessage(ToolSpec spec, List<String> violations) {
    final buffer = StringBuffer(
      'The arguments for `${spec.name}` were not valid:',
    );
    for (final violation in violations) {
      buffer.write('\n- $violation');
    }
    buffer.write('\nCorrect them and call `${spec.name}` again.');
    return buffer.toString();
  }

  Future<void> _runBounded(
    List<int> indices,
    Future<void> Function(int index) run,
  ) async {
    if (indices.isEmpty) return;
    var next = 0;

    Future<void> worker() async {
      while (true) {
        if (next >= indices.length) return;
        final index = indices[next++];
        await run(index);
      }
    }

    final workerCount = indices.length < maxConcurrency
        ? indices.length
        : maxConcurrency;
    await Future.wait(
      List<Future<void>>.generate(workerCount, (_) => worker()),
    );
  }

  static String _summarise(String content) {
    final collapsed = content.replaceAll(RegExp(r'\s+'), ' ').trim();
    return collapsed.length <= 120
        ? collapsed
        : '${collapsed.substring(0, 117)}...';
  }

  @override
  String toString() => 'ToolExecutor(${tools.length} tools)';
}
