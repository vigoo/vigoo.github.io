---
title: prox part 2 - akka streams with cats effect
tags: prox scala akka effects
---

## Blog post series
- [Part 1 - type level programming](2019-02-10-prox-1-types.html)
- [Part 2 - akka streams with cats effect](2019-03-07-prox-2-io-akkastreams.html)
- [Part 3 - effect abstraction and ZIO](2019-08-13-prox-3-zio.html)

## Intro
In the previous post we have seen how [prox](https://github.com/vigoo/prox) applies advanced type level programming techniques to express executing external system processes. The input and output of these processes can be connected to **streams**. The current version of [prox](https://github.com/vigoo/prox) uses the [fs2](https://fs2.io/) library to describe these streams, and [cats-effect](https://typelevel.org/cats-effect/) as an **IO** abstraction, allowing it to separate the specification of a process pipeline from its actual execution.

In this post we will keep [cats-effect](https://typelevel.org/cats-effect/) but replace [fs2](https://fs2.io/) with the stream library of the Akka toolkit, [Akka Streams](https://doc.akka.io/docs/akka/2.5/stream/). This will be a hybrid solution, as Akka Streams is not using any kind of IO abstraction, unlike [fs2](https://fs2.io/) which is implemented on top of [cats-effect](https://typelevel.org/cats-effect/). We will experiment with implementing [prox](https://github.com/vigoo/prox) purely with the *Akka* libraries in a future post.

## Replacing fs2 with Akka Streams
We start by removing the [fs2](https://fs2.io/) dependency and adding *Akka Streams*:

```scala
- "co.fs2" %% "fs2-core" % "1.0.3",
- "co.fs2" %% "fs2-io" % "1.0.3",

+ "com.typesafe.akka" %% "akka-stream" % "2.5.20",
```

Then we have to change all the *fs2* types used in the codebase to the matching *Akka Streams* types. The following table describe these pairs:

| fs2                    | Akka Streams                       |
|------------------------|------------------------------------|
| `Stream[IO, O]`        | `Source[O, Any]`                   |
| `Pipe[IO, I, O]`       | `Flow[I, O, Any]`                  |
| `Sink[IO, O]`          | `Sink[O, Future[Done]`             |

Another small difference that requires changing a lot of our functions is the *implicit context* these streaming solutions require.

With the original implementation it used to be:
- an implicit `ContextShift[IO]` instance
- and an explicitly passed *blocking execution context* of type `ExecutionContext`

We can treat the blocking execution context as part of the implicit context for *prox* too, and could refactor the library to pass both of them wrapped together within a context object.

Let's see what we need for the *Akka Streams* based implementation!
- an implicit `ContextShift[IO]` is *still needed* because we are still using `cats-effect` as our IO abstraction
- The blocking execution context however was only used for passing it to *fs2*, so we can remove that
- And for *Akka Streams* we will need an execution context of type `ExecutionContext` and also a `Materializer`. The materializer is used by *Akka Streams* to execute blueprints of streams. The usual implementation is `ActorMaterializer` which does that by spawning actors implementing the stream graph.

So for example the `start` extension method, is modified like this:

```scala
- def start[RP](blockingExecutionContext: ExecutionContext)
               (implicit start: Start.Aux[PN, RP, _], 
                contextShift: ContextShift[IO]): IO[RP]
+ def start[RP]()
               (implicit start: Start.Aux[PN, RP, _],
                contextShift: ContextShift[IO],
                materializer: Materializer,
                executionContext: ExecutionContext): IO[RP]
```

It turns out that there is one more minor difference that needs changes in the internal type signatures.

In *Akka Streams* byte streams are represented by not streams of element type `Byte`. like in *fs2*, but streams of *chunks* called `ByteString`s. So everywhere we used `Byte` as element type, such as on the process boundaries, we now simply have to use `ByteStrings`, for example:

```scala
- def apply(from: PN1, to: PN2, via: Pipe[IO, Byte, Byte]): ResultProcess 
+ def apply(from: PN1, to: PN2, via: Flow[ByteString, ByteString, Any]): ResultProcess 
```

Another thing to notice is that *fs2* had a type parameter for passing the `IO` monad to run on. As I wrote earlier, *Akka Streams* does not depend on such abstractions, so this parameter is missing. On the other hand, it has a third type parameter which is set in the above example to `Any`. This parameter is called `Mat` and represents the type of the value the flow will materialize to. At this point we don't care about it so we set it to `Any`.

Let's take a look of the `connect` function of the `ProcessIO` trait. With *fs2* the `InputStreamingSource` is implemented like this:

```scala
class InputStreamingSource(source: Source[ByteString, Any]) extends ProcessInputSource {
    override def toRedirect: Redirect = Redirect.PIPE
    
    override def connect(systemProcess: lang.Process, blockingExecutionContext: ExecutionContext)
                        (implicit contextShift: ContextShift[IO]): Stream[IO, Byte] = {
        source.observe(
            io.writeOutputStream[IO](
                IO { systemProcess.getOutputStream },
                closeAfterUse = true,
                blockingExecutionContext = blockingExecutionContext))
    }

    override def run(stream: Stream[IO, Byte])(implicit contextShift: ContextShift[IO]): IO[Fiber[IO, Unit]] =
        Concurrent[IO].start(stream.compile.drain) 
}
```

We have a `source` stream and during the setup of the process graph, when the system process has been already created, we have to set up the redirection of this source stream to this process. This is separated to a `connect` and a `run` step:
- The `connect` step creates an *fs2 stream* that observers the source stream and sends each byte to the system process's standard input. This just **defines** this stream, and returns it as a pure functional value.
- The `run` step on the other hand has the result type `IO[Fiber[IO, Unit]]`. It **defines** the effect of starting a new thread and running the stream on it.

In the case of *fs2* we can be sure that the `source.observe` function is pure just by checking it's type signature:

```scala
def observe(p: Pipe[F, O, Unit])(implicit F: Concurrent[F]): Stream[F, O]
```

All side-effecting functions in *fs2* are defined as `IO` functions, so we simply know that this one is not among them, and that's why the `connect` was a pure, non-`IO` function in the original implementation. With *Akka Streams* we don't have any information about this encoded in the type system. We use the `source.alsoTo` function:

```scala
def alsoTo(that: Graph[SinkShape[Out], _]): Repr[Out]
```

which is actually also pure (only creating a blueprint of the graph to be executed), so we can safely replace the implementation to this in the *Akka Streams* version:

```scala
class InputStreamingSource(source: Source[ByteString, Any]) extends ProcessInputSource {
    override def toRedirect: Redirect = Redirect.PIPE

    override def connect(systemProcess: lang.Process)(implicit contextShift: ContextShift[IO]): Source[ByteString, Any] =
        source.alsoTo(fromOutputStream(() => systemProcess.getOutputStream, autoFlush = true))

    override def run(stream: Source[ByteString, Any])
                    (implicit contextShift: ContextShift[IO],
                     materializer: Materializer,
                     executionContext: ExecutionContext): IO[Fiber[IO, Unit]] = {
        Concurrent[IO].start(IO.async { finish =>
            stream.runWith(Sink.ignore).onComplete {
                case Success(Done) => finish(Right(()))
                case Failure(reason) => finish(Left(reason))
            }
        })
    }
}
```

The implementation of `run` above is a nice example of how we can integrate asynchronous operations not implemented with `cats-effect` to an `IO` based program. With `IO.async` we define how to start the asynchronous operation (in this case running the *Akka stream*) and we get a callback function, `finish` to be called when the asynchronous operation ends. The stream here *materializes* to a `Future[T]` value, so we can use it's `onComplete` function to notify the IO system about the finished stream. The `IO` value returned by `IO.async` represents the whole asynchronous operation, it returns it's final result when the callback is called, and "blocks" the program flow until it is done. This does not mean actually blocking a thread; but the next IO function will be executed only when it finished running (as it's type is `IO[A]`). That is not what we need here, so we use `Concurrent[IO].start` to put this `IO` action on a separate *fiber*. This way all streams involved in the process graph will be executing in parallel.

### Calculating the result

[prox](https://github.com/vigoo/prox) supports multiple ways to calculate a result of running a process graph:

- If the target is a `Sink`, the result type is `Unit`
- If the pipe's output is `Out` and there is a `Monoid` instance for `Out`, the stream is folded into an `Out` value
- Otherwise if the pipe's output is `Out`, the result type will be `Vector[Out]`  

These cases can be enforced by the `Drain`, `ToVector` and `Fold` wrapper classes.

Let's see how we can implement them with *Akka Streams* compared to *fs2*.

#### Drain sink
The sink version was implemented like this with *fs2*:

```scala
Concurrent[IO].start(stream.compile.drain)
```

- `.compile` gets an interface that can be used to convert the stream to a `IO[A]` value in multiple ways.
- `.drain` is one of them. It runs the stream but ignores its elements, having a result type of `IO[Unit]`.
- We want to run this concurrently with the other streams so we move it to a *fiber*

With *Akka Streams* there is one big difference. In *fs2* the sink is represented as a `Pipe[F, E, Unit]`, so we could treat it in the same way as other stream segments. In this case the `Sink` is not a `Flow`, so we do a trick to keep the interface as close to the original one as possible:

```scala
create((sink: Sink[ByteString, Future[R]]) => new OutputStreamingTarget(Flow.fromFunction(identity)) 
                                                with ProcessOutputTarget[ByteString, R] {
    override def run(stream: Source[ByteString, Any])
                    (implicit contextShift: ContextShift[IO],
                    materializer: Materializer,
                    executionContext: ExecutionContext): IO[Fiber[IO, R]] =
    Concurrent[IO].start(IO.async { complete =>
        stream.runWith(sink).onComplete {
            case Success(value) => complete(Right(value))
            case Failure(reason) => complete(Left(reason))
        }
    })
}
```

The trick is that we create the `OutputStreamingTarget` with an identity flow, and only use the `Sink` when we actually run the stream, passing it to the `runWith` function. This materializes the stream into a `Future[Done]` value, that we can tie back to our `IO` system with `IO.async` as I already described it.

#### Combine with Monoid
When the element type is a *monoid* we can fold it into a single value. *Fs2* directly supports this:

```scala
Concurrent[IO].start(stream.compile.foldMonoid)
```

*Akka Streams* does not use cats type classes, but it also has a way to *fold* the stream, so we can easily implement it using the *monoid instance*:

```scala
Concurrent[IO].start(IO.async { complete =>
    stream.runFold(monoid.empty)(monoid.combine).onComplete {
        case Success(value) => complete(Right(value))
        case Failure(reason) => complete(Left(reason))
    }
})
```

#### Vector of elements
Finally let's see the version that keeps all the stream elements in a vector as a result:

```scala
Concurrent[IO].start(stream.compile.toVector)
```

With *Akka Streams* we can do it by running the stream into a *sink* created for this, `Sink.seq`. It materializes into a `Future[Seq[T]]` value that holds all the elements
of the executed stream:

```scala
Concurrent[IO].start(IO.async { complete =>
    stream.runWith(Sink.seq).onComplete {
        case Success(value) => complete(Right(value.toVector))
        case Failure(reason) => complete(Left(reason))
    }
})
```

### Testing
At this point the only remaining thing is to modify the tests too. One of the more complex examples is the `customProcessPiping` test case. With *fs2* it takes advantage of some *text processing* pipe elements coming with the library:

```scala
val customPipe: Pipe[IO, Byte, Byte] =
    (s: Stream[IO, Byte]) => s
    .through(text.utf8Decode)
    .through(text.lines)
    .map(_.split(' ').toVector)
    .map(v => v.map(_ + " !!!").mkString(" "))
    .intersperse("\n")
    .through(text.utf8Encode)

val proc = Process("echo", List("This is a test string"))
            .via(customPipe)
            .to(Process("wc", List("-w")) > text.utf8Decode[IO])
```

There are similar tools in *Akka Streams* to express this in the `Framing` module:

```scala
 val customPipe = Framing.delimiter(
      delimiter = ByteString("\n"),
      maximumFrameLength = 10000,
      allowTruncation = true
    ).map(_.utf8String)
     .map(_.split(' ').toVector)
     .map(v => v.map(_ + " !!!").mkString(" "))
     .intersperse("\n")
     .map(ByteString.apply)

val proc = Process("echo", List("This is a test string"))
            .via(customPipe)
            .to(Process("wc", List("-w")) > utf8Decode)
```

where `utf8Decode` is a helper sink defined as:

```scala
val utf8Decode: Sink[ByteString, Future[String]] =
    Flow[ByteString]
        .reduce(_ ++ _)
        .map(_.utf8String)
        .toMat(Sink.head)(Keep.right)
```

First it concatenates the `ByteString` chunks, then simply calls `.utf8String` on the result.

## Final thoughts
We have seen that it is relatively easy to replace the stream library in [prox](https://github.com/vigoo/prox) without changing it's interface much, if we keep [cats-effect](https://typelevel.org/cats-effect/) for expressing the effectful computations. The complete working example is available on the [`akka-streams` branch](https://github.com/vigoo/prox/compare/akka-streams).

In the next post I will show how it would look like if we drop [cats-effect](https://typelevel.org/cats-effect/) and do everything with *Akka Streams*.
