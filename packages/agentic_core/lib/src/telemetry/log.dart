/// Structured logging.
///
/// Agent runs are hard to debug after the fact. A single request fans out into
/// model calls, tool invocations, retrievals and retries, and when the answer
/// is wrong the question is always "which step went wrong, and what did it
/// see?". Unstructured `print` output cannot answer that.
///
/// So every log record here carries structured [LogRecord.fields] and, when one
/// is active, the trace and span identifiers of the step that emitted it. That
/// makes a run reconstructable: filter by `runId` to see one conversation,
/// by `spanId` to see one tool call.
///
/// # Cost
///
/// Logging must never be the reason an agent loop is slow. Two properties keep
/// it cheap: [AgenticLogger.isEnabled] lets callers skip building a message at
/// all, and disabled levels short-circuit before any field map is allocated.
/// In hot paths, guard:
///
/// ```dart
/// if (logger.isEnabled(LogLevel.debug)) {
///   logger.debug('Prompt assembled', fields: {'tokens': countTokens(prompt)});
/// }
/// ```
library;

import 'dart:async';

import 'package:agentic_core/src/common/clock.dart';
import 'package:agentic_core/src/common/disposable.dart';
import 'package:agentic_core/src/common/json_types.dart';
import 'package:meta/meta.dart';

/// Severity of a log record, ordered from most to least verbose.
///
/// [severity] is a numeric value aligned with the OpenTelemetry severity
/// number range so that records map onto external systems without a lookup
/// table.
enum LogLevel {
  /// Extremely fine-grained detail: every token, every HTTP frame.
  trace(1, 'TRACE'),

  /// Detail useful while developing: assembled prompts, chosen tools.
  debug(5, 'DEBUG'),

  /// Normal operation: a run started, a tool succeeded.
  info(9, 'INFO'),

  /// Something recoverable happened: a retry, a degraded fallback.
  warning(13, 'WARN'),

  /// An operation failed.
  error(17, 'ERROR'),

  /// The process cannot continue.
  fatal(21, 'FATAL'),

  /// Emits nothing. Only valid as a threshold, never on a record.
  off(99, 'OFF');

  const LogLevel(this.severity, this.label);

  /// Numeric severity, comparable across levels.
  final int severity;

  /// Fixed-width-ish label used by text formatters.
  final String label;

  /// Whether a record at this level passes a [threshold].
  bool passes(LogLevel threshold) => severity >= threshold.severity;
}

/// One immutable log entry.
@immutable
final class LogRecord {
  /// Creates a log record.
  LogRecord({
    required this.timestamp,
    required this.level,
    required this.message,
    required this.loggerName,
    Map<String, Object?> fields = const <String, Object?>{},
    this.error,
    this.stackTrace,
    this.traceId,
    this.spanId,
  }) : fields = fields.isEmpty
           ? const <String, Object?>{}
           : Map<String, Object?>.unmodifiable(fields);

  /// When the record was created, in UTC.
  final DateTime timestamp;

  /// Severity of the record.
  final LogLevel level;

  /// Human-readable description of the event.
  ///
  /// Should be a stable, low-cardinality sentence. Put the varying parts in
  /// [fields], so records can be grouped: `'Tool failed'` with
  /// `{'tool': 'web_search'}` groups, `'Tool web_search failed'` does not.
  final String message;

  /// Dotted name of the logger that produced the record, such as
  /// `agentic.llm.openai`.
  final String loggerName;

  /// Structured context, unmodifiable.
  final Map<String, Object?> fields;

  /// The associated error, when the record describes a failure.
  final Object? error;

  /// The stack trace associated with [error].
  final StackTrace? stackTrace;

  /// Identifier of the enclosing trace, when one is active.
  final String? traceId;

  /// Identifier of the enclosing span, when one is active.
  final String? spanId;

  /// Serialises this record as a JSON object, ready for a log aggregator.
  JsonMap toJson() => pruneNulls(<String, Object?>{
    'timestamp': timestamp.toIso8601String(),
    'level': level.label,
    'severity': level.severity,
    'logger': loggerName,
    'message': message,
    'traceId': traceId,
    'spanId': spanId,
    'fields': fields.isEmpty ? null : fields,
    'error': error?.toString(),
    'stackTrace': stackTrace?.toString(),
  });

  @override
  String toString() {
    final buffer = StringBuffer()
      ..write('${timestamp.toIso8601String()} ')
      ..write('${level.label.padRight(5)} ')
      ..write('[$loggerName] ')
      ..write(message);
    if (fields.isNotEmpty) {
      final rendered = fields.entries
          .map((entry) => '${entry.key}=${entry.value}')
          .join(' ');
      buffer.write(' | $rendered');
    }
    if (spanId != null) buffer.write(' | span=$spanId');
    if (error != null) buffer.write('\n  error: $error');
    if (stackTrace != null) buffer.write('\n$stackTrace');
    return buffer.toString();
  }
}

/// Receives log records.
///
/// Implement this to forward records to a crash reporter, a file, or a remote
/// aggregator. Sinks must not throw: a failing sink must never take down the
/// operation being logged.
abstract interface class LogSink implements Disposable {
  /// Handles one record.
  ///
  /// Called synchronously from the logging call site, so implementations that
  /// perform I/O should buffer rather than await.
  void emit(LogRecord record);
}

/// Writes records to the console through a caller-supplied print function.
///
/// The default sink. It takes its output function as a parameter so that
/// `agentic_flutter` can route to `debugPrint` — which throttles, where a raw
/// `print` of a large prompt will be truncated by the platform log buffer —
/// without `agentic_core` depending on Flutter.
final class ConsoleLogSink implements LogSink {
  /// Creates a console sink.
  ///
  /// Set [asJson] to emit one JSON object per line, which is what a log
  /// collector wants. Leave it off for human-readable local development.
  const ConsoleLogSink({
    void Function(String line) write = print,
    this.asJson = false,
  }) : _write = write;

  final void Function(String line) _write;

  /// Whether to render records as JSON rather than as text.
  final bool asJson;

  @override
  void emit(LogRecord record) =>
      _write(asJson ? record.toJson().toString() : record.toString());

  @override
  Future<void> dispose() async {}
}

/// Fans records out to several sinks.
///
/// A failing sink is isolated: the remaining sinks still receive the record.
final class MultiLogSink implements LogSink {
  /// Creates a fan-out sink over [sinks].
  MultiLogSink(Iterable<LogSink> sinks)
    : _sinks = List<LogSink>.unmodifiable(sinks);

  final List<LogSink> _sinks;

  @override
  void emit(LogRecord record) {
    for (final sink in _sinks) {
      try {
        sink.emit(record);
      } on Object {
        // Deliberately swallowed. A broken log sink must never fail the
        // operation that was being logged, and reporting the failure through
        // the logger would risk unbounded recursion.
      }
    }
  }

  @override
  Future<void> dispose() async {
    for (final sink in _sinks) {
      await sink.dispose();
    }
  }
}

/// Buffers records in memory.
///
/// The sink tests assert against, and a useful backing store for an in-app
/// debug console. [maxRecords] bounds memory: the oldest records are dropped
/// once the buffer is full.
final class InMemoryLogSink implements LogSink {
  /// Creates a bounded in-memory sink.
  InMemoryLogSink({this.maxRecords = 1000});

  /// Maximum number of records retained.
  final int maxRecords;

  final List<LogRecord> _records = <LogRecord>[];

  /// The buffered records, oldest first.
  List<LogRecord> get records => List<LogRecord>.unmodifiable(_records);

  /// The buffered records at or above [level].
  List<LogRecord> at(LogLevel level) =>
      _records.where((record) => record.level.passes(level)).toList();

  /// Discards every buffered record.
  void clear() => _records.clear();

  @override
  void emit(LogRecord record) {
    _records.add(record);
    if (_records.length > maxRecords) _records.removeAt(0);
  }

  @override
  Future<void> dispose() async => _records.clear();
}

/// Rewrites a field value before it is emitted.
///
/// Returns the value to log, which may be a redacted placeholder. Applied to
/// every field of every record, so keep it cheap.
typedef FieldRedactor = Object? Function(String key, Object? value);

/// Emits log records.
///
/// Injected everywhere rather than reached for globally, so that a host
/// application controls verbosity and destination, and so that tests can
/// assert on what was logged.
abstract interface class AgenticLogger {
  /// Whether a record at [level] would be emitted.
  ///
  /// Check this before doing expensive work to build a message or fields.
  bool isEnabled(LogLevel level);

  /// Emits a record at [level].
  void log(
    LogLevel level,
    String message, {
    Map<String, Object?> fields,
    Object? error,
    StackTrace? stackTrace,
  });

  /// Returns a logger scoped to a child [name], inheriting bound fields.
  ///
  /// Names compose with dots: `agentic.agents` becomes
  /// `agentic.agents.researcher`. Use one per component so verbosity can be
  /// tuned by subtree.
  AgenticLogger child(String name, {Map<String, Object?> fields});

  /// Returns a logger with [fields] attached to every record it emits.
  ///
  /// The mechanism behind per-run correlation: bind `runId` once at the start
  /// of a run and every downstream record carries it.
  AgenticLogger withFields(Map<String, Object?> fields);
}

/// Level-specific shorthands shared by every [AgenticLogger].
///
/// Provided as an extension so that adding a convenience never breaks a
/// third-party logger implementation.
extension AgenticLoggerLevels on AgenticLogger {
  /// Logs at [LogLevel.trace].
  void trace(String message, {Map<String, Object?> fields = const {}}) =>
      log(LogLevel.trace, message, fields: fields);

  /// Logs at [LogLevel.debug].
  void debug(String message, {Map<String, Object?> fields = const {}}) =>
      log(LogLevel.debug, message, fields: fields);

  /// Logs at [LogLevel.info].
  void info(String message, {Map<String, Object?> fields = const {}}) =>
      log(LogLevel.info, message, fields: fields);

  /// Logs at [LogLevel.warning].
  void warn(
    String message, {
    Map<String, Object?> fields = const {},
    Object? error,
    StackTrace? stackTrace,
  }) => log(
    LogLevel.warning,
    message,
    fields: fields,
    error: error,
    stackTrace: stackTrace,
  );

  /// Logs at [LogLevel.error].
  void error(
    String message, {
    Map<String, Object?> fields = const {},
    Object? error,
    StackTrace? stackTrace,
  }) => log(
    LogLevel.error,
    message,
    fields: fields,
    error: error,
    stackTrace: stackTrace,
  );

  /// Logs at [LogLevel.fatal].
  void fatal(
    String message, {
    Map<String, Object?> fields = const {},
    Object? error,
    StackTrace? stackTrace,
  }) => log(
    LogLevel.fatal,
    message,
    fields: fields,
    error: error,
    stackTrace: stackTrace,
  );
}

/// The default [AgenticLogger]: filters by level, binds fields, writes to a
/// [LogSink].
final class StructuredLogger implements AgenticLogger {
  /// Creates a logger.
  ///
  /// [redactor] defaults to [redactSensitiveFields], which masks values whose
  /// key looks like a credential. Pass `null` to disable redaction entirely —
  /// appropriate only for local development.
  StructuredLogger({
    this.name = 'agentic',
    this.level = LogLevel.info,
    LogSink? sink,
    Clock clock = const SystemClock(),
    Map<String, Object?> boundFields = const <String, Object?>{},
    FieldRedactor? redactor = redactSensitiveFields,
    String? Function()? traceIdProvider,
    String? Function()? spanIdProvider,
  }) : _sink = sink ?? const ConsoleLogSink(),
       _clock = clock,
       _boundFields = Map<String, Object?>.unmodifiable(boundFields),
       _redactor = redactor,
       _traceIdProvider = traceIdProvider,
       _spanIdProvider = spanIdProvider;

  /// Dotted name identifying the component that owns this logger.
  final String name;

  /// Minimum severity that will be emitted.
  final LogLevel level;

  final LogSink _sink;
  final Clock _clock;
  final Map<String, Object?> _boundFields;
  final FieldRedactor? _redactor;
  final String? Function()? _traceIdProvider;
  final String? Function()? _spanIdProvider;

  @override
  bool isEnabled(LogLevel level) =>
      this.level != LogLevel.off && level.passes(this.level);

  @override
  void log(
    LogLevel level,
    String message, {
    Map<String, Object?> fields = const <String, Object?>{},
    Object? error,
    StackTrace? stackTrace,
  }) {
    if (!isEnabled(level)) return;

    final merged = <String, Object?>{};
    if (_boundFields.isNotEmpty) merged.addAll(_boundFields);
    if (fields.isNotEmpty) merged.addAll(fields);

    final redactor = _redactor;
    final safe = redactor == null
        ? merged
        : merged.map((key, value) => MapEntry(key, redactor(key, value)));

    _sink.emit(
      LogRecord(
        timestamp: _clock.now(),
        level: level,
        message: message,
        loggerName: name,
        fields: safe,
        error: error,
        stackTrace: stackTrace,
        traceId: _traceIdProvider?.call(),
        spanId: _spanIdProvider?.call(),
      ),
    );
  }

  @override
  AgenticLogger child(
    String name, {
    Map<String, Object?> fields = const <String, Object?>{},
  }) => StructuredLogger(
    name: '${this.name}.$name',
    level: level,
    sink: _sink,
    clock: _clock,
    boundFields: <String, Object?>{..._boundFields, ...fields},
    redactor: _redactor,
    traceIdProvider: _traceIdProvider,
    spanIdProvider: _spanIdProvider,
  );

  @override
  AgenticLogger withFields(Map<String, Object?> fields) => StructuredLogger(
    name: name,
    level: level,
    sink: _sink,
    clock: _clock,
    boundFields: <String, Object?>{..._boundFields, ...fields},
    redactor: _redactor,
    traceIdProvider: _traceIdProvider,
    spanIdProvider: _spanIdProvider,
  );

  /// Returns a copy of this logger with a different [level].
  StructuredLogger withLevel(LogLevel level) => StructuredLogger(
    name: name,
    level: level,
    sink: _sink,
    clock: _clock,
    boundFields: _boundFields,
    redactor: _redactor,
    traceIdProvider: _traceIdProvider,
    spanIdProvider: _spanIdProvider,
  );
}

/// A logger that discards everything.
///
/// The default in library code, so that a component never logs unless the host
/// application asked for it. Every method is a no-op and [isEnabled] is always
/// `false`, so guarded call sites cost one boolean.
final class NoopLogger implements AgenticLogger {
  /// Creates the no-op logger.
  const NoopLogger();

  @override
  bool isEnabled(LogLevel level) => false;

  @override
  void log(
    LogLevel level,
    String message, {
    Map<String, Object?> fields = const <String, Object?>{},
    Object? error,
    StackTrace? stackTrace,
  }) {}

  @override
  AgenticLogger child(
    String name, {
    Map<String, Object?> fields = const <String, Object?>{},
  }) => this;

  @override
  AgenticLogger withFields(Map<String, Object?> fields) => this;
}

/// Field keys whose values are masked by [redactSensitiveFields].
///
/// Matched case-insensitively as substrings, so `openaiApiKey`,
/// `authorization` and `refresh_token` are all covered.
const Set<String> sensitiveFieldMarkers = <String>{
  'apikey',
  'api_key',
  'authorization',
  'auth',
  'secret',
  'password',
  'token',
  'credential',
  'cookie',
  'session',
  'bearer',
};

/// Masks values whose key looks like a credential.
///
/// The default redactor. A framework that holds provider API keys and routes
/// user content through logs has to make leaking them the *harder* path, not
/// the default one. The first four characters are preserved so a developer can
/// still tell which key was used.
///
/// This is a safety net, not a guarantee: it cannot know that a field named
/// `note` contains a password. Keep secrets out of log fields in the first
/// place.
Object? redactSensitiveFields(String key, Object? value) {
  if (value == null) return null;
  final normalised = key.toLowerCase().replaceAll(RegExp('[^a-z]'), '');
  final isSensitive = sensitiveFieldMarkers.any(
    (marker) => normalised.contains(marker.replaceAll('_', '')),
  );
  if (!isSensitive) return value;

  final text = value.toString();
  if (text.length <= 8) return '***';
  return '${text.substring(0, 4)}***${text.length}';
}
