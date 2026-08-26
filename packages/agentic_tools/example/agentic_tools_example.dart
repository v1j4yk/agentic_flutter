// Demonstrates the tool layer end to end: declaring capabilities, handing an
// agent a slice of the catalogue, and running what a model asked for — including
// the arguments it got slightly wrong, the tool that fails, and the one that
// needs a human to say yes.
//
// Run it with:
//
//     dart run example/agentic_tools_example.dart
//
// There is no model here. The `ToolCallPart`s below are exactly what a provider
// would have returned, hand-written so the example stays offline and
// deterministic.
import 'package:agentic_core/agentic_core.dart';
import 'package:agentic_tools/agentic_tools.dart';

Future<void> main() async {
  // ---------------------------------------------------------------------------
  // 1. Declare capabilities. Descriptions are written for the model: they are
  //    the entire basis on which it decides what to call and with what.
  // ---------------------------------------------------------------------------
  final registry = ToolRegistry()
    ..register(
      FunctionTool(
        name: 'search_web',
        description:
            'Searches the public web and returns the top results with titles '
            'and snippets. Use for current events and facts that may have '
            'changed recently.',
        tags: {'research'},
        parameters: JsonSchema.object(
          properties: {
            'query': JsonSchema.string(
              description: "The search query, in the user's own words",
              minLength: 1,
            ),
            'limit': JsonSchema.integer(
              description: 'How many results to return',
              minimum: 1,
              maximum: 10,
              defaultValue: 3,
            ),
          },
          required: {'query'},
        ),
        handler: (invocation) async {
          final query = invocation.require<String>('query');
          final limit = invocation.optional<int>('limit', 3);
          return ToolResult.success(
            List.generate(
              limit,
              (i) => '${i + 1}. Result for "$query"',
            ).join('\n'),
          );
        },
      ),
    )
    ..register(
      FunctionTool(
        name: 'read_file',
        description: 'Reads a UTF-8 text file and returns its contents.',
        tags: {'files'},
        parameters: JsonSchema.object(
          properties: {'path': JsonSchema.string(description: 'Absolute path')},
          required: {'path'},
        ),
        // An expected failure is *returned*, not thrown. The model reads this
        // and can recover — try another path, or ask the user.
        handler: (invocation) async => ToolResult.failure(
          'No such file: ${invocation.require<String>('path')}. '
          'Use `search_web` if you meant to look something up online.',
        ),
      ),
    )
    ..register(
      FunctionTool(
        name: 'send_email',
        description: 'Sends an email on the user\'s behalf.',
        tags: {'communication'},
        isReadOnly: false,
        isIdempotent: false,
        requiresApproval: true,
        parameters: JsonSchema.object(
          properties: {
            'to': JsonSchema.string(format: 'email'),
            'subject': JsonSchema.string(),
            'body': JsonSchema.string(),
          },
          required: {'to', 'subject', 'body'},
        ),
        handler: (invocation) async =>
            ToolResult.success('Sent to ${invocation.require<String>('to')}'),
      ),
    );

  // ---------------------------------------------------------------------------
  // 2. Hand each agent only what it needs. Forty tools measurably degrades a
  //    model's choices, and every unused spec costs tokens on every turn.
  // ---------------------------------------------------------------------------
  final available = registry.select(
    tags: {'research', 'files', 'communication'},
  );
  print('tools offered to the model:');
  for (final spec in available.specs) {
    print(
      '  ${spec.name.padRight(12)} ${spec.isReadOnly ? 'read ' : 'write'} '
      '${spec.requiresApproval ? '(needs approval)' : ''}',
    );
  }

  // This is what goes into the provider request.
  print('\nfunction definitions: ${available.toFunctionJson().length} tools');

  // ---------------------------------------------------------------------------
  // 3. Observe the run. A real UI would render these as they arrive.
  // ---------------------------------------------------------------------------
  final events = BroadcastEventBus();
  events.on<ToolEvent>().listen((event) {
    final detail = switch (event) {
      ToolCallStarted(:final arguments) => 'started $arguments',
      ToolCallCompleted(:final isError, :final failureKind) =>
        isError ? 'failed (${failureKind?.name})' : 'ok',
      ToolApprovalRequested() => 'awaiting approval',
      _ => '',
    };
    print('  [event] ${event.toolName}: $detail');
  });

  final context = AgenticContext.root(events: events);

  final executor = ToolExecutor(
    tools: available,
    // Fails closed without this: a tool marked as needing consent never runs
    // unapproved.
    approvalHandler: (request) async {
      print('  [approval] run ${request.spec.name} with ${request.arguments}?');
      return request.arguments['to'] != 'everyone@example.com';
    },
  );

  // ---------------------------------------------------------------------------
  // 4. Run what the model asked for. These four calls are deliberately imperfect
  //    in the ways models really are.
  // ---------------------------------------------------------------------------
  final toolCalls = <ToolCallPart>[
    // `limit` came back as a string. Repaired, not rejected.
    ToolCallPart(
      id: 'call_1',
      name: 'search_web',
      arguments: {'query': 'dart 3 records', 'limit': '2'},
    ),
    // `query` is missing entirely. The model is told exactly what to fix.
    ToolCallPart(id: 'call_2', name: 'search_web', arguments: {'limit': 3}),
    // A tool that runs and reports a failure.
    ToolCallPart(
      id: 'call_3',
      name: 'read_file',
      arguments: {'path': '/tmp/notes.txt'},
    ),
    // A write that needs a human. Writes are also serialised against each other.
    ToolCallPart(
      id: 'call_4',
      name: 'send_email',
      arguments: {
        'to': 'ada@example.com',
        'subject': 'Records',
        'body': 'They are tuples with names.',
      },
    ),
  ];

  print('\nrunning ${toolCalls.length} tool calls:');
  final messages = await executor.executeAllAsMessages(
    toolCalls,
    context: context,
  );

  // ---------------------------------------------------------------------------
  // 5. The result is history you can append and send straight back.
  // ---------------------------------------------------------------------------
  print('\nmessages to append to the conversation:');
  for (final message in messages) {
    final part = message.toolResults.single;
    final marker = part.isError ? 'ERROR' : 'ok   ';
    final firstLine = part.content.split('\n').first;
    print('  $marker ${part.name.padRight(12)} $firstLine');
  }

  await events.dispose();
  await registry.dispose();
}
