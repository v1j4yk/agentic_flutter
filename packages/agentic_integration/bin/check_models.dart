// Checks that every model identifier this framework ships still exists.
//
//   GEMINI_API_KEY=… dart run bin/check_models.dart
//   dart run bin/check_models.dart --json
//
// # Why this is a program
//
// A model identifier is a fact about someone else's product, written down in
// our source. Providers retire models, and nothing in `dart analyze`, the
// tests or a dry run knows that a name we default to has stopped existing.
//
// This framework has already been caught twice. `gemini-2.0-flash` was retired
// while it was the default, and `text-embedding-004` after it. The second one
// is the instructive failure: an indexer records a failed document rather than
// throwing, so a dead embedding model surfaced as notes "indexed" into zero
// passages — no error, no stack trace, just an assistant that could not answer
// questions about anything.
//
// So this asks each provider what it serves and compares that against the
// names in `AnthropicModels`, `OpenAiModels`, `GeminiModels` and friends. It
// is cheap — one listing call per provider, no generation — which is why it
// can run nightly rather than at release time, when it would be too late.
//
// Providers whose key is absent are skipped, not failed: a contributor running
// this with one key should learn about that one provider.
import 'dart:convert';
import 'dart:io';

import 'package:agentic_llm/agentic_llm.dart';

Future<void> main(List<String> arguments) async {
  final asJson = arguments.contains('--json');
  final checks = <_Check>[];

  for (final provider in _providers) {
    final key = _env(provider.keyVariable);
    if (key == null) {
      checks.add(_Check.skipped(provider, 'set ${provider.keyVariable}'));
      continue;
    }
    checks.add(await _check(provider, key));
  }

  if (asJson) {
    stdout.writeln(
      const JsonEncoder.withIndent('  ').convert(<String, Object?>{
        'checkedAt': DateTime.now().toUtc().toIso8601String(),
        'providers': <Object?>[for (final check in checks) check.toJson()],
      }),
    );
  } else {
    _report(checks);
  }

  if (checks.any((check) => check.missing.isNotEmpty || check.error != null)) {
    exitCode = 1;
  }
}

/// Runs one provider's listing call and compares it with what we ship.
Future<_Check> _check(_Provider provider, String apiKey) async {
  final model = provider.build(apiKey);
  try {
    final served = <String>{
      for (final descriptor in await model.listModels()) descriptor.id,
    };
    if (served.isEmpty) {
      return _Check.failed(provider, 'the provider returned no models at all');
    }
    return _Check(
      provider: provider,
      served: served.length,
      // An alias resolves server-side and need not appear in the list, so a
      // name is only missing when nothing served starts with it either.
      missing: <String>[
        for (final expected in provider.expected)
          if (!served.contains(expected) &&
              !served.any((id) => id.startsWith(expected)))
            expected,
      ],
    );
  } on Object catch (error) {
    return _Check.failed(provider, '$error');
  } finally {
    await model.dispose();
  }
}

void _report(List<_Check> checks) {
  for (final check in checks) {
    final name = check.provider.name.padRight(10);
    if (check.skipped) {
      stdout.writeln('skip   $name ${check.note}');
      continue;
    }
    if (check.error != null) {
      stdout.writeln('error  $name ${check.error}');
      continue;
    }
    if (check.missing.isEmpty) {
      stdout.writeln(
        'ok     $name ${check.provider.expected.length} name(s) still served '
        '(of ${check.served} available)',
      );
      continue;
    }
    stdout.writeln(
      'FAIL   $name no longer serves: ${check.missing.join(', ')}\n'
      '       Update the constants in agentic_llm and any default that names '
      'one, then release: a default naming a retired model fails silently '
      'inside an indexer.',
    );
  }
}

/// One provider, the names we ship for it, and how to build a directory.
final class _Provider {
  const _Provider({
    required this.name,
    required this.keyVariable,
    required this.expected,
    required this.build,
  });

  final String name;
  final String keyVariable;
  final List<String> expected;
  final ModelDirectory Function(String apiKey) build;
}

final class _Check {
  const _Check({
    required this.provider,
    required this.served,
    required this.missing,
    this.error,
    this.note,
    this.skipped = false,
  });

  factory _Check.skipped(_Provider provider, String note) => _Check(
    provider: provider,
    served: 0,
    missing: const <String>[],
    note: note,
    skipped: true,
  );

  factory _Check.failed(_Provider provider, String error) => _Check(
    provider: provider,
    served: 0,
    missing: const <String>[],
    error: error,
  );

  final _Provider provider;
  final int served;
  final List<String> missing;
  final String? error;
  final String? note;
  final bool skipped;

  Map<String, Object?> toJson() => <String, Object?>{
    'provider': provider.name,
    'skipped': skipped,
    if (note != null) 'note': note,
    if (error != null) 'error': error,
    'expected': provider.expected,
    'missing': missing,
    'served': served,
  };
}

/// Every provider with a listing endpoint, and the names we ship for it.
///
/// DeepSeek and Mistral are here even though their adapters require `model`:
/// the constants are still ours to keep honest.
final List<_Provider> _providers = <_Provider>[
  _Provider(
    name: 'openai',
    keyVariable: 'OPENAI_API_KEY',
    expected: <String>[
      ...OpenAiModels.all,
      OpenAiModels.embeddingSmall,
      OpenAiModels.embeddingLarge,
    ],
    build: (apiKey) => OpenAiCompatibleChatModel.openAi(apiKey: apiKey),
  ),
  _Provider(
    name: 'anthropic',
    keyVariable: 'ANTHROPIC_API_KEY',
    expected: AnthropicModels.all,
    build: (apiKey) => AnthropicChatModel(apiKey: apiKey),
  ),
  _Provider(
    name: 'gemini',
    keyVariable: 'GEMINI_API_KEY',
    expected: <String>[...GeminiModels.all, GeminiModels.embedding],
    build: (apiKey) => GeminiChatModel(apiKey: apiKey),
  ),
  _Provider(
    name: 'grok',
    keyVariable: 'XAI_API_KEY',
    expected: GrokModels.all,
    build: (apiKey) => OpenAiCompatibleChatModel.grok(apiKey: apiKey),
  ),
  _Provider(
    name: 'deepseek',
    keyVariable: 'DEEPSEEK_API_KEY',
    expected: DeepSeekModels.all,
    build: (apiKey) => OpenAiCompatibleChatModel.deepSeek(
      apiKey: apiKey,
      model: DeepSeekModels.flash,
    ),
  ),
  _Provider(
    name: 'mistral',
    keyVariable: 'MISTRAL_API_KEY',
    expected: MistralModels.all,
    build: (apiKey) => OpenAiCompatibleChatModel.mistral(
      apiKey: apiKey,
      model: MistralModels.medium,
    ),
  ),
];

/// Reads an environment variable, treating blank as absent — an unset CI
/// secret expands to the empty string rather than being absent.
String? _env(String name) {
  final value = Platform.environment[name];
  return value == null || value.trim().isEmpty ? null : value.trim();
}
