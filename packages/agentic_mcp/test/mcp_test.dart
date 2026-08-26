import 'dart:async';
import 'dart:convert';

import 'package:agentic_core/agentic_core.dart';
import 'package:agentic_core/testing.dart';
import 'package:agentic_mcp/agentic_mcp.dart';
import 'package:agentic_tools/agentic_tools.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

/// A scripted MCP server that answers over an in-memory transport.
///
/// Everything above the transport line — lifecycle, correlation, cancellation,
/// pagination — is testable against this without a process or a socket.
final class ScriptedServer {
  ScriptedServer(this.transport, {this.serverName = 'scripted'}) {
    transport.incoming.listen(_onMessage);
  }

  final InMemoryTransport transport;
  final String serverName;

  final List<JsonRpcRequest> requests = <JsonRpcRequest>[];
  final List<JsonRpcNotification> notifications = <JsonRpcNotification>[];
  final Map<String, JsonMap Function(JsonRpcRequest)> handlers =
      <String, JsonMap Function(JsonRpcRequest)>{};
  final Map<String, JsonRpcError> failures = <String, JsonRpcError>{};

  /// Methods this server will never answer, to exercise timeouts.
  final Set<String> silent = <String>{};

  /// Capabilities reported at initialisation.
  JsonMap capabilities = <String, Object?>{'tools': <String, Object?>{}};

  /// The revision this server claims.
  String protocolVersion = kLatestProtocolVersion;

  /// Extra delay before answering, to exercise cancellation.
  Duration delay = Duration.zero;

  void _onMessage(JsonMap raw) {
    final message = JsonRpcMessage.fromJson(raw);
    switch (message) {
      case JsonRpcNotificationMessage(:final notification):
        notifications.add(notification);
      case JsonRpcRequestMessage(:final request):
        requests.add(request);
        unawaited(_answer(request));
      case JsonRpcResponseMessage():
        break;
    }
  }

  Future<void> _answer(JsonRpcRequest request) async {
    if (silent.contains(request.method)) return;
    if (delay > Duration.zero) await Future<void>.delayed(delay);
    if (!transport.isOpen) return;

    final failure = failures[request.method];
    if (failure != null) {
      await transport.send(
        JsonRpcResponse.failure(request.id, failure).toJson(),
      );
      return;
    }

    final result = switch (request.method) {
      McpMethod.initialize => <String, Object?>{
        'protocolVersion': protocolVersion,
        'capabilities': capabilities,
        'serverInfo': <String, Object?>{'name': serverName, 'version': '1.2.3'},
        'instructions': 'Use the tools in order.',
      },
      McpMethod.ping => const <String, Object?>{},
      _ => handlers[request.method]?.call(request) ?? const <String, Object?>{},
    };
    await transport.send(JsonRpcResponse.result(request.id, result).toJson());
  }

  /// Sends an unsolicited notification to the client.
  Future<void> notify(String method, {JsonMap? params}) => transport.send(
    JsonRpcNotification(method: method, params: params).toJson(),
  );

  /// Sends a request to the client, returning its response.
  Future<JsonRpcResponse> ask(String method, {JsonMap? params}) async {
    final completer = Completer<JsonRpcResponse>();
    late final StreamSubscription<JsonMap> subscription;
    subscription = transport.incoming.listen((raw) {
      final message = JsonRpcMessage.fromJson(raw);
      if (message is JsonRpcResponseMessage && message.response.id == 'srv-1') {
        completer.complete(message.response);
        unawaited(subscription.cancel());
      }
    });
    await transport.send(
      JsonRpcRequest(id: 'srv-1', method: method, params: params).toJson(),
    );
    return completer.future;
  }
}

JsonMap toolDescriptor(
  String name, {
  String? description,
  JsonMap? schema,
  JsonMap annotations = const <String, Object?>{},
}) => <String, Object?>{
  'name': name,
  'description': ?description,
  'inputSchema':
      schema ??
      <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'path': <String, Object?>{'type': 'string'},
        },
        'required': <String>['path'],
      },
  if (annotations.isNotEmpty) 'annotations': annotations,
};

JsonMap textResult(String text, {bool isError = false}) => <String, Object?>{
  'content': <Object?>[
    <String, Object?>{'type': 'text', 'text': text},
  ],
  if (isError) 'isError': true,
};

Future<({McpClient client, ScriptedServer server})> connected({
  JsonMap? capabilities,
  AgenticContext? context,
  Duration requestTimeout = const Duration(seconds: 5),
}) async {
  final (clientSide, serverSide) = InMemoryTransport.pair();
  final server = ScriptedServer(serverSide);
  server.capabilities = capabilities ?? server.capabilities;

  final client = McpClient(
    transport: clientSide,
    context: context,
    requestTimeout: requestTimeout,
  );
  await client.initialize();
  // The `initialized` notification is delivered on a microtask, exactly as a
  // real transport would; let it land before the test looks.
  await Future<void>.delayed(Duration.zero);
  return (client: client, server: server);
}

void main() {
  group('JSON-RPC', () {
    test('tells requests, notifications and responses apart', () {
      expect(
        JsonRpcMessage.fromJson(<String, Object?>{
          'jsonrpc': '2.0',
          'id': 1,
          'method': 'ping',
        }),
        isA<JsonRpcRequestMessage>(),
      );
      expect(
        JsonRpcMessage.fromJson(<String, Object?>{
          'jsonrpc': '2.0',
          'method': 'notifications/initialized',
        }),
        isA<JsonRpcNotificationMessage>(),
      );
      expect(
        JsonRpcMessage.fromJson(<String, Object?>{
          'jsonrpc': '2.0',
          'id': 1,
          'result': <String, Object?>{},
        }),
        isA<JsonRpcResponseMessage>(),
      );
      expect(
        JsonRpcMessage.fromJson(<String, Object?>{
          'jsonrpc': '2.0',
          'id': 1,
          'error': <String, Object?>{'code': -32601, 'message': 'nope'},
        }),
        isA<JsonRpcResponseMessage>(),
      );
    });

    test('a null id makes a message a notification, not a request', () {
      final message = JsonRpcMessage.fromJson(<String, Object?>{
        'jsonrpc': '2.0',
        'id': null,
        'method': 'notifications/cancelled',
      });
      expect(message, isA<JsonRpcNotificationMessage>());
    });

    test('refuses to guess at something that is not JSON-RPC', () {
      expect(
        () => JsonRpcMessage.fromJson(<String, Object?>{'hello': 'world'}),
        throwsA(isA<SerializationException>()),
      );
    });

    test('a string id survives the round trip', () {
      final request = JsonRpcRequest(id: 'abc', method: 'ping');
      final decoded = JsonRpcRequest.fromJson(
        jsonDecode(jsonEncode(request.toJson())) as JsonMap,
      );
      expect(decoded.id, 'abc');
    });

    test('a null result decodes to an empty object, not a crash', () {
      final response = JsonRpcResponse.fromJson(<String, Object?>{
        'jsonrpc': '2.0',
        'id': 1,
        'result': null,
      });
      expect(response.isSuccess, isTrue);
      expect(response.result, isEmpty);
    });

    test('error codes map onto the framework hierarchy', () {
      JsonRpcError error(int code) =>
          JsonRpcError(code: code, message: 'because');
      AgenticException mapped(int code) =>
          error(code).toException(server: 's', method: 'tools/call');

      expect(
        mapped(JsonRpcErrorCode.methodNotFound),
        isA<CapabilityNotSupportedException>(),
      );
      expect(
        mapped(JsonRpcErrorCode.invalidParams),
        isA<ValidationException>(),
      );
      expect(
        mapped(JsonRpcErrorCode.parseError),
        isA<SerializationException>(),
      );
      expect(
        mapped(JsonRpcErrorCode.requestCancelled),
        isA<CancelledException>(),
      );
      expect(mapped(JsonRpcErrorCode.internalError), isA<ProviderException>());
    });

    test('cancellation never comes back retryable', () {
      final mapped = JsonRpcError(
        code: JsonRpcErrorCode.requestCancelled,
        message: 'user left',
      ).toException(server: 's');
      expect(mapped.isRetryable, isFalse);
    });

    test(
      'a server-defined code stays retryable rather than being guessed at',
      () {
        final mapped = JsonRpcError(
          code: -32050,
          message: 'upstream is busy',
        ).toException(server: 's', method: 'tools/call');
        expect(mapped, isA<ProviderException>());
        expect(mapped.isRetryable, isTrue);
      },
    );
  });

  group('capabilities', () {
    test('an empty object means supported, not unsupported', () {
      // The trap: `{}` is how the specification says "yes, with no
      // sub-features", and reading it as falsey disables every correct server.
      final capabilities = McpCapabilities.fromJson(<String, Object?>{
        'tools': <String, Object?>{},
        'resources': <String, Object?>{'subscribe': true},
      });

      expect(capabilities.tools, isTrue);
      expect(capabilities.resources, isTrue);
      expect(capabilities.resourceSubscribe, isTrue);
      expect(capabilities.toolListChanged, isFalse);
      expect(capabilities.prompts, isFalse);
    });

    test('keeps capabilities it does not understand', () {
      final capabilities = McpCapabilities.fromJson(<String, Object?>{
        'tools': <String, Object?>{},
        'timeTravel': <String, Object?>{'paradoxes': false},
      });
      expect(capabilities.extra.containsKey('timeTravel'), isTrue);
      expect(capabilities.toJson()['timeTravel'], isNotNull);
    });

    test('negotiation accepts a known revision and rejects an unknown one', () {
      expect(negotiateProtocolVersion('2024-11-05'), '2024-11-05');
      expect(negotiateProtocolVersion('1999-01-01'), isNull);
    });
  });

  group('content translation', () {
    test('text, images and embedded resources survive the round trip', () {
      final parts = contentPartsFromMcp(<Object?>[
        <String, Object?>{'type': 'text', 'text': 'hello'},
        <String, Object?>{
          'type': 'image',
          'data': base64Encode(<int>[1, 2, 3]),
          'mimeType': 'image/png',
        },
        <String, Object?>{
          'type': 'resource',
          'resource': <String, Object?>{
            'uri': 'file:///notes.txt',
            'text': 'inline contents',
          },
        },
      ]);

      expect(parts, hasLength(3));
      expect((parts[0] as TextPart).text, 'hello');
      expect((parts[1] as ImagePart).mimeType, 'image/png');
      expect((parts[2] as TextPart).text, 'inline contents');
    });

    test('an unknown block type is kept as text, not dropped', () {
      final parts = contentPartsFromMcp(<Object?>[
        <String, Object?>{'type': 'hologram', 'payload': 'something new'},
      ]);
      expect(parts, hasLength(1));
      expect((parts.single as TextPart).text, contains('hologram'));
    });

    test('malformed base64 costs its own block, not the whole result', () {
      final parts = contentPartsFromMcp(<Object?>[
        <String, Object?>{'type': 'text', 'text': 'kept'},
        <String, Object?>{
          'type': 'image',
          'data': 'not base64 !!!',
          'mimeType': 'image/png',
        },
      ]);
      expect(parts, hasLength(1));
      expect((parts.single as TextPart).text, 'kept');
    });

    test('rendering non-text blocks says what they were', () {
      final rendered = renderMcpContent(<Object?>[
        <String, Object?>{'type': 'text', 'text': 'Here it is:'},
        <String, Object?>{
          'type': 'image',
          'data': base64Encode(List<int>.filled(2048, 0)),
          'mimeType': 'image/png',
        },
      ]);
      expect(rendered, contains('Here it is:'));
      expect(rendered, contains('image/png'));
      expect(rendered, contains('KB'));
    });

    test('framework parts convert back to MCP blocks', () {
      expect(contentPartToMcp(const TextPart('hi')), <String, Object?>{
        'type': 'text',
        'text': 'hi',
      });
      expect(
        contentPartToMcp(
          ToolCallPart(
            id: 'c',
            name: 'x',
            arguments: const <String, Object?>{},
          ),
        ),
        isNull,
        reason: 'a tool call is an envelope concern in MCP, not content',
      );
    });
  });

  group('McpClient lifecycle', () {
    test('negotiates, announces readiness and reports the server', () async {
      final session = await connected();
      addTearDown(session.client.dispose);

      expect(session.client.isInitialized, isTrue);
      expect(session.client.session!.server.name, 'scripted');
      expect(session.client.session!.protocolVersion, kLatestProtocolVersion);
      expect(session.client.session!.instructions, contains('in order'));
      expect(
        session.server.notifications.single.method,
        McpMethod.initialized,
        reason: 'a server that never sees `initialized` may refuse everything',
      );
    });

    test('accepts a server that chose an older revision', () async {
      final (clientSide, serverSide) = InMemoryTransport.pair();
      ScriptedServer(serverSide).protocolVersion = '2024-11-05';
      final client = McpClient(transport: clientSide);
      addTearDown(client.dispose);

      final session = await client.initialize();
      expect(session.protocolVersion, '2024-11-05');
    });

    test('refuses a revision it cannot speak', () async {
      final (clientSide, serverSide) = InMemoryTransport.pair();
      ScriptedServer(serverSide).protocolVersion = '1999-01-01';
      final client = McpClient(transport: clientSide);
      addTearDown(client.dispose);

      await expectLater(
        client.initialize(),
        throwsA(
          isA<CapabilityNotSupportedException>().having(
            (e) => e.message,
            'message',
            contains('1999-01-01'),
          ),
        ),
      );
    });

    test('initialising twice is a no-op', () async {
      final session = await connected();
      addTearDown(session.client.dispose);

      await session.client.initialize();
      expect(
        session.server.requests.where((r) => r.method == McpMethod.initialize),
        hasLength(1),
      );
    });

    test('refuses to work before the session is open', () async {
      final (clientSide, _) = InMemoryTransport.pair();
      final client = McpClient(transport: clientSide);
      addTearDown(client.dispose);

      await expectLater(
        client.request(McpMethod.toolsList),
        throwsA(isA<InvalidStateException>()),
      );
    });

    test('publishes the session it opened', () async {
      final bus = BroadcastEventBus();
      final session = await connected(
        context: AgenticContext.root(
          events: bus,
          ids: SequentialIdGenerator(prefix: 'e'),
          clock: FakeClock(autoAdvance: true),
        ),
      );
      addTearDown(session.client.dispose);

      final event = bus.replayBuffer.whereType<McpSessionOpened>().single;
      expect(event.server, 'scripted');
      expect(event.protocolVersion, kLatestProtocolVersion);
      expect(event.capabilities, contains('tools'));
      await bus.dispose();
    });
  });

  group('McpClient calls', () {
    test('follows pagination to the end', () async {
      final session = await connected();
      addTearDown(session.client.dispose);

      var page = 0;
      session.server.handlers[McpMethod.toolsList] = (request) {
        final cursor = request.params?['cursor'];
        page++;
        return cursor == null
            ? <String, Object?>{
                'tools': <Object?>[toolDescriptor('one')],
                'nextCursor': 'page-2',
              }
            : <String, Object?>{
                'tools': <Object?>[toolDescriptor('two')],
              };
      };

      final tools = await session.client.listTools();
      expect(tools.map((t) => t.name), <String>['one', 'two']);
      expect(page, 2);
    });

    test('checks capabilities before making a pointless call', () async {
      final session = await connected(
        capabilities: <String, Object?>{'tools': <String, Object?>{}},
      );
      addTearDown(session.client.dispose);

      await expectLater(
        session.client.listPrompts(),
        throwsA(
          isA<CapabilityNotSupportedException>().having(
            (e) => e.capability,
            'capability',
            'prompts',
          ),
        ),
      );
      expect(
        session.server.requests.where((r) => r.method == McpMethod.promptsList),
        isEmpty,
      );
    });

    test('turns a JSON-RPC error into a framework exception', () async {
      final session = await connected();
      addTearDown(session.client.dispose);

      session.server.failures[McpMethod.toolsCall] = JsonRpcError(
        code: JsonRpcErrorCode.invalidParams,
        message: 'path must be absolute',
      );

      await expectLater(
        session.client.callTool('read_file'),
        throwsA(
          isA<ValidationException>().having(
            (e) => e.message,
            'message',
            contains('absolute'),
          ),
        ),
      );
    });

    test('times out rather than waiting forever', () async {
      final session = await connected(
        requestTimeout: const Duration(milliseconds: 50),
      );
      addTearDown(session.client.dispose);
      session.server.silent.add(McpMethod.toolsList);

      await expectLater(
        session.client.request(McpMethod.toolsList),
        throwsA(isA<AgenticTimeoutException>()),
      );
    });

    test('tells the server when the caller cancels', () async {
      final session = await connected();
      addTearDown(session.client.dispose);
      session.server
        ..silent.add(McpMethod.toolsCall)
        ..delay = const Duration(milliseconds: 10);

      final source = CancellationTokenSource();
      final context = AgenticContext.root(cancellation: source.token);

      final call = session.client.callTool('slow', context: context);
      await Future<void>.delayed(const Duration(milliseconds: 5));
      source.cancel('user left');

      await expectLater(call, throwsA(isA<CancelledException>()));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(
        session.server.notifications.map((n) => n.method),
        contains(McpMethod.cancelled),
        reason: 'a server left working on an abandoned call keeps burning time',
      );
    });

    test('a closed transport fails everything in flight', () async {
      final session = await connected();
      session.server.silent.add(McpMethod.toolsList);

      final pending = session.client.request(McpMethod.toolsList);
      // Listened to before the close, so the failure has somewhere to land.
      final expectation = expectLater(
        pending,
        throwsA(isA<ProviderException>()),
      );
      await session.server.transport.dispose();

      await expectation;
      await session.client.dispose();
    });

    test(
      'disposal fails what is in flight instead of leaving it hanging',
      () async {
        final session = await connected();
        session.server.silent.add(McpMethod.toolsList);

        final pending = session.client.request(McpMethod.toolsList);
        // Listened to before disposal, so the failure has somewhere to land.
        final expectation = expectLater(
          pending,
          throwsA(isA<InvalidStateException>()),
        );
        await session.client.dispose();

        await expectation;
      },
    );

    test('surfaces server notifications', () async {
      final session = await connected();
      addTearDown(session.client.dispose);

      final received = <String>[];
      session.client.notifications.listen((n) => received.add(n.method));
      await session.server.notify(McpMethod.toolListChanged);
      await Future<void>.delayed(Duration.zero);

      expect(received, <String>[McpMethod.toolListChanged]);
    });

    test('answers a server request through a handler', () async {
      final session = await connected();
      addTearDown(session.client.dispose);

      session.client.handle(
        McpMethod.rootsList,
        (request, context) async => <String, Object?>{
          'roots': <Object?>[
            <String, Object?>{'uri': 'file:///project', 'name': 'project'},
          ],
        },
      );

      final response = await session.server.ask(McpMethod.rootsList);
      expect(response.isSuccess, isTrue);
      expect(response.result!['roots'], hasLength(1));
    });

    test('answers method-not-found for a request it cannot handle', () async {
      final session = await connected();
      addTearDown(session.client.dispose);

      final response = await session.server.ask(
        McpMethod.samplingCreateMessage,
      );
      expect(response.isSuccess, isFalse);
      expect(response.error!.code, JsonRpcErrorCode.methodNotFound);
      expect(response.error!.message, contains('client.handle'));
    });

    test(
      'a throwing handler still answers, rather than hanging the server',
      () async {
        final session = await connected();
        addTearDown(session.client.dispose);

        session.client.handle(McpMethod.rootsList, (request, context) async {
          throw StateError('handler is broken');
        });

        final response = await session.server.ask(McpMethod.rootsList);
        expect(response.isSuccess, isFalse);
        expect(response.error!.code, JsonRpcErrorCode.internalError);
      },
    );
  });

  group('McpTool', () {
    Future<({McpClient client, ScriptedServer server, List<McpTool> tools})>
    withTools(List<JsonMap> descriptors) async {
      final session = await connected();
      session.server.handlers[McpMethod.toolsList] = (_) => <String, Object?>{
        'tools': descriptors,
      };
      final tools = await mcpTools(session.client);
      return (client: session.client, server: session.server, tools: tools);
    }

    test(
      'becomes a tool the rest of the framework already understands',
      () async {
        final fixture = await withTools(<JsonMap>[
          toolDescriptor(
            'read_file',
            description: 'Reads a file.',
            annotations: <String, Object?>{'readOnlyHint': true},
          ),
        ]);
        addTearDown(fixture.client.dispose);
        fixture.server.handlers[McpMethod.toolsCall] = (request) =>
            textResult('file contents for ${request.params!['arguments']}');

        final registry = ToolRegistry()..registerAll(fixture.tools);
        final executor = ToolExecutor(tools: registry.all);

        final result = await executor.execute(
          ToolCallPart(
            id: 'c1',
            name: 'read_file',
            arguments: const <String, Object?>{'path': '/tmp/a.txt'},
          ),
          context: AgenticContext.root(),
        );

        expect(result.isError, isFalse);
        expect(result.content, contains('file contents'));
        expect(result.metadata['mcpServer'], 'scripted');
      },
    );

    test('the executor validates against the server schema', () async {
      final fixture = await withTools(<JsonMap>[
        toolDescriptor(
          'read_file',
          annotations: <String, Object?>{'readOnlyHint': true},
        ),
      ]);
      addTearDown(fixture.client.dispose);

      final registry = ToolRegistry()..registerAll(fixture.tools);
      final executor = ToolExecutor(tools: registry.all);

      final result = await executor.execute(
        ToolCallPart(
          id: 'c1',
          name: 'read_file',
          arguments: const <String, Object?>{},
        ),
        context: AgenticContext.root(),
      );

      expect(result.isError, isTrue);
      expect(
        fixture.server.requests.where((r) => r.method == McpMethod.toolsCall),
        isEmpty,
        reason: 'invalid arguments must not reach the network',
      );
    });

    test(
      'a tool failure is a failure the model can see, not an exception',
      () async {
        final fixture = await withTools(<JsonMap>[toolDescriptor('read_file')]);
        addTearDown(fixture.client.dispose);
        fixture.server.handlers[McpMethod.toolsCall] = (_) =>
            textResult('No such file.', isError: true);

        final result = await fixture.tools.single.call(
          ToolInvocation(
            callId: 'c1',
            toolName: 'read_file',
            arguments: const <String, Object?>{'path': '/missing'},
            context: AgenticContext.root(),
          ),
        );

        expect(result.isError, isTrue);
        expect(result.content, 'No such file.');
      },
    );

    test('a transport failure becomes a failure, not a dead run', () async {
      final fixture = await withTools(<JsonMap>[toolDescriptor('read_file')]);
      addTearDown(fixture.client.dispose);
      fixture.server.failures[McpMethod.toolsCall] = JsonRpcError(
        code: JsonRpcErrorCode.internalError,
        message: 'the disk caught fire',
      );

      final result = await fixture.tools.single.call(
        ToolInvocation(
          callId: 'c1',
          toolName: 'read_file',
          arguments: const <String, Object?>{'path': '/a'},
          context: AgenticContext.root(),
        ),
      );

      expect(result.isError, isTrue);
      expect(result.content, contains('disk caught fire'));
      expect(result.metadata['retryable'], isTrue);
    });

    test('annotations tighten defaults and never loosen them', () async {
      final fixture = await withTools(<JsonMap>[
        toolDescriptor(
          'read_file',
          annotations: <String, Object?>{
            'readOnlyHint': true,
            'idempotentHint': true,
          },
        ),
        toolDescriptor(
          'delete_everything',
          annotations: <String, Object?>{'destructiveHint': true},
        ),
        toolDescriptor('unannotated'),
      ]);
      addTearDown(fixture.client.dispose);

      final read = fixture.tools[0].spec;
      expect(read.isReadOnly, isTrue);
      expect(read.requiresApproval, isFalse);

      final destroy = fixture.tools[1].spec;
      expect(destroy.requiresApproval, isTrue);

      final unknown = fixture.tools[2].spec;
      expect(
        unknown.isReadOnly,
        isFalse,
        reason: 'silence means "assume it writes"',
      );
      expect(unknown.isIdempotent, isFalse);
      expect(unknown.requiresApproval, isTrue);
    });

    test('a caller can demand approval the server did not ask for', () async {
      final session = await connected();
      addTearDown(session.client.dispose);
      session.server.handlers[McpMethod.toolsList] = (_) => <String, Object?>{
        'tools': <Object?>[
          toolDescriptor(
            'search',
            annotations: <String, Object?>{'readOnlyHint': true},
          ),
        ],
      };

      final tools = await mcpTools(
        session.client,
        approvalRequired: <String>{'search'},
      );
      expect(tools.single.spec.requiresApproval, isTrue);
    });

    test('prefixes and filters, so two servers can coexist', () async {
      final session = await connected();
      addTearDown(session.client.dispose);
      session.server.handlers[McpMethod.toolsList] = (_) => <String, Object?>{
        'tools': <Object?>[
          toolDescriptor('read_file'),
          toolDescriptor('write_file'),
          toolDescriptor('delete_file'),
        ],
      };

      final tools = await mcpTools(
        session.client,
        prefix: 'fs',
        exclude: <String>{'delete_file'},
      );

      expect(tools.map((t) => t.spec.name), <String>[
        'fs_read_file',
        'fs_write_file',
      ]);
      expect(
        tools.first.descriptor.name,
        'read_file',
        reason: 'the wire name is unchanged; only the local name is prefixed',
      );
    });

    test('a tool with no schema is callable with no arguments', () async {
      final session = await connected();
      addTearDown(session.client.dispose);
      session.server.handlers[McpMethod.toolsList] = (_) => <String, Object?>{
        'tools': <Object?>[
          <String, Object?>{'name': 'now', 'description': 'The time.'},
        ],
      };
      session.server.handlers[McpMethod.toolsCall] = (_) => textResult('12:00');

      final tools = await mcpTools(session.client);
      final result = await tools.single.call(
        ToolInvocation(
          callId: 'c1',
          toolName: 'now',
          context: AgenticContext.root(),
        ),
      );
      expect(result.content, '12:00');
    });

    test('says so when a tool returns nothing renderable', () async {
      final fixture = await withTools(<JsonMap>[toolDescriptor('snapshot')]);
      addTearDown(fixture.client.dispose);
      fixture.server.handlers[McpMethod.toolsCall] = (_) => <String, Object?>{
        'content': <Object?>[],
      };

      final result = await fixture.tools.single.call(
        ToolInvocation(
          callId: 'c1',
          toolName: 'snapshot',
          arguments: const <String, Object?>{'path': '/a'},
          context: AgenticContext.root(),
        ),
      );
      expect(result.content, contains('no content'));
    });

    test('publishes what was discovered and what was called', () async {
      final bus = BroadcastEventBus();
      final context = AgenticContext.root(
        events: bus,
        ids: SequentialIdGenerator(prefix: 'e'),
        clock: FakeClock(autoAdvance: true),
      );
      final session = await connected(context: context);
      addTearDown(session.client.dispose);
      session.server.handlers[McpMethod.toolsList] = (_) => <String, Object?>{
        'tools': <Object?>[toolDescriptor('read_file')],
      };
      session.server.handlers[McpMethod.toolsCall] = (_) => textResult('ok');

      final tools = await mcpTools(session.client, context: context);
      await tools.single.call(
        ToolInvocation(
          callId: 'c1',
          toolName: 'read_file',
          arguments: const <String, Object?>{'path': '/a'},
          context: context,
        ),
      );

      final discovered = bus.replayBuffer
          .whereType<McpToolsDiscovered>()
          .single;
      expect(discovered.names, <String>['read_file']);

      final called = bus.replayBuffer.whereType<McpToolCalled>().single;
      expect(called.tool, 'read_file');
      expect(called.failed, isFalse);
      await bus.dispose();
    });
  });

  group('resources and prompts', () {
    test('reads a resource', () async {
      final session = await connected(
        capabilities: <String, Object?>{'resources': <String, Object?>{}},
      );
      addTearDown(session.client.dispose);
      session.server.handlers[McpMethod.resourcesRead] = (_) =>
          <String, Object?>{
            'contents': <Object?>[
              <String, Object?>{
                'uri': 'file:///notes.txt',
                'mimeType': 'text/plain',
                'text': 'remember the milk',
              },
            ],
          };

      final contents = await session.client.readResource('file:///notes.txt');
      expect(contents.single.isText, isTrue);
      expect(contents.single.text, 'remember the milk');
    });

    test('renders a prompt into framework messages', () async {
      final session = await connected(
        capabilities: <String, Object?>{'prompts': <String, Object?>{}},
      );
      addTearDown(session.client.dispose);
      session.server.handlers[McpMethod.promptsGet] = (_) => <String, Object?>{
        'description': 'A code review.',
        'messages': <Object?>[
          <String, Object?>{
            'role': 'user',
            'content': <String, Object?>{
              'type': 'text',
              'text': 'Review this diff.',
            },
          },
          <String, Object?>{
            'role': 'assistant',
            'content': <String, Object?>{'type': 'text', 'text': 'Sure.'},
          },
        ],
      };

      final prompt = await session.client.getPrompt('review');
      expect(prompt.description, 'A code review.');
      expect(prompt.messages, hasLength(2));
      expect(prompt.messages.first.role, MessageRole.user);
      expect(prompt.messages.first.text, 'Review this diff.');
      expect(prompt.messages.last.role, MessageRole.assistant);
    });

    test('expands a resource template, encoding what it substitutes', () {
      const template = McpResourceTemplate(
        uriTemplate: 'file:///{path}',
        name: 'file',
      );
      expect(
        template.expand(<String, String>{'path': 'my notes.txt'}),
        'file:///my%20notes.txt',
      );
    });
  });

  group('McpServer', () {
    Future<({McpClient client, McpServer server, ToolRegistry registry})>
    served({
      bool publishApprovalRequired = false,
      ToolApprovalHandler? approvalHandler,
    }) async {
      final registry = ToolRegistry()
        ..register(
          FunctionTool.text(
            name: 'echo',
            description: 'Repeats what it is given.',
            parameters: JsonSchema.object(
              properties: <String, JsonSchema>{'text': JsonSchema.string()},
              required: const <String>{'text'},
            ),
            handler: (invocation) async => invocation.require<String>('text'),
          ),
        )
        ..register(
          FunctionTool.text(
            name: 'wipe_disk',
            description: 'Destroys everything.',
            isReadOnly: false,
            requiresApproval: true,
            handler: (invocation) async => 'gone',
          ),
        );

      final (clientSide, serverSide) = InMemoryTransport.pair();
      final server = McpServer(
        transport: serverSide,
        registry: registry,
        serverInfo: const McpImplementation(name: 'my-app', version: '2.0.0'),
        instructions: 'Echo things.',
        publishApprovalRequired: publishApprovalRequired,
        approvalHandler: approvalHandler,
      );
      await server.start();

      final client = McpClient(transport: clientSide);
      await client.initialize();
      await Future<void>.delayed(Duration.zero);
      return (client: client, server: server, registry: registry);
    }

    test('publishes a registry as tools a client can list and call', () async {
      final fixture = await served();
      addTearDown(fixture.client.dispose);
      addTearDown(fixture.server.dispose);

      final tools = await fixture.client.listTools();
      expect(tools.map((t) => t.name), <String>['echo']);
      expect(tools.single.description, 'Repeats what it is given.');

      final result = await fixture.client.callTool(
        'echo',
        arguments: const <String, Object?>{'text': 'hello there'},
      );
      expect(result.isError, isFalse);
      expect(result.text, 'hello there');
    });

    test('does not publish a tool that needs a person to approve it', () async {
      final fixture = await served();
      addTearDown(fixture.client.dispose);
      addTearDown(fixture.server.dispose);

      expect(
        (await fixture.client.listTools()).map((t) => t.name),
        isNot(contains('wipe_disk')),
      );
      await expectLater(
        fixture.client.callTool('wipe_disk'),
        throwsA(isA<CapabilityNotSupportedException>()),
        reason: 'unpublished means uncallable, not merely undocumented',
      );
    });

    test(
      'publishes gated tools only when told to, and still gates them',
      () async {
        var asked = 0;
        final fixture = await served(
          publishApprovalRequired: true,
          approvalHandler: (request) async {
            asked++;
            return false;
          },
        );
        addTearDown(fixture.client.dispose);
        addTearDown(fixture.server.dispose);

        expect(
          (await fixture.client.listTools()).map((t) => t.name),
          contains('wipe_disk'),
        );

        final result = await fixture.client.callTool('wipe_disk');
        expect(result.isError, isTrue);
        expect(asked, 1);
      },
    );

    test(
      'reports a tool failure in the result, not as a protocol error',
      () async {
        final fixture = await served();
        addTearDown(fixture.client.dispose);
        addTearDown(fixture.server.dispose);

        // Missing a required argument: the executor rejects it, and the client
        // must still get a result it can hand to a model.
        final result = await fixture.client.callTool('echo');
        expect(result.isError, isTrue);
        expect(result.text, isNotEmpty);
      },
    );

    test('announces itself and its capabilities', () async {
      final fixture = await served();
      addTearDown(fixture.client.dispose);
      addTearDown(fixture.server.dispose);

      final session = fixture.client.session!;
      expect(session.server.name, 'my-app');
      expect(session.server.version, '2.0.0');
      expect(session.capabilities.tools, isTrue);
      expect(session.capabilities.toolListChanged, isTrue);
      expect(session.instructions, 'Echo things.');
    });

    test('tells the client when its tool list changes', () async {
      final fixture = await served();
      addTearDown(fixture.client.dispose);
      addTearDown(fixture.server.dispose);

      final seen = <String>[];
      fixture.client.notifications.listen((n) => seen.add(n.method));

      fixture.registry.register(
        FunctionTool.text(
          name: 'reverse',
          description: 'Reverses text.',
          handler: (invocation) async => 'txet',
        ),
      );
      await fixture.server.notifyToolsChanged();
      await Future<void>.delayed(Duration.zero);

      expect(seen, contains(McpMethod.toolListChanged));
      expect(
        (await fixture.client.listTools()).map((t) => t.name),
        contains('reverse'),
      );
    });

    test('refuses a method it does not implement, without dying', () async {
      final fixture = await served();
      addTearDown(fixture.client.dispose);
      addTearDown(fixture.server.dispose);

      await expectLater(
        fixture.client.request('telepathy/read'),
        throwsA(isA<CapabilityNotSupportedException>()),
      );
      // Still alive.
      await fixture.client.ping();
    });

    test('serves resources when given a reader', () async {
      final (clientSide, serverSide) = InMemoryTransport.pair();
      final server = McpServer(
        transport: serverSide,
        registry: ToolRegistry(),
        resourceProvider: (_) async => <JsonMap>[
          <String, Object?>{'uri': 'app://config', 'name': 'config'},
        ],
        resourceReader: (uri, _) async => uri == 'app://config'
            ? <JsonMap>[
                <String, Object?>{'uri': uri, 'text': '{"theme":"dark"}'},
              ]
            : null,
      );
      await server.start();
      addTearDown(server.dispose);

      final client = McpClient(transport: clientSide);
      addTearDown(client.dispose);
      await client.initialize();

      expect(client.session!.capabilities.resources, isTrue);
      expect((await client.listResources()).single.uri, 'app://config');
      expect(
        (await client.readResource('app://config')).single.text,
        contains('dark'),
      );
      await expectLater(
        client.readResource('app://missing'),
        throwsA(isA<CapabilityNotSupportedException>()),
      );
    });

    test('round-trips through the client it was written against', () async {
      // The end-to-end shape this package exists for: an application's tools,
      // published over MCP, consumed by an agent as ordinary tools.
      final fixture = await served();
      addTearDown(fixture.client.dispose);
      addTearDown(fixture.server.dispose);

      final registry = ToolRegistry()
        ..registerAll(await mcpTools(fixture.client, prefix: 'remote'));
      final executor = ToolExecutor(tools: registry.all);

      final result = await executor.execute(
        ToolCallPart(
          id: 'c1',
          name: 'remote_echo',
          arguments: const <String, Object?>{'text': 'through the wire'},
        ),
        context: AgenticContext.root(),
      );

      expect(result.isError, isFalse);
      expect(result.content, 'through the wire');
    });
  });

  group('McpHttpTransport', () {
    test('posts JSON-RPC and reads a JSON answer', () async {
      final requests = <http.Request>[];
      final transport = McpHttpTransport(
        endpoint: Uri.parse('https://mcp.test/mcp'),
        headers: const <String, String>{'authorization': 'Bearer secret'},
        listenForServerMessages: false,
        client: MockClient((request) async {
          requests.add(request);
          return http.Response(
            jsonEncode(<String, Object?>{
              'jsonrpc': '2.0',
              'id': 1,
              'result': <String, Object?>{
                'protocolVersion': kLatestProtocolVersion,
                'capabilities': <String, Object?>{'tools': <String, Object?>{}},
                'serverInfo': <String, Object?>{
                  'name': 'remote',
                  'version': '1.0.0',
                },
              },
            }),
            200,
            headers: <String, String>{
              'content-type': 'application/json',
              kSessionIdHeader: 'session-42',
            },
          );
        }),
      );

      final client = McpClient(transport: transport);
      addTearDown(client.dispose);
      final session = await client.initialize();

      expect(session.server.name, 'remote');
      expect(transport.sessionId, 'session-42');
      expect(requests.first.headers['authorization'], 'Bearer secret');
      expect(
        requests.first.headers['accept'],
        contains('text/event-stream'),
        reason:
            'a server may answer either way and the client must accept both',
      );
      // The session id and negotiated revision are echoed from then on.
      expect(requests.last.headers[kSessionIdHeader], 'session-42');
      expect(
        requests.last.headers[kProtocolVersionHeader],
        kLatestProtocolVersion,
      );
    });

    test('reads an answer delivered as server-sent events', () async {
      final transport = McpHttpTransport(
        endpoint: Uri.parse('https://mcp.test/mcp'),
        listenForServerMessages: false,
        client: MockClient((request) async {
          final body = jsonDecode(request.body) as JsonMap;
          final payload = jsonEncode(<String, Object?>{
            'jsonrpc': '2.0',
            'id': body['id'],
            'result': <String, Object?>{
              'protocolVersion': kLatestProtocolVersion,
              'capabilities': <String, Object?>{'tools': <String, Object?>{}},
              'serverInfo': <String, Object?>{
                'name': 'streamed',
                'version': '1.0.0',
              },
            },
          });
          return http.Response(
            'event: message\ndata: $payload\n\n',
            200,
            headers: <String, String>{'content-type': 'text/event-stream'},
          );
        }),
      );

      final client = McpClient(transport: transport);
      addTearDown(client.dispose);
      expect((await client.initialize()).server.name, 'streamed');
    });

    test('maps an HTTP failure onto the framework hierarchy', () async {
      final transport = McpHttpTransport(
        endpoint: Uri.parse('https://mcp.test/mcp'),
        listenForServerMessages: false,
        client: MockClient((_) async => http.Response('{"error":"nope"}', 401)),
      );
      final client = McpClient(transport: transport);
      addTearDown(client.dispose);

      await expectLater(
        client.initialize(),
        throwsA(isA<AuthenticationException>()),
      );
    });

    test('a batched payload is delivered as separate messages', () async {
      final transport = McpHttpTransport(
        endpoint: Uri.parse('https://mcp.test/mcp'),
        listenForServerMessages: false,
        client: MockClient(
          (_) async => http.Response(
            jsonEncode(<Object?>[
              <String, Object?>{
                'jsonrpc': '2.0',
                'method': 'notifications/message',
              },
              <String, Object?>{
                'jsonrpc': '2.0',
                'id': 1,
                'result': <String, Object?>{
                  'protocolVersion': kLatestProtocolVersion,
                  'capabilities': <String, Object?>{},
                  'serverInfo': <String, Object?>{
                    'name': 'batched',
                    'version': '1.0.0',
                  },
                },
              },
            ]),
            200,
            headers: <String, String>{'content-type': 'application/json'},
          ),
        ),
      );

      final client = McpClient(transport: transport);
      addTearDown(client.dispose);
      expect((await client.initialize()).server.name, 'batched');
    });

    test('a disposed transport refuses to send', () async {
      final transport = McpHttpTransport(
        endpoint: Uri.parse('https://mcp.test/mcp'),
        listenForServerMessages: false,
        client: MockClient((_) async => http.Response('{}', 200)),
      );
      await transport.dispose();

      await expectLater(
        transport.send(const <String, Object?>{}),
        throwsA(isA<InvalidStateException>()),
      );
    });
  });

  group('InMemoryTransport', () {
    test('delivers what the peer sends', () async {
      final (a, b) = InMemoryTransport.pair();
      addTearDown(a.dispose);
      addTearDown(b.dispose);

      final received = <JsonMap>[];
      b.incoming.listen(received.add);
      await a.send(<String, Object?>{'hello': 'world'});
      await Future<void>.delayed(Duration.zero);

      expect(received.single, <String, Object?>{'hello': 'world'});
    });

    test('says so when the peer is gone', () async {
      final (a, b) = InMemoryTransport.pair();
      await b.dispose();

      await expectLater(
        a.send(const <String, Object?>{}),
        throwsA(isA<InvalidStateException>()),
      );
      await a.dispose();
    });
  });
}
