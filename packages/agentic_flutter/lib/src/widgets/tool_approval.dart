/// Asking a person before a tool runs.
///
/// # What the executor already guarantees
///
/// `agentic_tools` fails closed: a tool whose spec sets `requiresApproval` and
/// has no handler configured is **denied**, not run. So the failure mode this
/// file guards against is not "approval was skipped" — it is "approval was
/// configured, and the sheet was written in a way that says yes by accident".
///
/// Hence the deliberate choices below: dismissing the sheet denies, the
/// destructive action is not the default focus, and the arguments the model
/// actually proposed are shown rather than a summary of them.
library;

import 'dart:async';
import 'dart:convert';

import 'package:agentic_tools/agentic_tools.dart';
import 'package:flutter/material.dart';

/// Builds a [ToolApprovalHandler] backed by a modal sheet.
///
/// ```dart
/// final executor = ToolExecutor(
///   tools: registry.all,
///   approvalHandler: sheetApprovalHandler(navigatorKey: navigatorKey),
/// );
/// ```
///
/// [navigatorKey] rather than a `BuildContext`: approval is requested from deep
/// inside an agent loop, long after whatever context started it may have been
/// unmounted. A key that points at the navigator is the thing that is still
/// valid at that moment.
ToolApprovalHandler sheetApprovalHandler({
  required GlobalKey<NavigatorState> navigatorKey,
  bool showArguments = true,
}) => (request) async {
  final navigator = navigatorKey.currentState;
  if (navigator == null) {
    // No navigator means no way to ask, and an unanswerable request must deny.
    // Returning true here would silently run a gated tool whenever the app
    // happened to be between routes.
    return false;
  }
  return showToolApprovalSheet(
    navigator.context,
    request: request,
    showArguments: showArguments,
  );
};

/// Shows the approval sheet and returns the user's decision.
///
/// Returns `false` when the sheet is dismissed by a back gesture or a tap
/// outside — refusing is the only safe reading of "the user did not answer".
Future<bool> showToolApprovalSheet(
  BuildContext context, {
  required ToolApprovalRequest request,
  bool showArguments = true,
}) async {
  final approved = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    builder: (sheetContext) => ToolApprovalSheet(
      request: request,
      showArguments: showArguments,
      onDecision: ({required approved}) =>
          Navigator.of(sheetContext).pop(approved),
    ),
  );
  return approved ?? false;
}

/// The contents of the approval sheet.
///
/// Exposed as a widget so an application can present it its own way — a dialog,
/// an inline card, a full page — without reimplementing the parts that matter.
class ToolApprovalSheet extends StatelessWidget {
  /// Creates the sheet.
  const ToolApprovalSheet({
    required this.request,
    required this.onDecision,
    this.showArguments = true,
    super.key,
  });

  /// What is being asked for.
  final ToolApprovalRequest request;

  /// Whether the proposed arguments are shown.
  ///
  /// On by default. "Allow `send_email`?" is not a question anyone can answer;
  /// "allow `send_email` to `board@example.com`?" is.
  final bool showArguments;

  /// Called with the decision.
  final void Function({required bool approved}) onDecision;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final spec = request.spec;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Row(
              children: <Widget>[
                Icon(
                  spec.isReadOnly
                      ? Icons.visibility_outlined
                      : Icons.warning_amber_outlined,
                  color: spec.isReadOnly
                      ? theme.colorScheme.primary
                      : theme.colorScheme.error,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Allow “${spec.name}”?',
                    style: theme.textTheme.titleMedium,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(spec.description, style: theme.textTheme.bodyMedium),
            if (!spec.isReadOnly) ...<Widget>[
              const SizedBox(height: 8),
              Text(
                'This tool can change things. It is not read-only.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ],
            if (showArguments && request.arguments.isNotEmpty) ...<Widget>[
              const SizedBox(height: 16),
              Text('Arguments', style: theme.textTheme.labelLarge),
              const SizedBox(height: 4),
              // Constrained and scrollable: an argument can be a whole
              // document, and a sheet that grows past the screen has no
              // buttons on it.
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 220),
                child: SingleChildScrollView(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Text(
                        formatArguments(request.arguments),
                        style: theme.textTheme.bodySmall?.copyWith(
                          fontFamily: 'monospace',
                          fontFamilyFallback: const <String>[
                            'Menlo',
                            'Consolas',
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
            const SizedBox(height: 24),
            Row(
              children: <Widget>[
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => onDecision(approved: false),
                    child: const Text('Deny'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton(
                    // Deliberately not autofocused. A destructive action that
                    // is one stray Enter away from running is a gate in name
                    // only.
                    onPressed: () => onDecision(approved: true),
                    child: const Text('Allow'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// Renders [arguments] as indented JSON.
  ///
  /// Falls back to `toString` for anything that will not encode — a tool may be
  /// handed values this widget has never heard of, and an approval sheet that
  /// throws is an approval sheet that denies everything.
  static String formatArguments(Map<String, Object?> arguments) {
    try {
      return const JsonEncoder.withIndent('  ').convert(arguments);
    } on JsonUnsupportedObjectError {
      return arguments.toString();
    }
  }
}

/// Records approval decisions instead of asking, for tests and previews.
///
/// ```dart
/// final approvals = ScriptedApprovals(approveAll: true);
/// final executor = ToolExecutor(tools: tools, approvalHandler: approvals.handle);
/// ```
final class ScriptedApprovals {
  /// Creates a scripted handler.
  ///
  /// [approveAll] is off by default so a test that forgets to script a decision
  /// sees the same fail-closed behaviour production has, rather than passing
  /// for the wrong reason.
  ScriptedApprovals({this.approveAll = false, Set<String> approve = const {}})
    : _approve = Set<String>.of(approve);

  final Set<String> _approve;

  /// Whether every request is approved.
  final bool approveAll;

  /// Every request that was made, in order.
  final List<ToolApprovalRequest> requests = <ToolApprovalRequest>[];

  /// The handler to hand to a `ToolExecutor`.
  Future<bool> handle(ToolApprovalRequest request) async {
    requests.add(request);
    return approveAll || _approve.contains(request.spec.name);
  }

  /// The names that were asked about.
  List<String> get askedAbout => <String>[
    for (final request in requests) request.spec.name,
  ];

  @override
  String toString() => 'ScriptedApprovals(${requests.length} asked)';
}
