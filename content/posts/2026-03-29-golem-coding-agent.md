+++
title = "Golem as a Coding Agent engine"

[taxonimies]
tags = ["golem", "durable-execution", "agents", "coding-agents", "ai", "typescript", "rust"]

+++

## Introduction

**Coding agents** became the new way of writing software for many of us; even though I was skeptical about this for a long time, in the past few months all my code was written by agents, with productivity I never experienced before. The whole ecosystem is changing extremely fast, and people are trying to [figure out](https://x.com/jdegoes/status/2036931874057314390?s=20) what the best set of tools and workflows are to work efficiently in this new era. I cannot answer what set of coding agents, terminals, IDEs or post-IDE user interfaces fit best to the agentic development era. What I want to do is explore how [Golem](https://golem.cloud), the agent-native durable execution platform I'm working on could be a useful component of implementing reliable coding agents.

### What is a coding agent?

There are many existing articles about what exactly coding agents are, and how you can write your own, for example [one from Thorsten Ball from last year](https://ampcode.com/notes/how-to-build-an-agent). Today we have even [frameworks to build your own](https://pi.dev). But the basic idea is very simple: you use an LLM and provide a set of **tools** to it to be able to work on a project. The basic tools it needs are discovering files of your project, reading and editing these files. The models seem to like to do all kind of queries with standard piped Unix commands and [ripgrep](https://ripgrep.dev); they need a way to look up external information on the web, and most importantly they need to be able to actually try things out, to have a full feedback loop. This means they need to be able to trigger compilation, running the code, the test suites, and so on.

There are other aspects of course - finding and loading skill files, spawning sub-agents, dealing with the context size limitations, managing multiple connected threads etc.

All of this is not really super complicated, but it gets worse if you start to think about what can go wrong:

- LLM calls can fail. There can be temporary outages, timeouts, etc. You don't want your expensive, long running agent session to be lost in this case
- We said above we have to give the agent _write access_ and ability to execute arbitrary(?) commands on our computer. How is it not going to do something malicious?
- What my computer crashed, or just accidentally closed the terminal where the agent was operating - do I have to start from scratch?
- Can we guarantee that all the parallel running agents together are not exceeding some kind of AI API quota?

### Golem

Golem is an **agent-native** cloud platform that provides **durable execution**, exactly-once remote calls and many more features. The core entity in Golem is an **agent** - a stateful, potentially long running entity that can process external **invocations**, can spawn and communicate with other Golem agents, access external APIs and databases, and most importantly, can never die.

This what makes Golem (and other durable execution platforms) special - even if the server process crashes, or just need to restart for reasons like rebalancing, updates, etc, the running agents are guaranteed to survive this without any assistance from the programmer. You can store your state in memory, and stop worrying about loosing it for any external reasons.

Another important property of Golem agents is that they are **completely sandboxed**. They are [WASM components](https://component-model.bytecodealliance.org), each having their own linear memory and their own file system. There is no way an agent can interfere with any other agent, only through the trusted agent-to-agent communication channels. There is no way an agent can access any files that is not in its sandboxed file system.

## Golem as a Coding Agent platform

Let's start thinking about how we could take advantage of Golem's durability and sandboxing properties to implement our own coding agent! 

This is going to be a little unusual way to use Golem. Golem is a cloud platform - we provide our hosted infrastructure you can use, or you can bring up your own infrastructure as it is fully open source. We provide a local, single-executable version of it, which is primarily intended to be use for local development and testing.

In this experiment, we are going to fully build on this local Golem build. This will be an important detail when we figure out how to combine the fully sandboxed Golem environment with the need to build and run the developed applications.

### Architecture

In this experimental Golem based coding agent, I'm going to mix in a little the question of managing parallel workspaces as well. The idea we are going to explore is that there is exactly one **read/write coding agent** for a specific repository's specific **branch**. There can be an arbitrary number of **read-only coding agents** on the same branches, with no rights to do any changes. These can be used for exploratory work.

In Golem every _golem agent_ is identified by their constructor parameters. There can be only one instance for a concrete value of these parameters, and invocations and every other command work by using _upsert_ semantics - if the agent identified by your provided constructor parameters (that we call the **agent identity**) does not exist yet, it's going to be transparently created for you. There is extra feature that is going to be very useful for us: **phantom agents**. Phantom agents are "secondary" instances of an agent, distinguished from the primary one with an extra random uuid. This maps perfectly to our plan of representing read/write and read-only coding agents:

- `CodingAgent(repository, branch)` is the ID of a read/write coding agent
- `CodingAgent(repository, branch)[uuid]` is the ID of a read-only coding agent

These Golem agents are going to run the main loop of the coding agent - checkout their repository's branch into their own sandboxed file system, do the LLM calls, and implement tools that work on the files. All sandboxed and all durable automatically.

We also need a user-facing interface for this, of course. This is going to be a text user interface communicating with these Golem agents using another Golem feature - the ability to generate **bridge libraries** that can be used to invoke Golem agents from the outside in a fully type-safe way. It can currently generate Rust and TypeScript libraries.

This all looks straightforward, but we have not talked about one important thing yet:

> How do we make our agent be able to compile and run code?

We can't assume that the agent can set up a build tool-chain in its sandboxed WASM environment. We need to delegate that work to the host machine of the user. Conceptually, we need something like this:

- The agent reaches a state of its branch where it wants to, let's say, compile and run all tests
- We need to mirror the current state of the whole repository to the host machine
- There, we need to use the host machine's tool-chains to compile and run all the tests
- The agent needs to be able to observe the results (standard output, files)

We are going to tweak Golem a little and take advantage that we run it locally. By default each agent's sandboxed virtual filesystem is stored in a separate temp directory on the host filesystem. We are going to enable deterministic, agent-id base locations for these directories. Then we expose some feature through a HTTP server from our host application. Our coding agents will get the ability to call the host app and run some tools there. We are going to define a strict set of allowed commands to be executed on the host. (For example to build a Rust project using `cargo`).

Of course once we allow the agent to run arbitrary compiled code on our host, we are not safe anymore - I'm not going to try to solve this in this post. Having sandboxed and durable editing sessions and being able to strictly limit the host-execution to build tools and the actual generated artifacts is already interesting and different enough from current state of art.

One last thing we haven't talked about yet: LLM sessions have a limited context window so we cannot keep appending forever to a single session within one coding agent instance. We need to be able to start new threads, potentially do compaction of the old one, etc. With the proposed architecture of having one agent instance per "feature branch", we can do all this in the agent's memory. We can store multiple threads in memory, provide ways to query old ones, and provide tools for the LLM to get the compacted version of previous threads, or to read from them if needed.

## Implementation

### Agent language

With the initial design we are ready to start implementing this. Let's first decide what _language_ to use for the agent side. Golem currently fully supports Rust and TypeScript, with experimental support for Scala.js and MoonBit. For this experiment, I'm going to choose between Rust and TypeScript. What we need is a **git client** that works in Golem (will get back to that), a fast grep library and a way to emulate standard Unix commands on the agent's file system, and of course a way to call an LLM.

Let's see a comparison:

| Aspect     | Rust                                     | TypeScript                                                   |
| ---------- | ---------------------------------------- | ------------------------------------------------------------ |
| Git client | https://github.com/GitoxideLabs/gitoxide | https://isomorphic-git.org/                                  |
| AI client  | https://github.com/golemcloud/golem-ai   | Several options, such as [@effect/ai](https://effect.website/blog/effect-ai/) |
| Unix tools | https://crates.io/crates/brush           | https://github.com/shelljs/shelljs                           |

Golem provides an increasing level of Node.js compatibility so many existing libraries can be used as-is. Also, the browser `fetch` API and `node:http` are both working so any library built on top of these will able to call external services from a Golem agent. 

Unfortunately the Rust ecosystem makes this much harder. Golem does not provide low-level socket capabilities at the moment, the only way to make HTTP requests is through the [WASI HTTP interface](https://github.com/WebAssembly/WASI/tree/main/proposals/http/). There are [existing Rust crates](https://crates.io/crates/wstd) wrapping this interface but most of the Rust ecosystem is built on other ones such as `reqwest`, which are _not_ working in Golem out of the box. This is why we provide our own set of AI connector libraries ([golem-ai](https://github.com/golemcloud/golem-ai)) for Rust projects. But we also need a git client. So, if we'd choose Rust, we would need to either:

- be able to plug in our own http library (`wstd`'s client) into the git library
- or implement the git cloning on our host and proxy it through a custom http request to our agents

In addition to the `wasi-http` requirement, all Rust crates we choose to depend on must be compilable to `wasm32-wasip2` target.

Based on a short AI analysis of the `gitoxide` project, it seems like we _could_ extend it with a new, wasi-http based transport layer and most likely it could be compiled to `wasip2`, but it requires forking the library. Even though having `brush` would have been a nice tool for our agent implementation, for this experiment we are going to choose **TypeScript**.

### TUI language

Using TypeScript on the backend does not mean we are forced to use TypeScript for the text user interface. For that, I'm going to use **Rust** simply as a personal preference and the easiness of building distributable single executables.

Golem supports generating cross-language bridge libraries. This means our TypeScript agent's interface will be exposed as a generated Rust crate that we can use to communicate with the agents.

### The first version of our agent

We can start building the agent and build the host environment around it later. To not block on figuring out a nice name for this, I'll just call the project `golem-coding-agent`. We can create a new TypeScript Golem application with the CLI:

```shell
$ golem new gca-agents
Applying template(s)
  Creating /home/vigoo/projects/golem-coding-agent/gca-agents/.gitignore
  Creating /home/vigoo/projects/golem-coding-agent/gca-agents/AGENTS.md
  Creating /home/vigoo/projects/golem-coding-agent/gca-agents/golem.yaml
  Creating /home/vigoo/projects/golem-coding-agent/gca-agents/package.json
  Creating /home/vigoo/projects/golem-coding-agent/gca-agents/src/counter-agent.ts
  Creating /home/vigoo/projects/golem-coding-agent/gca-agents/src/main.ts
  Creating /home/vigoo/projects/golem-coding-agent/gca-agents/tsconfig.json

Finished applying template(s) [OK]
```

We select TypeScript and the basic template, and we end up with an initial TypeScript project implementing a simple agent that implements a counter.

We can validate that it works by doing `golem build`:

```shell
$ golem build
...
Finished building [OK]
```

The build command compiles and bundles the TypeScript project, injects it into a WASM base image, performs some pre-initialization optimizations and then it is ready to be deployed to Golem.

The first thing we should check if we can add all the npm packages we are planning to use (as said, Golem is more and more compatible with Node.js, but there are still gaps). Let's do it:

```shell
$ npm install effect
$ npm install @effect/ai
$ npm install @effect/ai-openai
$ npm install isomorphic-git
$ npm install shelljs
$ golem build
```

It still compiles. Now we can start a local, fresh golem server with `golem server run --clean` and then deploy our code to it:

```shell
$ golem deploy
...
Deployed all changes
╔═
║ Created new deployment
║
║ Application:         gca-agents
║ Environment:         local
║ Environment ID:      019d3982-c09d-7822-b35e-0692657a0503
║ Deployment Revision: 0
║ Hash:                75c45be092d7b5478df95af253bff74fa66ceb8f208a93d8c313ac9cc7a74c93
║ Deploy Revision:     0
╚═

Summary
  Finished deploying [OK]
```

Then try it out with Golem's TypeScript REPL:

```shell
$ golem repl
golem-ts-repl[gca-agents][local]>
>
> Available agent client types:
>   CounterAgent.get(name: string)
>     increment: () => number
>
> To see this message again, use the `.agent-type-info` command!
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
golem-ts-repl[gca-agents][local]> const c = CounterAgent.get("test")
golem-ts-repl[gca-agents][local]> c.increment()
> awaiting Promise<number>
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
1
golem-ts-repl[gca-agents][local]>
```

Everything seems to work. From this point I'll just let my (non-golem) coding agent do the actual implementation. First we replace the counter agent with a new agent called `CodingAgent` that already takes the repository and branch names, as we planned, and uses the git library to clone and check out that branch:

```typescript
@agent()
export class CodingAgent extends BaseAgent {
  readonly repository: string;
  readonly branch: string;
  readonly readOnly: boolean;
  repoInitialized: boolean = false;

  constructor(repository: string, branch: string) {
    super();
    this.repository = repository;
    this.branch = branch;
    this.readOnly = this.phantomId() !== undefined;
    console.info(
      `[CodingAgent] Constructed: repository=${repository}, branch=${branch}, readOnly=${this.readOnly}, phantomId=${this.phantomId()}`
    );
  }

async dump(): Promise<string> {
    return Effect.runPromise(
      Effect.gen(this, function* () {
        yield* logInfo("[CodingAgent.dump] Starting dump");
        yield* this.initRepo();
        const tree = yield* this.buildTree();
        yield* logInfo(
          `[CodingAgent.dump] Dump complete, tree length=${tree.length}`,
        );
        return tree;
      }),
    );
  }
}
```

The `initRepo` and `buildTree` functions are not very exciting - just effect-ts functions wrapping the git and node:fs modules, and using 

We can try it out by calling `dump()` on `CodingAgent("https://github.com/vigoo/test-r.git", "test1")`:

```she
[2026-03-29T12:42:33.985Z] [INVOKE  ] STARTED  golem:agent/guest@1.5.0.{invoke} (06e40a0f-ccfd-4571-8614-f86ef22787eb)
[2026-03-29T12:42:33.985Z] [INFO    ] [CodingAgent.dump] Starting dump
[2026-03-29T12:42:33.986Z] [INFO    ] [initRepo] Cloning repository https://github.com/vigoo/test-r.git into /
[2026-03-29T12:43:01.700Z] [INFO    ] [initRepo] Clone completed successfully
[2026-03-29T12:43:01.700Z] [DEBUG   ] [initRepo] Listing local branches
[2026-03-29T12:43:01.701Z] [DEBUG   ] [initRepo] Local branches: ["master"]
[2026-03-29T12:43:01.701Z] [DEBUG   ] [initRepo] Listing remote branches
[2026-03-29T12:43:01.969Z] [DEBUG   ] [initRepo] Remote branches: ["HEAD","experiment","gh-pages","master","release-plz-2024-10-05T17-10-16Z","release-plz-2024-10-06T09-00-48Z","release-plz-2024-10-06T10-04-28Z","release-plz-2024-10-06T13-49-33Z","release-plz-2024-10-06T14-16-30Z","release-plz-2024-10-06T15-07-52Z","release-plz-2024-10-06T15-12-36Z","release-plz-2024-10-06T15-23-15Z","release-plz-2024-10-06T16-21-51Z","release-plz-2024-10-11T08-35-32Z","release-plz-2024-10-11T09-10-17Z","release-plz-2024-10-11T10-10-21Z","release-plz-2024-10-14T11-31-50Z","release-plz-2024-10-21T08-45-47Z","release-plz-2024-10-21T08-46-34Z","release-plz-2024-10-21T13-29-32Z","release-plz-2024-10-27T13-18-39Z","release-plz-2024-12-29T10-03-43Z","release-plz-2024-12-29T11-06-51Z","release-plz-2024-12-29T12-13-17Z","release-plz-2024-12-29T13-17-50Z","release-plz-2025-01-30T14-13-36Z","release-plz-2025-04-05T11-48-31Z","release-plz-2025-05-14T18-08-55Z","release-plz-2025-05-14T19-47-48Z","release-plz-2025-05-31T11-07-46Z","release-plz-2025-05-31T17-56-08Z","release-plz-2025-06-01T20-31-20Z","release-plz-2025-06-02T07-12-42Z","release-plz-2025-08-27T15-56-32Z","release-plz-2026-02-25T11-24-02Z","release-plz-2026-02-25T12-10-01Z","release-plz-2026-02-25T12-23-41Z","release-plz-2026-02-25T13-29-14Z","release-plz-2026-02-25T13-31-11Z","release-plz-2026-02-25T13-54-34Z","release-plz-2026-02-25T14-17-43Z","release-plz-2026-03-02T15-30-44Z"]
[2026-03-29T12:43:01.969Z] [INFO    ] [initRepo] Branch 'test1' does not exist, creating it
[2026-03-29T12:43:01.979Z] [INFO    ] [initRepo] Created branch 'test1', checking out
[2026-03-29T12:43:04.395Z] [INFO    ] [initRepo] Checked out new branch 'test1'
[2026-03-29T12:43:04.395Z] [INFO    ] [initRepo] Repository initialization complete
[2026-03-29T12:43:04.395Z] [INFO    ] [buildTree] Building file tree
[2026-03-29T12:43:04.395Z] [DEBUG   ] [listFilesRecursive] Reading directory: /
[2026-03-29T12:43:04.577Z] [DEBUG   ] [listFilesRecursive] Found 19 entries in /
[2026-03-29T12:43:04.577Z] [DEBUG   ] [listFilesRecursive] Skipping .git directory
...

```

So cloning the repository works! The next thing we should add is an agent method that sends a **user prompt** to the LLM. Here we will start using the `@effect/ai` library to communicate with the AI. As I wrote earlier, we will store sessions simply in the agent's memory. Golem is durable so we don't have to worry about loosing anything.

So let's add a `Thread` class that is going to be responsible for a single AI thread and remembering its full context: 

```typescript
const SYSTEM_PROMPT = "You are a helpful coding assistant.";

type Message = { role: "user" | "assistant"; content: string };

export class Thread {
  readonly id: string;
  messages: Message[] = [];
  private chat: Chat.Service | undefined;

  constructor(id: string) {
    this.id = id;
  }

  private initSession() {
    return Effect.gen(this, function* () {
      if (this.chat) {
        return;
      }

      this.chat = yield* Chat.fromPrompt([
        {
          role: "system",
          content: SYSTEM_PROMPT,
        },
      ]);
    });
  }

  send(
    prompt: string,
  ): Effect.Effect<string, unknown, LanguageModel.LanguageModel> {
    return Effect.gen(this, function* () {
      yield* this.initSession();

      this.messages.push({ role: "user", content: prompt });

      const response = yield* this.chat!.generateText({ prompt });
      const text = response.text;
      this.messages.push({ role: "assistant", content: text });

      return text;
    });
  }
}
```

Note: in `@effect/ai` the `Chat` object itself remembers the session so there is no need to store it outside for ourselves. We still do it in the `messages` field, but it's not fed back to the chat session. It's just our history that will be easy to tweak and made queryable for our text user interface.

In our `CodingAgent` class we add a map of threads, and expose a new agent method:

```typescript
export class CodingAgent extends BaseAgent {  
  // ...
  threads: Map<string, Thread> = new Map();
  activeThreadId: string;

  constructor(repository: string, branch: string, config: Config<CodingAgentConfig>) {
    // ...
    const threadId = crypto.randomUUID();
    const thread = new Thread(threadId);
    this.threads.set(threadId, thread);
    this.activeThreadId = threadId;
  }
  // ...
```

Notice the new `config` parameter to our agent! It is a special parameter with the `Config<>` type, so it is NOT participating in our agent's identity. We can still refer to an agent by only the repository and branch names, but it uses Golem's underlying configuration engine to access type-safe configuration that we have to provide deploy-time. 

For now, we only require an OpenAI API key:

```typescript
type CodingAgentConfig = {
  openaiApiKey: Secret<string>;
};
```

and use it in our `sendPrompt` method:

```typescript
  async sendPrompt(prompt: string): Promise<string> {
    return Effect.runPromise(
      Effect.gen(this, function* () {
        yield* initRepo(this);

        const thread = this.threads.get(this.activeThreadId);
        if (!thread) {
          return yield* new ThreadNotFound({ threadId: this.activeThreadId });
        }
        const apiKey = this.config.value.openaiApiKey.get();
        const response = yield* thread.send(prompt).pipe(
          Effect.provide(this.makeModelLayer(apiKey))
        );
        return response;
      }),
    );
  }
```

The `makeModelLayer` just constructs the necessary effect-ai layer for running our effect:

```typescript
  private makeModelLayer(apiKey: string) {
    return OpenAiLanguageModel.model("gpt-5.4").pipe(
      Layer.provide(
        OpenAiClient.layer({
          apiKey: Redacted.make(apiKey),
        })
      ),
      Layer.provide(FetchHttpClient.layer)
    );
  }
```

Note that even though our _configuration_ is injected through the constructor, **secrets** are dynamic - they can be updated while your agent is running, and the `openaiApiKey.get()` call will always return the latest value.

We can set default values for our secrets in the application's manifest file:

```yaml
secretDefaults:
  local:
    - path: ["openaiApiKey"]
      value: "{{ OPENAI_API_KEY }}"
```

Let's try this out with our REPL:

```shell
$ golem repl
>
> Available agent client types:
>   CodingAgent.get(repository: string, branch: string)
>     dump: () => string
>     sendPrompt: (prompt: string) => string
>
> To see this message again, use the `.agent-type-info` command!
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
golem-ts-repl[gca-agents][local]> const testr = await CodingAgent.get("https://github.com/vigoo/test-r.git", "test1")
golem-ts-repl[gca-agents][local]> testr.sendPrompt("Who are you?")
> awaiting Promise<string>
'I’m a coding assistant here to help with your programming questions and provide guidance on technical topics. How can I assist you today?'
```

### Our first tools

Now that we have the source code and the AI connection set up, we have to add our first **tools** for our LLM so it can reach out and read and manipulate the source files.

We are going to add the following tools in this step:

- **List files** with optional starting directory and simple filtering
- **Read file** with optional start/end line numbers
- **Write file** creating/replacing a file's contents completely
- **Replace in file** to replace a source string with a destination string, optionally constrained by line numbers

Note that we don't have to worry about the write/replace tools to do anything dangerous - we are operating in our agent's sandbox.

We use `@effect/ai`'s tool definition mechanism to define these. For example, let's see how the **read file tool** looks like:

```typescript
const ReadFile = Tool.make("ReadFile", {
  description:
    "Read the contents of a file. Optionally specify 1-indexed start/end line numbers " +
    "to read a slice of the file.",
  parameters: {
    path: Schema.String,
    startLine: Schema.optional(Schema.Number),
    endLine: Schema.optional(Schema.Number),
  },
  success: Schema.String,
  failure: Schema.Struct({ message: Schema.String }),
  failureMode: "return" as const,
}).annotate(Tool.Readonly, true);

// ...

export const CodingToolkit = Toolkit.make(ListFiles, ReadFile, WriteFile, ReplaceInFile);
export const CodingToolkitLayer = CodingToolkit.toLayer({
  // ...
  ReadFile: (params) =>
    Effect.gen(function* () {
      yield* logDebug(
        `[Tool:ReadFile] path=${params.path}, startLine=${params.startLine}, endLine=${params.endLine}`,
      );
      const content = yield* Effect.tryPromise({
        try: () => fsPromises.readFile(params.path, "utf8"),
        catch: (e) => ({ message: String(e) }),
      });
      const result =
        params.startLine !== null || params.endLine !== null
          ? (() => {
              const lines = content.split("\n");
              const start = (params.startLine ?? 1) - 1;
              const end = params.endLine ?? lines.length;
              return lines.slice(start, end).join("\n");
            })()
          : content;
      yield* logDebug(`[Tool:ReadFile] returned ${result.length} chars`);
      return result;
    }),
  // ...
});    
```

We inject these tools for our LLM using the `toolkit` parameter:

```typescript
const response = yield* this.chat!.generateText({
        prompt,
        toolkit: CodingToolkit,
      });
```

But this is not enough. When the LLM returns with tool call requests, it is our responsibility to execute the tools and loop:

```typescript
      const MAX_STEPS = 15;
      let currentPrompt: string | readonly any[] = prompt;

      for (let step = 0; step < MAX_STEPS; step++) {
        const response = yield* this.chat!.generateText({
          prompt: currentPrompt,
          toolkit: CodingToolkit,
        });

        if (response.text.length > 0) {
          this.messages.push({ role: "assistant", content: response.text });
          return response.text;
        }

        if (response.toolCalls.length === 0) {
          this.messages.push({ role: "assistant", content: "" });
          return "";
        }

        const toolResults = response.content.filter(
          (p) => p.type === "tool-result",
        );

        yield* logDebug(
          `[Thread:${this.id}] Tool calls executed: ${response.toolCalls.map((tc) => tc.name).join(", ")}; looping back to model`,
        );
        // History is accumulated by Chat — send empty prompt to let the model
        // see the tool results and continue.
        currentPrompt = [];
      }
```

Let's see if we can actually ask our agent to work on our branch now!

```shell
$ golem repl
golem-ts-repl[gca-agents][local]> const testr = await CodingAgent.get("https://github.com/vigoo/test-r.git", "test1")
golem-ts-repl[gca-agents][local]> testr.sendPrompt("First take a look at this repository and tell me what it is")
> awaiting Promise<string>
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
[2026-03-29T15:14:07.985Z] [INFO    ] [] [initRepo] Cloning repository https://github.com/vigoo/test-r.git into /
...
[2026-03-29T15:14:41.264Z] [INFO    ] [] [Thread:54d30d83-a43a-4a3b-80dd-382741b95189] Initializing AI session
[2026-03-29T15:14:41.268Z] [INFO    ] [] [Thread:54d30d83-a43a-4a3b-80dd-382741b95189] AI session initialized
[2026-03-29T15:14:41.268Z] [INFO    ] [] [Thread:54d30d83-a43a-4a3b-80dd-382741b95189] Sending prompt: First take a look at this repository and tell me what it is...
[2026-03-29T15:14:41.268Z] [DEBUG   ] [] [Thread:54d30d83-a43a-4a3b-80dd-382741b95189] generateText step 1/15
[2026-03-29T15:14:44.119Z] [DEBUG   ] [] [Tool:ListFiles] directory=/, filter=null
[2026-03-29T15:14:44.467Z] [DEBUG   ] [] [Tool:ListFiles] returned 104 entries
[2026-03-29T15:14:44.840Z] [DEBUG   ] [] [Thread:54d30d83-a43a-4a3b-80dd-382741b95189] Tool calls executed: ListFiles; looping back to model
[2026-03-29T15:14:44.840Z] [DEBUG   ] [] [Thread:54d30d83-a43a-4a3b-80dd-382741b95189] generateText step 2/15
[2026-03-29T15:14:46.127Z] [DEBUG   ] [] [Tool:ReadFile] path=/README.md, startLine=1, endLine=20
[2026-03-29T15:14:46.128Z] [DEBUG   ] [] [Tool:ReadFile] returned 109 chars
[2026-03-29T15:14:46.352Z] [DEBUG   ] [] [Thread:54d30d83-a43a-4a3b-80dd-382741b95189] Tool calls executed: ReadFile; looping back to model
[2026-03-29T15:14:46.352Z] [DEBUG   ] [] [Thread:54d30d83-a43a-4a3b-80dd-382741b95189] generateText step 3/15
[2026-03-29T15:14:48.094Z] [INFO    ] [] [Thread:54d30d83-a43a-4a3b-80dd-382741b95189] Got text response, length=198
[2026-03-29T15:14:48.094Z] [DEBUG   ] [] [Thread:54d30d83-a43a-4a3b-80dd-382741b95189] Response preview: This repository is for "test-r", a test framework and runner for Rust. It provides testing capabilities for Rust projects. More details can be found in its [documentation](https://test-r.vigoo.dev).
[2026-03-29T15:14:48.102Z] [INFO    ] [] [CodingAgent.sendPrompt] Got response, length=198
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
'This repository is for "test-r", a test framework and runner for Rust. It provides testing capabilities for Rust projects. More details can be found in its [documentation](https://test-r.vigoo.dev).'
```

We can see that the agent used our **ListFiles** and **ReadFile** tools to take a look at the repository, and gave a correct answer!

Let's try another one (not showing all the debug lines now):

```shell
golem-ts-repl[gca-agents][local]> testr.sendPrompt("What dependencies are in the cargo file?")
'Here are the dependencies for the main components of this project:\n' +
  '\n' +
  '### `test-r-macro`\n' +
  '- **test-r-core**: Local path dependency\n' +
  '- **darling**: "0.21.3"\n' +
  '- **humantime**: "2.3.0"\n' +
  '- **proc-macro2**: "1"\n' +
  '- **quote**: "1"\n' +
  '- **rand**: "0.10"\n' +
  '- **syn**: "2" (with "full" features)\n' +
  '\n' +
  '### `test-r-core`\n' +
  '- **anyhow**: "1" (optional)\n' +
  '- **anstream**: "0.6"\n' +
  '- **anstyle**: "1"\n' +
  '- **anstyle-query**: "1.1.1"\n' +
  '- **anstyle-wincon**: "3.0.4"\n' +
  '- **desert_rust**: "0.1.7"\n' +
  '- **clap**: "4.5" (with "derive" features)\n' +
  '- **ctrf-rs**: "0.1.0"\n' +
  '- **escape8259**: "0.5"\n' +
  '- **futures**: "0.3"\n' +
  '- **interprocess**: "2.4"\n' +
  '- **parking_lot**: "0.12" (with "arc_lock", "send_guard" features)\n' +
  '- **quick-xml**: "0.38"\n' +
  '- **rand**: "0.10"\n' +
  '- **serde_json**: "1.0.149"\n' +
  '- **tokio**: "1" (with "rt-multi-thread", "process", "io-std" features, optional)\n' +
  '- **topological-sort**: "0.2"\n' +
  '- **uuid**: "1.21" (with "v4" features)\n' +
  '\n' +
  '### `test-r`\n' +
  '- **test-r-core**: Local path dependency (with default-features = false)\n' +
  '- **test-r-macro**: Local path dependency\n' +
  '- **ctor**: "0.4"\n' +
  '- **tokio**: "1" (with "rt-multi-thread" features, optional)\n' +
  '\n' +
  'These packages form the core of the test framework, providing various utilities and functionality for creating and running tests in Rust.'
```

And let's try if it is willing to edit files too:

```shell
golem-ts-repl[gca-agents][local]> testr.sendPrompt("Update the darling dependency to 0.23.0")
...
[2026-03-29T15:18:12.114Z] [DEBUG   ] [] [Tool:ReplaceInFile] 1 replacements in /test-r-macro/Cargo.toml
...
'The `darling` dependency has been updated to version "0.23.0" in the `test-r-macro` package.'
```

### Search tool

Let's add a few more tools before we switch to the host side. It's very useful for a coding agent to be able to search the web. We are going to add a tool that uses [exa](https://exa.ai) under the hood.

After registering to `exa` and getting an API key, and telling my coding agent to wire up exa as a web search tool, we get the following:

```typescript
const WebSearch = Tool.make("WebSearch", {
  description:
    "Search the web using Exa AI. Returns relevant results with titles, URLs, and text content. " +
    "Use this to find documentation, research, code examples, or any web-based information. " +
    "Optionally restrict results to specific domains or a date range.",
  parameters: {
    query: Schema.String,
    numResults: Schema.NullOr(Schema.Number),
    includeDomains: Schema.NullOr(Schema.Array(Schema.String)),
    excludeDomains: Schema.NullOr(Schema.Array(Schema.String)),
    startPublishedDate: Schema.NullOr(Schema.String),
    category: Schema.NullOr(
      Schema.Literal(
        "company",
        "research paper",
        "news",
        "pdf",
        "personal site",
      ),
    ),
  },
  success: Schema.String,
  failure: Schema.Struct({ message: Schema.String }),
  failureMode: "return" as const,
}).annotate(Tool.Readonly, true);

// ...

WebSearch: (params) =>
    Effect.gen(function* () {
      yield* logDebug(
        `[Tool:WebSearch] query=${params.query}, numResults=${params.numResults}`,
      );
      const body: Record<string, unknown> = {
        query: params.query,
        numResults: params.numResults ?? 5,
        type: "auto",
        contents: {
          text: { maxCharacters: 3000 },
        },
      };
      if (params.includeDomains) body.includeDomains = params.includeDomains;
      if (params.excludeDomains) body.excludeDomains = params.excludeDomains;
      if (params.startPublishedDate) body.startPublishedDate = params.startPublishedDate;
      if (params.category) body.category = params.category;

      const res = yield* Effect.tryPromise({
        try: () =>
          fetch("https://api.exa.ai/search", {
            method: "POST",
            headers: {
              "Content-Type": "application/json",
              "x-api-key": exaApiKey,
            },
            body: JSON.stringify(body),
          }),
        catch: (e) => ({ message: String(e) }),
      });

      if (!res.ok) {
        const text = yield* Effect.tryPromise({
          try: () => res.text(),
          catch: (e) => ({ message: String(e) }),
        });
        return yield* Effect.fail({ message: `Exa API error ${res.status}: ${text}` });
      }

      const data = yield* Effect.tryPromise({
        try: () =>
          res.json() as Promise<{
            results: Array<{
              title?: string;
              url: string;
              publishedDate?: string;
              text?: string;
            }>;
          }>,
        catch: (e) => ({ message: String(e) }),
      });

      const result = data.results
        .map(
          (r) =>
            `### ${r.title ?? "(no title)"}\nURL: ${r.url}${r.publishedDate ? `\nPublished: ${r.publishedDate}` : ""}${r.text ? `\n\n${r.text}` : ""}`,
        )
        .join("\n\n---\n\n");

      yield* logDebug(
        `[Tool:WebSearch] returned ${result.length} chars`,
      );
      return result;
    }),
```



Note: the official `exa-js` package had some trouble on Golem (to be investigated) but the actual API is just a single POST call so we can do it by hand.

Let's see if the agent uses the new tool:

```shell
[2026-03-29T15:53:26.861Z] [INFO    ] [] [Thread:f7550e6c-d8d0-46aa-ac1a-1b1771d814b3] Sending prompt: Does any of the dependencies of this project (based on any Cargo.toml in the repo) have a newer vers...
...
[2026-03-29T15:53:38.483Z] [DEBUG   ] [] [Tool:WebSearch] query=darling latest version, numResults=1
[2026-03-29T15:53:39.794Z] [DEBUG   ] [] [Tool:WebSearch] returned 2865 chars
[2026-03-29T15:53:39.795Z] [DEBUG   ] [] [Tool:WebSearch] query=humantime latest version, numResults=1
[2026-03-29T15:53:41.099Z] [DEBUG   ] [] [Tool:WebSearch] returned 2841 chars
[2026-03-29T15:53:41.101Z] [DEBUG   ] [] [Tool:WebSearch] query=proc-macro2 latest version, numResults=1
[2026-03-29T15:53:41.990Z] [DEBUG   ] [] [Tool:WebSearch] returned 2397 chars
[2026-03-29T15:53:41.992Z] [DEBUG   ] [] [Tool:WebSearch] query=quote latest version, numResults=1
...
```

### Unix commands 

Agents can more efficiently work on the code base if they can execute standard Unix commands. As we are in our sandboxed WASM environment, we can't actually run these commands - but we can use the [shelljs library](https://github.com/shelljs/shelljs) which emulates them in pure JS.

This library implements many of the standard unix commands in pure JavaScript, and supports composing them on the code level. But we should not just expose them as separate tools to the coding agent - we want it to be able to compose them (pipe them together, etc), and to use standard shell syntax for that. We will use the [shell-quote](https://github.com/shell-quote/shell-quote) package for parsing the shell scripts passed by the LLM, and translate them to shelljs calls.

We advertise this new tool towards the AI with the following tool definition:

```typescript
const RunPipeline = Tool.make("RunPipeline", {
  description:
    "Run a shell-style pipeline. " +
    "Supported commands: cat, grep, sed, head, tail, sort, uniq, wc, find, ls, echo, " +
    "cp, mv, rm, mkdir, touch, chmod, ln, pwd, cd. " +
    "Supports pipes `|`, output redirection `>` and `>>`, quotes, and globs. " +
    "Does NOT support `;`, `&&`, `||`, subshells, or env vars. " +
    "Examples: `grep -rn \"TODO\" src/`, `find src -name \"*.ts\" | wc -l`, " +
    "`sed -i \"s/foo/bar/g\" file.ts`, `cp src/a.ts src/b.ts`, " +
    "`cat file.ts | grep import | sort > imports.txt`.",
  parameters: {
    command: Schema.String,
    cwd: Schema.NullOr(Schema.String),
  },
  success: Schema.Struct({
    stdout: Schema.String,
    stderr: Schema.String,
    exitCode: Schema.Number,
    truncated: Schema.Boolean,
  }),
  failure: Schema.Struct({ message: Schema.String }),
  failureMode: "return" as const,
});
```

The implementation itself is not that interesting to show here in details, so let's just have a summary of what it does:

- First it parses the command using `shell-quote`'s `parse` function
- Based on the parsed tokens, it defines _stages_ - each stage is a command with arguments, and is either piped to the next stage or redirected to a file
- When running a command, it has a built-in set of allowed `shelljs` commands and maps them to those - it also allows adding custom commands, and implements `wc`, `find` and `sed` like that, as shelljs either did not implement them or it was not matching our requirements
- Finally it executes the whole pipeline of stages, and constructs the tool result

Trying this out, we can see that the agent is trying to use the new tool, but runs into lot of failures, for example:

```shell
[2026-03-29T17:02:49.957Z] [DEBUG   ] [] [Tool:RunPipeline] command=find / -type f | grep -v '^/proc' | grep -v '^/sys' | grep -v '^/dev' | grep -v '^/node_modules' | grep -v '^/target' | grep -E '\.(rs|toml|md|lock)$' | xargs grep -Rni "desert[-_]rust\|desert_rust\|desert rust", cwd=/
[2026-03-29T17:02:49.958Z] [DEBUG   ] [] [Tool:RunPipeline] exitCode=2, stdout=0 chars, truncated=false
```

What I did next: asked our coding agent about what he thinks about our `RunPipeline` tool:

```shell
golem-ts-repl[gca-agents][local]> testr.sendPrompt("Can you analyse all your RunPipeline tool calls so far, and tell me what did you expect and did not work, etc? I'm a developer of this tool and looking for feedback")
```

This returned a huge report that I've just pasted to my primary coding agent working on this example, to come up with a set of action items:

```shell
Here are the action items extracted from the feedback, in priority order:

Must fix (caused real failures)

1. Support grep -r / -R (recursive grep) — Most impactful missing feature. Shelljs grep already supports this flag, so it's likely our args passing that's broken for combined flags like -Rni.
2. Support grep -E (extended regex) — Shelljs grep uses JS RegExp which already supports extended syntax, so -E just needs to be accepted (and ignored, since JS regex is already "extended").
3. Add xargs command — Natural companion to find. At minimum support find ... | xargs grep pattern.
4. Fix empty grep error message — grep:  with no diagnostic when pattern like "desert_rust\|desert-rust" fails. Need to catch regex parse errors and report them clearly.

Should fix (UX/documentation)

5. Improve tool description — Rewrite to explicitly say it's not a full shell. Mention: no loops, no ;/&&/||, no subshells, no env vars. Say "restricted pipeline executor" not "shell-style pipeline".
6. Document supported flags per command in the description — Even a brief summary like grep: -n, -i, -v, -l, -r, -c, -E.
7. Clarify control structures are unsupported — Explicitly state no while, for, if, etc.

Nice to have

8. Standardize error messages — Every failure should say: which command, why, which flag/pattern caused it. No blank error strings.
```

Let's leave the agents figuring this out and move to our next topic - we can see that our proof of concept for emulating shell commands is working.

### Read-only mode

In our design we said we want to be able to have multiple **read-only** sessions of the same repository/branch combination. Why have multiple agents for this, instead of just having multiple `Thread`s within the same agent? Because Golem agents are single-threaded and they are not allowing overlapping async invocations. This means that we cannot run two parallel threads within the same agents.

We already determined that we are going to use the phantom agent feature for this. It's actually not requiring any further work - but we should explicitly disallow making changes in the phantom agents, to make sure the LLMs will not get confused. This means reducing the available tools presented to the AI based on our agent's phantom ID.

We define a limited toolkit for read-only agents:

```typescript
export const ReadOnlyCodingToolkit = Toolkit.make(
  ListFiles,
  ReadFile,
  WebSearch,
  ReadOnlyRunPipeline,
);
```

and define an abstraction over `chat.generateText` using Effect's `Context.Tag` service pattern:

```typescript
export class ThreadAi extends Context.Tag("ThreadAi")<
  ThreadAi,
  {
    readonly generateStep: (
      chat: Chat.Service,
      prompt: Prompt.RawInput,
    ) => Effect.Effect<ThreadStep, AiError.AiError, LanguageModel.LanguageModel>;
  }
>() {}
```

Then we can change our `Thread` to use `ThreadAi` to send the messages, and we can provide the proper `ThreadAi` implementation based on the read-only flag:

```typescript
export const makeThreadAiLayer = (exaApiKey: string, readOnly: boolean) =>
  Layer.succeed(ThreadAi, {
    generateStep: readOnly
      ? (chat, prompt) =>
          chat
            .generateText({ prompt, toolkit: ReadOnlyCodingToolkit })
            .pipe(
              Effect.provide(makeReadOnlyCodingToolkitLayer(exaApiKey)),
              Effect.map(normalize),
            )
      : (chat, prompt) =>
          chat
            .generateText({ prompt, toolkit: CodingToolkit })
            .pipe(
              Effect.provide(makeCodingToolkitLayer(exaApiKey)),
              Effect.map(normalize),
            ),
  });
```

We can try this out in the Golem REPL:

```shell
$ golem repl
golem-ts-repl[gca-agents][local]> const testr = await CodingAgent.get("https://github.com/vigoo/test-r.git", "test1")
golem-ts-repl[gca-agents][local]> testr.sendPrompt("Give me a list of all the tools you have")
...
'I have these tools available in this environment:\n' +
  '\n' +
  '- `functions.ListFiles`\n' +
  '- `functions.ReadFile`\n' +
  '- `functions.WriteFile`\n' +
  '- `functions.ReplaceInFile`\n' +
  '- `functions.WebSearch`\n' +
  '- `functions.RunPipeline`\n' +
  '- `multi_tool_use.parallel`\n' +
  '\n' +
  'I can also respond directly in chat without using a tool.'
  
golem-ts-repl[gca-agents][local]> const testrRo = await CodingAgent.newPhantom("https://github.com/vigoo/test-r.git", "test1")
golem-ts-repl[gca-agents][local]> testrRo.sendPrompt("Gie me a list of all the tools you have")
...
'Here are the tools I have available in this chat:\n' +
  '\n' +
  '- `functions.ListFiles`\n' +
  '  - List files and directories.\n' +
  '  - Can filter by substring.\n' +
  '\n' +
  '- `functions.ReadFile`\n' +
  '  - Read a file’s contents.\n' +
  '  - Can read specific line ranges.\n' +
  '\n' +
  '- `functions.WebSearch`\n' +
  '  - Search the web for documentation, articles, research, etc.\n' +
  '  - Can restrict by domain, date, and category.\n' +
  '\n' +
  '- `functions.RunPipeline`\n' +
  '  - Run a restricted read-only shell-style pipeline.\n' +
  '  - Supports commands like `find`, `grep`, `cat`, `head`, `tail`, `ls`, `sort`, `uniq`, `wc`, `echo`, `xargs`, `pwd`.\n' +
  '\n' +
  '- `multi_tool_use.parallel`\n' +
  '  - Run multiple developer tools in parallel when appropriate.\n' +
  '\n' +
  'Also, per your environment, I’m in read-only mode on the checked-out repo at `/`, so I can inspect and analyze code but not modify it.'
```

We can also see that we have two separate agent instances now:

```shell
$ golem agent list
+--------------------+-------------------------------+-----------+--------+-------------|
| Component name     | Agent name                    | Component | Status | Pending     |
|                    |                               | revision  |        | invocations |
+--------------------+-------------------------------+-----------+--------+-------------|
| gca-agents:ts-main | CodingAgent("https://         |         0 |   Idle |           0 |
|                    | github.com/vigoo/test-r.git", |           |        |             |
|                    | "test1")[1e0d3e2b-b20c-4cdc-  |           |        |             |
|                    | b1be-4d8ca1d22a72]            |           |        |             |
+--------------------+-------------------------------+-----------+--------+-------------+
| gca-agents:ts-main | CodingAgent("https://         |         0 |   Idle |           0 |
|                    | github.com/vigoo/test-r.git", |           |        |             |
|                    | "test1")                      |           |        |             |
+--------------------+-------------------------------+-----------+--------+-------------+
```

### Threads

The last thing we will do in our coding agent is to have a basic concept of threads. We already started this - we have an active thread ID, and a map of threads, but so far we've only created one thread. We are going to introduce a few new **agent methods** for controlling the our coding agent's threads:

#### Archiving threads

We add an `archiveThread()` method that archives the current thread - archived threads are going to be marked as such, and a summary is going to be stored for them, generated by a new LLM call.

#### Listing threads

We also expose a `listThread()` method, that returns all the threads with their ID, archive state and summary.

#### Activating a thread

There can be multiple non-archived threads, and we can switch between them. `sendPrompt` always works on the active one.

#### Handoff

We can `handoff` with a goal to archive the current thread, generate a summary and start a new thread. In the new thread's system prompt we include the parent thread's ID and the provided goal.

Adding these new methods is straightforward and does not require anything that we haven't seen before - just manipulating in-memory data, and call out to the LLM using `@effect/ai`. What is interesting is that we will also provide some new **tools** for the LLM to work on threads:

- `GetThreadInfo` tool to get a thread's message count and summary by id
- `ReadThreadMessages` to read chunks of the full conversation of the given thread

This way the agent can continue work in a new thread based on the summary of the parent thread (which is not included in the system prompt, just loaded on-demand with the tool) and it can decide to read more details from the parent thread if needed.

Let's leave this feature for now, and get back to testing it once we have our text user interface!

### Text user interface

Let's start implementing our user interface for our coding agent system! As mentioned in the introduction, we are going to use **Rust** for this. The first thing we want is to tell Golem to generate a Rust client library for our coding agent:

```yaml
bridge:
  rust:
    agents: "*"
```

Next run of `golem build` will generate our client create:

```shell
$ golem build
...
Generating bridge SDKs
  Generating Rust bridge SDK for CodingAgent to golem-temp/bridge-sdk/rust/coding-agent-client

Finished building [OK]
```

We can ask our (real) coding agent to generate a first version of a user interface using this bridge SDK and the `ratatui` crate:

- Accept a repo and branch parameter and a read-only flag
- If not provided, ask for it on startup
- Expose all agent methods as `/command` commands
- Everything else goes to `sendPrompt`

Setting up the client connection is straightforward and follows the same API that agent-to-agent communication and our REPL is providing:

```rust
coding_agent_client::configure(
    golem_client::bridge::GolemServer::Local,
    "gca-agents",
    "local",
);

let client = if cli.readonly {
    CodingAgent::new_phantom(repo.clone(), branch.clone()).await?
} else {
    CodingAgent::get(repo.clone(), branch.clone()).await?
};
```

After a few short iterations, we have something like this:



### Log streaming

Note that our coding agent interface is **non-streaming** so we cannot see the agent's progress while waiting for the final answer to our prompt. With the current version of Golem, we cannot really make the agent methods streaming, but we can do a few things:

- In this particular project we could send messages to a local http server started by the host application - we need this http server anyway for exposing the build/test tools
- But Golem itself has a **log stream** web socket API we can use to get all the logs generated by our agent. Let's go with this choice for now.

We will connect to this web-socket stream for the whole lifetime of the coding-agent TUI, but only show the messages while waiting for an answer - and collapsing them once the answer arrived.

### Message history



### Host features as tools



## What else?

- git commands for the agents
- "live" but read-only (snapshotted) view of the agent's fs for watching changes in IDEs etc
  - Or it can be the backend of a "post-ide" app that allows you to browser the remote repo and see the diffs
- Host execution can be evolved into execution in virtual machines etc. With that it can be evolved to be a hosted service.
- Automatic tracking of context size and managing threads
- Support skills and agents.md
- Setting up host-execution rules per repository
- Future golem versions will provide web-socket connection to agents
- Note: we are using a pre-released, patched Golem 1.5 so it's not that easy to do this for yourself yet. Wait a few weeks!
- Most important: that this took just a few hours with an agent, while making fixes to golem itself, and not having the skill catalog yet
