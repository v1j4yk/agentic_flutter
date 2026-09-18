/// OpenTelemetry export for the agentic framework.
///
/// The framework's spans are OpenTelemetry-shaped but stay inside the process
/// until something exports them. This is that something: agent, model and tool
/// spans sent over OTLP to Langfuse, Phoenix, Grafana, Honeycomb, Datadog,
/// Google Cloud Trace or a local collector.
///
/// ```dart
/// final exporter = BatchSpanExporter(
///   OtlpHttpSpanExporter(
///     endpoint: Uri.parse('https://collector.example.com/v1/traces'),
///     headers: {'authorization': 'Bearer $token'},
///     resource: const OtlpResource(serviceName: 'pocket_agent'),
///   ),
/// );
///
/// final runtime = AgenticRuntime(
///   tracer: Tracer(exporter: exporter, sampler: (name) => true),
/// );
/// ```
///
/// # What this package deliberately does not do
///
/// It does not send prompts or completions. Message content is the most
/// sensitive thing the framework touches, and a backend that shows it to
/// everyone with a dashboard login is a decision an application makes
/// deliberately — not a default that ships. `GenAiAttributes` names the keys,
/// and attaching content is a line you write.
///
/// It also does not export metrics or logs. Spans carry the timings, the token
/// counts and the failures, which is what a trace view needs; metrics are a
/// separate pipeline and a separate package when someone needs one.
library;

export 'src/batch_exporter.dart' show BatchSpanExporter;
export 'src/gen_ai.dart'
    show
        GenAiAttributes,
        GenAiOperations,
        genAiAgentAttributes,
        genAiChatAttributes,
        genAiToolAttributes;
export 'src/otlp_exporter.dart'
    show
        OtlpHttpSpanExporter,
        OtlpResource,
        encodeAttributes,
        encodeSpan,
        encodeSpans;
