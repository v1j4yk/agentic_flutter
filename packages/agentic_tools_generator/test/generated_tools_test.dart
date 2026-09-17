import 'dart:convert';

import 'package:agentic_core/agentic_core.dart';
import 'package:agentic_tools/agentic_tools.dart';
import 'package:test/test.dart';

import 'fixtures/order_tools.dart';

/// Runs [tool] the way an agent does: JSON arguments, through the executor,
/// so schema validation and coercion apply before the generated code reads
/// anything.
Future<ToolResult> run(
  Tool tool,
  String argumentsJson, {
  ToolApprovalHandler? approve,
}) {
  final executor = ToolExecutor(
    tools: (ToolRegistry()..register(tool)).all,
    approvalHandler: approve,
  );
  return executor.execute(
    ToolCallPart(
      id: 'call_1',
      name: tool.spec.name,
      arguments: (jsonDecode(argumentsJson) as Map).cast<String, Object?>(),
    ),
    context: AgenticContext.root(),
  );
}

List<String> items(ToolResult result) =>
    ((result.data! as Map)['items']! as List).cast<String>();

void main() {
  group('spec', () {
    test('name and description come from the function and its doc comment', () {
      final spec = orderStatusTool.spec;
      expect(spec.name, 'order_status');
      expect(
        spec.description,
        'Looks up where an order is.\n\nReturns the carrier and the last scan.',
      );
      expect(spec.isReadOnly, isTrue);
      expect(spec.isIdempotent, isTrue);
    });

    test('annotation fields override and extend the defaults', () {
      final spec = searchOrdersTool.spec;
      expect(spec.name, 'find_orders');
      expect(spec.description, 'Finds orders matching every filter given.');
      expect(spec.returnsUntrustedContent, isTrue);
      expect(spec.tags, {'orders', 'search'});
      expect(spec.timeout, const Duration(seconds: 5));
    });

    test('the schema follows the parameter list', () {
      final schema = searchOrdersTool.spec.parameters.toJson();
      final properties = schema['properties']! as Map<String, Object?>;

      expect(schema['required'], ['customer']);
      expect(properties['customer'], {'type': 'string'});
      expect(properties['limit'], {
        'type': 'integer',
        'description': 'Most results to return.',
        'default': 10,
      });
      expect(properties['minTotal'], {'type': 'number', 'default': 0.0});
      expect(properties['includeCancelled'], {
        'type': 'boolean',
        'default': false,
      });
      expect(properties['carrier'], {
        'type': 'string',
        'enum': ['ups', 'fedex', 'dhl'],
      });
      expect((properties['carriers']! as Map)['type'], 'array');
      expect((properties['ids']! as Map)['items'], {'type': 'integer'});
      expect(properties['placedAfter'], {
        'type': 'string',
        'format': 'date-time',
      });
      expect((properties['extra']! as Map)['type'], 'object');
      // Injected parameters are the framework's business, not the model's.
      expect(properties, isNot(contains('context')));
    });

    test('an injected ToolInvocation is not in the schema', () {
      final properties =
          checkOrderTool.spec.parameters.toJson()['properties']! as Map;
      expect(properties.keys, ['order']);
    });

    test('isIdempotent defaults to isReadOnly, and state-changing tools say '
        'so', () {
      final tools = OrderDesk([]).agentTools;
      final cancel = tools.firstWhere((t) => t.spec.name == 'cancel_order');
      expect(cancel.spec.isReadOnly, isFalse);
      expect(cancel.spec.isIdempotent, isFalse);
      expect(cancel.spec.requiresApproval, isTrue);
    });
  });

  group('arguments', () {
    test('a required argument is passed through', () async {
      final result = await run(orderStatusTool, '{"order": "1042"}');
      expect(result.isError, isFalse);
      expect(result.content, 'Order 1042: shipped.');
    });

    test('omitted optional arguments take the Dart defaults', () async {
      final result = await run(searchOrdersTool, '{"customer": "ada"}');
      expect(items(result), [
        'customer=ada',
        'limit=10',
        'minTotal=0.0',
        'includeCancelled=false',
        'carrier=null',
        'carriers=',
        'ids=',
        'placedAfter=null',
        'extra=null',
        'sort=newest',
        'context=true',
      ]);
    });

    test('every supported type is converted from JSON', () async {
      final result = await run(searchOrdersTool, '''
        {
          "customer": "ada",
          "limit": 3,
          "minTotal": 25,
          "includeCancelled": true,
          "carrier": "dhl",
          "carriers": ["ups", "fedex"],
          "ids": [7, 8.0],
          "placedAfter": "2026-09-01T10:00:00Z",
          "extra": {"vip": true},
          "sort": "oldest"
        }
      ''');
      expect(result.isError, isFalse, reason: result.content);
      expect(items(result), [
        'customer=ada',
        'limit=3',
        // JSON 25 decodes as an int; the double parameter still receives it.
        'minTotal=25.0',
        'includeCancelled=true',
        'carrier=dhl',
        'carriers=ups+fedex',
        'ids=7+8',
        'placedAfter=2026-09-01T10:00:00.000Z',
        'extra={vip: true}',
        'sort=oldest',
        'context=true',
      ]);
    });

    test('an explicit null is treated as omitted', () async {
      final result = await run(
        searchOrdersTool,
        '{"customer": "ada", "limit": null, "carrier": null}',
      );
      expect(items(result), contains('limit=10'));
      expect(items(result), contains('carrier=null'));
    });

    test('an optional positional parameter works', () async {
      expect((await run(orderTotalTool, '{"order": "1"}')).content, '1000');
      expect(
        (await run(orderTotalTool, '{"order": "1", "discount": 250}')).content,
        '750',
      );
    });

    test('a missing required argument is rejected before the function '
        'runs', () async {
      final result = await run(orderStatusTool, '{}');
      expect(result.isError, isTrue);
      expect(result.content, contains('order'));
    });

    test('an unknown enum value is rejected by the schema', () async {
      final result = await run(
        searchOrdersTool,
        '{"customer": "ada", "carrier": "pigeon"}',
      );
      expect(result.isError, isTrue);
    });

    test(
      'a default that names a private static constant still applies',
      () async {
        final desk = OrderDesk(['a', 'b', 'c', 'd', 'e']);
        final recent = desk.agentTools.firstWhere(
          (t) => t.spec.name == 'recent_cancellations',
        );
        expect((await run(recent, '{}')).content, 'a, b, c');
        expect((await run(recent, '{"limit": 1}')).content, 'a');
      },
    );
  });

  group('results', () {
    test('a List becomes JSON items', () async {
      final result = await run(searchOrdersTool, '{"customer": "ada"}');
      expect(result.data, isA<Map<String, Object?>>());
      expect(items(result).first, 'customer=ada');
    });

    test('a class with toJson becomes JSON', () async {
      final result = await run(loadOrderTool, '{"order": "9"}');
      expect(result.data, {'id': '9', 'status': 'shipped'});
    });

    test('a ToolResult is returned as is, including failures', () async {
      final ok = await run(checkOrderTool, '{"order": "9"}');
      expect(ok.content, 'Order 9 exists (call call_1).');

      final missing = await run(checkOrderTool, '{"order": "missing"}');
      expect(missing.isError, isTrue);
      expect(missing.content, 'No order missing.');
    });

    test('void confirms, and the side effect happens', () async {
      final cancelled = <String>[];
      final desk = OrderDesk(cancelled);
      final cancel = desk.agentTools.firstWhere(
        (t) => t.spec.name == 'cancel_order',
      );

      final result = await run(
        cancel,
        '{"order": "1042", "reason": "broken"}',
        approve: (_) async => true,
      );
      expect(result.isError, isFalse, reason: result.content);
      expect(result.content, 'Done.');
      expect(cancelled, ['1042:broken']);
    });

    test('requiresApproval is enforced on generated tools', () async {
      final cancelled = <String>[];
      final cancel = OrderDesk(
        cancelled,
      ).agentTools.firstWhere((t) => t.spec.name == 'cancel_order');
      final result = await run(
        cancel,
        '{"order": "1042"}',
        approve: (_) async => false,
      );
      expect(result.isError, isTrue);
      expect(cancelled, isEmpty);
    });
  });

  group('classes', () {
    test('instance tools use the instance, and static ones work too', () async {
      final desk = OrderDesk(['1', '2']);
      final tools = {for (final t in desk.agentTools) t.spec.name: t};

      expect(tools.keys, {
        'cancel_order',
        'cancellation_count',
        'desk_name',
        'recent_cancellations',
      });
      expect(
        (await run(tools['cancellation_count']!, '{}')).data,
        {'count': 2},
        reason:
            'must call the method, not the top-level function of the same '
            'name',
      );
      expect((await run(tools['desk_name']!, '{}')).content, 'returns');
    });

    test('unannotated methods are not tools', () {
      expect(
        OrderDesk([]).agentTools.map((t) => t.spec.name),
        isNot(contains('helper')),
      );
    });
  });
}
