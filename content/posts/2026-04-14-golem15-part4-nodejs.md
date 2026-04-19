+++
title = "Golem 1.5 features - Part 4: Node.js compatibility"
[taxonomies]
tags = ["golem", "durable-execution", "agents", "typescript", "golem-1.5", "nodejs"]
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

## JS/TS support
The previous release introduced our new QuickJS based **JavaScript engine** and supported using **TypeScript** for writing Golem applications. The runtime itself and the Golem SDK already worked well, however not many of the third party libraries of the JS/TS ecosystem were compatible with our runtime. We have put a lot of effort into increasing our runtime's compatibility with both browser APIs and Node.js modules.

### Previously supported
The runtime shipped with the last Golem release supported the following APIs:

- Good support for: `Console`, HTTP (`fetch`), `URL`, Streams, Timeout functions, Encoding, `Crypto`
- Very limited support for parts of `node:util`, `node:buffer`, `node:fs`, `node:path`, `node:process` and `node:stream`
- base64-js, ieee754

### The current state
During the development of **Golem 1.5**, we took Node.js's own test suite and tried to reach as high compatibility as possible with our runtime. Of course it cannot support it 100%, given the constraints of running on a different JS engine, in a single-threaded, sandboxed WASM environment. Still, we were able to implement a large part of Node.js's modules, tested some third party libraries extensively by hand and verified hundreds via automated coding agents.

The summary of what we have now:

- Web Platform APIs: `Console`, HTTP (`fetch`), `URL`, Streams, Timers, Abort Controller, Encoding, Messaging, Events, `Intl`, `Crypto` (global), Structured Clone
- Node modules: 
  - `node:assert`
  - `node:async_hooks`
  - `node:buffer`
  - `node:constants`
  - `node:crypto`
  - `node:diagnostics_channel` (implemented through Golem's invocation context APIs)
  - `node:dgram`
  - `node:dns`
  - `node:domain`
  - `node:events`
  - `node:fs`
  - `node:fs/promises`
  - `node:http`
  - `node:https`
  - `node:module`
  - `node:net`
  - `node:os`
  - `node:path`
  - `node:perf_hooks`
  - `node:process`
  - `node:punycode`
  - `node:querystring`
  - `node:readline`
  - `node:sqlite`
  - `node:stream`
  - `node:string_decoder`
  - `node:test`
  - `node:timers`
  - `node:trace_events`
  - `node:tty`
  - `node:url`
  - `node:util`
  - `node:vm`
  - `node:zlib`
- Defined (to satisfy imports) but not implemented:
  - `node:child_process` (not possible in our current WASM runtime)
  - `node:cluster`
  - `node:inspector`
  - `node:http2` (not possible in our current WASM runtime)
  - `node:repl`
  - `node:tls`
  - `node:v8` (not running on V8)
  - `node:worker_threads` (not possible in our current WASM runtime)

### More information
For more information you can take a look at the vendored Node.js test [compatibility report](https://github.com/golemcloud/wasm-rquickjs/blob/main/tests/node_compat/report.md) and the [automated library compatibility test report](https://github.com/golemcloud/wasm-rquickjs/blob/main/tests/libraries/libraries.md).

After **Golem 1.5** is released, we are going to further increase the compatibility of this runtime; please report any compatibility issues, real-world problems are going to be taken as highest priority.
