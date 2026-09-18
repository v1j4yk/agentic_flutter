---
name: agentic-llm-structured-output
description: >-
  Use when a model must return data rather than prose in agentic_llm:
  ResponseFormat.jsonSchema, generateStructured, decodeAs, building a
  JsonSchema, and what happens on providers without native structured output
  (Anthropic forces a tool call instead). Read this for "parse the model's
  JSON", "extract fields from text", or a schema the provider rejects.
license: MIT
metadata:
  package: agentic_llm
  min-version: 0.2.0
---

# Structured output

## The short way

```dart
final invoice = await model.generateStructured<Invoice>(
  ChatRequest(messages: [Message.user(emailBody)]),
  name: 'invoice',
  schema: JsonSchema.object(
    properties: {
      'total': JsonSchema.number(description: 'Amount due, in the stated currency'),
      'currency': JsonSchema.string(enumValues: ['GBP', 'EUR', 'USD']),
      'dueDate': JsonSchema.string(format: 'date', description: 'ISO 8601'),
      'lines': JsonSchema.array(items: JsonSchema.string()),
    },
    required: {'total', 'currency'},
  ),
  fromJson: Invoice.fromJson,
);
```

`generateStructured` picks the best mechanism the model has: a native JSON
schema response format where one exists, and a forced tool call where it does
not. That is why it is preferred over hand-rolling `responseFormat`.

## The explicit way

```dart
final response = await model.generate(
  ChatRequest(
    messages: [Message.user(text)],
    responseFormat: ResponseFormat.jsonSchema(name: 'invoice', schema: schema, strict: true),
  ),
);
final invoice = response.decodeAs(Invoice.fromJson, schema: schema);
```

Passing `schema:` to `decodeAs` validates before your `fromJson` runs, so a
missing field is a `ValidationException` naming the field rather than a null
where you expected a number. `response.decodeJson()` returns the raw map when
there is no class to build.

`ResponseFormat.json` is the weaker "some JSON, shape unspecified" mode; prefer
a schema whenever you know the shape.

## Writing the schema

```dart
JsonSchema.object(
  properties: {
    'title': JsonSchema.string(description: 'Short, in the document language'),
    'priority': JsonSchema.integer(minimum: 1, maximum: 5, defaultValue: 3),
    'tags': JsonSchema.array(items: JsonSchema.string(), maxItems: 5),
    'approved': JsonSchema.boolean(),
    'status': JsonSchema.enumeration(['open', 'closed']),
  },
  required: {'title'},
)
```

Descriptions are prompts — a field described well is extracted well. Keep the
schema small: models fill twenty fields worse than five, and a second call for
the rest is often more accurate.

`agentic_tools_generator` generates schemas from annotated Dart, which removes
the duplication between a class and its schema.

## Provider differences that will bite

| Provider | Mechanism | Watch for |
|---|---|---|
| OpenAI-compatible | native `response_format` | strict mode rejects some keywords |
| Gemini | `responseSchema`, an OpenAPI subset | `additionalProperties` is stripped; unions become a nullable flag |
| Anthropic | **no native mode** — a forced tool call | `structuredOutput` is deliberately not declared |
| Local models | often neither | declare capabilities honestly, expect repair |

Asking for structured output from a model that cannot do it throws
`CapabilityNotSupportedException` up front rather than returning prose you then
fail to parse.

## When the model answers badly anyway

1. **Validate, do not trust.** Always pass the schema to `decodeAs`.
2. **Ask again with the error.** One repair turn quoting the validation failure
   fixes most of them.
3. **Check `finishReason`.** `FinishReason.length` means truncated JSON — raise
   `maxOutputTokens` rather than fighting the parser. `response.wasTruncated`
   says so directly, and `ensureComplete()` throws if it was.
4. **Lower the temperature.** Extraction is not a creative task; 0 to 0.2.

## Typed agents

An agent can return structured output too:

```dart
ToolCallingAgent(
  info: info,
  model: model,
  responseFormat: ResponseFormat.jsonSchema(name: 'triage', schema: schema),
  budget: AgentBudget.interactive,
);
final triage = (await agent.run(input)).decodeJson(schema: schema);
```

In a workflow, `StructuredLlmNode` does the same thing as a node, and the
result is written into workflow state where the validator can see it.

## Common mistakes

- Parsing `response.text` with `jsonDecode` and no schema validation, so a
  missing field becomes a null far away from the cause.
- A schema with thirty fields and no descriptions.
- Forgetting `maxOutputTokens`, then debugging "invalid JSON" that is really
  truncation.
- Using `ResponseFormat.json` when you have a schema.
- Assuming Anthropic has a native JSON mode; it does not, and the tool-forcing
  fallback is why this still works.

## See also

- `agentic-llm-choose-provider` — capability negotiation in general
- `agentic-tools-generator-annotate-functions` — generating schemas from Dart
- `agentic-llm-middleware-retry-fallback-cache` — retrying the transient half
