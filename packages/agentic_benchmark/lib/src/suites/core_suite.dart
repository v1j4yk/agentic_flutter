/// What every other layer pays for on every call.
///
/// Nothing here does I/O, so these numbers are pure CPU and are the floor under
/// everything else. A schema validation that costs 40 µs is 40 µs on every tool
/// call in the framework; the same regression in a provider adapter would be
/// lost in the network time.
library;

import 'package:agentic_benchmark/src/harness.dart';
import 'package:agentic_core/agentic_core.dart';

BenchmarkSuite coreSuite() => BenchmarkSuite(
  name: 'core',
  benchmarks: <Benchmark<Object?>>[
    Benchmark<JsonSchema>(
      name: 'core.schema.validate.valid',
      description:
          'Validating a nested object that conforms. The happy path, paid on '
          'every tool call the framework makes.',
      setup: _invoiceSchema,
      run: (schema) => schema.validate(_validInvoice),
      iterations: 2000,
      warmup: 200,
    ),
    Benchmark<JsonSchema>(
      name: 'core.schema.validate.invalid',
      description:
          'Validating an object with four violations. Every violation is '
          'collected rather than short-circuiting, which is the point and also '
          'the cost.',
      setup: _invoiceSchema,
      run: (schema) => schema.validate(_invalidInvoice),
      iterations: 2000,
      warmup: 200,
    ),
    Benchmark<JsonSchema>(
      name: 'core.schema.coerce',
      description:
          'Repairing the near-miss arguments a model actually emits — a '
          'quoted number, a string boolean — before validation.',
      setup: _invoiceSchema,
      run: (schema) => schema.coerce(_sloppyInvoice),
      iterations: 2000,
      warmup: 200,
    ),
    Benchmark<Message>(
      name: 'core.message.roundtrip',
      description:
          'Serialising a multi-part message and reading it back. Every '
          'persisted session and every resumed workflow pays this per message.',
      setup: _richMessage,
      run: (message) => Message.fromJson(message.toJson()),
      iterations: 2000,
      warmup: 200,
    ),
    Benchmark<void>(
      name: 'core.ulid.generate',
      description:
          'Generating a sortable identifier. Called at least once per event, '
          'and this framework publishes a lot of events.',
      setup: () {},
      run: (_) => _ids.generate(),
      iterations: 5000,
      warmup: 500,
    ),
    Benchmark<BroadcastEventBus>(
      name: 'core.events.publish.8listeners',
      description:
          'Publishing one event to eight subscribers. The tax on observability '
          'being on by default.',
      setup: () {
        final bus = BroadcastEventBus();
        for (var i = 0; i < 8; i++) {
          bus.events.listen((_) {});
        }
        return bus;
      },
      teardown: (bus) => bus.dispose(),
      run: (bus) => bus.publish(
        GenericEvent(
          id: 'e',
          timestamp: DateTime.utc(2026),
          type: 'benchmark.tick',
        ),
      ),
      iterations: 5000,
      warmup: 500,
    ),
    Benchmark<RetryPolicy>(
      name: 'core.retry.backoff',
      description:
          'Computing a delay with decorrelated jitter. Cheap by design: a '
          'retry policy that costs real time is a retry policy that makes an '
          'outage worse.',
      setup: () => RetryPolicy.interactive,
      run: (policy) {
        var delay = Duration.zero;
        for (var attempt = 1; attempt <= 5; attempt++) {
          delay = policy.backoff.compute(attempt, delay);
        }
      },
      iterations: 5000,
      warmup: 500,
    ),
    Benchmark<void>(
      name: 'core.context.child',
      description:
          'Deriving a child context. Every agent step, tool call and workflow '
          'node creates one, so it sits on the hottest path there is.',
      setup: () {},
      run: (_) => _rootContext.child('step'),
      iterations: 5000,
      warmup: 500,
    ),
  ],
);

final IdGenerator _ids = Ulid();
final AgenticContext _rootContext = AgenticContext.root();

JsonSchema _invoiceSchema() => JsonSchema.object(
  properties: <String, JsonSchema>{
    'id': JsonSchema.string(minLength: 3),
    'total': JsonSchema.number(minimum: 0),
    'paid': JsonSchema.boolean(),
    'currency': JsonSchema.enumeration(const <String>['GBP', 'EUR', 'USD']),
    'lines': JsonSchema.array(
      items: JsonSchema.object(
        properties: <String, JsonSchema>{
          'sku': JsonSchema.string(),
          'quantity': JsonSchema.integer(minimum: 1),
          'price': JsonSchema.number(minimum: 0),
        },
        required: const <String>{'sku', 'quantity', 'price'},
      ),
      maxItems: 50,
    ),
  },
  required: const <String>{'id', 'total', 'currency', 'lines'},
);

const JsonMap _validInvoice = <String, Object?>{
  'id': 'INV-4417',
  'total': 249.5,
  'paid': false,
  'currency': 'GBP',
  'lines': <Object?>[
    <String, Object?>{'sku': 'A-1', 'quantity': 2, 'price': 99.0},
    <String, Object?>{'sku': 'B-7', 'quantity': 1, 'price': 51.5},
  ],
};

const JsonMap _invalidInvoice = <String, Object?>{
  'id': 'X',
  'total': -3,
  'currency': 'CHF',
  'lines': <Object?>[
    <String, Object?>{'sku': 'A-1', 'quantity': 0, 'price': 99.0},
  ],
};

/// The shapes a model emits when it nearly gets the schema right.
const JsonMap _sloppyInvoice = <String, Object?>{
  'id': 'INV-4417',
  'total': '249.5',
  'paid': 'false',
  'currency': 'GBP',
  'lines': <Object?>[
    <String, Object?>{'sku': 'A-1', 'quantity': '2', 'price': '99'},
  ],
};

Message _richMessage() => Message.assistant(
  'Here is the summary you asked for, with the figures checked twice.',
  toolCalls: <ToolCallPart>[
    ToolCallPart(
      id: 'call-1',
      name: 'lookup_invoice',
      arguments: const <String, Object?>{'id': 'INV-4417', 'expand': true},
    ),
  ],
);
