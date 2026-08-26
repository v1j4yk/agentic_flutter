/// The port every language model implements.
///
/// Two methods and a description. Everything else in this package — adapters,
/// middleware, fakes — is either an implementation of this interface or a
/// decorator over one, which is what makes retries, caching, failover and
/// logging composable without any of them knowing about the others.
library;

import 'dart:async';

import 'package:agentic_core/agentic_core.dart';
import 'package:agentic_llm/src/model/chat_chunk.dart';
import 'package:agentic_llm/src/model/chat_request.dart';
import 'package:agentic_llm/src/model/chat_response.dart';
import 'package:agentic_llm/src/model/model_info.dart';

/// A model that answers a conversation.
///
/// Implementations must:
///
/// * translate framework errors onto the core hierarchy, so callers never see a
///   raw `SocketException` or a provider's own error class;
/// * honour `AgenticContext.cancellation`, closing the connection when it fires;
/// * declare capabilities honestly in [info];
/// * be safe to share — a single instance serves concurrent requests.
///
/// ```dart
/// final model = OpenAiCompatibleChatModel.openAi(apiKey: key, model: 'gpt-4o');
/// final answer = await model.prompt('Explain Dart records in one sentence.');
/// ```
abstract interface class ChatModel implements Disposable {
  /// What this model is and what it supports.
  ///
  /// Read on every request for capability checks, so it must be a cheap field
  /// read rather than a network call.
  ModelInfo get info;

  /// Generates a complete answer.
  ///
  /// Throws an [AgenticException] subclass on failure — never a transport
  /// exception, and never a provider-specific type.
  Future<ChatResponse> generate(ChatRequest request, {AgenticContext? context});

  /// Generates an answer incrementally.
  ///
  /// The stream ends after a chunk with a [ChatChunk.finishReason]. Cancelling
  /// the subscription must close the underlying connection: an abandoned
  /// streaming request that keeps generating is billed in full.
  ///
  /// Collect the result with `stream(request).collect()` when you want the
  /// streaming transport but not the incremental updates.
  Stream<ChatChunk> stream(ChatRequest request, {AgenticContext? context});
}

/// Conveniences available on every [ChatModel].
///
/// Extensions rather than interface members, so adding one never breaks a
/// third-party implementation.
extension ChatModelOperations on ChatModel {
  /// Answers a single prompt and returns the text.
  ///
  /// The shortest useful call in the framework, for the many cases that are not
  /// a conversation.
  Future<String> prompt(
    String prompt, {
    String? system,
    double? temperature,
    int? maxOutputTokens,
    AgenticContext? context,
  }) async {
    final response = await generate(
      ChatRequest.prompt(
        prompt,
        system: system,
        temperature: temperature,
        maxOutputTokens: maxOutputTokens,
      ),
      context: context,
    );
    response.ensureComplete();
    return response.text;
  }

  /// Answers with a value conforming to [schema].
  ///
  /// Uses guaranteed structured output where the model supports it and falls
  /// back to JSON mode where it does not, so the same call site works across
  /// providers of different strengths. The answer is validated against [schema]
  /// either way, so the fallback is weaker in cost — a possible retry — not in
  /// correctness.
  Future<T> generateStructured<T>(
    ChatRequest request, {
    required String name,
    required JsonSchema schema,
    required T Function(JsonMap json) fromJson,
    AgenticContext? context,
  }) async {
    final format = info.supports(ModelCapability.structuredOutput)
        ? ResponseFormat.jsonSchema(name: name, schema: schema)
        : ResponseFormat.json;

    final response = await generate(
      request.copyWith(responseFormat: format),
      context: context,
    );
    return response.decodeAs(fromJson, schema: schema);
  }

  /// Verifies this model can satisfy [request].
  ///
  /// Throws [CapabilityNotSupportedException] naming the missing feature.
  /// Adapters call this before building a request body, so an unsupported
  /// feature fails with an actionable message instead of a provider 400.
  void checkSupports(ChatRequest request) {
    for (final requirement in request.requirements) {
      info.requireCapability(requirement.capability);
    }
    if (request.toolChoice.mode == ToolChoiceMode.specific &&
        !info.supports(ModelCapability.toolCalling)) {
      info.requireCapability(ModelCapability.toolCalling);
    }
  }
}

/// Implements [ChatModel.stream] for models that cannot stream.
///
/// Local runtimes and some hosted endpoints offer only a complete answer. Rather
/// than making every caller branch, this mixin emits the finished answer as a
/// single chunk followed by a terminal one — so a UI bound to a stream still
/// works, it simply updates once.
///
/// The mixin deliberately does *not* fake progressive delivery by slicing the
/// answer into fragments on a timer. That would be a lie about latency, and the
/// first person to measure time-to-first-token would be badly misled.
base mixin NonStreamingChatModel implements ChatModel {
  @override
  Stream<ChatChunk> stream(
    ChatRequest request, {
    AgenticContext? context,
  }) async* {
    final response = await generate(request, context: context);
    final message = response.message;

    if (message.reasoning case final reasoning?) {
      yield ChatChunk.reasoning(reasoning);
    }
    if (message.text.isNotEmpty) {
      yield ChatChunk.text(message.text);
    }
    for (var i = 0; i < message.toolCalls.length; i++) {
      final call = message.toolCalls[i];
      yield ChatChunk.tool(
        ToolCallDelta(
          index: i,
          id: call.id,
          name: call.name,
          argumentsDelta: call.argumentsJson,
        ),
      );
    }
    yield ChatChunk(
      finishReason: response.finishReason,
      usage: response.usage,
      modelId: response.modelId,
      requestId: response.requestId,
    );
  }
}

/// Wraps another [ChatModel], delegating everything by default.
///
/// The base for middleware. Every cross-cutting concern in this package —
/// retries, caching, logging, failover — is a subclass, and a user's own
/// decorator is indistinguishable from a built-in one.
///
/// ```dart
/// final class BudgetedModel extends DelegatingChatModel {
///   BudgetedModel(super.inner, this._budget);
///
///   final Budget _budget;
///
///   @override
///   Future<ChatResponse> generate(request, {context}) async {
///     _budget.checkRemaining();
///     final response = await super.generate(request, context: context);
///     _budget.record(response.cost ?? 0);
///     return response;
///   }
/// }
/// ```
abstract class DelegatingChatModel implements ChatModel {
  /// Wraps [inner].
  const DelegatingChatModel(this.inner);

  /// The wrapped model.
  final ChatModel inner;

  @override
  ModelInfo get info => inner.info;

  @override
  Future<ChatResponse> generate(
    ChatRequest request, {
    AgenticContext? context,
  }) => inner.generate(request, context: context);

  @override
  Stream<ChatChunk> stream(ChatRequest request, {AgenticContext? context}) =>
      inner.stream(request, context: context);

  /// Disposes the wrapped model.
  ///
  /// Override only to release a decorator's own resources, and call `super`.
  @override
  Future<void> dispose() => inner.dispose();
}
