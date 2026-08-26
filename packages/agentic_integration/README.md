# agentic_integration

A conformance suite run against real providers. The same battery of behaviours
applied to every adapter, so a provider changing what it does is caught here
rather than by a user.

Never published. It is a verification harness for this repository, and it spends
money when it runs.

```sh
# The harness's own tests. No credentials, no network, runs in the normal suite.
dart test

# The real thing. Nothing runs without the flag.
OPENAI_API_KEY=… ANTHROPIC_API_KEY=… dart test --tags integration

# The capability matrix.
OPENAI_API_KEY=… dart run bin/audit.dart
```

## Why the suite is shared rather than per-provider

Bespoke tests per adapter verify that each one did what its author expected on
the day they wrote it. That is worth little — the adapters already have unit
tests against recorded payloads, and those catch a shape change the moment it
appears in a fixture.

What recorded payloads cannot catch is **behaviour drift**: a provider changing
which `finish_reason` it sends for a truncated answer, how it fragments
tool-call JSON across stream chunks, whether it still emits usage on the final
chunk. The way to catch that is to state what the `ChatModel` port promises and
hold every implementation to it.

It is also the only honest test of the abstraction. If `ChatRequest` were
quietly an OpenAI request in disguise, this is where Gemini would say so.

## What it checks

| Check | Why it is worth a network call |
|---|---|
| `completion` | Text, a finish reason, and **usage** — budgets depend on usage, and a provider that stops reporting it turns cost limits into no limits, silently |
| `streaming` | Deltas assemble into an answer; reports when a provider sends no usage on a stream, which makes streamed turns invisible to a cost budget |
| `systemPrompt` | Each provider wires this differently — a message, a top-level field, `systemInstruction` |
| `toolCalling` | The model asks for the tool, with a call id, and arguments that **validate against the schema it was given** |
| `toolResultLoop` | The half that actually differs: a `tool` role, `tool_result` blocks in a *user* turn, or `functionResponse` parts correlated by name |
| `parallelToolCalls` | Several calls in one turn are distinguishable — distinct ids, known names |
| `structuredOutput` | A schema-constrained answer really conforms, validated rather than assumed |
| `lengthCap` | A truncated answer reports `length`. A provider reporting `stop` makes truncation invisible and the loop proceeds on half a thought |
| `cancellation` | Cancelling a stream stops it — on mobile, the difference between closing a screen and paying for tokens nobody reads |
| `badKeyMapping` | A rejected key becomes `AuthenticationException`. A 401 arriving as *retryable* is retried until the rate limit rejects it too, which is how a typo becomes an outage |
| embeddings | Batch order preserved, declared width matches reality, different text gives different vectors |

## Four rules this suite holds itself to

**A missing key is a skip, not a failure.** Almost nobody has a key for every
provider, and a suite that goes red because a contributor has no Anthropic
account is one people learn to ignore. Each skip carries its reason, so
"not configured" stays visibly different from "broken".

**Assertions are behavioural, never about wording.** "Returned some text",
"asked for `lookup_weather`", "stopped because of the length cap". An assertion
that a model produced a particular sentence is a test that fails on a Tuesday
for no reason.

**No retries.** Providers are flaky, and a retry wrapper would hide exactly the
intermittent behaviour this exists to surface. A genuine blip shows up as one
red nightly run, which is the right amount of noise.

**`parallelToolCalls` reports rather than insists.** Whether a model batches its
calls depends on the model as much as the provider. What it *does* assert hard
is that several calls, if they arrive, are distinguishable — a false failure
here would train people to ignore the suite.

## The audit

`bin/audit.dart` prints what each provider claims against what it does:

```
check                 openai  anthropic  gemini
------------------------------------------------
completion            pass    pass       pass
toolCalling           pass    pass       pass
structuredOutput      pass    --         pass
lengthCap             pass    pass       pass
```

`--` means the adapter never claimed the capability, which is a different thing
from failing it. `AnthropicChatModel` deliberately does not declare
`structuredOutput`: claiming it would be a lie that produces worse results than
the tool-forcing fallback `generateStructured` uses instead.

This is the report worth reading after a nightly run. A declared capability that
is not real fails deep inside an agent loop where the cause is invisible; here
it is one cell in a table.

## Cost

Every subject makes real calls. Defaults are the cheapest capable model each
provider offers and answers are capped at a few dozen tokens, which puts a full
run in the region of a penny per provider — not zero, which is why it runs
nightly rather than on every push.

## Configuration

| Variable | Effect |
|---|---|
| `OPENAI_API_KEY` | Enables OpenAI (chat and embeddings) |
| `OPENAI_MODEL` | Overrides `gpt-4o-mini` |
| `ANTHROPIC_API_KEY` | Enables Anthropic |
| `ANTHROPIC_MODEL` | Overrides `claude-3-5-haiku-latest` |
| `GEMINI_API_KEY` | Enables Gemini (chat and embeddings) |
| `GEMINI_MODEL` | Overrides `gemini-2.0-flash` |
| `DEEPSEEK_API_KEY` | Enables DeepSeek |
| `OLLAMA_BASE_URL` + `OLLAMA_MODEL` | Enables a local model |
| `OLLAMA_CAPABILITIES` | Comma-separated, e.g. `toolCalling,streaming`. A local model's capabilities depend on which weights are loaded, so the adapter cannot know them |

## Adding a provider

One entry in `discoverSubjects()`. The battery is shared, so a new adapter earns
the whole thing by declaring how to construct itself — which is the point:
a provider that cannot pass the same suite as the others has not been integrated,
it has been added.
