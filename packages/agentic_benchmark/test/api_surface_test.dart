import 'dart:io';

import 'package:agentic_benchmark/agentic_benchmark.dart';
import 'package:test/test.dart';

/// The snapshot is only a guard rail if it is actually checked, and only
/// trustworthy if the extractor reads a barrel the way Dart does.
void main() {
  group('extraction', () {
    test('reads the names in a show clause', () {
      final surface = ApiSurface(
        package: 'p',
        names: ApiSurface.parseShownNames('''
export 'src/a.dart' show Alpha, Beta;
export 'src/b.dart'
    show
        Gamma,
        delta;
'''),
      );
      expect(surface.names, <String>['Alpha', 'Beta', 'Gamma', 'delta']);
    });

    test('ignores hide clauses, which do not add to the surface', () {
      // `hide` narrows a wildcard export; it never introduces a name. Treating
      // the hidden names as exported would be exactly backwards.
      final names = ApiSurface.parseShownNames(
        "export 'src/a.dart' show Alpha hide Beta;",
      );
      expect(names, contains('Alpha'));
      expect(names, isNot(contains('Beta')));
    });

    test('records an umbrella re-export by the package it carries', () {
      // An umbrella re-exporting a sibling is the one legitimate wildcard, and
      // the surface it carries is tracked in that sibling's own snapshot.
      final names = ApiSurface.parseShownNames(
        "export 'package:agentic_core/agentic_core.dart';",
      );
      expect(names, <String>['re-exports agentic_core']);
    });

    test('flags a wildcard export it cannot describe', () {
      final names = ApiSurface.parseShownNames(
        "export 'package:collection/collection.dart';",
      );
      expect(names.single, startsWith(kUnshownMarker));
    });

    test('sorts and de-duplicates', () {
      final surface = ApiSurface(
        package: 'p',
        names: <String>['Zed', 'Alpha', 'Zed'],
      );
      expect(surface.names, <String>['Alpha', 'Zed']);
    });
  });

  group('snapshot format', () {
    test('round-trips', () {
      final original = ApiSurface(
        package: 'p',
        names: <String>['Alpha', 'Beta', 'gamma'],
      );
      final restored = ApiSurface.parse('p', original.render());
      expect(restored.names, original.names);
    });

    test('carries the count in the header', () {
      // A reviewer who sees 142 become 141 knows to look for a removal before
      // reading a line of the body.
      final rendered = ApiSurface(
        package: 'p',
        names: <String>['A', 'B'],
      ).render();
      expect(rendered, contains('# 2 names'));
      expect(rendered, contains('Do not edit'));
    });
  });

  group('diffs', () {
    ApiSurface surfaceOf(List<String> names) =>
        ApiSurface(package: 'p', names: names);

    test('an addition is not breaking', () {
      final diff = ApiDiff(
        package: 'p',
        before: surfaceOf(<String>['A']),
        after: surfaceOf(<String>['A', 'B']),
      );
      expect(diff.added, <String>['B']);
      expect(diff.hasChanges, isTrue);
      expect(diff.isBreaking, isFalse);
    });

    test('a removal is', () {
      final diff = ApiDiff(
        package: 'p',
        before: surfaceOf(<String>['A', 'B']),
        after: surfaceOf(<String>['A']),
      );
      expect(diff.removed, <String>['B']);
      expect(diff.isBreaking, isTrue);
      expect(diff.render(), contains('breaking'));
    });

    test('a rename shows as both, not as silence', () {
      final diff = ApiDiff(
        package: 'p',
        before: surfaceOf(<String>['OldName']),
        after: surfaceOf(<String>['NewName']),
      );
      expect(diff.removed, <String>['OldName']);
      expect(diff.added, <String>['NewName']);
      expect(diff.isBreaking, isTrue);
    });

    test('no change says so', () {
      final diff = ApiDiff(
        package: 'p',
        before: surfaceOf(<String>['A']),
        after: surfaceOf(<String>['A']),
      );
      expect(diff.hasChanges, isFalse);
      expect(diff.render(), contains('unchanged'));
    });
  });

  group('the committed snapshots', () {
    // Located from the test's own working directory, which `dart test` sets to
    // the package root.
    final root = Directory.current.path.endsWith('agentic_benchmark')
        ? '../..'
        : '.';

    test('exist for every tracked package', () {
      for (final package in trackedPackages.keys) {
        expect(
          File('$root/${snapshotPathFor(package)}').existsSync(),
          isTrue,
          reason:
              'No snapshot for $package. Record one with '
              '`dart run agentic_benchmark:api_snapshot --write`.',
        );
      }
    });

    test('match the barrels they were taken from', () {
      // The check the CI job runs, repeated here so a contributor sees it
      // before pushing rather than after.
      final changed = <String>[];
      for (final entry in trackedPackages.entries) {
        final snapshot = File('$root/${snapshotPathFor(entry.key)}');
        if (!snapshot.existsSync()) continue;

        final diff = ApiDiff(
          package: entry.key,
          before: ApiSurface.parse(entry.key, snapshot.readAsStringSync()),
          after: ApiSurface.fromBarrel(entry.key, '$root/${entry.value}'),
        );
        if (diff.hasChanges) changed.add(diff.render());
      }

      expect(
        changed,
        isEmpty,
        reason:
            'The public API changed:\n${changed.join('\n')}\n\n'
            'If that was intended, record it with '
            '`dart run agentic_benchmark:api_snapshot --write` and let the '
            'diff in api/ be part of the review.',
      );
    });

    test('describe no wildcard export outside an umbrella', () {
      for (final entry in trackedPackages.entries) {
        final surface = ApiSurface.fromBarrel(
          entry.key,
          '$root/${entry.value}',
        );
        final wildcards = surface.names
            .where((n) => n.startsWith(kUnshownMarker))
            .toList();
        expect(
          wildcards,
          isEmpty,
          reason:
              '${entry.key} re-exports something wholesale, so its surface is '
              'whatever that library happens to contain: $wildcards',
        );
      }
    });
  });
}
