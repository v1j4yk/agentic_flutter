@Tags(<String>['integration'])
library;

import 'package:agentic_integration/agentic_integration.dart';
import 'package:agentic_llm/agentic_llm.dart';
import 'package:test/test.dart';

/// These tests call real providers and spend real money.
///
/// Two gates, both required:
///
/// ```sh
/// AGENTIC_INTEGRATION=1 OPENAI_API_KEY=… dart test
/// ```
///
/// The opt-in exists because credentials alone are not consent: most people who
/// use this framework have `OPENAI_API_KEY` exported in their shell, and they
/// should not be billed for running `dart test` out of habit.
///
/// Anything without credentials is skipped with its reason attached, so the
/// output distinguishes "not configured" from "broken" — a suite that goes red
/// because a contributor has no Anthropic account is a suite people learn to
/// ignore.
void main() {
  final subjects = discoverSubjects();
  final optedOut = integrationEnabled
      ? null
      : 'Set $kOptInVariable=1 to call real providers. These tests cost money.';

  test('the run is configured to prove something', () {
    expect(
      subjects.available,
      isNotEmpty,
      reason:
          'The opt-in is set but no provider credentials were found, so this '
          'run proved nothing.\n${subjects.describeMissing()}',
    );
  }, skip: optedOut);

  for (final subject in subjects.available) {
    group(subject.name, () {
      late Set<ModelCapability> capabilities;

      setUpAll(() async {
        final model = subject.createChat();
        capabilities = model.info.capabilities;
        await model.dispose();
      });

      test(
        'completes a prompt and reports usage',
        () async {
          printOnFailure(await checkCompletion(subject));
        },
        timeout: const Timeout(Duration(minutes: 2)),
        skip: optedOut,
      );

      test(
        'streams deltas that assemble into an answer',
        () async {
          printOnFailure(await checkStreaming(subject));
        },
        timeout: const Timeout(Duration(minutes: 2)),
        skip: optedOut,
      );

      test(
        'honours a system prompt',
        () async {
          printOnFailure(await checkSystemPrompt(subject));
        },
        timeout: const Timeout(Duration(minutes: 2)),
        skip: optedOut,
      );

      test(
        'requests a tool with schema-valid arguments',
        () async {
          printOnFailure(await checkToolCalling(subject));
        },
        timeout: const Timeout(Duration(minutes: 2)),
        skip: optedOut,
      );

      test(
        'accepts a tool result and answers from it',
        () async {
          printOnFailure(await checkToolResultLoop(subject));
        },
        timeout: const Timeout(Duration(minutes: 3)),
        skip: optedOut,
      );

      test(
        'distinguishes several tool calls in one turn',
        () async {
          printOnFailure(await checkParallelToolCalls(subject));
        },
        timeout: const Timeout(Duration(minutes: 2)),
        skip: optedOut,
      );

      test(
        'produces output conforming to a schema',
        () async {
          printOnFailure(await checkStructuredOutput(subject));
        },
        timeout: const Timeout(Duration(minutes: 2)),
        skip: optedOut,
      );

      test(
        'reports a truncated answer as length',
        () async {
          printOnFailure(await checkLengthCap(subject));
        },
        timeout: const Timeout(Duration(minutes: 2)),
        skip: optedOut,
      );

      test(
        'stops streaming when cancelled',
        () async {
          printOnFailure(await checkCancellation(subject));
        },
        timeout: const Timeout(Duration(minutes: 2)),
        skip: optedOut,
      );

      test(
        'maps a rejected key to AuthenticationException',
        () async {
          printOnFailure(await checkBadKeyMapping(subject));
        },
        timeout: const Timeout(Duration(minutes: 2)),
        skip: optedOut,
      );

      // The capability checks are conditional on what the adapter claims, and
      // `skip` is computed at collection time from a value `setUpAll` fills in
      // — which is why each guarded test reads its flag inside the body rather
      // than in the `skip` argument.
      test(
        'embeds text, preserving batch order and width',
        () async {
          final create = subject.createEmbeddings;
          if (create == null) {
            markTestSkipped(
              '${subject.name} has no embedding model configured',
            );
            return;
          }
          final model = create();
          try {
            const inputs = <String>[
              'alpha',
              'beta gamma',
              'delta epsilon zeta',
            ];
            final embeddings = await model.embed(
              inputs,
              purpose: EmbeddingPurpose.document,
            );

            expect(embeddings, hasLength(inputs.length));
            for (var i = 0; i < embeddings.length; i++) {
              expect(
                embeddings[i].dimensions,
                model.dimensions,
                reason:
                    'the model reports ${model.dimensions} dimensions but '
                    'returned ${embeddings[i].dimensions}; an index built on the '
                    'declared width would reject every vector',
              );
              expect(
                embeddings[i].index,
                i,
                reason:
                    'embeddings must come back in input order — a provider that '
                    'reorders them silently pairs text with the wrong vector',
              );
            }

            // Different text must produce different vectors. A provider bug that
            // returns the same vector for everything makes retrieval return the
            // first record every time, and nothing else would notice.
            final first = embeddings[0];
            final second = embeddings[1];
            expect(first.cosineSimilarity(second), lessThan(0.999));
          } finally {
            await model.dispose();
          }
        },
        timeout: const Timeout(Duration(minutes: 2)),
        skip: optedOut,
      );

      test(
        'claims no capability it cannot demonstrate',
        () async {
          // The check with the most leverage. A declared capability that is not
          // real fails deep inside an agent loop, where the cause is invisible;
          // here it fails with the capability named.
          final outcomes = await auditProvider(subject);
          final broken = <String>[
            for (final outcome in outcomes)
              if (!outcome.passed && !outcome.skipped)
                '${outcome.check}: ${outcome.detail}',
          ];

          printOnFailure(outcomes.join('\n'));
          expect(
            broken,
            isEmpty,
            reason:
                '${subject.name} declares ${capabilities.map((c) => c.name)} '
                'but the following did not hold:\n  ${broken.join('\n  ')}',
          );
        },
        timeout: const Timeout(Duration(minutes: 10)),
        skip: optedOut,
      );
    });
  }
}
