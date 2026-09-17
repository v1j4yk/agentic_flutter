import 'dart:io';

import 'package:agentic_tools_generator/builder.dart';
import 'package:build/build.dart';
import 'package:build_test/build_test.dart';
import 'package:test/test.dart';

const String _package = 'agentic_tools_generator';

const String _imports = '''
import 'package:agentic_core/agentic_core.dart';
import 'package:agentic_tools/agentic_tools.dart';

part 'sample.g.dart';
''';

/// Builds [source] as `lib/sample.dart`, with the real framework packages
/// resolvable, and returns the generated part (or null) and every log line.
Future<({bool succeeded, String? output, String logs})> build(
  String source,
) async {
  final readerWriter = TestReaderWriter(
    rootPackage: _package,
    flattenOutput: true,
  );
  await readerWriter.testing.loadIsolateSources();
  final logs = StringBuffer();
  final result = await testBuilder(
    agentToolBuilder(BuilderOptions.empty),
    {'$_package|lib/sample.dart': source},
    rootPackage: _package,
    readerWriter: readerWriter,
    flattenOutput: true,
    onLog: (record) => logs.writeln('${record.message} ${record.error ?? ''}'),
  );
  final outputId = AssetId(_package, 'lib/sample.agent_tool.g.part');
  final output = result.outputs.contains(outputId)
      ? readerWriter.testing.readString(outputId)
      : null;
  return (succeeded: result.succeeded, output: output, logs: '$logs');
}

Matcher failsWith(String message) =>
    isA<({bool succeeded, String? output, String logs})>()
        .having((r) => r.succeeded, 'succeeded', isFalse)
        .having((r) => r.logs, 'logs', contains(message));

void main() {
  test('a library without @ToolFunction produces nothing', () async {
    final result = await build('$_imports\nString plain() => "x";\n');
    expect(result.succeeded, isTrue, reason: result.logs);
    expect(result.output, isNull);
  });

  test('the committed fixture output is up to date', () async {
    // The runtime tests compile test/fixtures/order_tools.g.dart. This proves
    // that file is what the generator writes today, so they test the real
    // output rather than a stale one.
    final fixture = File('test/fixtures/order_tools.dart')
        .readAsStringSync()
        .replaceFirst("part 'order_tools.g.dart';", "part 'sample.g.dart';");
    final result = await build(fixture);
    expect(result.succeeded, isTrue, reason: result.logs);

    // Line endings are normalised: a Windows checkout may turn the committed
    // file's LF into CRLF.
    String normalise(String code) => code
        .replaceAll('\r\n', '\n')
        .split('\n')
        .where((line) => !line.startsWith('//') && line.trim().isNotEmpty)
        .where((line) => !line.startsWith('part of'))
        .join('\n');
    final committed = File(
      'test/fixtures/order_tools.g.dart',
    ).readAsStringSync();
    expect(
      normalise(committed),
      normalise(result.output!),
      reason:
          'Run `dart run build_runner build` in this package and commit '
          'the result.',
    );
  });

  group('build errors', () {
    test('a parameter type with no JSON form', () async {
      expect(
        await build('''
$_imports
/// Waits.
@ToolFunction(isReadOnly: true)
String wait(Duration delay) => '';
'''),
        failsWith('Parameter `delay` has type `Duration`'),
      );
    });

    test('nullable list items', () async {
      expect(
        await build('''
$_imports
/// Tags.
@ToolFunction(isReadOnly: true)
String tag(List<String?> tags) => '';
'''),
        failsWith('list items must not be nullable'),
      );
    });

    test('a return type a model cannot read', () async {
      expect(
        await build('''
$_imports
/// Streams.
@ToolFunction(isReadOnly: true)
Stream<String> watch() => const Stream.empty();
'''),
        failsWith('cannot be shown to a model'),
      );
    });

    test('a nullable return', () async {
      expect(
        await build('''
$_imports
/// Finds.
@ToolFunction(isReadOnly: true)
Future<String?> find(String id) async => null;
'''),
        failsWith('may return null'),
      );
    });

    test('no description', () async {
      expect(
        await build('''
$_imports
@ToolFunction(isReadOnly: true)
String undocumented() => '';
'''),
        failsWith('has no description'),
      );
    });

    test('two tools with one name', () async {
      expect(
        await build('''
$_imports
/// One.
@ToolFunction(isReadOnly: true, name: 'lookup')
String first() => '';

/// Two.
@ToolFunction(isReadOnly: true, name: 'lookup')
String second() => '';
'''),
        failsWith('Two tools in this library are named `lookup`'),
      );
    });

    test('an unusable tool name', () async {
      expect(
        await build('''
$_imports
/// Bad.
@ToolFunction(isReadOnly: true, name: 'look up!')
String bad() => '';
'''),
        failsWith('is not usable'),
      );
    });

    test('a private function', () async {
      expect(
        await build('''
$_imports
/// Hidden.
@ToolFunction(isReadOnly: true)
String _hidden() => '';
'''),
        failsWith('is private'),
      );
    });

    test('a generic function', () async {
      expect(
        await build('''
$_imports
/// Generic.
@ToolFunction(isReadOnly: true)
String generic<T>(String id) => '';
'''),
        failsWith('is generic'),
      );
    });

    test('a generic class', () async {
      expect(
        await build('''
$_imports
class Box<T> {
  /// Opens.
  @ToolFunction(isReadOnly: true)
  String open() => '';
}
'''),
        failsWith('`Box` is generic'),
      );
    });

    test('a missing import names the import to add', () async {
      expect(
        await build('''
import 'package:agentic_tools/agentic_tools.dart';

part 'sample.g.dart';

/// Looks.
@ToolFunction(isReadOnly: true)
String look() => '';
'''),
        failsWith("import 'package:agentic_core/agentic_core.dart';"),
      );
    });

    test('isReadOnly cannot be left out', () async {
      // Required so a destructive tool is never read-only by default, which
      // would exempt it from untrusted-content approval.
      final result = await build('''
$_imports
/// Deletes.
@ToolFunction()
String delete(String id) => '';
''');
      expect(result.succeeded, isFalse);
    });
  });
}
