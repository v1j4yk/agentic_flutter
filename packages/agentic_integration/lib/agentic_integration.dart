/// A conformance suite run against real providers.
///
/// ```sh
/// # Nothing calls a provider without the opt-in: these tests spend money.
/// AGENTIC_INTEGRATION=1 OPENAI_API_KEY=… dart test
///
/// # The capability matrix, as a table or as JSON.
/// OPENAI_API_KEY=… dart run bin/audit.dart
/// ```
///
/// The unit tests in this package — the ones that verify the harness itself —
/// run normally and need no credentials.
library;

export 'src/conformance.dart'
    show
        ConformanceOutcome,
        auditProvider,
        checkBadKeyMapping,
        checkCancellation,
        checkCompletion,
        checkLengthCap,
        checkParallelToolCalls,
        checkStreaming,
        checkStructuredOutput,
        checkSystemPrompt,
        checkToolCalling,
        checkToolResultLoop,
        personSchema,
        timeTool,
        weatherTool;
export 'src/subjects.dart'
    show
        MissingSubject,
        ProviderSubject,
        SubjectSet,
        discoverSubjects,
        env,
        integrationEnabled,
        kOptInVariable;
