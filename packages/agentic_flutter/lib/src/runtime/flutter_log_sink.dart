/// Framework logging routed into Flutter's own console.
library;

import 'package:agentic_core/agentic_core.dart';
import 'package:flutter/foundation.dart';

/// Writes structured log records through [debugPrint].
///
/// # Why `debugPrint` and not `print`
///
/// Android's log buffer drops lines beyond roughly a thousand characters,
/// silently and mid-line. `debugPrint` throttles output to stay under that,
/// which is the difference between reading a truncated prompt and reading the
/// one line that explains a failure. `agentic_core` was built for this: its
/// [ConsoleLogSink] takes the write function as a parameter, so the core never
/// has to know Flutter exists and this class is a configuration rather than a
/// reimplementation.
///
/// # Silent in release by default
///
/// A framework that logs in release ships whatever the user typed to the
/// platform log, where other software can read it. The default is debug-only;
/// enabling [logInRelease] is a deliberate act. The credential redaction
/// `StructuredLogger` already applies still stands either way.
///
/// ```dart
/// final logger = StructuredLogger(
///   level: LogLevel.debug,
///   sink: const FlutterLogSink(),
/// );
/// ```
final class FlutterLogSink implements LogSink {
  /// Creates a sink.
  ///
  /// Set [asJson] when the console output is being scraped by a collector;
  /// leave it off for human-readable local development.
  const FlutterLogSink({this.logInRelease = false, this.asJson = false});

  /// Whether anything is written in a release build.
  final bool logInRelease;

  /// Whether records are rendered as JSON rather than as text.
  final bool asJson;

  @override
  void emit(LogRecord record) {
    if (kReleaseMode && !logInRelease) return;
    ConsoleLogSink(write: debugPrint, asJson: asJson).emit(record);
  }

  @override
  Future<void> dispose() async {}

  @override
  String toString() => 'FlutterLogSink(release: $logInRelease)';
}
