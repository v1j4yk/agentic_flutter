// Generates `llms.txt`: what this repository is, for a model that fetched it.
//
//   dart run tool/write_llms_txt.dart            # write
//   dart run tool/write_llms_txt.dart --check    # fail if it is out of date
//
// # Why generate it
//
// `llms.txt` is a file an AI assistant reads when it lands on a project and
// needs to know what is here and where to look. Hand-written, it would say
// "eleven packages" six months from now, the way the README did. Generated from
// the pubspecs and the skills on disk, it cannot.
//
// It is deliberately an index rather than documentation. The documentation an
// assistant should read is the bundled skills, which are installable with one
// command and are checked against the API snapshots; this file's job is to say
// that they exist.
library;

import 'dart:io';

const String _repository = 'https://github.com/v1j4yk/agentic_flutter';

Future<void> main(List<String> arguments) async {
  final check = arguments.contains('--check');
  final root = Directory.current;
  final packagesDir = Directory('${root.path}/packages');
  if (!packagesDir.existsSync()) {
    stderr.writeln('Run this from the repository root.');
    exitCode = 66; // EX_NOINPUT
    return;
  }

  final packages =
      packagesDir
          .listSync()
          .whereType<Directory>()
          .map(_Package.read)
          .whereType<_Package>()
          .toList()
        ..sort((a, b) => a.name.compareTo(b.name));

  final generated = _render(packages);
  final file = File('${root.path}/llms.txt');

  if (check) {
    final current = file.existsSync() ? file.readAsStringSync() : '';
    if (current.trim() != generated.trim()) {
      stderr.writeln(
        'llms.txt is out of date. Run `dart run tool/write_llms_txt.dart`.',
      );
      exitCode = 1;
      return;
    }
    stdout.writeln('llms.txt is current.');
    return;
  }

  file.writeAsStringSync(generated);
  stdout.writeln('Wrote llms.txt: ${packages.length} packages.');
}

String _render(List<_Package> packages) {
  final published = packages.where((p) => p.isPublished).toList();
  final internal = packages.where((p) => !p.isPublished).toList();
  final skillCount = published.fold(0, (sum, p) => sum + p.skills.length);

  final buffer = StringBuffer()
    ..writeln('# agentic — AI agents in Dart and Flutter')
    ..writeln()
    ..writeln(
      '> A framework for building agentic AI applications in Dart and '
      'Flutter: models, tools, agents, validated workflow graphs, memory, '
      'retrieval, the Model Context Protocol, on-device persistence, '
      'testing and chat widgets. Mobile-first: budgets, human approval and '
      'cancellation are built in rather than added later.',
    )
    ..writeln()
    ..writeln(
      'Applications depend on `agentic_flutter`, which re-exports the rest. '
      'A plugin depends only on the layer it extends — a tool package needs '
      '`agentic_tools`, not the whole framework.',
    )
    ..writeln()
    ..writeln('## If you are an AI assistant helping someone use this')
    ..writeln()
    ..writeln(
      'These packages ship $skillCount Agent Skills covering their APIs. '
      'Install them into your own skills directory rather than inferring '
      'the API:',
    )
    ..writeln()
    ..writeln('```sh')
    ..writeln('dart run skills@ get')
    ..writeln('```')
    ..writeln()
    ..writeln(
      'They are also readable in the repository under '
      '`packages/<package>/skills/`. Each says when to use a thing, when '
      'not to, and the mistakes people make.',
    )
    ..writeln()
    ..writeln('## Packages')
    ..writeln();

  for (final package in published) {
    buffer.writeln(
      '- [${package.name}](https://pub.dev/packages/${package.name}) '
      '(${package.version}): ${package.description}'
      '${package.skills.isEmpty ? '' : ' Skills: ${package.skills.join(', ')}.'}',
    );
  }

  buffer
    ..writeln()
    ..writeln('## Documentation')
    ..writeln()
    ..writeln(
      '- [README]($_repository#readme): what it is, with runnable code.',
    )
    ..writeln(
      '- [Architecture]($_repository/blob/main/doc/architecture.md): the '
      'layering, the extension points, and why each decision was made.',
    )
    ..writeln(
      '- [Migration to 0.2]($_repository/blob/main/doc/migration-0.2.md): '
      'breaking changes and how to migrate them.',
    )
    ..writeln(
      '- [Contributing]($_repository/blob/main/CONTRIBUTING.md) and '
      '[AGENTS.md]($_repository/blob/main/AGENTS.md): how to work in the '
      'repository itself.',
    )
    ..writeln(
      '- [Strategy]($_repository/tree/main/doc/strategy): the roadmap, the '
      'competitive analysis and the planned features.',
    )
    ..writeln(
      '- API reference: every package on pub.dev, and `api/*.txt` in the '
      'repository for the exported names of each.',
    )
    ..writeln()
    ..writeln('## Internal packages (not published)')
    ..writeln();

  for (final package in internal) {
    buffer.writeln('- ${package.name}: ${package.description}');
  }

  return buffer.toString();
}

/// One package, as far as this file cares.
final class _Package {
  const _Package({
    required this.name,
    required this.version,
    required this.description,
    required this.isPublished,
    required this.skills,
  });

  /// Reads a package directory, or returns null when it is not one.
  ///
  /// Deliberately a small hand-rolled read rather than a YAML dependency: this
  /// script runs from the workspace root, which has no dependencies of its own
  /// beyond melos, and one regex is cheaper than a resolution.
  static _Package? read(Directory directory) {
    final pubspec = File('${directory.path}/pubspec.yaml');
    if (!pubspec.existsSync()) return null;
    final source = pubspec.readAsStringSync();

    final name = _field(source, 'name');
    if (name == null) return null;

    final skills = <String>[];
    final skillsDir = Directory('${directory.path}/skills');
    if (skillsDir.existsSync()) {
      for (final skill in skillsDir.listSync().whereType<Directory>()) {
        skills.add(_basename(skill.path));
      }
      skills.sort();
    }

    return _Package(
      name: name,
      version: _field(source, 'version') ?? '0.0.0',
      description: _description(source),
      isPublished: !source.contains('publish_to: none'),
      skills: skills,
    );
  }

  final String name;
  final String version;
  final String description;
  final bool isPublished;
  final List<String> skills;
}

String? _field(String pubspec, String key) => RegExp(
  '^$key:\\s*(\\S.*)\$',
  multiLine: true,
).firstMatch(pubspec)?.group(1);

/// Reads a `description:`, which in this repository is almost always a folded
/// `>-` block over several lines.
///
/// Line-based rather than one regex: a pattern that handles both the inline and
/// the folded form reads as a puzzle, and the first version of it silently
/// returned the string `>-` for every folded description.
String _description(String pubspec) {
  // Split on `\r?\n`, not `\n`: these files are CRLF on Windows, and a stray
  // `\r` at the end of a line is a line terminator that `.` does not match —
  // so `^description:[ \t]*(.*)$` matched nothing at all, and every folded
  // description came back empty.
  final lines = pubspec.split(RegExp(r'\r?\n'));
  for (var i = 0; i < lines.length; i++) {
    final match = RegExp(r'^description:[ \t]*(.*)$').firstMatch(lines[i]);
    if (match == null) continue;

    final inline = match.group(1)!.trim();
    if (inline.isNotEmpty && inline != '>-' && inline != '>' && inline != '|') {
      return inline;
    }

    // A folded block: every following indented line, joined.
    final folded = <String>[];
    for (var j = i + 1; j < lines.length; j++) {
      final line = lines[j];
      if (line.trim().isEmpty) break;
      if (!line.startsWith(' ') && !line.startsWith('\t')) break;
      folded.add(line.trim());
    }
    return folded.join(' ');
  }
  return '';
}

String _basename(String path) =>
    path.replaceAll(r'\', '/').split('/').where((s) => s.isNotEmpty).last;
