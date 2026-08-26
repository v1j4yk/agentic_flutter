/// Micro-benchmarks for the agentic framework.
///
/// ```sh
/// dart run agentic_benchmark                     # everything
/// dart run agentic_benchmark vector              # one layer
/// dart run agentic_benchmark --save-baseline     # record the current numbers
/// dart run agentic_benchmark --baseline          # compare against them
/// ```
///
/// The point is not the absolute numbers, which depend on the machine. It is
/// the comparison: a change that makes `agents.turn.oneToolCall` forty per cent
/// slower should be a line in a pull request, not something discovered in
/// production six weeks later.
library;

export 'src/api_surface.dart'
    show ApiDiff, ApiSurface, kUnshownMarker, snapshotPathFor, trackedPackages;
export 'src/harness.dart'
    show Benchmark, BenchmarkResult, BenchmarkRunner, BenchmarkSuite;
export 'src/reporting.dart'
    show
        BenchmarkComparison,
        BenchmarkReport,
        BenchmarkVerdict,
        renderComparison,
        renderTable;
export 'src/suites/core_suite.dart' show coreSuite;
export 'src/suites/pipeline_suite.dart'
    show agentsSuite, llmSuite, mcpSuite, toolsSuite;
export 'src/suites/retrieval_suite.dart'
    show memorySuite, retrievalSuite, vectorSuite;
