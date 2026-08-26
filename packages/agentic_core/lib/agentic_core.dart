/// Foundation layer of the agentic framework.
///
/// `agentic_core` holds the vocabulary every other package speaks: messages and
/// content parts, JSON Schema, the error hierarchy, cancellation, resilience
/// policies, the event bus, structured logging and tracing, the plugin registry
/// and the run context.
///
/// It is pure Dart with two dependencies — `meta` and `collection` — and no
/// knowledge of any provider, transport or UI framework. Everything here is
/// either an immutable value object or a port that adapters implement, which is
/// what lets a Flutter app, a server and a CLI share the same domain model.
///
/// ```dart
/// import 'package:agentic_core/agentic_core.dart';
///
/// final context = AgenticContext.root(
///   logger: StructuredLogger(level: LogLevel.debug),
///   events: BroadcastEventBus(),
/// );
///
/// final history = <Message>[
///   Message.system('You are a helpful assistant.'),
///   Message.user('What is the capital of France?'),
/// ];
/// ```
///
/// Most applications depend on `agentic_flutter` instead, which re-exports this
/// library along with the agent, workflow and provider packages. Depend on
/// `agentic_core` directly when writing a plugin: a tool, a provider or a store
/// should never pull in the whole framework.
library;

// --- Cancellation ------------------------------------------------------------
export 'src/cancellation/cancellation.dart'
    show
        CancellationSubscription,
        CancellationToken,
        CancellationTokenSource,
        NullableCancellationToken;
// --- Common primitives -------------------------------------------------------
export 'src/common/agentic_id.dart'
    show IdGenerator, PrefixedIds, SequentialIdGenerator, Ulid;
export 'src/common/clock.dart' show Clock, ClockOperations, SystemClock;
export 'src/common/disposable.dart'
    show Disposable, DisposableBag, withResource;
export 'src/common/json_reader.dart' show JsonMapReader;
export 'src/common/json_types.dart'
    show JsonDecode, JsonEncode, JsonList, JsonMap, pruneNulls;
// --- Run context -------------------------------------------------------------
export 'src/context/agentic_context.dart' show AgenticContext;
export 'src/context/human_wait.dart' show HumanWaitLedger;
// --- Errors ------------------------------------------------------------------
export 'src/error/agentic_exception.dart'
    show
        AgenticException,
        AgenticTimeoutException,
        AuthenticationException,
        CancelledException,
        CapabilityNotSupportedException,
        ConfigurationException,
        InvalidStateException,
        NotFoundException,
        PermissionDeniedException,
        ProviderException,
        QuotaExceededException,
        RateLimitException,
        SerializationException,
        StorageException,
        ToolExecutionException,
        UnexpectedException,
        ValidationException;
// --- Events ------------------------------------------------------------------
export 'src/events/agentic_event.dart' show AgenticEvent, GenericEvent;
export 'src/events/event_bus.dart'
    show BroadcastEventBus, EventBus, EventBusOperations, NoopEventBus;
// --- Messaging ---------------------------------------------------------------
export 'src/messaging/content_part.dart'
    show
        AudioPart,
        ContentPart,
        FilePart,
        ImagePart,
        MediaPart,
        ReasoningPart,
        TextPart,
        ToolCallPart,
        ToolResultPart;
export 'src/messaging/message.dart'
    show ConversationHistory, Message, MessageRole;
export 'src/messaging/token_usage.dart' show TokenUsage, TokenUsageAggregation;
// --- Plugin registry ---------------------------------------------------------
export 'src/registry/registry.dart' show Registry, RegistryFactory;
// --- Resilience --------------------------------------------------------------
export 'src/resilience/backoff.dart'
    show
        BackoffStrategy,
        ConstantBackoff,
        ExponentialBackoff,
        FixedScheduleBackoff,
        Jitter,
        LinearBackoff,
        applyJitter;
export 'src/resilience/circuit_breaker.dart'
    show CircuitBreaker, CircuitOpenException, CircuitState;
export 'src/resilience/retry_policy.dart'
    show RetryListener, RetryPolicy, RetryPredicate;
// --- Result ------------------------------------------------------------------
export 'src/result/result.dart' show Err, Ok, Result, ResultFuture;
// --- Schema ------------------------------------------------------------------
export 'src/schema/json_schema.dart'
    show JsonSchema, JsonSchemaType, SchemaValidationResult, SchemaViolation;
// --- Telemetry ---------------------------------------------------------------
export 'src/telemetry/log.dart'
    show
        AgenticLogger,
        AgenticLoggerLevels,
        ConsoleLogSink,
        FieldRedactor,
        InMemoryLogSink,
        LogLevel,
        LogRecord,
        LogSink,
        MultiLogSink,
        NoopLogger,
        StructuredLogger,
        redactSensitiveFields,
        sensitiveFieldMarkers;
export 'src/telemetry/trace.dart'
    show
        InMemorySpanExporter,
        NoopSpanExporter,
        Sampler,
        Span,
        SpanData,
        SpanEvent,
        SpanExporter,
        SpanKind,
        SpanStatus,
        TraceContext,
        Tracer;
