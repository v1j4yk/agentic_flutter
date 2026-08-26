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

  final files = buildProject(
    name: name,
    provider: provider,
    dependency: _dependencyFor(frameworkPath),
  );

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
String _dependencyFor(String? frameworkPath) {
  if (frameworkPath == null) return '  agentic_flutter: ^0.1.0';
  final normalised = frameworkPath.replaceAll(r'\', '/');
  return '  agentic_flutter:\n    path: $normalised';
}
