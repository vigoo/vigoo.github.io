+++
title = "Golem 1.5 features - Part 16: Quotas"
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

## Quotas
A modern application usually depends on various third party services. This is even more true today with AI agents - an agent is going to make requests to various external systems as well as LLM providers and other AI infrastructure. Most of these have costs and limits. It does matter how many and how big requests you make to your chosen model, and many APIs have built-in quotas and rate limits affecting the callers.

In **Golem 1.5** we introduced a new, general purpose feature that tracks resource quotas in a distributed Golem application. The idea is that we can define an arbitrary set of **resources** with a limited availability, and enforce reserving some of this pool of available resources through **quota tokens**. With this token-granting we can control the parallel running agents and make sure we don't over-use the limited resources. 

It is possible to acquire some quota tokens and **split them**, passing a part of them to another Golem agent through agent-to-agent RPC calls. This is a very powerful tool to have a structured control over arbitrary external resource consumption.

### Integration
In this release we just introduce this as a general tool, available through the Golem SDKs, but it is not integrated with any libraries yet. In the future we expect to have dedicated support for quota tokens in various client libraries, but for now they have to be used as a manually implemented layer on top of the clients.

### Setting it up
Let's see some concrete examples. Just like with [secrets](/posts/golem15-part7-config-and-secrets), quota **resources** are also defined **per environment**, and we can define them with their initial limits in the **application manifest**. 

The following manifest snippet defines three different types of resources:

```yaml
resourceDefaults:
  prod:
    - name: api-calls
      limit:
        type: Rate
        value: 100
        period: minute
        max: 1000
      enforcementAction: reject
      unit: request
      units: requests
    - name: storage
      limit:
        type: Capacity
        value: 1073741824       # 1 GB
      enforcementAction: reject
      unit: byte
      units: bytes
    - name: connections
      limit:
        type: Concurrency
        value: 50
      enforcementAction: throttle
      unit: connection
      units: connections
```

The `prod` is just an example environment. For each environment we can define an arbitrary number of resources, identified by a unique name. The most important in their configuration are `limit` and `enforcementAction`. 

We have three different **limit** types:

- `Rate` defines a limited pool that refills by `value` in every `period`, with a maximum of `max`. This is great for example for rate-limiting API calls.
- `Capacity` defines a fixed number of `value` tokens. It never gets refilled - if an agent takes some of it, it remains taken forever.
- `Concurrency` defines a fixed pool of `value` tokens. The agents can never allocate more than this value at the same time, but once they stop using the tokens they get back to the pool. This is useful for limiting concurrency.

In addition to the limits, we can select what to do when the token request cannot be satisfied:

- `reject` means we return an error (with an optional hint of how much to wait). It is the agent's responsibility to handle this
- `throttle` means Golem will suspend the agent until the resource becomes available. This is fully automatic and does not require any further logic in the user code!
- `terminate` kills the agent with a specific failure message

### Dynamic changes
The resource definitions in the application manifest are only **defaults** applied at deployment. With CLI commands (or REST API calls) we can modify them any time, and the changes will affect running agents immediately.

For example we can increase the above defined `connections` resource's limit to 100 if we need more concurrency:

```shell
$ golem resource update connections --limit '{"type":"concurrency","value":100}' --environment prod
```

### Code example
Let's see how we can use these resources from code!

#### Initialization
The first step is to acquire a **quota token interface** for every resource our agent is going to need. This can be done in the agent's constructor, or the first time the token is needed, but should be done only once:

{% codetabs() %}
```typescript
import { acquireQuotaToken } from "golem-ts-sdk";

const token = acquireQuotaToken("api-calls", 1n);
```
```rust
use golem_rust::quota::QuotaToken;

let token = QuotaToken::new("api-calls", 1);
```
```scala
import golem.host.QuotaApi._

val token = QuotaToken("api-calls", BigInt(1))
```
```moonbit
let token = @quota.QuotaToken::new("api-calls", 1UL)
```
{% end %}

The parameter (`1`) is the **expected amount asked per reservation**. For a simple rate limiting use case, where we associate 1 API call with 1 token, this can be 1.

#### Simple rate limiting
For a simple rate limiting case, we can **reserve** one token for each API call (of course we could also weight different API calls differently, by associating different token counts to them):


{% codetabs() %}
```typescript
import { withReservation } from "golem-ts-sdk";

const result = await withReservation(token, 1n, async (reservation) => {
  const response = await callSimpleApi();
  return { used: BigInt(1), value: response };
});
```
```rust
use golem_rust::quota::with_reservation;

let result = with_reservation(&token, 1, |_reservation| {
    let response = call_simple_api();
    (1, response)
});
```
```scala
val result = withReservation(token, BigInt(1)) { reservation =>
  callSimpleApi().map { response =>
    (BigInt(1), response)
  }
}
```
```moonbit
let result = @quota.with_reservation(token, 1UL, fn(reservation) {
  let response = callSimpleApi()
  (1, response)
})
```
{% end %}

#### Rate-limiting LLMs
The same mechanism can be used to rate-limit for example LLMs, but not based on just the requests, but on the actual tokens consumed. Instead of reserving just one token, we reserve the number of maximum tokens we expect the request will consume (and in most LLM APIs we can enforce this). Then in the `response` we read how much actual tokens our request used, and **commit** that (returning the final number the `withReservation` helper is a way to commit, but there is also an explicit `commit` call we can use).

#### Splitting and merging
Quota tokens can be **split**, **merged** and **transformed** between agents. The following example splits off 200 units from our agent's available tokens for a given resource, and sends it to another agent. 

{% codetabs() %}
```typescript
const childToken: QuotaToken = token.split(200n);

const childAgent = await SummarizerAgent.newPhantom();
const summary = childAgent.summarize(text, childToken);
```
```rust
let child_token: QuotaToken = token.split(200);

let child_agent = SummarizerAgent::new_phantom().await;
let summary = child_agent.summarize(text, child_token).await;
```
```scala
val childToken: QuotaToken = token.split(BigInt(200))

for {
  childAgent <- SummarizerAgent.newPhantom()
  summary <- childAgent.summarize(text, childToken)
} yield summary
```
```moonbit
let child_token: QuotaToken = self.token.split(200UL)

let child_agent = SummarizerAgent::new_phantom()
child_agent.summarize(text, child_token)
```
{% end %}

In addition to this, we could return the split tokens after the remote call, and merge them back into the original agent's tokens:

{% codetabs() %}
```typescript
token.merge(returnedToken)
```
```rust
token.merge(returned_token)
```
```scala
token.merge(returnedToken)
```
```moonbit
token.merge(returned_token)
```
{% end %}
