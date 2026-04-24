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
The new retry policies are much more flexible and customizable than the single global configuration we had before. Just like with [secrets](/posts/golem15-part7-config-and-secrets) and [resource quotas](/posts/golem15-part17-semantic-retry-policies), retry policies are also defined **per-environment**. An environment can have an arbitrary number of **named** retry policies defined. Each has a **predicate** and a **policy** - the predicate is an expression that decides whether the policy should be applied for a given failure case or not. If it gets chosen (evaluation order can be controlled with a priority field), the applied retry strategy is described by the **policy**.

#### Policies
The policy is a highly composable structure, with the following base nodes controlling _delays_:

| Policy | Description |
|--------|-------------|
| `periodic` | Fixed delay between each attempt |
| `exponential` | `baseDelay × factor^attempt` — exponentially growing delays |
| `fibonacci` | Delays follow the Fibonacci sequence starting from `first` and `second` |
| `immediate` | Retry immediately (zero delay) |
| `never` | Never retry — give up on first failure |

These can be combined with various combinators:

| Combinator | Description |
|------------|-------------|
| `countBox` | Limits the total number of retry attempts |
| `timeBox` | Limits retries to a wall-clock duration |
| `clamp` | Clamps computed delay to a `[minDelay, maxDelay]` range |
| `addDelay` | Adds a constant offset on top of the computed delay |
| `jitter` | Adds random noise (±factor × delay) to avoid thundering herds |
| `filteredOn` | Apply the inner policy only when a predicate matches; otherwise give up |
| `andThen` | Run the first policy until it gives up, then switch to the second |
| `union` | Retry if _either_ sub-policy wants to; pick the shorter delay |
| `intersect` | Retry only while _both_ sub-policies want to; pick the longer delay |

#### Predicates

Predicates are boolean expressions evaluated against the **error context properties**. They can be composed with `and`, `or`, and `not`:

| Predicate | Description |
|-----------|-------------|
| `propEq` / `propNeq` | Equality / inequality comparison |
| `propGt` / `propGte` / `propLt` / `propLte` | Numeric comparisons |
| `propExists` | True if the named property exists in the context |
| `propIn` | True if the property value is in a given set |
| `propMatches` | Glob pattern matching on the text representation |
| `propStartsWith` / `propContains` | Prefix / substring matching |
| `true` / `false` | Constant predicates |

#### Available properties

The **properties** are what predicates can refer to to evaluate if a policy applies to a failure case. Golem defines the following ones:

| Property | Set by | Type | Description |
|----------|--------|------|-------------|
| `verb` | All | text | HTTP method, `"invoke"`, `"resolve"`, `"trap"`, etc. |
| `noun-uri` | All | text | Target URI (e.g. `https://…`, `worker://…`, `kv://…`) |
| `uri-scheme` | All with URI | text | Scheme part of the URI |
| `uri-host` | All with URI | text | Hostname |
| `uri-port` | When port present | integer | Port number |
| `uri-path` | All with URI | text | Path portion |
| `status-code` | HTTP responses | integer | HTTP response status code |
| `error-type` | HTTP errors | text | Error classification string |
| `function` | RPC | text | Target function name |
| `target-component-id` | RPC | text | Component ID of the target worker |
| `target-agent-type` | RPC | text | Agent type name of the target |
| `db-type` | RDBMS | text | Database type (from URI scheme) |
| `trap-type` | WASM traps | text | `"deterministic"` or `"transient"` |

### Defining policies

Retry policies can be defined in the application manifest under the `retryPolicyDefaults` section, keyed by environment name. These retry policies are default values set when the application is deployed, and they can be manipulated live while agents are already using them.

```yaml
retryPolicyDefaults:
  my-environment:
    # Never retry client errors (4xx)
    no-retry-4xx:
      priority: 20
      predicate:
        and:
          - propGte: { property: status-code, value: 400 }
          - propLt: { property: status-code, value: 500 }
      policy: "never"

    # Aggressive retry for known-transient HTTP errors
    http-transient:
      priority: 10
      predicate:
        propIn:
          property: status-code
          values: [502, 503, 504]
      policy:
        countBox:
          maxRetries: 5
          inner:
            jitter:
              factor: 0.15
              inner:
                clamp:
                  minDelay: "100ms"
                  maxDelay: "5s"
                  inner:
                    exponential:
                      baseDelay: "200ms"
                      factor: 2.0

    # Catch-all: moderate retry for everything else
    catch-all:
      priority: 0
      predicate: true
      policy:
        countBox:
          maxRetries: 3
          inner:
            exponential:
              baseDelay: "100ms"
              factor: 3.0
```

When the agent encounters an error, policies are evaluated in **descending priority order**. In this example:
1. First check `no-retry-4xx` (priority 20) — if it's a 4xx error, give up immediately
2. Then check `http-transient` (priority 10) — if it's a 502/503/504, retry aggressively
3. Fall through to `catch-all` (priority 0) — retry moderately for anything else

### Default retry policy

When no user-defined retry policies are set, a default catch-all policy is activated which behaves the same way as the old global retry policy did. 

- **Name**: `"default"`
- **Priority**: `0` (lowest — any user-defined policy with priority ≥ 1 overrides it)
- **Predicate**: `true` (matches everything)
- **Policy**: Up to **3 retries**, exponential backoff with factor 3.0, delays clamped to [100ms, 1s], with 15% jitter

In the new policy system, this would be defined like the following:

```yaml
name: default
priority: 0
predicate: true
policy:
  countBox:
    maxRetries: 3
    inner:
      jitter:
        factor: 0.15
        inner:
          clamp:
            minDelay: "100ms"
            maxDelay: "1s"
            inner:
              exponential:
                baseDelay: "100ms"
                factor: 3.0
```

### Live-editing policies

As mentioned above, the default policies created by `golem deploy` can be modified on the fly using the CLI (or the REST API). This can be useful to react to production issues by tweaking retry behaviors without having to redeploy anything.

The following examples show how the CLI can be used to manipulate these policies:

```bash
# Create a new policy
golem retry-policy create http-transient \
  --priority 10 \
  --predicate '{ propIn: { property: "status-code", values: [502, 503, 504] } }' \
  --policy '{ countBox: { maxRetries: 5, inner: { exponential: { baseDelay: "200ms", factor: 2.0 } } } }'

# List all policies in the current environment
golem retry-policy list

# Get a specific policy by name
golem retry-policy get http-transient

# Update an existing policy (e.g. raise its priority)
golem retry-policy update http-transient --priority 15

# Delete a policy
golem retry-policy delete http-transient
```

#### SDK support

The Golem SDK provide the same runtime query and modification capabilities. We can query retry policies, modify or create new ones, and have temporary overrides to them that are only affecting the running agent.

The following example uses the Golem SDK to define and use a custom retry policy for a given HTTP request:

{% codetabs() %}
```typescript
import {
  Policy, Predicate, NamedPolicy, Props, Duration,
  withRetryPolicy,
} from '@golemcloud/golem-ts-sdk';

const policy = NamedPolicy.named(
  'http-transient',
  Policy.exponential(Duration.milliseconds(200), 2.0)
    .clamp(Duration.milliseconds(100), Duration.seconds(5))
    .withJitter(0.15)
    .onlyWhen(Predicate.oneOf(Props.statusCode, [502, 503, 504]))
    .maxRetries(5),
)
  .priority(10)
  .appliesWhen(Predicate.eq(Props.uriScheme, 'https'));

// Scoped usage — policy is restored when the block exits
withRetryPolicy(policy, () => {
  // HTTP calls in this block use the custom retry policy
  makeHttpRequest();
});
```

```rust
use golem_rust::retry::*;
use std::time::Duration;

let policy = NamedPolicy::named(
    "http-transient",
    Policy::exponential(Duration::from_millis(200), 2.0)
        .clamp(Duration::from_millis(100), Duration::from_secs(5))
        .with_jitter(0.15)
        .only_when(Predicate::one_of(Props::STATUS_CODE, [502_u16, 503, 504]))
        .max_retries(5),
)
.priority(10)
.applies_when(Predicate::eq(Props::URI_SCHEME, "https"));

// Scoped usage — policy is restored when the block exits
with_named_policy(&policy, || {
    // HTTP calls in this block use the custom retry policy
    make_http_request();
})?;
```

```scala
import golem.Guards._
import golem.host.Retry._

import scala.concurrent.duration._

val policy = named(
  "http-transient",
  Policy.exponential(200.millis, 2.0)
    .clamp(100.millis, 5.seconds)
    .withJitter(0.15)
    .onlyWhen(Props.statusCode.oneOf(502, 503, 504))
    .maxRetries(5)
).priority(10)
 .appliesWhen(Props.uriScheme.eq("https"))

// Scoped usage — policy is restored when the Future completes
withRetryPolicy(policy) {
  Future {
    // HTTP calls in this block use the custom retry policy
    makeHttpRequest()
  }
}
```

```moonbit
let policy =
  NamedPolicy::named(
    "http-transient",
    Policy::exponential(Duration::millis(200), 2.0)
      .clamp(Duration::millis(100), Duration::seconds(5))
      .with_jitter(0.15)
      .only_when(
        Predicate::one_of(
          Props::status_code(),
          [Value::int(502), Value::int(503), Value::int(504)],
        ),
      )
      .max_retries(5),
  )
    .priority(10)
    .applies_when(Predicate::eq(Props::uri_scheme(), Value::text("https")))

// Scoped usage — policy is restored when the block exits
with_named_policy!(policy, fn() {
  // HTTP calls in this block use the custom retry policy
  make_http_request()
})
```

{% end %}

### Extensionability
Any future retry-capable host functionality we add to Golem can be integrated into this retry policy system, and with the ability of querying the policies runtime, third party, user-level retry functionalities can also be built on top of it.
