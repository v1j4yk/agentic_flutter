/// Testing for agents: recorded model answers, and evals.
///
/// Two tools for the two questions an agent test asks.
///
/// **Does my code still work?** Record a real model once with
/// `cassetteModel`, commit the file, and replay it offline in every test run
/// after. A changed prompt or tool description fails replay and says exactly
/// what changed.
///
/// ```dart
/// final model = cassetteModel(
///   'test/cassettes/support.json',
///   live: () => GeminiChatModel(apiKey: Platform.environment['GEMINI_API_KEY']!),
/// );
/// final agent = ToolCallingAgent(model: model, tools: tools, info: info);
/// expect(await agent.ask('Where is order 1042?'), contains('shipped'));
/// ```
///
/// **Does my agent behave well?** Describe good runs as checks, run them
/// repeatedly, and require a pass rate.
///
/// ```dart
/// final report = await EvalSuite(name: 'support', cases: [
///   EvalCase.text(
///     name: 'refund',
///     prompt: 'Refund order 1042, it arrived broken.',
///     checks: [
///       EvalCheck.calledTool('issue_refund'),
///       EvalCheck.didNotCallTool('delete_account'),
///     ],
///   ),
/// ]).run(agent, repeat: 5);
/// report.requirePassRate(0.8);
/// ```
library;

export 'src/cassette/cassette.dart'
    show Cassette, CassetteInteraction, CassetteMismatchError, Redactor;
export 'src/cassette/cassette_models.dart'
    show CassetteMode, RecordingChatModel, ReplayChatModel, cassetteModel;
export 'src/eval/eval_check.dart' show CheckResult, EvalCheck;
export 'src/eval/eval_suite.dart'
    show
        EvalCase,
        EvalCaseReport,
        EvalFailedError,
        EvalReport,
        EvalSuite,
        EvalTrial;
