import 'dart:io';

import 'package:create_agentic_app/create_agentic_app.dart';
import 'package:test/test.dart';

/// These verify the generator, not the generated app.
///
/// Whether the templates *compile* is a different question, and one no unit
/// test can answer: the templates are strings, so the analyser never sees them.
/// CI generates a project and runs `flutter analyze` and `flutter test` over
/// the result, which is the only thing keeping them honest — and which caught
/// two missing imports the first time it ran.
void main() {
  late Directory temporary;

  setUp(() {
    temporary = Directory.systemTemp.createTempSync('create_agentic_app_test');
  });

  tearDown(() {
    if (temporary.existsSync()) temporary.deleteSync(recursive: true);
  });

  String pathTo(String name) =>
      '${temporary.path}${Platform.pathSeparator}$name';

  group('project names', () {
    test('accepts a conventional name', () {
      expect(validateProjectName('my_notes_app'), isNull);
      expect(validateProjectName('app'), isNull);
      expect(validateProjectName('a1_b2'), isNull);
    });

    test('rejects the mistakes people actually make, with a suggestion', () {
      // Each of these fails later, from pub, with a message about a pubspec the
      // user did not write. Catching them first turns that into a sentence.
      expect(validateProjectName('My App'), contains('my_app'));
      expect(validateProjectName('my-notes-app'), contains('my_notes_app'));
      expect(validateProjectName('MyApp'), contains('lowercase'));
    });

    test('rejects names that would not import', () {
      expect(validateProjectName('1st_app'), isNotNull);
      expect(validateProjectName('my__app'), contains('double underscore'));
      expect(validateProjectName('my_app_'), contains('underscore'));
      expect(validateProjectName(''), isNotNull);
    });

    test('rejects a Dart reserved word', () {
      expect(validateProjectName('class'), contains('reserved'));
      expect(validateProjectName('extension'), contains('reserved'));
    });

    test('rejects a name that would collide with the framework', () {
      // `agentic_core` as a project name produces a library that cannot be
      // imported alongside the real one — a confusing afternoon.
      expect(validateProjectName('agentic_core'), contains('collides'));
    });

    test('derives a readable title', () {
      expect(titleFor('my_notes_app'), 'My Notes App');
      expect(titleFor('app'), 'App');
    });
  });

  group('generation', () {
    test('writes every file a Flutter project needs', () {
      final result = generate(name: 'my_app', directory: pathTo('my_app'));

      expect(result.succeeded, isTrue);
      expect(
        result.files,
        containsAll(<String>[
          'pubspec.yaml',
          'analysis_options.yaml',
          '.gitignore',
          'README.md',
          'lib/main.dart',
          'test/widget_test.dart',
        ]),
      );
      for (final file in result.files) {
        expect(
          File(
            '${pathTo('my_app')}${Platform.pathSeparator}$file',
          ).existsSync(),
          isTrue,
          reason: '$file was listed but not written',
        );
      }
    });

    test('occupies the test filename flutter create would claim', () {
      // The README tells you to run `flutter create .` to add platform
      // folders. That command writes its own counter-app widget test
      // referencing a `MyApp` this template does not have — but only when the
      // file is absent. Shipping the name is what keeps a freshly generated
      // project's `flutter test` green, and only running both commands in
      // that order ever showed it.
      final files = buildProject(
        name: 'my_app',
        provider: TemplateProvider.openai,
        dependency: '  agentic_flutter: ^0.1.0',
      );
      expect(files.keys, contains('test/widget_test.dart'));
      expect(files.keys, isNot(contains('test/app_test.dart')));
      expect(files['test/widget_test.dart'], isNot(contains('MyApp')));
    });

    test('substitutes the name everywhere it appears', () {
      generate(name: 'my_notes_app', directory: pathTo('my_notes_app'));

      final pubspec = File(
        '${pathTo('my_notes_app')}${Platform.pathSeparator}pubspec.yaml',
      ).readAsStringSync();
      expect(pubspec, contains('name: my_notes_app'));

      final test = File(
        '${pathTo('my_notes_app')}${Platform.pathSeparator}test'
        '${Platform.pathSeparator}widget_test.dart',
      ).readAsStringSync();
      expect(test, contains('package:my_notes_app/tools.dart'));

      final main = File(
        '${pathTo('my_notes_app')}${Platform.pathSeparator}lib'
        '${Platform.pathSeparator}main.dart',
      ).readAsStringSync();
      expect(main, contains('My Notes App'));
    });

    test('leaves no placeholder unfilled', () {
      // The failure this guards: a template gains a `__THING__` and nobody
      // notices until a user reads it in their own source file.
      final files = buildProject(
        name: 'my_app',
        provider: TemplateProvider.gemini,
        dependency: '  agentic_flutter: ^0.1.0',
      );

      for (final entry in files.entries) {
        expect(
          entry.value,
          isNot(contains('__')),
          reason: '${entry.key} still contains a placeholder',
        );
      }
    });

    test('wires the provider that was asked for', () {
      for (final provider in TemplateProvider.values) {
        final files = buildProject(
          name: 'my_app',
          provider: provider,
          dependency: '  agentic_flutter: ^0.1.0',
        );
        final agent = files['lib/agent.dart']!;

        expect(agent, contains(provider.keyName));
        expect(
          files['lib/screens/settings_screen.dart'],
          contains(provider.label),
        );
      }
    });

    test('a version constraint by default, a path when asked', () {
      final published = buildProject(
        name: 'my_app',
        provider: TemplateProvider.openai,
        dependency: '  agentic_flutter: ^0.1.0',
      )['pubspec.yaml']!;
      expect(published, contains('agentic_flutter: ^0.1.0'));

      generate(
        name: 'my_app',
        directory: pathTo('local'),
        frameworkPath: '/some/where/agentic_flutter',
      );
      final local = File(
        '${pathTo('local')}${Platform.pathSeparator}pubspec.yaml',
      ).readAsStringSync();
      expect(local, contains('path: /some/where/agentic_flutter'));
    });

    test('normalises a Windows path into the pubspec', () {
      // A backslash in YAML is an escape, so a Windows path written verbatim
      // produces a pubspec that does not parse.
      generate(
        name: 'my_app',
        directory: pathTo('windows'),
        frameworkPath: r'D:\code\agentic_flutter',
      );
      final pubspec = File(
        '${pathTo('windows')}${Platform.pathSeparator}pubspec.yaml',
      ).readAsStringSync();

      expect(pubspec, contains('D:/code/agentic_flutter'));
      expect(pubspec, isNot(contains(r'\')));
    });
  });

  group('refusals', () {
    test('an invalid name writes nothing', () {
      final result = generate(name: 'My App', directory: pathTo('My App'));

      expect(result.succeeded, isFalse);
      expect(Directory(pathTo('My App')).existsSync(), isFalse);
    });

    test('a non-empty directory is refused, and says how to override', () {
      final directory = Directory(pathTo('taken'))..createSync(recursive: true);
      File(
        '${directory.path}${Platform.pathSeparator}keep.txt',
      ).writeAsStringSync('important');

      final result = generate(name: 'my_app', directory: directory.path);

      expect(result.succeeded, isFalse);
      expect(result.error, contains('--force'));
      expect(
        File(
          '${directory.path}${Platform.pathSeparator}keep.txt',
        ).readAsStringSync(),
        'important',
        reason: 'a refusal must not touch what is already there',
      );
    });

    test('--force writes into a non-empty directory', () {
      final directory = Directory(pathTo('forced'))
        ..createSync(recursive: true);
      File(
        '${directory.path}${Platform.pathSeparator}keep.txt',
      ).writeAsStringSync('important');

      final result = generate(
        name: 'my_app',
        directory: directory.path,
        force: true,
      );

      expect(result.succeeded, isTrue);
      expect(
        File('${directory.path}${Platform.pathSeparator}keep.txt').existsSync(),
        isTrue,
        reason: 'force means "write alongside", not "delete what is there"',
      );
    });

    test('an empty existing directory is fine', () {
      Directory(pathTo('empty')).createSync(recursive: true);
      expect(
        generate(name: 'my_app', directory: pathTo('empty')).succeeded,
        isTrue,
      );
    });
  });

  group('what the template teaches', () {
    late Map<String, String> files;

    setUp(() {
      files = buildProject(
        name: 'my_app',
        provider: TemplateProvider.openai,
        dependency: '  agentic_flutter: ^0.1.0',
      );
    });

    test('the agent is bounded', () {
      // The characteristic failure of an agentic app is not a crash; it is a
      // loop that runs correctly and forever. A template without a budget
      // teaches that this is optional.
      expect(files['lib/agent.dart'], contains('AgentBudget'));
    });

    test('runs stop when the app leaves the screen', () {
      expect(files['lib/main.dart'], contains('cancelOnPause'));
    });

    test('a mutating tool requires approval', () {
      expect(files['lib/tools.dart'], contains('requiresApproval: true'));
      expect(files['lib/tools.dart'], contains('isReadOnly: false'));
    });

    test('no key is ever written into the source', () {
      for (final entry in files.entries) {
        expect(
          entry.value,
          isNot(matches(RegExp('sk-[A-Za-z0-9]{10,}'))),
          reason: '${entry.key} looks like it contains a real key',
        );
      }
      expect(files['lib/secrets.dart'], contains('SecretStore'));
    });

    test('the security posture is stated, not implied', () {
      final secrets = files['lib/secrets.dart']!;
      expect(secrets, contains('APK is a zip file'));
      expect(secrets, contains('flutter_secure_storage'));
      expect(files['README.md'], contains('Before you ship'));
    });

    test('the generated test needs no credentials', () {
      final test = files['test/widget_test.dart']!;
      expect(test, contains('offline'));
      expect(
        test,
        isNot(contains('API_KEY')),
        reason: 'a template whose test needs a key is a test nobody runs',
      );
    });
  });
}
