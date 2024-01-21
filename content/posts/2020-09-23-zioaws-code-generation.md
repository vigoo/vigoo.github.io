+++
title = "Code generation in ZIO-AWS"

[taxonomies]
tags = ["scala", "zio", "aws", "codegen", "sbt"]
+++

I have recently published a set of libraries, [**zio-aws**](https://github.com/vigoo/zio-aws), aiming to provide a better interface for working with _AWS services_ from [ZIO](https://zio.dev/) applications. For more information about how the ZIO _interface_ works and how to get started with these libraries, read the repository's README. In this post, I will focus on how these libraries are generated from the schema provided by the [AWS Java SDK v2](https://github.com/aws/aws-sdk-java-v2).

## Generating code

I wanted to cover _all_ AWS services at once. This means client libraries for more than 200 services, so the only possible approach was to _generate_ these libraries on top of a small hand-written core.

### Schema

The first thing we need for generating code is a source schema. This is the model that we use to create the source code from. It is usually constructed by some kind of DSL or more directly described by a JSON or YAML or similar data model. In the case of **zio-aws** this was already defined in the [AWS Java SDK v2](https://github.com/aws/aws-sdk-java-v2) project. The way it works is:

- There is a `codegen` project, published in the `software.amazon.awssdk` group among the client libraries, that contains the Java classes used for generating the Java SDK itself. This contains the data model classes for parsing the actual schema as well.
- In the AWS Java SDK v2 repository, the schema is located in the subdirectory called [`services`](https://github.com/aws/aws-sdk-java-v2/tree/master/services). There is a directory for each AWS service and it contains among other things some relevant _JSON_ schema files:
  - `service-2.json` is the main schema of the service, describing the data structures and operations
  - `paginators-1.json` describes the operations that the Java SDK creates a _paginator interface_ for
  - `customization.config` contains extra information, including changes to be applied on top of the service model
- Fortunately, these are also embedded in the generated *AWS Java SDK* libraries as resources, so getting _all client libraries_ on the classpath gives us an easy way to get the corresponding schemas as well

I decided to use the low-level data classes from the AWS `codegen` library to parse these files and using that build a higher-level model that can be then used as an input for the _code generator_.

This is encapsulated in a _ZIO layer_ called `Loader`, which has two functions:

```scala
def findModels(): ZIO[Blocking, Throwable, Set[ModelId]]
def loadCodegenModel(id: ModelId): ZIO[Blocking, Throwable, C2jModels]
```

The first one, `findModels` uses the `ClassLoader` to enumerate all `codegen-resources` folders on the _classpath_ and just returns a set of `ModelId`s. `ModelId` is a pair of a model name (such as `s3`) and an optional submodule name (for example `dynamodb:dynamodbstreams`).

Then for each detected model we can load it with the `loadCodegenModel` function, `C2jModels` is a class from the AWS `codegen` library.

Figuring out how to interpret these data structures, and how to map them to the generated Java API was the hardest part, but it's out of scope for this post. Our next topic here is how we generate code from our _model_.

### Scalameta

There are several possibilities to generate source code and I tried many of them during the past years. Let's see some examples:

- Using a general-purpose text template engine. An example we used at [Prezi](https://prezi.com) is the [Java implementation of the Liquid templating engine](https://github.com/bkiers/Liqp). Another example is the [OpenAPI generator project](https://github.com/OpenAPITools/openapi-generator) that uses [Mustache](https://mustache.github.io/) templates to generate server and client code from OpenAPI specifications.
- Generating from code with some general-purpose pretty-printing library. With this approach, we are using the pretty-printer library's composability features to create source code building blocks, and map the code generator model to these constructs. It is easier to express complex logic in this case, as we don't have to encode it in a limited dynamic template model. On the other hand, reading the code generator's source and imagining the output is not easy, and nothing enforces that the pretty-printer building blocks are actually creating valid source code.
- If the target language has an AST with a pretty-printing feature, we can map the model to the AST directly and just pretty print at the end. With this, we get a much more efficient development cycle, as the generated code is at least guaranteed to be syntactically correct. But the AST can be far from how the target language's textual representation looks like, which makes it difficult to read and write this code.
- With a library that supports building ASTs with _quasiquotes_, we can build the AST fragments with a syntax that is very close to the generated target language. For _Scala_, a library that supports this and is used in a lot of tooling projects is [Scalameta](https://scalameta.org/)

I wanted to try using _Scalameta_ ever since I met Devon Stewart and he mentioned how he uses it in [guardrail](https://github.com/twilio/guardrail/). Finally, this was a perfect use case to do so!

To get an understanding of what kind of Scala language constructs can be built with _quasiquotes_ with _Scalameta_, check [the list of them in the official documentation](https://scalameta.org/docs/trees/quasiquotes.html). 

We get a good mix of both worlds with this. It is possible to express complex template logic in real code, creating higher-level constructs, taking advantage of the full power of Scala. On the other hand, the actual _quasiquoted_ fragments are still close to the code generator's target language (which is in this case also Scala).

Let's see a short example of this:

```scala
private def generateMap(m: Model): ZIO[GeneratorContext, GeneratorFailure, ModelWrapper] = {
  for {
    keyModel <- get(m.shape.getMapKeyType.getShape)
    valueModel <- get(m.shape.getMapValueType.getShape)
    keyT <- TypeMapping.toWrappedType(keyModel)
    valueT <- TypeMapping.toWrappedType(valueModel)
  } yield ModelWrapper(
    code = List(q"""type ${m.asType} = Map[$keyT, $valueT]""")
  )
}
```

For each _AWS_ service-specific _model type_ we generate some kind of wrapper code into the ZIO service client library. This is done by processing the schema model to an intermediate format where for each such wrapper, we have a `ModelWrapper` value that already has the _Scalameta AST_ for that particular wrapper. The above code fragment creates this for _map types_, which is a simple type alias for a Scala `Map`. It's a `ZIO` function, taking advantage of passing around the context in the _environment_ and safely handling generator failures, while the actual generated code part in the `q"""..."""` remained quite readable.

Then the whole _model package_ can be expressed like this:

```scala
for {
  // ...
  primitiveModels <- ZIO.foreach(primitiveModels.toList.sortBy(_.name))(generateModel)
  models <- ZIO.foreach(complexModels.toList.sortBy(_.name))(generateModel)
} yield q"""package $fullPkgName {

            import scala.jdk.CollectionConverters._
            import java.time.Instant
            import zio.{Chunk, ZIO}
            import software.amazon.awssdk.core.SdkBytes

            ..$parentModuleImport

            package object model {
              object primitives {
                ..${primitiveModels.flatMap(_.code)}
              }

              ..${models.flatMap(_.code)}
            }}"""
```

This can be then _pretty printed_ simply with`.toString` and saved to a `.scala` file.

## Building the libraries

We have a way to collect the service models and generate source code from that, but we still have to use that generated code somehow. In `zio-aws` the goal was to generate a separate _client library_ for each AWS service. At the time of writing, there were **235** such services. The generated libraries have to be built and published to _Sonatype_.

### First version

In the first version I simply wired together the above described `loader` and `generator` module into a `ZIO` _command line_ app, using [clipp](https://vigoo.github.io/clipp/docs/) for command line parsing. It's `main` was really just something like the following:

```scala
val app = for {
  svcs <- config.parameters[Parameters].map(_.serviceList)
  ids <- svcs match {
    case Some(ids) => ZIO.succeed(ids.toSet)
    case None => loader.findModels().mapError(ReflectionError)
  }
  _ <- ZIO.foreachPar(ids) { id =>
    for {
      model <- loader.loadCodegenModel(id).mapError(ReflectionError)
      _ <- generator.generateServiceCode(id, model).mapError(GeneratorError)
    } yield ()
  }
  _ <- generator.generateBuildSbt(ids).mapError(GeneratorError)
  _ <- generator.copyCoreProject().mapError(GeneratorError)
} yield ExitCode.success

val cfg = config.fromArgsWithUsageInfo(args, Parameters.spec).mapError(ParserError)
val modules = loader.live ++ (cfg >+> generator.live)
app.provideCustomLayer(modules)
```

Then created a _multi-module_ `sbt` project with the following modules:

- `zio-aws-codegen` the CLI code generator we were talking about so far
- `zio-aws-core` holding the common part of all AWS service wrapper libraries. This contains things like how to translate AWS pagination into `ZStream` etc.
- `zio-aws-akka-http`, `zio-aws-http4s` and `zio-aws-netty` are the supported _HTTP layers_, all depend on `zio-aws-core`

I also created a first _example_ project in a separate `sbt` project, that demonstrated the use of some of the generated AWS client libraries. With this primitive setup, building everything from scratch and running the example took the following steps:

1. `sbt compile` the root project
2. manually running `zio-aws-codegen` to generate _all client libs at once_ to a separate directory, with a corresponding `build.sbt` including all these projects in a single `sbt` project
3. `sbt publishLocal` in the generated `sbt` project
4. `sbt run` in the _examples_ project

For the second, manual step I created some _custom sbt tasks_ called `generateAll`, `buildAll`, and `publishLocalAll`, that downloaded an `sbt-launch-*.jar` and used it to run the code generator and fork an `sbt` to build the generated project.

The `generateAll` task was quite simple:

```scala
generateAll := Def.taskDyn {
  val root = baseDirectory.value.getAbsolutePath
  Def.task {
    (codegen / Compile / run).toTask(s" --target-root ${root}/generated --source-root ${root} --version $zioAwsVersion --zio-version $zioVersion --zio-rs-version $zioReactiveStreamsInteropVersion").value
  }
}.value
```

Launching a second `sbt` took more effort:

```scala
buildAll := Def.taskDyn {
  val _ = generateAll.value
  val generatedRoot = baseDirectory.value / "generated"
  val launcherVersion = sbtVersion.value
  val launcher = s"sbt-launch-$launcherVersion.jar"
  val launcherFile = generatedRoot / launcher

  Def.task[Unit] {
    if (!launcherFile.exists) {
      val u = url(s"https://oss.sonatype.org/content/repositories/public/org/scala-sbt/sbt-launch/$launcherVersion/sbt-launch-$launcherVersion.jar")
      sbt.io.Using.urlInputStream(u) { inputStream =>
        IO.transfer(inputStream, launcherFile)
      }
    }
    val fork = new ForkRun(ForkOptions()
      .withWorkingDirectory(generatedRoot))
    fork.run(
      "xsbt.boot.Boot",
      classpath = launcherFile :: Nil,
      options = "compile" :: Nil,
      log = streams.value.log
    )
  }
}.value
```

With these extra tasks, I released the first version of the library manually, but there was a lot of annoying difficulties:

- Having to switch between various `sbt` projects
- The need to `publishLocal` the generated artifacts in order to build the examples, or any kind of integration tests that I planned to add
- The only way to build only those client libraries that are needed for the examples/tests was to build and publish them manually, as this dependency was not tracked at all between the unrelated `sbt` projects
- Because the generated `sbt` project could not refer to the outer `zio-aws-core` project, it has to be copied into the generated project in the code generator step
- Building and publishing all the **235** projects at once required about **16Gb** memory and hours of compilation time. It was too big to run on any of the (freely available) CI systems.

### Proper solution

When I mentioned this, _Itamar Ravid_ recommended trying to make it an _sbt code generator_. `sbt` has built-in support for generating source code, as described [on it's documentation page](https://www.scala-sbt.org/1.0/docs/Howto-Generating-Files.html). This alone though would not be enough to cover our use case, as in `zio-aws` even the _set of projects_ is dynamic and comes from the enumeration of schema models. Fortunately, there is support for that in too, through the `extraProjects` property of `sbt` _plugins_.

With these two tools, the new project layout became the following:

- `zio-aws-codegen` is an sbt **plugin**, having it's own `sbt` project in a subdirectory
- the `zio-aws-core` and the HTTP libraries are all in the top-level project as before
- examples and integration tests are also part of the top-level project
- the `zio-aws-codegen` plugin is referenced using a `ProjectRef` from the outer project
- the plugin adds all the _AWS service client wrapper libraries_ to the top-level project
- these projects generate their source on-demand

In this setup, it is possible to build any subset of the generated libraries without the need to process and compile all of them, so it needs much less memory. It is also much simpler to run tests or build examples on top of them, as the test and example projects can directly depend on the generated libraries as `sbt` submodules. And even developing the _code generator_ itself is convenient - although for editing it, it has to be opened as in a separate IDE session, but otherwise, `sbt reload` on the top level project automatically recompiles the plugin when needed.

Let's see piece by piece how we can achieve this!

#### Project as a source dependency

The first thing I wanted to do is having the `zio-aws-codegen` project converted to an `sbt` plugin, but still having it in the same repository and be able to use it without having to install to a local repository. Although the whole code generator code could have been added to the top level `sbt` project's `project` source, I wanted to keep it as a separate module to be able to publish it as a library or a CLI tool in the future if needed.

This can be achieved by putting it in a subdirectory of the top level project, with a separate `build.sbt` that contains the

```scala
sbtPlugin := true
```

(beside the usual ones). Then it can be referenced in the top level project's `project/plugins.sbt` in the following way:

```scala
lazy val codegen = project
  .in(file("."))
  .dependsOn(ProjectRef(file("../zio-aws-codegen"), "zio-aws-codegen"))
```

and enabled in the `build.sbt` as

```scala
enablePlugins(ZioAwsCodegenPlugin)
```

#### Dynamically generating projects

To generate the subprojects dynamically, we need the `Set[ModelId]` coming from the `loader` module. It is a `ZIO` module, so from the `sbt` plugin we have to use `Runtime.default.unsafeRun` to execute it. 

As the code generator project is now an `sbt` plugin, all the `sbt` data structures are directly available, so we can just write a function that maps the `ModelId`s to `Project`s:

```scala
protected def generateSbtSubprojects(ids: Set[ModelId]): Seq[Project] = ???
```

One interesting part here is that some of the subprojects are depending on each other. This happens with AWS service _submodules_, indicated by the second parameter of `ModelId`. An example is `dynamodbstreams` that depends on `dynamodb`. When creating the `Project` values, we have to be able to `dependOn` on some other already generated projects, and they have to be generated in the correct order to do so.

We could do a full topological sort, but it is not necessary, here we know that the maximum depth of dependencies is 1, so it is enough to put the submodules at the end of the sequence:

```scala
val map = ids
  .toSeq
  .sortWith { case (a, b) =>
    val aIsDependent = a.subModuleName match {
      case Some(value) if value != a.name => true
      case _ => false
    }
    val bIsDependent = b.subModuleName match {
      case Some(value) if value != b.name => true
      case _ => false
    }
    bIsDependent || (!aIsDependent && a.toString < b.toString)
  }
```

Then in order to be able get the dependencies, we do a _fold_ on the ordered `ModelId`s:

```scala
  .foldLeft(Map.empty[ModelId, Project]) { (mapping, id) =>
      // ...
      val deps = id.subModule match {
        case Some(value) if value != id.name =>
          Seq(ClasspathDependency(LocalProject("zio-aws-core"), None),
              ClasspathDependency(mapping(ModelId(id.name, Some(id.name))), None))
        case _ =>
          Seq(ClasspathDependency(LocalProject("zio-aws-core"), None))
      }      
      val project = Project(fullName, file("generated") / name)
        .settings(
          libraryDependencies += "software.amazon.awssdk" % id.name % awsLibraryVersion.value,
          // ...
        .dependsOn(deps: _*)

      mapping.updated(id, project)
  }
```

To make it easier to work with the generated projects, we also create a project named `all` that aggregates all the ones generated above.

#### Applying settings to the generated projects

The code generator only sets the basic settings for the generated projects: name, path and dependencies. We need a lot more, setting organization and version, all the publishing options, controlling the Scala version, etc.

I decided to keep these settings outside of the code generator plugin, in the top-level `sbt` project. By creating an `AutoPlugin` end enabling it for all projects, we can inject all the common settings for both the hand-written and the generated projects:

```scala
object Common extends AutoPlugin {

  object autoImport {
    val scala212Version = "2.12.12"
    val scala213Version = "2.13.3"
    // ...
  }
  import autoImport._
    
  override val trigger = allRequirements
  override val requires = Sonatype

  override lazy val projectSettings =
    Seq(
      scalaVersion := scala213Version,
      crossScalaVersions := List(scala212Version, scala213Version),
      // ...
    )
}
```

#### Source generator task

At this point, we could also add the already existing _source code generation_ to the initialization of the plugin, and just generate all the subproject's all source files every time the `sbt` project is loaded. With this number of generated projects though, it would have been a very big startup overhead and would not allow us to split the build (at least not the code generation part) on CI, to solve the memory and build time issues.

As `sbt` has built-in support for defining _source generator tasks_, we can do much better!

Instead of generating the source codes in one step, we define a `generateSources` task and add it to each _generated subproject_ as a _source generator_:

```scala
Compile / sourceGenerators += generateSources.taskValue,
awsLibraryId := id.toString
```

The `awsLibraryId` is a custom property that we the `generateSources` task can use to determine which schema to use for the code generation.

The first part of this task is to gather the information from the project it got applied on, including the custom `awsLibraryId` property:

```scala
lazy val generateSources =
  Def.task {
    val log = streams.value.log

    val idStr = awsLibraryId.value
    val id = ModelId.parse(idStr) match {
      case Left(failure) => sys.error(failure)
      case Right(value) => value
    }

    val targetRoot = (sourceManaged in Compile).value
    val travisSrc = travisSource.value
    val travisDst = travisTarget.value
    val parallelJobs = travisParallelJobs.value
```

From these, we create a `Parameters` data structure to pass to the `generator` module. This is what we used to construct with `clipp` from CLI arguments:

```scala
    val params = Parameters(
      targetRoot = Path.fromJava(targetRoot.toPath),
      travisSource = Path.fromJava(travisSrc.toPath),
      travisTarget = Path.fromJava(travisDst.toPath),
      parallelTravisJobs = parallelJobs
    )
```

And finally, construct the `ZIO` environment, load a **single** schema model, and generate the library's source code:

```scala
    zio.Runtime.default.unsafeRun {
      val cfg = ZLayer.succeed(params)
      val env = loader.live ++ (cfg >+> generator.live)
      val task =
        for {
          _ <- ZIO.effect(log.info(s"Generating sources for $id"))
          model <- loader.loadCodegenModel(id)
          files <- generator.generateServiceCode(id, model)
        } yield files.toSeq
      task.provideCustomLayer(env).catchAll { generatorError =>
        ZIO.effect(log.error(s"Code generator failure: ${generatorError}")).as(Seq.empty)
      }
    }
  }
```

The `generateServiceCode` function returns a `Set[File]` value containing all the generated source files. This is the result of the _source generator task_, and `sbt` uses this information to add the generated files to the compilation.

#### Referencing the generated projects

When defining downstream projects in the `build.sbt`, such as integration tests and other examples, we have to refer to the generated projects somehow. There is no value of type `Project` in scope to do so, but we can do it easily by name using `LocalProject`. The following example shows how the `example1` subproject does this:

```scala
lazy val example1 = Project("example1", file("examples") / "example1")
  .dependsOn(
    core,
    http4s,
    netty,
    LocalProject("zio-aws-elasticbeanstalk"),
    LocalProject("zio-aws-ec2")
  )
```

#### Parallel build on Travis CI

The last thing that I wanted to solve is building the full `zio-aws` suite on a CI. I am using [Travis CI](https://travis-ci.org/) for my private projects, so that's what I built it for. The idea is to split the set of _service client libraries_ to chunks and create [build matrix](https://docs.travis-ci.com/user/build-matrix/) to run those in parallel. The tricky part is that the set of generated service libraries is dynamic, collected by the code generator.

To solve this, I started to generate the `.travis.yml`  build descriptor as well. The _hand-written_ part has been moved to `.travis.base.yml`:

```yaml
language: scala
services:
  - docker
scala:
  - 2.12.12
  - 2.13.3

cache:
  directories:
    - $HOME/.cache/coursier
    - $HOME/.ivy2/cache
    - $HOME/.sbt

env:
  - COMMANDS="clean zio-aws-core/test zio-aws-akka-http/test zio-aws-http4s/test zio-aws-netty/test"
  - COMMANDS="clean examples/compile"
  - COMMANDS="clean integtests/test"

before_install:
  - if [ "$COMMANDS" = "clean integtests/test" ]; then docker pull localstack/localstack; fi
  - if [ "$COMMANDS" = "clean integtests/test" ]; then docker run -d -p 4566:4566 --env SERVICES=s3,dynamodb --env START_WEB=0 localstack/localstack; fi

script:
  - sbt ++$TRAVIS_SCALA_VERSION -jvm-opts travis/jvmopts $COMMANDS
```

I use the `COMMANDS` environment variable to define the parallel sets of `sbt` commands here. There are three predefined sets: building `zio-aws-core` and the HTTP implementations, building the _example projects_ and running the _integration test_. The last two involve generating actual service client code and building them - but only the few that are necessary, so it is not an issue to do that redundantly.

The real `.travis.yml` file is then generated by running a task _manually_, `sbt generateTravisYaml`. It is implemented in the `zio-aws-codegen` plugin and it loads the `.travis.base.yml` file and extends the `env` section with a set of `COMMANDS` variants, each compiling a subset of the generated subprojects.

## Conclusion

Travis CI can now build `zio-aws` and run its integration tests. A build runs for hours, but it is stable, and consists of 22 parallel jobs to build all the libraries for both Scala 2.12 and 2.13. At the same time, developing the code generator and the other subprojects and tests became really convenient.

