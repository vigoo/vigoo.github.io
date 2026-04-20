+++
title = "Golem 1.5 features - Part 2: Webhooks"

[taxonomies]
tags = ["golem", "durable-execution", "agents", "code-first", "golem-1.5"]
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

## Webhooks
We have seen how we can map our agents to HTTP APIs in the [previous post](/posts/golem15-part1-code-first-routes). Another new feature of **Golem 1.5**, closely related to that, is the ability to **create webhooks** and await them.

Let's see how it works!

### Creating a webhook
Webhooks are built on top of [Golem Promises](https://learn.golem.cloud/develop/promises), which were available in previous Golem releases as well. These are entities you can create from code and then await - while the agent is waiting, it gets fully suspended, consuming no resources.

What's new is that we can now export these promises as webhook URLs that make it very easy to complete them from a third party system.

{% codetabs() %}
```typescript
const webhook = createWebhook();
const url = webhook.getUrl();

// At this point we can somehow advertise this `url` - return as a result, post to a 3rd party API, etc

const payload = await webhook; // block until someone calls the webhook with a payload
const result: T = payload.json();
```
```rust
let webhook = create_webhook();
let url = webhook.url();

// At this point we can somehow advertise this `url` - return as a result, post to a 3rd party API, etc
 
let request = webhook.await;
let data: T = request.json().unwrap();
```
```scala
val webhook = HostApi.createWebhook()
val url = webhook.url

// At this point we can somehow advertise this `url` - return as a result, post to a 3rd party API, etc

webhook.await().map { payload =>
  val event = payload.json[T]()
  // ...
}
```
```moonbit
let webhook = @webhook.create()
let url = webhook.url()

// At this point we can somehow advertise this `url` - return as a result, post to a 3rd party API, etc

let payload = webhook.wait()
let text = payload.text()
```
{% end %}

### Calling the webhook
The webhook URL simply awaits a POST request with an arbitrary body. This body is what the `payload`'s helper methods are returning as raw byte array, string or parsed JSON.

### Customizing the webhook URL
There are two ways to customize the webhook URL, which is having the following form:

```
https://<domain>/<prefix>/<suffix>/<id> 
```

The `<domain>` part is the domain where our API is deployed to. The `<prefix>` is `/webhooks` by default, and it can be customized in the deployment section of the Golem application manifest:

```yaml
httpApi:
  deployments:
    default:
      - domain: example.com
        webhookUrl: "/my-custom-webhooks/"
        agents:
          # ...
```

The `<suffix>` part is the agent's type name in `kebab-case` by default, so for example `my-workflow` if our agent type is `MyWorkflow`. It can be customized by setting **webhook suffix** on our mount point:

{% codetabs() %}
```typescript
@agent({
  mount: '/workflow/{id}',
  webhookSuffix: '/workflow-hooks'
})
class Workflow extends BaseAgent {    
  // ...
}
```
```rust
#[agent_definition(
    mount = "/workflow/{id}",
    webhook_suffix = "/workflow-hooks"
)]
pub trait Workflow {
    // ...
}
```
```scala
@agentDefinition(
  mount = "/workflow/{id}",
  webhookSuffix = "/workflow-hooks",
)
trait Workflow extends BaseAgent {
  // ...
}
```
```moonbit
#derive.agent
#derive.mount("/workflow/{id}")
#derive.mount_webhook_suffix("/workflow-hooks")
pub(all) struct Workflow {
  // ...
}
```
{% end %}
