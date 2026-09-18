# Security policy

## Reporting a vulnerability

Use GitHub's private vulnerability reporting: **Security → Report a
vulnerability** on
[the repository](https://github.com/v1j4yk/agentic_flutter/security/advisories/new).
That channel is private until an advisory is published.

Please do not open a public issue for a vulnerability, and please do not include
a working API key in a report — a redacted request id is enough to trace a
provider call.

**What to expect.** This is a small project, so the honest commitment is: an
acknowledgement within 7 days, an assessment within 14, and a fix released
before the advisory is published. If a report needs more time than that, you
will be told why rather than left waiting.

## Supported versions

Until 1.0, only the latest minor version receives fixes. A security fix ships as
a patch on the current minor, and the changelog says what it was.

## What counts as a vulnerability here

This framework runs AI agents, which makes some failures security issues that
would otherwise be bugs:

- **A safety boundary that does not hold.** A tool marked `requiresApproval`
  running without approval; the untrusted-content rule failing to apply after a
  retrieval, memory or MCP result; an MCP server's annotations *loosening*
  rather than tightening a `ToolSpec`.
- **Secret leakage.** A key or token reaching logs, traces, events, cassettes or
  an error message. Redaction covers conventional field names; a gap in that
  coverage is a bug worth reporting.
- **Budget or cancellation bypass.** A path where a run continues after
  cancellation, or spends past a budget, is a denial-of-wallet issue.
- **Injection that crosses a boundary the framework claims to hold** — for
  example untrusted text reaching a place the ledger does not record.

## What is not a vulnerability

- **A model doing something unwise when a user approved it.** The framework's
  job is to make the dangerous step visible and confirmable, not to second-guess
  a person who confirmed it.
- **Prompt injection succeeding at persuading a model.** No framework prevents
  that. What is in scope is the boundary: a *write* tool running after untrusted
  content without approval.
- **An API key extracted from an application binary.** A key shipped in an app
  is a published key — see the `agentic-flutter-secrets-and-keys` skill and
  `SecretStore`. The framework documents this rather than pretending to solve it.
- **A third-party provider's own vulnerability.** Report it to them; tell us if
  this framework's handling makes it worse.

## Security-relevant design, for reviewers

- `UntrustedContentLedger` on `AgenticContext` records which tools brought
  outside text into a run. It is shared across every scope in a run and cannot
  be cleared, because clearing it is exactly what an attacker would want.
- `ToolSpec.requiresApproval` denies when no approval handler is configured, and
  tells the model that nobody could be asked rather than that the user refused.
- `McpServer` withholds approval-requiring tools, because there is no person on
  the far end of a socket.
- `MetadataFilter` is sealed so that a filter an adapter has not translated is a
  compile error, not a predicate silently dropped from a query.
- Structured logging redacts conventional secret field names before a sink sees
  a record.
