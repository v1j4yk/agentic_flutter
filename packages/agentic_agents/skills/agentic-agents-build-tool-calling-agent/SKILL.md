---
name: agentic-agents-build-tool-calling-agent
description: >-
  Use when building or debugging an agent with agentic_agents in Dart or
  Flutter: ToolCallingAgent, AgentInfo, instructions, running and streaming a
  turn, reading AgentResult and its stop reason, approval handling, and typed
  output. Start here for "the agent does not call my tool", "it loops", or "how
  do I stream its answer".
license: MIT
metadata:
  package: agentic_agents
  min-version: 0.2.0
---

# Build a tool-calling agent

An agent is a bounded loop around a model and a set of tools: reason, call
tools, observe, repeat until the model stops asking or a budget runs out.

```dart
final agent = ToolCallingAgent(
  info: AgentInfo(
    name: 'researcher',
    description: 'Researches technical topics using web search.',
    tags: {'research'},
  ),
  model: model,
  tools: registry.select(tags: {'research'}),
  instructions: 'Cite your sources. Say plainly when you are not sure.',
  budget: AgentBudget.interactive,
  approvalHandler: (request) => confirmWithUser(request),
);

final result = await agent.run(AgentInput.text('What shipped in Dart 3.11?'));
print('${result.text} — ${result.iterations} steps, '
      '${result.usage.totalTokens} tokens, ${result.cost}');
```

`agent.ask('…')` is the one-line form when all you want is the text.

## Reading the result

```dart
result.text;             // the final answer
result.stopReason;       // completed | budgetExhausted | stopped | cancelled | failed
result.isSuccess;        // stopReason.isSuccess
result.ensureSuccess();  // throws the underlying AgenticException instead
result.steps;            // one AgentStep per iteration: response, tool calls, results
result.allToolCalls;     // flattened, for assertions
result.messages;         // the full turn, to append to your own history
result.usage;            // TokenUsage across every model call in the run
```

**Always look at `stopReason`.** `budgetExhausted` means the answer is
best-effort: the loop forbids tool calls on its last permitted iteration
precisely so you get an answer rather than a dangling tool call.

## Streaming

```dart
await for (final chunk in agent.stream(AgentInput.text(question))) {
  switch (chunk) {
    case AgentTextDelta(:final text):          buffer.write(text);
    case AgentReasoningDelta():                 break;      // thinking, usually hidden
    case AgentToolCallStarted(:final toolName): setStatus('Using $toolName…');
    case AgentToolCallFinished():               setStatus(null);
    case AgentStepFinished():                   break;
    case AgentFinished(:final result):          finish(result);
  }
}
```

`AgentChunk` is a sealed-style hierarchy, so a `switch` over it is exhaustive
and adding a chunk type is a compile error you want.

## Making the model choose the right tool

Tool choice is a prompt problem far more often than a framework problem:

1. **Give it fewer tools.** `registry.select(tags: {'research'})`, not
   `registry.all`. Tool choice degrades as the list grows.
2. **Say when *not* to use each tool** in its description — that clause does
   most of the work.
3. **Put the policy in `instructions`**, not in every tool: "Search before
   answering questions about current events."
4. Check the model can do it at all: `model.info.supports(ModelCapability.toolCalling)`.
   A local 7B model routinely claims it and emits malformed calls.

## Other parameters worth knowing

```dart
ToolCallingAgent(
  // …
  temperature: 0.2,
  maxOutputTokens: 800,
  responseFormat: ResponseFormat.jsonSchema(name: 'answer', schema: schema),
  stopWhen: (step) => step.toolCalls.any((c) => c.name == 'finish'),
  untrustedContentPolicy: UntrustedContentPolicy.requireApproval,
  ownsModel: true,   // dispose the model when the agent is disposed
);
```

Without an `approvalHandler`, a tool needing approval is denied and the model is
told nobody could be asked — not that the user refused.

## Composing behaviour

`DelegatingAgent` wraps an agent the way `DelegatingChatModel` wraps a model, so
logging, rate limiting or a house style are one class rather than a fork:

```dart
final class LoggingAgent extends DelegatingAgent {
  const LoggingAgent(super.inner);

  @override
  Future<AgentResult> run(AgentInput input, {AgentSession? session, AgenticContext? context}) async {
    final result = await super.run(input, session: session, context: context);
    context?.logger.info('agent finished', fields: {'stop': result.stopReason.name});
    return result;
  }
}
```

## Common mistakes

- No `session`, then wondering why the agent has no memory of the last turn —
  each `run` without one is a fresh conversation.
- Ignoring `stopReason` and showing a truncated best-effort answer as final.
- Passing every tool in the registry to every agent.
- Creating the agent inside a widget `build`, so it is rebuilt each frame.
- Catching `CancelledException` inside a tool, which turns a user's cancel into
  a tool failure the model tries to work around.

## See also

- `agentic-agents-budgets` — the bounds that stop a loop spending money
- `agentic-agents-sessions-and-history` — multi-turn conversations
- `agentic-agents-multi-agent-delegation` — handing work to another agent
- `agentic-tools-write-a-tool` — the tools it calls
