// Lists every signature change since another checkout of the repository.
//
//   git worktree add ../release release/0.1.x
//   (cd ../release && dart pub get && cd packages/agentic_flutter && flutter pub get)
//   dart run packages/agentic_benchmark/tool/diff_release.dart ../release
//
// The migration guide for a release starts from this output: every `~` line
// is a signature to check for a break, and every `-` line is one.
import 'dart:io';

import 'package:agentic_benchmark/src/api_signatures.dart';
import 'package:agentic_benchmark/src/api_surface.dart';

Future<void> main(List<String> args) async {
  final other = args.single;
  final barrels = <String, String>{
    for (final e in trackedPackages.entries)
      if (File('$other/${e.value}').existsSync()) e.key: '$other/${e.value}',
  };
  final old = await readSignatures(barrels);
  for (final entry in old.entries) {
    final now = ApiSignatures.parse(
      entry.key,
      File(signaturePathFor(entry.key)).readAsStringSync(),
    );
    final diff = SignatureDiff(before: entry.value, after: now);
    stdout.writeln(diff.render());
  }
}
