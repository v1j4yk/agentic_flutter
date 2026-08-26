/// The framework-wide error hierarchy.
///
/// # Why a hierarchy and not `Result` everywhere
///
/// Dart's asynchronous idiom is exceptions: `await` propagates them, `try` /
/// `catch` handles them, and every SDK a Flutter developer already uses throws.
/// Returning `Result` from every method would force call sites into
/// `switch (await x)` ladders that no Flutter developer wants to write, and it
/// composes badly with `Stream`, which has its own error channel.
///
/// So the framework throws, and does it in a disciplined way:
///
/// * every failure is an [AgenticException] with a stable, machine-readable
///   [AgenticException.code];
/// * every failure declares whether retrying could plausibly help through
///   [AgenticException.isRetryable], so retry policies never have to
///   pattern-match on provider-specific error strings;
/// * every failure can be serialised for logs, traces and crash reports.
///
/// Callers who prefer explicit, value-level error handling are not left out:
/// `Result.guard` in `package:agentic_core/agentic_core.dart` converts any
/// throwing computation into a value. That keeps `Result` available as an
/// opt-in at boundaries where it genuinely reads better without imposing it on
/// the whole API surface.
///
/// # Why `base` and not `sealed`
///
/// `sealed` would enable exhaustive switches but would also make it impossible
/// for a third-party provider, tool or vector-store package to introduce its
/// own error type, because Dart requires every subtype of a sealed class to
/// live in the same library. A plugin framework cannot close that door.
///
/// `abstract base class` is the correct trade-off: any package may `extend`
/// [AgenticException] to add a domain-specific failure, while nobody may
/// `implement` it. That preserves the framework's ability to add members to the
/// base class in a minor release without breaking downstream code.
///
/// Branch on [AgenticException.isRetryable] or [AgenticException.code] rather
/// than on the concrete type where you can; reserve `is` checks for the cases
/// that genuinely need the extra fields.
library;

import 'package:agentic_core/src/common/json_types.dart';
import 'package:meta/meta.dart';

/// Base class for every error raised by the framework.
///
/// See the library documentation for why this type is `base` rather than
/// `sealed`, and for the contract that subclasses are expected to honour.
///
/// ```dart
/// try {
///   await model.generate(request);
/// } on AgenticException catch (error, stackTrace) {
///   logger.error(error.message, error: error, stackTrace: stackTrace);
///   if (error.isRetryable) scheduleRetry();
/// }
/// ```
abstract base class AgenticException implements Exception {
  /// Creates an exception carrying [message] and optional diagnostic context.
  ///
  /// [cause] is the lower-level error this failure wraps — a `SocketException`,
  /// a `FormatException` — and [causeStackTrace] is the stack trace captured
  /// where that cause was caught. Preserving both is what makes a wrapped
  /// error debuggable rather than merely categorised.
  ///
  /// [details] is arbitrary structured context attached to the failure. It is
  /// copied into an unmodifiable map so that an exception can be safely
  /// forwarded to a log sink or a crash reporter without any risk of later
  /// mutation.
  AgenticException(
    this.message, {
    this.cause,
    this.causeStackTrace,
    Map<String, Object?> details = const <String, Object?>{},
  }) : details = details.isEmpty
           ? const <String, Object?>{}
           : Map<String, Object?>.unmodifiable(details);

  /// Human-readable description of what went wrong.
  ///
  /// Written for the developer reading a log, not for an end user: it should
  /// name the component, the operation and the offending value.
  final String message;

  /// The lower-level error that triggered this failure, when there was one.
  final Object? cause;

  /// The stack trace captured where [cause] was caught.
  final StackTrace? causeStackTrace;

  /// Structured, unmodifiable diagnostic context supplied at construction.
  ///
  /// Values should be JSON-encodable so the whole exception can be shipped to
  /// a log aggregator. Never place secrets here: [details] is designed to be
  /// exported.
  final Map<String, Object?> details;

  /// Context added by layers the error passed through on its way out.
  ///
  /// [details] is what the *thrower* knew; [annotations] is what everything
  /// between the throw and the catch learned. A retry policy records how many
  /// attempts it made, an agent records which step it was on, a workflow
  /// records the node. By the time the error reaches application code it can
  /// explain not just what failed but where it was in the run.
  ///
  /// Mutable by design — it is the one part of an exception that legitimately
  /// grows as the error propagates — but only through [annotate], which never
  /// overwrites an existing key, so the innermost layer's account always wins.
  final Map<String, Object?> annotations = <String, Object?>{};

  /// Records [value] under [key] unless [key] is already present.
  ///
  /// First writer wins: annotations are added as the error unwinds, so the
  /// earliest — innermost, closest to the failure — annotation is the most
  /// specific and must not be overwritten by an outer layer.
  void annotate(String key, Object? value) =>
      annotations.putIfAbsent(key, () => value);

  /// Records every entry of [context] through [annotate].
  void annotateAll(Map<String, Object?> context) {
    for (final entry in context.entries) {
      annotate(entry.key, entry.value);
    }
  }

  /// Stable machine-readable identifier for this class of failure.
  ///
  /// Codes are `snake_case`, are part of the package's public contract and
  /// therefore follow semantic versioning: renaming one is a breaking change.
  /// Branch on this rather than on [message], which is free to change.
  String get code;

  /// Whether retrying the identical operation could plausibly succeed.
  ///
  /// This is the single signal retry policies consult. It answers "is this
  /// failure transient?", not "should this be retried?" — budget, idempotency
  /// and deadline decisions belong to the policy, not the error.
  ///
  /// A malformed request is not retryable. A 503 is. A cancellation is not,
  /// because the caller asked for the work to stop.
  bool get isRetryable;

  /// Serialises this exception for logs, traces and crash reports.
  ///
  /// [cause] is rendered with `toString` rather than recursively serialised,
  /// because causes come from outside the framework and carry no serialisation
  /// contract.
  @mustCallSuper
  JsonMap toJson() => pruneNulls(<String, Object?>{
    'code': code,
    'type': runtimeType.toString(),
    'message': message,
    'retryable': isRetryable,
    'cause': cause?.toString(),
    'details': details.isEmpty ? null : details,
    'annotations': annotations.isEmpty
        ? null
        : Map<String, Object?>.of(annotations),
  });

  @override
  String toString() {
    final buffer = StringBuffer('$runtimeType($code): $message');
    if (details.isNotEmpty) {
      buffer.write(' ${_renderDetails(details)}');
    }
    if (annotations.isNotEmpty) {
      buffer.write(' at ${_renderDetails(annotations)}');
    }
    if (cause != null) {
      buffer.write('\n  caused by: $cause');
    }
    return buffer.toString();
  }
}

String _renderDetails(Map<String, Object?> details) {
  final rendered = details.entries
      .map((entry) => '${entry.key}=${entry.value}')
      .join(', ');
  return '{$rendered}';
}

// -----------------------------------------------------------------------------
// Configuration and programming errors — never retryable.
// -----------------------------------------------------------------------------

/// The framework was assembled incorrectly.
///
/// A missing API key, a provider registered under a name nothing resolves, a
/// vector store pointed at a dimension that disagrees with its embedder. These
/// are deployment or wiring mistakes: retrying cannot fix them, and failing
/// loudly at startup is far better than degrading at request time.
final class ConfigurationException extends AgenticException {
  /// Creates a configuration failure describing the misconfigured [setting].
  ConfigurationException(
    super.message, {
    this.setting,
    super.cause,
    super.causeStackTrace,
    super.details,
  });

  /// Dotted path of the offending setting, such as `openai.apiKey`.
  final String? setting;

  @override
  String get code => 'configuration_error';

  @override
  bool get isRetryable => false;

  @override
  JsonMap toJson() =>
      pruneNulls(<String, Object?>{...super.toJson(), 'setting': setting});
}

/// Input failed validation before any work was attempted.
///
/// Raised by JSON Schema validation of tool arguments, by workflow graph
/// validation, and by any value object whose invariants were violated.
final class ValidationException extends AgenticException {
  /// Creates a validation failure listing the specific [violations].
  ValidationException(
    super.message, {
    List<String> violations = const <String>[],
    super.cause,
    super.causeStackTrace,
    super.details,
  }) : violations = violations.isEmpty
           ? const <String>[]
           : List<String>.unmodifiable(violations);

  /// Individual violations, each already prefixed with its JSON pointer.
  ///
  /// Reported as a list rather than a single string so that a caller — an LLM
  /// repairing its own malformed tool call, for instance — can see every
  /// problem in one round trip instead of discovering them one at a time.
  final List<String> violations;

  @override
  String get code => 'validation_error';

  @override
  bool get isRetryable => false;

  @override
  JsonMap toJson() => pruneNulls(<String, Object?>{
    ...super.toJson(),
    'violations': violations.isEmpty ? null : violations,
  });

  @override
  String toString() {
    if (violations.isEmpty) return super.toString();
    final rendered = violations.map((v) => '\n  - $v').join();
    return '$runtimeType($code): $message$rendered';
  }
}

/// A payload could not be decoded into the shape its contract promised.
///
/// Almost always signals provider drift: an upstream API changed a field's
/// type, started returning `null` for something documented as required, or
/// returned an error page where JSON was expected.
final class SerializationException extends AgenticException {
  /// Creates a decoding failure pointing at [path] within the payload.
  SerializationException(
    super.message, {
    this.path,
    super.cause,
    super.causeStackTrace,
    super.details,
  });

  /// Dotted or bracketed path to the offending field, such as `choices[0]`.
  final String? path;

  @override
  String get code => 'serialization_error';

  @override
  bool get isRetryable => false;

  @override
  JsonMap toJson() =>
      pruneNulls(<String, Object?>{...super.toJson(), 'path': path});
}

/// An operation was attempted against an object in the wrong lifecycle state.
///
/// Publishing to a closed event bus, resuming a workflow run that already
/// completed, reading from a disposed store. Distinct from
/// [ConfigurationException] because the wiring is correct — the sequencing is
/// not.
final class InvalidStateException extends AgenticException {
  /// Creates a lifecycle failure describing the [currentState] encountered.
  InvalidStateException(
    super.message, {
    this.currentState,
    this.expectedState,
    super.cause,
    super.causeStackTrace,
    super.details,
  });

  /// The state the object was actually in.
  final String? currentState;

  /// The state the operation required.
  final String? expectedState;

  @override
  String get code => 'invalid_state';

  @override
  bool get isRetryable => false;

  @override
  JsonMap toJson() => pruneNulls(<String, Object?>{
    ...super.toJson(),
    'currentState': currentState,
    'expectedState': expectedState,
  });
}

/// A requested capability is not supported by the selected implementation.
///
/// Local models that cannot do tool calling, providers without embedding
/// support, vector stores without metadata filtering. Surfacing this as a
/// distinct type lets higher layers degrade deliberately — falling back to
/// prompt-based tool selection, for example — instead of parsing an error
/// message.
final class CapabilityNotSupportedException extends AgenticException {
  /// Creates a capability failure naming the [capability] and the [component]
  /// that does not provide it.
  CapabilityNotSupportedException(
    super.message, {
    required this.capability,
    required this.component,
    super.cause,
    super.causeStackTrace,
    super.details,
  });

  /// The capability that was requested, such as `toolCalling`.
  final String capability;

  /// The implementation that does not provide it, such as `ollama:gemma3`.
  final String component;

  @override
  String get code => 'capability_not_supported';

  @override
  bool get isRetryable => false;

  @override
  JsonMap toJson() => pruneNulls(<String, Object?>{
    ...super.toJson(),
    'capability': capability,
    'component': component,
  });
}

/// A named resource could not be found.
final class NotFoundException extends AgenticException {
  /// Creates a lookup failure for [identifier] of kind [resourceType].
  NotFoundException(
    super.message, {
    required this.resourceType,
    required this.identifier,
    super.cause,
    super.causeStackTrace,
    super.details,
  });

  /// The kind of resource, such as `tool`, `agent` or `document`.
  final String resourceType;

  /// The identifier that produced no match.
  final String identifier;

  @override
  String get code => 'not_found';

  @override
  bool get isRetryable => false;

  @override
  JsonMap toJson() => pruneNulls(<String, Object?>{
    ...super.toJson(),
    'resourceType': resourceType,
    'identifier': identifier,
  });
}

// -----------------------------------------------------------------------------
// Authorisation — not retryable without operator intervention.
// -----------------------------------------------------------------------------

/// Credentials were missing, malformed, expired or rejected.
///
/// Deliberately not retryable: replaying a request with the same bad key only
/// burns rate-limit budget and, on some providers, accelerates a temporary
/// block.
final class AuthenticationException extends AgenticException {
  /// Creates an authentication failure attributed to [provider].
  AuthenticationException(
    super.message, {
    this.provider,
    super.cause,
    super.causeStackTrace,
    super.details,
  });

  /// The provider that rejected the credentials.
  final String? provider;

  @override
  String get code => 'authentication_error';

  @override
  bool get isRetryable => false;

  @override
  JsonMap toJson() =>
      pruneNulls(<String, Object?>{...super.toJson(), 'provider': provider});
}

/// The caller is authenticated but not permitted to perform the operation.
///
/// Covers both remote authorisation (a model the account cannot access) and
/// local authorisation (a tool the host application has not granted, such as
/// camera access denied by the user).
final class PermissionDeniedException extends AgenticException {
  /// Creates an authorisation failure for [operation] on [subject].
  PermissionDeniedException(
    super.message, {
    required this.operation,
    this.subject,
    super.cause,
    super.causeStackTrace,
    super.details,
  });

  /// The operation that was refused, such as `tool:camera.capture`.
  final String operation;

  /// The principal or resource the operation targeted.
  final String? subject;

  @override
  String get code => 'permission_denied';

  @override
  bool get isRetryable => false;

  @override
  JsonMap toJson() => pruneNulls(<String, Object?>{
    ...super.toJson(),
    'operation': operation,
    'subject': subject,
  });
}

// -----------------------------------------------------------------------------
// Transport and upstream failures — usually retryable.
// -----------------------------------------------------------------------------

/// An upstream provider returned an error.
///
/// Retryability is derived from the HTTP status rather than declared by the
/// caller: 408, 409, 425, 429 and every 5xx are transient, everything else is
/// the caller's fault. Passing `retryable` explicitly overrides that inference
/// for providers that misuse status codes.
final class ProviderException extends AgenticException {
  /// Creates an upstream failure attributed to [provider].
  ProviderException(
    super.message, {
    required this.provider,
    this.statusCode,
    this.providerCode,
    this.requestId,
    bool? retryable,
    super.cause,
    super.causeStackTrace,
    super.details,
  }) : _retryable = retryable;

  /// Identifier of the provider adapter, such as `openai` or `anthropic`.
  final String provider;

  /// HTTP status returned upstream, when the failure was an HTTP response.
  final int? statusCode;

  /// The provider's own error code, preserved verbatim for support tickets.
  final String? providerCode;

  /// The provider's request identifier, the single most useful field to quote
  /// when escalating to a provider's support team.
  final String? requestId;

  final bool? _retryable;

  @override
  String get code => 'provider_error';

  @override
  bool get isRetryable {
    final override = _retryable;
    if (override != null) return override;
    final status = statusCode;
    if (status == null) {
      // No status means the request never produced a response — a socket or
      // DNS failure. Those are the most retryable failures there are.
      return true;
    }
    if (status >= 500) return true;
    return const {408, 409, 425, 429}.contains(status);
  }

  @override
  JsonMap toJson() => pruneNulls(<String, Object?>{
    ...super.toJson(),
    'provider': provider,
    'statusCode': statusCode,
    'providerCode': providerCode,
    'requestId': requestId,
  });
}

/// The provider signalled that the caller is sending requests too quickly.
///
/// Always retryable. [retryAfter] carries the provider's own guidance when it
/// supplied any; `RetryPolicy` prefers it over its computed backoff, because
/// the server knows better than the client when it will be ready.
final class RateLimitException extends AgenticException {
  /// Creates a rate-limit failure for [provider], honouring [retryAfter].
  RateLimitException(
    super.message, {
    required this.provider,
    this.retryAfter,
    this.limit,
    this.scope,
    super.cause,
    super.causeStackTrace,
    super.details,
  });

  /// Identifier of the provider adapter that throttled the request.
  final String provider;

  /// How long the provider asked the client to wait, if it said.
  final Duration? retryAfter;

  /// The numeric limit that was hit, when reported.
  final int? limit;

  /// What the limit applies to, such as `requests` or `tokens`.
  final String? scope;

  @override
  String get code => 'rate_limited';

  @override
  bool get isRetryable => true;

  @override
  JsonMap toJson() => pruneNulls(<String, Object?>{
    ...super.toJson(),
    'provider': provider,
    'retryAfterMs': retryAfter?.inMilliseconds,
    'limit': limit,
    'scope': scope,
  });
}

/// A hard quota was exhausted — billing, not throttling.
///
/// Separated from [RateLimitException] precisely because it is *not*
/// retryable: waiting does not restore an exhausted credit balance, and a
/// retry loop against a billing failure is a support ticket generator.
final class QuotaExceededException extends AgenticException {
  /// Creates a quota failure for [provider].
  QuotaExceededException(
    super.message, {
    required this.provider,
    this.quota,
    super.cause,
    super.causeStackTrace,
    super.details,
  });

  /// Identifier of the provider adapter.
  final String provider;

  /// The exhausted quota's name, such as `monthly_tokens`.
  final String? quota;

  @override
  String get code => 'quota_exceeded';

  @override
  bool get isRetryable => false;

  @override
  JsonMap toJson() => pruneNulls(<String, Object?>{
    ...super.toJson(),
    'provider': provider,
    'quota': quota,
  });
}

/// An operation exceeded its time budget.
///
/// Named with an `Agentic` prefix to avoid colliding with `dart:async`'s
/// `TimeoutException`, which callers will often have in scope.
final class AgenticTimeoutException extends AgenticException {
  /// Creates a timeout failure for [operation] after [timeout].
  AgenticTimeoutException(
    super.message, {
    required this.operation,
    required this.timeout,
    super.cause,
    super.causeStackTrace,
    super.details,
  });

  /// The operation that ran out of time, such as `llm.generate`.
  final String operation;

  /// The budget that was exceeded.
  final Duration timeout;

  @override
  String get code => 'timeout';

  @override
  bool get isRetryable => true;

  @override
  JsonMap toJson() => pruneNulls(<String, Object?>{
    ...super.toJson(),
    'operation': operation,
    'timeoutMs': timeout.inMilliseconds,
  });
}

/// The operation was cancelled through a `CancellationToken`.
///
/// Not retryable: the caller explicitly asked for the work to stop. Retry
/// policies must let this propagate immediately, which is why cancellation is
/// modelled as an error type rather than as a silent early return — a silent
/// return would be indistinguishable from success.
final class CancelledException extends AgenticException {
  /// Creates a cancellation failure for [operation] with an optional [reason].
  CancelledException(
    super.message, {
    this.operation,
    this.reason,
    super.cause,
    super.causeStackTrace,
    super.details,
  });

  /// The operation that was interrupted.
  final String? operation;

  /// Why cancellation was requested, propagated from the token.
  final String? reason;

  @override
  String get code => 'cancelled';

  @override
  bool get isRetryable => false;

  @override
  JsonMap toJson() => pruneNulls(<String, Object?>{
    ...super.toJson(),
    'operation': operation,
    'reason': reason,
  });
}

/// A tool threw while executing.
///
/// Retryability is declared by the tool author, because only they know whether
/// the side effect is idempotent. The default is `false`: silently replaying an
/// unknown side effect is the more dangerous mistake.
final class ToolExecutionException extends AgenticException {
  /// Creates a tool failure for [toolName].
  ToolExecutionException(
    super.message, {
    required this.toolName,
    bool retryable = false,
    super.cause,
    super.causeStackTrace,
    super.details,
  }) : _retryable = retryable;

  /// The registered name of the failing tool.
  final String toolName;

  final bool _retryable;

  @override
  String get code => 'tool_execution_error';

  @override
  bool get isRetryable => _retryable;

  @override
  JsonMap toJson() =>
      pruneNulls(<String, Object?>{...super.toJson(), 'toolName': toolName});
}

/// A persistence adapter failed.
///
/// Raised by memory stores, vector stores and document stores. Retryability is
/// supplied by the adapter, since a locked SQLite file is transient while a
/// schema mismatch is not.
final class StorageException extends AgenticException {
  /// Creates a persistence failure for [store] during [operation].
  StorageException(
    super.message, {
    required this.store,
    this.operation,
    bool retryable = false,
    super.cause,
    super.causeStackTrace,
    super.details,
  }) : _retryable = retryable;

  /// Identifier of the store adapter, such as `sqlite` or `qdrant`.
  final String store;

  /// The failing operation, such as `upsert` or `query`.
  final String? operation;

  final bool _retryable;

  @override
  String get code => 'storage_error';

  @override
  bool get isRetryable => _retryable;

  @override
  JsonMap toJson() => pruneNulls(<String, Object?>{
    ...super.toJson(),
    'store': store,
    'operation': operation,
  });
}

/// Wraps an error that escaped from outside the framework.
///
/// Used at adapter boundaries so that no non-[AgenticException] ever reaches
/// application code from a framework entry point. The original error is always
/// preserved in [AgenticException.cause].
final class UnexpectedException extends AgenticException {
  /// Creates a wrapper around an unclassified [cause].
  UnexpectedException(
    super.message, {
    required super.cause,
    super.causeStackTrace,
    this.component,
    super.details,
  });

  /// The component the error escaped from, such as `agent:researcher`.
  final String? component;

  @override
  String get code => 'unexpected_error';

  /// Unknown errors are treated as non-transient.
  ///
  /// Retrying something the framework does not understand risks duplicating a
  /// side effect that already happened.
  @override
  bool get isRetryable => false;

  @override
  JsonMap toJson() =>
      pruneNulls(<String, Object?>{...super.toJson(), 'component': component});
}
