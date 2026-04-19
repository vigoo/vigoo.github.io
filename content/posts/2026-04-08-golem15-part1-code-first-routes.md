+++
title = "Golem 1.5 features - Part 1: Code-first routes"

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

## Code-first routes
In the previous Golem release we introduced **code-first agents** - we started defining everything in code, with the help of some TypeScript decorators and Rust annotations. With this we could define **agents** that expose a typed interface, can call each other and so on - but to expose these interfaces via regular HTTP endpoints, we had to define these endpoints in a OpenAPI-like YAML section and use a custom scripting language called **Rib** to map between the request/response and the underlying agent interface.

In **Golem 1.5** this is no longer the case - no custom scripting language, no YAML description of endpoints, everything is possible directly from our agent's code!

### Mount points

First we have to define a **mount point** for our agent:

{% codetabs() %}
```typescript
@agent({
  mount: '/task-agents/{name}',
})
export class Tasks extends BaseAgent {
  // ...
}
```
```rust
#[agent_definition(mount = "/task-agents/{name}")]
pub trait Tasks {
    // ...
}
```
```scala
@agentDefinition(mount = "/task-agents/{name}")
trait Tasks extends BaseAgent {
  // ...
}
```
```moonbit
#derive.agent
#derive.mount("/task-agents/{name}")
pub(all) struct Tasks {
  // ...
}
```
{% end %}

In the mount path we can use placeholders like `{name}` that identifies our agent - it maps directly to our agent constructor's `name` parameter. If there are multiple agent parameters, they all have to be mapped in the mount path.

### Endpoints

Once we have our mount we can export individual agent methods as various **endpoints**:

{% codetabs() %}
```typescript
@endpoint({ post: "/tasks" })
async createTask(request: CreateTaskRequest): Promise<Task> {
    // ...
}

async getTasks(): Promise<Task[]> {
    // ...
}

@endpoint({ post: "/tasks/{id}/complete" })
async completeTask(id: number): Promise<Task | null> {
    // ...
}
```
```rust
#[endpoint(post = "/tasks")]
fn create_task(&mut self, request: CreateTaskRequest) -> Task;

#[endpoint(get = "/tasks")]
fn get_tasks(&self) -> Vec<Task>;

#[endpoint(post = "/tasks/{id}/complete")]
fn complete_task(&mut self, id: usize) -> Option<Task>;
```
```scala
@endpoint(method = "POST", path = "/tasks")
def createTask(request: CreateTaskRequest): Future[Task]

@endpoint(method = "GET", path = "/tasks")
def getTasks(): Future[Array[Task]]

@endpoint(method = "POST", path = "/tasks/{id}/complete")
def completeTask(id: Int): Future[Option[Task]]
```
```moonbit
#derive.endpoint(post="/tasks")
pub fn Tasks::create_task(self : Self, request : CreateTaskRequest) -> Task {
  // ...
}

#derive.endpoint(get="/tasks")
pub fn Tasks::get_tasks(self: Self) -> Array[Task] {
  // ...
}

#derive.endpoint(post="/tasks/{id}/complete")
pub fn Tasks::complete_task(self: Self, id: UInt32) -> Option[Task] {
  // ...
}
```
{% end %}

Endpoint paths are relative to the mount point, and they can also use placeholders mapped to parameters. Unmapped parameters are set from the request body. Query parameters are also supported in the `path` patterns.

### Additional features

Custom headers can also be mapped to function parameters:

{% codetabs() %}
```typescript
@endpoint({
    get: '/example',
    headers: { 'X-Foo': 'location', 'X-Bar': 'name' },
  })
async example(location: string, name: string): Promise<String> {
  // ...
}
```
```rust
#[endpoint(get = "/example", headers("X-Foo" = "location", "X-Bar" = "name"))]
fn example(&self, location: String, name: String) -> String;
```
```scala
@endpoint(method = "GET", path = "/example")
def example(@header("X-Foo") location: String, @header("X-Bar") name: String): Future[String]
```
```moonbit
#derive.endpoint(get="/example")
#derive.endpoint_header("X-Foo", "location")
#derive.endpoint_header("X-Bar", "name")
pub fn ExampleAgent::example(
  self : Self,
  location: String,
  name: String
) -> String {
  // ...
}
```
{% end %}

Additionally, endpoint decorators support CORS and authentication. For CORS, we can add something like `cors = ["*"]` to the decorator (syntax slightly varies by language).
We can turn on **authentication** on the mount level or per individual endpoints. When authentication is enabled, agent constructors and methods optionally can receive a `Principal` parameter that contains information about the authenticated user.

It's also possible to tell the HTTP layer to create a **phantom agent** for each request - this is useful for ephemeral, stateless agents serving as a gateway to internal agents as it allows requests to be processed completely parallel. This is a single line change (`phantomAgent = true`) in the code, just changes how Golem internally maps each individual request to agent instances. Details of this technique will be provided in the updated documentation site.

### Deployments
There is still a small step necessary in the application manifest file to make these code-first routes deployed:

```yaml
httpApi:
  deployments:
    local:
    - domain: app-name.localhost:9006
      agents:
        Tasks: {}
```

We can specify what agents to deploy to what (sub)domains, and specify this per **environment** (such as local/staging/prod, for example).

### OpenAPI

Defining endpoints in code does not mean we cannot have proper OpenAPI specifications for them. Golem automatically adds an `openapi.yaml` endpoint to each deployment:

```shell
$ curl http://routes.localhost:9006/openapi.yaml
components: {}
info:
  title: Managed api provided by Golem
  version: 1.0.0
openapi: 3.0.0
paths:
  /openapi.yaml:
    get:
      responses:
        "200":
          content:
            application/yaml:
              schema:
                additionalProperties: true
                type: object
          description: Response 200
  /task-agents/{name}/tasks:
    get:
      parameters:
        - description: 'Path parameter: name'
          explode: false
          in: path
          name: name
          required: true
          schema:
            type: string
          style: simple
      responses:
        "200":
# ...
```
