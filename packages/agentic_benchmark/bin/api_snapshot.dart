// Records or checks the public API surface of every published package.
//
//   dart run agentic_benchmark:api_snapshot           check against api/
//   dart run agentic_benchmark:api_snapshot --write   record the current surface
//
// Run from the repository root. `--write` is the deliberate act that says "yes,
// I meant to change the API"; the check without it is what makes forgetting
// visible in CI.
import 'dart:io';

import 'package:agentic_benchmark/src/api_signatures.dart';
import 'package:agentic_benchmark/src/api_surface.dart';

Future<void> main(List<String> arguments) async {
  final write = arguments.contains('--write');

  if (!Directory('packages').existsSync()) {
    stderr.writeln('Run this from the repository root.');
    exitCode = 1;
    return;
  }
  Directory('api').createSync(recursive: true);

  final diffs = <ApiDiff>[];
  var unknown = 0;

  for (final entry in trackedPackages.entries) {
    final current = ApiSurface.fromBarrel(entry.key, entry.value);
    unknown += current.names.where((n) => n.startsWith(kUnshownMarker)).length;

    final snapshot = File(snapshotPathFor(entry.key));
    if (write) {
      snapshot.writeAsStringSync(current.render());
      stdout.writeln('${entry.key}: ${current.size} names');
      continue;
    }

    if (!snapshot.existsSync()) {
      stderr.writeln('No snapshot for ${entry.key}. Record one with --write.');
      exitCode = 1;
      continue;
    }
    diffs.add(
      ApiDiff(
        package: entry.key,
        before: ApiSurface.parse(entry.key, snapshot.readAsStringSync()),
        after: current,
      ),
    );
  }

  if (unknown > 0) {
    stderr.writeln(
      'Warning: $unknown export(s) have no `show` clause. Those re-export '
      'whatever the target library contains, so the snapshot cannot describe '
      'them.',
    );
  }
  // Signatures: what each declaration promises, not only that it exists.
  // An unresolved package reads every type it cannot find as `InvalidType`,
  // which would look like a change to every signature that mentions one.
  final unresolved = <String>[
    for (final entry in trackedPackages.entries)
      if (!File(packageConfigFor(entry.value)).existsSync()) entry.key,
  ];
  if (unresolved.isNotEmpty) {
    stderr.writeln(
      'Cannot read signatures for ${unresolved.join(', ')}: run `dart pub get` '
      'at the root and `flutter pub get` in packages/agentic_flutter first.',
    );
    exitCode = 1;
    return;
  }
  final signatures = await readSignatures(trackedPackages);
  final signatureDiffs = <SignatureDiff>[];
  for (final entry in signatures.entries) {
    final file = File(signaturePathFor(entry.key));
    if (write) {
      file.writeAsStringSync(entry.value.render());
      stdout.writeln('${entry.key}: ${entry.value.lines.length} declarations');
      continue;
    }
    if (!file.existsSync()) {
      stderr.writeln(
        'No signature snapshot for ${entry.key}. Record one with --write.',
      );
      exitCode = 1;
      continue;
    }
    signatureDiffs.add(
      SignatureDiff(
        before: ApiSignatures.parse(entry.key, file.readAsStringSync()),
        after: entry.value,
      ),
    );
  }

  if (write) return;

  final changedSignatures = signatureDiffs.where((d) => d.hasChanges).toList();
  final changed = diffs.where((d) => d.hasChanges).toList();
  if (changed.isEmpty && changedSignatures.isEmpty) {
    stdout.writeln(
      'The public API is unchanged across ${diffs.length} package(s).',
    );
    return;
  }

  stdout.writeln('The public API changed:');
  for (final diff in changed) {
    stdout.writeln(diff.render());
  }
  for (final diff in changedSignatures) {
    stdout.writeln(diff.render());
  }
  stdout
    ..writeln()
    ..writeln(
      'If that was intended, record it with:\n'
      '  dart run agentic_benchmark:api_snapshot --write\n'
      'and let the diff in api/ be part of the review.',
    );
  exitCode = 1;
}
