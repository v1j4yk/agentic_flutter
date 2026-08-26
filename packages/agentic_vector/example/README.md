# Examples

Run with `dart run example/agentic_vector_example.dart`.

The example runs offline: it ships a small hashing embedding model so nothing is
downloaded and no key is needed. Swap `HashingEmbeddingModel` for
`OpenAiCompatibleEmbeddingModel` or `GeminiEmbeddingModel` and the rest of the
file is unchanged — that is the point of the port.
