+++
title = "Golem 1.5 features - Part 7: Configuration and Secrets"
[taxonomies]
tags = ["golem", "durable-execution", "agents", "golem-1.5", "code-first"]
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
- [Part 11: Bridge libraries](/posts/golem15-part11-bridges)
- [Part 12: REPL](/posts/golem15-part12-repl)
- [Part 13: Per-agent configuration](/posts/golem15-part13-per-agent-config)
- [Part 14: OpenTelemetry](/posts/golem15-part14-otlp)

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
    readonly config: Config<ExampleConfig> // injection
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
    fn new(name: String, #[agent_config] config: Config<ExampleConfig>) -> Self;
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
#derive.config
pub(all) struct DbConfig {
  host : String
  port : UInt
}

#derive.config
pub(all) struct ExampleConfig {
  debug_logs : Bool
  alias : String?
  database : DbConfig  // nesting
}

#derive.agent
pub(all) struct ExampleAgent {
  example_param : String
  config : @config.Config[ExampleConfig] // injection
}

fn ExampleAgent::new(
  example_param : String,
  config : @config.Config[ExampleConfig]
) -> ExampleAgent {
  { example_param, config }
}

pub fn ExampleAgent::use_config(self : Self) -> Unit {
  let config = self.config.value
  if config.debug_logs {
    @log.debug("Debug logs enabled")
  }
}
```
{% end %}

Once we define these configuration **requirements** in code, we can no longer deploy our agent without satisfying them first! 

We can assign values to each field of our structured configuration per agent in the application manifest:

```yaml
agents:
  ExampleAgent:
    config:
      debugLogs: true
      alias: "main"
      database:
        host: "localhost"
        port: 5432
```

It is also possible to use the manifest's `preset` feature to define reusable bits of configuration that can be easily applied to multiple agents, or to define config values that apply to _all_ agents within a component.

### Secrets
**Secrets** are a special type of configuration - while regular configuration is tied to deployments, secrets can be updated dynamically for example when an API Token needs to be rotated. The difference between regular configuration and secrets is visible both in the code, and in the agent's metadata. The type difference encourages you to always `get` the secret's current value to get the latest available value before each use.

To define parts of the agent configuration as being secrets, wrap them in `Secret`. The following example extends our previous `DbConfig` type with a secret `password` field:

{% codetabs() %}
```typescript
type DbConfig = {
  host: string,
  port: number,
  password: Secret<string>
}
```
```rust
#[derive(ConfigSchema)]
pub struct DbConfig {
    host: String,
    port: u16,
    #[config_schema(secret)]
    password: Secret<String>,
}
```
```scala
final case class DbConfig(
  host: String,
  port: Int,
  password: Secret[String]
)
```
```moonbit
#derive.config
pub(all) struct DbConfig {
  host : String
  port : UInt
  password : @config.Secret[String]
}
```
{% end %}

Secret values are stored **per environment** and not per agent deployment. If an environment does not have a secret yet, its initial value can be automatically set at deploy time by using the `secretDefaults` section of the application manifest:

```yaml
secretDefaults:
  local:
    - path: [db, password]
      value: "{{ DB_PASSWORD }}"   # env var substitution supported
```

Just like in previous versions for environment variables, the `{{ X }}` format can be used to set a secret value to an environment variable's value **from the user's system**.

Alternatively secrets can be created using CLI commands:

```bash
golem agent-secret create db.password --secret-type string --secret-value "pwd"
```

The secrets can be examined and updated any time using the CLI:

```bash
golem agent-secret list
golem agent-secret update-value db.password --secret-value "new-pwd"
golem agent-secret delete db.password
```

Deleting a secret can make running agents fail at runtime, if they use it.

To access a secret's current value, use `get` on the `Secret` field — unlike regular config fields, this fetches the latest value each time:

{% codetabs() %}
```typescript
const password = config.database.password.get();
```
```rust
let password = config.database.password.get();
```
```scala
val password = config.database.password.get
```
```moonbit
let password = config.database.password.get!()
```
{% end %}

This way our `password` always gets the latest secret stored in the current environment.
