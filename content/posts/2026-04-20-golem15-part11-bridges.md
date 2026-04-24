+++
title = "Golem 1.5 features - Part 11: Bridge libraries"
[taxonomies]
tags = ["golem", "durable-execution", "agents", "golem-1.5", "codegen"]
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

## Calling agents from outside of Golem
There are multiple ways to create and invoke **Golem agents** from _outside_ of Golem. It is possible to [expose agents through HTTP](/posts/golem15-part1-code-first-routes) or [MCP](/posts/golem15-part3-mcp), to use the CLI or the new [REPL](/posts/golem15-part12-repl), or just use Golem's own REST API directly.

With **Golem 1.5** we added one more way to this list: generating **bridge libraries**. A bridge library is a self-contained Rust crate or TypeScript npm package implementing a fully **type-safe** client for a specific agent, to be used in non-golem applications. The Rust crate is built on `reqwest` for making requests to Golem's REST API under the hood, while the TypeScript one uses `fetch`. 

Note that due to time constraints, Golem 1.5 will not have bridge generators for Scala and MoonBit as a target language, but we will add them in a future release. This means that it is possible to generate a Rust or TypeScript library to work with agents written in Scala or MoonBit, but it is not possible to generate a Scala or MoonBit library yet.

### Enabling the bridge generator
Generating these bridge libraries can be enabled **per-agent** and **per language**. The following example enables generating a TypeScript package to call the `CounterAgent`, and one Rust crate for _every agent_ in the project:

```yaml
bridge:
  ts:
    agents: 
      - CounterAgent
  rust: 
    agents: "*"
```

After running `golem build`, the generated bridges are in the `golem-temp` directory:
- `golem-temp/bridge-sdk/ts/counter-agent-client`
- `golem-temp/bridge-sdk/rust/counter-agent-client`
- etc.

### Using the bridge libraries
The generated libraries follow the same conventions as our **agent-to-agent** communication implementation: there is a type matching the agent type's name with static constructor methods such as `get` (upserts a Golem agent identified by its constructor parameters), and `getPhantom`/`newPhantom` for phantom agents. There are also variants for overriding [configuration](/posts/golem15-part7-config-and-secrets).

The following example demonstrates how to call the default template's simple _counter agent_ from arbitrary Rust and TypeScript applications using the generated bridges:

{% codetabs() %}
```typescript
import {
  CounterAgent,
  configure,
} from 'counter-agent-client/counter-agent-client.js'

configure({
  server: { type: 'local' },
  application: 'bridgetest',
  environment: 'local'
})

const c1 = await CounterAgent.get('c1')
const value = await c1.increment()
```
```rust
use counter_agent_client::CounterAgent;
use golem_client::bridge::GolemServer;

CounterAgent::configure(
    GolemServer::Local,
    "bridgetest",
    "local"
);

let c1 = CounterAgent::get("c1").await?;
let value = c1.increment().await?;
```
{% end %}

In the configuration call we have to specify which Golem server to connect to - `Local` is the default local `golem server run` instance, but it can also connect to our hosted `Cloud` or to any custom deployment. The second parameter is the application name (can be found in the `app:` key of `golem.yaml`), and the third is the environment name (there can be multiple environments on the same server for an application, for example staging and prod).

Although not demonstrated by this simple example, these generated libraries are fully type-safe, defining all the custom data types used in the parameter list or return type of the agent methods.

### Method variants
Just like with agent-to-agent communication, each agent method has multiple _variants_ in the generated client. The default, matching the agent method's name, invokes the method and **awaits** its result. There is also a way to just **trigger** the invocation without awaiting it, or to **schedule** it to be called at a given point in time.
