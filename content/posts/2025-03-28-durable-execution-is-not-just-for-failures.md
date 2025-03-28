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

![](/images/2025-03-28/1.png)

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

![](/images/2025-03-28/2.png)

To see the interface of this example, let's query one using `component get`:

```nu
golem component get demo:cart0
```

![](/images/2025-03-28/3.png)

Before spawning our thousands of workers, we try out this exported interface by creating a single worker of `demo:cart0` called `test` and calling a few methods in it:

```nu
 golem worker invoke demo:cart0/test initialize-cart '"user1"'
```

![](/images/2025-03-28/4.png)

```nu
golem worker invoke demo:cart0/test add-item '{ product-id: "p1", name: "Example product", price: 1000.0, quantity: 2 }'
```

![](/images/2025-03-28/5.png)

```nu
golem worker invoke demo:cart0/test get-cart-contents
```

![](/images/2025-03-28/6.png)

For some more context, we can also check the size of the compiled WASM files (we were doing a debug build so they are relatively large) for these components:

![](/images/2025-03-28/7.png)

We can also query metadata of the created worker to get the same size information, and it also going to tell us the amount of **memory** the instance allocates on startup:

```nu
golem worker get demo:cart0/test
```

![](/images/2025-03-28/9.png)

And we can query the test worker's _oplog_ to get an idea of how much additional memory it allocated dynamically runtime:

```nu
golem worker oplog demo:cart0/test --query memory
```

![](/images/2025-03-28/8.png)

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

![](/images/2025-03-28/10.png)

Of course only some of these workers (the last accessed ones) are really in the locally running executor's memory. Whenever a worker that's not in memory is going to be accessed, it is loaded and its state is transparently restored before it gets the request. Golem is tracking the resource usage of its running components and if there is not enough memory to load the new component, an old one is going to be dropped out.

### Trying it out

To demonstrate this, we can just invoke workers randomly from the 10000 we've created:

![](/images/2025-03-28/11.png)

Thanks to the durable execution model, every one of the 10000 workers react just as if it was running.