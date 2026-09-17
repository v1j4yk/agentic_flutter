// Every shape the generator supports, compiled and exercised by
// generated_tools_test.dart. Regenerate with:
//
//   dart run build_runner build --delete-conflicting-outputs
import 'package:agentic_core/agentic_core.dart';
import 'package:agentic_tools/agentic_tools.dart';

part 'order_tools.g.dart';

enum Carrier { ups, fedex, dhl }

final class Order {
  Order(this.id, this.status);

  final String id;
  final String status;

  Map<String, Object?> toJson() => {'id': id, 'status': status};
}

/// Looks up where an order is.
///
/// Returns the carrier and the last scan.
@ToolFunction(isReadOnly: true)
Future<String> orderStatus(
  @ToolParam('The order number, such as 1042.') String order,
) async => 'Order $order: shipped.';

@ToolFunction(
  name: 'find_orders',
  description: 'Finds orders matching every filter given.',
  isReadOnly: true,
  returnsUntrustedContent: true,
  tags: {'orders', 'search'},
  timeout: Duration(seconds: 5),
)
List<String> searchOrders(
  String customer, {
  @ToolParam('Most results to return.') int limit = 10,
  double minTotal = 0,
  bool includeCancelled = false,
  Carrier? carrier,
  List<Carrier> carriers = const [],
  List<int> ids = const [],
  DateTime? placedAfter,
  Map<String, Object?>? extra,
  String sort = 'newest',
  AgenticContext? context,
}) => [
  'customer=$customer',
  'limit=$limit',
  'minTotal=$minTotal',
  'includeCancelled=$includeCancelled',
  'carrier=${carrier?.name}',
  'carriers=${carriers.map((c) => c.name).join('+')}',
  'ids=${ids.join('+')}',
  'placedAfter=${placedAfter?.toUtc().toIso8601String()}',
  'extra=$extra',
  'sort=$sort',
  'context=${context != null}',
];

/// Gives the order total, in cents.
@ToolFunction(isReadOnly: true)
int orderTotal(String order, [num discount = 0]) => 1000 - discount.toInt();

/// Loads an order.
@ToolFunction(isReadOnly: true)
Order loadOrder(String order) => Order(order, 'shipped');

/// Returns a raw result, marking failures itself.
@ToolFunction(isReadOnly: true)
ToolResult checkOrder(String order, ToolInvocation invocation) =>
    order == 'missing'
    ? ToolResult.failure('No order $order.')
    : ToolResult.success('Order $order exists (call ${invocation.callId}).');

/// Tools that need the instance's state.
final class OrderDesk {
  OrderDesk(this.cancelled);

  final List<String> cancelled;

  /// Cancels an order. Cannot be undone.
  @ToolFunction(isReadOnly: false, requiresApproval: true)
  Future<void> cancelOrder(String order, {String? reason}) async {
    cancelled.add('$order:${reason ?? 'none'}');
  }

  /// Counts cancelled orders.
  @ToolFunction(isReadOnly: true, isIdempotent: true)
  Map<String, Object?> cancellationCount() => {'count': cancelled.length};

  /// Says which desk this is.
  @ToolFunction(isReadOnly: true)
  static String deskName() => 'returns';

  static const int _recentLimit = 3;

  /// Lists recently cancelled orders.
  @ToolFunction(isReadOnly: true)
  String recentCancellations({int limit = _recentLimit}) =>
      cancelled.take(limit).join(', ');

  // Not annotated: not a tool.
  String helper() => 'x';
}

/// Shares a name with an [OrderDesk] method. The generated extension must
/// still call the method.
Map<String, Object?> cancellationCount() => {'count': -1};
