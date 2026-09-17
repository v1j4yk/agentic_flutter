// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'order_tools.dart';

// **************************************************************************
// AgentToolGenerator
// **************************************************************************

// ignore_for_file: type=lint

/// The `order_status` tool, generated from [orderStatus].
final FunctionTool orderStatusTool = FunctionTool(
  name: 'order_status',
  description:
      'Looks up where an order is.\n\nReturns the carrier and the last scan.',
  parameters: JsonSchema.object(
    properties: <String, JsonSchema>{
      'order': JsonSchema.string(
        description: 'The order number, such as 1042.',
      ),
    },
    required: <String>{'order'},
  ),
  isReadOnly: true,
  isIdempotent: true,
  handler: (invocation) async {
    return ToolResult.success(
      (await orderStatus((invocation.arguments['order'] as String))),
    );
  },
);

/// The `find_orders` tool, generated from [searchOrders].
final FunctionTool searchOrdersTool = FunctionTool(
  name: 'find_orders',
  description: 'Finds orders matching every filter given.',
  parameters: JsonSchema.object(
    properties: <String, JsonSchema>{
      'customer': JsonSchema.string(),
      'limit': JsonSchema.integer(
        description: 'Most results to return.',
        defaultValue: 10,
      ),
      'minTotal': JsonSchema.number(defaultValue: 0.0),
      'includeCancelled': JsonSchema.boolean(defaultValue: false),
      'carrier': JsonSchema.enumeration(<String>['ups', 'fedex', 'dhl']),
      'carriers': JsonSchema.array(
        items: JsonSchema.enumeration(<String>['ups', 'fedex', 'dhl']),
      ),
      'ids': JsonSchema.array(items: JsonSchema.integer()),
      'placedAfter': JsonSchema.string(format: 'date-time'),
      'extra': JsonSchema.anyObject(),
      'sort': JsonSchema.string(defaultValue: 'newest'),
    },
    required: <String>{'customer'},
  ),
  isReadOnly: true,
  isIdempotent: true,
  returnsUntrustedContent: true,
  tags: <String>{'orders', 'search'},
  timeout: const Duration(microseconds: 5000000),
  handler: (invocation) async {
    return ToolResult.json(<String, Object?>{
      'items': searchOrders(
        (invocation.arguments['customer'] as String),
        limit: (invocation.arguments['limit'] == null
            ? 10
            : (invocation.arguments['limit'] as num).toInt()),
        minTotal: (invocation.arguments['minTotal'] == null
            ? 0.0
            : (invocation.arguments['minTotal'] as num).toDouble()),
        includeCancelled: (invocation.arguments['includeCancelled'] == null
            ? false
            : (invocation.arguments['includeCancelled'] as bool)),
        carrier: (invocation.arguments['carrier'] == null
            ? null
            : Carrier.values.byName(invocation.arguments['carrier'] as String)),
        carriers: (invocation.arguments['carriers'] == null
            ? const []
            : <Carrier>[
                for (final item
                    in invocation.arguments['carriers'] as List<Object?>)
                  Carrier.values.byName(item as String),
              ]),
        ids: (invocation.arguments['ids'] == null
            ? const []
            : <int>[
                for (final item in invocation.arguments['ids'] as List<Object?>)
                  (item as num).toInt(),
              ]),
        placedAfter: (invocation.arguments['placedAfter'] == null
            ? null
            : DateTime.parse(invocation.arguments['placedAfter'] as String)),
        extra: (invocation.arguments['extra'] == null
            ? null
            : (invocation.arguments['extra'] as Map<String, Object?>)),
        sort: (invocation.arguments['sort'] == null
            ? 'newest'
            : (invocation.arguments['sort'] as String)),
        context: invocation.context,
      ),
    });
  },
);

/// The `order_total` tool, generated from [orderTotal].
final FunctionTool orderTotalTool = FunctionTool(
  name: 'order_total',
  description: 'Gives the order total, in cents.',
  parameters: JsonSchema.object(
    properties: <String, JsonSchema>{
      'order': JsonSchema.string(),
      'discount': JsonSchema.number(defaultValue: 0.0),
    },
    required: <String>{'order'},
  ),
  isReadOnly: true,
  isIdempotent: true,
  handler: (invocation) async {
    return ToolResult.success(
      '${orderTotal((invocation.arguments['order'] as String), (invocation.arguments['discount'] == null ? 0 : (invocation.arguments['discount'] as num)))}',
    );
  },
);

/// The `load_order` tool, generated from [loadOrder].
final FunctionTool loadOrderTool = FunctionTool(
  name: 'load_order',
  description: 'Loads an order.',
  parameters: JsonSchema.object(
    properties: <String, JsonSchema>{'order': JsonSchema.string()},
    required: <String>{'order'},
  ),
  isReadOnly: true,
  isIdempotent: true,
  handler: (invocation) async {
    return ToolResult.json(
      loadOrder((invocation.arguments['order'] as String)).toJson(),
    );
  },
);

/// The `check_order` tool, generated from [checkOrder].
final FunctionTool checkOrderTool = FunctionTool(
  name: 'check_order',
  description: 'Returns a raw result, marking failures itself.',
  parameters: JsonSchema.object(
    properties: <String, JsonSchema>{'order': JsonSchema.string()},
    required: <String>{'order'},
  ),
  isReadOnly: true,
  isIdempotent: true,
  handler: (invocation) async {
    return checkOrder((invocation.arguments['order'] as String), invocation);
  },
);

/// The `@ToolFunction` methods of [OrderDesk], as tools.
extension OrderDeskAgentTools on OrderDesk {
  /// Every `@ToolFunction` method, bound to this instance.
  ///
  /// Builds new tools on each read; read it once and register
  /// the result.
  List<FunctionTool> get agentTools => <FunctionTool>[
    FunctionTool(
      name: 'cancel_order',
      description: 'Cancels an order. Cannot be undone.',
      parameters: JsonSchema.object(
        properties: <String, JsonSchema>{
          'order': JsonSchema.string(),
          'reason': JsonSchema.string(),
        },
        required: <String>{'order'},
      ),
      isReadOnly: false,
      isIdempotent: false,
      requiresApproval: true,
      handler: (invocation) async {
        (await this.cancelOrder(
          (invocation.arguments['order'] as String),
          reason: (invocation.arguments['reason'] == null
              ? null
              : (invocation.arguments['reason'] as String)),
        ));
        return ToolResult.success('Done.');
      },
    ),
    FunctionTool(
      name: 'cancellation_count',
      description: 'Counts cancelled orders.',
      parameters: JsonSchema.object(
        properties: <String, JsonSchema>{},
        required: <String>{},
      ),
      isReadOnly: true,
      isIdempotent: true,
      handler: (invocation) async {
        return ToolResult.json(this.cancellationCount());
      },
    ),
    FunctionTool(
      name: 'desk_name',
      description: 'Says which desk this is.',
      parameters: JsonSchema.object(
        properties: <String, JsonSchema>{},
        required: <String>{},
      ),
      isReadOnly: true,
      isIdempotent: true,
      handler: (invocation) async {
        return ToolResult.success(OrderDesk.deskName());
      },
    ),
    FunctionTool(
      name: 'recent_cancellations',
      description: 'Lists recently cancelled orders.',
      parameters: JsonSchema.object(
        properties: <String, JsonSchema>{
          'limit': JsonSchema.integer(defaultValue: 3),
        },
        required: <String>{},
      ),
      isReadOnly: true,
      isIdempotent: true,
      handler: (invocation) async {
        return ToolResult.success(
          this.recentCancellations(
            limit: (invocation.arguments['limit'] == null
                ? 3
                : (invocation.arguments['limit'] as num).toInt()),
          ),
        );
      },
    ),
  ];
}
