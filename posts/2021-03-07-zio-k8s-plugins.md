---
title: Writing kubectl plugins with ZIO K8s
tags: scala zio k8s

---

Originally posted [at the Ziverge blog](https://ziverge.com/blog/zio-k8s-kubectl-plugin).

Andrea Peruffo recently published [a blog post on the Lightbend blog](https://www.lightbend.com/blog/writing-kubectl-plugins-with-scala-or-java-with-fabric8-kubernetes-client-on-graalvm?utm_campaign=Oktopost-BLG+-+Writing+Kubectl+plugins+in+Java+or+Scala) about how they migrated a `kubectl` plugin from Golang to Scala using the [Fabric8](https://github.com/fabric8io/kubernetes-client) Kubernetes client and a few Scala libraries. This is a perfect use case for the [zio-k8s library](https://coralogix.github.io/zio-k8s/) announced [two weeks ago](https://coralogix.com/log-analytics-blog/the-coralogix-operator-a-tale-of-zio-and-kubernetes/), so we decided to write this post demonstrating how to implement the same example using the ZIO ecosystem.

We are going to implement the same example, originally described in the [Write a kubectl plugin in Java with JBang and fabric8](https://dev.to/ikwattro/write-a-kubectl-plugin-in-java-with-jbang-and-fabric8-566) article, using the following libraries:

- [ZIO](https://zio.dev/)
- [ZIO K8s](https://coralogix.github.io/zio-k8s/)
- [ZIO Logging](https://zio.github.io/zio-logging/)
- [clipp](https://vigoo.github.io/clipp/docs/)
- [sttp](https://sttp.softwaremill.com/en/latest/)
- [circe](https://circe.github.io/circe/)

The source code of the example [can be found here](https://github.com/zivergetech/zio-k8s-kubectl-plugin-example).

The linked blog post does a great job in explaining the benefits and difficulties of compiling to native image with GraalVM so we are not going to repeat it here. Instead, we will focus on how the implementation looks in the functional Scala world.

The example has to implement two _kubectl commands_: `version` to print its own version and `list` to list information about _all Pods of the Kubernetes cluster_ in either ASCII table, JSON or YAML format.

### CLI parameters

Let's start with defining these command line options with the [clipp](https://vigoo.github.io/clipp/docs/) library!

First, we define the data structures that describe our parameters:

```scala
sealed trait Format
object Format {
  case object Default extends Format
  case object Json extends Format
  case object Yaml extends Format
}

sealed trait Command
object Command {
  final case class ListPods(format: Format) extends Command
  case object Version extends Command
}

final case class Parameters(verbose: Boolean, command: Command)
```

When parsing the arguments (passed as an array of strings), we need to either produce a `Parameters` value or fail and print some usage information.

With `clipp`, this is done by defining a parameter parser using its parser DSL in a _for comprehension_:

```scala
val spec =
  for {
    _           <- metadata("kubectl lp")
    verbose     <- flag("Verbose logging", 'v', "verbose")
    commandName <- command("version", "list")
    command     <- 
      commandName match {
        case "version" => 
          pure(Command.Version)
        case "list"    =>
          for {
            specifiedFormat <- optional {
                                namedParameter[Format](
                                  "Output format",
                                  "default|json|yaml",
                                  'o',
                                  "output"
                                )
                              }
            format           = specifiedFormat.getOrElse(Format.Default)
          } yield Command.ListPods(format)
      }
  } yield Parameters(verbose, command)
```

As we can see, it is possible to make decisions in the parser based on the previously parsed values, so each _command_ can have a different set of arguments. In order to parse the possible _output formats_, we also implement the `ParameterParser` type class for `Format`:

```scala
implicit val parameterParser: ParameterParser[Format] = new ParameterParser[Format] {
    override def parse(value: String): Either[String, Format] =
      value.toLowerCase match {
        case "default" => Right(Format.Default)
        case "json"    => Right(Format.Json)
        case "yaml"    => Right(Format.Yaml)
        case _         => Left(s"Invalid output format '$value', use 'default', 'json' or 'yaml'")
      }

    override def example: Format = Format.Default
  }
```

This is all we need to bootstrap our command line application. The following main function parses the arguments and provides the parsed `Parameters` value to the `ZIO` program:

```scala
def run(args: List[String]): URIO[zio.ZEnv, ExitCode] = {
  val clippConfig = config.fromArgsWithUsageInfo(args, Parameters.spec)
  runWithParameters()
    .provideCustomLayer(clippConfig)
    .catchAll { _: ParserFailure => ZIO.succeed(ExitCode.failure) }
}

def runWithParameters(): ZIO[ZEnv with ClippConfig[Parameters], Nothing, ExitCode] = // ...
```

### Working with Kubernetes

In `runWithParameters`, we have everything needed to initialize the logging and Kubernetes modules and perform the actual command. Before talking about the initialization though, let's take a look at how we can list the pods!

We define a data type holding all the information we want to report about each pod:

```scala
case class PodInfo(name: String, namespace: String, status: String, message: String)
```

The task now is to fetch _all pods_ from Kubernetes and construct `PodInfo` values. In `zio-k8s` _getting a list of pods_ is defined as a **ZIO Stream**, which under the hood sends multiple HTTP requests to Kubernetes taking advantage of its _pagination_ capability. In this _stream_ each element will be a `Pod` and we can start processing them one by one as soon they arrive over the wire. This way the implementation of the `list` command can be something like this:

```scala
def run(format: Format) = 
  for {
    _ <- log.debug("Executing the list command")
    _ <- pods
            .getAll(namespace = None)
            .mapM(toModel)
            .run(reports.sink(format))
            .catchAll { k8sFailure =>
              console.putStrLnErr(s"Failed to get the list of pods: $k8sFailure")
            }
  } yield ()
```

Let's take a look at each line!

First, `log.debug` uses the _ZIO logging_ library. We are going to initialize logging in a way that these messages only appear if the `--verbose` option was enabled.

Then `pods.getAll` is the ZIO Stream provided by the _ZIO K8s_ library. Not providing a specific namespace means that we are getting pods from _all_ namespaces.

With `mapM(toModel)` we transform each `Pod` in the stream to our `PodInfo` data structure.

Finally we `run` the stream into a _sink_ that is responsible for displaying the `PodInfo` structures with the specific _output format_.

The `Pod` objects returned in the stream are simple _case classes_ containing all the information available for the given resource. Most of the fields of these case classes are _optional_ though, even though we can be sure that in our case each pod would have a name, a namespace and a status. To make working with these data structures easier within a set of expectations, they feature _getter methods_ that are ZIO functions either returning the field's value, or failing if they are not specified. With these we can implement `toModel`:

```scala
def toModel(pod: Pod): IO[K8sFailure, PodInfo] =
    for {
      metadata  <- pod.getMetadata
      name      <- metadata.getName
      namespace <- metadata.getNamespace
      status    <- pod.getStatus
      phase     <- status.getPhase
      message    = status.message.getOrElse("")
    } yield PodInfo(name, namespace, phase, message)
```

An alternative would be to just store the optional values in `PodInfo` and handle their absence in the _report sink_.

Let's talk about the _type_ of the above defined `run` function:

```scala
ZIO[Pods with Console with Logging, Nothing, Unit]
```

The ZIO _environment_ precisely specifies the modules used by our `run` function:

| Module    | Description                                                            |
|-----------|------------------------------------------------------------------------|
|`Pods`     | for accessing K8s pods                                                 |
|`Console`  | for printing _errors_ on the standard error channel with `putStrLnErr` |
|`Logging`  | for emitting some debug logs                                           |

The error type is `Nothing` because it can never fail - all errors are catched and displayed for the user within the run function.

### Initialization

Now we can see that in order to run the `list` command in `runWithParameters`, we must _provide_ `Pods` and `Logging` modules to our implementation (`Console` is part of the default environment and does not need to be provided).

These modules are described by _ZIO Layers_ which can be composed together to provide the _environment_ for running our ZIO program. In this case we need to define a _logging layer_ and a _kubernetes pods client_ layer and then compose the two for our `list` implementation.

Let's start with logging:

```scala
def configuredLogging(verbose: Boolean): ZLayer[Console with Clock, Nothing, Logging] = {
    val logLevel = if (verbose) LogLevel.Trace else LogLevel.Info
    Logging.consoleErr(logLevel) >>> initializeSlf4jBridge
  }
```

We create a simple ZIO console logger that will print lines to the standard error channel; the enabled log level is determined by the `verbose` command line argument. As this logger writes to the console and also prints timestamps, our logging layer _requires_ `Console with Clock` to be able to build a `Logging` module. Enabling the _SLF4j bridge_ guarantees that logs coming from third party libraries will also get logged through ZIO logging. In our example this means that when we enable verbose logging, our `kubectl` plugin will log the HTTP requests made by the Kubernetes library!

The second layer we must define constructs a `Pods` module:

```scala
val pods = k8sDefault >>> Pods.live)
```

By using `k8sDefault` we ask `zio-k8s` to use the _default configuration chain_, which first tries to load the `kubeconfig` and use the active _context_ stored in it. This is exactly what `kubectl` does, so it is the perfect choice when writing a `kubectl` plugin. Other variants provide more flexibility such as loading custom configuration with the [ZIO Config](https://zio.github.io/zio-config/) library. Once we have a _k8s configuration_ we just feed it to the set of resource modules we need. In this example we only need to access pods. In more complex applications this would be something like `k8sDefault >>> (Pods.live ++ Deployments.live ++ ...)`.

With both layers defined, we can now provide them to our command implementation:

```scala
runCommand(parameters.command)
  .provideCustomLayer(logging ++ pods)
```

### Output
The last thing missing is the _report sink_ that we are running the stream of pods into. We are going to define three different sinks for the three output types.

Let's start with JSON!

```scala
def sink[T: Encoder]: ZSink[Console, Nothing, T, T, Unit] =
  ZSink.foreach { (item: T) =>
    console.putStrLn(item.asJson.printWith(Printer.spaces2SortKeys))
  }
```

The JSON sink requires `Console` and then for each element `T` it converts it to JSON and pretty prints it to console. Note that this is going to be a JSON document per each line. We could easily define a different sink that collects each element and produces a single valid JSON array of them:

```scala
def arraySink[T: Encoder]: ZSink[Console, Nothing, T, T, Unit] =
    ZSink.collectAll.flatMap { (items: Chunk[T]) =>
      ZSink.fromEffect {
        console.putStrLn(Json.arr(items.map(_.asJson): _*).printWith(Printer.spaces2SortKeys))
      }
    }
```

The `T` type paramter in our example will always be `PodInfo`. By requiring it to have an implementation of circe's `Encoder` type class we can call `.asJson` on instances of `T`, encoding it into a JSON object. We can _derive_ these encoders automatically:

```scala
implicit val encoder: Encoder[PodInfo] = deriveEncoder
```

Producing YAML output is exactly the same except of first converting the JSON model to YAML with `asJson.asYaml`.

The third output format option is to generate ASCII tables. We implement that with the same Java library as the original post, called [`asciitable`](https://github.com/vdmeer/asciitable). In order to separate the specification of how to convert a `PodInfo` to a table from the sink implementation, we can define our own type class similar to the JSON `Encoder`:

```scala
trait Tabular[T] {
    /** Initializes a table by setting properties and adding header rows
      */
    def createTableRenderer(): ZManaged[Any, Nothing, AsciiTable]

    /** Adds a single item of type T to the table created with [[createTableRenderer()]]
      */
    def addRow(table: AsciiTable)(item: T): UIO[Unit]

    /** Adds the table's footer and renders it to a string
      */
    def renderTable(table: AsciiTable): UIO[String]
  }
```

We can implement this for `PodInfo` and then use a generic sink for printing the result table, similar to the previous examples:

```scala
def sink[T](implicit tabular: Tabular[T]): ZSink[Console, Nothing, T, T, Unit] =
  ZSink.managed[Console, Nothing, T, AsciiTable, T, Unit](tabular.createTableRenderer()) {
    table => // initialize the table
      ZSink.foreach(tabular.addRow(table)) <* // add each row
      printResultTable[T](table) // print the result
    }

def printResultTable[T](
  table: AsciiTable
)(implicit tabular: Tabular[T]): ZSink[Console, Nothing, T, T, Unit] =
  ZSink.fromEffect {
    tabular
      .renderTable(table)
      .flatMap(str => console.putStrLn(str))
  }
```

### Trying it out

With the report sinks implemenented we have everything ready to try out our new `kubectl` plugin!

We can compile the example to _native image_ and copy the resulting image to a location on the `PATH`:

```
sbt nativeImage
cp target/native-image/kubectl-lp ~/bin
```

Then use `kubectl lp` to access our custom functions:

![kubectl-example](/images/blog-ziok8s-kubectlplugin.png)
