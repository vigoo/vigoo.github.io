+++
title = "LambdaConf 2024-2025 - one year of Golem"

[taxonomies]
tags = ["golem"]
+++

I'm on the last LambdaConf at the moment, and exactly a year ago I gave a [talk about Golem on LambdaConf 2024](/posts/golem-and-the-wasm-component-model). Someone asked me what happened with Golem since then? So many things I could not properly answer. So here is a short summary of one year amount of Golem development, from LambdaConf 2024 to LambdaConf 2025.

We had a Golem Hackathon on last LambdaConf, and had a fresh release of Golem for it which we called **Golem 0.0.100**. We've spent the summer after that to prepare the first production ready release of Golem OSS, **Golem 1.0**, which we released 23th of August, 2024. In the few months between the hackathon and Golem 1.0, we made Golem's oplog store more scalable, introduced _environment inheritance_ between workers when they are spawned through RPC, added a worker scheduler that tracks worker memory usage and suspends workers when necessary to keep the system responsible. The stability of the executor itself has been improved significantly. We tried to make the CLI for 1.0 more user friendly, created precompiled binaries of it so users don't have to compile it themselves, and created the first usable version of **Rib**, our scripting language used in Golem's API gateway.

Rib itself did not stop there - we continued working on it in the rest of the year and it got much better type inference, error messages, new language features such as first-class worker support, list comprehensions and aggregations and so on.

Our next milestone was **Golem 1.1**, which has been released on the 9th of December, 2024. With this release we were no longer just targeting durable execution but realized that most applications also need components that are ephemeral - so we added support for **ephemeral components**, which are stateless programs getting a fresh instance for each incoming call. We added the concept of **plugins** in this release, although not fully complete yet, but with a vision of a future plugin ecosystem where these plugins can transform user's components and observe the living workers realtime. The API gateway got support for things like **authentication** and **CORS**, and we created tools to better observe the Golem worker's history by **querying their oplog** itself. This was the first release with the ability to add an **initial file system** for components.

We were trying to make it easier for users, especially if they are not Rust developers, to use Golem. So we created precompiled, downloadable **single executable Golem versions** for local development.

Golem 1.1 was also the first version introducing the **Golem application manifest**. This brings the concept of an _application_, consist of one or more components, with the ability to describe (RPC) **dependencies** between these components in a declarative way. This significantly simplified the way how these multi-component Golem applications are built, especially the iterative development process.

For **Golem 1.2** we decided to make this application manifest feature a core element of Golem development. We have redesigned the CLI to be based on the application concept, with single commands to build and deploy whole, multi-component Golem applications with support for dependencies between these components and allowing them to be written in different programming languages, even within a single application.

We also improved our RPC solution so it no longer requires a working Rust toolchain. Instead we are **linking** the RPC clients dynamically in the executor.

Other improvements added in the 3-4 months of development of Golem 1.2 consisted of the first version of Golem's **debugging** service, which will allow interactive debug and observation of running workers once it is done. Other features helping with the debugging of Golem code are the support for **reverting** workers and cancel pending invocations. We have added support for special kind of workers implementing a HTTP **request handler** (using the wasi-http interface) that can be directly mapped in the API gateway to various endpoints, and get the whole incoming HTTP request to be processed in the worker itself. We also support now **scheduling** invocations (even through RPC) to be done at an arbitrary point in time instead of being executed immediately.

Golem 1.2 has been released on 27th of March, 2025.

In the roughly 1.5 months since then we were focusing on further improving the developer experience by updating our **language support** to the latest version of everything (especially the JavaScript and TypeScript, Python and Go tooling). We can now define _plugin installations_ and _APIs_ in the **application manifest** itself. We continued making the application manifest the primary way to work with Golem by further simplifying the CLI interface and enforcing that every Golem component is named the same as the WIT package it defines. We've introduced a **new dependency type** in the application manifest for directly depending on another WASM component, composing them build-time. This dependency type even supports downloading these WASM components from remote URLs, which is an nice way to use WASM components as language-independent libraries. The first such library we provide is [**golem-llm**](https://github.com/golemcloud/golem-llm). The dependencies can now also added using a CLI command for those who prefer this method. In addition to that, we improved the CLI's **error messages** significantly. Another small detail is that in Golem Cloud accounts can be now referenced by their **e-mail address**, which allows us to for example share a project with other accounts by using their e-mail. Another small improvement is the ability to define **environment variables** on a per-component level now (not just per worker). A nice new feature available for Golem programs is the ability to **fork** workers.

Rib continued to evolve, being more and more stable and having better error reporting. It is no longer just a scripting language to be used as glue code in the API gateway, but it is also integrated into the CLI as a **REPL**, a convenient way to interact with Golem workers.

All these DX improvements are going to be released today as **Golem 1.2.2**, the version to be used on the LambdaConf 2025 hackathon.
