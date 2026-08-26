/// Provider-independent language model access for the agentic framework.
///
/// One `ChatModel` port, three wire formats behind it, and cross-cutting
/// behaviour composed as decorators.
///
/// ```dart
/// import 'package:agentic_llm/agentic_llm.dart';
///
/// final model = ObservableChatModel(
///   RetryingChatModel(
///     FallbackChatModel([
///       OpenAiCompatibleChatModel.openAi(apiKey: openAiKey),
///       AnthropicChatModel(apiKey: anthropicKey),
///     ]),
///   ),
/// );
///
/// final answer = await model.prompt('Explain Dart records in one sentence.');
/// ```
///
/// The adapters shipped here cover every provider the framework claims:
/// `OpenAiCompatibleChatModel` speaks the format used by OpenAI, DeepSeek,
/// Grok, Mistral, Together, Groq, Ollama and llama.cpp; `AnthropicChatModel`
/// and `GeminiChatModel` speak their own. Adding another provider is a class
/// implementing `ChatModel` in your own package — nothing here needs to change.
library;

// --- Events ------------------------------------------------------------------
export 'src/events/llm_events.dart'
    show
        LlmEvent,
        LlmFailoverOccurred,
        LlmFirstTokenReceived,
        LlmRequestFailed,
        LlmRequestStarted,
        LlmResponseCompleted;
// --- Middleware --------------------------------------------------------------
export 'src/middleware/chat_middleware.dart'
    show
        CachingChatModel,
        ChatCache,
        FallbackChatModel,
        InMemoryChatCache,
        ObservableChatModel,
        RetryingChatModel;
// --- Streaming ---------------------------------------------------------------
export 'src/model/chat_chunk.dart'
    show ChatChunk, ChatChunkStream, ChatResponseBuilder, ToolCallDelta;
// --- Ports -------------------------------------------------------------------
export 'src/model/chat_model.dart'
    show
        ChatModel,
        ChatModelOperations,
        DelegatingChatModel,
        NonStreamingChatModel;
export 'src/model/chat_request.dart'
    show
        ChatRequest,
        ModelCapabilityRequirement,
        ReasoningEffort,
        RequirementCapability,
        ResponseFormat,
        ResponseFormatKind,
        ToolChoice,
        ToolChoiceMode;
export 'src/model/chat_response.dart' show ChatResponse, FinishReason;
export 'src/model/embedding_model.dart'
    show Embedding, EmbeddingModel, EmbeddingModelOperations, EmbeddingPurpose;
export 'src/model/model_info.dart'
    show ModelCapabilities, ModelCapability, ModelInfo, ModelPricing;
// --- Providers ---------------------------------------------------------------
export 'src/provider/anthropic.dart' show AnthropicChatModel;
export 'src/provider/gemini.dart' show GeminiChatModel, GeminiEmbeddingModel;
export 'src/provider/openai_compatible.dart'
    show OpenAiCompatibleChatModel, OpenAiCompatibleEmbeddingModel;
// --- Transport ---------------------------------------------------------------
export 'src/streaming/sse.dart'
    show
        SseEvent,
        decodeServerSentEventLines,
        decodeServerSentEvents,
        sseTransformer;
export 'src/transport/http_transport.dart'
    show LlmHttpTransport, mapHttpFailure, parseHttpDate;
