// Demonstrates `create_agentic_app` as a library rather than as a CLI.
//
// Run it with:
//
//     dart run example/create_agentic_app_example.dart
//
// Most people will reach this package through `create_agentic_app my_app` on
// the command line. The library underneath is public for the cases the CLI
// does not cover: a tool that scaffolds several projects, a test that wants to
// assert what the template emits, an internal generator that starts from these
// files and then adds its own.
//
// Nothing here writes to disk except the final step, which uses a temporary
// directory and removes it again.
import 'dart:io';

import 'package:create_agentic_app/create_agentic_app.dart';

void main() {
  _names();
  _filesWithoutWritingThem();
  _providersDifferWhereItMatters();
  _generateToDisk();
}

/// A project name is a Dart package name, and the rules are not obvious.
///
/// Checking before generating is the difference between a clear message and a
/// half-written directory that does not compile.
void _names() {
  print('--- names ---');

  for (final candidate in <String>[
    'my_app',
    'My App',
    'agentic_thing',
    'class',
    '2fast',
  ]) {
    final problem = validateProjectName(candidate);
    print(
      problem == null
          ? '  ok        $candidate  ->  "${titleFor(candidate)}"'
          : '  rejected  $candidate  ->  $problem',
    );
  }
}

/// Every file the template would write, as strings.
///
/// The CLI writes these to disk; getting them as a map first is what lets a
/// caller inspect, transform or test them without a filesystem.
void _filesWithoutWritingThem() {
  print('\n--- files ---');

  final files = buildProject(
    name: 'field_notes',
    provider: TemplateProvider.gemini,
    dependency: '  agentic_flutter: ^0.1.0',
  );

  for (final path in files.keys.toList()..sort()) {
    print('  ${path.padRight(34)} ${files[path]!.length} bytes');
  }
}

/// The provider changes the model, the key name and the prose around it.
///
/// One template, four wirings — which is why the provider is a parameter
/// rather than four copies of the same project.
void _providersDifferWhereItMatters() {
  print('\n--- providers ---');

  for (final provider in TemplateProvider.values) {
    final agent = buildProject(
      name: 'field_notes',
      provider: provider,
      dependency: '  agentic_flutter: ^0.1.0',
    )['lib/agent.dart']!;

    final model = RegExp(r'model: (.+),').firstMatch(agent)?.group(1);
    print(
      '  ${provider.name.padRight(10)} '
      'key=${provider.keyName.padRight(18)} '
      'needsKey=${provider.needsKey}',
    );
    print('    $model');
  }
}

/// The whole thing, onto disk, then cleaned up.
void _generateToDisk() {
  print('\n--- generating ---');

  final directory = Directory.systemTemp.createTempSync('create_agentic_app_');
  try {
    final result = generate(
      name: 'field_notes',
      directory: directory.path,
      provider: TemplateProvider.gemini,
      force: true,
    );

    if (!result.succeeded) {
      print('  failed: ${result.error}');
      return;
    }

    print('  wrote ${result.files.length} files to a temporary directory');
    for (final file in result.files) {
      print('    $file');
    }
    print(
      '\n  Next, in a real project: `flutter create . --platforms android` '
      'then `flutter run`.',
    );
    print(
      '  It starts in demo mode against a scripted model, so it runs before '
      'there is a key.',
    );
  } finally {
    // A generator whose example leaves a project behind in the temp directory
    // is teaching the wrong lesson about cleaning up after itself.
    directory.deleteSync(recursive: true);
  }
}
