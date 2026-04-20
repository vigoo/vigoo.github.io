+++
title = "Golem 1.5 features - Part 10: WebSocket client"
date = 2026-04-18T11:50:00Z
[taxonomies]
tags = ["golem", "durable-execution", "agents", "golem-1.5", "websocket"]
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

## WebSockets
Golem applications are WebAssembly components and the only way they can make external requests is through the [WASI HTTP interface](https://github.com/WebAssembly/WASI/tree/main/proposals/http/). This is not really visible for Golem developers - in TypeScript and Scala the standard `fetch` or `node:http` interfaces are hiding this fact, just like in Rust where higher level HTTP libraries like `wstd::http` can be used.

This HTTP interface has its limitations; one such limitation is that it does not support upgrading to a WebSocket connection.

### WebSocket client API
In **Golem 1.5** we introduce a new WebSocket client API that complements the WASI HTTP one for connecting to 3rd party WebSocket servers. 

Under the hood this API is described by the following WebAssembly interface:

<details>
<summary>WIT definition of <code>golem:websocket@1.5.0</code></summary>

```wit
package golem:websocket@1.5.0;

interface client {
  use wasi:io/poll@0.2.3.{pollable};

  variant error {
    connection-failure(string),
    send-failure(string),
    receive-failure(string),
    protocol-error(string),
    closed(option<close-info>),
    other(string),
  }

  record close-info {
    code: u16,
    reason: string,
  }

  /// A WebSocket message — text or binary
  variant message {
    text(string),
    binary(list<u8>),
  }

  /// A WebSocket connection resource
  resource websocket-connection {
    /// Connect to a WebSocket server at the given URL (ws:// or wss://)
    /// Optional headers for auth, subprotocols, etc.
    connect: static func(
      url: string,
      headers: option<list<tuple<string, string>>>
    ) -> result<websocket-connection, error>;

    /// Send a message (text or binary)
    send: func(message: message) -> result<_, error>;

    /// Receive the next message (blocks until available)
    receive: func() -> result<message, error>;

    /// Receive the next message with a timeout in milliseconds.
    /// Returns none if the timeout expires before a message arrives.
    receive-with-timeout: func(timeout-ms: u64) -> result<option<message>, error>;

    /// Send a close frame with optional code and reason
    close: func(code: option<u16>, reason: option<string>) -> result<_, error>;

    /// Returns a pollable that resolves when a message is available to read
    subscribe: func() -> pollable;
  }
}
```

</details>

This is just an implementation detail which can be mostly hidden by higher level APIs provided by our language-specific SDKs, just like the WASI HTTP interfaces are.

### Higher level WebSocket APIs

In **TypeScript** the WebSocket support is implemented through the standard browser [`WebSocket`](https://developer.mozilla.org/en-US/docs/Web/API/WebSocket) and [`WebSocketStream`](https://developer.mozilla.org/en-US/docs/Web/API/WebSocketStream) APIs.

In **Rust** we could not override the behavior of an existing WebSocket library so the Golem Rust SDK provides its own, inspired by the popular [tungstenite](https://github.com/snapview/tungstenite-rs) library.

**Scala** compiles to JS on Golem, so the most straightforward approach is to use the browser `WebSocket`/`WebSocketStream` APIs. At the time of writing [`zio-http`](https://ziohttp.com) does not support WebSockets on Scala.js, but this is something we could possibly fix!

In **MoonBit** we can directly use the low level WIT interface through the generated bindings.

#### Example

The following example shows how an agent method can initiate and run a WebSocket connection:

{% codetabs() %}
```typescript
@agent()
class ExampleAgent extends BaseAgent {
  async run(): Promise<void> {
    return new Promise((resolve, reject) => {
      const ws = new WebSocket("wss://example.com/chat");
  
      ws.onopen = () => {
        console.log("Connected");
        ws.send("Hello, server!");
      };
  
      ws.onmessage = (event: MessageEvent) => {
        if (typeof event.data === "string") {
          console.log("Text:", event.data);
        } else {
          console.log("Binary:", new Uint8Array(event.data));
        }
      };
  
      ws.onerror = () => reject(new Error("WebSocket error"));
      ws.onclose = (event: CloseEvent) => {
        console.log(`Closed [${event.code}] "${event.reason}"`);
        resolve();
      };
    });
  }
}
```
```rust
#[agent_implementation]
impl ExampleAgent for ExampleAgentImpl {
    async fn run() -> Result<(), WebSocketError> {
        let ws = WebsocketConnection::connect("wss://example.com/chat", None)?;
        println!("Connected");
    
        ws.send(&WebSocketMessage::Text("Hello, server!".to_string()))?;
    
        loop {
            match ws.receive().await {
                Ok(WebSocketMessage::Text(text)) => println!("Text: {text}"),
                Ok(WebSocketMessage::Binary(data)) => println!("Binary: {data:?}"),
                Err(WebSocketError::Closed(info)) => {
                    if let Some(info) = info {
                        println!("Closed [{}] \"{}\"", info.code, info.reason);
                    }
                    break;
                }
                Err(err) => return Err(err),
            }
        }
    
        Ok(())
    }
}
```
```scala
case class ExampleAgentImpl() extends ExampleAgent {
  def run(): Future[Unit] = {
    val done = Promise[Unit]()
    val ws = new WebSocket("wss://example.com/chat")
  
    ws.onopen = { (_: Event) =>
      println("Connected")
      ws.send("Hello, server!")
    }
  
    ws.onmessage = { (event: MessageEvent) =>
      event.data match {
        case text: String => println(s"Text: $text")
        case other        => println(s"Binary: $other")
      }
    }
  
    ws.onerror = { (_: Event) =>
      done.tryFailure(new Exception("WebSocket error"))
    }
  
    ws.onclose = { (event: CloseEvent) =>
      println(s"Closed [${event.code}] \"${event.reason}\"")
      done.trySuccess(())
    }
  
    done.future
  }
}
```
```moonbit
pub fn ExampleAgent::run(self : Self) -> Unit raise @common.AgentError {
  let conn = match @websocket_client.WebsocketConnection::connect(
    "wss://example.com/chat", None,
  ) {
    Ok(c) => c
    Err(e) => raise @common.AgentError::InvalidInput("Connect failed: \{e}")
  }
  println("Connected")
  match conn.send(Text("Hello, server!")) {
    Ok(_) => ()
    Err(e) => raise @common.AgentError::InvalidInput("Send failed: \{e}")
  }
  while true {
    match conn.receive() {
      Ok(Text(msg)) => println("Text: \{msg}")
      Ok(Binary(data)) => println("Binary: \{data.length()} bytes")
      Err(Closed(Some(info))) => {
        println("Closed [\{info.code}] \"\{info.reason}\"")
        break
      }
      Err(Closed(None)) => break
      Err(e) => raise @common.AgentError::InvalidInput("Receive failed: \{e}")
    }
  }
  conn.drop()
}
```
{% end %}

### Durability
Golem agents are durable, surviving failures and restarts. But what about these WebSocket connections? In **Golem 1.5** we have limited support for recovering WebSocket connections in case of a restart. 

If the connection happened in the past, and was already closed, it works as expected - the whole communication is stored in the agent's **oplog** and there isn't any problem recovering the agent's state. 

If the connection is still open, we have a problem because WebSocket connections are quite low level - there is no standard way to resume a connection. What Golem does is it assumes that the server supports transparent reconnections, and just reopens the connection and continues sending/receiving on it. For the Golem application's developer this is completely transparent, but it's the server's responsibility to support this kind of resumption.

If the server does not support this kind of reconnection, then agents using these connections are no longer able to transparently survive failure scenarios. This is something we can further improve in upcoming Golem releases.
