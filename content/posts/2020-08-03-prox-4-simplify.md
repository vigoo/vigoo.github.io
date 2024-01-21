+++
title = "prox part 4 - simplified redesign"

[taxonomies]
tags = ["prox", "scala", "redesign"]
+++

## Blog post series

- [Part 1 - type level programming](@/posts/2019-02-10-prox-1-types.md)
- [Part 2 - akka streams with cats effect](@/posts/2019-03-07-prox-2-io-akkastreams.md)
- [Part 3 - effect abstraction and ZIO](@/posts/2019-08-13-prox-3-zio.md)
- [Part 4 - simplified redesign](@/posts/2020-08-03-prox-4-simplify.md)

## Intro

In [Part 1](2019-02-10-prox-1-types.html) I described how the advanced type level programming techniques can be used to describe the execution of system processes. It was both a good playground to experiment with these and the result has been proven useful as we started to use it in more and more production systems and test environments at [Prezi](https://prezi.com).

On the other hand as I mentioned at the end of the first post, there is a tradeoff. These techniques made the original version of _prox_ very hard to maintain and improve, and the error messages library users got by small mistakes were really hard to understand.

Last December (in 2019) I redesigned the library to be simpler and easier to use by making some compromises. Let's discover how!

## A single process

We start completely from scratch and try to design the library with the same functionality but with simplicity in mind. The code snippets shown here are not necessarily the final, current state of the traits and objects of the library, but some intermediate steps so we see the thought process.

First let's focus on defining a **single process**:

```scala
trait Process {
  val command: String
  val arguments: List[String]
  val workingDirectory: Option[Path]
  val environmentVariables: Map[String, String]
  val removedEnvironmentVariables: Set[String]    
}
```

Without deciding already how it will be implemented, we know we need these information to be able to launch the process alone. And how to execute it? Let's separate it completely:

```scala
trait ProcessResult {
  val exitCode: ExitCode
}

trait ProcessRunner {
  def start(process: Process): Resource[IO, Fiber[IO, ProcessResult]]
}
```

I decided that better integration with the IO library ([cats-effect](https://typelevel.org/cats-effect/) in this case) is also a goal of the redesign, so for starter modelled the _running process_ as a cancellable fiber resulting in `ProcessResult`, where cancellation means **terminating** the process. At this stage of the redesign I worked directly with `IO` instead of the _IO typeclasses_ and later replaced it like I described in [the previous post](2019-08-13-prox-3-zio.html).

Let's see how a simple runner implementation would look like:

```scala
import java.lang.{Process => JvmProcess}

class JVMProcessRunner(implicit contextShift: ContextShift[IO]) extends ProcessRunner {
  import JVMProcessRunner._

  override def start(process: Process): Resource[IO, Fiber[IO, ProcessResult]] = {
    val builder = withEnvironmentVariables(process,
      withWorkingDirectory(process,
        new ProcessBuilder((process.command :: process.arguments).asJava)))

    val start = IO.delay(new JVMRunningProcess(builder.start())).bracketCase { runningProcess =>
      runningProcess.waitForExit()
    } {
      case (_, Completed) =>
        IO.unit
      case (_, Error(reason)) =>
        IO.raiseError(reason)
      case (runningProcess, Canceled) =>
        runningProcess.terminate() >> IO.unit
    }.start

    Resource.make(start)(_.cancel)
  }
}
```

Here `withEnvironmentVariables` and `withWorkingDirectories` are just helper functions around the JVM _process builder_. The more important part is the _cancelation_ and that we expose it as a _resource_. 

First we wrap the started JVM process in a `JVMRunningProcess` class which really just wraps some of it's operations in IO operations:

```scala
case class SimpleProcessResult(override val exitCode: ExitCode)
  extends ProcessResult

class JVMRunningProcess(val nativeProcess: JvmProcess) extends RunningProcess {
  override def isAlive: IO[Boolean] = IO.delay(nativeProcess.isAlive)
  override def kill(): IO[ProcessResult] = IO.delay(nativeProcess.destroyForcibly()) >> waitForExit()
  override def terminate(): IO[ProcessResult] = IO.delay(nativeProcess.destroy()) >> waitForExit()
  override def waitForExit(): IO[ProcessResult] =
    for {
      exitCode <- IO.delay(nativeProcess.waitFor())
    } yield SimpleProcessResult(ExitCode(exitCode))
}
```

Then we wrap the _starting of the process_ with `bracketCase`, specifying the two cases:

- On normal execution, we `waitForExit` for the process to stop and create the `ProcessResult` as the result of the bracketed IO operation. 
- In the release case, if JVM thrown an exception it is raised to the IO level
- And if it got _canceled_, we `terminate` the process

This way the IO cancelation interface gets a simple way to wait for or terminate an executed process. By calling `.start` on this bracketed IO operation we move it to a concurrent _fiber_.

Finally we wrap it in a `Resource`, so if the user code starting the process got canceled, it _releases the resource_ too that ends up _terminating_ the process, leaving no process leaks. This is something that was missing from the earlier versions of the library.

To make starting processes more convenient we can create an **extension method** on the `Process` trait:

```scala
implicit class ProcessOps(private val process: Process) extends AnyVal {
  def start(implicit runner: ProcessRunner): Resource[IO, Fiber[IO, ProcessResult]] =
    runner.start(process)
}
```

## Redirection

The next step was to implement input/output/error _redirection_. In the original _prox_ library we had two important features, both implemented with type level techniques:

- Allow redirection only once per channel
- The redirection source or target was a type class with _dependent result types_

To keep the type signatures simpler I decided to work around these by sacrificing some genericity and terseness. Let's start by defining an interface for **redirecting process output**:

```scala
trait RedirectableOutput[+P[_] <: Process[_]] {
  def connectOutput[R <: OutputRedirection, O](target: R)(implicit outputRedirectionType: OutputRedirectionType.Aux[R, O]): P[O]
  
  // ...
}
```

This is not _very_ much different than the output redirection operator in the previous _prox_ versions:

```scala
def >[F[_], To, NewOut, NewOutResult, Result <: ProcessNode[_, _, _, Redirected, _]]
    (to: To)
    (implicit
     contextOf: ContextOf.Aux[PN, F],
     target: CanBeProcessOutputTarget.Aux[F, To, NewOut, NewOutResult],
     redirectOutput: RedirectOutput.Aux[F, PN, To, NewOut, NewOutResult, Result])
```

One of the primary differences is that we don't allow arbitrary targets just by requiring a `CanBeProcessOutput` type class. Instead we can only connect the output to a value of `OutputRedirection` which is an ADT:

```scala
sealed trait OutputRedirection
case object StdOut extends OutputRedirection
case class OutputFile(path: Path, append: Boolean) extends OutputRedirection
case class OutputStream[O, +OR](pipe: Pipe[IO, Byte, O], runner: Stream[IO, O] => IO[OR], chunkSize: Int = 8192) extends OutputRedirection
```

We still need a type level calculation to extract the result type of the `OutputStream` case (which is the `OR` type parameter). This extracted by the following trait with the help of the `Aux` pattern:

```scala
trait OutputRedirectionType[R] {
  type Out
  def runner(of: R)(nativeProcess: JvmProcess, blocker: Blocker, contextShift: ContextShift[IO]): IO[Out]
}
```

The important difference from earlier versions of the library is that this remains completely an implementation detail. `OutputRedirectionType` is implemented for all three cases of the `OutputRedirection` type and `connectOutput` is not even used in the default use cases, only when implementing redirection for something custom. 

Instead the `RedirectableOutput` trait itself defines a set of operators and named function versions for redirecting to different targets. With this we loose a general-purpose, type class managed way to redirect to _anything_ but improve a lot on the usability of the library. All these functions are easily discoverable from the IDE and there would not be any weird implicit resolution errors.

Let's see some examples of these functions:

```scala
trait RedirectableOutput[+P[_] <: Process[_]] {
  // ...
  def >(sink: Pipe[IO, Byte, Unit]): P[Unit] = toSink(sink)
  def toSink(sink: Pipe[F, Byte, Unit]): P[Unit] = 
    connectOutput(OutputStream(sink, (s: Stream[F, Unit]) => s.compile.drain))
    
  def >#[O: Monoid](pipe: Pipe[F, Byte, O]): P[O] = toFoldMonoid(pipe)
  def toFoldMonoid[O: Monoid](pipe: Pipe[F, Byte, O]): P[O] =
    connectOutput(OutputStream(pipe, (s: Stream[F, O]) => s.compile.foldMonoid))
    
  def >>(path: Path): P[Unit] = appendToFile(path)
  def appendToFile(path: Path): P[Unit] =
    connectOutput(OutputFile[F](path, append = true))    
  // ...
}
```

All of them are just using the `connectOutput` function so implementations of the `RedirectableOutput` trait need to define that single function to get this capability.

Note that `connectOutput` has a return type of `P[O]` instead of being just `Process`. This is important for multiple reasons. 

First, in order to actually _execute_ the output streams, we need to store it somehow in the `Process` data type itself. For this reason we add a type parameter to the `Process` trait representing the _output type_ and store the _output stream runner function_ itself in it:

```scala
trait Process[O] {
  // ...
  val outputRedirection: OutputRedirection
  val runOutputStream: (JvmProcess, Blocker, ContextShift[IO]) => IO[O]
}
```

Note that `runOutputStream` is actually the `OutputRedirectiontype.runner` function, got from the "hidden" type level operation and stored in the process data structure. With this, the _process runner_ can be extended to pass the started JVM process to this function that sets up the redirection, and then store the result of type `O` in `ProcessResult[O]`:

```scala
override def start[O](process: Process[O], blocker: Blocker): Resource[IO, Fiber[IO, ProcessResult[O]]] = {
  // ... process builder
    
  val outputRedirect = process.outputRedirection match {
    case StdOut => ProcessBuilder.Redirect.INHERIT
    case OutputFile(path) => ProcessBuilder.Redirect.to(path.toFile)
    case OutputStream(_, _, _) => ProcessBuilder.Redirect.PIPE
  }
  builder.redirectOutput(outputRedirect)

  val startProcess = for {
    nativeProcess <- IO.delay(builder.start())
    runningOutput <- process.runOutputStream(nativeProcess, blocker, contextShift).start
  } yield new JVMRunningProcess(nativeProcess, runningOutput)  
  
  // ... bracketCase, start, Resource.make
}
```

It is also important that this `RedirectableOutput` trait is not something all process has: it is a **capability**, and only processes with unbound output should implement it. This is the new encoding of fixing the three channels of a process. Instead of having three type parameters with _phantom types_, now we have a combination of capability traits mixed with the `Process` trait, constraining what kind of redirections we can do. As this is not something unbounded and have relatively small number of cases, I chose to implement the combinations by hand, designing it in a way to minimize the redundancy in these implementation classes. This means, in total **8** classes representing the combinations of bound input, output and error. 

I will demonstrate this with a single example. The `Process` constructor now returns a type with everything unbound, represented by having all the redirection capability traits:

```scala
object Process {
  def apply(command: String, arguments: List[String] = List.empty): ProcessImpl =
    ProcessImpl(
      command,
      arguments,
      workingDirectory = None,
      environmentVariables = Map.empty,
      removedEnvironmentVariables = Set.empty,
      
      outputRedirection = StdOut,
      runOutputStream = (_, _, _) => IO.unit,
      errorRedirection = StdOut,
      runErrorStream = (_, _, _) => IO.unit,
      inputRedirection = StdIn
    )
    
  case class ProcessImpl(override val command: String,
                         override val arguments: List[String],
                         override val workingDirectory: Option[Path],
                         override val environmentVariables: Map[String, String],
                         override val removedEnvironmentVariables: Set[String],
                         override val outputRedirection: OutputRedirection[F],
                         override val runOutputStream: (java.io.InputStream, Blocker, ContextShift[F]) => F[Unit],
                         override val errorRedirection: OutputRedirection[F],
                         override val runErrorStream: (java.io.InputStream, Blocker, ContextShift[F]) => F[Unit],
                         override val inputRedirection: InputRedirection[F])
    extends Process[Unit, Unit]
      with RedirectableOutput[ProcessImplO[*]]
      with RedirectableError[ProcessImplE[*]]
      with RedirectableInput[ProcessImplI]] {
    // ...
    
    def connectOutput[R <: OutputRedirection, RO](target: R)(implicit outputRedirectionType: OutputRedirectionType.Aux[R, RO]): ProcessImplO[RO] =
      ProcessImplO(
        // ...
        target,
        outputRedirectionType.runner(target),
        // ...
      )
  }
    
  case class ProcessImplO[O](// ...
                             override val runOutputStream: (java.io.InputStream, Blocker, ContextShift[F]) => F[O],
                             // ...
                            )
    extends Process[O, Unit]
      with RedirectableError[ProcessImplOE[O, *]]
      with RedirectableInput[ProcessImplIO[O]] {    
      // ...
    }
}
```

Each implementation class only has the necessary subset of type parameters `O` and `E` (`E` is the error output type), and the `I` `O` and `E` postfixes in the class names represent which channels are _bound_. Each redirection leads to a different implementation class with less and less redirection _capabilities_. `ProcessImplIOE` is the fully bound process.

This makes all the redirection operators completely type inferable and very pleasant to use for building up concrete process definitions. And we don't loose the ability to create generic function either. We can do it by requiring redirection capabilities:

```scala
def withInput[O, E, P <: Process[O, E]](s: String)(process: Process[O, E] with RedirectableInput[P]): P = {
  val input = Stream("This is a test string").through(text.utf8Encode)
  process < input
}
```

Here we know we want to have a `Process` with the `RedirectableInput` capability. We also know that by binding the input we get a something without that trait, so we know the result is a process `P` but know nothing else about its further capabilities. This is where this solution gets a bit inconvenient, if we want to chain these wrapper functions. To help with it, the library contains _type aliases_ for the whole redirection capability chain that can be used in these functions. For example:

```scala
/** Process with unbound input, output and error streams */
type UnboundProcess = Process[Unit, Unit]
  with RedirectableInput[UnboundOEProcess]
  with RedirectableOutput[UnboundIEProcess[*]]
  with RedirectableError[UnboundIOProcess[*]]
```

## Process piping

The other major feature beside redirection that _prox_ had is **piping processes together**, meaning the first process' output gets redirected to the second process' input. Now that we have redesigned processes and redirection capabilities, we can try to implement this on top of them.

The idea is that when we construct a _process group_ from a list of `Process` instances with the necessary redirection capabilities, this construction could set up the redirection and store the modified processes instead, then running them together. And it can reuse the `RedirectableOutput` and `RedirectableInput` capabilities to bind the first/last process!

Let's again start by defining what we need for the _process group_:

```scala
trait ProcessGroup[O, E] extends ProcessLike {
  val firstProcess: Process[Stream[IO, Byte], E]
  val innerProcesses: List[Process.UnboundIProcess[Stream[IO, Byte], E]]
  val lastProcess: Process.UnboundIProcess[O, E]

  val originalProcesses: List[Process[Unit, Unit]]
}
```

`ProcessLike` is a common base trait for `Process` and `ProcessGroup`. By introducing it, we can change the `RedirectableOutput` trait's self type bounds so it works for both processes and process groups.

A valid process group always have at least **2** processes and they get pre-configured during the construction of the group so when they get started, their channels can be joined. This means the group members can be split into three groups:

- The **first process** has it's output redirected to a stream, but _running_ the stream just returns the stream itself; this way it can be connected to the next process's input
- The **inner processes** are all having their output redirected in the same way, and it is also a _requirement_ that these must have their *input channel* unbound. This is needed for the operation described above, when we plug the previous process' output into the input
- The **last process** can have its output freely redirected by the user, but it's _input_ must be unbound so the previous process can be plugged in

We also store the _original_ process values for reasons explained later.

So as we can see the piping has two stages: 

1. First we prepare the processes by setting up their output to return an un-executed stream
2. And we need a process group specific start function into the `ProcessRunner` that plugs everything together

The first step is performed by the _pipe operator_ (`|`), which is defined on `Process` via an extension method to construct group of two processes, and on `ProcessGroupImpl` to add more. For simplicity the piping operator is currently not defined on the bound process group types. So it has to be first constructed, and then the redirection set up.

Let's see the one that adds one more process to a group:

```scala
def pipeInto(other: Process.UnboundProcess,
             channel: Pipe[IO, Byte, Byte]): ProcessGroupImpl = {
  val pl1 = lastProcess.connectOutput(OutputStream(channel, (stream: Stream[IO, Byte]) => IO.pure(stream)))

  copy(
    innerProcesses = pl1 :: innerProcesses,
    lastProcess = other,
    originalProcesses = other :: originalProcesses
  )
}

def |(other: Process.UnboundProcess): ProcessGroupImpl = pipeInto(other, identity)
```

Other than moving processes around in the `innerProcesses` and `lastProcess`, we also set up the **previous last process**'s output in the way I described:

- It gets redirected to a pipe which is by default `identity`
- And it's _runner_ instead of actually running the stream, just returns the stream definition

This way we can write a process group specific start function into the _process runner_:

```scala
override def startProcessGroup[O, E](processGroup: ProcessGroup[O, E], blocker: Blocker): IO[RunningProcessGroup[O, E]] =
  for {
    first <- startProcess(processGroup.firstProcess, blocker)
    firstOutput <- first.runningOutput.join
    innerResult <- if (processGroup.innerProcesses.isEmpty) {
      IO.pure((List.empty, firstOutput))
    } else {
      val inner = processGroup.innerProcesses.reverse
      connectAndStartProcesses(inner.head, firstOutput, inner.tail, blocker, List.empty)
    }
    (inner, lastInput) = innerResult
    last <- startProcess(processGroup.lastProcess.connectInput(InputStream(lastInput, flushChunks = false)), blocker)
    runningProcesses = processGroup.originalProcesses.reverse.zip((first :: inner) :+ last).toMap
  } yield new JVMRunningProcessGroup[O, E](runningProcesses, last.runningOutput)
```

where `connectAndStartProcesses` is a recursive function that does the same as we do with the first process: 

- start it with the `startProcess` function (this is the same function we discussed in the first section, that starts `Process` values)
- then "join" the output fiber; this completes immediately as it is not really running the output stream just returning it
- we connect the _input_ of the next process to the previous process' output



One thing we did not talk about yet is getting the **results** of a process group. This is where the old implementation again used some type level techniques and returned a `RunningProcess` value with specific per-process output and error types for each member of the group, as a `HList` (or converted to a _tuple_).

By making the library a bit more dynamic we can drop this part too. What is that we really want to do with a running process group?

- **Terminating** the whole group together. Terminating just one part is something we does not support currently although it would not be hard to add.
- **Waiting** for all processes to stop
- Examining the **exit code** for each member of the group
- Redirecting the **error** channel of each process to something and getting them in the result
- Redirecting the **input** of the group's first process
- Redirecting the **output** of the group's last process, and getting it in the result

The most difficult and primary reason for the `HList` in the old version is the error redirection, as it can be done _per process_. With some restrictions we can make a reasonable implementation though.

First, we require that the processes participating in forming a _process group_ does not have their _error channel_ bound yet. Then we create a `RedirectableErrors` capability that is very similar to the existing `RedirectableError` trait, but provides an advanced interface through it's `customizedPerProcess` field:

```scala
trait RedirectableErrors[+P[_] <: ProcessGroup[_, _]] {
  lazy val customizedPerProcess: RedirectableErrors.CustomizedPerProcess[P] = // ...
}
```

where the `CustomizedPerProcess` interface contains the same redirection functions but accept a function of a `Process` as parameter.

For example:

```scala
def errorsToSink(sink: Pipe[IO, Byte, Unit]): P[Unit]
// vs
def errorsToSink(sinkFn: Process[_, _] => Pipe[IO, Byte, Unit]): P[Unit] =
```

The limitation is that for all process we need to have the same **error result type** but it still gets a lot of freedom via the advanced interface: we can tag the output with the process and split their processing further in the stream.

With this choice, we can finally define the result type of the process group too:

```scala
trait ProcessGroupResult[+O, +E] {
  val exitCodes: Map[Process[Unit, Unit], ExitCode]
  val output: O
  val errors: Map[Process[Unit, Unit], E]
}
```

The error results and the exit codes are in a map indexed by the **original process**. This is the value passed to the piping operator, the one that the user constructing the group has. That's why in the `ProcessGroup` trait we also had to store the original process values.

As the output of all the inner processes are piped to the next process, we only have to care about the last process' output.

## Conclusion

With a full redesign and making some compromises, we get a library that has a much more readable and easier to maintain code, and an API that is discoverable by the IDE and does not produce any weird error messages on misuse.

Note that in all the code snippets above I removed the _effect abstraction_ and just used `IO` to make them simpler. The real code of course can be used with any IO library such as ZIO, just like the previous versions.

