+++
title = "Generating a Rust client library for ZIO Http endpoints"

[taxonomies]
tags = ["scala", "rust", "codegen", "zio"]
+++

We at [Golem Cloud](https://golem.cloud) built our first developer preview on top of the ZIO ecosystem, including [ZIO Http](https://github.io/zio/zio-http) for defining and implementing our server's REST API. By using **ZIO Http** we immediately had the ability to call our endpoints using endpoint **client**s, which allowed us to develop the first version of Golem's **CLI tool** very rapidly.

Although very convenient for development, _using_ a CLI tool built with Scala for the JVM is not a pleasant experience for the users due to the slow startup time. One possible solution is to compile to native using [GraalVM Native Image](https://www.graalvm.org/22.0/reference-manual/native-image/) but it is very hard to set up and even when it works, it is extremely fragile - further changes to the code or updated dependencies can break it causing unexpected extra maintenance cost. After some initial experiments we dropped this idea - and instead chose to reimplement the CLI using **Rust** - a language being a much better fit for command line tools, and also already an important technology in our Golem stack.

## ZIO Http

If we rewrite `golem-cli` to Rust, we lose the convenience of using  **endpoint definitions** (written in Scala with ZIO Http, the ones we have for implementing the server) for calling our API, and we would also lose all the **types** used in these APIs as they are all defined as Scala case classes and enums. Just to have more context, let's take a look at one of the endpoints!

A ZIO Http **endpoint** is just a definition of a single endpoint of a HTTP API, describing the routing as well the inputs and outputs of it:

```scala
val getWorkerMetadata =
    Endpoint(GET / "v1" / "templates" / rawTemplateId / "workers" / workerName)
      .header(Auth.tokenSecret)
      .outErrorCodec(errorCodec)
      .out[WorkerMetadata] ?? Doc.p("Get the current worker status and metadata")
```

Let's see what we have here:

- the endpoint is reached by sending a **GET** request
- the request **path** consists of some static segments as well as the _template id_ and the _worker name_ 
- it also requires an **authorization header**
- we define the kind of errors it can return
- and finally it defines that the response's **body** will contain a JSON representation (default in ZIO Http) of a type called `WorkerMetadata`

What are `rawTemplateId` and `workerName`? These are so called **path codecs**, defined in a common place so they can be reused in multiple endpoints. They allow us to have dynamic parts of the request path mapped to specific types - so when we implement the endpoint (or call it in a client) we don't have to pass strings and we can directly work with the business domain types, in this case `RawTemplateId` and `WorkerName`.

The simplest way to define path codecs is to **transform** an existing one:

```scala
val workerName: PathCodec[WorkerName] =
  string("worker-name").transformOrFailLeft(WorkerName.make(_).toErrorEither, _.value)
```

Here the `make` function is a **ZIO Prelude** [`Validation`](https://zio.github.io/zio-prelude/docs/functionaldatatypes/validation) which we have to convert to an `Either` for the transform function. Validations can contain more than one failures, as opposed to `Either`s, which allows us to compose them in a way that we can keep multiple errors instead of immediately returning with the first failure.

The `tokenSecret` is similar, but it is a `HeaderCodec` describing what type of header it is and how the value of the given header should be mapped to a specific type (a token, in this case).

What is `WorkerMetadata` and how does ZIO Http know how to produce a JSON from it?

It's just a simple _case class_:

```scala
final case class WorkerMetadata(
  workerId: ComponentInstanceId,
  accountId: AccountId,
  args: Chunk[String],
  env: Map[String, String],
  status: InstanceStatus,
  templateVersion: Int,
  retryCount: Int
)
```

But with an implicit **derived** **ZIO Schema**:

```scala
object WorkerMetadata {
  implicit val schema: Schema[WorkerMetadata] = DeriveSchema.gen[WorkerMetadata]
}
```

We will talk more about ZIO Schema below - for now all we need to know is it describes the structure of Scala types, and this information can be used to serialize data into various formats, including JSON.

Once we have our endpoints defined like this, we can do several things with them - they are just data describing what an endpoint looks like!

### Implementing an endpoint

When developing a _server_, the most important thing to do with an endpoint is to **implement** it. Implementing an endpoint looks like the following:

```scala
val getWorkerMetadataImpl =
    getWorkerMetadata.implement {
      Handler.fromFunctionZIO { (rawTemplateId, workerName, authTokenId) =>
        // ... ZIO program returning a WorkerMetadata
      }
    }
```

The _type_ of `getWorkerMetadataImpl` is `Route` - it is no longer just a description of what an endpoint looks like, it defines a specific HTTP route and its associated _request handler_, implemented by a ZIO effect (remember that ZIO effects are also values - we _describe_ what we need to do when a request comes in, but executing it will be the responsibility of the server implementation).

The nice thing about ZIO Http endpoints is that they are completely type safe. I've hidden the type signature in the previous code snippets but actually `getWorkerMetadata` has the type:

```scala
Endpoint[
    (RawTemplateId, WorkerName),
    (RawTemplateId, WorkerName, TokenSecret),
    WorkerEndpointError,
    WorkerMetadata,
    None
]
```

Here the _second_ type parameter defines the **input** of the request handler and the _forth_ type parameter defines the **output** the server constructs the response from.

With these types, we really just have to implement a (ZIO) function from the input to the output: 

```scala
(RawTemplateId, WorkerName, TokenSecret) => ZIO[Any, WorkerEndpointError, WorkerMetadata]
```

and this is exactly what we pass to `Handler.fromFunctionZIO` in the above example.

### Calling an endpoint

The same endpoint values can also be used to make requests to our API from clients such as `golem-cli`. Taking advantage of the same type safe representation we can just call `apply` on the endpoint definition passing its input as a parameter to get an **invocation**:

```scala
val invocation = getInstanceMetadata(rawTemplateId, workerName, token)
```

this invocation can be **executed** to perform the actual request using an `EndpointExecutor` which can be easily constructed from a ZIO Http `Client` and some other parameters like the URL of the remote server:

```scala
executor(invocation).flatMap { workerMetadata => 
  // ...
}
```

## The task

So can we do anything to keep this convenient way of calling our endpoints when migrating the CLI to Rust? At the time of writing we already had more than 60 endpoints, with many complex types used in them - defining them by hand in Rust, and keeping the Scala and Rust code in sync sounds like a nightmare.

The ideal case would be to have something like this in Rust:

```rust
#[async_trait]
pub trait Worker {
  // ...
  async fn get_worker_metadata(&self, template_id: &TemplateId, worker_name: &WorkerName, authorization: &Token) -> Result<WorkerMetadata, WorkerError>;
}
```

with an implementation that just requires the same amount of configuration as the Scala endpoint executor (server URL, etc), and all the referenced types like `WorkerMetadata` would be an exact clone of the Scala types just in Rust.

Fortunately we can have (almost) this by taking advantage of the declarative nature of ZIO Http and ZIO Schema!

In the rest of this post we will see how we can **generate Rust code** using a combination of ZIO libraries to automatically have all our type definitions and client implementation ready to use from the Rust version of `golem-cli`.

## The building blocks

We want to generate from an arbitrary set of ZIO Http `Endpoint` definitions a **Rust crate** ready to be compiled, published and used. We will take advantage of the following libraries:

- [ZIO Http](https://zio.dev/zio-http/) as the source of **endpoint** definitions
- [ZIO Schema](https://zio.dev/zio-schema/) for observing the **type** definitions
- [ZIO Parser](https://zio.dev/zio-parser/) because it has a composable **printer** concept
- [ZIO NIO](https://zio.dev/zio-nio/) for working with the **filesystem**
- [ZIO Prelude](https://zio.dev/zio-prelude/) for implementing the stateful endpoint/type discovery in a purely functional way

## Generating Rust code

Let's start with the actual source code generation. This is something that can be done in many different ways - one extreme could be to just concatenate strings (or use a `StringBuilder`) while the other is to build a full real Rust _AST_ and pretty print that. I had a [talk on Function Scala 2021 about the topic](@/posts/2021-12-03-funscala2021-talk.md).

For this task I chose a technique which is somewhere in the middle and provides some extent of composability while also allowing use to do just the amount of abstraction we want to. The idea is that we define a _Rust code generator model_ which does not have to strictly follow the actual generated language's concepts, and then define a pretty printer for this model. This way we only have to model the subset of the language we need for the code generator, and we can keep simplifications or even complete string fragments in it if that makes our life easier. 

Let's see how this works with some examples!

We will have to generate _type definitions_ so we can define a Scala _enum_ describing what kind of type definitions we want to generate:

```scala
enum RustDef:
  case TypeAlias(name: Name, typ: RustType, derives: Chunk[RustType])
  case Newtype(name: Name, typ: RustType, derives: Chunk[RustType])
  case Struct(name: Name, fields: Chunk[RustDef.Field], derives: Chunk[RustType], isPublic: Boolean)
  case Enum(name: Name, cases: Chunk[RustDef], derives: Chunk[RustType])
  case Impl(tpe: RustType, functions: Chunk[RustDef])
  case ImplTrait(implemented: RustType, forType: RustType, functions: Chunk[RustDef])
  case Function(name: Name, parameters: Chunk[RustDef.Parameter], returnType: RustType, body: String, isPublic: Boolean)
```

We can make this as convenient to use as we want, for example adding constructors like:

```scala 
def struct(name: Name, fields: Field*): RustDef
```

The `Name` is an opaque string type with extension methods to convert between various cases like pascal case, snake case, etc. `RustType` is a similar _enum_ to `RustDef`, containing all the different type descriptions we will have to use. But it is definitely not how a proper Rust parser would define what a type is - for example we can have a `RustType.Option` as a shortcut for wrapping a Rust type in Rust's own option type, just because it makes our code generator simpler to write.

So once we have this model (which in practice evolves together with the code generator, usually starting with a few simple case classes) we can use **ZIO Parser**'s printer feature to define composable elements constructing Rust source code.

We start by defining a module and a type alias for our printer:

```scala
object Rust:
  type Rust[-A] = Printer[String, Char, A]
```

and then just define building blocks - what these building blocks are depends completely on us, and the only thing it affects is how well you can compose them. Having very small building blocks may reduce the readability of the code generator, but using too large chunks reduces their composability and makes it harder to change or refactor.

We can define some short aliases for often used characters or string fragments:

```scala
def gt: Rust[Any] = Printer.print('>')
def lt: Rust[Any] = Printer.print('<')
def bracketed[A](inner: Rust[A]): Rust[A] =
  lt ~ inner ~ gt
```

and we have to define `Rust` printers for each of our model types. For example for the `RustType` enum it could be something like this:

```scala
def typename: Rust[RustType] = Printer.byValue:
  case RustType.Primitive(name)             => str(name)
  case RustType.Option(inner)               => typename(RustType.Primitive("Option")) ~ bracketed(typename(inner))
  case RustType.Vec(inner)                  => typename(RustType.Primitive("Vec")) ~ bracketed(typename(inner))
  case RustType.SelectFromModule(path, typ) => Printer.anyString.repeatWithSep(dcolon)(path) ~ dcolon ~ typename(typ)
  case RustType.Parametric(name, params) =>
    str(name) ~ bracketed(typename.repeatWithSep(comma)(params))
  // ...
```

We can see that `typename` uses itself to recursively generate inner type names, for example when generating type parameters of tuple members. It also demonstrates that we can extract patterns such as `bracketed` to simplify our printer definitions and eliminate repetition.

Another nice feature we get by using a general purpose printer library like ZIO Parser is that we can use the built-in combinators to get printers for new types. One example is the sequential composition of printers. For example the following fragment:

```scala
val p = str("pub ") ~ name ~ str(": ") ~ typename
```

would have the type `Rust[(Name, RustType)]` and we can even make that a printer of a case class like:

```scala
final case class PublicField(name: Name, typ: RustType)

val p2 = p.from[PublicField]
```

where `p2` will have the type `Rust[PublicField`].

Another very useful combinator is **repetition**. For example if we have a printer for an enum's case:

```scala
def enumCase: Rust[RustDef] = // ...
```

we can simply use one of the repetition combinators to make a printer for a _list of enum cases_: 

```scala
def enumCases: Rust[Chunk[RustDef]] = enumCase.*
```

or as in the `typename` example above:

```scala
typename.repeatWithSep(comma)
```

to have a `Rust[Chunk[RustType]]` that inserts a comma between each element when printed.

## Inspecting the Scala types

As we have seen the _endpoint DSL_ uses **ZIO Schema** to capture information about the types being used in the endpoints (usually as request or response bodies, serialized into JSON). We can use the same information to generate **Rust types** from our Scala types!

The core data type defined by the ZIO Schema library is called `Schema`:

```scala
sealed trait Schema[A] {
  // ...
}
```

Schema describes the structure of a Scala type `A` in a way we can inspect it from regular Scala code. Let's imagine we have `Schema[WorkerMetadata]` coming from our endpoint definition and we have to generate an equivalent Rust `struct` with the same field names and field types.

The first thing to notice is that type definitions are recursive. Unless `WorkerMetadata` only contains fields of _primitive types_ such as integer or string, our job does not end with generating a single Rust struct - we need to recursively generate all the other types `WorkerMetadata` is depending on! To capture this fact let's introduce a type that represents everything we have to extract from a single (or a set of) schemas in order to generate Rust types from them:

```scala
final case class RustModel(
  typeRefs: Map[Schema[?], RustType], 
  definitions: Chunk[RustDef], 
  requiredCrates: Set[Crate]
)
```

We have `typeRefs` which associates a `RustType` with a schema so we can use it in future steps of our code generator to refer to a generated type in our Rust codebase. We have a list of `RustDef` values which are the generated type definitions, ready to be printed with out `Rust` pretty printer. And finally we can also gather a set of required extra rust _crates_, because some of the types considered _primitive types_ by ZIO Schema are not having proper representations in the Rust standard library, only in external crates. Examples are UUIDs and various date/time types.

So our job now is to write a function of 

```scala
def fromSchemas(schemas: Seq[Schema[?]]): Either[String, RustModel]
```

The `Either` result type is used to indicate failures. Even if we write a transformation that can produce from any `Schema` a proper `RustModel`, we always have to have an error result when working with ZIO Schema because it has an explicit failure case called `Schema.Fail`. If we process a schema and end up with a `Fail` node, we can't do anything else than fail our code generator.

There are many important details to consider when implementing this function, but let's just see first what the actual `Schema` type looks like. When we have a value of `Schema[?]` we can pattern match on it and implement the following cases:

- `Schema.Primitive` describes a primitive type - there are a lot of primitive types defined by ZIO Schema's `StandardType` enum
- `Schema.Enum` describes a type with multiple cases (a _sum type_) such as a `sealed trait` or `enum` 
- `Schema.Record` describes a type with multiple fields (a _product type_) such as a `case class` 
- `Schema.Map` represents a _map_ with a key and value type
- `Schema.Sequence` represents a _sequence_ of items of a given element type
- `Schema.Set` is a _set_ of items of a given element type
- `Schema.Optional` represents an _optional_ type (like an `Option[T]`)
- `Schema.Either` is a special case of sum types representing either one or the other type (like an `Either[A, B]`)
- `Schema.Lazy` is used to safely encode recursive types, it contains a function that evaluates into an inner `Schema`
- `Schema.Dynamic` represents a type that is dynamic - like a `JSON` value
- `Schema.Transform` assigns a transformation function that converts a _value_ of a type represented by the schema to a value of some other type. As we have no way to inspect these functions (they are compiled Scala functions) in our code generator, this is not very interesting for us now.
- `Schema.Fail` as already mentioned represents a failure in describing the data type

When traversing a `Schema` recursively (for any reason), it is important to keep in mind that it _can_ encode recursive types! A simple example is a binary tree:

```scala
final case class Tree[A](label: A, left: Option[Tree], right: Option[Tree])
```

We can construct a `Schema[Tree[A]]` if we have a `Schema[A]`. This will be something like (pseudo-code):

```scala
lazy val tree: Schema[Tree] =
  Schema.Record(
    Field("label", Schema[A]),
    Field("left", Schema.Optional(Schema.Lazy(() => tree))),
    Field("right", Schema.Optional(Schema.Lazy(() => tree)))
  )
```

If we are not prepared for recursive types we can easily get into an endless loop (or stack overflow) when processing these schemas.

This is just one example of things to keep track of while converting a schema into a set of Rust definitions. If fields refer to the self type we want to use `Box` so to put them on the heap. We also need to keep track of if everything within a generated type derives `Ord` and `Hash` - and if yes, we should derive an instance for the same type classes for our generated type as well.

My preferred way to implement such recursive stateful transformation functions is to use **ZIO Prelude**'s `ZPure` type. It's type definition looks a little scary:

```scala
sealed trait ZPure[+W, -S1, +S2, -R, +E, +A]
```

`ZPure` describes a _purely functional computation_ which can:

- Emit log entries of type `W`
- Works with an inital state of type `S1`
- Results in a final state of type `S2`
- Has access to some context of type `R`
- Can fail with a value of `E`
- Or succeed with a value of `A`

In this case we need the state, failure and result types only, but we could also take advantage of `W` to log debug information within our schema transformation function.

To make it easier to work with `ZPure` we can introduce a _type alias_:

```scala
type Fx[+A] = ZPure[Nothing, State, State, Any, String, A]
```

where `State` is our own _case class_ containing everything we need:

```scala
final case class State(
  typeRefs: Map[Schema[?], RustType],
  definitions: Chunk[RustDef],
  requiredCrates: Set[Crate],
  processed: Set[Schema[?]],
  stack: Chunk[Schema[?]],
  nameTypeIdMap: Map[Name, Set[TypeId]],
  schemaCaps: Map[Schema[?], Capabilities]
)
```

We won't get into the details of the state type here, but I'm showing some fragments to get a feeling of working with `ZPure` values.

Some helper functions to manipulate the state can make our code much easier to read:

```scala
private def getState: Fx[State] = ZPure.get[State]
private def updateState(f: State => State): Fx[Unit] = ZPure.update[State, State](f)
```

For example we can use `updateState`  to manipulate the `stack` field of the state around another computation - before running it, we add a schema to the stack, after that we remove it:

```scala
private def stacked[A, R](schema: Schema[A])(f: => Fx[R]): Fx[R] =
  updateState(s => s.copy(stack = s.stack :+ schema))
    .zipRight(f)
    .zipLeft(updateState(s => s.copy(stack = s.stack.dropRight(1))))
```

This allows us to decide whether we have to wrap a generated field's type in `Box` in the rust code:

```scala
private def boxIfNeeded[A](schema: Schema[A]): Fx[RustType] =
  for
    state <- getState
    backRef = state.stack.contains(schema)
    rustType <- getRustType(schema)
  yield if backRef then RustType.box(rustType) else rustType
```

By looking into `state.stack` we can decide if we are dealing with a recursive type or not, and make our decision regarding boxing the field.

Another example is to guard against infinite recursion when traversing the schema definition, as I explained before. We can define a helper function that just keeps track of all the visited schemas and shortcuts the computation if something has already been seen:

```scala
private def ifNotProcessed[A](value: Schema[A])(f: => Fx[Unit]): Fx[Unit] =
  getState.flatMap: state =>
    if state.processed.contains(value) then ZPure.unit
    else updateState(_.copy(processed = state.processed + value)).zipRight(f)
```

Putting all these smaller combinators together we have an easy-to-read core recursive transformation function for converting the schema:

```scala
private def process[A](schema: Schema[A]): Fx[Unit] =
  ifNotProcessed(schema):
    getRustType(schema).flatMap: typeRef =>
      stacked(schema):
        schema match
          // ...
```

In the end to run a `Fx[A]` all we need to do is to provide an initial state:

```scala
processSchema.provideState(State.empty).runEither
```



## Inspecting the endpoints

We generated Rust code for all our types but we still need to generate HTTP clients. The basic idea is the same as what we have seen so far:

- Traversing the `Endpoint` data structure for each endpoint we have
- Generate some intermediate model 
- Pretty print this model to Rust code

The conversion once again is recursive, can fail, and requires keeping track of various things, so we can use `ZPure` to implement it. Not repeating the same details, in this section we will talk about what exactly the endpoint descriptions look like and what we have be aware of when trying to process them.

The first problem to solve is that currently ZIO Http does not have a concept of multiple endpoints. We are not composing `Endpoint` values into an API, instead we first **implement** them to get `Route` values and compose those. We can no longer inspect the endpoint definitions from the composed routes, so unfortunately we have to repeat ourselves and somehow compose our set of endpoints for our code generator. 

First we can define a `RustEndpoint` class, similar to the `RustModel` earlier, containing all the necessary information to generate Rust code for a **single endpoint**.

We can construct it with a function:

```scala
// ...
object RustEndpoint:
  def fromEndpoint[PathInput, Input, Err, Output, Middleware <: EndpointMiddleware](
      name: String,
      endpoint: Endpoint[PathInput, Input, Err, Output, Middleware],
  ): Either[String, RustEndpoint] = // ...
```

The second thing to notice: endpoints do not have a name! If we look back to our initial example of `getWorkerMetadata`, it did not have a unique name except the Scala value it was assigned to. But we can't observe that in our code generator (without writing a macro) so here we have chosen to just get a name as a string next to the definition.

Then we can define a **collection** of `RustEndpoint`s:

```scala
final case class RustEndpoints(name: Name, originalEndpoints: Chunk[RustEndpoint])
```

and define a `++` operator between `RustEndpoint` and `RustEndpoints`. In the end we can use these to define APIs like this:

```scala
    for
      getDefaultProject <- fromEndpoint("getDefaultProject", ProjectEndpoints.getDefaultProject)
      getProjects       <- fromEndpoint("getProjects", ProjectEndpoints.getProjects)
      postProject       <- fromEndpoint("postProject", ProjectEndpoints.postProject)
      getProject        <- fromEndpoint("getProject", ProjectEndpoints.getProject)
      deleteProject     <- fromEndpoint("deleteProject", ProjectEndpoints.deleteProject)
    yield (getDefaultProject ++ getProjects ++ postProject ++ getProject ++ deleteProject).named("Project")
```

The collection of endpoints also have a name (`"Project"`). In the code generator we can use these to have a separate **client** (trait and implementation) for each of these groups of endpoints.

When processing a single endpoint, we need to process the following parts of data:

- Inputs (`endpoint.input`)
- Outputs (`endpoint.output`)
- Errors (`endpoint.error`)

Everything we need is encoded in one of these three fields of an endpoint, and all three are built on the same abstraction called `HttpCodec`. Still there is a significant difference in what we want to do with inputs versus what we want to do with outputs and errors, so we can write two different traversals for gathering all the necessary information from them.

### Inputs

When gathering information from the inputs, we are going to run into the following cases:

- `HttpCodec.Combine` means we have two different inputs; we need both, so we have to process both inner codecs sequentially, both extending our conversion function's state.
- `HttpCodec.Content` describes a **request body**. Here we have a `Schema` of our request body type and we can use the previously generated schema-to-rust type mapping to know how to refer to the generated rust type in our client code. It is important that in case there are **multiple content codecs**, that means the endpoint receives a `multipart/form-data` body, while if there is only one codec, it accepts an `application/json` representation of that.
- `HttpCodec.ContentStream` represents a body containing a stream of a given element type. We can model this as just a `Vec<A>` in the Rust side, but there is one special case here - if the element is a `Byte`, ZIO Http expects a simple byte stream of type `application/octet-stream` instead of a JSON-encoded array of bytes.
- `HttpCodec.Fallback` this represents the case when we should either use the first codec, _or_ the second. A special case is when the `right` value of `Fallback` is `HttpCodec.Empty`. This is how ZIO Http represents optional inputs! We have to handle this specially in our code generator to mark some of the input parameters of the generated API as optional parameters. We don't support currently the other cases (when `right` is not empty) as it is not frequently used and was not required for the *Golem API*.
- `HttpCodec.Header` means we need to send a _header_ in the request, which can be a static (value described by the endpoint) or dynamic one (where we need to add an extra parameter to the generated function to get a value of the header). There are a couple of different primitive types supported for the value, such as string, numbers, UUIDs.
- `HttpCodec.Method` defines the method to be used for calling the endpoint
- `HttpCodec.Path` describes the request path, which consists of a sequence of static and dynamic segments - for the dynamic segments the generated API need to have exposed function parameters of the appropriate type
- `HttpCodec.Query` similar to the header codec defines query parameters to be sent
- `HttpCodec.TransformOrFail` transforms a value with a Scala function - the same case as with `Schema.Transform`. We cannot use the Scala function in our code generator so we just need to ignore this and go to the inner codec.
- `HttpCodec.Annotated` attaches additional information to the codecs that we are currently not using, but it could be used to get documentation strings and include them in the generated code as comments, for example.

### Outputs

For outputs we are dealing with the same `HttpCodec` type but there are some significant differences:

- We can ignore `Path`, `Method`, `Query` as they have no meaning for outputs
- We could look for _output headers_ but currently we ignore them
- `Fallback` on the other hand needs to be properly handled for outputs (errors, especially) because this is how the different error responses are encoded.
- `Status` is combined with `Content` in these `Fallback` nodes to describe cases. This complicates the code generator because we need to record "possible outputs" which are only added as real output once we are sure we will not get any other piece of information for them.

To understand the error fallback handling better, let's take a look at how it is defined in one of Golem's endpoint groups:

```scala
val errorCodec: HttpCodec[HttpCodecType.Status & HttpCodecType.Content, LimitsEndpointError] =
  HttpCodec.enumeration[LimitsEndpointError](
    HttpCodec.error[LimitsEndpointError.Unauthorized](Status.Unauthorized),
    HttpCodec.error[LimitsEndpointError.ArgValidationError](Status.BadRequest),
    HttpCodec.error[LimitsEndpointError.LimitExceeded](Status.Forbidden),
    HttpCodec.error[LimitsEndpointError.InternalError](Status.InternalServerError)
  )
```

This leads to a series of nested `HttpCodec.Fallback`, `HttpCodec.Combine`, `HttpCodec.Status` and `HttpCodec.Content` nodes. When processing them we first add values of possible outputs:

```scala
final case class PossibleOutput(tpe: RustType, status: Option[Status], isError: Boolean, schema: Schema[?])
```

and once we have fully processed one branch of a `Fallback`, we finalize these possible outputs and make them real outputs. The way these different error cases are mapped into different case classes of a a single error type (`LimitsEndpointError`) also complicates things. When we reach a `HttpCodec.Content` referencing  `Schema[LimitsEndpointError.LimitExceeded`] for example, all we see is a `Schema.Record` - and not the parent enum! For this reason in the code generator we are explicitly defining the error ADT type:

```scala
val fromEndpoint = RustEndpoint.withKnownErrorAdt[LimitsEndpointError].zio
```

and we detect if all cases are subtypes of this error ADT and generate the client code according to that.

### The Rust client

It is time to take a look at what the output of all this looks like. In this section we will examine some parts of the generated Rust code.

Let's take a look at the **Projects API**. We have generated a `trait` for all the endpoints belonging to it:

```rust
#[async_trait::async_trait]
pub trait Project {
    async fn get_default_project(&self, authorization: &str) -> Result<crate::model::Project, ProjectError>;
    async fn get_projects(&self, project_name: Option<&str>, authorization: &str) -> Result<Vec<crate::model::Project>, ProjectError>;
    async fn post_project(&self, field0: crate::model::ProjectDataRequest, authorization: &str) -> Result<crate::model::Project, ProjectError>;
    async fn get_project(&self, project_id: &str, authorization: &str) -> Result<crate::model::Project, ProjectError>;
    async fn delete_project(&self, project_id: &str, authorization: &str) -> Result<(), ProjectError>;
}
```

This is quite close to our original goal! One significant difference is that some type information is lost: `project_id` was `ProjectId` in Scala, and `authorization` was `TokenSecret` etc. Unfortunately with the current version of ZIO Schema these newtypes (or Scala 3 opaque types) are represented as primitive types transformed by a function. As explained earlier, we can't inspect the transformation function so all we can do is to use the underlying primitive type's schema here. This can be solved by introducing the concept of newtypes into ZIO Schema.

The `ProjectError` is a client specific generated `enum` which can represent a mix of internal errors (such as not being able to call the endpoint) as well as the endpoint-specific domain errors:

```rust
pub enum ProjectError {
    RequestFailure(reqwest::Error),
    InvalidHeaderValue(reqwest::header::InvalidHeaderValue),
    UnexpectedStatus(reqwest::StatusCode),
    Status404 {
        message: String,
    },
    Status403 {
        error: String,
    },
    Status400 {
        errors: Vec<String>,
    },
    Status500 {
        error: String,
    },
    Status401 {
        message: String,
    },
}
```

So why are these per-status-code error types inlined here instead of generating the error ADT as a Rust `enum` and using that? The reason is a difference between Scala and Rust: we have a single error ADT in Scala and we can still use its _cases_ directly in the endpoint definition:

```scala
sealed trait ProjectEndpointError
object ProjectEndpointError {
  final case class ArgValidation(errors: Chunk[String]) extends ProjectEndpointError
  // ...
}

// ...
HttpCodec.error[ProjectEndpointError.ArgValidation](Status.BadRequest),
```

We _do_ generate the corresponding `ProjectEndpointError` enum in Rust:

```rust
#[derive(Debug, Clone, PartialEq, Eq, Hash, Ord, PartialOrd, serde::Serialize, serde::Deserialize)]
pub enum ProjectEndpointError {
    ArgValidation {
        errors: Vec<String>,
    },
    // ...
}
```

but we cannot use `ProjectEndpointError::ArgValidation` as a type in the above `ProjectError` enum. And we cannot safely do something like `Either[ClientError, ProjectEndpointError]` because in the endpoint DSL we just have a sequence of status code - error case pairs. There is no guarantee that one enum case is only used once in that mapping, or that every case is used at least once. For this reason the mapping from `ProjectError` to `ProjectEndpointError` is generated as a transformation function:

```rust
impl ProjectError {
  pub fn to_project_endpoint_error(&self) -> Option<crate::model::ProjectEndpointError> {
    match self {
      ProjectError::Status400 { errors } => Some(crate::model::ProjectEndpointError::ArgValidation { errors: errors.clone() }), 
      // ...
    }
  }
}
```

For each client trait we also generate a **live implementation**, represented by a struct containing configuration for the client:

```rust
#[derive(Clone, Debug)]
pub struct ProjectLive {
    pub base_url: reqwest::Url,
    pub allow_insecure: bool,
}
```

And the implementation of the client trait for these live structs are just using [`reqwest`](https://docs.rs/reqwest/latest/reqwest/) (a HTTP client library for Rust) to construct the request from the input parameters exactly the way the endpoint definition described:

```rust
async fn get_project(&self, project_id: &str, authorization: &str) -> Result<Project, ProjectError> {
  let mut url = self.base_url.clone();
  url.set_path(&format!("v1/projects/{project_id}"));

  let mut headers = reqwest::header::HeaderMap::new();
  // ...
      
  let mut builder = reqwest::Client::builder();
  // ...
  let client = builder.build()?;
  let result = client
    .get(url)
    .headers(headers)
    .send()
    .await?;
  match result.status().as_u16() {
    200 => {
      let body = result.json::<crate::model::Project>().await?;
      Ok(body)
    }
    404 => {
      let body = result.json::<ProjectEndpointErrorNotFoundPayload>().await?;
      Err(ProjectError::Status404 { message: body.message })
    }
    // ...
  }
}
```

## Putting it all together

At this point we have seen how _ZIO Http_ describes endpoints, how _ZIO Schema_ encodes Scala types, how we can use _ZIO Parser_ to have composable printers and how _ZIO Prelude_ can help with working with state in a purely functional code. The only thing remaining is to wire everything together and define an easy to use function that, when executed, creates all the required _Rust files_ ready to be compiled.

We can create a class for this:

```scala
final case class ClientCrateGenerator(name: String, version: String, description: String, homepage: String, endpoints: Chunk[RustEndpoints]):
```

Here `endpoints` is a collection of a **group of endpoints**, as it was shown earlier. So first you can use `RustEndpoint.fromEither` and `++` to create a `RustEndpoints` value for each API you have, and then generate a client for all of those in one run with this class.

The first thing to do is collect _all_ the referenced `Schema` from all the endpoints:

```scala
private val allSchemas = endpoints.map(_.endpoints.toSet.flatMap(_.referredSchemas)).reduce(_ union _)
```

Then we define a ZIO function (it is an effectful function, manipulating the filesystem!) to generate the files:

```scala
def generate(targetDirectory: Path): ZIO[Any, Throwable, Unit] =
  for
    clientModel <- ZIO.fromEither(RustModel.fromSchemas(allSchemas.toSeq))
                      .mapError(err => new RuntimeException(s"Failed to generate client model: $err"))
    cargoFile = targetDirectory / "Cargo.toml"
    srcDir = targetDirectory / "src"
    libFile = srcDir / "lib.rs"
    modelFile = srcDir / "model.rs"

    requiredCrates = clientModel.requiredCrates union endpoints.map(_.requiredCrates).reduce(_ union _)

    _ <- Files.createDirectories(targetDirectory)
    _ <- Files.createDirectories(srcDir)
    _ <- writeCargo(cargoFile, requiredCrates)
    _ <- writeLib(libFile)
    _ <- writeModel(modelFile, clientModel.definitions)
    _ <- ZIO.foreachDiscard(endpoints): endpoints =>
           val clientFile = srcDir / s"${endpoints.name.toSnakeCase}.rs"
           writeClient(clientFile, endpoints)
  yield ()
```

The steps are straightforward:

- Create a `RustModel` using all the collected `Schema[?]` values
- Create all the required directories 
- Write a *cargo file* - having all the dependencies and other metadata required to compile the Rust project
- Write a *lib file* - this is just a series of `pub mod xyz;` lines, defining the generated modules which are put in different fiels
- Write all the generated Rust types into a `model.rs`
- For each endpoint group create a `xyz.rs` module containing the client trait and implementation

For working with the file system - creating directories, writing data into files, we can use the [[ZIO NIO](https://zio.dev/zio-nio/)] library providing ZIO wrapprers for all these functionalities.

### Links

Finally, some links:

- The **code generator** is open source and available at https://github.com/vigoo/zio-http-rust - the code and the repository itself is not documented at the moment, except by this blog post.
- The generated **Golem client for Rust** is published as a crate to https://crates.io/crates/golem-client
- The new **Golem CLI**, using the generated client, is also open sourced and can be found at https://github.com/golemcloud/golem-cli
- Finally you can learn more about **Golem** itself at https://www.golem.cloud





