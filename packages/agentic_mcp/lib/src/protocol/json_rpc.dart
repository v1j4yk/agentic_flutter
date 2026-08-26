/// JSON-RPC 2.0, the wire format MCP is built on.
///
/// # Why this is its own layer
///
/// MCP is a vocabulary — `tools/list`, `resources/read` — spoken over plain
/// JSON-RPC 2.0. Keeping the envelope separate from the vocabulary means the
/// framing, the identifier correlation and the error mapping are written and
/// tested once, and every transport (stdio, HTTP, an in-process pipe) reuses
/// them.
///
/// # The three message shapes
///
/// A **request** has an `id` and expects exactly one response. A
/// **notification** has no `id` and expects none — sending a response to one,
/// or waiting for a response that will never come, are the two classic bugs
/// here. A **response** carries either `result` or `error`, never both.
library;

import 'package:agentic_core/agentic_core.dart';
import 'package:meta/meta.dart';

/// The only JSON-RPC version MCP speaks.
const String kJsonRpcVersion = '2.0';

/// Error codes defined by JSON-RPC 2.0 itself.
///
/// Codes from -32000 to -32099 are reserved for implementations; MCP uses that
/// range for its own conditions, which is why this class is not exhaustive.
abstract final class JsonRpcErrorCode {
  /// Invalid JSON was received.
  static const int parseError = -32700;

  /// The JSON is not a valid request object.
  static const int invalidRequest = -32600;

  /// The method does not exist.
  static const int methodNotFound = -32601;

  /// The parameters are wrong.
  static const int invalidParams = -32602;

  /// An error internal to the server.
  static const int internalError = -32603;

  /// The request was cancelled — an MCP convention in the reserved range.
  static const int requestCancelled = -32800;
}

/// A call that expects a response.
@immutable
final class JsonRpcRequest {
  /// Creates a request.
  JsonRpcRequest({required this.id, required this.method, JsonMap? params})
    : params = params == null
          ? null
          : Map<String, Object?>.unmodifiable(params);

  /// Restores a request from JSON.
  factory JsonRpcRequest.fromJson(JsonMap json) => JsonRpcRequest(
    id: json['id'],
    method: json.requireString('method'),
    params: json.optionalObject('params'),
  );

  /// Correlates this call with its response.
  ///
  /// Typed as [Object] because the specification allows a string or a number,
  /// and a client that assumes one will fail against a server that chose the
  /// other. It must not be null — that is what makes a message a notification.
  final Object? id;

  /// The method being called, such as `tools/call`.
  final String method;

  /// Method arguments.
  final JsonMap? params;

  /// Serialises the request.
  JsonMap toJson() => pruneNulls(<String, Object?>{
    'jsonrpc': kJsonRpcVersion,
    'id': id,
    'method': method,
    'params': params,
  });

  @override
  String toString() => 'JsonRpcRequest($method, id: $id)';
}

/// A message that expects no response.
@immutable
final class JsonRpcNotification {
  /// Creates a notification.
  JsonRpcNotification({required this.method, JsonMap? params})
    : params = params == null
          ? null
          : Map<String, Object?>.unmodifiable(params);

  /// Restores a notification from JSON.
  factory JsonRpcNotification.fromJson(JsonMap json) => JsonRpcNotification(
    method: json.requireString('method'),
    params: json.optionalObject('params'),
  );

  /// The method being announced, such as `notifications/initialized`.
  final String method;

  /// Method arguments.
  final JsonMap? params;

  /// Serialises the notification.
  JsonMap toJson() => pruneNulls(<String, Object?>{
    'jsonrpc': kJsonRpcVersion,
    'method': method,
    'params': params,
  });

  @override
  String toString() => 'JsonRpcNotification($method)';
}

/// What a request returned.
@immutable
final class JsonRpcResponse {
  /// Creates a successful response.
  JsonRpcResponse.result(this.id, JsonMap result)
    : result = Map<String, Object?>.unmodifiable(result),
      error = null;

  /// Creates a failed response.
  const JsonRpcResponse.failure(this.id, JsonRpcError this.error)
    : result = null;

  /// Restores a response from JSON.
  factory JsonRpcResponse.fromJson(JsonMap json) {
    final error = json.optionalObject('error');
    if (error != null) {
      return JsonRpcResponse.failure(json['id'], JsonRpcError.fromJson(error));
    }
    // A result of `null` is legal and means "done, nothing to report"; an empty
    // object preserves that without forcing every caller to null-check.
    final result = json['result'];
    return JsonRpcResponse.result(
      json['id'],
      result is Map
          ? result.cast<String, Object?>()
          : const <String, Object?>{},
    );
  }

  /// The identifier of the request this answers.
  final Object? id;

  /// The result, when the call succeeded.
  final JsonMap? result;

  /// The failure, when it did not.
  final JsonRpcError? error;

  /// Whether the call succeeded.
  bool get isSuccess => error == null;

  /// Serialises the response.
  JsonMap toJson() => pruneNulls(<String, Object?>{
    'jsonrpc': kJsonRpcVersion,
    'id': id,
    'result': result,
    'error': error?.toJson(),
  });

  @override
  String toString() => isSuccess
      ? 'JsonRpcResponse(id: $id, ok)'
      : 'JsonRpcResponse(id: $id, ${error!.code})';
}

/// A JSON-RPC failure.
@immutable
final class JsonRpcError {
  /// Creates an error.
  const JsonRpcError({required this.code, required this.message, this.data});

  /// Restores an error from JSON.
  factory JsonRpcError.fromJson(JsonMap json) => JsonRpcError(
    code: json.intOr('code', JsonRpcErrorCode.internalError),
    message: json.stringOr('message', 'The server did not explain the error.'),
    data: json['data'],
  );

  /// The numeric code.
  final int code;

  /// A human-readable explanation.
  final String message;

  /// Anything else the peer wanted to say.
  final Object? data;

  /// Converts this into the framework's error hierarchy.
  ///
  /// The mapping is what keeps retry policies and circuit breakers working
  /// across an MCP boundary: a `methodNotFound` is a permanent configuration
  /// problem, an `internalError` is worth retrying, and a cancellation must
  /// never be retried at all.
  AgenticException toException({required String server, String? method}) {
    final where = method == null ? server : '$server/$method';
    final details = pruneNulls(<String, Object?>{
      'rpcCode': code,
      'data': data is String || data is num || data is bool ? data : null,
    });

    return switch (code) {
      JsonRpcErrorCode.requestCancelled => CancelledException(
        'The MCP server `$server` cancelled the call: $message',
        operation: method,
        reason: message,
        details: details,
      ),
      JsonRpcErrorCode.methodNotFound => CapabilityNotSupportedException(
        'The MCP server `$server` does not implement `$method`: $message',
        capability: method ?? 'unknown',
        component: server,
        details: details,
      ),
      JsonRpcErrorCode.invalidParams => ValidationException(
        'The MCP server `$server` rejected the arguments for `$method`: '
        '$message',
        violations: <String>[message],
        details: details,
      ),
      JsonRpcErrorCode.parseError ||
      JsonRpcErrorCode.invalidRequest => SerializationException(
        'The MCP server `$server` could not read the request for `$where`: '
        '$message',
        details: details,
      ),
      // Everything else, the -32000 implementation range included, is treated
      // as a server-side failure and left retryable: a server's own error codes
      // are its own business, and guessing at their semantics would be worse
      // than assuming the call may work next time.
      _ => ProviderException(
        'The MCP server `$server` failed `$where`: $message',
        provider: server,
        statusCode: code,
        retryable: true,
        details: details,
      ),
    };
  }

  /// Serialises the error.
  JsonMap toJson() => pruneNulls(<String, Object?>{
    'code': code,
    'message': message,
    'data': data,
  });

  @override
  String toString() => 'JsonRpcError($code: $message)';
}

/// Classifies a decoded JSON-RPC message.
///
/// A peer's incoming stream mixes all three shapes, and telling them apart is
/// the first thing any implementation has to do. Returning a sealed type makes
/// the switch that follows exhaustive.
sealed class JsonRpcMessage {
  const JsonRpcMessage();

  /// Reads any JSON-RPC message.
  ///
  /// Throws a [SerializationException] for anything that is not one, carrying
  /// the offending payload — which is the only useful diagnostic when a server
  /// writes a stray line to its own stdout.
  factory JsonRpcMessage.fromJson(JsonMap json) {
    final hasMethod = json['method'] is String;
    final hasId = json.containsKey('id') && json['id'] != null;

    if (hasMethod && hasId) {
      return JsonRpcRequestMessage(JsonRpcRequest.fromJson(json));
    }
    if (hasMethod) {
      return JsonRpcNotificationMessage(JsonRpcNotification.fromJson(json));
    }
    if (json.containsKey('result') || json.containsKey('error')) {
      return JsonRpcResponseMessage(JsonRpcResponse.fromJson(json));
    }
    throw SerializationException(
      'Not a JSON-RPC message: it has no `method`, `result` or `error`.',
      details: <String, Object?>{'keys': json.keys.toList()},
    );
  }
}

/// An incoming request.
final class JsonRpcRequestMessage extends JsonRpcMessage {
  /// Wraps [request].
  const JsonRpcRequestMessage(this.request);

  /// The request.
  final JsonRpcRequest request;
}

/// An incoming notification.
final class JsonRpcNotificationMessage extends JsonRpcMessage {
  /// Wraps [notification].
  const JsonRpcNotificationMessage(this.notification);

  /// The notification.
  final JsonRpcNotification notification;
}

/// An incoming response.
final class JsonRpcResponseMessage extends JsonRpcMessage {
  /// Wraps [response].
  const JsonRpcResponseMessage(this.response);

  /// The response.
  final JsonRpcResponse response;
}
