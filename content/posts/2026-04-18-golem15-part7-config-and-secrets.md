+++
title = "Golem 1.5 features - Part 7: Configuration and Secrets"
[taxonomies]
tags = ["golem", "durable-execution", "agents", "scala", "golem-1.5", "code-fist"]
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

## Code-first Configuration
Before **Golem 1.5**, the standard way to inject configuration values and secrets were through _environment variables_. We can specify environment variables on a per-component, per agent type or per agent instance level, and the application can read them using the standard APIs such as `node:process` or the Rust standard library. Environment variables also get inherited when agents are doing agent-to-agent RPC calls. This works, but has some drawbacks - they can only be strings, and most importantly they are not discoverable. An agent can read arbitrary environment variables and there is no way to tell in advance what they require.

To solve these issues, the new Golem release introduces **code-first configuration and secrets**. Similarly to [code-first routes](/posts/golem15-part1-code-first-routes), agents code can define fully typed configuration types and these become part of an agent's **type** - the deployment operation can verify that all of them are provided and have the proper type, and so on.

### Configuration
Configuration types are record types which can be nested, and are injected specially to the agent's constructor:

{% codetabs() %}
```typescript
type DbConfig = {
  host: string,
  port: number
}

type ExampleConfig = {
  debugLogs: boolean,
  alias?: string,
  database: DbConfig  // nesting
}

@agent()
class ExampleAgent extends BaseAgent {
  constructor(
    exampleParam: string, 
    readonly config: Config<ConfigAgentConfig> // injection
  ) {
    // ...
  }
  
  useConfig() {
    const config = this.config.value;
    if (config.debugLogs) {
      console.debug("Debug logs enabled");
    }
  }
}
```
```rust
#[derive(ConfigSchema)]
pub struct DbConfig {
    host: String,
    port: u16
}

#[derive(ConfigSchema)]
pub struct ExampleConfig {
    debug_logs: bool,
    alias: Option<String>,
    database: DbConfig
}

#[agent_definition]
pub trait ExampleAgent {
    fn new(name: String, #[agent_config] config: Config<ConfigAgentConfig>) -> Self;
    fn use_config(&self);
}

struct ExampleAgentImpl {
    config: Config<ExampleConfig>
}

#[agent_implementation]
impl ExampleAgent for ExampleAgentImpl {
    fn new(example_param: String, #[agent_config] config: Config<ExampleConfig>) -> Self {
        Self { config }
    }

    fn use_config(&self) {
        let config = self.config.get();
        if config.debug_logs {        
            logging::log(logging::Level::Debug, "example", "Debug logs enabled");
        }
    }
}
```
```scala
final case class DbConfig(
  host: String,
  port: Int
)

object DbConfig {
  implicit val schema: Schema[DbConfig] = Schema.derived
}

final case class ExampleConfig(
  debugLogs: Boolean,
  alias: Option[String],
  database: DbConfig
)

object ExampleConfig {
  implicit val schema: Schema[ExampleConfig] = Schema.derived
}


@agentDefinition()
trait ExampleAgent extends BaseAgent with AgentConfig[ExampleConfig] {
  class Id(val exampleParam: String)

  def useConfig(): Future[Unit]
}

@agentImplementation()
final case class ExampleAgentImpl(exampleParam: String, config: Config[ExampleConfig])
  extends ExampleAgent {
  
  override def useConfig(): Future[Unit] = {
    val config = config.value
    if (config.debugLogs) {
      js.Dynamic.global.console.debug("Debug logs enabled");
    }
  }
}
```
```moonbit
```
{% end %}
