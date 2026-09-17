/// Writing a project to disk, or refusing to.
library;

import 'dart:io';

import 'package:create_agentic_app/src/project_name.dart';
import 'package:create_agentic_app/src/templates.dart';

/// What a generation attempt produced.
final class GenerationResult {
  /// Records a result.
  GenerationResult({
    required this.directory,
    required List<String> files,
    this.error,
  }) : files = List<String>.unmodifiable(files);

  /// Where the project was written.
  final String directory;

  /// The relative paths created, in order.
  final List<String> files;

  /// Why nothing was written, or `null` on success.
  final String? error;

  /// Whether a project now exists.
  bool get succeeded => error == null;

  @override
  String toString() => succeeded
      ? 'GenerationResult($directory, ${files.length} files)'
      : 'GenerationResult(failed: $error)';
}

/// Generates a project at [directory].
///
/// # Nothing is written until everything can be
///
/// The checks all happen first. A generator that creates four files and then
/// discovers the fifth cannot be written leaves a half-project that the user
/// must clean up by hand before trying again — and which `flutter run` will
/// fail on in a way that has nothing to do with the real problem.
GenerationResult generate({
  required String name,
  required String directory,
  TemplateProvider provider = TemplateProvider.openai,
  String? frameworkPath,
  bool force = false,
}) {
  final nameError = validateProjectName(name);
  if (nameError != null) {
    return GenerationResult(
      directory: directory,
      files: const <String>[],
      error: nameError,
    );
  }

  final target = Directory(directory);
  if (target.existsSync() && !force) {
    final contents = target.listSync();
    if (contents.isNotEmpty) {
      return GenerationResult(
        directory: directory,
        files: const <String>[],
        error:
            '"$directory" already exists and is not empty. Choose another '
            'name, or pass --force to write into it anyway.',
      );
    }
  }

  final files = <String, String>{
    ...buildProject(
      name: name,
      provider: provider,
      dependency: _dependencyFor(frameworkPath),
    ),
    if (frameworkPath != null)
      'pubspec_overrides.yaml': ?_siblingOverridesFor(frameworkPath),
  };

  try {
    for (final entry in files.entries) {
      final file = File('$directory${Platform.pathSeparator}${entry.key}');
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(entry.value);
    }
  } on FileSystemException catch (error) {
    return GenerationResult(
      directory: directory,
      files: const <String>[],
      error: 'Could not write the project: ${error.message}',
    );
  }

  return GenerationResult(directory: directory, files: files.keys.toList());
}

/// The pubspec fragment that pulls in the framework.
///
/// A path dependency when [frameworkPath] is given, which is how the framework's
/// own CI generates a project and proves the template still compiles against
/// the code in the working tree rather than against whatever is on pub.dev.
/// Points the framework's sibling packages at the same working tree.
///
/// A path dependency on `agentic_flutter` alone is not enough: pub applies
/// only the *root* package's overrides, so every sibling would come from
/// pub.dev, and a change spanning two packages would be compiled against the
/// published half. The framework's own `pubspec_overrides.yaml` already lists
/// the siblings; this copies it with each path made absolute.
///
/// Returns `null` when the framework has no overrides file, as a copy of the
/// published package does not.
String? _siblingOverridesFor(String frameworkPath) {
  final framework = frameworkPath.replaceAll(r'\', '/');
  final source = File('$framework/pubspec_overrides.yaml');
  if (!source.existsSync()) return null;

  final entries = RegExp(
    r'^  ([a-z_]+):\s*\n\s+path:\s*(\S+)\s*$',
    multiLine: true,
  ).allMatches(source.readAsStringSync().replaceAll('\r\n', '\n'));
  if (entries.isEmpty) return null;

  final buffer = StringBuffer()
    ..writeln('# Written by create_agentic_app --framework-path, so the')
    ..writeln('# framework packages all come from the same working tree.')
    ..writeln('dependency_overrides:');
  for (final entry in entries) {
    final relative = entry.group(2)!;
    final absolute = Uri.directory(framework).resolve(relative).path;
    // `Uri.path` gives `/D:/...` for a Windows drive; pub wants `D:/...`.
    final path = RegExp('^/[A-Za-z]:').hasMatch(absolute)
        ? absolute.substring(1)
        : absolute;
    final trimmed = path.endsWith('/')
        ? path.substring(0, path.length - 1)
        : path;
    buffer
      ..writeln('  ${entry.group(1)}:')
      ..writeln('    path: $trimmed');
  }
  return buffer.toString();
}

String _dependencyFor(String? frameworkPath) {
  if (frameworkPath == null) return '  agentic_flutter: ^0.1.0';
  final normalised = frameworkPath.replaceAll(r'\', '/');
  return '  agentic_flutter:\n    path: $normalised';
}
