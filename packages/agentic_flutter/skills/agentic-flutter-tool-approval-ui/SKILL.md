---
name: agentic-flutter-tool-approval-ui
description: >-
  Use when a Flutter app must ask a person before an agent's tool runs, with
  agentic_flutter: sheetApprovalHandler, showToolApprovalSheet,
  ToolApprovalSheet, why approval needs a navigator key rather than a
  BuildContext, the untrusted-content warning, and ScriptedApprovals in tests.
  Read this for "confirm before the agent does something", "the approval dialog
  never appears", or a denied tool call.
license: MIT
metadata:
  package: agentic_flutter
  min-version: 0.2.0
---

# Asking the user to approve a tool call

## Wiring it

```dart
final navigatorKey = GlobalKey<NavigatorState>();

MaterialApp(navigatorKey: navigatorKey, home: const ChatScreen());

final agent = ToolCallingAgent(
  info: info,
  model: model,
  tools: registry.all,
  budget: AgentBudget.interactive,
  approvalHandler: sheetApprovalHandler(navigatorKey: navigatorKey),
);
```

That is the whole integration: a tool whose spec sets `requiresApproval: true`
now raises a sheet, and the agent waits for the answer.

## Why a navigator key, not a `BuildContext`

Approval is requested from **inside the agent loop**, potentially many seconds
after the run started, and by then the widget that started it may have been
disposed — the user scrolled, navigated, or the screen rebuilt. A
`BuildContext` captured at send time is a dangling reference; a navigator key is
still valid.

This is also why the handler is passed to the agent rather than read from a
provider at the call site.

## What the sheet shows

```dart
await showToolApprovalSheet(context, request: request, showArguments: true);
```

`ToolApprovalSheet` renders the tool's name, its description, the arguments the
model proposed, and — when the call follows untrusted content — a warning naming
the tools that brought it in.

**Keep `showArguments: true`.** "Allow `send_email`?" is a button; "Allow
`send_email` to `finance@acme.com` with subject *Invoice*?" is a decision.
Arguments that cannot be encoded render as text rather than throwing, so a
surprising value never breaks the sheet.

Dismissing the sheet **denies**. That is the safe default and the one users
expect: swiping away is not consent.

## When no handler is configured

The call is denied, and the model is told that nobody could be asked — not that
the user refused. The distinction matters: a model told "the user declined"
argues; a model told "no one was available" explains the limitation and moves
on.

So if approvals seem to be silently failing, check that the handler reached the
agent (or the `ToolExecutor`) at all.

## Designing approvals people actually read

- **Ask rarely.** Ten prompts a minute trains a user to tap Approve without
  looking, which is worse than not asking. Reserve it for the destructive, the
  irreversible and the expensive.
- **Make the tool narrow.** A `send_email` that can only reply to the current
  thread may not need approval at all; one that takes any address does.
- **Explain, in the tool's description.** The sheet shows it, and it is what a
  user reads to decide.
- **Watch the untrusted-content warning.** When it appears, the agent has read
  something the app did not write — a document, a memory, an MCP result — before
  proposing this action. That is exactly when a person should look closely.

## In tests

```dart
final approvals = ScriptedApprovals(approve: {'send_email'});
final agent = ToolCallingAgent(
  info: info, model: model, tools: registry.all,
  budget: AgentBudget.interactive,
  approvalHandler: approvals.handle,
);

await agent.run(AgentInput.text('email finance the invoice'));
expect(approvals.askedAbout, contains('send_email'));
```

`ScriptedApprovals` **fails closed by default**: anything not named is denied,
so a test never accidentally proves that an unapproved tool ran.

## Common mistakes

- No `navigatorKey` on the `MaterialApp`, so the handler has nothing to present
  from.
- Passing a captured `BuildContext` instead of the key.
- `showArguments: false` to make the sheet tidier, leaving users approving
  blind.
- Marking everything `requiresApproval: true`, then removing the handler
  because the prompts are annoying.
- Treating a denial as an error: it is a legitimate outcome, and the model
  handles it if the tool returns it as a value.

## See also

- `agentic-tools-approval-and-untrusted-content` — the rules behind the prompt
- `agentic-flutter-add-chat-agent` — wiring the agent that raises it
- `agentic-workflow-human-approval-and-resume` — approval that outlives the process
