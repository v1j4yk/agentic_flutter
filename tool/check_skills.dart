// Checks the Agent Skills bundled with each package.
//
//   dart run tool/check_skills.dart            # check
//   dart run tool/check_skills.dart --strict   # also fail on warnings
//
// # Why this is a program and not a review checklist
//
// A skill is documentation that an AI coding assistant reads *instead of*
// asking, and then writes code from. That makes a stale skill worse than no
// skill: it produces confident, wrong code in someone else's project, and the
// package gets the blame. The failure is silent — nothing in `dart analyze`
// knows that `api/agentic_tools.txt` no longer exports the name a skill tells
// an assistant to call.
//
// So this checks the two things that rot:
//
// * the packaging rules, because `package:skills` *silently skips* a skill
//   whose directory name does not start with the package name — a typo means
//   the skill simply never reaches anyone, with no error anywhere;
// * every framework identifier a skill mentions in a Dart code block, against
//   the committed API snapshots in `api/`. Rename an export and the skill that
//   teaches it fails here, in the same commit.
library;

import 'dart:io';

Future<void> main(List<String> arguments) async {
  final strict = arguments.contains('--strict');
  final root = Directory.current;
  final packages = Directory('${root.path}/packages');
  if (!packages.existsSync()) {
    stderr.writeln('Run this from the repository root.');
    exitCode = 66; // EX_NOINPUT
    return;
  }

  final known = _knownApiNames(Directory('${root.path}/api'))
    ..addAll(_secondaryLibraryNames(packages));
  if (known.isEmpty) {
    stderr.writeln(
      'No API snapshots found in api/. Run `melos run api:write` first.',
    );
    exitCode = 66;
    return;
  }

  final problems = <_Problem>[];
  final skillNames = <String>{};
  final skills = <_Skill>[];

  for (final directory in packages.listSync().whereType<Directory>()) {
    final package = _basename(directory.path);
    final skillsDir = Directory('${directory.path}/skills');
    if (!skillsDir.existsSync()) {
      if (_isPublished(directory)) {
        problems.add(
          _Problem.warning(
            '$package: no skills/ directory. Every published package should '
            'teach an AI assistant how to use it.',
          ),
        );
      }
      continue;
    }

    for (final skillDir in skillsDir.listSync().whereType<Directory>()) {
      final skill = _Skill.read(package: package, directory: skillDir);
      skills.add(skill);
      skillNames.add(skill.directoryName);
      problems.addAll(skill.validate(known));
    }
  }

  // Cross-references are a warning: a skill may legitimately point at one that
  // is planned but not yet written. It must never point at a typo, though,
  // which is what listing the unknown targets makes visible.
  for (final skill in skills) {
    for (final reference in skill.references) {
      if (!skillNames.contains(reference)) {
        problems.add(
          _Problem.warning(
            '${skill.id}: "See also" names `$reference`, which does not exist '
            'yet.',
          ),
        );
      }
    }
  }

  final errors = problems.where((p) => p.isError).toList();
  final warnings = problems.where((p) => !p.isError).toList();

  for (final problem in [...errors, ...warnings]) {
    stdout.writeln(
      '${problem.isError ? 'error  ' : 'warning'}  ${problem.message}',
    );
  }

  stdout.writeln(
    '\n${skills.length} skill(s) checked: '
    '${errors.length} error(s), ${warnings.length} warning(s).',
  );

  if (errors.isNotEmpty || (strict && warnings.isNotEmpty)) {
    exitCode = 1;
  }
}

/// One skill directory, parsed far enough to check it.
final class _Skill {
  _Skill({
    required this.package,
    required this.directoryName,
    required this.path,
    required this.name,
    required this.description,
    required this.bodyLines,
    required this.dartIdentifiers,
    required this.references,
    required this.missingFile,
  });

  factory _Skill.read({required String package, required Directory directory}) {
    final directoryName = _basename(directory.path);
    final file = File('${directory.path}/SKILL.md');
    if (!file.existsSync()) {
      return _Skill(
        package: package,
        directoryName: directoryName,
        path: directory.path,
        name: null,
        description: null,
        bodyLines: 0,
        dartIdentifiers: const <String>{},
        references: const <String>[],
        missingFile: true,
      );
    }

    final content = file.readAsStringSync();
    final frontmatter = _frontmatter(content);
    return _Skill(
      package: package,
      directoryName: directoryName,
      path: file.path,
      name: frontmatter['name'],
      description: frontmatter['description'],
      bodyLines: '\n'.allMatches(content).length + 1,
      dartIdentifiers: _dartIdentifiers(
        content,
      ).difference(_sampleTypes(content)),
      references: _references(content),
      missingFile: false,
    );
  }

  final String package;
  final String directoryName;
  final String path;
  final String? name;
  final String? description;
  final int bodyLines;
  final Set<String> dartIdentifiers;
  final List<String> references;
  final bool missingFile;

  String get id => '$package/$directoryName';

  List<_Problem> validate(Set<String> known) {
    final problems = <_Problem>[];

    if (missingFile) {
      return [_Problem.error('$id: no SKILL.md in the skill directory.')];
    }

    // `package:skills` skips anything that does not start with the package
    // name, hyphenated or not. A skipped skill fails silently, so this is an
    // error rather than a warning.
    final hyphenated = package.replaceAll('_', '-');
    if (!directoryName.startsWith('$package-') &&
        !directoryName.startsWith('$hyphenated-')) {
      problems.add(
        _Problem.error(
          '$id: directory must start with `$hyphenated-` (or `$package-`), or '
          'the skills CLI silently skips it.',
        ),
      );
    }

    final name = this.name;
    if (name == null || name.isEmpty) {
      problems.add(_Problem.error('$id: frontmatter has no `name`.'));
    } else {
      if (name != directoryName) {
        problems.add(
          _Problem.error(
            '$id: `name: $name` must equal the directory name '
            '`$directoryName`.',
          ),
        );
      }
      if (!RegExp(r'^[a-z0-9-]{1,64}$').hasMatch(name)) {
        problems.add(
          _Problem.error(
            '$id: `name` must be 1-64 lowercase letters, digits or hyphens.',
          ),
        );
      }
    }

    final description = this.description;
    if (description == null || description.trim().isEmpty) {
      problems.add(_Problem.error('$id: frontmatter has no `description`.'));
    } else if (description.length > 1024) {
      problems.add(
        _Problem.error(
          '$id: `description` is ${description.length} characters; the limit '
          'is 1024.',
        ),
      );
    } else if (!description.toLowerCase().contains('use when')) {
      // The description is the only thing an assistant sees before deciding to
      // load the skill, so it has to say *when* the skill applies.
      problems.add(
        _Problem.warning(
          '$id: `description` should say when to use the skill ("Use when …").',
        ),
      );
    }

    if (bodyLines > 500) {
      problems.add(
        _Problem.warning(
          '$id: SKILL.md is $bodyLines lines; keep it under 500 and move detail '
          'into references/.',
        ),
      );
    }

    for (final identifier in dartIdentifiers) {
      if (!known.contains(identifier) && !_external.contains(identifier)) {
        problems.add(
          _Problem.error(
            '$id: code mentions `$identifier`, which no package exports. '
            'Fix the skill, or add the name to `_external` if it comes from '
            'Flutter or the SDK.',
          ),
        );
      }
    }

    return problems;
  }
}

final class _Problem {
  const _Problem.error(this.message) : isError = true;
  const _Problem.warning(this.message) : isError = false;

  final String message;
  final bool isError;
}

/// Type names a skill declares as belonging to the reader's own code.
///
/// An example needs something concrete to act on — a `Customer`, a
/// `DebugScreen` — and those names are by definition not in any API snapshot.
/// Declaring them under `metadata.sample-types` keeps the check strict about
/// everything else, and documents for a reader which names are theirs to
/// supply:
///
/// ```yaml
/// metadata:
///   sample-types: Customer, DebugScreen
/// ```
Set<String> _sampleTypes(String content) {
  if (!content.startsWith('---')) return <String>{};
  final end = content.indexOf('\n---', 3);
  if (end < 0) return <String>{};
  final match = RegExp(
    r'^\s*sample-types:\s*(.+)$',
    multiLine: true,
  ).firstMatch(content.substring(0, end));
  if (match == null) return <String>{};
  return <String>{
    for (final name in match.group(1)!.split(','))
      if (name.trim().isNotEmpty) name.trim(),
  };
}

/// Names exported by a package's *other* public libraries.
///
/// The API snapshots cover each package's main barrel, which is the surface
/// that matters for compatibility. A package may have more than one public
/// library, though — `package:agentic_mcp/io.dart` holds the subprocess
/// transport, so that the main one still compiles for the web — and a skill
/// teaching it is correct even though the snapshot has never heard of it.
Set<String> _secondaryLibraryNames(Directory packages) {
  final names = <String>{};
  final shown = RegExp(r'show\s+([^;]+);', multiLine: true);
  for (final package in packages.listSync().whereType<Directory>()) {
    final lib = Directory('${package.path}/lib');
    if (!lib.existsSync()) continue;
    final barrel = '${_basename(package.path)}.dart';
    for (final file in lib.listSync().whereType<File>()) {
      if (!file.path.endsWith('.dart')) continue;
      if (_basename(file.path) == barrel) continue; // already in the snapshot
      for (final match in shown.allMatches(file.readAsStringSync())) {
        for (final name in match.group(1)!.split(',')) {
          final trimmed = name.trim();
          if (trimmed.isNotEmpty) names.add(trimmed);
        }
      }
    }
  }
  return names;
}

/// Every public name the framework exports, from the committed snapshots.
Set<String> _knownApiNames(Directory api) {
  if (!api.existsSync()) return <String>{};
  final names = <String>{};
  for (final file in api.listSync().whereType<File>()) {
    if (!file.path.endsWith('.txt')) continue;
    if (file.path.endsWith('.signatures.txt')) {
      for (final line in file.readAsLinesSync()) {
        final member = line.split(':').first.trim();
        if (member.isEmpty || member.startsWith('#')) continue;
        names.add(member.split('.').first);
      }
      continue;
    }
    for (final line in file.readAsLinesSync()) {
      final trimmed = line.trim();
      if (trimmed.isEmpty || trimmed.startsWith('#')) continue;
      for (final word in trimmed.split(RegExp(r'\s+'))) {
        if (word.isNotEmpty) names.add(word);
      }
    }
  }
  return names;
}

/// Type-shaped identifiers used inside ```dart blocks.
///
/// Only `UpperCamelCase` words are considered: those are the names that get
/// renamed, and the ones an assistant copies verbatim.
Set<String> _dartIdentifiers(String content) {
  final identifiers = <String>{};
  final declared = <String>{};
  final fence = RegExp(r'```dart\n([\s\S]*?)```', multiLine: true);
  final word = RegExp(r'\b[A-Z][A-Za-z0-9]{2,}\b');
  // A skill that teaches "write your own event type" declares one in its
  // example. Those names are the sample's own and cannot be in an API
  // snapshot, so collect them and exclude them below.
  final declaration = RegExp(
    r'^\s*(?:abstract\s+|final\s+|base\s+|sealed\s+|interface\s+|mixin\s+)*'
    r'(?:class|enum|extension type|typedef)\s+([A-Z][A-Za-z0-9]*)',
    multiLine: true,
  );
  for (final block in fence.allMatches(content)) {
    final code = block.group(1) ?? '';
    for (final match in declaration.allMatches(code)) {
      declared.add(match.group(1)!);
    }
    for (final line in code.split('\n')) {
      // Comments and string literals are prose — a tool description, a prompt,
      // an error message — and may contain any capitalised word. Only code
      // outside them names an API.
      final withoutComment = line.split('//').first;
      final withoutStrings = withoutComment
          .replaceAll(RegExp(r"'(?:[^'\\]|\\.)*'"), "''")
          .replaceAll(RegExp(r'"(?:[^"\\]|\\.)*"'), '""')
          // A string continued on the next line leaves one unbalanced quote.
          .replaceAll(RegExp(r"'[^']*$"), '')
          .replaceAll(RegExp(r'"[^"]*$'), '');
      for (final match in word.allMatches(withoutStrings)) {
        identifiers.add(match.group(0)!);
      }
    }
  }
  return identifiers.difference(declared);
}

/// Skill names referenced from a "See also" section.
List<String> _references(String content) {
  final index = content.indexOf('## See also');
  if (index < 0) return const <String>[];
  return RegExp(r'`([a-z0-9-]+)`')
      .allMatches(content.substring(index))
      .map((m) => m.group(1)!)
      .where((name) => name.contains('-'))
      .toList();
}

/// A deliberately small YAML reader: the frontmatter this checks is `key:
/// value` and folded `>-` blocks, and depending on a YAML package would make
/// this script need a pub resolution it otherwise does not.
Map<String, String> _frontmatter(String content) {
  if (!content.startsWith('---')) return const <String, String>{};
  final end = content.indexOf('\n---', 3);
  if (end < 0) return const <String, String>{};

  final fields = <String, String>{};
  final lines = content.substring(4, end).split('\n');
  String? key;
  final buffer = StringBuffer();

  void flush() {
    final current = key;
    if (current != null) fields[current] = buffer.toString().trim();
    buffer.clear();
  }

  for (final line in lines) {
    final match = RegExp(r'^([a-z][a-z-]*):\s*(.*)$').firstMatch(line);
    if (match != null) {
      flush();
      key = match.group(1);
      final value = match.group(2)!.trim();
      if (value != '>-' && value != '>' && value != '|') buffer.write(value);
      continue;
    }
    if (key != null && line.trim().isNotEmpty) {
      if (buffer.isNotEmpty) buffer.write(' ');
      buffer.write(line.trim());
    }
  }
  flush();
  return fields;
}

bool _isPublished(Directory package) {
  final pubspec = File('${package.path}/pubspec.yaml');
  if (!pubspec.existsSync()) return false;
  return !pubspec.readAsStringSync().contains('publish_to: none');
}

String _basename(String path) =>
    path.replaceAll(r'\', '/').split('/').where((s) => s.isNotEmpty).last;

/// Names that come from Flutter, the SDK or a code sample's own domain, and so
/// cannot be checked against the framework's API snapshots.
const Set<String> _external = <String>{
  // Flutter framework, and packages an example tells the reader to add
  'AppBar', 'AppLifecycleState', 'BuildContext', 'ChangeNotifier', 'Colors',
  'EdgeInsets',
  'FlutterSecureStorage', 'GlobalKey', 'Key', 'MaterialApp', 'NavigatorState',
  'Scaffold', 'State', 'StatefulWidget', 'StatelessWidget', 'Text', 'ThemeData',
  'Widget', 'WidgetsBinding',
  // Dart SDK
  'DateTime', 'Duration', 'File', 'Future', 'Iterable', 'List', 'Map',
  'MapEntry',
  'Object', 'Platform', 'Process', 'RegExp', 'Set', 'Stream', 'String',
  'Uri',
  // Names that belong to the reader's own application in an example: the
  // domain types a skill invents to have something concrete to show.
  'MyApp', 'ChatScreen', 'ExampleApp', 'CameraTool', 'Invoice', 'Recipe',
  'Order', 'OrderTools', 'Note', 'Ingredient', 'Difficulty',
};
