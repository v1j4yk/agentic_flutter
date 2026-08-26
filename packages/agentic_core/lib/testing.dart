/// Test doubles and helpers for code built on `agentic_core`.
///
/// Kept in a separate entry point so that production builds never pull in test
/// scaffolding, while packages that build on the framework — including
/// third-party tools and providers — can reuse the same doubles the framework
/// tests itself with.
///
/// ```dart
/// import 'package:agentic_core/testing.dart';
///
/// final clock = FakeClock(autoAdvance: true);
/// final ids = SequentialIdGenerator(prefix: 'evt-');
/// final logs = InMemoryLogSink();
/// ```
library;

export 'src/cancellation/cancellation.dart' show debugCreateToken;
export 'src/common/agentic_id.dart' show SequentialIdGenerator;
export 'src/telemetry/log.dart' show InMemoryLogSink;
export 'src/telemetry/trace.dart' show InMemorySpanExporter;
export 'src/testing/fake_clock.dart' show FakeClock;
