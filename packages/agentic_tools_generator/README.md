# agentic_tools_generator

Write a Dart function, get a tool. Part of the
[agentic framework](https://github.com/v1j4yk/agentic_flutter).

A hand-written `FunctionTool` repeats every parameter three times: once in the
JSON schema, once reading it back out of the arguments, and once calling your
code. They drift apart. A renamed parameter or a changed type becomes a tool
call that fails at runtime, in front of a user. This generator writes those
three from the function signature, and anything a model can't use fails the
build instead.

```yaml
dependencies:
  agentic_tools: ^0.2.0
  agentic_core: ^0.2.0

dev_dependencies:
  build_runner: ^2.16.1
  agentic_tools_generator: ^0.2.0
```

## A function

```dart
import 'package:agentic_core/agentic_core.dart';
import 'package:agentic_tools/agentic_tools.dart';

part 'order_tools.g.dart';

enum Carrier { ups, fedex, dhl }

/// Finds a customer's orders, newest first.
@ToolFunction(isReadOnly: true)
Future<List<String>> findOrders(
  @ToolParam('The customer email address.') String customer, {
  @ToolParam('Most results to return.') int limit = 10,
  Carrier? carrier,
  DateTime? placedAfter,
}) => orders.search(customer, limit: limit, carrier: carrier, after: placedAfter);
```

```sh
dart run build_runner build
```

This generates `final FunctionTool findOrdersTool`, named `find_orders`, with
this schema:

```json
{
  "type": "object",
  "properties": {
    "customer": {"type": "string", "description": "The customer email address."},
    "limit": {"type": "integer", "description": "Most results to return.", "default": 10},
    "carrier": {"type": "string", "enum": ["ups", "fedex", "dhl"]},
    "placedAfter": {"type": "string", "format": "date-time"}
  },
  "required": ["customer"]
}
```

## Methods that need dependencies

Most real tools need a repository, a client or a user session. Annotate
methods on a class, and the generator adds an `agentTools` getter that binds
them to an instance:

```dart
final class OrderDesk {
  OrderDesk(this.orders);

  final OrderRepository orders;

  /// Cancels an order. Cannot be undone.
  @ToolFunction(isReadOnly: false, requiresApproval: true)
  Future<void> cancelOrder(String order, {String? reason}) =>
      orders.cancel(order, reason: reason);

  /// Where an order is.
  @ToolFunction(isReadOnly: true)
  Future<String> orderStatus(String order) => orders.status(order);
}

final registry = ToolRegistry()..registerAll(OrderDesk(repository).agentTools);
```

## What maps to what

| Parameter type | Schema |
|---|---|
| `String`, `int`, `double`, `num`, `bool` | `string`, `integer`, `number`, `boolean` |
| An enum | `string` with an `enum` of the value names |
| `DateTime` | `string` with `format: date-time` |
| `List<T>` of any of the above | `array` |
| `Map<String, Object?>` | `object` |
| `T?`, or a parameter with a default | Optional. The default is included in the schema |
| `ToolInvocation`, `AgenticContext`, `CancellationToken` | Supplied by the framework, not by the model |

| Return type | The model reads |
|---|---|
| `String` | The text |
| `ToolResult` | Exactly what you return, including failures |
| `Map<String, Object?>`, or a class with `toJson()` | JSON |
| `List`, `num`, `bool` | JSON or text |
| `void` | "Done." |

`Future` and `FutureOr` versions of each work too.

## Checked at build time

Each of these fails `build_runner` with a message pointing at the source line:

- a parameter or return type with no JSON form, such as `Duration` or
  `Stream<String>`
- a nullable return, because a model needs to be told when nothing was found
- no doc comment and no `description:`, because models choose tools by their
  descriptions
- two tools with the same name, or a name providers reject
- private or generic functions, and generic classes
- a library that doesn't import `agentic_core` and `agentic_tools`

`isReadOnly` is required. It decides whether a person must approve a call after
the agent has read untrusted content. If "read-only" were the default, a
forgotten flag on a delete function would silently remove that check.

## Descriptions

The function's doc comment becomes the tool description, and
`@ToolParam('...')` describes a parameter. Write both for the model. Say what
the tool is for, when not to use it, and the units and formats of its
arguments. That text is all the model has to decide with.
