import 'package:agentic_benchmark/agentic_benchmark.dart';
import 'package:agentic_core/agentic_core.dart';
import 'package:test/test.dart';

BenchmarkResult resultOf(String name, int medianUs) => BenchmarkResult(
  name: name,
  description: '',
  count: 100,
  minUs: medianUs,
  medianUs: medianUs,
  p90Us: medianUs,
  p99Us: medianUs,
  maxUs: medianUs,
);

BenchmarkReport reportOf(List<BenchmarkResult> results) => BenchmarkReport(
  results: results,
  dartVersion: '3.11.0',
  platform: 'test-x64',
  recordedAt: DateTime.utc(2026),
);

void main() {
  group('BenchmarkResult', () {
    test('percentiles come from the sorted samples', () {
      final result = BenchmarkResult.fromSamples(
        name: 'x',
        description: '',
        // Deliberately unsorted: a harness that assumes order is a harness that
        // reports the wrong percentile the first time somebody feeds it a list.
        samples: <int>[50, 10, 40, 20, 30, 60, 70, 80, 90, 100],
      );

      expect(result.count, 10);
      expect(result.minUs, 10);
      expect(result.maxUs, 100);
      expect(result.medianUs, 50);
      expect(result.p90Us, 90);
      expect(result.p99Us, 100);
    });

    test('a percentile is always a value that was measured', () {
      // Nearest rank, not interpolation. A reader who takes the number to a
      // profiler should be looking for a duration that actually happened.
      final result = BenchmarkResult.fromSamples(
        name: 'x',
        description: '',
        samples: <int>[1, 2, 3],
      );
      for (final value in <int>[
        result.minUs,
        result.medianUs,
        result.p90Us,
        result.p99Us,
        result.maxUs,
      ]) {
        expect(<int>[1, 2, 3], contains(value));
      }
    });

    test('refuses to summarise nothing', () {
      expect(
        () => BenchmarkResult.fromSamples(
          name: 'x',
          description: '',
          samples: const <int>[],
        ),
        throwsA(isA<ValidationException>()),
      );
    });

    test('reports the tail ratio', () {
      final result = BenchmarkResult(
        name: 'x',
        description: '',
        count: 100,
        minUs: 5,
        medianUs: 10,
        p90Us: 20,
        p99Us: 40,
        maxUs: 50,
      );
      expect(result.tailRatio, 4);
      expect(result.opsPerSecond, closeTo(100000, 1));
    });

    test('round-trips through JSON', () {
      final original = BenchmarkResult.fromSamples(
        name: 'core.thing',
        description: 'A thing.',
        samples: <int>[1, 2, 3, 4, 5],
      );
      final restored = BenchmarkResult.fromJson(original.toJson());

      expect(restored.name, original.name);
      expect(restored.medianUs, original.medianUs);
      expect(restored.p99Us, original.p99Us);
      expect(restored.count, original.count);
    });
  });

  group('Benchmark', () {
    test('builds the fixture once and hands it to every iteration', () async {
      var setups = 0;
      var runs = 0;
      var teardowns = 0;

      await Benchmark<int>(
        name: 'x',
        description: '',
        setup: () => ++setups,
        run: (fixture) {
          expect(fixture, 1);
          runs++;
        },
        teardown: (_) => teardowns++,
        iterations: 10,
        warmup: 3,
      ).measure();

      expect(setups, 1);
      expect(runs, 13, reason: 'warmup runs too, it is just not measured');
      expect(teardowns, 1);
    });

    test('only the measured iterations become samples', () async {
      final result = await Benchmark<void>(
        name: 'x',
        description: '',
        setup: () {},
        run: (_) {},
        iterations: 25,
        warmup: 5,
      ).measure();

      expect(result.count, 25);
    });

    test('releases the fixture even when the body throws', () async {
      var released = false;
      await expectLater(
        Benchmark<int>(
          name: 'x',
          description: '',
          setup: () => 1,
          run: (_) => throw StateError('boom'),
          teardown: (_) => released = true,
          iterations: 1,
          warmup: 0,
        ).measure(),
        throwsStateError,
      );
      expect(released, isTrue);
    });

    test('measures elapsed time rather than iteration count', () async {
      final result = await Benchmark<void>(
        name: 'x',
        description: '',
        setup: () {},
        run: (_) => Future<void>.delayed(const Duration(milliseconds: 5)),
        iterations: 3,
        warmup: 0,
      ).measure();

      // Loose bounds on purpose: a tight assertion on wall time is a flaky
      // test, and the property under test is only that real time is measured.
      expect(result.medianUs, greaterThan(3000));
    });
  });

  group('BenchmarkRunner', () {
    BenchmarkSuite suiteOf(List<String> names) => BenchmarkSuite(
      name: 'suite',
      benchmarks: <Benchmark<Object?>>[
        for (final name in names)
          Benchmark<void>(
            name: name,
            description: '',
            setup: () {},
            run: (_) {},
            iterations: 2,
            warmup: 0,
          ),
      ],
    );

    test('runs everything when there is no filter', () async {
      final results = await const BenchmarkRunner().run(<BenchmarkSuite>[
        suiteOf(<String>['a.one', 'b.two']),
      ]);
      expect(results.map((r) => r.name), <String>['a.one', 'b.two']);
    });

    test('a filter selects a layer or a single benchmark', () async {
      final suites = <BenchmarkSuite>[
        suiteOf(<String>['vector.search.1k', 'vector.upsert', 'rag.chunk']),
      ];

      expect(
        (await const BenchmarkRunner().run(suites, filter: 'vector')).length,
        2,
      );
      expect(
        (await const BenchmarkRunner().run(
          suites,
          filter: 'vector.search.1k',
        )).single.name,
        'vector.search.1k',
      );
    });

    test('reports progress as it goes', () async {
      final seen = <String>[];
      await BenchmarkRunner(onProgress: seen.add).run(<BenchmarkSuite>[
        suiteOf(<String>['a', 'b']),
      ]);
      expect(seen, <String>['a', 'b']);
    });
  });

  group('comparison', () {
    test('a change within tolerance is not a regression', () {
      final comparisons = reportOf(<BenchmarkResult>[
        resultOf('x', 110),
      ]).compareWith(reportOf(<BenchmarkResult>[resultOf('x', 100)]));

      expect(comparisons.single.verdict, BenchmarkVerdict.unchanged);
      expect(comparisons.single.changePercent, closeTo(10, 0.01));
    });

    test('a change beyond tolerance is', () {
      final comparisons = reportOf(<BenchmarkResult>[
        resultOf('x', 150),
      ]).compareWith(reportOf(<BenchmarkResult>[resultOf('x', 100)]));

      expect(comparisons.single.verdict, BenchmarkVerdict.slower);
      expect(comparisons.single.verdict.isRegression, isTrue);
    });

    test('an improvement is reported but never fails a run', () {
      final comparisons = reportOf(<BenchmarkResult>[
        resultOf('x', 40),
      ]).compareWith(reportOf(<BenchmarkResult>[resultOf('x', 100)]));

      expect(comparisons.single.verdict, BenchmarkVerdict.faster);
      expect(comparisons.single.verdict.isRegression, isFalse);
    });

    test('a tighter tolerance catches a smaller change', () {
      final comparisons = reportOf(<BenchmarkResult>[resultOf('x', 110)])
          .compareWith(
            reportOf(<BenchmarkResult>[resultOf('x', 100)]),
            tolerance: 0.05,
          );
      expect(comparisons.single.verdict, BenchmarkVerdict.slower);
    });

    test('a rename shows as both removed and added, not as silence', () {
      // The failure this guards: a renamed benchmark quietly loses its history
      // and looks like it was never measured.
      final comparisons = reportOf(<BenchmarkResult>[
        resultOf('x.new', 100),
      ]).compareWith(reportOf(<BenchmarkResult>[resultOf('x.old', 100)]));

      expect(
        comparisons.map((c) => c.verdict),
        containsAll(<BenchmarkVerdict>[
          BenchmarkVerdict.added,
          BenchmarkVerdict.removed,
        ]),
      );
      expect(comparisons.any((c) => c.verdict.isRegression), isFalse);
    });

    test('a report round-trips through its baseline format', () {
      final report = reportOf(<BenchmarkResult>[
        resultOf('a', 10),
        resultOf('b', 20),
      ]);
      final restored = BenchmarkReport.fromJson(report.toJson());

      expect(restored.platform, 'test-x64');
      expect(restored.dartVersion, '3.11.0');
      expect(restored['b']!.medianUs, 20);
      expect(restored['missing'], isNull);
    });
  });

  group('rendering', () {
    test('a table names every benchmark it was given', () {
      final table = renderTable(<BenchmarkResult>[
        resultOf('vector.search.10k', 24000),
      ]);
      expect(table, contains('vector.search.10k'));
      expect(table, contains('24.00ms'));
    });

    test('a fast benchmark is never flagged for tail latency', () {
      // At a 1 µs median, one tick of scheduler noise reads as "4x slower".
      // Flagging that would mean flagging every fast benchmark, which is the
      // same as flagging none.
      final table = renderTable(<BenchmarkResult>[
        BenchmarkResult(
          name: 'core.fast',
          description: '',
          count: 100,
          minUs: 1,
          medianUs: 1,
          p90Us: 3,
          p99Us: 10,
          maxUs: 12,
        ),
      ]);
      expect(table, isNot(contains('Tail latency')));
    });

    test('a slow benchmark with a real spike is flagged', () {
      final table = renderTable(<BenchmarkResult>[
        BenchmarkResult(
          name: 'vector.search',
          description: '',
          count: 100,
          minUs: 900,
          medianUs: 1000,
          p90Us: 2000,
          p99Us: 9000,
          maxUs: 9500,
        ),
      ]);
      expect(table, contains('Tail latency'));
      expect(table, contains('9.0x'));
    });

    test('an empty run says so rather than printing a bare header', () {
      expect(renderTable(const <BenchmarkResult>[]), contains('No benchmarks'));
    });

    test('a comparison names the regressions', () {
      final comparisons =
          reportOf(<BenchmarkResult>[
            resultOf('slow.one', 200),
            resultOf('fine.two', 100),
          ]).compareWith(
            reportOf(<BenchmarkResult>[
              resultOf('slow.one', 100),
              resultOf('fine.two', 100),
            ]),
          );

      final rendered = renderComparison(comparisons);
      expect(rendered, contains('slow.one'));
      expect(rendered, contains('+100.0%'));
      expect(rendered, contains('1 regression(s)'));
    });

    test('a clean comparison says so', () {
      final comparisons = reportOf(<BenchmarkResult>[
        resultOf('x', 100),
      ]).compareWith(reportOf(<BenchmarkResult>[resultOf('x', 100)]));
      expect(renderComparison(comparisons), contains('No regression'));
    });
  });

  group('the suites themselves', () {
    test('every benchmark has a unique, dotted name', () {
      final names = <String>[
        for (final suite in <BenchmarkSuite>[
          coreSuite(),
          toolsSuite(),
          llmSuite(),
          agentsSuite(),
          memorySuite(),
          vectorSuite(),
          retrievalSuite(),
          mcpSuite(),
        ])
          for (final benchmark in suite.benchmarks) benchmark.name,
      ];

      expect(names, isNotEmpty);
      expect(
        names.toSet().length,
        names.length,
        reason:
            'a duplicate name means one benchmark overwrites the other in '
            'the baseline',
      );
      for (final name in names) {
        expect(name, contains('.'), reason: '$name should be layer-qualified');
      }
    });

    test('every benchmark explains what it measures', () {
      for (final suite in <BenchmarkSuite>[coreSuite(), vectorSuite()]) {
        for (final benchmark in suite.benchmarks) {
          expect(
            benchmark.description.length,
            greaterThan(30),
            reason: '${benchmark.name} needs a description a reader can use',
          );
        }
      }
    });
  });
}
