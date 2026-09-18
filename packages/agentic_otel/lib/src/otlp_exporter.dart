/// Sending spans to an OpenTelemetry collector.
///
/// # Why OTLP over HTTP with a JSON body
///
/// The binary protobuf encoding is smaller on the wire and needs a generated
/// schema, a protobuf runtime and a build step. Every collector accepts the
/// JSON encoding too, and the difference is bytes on a connection that already
/// carries model requests measured in kilobytes. For a phone, and for a Dart
/// server, JSON is the right trade.
library;

import 'dart:async';
import 'dart:convert';

import 'package:agentic_core/agentic_core.dart';
import 'package:http/http.dart' as http;
import 'package:meta/meta.dart';

/// Exports spans to an OTLP endpoint over HTTP.
///
/// ```dart
/// final exporter = BatchSpanExporter(
///   OtlpHttpSpanExporter(
///     endpoint: Uri.parse('https://collector.example.com/v1/traces'),
///     headers: {'authorization': 'Bearer $token'},
///     resource: OtlpResource(serviceName: 'pocket_agent'),
///   ),
/// );
/// final runtime = AgenticRuntime(tracer: Tracer(exporter: exporter));
/// ```
///
/// # Failure is never the application's problem
///
/// Telemetry that breaks a run is worse than no telemetry. A failed export is
/// reported through [onError] and dropped; it is never thrown into the code
/// that produced the span, and never retried indefinitely into a dead
/// collector.
final class OtlpHttpSpanExporter implements SpanExporter {
  /// Creates an exporter posting to [endpoint].
  ///
  /// [endpoint] is the full traces URL — collectors expose `/v1/traces` — not
  /// the collector root, because a wrong path is a 404 that looks like a
  /// network problem.
  OtlpHttpSpanExporter({
    required this.endpoint,
    this.headers = const <String, String>{},
    OtlpResource? resource,
    http.Client? client,
    this.timeout = const Duration(seconds: 10),
    this.onError,
  }) : resource = resource ?? const OtlpResource(),
       _client = client ?? http.Client(),
       _ownsClient = client == null;

  /// Where spans are posted, such as `https://host/v1/traces`.
  final Uri endpoint;

  /// Headers sent with every export, typically authentication.
  final Map<String, String> headers;

  /// What produced these spans.
  final OtlpResource resource;

  /// Ceiling for one export request.
  final Duration timeout;

  /// Called when an export fails, rather than throwing.
  final void Function(Object error, StackTrace stackTrace)? onError;

  final http.Client _client;
  final bool _ownsClient;
  bool _disposed = false;

  @override
  void export(SpanData span) {
    unawaited(exportAll(<SpanData>[span]));
  }

  /// Posts [spans] as one OTLP request.
  ///
  /// Returns whether the collector accepted them. Batching is what makes export
  /// affordable on a phone — one request per run rather than one per span — so
  /// this is the method `BatchSpanExporter` calls.
  Future<bool> exportAll(List<SpanData> spans) async {
    if (_disposed || spans.isEmpty) return true;
    try {
      final response = await _client
          .post(
            endpoint,
            headers: <String, String>{
              'content-type': 'application/json',
              ...headers,
            },
            body: jsonEncode(encodeSpans(spans, resource: resource)),
          )
          .timeout(timeout);

      if (response.statusCode >= 400) {
        _report(
          StateError(
            'The collector rejected ${spans.length} span(s) with '
            '${response.statusCode}: ${_preview(response.body)}',
          ),
          StackTrace.current,
        );
        return false;
      }
      return true;
    } on Object catch (error, stackTrace) {
      // Includes the timeout, DNS failures and a collector that is simply not
      // running — none of which the application can do anything about, and
      // none of which should reach it.
      _report(error, stackTrace);
      return false;
    }
  }

  void _report(Object error, StackTrace stackTrace) {
    final handler = onError;
    if (handler != null) handler(error, stackTrace);
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    if (_ownsClient) _client.close();
  }

  static String _preview(String body) =>
      body.length <= 200 ? body : '${body.substring(0, 197)}...';
}

/// What produced a set of spans: the `resource` in OpenTelemetry's model.
///
/// A backend groups and filters by these, so `serviceName` is the one field
/// worth setting deliberately — every span from every deployment arriving as
/// `unknown_service` is the usual reason a trace view is unusable.
@immutable
final class OtlpResource {
  /// Creates a resource description.
  const OtlpResource({
    this.serviceName = 'agentic',
    this.serviceVersion,
    this.deploymentEnvironment,
    this.attributes = const <String, Object?>{},
  });

  /// The service these spans came from.
  final String serviceName;

  /// The version of that service, when it is known.
  final String? serviceVersion;

  /// `production`, `staging`, a developer's name — whatever separates them.
  final String? deploymentEnvironment;

  /// Anything else worth attaching to every span.
  final Map<String, Object?> attributes;

  /// The OTLP attribute list for this resource.
  List<JsonMap> toAttributes() => encodeAttributes(<String, Object?>{
    'service.name': serviceName,
    'service.version': ?serviceVersion,
    'deployment.environment.name': ?deploymentEnvironment,
    ...attributes,
  });
}

/// Encodes spans as an OTLP `ExportTraceServiceRequest`.
///
/// Public because it is the part worth testing directly, and because an
/// application that already has its own transport — a queue, a proxy, a file —
/// needs the encoding without the HTTP client.
JsonMap encodeSpans(
  List<SpanData> spans, {
  OtlpResource resource = const OtlpResource(),
}) => <String, Object?>{
  'resourceSpans': <Object?>[
    <String, Object?>{
      'resource': <String, Object?>{'attributes': resource.toAttributes()},
      'scopeSpans': <Object?>[
        <String, Object?>{
          'scope': <String, Object?>{'name': 'agentic'},
          'spans': <Object?>[for (final span in spans) encodeSpan(span)],
        },
      ],
    },
  ],
};

/// Encodes one span in OTLP's JSON form.
JsonMap encodeSpan(SpanData span) => <String, Object?>{
  'traceId': span.context.traceId,
  'spanId': span.context.spanId,
  'parentSpanId': ?span.context.parentSpanId,
  'name': span.name,
  'kind': _kinds[span.kind]!,
  // OTLP wants nanoseconds since the epoch, as a string: the value exceeds
  // what a JavaScript number can hold exactly, and a collector reading it as a
  // double would round timestamps to the nearest microsecond.
  'startTimeUnixNano': _nanos(span.startTime),
  'endTimeUnixNano': _nanos(span.endTime),
  'attributes': encodeAttributes(span.attributes),
  'status': <String, Object?>{
    'code': _statuses[span.status]!,
    'message': ?span.statusMessage,
  },
  if (span.events.isNotEmpty)
    'events': <Object?>[
      for (final event in span.events)
        <String, Object?>{
          'name': event.name,
          'timeUnixNano': _nanos(event.timestamp),
          'attributes': encodeAttributes(event.attributes),
        },
    ],
};

/// Encodes attributes in OTLP's tagged-value form.
///
/// Null values are dropped rather than sent as an empty value: a collector
/// showing an attribute with no value is worse than not showing it.
List<JsonMap> encodeAttributes(Map<String, Object?> attributes) => <JsonMap>[
  for (final MapEntry(key: key, value: value) in attributes.entries)
    if (value != null) <String, Object?>{'key': key, 'value': _value(value)},
];

JsonMap _value(Object value) => switch (value) {
  final bool it => <String, Object?>{'boolValue': it},
  final int it => <String, Object?>{'intValue': '$it'},
  final double it => <String, Object?>{'doubleValue': it},
  final String it => <String, Object?>{'stringValue': it},
  final Iterable<Object?> it => <String, Object?>{
    'arrayValue': <String, Object?>{
      'values': <Object?>[
        for (final element in it)
          if (element != null) _value(element),
      ],
    },
  },
  // Anything else — a map, a domain object — is rendered rather than dropped,
  // because a span attribute that silently disappears is a debugging session
  // spent looking for it.
  _ => <String, Object?>{'stringValue': '$value'},
};

String _nanos(DateTime time) => '${time.toUtc().microsecondsSinceEpoch * 1000}';

const Map<SpanKind, int> _kinds = <SpanKind, int>{
  SpanKind.internal: 1,
  SpanKind.server: 2,
  SpanKind.client: 3,
  SpanKind.producer: 4,
  SpanKind.consumer: 5,
};

const Map<SpanStatus, int> _statuses = <SpanStatus, int>{
  SpanStatus.unset: 0,
  SpanStatus.ok: 1,
  SpanStatus.error: 2,
};
