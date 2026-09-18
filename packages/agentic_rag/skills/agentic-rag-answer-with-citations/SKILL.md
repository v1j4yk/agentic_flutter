---
name: agentic-rag-answer-with-citations
description: >-
  Use when answering questions from indexed documents with agentic_rag:
  RagPipeline, cited answers, isGrounded, streaming a RAG answer, giving an
  agent searchTool and answeringTool, and metadata filters. Read this for
  "answer from my documents", "show sources", or "the model made something up".
license: MIT
metadata:
  package: agentic_rag
  min-version: 0.2.0
---

# Answering with citations

## The pipeline

```dart
final pipeline = RagPipeline(
  retriever: retriever,
  model: chatModel,
  reranker: LlmReranker(model: cheapModel),   // optional
  topK: 6,        // retrieved
  finalK: 4,      // kept after reranking, and put in the prompt
  minScore: 0.2,
  maxContextChars: 6000,
  includeQuotes: true,
);

final answer = await pipeline.answer('How much holiday do I get?');

print(answer.text);
for (final citation in answer.citations) {
  print('${citation.marker} ${citation.label} ${citation.source ?? ''}');
}
```

Citations are first class, not metadata. Passages are numbered in the prompt,
the model marks each claim with `[1]`, and the markers resolve back to
documents. Numbers, because models reproduce `[3]` reliably and mangle
`guide.md#7`.

## `isGrounded` is the signal that matters

```dart
if (!answer.isGrounded) {
  // The model cited nothing: the corpus did not cover the question.
  return 'I could not find that in the handbook.';
}
```

An answer that cites nothing is the corpus telling you it does not contain the
answer. Showing it anyway is how a RAG app becomes a confident liar. Handle the
ungrounded case explicitly — it is the difference between a demo and a product.

## Streaming

```dart
await for (final event in pipeline.stream(question)) {
  switch (event) {
    case RagSourcesReady(:final context):   showSources(context.chunks);
    case RagAnswerDelta(:final text):       append(text);
    case RagAnswerCompleted(:final answer): finish(answer);
  }
}
```

Sources arrive **before** the first token, which is the sequence a good UI
wants: the user sees what is being read while the answer is written.

## Filtering

```dart
await pipeline.answer(
  question,
  filter: AndFilter([
    EqualsFilter('team', 'ops'),
    GreaterThanFilter('year', 2024),
  ]),
  namespace: 'handbook',
);
```

Filters are sealed, so every store either translates a filter or fails to
compile — a condition is never silently dropped from a query. Permission
filtering belongs here, before generation, not after.

## Giving it to an agent

```dart
final tools = ToolRegistry()
  ..register(searchTool(retriever: retriever, description: 'Searches the staff handbook.'))
  ..register(answeringTool(pipeline: pipeline, description: 'Answers handbook questions with citations.'));
```

`searchTool` returns passages and lets the agent reason across several
searches; `answeringTool` returns a finished cited answer. Prefer `searchTool`
for multi-hop questions, `answeringTool` when the agent should delegate the
whole question.

Both **return untrusted content**: a document can contain instructions. After
either returns, a tool that is not read-only needs approval — which is the
framework's defence against injection arriving through data.

## When the answer is wrong

Check in this order, because the cause is usually earlier than it looks:

1. **Did retrieval find it?** `pipeline.buildContext(query)` and look. If the
   right chunk is absent, this is a retrieval problem — see
   `agentic-rag-tune-retrieval`.
2. **Was it in the prompt?** `maxContextChars` and `finalK` may have cut it.
3. **Is the chunk understandable alone?** A chunk without its heading often is
   not.
4. **Only then** change the prompt. `systemPrompt` replaces
   `RagPipeline.defaultSystemPrompt`, which already instructs the model to cite
   and to say when it does not know — keep both instructions if you replace it.

## Common mistakes

- Ignoring `isGrounded` and presenting an uncited answer as sourced.
- `finalK` so large the prompt is mostly irrelevant passages; more context is
  not better context.
- Rewriting the system prompt and dropping the citation instruction, so
  `citations` comes back empty.
- Using `answeringTool` for a multi-hop question, where the agent needed to
  search twice.
- Forgetting that retrieved text is untrusted, and being surprised by an
  approval prompt after a search.

## See also

- `agentic-rag-index-documents` — getting documents in
- `agentic-rag-tune-retrieval` — when the right passage is not retrieved
- `agentic-tools-approval-and-untrusted-content` — why a search changes approval
