+++
title = "Durable Execution is not just for failures"

[taxonomies]
tags = ["golem", "durable-execution"]

+++

## Introduction

When talking about [Golem](https://golem.cloud) or other **durable execution engines** the most important property we are always pointing out is that by making the application _durable_, it can automatically survive various failure scenarios. In case of a transient error, or some other external event such as updating or restarting the underlying servers durable programs can survive by seamlessly continuing their execution from the point where they were interrupted, without any visible (except for some latency, of course) effect for the application's users.

But having this core capability has many other interesting consequences. 

A durable program can be dropped out of memory any time without having to explicitly save its state or shut it down in any way - and whenever it is needed it can be automatically recovered and it continues from where it left. The application developers can rely on very simple code storing everything in memory - as it is guaranteed that the in-memory state never gets lost. 

If a **Golem worker** (a running durable program) is not performing any active job at the moment - for example it is waiting to be invoked, or waiting for some scheduled event - they automatically get dropped out of the executor's memory to make space for other workers. This means we can have an (almost arbitrary) large number of "running" workers, if they are not performing CPU intensive tasks. Sure, having to continuously recover dropped out workers is affecting latency, but still, it means we can run these large number of simultaneous, stateful programs even on a locally started Golem on a developer machine.

## Demo

### Setting it up

In this short blog post we are going to demonstrate this. We are going to start the latest version of Golem (1.2) locally, then use the CLI (and some [Nushell](https://www.nushell.sh) snippets) to build, deploy and run a large number of workers.

First we download the latest `golem` command line application [according to Golem's Quick Start pages](https://learn.golem.cloud/quickstart). With that we can start our local Golem cluster - all the core Golem services are integrated in this single `golem` binary:

```nu
golem server run
```

We are going to use the same `golem` CLI application to create, deploy and invoke Golem components.

Next we create a new *golem application*:

```nu
golem app new manyworkers rust
```

<img src="/images/2025-03-28/1.webp" alt="Golem CLI creating the manyworkers Rust application" width="1100" height="143" loading="lazy" decoding="async">

Golem comes with a set of **components templates** for all supported languages. One of these templates is a simple _shopping cart_ implementation in Rust, where each Golem worker (running instance of this component) represents a single shopping cart, keeping its contents in memory.

We are going to create **10** (identical) versions of this template, simulating that we have more than one applications running in a cluster. Even though they are going to be exactly the same to keep the post simple, from Golem's point of view it is going to be 10 different applications, compiled and deployed separately.

Let's call the `golem component new` command 10 times in the newly generated application to set this up!

```nu
0..9 | each { |x| golem component new rust/example-shopping-cart $"demo:cart($x)" }
```

This command created 10 components in our application, with names `demo:cart0` to `demo:cart9`. First let's build and deploy these components:

```nu
golem app build
golem app deploy
```

<img src="/images/2025-03-28/2.webp" alt="Golem CLI creating the demo:cart9 durable component and listing its exported shopping cart API" width="1100" height="318" loading="lazy" decoding="async">

To see the interface of this example, let's query one using `component get`:

```nu
golem component get demo:cart0
```

<img src="/images/2025-03-28/3.webp" alt="Component metadata of demo:cart0 with its WASM exports" width="1100" height="289" loading="lazy" decoding="async">

Before spawning our thousands of workers, we try out this exported interface by creating a single worker of `demo:cart0` called `test` and calling a few methods in it:

```nu
 golem worker invoke demo:cart0/test initialize-cart '"user1"'
```

<img src="/images/2025-03-28/4.webp" alt="Invoking initialize-cart on the demo:cart0 worker through the Golem CLI" width="1100" height="137" loading="lazy" decoding="async">

```nu
golem worker invoke demo:cart0/test add-item '{ product-id: "p1", name: "Example product", price: 1000.0, quantity: 2 }'
```

<img src="/images/2025-03-28/5.webp" alt="Invoking add-item on the demo:cart0 worker through the Golem CLI" width="1100" height="99" loading="lazy" decoding="async">

```nu
golem worker invoke demo:cart0/test get-cart-contents
```

<img src="/images/2025-03-28/6.webp" alt="Invoking get-cart-contents on the demo:cart0 worker, returning the stored cart" width="1100" height="105" loading="lazy" decoding="async">

For some more context, we can also check the size of the compiled WASM files (we were doing a debug build so they are relatively large) for these components:

<img src="/images/2025-03-28/7.webp" alt="Worker metadata of the demo:cart0 test worker showing status and memory usage" width="1100" height="418" loading="lazy" decoding="async">

We can also query metadata of the created worker to get the same size information, and it also going to tell us the amount of **memory** the instance allocates on startup:

```nu
golem worker get demo:cart0/test
```

<img src="/images/2025-03-28/9.webp" alt="File listing of the twelve demo cart debug WASM components, each 3.1 megabytes" width="1100" height="510" loading="lazy" decoding="async">

And we can query the test worker's _oplog_ to get an idea of how much additional memory it allocated dynamically runtime:

```nu
golem worker oplog demo:cart0/test --query memory
```

<img src="/images/2025-03-28/8.webp" alt="Invocation log of the demo:cart0 worker showing repeated durable grow memory operations" width="1100" height="329" loading="lazy" decoding="async">

### Spawning many workers

Now that we have seen how a single worker looks like, let's spawn 1000 workers of each test component. This is going to take some time as it actually **instantiates** the WASM program for each to make the initial two invocations.

```nu
mut j = 0;
loop {
    mut i = 0;
    loop {
           golem worker new $"demo:cart($i)/($j)";
           golem worker invoke $"demo:cart($i)/($j)" initialize-cart '"user1"';
           golem worker invoke $"demo:cart($i)/($j)" add-item $"{ product-id: \"p1\", name: \"Example product ($j)/($i)\", price: 1000.0, quantity: 2 }";
           
           if $i >= 9 { break; };
           $i = $i + 1;
    }
    if $j >= 999 { break; };
    $j = $j + 1;
}
```

After that, we have 10000 "running" workers (all idle, waiting for a next invocation). We can check by listing for example one of the component's workers:

```nu
golem worker list demo:cart5
```

<img src="/images/2025-03-28/10.webp" alt="Cart contents of a thousand demo cart workers listed by the Golem CLI" width="1100" height="732" loading="lazy" decoding="async">

Of course only some of these workers (the last accessed ones) are really in the locally running executor's memory. Whenever a worker that's not in memory is going to be accessed, it is loaded and its state is transparently restored before it gets the request. Golem is tracking the resource usage of its running components and if there is not enough memory to load the new component, an old one is going to be dropped out.

### Trying it out

To demonstrate this, we can just invoke workers randomly from the 10000 we've created:

<img src="/images/2025-03-28/11.webp" alt="Invoking get-cart-contents on several durable shopping cart workers in sequence" width="1100" height="383" loading="lazy" decoding="async">

Thanks to the durable execution model, every one of the 10000 workers react just as if it was running.