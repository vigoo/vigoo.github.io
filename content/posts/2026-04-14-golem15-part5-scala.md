+++
title = "Golem 1.5 features - Part 5: Scala support"
date = 2026-04-14T20:45:00Z
[taxonomies]
tags = ["golem", "durable-execution", "agents", "scala", "golem-1.5"]
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

## Scala support
We love **Scala** and always wanted to have it among the supported languages for **Golem**. As Golem runs _WASM components_ this had some difficulties; there are ongoing projects trying to make Scala compiled to WASM, but none of them were production-ready yet a few months ago - and as far as I know, they still are not. So we took a different route - as we already put [a lot of effort in our JS support](/posts/golem15-part4-nodejs), we decided to support Scala through **Scala.js**.

Scala gets compiled to JS using Scala.js, and executed in our QuickJS based runtime which is compiled to WASM. This sounds way too complicated, but it works; the important part is not this compilation chain, but rather the **Golem Scala SDK** and its integration with Golem's CLI, which support everything that the other supported languages do.

### CLI integration
Scala is a supported language in the Golem CLI - we can select it when creating a new application, and choose from existing _templates_ (although at the time of writing we only have one). When working with a Scala agent through the CLI, types and values (agent identifiers, method parameters, etc.) are parsed and printed using the Scala syntax. The CLI installs a huge catalog of Scala specific agentic skills helping your AI coding assistant write Scala code that runs on Golem.

Part of the build chain is an `sbt` plugin, but the whole application is built using `golem build` just like with the other supported languages.

#### What's not supported yet?

Two features are not available yet for Scala: 
- there is no Scala REPL yet, but you can use the TypeScript one to work with Scala (or any other) agents 
- there is no Scala bridge library generator yet - this is a new feature to be explained in a future part of this series; it is a feature that makes it really easy to call agents from non-Golem applications in a typesafe way.

### Code-first features
Just like with the other supported languages, we can define Golem **agents** purely by writing Scala code and using some _annotations_:

```scala
@agentDefinition(mount = "/counters/{name}")
trait CounterAgent extends BaseAgent {

  class Id(val name: String)

  @prompt("Increase the count by one")
  @description("Increases the count by one and returns the new value")
  @endpoint(method = "POST", path = "/increment")
  def increment(): Future[Int]
}

@agentImplementation()
final class CounterAgentImpl(@unused private val name: String) extends CounterAgent {
  private var count: Int = 0

  override def increment(): Future[Int] = Future.successful {
    count += 1
    count
  }
}
```

This is the default template, a very simple stateful agent representing a counter. The example also demonstrates how [code-first routes](/posts/golem15-part1-code-first-routes) are also supported.

Note that in every code example in [this series](https://blog.vigoo.dev/tags/golem-1-5/), I'm showing Scala examples as well.

### RPC
One part of the custom build step implemented by the sbt plugin is generating **client classes** for all the agents. This is very similar to how we do it in Rust - for a given agent called `Xyz` we generate a new type called `XyzClient` with **client constructor methods** such as `get` or `newPhantom` to get an enriched interface of our agent's methods. This enriched interface not only has the original agent methods - calling them means "invoke it on the remote agent, and await the result" - but also has variants for _triggering_ a remote invocation without awaiting its results, and to _schedule it_ for a future point in time.

Here is an example of how using these clients look like:

```scala
@agentDefinition()
@description("Calls CounterAgent remotely and returns the result.")
trait CallerAgent extends BaseAgent {
  class Id(val value: String)

  @description("Increments the given counter N times and returns the final value.")
  def incrementCounter(counterId: String, times: Int): Future[Int]
}

@agentImplementation()
final class CallerAgentImpl(@unused private val name: String) extends CallerAgent {
  override def incrementCounter(counterId: String, times: Int): Future[Int] = {
    val counter = CounterAgentClient.get(counterId)

    (1 until times)
      .foldLeft(counter.increment()) { (prev, _) =>
        prev.flatMap(_ => counter.increment())
      }
  }
}
```

### HTTP
As we compile to JS, we can (and have to) use `fetch` for making HTTP requests. It can be called directly using Scala.js's interfaces, but it is also possible to use the [zio-http](https://ziohttp.com) library that has a fetch backend!

Let's see an example agent using **zio-http**!

```scala
@agentImplementation()
final class FetchAgentImpl() extends FetchAgent {
  override def fetchFromPort(port: Int): Future[String] = {
    val effect =
      for {
        response <- ZIO.serviceWithZIO[Client] { client =>
                      client.url(url"http://localhost").port(port).batched.get("/test")
                    }
        body <- response.body.asString
      } yield body;

    Unsafe.unsafe { implicit u =>
      Runtime.default.unsafe.runToFuture(effect.provide(ZClient.default))
    }
  }
}
```

## Next steps
This is just the beginning. The core Golem SDK is quite low level with no integration with ZIO or other libraries (although it uses the [new **ZIO Schema**](https://www.youtube.com/watch?v=hWhxIYNl1T8) under the hood). With Scala support included in the **Golem 1.5** release we can start building on top of this to have a first-class Scala experience for Golem!
