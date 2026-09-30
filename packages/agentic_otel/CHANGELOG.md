# Changelog

## 0.3.0

Initial release, at the framework's current version.

- `OtlpHttpSpanExporter` sends spans to any OTLP endpoint over HTTP with a JSON
  body — no protobuf dependency and no build step. A failed export is reported
  through `onError` and dropped, never thrown into the code that produced the
  span: telemetry that breaks a run is worse than no telemetry.
- `BatchSpanExporter` buffers spans so export costs one request rather than one
  per span, which on a phone is one TLS handshake rather than thirty. A full
  queue drops the oldest and counts them; a rejected batch is dropped rather
  than retried into a collector that is down.
- `OtlpResource` describes what produced the spans. Setting `serviceName` is
  the difference between a usable trace view and one where everything is
  `unknown_service`.
- `GenAiAttributes`, `GenAiOperations`, and the `genAiChatAttributes`,
  `genAiToolAttributes` and `genAiAgentAttributes` helpers: the OpenTelemetry
  GenAI semantic conventions, which are what make a backend render an LLM span
  as an LLM span rather than as a generic one.
- `encodeSpans`, `encodeSpan` and `encodeAttributes` are public, so an
  application with its own transport can use the encoding without the client.

Prompts and completions are deliberately not exported. The attribute keys are
here; attaching content is a line the application writes, after deciding what
redaction applies.
