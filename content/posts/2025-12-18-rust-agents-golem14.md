+++
title = "Rust agents in Golem 1.4"

[taxonomies]
tags = ["rust", "golem"]
+++

The [previous version of Golem, 1.3](https://blog.vigoo.dev/posts/golem-code-first-agents/) made a big leap from earlier versions by introducing **code-first agents**. We could now write stateful, persistent entities called agents by simply defining TypeScript classes with some annotations, while previously it required learning the WebAssembly interface definition language and using that to first define our application's public interface, then figure out how to implement that.

But in Golem 1.3 we only supported this to TypeScript - we dropped support for all languages, as we wanted to only support this new experience; with Golem 1.4, [launched on 22nd of December](https://x.com/GolemCloud/status/2000696015142228039) we have a similar new code-first developer experience for **Rust**.

In this post I'm showing how to write a small Golem application with the new Rust SDK. 

Note that even though this post is about Rust agents, everything we are going to see is possible with TypeScript agents as well, in a very similar way (with slightly even less boilerplate).

## The example

The application we are going to develop, although not being extremely useful by itself, is small enough to fit to this post, but still contains many interesting details of how writing Rust agents in Golem 1.4 feels.

Our application is going to be a graph database of *libraries* for various *programming languages*, organized into *topics*. By selecting a topic (let's say `json`) we will be able to discover libraries (Rust and JavaScript libraries) that associated with that topic - then all hits are going to be analyzed and stored. Each analyzed library is going to also add new topics, and these topics can be used to do more search for libraries, and so on.

For searching libraries for a given topic, we are going to use the Google programmable search API to look for repositories on GitHub. To analyze the hits, we are going to ask OpenAI to give a short description and set of topics based on the project's README.

The number of libraries and topics will be arbitrarily scalable, as well as the number of parallel topic discoveries (but limited by the 3rd party provider's limitations, of course).

## Implementation

In general it is a good idea to design the whole architecture of an application like this in advance, and start working on it with a good understanding of what to do. I'm not going to show the overall design at this point, because introducing the parts one by one  will make it easier to explain the concepts and decisions.

### Starting the project

The only prerequisites to implement this example are:

- Golem 1.4 (the `golem` CLI application)
- Rust toolchain with the `wasm32-wasip1` target installed
- `cargo-component 0.21.1`

See the Rust tab on [the official setup page](https://learn.golem.cloud/develop/setup) to learn how exactly set these up.

Once we have them, we can create a new application using `golem` :

```
$ golem new 
> Application name: lib-db
> Select language for the new component Rust
> Select a template for the new component: default: A simple agent implementing a counter
> Component Package Name: libdb:backend
> Add another component or create application? Create application
Created application directory: lib-db
Adding component libdb:backend
Added new app component libdb:backend
Created application lib-db
```

The application is called `lib-db`, and it consists of a single component, `libdb:backend`. Components are an organizational unit in Golem - an application can have multiple components, and each component can any number of **agents**. In this example we don't need to use multiple components. A possible reason could be to have different update/deploy strategies for different subsets of our agents. 

The `default` template we've chosen consists of a simple agent called `CounterAgent`, implementing a stateful counter identified by a name, with a single `increment` method.

We can delete that, and start implementing our own agents. All agents are going to be defined in `components-rust/libdb-backend/src` - the module structure can be anything, I prefer putting each agent in its own submodule, and the shared data types (if not many) in the root module.

### The library agent

What is an agent in Golem? A stateful, durable entity, identified by its constructor parameters, exposing methods. Agents can run in parallel, but each agent itself executes their invoked methods sequentially. They also scale horizontally as each agent is put on one executor of the whole Golem cluster, based on some internal sharing logic.

One good candidate for an agent in our example application is a **library**. A library is an entity identified by its name and programming language, and it holds state - was it already analyzed? If it was, it has some data - description, set of topics.

As the agent state is not publicly visible, we also need to expose a method to query it.

Let's see how this looks like in Rust!

```rust
use golem_rust::{agent_definition, agent_implementation};
use http::Uri;
use std::collections::HashSet;

#[agent_definition]
pub trait Library {
    fn new(reference: LibraryReference) -> Self;
    fn get_details(&self) -> Result<LibraryDetails, String>;
}

struct LibraryImpl {
    reference: LibraryReference,
    state: LibraryState
}

enum LibraryState {
    Unknown,
    Analysed {
        repository: Uri,
        description: String,
        topics: HashSet<String>,
    },
    Failed {
        message: String,
    },
}

#[agent_implementation]
impl Library for LibraryImpl {
    fn new(reference: LibraryReference) -> Self {
        Self {
            reference,
            state: LibraryState::Unknown
        }
    }
    
    fn get_details(&self) -> Result<LibraryDetails, String> {
        match &self.state {
            LibraryState::Failed { message } => Err(message.clone()),
            LibraryState::Analysed {
                description,
                topics,
                repository,
            } => Ok(LibraryDetails {
                description: description.clone(),
                name: self.reference.name.clone(),
                language: self.reference.language.clone(),
                repository: repository.clone(),
                topics: topics.iter().cloned().collect(),
            }),
            LibraryState::Unknown => Err("Library not yet analyzed".to_string()),
        }
    } 
}
```

And some common data types used in the above snippet:

```rust
use golem_rust::Schema;

#[derive(Debug, Clone, Hash, PartialEq, Eq, Schema)]
pub enum Language {
    Rust,
    JavaScript,
}

#[derive(Debug, Clone, Hash, PartialEq, Eq, Schema)]
pub struct LibraryReference {
    name: String,
    language: Language,
}

impl Display for LibraryReference {
    fn fmt(&self, f: &mut Formatter<'_>) -> std::fmt::Result {
        write!(f, "{} [{:?}]", self.name, self.language)
    }
}

#[derive(Debug, Clone, Schema)]
pub struct LibraryDetails {
    name: String,
    language: Language,
    repository: Uri,
    description: String,
    topics: HashSet<String>,
}
```

In these snippets we only have three Golem-specific details:

- Data types used anywhere in the agent's interface must derive `Schema`
- The agent must be implemented as a pair of a `trait` and an implementation, with two macros: `agent_definition` and `agent_implementation` applied 

That's all that is required - our application can be built with `golem build` and deployed with `golem deploy`, assuming we have a locally started Golem server (`golem server run`). 

Let's do that, and try it out with `golem repl`:

```
>>> let testr = library({ name: "test-r", language: rust})
()
>>> testr.get-details()
err("Library not yet analysed")
>>> let desertrs = library({ name: "desert-rust", language: rust})
()
>>> desertrs.get-details()
err("Library not yet analysed")
>>> let golem-ts-sdk = library({ name: "golem-ts-sdk", language: java-script})
()
>>> golem-ts-sdk.get-details()
err("Library not yet analysed")
>>>
```

Of course every agent is initialized with `LibraryState::Unknown` so we can't see anything interesting yet. If we get out of the REPL, and check `golem agent list`, we can see that it indeed created three different agents in our server:

```
Selected app: lib-db, env: local, server: local - builtin (http://localhost:9881)
+----------------+-----------------------------+-----------+--------+-------------+--------------------------+
| Component name | Agent name                  | Component | Status | Pending     | Created at               |
|                |                             | revision  |        | invocations |                          |
+----------------+-----------------------------+-----------+--------+-------------+--------------------------+
| libdb:backend  | library({name:"desert-      |         0 |   Idle |           0 | 2025-12-18T14:53:14.531Z |
|                | rust",language:rust})       |           |        |             |                          |
+----------------+-----------------------------+-----------+--------+-------------+--------------------------+
| libdb:backend  | log()                       |         0 |   Idle |           0 | 2025-12-18T14:52:50.858Z |
+----------------+-----------------------------+-----------+--------+-------------+--------------------------+
| libdb:backend  | library({name:"test-        |         0 |   Idle |           0 | 2025-12-18T14:52:50.731Z |
|                | r",language:rust})          |           |        |             |                          |
+----------------+-----------------------------+-----------+--------+-------------+--------------------------+
| libdb:backend  | library({name:"golem-ts-    |         0 |   Idle |           0 | 2025-12-18T14:53:38.352Z |
|                | sdk",language:java-script}) |           |        |             |                          |
+----------------+-----------------------------+-----------+--------+-------------+--------------------------+
```

One thing to notice - although we defined our data types and method names in the normal convention of Rust - pascal case for the type names, snake case for the method names and fields - when using the REPL and other Golem CLI commands, we have to use a `kebab-cased` version of everything. This is a limitation of Golem 1.4 that's going to be removed in the next version. For now, because of how it builds on WebAssembly components under the hood, we need to accept this, but at least the REPL provides auto-completion to make it easier to discover these transformed names.

### The topic agent

The second entity in our system is going to be a **topic**. Let's just define a topic as something identified by a (lowercase) string, and has two methods: one to get the known list of libraries implementing this topic, and another to start **discovering** more libraries for this topic. 

We want to keep this discovery process on-demand, otherwise we would create an exponentially growing system trying to explore the whole GitHub.

We can create another submodule and just sketch an initial version of this agent:

```rust
#[agent_definition]
pub trait Topic {
    fn new(name: String) -> Self;
    fn discover_libraries(&mut self);
    fn get_libraries(&self) -> Result<HashSet<LibraryReference>, Vec<String>>;
}

struct TopicImpl {
    name: String,
    libraries: HashSet<LibraryReference>,
    failures: Vec<String>
}

#[agent_implementation]
impl Topic for TopicImpl {
    fn new(name: String) -> Self {
        if name.to_lowercase() != name {
            panic!("Topic names must be lowercase")
        }
        
        Self {
            name,
            libraries: HashSet::new(),
            failures: Vec::new()
        }
    }
    
    fn discover_libraries(&mut self) {
        todo!();
    }
    
    fn get_libraries(&self) -> Result<HashSet<LibraryReference>, Vec<String>> {
        if self.failures.is_empty() {
            Ok(self.libraries.clone())
        } else {
            Err(self.failures.clone())
        }        
    }
}
```

With out two main entities defined, we can finally switch to implement the topic discovery and library analysis!

### Topic discovery

The `discover_libraries` method that we left unimplemented so far need to do some Google search calls to find links to libraries on GitHub, and then for each hit, spawn a **Library agent** that is going to analyze that library and in case the analysis was successful, register it to belong to our **topic**. 

At this point we could write some code in `discover_libraries` implementing this - do requests to Google, process the response, loop on paginated results, etc. But this is a slow process, and as I mentioned earlier, **agents are single-threaded and their invocations are sequential**. If we would do it this way, the topic agent would be unresponsive during the discovery process, we could not even query it's status (for example invoking  `get_libraries` on it would just be enqueued to be executed *after* the discovery method returned).

There are two ways to solve this in Golem - forking and spawning child agents. In this example we are going to define a new agent, **TopicDiscovery**, which is going to be responsible for the long-running process of searching for libraries, while the Topic agents remain responsible.

When defining a new agent, we need to think about two things: its identity (constructor parameters) and its methods. In this case we have only one really good choice for the agent identity - we could say that each **topic** can have maximum 1 **topic discovery**. To achieve this, we can make the topic discovery agent also be identified by **the topic name**. 

If we would choose something with smaller cardinality, for example we would make the **TopicDiscovery** a singleton with no constructor parameters, then we could not run searches for multiple topics in parallel. If we would just assign a random ID (Golem has a built-in feature for that called **phantom agents**) then we would be able to run multiple searches for the _same topic_ in parallel, which also would not make much sense. 

So we are going to have a 1-1 mapping, and use the topic name as our discovery agent's identity, and we are going to add a **single run method** to it. This is going to be long-running, but it does not matter because there isn't anything else to be called on this agent. 

Let's first define the "skeleton" of this agent without an actual implementation:

```rust
#[agent_definition]
pub trait TopicDiscovery {
    fn new(name: String) -> Self;
    async fn run(&self);
}

struct TopicDiscoveryImpl {
    name: String
}

impl TopicDiscoveryImpl {
    fn try_run(&self) -> anyhow::Result<Vec<(Language, SearchResult)>> {
        todo!() // A
    }
}

#[agent_implementation]
impl TopicDiscovery for TopicDiscoveryImpl {
    fn new(name: String) -> Self {
        Self {
            name
        }
    }
    
    async fn run(&self) {
        match self.try_run() {
            Ok(results) => {
                todo!() // B
            }
            Err(err) => {
                todo!() // C
            }
        }
    }
}
```

There are two new things in this snippet we haven't seen so far:

- agent methods (and also the constructor) can be `async`. Even being single-threaded, and invocations not being able to overlap, within an invocation there are async operations that can overlap, such as RPC calls, HTTP requests, and waiting for external events (using Golem promises). 
- we can easily add helper methods to our implementations - everything outside of the `agent_implementation` is an implementation detail of that agent

There are three `todo!`s in the above implementation, let's discuss them one by one.

#### Searching the web (A)

We could manually do HTTP requests to use Google's search APIs (the recommended way is using the [wstd crate's HTTP client](https://docs.rs/wstd/latest/wstd/)) but we have a better option. Golem comes with a large number of **connectors** for 3rd party providers: LLMs, embeddings, text-to-speech, speech-to-text, video generation, code snippet execution, vector databases, searching, etc. Each of these categories define a unified API for working with various third-party providers in that category.

For implementing `try_run`, we are going to use the `golem_rust::golem_ai::golem::web_search` module and as a separate step, we are going to choose Google as the selected implementation for it.

The first step is to enable these connectors in the `Cargo.toml` file, as they are disabled in the default template:

```toml
golem-rust = { version = "1.10.3", features = ["export_golem_agentic", "golem_ai"] }
```

Adding the `golem_ai` feature enables access to all the connectors defined in the [golem-ai repo](https://github.com/golemcloud/golem-ai).

Then we can use these bindings in our method implementation:

```rust
use golem_rust::golem_ai::golem::web_search::types::{SearchParams, SearchResult};
use golem_rust::golem_ai::golem::web_search::web_search::start_search;

const LANGUAGES: &[Language] = &[Language::Rust, Language::JavaScript];
let mut result = vec![];

for language in LANGUAGES {
    let search = start_search(&SearchParams {
        query: format!("{} library for {:?}", self.name.clone(), language),
        include_domains: Some(vec!["github.com".to_string()]),
        include_images: Some(false),
        // everything else is undefined below
        safe_search: None, language: None,
        region: None, max_results: None, time_range: None,
        exclude_domains: None, include_html: None, advanced_answer: None,
    })?;

    loop {
        let page = search.next_page()?;
        if page.is_empty() {
            break;
        }
        result.extend(page.into_iter().map(|r| (language.clone(), r)));
    }
}

Ok(result)
```

We perform a separate search query for each language we are interested in, and go through all pages of the results for each.

Note that the search API (and all the others in `golem-ai`) is NOT async. This is a limitation coming from being built on the current version of the WASM component model, and it is going to be lifted in the next Golem release.

This search interface is not limited to Google search - we have implementations for Brave Search, Google Custom Search, Serper.dev and Tavily AI at the moment. Before deploying our application we need to choose which provider to use, by editing the `golem.yaml` file of our component. It comes by default with commented-out sections for all these connectors. To enable Google, we need to add a `dependency` and two entries to the `env` section:

```yaml
components:
  libdb:backend:
    templates: rust
    env:
      GOOGLE_API_KEY: "{{ GOOGLE_API_KEY }}"
      GOOGLE_SEARCH_ENGINE_ID: "{{ GOOGLE_SEARCH_ENGINE_ID }}"
    dependencies:
      - type: wasm
        url: https://github.com/golemcloud/golem-ai/releases/download/v0.4.0-dev.1/golem_web_search_google-dev.wasm
```

Using the `{{ X }}` syntax for the environment variables allow the `golem` CLI tool to read them from the environment during deployment, so we don't accidentally commit our keys in our repo. See the [official Google page](https://developers.google.com/custom-search/v1/introduction) to learn how to define an API key and a search engine ID.

#### Processing results (B)

If the search was successful, we end up having a list of `SearchResult` values - these are records defined in the web-search API. In this example we are only going to use the `url` field of it, which is the search result URL.

For each result we are going to spawn a **LibraryAnalysis** agent. The idea is the same as with **Topic** vs **TopicDiscovery** - we want something that runs in the background, not affecting the actual Library, so it can be accessed freely while the analysis runs. Let's assume we identify a library analysis by the library reference (1-1 mapping between a library and its analysis agent), and we pass additional information, such as the GitHub repository our search revealed, to its **run method**:

```rust
for (language, result) in results {
  let mut library_analysis = LibraryAnalysisClient::get(LibraryReference {
    name: extract_github_repo_name(result.url.clone()),
    language,
  });
  library_analysis
    .run(Some(self.name.clone()), extract_github_repo(result.url))
    .await;    
}
```

Before talking about the more interesting parts of this snippet, let's just quickly define what `extract_github_repo_name` and `extract_github_repo` are. Our search is constrained to only give hits within https://github.com and repository links are having the format `https://github.com/<org>/<name>`. These helper functions are just extracting `name` and the root repository URL from an arbitrary search result URL (that can point to anywhere within a repo).

But more importantly, what we see here is **agent-to-agent communication**!

Every agent we define with the `#[agent_definition]` macro automatically creates a **client** type - if the agent name is `LibraryAnalysis`, the client is a type called `LibraryAnalyisClient`. Each such agent client has a `get` method, with exactly the same parameters as the agent's constructor. The semantics of this get method is "upsert" - as the constructor parameters are the identity of an agent, calling this method either returns a reference to an existing agent with the given identity, or to a new one if it had not existed before. This explains why is it called `get` and not `new`.

There are two more client constructor methods in each client (`new_phantom` and `get_phantom`) but we don't need them for this example.

The clients returned by `get` have an **async method** for each **agent method** the agent exports, with the same parameters as in the original definition. No matter if the agent method was async or not, the method on the client is always `async` - as it represents an async remote call awaiting the method's result.

So, `.await`-ing `run` in the loop means we do the analysis one by one. I did that to reduce the load on my OpenAI account which the analysis is using. We could also trigger an analysis for all libraries together, or in batches - these are standard Rust futures, so we could use crates like [futures_concurrency](https://docs.rs/futures-concurrency/latest/futures_concurrency/index.html) to manage them.

#### Search failures (C)

If the search failed, we want to report this back to the **Topic** because that's the "user-facing" representation of our topic. So let's add a new agent method to the topic agent (both its trait and its impl):

```rust
fn record_failure(&mut self, failure: String) {
    self.failures.push(failure);
}
```

and then use **agent-to-agent communication** again to call this from our `Err` branch in the topic discovery implementation:

```rust
let mut topic = TopicClient::get(self.name.clone());
topic.record_failure(err.to_string()).await;
```

### Logging

Before implementing **LibraryAnalysis**, let's take a look at logging. Now that we can spawn multiple parallel web searches running in background agents, if we would start playing with out application (which we can't at the moment, without defining the library analysis agent first), it would be very hard to observe what is happening on each agent.

In Golem each agent can emit log events - writing to the standard output is a log event, but in Rust we can also use the [log crate](https://docs.rs/log/0.4.29/log/) to emit log events in different log levels. This log stream is **per agent**. We can observe it by using for example the `golem agent stream` command:

```
golem agent stream 'library({ name: "test-r", language: rust})'
```

Invocations from the Golem REPL are also automatically streaming the log events back to the REPL. We haven't seen that before in this example because we did not log anything.

Golem does not have any built-in support for observing logs from a tree of agents currently. So if we want to see - after asking our application to discover a topic - logs from our topic discovery agents, and then from each library analysis agent that we spawned, we are in trouble.

But we can simply solve this by building our **own log aggregator** in Golem itself! As we've seen, it's very easy to call an agent from another agent. We can define a **log agent** that receives messages, and then emits them as its own log events that we can stream with Golem's CLI.

But if we would only have what we have seen so far, this would have a terrible effect on our application. The **log agent** would be a single instance processing log messages one by one, and every remote log method call would block until it processed the message.

Fortunately the **agent clients** have another variant of each agent method on their interface - they can **trigger** an agent method invocation in a non-blocking way. This is very fast and returns immediately (as soon as the invocation is enqueued in the remote agent). It is also very safe - no message is going to be lost. Golem guarantees exactly-once calling semantics between agents, and the log agent itself is also automatically durable. 

(With a very large number of agents, or large log entries of course having a single log agent can be a bottleneck - it may not be able to process the messages fast enough; we are not going to solve this problem in this post)

Let's define our log agent!

```rust
use golem_rust::bindings::wasi::logging::logging::{log, Level};

#[agent_definition]
trait Log {
    fn new() -> Self;
    fn log(&self, level: Level, sender: String, message: String)
}

struct LogImpl {}

#[agent_implementation]
impl Log for LogImpl {
    fn new() -> Self {
        Self {}
    }
    
    fn log(&self, level: Level, sender: String, message: String) {
        log(level, &sender, &message)
    }
}
```

This is a very simple agent. It has **no constructor parameters**, which means it is a **cluster-level singleton**. It has a single method, that just delegates the call to the low-level `log` function defined in the Golem Rust SDK.

To make this agent nice to use, we define a helper struct called `Logger`, which we can use in our other agents to conveniently log messages.

```rust
pub struct Logger {
    client: LogClient,
    sender: String
}

impl Logger {
    pub fn new(sender: &str) -> Self {
        Self {
            client: LogClient::get(),
            sender: sender.to_string(),
        }
    }
    
    // ...
    
    pub fn info(&self, message: impl AsRef<str>) {
      log(Level::Info, &self.sender, message.as_ref());
      self.client.trigger_log(
        Level::Info,
        self.sender.clone(),
        message.as_ref().to_string(),
       );
    }
    
    // ...
}
```

We create the remote client in the constructor, and then expose methods for each log level. In these methods we first emit the log message in our "own" agent's log stream, and then also enqueue the log message in the singleton log agent's message queue. 

We do this by calling **trigger_log** on the client, instead of **log** - this is the non-blocking method to trigger an invocation without awaiting its execution.

With this set up, we can add a `Logger` to our other agents, for example:

```rust
struct TopicDiscoveryImpl {
    name: String,
    logger: Logger,
}
```

and then use it to log messages:

```rust
for language in LANGUAGES {
  self.logger.debug(format!("Searching for libraries in {language:?}..."));
  // ...
```

When running our application we can observe all logs by running

```
golem agent stream 'log()' --logs-only
```

### Library analysis

We already seen how our **library analysis agent** will look like:

```rust
#[agent_definition]
trait LibraryAnalysis {
    fn new(reference: LibraryReference) -> Self;
    async fn run(&mut self, parent_topic: Option<String>, repo_uri: Uri);
}
```

The agent's identity is the same as the library agent's - there is a 1-1 mapping between them. The only agent method is the long-running `run` method, that gets some details (which topic initiated the analysis, and what is the GitHub repo URL). 

As mentioned earlier, we also have an LLM library with implementations for various providers: Anthropic, OpenAI, OpenRouter, Amazon Bedrock, Grok and Ollama. It works the same way as I explained with the web search - we use the library through a module of `golem_rust`, and then configure the provider and its API keys in `golem.yaml`.

The library analysis itself won't be very sophisticated - just serving example purposes. We are going to ask an LLM to:

- Read the repository's front page
- Check if it's a library of the programming language we believe it is
- If yes, write a short summary of what the library does
- Also collect a set of tags (or topics) representing what the library implements

We ask it to return this in a structured (JSON) format. If it does not, or anything else fails, we mark the library analysis as failed. 

In either way, at the end we will call something in the corresponding **LibraryAgent** to store the analysis results.

So first let's extend **LibraryAgent** with two new methods to store the results:

```rust
#[agent_definition]
pub trait Library {
// ...
  fn analysis_failed(&mut self, message: String);
  async fn analysis_succeeded(
      &mut self, 
      repository: Uri, 
      description: String, 
      topics: Vec<String>
    );
}  
```

The `analysis_failed` implementation just changes the state and logs a message:

```rust
fn analysis_failed(&mut self, message: String) {
    self.logger
        .error(format!("Library analysis failed: {message}"));

    self.state = LibraryState::Failed { message };
}
```

The `analysis_succeeded` also registers the library into the **topics** the LLM identified it belongs to! This way we continuously build our information graph. To register a library to a topic, we can add a simple `add` method to the **TopicAgent** and then trigger the invocation (to not introduce any slowdowns here):

```rust
async fn analysis_succeeded(
    &mut self,
    repository: Uri,
    description: String,
    topics: Vec<String>,
) {
    self.logger.info(format!(
        "Library analysis based on {repository} succeeded with description: {description} and topics: {topics:?}"
    ));

    for topic in &topics {
        let mut topic = TopicClient::get(topic.clone());
        topic.trigger_add(self.reference.clone());
    }

    self.state = LibraryState::Analysed {
        repository,
        description,
        topics: topics.into_iter().collect(),
    };        
}
```

With this being ready, let's go back to our **LibraryAnalysis** agent's `run` method!

We start by using Golem's LLM connector to ask a question:

```rust
let response = send(&[Event::Message(
    Message {
        role: Role::User,
        name: None,
        content: vec![
            ContentPart::Text(format!("Let's analyse the GitHub repository at {}. First check if this is a library for {:?}. If it is, then come up with a list of tags describing what this library is for, and return it as a JSON array of strings. If it is not for the given language, return an empty tag array.", repo_uri, self.reference.language)),
            ContentPart::Text("In addition to the array of tags, also return a short description of the library in a separate field of the result JSON object.".to_string()),
            ContentPart::Text("Always response with a JSON object with the following structure: { \"description\": \"short description of the library\", \"tags\": [\"tag1\", \"tag2\", ...] }".to_string()),
        ],
      }
    )],
    &Config {
        model: "gpt-3.5-turbo".to_string(),
        temperature: None,
        max_tokens: None,
        stop_sequences: None,
        tools: None,
        tool_choice: None,
        provider_options: None,
     },
);

let mut library = LibraryClient::get(self.reference.clone());
match response {
    // ...
```

The response is either `Ok` or `Err`. If it was successful, it just contains a list of `ContentPart`s. We just naively try to concatenate those and decode as our expected JSON:

```rust
#[derive(Debug, Clone, serde::Deserialize)]
struct ExpectedLlmResponse {
    description: String,
    tags: Vec<String>,
}

// ...

let raw_string_content = response
    .content
    .iter()
    .map(|c| match c {
        ContentPart::Text(s) => s.clone(),
        _ => "".to_string(),
    })
    .collect::<Vec<String>>()
    .join("");

self.logger.debug(format!("LLM response: {raw_string_content}"));

match serde_json::from_str::<ExpectedLlmResponse>(&raw_string_content) {
    // ...
```

If the `tags` in the response is empty, or anything else fails, we call `analysis_failed` through `library`, otherwise we call `analysis_succeeded` with the information gathered from the LLM's response.

At this point we can build and deploy our application, and start playing with it:

![](/images/libdb-golem-rust-1.png)

and the log stream:

![](/images/libdb-golem-rust-2.png)

### Catalog agent

The application we created so far spawns many top-level agents automatically - discovering one topic can create a lot of new topic agents, all ready to further investigate by calling `discover-libraries` on them.

To see what topics and libraries we've discovered so far, we can use the `golem agent list` command - but that's just a debug tool, not suitable for using as part of our application's API. If we want to for example build a UI on top of this app, we would need a way to enumerate all the topics we currently know about.

This can be very easily done by introducing a new **singleton agent** to just keep a catalog of all the topics and libraries in its memory. This, however, will become a bottleneck if we want to scale this application significantly. There are solutions to that, for example we could define a sharded multi-agent catalog. In this post, however, we are going to do the simple version and just define it as a singleton agent with two lists:

```rust
#[agent_definition]
trait Catalog {
    fn new() -> Self;

    fn get_libraries(&self) -> Vec<LibraryReference>;
    fn get_topics(&self) -> Vec<String>;

    fn register_library(&mut self, library: LibraryReference);
    fn register_topic(&mut self, topic: String);
}
```

The implementation is straightforward - just store the libraries and topics in two `Vec`s in the agent's internal state. We can call `register_library` from the `analysis_succeeded` method of `Library`:

```rust
let mut catalog = CatalogClient::get();
catalog.trigger_register_library(self.reference.clone());
```

And similarly, `register_topic` from the **constructor** of `Topic`:

```rust
let mut catalog = CatalogClient::get();
catalog.trigger_register_topic(name.clone());
```

## Public API

At this point we are mostly done with our application's implementation, but we can only interact with it through debug tools like the Golem REPL. We could also use Golem's [REST API to invoke agents](https://learn.golem.cloud/rest-api/worker) but that's not a very nice way for integration our application to for example a user interface.

Fortunately Golem supports **defining custom APIs** for applications. In Golem 1.4, this has to be done in the application manifest - defining routes in the `golem.yaml`, and mapping logic in a custom scripting language called [Rib](https://learn.golem.cloud/rib). 

This is something that is going to be changing in the next release (a few months from now), and we are going to be able to define these APIs fully from code, in our chosen programming language. Until then, let's see how the current method looks like!

In our component's `golem.yaml` file, there is a `httpApi` section:

```yaml
httpApi:
  definitions:
    libdb-backend-api:
      version: '0.0.1'
      routes:
        # ...
```

Here we can list endpoints, and for each endpoint include a script that can access information from the request, **call an agent** and use the agent's results to construct HTTP response.

A simple one can be an endpoint that lists _all the libraries_ by invoking the **Catalog** agent:

```yaml
        - method: GET
          path: /libdb-backend-api/libs
          binding:
            type: default
            componentName: libdb:backend
            response: |
              let agent = catalog();
              let libs = agent.get-libraries();
              { status: 200, body: { libraries: libs } }
```

The language used in these scripts is the same that we were using in the Golem REPL.

For more advanced cases, we may need to use pattern matching in the scripts. For example to get _the libraries belonging to a topic_, our agent method returns a Rust `Result` which we have to process in the script:

```yaml
		- method: GET
          path: /libdb-backend-api/topics/{name}
          binding:
            type: default
            componentName: libdb:backend
            response: |
              let name: string = request.path.name;
              let agent = topic(name);
              let res = agent.get-libraries();
              match res {
                ok(libraries) => { status: 200, body: { libraries: some(libraries), failures: none } },
                err(failures) => { status: 500, body: { libraries: none, failures: some(failures) } }
              }
```

One important trick here is that the branches of the `match` must evaluate to the same type. So we can't just use `body : { libraries: libraries }` in one branch and `body: { failures: failures }` in the other, as Rib cannot unify those two body types.

We can add more endpoints to get details of a library or trigger discovery of a topic, etc. Once we've done with all that, simply running `golem deploy` again will make these endpoints available on the chosen deployment. For locally running Golem server, that's by default is `http://lib-db.localhost:9006` for this example. 

Deployments are also configurable in the application manifest, and there can be different environments such as local, prod, etc with different properties.

Once the API is deployed we can try it out with `curl` for example:

```bas
$ curl -X GET http://lib-db.localhost:9006/libdb-backend-api/topics
{"status":200,"topics":["mp3"]}%
```

## Frontend

### "Writing" the frontend 

Now that we have a public REST API for our application, we can build a simple web application on top of it, and host it from our Golem application itself. As the frontend itself is not the focus of this post, we are going to generate it with AI and just see how we can integrate it within our application.

The first step we can do is to export an **OpenAPI definition** for our API, hoping that our AI tools will understand it better than Golem's own API definition language. Running the following command:

```
$ golem api definition open-api libdb-backend-api
Selected app: lib-db, env: local, server: local - builtin (http://localhost:9881)
Exported OpenAPI spec for libdb-backend-api to libdb-backend-api.yaml
```

Then we can ask our favorite coding agent to use this to build a frontend for us. I asked for a single HTML page with embedded scripts, with no dependencies or build steps necessary, for simplicity: [see the amp thread](https://ampcode.com/threads/T-019b313f-191c-7444-80ca-d8f46ba7fdee).

With this we have an `index.html`, and we want to host that as part of our application.

### Hosting the frontend

One thing we can do is to modify the `golem.yaml` again, and list files to be added to our **agent's file system**:

```yaml
components:
  libdb:backend:
    files:
      - sourcePath: index.html
        targetPath: /index.html
        permissions: read-only
```

With Rust, however, it is much easier to include a single HTML file by using `include_bytes!` macro. This is compile time, so we don't need to add any files to our agent's run-time file system.

We can define a new agent with the only purpose to be able to return this file:

```rust
#[agent_definition(ephemeral)]
trait Frontend {
    fn new() -> Self;
    fn index(&self) -> Vec<u8>;
}

struct FrontendImpl {}

#[agent_implementation]
impl Frontend for FrontendImpl {
    fn new() -> Self {
        Self {}
    }

    fn index(&self) -> Vec<u8> {
        let bytes = include_bytes!("../index.html");
        bytes.to_vec()
    }
}

```

This agent is **singleton** - there is only one way to return this `index.html`, we don't need multiple agents with different parameters to do so. On the other hand we already learned that agents are executing a single request at the same time, so if we would serve our `index.html` through a single agent instance, that would be a significant performance problem.

The solution for these cases in Golem is to mark the agent as **ephemeral**. In Rust we can do it in the parameter of the `agent_definition` macro, as shown above. Ephemeral agents are different from the default, **durable agents** in the following ways:

- They are faster and cheaper - their state is not persisted (but to some extent their history is still preserved in long-term storage)
- They are not durable - every invocation is starting from a fresh state, and cannot survive failures
- Invoking an ephemeral agent from an API definition (or the REPL, etc) **creates a separate agent every time**.

This last feature allows us to serve an arbitrary number of `index.html` requests simultaneously, even though our agent looks like a singleton as there is no constructor parameter to distinguish these parallel instances. Golem has a built-in feature called **phantom-id** that is appended to the identity of these agents in this case. 

### Endpoint for index.html

With this new **Frontend** agent we can add a new endpoint to our routes:

```yaml
        - method: GET
          path: /libdb-backend-api
          binding:
            type: default
            componentName: "libdb:backend"
            response: |
              let agent = frontend();
              let file = agent.index();
              {
                headers: { 
                  Content-Type: "text/html; charset=utf-8"
                },
                body: file
              }
```

Let's deploy this and try out in the browser! The page gets downloaded, but it does not work - failing with CORS errors.

### CORS

We need to add CORS Preflight endpoints to our route to make the scripts work. In the current version of Golem this is a bit inconvenient, as we need to add them one by one for each endpoint we defined, for example:

```yaml
        - method: OPTIONS
          path: /libdb-backend-api/topics/{name}
          binding:
            type: cors-preflight
```

Once we added all of them and redeployed, our frontend works as expected!

![](/images/libdb-golem-rust-3.png)

## Conclusion

I hope this post shows how much more fun it is to write applications for Golem in this new release. The important thing is to think about the problem to be solved as a set of durable agents communicating with each other. You can think of a Golem application as a distributed, persistent actor system, if you are familiar with those concepts. Once the architecture is done, it's mostly just writing the application logic, without dealing with code generators, new languages (except Rib, for now), or boilerplate to set the network up. Everything is automatically persisted, the agents remain available forever, and by scaling the Golem Cluster your application scales horizontally as well.

The example is available on [GitHub](https://github.com/vigoo/golem-example-lib-db).
