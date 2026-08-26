# Examples

Run with `dart run example/agentic_rag_example.dart`.

The example runs offline: it ships a small hashing embedding model and a
scripted chat model, so nothing is downloaded and no key is needed. Swap
`HashingEmbeddingModel` for `OpenAiCompatibleEmbeddingModel` and `FakeChatModel`
for a real `ChatModel`, and the rest of the file is unchanged.
