// Generates a working Flutter app built on the agentic framework.
//
//   dart pub global activate create_agentic_app
//   create_agentic_app my_app
//   cd my_app && flutter create . --platforms ios,android && flutter run
//
// The generated app runs immediately in demo mode against a scripted model, so
// there is something on screen before there is an API key. That order matters:
// a template whose first run is an error message about credentials teaches the
// wrong thing about the framework and about shipping keys.
import 'dart:io';

import 'package:create_agentic_app/create_agentic_app.dart';

void main(List<String> arguments) {
  final options = _Options.parse(arguments);

  if (options.help) {
    stdout.writeln(_usage);
    return;
  }
  if (options.error != null) {
    stderr
      ..writeln(options.error)
      ..writeln()
      ..writeln(_usage);
    exitCode = 64; // EX_USAGE
    return;
  }

  final name = options.name!;
  final directory = options.directory ?? name;

  final result = generate(
    name: name,
    directory: directory,
    provider: options.provider,
    frameworkPath: options.frameworkPath,
    force: options.force,
  );

  if (!result.succeeded) {
    stderr.writeln(result.error);
    exitCode = 1;
    return;
  }

  stdout
    ..writeln('Created $name in $directory/')
    ..writeln();
  for (final file in result.files) {
    stdout.writeln('  $file');
  }
  stdout
    ..writeln()
    ..writeln('Next:')
    ..writeln()
    ..writeln('  cd $directory')
    // `flutter create .` rather than generating platform folders here: those
    // are hundreds of files of Gradle, Xcode and manifest boilerplate that
    // Flutter itself generates correctly and that would rot in a template
    // within one release.
    ..writeln('  flutter create . --platforms ios,android,macos,windows,linux')
    ..writeln('  flutter run')
    ..writeln()
    ..writeln(
      'It starts in demo mode with no key. Tap the key icon to add a '
      '${options.provider.label} key.',
    )
    ..writeln('Read lib/secrets.dart before you ship it.');
}

final class _Options {
  const _Options({
    this.name,
    this.directory,
    this.provider = TemplateProvider.openai,
    this.frameworkPath,
    this.force = false,
    this.help = false,
    this.error,
  });

  factory _Options.parse(List<String> arguments) {
    String? name;
    String? directory;
    String? frameworkPath;
    var provider = TemplateProvider.openai;
    var force = false;
    var help = false;

    for (final argument in arguments) {
      if (argument == '-h' || argument == '--help') {
        help = true;
      } else if (argument == '--force') {
        force = true;
      } else if (argument.startsWith('--provider=')) {
        final value = argument.substring('--provider='.length);
        final parsed = TemplateProvider.parse(value);
        if (parsed == null) {
          return _Options(
            error:
                'Unknown provider "$value". Choose one of: '
                '${TemplateProvider.values.map((p) => p.name).join(', ')}.',
          );
        }
        provider = parsed;
      } else if (argument.startsWith('--directory=')) {
        directory = argument.substring('--directory='.length);
      } else if (argument.startsWith('--framework-path=')) {
        frameworkPath = argument.substring('--framework-path='.length);
      } else if (argument.startsWith('-')) {
        return _Options(error: 'Unknown option "$argument".');
      } else if (name == null) {
        name = argument;
      } else {
        return _Options(error: 'Unexpected extra argument "$argument".');
      }
    }

    if (!help && name == null) {
      return const _Options(error: 'A project name is required.');
    }
    return _Options(
      name: name,
      directory: directory,
      provider: provider,
      frameworkPath: frameworkPath,
      force: force,
      help: help,
    );
  }

  final String? name;
  final String? directory;
  final TemplateProvider provider;
  final String? frameworkPath;
  final bool force;
  final bool help;
  final String? error;
}

const String _usage = '''
Generates a Flutter app built on the agentic framework.

Usage: create_agentic_app <name> [options]

  <name>                   A Dart package name: lowercase_with_underscores.

Options:
  --provider=openai        Which provider to wire up. One of:
                           openai, anthropic, gemini, ollama.
  --directory=path         Where to write it. Defaults to the project name.
  --framework-path=path    Depend on a local checkout of the framework rather
                           than on a published version. Used by the framework's
                           own CI to prove this template still compiles.
  --force                  Write into a directory that is not empty.
  -h, --help               Show this.

What you get: a chat screen, an agent with three tools, human approval for the
one that changes something, a live trace panel, and an API key kept out of the
source. It runs offline in demo mode until you add a key.''';
