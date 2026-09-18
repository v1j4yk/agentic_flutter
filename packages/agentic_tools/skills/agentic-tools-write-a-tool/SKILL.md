---
name: agentic-tools-write-a-tool
description: >-
  Use when writing, registering or debugging a tool an AI agent can call in a
  Dart or Flutter project that depends on agentic_tools (including through
  agentic_flutter or agentic_agents). Covers FunctionTool, ToolSpec, JsonSchema
  parameters, reading arguments, returning results and failures, ToolRegistry,
  ToolSet selection, and the isReadOnly / requiresApproval /
  returnsUntrustedContent flags that decide whether a person is asked first.
  Use agentic-tools-generator-annotate-functions instead when the project
  generates tools from annotated Dart functions with build_runner.
license: MIT
metadata:
  package: agentic_tools
  min-version: 0.2.0
---

# Write a tool an agent can call

## The shape

A tool is a name, a description, a JSON Schema for its parameters, and a handler
returning a `ToolResult`. `FunctionTool` covers almost every case.

```dart
import 'package:agentic_tools/agentic_tools.dart';

final searchDocs = FunctionTool(
  name: 'search_documents',
  description:
      "Searches the user's own saved documents and returns matching passages. "
      'Use for questions about their notes, contracts or handbook. '
      'Do not use for public web facts — use `search_web`.',
  tags: {'research'},
  parameters: JsonSchema.object(
    properties: {
      'query': JsonSchema.string(description: "The query, in the user's words"),
      'limit': JsonSchema.integer(minimum: 1, maximum: 20, defaultValue: 5),
    },
    required: {'query'},
  ),
  // Reading is safe; the result is text the application did not write.
  isReadOnly: true,
  returnsUntrustedContent: true,
  handler: (invocation) async {
    final hits = await repository.search(
      invocation.require<String>('query'),
      limit: invocation.optional<int>('limit', 5),
      cancellation: invocation.cancellation,
    );
    if (hits.isEmpty) {
      return ToolResult.failure(
        'No documents matched. Try fewer words, or `list_documents` to see '
        'what is indexed.',
      );
    }
    return ToolResult.success(hits.map((h) => h.text).join('\n\n'));
  },
);
```

`FunctionTool.text(...)` is the same thing when the handler returns a plain
`String`; `ToolResult.json({...})` returns structured data.

## Rules that matter

1. **The description is a prompt.** Say what the tool does, when to use it, and
   when *not* to — the last clause is what stops the model picking the wrong
   tool. Describe every parameter too.
2. **Names** are 1–64 characters of letters, digits, underscores or hyphens (the
   intersection of what OpenAI, Anthropic and Google accept). `search web!`
   throws `ConfigurationException` at construction.
3. **`isReadOnly` defaults to `true`.** Set `isReadOnly: false` on anything that
   changes state — sending, writing, deleting, paying. This flag drives the
   untrusted-content rule below, so getting it wrong removes a safety net.
4. **`requiresApproval: true`** asks a person before each call. Use it for
   anything destructive, irreversible or costly. With no approval handler
   configured the call is denied, and the model is told nobody could be asked.
5. **`returnsUntrustedContent: true`** for anything whose text came from outside
   the application: retrieval, memory recall, MCP servers, web fetches. After
   one of these returns, a tool that is not read-only needs approval — that is
   the framework's defence against prompt injection arriving through data.
6. **Expected failures are values, not exceptions.** Return
   `ToolResult.failure('...')` with a message that tells the model what to do
   next. Only a caller's cancellation should escape the handler.
7. **Long work must honour cancellation**: pass `invocation.cancellation` down,
   or check `invocation.cancellation.isCancelled` between steps.

## Reading arguments

```dart
invocation.require<String>('query');       // throws ValidationException if absent
invocation.optional<int>('limit', 5);      // default when absent
invocation.context;                        // AgenticContext: logger, events, clock
invocation.callId;                         // correlates with the model's call
```

Arguments are validated and repaired against the schema before the handler runs,
so a handler does not re-check types.

## Registering and selecting

```dart
final registry = ToolRegistry()
  ..register(searchDocs)
  ..register(sendEmail)
  ..registerLazy(cameraSpec, () => CameraTool(controller));  // built on first use

final research = registry.select(tags: {'research'});
final safe     = registry.select(readOnly: true);
final combined = research + registry.select(names: {'send_email'});

final agent = ToolCallingAgent(/* … */, tools: research);
```

Give an agent the smallest `ToolSet` that can do its job: fewer tools means
better tool choice and fewer tokens per turn.

## Executing tools yourself

Agents do this for you. Direct use looks like:

```dart
final executor = ToolExecutor(
  tools: registry.all,
  approvalHandler: (request) => showConfirmDialog(request),  // else denied
  maxConcurrency: 4,
  defaultTimeout: const Duration(seconds: 30),
);
final messages = await executor.executeAllAsMessages(
  response.toolCalls,
  context: context,
);
```

## Common mistakes

- Leaving `isReadOnly` at its default on a tool that writes — silently opts out
  of untrusted-content approval.
- Throwing on an expected failure (file missing, no results). Return
  `ToolResult.failure` so the model can recover in the same run.
- A description that says what the function is called rather than when to use it.
- Registering 60 tools and passing `registry.all` to every agent.
- Building an expensive dependency eagerly instead of `registerLazy`.

## See also

- `agentic-tools-approval-and-untrusted-content` — the approval and injection rules in full
- `agentic-tools-generator-annotate-functions` — generate all of this from a Dart function
- `agentic-agents-build-tool-calling-agent` — giving the tools to an agent
