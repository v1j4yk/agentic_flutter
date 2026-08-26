/// Shared HTTP plumbing for provider adapters.
///
/// Every hosted provider is the same three problems: post JSON and read JSON,
/// post JSON and read server-sent events, and turn a failure into something the
/// framework understands. Solving them once means a new adapter is a request
/// builder and a response parser — not another hand-rolled error taxonomy.
///
/// # Error mapping is the point
///
/// The value of this class is [mapHttpFailure]. Retry policies, circuit
/// breakers and failover all key off `AgenticException.isRetryable`, so the
/// moment a provider's 429 becomes a generic exception, every one of those
/// stops working correctly. Mapping here, once, keeps that contract true for
/// every adapter.
library;

import 'dart:async';
import 'dart:convert';

import 'package:agentic_core/agentic_core.dart';
import 'package:agentic_llm/src/streaming/sse.dart';
import 'package:http/http.dart' as http;

/// Posts JSON to a provider and reads JSON or events back.
///
/// One transport per provider configuration. Sharing an [http.Client] across
/// requests is what enables connection reuse, and on mobile that is the
/// difference between one TLS handshake and one per turn.
final class LlmHttpTransport implements Disposable {
  /// Creates a transport.
  ///
  /// [headers] are sent on every request and typically carry authentication.
  /// They are never logged: this class treats them as secret.
  LlmHttpTransport({
    required this.baseUrl,
    required this.provider,
    Map<String, String> headers = const <String, String>{},
    http.Client? client,
    this.timeout = const Duration(seconds: 120),
    this.requestIdHeaders = const <String>['x-request-id', 'request-id'],
  }) : _headers = Map<String, String>.unmodifiable(headers),
       _client = client ?? http.Client(),
       _ownsClient = client == null;

  /// Root of the provider's API, such as `https://api.openai.com/v1`.
  final Uri baseUrl;

  /// Adapter identifier used in errors and traces.
  final String provider;

  /// Ceiling for a single request.
  ///
  /// Generous by default: reasoning models legitimately take minutes. A caller
  /// that wants a tighter bound should cancel rather than lower this, because
  /// cancellation propagates and a timeout here only stops the waiting.
  final Duration timeout;

  /// Response headers that may carry the provider's request identifier.
  final List<String> requestIdHeaders;

  final Map<String, String> _headers;
  final http.Client _client;
  final bool _ownsClient;
  bool _disposed = false;

  /// Posts [body] to [path] and decodes the JSON response.
  Future<JsonMap> postJson(
    String path,
    JsonMap body, {
    AgenticContext? context,
    Map<String, String> extraHeaders = const <String, String>{},
  }) async {
    _throwIfDisposed();
    // Checked through the context rather than the token so that an expired
    // deadline is caught too, not just an explicit cancellation.
    context?.throwIfCancelled();
    final token = context?.cancellation ?? CancellationToken.none;

    final request = http.Request('POST', _resolve(path))
      ..headers.addAll(_requestHeaders(extraHeaders))
      ..body = jsonEncode(body);

    final response = await token.race(
      _send(request, path),
      operation: '$provider.$path',
    );

    final text = utf8.decode(response.bodyBytes, allowMalformed: true);
    if (response.statusCode >= 400) {
      throw mapHttpFailure(
        statusCode: response.statusCode,
        body: text,
        provider: provider,
        headers: response.headers,
        requestIdHeaders: requestIdHeaders,
      );
    }

    try {
      final decoded = jsonDecode(text);
      if (decoded is Map) return decoded.cast<String, Object?>();
      throw SerializationException(
        'Expected a JSON object from $provider, got ${decoded.runtimeType}.',
      );
    } on FormatException catch (error, stackTrace) {
      throw SerializationException(
        '$provider returned a ${response.statusCode} with a body that is not '
        'JSON: ${_preview(text)}',
        cause: error,
        causeStackTrace: stackTrace,
      );
    }
  }

  /// Posts [body] to [path] and decodes a server-sent event stream.
  ///
  /// Cancelling the returned stream's subscription closes the connection, which
  /// is what stops a provider generating — and billing for — an answer nobody
  /// will read.
  Stream<SseEvent> postSse(
    String path,
    JsonMap body, {
    AgenticContext? context,
    Map<String, String> extraHeaders = const <String, String>{},
  }) async* {
    _throwIfDisposed();
    // Checked through the context rather than the token so that an expired
    // deadline is caught too, not just an explicit cancellation.
    context?.throwIfCancelled();
    final token = context?.cancellation ?? CancellationToken.none;

    final request = http.Request('POST', _resolve(path))
      ..headers.addAll(<String, String>{
        ..._requestHeaders(extraHeaders),
        'accept': 'text/event-stream',
      })
      ..body = jsonEncode(body);

    final http.StreamedResponse response;
    try {
      response = await token.race(
        _client.send(request),
        operation: '$provider.$path',
      );
    } on CancelledException {
      rethrow;
    } on AgenticException {
      rethrow;
    } on Object catch (error, stackTrace) {
      throw _transportFailure(error, stackTrace, path);
    }

    if (response.statusCode >= 400) {
      // The body of a failed streaming request is a normal JSON error, not
      // events. Draining it is what makes the message useful.
      final text = await response.stream.bytesToString();
      throw mapHttpFailure(
        statusCode: response.statusCode,
        body: text,
        provider: provider,
        headers: response.headers,
        requestIdHeaders: requestIdHeaders,
      );
    }

    // Binding to the token means cancelling the run tears down this
    // subscription, and cancelling the subscription closes the socket.
    yield* token.bind(
      decodeServerSentEvents(response.stream),
      operation: '$provider.$path',
    );
  }

  /// The provider request identifier carried in [headers], if any.
  String? requestIdOf(Map<String, String> headers) {
    for (final name in requestIdHeaders) {
      final value = headers[name] ?? headers[name.toLowerCase()];
      if (value != null && value.isNotEmpty) return value;
    }
    return null;
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    // Only close a client this transport created. Closing a caller's shared
    // client would break every other transport using it.
    if (_ownsClient) _client.close();
  }

  Future<http.Response> _send(http.Request request, String path) async {
    try {
      final streamed = await _client
          .send(request)
          .timeout(
            timeout,
            onTimeout: () => throw AgenticTimeoutException(
              '$provider did not respond within ${timeout.inSeconds}s.',
              operation: '$provider.$path',
              timeout: timeout,
            ),
          );
      return await http.Response.fromStream(streamed);
    } on AgenticException {
      rethrow;
    } on TimeoutException catch (error, stackTrace) {
      throw AgenticTimeoutException(
        '$provider did not respond within ${timeout.inSeconds}s.',
        operation: '$provider.$path',
        timeout: timeout,
        cause: error,
        causeStackTrace: stackTrace,
      );
    } on Object catch (error, stackTrace) {
      throw _transportFailure(error, stackTrace, path);
    }
  }

  ProviderException _transportFailure(
    Object error,
    StackTrace stackTrace,
    String path,
  ) => ProviderException(
    'Could not reach $provider: $error${_permissionHint(error)}',
    provider: provider,
    // No status means no response — a DNS, TLS or socket failure. Those are the
    // most retryable failures there are, and on mobile they are also the most
    // common: a request issued as the user walks into a lift fails exactly here.
    retryable: true,
    cause: error,
    causeStackTrace: stackTrace,
    details: <String, Object?>{'path': path},
  );

  /// An extra line for a host-lookup failure, naming the cause that hides.
  ///
  /// A name that will not resolve looks identical whether the network is down
  /// or the app was never permitted onto it. On Android the second is both
  /// common and invisible: `flutter create` writes the `INTERNET` permission
  /// into the debug and profile manifests only, so a release build fails here
  /// and only here — which is precisely when no debugger is attached and the
  /// message is all anyone has.
  ///
  /// The wording suggests rather than concludes: this cannot tell the two
  /// apart, and claiming to would send someone the wrong way when the cause
  /// really was an aeroplane.
  static String _permissionHint(Object error) {
    if (!error.toString().contains('Failed host lookup')) return '';
    return '\n\nIf the device is online, check that '
        '`<uses-permission android:name="android.permission.INTERNET"/>` is '
        'in android/app/src/main/AndroidManifest.xml. Flutter adds it only to '
        'the debug and profile manifests, so release builds fail exactly this '
        'way.';
  }

  Map<String, String> _requestHeaders(Map<String, String> extra) =>
      <String, String>{
        'content-type': 'application/json',
        ..._headers,
        ...extra,
      };

  Uri _resolve(String path) {
    if (path.startsWith('http://') || path.startsWith('https://')) {
      return Uri.parse(path);
    }
    final base = baseUrl.toString();
    final root = base.endsWith('/') ? base.substring(0, base.length - 1) : base;
    final suffix = path.startsWith('/') ? path : '/$path';
    return Uri.parse('$root$suffix');
  }

  void _throwIfDisposed() {
    if (!_disposed) return;
    throw InvalidStateException(
      'This $provider transport has been disposed.',
      currentState: 'disposed',
      expectedState: 'active',
    );
  }

  static String _preview(String text) =>
      text.length <= 300 ? text : '${text.substring(0, 297)}...';
}

/// Converts an HTTP failure into the framework's error hierarchy.
///
/// The status code decides the type, with two refinements that matter:
///
/// * a 429 whose body mentions an exhausted quota becomes a
///   [QuotaExceededException], **not** a [RateLimitException]. The difference is
///   whether waiting helps: retrying a throttle succeeds, retrying a spent
///   credit balance generates support tickets;
/// * `Retry-After` is parsed in both of its legal forms, because a provider's
///   own estimate of when it will be ready beats any client-side schedule.
AgenticException mapHttpFailure({
  required int statusCode,
  required String body,
  required String provider,
  Map<String, String> headers = const <String, String>{},
  List<String> requestIdHeaders = const <String>['x-request-id', 'request-id'],
}) {
  final parsed = _parseErrorBody(body);
  final message = parsed.message ?? _defaultMessage(statusCode, body);
  final requestId = _headerValue(headers, requestIdHeaders);
  final retryAfter = _parseRetryAfter(headers['retry-after']);

  final details = pruneNulls(<String, Object?>{
    'providerCode': parsed.code,
    'providerType': parsed.type,
  });

  if (statusCode == 401) {
    return AuthenticationException(
      '$provider rejected the credentials: $message',
      provider: provider,
      details: details,
    );
  }
  if (statusCode == 403) {
    return PermissionDeniedException(
      '$provider refused the request: $message',
      operation: '$provider.request',
      subject: provider,
      details: details,
    );
  }
  if (statusCode == 404) {
    return NotFoundException(
      '$provider has no such endpoint or model: $message',
      resourceType: 'model',
      identifier: provider,
      details: details,
    );
  }
  if (statusCode == 402 || _looksLikeQuota(parsed, body)) {
    return QuotaExceededException(
      '$provider reports the account quota is exhausted: $message',
      provider: provider,
      quota: parsed.code,
      details: details,
    );
  }
  if (statusCode == 429) {
    return RateLimitException(
      '$provider is throttling this client: $message',
      provider: provider,
      retryAfter: retryAfter,
      scope: parsed.type,
      details: details,
    );
  }

  return ProviderException(
    '$provider returned $statusCode: $message',
    provider: provider,
    statusCode: statusCode,
    providerCode: parsed.code,
    requestId: requestId,
    details: details,
  );
}

/// Whether an error body indicates an exhausted quota rather than a rate limit.
///
/// Both arrive as 429 on most providers, and only the body distinguishes them.
bool _looksLikeQuota(_ProviderError parsed, String body) {
  final haystack = '${parsed.code ?? ''} ${parsed.type ?? ''} $body'
      .toLowerCase();
  return haystack.contains('insufficient_quota') ||
      haystack.contains('exceeded your current quota') ||
      haystack.contains('billing_hard_limit') ||
      haystack.contains('credit balance is too low');
}

/// Parses `Retry-After` in either legal form.
///
/// The header is defined as delta-seconds *or* an HTTP date, and providers use
/// both. Handling only the integer form silently drops the server's guidance
/// exactly when it matters most.
Duration? _parseRetryAfter(String? value) {
  if (value == null || value.isEmpty) return null;
  final seconds = int.tryParse(value.trim());
  if (seconds != null) return Duration(seconds: seconds.clamp(0, 3600));
  try {
    final date = parseHttpDate(value);
    if (date == null) return null;
    final delta = date.difference(DateTime.now().toUtc());
    return delta.isNegative ? Duration.zero : delta;
  } on Object {
    return null;
  }
}

/// Parses an IMF-fixdate, the only format modern servers are required to send.
///
/// Written out rather than pulled from a dependency: it is fifteen lines, and
/// the whole point of this package's dependency discipline is that a mobile app
/// does not inherit a date-parsing library to read one header.
DateTime? parseHttpDate(String value) {
  // Example: 'Wed, 21 Oct 2026 07:28:00 GMT'
  final match = RegExp(
    r'^\w{3}, (\d{2}) (\w{3}) (\d{4}) (\d{2}):(\d{2}):(\d{2}) GMT$',
  ).firstMatch(value.trim());
  if (match == null) return null;
  const months = <String, int>{
    'Jan': 1,
    'Feb': 2,
    'Mar': 3,
    'Apr': 4,
    'May': 5,
    'Jun': 6,
    'Jul': 7,
    'Aug': 8,
    'Sep': 9,
    'Oct': 10,
    'Nov': 11,
    'Dec': 12,
  };
  final month = months[match.group(2)];
  if (month == null) return null;
  return DateTime.utc(
    int.parse(match.group(3)!),
    month,
    int.parse(match.group(1)!),
    int.parse(match.group(4)!),
    int.parse(match.group(5)!),
    int.parse(match.group(6)!),
  );
}

String? _headerValue(Map<String, String> headers, List<String> names) {
  for (final name in names) {
    final value = headers[name] ?? headers[name.toLowerCase()];
    if (value != null && value.isNotEmpty) return value;
  }
  return null;
}

String _defaultMessage(int statusCode, String body) {
  final trimmed = body.trim();
  if (trimmed.isEmpty) return 'no response body';
  return trimmed.length <= 300 ? trimmed : '${trimmed.substring(0, 297)}...';
}

/// The message, code and type extracted from a provider error body.
final class _ProviderError {
  const _ProviderError({this.message, this.code, this.type});

  final String? message;
  final String? code;
  final String? type;
}

/// Extracts the useful fields from a provider's error body.
///
/// OpenAI, Anthropic and Google all nest the human-readable message under an
/// `error` object, so one extractor covers every adapter. A body in an
/// unrecognised shape degrades to the raw text rather than throwing — an error
/// path that throws while reporting an error is the worst possible outcome.
_ProviderError _parseErrorBody(String body) {
  if (body.trim().isEmpty) return const _ProviderError();
  try {
    final decoded = jsonDecode(body);
    if (decoded is! Map) return const _ProviderError();
    final json = decoded.cast<String, Object?>();

    final error = json['error'];
    if (error is Map) {
      final errorJson = error.cast<String, Object?>();
      return _ProviderError(
        message: errorJson['message'] as String?,
        code: errorJson['code']?.toString(),
        type: errorJson['type'] as String?,
      );
    }
    if (error is String) return _ProviderError(message: error);

    // Some OpenAI-compatible servers report failures at the top level.
    return _ProviderError(
      message: json['message'] as String?,
      code: json['code']?.toString(),
      type: json['type'] as String?,
    );
  } on FormatException {
    return const _ProviderError();
  }
}
