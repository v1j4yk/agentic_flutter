// Prints a capability matrix: what each provider claims, against what it does.
//
//   OPENAI_API_KEY=… dart run bin/audit.dart
//   OPENAI_API_KEY=… dart run bin/audit.dart --json
//
// This is the report worth reading after a nightly run. A declared capability
// that is not real fails deep inside an agent loop where the cause is
// invisible; here it is one cell in a table.
//
// It makes real calls and costs a small amount of money per provider.
import 'dart:convert';
import 'dart:io';

import 'package:agentic_integration/agentic_integration.dart';

Future<void> main(List<String> arguments) async {
  final json = arguments.contains('--json');
  final subjects = discoverSubjects();

  if (subjects.isEmpty) {
    stderr
      ..writeln('No provider credentials found.')
      ..writeln(subjects.describeMissing());
    exitCode = 1;
    return;
  }

  if (!json) {
    stdout
      ..writeln('Auditing ${subjects.available.length} provider(s). This calls')
      ..writeln('real APIs and takes a minute or two.')
      ..writeln();
    if (subjects.missing.isNotEmpty) {
      stdout
        ..writeln(subjects.describeMissing())
        ..writeln();
    }
  }

  final byProvider = <String, List<ConformanceOutcome>>{};
  for (final subject in subjects.available) {
    if (!json) stderr.writeln('  auditing ${subject.name}…');
    byProvider[subject.name] = await auditProvider(subject);
  }

  if (json) {
    stdout.writeln(
      const JsonEncoder.withIndent('  ').convert(<String, Object?>{
        for (final entry in byProvider.entries)
          entry.key: entry.value.map((o) => o.toJson()).toList(),
      }),
    );
  } else {
    stdout.writeln(_renderMatrix(byProvider));
  }

  final failed = byProvider.values
      .expand((outcomes) => outcomes)
      .where((outcome) => !outcome.passed && !outcome.skipped)
      .toList();
  if (failed.isEmpty) return;

  if (!json) {
    stdout
      ..writeln()
      ..writeln('${failed.length} check(s) did not hold:');
    for (final outcome in failed) {
      stdout.writeln('  $outcome');
    }
  }
  exitCode = 1;
}

/// Renders providers as columns and checks as rows.
///
/// That orientation on purpose: the question a reader has is "does this
/// behaviour hold everywhere", and a row that is `pass pass FAIL pass` answers
/// it at a glance. The transpose answers a question nobody asks.
String _renderMatrix(Map<String, List<ConformanceOutcome>> byProvider) {
  final providers = byProvider.keys.toList();
  final checks = <String>{
    for (final outcomes in byProvider.values)
      for (final outcome in outcomes) outcome.check,
  }.toList();

  const checkWidth = 22;
  final columnWidth = providers
      .map((p) => p.length)
      .fold(8, (widest, length) => length + 2 > widest ? length + 2 : widest);

  final buffer = StringBuffer()
    ..write('check'.padRight(checkWidth))
    ..writeln(providers.map((p) => p.padRight(columnWidth)).join())
    ..writeln('-' * (checkWidth + columnWidth * providers.length));

  for (final check in checks) {
    buffer.write(check.padRight(checkWidth));
    for (final provider in providers) {
      final outcome = byProvider[provider]!
          .where((o) => o.check == check)
          .firstOrNull;
      buffer.write(_cell(outcome).padRight(columnWidth));
    }
    buffer.writeln();
  }

  buffer
    ..writeln()
    ..writeln(
      'pass = holds   FAIL = claimed but does not hold   '
      '-- = not claimed',
    );
  return buffer.toString();
}

String _cell(ConformanceOutcome? outcome) => switch (outcome) {
  null => '?',
  ConformanceOutcome(skipped: true) => '--',
  ConformanceOutcome(passed: true) => 'pass',
  _ => 'FAIL',
};
