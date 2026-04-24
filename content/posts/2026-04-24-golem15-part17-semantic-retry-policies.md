+++
title = "Golem 1.5 features - Part 17: Semantic retry policies"
date = 2026-04-24T16:00:00Z
[taxonomies]
tags = ["golem", "durable-execution", "agents", "golem-1.5"]
+++

## Introduction
I am writing a series of _short_ posts showcasing the new features of **Golem 1.5**, to be released at the end of April, 2026. The episodes of this series will be short and assume the reader knows what Golem is. Check my [other Golem-related posts](https://blog.vigoo.dev/tags/golem/) for more information!

Parts released so far:
- [Part 1: Code-first routes](/posts/golem15-part1-code-first-routes)
- [Part 2: Webhooks](/posts/golem15-part2-webhooks)
- [Part 3: MCP](/posts/golem15-part3-mcp)
- [Part 4: Node.js compatibility](/posts/golem15-part4-nodejs)
- [Part 5: Scala support](/posts/golem15-part5-scala)
- [Part 6: User-defined snapshotting](/posts/golem15-part6-user-defined-snapshotting)
- [Part 7: Configuration and Secrets](/posts/golem15-part7-config-and-secrets)
- [Part 8: Template simplifications and automatic updates](/posts/golem15-part8-template-simplifications)
- [Part 9: Agent skills](/posts/golem15-part9-skills)
- [Part 10: WebSocket client](/posts/golem15-part10-websocket)
- [Part 11: Bridge libraries](/posts/golem15-part11-bridges)
- [Part 12: REPL](/posts/golem15-part12-repl)
- [Part 13: Per-agent configuration](/posts/golem15-part13-per-agent-config)
- [Part 14: OpenTelemetry](/posts/golem15-part14-otlp)
- [Part 15: MoonBit](/posts/golem15-part15-moonbit)
- [Part 16: Quotas](/posts/golem15-part16-quotas)
- [Part 17: Semantic retry policies](/posts/golem15-part17-semantic-retry-policies)

## Retry policies
Previous Golem versions had a simple, global retry policy describing a few retries with exponential backoff. This retry policy applied to everything - in case a Golem application failed with an error (for example a Rust panic) it recreated the instance according to this policy a few times before it marked the agent to be permanently failed. This in theory could make transient errors auto-resolved but it did not allow much control to the user (although the parameters of this global policy could be overridden) and the exact behavior depended heavily on how exactly (and _when_) the application crashes with an error.

**Golem 1.5** improves this in two ways:
- introducing automatic inline retries in many scenarios
- a fully redesigned, customizable and composable retry policy model

### Inline retries
In many cases throwing away the agent instance, and recreating its state from scratch is not necessary for a retry. Golem now transparently retries all these transient issues with HTTP requests etc. immediately, providing a much faster and reliable retry mechanism.

Another part of this change is better classification of what _can_ be retried and what not. We no longer retry things that are known to be deterministically fail again. 

### Retry policies
The new retry policies are much more flexible and customizable than the single global configuration we had before. 

TODO: explain all the policies, combinators, predicates and properties

#### Default retry policy

TODO: explain what the default retry policy is

#### Defining policies

TODO: show example of defining custom policies in the app manifest

#### Modifying them on the fly

TODO: show an example of using the CLI to modify an existing policy

#### SDK support

TODO: show per-language (with code tabs) example of using the retry policy SDK support
