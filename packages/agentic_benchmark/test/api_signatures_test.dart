import 'dart:io';

import 'package:agentic_benchmark/src/api_signatures.dart';
import 'package:agentic_benchmark/src/api_surface.dart';
import 'package:test/test.dart';

void main() {
  group('SignatureDiff', () {
    ApiSignatures signatures(Map<String, String> lines) =>
        ApiSignatures(package: 'p', lines: lines);

    test('tells a changed declaration from a removed one', () {
      final diff = SignatureDiff(
        before: signatures({
          'Foo': 'final class Foo',
          'Foo.new': 'Foo({int? a})',
          'Foo.bar': 'void bar()',
        }),
        after: signatures({
          'Foo': 'final class Foo',
          'Foo.new': 'Foo({required int a})',
          'Foo.baz': 'void baz()',
        }),
      );

      expect(diff.changed, ['Foo.new']);
      expect(diff.removed, ['Foo.bar']);
      expect(diff.added, ['Foo.baz']);
      expect(diff.render(), contains('was: Foo({int? a})'));
      expect(diff.render(), contains('now: Foo({required int a})'));
    });

    test('an identical snapshot has no changes', () {
      final lines = {'Foo': 'final class Foo'};
      final diff = SignatureDiff(
        before: signatures(lines),
        after: signatures(lines),
      );
      expect(diff.hasChanges, isFalse);
      expect(diff.render(), contains('unchanged'));
    });

    test('render and parse round-trip, including colons in signatures', () {
      final original = signatures({
        'Foo.map': 'Map<String, Object?> map({String key = "a: b"})',
        'Foo': 'final class Foo',
      });
      final parsed = ApiSignatures.parse('p', original.render());
      expect(parsed.lines, original.lines);
      expect(parsed.lines.keys.first, 'Foo', reason: 'sorted by key');
    });
  });

  group('reading real packages', () {
    final root = Directory.current.path.endsWith('agentic_benchmark')
        ? '../..'
        : '.';
    late Map<String, ApiSignatures> read;

    setUpAll(() async {
      read = await readSignatures(<String, String>{
        'agentic_core': '$root/packages/agentic_core/lib/agentic_core.dart',
        'agentic_tools': '$root/packages/agentic_tools/lib/agentic_tools.dart',
        'agentic_agents':
            '$root/packages/agentic_agents/lib/agentic_agents.dart',
      });
    });

    test('records constructor parameters, requiredness and defaults', () {
      final line = read['agentic_tools']!.lines['ToolFunction.new']!;
      expect(line, startsWith('const ToolFunction({'));
      expect(line, contains('required bool isReadOnly'));
      expect(line, contains('bool requiresApproval = false'));
    });

    test('records class modifiers, supertypes and enum values', () {
      final tools = read['agentic_tools']!.lines;
      expect(tools['Tool'], 'abstract interface class Tool');
      expect(
        tools['RenamedTool'],
        'final class RenamedTool extends DelegatingTool',
      );
      expect(
        tools['UntrustedContentPolicy.values'],
        'requireApproval, refuse, allow',
      );
      expect(
        read['agentic_core']!.lines['ContentPart'],
        'sealed class ContentPart',
      );
    });

    test('records methods, getters, typedefs and extensions', () {
      final core = read['agentic_core']!.lines;
      expect(
        core['CancellationSubscription'],
        'typedef CancellationSubscription = void Function()',
      );
      expect(
        core['ConversationHistory'],
        'extension ConversationHistory on List<Message>',
      );
      expect(
        read['agentic_tools']!.lines['ToolExecutor.execute'],
        'Future<ToolResult> execute(ToolCallPart call, '
        '{required AgenticContext context})',
      );
      expect(
        read['agentic_tools']!
            .lines['ToolApprovalRequest.followsUntrustedContent'],
        'bool get followsUntrustedContent',
      );
    });

    test('leaves out private members and Object overrides', () {
      final keys = read['agentic_tools']!.lines.keys;
      expect(keys.where((k) => k.contains('._')), isEmpty);
      expect(keys.where((k) => k.endsWith('.toString')), isEmpty);
    });

    test('leaves out declarations another package made', () {
      // agentic_agents uses core and tools types but must not repeat them.
      final agents = read['agentic_agents']!.lines.keys;
      expect(agents, isNot(contains('ToolExecutor')));
      expect(agents, contains('ToolCallingAgent'));
    });

    test('match the committed snapshots', () async {
      // The unit-test CI job has no Flutter SDK, so agentic_flutter cannot be
      // resolved there; the `api-surface` job, which has it, checks it.
      final all = await readSignatures(<String, String>{
        for (final entry in trackedPackages.entries)
          if (File('$root/${packageConfigFor(entry.value)}').existsSync())
            entry.key: '$root/${entry.value}',
      });
      final changed = <String>[
        for (final entry in all.entries)
          if (SignatureDiff(
                before: ApiSignatures.parse(
                  entry.key,
                  File(
                    '$root/${signaturePathFor(entry.key)}',
                  ).readAsStringSync(),
                ),
                after: entry.value,
              )
              case final diff when diff.hasChanges)
            diff.render(),
      ];
      expect(
        changed,
        isEmpty,
        reason:
            'Public signatures changed:\n${changed.join('\n')}\n\nIf intended, '
            'record them with `dart run agentic_benchmark:api_snapshot --write`.',
      );
    }, timeout: const Timeout(Duration(minutes: 5)));
  });
}
