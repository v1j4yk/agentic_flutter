import 'dart:async';

import 'package:agentic_core/agentic_core.dart';
import 'package:agentic_core/testing.dart';
import 'package:agentic_tools/agentic_tools.dart';
import 'package:test/test.dart';

FunctionTool searchTool({List<String>? log}) => FunctionTool(
  name: 'search_web',
  description: 'Searches the public web and returns the top results.',
  tags: {'research'},
  parameters: JsonSchema.object(
    properties: {
      'query': JsonSchema.string(description: 'The search query', minLength: 1),
      'limit': JsonSchema.integer(minimum: 1, maximum: 10, defaultValue: 5),
    },
    required: {'query'},
  ),
  handler: (invocation) async {
    log?.add(invocation.require<String>('query'));
    return ToolResult.success(
      'results for ${invocation.require<String>('query')} '
      '(limit ${invocation.optional<int>('limit', 5)})',
    );
  },
);

FunctionTool writeTool({
  required List<String> log,
  bool requiresApproval = false,
}) => FunctionTool(
  name: 'write_file',
  description: 'Writes text to a file, replacing any existing content.',
  tags: {'files'},
  isReadOnly: false,
  isIdempotent: false,
  requiresApproval: requiresApproval,
  parameters: JsonSchema.object(
    properties: {'path': JsonSchema.string(), 'body': JsonSchema.string()},
    required: {'path', 'body'},
  ),
  handler: (invocation) async {
    log.add('start:${invocation.require<String>('path')}');
    await Future<void>.delayed(Duration.zero);
    log.add('end:${invocation.require<String>('path')}');
    return ToolResult.success('written');
  },
);

ToolCallPart callTo(
  String name, {
  Map<String, Object?> arguments = const {},
  String id = 'call_1',
}) => ToolCallPart(id: id, name: name, arguments: arguments);

AgenticContext testContext({EventBus? events, SpanExporter? exporter}) =>
    AgenticContext.root(
      runId: 'run-1',
      events: events,
      ids: SequentialIdGenerator(prefix: 'x'),
      tracer: exporter == null ? null : Tracer(exporter: exporter),
    );

void main() {
  group('ToolSpec', () {
    test('rejects a name providers would reject', () {
      expect(
        () => ToolSpec(name: 'search web!', description: 'x'),
        throwsA(isA<ConfigurationException>()),
      );
    });

    test('rejects an empty description', () {
      expect(
        () => ToolSpec(name: 'ok', description: '   '),
        throwsA(
          isA<ConfigurationException>().having(
            (e) => e.message,
            'message',
            contains('description'),
          ),
        ),
      );
    });

    test('defaults to a closed, empty parameter object', () {
      final spec = ToolSpec(name: 'now', description: 'The time.');

      expect(spec.parameters.type, JsonSchemaType.object);
      expect(spec.parameters.additionalProperties, isFalse);
    });

    test('renders a provider function definition', () {
      final json = searchTool().spec.toFunctionJson();

      expect(json['name'], 'search_web');
      expect(json['description'], contains('Searches'));
      expect((json['parameters']! as Map)['type'], 'object');
    });

    test('folds examples into the model-visible description', () {
      final spec = ToolSpec(
        name: 'convert',
        description: 'Converts a currency amount.',
        examples: [
          ToolExample(
            situation: 'How much is 20 euros in dollars?',
            arguments: {'from': 'EUR', 'to': 'USD', 'amount': 20},
          ),
        ],
      );

      final description = spec.toFunctionJson()['description']! as String;
      expect(description, contains('Examples:'));
      expect(description, contains('from: "EUR"'));
    });
  });

  group('ToolRegistry', () {
    test('registers, resolves and selects', () {
      final registry = ToolRegistry()
        ..register(searchTool())
        ..register(writeTool(log: []));

      expect(registry.length, 2);
      expect(registry.select(tags: {'research'}).names, <String>['search_web']);
      expect(registry.select(readOnly: true).names, <String>['search_web']);
      expect(registry.select(readOnly: false).names, <String>['write_file']);
      expect(registry.select(excludeTags: {'files'}).names, <String>[
        'search_web',
      ]);
    });

    test('rejects a duplicate tool name', () {
      final registry = ToolRegistry()..register(searchTool());

      expect(
        () => registry.register(searchTool()),
        throwsA(isA<ConfigurationException>()),
      );
    });

    test('a lazy tool is described without being constructed', () {
      var constructed = false;
      final spec = ToolSpec(
        name: 'camera',
        description: 'Takes a photo with the device camera.',
      );

      final registry = ToolRegistry()
        ..registerLazy(spec, () {
          constructed = true;
          return FunctionTool.fromSpec(
            spec: spec,
            handler: (_) async => ToolResult.success('photo'),
          );
        });

      expect(registry.all.specs.single.name, 'camera');
      expect(registry.all.specOf('camera'), isNotNull);
      expect(
        constructed,
        isFalse,
        reason: 'describing a tool must not open the camera',
      );

      registry.resolve('camera');
      expect(constructed, isTrue);
    });

    test('a set distinguishes "not selected" from "does not exist"', () {
      final registry = ToolRegistry()
        ..register(searchTool())
        ..register(writeTool(log: []));
      final set = registry.select(tags: {'research'});

      expect(
        () => set.resolve('write_file'),
        throwsA(
          isA<NotFoundException>().having(
            (e) => e.message,
            'message',
            contains('not made available to this agent'),
          ),
        ),
      );
      expect(
        () => set.resolve('nonexistent'),
        throwsA(
          isA<NotFoundException>().having(
            (e) => e.message,
            'message',
            contains('No tool named'),
          ),
        ),
      );
    });

    test('sets compose and subtract', () {
      final registry = ToolRegistry()
        ..register(searchTool())
        ..register(writeTool(log: []));

      final combined =
          registry.select(tags: {'research'}) +
          registry.select(tags: {'files'});

      expect(combined.length, 2);
      expect(combined.without({'write_file'}).names, <String>['search_web']);
    });

    test('RenamedTool resolves a naming collision', () async {
      final renamed = RenamedTool(searchTool(), name: 'web_lookup');
      final registry = ToolRegistry()..register(renamed);

      expect(registry.names, <String>['web_lookup']);

      final result = await ToolExecutor(tools: registry.all).execute(
        callTo('web_lookup', arguments: {'query': 'dart'}),
        context: testContext(),
      );

      expect(result.isError, isFalse);
      expect(result.content, contains('results for dart'));
    });
  });

  group('ToolExecutor', () {
    late ToolRegistry registry;
    late List<String> searchLog;

    setUp(() {
      searchLog = <String>[];
      registry = ToolRegistry()..register(searchTool(log: searchLog));
    });

    test('runs a valid call', () async {
      final result = await ToolExecutor(tools: registry.all).execute(
        callTo('search_web', arguments: {'query': 'dart 3'}),
        context: testContext(),
      );

      expect(result.isError, isFalse);
      expect(result.content, contains('results for dart 3'));
      expect(searchLog, <String>['dart 3']);
    });

    test('applies schema defaults', () async {
      final result = await ToolExecutor(tools: registry.all).execute(
        callTo('search_web', arguments: {'query': 'x'}),
        context: testContext(),
      );

      expect(result.content, contains('limit 5'));
    });

    test('repairs a stringified number rather than failing', () async {
      final result = await ToolExecutor(tools: registry.all).execute(
        callTo('search_web', arguments: {'query': 'x', 'limit': '3'}),
        context: testContext(),
      );

      expect(result.isError, isFalse);
      expect(result.content, contains('limit 3'));
    });

    test('coercion can be turned off', () async {
      final result =
          await ToolExecutor(
            tools: registry.all,
            coerceArguments: false,
          ).execute(
            callTo('search_web', arguments: {'query': 'x', 'limit': '3'}),
            context: testContext(),
          );

      expect(result.isError, isTrue);
      expect(result.metadata['failureKind'], 'invalidArguments');
    });

    test('returns an unknown tool as a recoverable failure', () async {
      final result = await ToolExecutor(tools: registry.all).execute(
        callTo('serch_web', arguments: {'query': 'x'}),
        context: testContext(),
      );

      // Returned, not thrown: the model can pick the right name next turn.
      expect(result.isError, isTrue);
      expect(result.metadata['failureKind'], 'unknownTool');
      expect(result.content, contains('search_web'));
    });

    test('returns invalid arguments with every violation listed', () async {
      final result = await ToolExecutor(tools: registry.all).execute(
        callTo('search_web', arguments: {'limit': 99}),
        context: testContext(),
      );

      expect(result.isError, isTrue);
      expect(result.metadata['failureKind'], 'invalidArguments');
      expect(result.content, contains('/query'));
      expect(result.content, contains('/limit'));
      expect(result.content, contains('call `search_web` again'));
    });

    test('turns a thrown framework error into a failure result', () async {
      final failing = ToolRegistry()
        ..register(
          FunctionTool(
            name: 'flaky',
            description: 'Fails on purpose.',
            handler: (_) async =>
                throw StorageException('disk full', store: 'sqlite'),
          ),
        );

      final result = await ToolExecutor(
        tools: failing.all,
      ).execute(callTo('flaky'), context: testContext());

      expect(result.isError, isTrue);
      expect(result.metadata['failureKind'], 'executionFailed');
      expect(result.content, contains('disk full'));
    });

    test('contains an unclassified crash instead of failing the run', () async {
      final broken = ToolRegistry()
        ..register(
          FunctionTool(
            name: 'broken',
            description: 'Throws something unexpected.',
            handler: (_) async => throw StateError('null deref'),
          ),
        );

      final result = await ToolExecutor(
        tools: broken.all,
      ).execute(callTo('broken'), context: testContext());

      expect(result.isError, isTrue);
      expect(result.metadata['failureKind'], 'unexpectedError');
    });

    test('propagates cancellation instead of swallowing it', () async {
      final source = CancellationTokenSource();
      final cancelling = ToolRegistry()
        ..register(
          FunctionTool(
            name: 'long',
            description: 'Runs until cancelled.',
            handler: (invocation) async {
              source.cancel('user left');
              invocation.cancellation.throwIfCancelled(operation: 'long');
              return ToolResult.success('never');
            },
          ),
        );

      await expectLater(
        ToolExecutor(tools: cancelling.all).execute(
          callTo('long'),
          context: AgenticContext.root(cancellation: source.token),
        ),
        throwsA(isA<CancelledException>()),
      );
    });

    test('enforces a per-tool timeout', () async {
      final clock = FakeClock();
      final slow = ToolRegistry()
        ..register(
          FunctionTool(
            name: 'slow',
            description: 'Never finishes.',
            timeout: const Duration(seconds: 2),
            handler: (invocation) async {
              await invocation.context.clock.delay(const Duration(hours: 1));
              return ToolResult.success('done');
            },
          ),
        );

      final pending = ToolExecutor(
        tools: slow.all,
      ).execute(callTo('slow'), context: AgenticContext.root(clock: clock));

      await clock.advance(const Duration(seconds: 3));
      final result = await pending;

      // A timeout is reported to the model, not thrown: the agent can say the
      // tool was too slow and carry on.
      expect(result.isError, isTrue);
      expect(result.metadata['failureKind'], 'timeout');
      expect(result.content, contains('did not finish'));
      await clock.resolvePending();
    });

    test('a cooperative tool stops itself when the budget expires', () async {
      final clock = FakeClock();
      var observedCancellation = false;
      final polite = ToolRegistry()
        ..register(
          FunctionTool(
            name: 'polite',
            description: 'Checks its cancellation token while working.',
            timeout: const Duration(seconds: 2),
            handler: (invocation) async {
              await invocation.cancellation.whenCancelled;
              observedCancellation = true;
              invocation.cancellation.throwIfCancelled(operation: 'polite');
              return ToolResult.success('never');
            },
          ),
        );

      final pending = ToolExecutor(
        tools: polite.all,
      ).execute(callTo('polite'), context: AgenticContext.root(clock: clock));

      await clock.advance(const Duration(seconds: 3));
      final result = await pending;

      expect(observedCancellation, isTrue);
      // A tool that cooperates is not punished for it: the outcome is the same
      // timeout failure an uncooperative tool would have produced.
      expect(result.isError, isTrue);
      expect(result.metadata['failureKind'], 'timeout');
      await clock.resolvePending();
    });
  });

  group('approval', () {
    test('denies by default when no handler is configured', () async {
      final log = <String>[];
      final registry = ToolRegistry()
        ..register(writeTool(log: log, requiresApproval: true));

      final result = await ToolExecutor(tools: registry.all).execute(
        callTo('write_file', arguments: {'path': '/a', 'body': 'b'}),
        context: testContext(),
      );

      expect(result.isError, isTrue);
      expect(result.metadata['failureKind'], 'approvalDenied');
      expect(
        log,
        isEmpty,
        reason: 'failing closed is the only safe default for consent',
      );
    });

    test('runs when the handler approves', () async {
      final log = <String>[];
      final registry = ToolRegistry()
        ..register(writeTool(log: log, requiresApproval: true));

      final result =
          await ToolExecutor(
            tools: registry.all,
            approvalHandler: (request) async {
              expect(request.spec.name, 'write_file');
              expect(request.arguments['path'], '/a');
              return true;
            },
          ).execute(
            callTo('write_file', arguments: {'path': '/a', 'body': 'b'}),
            context: testContext(),
          );

      expect(result.isError, isFalse);
      expect(log, contains('start:/a'));
    });

    test('records the wait on the human as human waiting', () async {
      // The executor is the only place that knows an await is a person rather
      // than work. If it stops recording, a wall-clock budget silently starts
      // charging users for reading the prompt — and nothing else in the
      // framework is positioned to notice.
      final clock = FakeClock();
      final context = AgenticContext.root(
        runId: 'run-1',
        clock: clock,
        ids: SequentialIdGenerator(prefix: 'x'),
      );
      final registry = ToolRegistry()
        ..register(writeTool(log: [], requiresApproval: true));

      final pending =
          ToolExecutor(
            tools: registry.all,
            approvalHandler: (_) async {
              await clock.advance(const Duration(seconds: 12));
              return false;
            },
          ).execute(
            callTo('write_file', arguments: {'path': '/a', 'body': 'b'}),
            context: context,
          );

      await pending;
      expect(context.humanWait.total, const Duration(seconds: 12));
    });

    test('publishes an approval request event', () async {
      final bus = BroadcastEventBus();
      final registry = ToolRegistry()
        ..register(writeTool(log: [], requiresApproval: true));

      await ToolExecutor(
        tools: registry.all,
        approvalHandler: (_) async => false,
      ).execute(
        callTo('write_file', arguments: {'path': '/a', 'body': 'b'}),
        context: testContext(events: bus),
      );

      final events = await bus.on<ToolApprovalRequested>().first;
      expect(events.toolName, 'write_file');
      await bus.dispose();
    });
  });

  group('executeAll', () {
    test('preserves request order regardless of completion order', () async {
      final registry = ToolRegistry()
        ..register(
          FunctionTool(
            name: 'fast',
            description: 'Returns immediately.',
            handler: (_) async => ToolResult.success('fast'),
          ),
        )
        ..register(
          FunctionTool(
            name: 'slower',
            description: 'Returns after a microtask.',
            handler: (_) async {
              await Future<void>.delayed(const Duration(milliseconds: 5));
              return ToolResult.success('slower');
            },
          ),
        );

      final results = await ToolExecutor(tools: registry.all).executeAll([
        callTo('slower', id: 'c1'),
        callTo('fast', id: 'c2'),
      ], context: testContext());

      expect(results.map((r) => r.content), <String>['slower', 'fast']);
    });

    test('runs read-only calls concurrently', () async {
      var active = 0;
      var peak = 0;
      final registry = ToolRegistry()
        ..register(
          FunctionTool(
            name: 'reader',
            description: 'Reads something.',
            handler: (_) async {
              active++;
              peak = active > peak ? active : peak;
              await Future<void>.delayed(const Duration(milliseconds: 5));
              active--;
              return ToolResult.success('read');
            },
          ),
        );

      await ToolExecutor(tools: registry.all).executeAll(
        List.generate(4, (i) => callTo('reader', id: 'c$i')),
        context: testContext(),
      );

      expect(peak, greaterThan(1));
    });

    test('serialises mutating calls so writes cannot interleave', () async {
      final log = <String>[];
      final registry = ToolRegistry()..register(writeTool(log: log));

      await ToolExecutor(tools: registry.all).executeAll([
        callTo('write_file', id: 'c1', arguments: {'path': '/a', 'body': 'x'}),
        callTo('write_file', id: 'c2', arguments: {'path': '/b', 'body': 'y'}),
      ], context: testContext());

      expect(log, <String>['start:/a', 'end:/a', 'start:/b', 'end:/b']);
    });

    test('respects the concurrency ceiling', () async {
      var active = 0;
      var peak = 0;
      final registry = ToolRegistry()
        ..register(
          FunctionTool(
            name: 'reader',
            description: 'Reads something.',
            handler: (_) async {
              active++;
              peak = active > peak ? active : peak;
              await Future<void>.delayed(const Duration(milliseconds: 5));
              active--;
              return ToolResult.success('read');
            },
          ),
        );

      await ToolExecutor(tools: registry.all, maxConcurrency: 2).executeAll(
        List.generate(6, (i) => callTo('reader', id: 'c$i')),
        context: testContext(),
      );

      expect(peak, lessThanOrEqualTo(2));
    });

    test('produces messages ready to append to history', () async {
      final registry = ToolRegistry()..register(searchTool());

      final messages = await ToolExecutor(tools: registry.all)
          .executeAllAsMessages([
            callTo('search_web', arguments: {'query': 'dart'}),
          ], context: testContext());

      final part = messages.single.toolResults.single;
      expect(messages.single.role, MessageRole.tool);
      expect(part.callId, 'call_1');
      expect(part.name, 'search_web');
      expect(part.isError, isFalse);
    });

    test('an empty batch is a no-op', () async {
      final results = await ToolExecutor(
        tools: ToolRegistry().all,
      ).executeAll([], context: testContext());

      expect(results, isEmpty);
    });
  });

  group('observability', () {
    test('publishes start and completion events', () async {
      final bus = BroadcastEventBus();
      final registry = ToolRegistry()..register(searchTool());

      await ToolExecutor(tools: registry.all).execute(
        callTo('search_web', arguments: {'query': 'dart'}),
        context: testContext(events: bus),
      );

      final events = bus.replayBuffer.whereType<ToolEvent>().toList();
      expect(events.first, isA<ToolCallStarted>());
      expect(events.last, isA<ToolCallCompleted>());
      expect((events.last as ToolCallCompleted).isError, isFalse);
      expect(events.every((e) => e.runId == 'run-1'), isTrue);
      await bus.dispose();
    });

    test('reports the failure kind on the completion event', () async {
      final bus = BroadcastEventBus();
      final registry = ToolRegistry()..register(searchTool());

      await ToolExecutor(
        tools: registry.all,
      ).execute(callTo('search_web'), context: testContext(events: bus));

      final completed = bus.replayBuffer.whereType<ToolCallCompleted>().single;
      expect(completed.isError, isTrue);
      expect(completed.failureKind, ToolFailureKind.invalidArguments);
    });

    test('categorises a failure the tool reported itself', () async {
      final bus = BroadcastEventBus();
      final failing = ToolRegistry()
        ..register(
          FunctionTool(
            name: 'reader',
            description: 'Returns its own failure rather than throwing.',
            handler: (_) async => ToolResult.failure('no such file'),
          ),
        );

      await ToolExecutor(
        tools: failing.all,
      ).execute(callTo('reader'), context: testContext(events: bus));

      final completed = bus.replayBuffer.whereType<ToolCallCompleted>().single;
      expect(completed.isError, isTrue);
      expect(
        completed.failureKind,
        ToolFailureKind.executionFailed,
        reason: 'a UI counting failures by category must not miss these',
      );
      await bus.dispose();
    });

    test('opens a span per tool call with useful attributes', () async {
      final exporter = InMemorySpanExporter();
      final registry = ToolRegistry()..register(searchTool());

      await ToolExecutor(tools: registry.all).execute(
        callTo('search_web', arguments: {'query': 'dart'}),
        context: testContext(exporter: exporter),
      );

      final span = exporter.named('tool.search_web').single;
      expect(span.attributes['tool.name'], 'search_web');
      expect(span.attributes['tool.read_only'], isTrue);
      expect(span.attributes['tool.is_error'], isFalse);
      expect(span.status, SpanStatus.ok);
    });
  });

  group('ToolResult', () {
    test('renders structured data as JSON for the model', () {
      final result = ToolResult.json({'city': 'Paris', 'temp': 21});

      expect(result.content, '{"city": "Paris", "temp": 21}');
      expect(result.data, isA<Map<String, Object?>>());
      expect(result.isError, isFalse);
    });

    test('converts to a tool message part', () {
      final part = ToolResult.success(
        'ok',
      ).toPart(callId: 'c1', toolName: 'search_web');

      expect(part.callId, 'c1');
      expect(part.name, 'search_web');
      expect(part.isError, isFalse);
    });

    test('metadata is unmodifiable and mergeable', () {
      final result = ToolResult.success('ok').withMetadata({'cached': true});

      expect(result.metadata['cached'], isTrue);
      expect(() => result.metadata['x'] = 1, throwsUnsupportedError);
    });
  });
}
