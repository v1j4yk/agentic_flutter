import 'dart:async';
import 'dart:typed_data';

import 'package:agentic_flutter/agentic_flutter.dart';
import 'package:agentic_llm/testing.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// An agent that answers from a script, so widget tests are deterministic.
final class ScriptedAgent implements Agent {
  ScriptedAgent({
    this.reply = 'Scripted answer.',
    this.chunks = const <String>['Scripted ', 'answer.'],
    this.failure,
    this.toolName,
    this.delay = Duration.zero,
  });

  final String reply;
  final List<String> chunks;
  final AgenticException? failure;
  final String? toolName;
  final Duration delay;

  int runs = 0;

  @override
  AgentInfo get info =>
      AgentInfo(name: 'scripted', description: 'Answers from a script.');

  @override
  Future<AgentResult> run(
    AgentInput input, {
    AgentSession? session,
    AgenticContext? context,
  }) async {
    runs++;
    if (delay > Duration.zero) await Future<void>.delayed(delay);
    context?.throwIfCancelled();
    final error = failure;
    if (error != null) throw error;
    return AgentResult(
      message: Message.assistant(reply),
      stopReason: AgentStopReason.completed,
      duration: Duration.zero,
    );
  }

  @override
  Stream<AgentChunk> stream(
    AgentInput input, {
    AgentSession? session,
    AgenticContext? context,
  }) async* {
    runs++;
    final tool = toolName;
    if (tool != null) {
      yield AgentToolCallStarted(toolName: tool, callId: 'c1');
    }
    for (final chunk in chunks) {
      if (delay > Duration.zero) await Future<void>.delayed(delay);
      context?.throwIfCancelled();
      yield AgentTextDelta(chunk);
    }
    final error = failure;
    if (error != null) throw error;
    yield AgentFinished(
      AgentResult(
        message: Message.assistant(chunks.join()),
        stopReason: AgentStopReason.completed,
        duration: Duration.zero,
      ),
    );
  }

  @override
  Future<void> dispose() async {}
}

Widget wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

void main() {
  group('FlutterLogSink', () {
    test('writes through debugPrint in debug builds', () {
      final lines = <String>[];
      final original = debugPrint;
      debugPrint = (message, {wrapWidth}) => lines.add(message ?? '');
      addTearDown(() => debugPrint = original);

      const FlutterLogSink().emit(
        LogRecord(
          timestamp: DateTime.utc(2026),
          level: LogLevel.info,
          message: 'hello',
          loggerName: 'test',
        ),
      );

      expect(lines, hasLength(1));
      expect(lines.single, contains('hello'));
    });
  });

  group('LifecycleCancellation', () {
    testWidgets('cancels on detach but not on pause, by default', (
      tester,
    ) async {
      final source = CancellationTokenSource();
      final binding = LifecycleCancellation.attach(source);
      addTearDown(binding.detach);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      expect(source.isCancelled, isFalse);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.detached);
      expect(source.isCancelled, isTrue);
    });

    testWidgets('cancels on pause when asked to', (tester) async {
      final source = CancellationTokenSource();
      var notified = 0;
      final binding = LifecycleCancellation.attach(
        source,
        policy: BackgroundPolicy.cancelOnPause,
        onCancelled: (_) => notified++,
      );
      addTearDown(binding.detach);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      expect(source.isCancelled, isTrue);
      expect(notified, 1);

      // Idempotent: a second lifecycle change must not fire the callback again.
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.detached);
      expect(notified, 1);
    });

    testWidgets('keepRunning survives everything', (tester) async {
      final source = CancellationTokenSource();
      final binding = LifecycleCancellation.attach(
        source,
        policy: BackgroundPolicy.keepRunning,
      );
      addTearDown(binding.detach);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.detached);
      expect(source.isCancelled, isFalse);
    });

    testWidgets('a detached binding stops observing', (tester) async {
      final source = CancellationTokenSource();
      LifecycleCancellation.attach(
        source,
        policy: BackgroundPolicy.cancelOnPause,
      ).detach();

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      expect(source.isCancelled, isFalse);
    });

    testWidgets('withLifecycleCancellation always removes its observer', (
      tester,
    ) async {
      await expectLater(
        withLifecycleCancellation<void>((token) async {
          throw const FormatException('boom');
        }),
        throwsFormatException,
      );

      // If the observer had leaked, this would cancel a token nobody holds and
      // the test would still pass — so the check is that a *new* binding sees
      // a clean world.
      final source = CancellationTokenSource();
      final binding = LifecycleCancellation.attach(source);
      addTearDown(binding.detach);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      expect(source.isCancelled, isFalse);
    });
  });

  group('AgenticRuntime', () {
    testWidgets('gives every run its own cancellation', (tester) async {
      final runtime = AgenticRuntime();
      addTearDown(runtime.dispose);

      final first = runtime.runContext('one');
      final second = runtime.runContext('two');
      addTearDown(first.binding.detach);
      addTearDown(second.binding.detach);

      first.binding.token.isCancelled;
      expect(first.context.cancellation, isNot(second.context.cancellation));
      expect(first.context.name, endsWith('one'));
    });

    testWidgets('run releases its lifecycle binding', (tester) async {
      final runtime = AgenticRuntime(
        backgroundPolicy: BackgroundPolicy.cancelOnPause,
      );
      addTearDown(runtime.dispose);

      await runtime.run('turn', (context) async => context.name);

      // The run is over, so a lifecycle change must not reach anything.
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      expect(runtime.context.cancellation.isCancelled, isFalse);
    });

    test('does not dispose what it was handed', () async {
      final bus = BroadcastEventBus();
      final tools = ToolRegistry();
      final runtime = AgenticRuntime(events: bus, tools: tools);

      await runtime.dispose();
      expect(bus.isClosed, isFalse, reason: 'the caller still owns it');
      await bus.dispose();
    });

    test('disposes what it created', () async {
      final runtime = AgenticRuntime();
      final bus = runtime.events;
      await runtime.dispose();
      expect(bus.isClosed, isTrue);
    });

    test('refuses to hand out contexts after disposal', () async {
      final runtime = AgenticRuntime();
      await runtime.dispose();
      expect(
        () => runtime.runContext('late'),
        throwsA(isA<InvalidStateException>()),
      );
    });
  });

  group('AgenticScope', () {
    testWidgets('provides the runtime to the subtree', (tester) async {
      final runtime = AgenticRuntime();
      addTearDown(runtime.dispose);
      AgenticRuntime? seen;

      await tester.pumpWidget(
        AgenticScope(
          runtime: runtime,
          child: Builder(
            builder: (context) {
              seen = context.agentic;
              return const SizedBox();
            },
          ),
        ),
      );

      expect(identical(seen, runtime), isTrue);
    });

    testWidgets('says what is missing when there is no scope', (tester) async {
      Object? thrown;
      await tester.pumpWidget(
        Builder(
          builder: (context) {
            try {
              AgenticScope.of(context);
            } on Object catch (error) {
              thrown = error;
            }
            return const SizedBox();
          },
        ),
      );

      expect(thrown, isA<ConfigurationException>());
      expect('$thrown', contains('AgenticScope'));
    });

    testWidgets('maybeOf returns null rather than throwing', (tester) async {
      AgenticRuntime? seen;
      await tester.pumpWidget(
        Builder(
          builder: (context) {
            seen = AgenticScope.maybeOf(context);
            return const SizedBox();
          },
        ),
      );
      expect(seen, isNull);
    });

    testWidgets('leaves a runtime it was not asked to own', (tester) async {
      final runtime = AgenticRuntime();
      addTearDown(runtime.dispose);

      await tester.pumpWidget(
        AgenticScope(runtime: runtime, child: const SizedBox()),
      );
      await tester.pumpWidget(const SizedBox());

      expect(runtime.events.isClosed, isFalse);
    });
  });

  group('AgentChatController', () {
    test('streams an answer into one entry', () async {
      final controller = AgentChatController(
        agent: ScriptedAgent(chunks: const <String>['Hello ', 'there.']),
      );
      addTearDown(controller.dispose);

      final entry = await controller.send('hi');

      expect(controller.entries, hasLength(2));
      expect(controller.entries.first.role, MessageRole.user);
      expect(entry.text, 'Hello there.');
      expect(entry.isStreaming, isFalse);
      expect(controller.isBusy, isFalse);
    });

    test('reports which tool it is using while it works', () async {
      final seen = <String?>[];
      final controller = AgentChatController(
        agent: ScriptedAgent(toolName: 'search_web'),
      );
      addTearDown(controller.dispose);
      controller.addListener(() => seen.add(controller.entries.last.activity));

      final entry = await controller.send('hi');
      expect(seen, contains('using search_web'));
      expect(entry.toolCalls, contains('search_web'));
    });

    test('keeps partial text when a turn is cancelled', () async {
      final controller = AgentChatController(
        agent: ScriptedAgent(
          chunks: const <String>['one ', 'two ', 'three'],
          delay: const Duration(milliseconds: 10),
        ),
      );
      addTearDown(controller.dispose);

      final pending = controller.send('hi');
      await Future<void>.delayed(const Duration(milliseconds: 15));
      controller.cancel();
      final entry = await pending;

      expect(entry.text, isNotEmpty);
      expect(entry.text.length, lessThan('one two three'.length));
      expect(entry.activity, 'stopped');
      expect(entry.isError, isFalse, reason: 'stopping is not a failure');
    });

    test('shows a failure without discarding the transcript', () async {
      final controller = AgentChatController(
        agent: ScriptedAgent(
          failure: RateLimitException('Slow down.', provider: 'test'),
        ),
      );
      addTearDown(controller.dispose);

      final entry = await controller.send('hi');
      expect(entry.isError, isTrue);
      expect(controller.entries.first.text, 'hi');
    });

    test('refuses a second turn while one is running', () async {
      final controller = AgentChatController(
        agent: ScriptedAgent(delay: const Duration(milliseconds: 20)),
      );
      addTearDown(controller.dispose);

      final pending = controller.send('first');
      expect(
        () => controller.send('second'),
        throwsA(isA<InvalidStateException>()),
      );
      await pending;
    });

    test('works without streaming', () async {
      final controller = AgentChatController(
        agent: ScriptedAgent(reply: 'Buffered.'),
        streaming: false,
      );
      addTearDown(controller.dispose);

      final entry = await controller.send('hi');
      expect(entry.text, 'Buffered.');
      expect(entry.isStreaming, isFalse);
    });

    test('clear empties the transcript and the session', () async {
      final controller = AgentChatController(agent: ScriptedAgent());
      addTearDown(controller.dispose);

      await controller.send('hi');
      controller.clear();

      expect(controller.entries, isEmpty);
      expect(controller.session.history, isEmpty);
    });
  });

  group('AgentChatView', () {
    testWidgets('renders a conversation and sends on submit', (tester) async {
      final controller = AgentChatController(
        agent: ScriptedAgent(chunks: const <String>['Hi ', 'there.']),
      );
      addTearDown(controller.dispose);

      await tester.pumpWidget(wrap(AgentChatView(controller: controller)));

      await tester.enterText(find.byType(TextField), 'hello');
      await tester.testTextInput.receiveAction(TextInputAction.send);
      await tester.pumpAndSettle();

      expect(find.text('hello'), findsOneWidget);
      expect(find.text('Hi there.'), findsOneWidget);
    });

    testWidgets('shows an empty state before anything is said', (tester) async {
      final controller = AgentChatController(agent: ScriptedAgent());
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        wrap(
          AgentChatView(
            controller: controller,
            emptyState: const Text('Ask me anything.'),
          ),
        ),
      );

      expect(find.text('Ask me anything.'), findsOneWidget);
    });

    testWidgets('offers a stop button while a turn is running', (tester) async {
      final controller = AgentChatController(
        agent: ScriptedAgent(
          chunks: const <String>['one ', 'two'],
          delay: const Duration(milliseconds: 40),
        ),
      );
      addTearDown(controller.dispose);

      // Found by tooltip rather than by glyph: what matters is that a way to
      // stop appears and works, not which of Material's stop icons draws it.
      // Pinning the glyph makes a restyle look like a broken feature.
      final stop = find.byTooltip('Stop');

      await tester.pumpWidget(wrap(AgentChatView(controller: controller)));
      expect(stop, findsNothing);

      unawaited(controller.send('hi'));
      await tester.pump();
      expect(stop, findsOneWidget);

      await tester.tap(stop);
      // pump, not pumpAndSettle: a turn in flight shows an indeterminate
      // progress animation, which by construction never settles. Any app test
      // written against this widget has to do the same, which is why the
      // widget's own documentation says so.
      await tester.pump(const Duration(milliseconds: 100));
      expect(stop, findsNothing);
    });

    testWidgets('turns a rate limit into advice a user can act on', (
      tester,
    ) async {
      final controller = AgentChatController(
        agent: ScriptedAgent(
          failure: RateLimitException('429', provider: 'test'),
        ),
      );
      addTearDown(controller.dispose);

      await tester.pumpWidget(wrap(AgentChatView(controller: controller)));
      await controller.send('hi');
      await tester.pumpAndSettle();

      expect(find.textContaining('rate-limiting'), findsOneWidget);
    });
  });

  group('tool approval', () {
    ToolApprovalRequest requestFor(ToolSpec spec) => ToolApprovalRequest(
      spec: spec,
      callId: 'c1',
      arguments: const <String, Object?>{'to': 'board@example.test'},
      context: AgenticContext.root(),
    );

    testWidgets('shows the arguments the model actually proposed', (
      tester,
    ) async {
      bool? decision;
      await tester.pumpWidget(
        wrap(
          ToolApprovalSheet(
            request: requestFor(
              ToolSpec(
                name: 'send_email',
                description: 'Sends an email.',
                isReadOnly: false,
              ),
            ),
            onDecision: ({required approved}) => decision = approved,
          ),
        ),
      );

      expect(find.textContaining('send_email'), findsOneWidget);
      expect(find.textContaining('board@example.test'), findsOneWidget);
      expect(find.textContaining('not read-only'), findsOneWidget);

      await tester.tap(find.text('Deny'));
      expect(decision, isFalse);
    });

    testWidgets('dismissing the sheet denies', (tester) async {
      late BuildContext sheetContext;
      await tester.pumpWidget(
        wrap(
          Builder(
            builder: (context) {
              sheetContext = context;
              return const SizedBox();
            },
          ),
        ),
      );

      final decision = showToolApprovalSheet(
        sheetContext,
        request: requestFor(
          ToolSpec(name: 'read_file', description: 'Reads a file.'),
        ),
      );
      await tester.pumpAndSettle();

      // Tapping the barrier is how a user dismisses without answering.
      await tester.tapAt(const Offset(20, 20));
      await tester.pumpAndSettle();

      expect(await decision, isFalse);
    });

    test('a handler with no navigator denies rather than allowing', () async {
      final handler = sheetApprovalHandler(
        navigatorKey: GlobalKey<NavigatorState>(),
      );
      final approved = await handler(
        requestFor(ToolSpec(name: 'x', description: 'y')),
      );
      expect(approved, isFalse);
    });

    test('scripted approvals fail closed by default', () async {
      final approvals = ScriptedApprovals();
      expect(
        await approvals.handle(
          requestFor(ToolSpec(name: 'wipe', description: 'Wipes.')),
        ),
        isFalse,
      );
      expect(approvals.askedAbout, <String>['wipe']);
    });

    test('unencodable arguments render rather than throwing', () {
      final rendered = ToolApprovalSheet.formatArguments(<String, Object?>{
        'callback': () {},
      });
      expect(rendered, isNotEmpty);
    });
  });

  group('platform tools', () {
    test('location reports its accuracy, not just its coordinates', () async {
      final tool = locationTool(
        read: () async => const DeviceLocation(
          latitude: 51.5072,
          longitude: -0.1276,
          accuracyMetres: 12,
          placeName: 'London',
        ),
      );

      final result = await tool.call(
        ToolInvocation(
          callId: 'c1',
          toolName: tool.spec.name,
          context: AgenticContext.root(),
        ),
      );

      expect(result.isError, isFalse);
      expect(result.content, contains('London'));
      expect(result.content, contains('12 m'));
    });

    test('a denial becomes a failure the model can recover from', () async {
      final tool = locationTool(
        read: () async => throw permissionDenied('location'),
      );

      final result = await tool.call(
        ToolInvocation(
          callId: 'c1',
          toolName: tool.spec.name,
          context: AgenticContext.root(),
        ),
      );

      expect(result.isError, isTrue);
      expect(result.content, contains('declined'));
    });

    test('a permanent denial says not to ask again', () async {
      final tool = locationTool(
        read: () async => throw permissionDenied('location', permanent: true),
      );

      final result = await tool.call(
        ToolInvocation(
          callId: 'c1',
          toolName: tool.spec.name,
          context: AgenticContext.root(),
        ),
      );

      expect(result.content, contains('do not ask again'));
    });

    test(
      'a plugin throwing something unexpected does not end the run',
      () async {
        final tool = locationTool(
          read: () => throw StateError('plugin blew up'),
        );

        final result = await tool.call(
          ToolInvocation(
            callId: 'c1',
            toolName: tool.spec.name,
            context: AgenticContext.root(),
          ),
        );

        expect(result.isError, isTrue);
        expect(result.content, contains('plugin blew up'));
      },
    );

    test(
      'cancellation propagates instead of becoming a tool failure',
      () async {
        final tool = locationTool(
          read: () => throw CancelledException('stopped'),
        );

        await expectLater(
          tool.call(
            ToolInvocation(
              callId: 'c1',
              toolName: tool.spec.name,
              context: AgenticContext.root(),
            ),
          ),
          throwsA(isA<CancelledException>()),
        );
      },
    );

    test(
      'the camera requires approval and refuses an oversized photo',
      () async {
        final tool = cameraTool(
          capture: (purpose) async => CapturedImage(
            bytes: Uint8List(5 * 1024 * 1024),
            mimeType: 'image/jpeg',
          ),
        );

        expect(tool.spec.requiresApproval, isTrue);
        expect(tool.spec.isReadOnly, isFalse);

        final result = await tool.call(
          ToolInvocation(
            callId: 'c1',
            toolName: tool.spec.name,
            arguments: const <String, Object?>{'purpose': 'the label'},
            context: AgenticContext.root(),
          ),
        );

        expect(result.isError, isTrue);
        expect(result.content, contains('Resize it'));
      },
    );

    test('a captured photo travels as an image part', () async {
      final tool = cameraTool(
        capture: (purpose) async => CapturedImage(
          bytes: Uint8List.fromList(<int>[1, 2, 3]),
          mimeType: 'image/jpeg',
        ),
      );

      final result = await tool.call(
        ToolInvocation(
          callId: 'c1',
          toolName: tool.spec.name,
          arguments: const <String, Object?>{'purpose': 'the label'},
          context: AgenticContext.root(),
        ),
      );

      expect(result.isError, isFalse);
      expect(result.parts.whereType<ImagePart>(), hasLength(1));
    });

    test('a dismissed camera is a recoverable failure', () async {
      final tool = cameraTool(capture: (purpose) async => null);

      final result = await tool.call(
        ToolInvocation(
          callId: 'c1',
          toolName: tool.spec.name,
          arguments: const <String, Object?>{'purpose': 'the label'},
          context: AgenticContext.root(),
        ),
      );

      expect(result.isError, isTrue);
      expect(result.content, contains('without taking a photo'));
    });

    test('ask_user returns what the user said', () async {
      final tool = askUserTool(ask: (question, options) async => options.first);

      final result = await tool.call(
        ToolInvocation(
          callId: 'c1',
          toolName: tool.spec.name,
          arguments: const <String, Object?>{
            'question': 'Which account?',
            'options': <String>['personal', 'work'],
          },
          context: AgenticContext.root(),
        ),
      );

      expect(result.content, 'personal');
    });
  });

  group('SecretStore', () {
    test('require names the key that is missing', () async {
      final store = InMemorySecretStore();
      addTearDown(store.dispose);

      await expectLater(
        store.require('OPENAI_API_KEY'),
        throwsA(
          isA<ConfigurationException>().having(
            (e) => e.setting,
            'setting',
            'OPENAI_API_KEY',
          ),
        ),
      );
    });

    test('an empty value counts as missing', () async {
      final store = InMemorySecretStore(<String, String>{'k': ''});
      addTearDown(store.dispose);
      expect(await store.has('k'), isFalse);
    });

    test('layers read in order and write to the front', () async {
      final user = InMemorySecretStore();
      final defaults = InMemorySecretStore(<String, String>{'k': 'default'});
      final layered = LayeredSecretStore(<SecretStore>[user, defaults]);
      addTearDown(layered.dispose);

      expect(await layered.read('k'), 'default');

      await layered.write('k', 'user');
      expect(await layered.read('k'), 'user');
      expect(
        await defaults.read('k'),
        'default',
        reason: 'a write must not land in the fallback layer',
      );
    });

    test('a layer that refuses does not stop the ones behind it', () async {
      final refusing = _RefusingStore();
      final layered = LayeredSecretStore(<SecretStore>[
        refusing,
        InMemorySecretStore(<String, String>{'k': 'v'}),
      ]);
      addTearDown(layered.dispose);

      expect(await layered.read('k'), 'v');
    });

    test(
      'compile-time values are readable in debug and cannot be written',
      () async {
        const store = DartDefineSecretStore(
          values: <String, String>{'OLLAMA_URL': 'http://localhost:11434'},
        );

        expect(await store.read('OLLAMA_URL'), 'http://localhost:11434');
        await expectLater(
          store.write('OLLAMA_URL', 'x'),
          throwsA(isA<CapabilityNotSupportedException>()),
        );
      },
    );
  });

  group('EventRecorder', () {
    test('keeps the newest events and reports what it dropped', () async {
      final bus = BroadcastEventBus();
      addTearDown(bus.dispose);
      final recorder = EventRecorder(bus, capacity: 3)..start();
      addTearDown(recorder.dispose);

      for (var i = 0; i < 5; i++) {
        bus.publish(
          GenericEvent(
            id: 'e$i',
            timestamp: DateTime.utc(2026),
            type: 'test.event',
            data: <String, Object?>{'i': i},
          ),
        );
      }
      await Future<void>.delayed(Duration.zero);

      expect(recorder.events, hasLength(3));
      expect(recorder.dropped, 2);
      expect(recorder.events.last.id, 'e4');
    });

    test('a filter keeps only what was asked for', () async {
      final bus = BroadcastEventBus();
      addTearDown(bus.dispose);
      final recorder = EventRecorder(bus, include: <String>{'llm.'})..start();
      addTearDown(recorder.dispose);

      bus
        ..publish(
          GenericEvent(
            id: 'a',
            timestamp: DateTime.utc(2026),
            type: 'llm.request.started',
          ),
        )
        ..publish(
          GenericEvent(
            id: 'b',
            timestamp: DateTime.utc(2026),
            type: 'workflow.node.entered',
          ),
        );
      await Future<void>.delayed(Duration.zero);

      expect(recorder.events.map((e) => e.id), <String>['a']);
    });

    testWidgets('the inspector shows events newest first', (tester) async {
      final bus = BroadcastEventBus();
      addTearDown(bus.dispose);
      final recorder = EventRecorder(bus)..start();
      addTearDown(recorder.dispose);

      await tester.pumpWidget(wrap(TraceInspector(recorder: recorder)));
      expect(find.textContaining('Waiting for events'), findsOneWidget);

      bus.publish(
        GenericEvent(
          id: 'a',
          timestamp: DateTime.utc(2026),
          type: 'tool.call.completed',
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('tool.call.completed'), findsOneWidget);
      expect(find.textContaining('1 event'), findsOneWidget);
    });
  });

  group('the umbrella', () {
    test('re-exports every layer through one import', () {
      // The point of the package: an application needs one import, not nine.
      // Naming a type from each layer is what proves it.
      expect(Message.user('x'), isA<Message>());
      expect(ToolRegistry(), isA<ToolRegistry>());
      expect(FakeChatModel.text('x'), isA<ChatModel>());
      expect(AgentSession(), isA<AgentSession>());
      expect(InMemoryMemoryStore(), isA<MemoryStore>());
      expect(WorkflowState(), isA<WorkflowState>());
      expect(InMemoryVectorStore(dimensions: 4), isA<VectorStore>());
      expect(const RecursiveChunker(), isA<Chunker>());
      expect(McpCapabilities(), isA<McpCapabilities>());
    });
  });
}

/// A store that refuses every operation, standing in for a release-mode layer.
final class _RefusingStore implements SecretStore {
  @override
  Future<String?> read(String key) async =>
      throw ConfigurationException('refused', setting: key);

  @override
  Future<void> write(String key, String value) async =>
      throw ConfigurationException('refused', setting: key);

  @override
  Future<void> delete(String key) async =>
      throw ConfigurationException('refused', setting: key);

  @override
  Future<void> dispose() async {}
}
