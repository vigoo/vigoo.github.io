+++
title = "Golem 1.5 features - Part 15: MoonBit"
[taxonomies]
tags = ["golem", "durable-execution", "agents", "golem-1.5", "moonbit"]
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

## MoonBit support
The new **Golem 1.5** release compes with two new supported languages: [Scala](/posts/golem15-part5-scala) and **MoonBit**. An experimental Golem MoonBit SDK has already been released as a separate project for the previous Golem version, but now it becomes a first-class supported language, integrated with our CLI and build flows.

[MoonBit](https://www.moonbitlang.com) is an interesting new language with many nice features. One property that distinguishes it from the other languages we support is that it can compile to very small WASM binaries (and very quickly). This makes a difference in Golem, as the smallest the actual compiled component is, the faster we can instantiate an agent.

As with Scala, we don't have [bridge generators](/posts/golem15-part11-bridges) and a MoonBit [REPL](/posts/golem15-part12-repl) yet, but the TypeScript REPL is fully usable with MoonBit agents as well.

### How does it look like?
Let's see how the simplest _counter agent_ example looks like in MooBit:

```moonbit
///|
/// Counter agent in MoonBit
#derive.agent
struct Counter {
  name : String
  mut value : UInt64
}

///|
/// Creates a new counter with the given name
fn Counter::new(name : String) -> Counter {
  { name, value: 0 }
}

///|
/// Increments the counter and returns the new value
pub fn Counter::increment(self : Self) -> UInt64 {
  self.value += 1
  self.value
}

///|
/// Returns the current value of the counter
pub fn Counter::get_value(self : Self) -> UInt64 {
  self.value
}
```

Agents are structs annotated with `#derive.agent`, and all public methods are becoming **agent methods**. The type needs a `new` constructor that is going to the agent's **identity**.

Custom data types are supported by annotating them with `#derive.golem_schema`:

```moonbit
#derive.golem_schema
struct MyData {
  field1: String
  field2: UInt
}

#derive.golem_schema
enum Status {
  Active
  Inactive(String)
```

Every type used in the constructor or agent methods (either as a parameter or return type) must have a derived Golem schema.

#### RPC
Agent to agent communication works just like with the other languages - for each agent we have a **client type** generated:

```moonbit
CounterClient::scoped("my-counter", fn(counter) raise @common.AgentError {
  counter.increment()
  counter.increment()
  let value = counter.get_value()
  value
})
```

The `scoped` function is equivalent to calling the `get` constructor (that in Golem means "get or create if not existing" an agent), and dropping the remote connection in the end. 

#### Exposing HTTP endpoints
As we've seen, Golem 1.5 comes with [code-first routes](/posts/golem15-part1-code-first-routes) and MoonBit also fully supports this. For example we could expose our counter via a POST endpoint by just adding a few more annotations:

```moonbit
#derive.agent
#derive.mount("/moonbit-counters/{name}")
struct Counter {
 // ...
}

#derive.endpoint(post="/increment")
pub fn Counter::increment(self : Self) -> UInt64 {
  // ..
}
```

### Other features
Every other feature we mentioned in [this series](https://blog.vigoo.dev/tags/golem/) is available for MoonBit. The new version of our [documentation](https://learn.golem.cloud) will have every code snippet presented in all supported languages including MoonBit, and we our [skill catalog](/posts/golem15-part9-skills) also have a large number of MoonBit specific agent skills. Until the new documentation site is published, they can be checked in [the repo](https://github.com/golemcloud/golem/tree/main/golem-skills/skills/moonbit).

### Implementation details
The MoonBit SDK consists of two major parts: a code-level transformation tool implemented in MoonBit using the [moonbitlang/parser](https://mooncakes.io/docs/moonbitlang/parser) and [moonbitlang/formatter](https://mooncakes.io/docs/moonbitlang/formatter) packages, and a MoonBit library every Golem application must depend on.

The tool parses the user's source code and finds all the Golem-specific derive attributes, and generates code (typeclass implementations for annotated custom types, agent registration code, RPC clients etc). The SDK encapsulates the generated WASM bindings (using `wit-bindgen-moonbit`) and presents them as a higher level MoonBit library for the Golem developers.

The whole multi-step build flow is _hidden_ in a [golem-managed build template](https://github.com/golemcloud/golem/blob/main/cli/golem-cli/templates/moonbit/common-on-demand/golem.yaml).
