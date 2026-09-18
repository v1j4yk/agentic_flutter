/// OpenTelemetry's GenAI semantic conventions, as constants.
///
/// # Why names matter more than usual here
///
/// A tracing backend renders an LLM span specially — prompt, completion, token
/// counts, cost — only when it recognises the attribute names. The same data
/// under `llm.model` instead of `gen_ai.request.model` is a generic span with
/// some strings on it. These constants exist so that a span produced here is
/// one Langfuse, Phoenix, Grafana or Datadog can read without configuration.
///
/// The conventions are still marked Development upstream, so they move. They
/// are kept here, in one file, precisely so that following a change is an edit
/// in one place rather than a search across the framework.
library;

/// Attribute keys from the OpenTelemetry GenAI semantic conventions.
abstract final class GenAiAttributes {
  /// What the span did: `chat`, `execute_tool`, `invoke_agent`, `embeddings`.
  static const String operationName = 'gen_ai.operation.name';

  /// The provider behind the call, such as `anthropic` or `openai`.
  static const String providerName = 'gen_ai.provider.name';

  /// The model the caller asked for.
  static const String requestModel = 'gen_ai.request.model';

  /// The model the provider says answered, which is not always the same.
  static const String responseModel = 'gen_ai.response.model';

  /// Sampling temperature, when one was set.
  static const String requestTemperature = 'gen_ai.request.temperature';

  /// The output ceiling the request carried.
  static const String requestMaxTokens = 'gen_ai.request.max_tokens';

  /// Why generation stopped, as a list: `stop`, `length`, `tool_calls`.
  static const String responseFinishReasons = 'gen_ai.response.finish_reasons';

  /// The provider's identifier for the response, for support tickets.
  static const String responseId = 'gen_ai.response.id';

  /// Prompt tokens.
  static const String usageInputTokens = 'gen_ai.usage.input_tokens';

  /// Completion tokens.
  static const String usageOutputTokens = 'gen_ai.usage.output_tokens';

  /// The conversation this call belongs to.
  static const String conversationId = 'gen_ai.conversation.id';

  /// The agent's name, for an `invoke_agent` span.
  static const String agentName = 'gen_ai.agent.name';

  /// The tool's name, for an `execute_tool` span.
  static const String toolName = 'gen_ai.tool.name';

  /// What kind of tool it was: `function`, `extension`, `datastore`.
  static const String toolType = 'gen_ai.tool.type';

  /// The tool call's identifier, correlating a call with its result.
  static const String toolCallId = 'gen_ai.tool.call.id';
}

/// The operation names the conventions define.
abstract final class GenAiOperations {
  /// A chat completion.
  static const String chat = 'chat';

  /// An embedding request.
  static const String embeddings = 'embeddings';

  /// A whole agent run.
  static const String invokeAgent = 'invoke_agent';

  /// One tool execution.
  static const String executeTool = 'execute_tool';
}

/// Attributes for a chat span, with the null entries left out.
///
/// The convention also defines attributes for the prompt and the completion
/// themselves. They are deliberately not built here: message content is the
/// most sensitive thing this framework touches, and a helper that makes it easy
/// to attach by accident is a helper that leaks it. Attach it deliberately, to
/// a span you control, after deciding what redaction applies.
Map<String, Object?> genAiChatAttributes({
  required String provider,
  required String requestModel,
  String? responseModel,
  String? responseId,
  double? temperature,
  int? maxTokens,
  int? inputTokens,
  int? outputTokens,
  String? finishReason,
  String? conversationId,
}) => <String, Object?>{
  GenAiAttributes.operationName: GenAiOperations.chat,
  GenAiAttributes.providerName: provider,
  GenAiAttributes.requestModel: requestModel,
  GenAiAttributes.responseModel: ?responseModel,
  GenAiAttributes.responseId: ?responseId,
  GenAiAttributes.requestTemperature: ?temperature,
  GenAiAttributes.requestMaxTokens: ?maxTokens,
  GenAiAttributes.usageInputTokens: ?inputTokens,
  GenAiAttributes.usageOutputTokens: ?outputTokens,
  if (finishReason != null)
    GenAiAttributes.responseFinishReasons: <String>[finishReason],
  GenAiAttributes.conversationId: ?conversationId,
};

/// Attributes for a tool-execution span.
Map<String, Object?> genAiToolAttributes({
  required String toolName,
  String? callId,
  String type = 'function',
}) => <String, Object?>{
  GenAiAttributes.operationName: GenAiOperations.executeTool,
  GenAiAttributes.toolName: toolName,
  GenAiAttributes.toolType: type,
  GenAiAttributes.toolCallId: ?callId,
};

/// Attributes for an agent-run span.
Map<String, Object?> genAiAgentAttributes({
  required String agentName,
  String? conversationId,
}) => <String, Object?>{
  GenAiAttributes.operationName: GenAiOperations.invokeAgent,
  GenAiAttributes.agentName: agentName,
  GenAiAttributes.conversationId: ?conversationId,
};
