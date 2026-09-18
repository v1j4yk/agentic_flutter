/// Buffering spans so that export costs one request, not one per span.
library;

import 'dart:async';

import 'package:agentic_core/agentic_core.dart';
import 'package:agentic_otel/src/otlp_exporter.dart';

/// Collects spans and exports them in batches.
///
/// A run produces tens of spans. Posting each one separately means tens of TLS
/// handshakes on a phone, on the same radio the model call is using — which is
/// how observability turns into latency and battery drain. This buffers them
/// and sends one request.
///
/// ```dart
/// final exporter = BatchSpanExporter(
///   OtlpHttpSpanExporter(endpoint: collector),
///   maxBatch: 128,
///   flushEvery: const Duration(seconds: 5),
/// );
/// // On a phone, flush when the app goes to the background:
/// WidgetsBinding.instance.addObserver(...)  // → exporter.flush()
/// await exporter.dispose();                  // flushes what is left
/// ```
final class BatchSpanExporter implements SpanExporter {
  /// Wraps [inner], buffering up to [maxBatch] spans.
  ///
  /// [maxQueue] bounds memory when the collector is unreachable: past it the
  /// **oldest** spans are dropped, because in a queue of stale telemetry the
  /// newest is the one worth keeping. [dropped] says how many, so the gap
  /// is visible rather than silent.
  BatchSpanExporter(
    this.inner, {
    this.maxBatch = 128,
    this.maxQueue = 2048,
    this.flushEvery = const Duration(seconds: 5),
  }) {
    if (flushEvery > Duration.zero) {
      _timer = Timer.periodic(flushEvery, (_) => unawaited(flush()));
    }
  }

  /// Where batches are sent.
  final OtlpHttpSpanExporter inner;

  /// How many spans are sent in one request.
  final int maxBatch;

  /// How many spans may wait before the oldest are dropped.
  final int maxQueue;

  /// How often a partial batch is sent anyway.
  ///
  /// Without this, the last few spans of a run sit in the buffer until the next
  /// run fills it — and a trace that arrives an hour late is a trace nobody
  /// looks at.
  final Duration flushEvery;

  final List<SpanData> _queue = <SpanData>[];
  Timer? _timer;
  Future<void>? _inFlight;
  bool _disposed = false;
  int _dropped = 0;

  /// Spans dropped because the queue was full.
  int get dropped => _dropped;

  /// Spans waiting to be sent.
  int get pending => _queue.length;

  @override
  void export(SpanData span) {
    if (_disposed) return;
    _queue.add(span);

    if (_queue.length > maxQueue) {
      final excess = _queue.length - maxQueue;
      _queue.removeRange(0, excess);
      _dropped += excess;
    }

    if (_queue.length >= maxBatch) unawaited(flush());
  }

  /// Sends everything buffered.
  ///
  /// Serialised: a second flush while one is in flight waits for it rather than
  /// opening a second connection, so a burst of spans cannot turn into a burst
  /// of requests.
  Future<void> flush() async {
    if (_inFlight case final running?) {
      await running;
    }
    if (_queue.isEmpty) return;

    final completer = Completer<void>();
    _inFlight = completer.future;
    try {
      while (_queue.isNotEmpty) {
        final batch = _queue.take(maxBatch).toList();
        _queue.removeRange(0, batch.length);
        final accepted = await inner.exportAll(batch);
        // A rejected batch is dropped rather than requeued: retrying into a
        // collector that is down turns one problem into an unbounded queue,
        // and these spans have already been reported through `onError`.
        if (!accepted) _dropped += batch.length;
      }
    } finally {
      _inFlight = null;
      completer.complete();
    }
  }

  /// Flushes and releases the timer and the inner exporter.
  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _timer?.cancel();
    _timer = null;
    // Flushed before the flag stops accepting new spans would be pointless —
    // what matters is that the buffer is not lost on the way out.
    await _flushRemaining();
    await inner.dispose();
  }

  Future<void> _flushRemaining() async {
    if (_queue.isEmpty) return;
    final remaining = List<SpanData>.of(_queue);
    _queue.clear();
    for (var i = 0; i < remaining.length; i += maxBatch) {
      final end = (i + maxBatch).clamp(0, remaining.length);
      final batch = remaining.sublist(i, end);
      // Counted the same way `flush` counts them: spans lost on the way out
      // are still spans lost, and a `dropped` that only counts some of them is
      // a number nobody can act on.
      if (!await inner.exportAll(batch)) _dropped += batch.length;
    }
  }

  @override
  String toString() =>
      'BatchSpanExporter(pending: $pending, dropped: $dropped, '
      'flushEvery: ${flushEvery.inSeconds}s)';
}
