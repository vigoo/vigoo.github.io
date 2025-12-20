+++
title = "Agent patterns in Golem"

[taxonomies]
tags = ["typescript", "golem", "agents", "patterns"]
+++

[Golem](https://golem.cloud) is an _agent-native_ platform that provides high level of fault-tolerance and exactly-once (or in some cases, at-least once) semantics automatically without requiring to write any code for persisting and recovering state. We wrote several blog posts, demos and live coding sessions showing how this looks like. Yesterday I've [posted about writing a Golem application in Rust](https://blog.vigoo.dev/posts/rust-agents-golem14/), and a week before John de Goes had a really nice [live coding session showing writing a NoSQL database using Golem in Type Script](https://www.youtube.com/live/ovVn_fNIyJU).

In all these examples we are defining one or more **agents** that interact with each other - it's the fundamental building block of a Golem application. But what are these agents? How should we structure our application, what are some common patterns?

I'm trying to answer some of these questions in this article.

## Agents as workflows

When we first released Golem, we said you can run any application (with some restrictions, of course) on it without having to rewrite it to use anything Golem specific. With the new, agent centric approach this might seem to be no longer true - but to some extent it still is. The simplest way to map an application to agents is that every unique run of the program is an agent - we can create such a unique instance of our program, and run it - and it's going to do some _side-effects_ such as calling remote HTTP endpoints or databases.

In this setup the agent's identity is a unique identifier - for example a UUID, and the agent exposes a single callable entry point, similar how a traditional program's exposes it's single entry point in the form of a `main` function. Let's see how an agent like this looks like in Golem, using TypeScript:

```typescript
import { BaseAgent, agent,} from '@golemcloud/golem-ts-sdk';
import { validate as uuidValidate } from 'uuid';

@agent()
class BlackboxWorkflow extends BaseAgent {
    private readonly id: string;

    constructor(id: string) {
        super()
        if (!uuidValidate(id)) {
            throw new Error(`Invalid id, must be a UUID: ${id}`);
        }
        this.id = id;
    }

    async run(): Promise<void> {
        // Potentially long running workflow doing a series of steps
    }
}
```

The `run` function can do a a series of steps - call `fetch` multiple times, sleep, use third party libraries to connect to external systems, and so on, without having any Golem specific detail in it. Even an agent like this is completely **durable** in Golem. For example, if it's execution gets interrupted by a scaling event the running agent can be "moved" (interrupted in one node, and restored in another) to another node and it can continue executing without any noticable effect, except for some latency. 

### Observing a workflow's state

The above example is a **black box** - once you started a workflow like this, by creating the agent and invoking it's `run` method, you cannot really observe the workflow's inner state. You can observe its side effects - it may call external systems, write logs, etc, but there is no real way to query or control what's happening until `run` finishes.

The primary reason for this is that Golem agents are **single-threaded** and **invocations cannot overlap**. Although `run` can contain overlapping asynchronous network calls, for example, even if we would export more methods than just `run` from our agent, we would not be able to call them _during_ `run` is executing. The other calls would end up in a message queue, waiting to be processed one by one.

One very important property of **agents** is that an agent can **call** another agent; this call can be synchronous (the caller awaits a response) or just a trigger (the caller puts an invocation request in the other agent's message queue). Both of these are persistent and by that, Golem can guarantee **exactly-once semantics**. If the code to call an agent from another agent runs, you can be sure that is going to happen, and only once, no matter what happens to the execution environment.

We can use this feature to introduce simple observability to a long-running workflow like the one we defined above by defining a second agent representing the running workflow's state:

```typescript
type State = {
    tag: "not-started"
    id: string,
} | {
    tag: "in-progress",
    id: string,
    currentStep: string,
    startedAt: string
} | {
    tag: "completed",
    id: string,
    startedAt?: string,
    finishedAt: string,
    results: number[] // some domain-specific result
}

@agent()
class WorkflowState extends BaseAgent {
    private state: State;

    constructor(id: string) {
        super()
        this.state = {tag: "not-started", id};
    }

    get(): State {
      return this.state;
    }
  
    update(currentStep: string) {
        if (this.state.tag === "not-started") {
            this.state = {
              tag: "in-progress",
              id: this.state.id, currentStep, 
              startedAt: new Date().toISOString()
            };
        } else if (this.state.tag === "in-progress") {
            this.state.currentStep = currentStep;
        } else if (this.state.tag == "completed") {
            throw new Error("Cannot update completed workflow state");
        }
    }

    finished(results: number[]) {
        if (this.state.tag == "completed") {
            throw new Error("Cannot finish completed workflow state");
        } else {
            this.state = {
                tag: "completed",
                id: this.state.id,
                startedAt: this.state.tag === "in-progress" 
              		? this.state.startedAt : undefined,
                finishedAt: new Date().toISOString(),
                results
            }
        }
    }
}
```

With this, we can modify our black box agent's `run` method to report progress and completion to this other agent:

```typescript
async run(): Promise<void> {
    const state = WorkflowState.get(this.id);
   	// ...
    state.update.trigger("step 1");
    // ...
    state.update.trigger("step 2");
    // ...
    state.finished.trigger([1, 2, 3]);
}
```

The `trigger` in the agent calls means we don't want to block on these calls - we just trigger the update on the other agent, so it's very fast. 

Our `WorkflowState` agent is very different from our first one, as it is reactive. Its methods are not long running, they are just updating the agent's inner state. We can call `get` any time on it while the workflow is running, these `get` calls are going to be interleaved between the status update calls.

### Multi-step workflows

As we've seen on `WorkflowState` agents can export **multiple methods**. This suggests that instead of writing a workflow like in the first example - a single method performing all the steps sequentially, we could also expose these steps as agent methods.

This is not always what we want, and it has pros and cons:

- We may already have our code structured like this - extracting sub-steps into functions. Exposing them as agent methods is just a matter of making them public methods on the agent class
- However once we do that, we no longer have a single entry point for our workflow. We need something that orchestrates the workflow execution! This can be both an advantage and a disadvantage:
  - The external orchestrator may customize the execution flow by deciding which steps to call, etc
  - But we need to write this orchestrator (potentially an another agent) that complicates our architecture

```typescript
@agent()
class InnerWorkflow extends BaseAgent {
    private readonly id: string;
    private value: number = 0;

    constructor(id: string) {
        super()
        this.id = id;
    }

    async step1(): Promise<void> {
        // ..
    }

    async step2(): Promise<void> {
        // ..
    }

    async step3(): Promise<void> {
        // ..
    }
}

@agent()
class OuterWorkflow extends BaseAgent {
    private readonly id: string;
    private value: number = 0;

    constructor(id: string) {
        super()
        this.id = id;
    }

    async run(): Promise<void> {
        const inner  = InnerWorkflow.get(this.id);
        await inner.step1();
        await inner.step2();
        await inner.step3();
    }
}
```

We can introduce these hierarchies of agents in as many layers as we want, but the reason why would want to do so is controlling **concurrency**.

### Concurrency

Even though agent methods can be `async` and do some operations in parallel - HTTP requests, remote agent calls and so on - agents are single threaded and their exported methods cannot overlap. 

We can implement fully parallel execution with two techniques:

- Spawning child agents
- Forking agents

We have already seen a simple example of spawning child agents to achieve concurrency when we created a `WorkflowState` agent as a child of our `Workflow` agent. 

In general the pattern looks like the following:

```typescript
@agent()
class ConcurrentAgent extends BaseAgent {
    private readonly id: string;

    constructor(id: string) {
        super()
        this.id = id;
    }

    async run(): Promise<void> {
        const inputs = ["a", "b", "c"]; // example chunks we want to process in parallel
        const stepPromises = inputs.map((input, idx) =>
            Substep.get(this.id, idx).run(input));
        const results = await Promise.all(stepPromises);
        // ...
    }
}

@agent()
class Substep extends BaseAgent {
    private readonly id: string;
    private readonly substepId: number;

    constructor(id: string, substepId: number) {
        super()
        this.id = id;
        this.substepId = substepId;
    }

    async run(input: string): Promise<string> {
        // Some operation on input producing an output
        return input;
    }
}
```

This example takes every element of `inputs` and spawns a separate **child agent** to process that chunk. The `Substep` agent is responsible for performing work on one chunk - its _identity_ is no longer just the main workflow's ID, but it also contains an index. This can be useful if this number (`substepId` in the example) holds some important meaning in our problem domain (imagine it's not just an index, but a domain-specific identifier of the chunk of data it works on).

In case the identity of the substeps does not matter, just that we get a separate instance for each substep that can run in parallel, we can use the **phantom agent** feature of Golem to make it even simpler:

```typescript
@agent()
class PhantomSubstep extends BaseAgent {
    constructor() {
        super()
    }

    async run(input: string): Promise<string> {
      // ...
    }
}

// ...
const stepPromises = inputs.map(input => PhantomSubstep.newPhantom().run(input));
```

`newPhantom` always creates a new instance of the agent, even if there is no user-defined unique identity to distinguish them.

#### Results

The above example was **awaiting all results** before moving forward. This is just one of the possibilities. When using `Promise.all` to await all the agent invocations, we were using the divide and conquer strategy to delegate work to other agents running in parallel, to speed up execution. We need all the results to move forward to the next step (or completion) of our main agent.

It's also possible do a **race** instead - we wait for the first child agent to complete, and use its results, ignoring the others. This is problematic in Golem 1.4 though, because `Promise.race` does not cancel the losing promises, and Golem's current JS runtime **ensures that all promises complete** before an invocation stops. So even though we would get the winner promise as soon as possible, our method would only return when every other sub-agents finished as well. This is a temporary limitation and future Golem TypeScript SDK versions will provide a way to pass an [`AbortSignal`](https://developer.mozilla.org/en-US/docs/Web/API/AbortSignal) to the invocations. 

Until then, let's see how racing looks like in a Rust agent!

```rust
#[agent_definition]
pub trait RustRaceSubAgent {
    fn new() -> Self;
    fn run(&mut self, millis: u64) -> String;
}

struct RustRaceSubAgentImpl {}

#[agent_implementation]
impl RustRaceSubAgent for RustRaceSubAgentImpl {
    fn new() -> Self {
        Self {}
    }

    fn run(&mut self, millis: u64) -> String {
        std::thread::sleep(std::time::Duration::from_millis(millis));
        format!("slept {} millis", millis)
    }
}

#[agent_definition]
pub trait RustRaceAgent {
    fn new(name: String) -> Self;
    async fn run(&mut self);
}

struct RustRaceAgentImpl {
    _name: String,
}

#[agent_implementation]
impl RustRaceAgent for RustRaceAgentImpl {
    fn new(name: String) -> Self {
        Self {
            _name: name,
        }
    }

    async fn run(&mut self) {
        let mut a = RustRaceSubAgentClient::new_phantom();
        let mut b = RustRaceSubAgentClient::new_phantom();
        let mut c = RustRaceSubAgentClient::new_phantom();

        let f1 = a.run(1000);
        let f2 = b.run(2000);
        let f3 = c.run(10000);

        let result = (f1, f2, f3).race().await;
        println!("{result}");
    }
}
```

This works as expected - the main agent finishes in 1 second. 

What can we do in TypeScript until invocations became abortable? There is a workaround - we can use **Golem Promises** to signal completion, instead of blocking asynchronous method invocations.

#### Golem Promises

A **Golem Promise** is a cluster-level entity that can be **completed** either from an agent, or even from the outside. Completing it from the outside is our basic building block for introducing **human-in-the-loop** for agentic workflows.

Let's see how we can use promises as a workaround for the race issue in TypeScript!

```typescript
import {awaitPromise, completePromise, createPromise, PromiseId} from '@golemcloud/golem-ts-sdk';

@agent()
class RaceAgentWithPromise extends BaseAgent {
    private readonly id: string;

    constructor(id: string) {
        super()
        this.id = id;
    }

    async run(): Promise<void> {
        const promise = createPromise();
        RaceSubstepWithPromise.newPhantom(promise).run.trigger(1000);
        RaceSubstepWithPromise.newPhantom(promise).run.trigger(2000);
        RaceSubstepWithPromise.newPhantom(promise).run.trigger(10000);
        const result = await awaitPromise(promise);
        console.log(new TextDecoder().decode(result));
    }
}


@agent()
class RaceSubstepWithPromise extends BaseAgent {
    private readonly promiseId: PromiseId;

    constructor(promiseId: PromiseId) {
        super()
        this.promiseId = promiseId;
    }

    async run(millis: number): Promise<void> {
        const sleep: Promise<string> = new Promise(resolve =>
            setTimeout(() => resolve(`Slept ${millis}`), millis)
        );
        const result = await sleep;
        completePromise(this.promiseId, new TextEncoder().encode(result));
    }
}
```

Instead of returning the result as a return value from our method, we are completing a **Golem promise** with it. This way we don't need await the invocation itself on the caller side, instead we await the promise - and the first sub-agent that completes it will unblock that await.

#### Forking

Forking is another way to do work in parallel from Golem agents. It is a special way to spawn a new agent - instead of explicitly creating a new agent with an initial state, `fork()` creates a **copy** of the agent it is called in, and both agents continue running from the fork point. The new copy inherits the state of the original agent, including all the values of all the variables etc. The only distinction between the two copies is the **return value** of `fork()` - it can be used to decide what to do next.

**Golem promises** are an important part of working with forking, as in this case there is no invoked method to return values from. 

Forking can be a convenient way to parallize some work in cases where the context necessary for the child agent is big and would be hard to pass down as parameters. 

```typescript
async run(): Promise<void> {
    const inputs = [
        "a", "b", "c"
    ];

    const promises = [];

    for (const input of inputs) {
        const promise = createPromise();
        promises.push(this.processInput(promise, input));
        if (this.forked) {
            break;
        }
    }
		if (!this.forked) {
      const results = await Promise.all(promises);
      console.log(results);
    }
}

async processInput(promise: PromiseId, input: string): Promise<string> {
    switch (fork().tag) {
        case "original": {
            // awaiting the promise in the original copy
            const bytes = await awaitPromise(promise);
            return new TextDecoder().decode(bytes);
        }
        case "forked": {
            // do the actual work in the forked copy
            const processed = input + "!";
            completePromise(promise, new TextEncoder().encode(processed));
	          this.forked = true;
            return processed;
        }
    }
}
```

Note that we need to remember that we got into a forked copy to avoid forking again from the fork - as all copies are (almost) identical. This makes things easy as the forked copy has the same state as the original at the fork point, but also makes things hard by having to remember to not get back to the same code path in both instances.

## Agents as domain entities

So far we represented workflows and their subtasks as agents. We can also **model our domain using agents**! 

**Domain-driven design** as an approach is with us since more than 20 years, and many books and articles discuss how to model our application based on the domains its applied to. The entities identified can be directly mapped to Golem agents and the interaction between these entities can be done with our **agent-to-agent** communication. 

It is important that agents are **durable** by default, which can significantly simplify the implementation of these entities, so we end up with something that closely maps to our domain model.

To demonstrate this, consider a simple e-commerce example where we identify three entities: **Customer**, **Order** and **OrderItem**. Customers and orders are top-level entities directly accessible by their unique identifier: the customer e-mail address and the order ID. Each order is associated with a customer, and can have one or more items.

We said that both Customer and Order are top-level entities with unique identifiers. This maps directly to Golem agents:

```typescript
type OrderId = string;

@agent()
class Customer extends BaseAgent {
    private readonly email: string;

    constructor(email: string) {
        super();
        this.email = email;
    }

    // ...
}

@agent()
class Order extends BaseAgent {
    private readonly orderId: OrderId;

    constructor(orderId: OrderId) {
        super();
        this.orderId = orderId;
    }

    // ...
}
```

We can refer to a customer directly by its domain-specific unique identifier, for example in Golem REPL:

```
>>> let vigoo = customer("vigoo@email.address")
```

The third entity, an item associated with an Order is important from a data modelling perspective but probably not something we would  map to an individual Golem agent. It is small enough that we can just model it as a record type and associate the list of items directly with our Order by just adding a new field to it:

```typescript
type OrderItem = {
    productId: string,
    quantity: number,
    price: number
}

@agent()
class Order extends BaseAgent {
    private readonly orderId: OrderId;
    private readonly items: OrderItem[];
// ...
```

Operations on these entities are going to be **agent methods**:

```typescript
add(item: OrderItem) {
    this.items.push(item)
}

getItems(): OrderItem[] {
    return this.items;
}
```

The agents can simply call each other when needed using **agent-to-agent calls**. For example, assuming we also added a way to attach the customer's email address to an order, we could have a method in `Customer` like the following:

```typescript
async newOrder(): Promise<OrderId> {
    const newId = uuidv4();
    const order = Order.get(newId);
    await order.setCustomer(this.email);
    return newId;
}
```

The facts that agents are **durable** and that calls between agents are guaranteed to be **exactly-once** make these trivial implementations very powerful.

## Patterns

We can identify some useful patterns that can help a lot in developing agent based applications on Golem. As people will write more and more applications on this platform, we are going to identify more of these patterns. 

### Cluster level singletons

The first pattern we discuss is **cluster level singletons**. A cluster level singleton agent has exactly one instance in the whole application. In Golem an agent's identity is its constructor parameters - so if our agent does not have any constructor parameter, it can only have a single instance, and any other agent or external call referring to it will refer to the same instance.

As an example, let's assume that our `OrderId` type from the previous section is not a UUID but need to be a unique, sequential number. It's quite easy to achieve this of course if we have some kind of database in our application. But in Golem we don't need a third party database for this - we can just create a singleton agent responsible for generating new unique order IDs:

```typescript
type OrderId = number;

@agent()
class OrderIds extends BaseAgent {
    private next: OrderId = 0;

    constructor() {
        super();
    }

    nextId(): OrderId {
        return this.next++;
    }
}

@agent()
class Customer extends BaseAgent {
// ...
    async newOrder(): OrderId {
        const newId = await OrderIds.get().nextId();
        // ...
```

### Shard singletons

Having a single shared global state using **cluster singletons** can be very useful, however it can very soon become a bottleneck. One possible way to reduce this bottleneck is to not only have a single instance in the whole cluster, but define somehow a set of distinct **shards**, and have a single instance **per shard**. It is very much depending on the actual domain whether this technique can be applied or not, but in general the idea is that if every agent can calculate the **shard** it belongs to, and there is no need to share information among the shards, they can simply access the shard instance they need to. 

To demonstrate this, let's assume we want to maintain a **list of all customers** with a count of how many orders they have. As this map will have to be updated every time an order is created, we don't want to maintain it in a cluster level singleton. Instead, we associate the customers into N (=100) shards, and have a separate `Customer->OrderCount` map in each shard:

```typescript
type Shard = number;

@agent()
class ShardedCustomers extends BaseAgent {
    private readonly shard: Shard;
    private readonly customerWithOrderCount: Map<string, number> = new Map();

    constructor(shard: Shard) {
        super();
        this.shard = shard;
    }

    registerCustomer(customer: string) {
        this.customerWithOrderCount.set(customer, 0);
    }

    registerOrder(customer: string, orderId: OrderId) {
        const count = this.customerWithOrderCount.get(customer) ?? 0;
        this.customerWithOrderCount.set(customer, count + 1);
    }
}
```

We can then write a function that determines the `Shard` from a customer's identifier (an email address string):

```typescript
import md5 from "md5-ts";

function shardOfCustomer(email: string): Shard {
    const SHARDS = 100;
    const hash = md5(email);
    const hashPefixAsNumber = parseInt(hash.substring(0, 8), 16);
    return hashPefixAsNumber % SHARDS;
}
```

Using this function we can call `registerCustomer` and `registerOrder` in an asynchronous way using `trigger` on the remote agent interface:

```typescript
// in class Order:
setCustomer(customer: string) {
    this.customer = customer;
    ShardedCustomers
      .get(shardOfCustomer(customer))
      .registerOrder
      .trigger(customer, this.orderId);
}

// in class Customer:
constructor(email: string) {
    super();
    this.email = email;
    ShardedCustomers
      .get(shardOfCustomer(email))
      .registerCustomer
      .trigger(email);
}
```

By using `trigger` we guarantee that even if the shard-level singleton gets overloaded with registration messages, this does not block our Order or Customer agents.

### Agents as message queues

It's not really a pattern but this last statement also tells an important feature of Golem - every agent **has its own persistent message queue**. If every agent invocation is done using `trigger` (or `schedule` to trigger an invocation in a future point in time), an agent actually works as a persistent message queue from the senders point of view. 

The example above demonstrated this - `Order` and `Customer` were just sending _registration messages_ to a message queue, without blocking on anything. The consumer of the message queue was the `ShardedCustomers` agent itself.

These message queues are just as durable as everything else in Golem. Once the `trigger` call returned we can be sure that the invocation is in the target agent's pending invocations queue, and even if the agent gets restarted, or relocated to another node, it will always have it in its invocation queue.

A different example could be a cluster-level singleton for aggregating important domain-level events from various agents:

```typescript
type Event = // ...

@agent()
class EventLog extends BaseAgent {
    constructor() {
        super();
    }

    log(event: Event) {
        console.log(event);
    }
}

/// Log an event from anywhere
function log(event: Event) {
    EventLog.get().log.trigger(event);
}
```

Our `log` processor could do anything - just log the event in the singleton agent's log stream, or store it in memory, extract and aggregate some information, etc. Even just logging it can help with debugging distributed systems, as it is a developer-defined aggregated view of the logs important for the application's logic itself, unlike the lower level server logs of the Golem platform itself.

### Ephemeral agents

Finally let's talk about **ephemeral agents** which are so important that Golem has built-in support for them and make the use of them very convenient. Ephemeral agents are agents - they can have constructor parameters and exported methods, but they are **not durable**. For each invocation a fresh instance is created, and although Golem allows you to observe past ephemeral agent instances for debugging purposes, you cannot invoke them again. 

Calling an ephemeral agent's method is Golem's equivalent of **serverless functions**. As each invocation gets a fresh instance, we don't have to worry about the message queueing property of agents - all the invoations are going to run in parallel. This is a very good fit for writing **request handlers** at the edge of a Golem application.

As an example we are going to write an ephemeral agent with a single function that enumerates **all customers** in the system. In a real application where we have so many customers that we are managing the list of them in sharded singletons, we would not want a single function returning all of them at once, of course; but for simplicity, let's implement it anyway.

First we add a new agent method to `ShardedCustomers` to get the list of customers in that particular shard:

```typescript
getCustomers(): string[] {
    return Array.from(this.customerWithOrderCount.keys());
}
```

And then we create an **ephemeral** `RequestHandler` agent:

```typescript
@agent({mode: "ephemeral"})
class RequestHandler extends BaseAgent {
    constructor() {
        super();
    }

    async getAllConsumers(): Promise<string[]> {
        const SHARDS = 100;
        const allCustomers: string[] = [];
        for (let shard = 0; shard < SHARDS; shard++) {
            const customers = await ShardedCustomers.get(shard).getCustomers();
            allCustomers.push(...customers);
        }
        return allCustomers;
    }
}
```

This is a long running call that makes 100 remote agent calls in sequence. But it is done every time on a fresh ephemeral agent instance without affecting any potentially already running request handlers.

## Conclusion

As I demonstrated the basic building blocks of Golem - **agents** - can be used in many different ways to write applications that can run in a safe way, surviving external failure conditions, automatically providing observability and many other features with almost zero boilerplate. Some of these benefits apply even if the application is not really designed with a distributed net of agents in mind, but to use the full potential of Golem we should think about how our application can be modelled like that.

It is nothing fundamentally new - there are many publications discussing domain driven design, distributed actor systems, reactive messaging patterns and so on. These existing materials can be useful inspiration, but keep in mind that in Golem each agent is durable (persistent) by default - this provides a lot of guarantees out of the box, which would have been solved by explicit architecture in other systems.

